import AppKit
import Observation
import SwiftUI

/// The single user-facing state boundary shared by KeyLight's scene roots.
/// Platform lifecycle and renderer ownership remain outside this model.
@MainActor
@Observable
final class KeyLightModel {
    typealias FeedbackAnnouncer = @MainActor (String) -> Void

    private let settings: SettingsManager
    @ObservationIgnored private let feedbackAnnouncer: FeedbackAnnouncer

    @ObservationIgnored private var isLoading = true
    @ObservationIgnored private var persistWorkItem: DispatchWorkItem?
    @ObservationIgnored private var enabledChangeHandler: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private var configurationChangeHandler: (@MainActor () -> Void)?
    @ObservationIgnored private var permissionRequestHandler: (@MainActor () -> Void)?
    @ObservationIgnored private var permissionRetryHandler: (@MainActor () -> Void)?
    @ObservationIgnored private var inputMonitoringSettingsHandler: (@MainActor () -> Void)?
    @ObservationIgnored private var previewSetHandler: (@MainActor (GlowTarget, PreviewSource) -> Void)?
    @ObservationIgnored private var previewClearHandler: (@MainActor (PreviewSource) -> Void)?
    @ObservationIgnored private var chordPreviewSetHandler: (@MainActor ([GlowTarget]) -> Void)?
    @ObservationIgnored private var chordPreviewClearHandler: (@MainActor () -> Void)?
    @ObservationIgnored private var displaySelectionHandler: (@MainActor (OverlayDisplaySelection) -> Void)?
    @ObservationIgnored private var mirroredDisplaysHandler: (@MainActor (Set<String>) -> Void)?
    @ObservationIgnored private var displayLayoutBindingHandler: (@MainActor (String, UUID?) -> Void)?
    @ObservationIgnored private var shortcutChangeHandler: (@MainActor (GlobalShortcut) -> Void)?
    @ObservationIgnored private var physicalKeySequence: UInt = 0

    private let persistDebounceInterval: TimeInterval = 0.1

    var isEnabled: Bool = true {
        didSet {
            if !isLoading {
                settings.isEnabled = isEnabled
                enabledChangeHandler?(isEnabled)
                configurationChangeHandler?()
            }
        }
    }

    var inputMonitoringState: InputMonitoringState = .checking
    var inputMonitoringAppPath: String = Bundle.main.bundlePath
    var inputMonitoringInstallationIssue: String?
    private(set) var hasSeenPermissionExplanation: Bool = false
    private(set) var permissionSetupPresentationRequested: Bool = false
    private(set) var physicalKeyActivity: PhysicalKeyActivity?
    private(set) var savedThemes: [Theme] = []
    private(set) var selectedThemeID: UUID?
    var feedback: UserFeedback? {
        didSet {
            guard feedback != oldValue, let feedback else { return }
            announce(feedback)
        }
    }
    private(set) var globalHotKeyStatus: GlobalHotKeyStatus = .checking
    private(set) var effectRuntimeStatus: EffectRuntimeStatus = .initial
    private(set) var availableDisplays: [OverlayDisplayDescriptor] = []
    private(set) var activeDisplayPersistentID: String?
    private(set) var activeDisplayPersistentIDs: [String] = []

    var overlayDisplaySelection: OverlayDisplaySelection = .automatic {
        didSet {
            guard !isLoading, overlayDisplaySelection != oldValue else { return }
            settings.overlayDisplaySelection = overlayDisplaySelection
            displaySelectionHandler?(overlayDisplaySelection)
        }
    }

    var mirroredDisplayIDs: Set<String> = [] {
        didSet {
            guard !isLoading, mirroredDisplayIDs != oldValue else { return }
            settings.mirroredDisplayIDs = mirroredDisplayIDs
            mirroredDisplaysHandler?(mirroredDisplayIDs)
        }
    }

    var globalShortcut: GlobalShortcut = .default {
        didSet {
            guard !isLoading, globalShortcut != oldValue else { return }
            settings.globalShortcut = globalShortcut
            shortcutChangeHandler?(globalShortcut)
        }
    }

