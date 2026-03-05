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

/// Represents a keyboard event with key code, state, position and width
struct KeyEvent: Sendable {
    let keyCode: UInt16
    let isKeyDown: Bool
    let horizontalPosition: CGFloat
    let keyWidth: CGFloat
}

/// Monitors global keyboard events using CGEventTap
/// SAFETY: KeyboardMonitor state is confined to the main run loop.
/// C callbacks only interact with the instance via main-run-loop scheduled work.
final class KeyboardMonitor: @unchecked Sendable {
    private enum MediaEventSource {
        case systemDefined
        case hid
    }

    private enum KeyboardResolutionConfidence {
        case high
        case unknown
    }

    private struct KeyboardResolution {
        let keyCode: UInt16
        let confidence: KeyboardResolutionConfidence
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var callback: ((KeyEvent) -> Void)?
    private var hidManager: IOHIDManager?

    private var recentMediaEventTimes: [UInt32: CFAbsoluteTime] = [:]
    private var recentHIDMediaEventTimes: [UInt32: CFAbsoluteTime] = [:]
    private var recentSystemMediaEventTimes: [UInt32: CFAbsoluteTime] = [:]
    private var recentTrustedKeyboardTopRowEvents: [Bool: (keyCode: UInt16, timestamp: CFAbsoluteTime)] = [:]
    private var modifierKeyStates: [UInt16: Bool] = [:]
    private var lastCapsLockTransitionTime: CFAbsoluteTime = -1
    private let mediaDedupWindow: CFAbsoluteTime = 0.03
    private let keyboardTopRowSourceWindow: CFAbsoluteTime = 0.04
    private let capsLockSystemEventGuardWindow: CFAbsoluteTime = 0.08
    private let capsLockPulseDuration: TimeInterval = 0.1

    // Legacy compatibility mapping for system-defined media key events.
    private static let legacyNXMap: [Int: UInt16] = [
        0: 500,   // Brightness Down
        1: 501,   // Brightness Up
        2: 502,   // Mission Control
        3: 503,   // Spotlight/Launchpad
        7: 507,   // Legacy F8 media position
        16: 516,  // Play/Pause
        17: 517,  // Next
        18: 518,  // Mute
    ]

    // Canonical NX_* mapping from ev_keymap.h.
    private static let canonicalNXMap: [Int: UInt16] = [
        3: 500,   // NX_KEYTYPE_BRIGHTNESS_DOWN
        2: 501,   // NX_KEYTYPE_BRIGHTNESS_UP
        18: 506,  // NX_KEYTYPE_PREVIOUS
        16: 516,  // NX_KEYTYPE_PLAY
        17: 517,  // NX_KEYTYPE_NEXT
        7: 518,   // NX_KEYTYPE_MUTE
        1: 519,   // NX_KEYTYPE_SOUND_DOWN
        0: 520,   // NX_KEYTYPE_SOUND_UP
    ]
    private static let canonicalPreferredNXCodes: Set<Int> = [0, 1, 2, 3, 7, 16, 17, 18]

