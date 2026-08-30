import AppKit

struct AccessibilityDisplayOptions: Equatable, Sendable {
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increaseContrast: Bool
}

@MainActor
protocol AppCoordinatorInputControlling: AnyObject {
    func start(isEnabled: Bool)
    func stop()
    func setEnabled(_ enabled: Bool)
    func applicationDidBecomeActive()
    func handleSleep()
    func handleWake()
    func requestPermission()
    func retry()
    func openInputMonitoringSettings()
}

extension InputController: AppCoordinatorInputControlling {
    func start(isEnabled: Bool) {
        start(isEnabled: isEnabled, allowPermissionRequest: false)
    }

    func setEnabled(_ enabled: Bool) {
        setEnabled(enabled, allowPermissionRequest: false)
    }
}

@MainActor
protocol AppCoordinatorOverlayControlling: AnyObject {
    var availableDisplays: [OverlayDisplayDescriptor] { get }
    var activeDisplayPersistentID: String? { get }
    var activeDisplayPersistentIDs: [String] { get }

    func start()
    func shutdown()
    func setEnabled(_ enabled: Bool)
    func apply(effectStyle: EffectStyle, configuration: RendererConfiguration)
    func handle(_ event: KeyboardEvent, target: GlowTarget?)
    func updateDisplayTopology()
    func setDisplaySelection(_ selection: OverlayDisplaySelection)
    func setMirroredDisplayIDs(_ persistentIDs: Set<String>)
    func setPreview(_ target: GlowTarget, source: PreviewSource)
    func clearPreview(_ source: PreviewSource)
    func setChordPreview(_ targets: [GlowTarget])
    func clearChordPreview()
    func setRuntimeStatusHandler(
        _ handler: (@MainActor (EffectRuntimeStatus) -> Void)?
    )
}

extension AppCoordinatorOverlayControlling {
    var availableDisplays: [OverlayDisplayDescriptor] { [] }
    var activeDisplayPersistentID: String? { nil }
    var activeDisplayPersistentIDs: [String] { [] }

    func setDisplaySelection(_ selection: OverlayDisplaySelection) {}
    func setMirroredDisplayIDs(_ persistentIDs: Set<String>) {}
    func setChordPreview(_ targets: [GlowTarget]) {}
    func clearChordPreview() {}

    func setRuntimeStatusHandler(
        _ handler: (@MainActor (EffectRuntimeStatus) -> Void)?
    ) {}
}

extension OverlayController: AppCoordinatorOverlayControlling {
    func updateDisplayTopology() {
        updateDisplayTopology(forceRecreation: false)
    }
}

@MainActor
protocol AppCoordinatorHotKeyServicing: AnyObject {
    func start()
    func stop()
    func setShortcut(_ shortcut: GlobalShortcut)
}

extension HotKeyService: AppCoordinatorHotKeyServicing {}

extension AppCoordinatorHotKeyServicing {
    func setShortcut(_ shortcut: GlobalShortcut) {}
}

/// Owns KeyLight's runtime services and translates user-facing model changes
/// into atomic controller operations. AppKit lifecycle remains at the narrow
/// AppDelegate boundary; platform notifications are reconciled here.
@MainActor
final class AppCoordinator {
    typealias InputControllerFactory = @MainActor (
        _ onKeyboardEvent: @escaping @MainActor (KeyboardEvent) -> Void,
        _ onStatusChange: @escaping @MainActor (InputControllerStatus) -> Void
    ) -> any AppCoordinatorInputControlling

    typealias OverlayControllerFactory = @MainActor (
        _ onPhysicalEvent: @escaping @MainActor (KeyboardEvent) -> Void
    ) -> any AppCoordinatorOverlayControlling

    typealias HotKeyServiceFactory = @MainActor (
        _ onPress: @escaping @MainActor @Sendable () -> Void,
        _ onStatusChange: @escaping @MainActor @Sendable (HotKeyServiceStatus) -> Void
    ) -> any AppCoordinatorHotKeyServicing

    typealias AccessibilityOptionsProvider = @MainActor () -> AccessibilityDisplayOptions
    typealias PowerEnvironmentProvider = @MainActor () -> PowerEnvironmentState

    let model: KeyLightModel

    private let defaultGlowBaseWidth: CGFloat = 60
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let keyLayoutStore: KeyLayoutStore
    private let inputControllerFactory: InputControllerFactory
    private let overlayControllerFactory: OverlayControllerFactory
    private let hotKeyServiceFactory: HotKeyServiceFactory
    private let accessibilityOptionsProvider: AccessibilityOptionsProvider
    private let powerEnvironmentProvider: PowerEnvironmentProvider

    private lazy var overlayController = overlayControllerFactory(
        { [weak self] event in
            self?.receivePhysicalEventFromOverlay(event)
        }
    )

