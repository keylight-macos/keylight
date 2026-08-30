import SwiftUI
import AppKit

// MARK: - Menu Bar Menu

struct MenuBarMenuView: View {
    let model: KeyLightModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(model.isEnabled ? "Disable \(KeyLightApplicationIdentity.displayName)" : "Enable \(KeyLightApplicationIdentity.displayName)") {
            model.isEnabled.toggle()
        }

        if inputMonitoringNeedsAttention {
            Divider()

            Label(inputMonitoringStatusTitle, systemImage: inputMonitoringStatusIcon)
                .foregroundStyle(inputMonitoringStatusColor)
                .accessibilityLabel("Input Monitoring: \(inputMonitoringStatusTitle)")

            if model.inputMonitoringInstallationIssue != nil {
                Button("Resolve Installation…") {
                    KeyLightWindowActivation.present(.setup) {
                        openWindow(id: KeyLightSceneID.setup)
                    }
                }
                .accessibilityHint("Explains how to install KeyLight before allowing Input Monitoring")
            } else if model.inputMonitoringState == .permissionRequired {
                Button("Allow Input Monitoring…") {
                    if model.hasSeenPermissionExplanation {
                        model.requestInputMonitoringPermission()
                    } else {
                        KeyLightWindowActivation.present(.setup) {
                            openWindow(id: KeyLightSceneID.setup)
                        }
                    }
                }
                .accessibilityHint("Requests Input Monitoring permission for KeyLight")

                Button("Open System Settings") {
                    model.openInputMonitoringSettings()
                }
                .accessibilityHint("Opens the Input Monitoring privacy settings")
            } else if model.inputMonitoringState == .monitorUnavailable {
                Button("Check Again") {
                    model.retryInputMonitoring()
                }
                .accessibilityHint("Checks Input Monitoring and restarts key detection")

                Button("Open System Settings") {
                    model.openInputMonitoringSettings()
                }
                .accessibilityHint("Opens the Input Monitoring privacy settings")
            }
        }

        Divider()

        Button("Settings…") {
            KeyLightWindowActivation.present(.settings) {
                openSettings()
            }
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Calibrate Keyboard…") {
            KeyLightWindowActivation.present(.keyEditor) {
                openWindow(id: KeyLightSceneID.keyEditor)
            }
        }

        Button("About \(KeyLightApplicationIdentity.displayName)") {
            NSApp.activate(ignoringOtherApps: true)
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
        }

        Divider()

        Button("Quit \(KeyLightApplicationIdentity.displayName)") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var inputMonitoringNeedsAttention: Bool {
        model.inputMonitoringInstallationIssue != nil ||
            model.inputMonitoringState == .permissionRequired ||
            model.inputMonitoringState == .monitorUnavailable
    }

    private var inputMonitoringStatusTitle: String {
        switch model.inputMonitoringState {
        case .checking:
            return "Checking Input Monitoring"
        case .permissionRequired:
            return "Input Monitoring Needed"
        case .authorized:
            return "Input Monitoring Allowed"
        case .starting:
            return "Input Monitoring Starting"
        case .active:
            return "Input Monitoring Active"
        case .monitorUnavailable:
            return "Input Monitoring Unavailable"
        }
    }

    private var inputMonitoringStatusIcon: String {
        switch model.inputMonitoringState {
        case .checking, .starting:
            return "clock"
        case .permissionRequired:
            return "exclamationmark.triangle"
        case .authorized:
            return "checkmark.shield"
        case .active:
            return "checkmark.circle"
        case .monitorUnavailable:
            return "xmark.circle"
        }
    }

    private var inputMonitoringStatusColor: Color {
        switch model.inputMonitoringState {
        case .checking, .starting:
            return .secondary
        case .permissionRequired:
            return .orange
        case .authorized, .active:
            return .green
        case .monitorUnavailable:
            return .red
        }
    }
}
struct MenuBarLabel: View {
    let model: KeyLightModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label(KeyLightApplicationIdentity.displayName, systemImage: statusItemSymbol)
            .onAppear(perform: presentSetupIfRequested)
            .onChange(of: model.permissionSetupPresentationRequested) { _, requested in
                guard requested else { return }
                presentSetupIfRequested()
            }
    }

    private var statusItemSymbol: String {
        guard model.isEnabled else { return "keyboard.badge.ellipsis" }
        switch model.inputMonitoringState {
        case .active:
            return "keyboard"
        case .permissionRequired, .monitorUnavailable:
            return "exclamationmark.triangle"
        case .checking, .authorized, .starting:
            return "keyboard.badge.ellipsis"
        }
    }

    private func presentSetupIfRequested() {
        guard model.consumePermissionSetupPresentationRequest() else { return }
        KeyLightWindowActivation.present(.setup) {
            openWindow(id: KeyLightSceneID.setup)
        }
    }
}
