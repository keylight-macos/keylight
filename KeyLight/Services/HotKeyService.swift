import Carbon.HIToolbox
import Foundation

struct GlobalShortcut: Codable, Equatable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let `default` = GlobalShortcut(
        uncheckedKeyCode: UInt32(kVK_ANSI_K),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    private static let allowedModifiers = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    init?(keyCode: UInt32, modifiers: UInt32) {
        let normalizedModifiers = modifiers & Self.allowedModifiers
        guard keyCode <= 255, normalizedModifiers != 0 else {
            return nil
        }
        self.keyCode = keyCode
        self.modifiers = normalizedModifiers
    }

    private init(uncheckedKeyCode: UInt32, modifiers: UInt32) {
        keyCode = uncheckedKeyCode
        self.modifiers = modifiers
    }

    var displayName: String {
        var result = ""
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        return result + Self.keyDisplayName(keyCode)
    }

    private static func keyDisplayName(_ keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B",
            UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D",
            UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
            UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J",
            UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N",
            UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P",
            UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
            UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V",
            UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1",
            UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
            UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7",
            UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space", UInt32(kVK_Tab): "⇥",
            UInt32(kVK_Return): "↩", UInt32(kVK_Escape): "⎋",
            UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
            UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2",
            UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
            UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10",
            UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
            UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
            UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
            UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
            UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Backslash): "\\",
            UInt32(kVK_ANSI_Grave): "`"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}

enum HotKeyRegistrationFailure: Error, Equatable, Sendable {
    case eventHandlerInstallationFailed(status: Int32)
    case hotKeyRegistrationFailed(status: Int32)
}

enum HotKeyServiceStatus: Equatable, Sendable {
    case stopped
    case registering
    case registered
    case unavailable(HotKeyRegistrationFailure)
}

@MainActor
protocol HotKeyRegistration: AnyObject {
    func unregister()
}

@MainActor
protocol HotKeyRegistering: AnyObject {
    func register(
        _ shortcut: GlobalShortcut,
        onPress: @escaping @MainActor @Sendable () -> Void
    ) -> Result<any HotKeyRegistration, HotKeyRegistrationFailure>
}

/// Owns KeyLight's one global shortcut and atomically replaces its Carbon
/// registration when the user records a different combination.
@MainActor
final class HotKeyService {
    private let registrar: any HotKeyRegistering
    private let onPress: @MainActor @Sendable () -> Void
    private let onStatusChange: @MainActor @Sendable (HotKeyServiceStatus) -> Void

    private var registration: (any HotKeyRegistration)?
    private var generation: UInt = 0
    private var shortcut: GlobalShortcut

    private(set) var status: HotKeyServiceStatus = .stopped

    init(
        registrar: any HotKeyRegistering = CarbonHotKeyRegistrar(),
        shortcut: GlobalShortcut = .default,
        onPress: @escaping @MainActor @Sendable () -> Void,
        onStatusChange: @escaping @MainActor @Sendable (HotKeyServiceStatus) -> Void = { _ in }
    ) {
        self.registrar = registrar
        self.shortcut = shortcut
        self.onPress = onPress
        self.onStatusChange = onStatusChange
    }

    /// Starts registration once. Calling start while registered is a no-op;
    /// calling it after a failure performs an explicit retry.
    func start() {
        guard registration == nil, status != .registering else { return }

        generation &+= 1
        let attemptGeneration = generation
        updateStatus(.registering)

        let result = registrar.register(shortcut) { [weak self] in
            guard let self,
                  self.generation == attemptGeneration,
                  self.registration != nil else {
                return
            }
            self.onPress()
        }

        switch result {
        case .success(let newRegistration):
            guard generation == attemptGeneration, status == .registering else {
                newRegistration.unregister()
                return
            }
            registration = newRegistration
            updateStatus(.registered)
        case .failure(let failure):
            guard generation == attemptGeneration, status == .registering else {
                return
            }
            updateStatus(.unavailable(failure))
        }
    }