    // Consumer-page HID usages mapped to the same virtual key codes as systemDefined events.
    private static let hidConsumerUsageMap: [UInt32: UInt16] = [
        UInt32(kHIDUsage_Csmr_DisplayBrightnessDecrement): 500,
        UInt32(kHIDUsage_Csmr_DisplayBrightnessIncrement): 501,
        UInt32(kHIDUsage_Csmr_KeyboardBrightnessDecrement): 500,
        UInt32(kHIDUsage_Csmr_KeyboardBrightnessIncrement): 501,
        UInt32(kHIDUsage_Csmr_ScanPreviousTrack): 506,
        UInt32(kHIDUsage_Csmr_Rewind): 506,
        UInt32(kHIDUsage_Csmr_Play): 516,
        UInt32(kHIDUsage_Csmr_Pause): 516,
        UInt32(kHIDUsage_Csmr_PlayOrPause): 516,
        UInt32(kHIDUsage_Csmr_PlayOrSkip): 516,
        UInt32(kHIDUsage_Csmr_ScanNextTrack): 517,
        UInt32(kHIDUsage_Csmr_FastForward): 517,
        UInt32(kHIDUsage_Csmr_Mute): 518,
        UInt32(kHIDUsage_Csmr_VolumeDecrement): 519,
        UInt32(kHIDUsage_Csmr_VolumeIncrement): 520,
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

    private static let modifierCounterpartKeyCode: [UInt16: UInt16] = [
        55: 54,
        54: 55,
        58: 61,
        61: 58,
        59: 62,
        62: 59,
        56: 60,
        60: 56
    ]

    private static let functionCharacterToFunctionKeyCode: [UInt32: UInt16] = [
        0xF704: 122, // F1
        0xF705: 120, // F2
        0xF706: 99,  // F3
        0xF707: 118, // F4
        0xF708: 96,  // F5
        0xF709: 97,  // F6
        0xF70A: 98,  // F7
        0xF70B: 100, // F8
        0xF70C: 101, // F9
        0xF70D: 109, // F10
        0xF70E: 103, // F11
        0xF70F: 111  // F12
    ]

    private static let specialKeyRawValueToFunctionKeyCode: [Int: UInt16] = [
        NSEvent.SpecialKey.f1.rawValue: 122,
        NSEvent.SpecialKey.f2.rawValue: 120,
        NSEvent.SpecialKey.f3.rawValue: 99,
        NSEvent.SpecialKey.f4.rawValue: 118,
        NSEvent.SpecialKey.f5.rawValue: 96,
        NSEvent.SpecialKey.f6.rawValue: 97,
        NSEvent.SpecialKey.f7.rawValue: 98,
        NSEvent.SpecialKey.f8.rawValue: 100,
        NSEvent.SpecialKey.f9.rawValue: 101,
        NSEvent.SpecialKey.f10.rawValue: 109,
        NSEvent.SpecialKey.f11.rawValue: 103,
        NSEvent.SpecialKey.f12.rawValue: 111
    ]

    // Trusted raw keyboard codes observed on media-mode top-row keys.
    // These are only used when specialKey/scalar metadata is absent.
    private static let trustedTopRowRawFunctionKeyCodeMap: [UInt16: UInt16] = [
        145: 122, // F1
        144: 120, // F2
        160: 99,  // F3
        131: 118, // F4
        177: 96,  // F5
        176: 97,  // F6
        173: 98,  // F7
        174: 100, // F8
        175: 101, // F9
        74: 109,  // F10
        73: 103,  // F11
        72: 111   // F12
    ]

    private static let topRowFunctionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    init(callback: @escaping (KeyEvent) -> Void) {
        self.callback = callback
    }

    func start() {
        recentMediaEventTimes.removeAll()
        recentHIDMediaEventTimes.removeAll()
        recentSystemMediaEventTimes.removeAll()
        recentTrustedKeyboardTopRowEvents.removeAll()
        modifierKeyStates.removeAll()
        lastCapsLockTransitionTime = -1

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
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout {
                    if enableDebugLogging { print("KeyboardMonitor: Tap was disabled, re-enabling...") }
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
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
                    if rawKeyCode == 57 {
                        monitor.lastCapsLockTransitionTime = CFAbsoluteTimeGetCurrent()
                    }
                    let resolution = monitor.resolveKeyboardEventKeyCode(rawKeyCode: rawKeyCode, event: event)
                    guard resolution.confidence == .high else {
                        #if DEBUG
                        if enableDebugLogging {
                            KeyLightLog("Skipping unresolved keyboard event keyCode \(rawKeyCode)")
                        }
                        #endif
                        return Unmanaged.passUnretained(event)
                    }

                    let keyCode = resolution.keyCode
                    if monitor.isTopRowFunctionKeyCode(keyCode) {
                        monitor.recordTrustedKeyboardTopRowEvent(keyCode: keyCode, isKeyDown: isKeyDown)
                    }
                    monitor.emitMappedKeyEvent(keyCode: keyCode, isKeyDown: isKeyDown)
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            print("KeyboardMonitor: FAILED to create event tap!")
            print("KeyboardMonitor: Make sure Input Monitoring permission is granted in System Settings")
            return
        }

        if enableDebugLogging { print("KeyboardMonitor: Event tap created successfully!") }
        eventTap = tap

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

        CGEvent.tapEnable(tap: tap, enable: true)
        if enableDebugLogging { print("KeyboardMonitor: Listening for keyboard events...") }
        startHIDMediaMonitoring()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        stopHIDMediaMonitoring()
        eventTap = nil
        runLoopSource = nil
        recentMediaEventTimes.removeAll()
        recentHIDMediaEventTimes.removeAll()
        recentSystemMediaEventTimes.removeAll()
        recentTrustedKeyboardTopRowEvents.removeAll()
        modifierKeyStates.removeAll()
        callback = nil
    }

    private func startHIDMediaMonitoring() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let context = Unmanaged.passUnretained(self).toOpaque()

        let callback: IOHIDValueCallback = { context, _, _, value in
            guard let context else { return }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleHIDInputValue(value)
        }

        IOHIDManagerRegisterInputValueCallback(manager, callback, context)
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            KeyLightLog("HID fallback unavailable (open result: \(openResult))")
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return
        }

