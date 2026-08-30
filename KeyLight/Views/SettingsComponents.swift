import AppKit
import SwiftUI

enum ThemeTransferMode: String, Identifiable {
    case share
    case importTheme

    var id: String { rawValue }
}

struct InlineSettingsFeedback: View {
    let feedback: UserFeedback

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(feedback.title)
                    .font(.caption.weight(.semibold))
                if let detail = feedback.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch feedback.severity {
        case .information: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch feedback.severity {
        case .information: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct SettingsFeedbackBanner: View {
    let feedback: UserFeedback
    let onRecovery: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(feedback.title)
                    .font(.callout.weight(.semibold))
                if let detail = feedback.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let recoveryTitle {
                Button(recoveryTitle) {
                    onRecovery()
                }
                .controlSize(.small)
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss \(feedback.title)")
        }
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var icon: String {
        switch feedback.severity {
        case .information: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch feedback.severity {
        case .information: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var recoveryTitle: String? {
        switch feedback.recoveryAction {
        case .checkAgain: return String(localized: "Check Again")
        case .retry: return String(localized: "Retry")
        case .openInputMonitoringSettings: return String(localized: "Open Settings")
        case .undo, nil: return nil
        }
    }
}

struct ThemeTransferSheet: View {
    @Environment(\.dismiss) private var dismiss

    let mode: ThemeTransferMode
    @Binding var transferString: String
    @Binding var feedback: UserFeedback?
    let onCopy: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode == .share ? "Share Theme" : "Import Theme")
                .font(.title2.bold())

            Text(
                mode == .share
                    ? "Copy this KeyLight theme string to share the current appearance."
                    : "Paste a KeyLight theme string. A valid theme is saved and applied immediately."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if mode == .share {
                ScrollView {
                    Text(transferString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                )
                .accessibilityLabel("Shareable theme string")
            } else {
                TextEditor(text: $transferString)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                    )
                    .accessibilityLabel("Theme string to import")
            }

            if let feedback {
                InlineSettingsFeedback(feedback: feedback)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }

                if mode == .share {
                    Button("Copy") {
                        onCopy()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(transferString.isEmpty)
                } else {
                    Button("Import and Apply") {
                        onImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(transferString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

struct InputMonitoringStatusBanner: View {
    let model: KeyLightModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title3)
                .foregroundStyle(statusColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(statusTitle)
                    .font(.headline)

                Text(statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup("Technical Details") {
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Running app")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(model.inputMonitoringAppPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let installationIssue = model.inputMonitoringInstallationIssue {
                            Label(installationIssue, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("Quit this copy, install it in Applications using the exact filename shown above, then launch that app. In Input Monitoring, remove any stale row, add the installed app again, turn it on, and retry in the relaunched app.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if model.inputMonitoringState == .permissionRequired {
                            Text("If this app is already listed but access remains unavailable, remove its stale row, add the installed app again, turn it on, and retry the monitor.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if model.inputMonitoringState == .permissionRequired ||
                            model.inputMonitoringState == .monitorUnavailable {
                            Text("Accessibility permission is not required.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if Bundle.main.bundleIdentifier ==
                            "com.keylight.app.motionpreview" {
                            Text(KeyLightApplicationIdentity.current.channel.localizedCaseInsensitiveContains("Signed")
                                ? "This Motion Preview uses a stable Developer ID identity, so normal preview upgrades can retain permission. It remains isolated from the production app."
                                : "Local Motion Preview builds use a new ad-hoc code identity when rebuilt. macOS may therefore require the preview row to be removed and added again. A Developer ID-signed preview can retain permission across normal upgrades.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)

                if showsRepairActions {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            if model.inputMonitoringInstallationIssue != nil {
                                Button("Review Installation…") {
                                    KeyLightWindowActivation.present(.setup) {
                                        openWindow(id: KeyLightSceneID.setup)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityHint("Explains the exact installation correction before Input Monitoring is requested")
                            } else if model.inputMonitoringState == .permissionRequired {
                                Button(model.hasSeenPermissionExplanation ? "Grant Access" : "Review Access…") {
                                    if model.hasSeenPermissionExplanation {
                                        model.requestInputMonitoringPermission()
                                    } else {
                                        model.requestPermissionSetupIfNeeded()
                                        KeyLightWindowActivation.present(.setup) {
                                            openWindow(id: KeyLightSceneID.setup)
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityHint(
                                    model.hasSeenPermissionExplanation
                                        ? "Requests Input Monitoring access for KeyLight"
                                        : "Explains why KeyLight needs Input Monitoring before requesting access"
                                )
                            }

                            if model.inputMonitoringInstallationIssue == nil {
                                Button("Retry Monitor") {
                                    model.retryInputMonitoring()
                                }
                                .accessibilityHint("Retries the KeyLight keyboard monitor")
                            }
                        }

                        if model.inputMonitoringInstallationIssue == nil {
                            Button("Open Input Monitoring Settings") {
                                model.openInputMonitoringSettings()
                            }
                            .accessibilityHint("Opens the Input Monitoring privacy settings")
                        }
                    }
                    .controlSize(.small)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(statusColor.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Input Monitoring status: \(statusTitle)")
    }

    private var showsRepairActions: Bool {
        model.inputMonitoringInstallationIssue != nil ||
            model.inputMonitoringState == .permissionRequired ||
            model.inputMonitoringState == .monitorUnavailable
    }

    private var statusTitle: String {
        switch model.inputMonitoringState {
        case .checking:
            return String(localized: "Checking Input Monitoring")
        case .permissionRequired:
            return String(localized: "Input Monitoring Required")
        case .authorized:
            return String(localized: "Input Monitoring Authorized")
        case .starting:
            return String(localized: "Input Monitoring Starting")
        case .active:
            return String(localized: "Input Monitoring Active")
        case .monitorUnavailable:
            return String(localized: "Input Monitoring Unavailable")
        }
    }

    private var statusDetail: String {
        switch model.inputMonitoringState {
        case .checking:
            return String(localized: "KeyLight is checking macOS permission and keyboard monitor status.")
        case .permissionRequired:
            return String(localized: "KeyLight needs Input Monitoring to detect key presses.")
        case .authorized:
            return String(localized: "Input Monitoring is granted. Enable KeyLight to start the keyboard monitor.")
        case .starting:
            return String(localized: "KeyLight is starting the keyboard monitor.")
        case .active:
            return String(localized: "Input Monitoring is granted and key presses are being monitored.")
        case .monitorUnavailable:
            return String(localized: "Input Monitoring is granted, but KeyLight could not start the keyboard monitor.")
        }
    }

    private var statusIcon: String {
        switch model.inputMonitoringState {
        case .checking, .starting:
            return "clock"
        case .permissionRequired:
            return "exclamationmark.triangle.fill"
        case .authorized:
            return "checkmark.shield"
        case .active:
            return "checkmark.circle.fill"
        case .monitorUnavailable:
            return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
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

struct SettingsScrollViewBridge: NSViewRepresentable {
    let onResolve: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            var current: NSView? = nsView
            while let view = current {
                if let scrollView = view as? NSScrollView {
                    onResolve(scrollView)
                    return
                }
                current = view.superview
            }
        }
    }
}

struct ColorPresetButton: View {
    let color: Color
    let model: KeyLightModel
    @Binding var hexColor: String

    private var isSelected: Bool {
        model.glowColor.toHex()?.uppercased() == color.toHex()?.uppercased()
    }

    var body: some View {
        Button(action: {
            model.glowColor = color
            hexColor = color.toHex() ?? ""
        }) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.2),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.caption)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use color \(color.toHex() ?? "custom")")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct GradientPresetButton: View {
    let startHex: String
    let endHex: String
    let model: KeyLightModel

    private var isSelected: Bool {
        let currentStart = model.gradientStartColor.toHex()?.uppercased()
        let currentEnd = model.gradientEndColor.toHex()?.uppercased()
        return currentStart == startHex.uppercased() && currentEnd == endHex.uppercased()
    }

    var body: some View {
        Button(action: {
            model.gradientStartColor = Color(hex: startHex) ?? .blue
            model.gradientEndColor = Color(hex: endHex) ?? .green
        }) {
            LinearGradient(
                colors: [Color(hex: startHex) ?? .blue, Color(hex: endHex) ?? .green],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 30, height: 20)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            )
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.caption)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use gradient from \(startHex) to \(endHex)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