    var glowColor: Color = Color(hex: "68B8FF") ?? Color(red: 0.41, green: 0.72, blue: 1.0) {
        didSet {
            glowNSColor = NSColor(glowColor)
            if !isLoading {
                debouncedPersist()
                configurationChangeHandler?()
            }
        }
    }

    var glowOpacity: Double = 0.8013 {
        didSet {
            if !isLoading {
                debouncedPersist()
                configurationChangeHandler?()
            }
        }
    }

    var physicalRefractionStrength: Double = 1.0 {
        didSet {
            if !isLoading {
                debouncedPersist()
                configurationChangeHandler?()
            }
        }
    }

    var glowSize: Double = 80.5536 {
        didSet {
            if !isLoading {
                debouncedPersist()
                configurationChangeHandler?()
            }
        }
    }

    var glowWidth: Double = 1.0 {
        didSet {
            if !isLoading {
                debouncedPersist()
                configurationChangeHandler?()
            }
        }
    }

    var glowRoundness: Double = 0.7069 {
        didSet {
            if !isLoading {
                debouncedPersist()
                configurationChangeHandler?()
            }
        }
    }

    var glowFullness: Double = 0.6046 {
        didSet {
            if !isLoading {
                debouncedPersist()
                configurationChangeHandler?()
            }
        }
    }

    var fadeDuration: Double = 1.0004 {
        didSet {
            if !isLoading {
                debouncedPersist()
                configurationChangeHandler?()
            }
        }
    }

    var launchAtLogin: Bool = false {
        didSet {
            if !isLoading {
                let requestedValue = launchAtLogin
                let result = settings.setLaunchAtLogin(requestedValue)
                let actualValue = result.status.isEnabled
                if !result.isApplied || actualValue != requestedValue {
                    isLoading = true
                    launchAtLogin = actualValue
                    isLoading = false
                    feedback = launchAtLoginFeedback(for: result)
                }
            }
        }
    }

    var colorMode: ColorMode = .positionGradient {
        didSet {
            if !isLoading {
                debouncedPersist()
                configurationChangeHandler?()
            }
        }
    }

    var effectStyle: EffectStyle = .classicGlow {
        didSet {
            guard !isLoading else { return }
            let previousStyle = oldValue.supportedStyle
            let requestedStyle = effectStyle.supportedStyle
            if effectStyle != requestedStyle {
                isLoading = true
                effectStyle = requestedStyle
                isLoading = false
            }
            guard previousStyle != requestedStyle else { return }
            switchEffectProfile(
                from: previousStyle,
                to: requestedStyle
            )
        }
    }

    var chordAppearance: ChordAppearance = .default {
        didSet {
            guard !isLoading else { return }
            let normalized = chordAppearance.normalized
            if chordAppearance != normalized {
                isLoading = true
                chordAppearance = normalized
                isLoading = false
            }
            settings.chordAppearance = normalized
            configurationChangeHandler?()
        }
    }

    var powerSavingMode: PowerSavingMode = .automatic {
        didSet {
            guard !isLoading, powerSavingMode != oldValue else { return }
            settings.powerSavingMode = powerSavingMode
            configurationChangeHandler?()
        }
    }

    private(set) var powerEnvironmentState: PowerEnvironmentState = .normal

    var automaticPowerSavingIsActive: Bool {
        powerSavingMode == .automatic
            && powerEnvironmentState.requiresFallback
    }

    var surfaceShapeProfile: SurfaceShapeProfile = .currentWave {
        didSet {
            if !isLoading {
                debouncedPersist()
                configurationChangeHandler?()
            }
        }
    }

    var gradientStartColor: Color = Color(hex: "68B8FF") ?? .blue {
        didSet {
            gradientStartNSColor = NSColor(gradientStartColor)
            if !isLoading {
                debouncedPersist()
                configurationChangeHandler?()
            }
        }
    }

