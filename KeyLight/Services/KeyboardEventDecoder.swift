import Foundation

/// Privacy-safe platform event metadata emitted after decoding. Geometry is
/// resolved later from the live layout; characters never leave decoding.
struct KeyEvent: Sendable {
    let keyCode: UInt16
    let isKeyDown: Bool
    let isRepeat: Bool
    let source: KeyboardEvent.Source
    let sequence: UInt64

    init(
        keyCode: UInt16,
        isKeyDown: Bool,
        isRepeat: Bool,
        source: KeyboardEvent.Source = .eventTap,
        sequence: UInt64 = 0
    ) {
        self.keyCode = keyCode
        self.isKeyDown = isKeyDown
        self.isRepeat = isKeyDown && isRepeat
        self.source = source
        self.sequence = sequence
    }
}

/// Deterministic keyboard decoding and source-deduplication state. This type
/// deliberately has no event-tap, HID, run-loop, permission, or rendering
/// ownership so fixtures can exercise the complete normalization policy.
struct KeyboardEventDecoder: Sendable {
    enum MediaEventSource: Sendable {
        case systemDefined
        case hid
    }

    enum ResolutionConfidence: Equatable, Sendable {
        case high
        case unknown
    }

    struct KeyboardResolution: Equatable, Sendable {
        let keyCode: UInt16
        let confidence: ResolutionConfidence
    }

    struct MediaTransition: Equatable, Sendable {
        let keyCode: UInt16
        let isKeyDown: Bool
    }

    private var recentMediaEventTimes: [UInt32: TimeInterval] = [:]
    private var recentHIDMediaEventTimes: [UInt32: TimeInterval] = [:]
    private var recentSystemMediaEventTimes: [UInt32: TimeInterval] = [:]
    private var recentTrustedKeyboardTopRowEvents: [Bool: (keyCode: UInt16, timestamp: TimeInterval)] = [:]
    private var modifierKeyStates: [UInt16: Bool] = [:]
    private var lastCapsLockTransitionTime: TimeInterval = -1