        hidManager = manager
    }

    private func stopHIDMediaMonitoring() {
        guard let manager = hidManager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = nil
    }

    private func handleSystemDefinedCGEvent(_ event: CGEvent) {
        guard let systemEvent = NSEvent(cgEvent: event) else { return }
        handleMediaKeyEvent(systemEvent)
    }

    private func handleFlagsChangedCGEvent(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == 57 {
            lastCapsLockTransitionTime = CFAbsoluteTimeGetCurrent()
        }
        guard let isKeyDown = resolveModifierFlagsChanged(keyCode: keyCode, flags: event.flags) else { return }
        if keyCode == 57 {
            emitCapsLockTransition(isKeyDown: isKeyDown)
            return
        }
        emitMappedKeyEvent(keyCode: keyCode, isKeyDown: isKeyDown)
    }

    private func handleMediaKeyEvent(_ event: NSEvent) {
        // Media keys arrive as system-defined subtype 8 events.
        guard event.subtype.rawValue == 8 else { return }

        let data1 = UInt32(truncatingIfNeeded: event.data1)
        let nxKeyCode = Int((data1 & 0xFFFF0000) >> 16)
        let keyState = Int((data1 & 0x0000FF00) >> 8)
        // Some keyboards emit 0x00 for key-down in system-defined events.
        let isKeyDown = (keyState == 0x0A || keyState == 0x00)
        let isKeyUp = (keyState == 0x0B)

        guard isKeyDown || isKeyUp else { return }
        let now = CFAbsoluteTimeGetCurrent()

        // Some keyboards report Caps Lock transitions through NX code 4.
        // Suppress those so they never masquerade as top-row media activity.
        if nxKeyCode == 4,
           lastCapsLockTransitionTime >= 0,
           now - lastCapsLockTransitionTime < capsLockSystemEventGuardWindow {
            return
        }

        guard let virtualKeyCode = resolveVirtualKeyCode(nxCode: nxKeyCode) else { return }
        emitMediaKeyEvent(keyCode: virtualKeyCode, isKeyDown: isKeyDown, source: .systemDefined)
    }

    private func handleHIDInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        guard usagePage == UInt32(kHIDPage_Consumer) else { return }

        let usage = IOHIDElementGetUsage(element)
        guard let virtualKeyCode = Self.hidConsumerUsageMap[usage] else { return }

