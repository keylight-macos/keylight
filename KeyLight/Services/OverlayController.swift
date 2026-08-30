import AppKit
import ColorSync
import CoreGraphics

enum OverlayDisplaySelection: Hashable, Sendable {
    case automatic
    case builtIn
    case main
    case specific(String)

    private static let specificPrefix = "display:"

    init(persistedValue: String?) {
        switch persistedValue {
        case "builtIn":
            self = .builtIn
        case "main":
            self = .main
        case let value? where value.hasPrefix(Self.specificPrefix):
            let persistentID = String(value.dropFirst(Self.specificPrefix.count))
            self = persistentID.isEmpty ? .automatic : .specific(persistentID)
        default:
            self = .automatic
        }
    }

    var persistedValue: String {
        switch self {
        case .automatic:
            return "automatic"
        case .builtIn:
            return "builtIn"
        case .main:
            return "main"
        case .specific(let persistentID):
            return Self.specificPrefix + persistentID
        }
    }
}

struct OverlayDisplayDescriptor: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let isBuiltIn: Bool
    let isMain: Bool
}

struct OverlayDisplayCandidate: Equatable, Sendable {
    let id: CGDirectDisplayID
    let persistentID: String
    let name: String
    let isBuiltIn: Bool
    let isMain: Bool
    let frame: CGRect

    init(
        id: CGDirectDisplayID,
        persistentID: String? = nil,
        name: String? = nil,
        isBuiltIn: Bool,
        isMain: Bool,
        frame: CGRect = .zero
    ) {
        self.id = id
        self.persistentID = persistentID ?? "display-\(id)"
        self.name = name ?? "Display \(id)"
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
        self.frame = frame
    }

    var descriptor: OverlayDisplayDescriptor {
        OverlayDisplayDescriptor(
            id: persistentID,
            name: name,
            isBuiltIn: isBuiltIn,
            isMain: isMain
        )
    }
}

enum OverlayDisplayResolver {
    static func target(
        in candidates: [OverlayDisplayCandidate],
        selection: OverlayDisplaySelection = .automatic
    ) -> OverlayDisplayCandidate? {
        let automatic = candidates.first(where: \.isBuiltIn)
            ?? candidates.first(where: \.isMain)
            ?? candidates.first

        switch selection {
        case .automatic:
            return automatic
        case .builtIn:
            return candidates.first(where: \.isBuiltIn) ?? automatic
        case .main:
            return candidates.first(where: \.isMain) ?? automatic
        case .specific(let persistentID):
            return candidates.first(where: { $0.persistentID == persistentID }) ?? automatic
        }
    }

    static func targetID(
        in candidates: [OverlayDisplayCandidate],
        selection: OverlayDisplaySelection = .automatic
    ) -> CGDirectDisplayID? {
        target(in: candidates, selection: selection)?.id
    }
}

@MainActor
protocol OverlayPanel: AnyObject {
    var glowRenderer: (any GlowRenderer)? { get }
    var frame: NSRect { get }

    func setEffectStyle(_ requestedStyle: EffectStyle)
    func setFrame(_ frameRect: NSRect, display flag: Bool)
    func orderFrontRegardless()
    func close()
}

extension GlowOverlayWindow: OverlayPanel {}

/// Owns KeyLight's passive panel collection, one central interaction state,
/// and the renderer configuration broadcast to every selected display.
/// The controller accepts normalized events and renderer-ready targets only; it
/// never decodes characters or reaches into persistence.
@MainActor
final class OverlayController {
    typealias DisplayProvider = @MainActor () -> [OverlayDisplayCandidate]
    typealias WindowFactory = @MainActor (NSRect) -> any OverlayPanel

    private let overlayHeight: CGFloat
    private let displayProvider: DisplayProvider
    private let windowFactory: WindowFactory
    private let onPhysicalEvent: @MainActor (KeyboardEvent) -> Void
    private var runtimeStatusHandler: (@MainActor (EffectRuntimeStatus) -> Void)?

    private struct PanelEntry {
        let persistentID: String
        let displayID: CGDirectDisplayID
        let panel: any OverlayPanel
    }