    private lazy var inputController = inputControllerFactory(
        { [weak self] event in
            self?.handleKeyboardEvent(event)
        },
        { [weak self] status in
            self?.applyInputStatus(status)
        }
    )

    private lazy var hotKeyService = hotKeyServiceFactory(
        { [weak self] in
            guard let self, self.isStarted else { return }
            self.model.isEnabled.toggle()
        },
        { [weak self] status in
            self?.applyHotKeyStatus(status)
        }
    )

    private struct ObserverToken {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }

    private var observerTokens: [ObserverToken] = []
    private var isStarted = false
    private var reduceMotionEnabled = false
    private var reduceTransparencyEnabled = false
    private var increaseContrastEnabled = false
    private var deferredDisplayLayoutBinding: (displayID: String, profileID: UUID)?

    init(
        model: KeyLightModel,
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        keyLayoutStore: KeyLayoutStore,
        inputControllerFactory: @escaping InputControllerFactory = { onEvent, onStatus in
            InputController(
                onKeyboardEvent: onEvent,
                onStatusChange: onStatus
            )
        },
        overlayControllerFactory: @escaping OverlayControllerFactory = { onPhysicalEvent in
            OverlayController(onPhysicalEvent: onPhysicalEvent)
        },
        hotKeyServiceFactory: @escaping HotKeyServiceFactory = { onPress, onStatus in
            HotKeyService(
                onPress: onPress,
                onStatusChange: onStatus
            )
        },
        accessibilityOptionsProvider: @escaping AccessibilityOptionsProvider = {
            AccessibilityDisplayOptions(
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            )
        },
        powerEnvironmentProvider: @escaping PowerEnvironmentProvider = {
            PowerEnvironmentState.current()
        }
    ) {
        self.model = model
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.keyLayoutStore = keyLayoutStore
        self.inputControllerFactory = inputControllerFactory
        self.overlayControllerFactory = overlayControllerFactory
        self.hotKeyServiceFactory = hotKeyServiceFactory
        self.accessibilityOptionsProvider = accessibilityOptionsProvider
        self.powerEnvironmentProvider = powerEnvironmentProvider
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        KeyLightLogger.app.notice("Application startup began")

        #if DEBUG
        KeyMapping.assertParityContracts()
        #endif

        // Seed the transient state before connecting the runtime so startup
        // applies one complete renderer configuration rather than briefly
        // starting capture and immediately falling back.
        model.updatePowerEnvironmentState(powerEnvironmentProvider())

        model.connectRuntime(
            onEnabledChange: { [weak self] enabled in
                self?.setEnabled(enabled)
            },
            onConfigurationChange: { [weak self] in
                self?.applyRendererConfiguration()
            },
            onPermissionRequest: { [weak self] in
                self?.inputController.requestPermission()
            },
            onPermissionRetry: { [weak self] in
                self?.inputController.retry()
            },
            onOpenInputMonitoringSettings: { [weak self] in
                self?.inputController.openInputMonitoringSettings()
            },
            onPreviewSet: { [weak self] target, source in
                guard let self, self.isStarted else { return }
                self.overlayController.setPreview(target, source: source)
            },
            onPreviewClear: { [weak self] source in
                guard let self, self.isStarted else { return }
                self.overlayController.clearPreview(source)
            },
            onChordPreviewSet: { [weak self] targets in
                guard let self, self.isStarted else { return }
                self.overlayController.setChordPreview(targets)
            },
            onChordPreviewClear: { [weak self] in
                guard let self, self.isStarted else { return }
                self.overlayController.clearChordPreview()
            },
            onDisplaySelectionChange: { [weak self] selection in
                guard let self, self.isStarted else { return }
                self.overlayController.setDisplaySelection(selection)
                self.synchronizeDisplayStateAndLayout()
            },
            onMirroredDisplaysChange: { [weak self] persistentIDs in
                guard let self, self.isStarted else { return }
                self.overlayController.setMirroredDisplayIDs(persistentIDs)
                self.synchronizeDisplayStateAndLayout()
            },
            onDisplayLayoutBindingChange: { [weak self] displayID, profileID in
                guard let self, self.isStarted,
                      displayID == self.overlayController.activeDisplayPersistentID else {
                    return
                }
                self.applyBoundLayout(profileID, forDisplay: displayID)
            },
            onShortcutChange: { [weak self] shortcut in
                guard let self, self.isStarted else { return }
                self.hotKeyService.setShortcut(shortcut)
            }
        )

        installPlatformObservers()
        overlayController.setRuntimeStatusHandler { [weak self] status in
            self?.model.updateEffectRuntimeStatus(status)
        }
        overlayController.setDisplaySelection(model.overlayDisplaySelection)
        overlayController.setMirroredDisplayIDs(model.mirroredDisplayIDs)
        overlayController.start()
        synchronizeDisplayStateAndLayout()
        overlayController.setEnabled(model.isEnabled)
        updateAccessibilityDisplayOptions()
        hotKeyService.setShortcut(model.globalShortcut)
        hotKeyService.start()

        // Permission prompts are reserved for the model's explicit user action.
        inputController.start(isEnabled: model.isEnabled)
        model.requestPermissionSetupIfNeeded()

        KeyLightLogger.app.notice("Application startup completed")
    }