        let isKeyDown = IOHIDValueGetIntegerValue(value) != 0
        emitMediaKeyEvent(keyCode: virtualKeyCode, isKeyDown: isKeyDown, source: .hid)
    }

    private func emitMediaKeyEvent(keyCode: UInt16, isKeyDown: Bool, source: MediaEventSource) {
        let now = CFAbsoluteTimeGetCurrent()
        if shouldDedupeMediaEvent(keyCode: keyCode, isKeyDown: isKeyDown, source: source, now: now) {
            return
        }

        emitMappedKeyEvent(keyCode: keyCode, isKeyDown: isKeyDown)
    }

    private func emitMappedKeyEvent(keyCode: UInt16, isKeyDown: Bool) {
        // HID callbacks are scheduled on the same run loop as the event tap.
        MainActor.assumeIsolated {
            let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
            let keyInfo = KeyMapping.keyInfo(for: canonicalKeyCode)
            let adjustedPosition = KeyPositionManager.shared.adjustedPosition(
                for: canonicalKeyCode,
                originalPosition: keyInfo.position
            )
            let effectiveKeyWidth = KeyWidthManager.shared.effectiveWidth(
                for: canonicalKeyCode,
                defaultWidth: keyInfo.width
            )

            callback?(KeyEvent(
                keyCode: canonicalKeyCode,
                isKeyDown: isKeyDown,
                horizontalPosition: adjustedPosition,
                keyWidth: effectiveKeyWidth
            ))
        }
    }

    private func emitCapsLockTransition(isKeyDown: Bool) {
        let keyCode: UInt16 = 57
        let sequence = capsLockEmitSequence(isKeyDown: isKeyDown)
        guard let first = sequence.first else { return }
        emitMappedKeyEvent(keyCode: keyCode, isKeyDown: first)

        if sequence.count > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + capsLockPulseDuration) { [weak self] in
                self?.emitMappedKeyEvent(keyCode: keyCode, isKeyDown: false)
            }
        }
    }

    private func capsLockEmitSequence(isKeyDown: Bool) -> [Bool] {
        isKeyDown ? [true, false] : [false]
    }

    private func shouldDedupeMediaEvent(
        keyCode: UInt16,
        isKeyDown: Bool,
        source: MediaEventSource,
        now: CFAbsoluteTime
    ) -> Bool {
        let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
        let dedupeKey = (UInt32(canonicalKeyCode) << 1) | (isKeyDown ? 1 : 0)

        if shouldSuppressMediaEventForRecentTrustedKeyboardTopRow(
            keyCode: canonicalKeyCode,
            isKeyDown: isKeyDown,
            now: now
        ) {
            return true
        }

        switch source {
        case .hid:
            if let lastHID = recentHIDMediaEventTimes[dedupeKey], now - lastHID < mediaDedupWindow {
                return true
            }
            recentHIDMediaEventTimes[dedupeKey] = now
        case .systemDefined:
            // Prefer HID media events if both sources report the same press/release in the dedupe window.
            if let lastHID = recentHIDMediaEventTimes[dedupeKey], now - lastHID < mediaDedupWindow {
                return true
            }
            if let lastSystem = recentSystemMediaEventTimes[dedupeKey], now - lastSystem < mediaDedupWindow {
                return true
            }
            recentSystemMediaEventTimes[dedupeKey] = now
        }

        recentMediaEventTimes[dedupeKey] = now
        if recentMediaEventTimes.count > 64 {
            recentMediaEventTimes = recentMediaEventTimes.filter { now - $0.value < mediaDedupWindow * 2 }
        }
        if recentHIDMediaEventTimes.count > 64 {
            recentHIDMediaEventTimes = recentHIDMediaEventTimes.filter { now - $0.value < mediaDedupWindow * 2 }
        }
        if recentSystemMediaEventTimes.count > 64 {
            recentSystemMediaEventTimes = recentSystemMediaEventTimes.filter { now - $0.value < mediaDedupWindow * 2 }
        }
        return false
    }

    private func resolveVirtualKeyCode(nxCode: Int) -> UInt16? {
        if Self.canonicalPreferredNXCodes.contains(nxCode) {
            return Self.canonicalNXMap[nxCode] ?? Self.legacyNXMap[nxCode]
        }

        return Self.canonicalNXMap[nxCode] ?? Self.legacyNXMap[nxCode]
    }

    private func resolveKeyboardEventKeyCode(rawKeyCode: UInt16, event: CGEvent) -> KeyboardResolution {
        let nsEvent = NSEvent(cgEvent: event)
        let characters = nsEvent?.charactersIgnoringModifiers
#if compiler(>=5.3)
        let specialKey = nsEvent?.specialKey
#else
        let specialKey: NSEvent.SpecialKey? = nil
#endif
        return resolveKeyboardEventKeyCode(
            rawKeyCode: rawKeyCode,
            charactersIgnoringModifiers: characters,
            specialKeyRawValue: specialKey?.rawValue
        )
    }

    private func resolveKeyboardEventKeyCode(
        rawKeyCode: UInt16,
        charactersIgnoringModifiers: String?,
        specialKeyRawValue: Int?
    ) -> KeyboardResolution {
        if isMappedKeyCode(rawKeyCode) {
            return KeyboardResolution(keyCode: rawKeyCode, confidence: .high)
        }

        if let specialKeyRawValue,
           let functionKeyCode = Self.specialKeyRawValueToFunctionKeyCode[specialKeyRawValue] {
            return KeyboardResolution(keyCode: functionKeyCode, confidence: .high)
        }

        if let scalar = charactersIgnoringModifiers?.unicodeScalars.first,
           let functionKeyCode = Self.functionCharacterToFunctionKeyCode[scalar.value] {
            return KeyboardResolution(keyCode: functionKeyCode, confidence: .high)
        }

        if let functionKeyCode = Self.trustedTopRowRawFunctionKeyCodeMap[rawKeyCode] {
            return KeyboardResolution(keyCode: functionKeyCode, confidence: .high)
        }

        return KeyboardResolution(keyCode: rawKeyCode, confidence: .unknown)
    }

    private func resolveModifierFlagsChanged(keyCode: UInt16, flags: CGEventFlags) -> Bool? {
        guard let mask = Self.modifierKeyFlagMaskByKeyCode[keyCode] else { return nil }
        let isKeyDownFromFlags = flags.contains(mask)
        let previous = modifierKeyStates[keyCode] ?? false

        if previous == isKeyDownFromFlags {
            // Shared masks (left/right command/option/control/shift): when one side is released
            // while the other side stays held, macOS keeps the mask set. Use counterpart state
            // to infer that this key transitioned to key-up.
            if previous,
               let counterpart = Self.modifierCounterpartKeyCode[keyCode],
               modifierKeyStates[counterpart] == true {
                modifierKeyStates[keyCode] = false
                return false
            }
            return nil
        }

        modifierKeyStates[keyCode] = isKeyDownFromFlags
        return isKeyDownFromFlags
    }

    private func isMappedKeyCode(_ keyCode: UInt16) -> Bool {
        MainActor.assumeIsolated {
            KeyMapping.hasMappedKeyCode(keyCode)
        }
    }

    private func isTopRowFunctionKeyCode(_ keyCode: UInt16) -> Bool {
        let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
        return Self.topRowFunctionKeyCodes.contains(canonicalKeyCode)
    }

    private func recordTrustedKeyboardTopRowEvent(keyCode: UInt16, isKeyDown: Bool) {
        let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
        recentTrustedKeyboardTopRowEvents[isKeyDown] = (canonicalKeyCode, CFAbsoluteTimeGetCurrent())
    }

    private func shouldSuppressMediaEventForRecentTrustedKeyboardTopRow(
        keyCode: UInt16,
        isKeyDown: Bool,
        now: CFAbsoluteTime
    ) -> Bool {
        guard Self.topRowFunctionKeyCodes.contains(keyCode) else { return false }
        guard let recent = recentTrustedKeyboardTopRowEvents[isKeyDown] else { return false }
        guard now - recent.timestamp <= keyboardTopRowSourceWindow else {
            recentTrustedKeyboardTopRowEvents.removeValue(forKey: isKeyDown)
            return false
        }

        // Prefer the trusted keyboard event for this press/release window.
        // This prevents mismatched NX/HID aliases from overriding the correct physical key.
        return true
    }

