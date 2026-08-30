import AppKit
import Carbon.HIToolbox
import XCTest
@testable import KeyLight

final class AppCoordinatorTests: XCTestCase {
    @MainActor
    func testStartAndShutdownAreIdempotent() {
        let harness = CoordinatorHarness()

        harness.coordinator.start()
        harness.coordinator.start()

        XCTAssertEqual(harness.input.startValues, [true])
        XCTAssertEqual(harness.overlay.startCount, 1)
        XCTAssertEqual(harness.overlay.enabledValues, [true])
        XCTAssertEqual(harness.overlay.appliedConfigurations.count, 1)
        XCTAssertEqual(harness.hotKey.startCount, 1)
        XCTAssertEqual(harness.hotKey.shortcutValues, [.default])
        XCTAssertEqual(harness.accessibility.readCount, 1)

        harness.coordinator.shutdown()
        harness.coordinator.shutdown()

        XCTAssertEqual(harness.input.stopCount, 1)
        XCTAssertEqual(harness.overlay.shutdownCount, 1)
        XCTAssertEqual(harness.hotKey.stopCount, 1)
    }

    @MainActor
    func testModelActionsReachInjectedServicesAndInputStatusUpdatesModel() {
        let harness = CoordinatorHarness(accessibilityOptions: AccessibilityDisplayOptions(
            reduceMotion: true,
            reduceTransparency: false,
            increaseContrast: true
        ))
        harness.coordinator.start()
        let initialApplyCount = harness.overlay.appliedConfigurations.count

        harness.model.isEnabled = false

        XCTAssertEqual(harness.overlay.enabledValues.last, false)
        XCTAssertEqual(harness.input.enabledValues.last, false)
        XCTAssertEqual(harness.overlay.appliedConfigurations.count, initialApplyCount + 1)

        harness.model.glowOpacity = 0.42
        harness.model.physicalRefractionStrength = 2.1

        let latestConfiguration = harness.overlay.appliedConfigurations.last?.configuration
        XCTAssertEqual(
            latestConfiguration?.maximumOpacity ?? -1,
            Float(0.42),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            latestConfiguration?.refractionStrength ?? -1,
            CGFloat(2.1),
            accuracy: 0.0001
        )
        XCTAssertEqual(latestConfiguration?.reduceMotion, true)
        XCTAssertEqual(latestConfiguration?.reduceTransparency, false)
        XCTAssertEqual(latestConfiguration?.increaseContrast, true)

        harness.model.requestInputMonitoringPermission()
        harness.model.retryInputMonitoring()
        harness.model.openInputMonitoringSettings()

        XCTAssertEqual(harness.input.permissionRequestCount, 1)
        XCTAssertEqual(harness.input.retryCount, 1)
        XCTAssertEqual(harness.input.openSettingsCount, 1)

        let customShortcut = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(controlKey | optionKey)
        )!
        harness.model.globalShortcut = customShortcut
        XCTAssertEqual(harness.hotKey.shortcutValues.last, customShortcut)

        harness.model.mirroredDisplayIDs = ["studio-display"]
        XCTAssertEqual(
            harness.overlay.mirroredDisplayValues.last,
            Set(["studio-display"])
        )

        harness.input.emitStatus(InputControllerStatus(
            state: .monitorUnavailable,
            runningApplicationPath: "/Applications/KeyLight.app",
            installationIssue: "Install the signed app",
            lastKnownAuthorization: true,
            monitorRunning: false,
            recheckInterval: 5
        ))

