import AppKit

/// The smallest AppKit bridge in KeyLight: NSApplication lifecycle enters the
/// runtime coordinator here, while SwiftUI scenes read the coordinator's model.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings: SettingsManager
    private let layoutStore: KeyLayoutStore
    private let updater: UpdateService
    private let coordinator: AppCoordinator

    override init() {
        let preferences: PreferencesStore
        #if DEBUG
        if KeyLightDebugLaunchConfiguration.isEnabled,
           let defaults = UserDefaults(
            suiteName: KeyLightDebugLaunchConfiguration.defaultsSuiteName
           ) {
            defaults.removePersistentDomain(
                forName: KeyLightDebugLaunchConfiguration.defaultsSuiteName
            )
            preferences = PreferencesStore(userDefaults: defaults)
        } else {
            preferences = .standard
        }
        #else
        preferences = .standard
        #endif
        let settings = SettingsManager(preferencesStore: preferences)
        let layoutStore = KeyLayoutStore(
            preferencesStore: preferences,
            settingsManager: settings
        )
        let model = KeyLightModel(settings: settings)
        let updater = UpdateService()

        #if DEBUG
        if let requestedEffect = KeyLightDebugLaunchConfiguration.effectStyle {
            model.effectStyle = requestedEffect
        }
        #endif

        let coordinator: AppCoordinator
        #if DEBUG
        if KeyLightDebugLaunchConfiguration.isEnabled {
            coordinator = AppCoordinator(
                model: model,
                keyLayoutStore: layoutStore,
                inputControllerFactory: { _, onStatus in
                    DebugInputController(onStatusChange: onStatus)
                }
            )
        } else {
            coordinator = AppCoordinator(
                model: model,
                keyLayoutStore: layoutStore
            )
        }
        #else
        coordinator = AppCoordinator(
            model: model,
            keyLayoutStore: layoutStore
        )
        #endif

        self.settings = settings
        self.layoutStore = layoutStore
        self.updater = updater
        self.coordinator = coordinator
        super.init()
    }

    var appState: KeyLightModel {
        coordinator.model
    }

    var settingsManager: SettingsManager {
        settings
    }

    var keyLayoutStore: KeyLayoutStore {
        layoutStore
    }

    var updateService: UpdateService {
        updater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Packaging launches the staged executable once to prove that dyld,
        // embedded frameworks, the hardened-runtime signature, and the app
        // entry point are mutually compatible. Exit before monitoring,
        // capture, updater startup, or user-interface presentation so this
        // verification cannot touch permissions or persisted state.
        if ProcessInfo.processInfo.environment[
            "KEYLIGHT_PACKAGE_LAUNCH_SMOKE_TEST"
        ] == "1" {
            NSApp.terminate(nil)
            return
        }

        coordinator.start()
        updater.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }
}

#if DEBUG
enum KeyLightDebugLaunchConfiguration {
    static let defaultsSuiteName = "com.keylight.ui-baseline"
    private static let environment = ProcessInfo.processInfo.environment

    static var isEnabled: Bool {
        environment["KEYLIGHT_UI_TEST_MODE"] == "1"
    }

    static var requestedScene: String? {
        guard isEnabled else { return nil }
        return environment["KEYLIGHT_UI_TEST_SCENE"]?.lowercased()
            ?? "settings"
    }

    static var effectStyle: EffectStyle? {
        guard isEnabled,
              let raw = environment["KEYLIGHT_UI_TEST_EFFECT"] else {
            return nil
        }
        return EffectStyle(rawValue: raw)
    }
}

@MainActor
private final class DebugInputController: AppCoordinatorInputControlling {
    private let onStatusChange: @MainActor (InputControllerStatus) -> Void
    private var enabled = false

    init(
        onStatusChange: @escaping @MainActor (InputControllerStatus) -> Void
    ) {
        self.onStatusChange = onStatusChange
    }

    func start(isEnabled: Bool) {
        enabled = isEnabled
        publish()
    }

    func stop() {}

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        publish()
    }

    func applicationDidBecomeActive() { publish() }
    func handleSleep() {}
    func handleWake() { publish() }
    func requestPermission() { publish() }
    func retry() { publish() }
    func openInputMonitoringSettings() {}

    private func publish() {
        onStatusChange(InputControllerStatus(
            state: enabled ? .active : .authorized,
            runningApplicationPath: "/Applications/KeyLight Motion Preview.app",
            installationIssue: nil,
            lastKnownAuthorization: true,
            monitorRunning: enabled,
            recheckInterval: nil
        ))
    }
}
#endif
