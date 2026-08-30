import Foundation

enum InputMonitoringState: Equatable, Sendable {
    case checking
    case permissionRequired
    case authorized
    case starting
    case active
    case monitorUnavailable
}

enum GlobalHotKeyStatus: Equatable, Sendable {
    case checking
    case registered
    case unavailable
}

/// One ephemeral, privacy-safe physical-key transition for setup verification
/// and calibration highlighting. The model retains no history or characters.
struct PhysicalKeyActivity: Equatable, Sendable {
    let sequence: UInt
    let keyCode: UInt16
    let isDown: Bool
}

/// Identifies an internal, non-physical glow preview.
enum PreviewSource: String, CaseIterable, Hashable, Sendable {
    case settings
    case keyEditor
    case guidedCalibration
    case chordTest1
    case chordTest2
    case chordTest3
    case chordTest4

    static let chordTestSources: [PreviewSource] = [
        .chordTest1, .chordTest2, .chordTest3, .chordTest4
    ]

    var isChordTest: Bool {
        Self.chordTestSources.contains(self)
    }

    fileprivate static let renderPriority: [PreviewSource] = [
        .chordTest1, .chordTest2, .chordTest3, .chordTest4,
        .guidedCalibration, .keyEditor, .settings
    ]
}

/// Stable identity for either a physically held key or a transient preview.
enum GlowID: Hashable, Sendable {
    case physicalKey(UInt16)
    case preview(PreviewSource)
}

/// Renderer-independent geometry for one glow.
///
/// Values use `Double` rather than AppKit/CoreGraphics types so the interaction
/// model remains portable and straightforward to unit test. Construction keeps
/// every target finite and within the renderer's existing safe ranges.
struct GlowTarget: Hashable, Sendable {
    static let horizontalPositionRange: ClosedRange<Double> = 0 ... 1
    static let keyWidthRange: ClosedRange<Double> = 0.05 ... 5

    let id: GlowID
    let colorReferenceKeyCode: UInt16?
    let horizontalPosition: Double
    let keyWidth: Double

    static func physicalKey(
        _ canonicalKeyCode: UInt16,
        horizontalPosition: Double,
        keyWidth: Double
    ) -> GlowTarget {
        GlowTarget(
            id: .physicalKey(canonicalKeyCode),
            colorReferenceKeyCode: canonicalKeyCode,
            horizontalPosition: horizontalPosition,
            keyWidth: keyWidth
        )
    }

    static func preview(
        _ source: PreviewSource,
        colorReferenceKeyCode: UInt16? = nil,
        horizontalPosition: Double,
        keyWidth: Double
    ) -> GlowTarget {
        GlowTarget(
            id: .preview(source),
            colorReferenceKeyCode: colorReferenceKeyCode,
            horizontalPosition: horizontalPosition,
            keyWidth: keyWidth
        )
    }

    private init(
        id: GlowID,
        colorReferenceKeyCode: UInt16?,
        horizontalPosition: Double,
        keyWidth: Double
    ) {
        self.id = id
        self.colorReferenceKeyCode = colorReferenceKeyCode
        self.horizontalPosition = Self.sanitized(
            horizontalPosition,
            default: 0.5,
            in: Self.horizontalPositionRange
        )
        self.keyWidth = Self.sanitized(
            keyWidth,
            default: 1,
            in: Self.keyWidthRange
        )
    }

    private static func sanitized(
        _ value: Double,
        default defaultValue: Double,
        in range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Privacy-safe keyboard metadata emitted after platform events are decoded.
///
/// It intentionally has no character, modifier text, or raw event payload.
/// `canonicalKeyCode` is populated only for key transitions; stream resets use
/// `nil` and clear all physical interaction state.
struct KeyboardEvent: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case down
        case up
        case streamReset
    }

    enum Source: Equatable, Sendable {
        case eventTap
        case consumerHID
        case lifecycle
    }

    let action: Action
    let canonicalKeyCode: UInt16?
    let isRepeat: Bool
    let source: Source
    let timestamp: TimeInterval
    let sequence: UInt64

    static func keyDown(
        _ canonicalKeyCode: UInt16,
        isRepeat: Bool = false,
        source: Source,
        timestamp: TimeInterval,
        sequence: UInt64 = 0
    ) -> KeyboardEvent {
        KeyboardEvent(
            action: .down,
            canonicalKeyCode: canonicalKeyCode,
            isRepeat: isRepeat,
            source: source,
            timestamp: timestamp,
            sequence: sequence
        )
    }

    static func keyUp(
        _ canonicalKeyCode: UInt16,
        source: Source,
        timestamp: TimeInterval,
        sequence: UInt64 = 0
    ) -> KeyboardEvent {
        KeyboardEvent(
            action: .up,
            canonicalKeyCode: canonicalKeyCode,
            isRepeat: false,
            source: source,
            timestamp: timestamp,
            sequence: sequence
        )
    }

    static func streamReset(
        source: Source = .lifecycle,
        timestamp: TimeInterval,
        sequence: UInt64 = 0
    ) -> KeyboardEvent {
        KeyboardEvent(
            action: .streamReset,
            canonicalKeyCode: nil,
            isRepeat: false,
            source: source,
            timestamp: timestamp,
            sequence: sequence
        )
    }

    private init(
        action: Action,
        canonicalKeyCode: UInt16?,
        isRepeat: Bool,
        source: Source,
        timestamp: TimeInterval,
        sequence: UInt64
    ) {
        self.action = action
        self.canonicalKeyCode = canonicalKeyCode
        self.isRepeat = isRepeat
        self.source = source
        self.timestamp = timestamp.isFinite && timestamp >= 0 ? timestamp : 0
        self.sequence = sequence
    }
}