        XCTAssertEqual(harness.model.inputMonitoringState, .monitorUnavailable)
        XCTAssertEqual(harness.model.inputMonitoringAppPath, "/Applications/KeyLight.app")
        XCTAssertEqual(harness.model.inputMonitoringInstallationIssue, "Install the signed app")
    }

    @MainActor
    func testKeyboardTargetsResolveThroughInjectedLiveLayoutStore() {
        let harness = CoordinatorHarness()
        let keyCode: UInt16 = 0
        let base = KeyMapping.keyInfo(for: keyCode)
        harness.layoutStore.setOffset(0.1, for: keyCode)
        harness.layoutStore.setWidthMultiplier(1.5, for: keyCode)
        harness.coordinator.start()

        harness.input.emitKeyboardEvent(.keyDown(
            keyCode,
            source: .eventTap,
            timestamp: 1
        ))

        let target = harness.overlay.events.last?.target
        XCTAssertEqual(target?.id, .physicalKey(keyCode))
        XCTAssertEqual(
            target?.horizontalPosition ?? -1,
            Double(min(max(base.position + 0.1, 0), 1)),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            target?.keyWidth ?? -1,
            Double(base.width * 1.5),
            accuracy: 0.0001
        )
    }

    @MainActor
    func testPlatformObserversAreRemovedAndStaleCallbacksAreHarmlessAfterShutdown() {
        let harness = CoordinatorHarness()
        harness.coordinator.start()

        harness.notificationCenter.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        harness.notificationCenter.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        harness.model.setPreview(
            .preview(
                .settings,
                horizontalPosition: 0.4,
                keyWidth: 1.2
            ),
            source: .settings
        )
        harness.model.clearPreview(.settings)
        let chord = [GlowTarget.preview(
            .chordTest1,
            colorReferenceKeyCode: 0,
            horizontalPosition: 0.3,
            keyWidth: 1
        )]
        harness.model.setChordPreview(chord)
        harness.model.clearChordPreview()
        harness.workspaceNotificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        harness.workspaceNotificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        harness.workspaceNotificationCenter.post(
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        harness.workspaceNotificationCenter.post(
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        harness.accessibility.options = AccessibilityDisplayOptions(
            reduceMotion: true,
            reduceTransparency: true,
            increaseContrast: false
        )
        harness.workspaceNotificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        XCTAssertEqual(harness.overlay.topologyUpdateCount, 3)
        XCTAssertEqual(harness.input.activationCount, 1)
        XCTAssertEqual(harness.input.sleepCount, 2)
        XCTAssertEqual(harness.input.wakeCount, 2)
        XCTAssertEqual(
            Array(harness.overlay.enabledValues.suffix(4)),
            [false, true, false, true],
            "Sleep must stop renderer-owned capture immediately and wake restores the saved enabled intent"
        )
        XCTAssertEqual(harness.overlay.previews.map(\.source), [.settings])
        XCTAssertEqual(harness.overlay.clearedPreviews, [.settings])
        XCTAssertEqual(harness.overlay.chordPreviews, [chord])
        XCTAssertEqual(harness.overlay.chordPreviewClearCount, 1)
        XCTAssertEqual(harness.accessibility.readCount, 2)
        XCTAssertEqual(
            harness.overlay.appliedConfigurations.last?.configuration.reduceTransparency,
            true
        )

        harness.coordinator.shutdown()

        let serviceSnapshot = harness.snapshot
        let enabledBeforeStaleCallbacks = harness.model.isEnabled
        let hotKeyStatusBeforeStaleCallbacks = harness.model.globalHotKeyStatus
        let inputStateBeforeStaleCallbacks = harness.model.inputMonitoringState
        let physicalActivityBeforeStaleCallbacks = harness.model.physicalKeyActivity

        harness.notificationCenter.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        harness.notificationCenter.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        harness.workspaceNotificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        harness.workspaceNotificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        harness.workspaceNotificationCenter.post(
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        harness.workspaceNotificationCenter.post(
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        harness.workspaceNotificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        harness.input.emitKeyboardEvent(.keyDown(
            0,
            source: .eventTap,
            timestamp: 1
        ))
        harness.input.emitStatus(InputControllerStatus(
            state: .active,
            runningApplicationPath: "/stale",
            installationIssue: nil,
            lastKnownAuthorization: true,
            monitorRunning: true,
            recheckInterval: 300
        ))
        harness.hotKey.emitStatus(.registered)
        harness.hotKey.press()
        harness.overlay.emitPhysicalEvent(.keyDown(
            1,
            source: .eventTap,
            timestamp: 2
        ))

        harness.model.isEnabled.toggle()
        harness.model.glowOpacity = 0.33
        harness.model.requestInputMonitoringPermission()
        harness.model.retryInputMonitoring()
        harness.model.openInputMonitoringSettings()
        harness.model.setPreview(
            .preview(.settings, horizontalPosition: 0.5, keyWidth: 1),
            source: .settings
        )
        harness.model.clearPreview(.settings)

        XCTAssertEqual(harness.snapshot, serviceSnapshot)
        XCTAssertNotEqual(harness.model.isEnabled, enabledBeforeStaleCallbacks)
        XCTAssertEqual(harness.model.globalHotKeyStatus, hotKeyStatusBeforeStaleCallbacks)
        XCTAssertEqual(harness.model.inputMonitoringState, inputStateBeforeStaleCallbacks)
        XCTAssertEqual(harness.model.physicalKeyActivity, physicalActivityBeforeStaleCallbacks)
    }

    @MainActor
    func testHotKeyCallbacksMapStatusAndPressToTheModel() {
        let harness = CoordinatorHarness()
        harness.coordinator.start()

        harness.hotKey.emitStatus(.registering)
        XCTAssertEqual(harness.model.globalHotKeyStatus, .checking)

        harness.hotKey.emitStatus(.registered)
        XCTAssertEqual(harness.model.globalHotKeyStatus, .registered)

        harness.hotKey.emitStatus(.unavailable(.hotKeyRegistrationFailed(status: -9876)))
        XCTAssertEqual(harness.model.globalHotKeyStatus, .unavailable)
        XCTAssertEqual(harness.model.feedback?.title, "Keyboard Shortcut Unavailable")

        let enabledBeforePress = harness.model.isEnabled
        harness.hotKey.press()
        XCTAssertEqual(harness.model.isEnabled, !enabledBeforePress)
        XCTAssertEqual(harness.overlay.enabledValues.last, !enabledBeforePress)
        XCTAssertEqual(harness.input.enabledValues.last, !enabledBeforePress)
    }

    @MainActor
    func testFirstRunRequestsSetupWithoutRequestingPermission() {
        let firstRun = CoordinatorHarness()

        firstRun.coordinator.start()

        XCTAssertTrue(firstRun.model.permissionSetupPresentationRequested)
        XCTAssertEqual(firstRun.input.permissionRequestCount, 0)

        let returningUser = CoordinatorHarness(hasSeenPermissionExplanation: true)
        returningUser.coordinator.start()

        XCTAssertFalse(returningUser.model.permissionSetupPresentationRequested)
        XCTAssertEqual(returningUser.input.permissionRequestCount, 0)

        let existingWithoutPriorPermissionExplanation = CoordinatorHarness(
            hasSeenPermissionExplanation: false
        )
        existingWithoutPriorPermissionExplanation.coordinator.start()

        XCTAssertFalse(
            existingWithoutPriorPermissionExplanation.model.permissionSetupPresentationRequested
        )
        XCTAssertEqual(
            existingWithoutPriorPermissionExplanation.input.permissionRequestCount,
            0
        )
    }

    @MainActor
    func testAutomaticPowerSavingTracksLowPowerAndEveryThermalState() {
        let harness = CoordinatorHarness(powerEnvironmentState: .normal)
        harness.coordinator.start()
        harness.model.effectStyle = .physicalRefraction

        let cases: [(PowerThermalState, Bool)] = [
            (.nominal, false),
            (.fair, false),
            (.serious, true),
            (.critical, true)
        ]
        for (thermalState, expectedActive) in cases {
            harness.powerEnvironment.state = PowerEnvironmentState(
                isLowPowerModeEnabled: false,
                thermalState: thermalState
            )
            harness.notificationCenter.post(
                name: ProcessInfo.thermalStateDidChangeNotification,
                object: nil
            )
            let latest = harness.overlay.appliedConfigurations.last
            XCTAssertEqual(
                latest?.configuration.automaticPowerSavingIsActive,
                expectedActive,
                "Unexpected policy for \(thermalState)"
            )
            XCTAssertEqual(latest?.effectStyle, .physicalRefraction)
            XCTAssertEqual(harness.model.effectStyle, .physicalRefraction)
        }

        harness.powerEnvironment.state = PowerEnvironmentState(
            isLowPowerModeEnabled: true,
            thermalState: .nominal
        )
        harness.notificationCenter.post(
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        XCTAssertTrue(try! XCTUnwrap(
            harness.overlay.appliedConfigurations.last
        ).configuration.automaticPowerSavingIsActive)
        XCTAssertEqual(harness.model.effectStyle, .physicalRefraction)
    }

    @MainActor
    func testPowerSavingRestoresOnceAndOffModeSuppressesFallback() {
        let harness = CoordinatorHarness(powerEnvironmentState: PowerEnvironmentState(
            isLowPowerModeEnabled: false,
            thermalState: .serious
        ))
        harness.coordinator.start()
        harness.model.effectStyle = .physicalRefraction
        XCTAssertTrue(try! XCTUnwrap(
            harness.overlay.appliedConfigurations.last
        ).configuration.automaticPowerSavingIsActive)

        harness.powerEnvironment.state = .normal
        let beforeRestore = harness.overlay.appliedConfigurations.count
        harness.notificationCenter.post(
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        XCTAssertEqual(
            harness.overlay.appliedConfigurations.count,
            beforeRestore + 1
        )
        XCTAssertFalse(try! XCTUnwrap(
            harness.overlay.appliedConfigurations.last
        ).configuration.automaticPowerSavingIsActive)

        harness.notificationCenter.post(
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        XCTAssertEqual(
            harness.overlay.appliedConfigurations.count,
            beforeRestore + 1,
            "An unchanged power state must not restore the renderer twice"
        )

        harness.powerEnvironment.state = PowerEnvironmentState(
            isLowPowerModeEnabled: true,
            thermalState: .critical
        )
        harness.notificationCenter.post(
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        harness.model.powerSavingMode = .off
        let latest = try! XCTUnwrap(harness.overlay.appliedConfigurations.last)
        XCTAssertFalse(latest.configuration.automaticPowerSavingIsActive)
        XCTAssertEqual(harness.model.effectStyle, .physicalRefraction)
    }
}

@MainActor
private final class CoordinatorHarness {
    struct ServiceSnapshot: Equatable {
        let inputActivationCount: Int
        let inputSleepCount: Int
        let inputWakeCount: Int
        let inputPermissionRequestCount: Int
        let inputRetryCount: Int
        let inputOpenSettingsCount: Int
        let inputEnabledValues: [Bool]
        let overlayTopologyUpdateCount: Int
        let overlayPreviewCount: Int
        let overlayClearPreviewCount: Int
        let overlayEventCount: Int
        let overlayEnabledValues: [Bool]
        let overlayApplyCount: Int
        let accessibilityReadCount: Int
    }

    let model: KeyLightModel
    let coordinator: AppCoordinator
    let input: CoordinatorInputSpy
    let overlay: CoordinatorOverlaySpy
    let hotKey: CoordinatorHotKeySpy
    let accessibility: AccessibilityOptionsBox
    let powerEnvironment: PowerEnvironmentBox
    let layoutStore: KeyLayoutStore
    let notificationCenter: NotificationCenter
    let workspaceNotificationCenter: NotificationCenter
    private let isolatedDefaults: CoordinatorIsolatedDefaults

    var snapshot: ServiceSnapshot {
        ServiceSnapshot(
            inputActivationCount: input.activationCount,
            inputSleepCount: input.sleepCount,
            inputWakeCount: input.wakeCount,
            inputPermissionRequestCount: input.permissionRequestCount,
            inputRetryCount: input.retryCount,
            inputOpenSettingsCount: input.openSettingsCount,
            inputEnabledValues: input.enabledValues,
            overlayTopologyUpdateCount: overlay.topologyUpdateCount,
            overlayPreviewCount: overlay.previews.count,
            overlayClearPreviewCount: overlay.clearedPreviews.count,
            overlayEventCount: overlay.events.count,
            overlayEnabledValues: overlay.enabledValues,
            overlayApplyCount: overlay.appliedConfigurations.count,
            accessibilityReadCount: accessibility.readCount
        )
    }

    init(
        hasSeenPermissionExplanation: Bool? = nil,
        accessibilityOptions: AccessibilityDisplayOptions = AccessibilityDisplayOptions(
            reduceMotion: false,
            reduceTransparency: false,
            increaseContrast: false
        ),
        powerEnvironmentState: PowerEnvironmentState = .normal
    ) {
        let defaults = CoordinatorIsolatedDefaults()
        if let hasSeenPermissionExplanation {
            defaults.defaults.set(
                hasSeenPermissionExplanation,
                forKey: "hasSeenPermissionExplanation"
            )
        }
        let settings = SettingsManager(
            preferencesStore: PreferencesStore(userDefaults: defaults.defaults)
        )
        let model = KeyLightModel(settings: settings, feedbackAnnouncer: { _ in })
        let input = CoordinatorInputSpy()
        let overlay = CoordinatorOverlaySpy()
        let hotKey = CoordinatorHotKeySpy()
        let accessibility = AccessibilityOptionsBox(options: accessibilityOptions)
        let powerEnvironment = PowerEnvironmentBox(state: powerEnvironmentState)
        let notificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let keyLayoutStore = KeyLayoutStore(
            defaults: defaults.defaults,
            debounceInterval: 0
        )

        self.model = model
        self.input = input
        self.overlay = overlay
        self.hotKey = hotKey
        self.accessibility = accessibility
        self.powerEnvironment = powerEnvironment
        self.layoutStore = keyLayoutStore
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        isolatedDefaults = defaults
        coordinator = AppCoordinator(
            model: model,
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            keyLayoutStore: keyLayoutStore,
            inputControllerFactory: { onEvent, onStatus in
                input.install(onKeyboardEvent: onEvent, onStatusChange: onStatus)
                return input
            },
            overlayControllerFactory: { onPhysicalEvent in
                overlay.install(onPhysicalEvent: onPhysicalEvent)
                return overlay
            },
            hotKeyServiceFactory: { onPress, onStatus in
                hotKey.install(onPress: onPress, onStatusChange: onStatus)
                return hotKey
            },
            accessibilityOptionsProvider: {
                accessibility.read()
            },
            powerEnvironmentProvider: {
                powerEnvironment.read()
            }
        )
    }
}

@MainActor
private final class CoordinatorInputSpy: AppCoordinatorInputControlling {
    private var onKeyboardEvent: (@MainActor (KeyboardEvent) -> Void)?
    private var onStatusChange: (@MainActor (InputControllerStatus) -> Void)?

    private(set) var startValues: [Bool] = []
    private(set) var stopCount = 0
    private(set) var enabledValues: [Bool] = []
    private(set) var activationCount = 0
    private(set) var sleepCount = 0
    private(set) var wakeCount = 0
    private(set) var permissionRequestCount = 0
    private(set) var retryCount = 0
    private(set) var openSettingsCount = 0

    func install(
        onKeyboardEvent: @escaping @MainActor (KeyboardEvent) -> Void,
        onStatusChange: @escaping @MainActor (InputControllerStatus) -> Void
    ) {
        self.onKeyboardEvent = onKeyboardEvent
        self.onStatusChange = onStatusChange
    }

    func start(isEnabled: Bool) {
        startValues.append(isEnabled)
    }

    func stop() {
        stopCount += 1
    }

    func setEnabled(_ enabled: Bool) {
        enabledValues.append(enabled)
    }

    func applicationDidBecomeActive() {
        activationCount += 1
    }

    func handleSleep() {
        sleepCount += 1
    }

    func handleWake() {
        wakeCount += 1
    }

    func requestPermission() {
        permissionRequestCount += 1
    }

    func retry() {
        retryCount += 1
    }

    func openInputMonitoringSettings() {
        openSettingsCount += 1
    }

    func emitKeyboardEvent(_ event: KeyboardEvent) {
        onKeyboardEvent?(event)
    }

    func emitStatus(_ status: InputControllerStatus) {
        onStatusChange?(status)
    }
}

@MainActor
private final class CoordinatorOverlaySpy: AppCoordinatorOverlayControlling {
    struct AppliedConfiguration {
        let effectStyle: EffectStyle
        let configuration: RendererConfiguration
    }

    struct PreviewCall {
        let target: GlowTarget
        let source: PreviewSource
    }

    private var onPhysicalEvent: (@MainActor (KeyboardEvent) -> Void)?

    private(set) var startCount = 0
    private(set) var shutdownCount = 0
    private(set) var enabledValues: [Bool] = []
    private(set) var appliedConfigurations: [AppliedConfiguration] = []
    private(set) var events: [(event: KeyboardEvent, target: GlowTarget?)] = []
    private(set) var topologyUpdateCount = 0
    private(set) var previews: [PreviewCall] = []
    private(set) var clearedPreviews: [PreviewSource] = []
    private(set) var chordPreviews: [[GlowTarget]] = []
    private(set) var chordPreviewClearCount = 0
    private(set) var mirroredDisplayValues: [Set<String>] = []

    func install(onPhysicalEvent: @escaping @MainActor (KeyboardEvent) -> Void) {
        self.onPhysicalEvent = onPhysicalEvent
    }

    func start() {
        startCount += 1
    }

    func shutdown() {
        shutdownCount += 1
    }

    func setEnabled(_ enabled: Bool) {
        enabledValues.append(enabled)
    }

    func apply(effectStyle: EffectStyle, configuration: RendererConfiguration) {
        appliedConfigurations.append(AppliedConfiguration(
            effectStyle: effectStyle,
            configuration: configuration
        ))
    }

    func handle(_ event: KeyboardEvent, target: GlowTarget?) {
        events.append((event, target))
    }

    func updateDisplayTopology() {
        topologyUpdateCount += 1
    }

    func setPreview(_ target: GlowTarget, source: PreviewSource) {
        previews.append(PreviewCall(target: target, source: source))
    }

    func clearPreview(_ source: PreviewSource) {
        clearedPreviews.append(source)
    }

    func setChordPreview(_ targets: [GlowTarget]) {
        chordPreviews.append(targets)
    }

    func clearChordPreview() {
        chordPreviewClearCount += 1
    }

    func setMirroredDisplayIDs(_ persistentIDs: Set<String>) {
        mirroredDisplayValues.append(persistentIDs)
    }

    func emitPhysicalEvent(_ event: KeyboardEvent) {
        onPhysicalEvent?(event)
    }
}

@MainActor
private final class CoordinatorHotKeySpy: AppCoordinatorHotKeyServicing {
    private var onPress: (@MainActor @Sendable () -> Void)?
    private var onStatusChange: (@MainActor @Sendable (HotKeyServiceStatus) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var statusEmissionCount = 0
    private(set) var shortcutValues: [GlobalShortcut] = []
    private(set) var pressCount = 0

    func install(
        onPress: @escaping @MainActor @Sendable () -> Void,
        onStatusChange: @escaping @MainActor @Sendable (HotKeyServiceStatus) -> Void
    ) {
        self.onPress = onPress
        self.onStatusChange = onStatusChange
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func setShortcut(_ shortcut: GlobalShortcut) {
        shortcutValues.append(shortcut)
    }

    func emitStatus(_ status: HotKeyServiceStatus) {
        statusEmissionCount += 1
        onStatusChange?(status)
    }

    func press() {
        pressCount += 1
        onPress?()
    }
}

@MainActor
private final class AccessibilityOptionsBox {
    var options: AccessibilityDisplayOptions
    private(set) var readCount = 0

    init(options: AccessibilityDisplayOptions) {
        self.options = options
    }

    func read() -> AccessibilityDisplayOptions {
        readCount += 1
        return options
    }
}

@MainActor
private final class PowerEnvironmentBox {
    var state: PowerEnvironmentState
    private(set) var readCount = 0

    init(state: PowerEnvironmentState) {
        self.state = state
    }

    func read() -> PowerEnvironmentState {
        readCount += 1
        return state
    }
}

private final class CoordinatorIsolatedDefaults {
    let suiteName = "KeyLight.AppCoordinatorTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated defaults suite")
        }
        self.defaults = defaults
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "fadeDurationDefaultMigratedV2")
        defaults.set(1, forKey: "defaultExperienceSeedVersion")
        defaults.set(1, forKey: "defaultLayoutMigrationVersion")
        defaults.set(1, forKey: "bundledLayoutProfilesSeedVersion")
        defaults.set(1, forKey: "stableSelectionMigrationVersion")
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