    var gradientEndColor: Color = Color(hex: "00E69A") ?? .green {
        didSet {
            gradientEndNSColor = NSColor(gradientEndColor)
            if !isLoading {
                debouncedPersist()
                configurationChangeHandler?()
            }
        }
    }

    @ObservationIgnored
    private(set) var glowNSColor = NSColor(red: 0.41, green: 0.72, blue: 1.0, alpha: 1.0)

    @ObservationIgnored
    private(set) var gradientStartNSColor = NSColor(red: 0.41, green: 0.72, blue: 1.0, alpha: 1.0)

    @ObservationIgnored
    private(set) var gradientEndNSColor = NSColor(red: 0.0, green: 0.90, blue: 0.60, alpha: 1.0)

    init(
        settings: SettingsManager,
        feedbackAnnouncer: @escaping FeedbackAnnouncer = KeyLightModel.announceFeedback
    ) {
        self.settings = settings
        self.feedbackAnnouncer = feedbackAnnouncer
        loadSettings()
        reloadSavedThemes()
        isLoading = false
    }

    var selectedTheme: Theme? {
        selectedThemeID.flatMap { id in savedThemes.first(where: { $0.id == id }) }
    }

    var currentEffectConfiguration: EffectConfiguration {
        effectConfiguration(style: effectStyle)
    }

    private func effectConfiguration(style: EffectStyle) -> EffectConfiguration {
        EffectConfiguration(
            style: style.supportedStyle,
            shapeProfile: surfaceShapeProfile,
            color: ColorConfiguration(
                mode: colorMode,
                solidHex: Self.normalizedHex(glowColor.toHex(), fallback: "68B8FF"),
                gradientStartHex: Self.normalizedHex(gradientStartColor.toHex(), fallback: "68B8FF"),
                gradientEndHex: Self.normalizedHex(gradientEndColor.toHex(), fallback: "00E69A")
            ),
            opacity: glowOpacity,
            refractionStrength: physicalRefractionStrength,
            height: glowSize,
            width: glowWidth,
            roundness: glowRoundness,
            hardness: glowFullness,
            fadeDuration: fadeDuration
        )
    }

    var selectedThemeIsEdited: Bool {
        guard let selectedTheme else { return false }
        return Self.effectConfiguration(for: selectedTheme) != currentEffectConfiguration
    }

    /// Connects the user-facing model to its runtime owner. Renderer updates
    /// are deliberately immediate; persistence keeps the single trailing
    /// debounce below. Reconnecting replaces the previous owner atomically.
    func connectRuntime(
        onEnabledChange: @escaping @MainActor (Bool) -> Void,
        onConfigurationChange: @escaping @MainActor () -> Void,
        onPermissionRequest: @escaping @MainActor () -> Void,
        onPermissionRetry: @escaping @MainActor () -> Void,
        onOpenInputMonitoringSettings: @escaping @MainActor () -> Void = {},
        onPreviewSet: @escaping @MainActor (GlowTarget, PreviewSource) -> Void = { _, _ in },
        onPreviewClear: @escaping @MainActor (PreviewSource) -> Void = { _ in },
        onChordPreviewSet: @escaping @MainActor ([GlowTarget]) -> Void = { _ in },
        onChordPreviewClear: @escaping @MainActor () -> Void = {},
        onDisplaySelectionChange: @escaping @MainActor (OverlayDisplaySelection) -> Void = { _ in },
        onMirroredDisplaysChange: @escaping @MainActor (Set<String>) -> Void = { _ in },
        onDisplayLayoutBindingChange: @escaping @MainActor (String, UUID?) -> Void = { _, _ in },
        onShortcutChange: @escaping @MainActor (GlobalShortcut) -> Void = { _ in }
    ) {
        enabledChangeHandler = onEnabledChange
        configurationChangeHandler = onConfigurationChange
        permissionRequestHandler = onPermissionRequest
        permissionRetryHandler = onPermissionRetry
        inputMonitoringSettingsHandler = onOpenInputMonitoringSettings
        previewSetHandler = onPreviewSet
        previewClearHandler = onPreviewClear
        chordPreviewSetHandler = onChordPreviewSet
        chordPreviewClearHandler = onChordPreviewClear
        displaySelectionHandler = onDisplaySelectionChange
        mirroredDisplaysHandler = onMirroredDisplaysChange
        displayLayoutBindingHandler = onDisplayLayoutBindingChange
        shortcutChangeHandler = onShortcutChange
    }