/// Resolution before and after one interaction-state mutation.
///
/// Consumers can ignore no-op transitions, refresh when the ID is unchanged but
/// geometry differs, and switch targets when the resolved ID changes.
struct GlowInteractionTransition: Equatable, Sendable {
    let previous: GlowTarget?
    let current: GlowTarget?

    var isNoOp: Bool { previous == current }
}

/// Deterministic source of truth for physical-key ordering and preview priority.
///
/// The value has no actor affinity. `OverlayController` owns it on the main actor
/// while pure tests and event normalization remain actor-free.
struct GlowInteractionState: Equatable, Sendable {
    private(set) var heldPhysicalKeyCodes: [UInt16] = []
    private var physicalTargets: [UInt16: GlowTarget] = [:]
    private var previewTargets: [PreviewSource: GlowTarget] = [:]

    var resolvedTarget: GlowTarget? {
        if let keyCode = heldPhysicalKeyCodes.last {
            return physicalTargets[keyCode]
        }

        for source in PreviewSource.renderPriority {
            if let target = previewTargets[source] {
                return target
            }
        }

        return nil
    }

    var activePreviewSourcesInPriorityOrder: [PreviewSource] {
        PreviewSource.renderPriority.filter { previewTargets[$0] != nil }
    }

    var activeChordTestTargetsInSourceOrder: [GlowTarget] {
        PreviewSource.chordTestSources.compactMap { previewTargets[$0] }
    }

    /// All physically held targets in deterministic press order. Concurrent
    /// renderers use the complete chord, while `resolvedTarget` remains the
    /// newest key for priority decisions and legacy renderer fallbacks.
    var activePhysicalTargetsInPressOrder: [GlowTarget] {
        heldPhysicalKeyCodes.compactMap { physicalTargets[$0] }
    }

    func target(for id: GlowID) -> GlowTarget? {
        switch id {
        case .physicalKey(let keyCode):
            return physicalTargets[keyCode]
        case .preview(let source):
            return previewTargets[source]
        }
    }

    /// Applies one normalized keyboard event. A key-down requires a matching
    /// physical target resolved from the current layout. Key-up and reset events
    /// ignore `target`.
    @discardableResult
    mutating func handle(
        _ event: KeyboardEvent,
        target: GlowTarget? = nil
    ) -> GlowInteractionTransition {
        let previous = resolvedTarget

        switch event.action {
        case .down:
            guard let keyCode = event.canonicalKeyCode,
                  let target,
                  target.id == .physicalKey(keyCode) else {
                return GlowInteractionTransition(previous: previous, current: previous)
            }

            physicalTargets[keyCode] = target
            if !heldPhysicalKeyCodes.contains(keyCode) {
                heldPhysicalKeyCodes.append(keyCode)
            }

        case .up:
            guard let keyCode = event.canonicalKeyCode else {
                return GlowInteractionTransition(previous: previous, current: previous)
            }
            physicalTargets.removeValue(forKey: keyCode)
            heldPhysicalKeyCodes.removeAll { $0 == keyCode }

        case .streamReset:
            physicalTargets.removeAll(keepingCapacity: true)
            heldPhysicalKeyCodes.removeAll(keepingCapacity: true)
        }

        return GlowInteractionTransition(previous: previous, current: resolvedTarget)
    }

    @discardableResult
    mutating func setPreview(
        _ target: GlowTarget,
        for source: PreviewSource
    ) -> GlowInteractionTransition {
        let previous = resolvedTarget
        guard target.id == .preview(source) else {
            return GlowInteractionTransition(previous: previous, current: previous)
        }

        previewTargets[source] = target
        return GlowInteractionTransition(previous: previous, current: resolvedTarget)
    }

    @discardableResult
    mutating func clearPreview(_ source: PreviewSource) -> GlowInteractionTransition {
        let previous = resolvedTarget
        previewTargets.removeValue(forKey: source)
        return GlowInteractionTransition(previous: previous, current: resolvedTarget)
    }

    @discardableResult
    mutating func replaceChordTestTargets(
        _ targets: [GlowTarget]
    ) -> GlowInteractionTransition {
        let previous = resolvedTarget
        for source in PreviewSource.chordTestSources {
            previewTargets.removeValue(forKey: source)
        }
        for source in PreviewSource.chordTestSources {
            if let target = targets.first(where: { $0.id == .preview(source) }) {
                previewTargets[source] = target
            }
        }
        return GlowInteractionTransition(previous: previous, current: resolvedTarget)
    }

    @discardableResult
    mutating func clearChordTestTargets() -> GlowInteractionTransition {
        replaceChordTestTargets([])
    }

    /// Clears only physical input, retaining previews so the highest-priority
    /// still-active preview resumes immediately.
    @discardableResult
    mutating func clearPhysicalInput() -> GlowInteractionTransition {
        let previous = resolvedTarget
        physicalTargets.removeAll(keepingCapacity: true)
        heldPhysicalKeyCodes.removeAll(keepingCapacity: true)
        return GlowInteractionTransition(previous: previous, current: resolvedTarget)
    }

    @discardableResult
    mutating func clearAll() -> GlowInteractionTransition {
        let previous = resolvedTarget
        physicalTargets.removeAll(keepingCapacity: true)
        heldPhysicalKeyCodes.removeAll(keepingCapacity: true)
        previewTargets.removeAll(keepingCapacity: true)
        return GlowInteractionTransition(previous: previous, current: nil)
    }
}
