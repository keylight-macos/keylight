import Foundation
import ServiceManagement

/// The current state reported by macOS for KeyLight's main-app login item.
/// `enabled` is the only state treated as an active login item.
enum LaunchAtLoginStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    var isEnabled: Bool {
        self == .enabled
    }
}

enum LaunchAtLoginOperationFailure: Equatable, Sendable {
    case registrationFailed
    case unregistrationFailed
}

enum LaunchAtLoginChangeOutcome: Equatable, Sendable {
    case applied
    case requiresApproval
    case rejected
    case failed(LaunchAtLoginOperationFailure)
}

/// The result of a requested change, including the authoritative state read
/// back from macOS after the operation completes or fails.
struct LaunchAtLoginChangeResult: Equatable, Sendable {
    let requestedEnabled: Bool
    let status: LaunchAtLoginStatus
    let outcome: LaunchAtLoginChangeOutcome

    var isApplied: Bool {
        outcome == .applied
    }
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> LaunchAtLoginChangeResult
}

@MainActor
protocol LaunchAtLoginSystemClient: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

/// Owns launch-at-login reconciliation without treating a requested value as
/// saved state. Every result is based on the service status read back from
/// macOS, including thrown operations and approval-required states.
@MainActor
final class LaunchAtLoginService: LaunchAtLoginServicing {
    private let systemClient: any LaunchAtLoginSystemClient

    var status: LaunchAtLoginStatus {
        systemClient.status
    }

    init(systemClient: any LaunchAtLoginSystemClient = SMAppServiceSystemClient()) {
        self.systemClient = systemClient
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> LaunchAtLoginChangeResult {
        let initialStatus = systemClient.status
        if initialStatus == .requiresApproval, enabled {
            return LaunchAtLoginChangeResult(
                requestedEnabled: true,
                status: .requiresApproval,
                outcome: .requiresApproval
            )
        }
        let isAlreadySatisfied = (initialStatus == .enabled && enabled) ||
            (initialStatus == .disabled && !enabled)
        if isAlreadySatisfied {
            return LaunchAtLoginChangeResult(
                requestedEnabled: enabled,
                status: initialStatus,
                outcome: .applied
            )
        }

        do {
            if enabled {
                try systemClient.register()
            } else {
                try systemClient.unregister()
            }
        } catch {
            return LaunchAtLoginChangeResult(
                requestedEnabled: enabled,
                status: systemClient.status,
                outcome: .failed(enabled ? .registrationFailed : .unregistrationFailed)
            )
        }

        let actualStatus = systemClient.status
        let outcome: LaunchAtLoginChangeOutcome
        if actualStatus == .requiresApproval {
            outcome = .requiresApproval
        } else if actualStatus.isEnabled == enabled,
                  actualStatus != .unavailable {
            outcome = .applied
        } else {
            outcome = .rejected
        }

        return LaunchAtLoginChangeResult(
            requestedEnabled: enabled,
            status: actualStatus,
            outcome: outcome
        )
    }
}

@MainActor
private final class SMAppServiceSystemClient: LaunchAtLoginSystemClient {
    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