    /// Unregisters all Carbon resources exactly once and invalidates callbacks
    /// retained by an old registration.
    func stop() {
        guard registration != nil || status != .stopped else { return }

        generation &+= 1
        let existingRegistration = registration
        registration = nil
        existingRegistration?.unregister()
        updateStatus(.stopped)
    }

    func setShortcut(_ shortcut: GlobalShortcut) {
        guard shortcut != self.shortcut else { return }
        let shouldRestart = status != .stopped
        if shouldRestart {
            stop()
        }
        self.shortcut = shortcut
        if shouldRestart {
            start()
        }
    }

    private func updateStatus(_ next: HotKeyServiceStatus) {
        guard status != next else { return }
        status = next
        onStatusChange(next)
    }
}

@MainActor
private final class CarbonHotKeyRegistrar: HotKeyRegistering {
    private static let signature = OSType(0x4B4C4754) // "KLGT"
    private static let identifier: UInt32 = 1

    func register(
        _ shortcut: GlobalShortcut,
        onPress: @escaping @MainActor @Sendable () -> Void
    ) -> Result<any HotKeyRegistration, HotKeyRegistrationFailure> {
        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.identifier
        )
        let callbackBox = CarbonHotKeyCallbackBox(
            hotKeyID: hotKeyID,
            onPress: onPress
        )
        let retainedCallbackBox = Unmanaged.passRetained(callbackBox)

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var eventHandler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            keyLightCarbonHotKeyHandler,
            1,
            &eventType,
            retainedCallbackBox.toOpaque(),
            &eventHandler
        )

        guard handlerStatus == noErr, let eventHandler else {
            retainedCallbackBox.release()
            return .failure(.eventHandlerInstallationFailed(
                status: handlerStatus == noErr ? Int32(paramErr) : Int32(handlerStatus)
            ))
        }

        var hotKey: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )

        guard registrationStatus == noErr, let hotKey else {
            RemoveEventHandler(eventHandler)
            retainedCallbackBox.release()
            return .failure(.hotKeyRegistrationFailed(
                status: registrationStatus == noErr ? Int32(paramErr) : Int32(registrationStatus)
            ))
        }

        return .success(CarbonHotKeyRegistration(
            hotKey: hotKey,
            eventHandler: eventHandler,
            retainedCallbackBox: retainedCallbackBox
        ))
    }
}

private final class CarbonHotKeyCallbackBox: @unchecked Sendable {
    let hotKeyID: EventHotKeyID
    let onPress: @MainActor @Sendable () -> Void

    init(
        hotKeyID: EventHotKeyID,
        onPress: @escaping @MainActor @Sendable () -> Void
    ) {
        self.hotKeyID = hotKeyID
        self.onPress = onPress
    }

    func dispatchPress() {
        Task { @MainActor [onPress] in
            onPress()
        }
    }
}

private let keyLightCarbonHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    let callbackBox = Unmanaged<CarbonHotKeyCallbackBox>
        .fromOpaque(userData)
        .takeUnretainedValue()
    var receivedID = EventHotKeyID()
    let parameterStatus = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &receivedID
    )

    guard parameterStatus == noErr,
          receivedID.signature == callbackBox.hotKeyID.signature,
          receivedID.id == callbackBox.hotKeyID.id else {
        return OSStatus(eventNotHandledErr)
    }

    callbackBox.dispatchPress()
    return noErr
}

@MainActor
private final class CarbonHotKeyRegistration: HotKeyRegistration {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var retainedCallbackBox: Unmanaged<CarbonHotKeyCallbackBox>?

    init(
        hotKey: EventHotKeyRef,
        eventHandler: EventHandlerRef,
        retainedCallbackBox: Unmanaged<CarbonHotKeyCallbackBox>
    ) {
        self.hotKey = hotKey
        self.eventHandler = eventHandler
        self.retainedCallbackBox = retainedCallbackBox
    }

    func unregister() {
        guard hotKey != nil || eventHandler != nil || retainedCallbackBox != nil else {
            return
        }

        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        retainedCallbackBox?.release()
        retainedCallbackBox = nil
    }
}
