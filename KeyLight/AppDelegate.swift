import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let overlayWindowHeight: CGFloat = 120
    private let defaultGlowBaseWidth: CGFloat = 60

    var overlayWindows: [CGDirectDisplayID: GlowOverlayWindow] = [:]
    var keyboardMonitor: KeyboardMonitor?
    var keyPositionEditorWindow: KeyPositionEditorWindow?
    let appState = AppState()

    private var cachedKeyboardDisplayID: CGDirectDisplayID?

    private var hotkeyEventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private var retainedSelfForHotkey: Unmanaged<AppDelegate>?

    private var notificationObservers: [Any] = []
    private var workspaceObservers: [Any] = []

    private var permissionCheckTimer: Timer?
    private var permissionPollInterval: TimeInterval?
    private var lastKnownPermissionState: Bool?

    private let permissionPollFast: TimeInterval = 5
    private let permissionPollSlow: TimeInterval = 300

    private var settingsDebounceWorkItem: DispatchWorkItem?
    private var reduceMotionEnabled: Bool = false
    
    private struct GlowPreviewPayload: Sendable {
        let keyCode: UInt16?
        let position: CGFloat
        let keyWidth: CGFloat
        
        init?(userInfo: [AnyHashable: Any]?) {
            guard let userInfo,
                  let position = userInfo["position"] as? CGFloat,
                  let keyWidth = userInfo["keyWidth"] as? CGFloat else {
                return nil
            }
            
            if let keyCode = userInfo["keyCode"] as? UInt16 {
                self.keyCode = keyCode
            } else if let keyCodeNumber = userInfo["keyCode"] as? NSNumber {
                self.keyCode = keyCodeNumber.uint16Value
            } else if let intCode = userInfo["keyCode"] as? Int,
                      intCode >= 0,
                      intCode <= Int(UInt16.max) {
                self.keyCode = UInt16(intCode)
            } else {
                self.keyCode = nil
            }
            
            self.position = position
            self.keyWidth = keyWidth
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyLightLog("Starting up...")

        #if DEBUG
        KeyMapping.assertParityContracts()
        #endif

        let hasPermission = PermissionManager.shared.hasInputMonitoringPermission()
        KeyLightLog("Input Monitoring permission = \(hasPermission)")

        if !hasPermission {
            PermissionManager.shared.requestInputMonitoringPermission()
        }

        setupOverlayWindows()

        if hasPermission && appState.isEnabled {
            setupKeyboardMonitor()
        }

        setupGlobalHotkey()
        setupNotificationObservers()
        setupWorkspaceObservers()

        updateReduceMotion()

        let interval: TimeInterval = (hasPermission && keyboardMonitor != nil) ? permissionPollSlow : permissionPollFast
        reschedulePermissionTimer(interval: interval)

        applySettings()
        KeyLightLog("Ready!")
    }

    private func setupNotificationObservers() {
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .glowSettingsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.settingsChanged()
            }
        )

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.screenChanged()
            }
        )

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .openKeyPositionEditor,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.openKeyPositionEditor()
            }
        )

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .keyPositionsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.keyPositionsChanged()
            }
        )

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .showGlowPreview,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let payload = GlowPreviewPayload(userInfo: notification.userInfo)
                guard let payload else { return }
                self?.showGlowPreview(payload)
            }
        )

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .hideGlowPreview,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.hideGlowPreview()
            }
        )

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .openSettingsWindow,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.openSettingsWindow()
            }
        )

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.checkPermissionStatus()
            }
        )
    }

    private func setupWorkspaceObservers() {
        workspaceObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleSleep()
            }
        )

        workspaceObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleWake()
            }
        )

        workspaceObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleSleep()
            }
        )

        workspaceObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleWake()
            }
        )

        workspaceObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateReduceMotion()
            }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.flushPendingPersist()

        settingsDebounceWorkItem?.cancel()
        settingsDebounceWorkItem = nil
        KeyPositionManager.shared.cancelPendingWork()

        SettingsWindowController.shared.closeWindow()
        keyPositionEditorWindow?.close()
        keyPositionEditorWindow = nil

        keyboardMonitor?.stop()
        keyboardMonitor = nil

        for window in overlayWindows.values {
            window.glowView?.clearHeldKeys()
            window.close()
        }
        overlayWindows.removeAll()

        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        if let handler = hotkeyEventHandler {
            RemoveEventHandler(handler)
            hotkeyEventHandler = nil
        }
        if let hotkey = hotkeyRef {
            UnregisterEventHotKey(hotkey)
            hotkeyRef = nil
        }

        retainedSelfForHotkey?.release()
        retainedSelfForHotkey = nil

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        permissionPollInterval = nil
    }

    // MARK: - Multi-Monitor

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func setupOverlayWindows() {
        for window in overlayWindows.values {
            window.glowView?.clearHeldKeys()
            window.close()
        }
        overlayWindows.removeAll()

        for screen in NSScreen.screens {
            guard let id = displayID(for: screen) else { continue }

            let frame = NSRect(
                x: screen.frame.origin.x,
                y: screen.frame.origin.y,
                width: screen.frame.width,
                height: overlayWindowHeight
            )

            let window = GlowOverlayWindow(contentRect: frame)
            window.orderFrontRegardless()
            overlayWindows[id] = window
            KeyLightLog("Overlay window created for screen \(id) at \(frame)")
        }

        updateKeyboardDisplayID()
    }

    private var keyboardDisplayID: CGDirectDisplayID? {
        if let cached = cachedKeyboardDisplayID {
            return cached
        }
        updateKeyboardDisplayID()
        return cachedKeyboardDisplayID
    }

    private func updateKeyboardDisplayID() {
        for screen in NSScreen.screens {
            if let id = displayID(for: screen), CGDisplayIsBuiltin(id) != 0 {
                cachedKeyboardDisplayID = id
                return
            }
        }

        let fallbackScreen = NSScreen.main ?? NSScreen.screens.first
        cachedKeyboardDisplayID = fallbackScreen.flatMap { displayID(for: $0) }
    }

    private var primaryOverlayWindow: GlowOverlayWindow? {
        guard let id = keyboardDisplayID else { return nil }
        return overlayWindows[id]
    }

    private func setupKeyboardMonitor() {
        keyboardMonitor?.stop()
        keyboardMonitor = nil

        for window in overlayWindows.values {
            window.glowView?.clearHeldKeys()
        }

        let monitor = KeyboardMonitor { [weak self] event in
            self?.handleKeyEvent(event)
        }
        monitor.start()
        keyboardMonitor = monitor
    }

    // MARK: - Global Hotkey

    private func setupGlobalHotkey() {
        var hotKeyRefLocal: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B4C4754), id: 1) // "KLGT"

        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let keyCode: UInt32 = 0x28 // K

        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRefLocal)

        if status == noErr {
            hotkeyRef = hotKeyRefLocal
            KeyLightLog("Global hotkey Cmd+Shift+K registered")

            let retained = Unmanaged.passRetained(self)
            retainedSelfForHotkey = retained

            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData in
                    guard let userData = userData else { return noErr }
                    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                    DispatchQueue.main.async {
                        appDelegate.toggleEffect()
                    }
                    return noErr
                },
                1,
                &eventType,
                retained.toOpaque(),
                &hotkeyEventHandler
            )
        } else {
            KeyLightLog("Failed to register global hotkey (status: \(status))")
        }
    }

    @objc func toggleEffect() {
        appState.isEnabled.toggle()
        KeyLightLog("Effect \(appState.isEnabled ? "enabled" : "disabled")")

        if !appState.isEnabled {
            for window in overlayWindows.values {
                window.glowView?.clearHeldKeys()
            }
            keyboardMonitor?.stop()
            keyboardMonitor = nil
        } else if PermissionManager.shared.hasInputMonitoringPermission() {
            setupKeyboardMonitor()
        } else {
            PermissionManager.shared.requestInputMonitoringPermission()
        }

        applySettings()
    }

    // MARK: - Notifications

    private func settingsChanged() {
        settingsDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.applySettings()
        }
        settingsDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func screenChanged() {
        updateOverlayWindows()
        applySettings()
    }

    private func updateOverlayWindows() {
        var currentDisplayIDs: Set<CGDirectDisplayID> = []

        for screen in NSScreen.screens {
            guard let id = displayID(for: screen) else { continue }
            currentDisplayIDs.insert(id)

            if let existingWindow = overlayWindows[id] {
                let frame = NSRect(
                    x: screen.frame.origin.x,
                    y: screen.frame.origin.y,
                    width: screen.frame.width,
                    height: overlayWindowHeight
                )
                existingWindow.setFrame(frame, display: true)
            } else {
                let frame = NSRect(
                    x: screen.frame.origin.x,
                    y: screen.frame.origin.y,
                    width: screen.frame.width,
                    height: overlayWindowHeight
                )
                let window = GlowOverlayWindow(contentRect: frame)
                window.orderFrontRegardless()
                overlayWindows[id] = window
                KeyLightLog("Overlay window created for screen \(id) at \(frame)")
            }
        }

        for (id, window) in overlayWindows where !currentDisplayIDs.contains(id) {
            window.glowView?.clearHeldKeys()
            window.close()
            overlayWindows.removeValue(forKey: id)
            KeyLightLog("Overlay window removed for disconnected screen \(id)")
        }

        updateKeyboardDisplayID()
    }

    private func openSettingsWindow() {
        SettingsWindowController.shared.showWindow(appState: appState)
    }

    private func openKeyPositionEditor() {
        if keyPositionEditorWindow == nil {
            keyPositionEditorWindow = KeyPositionEditorWindow()
        }
        keyPositionEditorWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func keyPositionsChanged() {
        KeyPositionManager.shared.reloadOffsets()
    }

    // MARK: - Sleep / Wake

    private func handleSleep() {
        KeyLightLog("System sleeping, pausing keyboard monitor")
        keyboardMonitor?.stop()
        keyboardMonitor = nil

        for window in overlayWindows.values {
            window.glowView?.clearHeldKeys()
        }

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    private func handleWake() {
        KeyLightLog("System waking, resuming keyboard monitor")

        for window in overlayWindows.values {
            window.glowView?.clearHeldKeys()
        }

        let hasPermission = PermissionManager.shared.hasInputMonitoringPermission()
        if hasPermission && appState.isEnabled {
            setupKeyboardMonitor()
        }

        let interval = (hasPermission && (!appState.isEnabled || keyboardMonitor != nil)) ? permissionPollSlow : permissionPollFast
        reschedulePermissionTimer(interval: interval)
    }

    // MARK: - Preview Glow

    private var previewKeyCode: UInt16 = 9999

    private func showGlowPreview(_ payload: GlowPreviewPayload) {
        guard let glowView = primaryOverlayWindow?.glowView else { return }

        if appState.colorMode == .randomPerKey {
            let requestedKeyCode = payload.keyCode ?? previewKeyCode
            glowView.glowColor = appState.randomPerKeyNSColor(for: requestedKeyCode)
            glowView.colorResolver = nil
        }

        glowView.updateGlowPosition(at: payload.position, keyCode: previewKeyCode, keyWidth: payload.keyWidth)
    }

    private func hideGlowPreview() {
        guard let glowView = primaryOverlayWindow?.glowView else { return }
        glowView.hideGlow(keyCode: previewKeyCode)
    }

    // MARK: - Accessibility

    private func updateReduceMotion() {
        let shouldReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let changed = shouldReduceMotion != reduceMotionEnabled
        reduceMotionEnabled = shouldReduceMotion

        if changed {
            applySettings()
        }

        KeyLightLog("Reduce motion: \(reduceMotionEnabled)")
    }

    // MARK: - Permission Monitoring

    private func checkPermissionStatus() {
        let hasPermission = PermissionManager.shared.hasInputMonitoringPermission()
        let permissionChanged = (lastKnownPermissionState == nil) || (lastKnownPermissionState != hasPermission)
        lastKnownPermissionState = hasPermission

        if !hasPermission {
            if keyboardMonitor != nil {
                KeyLightLog("Input Monitoring permission was revoked")
                keyboardMonitor?.stop()
                keyboardMonitor = nil
            }
            reschedulePermissionTimer(interval: permissionPollFast)
            if permissionChanged {
                NotificationCenter.default.post(name: .permissionStatusChanged, object: nil)
            }
            return
        }

        if appState.isEnabled && keyboardMonitor == nil {
            setupKeyboardMonitor()
        }

        let monitorHealthy = !appState.isEnabled || keyboardMonitor != nil
        reschedulePermissionTimer(interval: monitorHealthy ? permissionPollSlow : permissionPollFast)

        if permissionChanged {
            NotificationCenter.default.post(name: .permissionStatusChanged, object: nil)
        }
    }

    private func reschedulePermissionTimer(interval: TimeInterval) {
        if let current = permissionPollInterval,
           abs(current - interval) < 0.001,
           permissionCheckTimer != nil {
            return
        }

        permissionCheckTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPermissionStatus()
            }
        }
        timer.tolerance = min(10.0, interval * 0.5)
        permissionCheckTimer = timer
        permissionPollInterval = interval
    }

    // MARK: - Apply Settings / Events

    private func applySettings() {
        for window in overlayWindows.values {
            guard let glowView = window.glowView else { continue }

            glowView.maxOpacity = Float(appState.glowOpacity)
            glowView.baseKeyWidth = defaultGlowBaseWidth
            glowView.glowHeight = CGFloat(appState.glowSize)
            glowView.widthMultiplier = CGFloat(appState.glowWidth)
            glowView.fadeOutDuration = appState.fadeDuration
            glowView.glowRoundness = CGFloat(appState.glowRoundness)
            glowView.glowFullness = CGFloat(appState.glowFullness)

            switch appState.colorMode {
            case .solid:
                glowView.glowColor = appState.glowNSColor
                glowView.colorResolver = nil
            case .positionGradient:
                glowView.glowColor = appState.glowNSColor
                glowView.colorResolver = { [weak appState] position in
                    guard let appState = appState else { return .blue }
                    return interpolateColor(
                        from: appState.gradientStartNSColor,
                        to: appState.gradientEndNSColor,
                        fraction: position
                    )
                }
            case .rainbow:
                glowView.glowColor = appState.glowNSColor
                glowView.colorResolver = { position in
                    let clamped = max(0.0, min(1.0, position))
                    return NSColor(hue: clamped, saturation: 0.9, brightness: 1.0, alpha: 1.0)
                }
            case .randomPerKey:
                glowView.glowColor = appState.randomPerKeyNSColor(for: 0)
                glowView.colorResolver = nil
            }
        }
    }

    // SECURITY: This handler is for visual positioning only. Never log keystroke data.
    private func handleKeyEvent(_ event: KeyEvent) {
        NotificationCenter.default.post(
            name: event.isKeyDown ? .physicalKeyDown : .physicalKeyUp,
            object: nil,
            userInfo: ["keyCode": event.keyCode]
        )

        guard let glowView = primaryOverlayWindow?.glowView else {
            return
        }

        if event.isKeyDown {
            guard appState.isEnabled else { return }

            if appState.colorMode == .randomPerKey {
                glowView.glowColor = appState.randomPerKeyNSColor(for: event.keyCode)
                glowView.colorResolver = nil
            }

            glowView.showGlow(
                at: event.horizontalPosition,
                keyCode: event.keyCode,
                keyWidth: event.keyWidth
            )
        } else {
            // Always process keyUp to avoid stuck glows when disabling mid-press
            glowView.hideGlow(keyCode: event.keyCode)
        }
    }
}