    func disconnectRuntime() {
        enabledChangeHandler = nil
        configurationChangeHandler = nil
        permissionRequestHandler = nil
        permissionRetryHandler = nil
        inputMonitoringSettingsHandler = nil
        previewSetHandler = nil
        previewClearHandler = nil
        chordPreviewSetHandler = nil
        chordPreviewClearHandler = nil
        displaySelectionHandler = nil
        mirroredDisplaysHandler = nil
        displayLayoutBindingHandler = nil
        shortcutChangeHandler = nil
    }

    func requestInputMonitoringPermission() {
        permissionRequestHandler?()
        guard inputMonitoringState == .permissionRequired else { return }
        feedback = UserFeedback(
            severity: .warning,
            title: String(localized: "Finish Input Monitoring in System Settings"),
            detail: String(localized: "macOS did not grant the new app identity. Remove any stale KeyLight row, add this installed app again, turn it on, then return and choose Retry Monitor."),
            recoveryAction: .openInputMonitoringSettings
        )
        // This follows an explicit Allow action and avoids the previous silent
        // no-op when TCC retained a stale entry for an older preview build.
        inputMonitoringSettingsHandler?()
    }

    func retryInputMonitoring() {
        permissionRetryHandler?()
        guard inputMonitoringState == .permissionRequired ||
                inputMonitoringState == .monitorUnavailable else {
            return
        }
        feedback = UserFeedback(
            severity: .warning,
            title: String(localized: "Input Monitoring Still Needs Attention"),
            detail: String(localized: "If KeyLight is already listed, remove the stale row, add the installed app again, turn it on, and retry."),
            recoveryAction: .openInputMonitoringSettings
        )
    }

    func refreshLaunchAtLoginStatus() {
        let authoritativeValue = settings.launchAtLogin
        guard authoritativeValue != launchAtLogin else { return }
        isLoading = true
        launchAtLogin = authoritativeValue
        isLoading = false
    }

    func openInputMonitoringSettings() {
        inputMonitoringSettingsHandler?()
    }

    func selectEffect(_ style: EffectStyle) {
        effectStyle = style.supportedStyle
    }

    /// Re-resolves permission-dependent renderers without manufacturing a
    /// settings mutation or rewriting the selected effect profile.
    func refreshEffectRenderer() {
        configurationChangeHandler?()
    }

    func setPreview(_ target: GlowTarget, source: PreviewSource) {
        guard target.id == .preview(source) else { return }
        previewSetHandler?(target, source)
    }

    func clearPreview(_ source: PreviewSource) {
        previewClearHandler?(source)
    }

    func setChordPreview(_ targets: [GlowTarget]) {
        guard !targets.isEmpty,
              targets.count <= PreviewSource.chordTestSources.count,
              targets.allSatisfy({ target in
                guard case .preview(let source) = target.id else { return false }
                return source.isChordTest
              }) else {
            return
        }
        chordPreviewSetHandler?(targets)
    }

    func clearChordPreview() {
        chordPreviewClearHandler?()
    }

    func updateDisplayState(
        availableDisplays: [OverlayDisplayDescriptor],
        activeDisplayPersistentID: String?,
        activeDisplayPersistentIDs: [String]
    ) {
        self.availableDisplays = availableDisplays
        self.activeDisplayPersistentID = activeDisplayPersistentID
        self.activeDisplayPersistentIDs = activeDisplayPersistentIDs
    }

    func boundLayoutProfileID(forDisplay persistentDisplayID: String) -> UUID? {
        settings.displayLayoutProfileBindings[persistentDisplayID]
    }

    func setLayoutProfileBinding(_ profileID: UUID?, forDisplay persistentDisplayID: String) {
        settings.setLayoutProfileBinding(profileID, forDisplay: persistentDisplayID)
        displayLayoutBindingHandler?(persistentDisplayID, profileID)
    }