    private var panels: [String: PanelEntry] = [:]
    private var primaryDisplayPersistentID: String?
    private var mirroredDisplayIDs: Set<String> = []
    private var perDisplayRendererStates: [String: GlowRendererRuntimeState] = [:]
    private var interactionState = GlowInteractionState()
    private var renderedTarget: GlowTarget?
    private var effectStyle: EffectStyle = .classicGlow
    private var configuration = RendererConfiguration.standard
    private var isEnabled = true
    private var displaySelection: OverlayDisplaySelection = .automatic
    private var latestDisplayCandidates: [OverlayDisplayCandidate] = []

    init(
        overlayHeight: CGFloat = 120,
        displayProvider: @escaping DisplayProvider = OverlayController.liveDisplays,
        windowFactory: @escaping WindowFactory = { GlowOverlayWindow(contentRect: $0) },
        onPhysicalEvent: @escaping @MainActor (KeyboardEvent) -> Void = { _ in }
    ) {
        self.overlayHeight = overlayHeight
        self.displayProvider = displayProvider
        self.windowFactory = windowFactory
        self.onPhysicalEvent = onPhysicalEvent
    }

    var activeDisplayID: CGDirectDisplayID? {
        guard let primaryDisplayPersistentID else { return nil }
        return panels[primaryDisplayPersistentID]?.displayID
    }
    var activeDisplayPersistentID: String? {
        primaryDisplayPersistentID
    }
    var activeDisplayPersistentIDs: [String] {
        guard let primaryDisplayPersistentID,
              panels[primaryDisplayPersistentID] != nil else {
            return panels.keys.sorted()
        }
        return [primaryDisplayPersistentID]
            + panels.keys
                .filter { $0 != primaryDisplayPersistentID }
                .sorted()
    }
    var availableDisplays: [OverlayDisplayDescriptor] {
        latestDisplayCandidates.map(\.descriptor)
    }
    var activePreviewSources: [PreviewSource] {
        interactionState.activePreviewSourcesInPriorityOrder
    }
    var resolvedTarget: GlowTarget? { interactionState.resolvedTarget }

    func setRuntimeStatusHandler(
        _ handler: (@MainActor (EffectRuntimeStatus) -> Void)?
    ) {
        runtimeStatusHandler = handler
        configureAllRuntimeStatusHandlers()
    }

    func start() {
        updateDisplayTopology(forceRecreation: panels.isEmpty)
    }

    func setDisplaySelection(_ selection: OverlayDisplaySelection) {
        guard selection != displaySelection else { return }
        displaySelection = selection
        updateDisplayTopology()
    }

    func setMirroredDisplayIDs(_ persistentIDs: Set<String>) {
        let normalized = Set(
            persistentIDs
                .filter { !$0.isEmpty }
                .sorted()
                .prefix(16)
        )
        guard normalized != mirroredDisplayIDs else { return }
        mirroredDisplayIDs = normalized
        updateDisplayTopology()
    }