    func shutdown() {
        guard isStarted else { return }
        isStarted = false

        model.disconnectRuntime()
        removePlatformObservers()
        inputController.stop()
        hotKeyService.stop()
        overlayController.shutdown()
        keyLayoutStore.flush()
        model.flushPendingPersist()
    }

    // MARK: - Model actions

    private func setEnabled(_ enabled: Bool) {
        KeyLightLogger.app.notice("Effect enabled state changed: \(enabled, privacy: .public)")
        overlayController.setEnabled(enabled)
        // Enabling the effect is never treated as permission-request consent.
        inputController.setEnabled(enabled)
    }

    private func applyRendererConfiguration() {
        let colorMode: RendererConfiguration.ColorMode
        switch model.colorMode {
        case .solid:
            colorMode = .solid(model.glowNSColor)
        case .positionGradient:
            colorMode = .positionGradient(
                start: model.gradientStartNSColor,
                end: model.gradientEndNSColor
            )
        case .rainbow:
            colorMode = .rainbow
        case .randomPerKey:
            colorMode = .randomPerKey
        }

        let configuration = RendererConfiguration(
            colorMode: colorMode,
            shapeProfile: model.surfaceShapeProfile,
            baseKeyWidth: defaultGlowBaseWidth,
            glowHeight: CGFloat(model.glowSize),
            widthMultiplier: CGFloat(model.glowWidth),
            maximumOpacity: Float(model.glowOpacity),
            refractionStrength: CGFloat(model.physicalRefractionStrength),
            fadeDuration: model.fadeDuration,
            roundness: CGFloat(model.glowRoundness),
            fullness: CGFloat(model.glowFullness),
            reduceMotion: reduceMotionEnabled,
            reduceTransparency: reduceTransparencyEnabled,
            increaseContrast: increaseContrastEnabled,
            chordAppearance: model.chordAppearance,
            powerSavingMode: model.powerSavingMode,
            powerEnvironmentState: model.powerEnvironmentState
        )

        overlayController.apply(
            effectStyle: model.effectStyle,
            configuration: configuration
        )
    }

    // MARK: - Input

    // SECURITY: This boundary receives only normalized metadata. Never log key codes.
    private func handleKeyboardEvent(_ event: KeyboardEvent) {
        guard isStarted else { return }

        let target: GlowTarget?
        if event.action == .down, let keyCode = event.canonicalKeyCode {
            let keyInfo = KeyMapping.keyInfo(for: keyCode)
            target = .physicalKey(
                keyCode,
                horizontalPosition: Double(keyLayoutStore.adjustedPosition(
                    for: keyCode,
                    originalPosition: keyInfo.position
                )),
                keyWidth: Double(keyLayoutStore.effectiveWidth(
                    for: keyCode,
                    defaultWidth: keyInfo.width
                ))
            )
        } else {
            target = nil
        }

        KeyLightSignposts.overlayStateUpdated(sequence: event.sequence)
        overlayController.handle(event, target: target)
    }

    private func applyInputStatus(_ status: InputControllerStatus) {
        guard isStarted else { return }

        let previousState = model.inputMonitoringState
        model.updateInputMonitoring(
            state: status.state,
            appPath: status.runningApplicationPath,
            installationIssue: status.installationIssue
        )

        if previousState != status.state {
            let stateDescription = String(describing: status.state)
            KeyLightLogger.permissions.notice(
                "Input Monitoring state changed to \(stateDescription, privacy: .public)"
            )
        }
    }

    private func applyHotKeyStatus(_ status: HotKeyServiceStatus) {
        guard isStarted else { return }

        switch status {
        case .stopped, .registering:
            model.updateGlobalHotKeyStatus(.checking)
        case .registered:
            model.updateGlobalHotKeyStatus(.registered)
        case .unavailable:
            model.updateGlobalHotKeyStatus(.unavailable)
        }
    }

    // MARK: - Platform lifecycle