    func announce(_ feedback: UserFeedback) {
        let message = [feedback.title, feedback.detail]
            .compactMap { $0 }
            .joined(separator: ". ")
        feedbackAnnouncer(message)
    }

    func receivePhysicalKeyboardEvent(_ event: KeyboardEvent) {
        guard let keyCode = event.canonicalKeyCode else {
            if event.action == .streamReset {
                physicalKeyActivity = nil
            }
            return
        }
        let isDown: Bool
        switch event.action {
        case .down:
            isDown = true
        case .up:
            isDown = false
        case .streamReset:
            physicalKeyActivity = nil
            return
        }
        physicalKeySequence &+= 1
        physicalKeyActivity = PhysicalKeyActivity(
            sequence: physicalKeySequence,
            keyCode: keyCode,
            isDown: isDown
        )
    }

    func flushPendingPersist() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        persistAllSettings()
    }

    func loadSettings() {
        isLoading = true
        let preferences = settings.appPreferences
        let effect = preferences.effect
        isEnabled = preferences.isEnabled
        hasSeenPermissionExplanation = settings.hasSeenPermissionExplanation
        glowColor = Color(hex: effect.color.solidHex) ?? Color(hex: "68B8FF") ?? Color(red: 0.41, green: 0.72, blue: 1.0)
        glowOpacity = effect.opacity
        physicalRefractionStrength = effect.refractionStrength
        glowSize = effect.height
        glowWidth = effect.width
        glowRoundness = effect.roundness
        glowFullness = effect.hardness
        fadeDuration = effect.fadeDuration
        launchAtLogin = preferences.launchAtLogin
        overlayDisplaySelection = settings.overlayDisplaySelection
        mirroredDisplayIDs = settings.mirroredDisplayIDs
        globalShortcut = settings.globalShortcut
        colorMode = effect.color.mode
        effectStyle = effect.style
        chordAppearance = preferences.chordAppearance
        powerSavingMode = preferences.powerSavingMode
        surfaceShapeProfile = effect.shapeProfile
        gradientStartColor = Color(hex: effect.color.gradientStartHex) ?? Color(hex: "68B8FF") ?? .blue
        gradientEndColor = Color(hex: effect.color.gradientEndHex) ?? Color(hex: "00E69A") ?? .green
        isLoading = false
    }

    /// Reloads only after SettingsManager has completed an atomic snapshot
    /// transaction. All observable values are replaced while persistence is
    /// muted, then existing runtime boundaries receive the complete state.
    func reloadManagedConfiguration() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        loadSettings()
        reloadSavedThemes()

        configurationChangeHandler?()
        displaySelectionHandler?(overlayDisplaySelection)
        mirroredDisplaysHandler?(mirroredDisplayIDs)
        shortcutChangeHandler?(globalShortcut)
    }

    func reloadSavedThemes() {
        savedThemes = settings.savedThemes
        selectedThemeID = settings.activeThemeID
            ?? savedThemes.first(where: { $0.name == settings.currentThemeName })?.id
    }

    func markPermissionExplanationSeen() {
        guard !hasSeenPermissionExplanation else { return }
        hasSeenPermissionExplanation = true
        settings.hasSeenPermissionExplanation = true
    }

    func requestPermissionSetupIfNeeded() {
        guard settings.shouldPresentOnboarding else { return }
        permissionSetupPresentationRequested = true
    }

    func deferOnboarding() {
        settings.deferOnboarding()
        permissionSetupPresentationRequested = false
    }

    func completeOnboarding() {
        settings.completeOnboarding()
        permissionSetupPresentationRequested = false
    }

    func updateGlobalHotKeyStatus(_ status: GlobalHotKeyStatus) {
        globalHotKeyStatus = status
        guard status == .unavailable else { return }
        feedback = UserFeedback(
            severity: .warning,
            title: String(localized: "Keyboard Shortcut Unavailable"),
            detail: String(localized: "\(globalShortcut.displayName) could not be registered. Record a different shortcut or enable KeyLight from the menu.")
        )
    }

    func updateEffectRuntimeStatus(_ status: EffectRuntimeStatus) {
        effectRuntimeStatus = status
    }

    func updatePowerEnvironmentState(_ state: PowerEnvironmentState) {
        guard powerEnvironmentState != state else { return }
        powerEnvironmentState = state
        configurationChangeHandler?()
    }

    func updateInputMonitoring(
        state: InputMonitoringState,
        appPath: String,
        installationIssue: String?
    ) {
        let previousState = inputMonitoringState
        inputMonitoringState = state
        inputMonitoringAppPath = appPath
        inputMonitoringInstallationIssue = installationIssue
        guard previousState != state else { return }

        switch state {
        case .checking, .starting:
            break
        case .permissionRequired:
            feedback = UserFeedback(
                severity: .warning,
                title: String(localized: "Input Monitoring Required"),
                detail: installationIssue ?? String(localized: "Allow Input Monitoring so KeyLight can detect key presses."),
                recoveryAction: installationIssue == nil ? .openInputMonitoringSettings : nil
            )
        case .authorized:
            feedback = UserFeedback(
                severity: .information,
                title: String(localized: "Input Monitoring Allowed"),
                detail: String(localized: "Enable KeyLight to start key detection.")
            )
        case .active:
            feedback = UserFeedback(
                severity: .success,
                title: String(localized: "Input Monitoring Active"),
                detail: String(localized: "KeyLight is ready to detect key presses.")
            )
        case .monitorUnavailable:
            feedback = UserFeedback(
                severity: .error,
                title: String(localized: "Input Monitoring Unavailable"),
                detail: String(localized: "Permission is allowed, but KeyLight could not start key detection."),
                recoveryAction: .retry
            )
        }
    }

    @discardableResult
    func consumePermissionSetupPresentationRequest() -> Bool {
        guard permissionSetupPresentationRequested else { return false }
        permissionSetupPresentationRequested = false
        return true
    }

    func applyTheme(_ theme: Theme) {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        settings.setEffectConfiguration(
            effectConfiguration(style: effectStyle),
            for: effectStyle
        )

        isLoading = true
        glowColor = Color(hex: theme.colorHex) ?? glowColor
        glowOpacity = theme.opacity
        physicalRefractionStrength = theme.refractionStrength
        glowSize = theme.size
        glowWidth = theme.width
        glowRoundness = theme.glowRoundness
        glowFullness = theme.glowFullness
        fadeDuration = theme.fadeDuration
        colorMode = theme.colorMode
        effectStyle = theme.effectStyle.supportedStyle
        surfaceShapeProfile = theme.shapeProfile
        gradientStartColor = Color(hex: theme.gradientStartHex ?? "68B8FF") ?? gradientStartColor
        gradientEndColor = Color(hex: theme.gradientEndHex ?? "00E69A") ?? gradientEndColor
        isLoading = false

        persistWorkItem?.cancel()
        persistAllSettings()
        settings.activeThemeID = theme.id
        reloadSavedThemes()
        configurationChangeHandler?()
    }

    func currentTheme() -> Theme {
        Theme(
            name: settings.currentThemeName,
            colorHex: glowColor.toHex() ?? "68B8FF",
            opacity: glowOpacity,
            refractionStrength: physicalRefractionStrength,
            size: glowSize,
            width: glowWidth,
            glowRoundness: glowRoundness,
            glowFullness: glowFullness,
            fadeDuration: fadeDuration,
            colorMode: colorMode,
            effectStyle: effectStyle,
            shapeProfile: surfaceShapeProfile,
            gradientStartHex: gradientStartColor.toHex() ?? "68B8FF",
            gradientEndHex: gradientEndColor.toHex() ?? "00E69A"
        )
    }

    private func debouncedPersist() {
        persistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistAllSettings()
        }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + persistDebounceInterval, execute: workItem)
    }

    private func persistAllSettings() {
        settings.effectConfiguration = currentEffectConfiguration
    }

    private func switchEffectProfile(
        from previousStyle: EffectStyle,
        to requestedStyle: EffectStyle
    ) {
        persistWorkItem?.cancel()
        persistWorkItem = nil

        settings.setEffectConfiguration(
            effectConfiguration(style: previousStyle),
            for: previousStyle
        )

        let destination = settings.effectConfiguration(
            for: requestedStyle
        )
        isLoading = true
        applyEffectConfigurationValues(destination)
        effectStyle = destination.style.supportedStyle
        isLoading = false

        settings.effectConfiguration = destination
        configurationChangeHandler?()
    }

    private func applyEffectConfigurationValues(
        _ configuration: EffectConfiguration
    ) {
        glowColor = Color(hex: configuration.color.solidHex) ?? glowColor
        glowOpacity = configuration.opacity
        physicalRefractionStrength = configuration.refractionStrength
        glowSize = configuration.height
        glowWidth = configuration.width
        glowRoundness = configuration.roundness
        glowFullness = configuration.hardness
        fadeDuration = configuration.fadeDuration
        colorMode = configuration.color.mode
        surfaceShapeProfile = configuration.shapeProfile
        gradientStartColor = Color(
            hex: configuration.color.gradientStartHex
        ) ?? gradientStartColor
        gradientEndColor = Color(
            hex: configuration.color.gradientEndHex
        ) ?? gradientEndColor
    }

    private func launchAtLoginFeedback(for result: LaunchAtLoginChangeResult) -> UserFeedback {
        switch result.outcome {
        case .requiresApproval:
            return UserFeedback(
                severity: .warning,
                title: String(localized: "Launch at Login Needs Approval"),
                detail: String(localized: "Allow KeyLight in System Settings › General › Login Items, then try again.")
            )
        case .rejected:
            return UserFeedback(
                severity: .warning,
                title: String(localized: "Launch at Login Wasn’t Changed"),
                detail: String(localized: "macOS kept the previous launch-at-login setting.")
            )
        case .failed(let failure):
            return UserFeedback(
                severity: .error,
                title: String(localized: "Launch at Login Failed"),
                detail: failure == .registrationFailed
                    ? String(localized: "KeyLight could not enable launch at login. The previous setting was restored.")
                    : String(localized: "KeyLight could not disable launch at login. The previous setting was restored.")
            )
        case .applied:
            return UserFeedback(
                severity: .warning,
                title: String(localized: "Launch at Login Wasn’t Changed"),
                detail: String(localized: "macOS reported a different launch-at-login state, so KeyLight restored the current system value.")
            )
        }
    }

    private static func effectConfiguration(for theme: Theme) -> EffectConfiguration {
        EffectConfiguration(
            style: theme.effectStyle,
            shapeProfile: theme.shapeProfile,
            color: ColorConfiguration(
                mode: theme.colorMode,
                solidHex: normalizedHex(theme.colorHex, fallback: "68B8FF"),
                gradientStartHex: normalizedHex(theme.gradientStartHex, fallback: "68B8FF"),
                gradientEndHex: normalizedHex(theme.gradientEndHex, fallback: "00E69A")
            ),
            opacity: theme.opacity,
            refractionStrength: theme.refractionStrength,
            height: theme.size,
            width: theme.width,
            roundness: theme.glowRoundness,
            hardness: theme.glowFullness,
            fadeDuration: theme.fadeDuration
        )
    }

    private static func normalizedHex(_ value: String?, fallback: String) -> String {
        (value ?? fallback).uppercased()
    }

    private static func announceFeedback(_ message: String) {
        guard !message.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }

    func toHex() -> String? {
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components else {
            return nil
        }

        let r = components.count > 0 ? components[0] : 0
        let g = components.count > 1 ? components[1] : 0
        let b = components.count > 2 ? components[2] : 0

        func byte(_ component: CGFloat) -> Int {
            guard component.isFinite else { return 0 }
            return Int((min(max(component, 0), 1) * 255).rounded())
        }

        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
