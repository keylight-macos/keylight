import Foundation

/// Debug-only logging — completely stripped from Release builds.
/// SECURITY: Never log key codes, key events, or any keystroke-related data.
@inline(__always)
func KeyLightLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("KeyLight: \(message())")
    #endif
}