    func shutdown() {
        let hadPhysicalInput = !interactionState.heldPhysicalKeyCodes.isEmpty
        interactionState.clearAll()
        if hadPhysicalInput {
            publishPhysicalReset()
        }
        renderedTarget = nil
        clearAndCloseAllPanels()
        primaryDisplayPersistentID = nil
        publishRuntimeStatus()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            renderResolvedTarget(force: true)
        } else {
            let hadPhysicalInput = !interactionState.heldPhysicalKeyCodes.isEmpty
            interactionState.clearAll()
            if hadPhysicalInput {
                publishPhysicalReset()
            }
            renderedTarget = nil
            broadcastClear()
        }
    }

    func apply(effectStyle: EffectStyle, configuration: RendererConfiguration) {
        self.effectStyle = effectStyle
        self.configuration = configuration

        let resolvedStyle = configuration.resolvedEffectStyle(for: effectStyle)
        for entry in panels.values {
            let rendererBefore = entry.panel.glowRenderer
            entry.panel.setEffectStyle(resolvedStyle)
            guard let renderer = entry.panel.glowRenderer else {
                perDisplayRendererStates[entry.persistentID] = GlowRendererRuntimeState(
                    readiness: .failed,
                    captureState: .idle,
                    fallbackReason: "Renderer unavailable"
                )
                continue
            }
            configureRuntimeStatusHandler(
                for: renderer,
                persistentID: entry.persistentID
            )
            renderer.apply(configuration)
            let rendererChanged = rendererBefore.map { $0 !== renderer } ?? true
            if rendererChanged {
                renderResolvedState(on: renderer)
            }
        }
        publishRuntimeStatus()
    }

    func updateDisplayTopology(forceRecreation: Bool = false) {
        let candidates = displayProvider()
        latestDisplayCandidates = candidates
        guard let primaryDisplay = OverlayDisplayResolver.target(
            in: candidates,
            selection: displaySelection
        ) else {
            let hadPhysicalInput = !interactionState.heldPhysicalKeyCodes.isEmpty
            interactionState.clearPhysicalInput()
            if hadPhysicalInput {
                publishPhysicalReset()
            }
            renderedTarget = nil
            clearAndCloseAllPanels()
            primaryDisplayPersistentID = nil
            publishRuntimeStatus()
            return
        }

        let previousPrimaryID = primaryDisplayPersistentID
        let nextPrimaryID = primaryDisplay.persistentID
        if let previousPrimaryID, previousPrimaryID != nextPrimaryID {
            let hadPhysicalInput = !interactionState.heldPhysicalKeyCodes.isEmpty
            interactionState.clearPhysicalInput()
            if hadPhysicalInput {
                publishPhysicalReset()
            }
            broadcastClear()
            renderedTarget = nil
        }
        primaryDisplayPersistentID = nextPrimaryID

        var desiredByPersistentID: [String: OverlayDisplayCandidate] = [
            nextPrimaryID: primaryDisplay
        ]
        for candidate in candidates
        where mirroredDisplayIDs.contains(candidate.persistentID)
            && candidate.persistentID != nextPrimaryID {
            desiredByPersistentID[candidate.persistentID] = candidate
        }

        if forceRecreation {
            clearAndCloseAllPanels()
        } else {
            let stalePanelIDs = panels.keys.filter {
                desiredByPersistentID[$0] == nil
            }
            for persistentID in stalePanelIDs {
                removePanel(persistentID: persistentID)
            }
        }

        let orderedIDs = [nextPrimaryID]
            + desiredByPersistentID.keys
                .filter { $0 != nextPrimaryID }
                .sorted()
        for persistentID in orderedIDs {
            guard let candidate = desiredByPersistentID[persistentID] else {
                continue
            }
            let frame = Self.panelFrame(
                for: candidate.frame,
                height: overlayHeight
            )

            if let existing = panels[persistentID],
               existing.displayID == candidate.id {
                let frameChanged = existing.panel.frame != frame
                existing.panel.setFrame(frame, display: true)
                if frameChanged, let renderer = existing.panel.glowRenderer {
                    renderer.clear()
                    renderer.apply(configuration)
                    renderResolvedState(on: renderer)
                }
                continue
            }

            removePanel(persistentID: persistentID)
            let replacement = windowFactory(frame)
            replacement.setEffectStyle(
                configuration.resolvedEffectStyle(for: effectStyle)
            )
            let entry = PanelEntry(
                persistentID: persistentID,
                displayID: candidate.id,
                panel: replacement
            )
            panels[persistentID] = entry
            configureRuntimeStatusHandler(
                for: replacement.glowRenderer,
                persistentID: persistentID
            )
            replacement.glowRenderer?.apply(configuration)
            replacement.orderFrontRegardless()
            if let renderer = replacement.glowRenderer {
                renderResolvedState(on: renderer)
            }
        }

        publishRuntimeStatus()
    }

    func handle(_ event: KeyboardEvent, target: GlowTarget? = nil) {
        defer {
            KeyLightSignposts.rendererSubmitted(sequence: event.sequence)
        }
        // Calibration mirrors the same normalized stream as the renderer,
        // including resets so transient pressed-state cannot become stale.
        onPhysicalEvent(event)

        guard isEnabled else {
            if event.action == .streamReset {
                interactionState.clearPhysicalInput()
            }
            return
        }

        let previous = interactionState.resolvedTarget
        switch event.action {
        case .down:
            let transition = interactionState.handle(event, target: target)
            guard let keyCode = event.canonicalKeyCode,
                  let physicalTarget = interactionState.target(
                    for: .physicalKey(keyCode)
                  ) else {
                return
            }

            if event.isRepeat,
               broadcastRefresh(physicalTarget.id) {
                renderedTarget = physicalTarget
                return
            }

            if let previous, case .preview = previous.id {
                if case .preview(let source) = previous.id, source.isChordTest {
                    for chordTarget in interactionState.activeChordTestTargetsInSourceOrder {
                        broadcastHide(chordTarget.id)
                    }
                } else {
                    broadcastHide(previous.id)
                }
                renderedTarget = nil
            }

            if renderersSupportConcurrentTargets {
                broadcastShow(physicalTarget)
                renderedTarget = physicalTarget
            } else {
                renderResolvedTarget(force: transition.previous != transition.current)
            }

        case .up:
            if let keyCode = event.canonicalKeyCode {
                broadcastHide(.physicalKey(keyCode))
            }
            let transition = interactionState.handle(event)

            if renderersSupportConcurrentTargets {
                if interactionState.activePhysicalTargetsInPressOrder.isEmpty {
                    renderedTarget = nil
                    renderResolvedTarget(force: true)
                } else {
                    renderedTarget = interactionState.activePhysicalTargetsInPressOrder.last
                }
            } else if transition.current != transition.previous {
                renderedTarget = nil
                renderResolvedTarget(force: true)
            }

        case .streamReset:
            interactionState.handle(event)
            broadcastClear()
            renderedTarget = nil
            renderResolvedTarget(force: true)
        }
    }

    func setPreview(_ target: GlowTarget, source: PreviewSource) {
        guard !source.isChordTest else { return }
        guard target.id == .preview(source) else { return }
        guard isEnabled else {
            interactionState.clearPreview(source)
            return
        }
        let transition = interactionState.setPreview(target, for: source)
        guard transition.current != transition.previous else { return }
        if let previous = transition.previous {
            broadcastHide(previous.id)
        }
        renderedTarget = nil
        renderResolvedTarget(force: true)
    }

    func clearPreview(_ source: PreviewSource) {
        guard !source.isChordTest else { return }
        let transition = interactionState.clearPreview(source)
        guard isEnabled, transition.current != transition.previous else { return }
        broadcastHide(.preview(source))
        renderedTarget = nil
        renderResolvedTarget(force: true)
    }

    func setChordPreview(_ targets: [GlowTarget]) {
        let acceptedTargets = PreviewSource.chordTestSources.compactMap { source in
            targets.first(where: { $0.id == .preview(source) })
        }
        let oldTargets = interactionState.activeChordTestTargetsInSourceOrder
        guard acceptedTargets != oldTargets else { return }

        let previous = interactionState.resolvedTarget
        interactionState.replaceChordTestTargets(acceptedTargets)
        for target in oldTargets {
            broadcastHide(target.id)
        }

        guard isEnabled,
              interactionState.activePhysicalTargetsInPressOrder.isEmpty else {
            return
        }
        if let previous,
           case .preview(let source) = previous.id,
           !source.isChordTest {
            broadcastHide(previous.id)
        }
        renderedTarget = nil
        renderResolvedTarget(force: true)
    }

    func clearChordPreview() {
        let oldTargets = interactionState.activeChordTestTargetsInSourceOrder
        guard !oldTargets.isEmpty else { return }
        interactionState.clearChordTestTargets()
        for target in oldTargets {
            broadcastHide(target.id)
        }
        guard isEnabled,
              interactionState.activePhysicalTargetsInPressOrder.isEmpty else {
            return
        }
        renderedTarget = nil
        renderResolvedTarget(force: true)
    }

    func clearPhysicalInput(source: KeyboardEvent.Source = .lifecycle) {
        handle(.streamReset(source: source, timestamp: ProcessInfo.processInfo.systemUptime))
    }

    private func renderResolvedTarget(force: Bool) {
        guard isEnabled, !activeRenderers.isEmpty else {
            return
        }

        let physicalTargets = interactionState.activePhysicalTargetsInPressOrder
        if renderersSupportConcurrentTargets, !physicalTargets.isEmpty {
            if !force, renderedTarget == physicalTargets.last {
                return
            }
            for target in physicalTargets {
                broadcastShow(target)
            }
            renderedTarget = physicalTargets.last
            return
        }

        let chordTargets = interactionState.activeChordTestTargetsInSourceOrder
        if renderersSupportConcurrentTargets, !chordTargets.isEmpty {
            if !force, renderedTarget == chordTargets.last {
                return
            }
            for target in chordTargets {
                broadcastShow(target)
            }
            renderedTarget = chordTargets.last
            return
        }

        guard let target = interactionState.resolvedTarget else { return }
        if !force, renderedTarget == target {
            return
        }
        broadcastShow(target)
        renderedTarget = target
    }

    private func renderResolvedState(on renderer: any GlowRenderer) {
        guard isEnabled else { return }
        let physicalTargets = interactionState.activePhysicalTargetsInPressOrder
        if renderer.supportsConcurrentPhysicalTargets,
           !physicalTargets.isEmpty {
            for target in physicalTargets {
                renderer.show(target)
            }
            return
        }

        let chordTargets = interactionState.activeChordTestTargetsInSourceOrder
        if renderer.supportsConcurrentPhysicalTargets,
           !chordTargets.isEmpty {
            for target in chordTargets {
                renderer.show(target)
            }
            return
        }

        if let target = interactionState.resolvedTarget {
            renderer.show(target)
        }
    }

    private func publishPhysicalReset() {
        onPhysicalEvent(.streamReset(
            source: .lifecycle,
            timestamp: ProcessInfo.processInfo.systemUptime
        ))
    }

    private var activeRenderers: [any GlowRenderer] {
        activeDisplayPersistentIDs.compactMap {
            panels[$0]?.panel.glowRenderer
        }
    }

    private var renderersSupportConcurrentTargets: Bool {
        let renderers = activeRenderers
        return !renderers.isEmpty
            && renderers.allSatisfy(\.supportsConcurrentPhysicalTargets)
    }

    private func broadcastShow(_ target: GlowTarget) {
        for renderer in activeRenderers {
            renderer.show(target)
        }
    }

    private func broadcastHide(_ id: GlowID) {
        for renderer in activeRenderers {
            renderer.hide(id)
        }
    }

    private func broadcastClear() {
        for renderer in activeRenderers {
            renderer.clear()
        }
    }

    private func broadcastRefresh(_ id: GlowID) -> Bool {
        let renderers = activeRenderers
        guard !renderers.isEmpty else { return false }
        return renderers.map { $0.refresh(id) }.allSatisfy { $0 }
    }

    private func removePanel(persistentID: String) {
        guard let entry = panels.removeValue(forKey: persistentID) else {
            return
        }
        entry.panel.glowRenderer?.clear()
        entry.panel.close()
        perDisplayRendererStates.removeValue(forKey: persistentID)
    }

    private func clearAndCloseAllPanels() {
        let persistentIDs = Array(panels.keys)
        for persistentID in persistentIDs {
            removePanel(persistentID: persistentID)
        }
    }

    private func configureAllRuntimeStatusHandlers() {
        for entry in panels.values {
            configureRuntimeStatusHandler(
                for: entry.panel.glowRenderer,
                persistentID: entry.persistentID
            )
        }
        publishRuntimeStatus()
    }

    private func configureRuntimeStatusHandler(
        for renderer: (any GlowRenderer)?,
        persistentID: String
    ) {
        let selected = effectStyle
        let powerSavingActive = configuration.automaticPowerSavingIsActive
            && selected.supportedStyle == .physicalRefraction
        let powerEnvironmentState = configuration.powerEnvironmentState
        guard let renderer else {
            perDisplayRendererStates[persistentID] = GlowRendererRuntimeState(
                readiness: .failed,
                captureState: .idle,
                fallbackReason: "Renderer unavailable"
            )
            publishRuntimeStatus()
            return
        }

        renderer.setRuntimeStatusHandler { [weak self] rendererState in
            guard let self else { return }
            var state = rendererState
            if powerSavingActive {
                state.readiness = .fallback
                state.captureState = .idle
                state.fallbackReason = powerEnvironmentState
                    .fallbackReason
                    .map { "Automatic Power Saving: \($0)" }
                    ?? "Automatic Power Saving is active"
            } else if selected == .physicalRefraction,
               !ScreenCaptureAuthorization.isGranted {
                state.readiness = .fallback
                state.captureState = .permissionRequired
                state.fallbackReason = "Screen Recording permission is not allowed"
            }
            self.perDisplayRendererStates[persistentID] = state
            self.publishRuntimeStatus()
        }
    }

    private func publishRuntimeStatus() {
        guard let runtimeStatusHandler else { return }
        let selected = effectStyle
        let powerSavingActive = configuration.automaticPowerSavingIsActive
            && selected.supportedStyle == .physicalRefraction
        let activeIDs = activeDisplayPersistentIDs
        let states = activeIDs.map { persistentID in
            perDisplayRendererStates[persistentID]
                ?? GlowRendererRuntimeState(
                    readiness: .failed,
                    captureState: .idle,
                    fallbackReason: "Renderer unavailable on \(persistentID)"
                )
        }
        let aggregate = states.max { left, right in
            let leftRank = Self.readinessRank(left.readiness)
            let rightRank = Self.readinessRank(right.readiness)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            return Self.captureRank(left.captureState)
                < Self.captureRank(right.captureState)
        } ?? GlowRendererRuntimeState(
            readiness: .failed,
            captureState: .idle,
            fallbackReason: "No display is available"
        )

        runtimeStatusHandler(EffectRuntimeStatus(
            selectedEffect: selected,
            resolvedEffect: configuration.resolvedEffectStyle(for: selected),
            rendererReadiness: aggregate.readiness,
            captureState: aggregate.captureState,
            fallbackReason: aggregate.fallbackReason,
            powerSavingMode: configuration.powerSavingMode,
            powerEnvironmentState: configuration.powerEnvironmentState,
            automaticPowerSavingIsActive: powerSavingActive,
            activeDisplayID: activeDisplayID,
            activeDisplayPersistentIDs: activeIDs,
            sampledStripHeight: selected == .physicalRefraction
                && !powerSavingActive
                && !activeIDs.isEmpty
                ? Double(max(overlayHeight + 80, 180))
                : nil
        ))
    }

    private static func readinessRank(_ readiness: RendererReadiness) -> Int {
        switch readiness {
        case .ready: 0
        case .fallback: 1
        case .failed: 2
        }
    }

    private static func captureRank(_ state: PhysicalCaptureState) -> Int {
        switch state {
        case .idle: 0
        case .stopping: 1
        case .gracePeriod: 2
        case .active: 3
        case .starting: 4
        case .permissionRequired: 5
        case .failed: 6
        }
    }

    private static func liveDisplays() -> [OverlayDisplayCandidate] {
        let mainScreen = NSScreen.main
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else {
                return nil
            }
            return OverlayDisplayCandidate(
                id: id,
                persistentID: persistentDisplayID(for: id),
                name: screen.localizedName,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                isMain: mainScreen.map { screen === $0 } ?? false,
                frame: screen.frame
            )
        }
    }

    private static func persistentDisplayID(for displayID: CGDirectDisplayID) -> String {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return "display-\(displayID)"
        }
        let uuid = unmanagedUUID.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func panelFrame(for screenFrame: CGRect, height: CGFloat) -> NSRect {
        NSRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: height
        )
    }
}
