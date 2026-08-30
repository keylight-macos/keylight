//
//  KeyLightApp.swift
//  KeyLight
//

import SwiftUI
import AppKit

@main
struct KeyLightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let applicationName = KeyLightApplicationIdentity.displayName

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenuView(model: appDelegate.appState)
        } label: {
            MenuBarLabel(model: appDelegate.appState)
                #if DEBUG
                .background {
                    DebugLaunchSceneRouter()
                }
                #endif
        }

        Settings {
            SettingsView(
                model: appDelegate.appState,
                settings: appDelegate.settingsManager,
                keyLayoutStore: appDelegate.keyLayoutStore,
                updateService: appDelegate.updateService
            )
            .background(
                KeyLightWindowBridge(identifier: .settings)
            )
        }

        Window("Keyboard Calibration", id: KeyLightSceneID.keyEditor) {
            KeyPositionEditorSceneRoot(
                model: appDelegate.appState,
                layoutStore: appDelegate.keyLayoutStore
            )
            .background(
                KeyLightWindowBridge(
                    identifier: .keyEditor,
                    consumesUnmodifiedSpace: true
                )
            )
        }
        .defaultSize(width: 1_050, height: 460)
        .windowResizability(.contentMinSize)

        Window("Guided Keyboard Calibration", id: KeyLightSceneID.guidedCalibration) {
            GuidedCalibrationSceneRoot(
                model: appDelegate.appState,
                settings: appDelegate.settingsManager,
                layoutStore: appDelegate.keyLayoutStore
            )
            .background(
                KeyLightWindowBridge(
                    identifier: .guidedCalibration,
                    consumesUnmodifiedSpace: true
                )
            )
        }
        .defaultSize(width: 720, height: 560)
        .windowResizability(.contentMinSize)

        Window("\(applicationName) Setup", id: KeyLightSceneID.setup) {
            PermissionSetupView(
                model: appDelegate.appState,
                updateService: appDelegate.updateService
            )
            .background(
                KeyLightWindowBridge(identifier: .setup)
            )
        }
        .defaultSize(width: 560, height: 460)
        .windowResizability(.contentMinSize)
    }
}

#if DEBUG
private struct DebugLaunchSceneRouter: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var didRoute = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                guard !didRoute,
                      let requestedScene =
                        KeyLightDebugLaunchConfiguration.requestedScene else {
                    return
                }
                didRoute = true
                await Task.yield()
                switch requestedScene {
                case "setup":
                    KeyLightWindowActivation.present(.setup) {
                        openWindow(id: KeyLightSceneID.setup)
                    }
                case "keyboard", "calibration":
                    KeyLightWindowActivation.present(.keyEditor) {
                        openWindow(id: KeyLightSceneID.keyEditor)
                    }
                case "guided-calibration":
                    KeyLightWindowActivation.present(.guidedCalibration) {
                        openWindow(id: KeyLightSceneID.guidedCalibration)
                    }
                default:
                    KeyLightWindowActivation.present(.settings) {
                        openSettings()
                    }
                }
            }
    }
}
#endif

struct KeyLightBuildIdentity: Equatable, Sendable {
    let displayName: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let channel: String
    let bundlePath: String