#if DEBUG
    func _testResolveVirtualKeyCode(nxCode: Int) -> UInt16? {
        resolveVirtualKeyCode(nxCode: nxCode)
    }

    func _testShouldDedupeMediaEvent(keyCode: UInt16, isKeyDown: Bool, now: CFAbsoluteTime) -> Bool {
        shouldDedupeMediaEvent(keyCode: keyCode, isKeyDown: isKeyDown, source: .systemDefined, now: now)
    }

    func _testShouldDedupeMediaEventWithSource(
        keyCode: UInt16,
        isKeyDown: Bool,
        source: String,
        now: CFAbsoluteTime
    ) -> Bool {
        let mappedSource: MediaEventSource = source == "hid" ? .hid : .systemDefined
        return shouldDedupeMediaEvent(keyCode: keyCode, isKeyDown: isKeyDown, source: mappedSource, now: now)
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

    func _testResolveModifierFlagsChanged(keyCode: UInt16, flags: CGEventFlags) -> Bool? {
        resolveModifierFlagsChanged(keyCode: keyCode, flags: flags)
    }

    func _testCapsLockEmitSequence(isKeyDown: Bool) -> [Bool] {
        capsLockEmitSequence(isKeyDown: isKeyDown)
    }
#endif

    deinit {
        stop()
    }
}
