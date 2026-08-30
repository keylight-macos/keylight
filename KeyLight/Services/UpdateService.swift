import Foundation
import Observation
import Sparkle

enum UpdateAvailabilityState: Equatable, Sendable {
    case unavailableConfiguration
    case ready
    case checking
    case upToDate
    case updateAvailable(version: String)
    case failed

    var displayName: String {
        switch self {
        case .unavailableConfiguration:
            return String(localized: "Unavailable in This Build")
        case .ready:
            return String(localized: "Ready")
        case .checking:
            return String(localized: "Checking…")
        case .upToDate:
            return String(localized: "Up to Date")
        case .updateAvailable(let version):
            return String(localized: "Version \(version) Available")
        case .failed:
            return String(localized: "Check Failed")
        }
    }
}

/// Testable boundary around Sparkle. The service never creates a request until
/// `start()` has validated an HTTPS feed and a non-empty EdDSA public key.
/// Automatic checks are initially disabled by Info.plist and change only in
/// response to the explicit settings/onboarding toggle.
@MainActor
protocol UpdateServicing: AnyObject {
    var status: UpdateAvailabilityState { get }
    var isConfigured: Bool { get }
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }

    func start()
    func checkForUpdates()
}

@MainActor
@Observable
final class UpdateService: NSObject, UpdateServicing {
    private static let automaticConsentKey =
        "KeyLightUpdateAutomaticChecksExplicitlyEnabled"

    private(set) var status: UpdateAvailabilityState = .unavailableConfiguration
    private(set) var isConfigured = false
    private var hasStarted = false

    @ObservationIgnored
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    var canCheckForUpdates: Bool {
        hasStarted && updaterController.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            guard isConfigured,
                  UserDefaults.standard.bool(
                    forKey: Self.automaticConsentKey
                  ) else { return false }
            return updaterController.updater.automaticallyChecksForUpdates
        }
        set {
            guard isConfigured else { return }
            UserDefaults.standard.set(
                newValue,
                forKey: Self.automaticConsentKey
            )
            updaterController.updater.automaticallyChecksForUpdates = newValue
            if status == .unavailableConfiguration {
                status = .ready
            }
        }
    }

    override init() {
        super.init()
        isConfigured = Self.hasSecureConfiguration(in: .main)
        status = isConfigured ? .ready : .unavailableConfiguration
    }

    func start() {
        guard isConfigured, !hasStarted else { return }
        let updater = updaterController.updater
        if !UserDefaults.standard.bool(forKey: Self.automaticConsentKey) {
            updater.automaticallyChecksForUpdates = false
        }
        // Fail closed even if stale Sparkle defaults from a beta or manual
        // defaults edit attempted to enable profiling or silent downloads.
        updater.sendsSystemProfile = false
        updater.automaticallyDownloadsUpdates = false
        hasStarted = true
        updaterController.startUpdater()
        status = .ready
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        status = .checking
        updaterController.checkForUpdates(nil)
    }

    func eraseLocalUpdatePreferences() {
        automaticallyChecksForUpdates = false
        let keys = [
            "SULastCheckTime",
            "SULastProfileSubmitDate",
            "SUSkippedVersion",
            "SUEnableAutomaticChecks",
            "SUAutomaticallyUpdate",
            "SUSendProfileInfo",
            Self.automaticConsentKey
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        status = isConfigured ? .ready : .unavailableConfiguration
    }

    nonisolated static func hasSecureConfiguration(in bundle: Bundle) -> Bool {
        hasSecureConfiguration(
            feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(
                forInfoDictionaryKey: "SUPublicEDKey"
            ) as? String
        )
    }

    nonisolated static func hasSecureConfiguration(
        feed: String?,
        publicKey: String?
    ) -> Bool {
        guard let feed,
              let feedURL = URL(string: feed),
              feedURL.scheme?.lowercased() == "https",
              feedURL.host != nil,
              feedURL.user == nil,
              feedURL.password == nil,
              let publicKey,
              let publicKeyData = Data(
                base64Encoded: publicKey.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
              ),
              publicKeyData.count == 32 else {
            return false
        }
        return true
    }
}

extension UpdateService: SPUUpdaterDelegate {
    func feedParameters(
        for updater: SPUUpdater,
        sendingSystemProfile sendingProfile: Bool
    ) -> [[String: String]] {
        // Do not append custom identifiers or profile fields to the appcast.
        []
    }

    func updater(
        _ updater: SPUUpdater,
        didFindValidUpdate item: SUAppcastItem
    ) {
        status = .updateAvailable(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status = .upToDate
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        status = .failed
    }
}