    private func installPlatformObservers() {
        guard observerTokens.isEmpty else { return }

        let screenToken = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStarted else { return }
                self.overlayController.updateDisplayTopology()
                self.synchronizeDisplayStateAndLayout()
            }
        }
        observerTokens.append(ObserverToken(center: notificationCenter, token: screenToken))

        let activationToken = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStarted else { return }
                self.inputController.applicationDidBecomeActive()
                self.model.refreshLaunchAtLoginStatus()
            }
        }
        observerTokens.append(ObserverToken(center: notificationCenter, token: activationToken))

        let sleepToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStarted else { return }
                self.overlayController.setEnabled(false)
                self.inputController.handleSleep()
            }
        }
        observerTokens.append(ObserverToken(
            center: workspaceNotificationCenter,
            token: sleepToken
        ))

        let wakeToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStarted else { return }
                self.overlayController.updateDisplayTopology()
                self.synchronizeDisplayStateAndLayout()
                self.overlayController.setEnabled(self.model.isEnabled)
                self.inputController.handleWake()
            }
        }
        observerTokens.append(ObserverToken(
            center: workspaceNotificationCenter,
            token: wakeToken
        ))

        let screensSleepToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStarted else { return }
                self.overlayController.setEnabled(false)
                self.inputController.handleSleep()
            }
        }
        observerTokens.append(ObserverToken(
            center: workspaceNotificationCenter,
            token: screensSleepToken
        ))

        let screensWakeToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStarted else { return }
                self.overlayController.updateDisplayTopology()
                self.synchronizeDisplayStateAndLayout()
                self.overlayController.setEnabled(self.model.isEnabled)
                self.inputController.handleWake()
            }
        }
        observerTokens.append(ObserverToken(
            center: workspaceNotificationCenter,
            token: screensWakeToken
        ))

        let accessibilityToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateAccessibilityDisplayOptions()
            }
        }
        observerTokens.append(ObserverToken(
            center: workspaceNotificationCenter,
            token: accessibilityToken
        ))

        let lowPowerToken = notificationCenter.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePowerEnvironmentState()
            }
        }
        observerTokens.append(ObserverToken(
            center: notificationCenter,
            token: lowPowerToken
        ))

        let thermalToken = notificationCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePowerEnvironmentState()
            }
        }
        observerTokens.append(ObserverToken(
            center: notificationCenter,
            token: thermalToken
        ))
    }

    private func removePlatformObservers() {
        for observation in observerTokens {
            observation.center.removeObserver(observation.token)
        }
        observerTokens.removeAll()
    }

    private func updateAccessibilityDisplayOptions() {
        guard isStarted else { return }
        let options = accessibilityOptionsProvider()
        reduceMotionEnabled = options.reduceMotion
        reduceTransparencyEnabled = options.reduceTransparency
        increaseContrastEnabled = options.increaseContrast
        applyRendererConfiguration()

        KeyLightLogger.app.debug(
            "Accessibility options changed: reduceMotion=\(self.reduceMotionEnabled, privacy: .public), reduceTransparency=\(self.reduceTransparencyEnabled, privacy: .public), increaseContrast=\(self.increaseContrastEnabled, privacy: .public)"
        )
    }

    private func updatePowerEnvironmentState() {
        guard isStarted else { return }
        model.updatePowerEnvironmentState(powerEnvironmentProvider())
    }

    private func receivePhysicalEventFromOverlay(_ event: KeyboardEvent) {
        guard isStarted else { return }
        model.receivePhysicalKeyboardEvent(event)
    }

    private func synchronizeDisplayStateAndLayout() {
        let activeDisplayID = overlayController.activeDisplayPersistentID
        model.updateDisplayState(
            availableDisplays: overlayController.availableDisplays,
            activeDisplayPersistentID: activeDisplayID,
            activeDisplayPersistentIDs: overlayController.activeDisplayPersistentIDs
        )
        guard let activeDisplayID else { return }
        applyBoundLayout(
            model.boundLayoutProfileID(forDisplay: activeDisplayID),
            forDisplay: activeDisplayID
        )
    }

    private func applyBoundLayout(_ profileID: UUID?, forDisplay displayID: String) {
        guard let profileID,
              keyLayoutStore.selectedProfileID != profileID else {
            deferredDisplayLayoutBinding = nil
            return
        }

        if keyLayoutStore.selectedProfileIsEdited {
            let pending = (displayID: displayID, profileID: profileID)
            if deferredDisplayLayoutBinding?.displayID != pending.displayID ||
                deferredDisplayLayoutBinding?.profileID != pending.profileID {
                model.feedback = UserFeedback(
                    severity: .warning,
                    title: String(localized: "Display Layout Not Applied"),
                    detail: String(localized: "Save or revert the current keyboard calibration before switching to this display's bound layout.")
                )
            }
            deferredDisplayLayoutBinding = pending
            return
        }

        if keyLayoutStore.selectSavedProfile(id: profileID) {
            deferredDisplayLayoutBinding = nil
        }
    }
}
