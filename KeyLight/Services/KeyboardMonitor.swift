import Foundation
import CoreGraphics
import AppKit
import IOKit.hid

// Set to true to enable debug logging (disable for production)
#if DEBUG
private let enableDebugLogging = false
#else
private let enableDebugLogging = false
#endif
private let systemDefinedEventRawValue: UInt32 = 14

/// Monitors global keyboard events using a listen-only CGEventTap.
///
/// The event tap, decoder, and narrowly allow-listed HID fallback are confined
/// to one dedicated serial CFRunLoop thread. Only normalized value events cross
/// to the main actor, keeping AppKit layout and rendering out of the event-tap
/// timeout path.
final class KeyboardMonitor: @unchecked Sendable {
    /// The privacy-critical tap mode is a runtime contract, not merely a
    /// source-code convention. Keeping it in one value lets tests verify the
    /// actual option passed to Core Graphics without reading protected source
    /// folders or requesting Files & Folders access.
    static let eventTapOptions: CGEventTapOptions = .listenOnly

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var callback: (@MainActor (KeyEvent) -> Void)?
    private var onStreamReset: ((KeyboardMonitor) -> Void)?
    private var onBecameUnavailable: ((KeyboardMonitor) -> Void)?
    private var hidManager: IOHIDManager?
    private var decoder = KeyboardEventDecoder()
    private let capsLockPulseDuration: TimeInterval = 0.1
    private let lifecycleLock = NSLock()
    private var eventThread: Thread?
    private var eventRunLoop: CFRunLoop?
    private var eventLoopStopped: DispatchSemaphore?
    private var running = false
    private var eventSequence: UInt64 = 0

    private struct HIDUsage: Hashable {
        let page: UInt32
        let usage: UInt32
    }

