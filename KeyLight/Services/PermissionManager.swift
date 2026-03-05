import Foundation
import ApplicationServices
import AppKit

@MainActor
final class PermissionManager {
    static let shared = PermissionManager()

    private init() {}

    /// Check if we have Input Monitoring permission
    func hasInputMonitoringPermission() -> Bool {
        return CGPreflightListenEventAccess()
    }

    /// Request Input Monitoring permission (shows system dialog if not granted)
    func requestInputMonitoringPermission() {
        if !hasInputMonitoringPermission() {
            CGRequestListenEventAccess()
        }
    }

    /// Open System Settings to Input Monitoring pane
    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
