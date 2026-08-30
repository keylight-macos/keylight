import Foundation
import OSLog

/// Privacy-safe unified loggers. Never log key codes, key events, typed text,
/// or any other keystroke-derived data.
enum KeyLightLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.keylight.app"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let permissions = Logger(subsystem: subsystem, category: "Permissions")
    static let keyboardMonitor = Logger(subsystem: subsystem, category: "KeyboardMonitor")
    static let display = Logger(subsystem: subsystem, category: "Display")
    static let renderer = Logger(subsystem: subsystem, category: "Renderer")
    static let storage = Logger(subsystem: subsystem, category: "Storage")
    static let imports = Logger(subsystem: subsystem, category: "Import")
    static let recovery = Logger(subsystem: subsystem, category: "Recovery")
}

/// Local Instruments markers for the latency pipeline. They carry only an
/// anonymous, process-local sequence number and are absent from Release builds.
/// Never add key codes, characters, geometry, captured content, or file paths.
enum KeyLightSignposts {
    #if DEBUG
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.keylight.app",
        category: "Latency"
    )

    static func eventReceived(sequence: UInt64) {
        os_signpost(.event, log: log, name: "Event Received", "sequence=%{public}llu", sequence)
    }

    static func eventNormalized(sequence: UInt64) {
        os_signpost(.event, log: log, name: "Event Normalized", "sequence=%{public}llu", sequence)
    }

    static func normalizedEventDispatched(sequence: UInt64) {
        os_signpost(.event, log: log, name: "Normalized Event Dispatched", "sequence=%{public}llu", sequence)
    }

    static func overlayStateUpdated(sequence: UInt64) {
        os_signpost(.event, log: log, name: "Overlay State Updated", "sequence=%{public}llu", sequence)
    }

    static func rendererSubmitted(sequence: UInt64) {
        os_signpost(.event, log: log, name: "Renderer Submitted", "sequence=%{public}llu", sequence)
    }

    static func captureStarted() {
        os_signpost(.event, log: log, name: "Capture Started")
    }

    static func captureStopped() {
        os_signpost(.event, log: log, name: "Capture Stopped")
    }

    static func framePresented(sequence: UInt64) {
        os_signpost(.event, log: log, name: "Capture Frame Presented", "sequence=%{public}llu", sequence)
    }

    static func frameDropped(sequence: UInt64) {
        os_signpost(.event, log: log, name: "Capture Frame Dropped", "sequence=%{public}llu", sequence)
    }
    #else
    static func eventReceived(sequence: UInt64) {}
    static func eventNormalized(sequence: UInt64) {}
    static func normalizedEventDispatched(sequence: UInt64) {}
    static func overlayStateUpdated(sequence: UInt64) {}
    static func rendererSubmitted(sequence: UInt64) {}
    static func captureStarted() {}
    static func captureStopped() {}
    static func framePresented(sequence: UInt64) {}
    static func frameDropped(sequence: UInt64) {}
    #endif
}