    // Keep the fallback privacy boundary narrow: declared media controls, the
    // Generic Desktop Do Not Disturb usage, and the three physical Keyboard-
    // page function usages Apple hardware may expose before Fn remapping.
    private static let hidUsageMap: [HIDUsage: UInt16] = [
        HIDUsage(page: UInt32(kHIDPage_GenericDesktop), usage: UInt32(kHIDUsage_GD_DoNotDisturb)): 505,
        HIDUsage(page: UInt32(kHIDPage_KeyboardOrKeypad), usage: UInt32(kHIDUsage_KeyboardF6)): 505,
        HIDUsage(page: UInt32(kHIDPage_KeyboardOrKeypad), usage: UInt32(kHIDUsage_KeyboardF7)): 506,
        HIDUsage(page: UInt32(kHIDPage_KeyboardOrKeypad), usage: UInt32(kHIDUsage_KeyboardF9)): 517,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_DisplayBrightnessDecrement)): 500,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_DisplayBrightnessIncrement)): 501,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_KeyboardBrightnessDecrement)): 500,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_KeyboardBrightnessIncrement)): 501,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_ScanPreviousTrack)): 506,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_Rewind)): 506,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_Play)): 516,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_Pause)): 516,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_PlayOrPause)): 516,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_PlayOrSkip)): 516,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_ScanNextTrack)): 517,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_FastForward)): 517,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_Mute)): 518,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_VolumeDecrement)): 519,
        HIDUsage(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_VolumeIncrement)): 520,
    ]

    private static let modifierKeyFlagMaskByKeyCode: [UInt16: CGEventFlags] = [
        55: .maskCommand,
        54: .maskCommand,
        58: .maskAlternate,
        61: .maskAlternate,
        59: .maskControl,
        62: .maskControl,
        56: .maskShift,
        60: .maskShift,
        63: .maskSecondaryFn,
        57: .maskAlphaShift
    ]

    init(
        onStreamReset: ((KeyboardMonitor) -> Void)? = nil,
        onBecameUnavailable: ((KeyboardMonitor) -> Void)? = nil,
        callback: @escaping @MainActor (KeyEvent) -> Void
    ) {
        self.onStreamReset = onStreamReset
        self.onBecameUnavailable = onBecameUnavailable
        self.callback = callback
    }

    var isRunning: Bool {
        lifecycleLock.withLock { running }
    }

    @discardableResult
    func start() -> Bool {
        if isRunning {
            return true
        }
        let canStart = lifecycleLock.withLock {
            eventThread == nil && eventRunLoop == nil
        }
        guard canStart else {
            return false
        }

        let started = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runEventLoop(started: started, stopped: stopped)
        }
        thread.name = "KeyLight Keyboard Event Loop"
        thread.qualityOfService = .userInteractive
        lifecycleLock.withLock {
            eventThread = thread
            eventLoopStopped = stopped
        }
        thread.start()

        guard started.wait(timeout: .now() + 2) == .success else {
            KeyLightLogger.keyboardMonitor.error("Keyboard event loop did not start in time")
            stop()
            return false
        }
        return isRunning
    }

    private func runEventLoop(
        started: DispatchSemaphore,
        stopped: DispatchSemaphore
    ) {
        autoreleasepool {
            guard let runLoop = CFRunLoopGetCurrent() else {
                lifecycleLock.withLock {
                    running = false
                    eventThread = nil
                }
                started.signal()
                stopped.signal()
                return
            }
            lifecycleLock.withLock {
                eventRunLoop = runLoop
            }
            decoder.reset()

            guard installEventTap(on: runLoop) else {
                lifecycleLock.withLock {
                    running = false
                    eventRunLoop = nil
                    eventThread = nil
                }
                started.signal()
                stopped.signal()
                return
            }

            startHIDMediaMonitoring(on: runLoop)
            lifecycleLock.withLock { running = true }
            started.signal()
            KeyLightLogger.keyboardMonitor.notice("Keyboard monitor started")
            CFRunLoopRun()

            tearDownEventSources(on: runLoop)
            decoder.reset()
            lifecycleLock.withLock {
                running = false
                eventRunLoop = nil
                eventThread = nil
            }
            stopped.signal()
        }
    }

    private func installEventTap(on runLoop: CFRunLoop) -> Bool {

        let eventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << systemDefinedEventRawValue)

        // Store self reference for the C callback
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: Self.eventTapOptions,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    KeyLightLogger.keyboardMonitor.notice("Event tap was disabled; attempting to re-enable it")
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                        monitor.reportEventTapRecoveryOutcome(
                            reenabled: CGEvent.tapIsEnabled(tap: tap)
                        )
                    } else {
                        monitor.reportEventTapRecoveryOutcome(reenabled: false)
                    }
                    return Unmanaged.passUnretained(event)
                }

                if type.rawValue == systemDefinedEventRawValue {
                    monitor.handleSystemDefinedCGEvent(event)
                    return Unmanaged.passUnretained(event)
                }

                if type == .flagsChanged {
                    monitor.handleFlagsChangedCGEvent(event)
                    return Unmanaged.passUnretained(event)
                }

                if type == .keyDown || type == .keyUp {
                    let rawKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                    let isKeyDown = (type == .keyDown)
                    let isRepeat = isKeyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if rawKeyCode == 57 {
                        monitor.decoder.recordCapsLockTransition(
                            at: ProcessInfo.processInfo.systemUptime
                        )
                    }
                    guard let decoded = monitor.decodeKeyboardEvent(
                        rawKeyCode: rawKeyCode,
                        isKeyDown: isKeyDown,
                        isRepeat: isRepeat
                    ) else {
                        #if DEBUG
                        if enableDebugLogging {
                            KeyLightLogger.keyboardMonitor.debug("Skipping an unresolved keyboard event")
                        }
                        #endif
                        return Unmanaged.passUnretained(event)
                    }

                    let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: decoded.keyCode)
                    monitor.decoder.recordTrustedKeyboardTopRowEvent(
                        canonicalKeyCode: canonicalKeyCode,
                        isKeyDown: decoded.isKeyDown,
                        now: ProcessInfo.processInfo.systemUptime
                    )
                    monitor.emitMappedKeyEvent(decoded)
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            KeyLightLogger.keyboardMonitor.error("Failed to create the keyboard event tap")
            return false
        }

        eventTap = tap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            KeyLightLogger.keyboardMonitor.error("Failed to create the keyboard event tap run-loop source")
            eventTap = nil
            return false
        }
        runLoopSource = source
        CFRunLoopAddSource(runLoop, source, .commonModes)

        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            KeyLightLogger.keyboardMonitor.error("Keyboard event tap could not be enabled")
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            runLoopSource = nil
            eventTap = nil
            return false
        }
        return true
    }

    func stop() {
        let state = lifecycleLock.withLock {
            (eventRunLoop, eventLoopStopped, eventThread)
        }
        if let runLoop = state.0 {
            if state.2 === Thread.current {
                CFRunLoopStop(runLoop)
            } else {
                CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                    CFRunLoopStop(runLoop)
                }
                CFRunLoopWakeUp(runLoop)
                _ = state.1?.wait(timeout: .now() + 2)
            }
        }
        lifecycleLock.withLock {
            running = false
            eventRunLoop = nil
            eventThread = nil
            eventLoopStopped = nil
        }
        callback = nil
        onStreamReset = nil
        onBecameUnavailable = nil
        KeyLightLogger.keyboardMonitor.debug("Keyboard monitor stopped")
    }

    private func tearDownEventSources(on runLoop: CFRunLoop) {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        stopHIDMediaMonitoring(from: runLoop)
        eventTap = nil
        runLoopSource = nil
    }

    private func reportEventTapRecoveryOutcome(reenabled: Bool) {
        guard reenabled else {
            KeyLightLogger.keyboardMonitor.error("Event tap could not be re-enabled")
            Task { @MainActor [weak self] in
                guard let self else { return }
                onBecameUnavailable?(self)
            }
            return
        }

        // Modifier state and deduplication windows are stream-derived too; a
        // timeout can make them stale even when the tap itself recovers.
        decoder.reset()
        Task { @MainActor [weak self] in
            guard let self else { return }
            onStreamReset?(self)
        }
    }

    private func startHIDMediaMonitoring(on runLoop: CFRunLoop) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let context = Unmanaged.passUnretained(self).toOpaque()

        let callback: IOHIDValueCallback = { context, _, _, value in
            guard let context else { return }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleHIDInputValue(value)
        }

        IOHIDManagerRegisterInputValueCallback(manager, callback, context)
        let allowedValueMatches: [[String: Int]] = Self.hidUsageMap.keys
            .sorted {
                if $0.page == $1.page { return $0.usage < $1.usage }
                return $0.page < $1.page
            }
            .map { usage in
                [
                    kIOHIDElementUsagePageKey as String: Int(usage.page),
                    kIOHIDElementUsageKey as String: Int(usage.usage)
                ]
            }
        IOHIDManagerSetInputValueMatchingMultiple(
            manager,
            allowedValueMatches as CFArray
        )
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            runLoop,
            CFRunLoopMode.commonModes.rawValue
        )

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            KeyLightLogger.keyboardMonitor.warning("Optional HID media-key fallback is unavailable")
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                runLoop,
                CFRunLoopMode.commonModes.rawValue
            )
            return
        }

        hidManager = manager
    }

    private func stopHIDMediaMonitoring(from runLoop: CFRunLoop) {
        guard let manager = hidManager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            runLoop,
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = nil
    }

    private func handleSystemDefinedCGEvent(_ event: CGEvent) {
        // NSEvent construction consults Text Input Services and is main-queue
        // isolated on current macOS releases. Doing that work directly in the
        // dedicated event-tap run loop triggers libdispatch's queue assertion
        // after ordinary typing. Copy the immutable CGEvent, extract only the
        // system-defined media metadata on the main queue, then return that
        // value metadata to the event loop where decoder state is confined.
        let eventBox = SendableCGEvent(event.copy() ?? event)
        let eventTime = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self, eventBox] in
            guard let self,
                  let systemEvent = NSEvent(cgEvent: eventBox.value) else {
                return
            }
            self.enqueueSystemDefinedMediaEvent(
                subtypeRawValue: Int(systemEvent.subtype.rawValue),
                data1: UInt32(truncatingIfNeeded: systemEvent.data1),
                eventTime: eventTime
            )
        }
    }

    private func handleFlagsChangedCGEvent(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == 57 {
            decoder.recordCapsLockTransition(
                at: ProcessInfo.processInfo.systemUptime
            )
        }
        guard let isKeyDown = resolveModifierFlagsChanged(keyCode: keyCode, flags: event.flags) else { return }
        if keyCode == 57 {
            emitCapsLockTransition(isKeyDown: isKeyDown)
            return
        }
        emitMappedKeyEvent(keyCode: keyCode, isKeyDown: isKeyDown)
    }

    private func enqueueSystemDefinedMediaEvent(
        subtypeRawValue: Int,
        data1: UInt32,
        eventTime: TimeInterval
    ) {
        guard let runLoop = lifecycleLock.withLock({ eventRunLoop }) else {
            return
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            [weak self] in
            self?.handleSystemDefinedMediaEvent(
                subtypeRawValue: subtypeRawValue,
                data1: data1,
                eventTime: eventTime
            )
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func handleSystemDefinedMediaEvent(
        subtypeRawValue: Int,
        data1: UInt32,
        eventTime: TimeInterval
    ) {
        guard let transition = decoder.decodeSystemDefinedMediaEvent(
            subtypeRawValue: subtypeRawValue,
            data1: data1,
            now: eventTime
        ) else { return }
        emitMediaKeyEvent(
            keyCode: transition.keyCode,
            isKeyDown: transition.isKeyDown,
            source: .systemDefined
        )
    }

    private func handleHIDInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        guard let virtualKeyCode = Self.hidUsageMap[HIDUsage(page: usagePage, usage: usage)] else { return }

        let isKeyDown = IOHIDValueGetIntegerValue(value) != 0
        emitMediaKeyEvent(keyCode: virtualKeyCode, isKeyDown: isKeyDown, source: .hid)
    }

    private func emitMediaKeyEvent(
        keyCode: UInt16,
        isKeyDown: Bool,
        source: KeyboardEventDecoder.MediaEventSource
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
        if decoder.shouldDedupeMediaEvent(
            canonicalKeyCode: canonicalKeyCode,
            isKeyDown: isKeyDown,
            source: source,
            now: now
        ) {
            return
        }

        let normalizedSource: KeyboardEvent.Source
        switch source {
        case .systemDefined:
            normalizedSource = .eventTap
        case .hid:
            normalizedSource = .consumerHID
        }
        emitMappedKeyEvent(
            keyCode: canonicalKeyCode,
            isKeyDown: isKeyDown,
            source: normalizedSource
        )
    }

    private func emitMappedKeyEvent(
        keyCode: UInt16,
        isKeyDown: Bool,
        isRepeat: Bool = false,
        source: KeyboardEvent.Source = .eventTap
    ) {
        emitMappedKeyEvent(KeyEvent(
            keyCode: keyCode,
            isKeyDown: isKeyDown,
            isRepeat: isRepeat,
            source: source
        ))
    }

    private func emitMappedKeyEvent(_ event: KeyEvent) {
        let sequence = lifecycleLock.withLock { () -> UInt64 in
            eventSequence &+= 1
            return eventSequence
        }
        KeyLightSignposts.eventReceived(sequence: sequence)
        let normalized = KeyEvent(
            keyCode: KeyboardLayoutInfo.canonicalKeyCode(for: event.keyCode),
            isKeyDown: event.isKeyDown,
            isRepeat: event.isRepeat,
            source: event.source,
            sequence: sequence
        )
        KeyLightSignposts.eventNormalized(sequence: sequence)
        Task { @MainActor [weak self] in
            self?.callback?(normalized)
        }
    }

    private func emitCapsLockTransition(isKeyDown: Bool) {
        let keyCode: UInt16 = 57
        let sequence = decoder.capsLockEmitSequence(isKeyDown: isKeyDown)
        guard let first = sequence.first else { return }
        emitMappedKeyEvent(keyCode: keyCode, isKeyDown: first)

        if sequence.count > 1 {
            let pulseDuration = capsLockPulseDuration
            Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(pulseDuration))
                } catch {
                    return
                }
                self?.emitMappedKeyEvent(
                    keyCode: keyCode,
                    isKeyDown: false,
                    source: .eventTap
                )
            }
        }
    }

    private func resolveVirtualKeyCode(nxCode: Int) -> UInt16? {
        decoder.resolveVirtualKeyCode(nxCode: nxCode)
    }

    private func decodeKeyboardEvent(
        rawKeyCode: UInt16,
        isKeyDown: Bool,
        isRepeat: Bool
    ) -> KeyEvent? {
        // The established key table and explicit Apple top-row raw-code map
        // resolve every input KeyLight supports. Never materialize NSEvent or
        // consult character metadata on this non-main event thread.
        return decoder.decodeKeyboardEvent(
            rawKeyCode: rawKeyCode,
            isKeyDown: isKeyDown,
            isRepeat: isRepeat,
            source: .eventTap,
            charactersIgnoringModifiers: nil,
            specialKeyRawValue: nil,
            isMappedKeyCode: isMappedKeyCode(rawKeyCode)
        )
    }

    private func resolveKeyboardEventKeyCode(
        rawKeyCode: UInt16,
        charactersIgnoringModifiers: String?,
        specialKeyRawValue: Int?
    ) -> KeyboardEventDecoder.KeyboardResolution {
        decoder.resolveKeyboardEvent(
            rawKeyCode: rawKeyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            specialKeyRawValue: specialKeyRawValue,
            isMappedKeyCode: isMappedKeyCode(rawKeyCode)
        )
    }

    private func resolveModifierFlagsChanged(keyCode: UInt16, flags: CGEventFlags) -> Bool? {
        guard let mask = Self.modifierKeyFlagMaskByKeyCode[keyCode] else { return nil }
        return decoder.resolveModifierFlagsChanged(
            keyCode: keyCode,
            flagIsSet: flags.contains(mask)
        )
    }

    private func isMappedKeyCode(_ keyCode: UInt16) -> Bool {
        KeyMapping.hasMappedKeyCode(keyCode)
    }

