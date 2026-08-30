import Foundation
import ApplicationServices
import AppKit

enum InputMonitoringReconciliationAction: Equatable {
    case requestPermission
    case settle(state: InputMonitoringState, stopMonitor: Bool)
    case startMonitor(stopExisting: Bool)
}

enum InputMonitoringReconciliationResolver {
    static func resolve(
        installationIssue: String?,
        authorized: Bool,
        allowRequest: Bool,
        isEnabled: Bool,
        monitorExists: Bool,
        monitorRunning: Bool
    ) -> InputMonitoringReconciliationAction {
        guard authorized else {
            // `allowRequest` represents a deliberate user action in Setup or
            // recovery UI. Consent is independent of whether the visual effect
            // is currently enabled; authorization must not implicitly enable
            // or start the keyboard monitor.
            if allowRequest && installationIssue == nil {
                return .requestPermission
            }
            return .settle(state: .permissionRequired, stopMonitor: monitorExists)
        }

        guard isEnabled else {
            return .settle(state: .authorized, stopMonitor: monitorExists)
        }

        if monitorExists && monitorRunning {
            return .settle(state: .active, stopMonitor: false)
        }

        return .startMonitor(stopExisting: monitorExists)
    }

    static func stateAfterMonitorStart(succeeded: Bool) -> InputMonitoringState {
        succeeded ? .active : .monitorUnavailable
    }
}

@MainActor
final class PermissionManager {
    init() {}

    var runningApplicationPath: String {
        Bundle.main.bundleURL.standardizedFileURL.path
    }

    /// TCC grants must be made to the installed, canonically named app rather
    /// than a copy still mounted in a DMG or renamed by Finder during copying.
    var installationIssue: String? {
        Self.installationIssue(
            for: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.keylight.app",
            expectedBundleName: KeyLightApplicationIdentity.bundleName
        )
    }

    static func installationIssue(
        for bundleURL: URL,
        bundleIdentifier: String = "com.keylight.app",
        expectedBundleName: String = "KeyLight.app"
    ) -> String? {
        let standardizedURL = bundleURL.standardizedFileURL
        let path = standardizedURL.path
        let canonicalBundleName = expectedBundleName.hasSuffix(".app")
            ? expectedBundleName
            : "\(expectedBundleName).app"
        let productName = String(canonicalBundleName.dropLast(4))
        if path == "/Volumes" || path.hasPrefix("/Volumes/") {
            return "\(productName) is running from a disk image. Move it to /Applications/\(canonicalBundleName) before granting Input Monitoring."
        }

        let bundleName = standardizedURL.lastPathComponent
        if bundleName != canonicalBundleName {
            return "\(productName) must be named \(canonicalBundleName) before granting Input Monitoring. The current app is named \(bundleName)."
        }

        // Debug builds use their own bundle identifier so local development
        // cannot alter the production app's TCC record. Production permission
        // requests are restricted to the one canonical installation path.
        if bundleIdentifier == "com.keylight.app.debug" {
            return nil
        }

        let canonicalURL = URL(fileURLWithPath: "/Applications/\(canonicalBundleName)").standardizedFileURL
        if standardizedURL != canonicalURL {
            return "\(productName) must run from /Applications/\(canonicalBundleName) before granting Input Monitoring. The current copy is at \(path)."
        }

        return nil
    }

    /// Check if we have Input Monitoring permission
    func hasInputMonitoringPermission() -> Bool {
        let authorized = CGPreflightListenEventAccess()
        KeyLightLogger.permissions.debug("Input Monitoring preflight result: \(authorized, privacy: .public)")
        return authorized
    }

    /// Request Input Monitoring permission (shows system dialog if not granted)
    @discardableResult
    func requestInputMonitoringPermission() -> Bool {
        if installationIssue != nil {
            KeyLightLogger.permissions.notice("Input Monitoring request blocked by the installation guard")
            return false
        }

        if CGPreflightListenEventAccess() {
            KeyLightLogger.permissions.debug("Input Monitoring request skipped because access is already authorized")
            return true
        }

        KeyLightLogger.permissions.notice("Requesting Input Monitoring access")
        let authorized = CGRequestListenEventAccess()
        KeyLightLogger.permissions.notice("Input Monitoring request result: \(authorized, privacy: .public)")
        return authorized
    }

    /// Open System Settings to Input Monitoring pane
    func openInputMonitoringSettings() {
        KeyLightLogger.permissions.notice("Opening Input Monitoring settings")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