    private let mediaDedupWindow: TimeInterval = 0.03
    private let keyboardTopRowSourceWindow: TimeInterval = 0.04
    private let capsLockSystemEventGuardWindow: TimeInterval = 0.08

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
        19: 517,  // NX_KEYTYPE_FAST
        20: 506,  // NX_KEYTYPE_REWIND
        7: 518,   // NX_KEYTYPE_MUTE
        1: 519,   // NX_KEYTYPE_SOUND_DOWN
        0: 520,   // NX_KEYTYPE_SOUND_UP
    ]
    private static let canonicalPreferredNXCodes: Set<Int> = [0, 1, 2, 3, 7, 16, 17, 18, 19, 20]

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    private static let modifierCounterpartKeyCode: [UInt16: UInt16] = [
        55: 54,
        54: 55,
        58: 61,
        61: 58,
        59: 62,
        62: 59,
        56: 60,
        60: 56,
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
        0xF70F: 111, // F12
    ]

    // NSEvent.SpecialKey F1...F12 use the same stable function-key scalar
    // values. Keeping the raw fixture boundary here avoids importing AppKit.
    private static let specialKeyRawValueToFunctionKeyCode: [Int: UInt16] = [
        0xF704: 122,
        0xF705: 120,
        0xF706: 99,
        0xF707: 118,
        0xF708: 96,
        0xF709: 97,
        0xF70A: 98,
        0xF70B: 100,
        0xF70C: 101,
        0xF70D: 109,
        0xF70E: 103,
        0xF70F: 111,
    ]

    // Trusted raw keyboard codes observed on media-mode top-row keys. These
    // are used only when special-key/scalar metadata is absent.
    private static let trustedTopRowRawFunctionKeyCodeMap: [UInt16: UInt16] = [
        145: 122, // F1
        144: 120, // F2
        160: 99,  // F3
        131: 118, // F4
        177: 96,  // F5
        176: 97,  // F6
        178: 97,  // F6 Do Not Disturb on newer Apple keyboards
        173: 98,  // F7
        174: 100, // F8
        175: 101, // F9
        74: 109,  // F10
        73: 103,  // F11
        72: 111,  // F12
    ]

    private static let topRowFunctionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
    ]

    mutating func reset() {
        recentMediaEventTimes.removeAll()
        recentHIDMediaEventTimes.removeAll()
        recentSystemMediaEventTimes.removeAll()
        recentTrustedKeyboardTopRowEvents.removeAll()
        modifierKeyStates.removeAll()
        lastCapsLockTransitionTime = -1
    }

    func resolveVirtualKeyCode(nxCode: Int) -> UInt16? {
        if Self.canonicalPreferredNXCodes.contains(nxCode) {
            return Self.canonicalNXMap[nxCode] ?? Self.legacyNXMap[nxCode]
        }
        return Self.canonicalNXMap[nxCode] ?? Self.legacyNXMap[nxCode]
    }

    func resolveKeyboardEvent(
        rawKeyCode: UInt16,
        charactersIgnoringModifiers: String?,
        specialKeyRawValue: Int?,
        isMappedKeyCode: Bool
    ) -> KeyboardResolution {
        if isMappedKeyCode {
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

    func decodeKeyboardEvent(
        rawKeyCode: UInt16,
        isKeyDown: Bool,
        isRepeat: Bool,
        source: KeyboardEvent.Source = .eventTap,
        charactersIgnoringModifiers: String?,
        specialKeyRawValue: Int?,
        isMappedKeyCode: Bool
    ) -> KeyEvent? {
        let resolution = resolveKeyboardEvent(
            rawKeyCode: rawKeyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            specialKeyRawValue: specialKeyRawValue,
            isMappedKeyCode: isMappedKeyCode
        )
        guard resolution.confidence == .high else { return nil }
        return KeyEvent(
            keyCode: resolution.keyCode,
            isKeyDown: isKeyDown,
            isRepeat: isRepeat,
            source: source
        )
    }

    mutating func resolveModifierFlagsChanged(keyCode: UInt16, flagIsSet: Bool) -> Bool? {
        guard Self.modifierKeyCodes.contains(keyCode) else { return nil }
        let previous = modifierKeyStates[keyCode] ?? false

        if previous == flagIsSet {
            // Shared masks retain the flag while the opposite side remains
            // held, so infer this key's release from counterpart state.
            if previous,
               let counterpart = Self.modifierCounterpartKeyCode[keyCode],
               modifierKeyStates[counterpart] == true {
                modifierKeyStates[keyCode] = false
                return false
            }
            return nil
        }

        modifierKeyStates[keyCode] = flagIsSet
        return flagIsSet
    }

    mutating func recordCapsLockTransition(at timestamp: TimeInterval) {
        lastCapsLockTransitionTime = timestamp
    }

    func capsLockEmitSequence(isKeyDown: Bool) -> [Bool] {
        isKeyDown ? [true, false] : [false]
    }

    func decodeSystemDefinedMediaEvent(
        subtypeRawValue: Int,
        data1: UInt32,
        now: TimeInterval
    ) -> MediaTransition? {
        guard subtypeRawValue == 8 else { return nil }

        let nxKeyCode = Int((data1 & 0xFFFF0000) >> 16)
        let keyState = Int((data1 & 0x0000FF00) >> 8)
        let isKeyDown = keyState == 0x0A || keyState == 0x00
        let isKeyUp = keyState == 0x0B
        guard isKeyDown || isKeyUp else { return nil }

        // Some keyboards report Caps Lock through NX code 4 immediately after
        // the real flags event. It must never masquerade as top-row activity.
        if nxKeyCode == 4,
           lastCapsLockTransitionTime >= 0,
           now - lastCapsLockTransitionTime < capsLockSystemEventGuardWindow {
            return nil
        }

        guard let virtualKeyCode = resolveVirtualKeyCode(nxCode: nxKeyCode) else { return nil }
        return MediaTransition(keyCode: virtualKeyCode, isKeyDown: isKeyDown)
    }

    mutating func recordTrustedKeyboardTopRowEvent(
        canonicalKeyCode: UInt16,
        isKeyDown: Bool,
        now: TimeInterval
    ) {
        guard Self.topRowFunctionKeyCodes.contains(canonicalKeyCode) else { return }
        recentTrustedKeyboardTopRowEvents[isKeyDown] = (canonicalKeyCode, now)
    }

    mutating func shouldDedupeMediaEvent(
        canonicalKeyCode: UInt16,
        isKeyDown: Bool,
        source: MediaEventSource,
        now: TimeInterval
    ) -> Bool {
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
            // Prefer HID if both sources report the same transition.
            if let lastHID = recentHIDMediaEventTimes[dedupeKey], now - lastHID < mediaDedupWindow {
                return true
            }
            if let lastSystem = recentSystemMediaEventTimes[dedupeKey], now - lastSystem < mediaDedupWindow {
                return true
            }
            recentSystemMediaEventTimes[dedupeKey] = now
        }

        recentMediaEventTimes[dedupeKey] = now
        pruneMediaHistory(now: now)
        return false
    }

    private mutating func shouldSuppressMediaEventForRecentTrustedKeyboardTopRow(
        keyCode: UInt16,
        isKeyDown: Bool,
        now: TimeInterval
    ) -> Bool {
        guard Self.topRowFunctionKeyCodes.contains(keyCode) else { return false }
        guard let recent = recentTrustedKeyboardTopRowEvents[isKeyDown] else { return false }
        guard now - recent.timestamp <= keyboardTopRowSourceWindow else {
            recentTrustedKeyboardTopRowEvents.removeValue(forKey: isKeyDown)
            return false
        }

        // Preserve the trusted keyboard transition over mismatched NX/HID
        // aliases reported for the same physical press/release window.
        return true
    }

    private mutating func pruneMediaHistory(now: TimeInterval) {
        if recentMediaEventTimes.count > 64 {
            recentMediaEventTimes = recentMediaEventTimes.filter {
                now - $0.value < mediaDedupWindow * 2
            }
        }
        if recentHIDMediaEventTimes.count > 64 {
            recentHIDMediaEventTimes = recentHIDMediaEventTimes.filter {
                now - $0.value < mediaDedupWindow * 2
            }
        }
        if recentSystemMediaEventTimes.count > 64 {
            recentSystemMediaEventTimes = recentSystemMediaEventTimes.filter {
                now - $0.value < mediaDedupWindow * 2
            }
        }
    }
}