#if DEBUG
    func _testReportEventTapRecoveryOutcome(reenabled: Bool) {
        if reenabled {
            decoder.reset()
            onStreamReset?(self)
        } else {
            onBecameUnavailable?(self)
        }
    }

    func _testResolveVirtualKeyCode(nxCode: Int) -> UInt16? {
        resolveVirtualKeyCode(nxCode: nxCode)
    }

    func _testShouldDedupeMediaEvent(keyCode: UInt16, isKeyDown: Bool, now: CFAbsoluteTime) -> Bool {
        decoder.shouldDedupeMediaEvent(
            canonicalKeyCode: KeyboardLayoutInfo.canonicalKeyCode(for: keyCode),
            isKeyDown: isKeyDown,
            source: .systemDefined,
            now: now
        )
    }

    func _testShouldDedupeMediaEventWithSource(
        keyCode: UInt16,
        isKeyDown: Bool,
        source: String,
        now: CFAbsoluteTime
    ) -> Bool {
        let mappedSource: KeyboardEventDecoder.MediaEventSource = source == "hid" ? .hid : .systemDefined
        return decoder.shouldDedupeMediaEvent(
            canonicalKeyCode: KeyboardLayoutInfo.canonicalKeyCode(for: keyCode),
            isKeyDown: isKeyDown,
            source: mappedSource,
            now: now
        )
    }

    func _testResolveHIDConsumerUsage(_ usage: UInt32) -> UInt16? {
        _testResolveHIDUsage(page: UInt32(kHIDPage_Consumer), usage: usage)
    }

    func _testResolveHIDUsage(page: UInt32, usage: UInt32) -> UInt16? {
        Self.hidUsageMap[HIDUsage(page: page, usage: usage)]
    }

    func _testResolveKeyboardEventKeyCode(rawKeyCode: UInt16, charactersIgnoringModifiers: String?) -> UInt16 {
        resolveKeyboardEventKeyCode(
            rawKeyCode: rawKeyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            specialKeyRawValue: nil
        ).keyCode
    }

    func _testResolveKeyboardEventConfidence(rawKeyCode: UInt16, charactersIgnoringModifiers: String?) -> String {
        let confidence = resolveKeyboardEventKeyCode(
            rawKeyCode: rawKeyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            specialKeyRawValue: nil
        ).confidence
        switch confidence {
        case .high:
            return "high"
        case .unknown:
            return "unknown"
        }
    }

    func _testResolveKeyboardEventKeyCodeWithSpecialKey(rawKeyCode: UInt16, specialKeyRawValue: Int) -> UInt16 {
        resolveKeyboardEventKeyCode(
            rawKeyCode: rawKeyCode,
            charactersIgnoringModifiers: nil,
            specialKeyRawValue: specialKeyRawValue
        ).keyCode
    }

    func _testResolveKeyboardEventConfidenceWithSpecialKey(rawKeyCode: UInt16, specialKeyRawValue: Int) -> String {
        let confidence = resolveKeyboardEventKeyCode(
            rawKeyCode: rawKeyCode,
            charactersIgnoringModifiers: nil,
            specialKeyRawValue: specialKeyRawValue
        ).confidence
        switch confidence {
        case .high:
            return "high"
        case .unknown:
            return "unknown"
        }
    }

    func _testDecodeEventLoopKeyboardEvent(
        rawKeyCode: UInt16,
        isKeyDown: Bool,
        isRepeat: Bool = false
    ) -> KeyEvent? {
        decodeKeyboardEvent(
            rawKeyCode: rawKeyCode,
            isKeyDown: isKeyDown,
            isRepeat: isRepeat
        )
    }

    func _testResolveModifierFlagsChanged(keyCode: UInt16, flags: CGEventFlags) -> Bool? {
        resolveModifierFlagsChanged(keyCode: keyCode, flags: flags)
    }

    func _testCapsLockEmitSequence(isKeyDown: Bool) -> [Bool] {
        decoder.capsLockEmitSequence(isKeyDown: isKeyDown)
    }
#endif

    deinit {
        stop()
    }
}

/// Core Foundation event objects are immutable for KeyLight's use here. This
/// wrapper makes the intentional cross-queue ownership explicit under Swift 6
/// without broadening KeyboardMonitor's unsafe surface.
private final class SendableCGEvent: @unchecked Sendable {
    let value: CGEvent

    init(_ value: CGEvent) {
        self.value = value
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