    init(
        info: [String: Any],
        bundleIdentifier: String?,
        bundlePath: String
    ) {
        let resolvedName = (
            info["CFBundleDisplayName"] as? String
                ?? info["CFBundleName"] as? String
                ?? "KeyLight"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBundleIdentifier = (
            bundleIdentifier
                ?? info["CFBundleIdentifier"] as? String
                ?? "com.keylight.app"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitChannel = (info["KeyLightBuildChannel"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        displayName = resolvedName.isEmpty ? "KeyLight" : resolvedName
        self.bundleIdentifier = resolvedBundleIdentifier.isEmpty
            ? "com.keylight.app"
            : resolvedBundleIdentifier
        version = Self.nonempty(info["CFBundleShortVersionString"] as? String)
        build = Self.nonempty(info["CFBundleVersion"] as? String)
        channel = Self.resolvedChannel(
            explicitChannel: explicitChannel,
            bundleIdentifier: self.bundleIdentifier
        )
        self.bundlePath = bundlePath
    }

    init(bundle: Bundle = .main) {
        self.init(
            info: bundle.infoDictionary ?? [:],
            bundleIdentifier: bundle.bundleIdentifier,
            bundlePath: bundle.bundlePath
        )
    }

    var versionDescription: String {
        guard build != version else { return version }
        return "\(version) (\(build))"
    }

    var supportSummary: String {
        [
            "\(displayName) \(versionDescription)",
            "Channel: \(channel)",
            "Bundle ID: \(bundleIdentifier)",
            "Bundle path: \(bundlePath)"
        ].joined(separator: "\n")
    }

    private static func nonempty(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return "—"
        }
        return value
    }

    private static func resolvedChannel(
        explicitChannel: String?,
        bundleIdentifier: String
    ) -> String {
        if let explicitChannel, !explicitChannel.isEmpty {
            return explicitChannel
        }
        switch bundleIdentifier {
        case "com.keylight.app.motionpreview": return "Motion Preview"
        case "com.keylight.app.debug": return "Local Debug"
        case "com.keylight.app.v2": return "Side-by-Side"
        case "com.keylight.app": return "Production"
        default: return "Development"
        }
    }
}

enum KeyLightApplicationIdentity {
    static var current: KeyLightBuildIdentity {
        KeyLightBuildIdentity()
    }

    static var displayName: String {
        current.displayName
    }

    static var bundleName: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? displayName
        return name.hasSuffix(".app") ? name : "\(name).app"
    }
}

enum KeyLightSceneID {
    static let keyEditor = "key-editor"
    static let guidedCalibration = "guided-calibration"
    static let setup = "setup"
}

enum KeyLightWindowIdentifier: String, Sendable {
    case settings = "com.keylight.window.settings"
    case keyEditor = "com.keylight.window.key-editor"
    case guidedCalibration = "com.keylight.window.guided-calibration"
    case setup = "com.keylight.window.setup"

    var appKitIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(rawValue)
    }
}

enum KeyLightCalibrationKeyPolicy {
    static func consumesLocalControlActivation(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        keyCode == 49 && modifierFlags.intersection([
            .command, .control, .option
        ]).isEmpty
    }
}

/// SwiftUI creates the scenes; this tiny AppKit edge makes an explicit menu
/// action behave like a foreground command in an LSUIElement application.
@MainActor
enum KeyLightWindowActivation {
    static func present(
        _ identifier: KeyLightWindowIdentifier,
        opening action: () -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        action()
        activate(identifier)
        DispatchQueue.main.async {
            activate(identifier)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            activate(identifier)
        }
    }

    static func activate(_ identifier: KeyLightWindowIdentifier) {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: {
            $0.identifier == identifier.appKitIdentifier
        }) else { return }
        window.makeKeyAndOrderFront(nil)
    }
}

struct KeyLightWindowBridge: NSViewRepresentable {
    let identifier: KeyLightWindowIdentifier
    var consumesUnmodifiedSpace = false

    func makeNSView(context: Context) -> KeyLightWindowBridgeView {
        KeyLightWindowBridgeView(
            identifier: identifier,
            consumesUnmodifiedSpace: consumesUnmodifiedSpace
        )
    }

    func updateNSView(
        _ nsView: KeyLightWindowBridgeView,
        context: Context
    ) {
        nsView.configure(
            identifier: identifier,
            consumesUnmodifiedSpace: consumesUnmodifiedSpace
        )
    }
}

@MainActor
final class KeyLightWindowBridgeView: NSView {
    private var windowIdentifier: KeyLightWindowIdentifier
    private var consumesUnmodifiedSpace: Bool
    // NSEvent's opaque monitor token is created, used, and cleared only on the
    // AppKit main actor. Marking the storage unsafe-nonisolated prevents Swift
    // 6's synthesized nonisolated deinitializer from treating `Any` as a
    // cross-actor transfer.
    nonisolated(unsafe) private var keyMonitor: Any?

    init(
        identifier: KeyLightWindowIdentifier,
        consumesUnmodifiedSpace: Bool
    ) {
        windowIdentifier = identifier
        self.consumesUnmodifiedSpace = consumesUnmodifiedSpace
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        identifier: KeyLightWindowIdentifier,
        consumesUnmodifiedSpace: Bool
    ) {
        windowIdentifier = identifier
        self.consumesUnmodifiedSpace = consumesUnmodifiedSpace
        configureWindow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeKeyMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func configureWindow() {
        removeKeyMonitor()
        guard let window else { return }
        window.identifier = windowIdentifier.appKitIdentifier
        if consumesUnmodifiedSpace {
            keyMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [weak self, weak window] event in
                guard let self,
                      let window,
                      self.window === window,
                      event.window === window,
                      KeyLightCalibrationKeyPolicy
                        .consumesLocalControlActivation(
                            keyCode: event.keyCode,
                            modifierFlags: event.modifierFlags
                        ) else {
                    return event
                }
                // The listen-only global tap has already observed this Space
                // event. Suppress only its local control activation so Reset
                // All cannot become an accidental default button.
                return nil
            }
        }
        DispatchQueue.main.async {
            KeyLightWindowActivation.activate(self.windowIdentifier)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

}
