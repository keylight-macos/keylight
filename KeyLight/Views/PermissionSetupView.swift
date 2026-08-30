import AppKit
import SwiftUI

/// Resumable, consent-first setup. Permission prompts and update traffic occur
/// only after their explicit buttons or toggles are used.
struct PermissionSetupView: View {
    private enum Stage {
        case welcome
        case installation
        case inputExplanation
        case waitingForInputPermission
        case monitorRecovery
        case keyVerification
        case effectChoice
        case physicalPermission
        case updates
        case complete
    }

    let model: KeyLightModel
    let updateService: UpdateService
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .welcome
    @State private var screenCaptureAccessGranted =
        ScreenCaptureAuthorization.isGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: symbolName)
                .font(.title2.weight(.semibold))

            content

            Spacer(minLength: 0)

            HStack {
                if stage != .complete {
                    Button("Not Now") {
                        model.deferOnboarding()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint(
                        "Keeps Classic Glow as the safe default and does not reopen this setup automatically"
                    )
                }

                Spacer()
                actions
            }
        }
        .padding(24)
        .frame(minWidth: 540, idealWidth: 560, minHeight: 440)
        .onAppear {
            screenCaptureAccessGranted = ScreenCaptureAuthorization.isGranted
            if model.inputMonitoringInstallationIssue != nil {
                stage = .installation
            }
        }
        .onChange(of: model.inputMonitoringState) { _, _ in
            synchronizePermissionStage()
        }
        .onChange(of: model.inputMonitoringInstallationIssue) { _, issue in
            if issue != nil {
                stage = .installation
            } else {
                synchronizePermissionStage()
            }
        }
        .onChange(of: model.physicalKeyActivity) { _, activity in
            guard stage == .keyVerification, activity?.isDown == true else {
                return
            }
            stage = .effectChoice
            model.announce(UserFeedback(
                severity: .success,
                title: String(localized: "Key Detected"),
                detail: String(localized: "Input Monitoring verification succeeded. Choose an effect.")
            ))
        }
    }

    private var title: String {
        switch stage {
        case .welcome: String(localized: "Welcome to KeyLight")
        case .installation: String(localized: "Verify Installation")
        case .inputExplanation: String(localized: "Allow Input Monitoring")
        case .waitingForInputPermission: String(localized: "Finish in System Settings")
        case .monitorRecovery: String(localized: "Input Monitoring Needs Attention")
        case .keyVerification: String(localized: "Verify a Physical Key")
        case .effectChoice: String(localized: "Choose Your Effect")
        case .physicalPermission: String(localized: "Optional Screen Recording")
        case .updates: String(localized: "Software Updates")
        case .complete: String(localized: "KeyLight Is Ready")
        }
    }

    private var symbolName: String {
        switch stage {
        case .welcome: "keyboard"
        case .installation: "app.badge.checkmark"
        case .inputExplanation, .waitingForInputPermission, .monitorRecovery:
            "keyboard.badge.ellipsis"
        case .keyVerification: "keyboard.fill"
        case .effectChoice: "sparkles"
        case .physicalPermission: "rectangle.on.rectangle"
        case .updates: "arrow.triangle.2.circlepath"
        case .complete: "checkmark.circle.fill"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .welcome:
            VStack(alignment: .leading, spacing: 12) {
                Text("KeyLight turns physical key presses into a fluid light surface along the bottom of your display.")
                Label("No typing history, analytics, accounts, or cloud sync", systemImage: "hand.raised.fill")
                Label("Ordinary key events are reduced to identity and press/release metadata", systemImage: "keyboard")
                Label("Screen Recording is optional and used only by Physical Refraction", systemImage: "rectangle.on.rectangle.slash")
            }
            .foregroundStyle(.secondary)

        case .installation:
            VStack(alignment: .leading, spacing: 10) {
                Text(model.inputMonitoringInstallationIssue ?? "KeyLight is running from a stable installed location.")
                Text(model.inputMonitoringAppPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .foregroundStyle(.secondary)

        case .inputExplanation:
            VStack(alignment: .leading, spacing: 12) {
                Text("KeyLight needs Input Monitoring to receive global key press and release events and position the effect under the corresponding physical key.")
                Text("Typed characters are not retained, logged, exported, or sent anywhere.")
                    .font(.callout.weight(.medium))
            }
            .foregroundStyle(.secondary)

        case .waitingForInputPermission:
            Text("Turn on KeyLight in Privacy & Security › Input Monitoring, then return here. KeyLight checks permission without showing another prompt.")
                .foregroundStyle(.secondary)

        case .monitorRecovery:
            Text("Input Monitoring is allowed, but the keyboard event loop could not start. Retry it or review the installed KeyLight entry in System Settings.")
                .foregroundStyle(.secondary)

        case .keyVerification:
            VStack(alignment: .leading, spacing: 10) {
                Text("Press and release any physical key once.")
                Text("The completion screen stays open until you choose Done; setup never dismisses itself automatically.")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

        case .effectChoice:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(EffectStyle.allCases, id: \.self) { effect in
                    effectRow(effect)
                }
            }

        case .physicalPermission:
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    screenCaptureAccessGranted
                        ? "Screen Recording is allowed"
                        : "Screen Recording is not yet allowed",
                    systemImage: screenCaptureAccessGranted
                        ? "checkmark.shield.fill"
                        : "hand.raised.fill"
                )
                .foregroundStyle(screenCaptureAccessGranted ? .green : .orange)

                Text("Physical Refraction starts capture only when a visible key surface first appears. It samples one bottom strip at up to 30 fps, retains one latest GPU-backed frame, and stops two seconds after the final retraction.")
                    .foregroundStyle(.secondary)
                Text("Selecting the effect never requests permission. The button below is the explicit consent action. System Glass is the capture-free alternative.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .updates:
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updateService.automaticallyChecksForUpdates },
                        set: { updateService.automaticallyChecksForUpdates = $0 }
                    )
                )
                .disabled(!updateService.isConfigured)
                Text(
                    updateService.isConfigured
                        ? "Off by default. When enabled, KeyLight contacts only its signed HTTPS update feed and sends no system profile or analytics."
                        : "This local preview has no production update feed or public signing key, so it cannot make update requests."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

        case .complete:
            VStack(alignment: .leading, spacing: 10) {
                Text("Setup is complete. Your selected effect and update choice are saved.")
                LabeledContent("Effect") {
                    Text(model.effectStyle.displayName)
                }
                LabeledContent("Input Monitoring") {
                    Text(model.inputMonitoringState == .active ? "Active" : "Needs attention")
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch stage {
        case .welcome:
            Button("Continue") {
                advanceFromWelcome()
            }
            .keyboardShortcut(.defaultAction)

        case .installation:
            Button("Open Applications") {
                NSWorkspace.shared.open(
                    URL(fileURLWithPath: "/Applications", isDirectory: true)
                )
            }
            Button("Check Again") {
                if model.inputMonitoringInstallationIssue == nil {
                    advanceFromWelcome()
                } else {
                    model.retryInputMonitoring()
                }
            }
            .keyboardShortcut(.defaultAction)

        case .inputExplanation:
            Button("Allow Input Monitoring…") {
                model.markPermissionExplanationSeen()
                stage = .waitingForInputPermission
                model.requestInputMonitoringPermission()
            }
            .keyboardShortcut(.defaultAction)

        case .waitingForInputPermission:
            Button("Open System Settings") {
                model.openInputMonitoringSettings()
            }
            Button("Check Again") {
                model.retryInputMonitoring()
            }
            .keyboardShortcut(.defaultAction)

        case .monitorRecovery:
            Button("Open System Settings") {
                model.openInputMonitoringSettings()
            }
            Button("Retry Monitor") {
                model.retryInputMonitoring()
            }
            .keyboardShortcut(.defaultAction)

        case .keyVerification:
            Button("Retry Monitor") {
                model.retryInputMonitoring()
            }

        case .effectChoice:
            Button("Continue") {
                stage = model.effectStyle == .physicalRefraction
                    ? .physicalPermission
                    : .updates
            }
            .keyboardShortcut(.defaultAction)

        case .physicalPermission:
            if !screenCaptureAccessGranted {
                Button("Continue with Fallback") {
                    stage = .updates
                }
                Button("Use System Glass Instead") {
                    model.selectEffect(.systemGlass)
                    stage = .updates
                }
                Button("Allow Screen Recording…") {
                    screenCaptureAccessGranted =
                        ScreenCaptureAuthorization.requestAccess()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") {
                    stage = .updates
                }
                .keyboardShortcut(.defaultAction)
            }

        case .updates:
            Button("Continue") {
                stage = .complete
                model.announce(UserFeedback(
                    severity: .success,
                    title: String(localized: "Setup Complete"),
                    detail: String(localized: "KeyLight is ready. Choose Done to close setup.")
                ))
            }
            .keyboardShortcut(.defaultAction)

        case .complete:
            Button("Done") {
                model.completeOnboarding()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func effectRow(_ effect: EffectStyle) -> some View {
        let available = effect.isAvailableOnCurrentSystem
        return Button {
            guard available else { return }
            model.selectEffect(effect)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.effectStyle == effect
                    ? "checkmark.circle.fill"
                    : "circle")
                    .foregroundStyle(
                        model.effectStyle == effect
                            ? Color.accentColor
                            : Color.secondary
                    )
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(effect.displayName).fontWeight(.medium)
                        Text(effect.usesScreenCapture
                            ? "Uses Optional Screen Recording"
                            : "No Screen Capture")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if effect.requiresMacOS26 {
                            Text("macOS 26+")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(effectDescription(effect))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(
                model.effectStyle == effect
                    ? Color.accentColor.opacity(0.09)
                    : Color.secondary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityLabel(
            "\(effect.displayName), \(effect.usesScreenCapture ? "uses optional Screen Recording" : "no screen capture")"
        )
    }

    private func effectDescription(_ effect: EffectStyle) -> String {
        switch effect {
        case .classicGlow:
            String(localized: "The original single-target KeyLight glow with unchanged pixels and timing.")
        case .classicPlus:
            String(localized: "Retired preview effect; migrated to Classic Glow.")
        case .liquidGlass:
            String(localized: "Retired preview effect; migrated to System Glass.")
        case .systemGlass:
            String(localized: "Capture-free optics controlled entirely by Apple's compositor.")
        case .physicalRefraction:
            String(localized: "Physically modeled backdrop refraction with System Glass fallback.")
        case .solidBlack:
            String(localized: "An opaque black silhouette that retracts geometrically.")
        }
    }

    private func advanceFromWelcome() {
        if model.inputMonitoringInstallationIssue != nil {
            stage = .installation
        } else if !model.hasSeenPermissionExplanation {
            stage = .inputExplanation
        } else {
            synchronizePermissionStage(force: true)
        }
    }

    private func synchronizePermissionStage(force: Bool = false) {
        let permissionStages: Set<Stage> = [
            .welcome,
            .installation,
            .inputExplanation,
            .waitingForInputPermission,
            .monitorRecovery,
            .keyVerification
        ]
        guard force || permissionStages.contains(stage) else { return }
        if model.inputMonitoringInstallationIssue != nil {
            stage = .installation
            return
        }
        guard model.hasSeenPermissionExplanation else {
            if force { stage = .inputExplanation }
            return
        }
        switch model.inputMonitoringState {
        case .active:
            stage = .keyVerification
        case .monitorUnavailable:
            stage = .monitorRecovery
        case .checking, .permissionRequired, .authorized, .starting:
            stage = .waitingForInputPermission
        }
    }
}
