import AppKit
import Carbon.HIToolbox
import SwiftUI

extension SettingsView {
    @ViewBuilder
    var generalTabContent: some View {
        HStack {
            Text(KeyLightApplicationIdentity.displayName)
                .font(.title2)
                .bold()
            Spacer()
            Text(model.globalShortcut.displayName)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
            Toggle("", isOn: $model.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Enable \(KeyLightApplicationIdentity.displayName)")
        }

        Divider()

        Toggle("Launch at Login", isOn: $model.launchAtLogin)
            .accessibilityHint("Starts KeyLight automatically after you sign in")

        Divider()

        Text("Power Saving")
            .font(.headline)

        Picker("Mode", selection: $model.powerSavingMode) {
            ForEach(PowerSavingMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        LabeledContent("Current Power State") {
            Text(powerEnvironmentDescription)
                .foregroundStyle(.secondary)
        }

        if model.powerSavingMode == .automatic {
            if model.powerEnvironmentState.requiresFallback {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        model.effectStyle == .physicalRefraction
                            ? "Temporarily using \(model.effectRuntimeStatus.resolvedEffect.displayName)"
                            : "Automatic power saving is active",
                        systemImage: "leaf.fill"
                    )
                    .foregroundStyle(.orange)

                    Text(
                        model.powerEnvironmentState.fallbackReason
                            ?? "macOS requested reduced power use."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if model.effectStyle == .physicalRefraction {
                        Text("Your Physical Refraction selection is preserved and returns automatically when the condition clears.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Physical Refraction remains active until Low Power Mode or serious thermal pressure begins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Automatic renderer fallback is disabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Divider()

        LabeledContent("Global Shortcut") {
            HStack(spacing: 8) {
                GlobalShortcutRecorder(shortcut: $model.globalShortcut)
                    .fixedSize()

                Button("Reset") {
                    model.globalShortcut = .default
                }
                .controlSize(.small)
                .disabled(model.globalShortcut == .default)
            }
        }

        LabeledContent("Shortcut Status") {
            Label(hotKeyStatusTitle, systemImage: hotKeyStatusIcon)
                .foregroundStyle(hotKeyStatusColor)
                .accessibilityLabel("\(model.globalShortcut.displayName): \(hotKeyStatusTitle)")
        }

        LabeledContent("Version") {
            Text(appVersionDescription)
                .foregroundStyle(.secondary)
        }

        LabeledContent("Build Channel") {
            Text(buildIdentity.channel)
                .foregroundStyle(.secondary)
        }

        LabeledContent("Bundle ID") {
            Text(buildIdentity.bundleIdentifier)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }

        Button("Copy Build Information") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(buildIdentity.supportSummary, forType: .string)
        }
        .accessibilityHint("Copies the version, build channel, bundle identifier, and app location")

        Divider()

        Toggle(
            "Automatically check for updates",
            isOn: Binding(
                get: { updateService.automaticallyChecksForUpdates },
                set: { updateService.automaticallyChecksForUpdates = $0 }
            )
        )
        .disabled(!updateService.isConfigured)
        .accessibilityHint("Contacts only the signed KeyLight update feed")

        LabeledContent("Updates") {
            Text(updateService.status.displayName)
                .foregroundStyle(.secondary)
        }

        Button("Check for Updates…") {
            updateService.checkForUpdates()
        }
        .disabled(!updateService.canCheckForUpdates)

        Divider()

        Text("Permissions")
            .font(.headline)

        InputMonitoringStatusBanner(model: model)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    screenCaptureAccessGranted
                        ? "Screen Recording Allowed"
                        : "Screen Recording Not Allowed",
                    systemImage: screenCaptureAccessGranted
                        ? "checkmark.shield.fill"
                        : "rectangle.on.rectangle.slash"
                )
                .foregroundStyle(
                    screenCaptureAccessGranted ? .green : .secondary
                )
                Spacer()
                Button("Check Again") {
                    screenCaptureAccessGranted =
                        ScreenCaptureAuthorization.isGranted
                    model.refreshEffectRenderer()
                }
                .controlSize(.small)
            }

            Text("Optional. Physical Refraction uses it only while a key surface is visible; no captured image is saved or sent.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if !screenCaptureAccessGranted {
                    Button("Allow Screen Recording…") {
                        screenCaptureAccessGranted =
                            ScreenCaptureAuthorization.requestAccess()
                        model.refreshEffectRenderer()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Open Screen Recording Settings") {
                    ScreenCaptureAuthorization.openSettings()
                }
            }
            .controlSize(.small)
        }

        HStack(spacing: 14) {
            Link("Privacy", destination: URL(string: "https://github.com/keylight-macos/keylight/blob/main/PRIVACY.md")!)
            Link("Troubleshooting", destination: URL(string: "https://github.com/keylight-macos/keylight/blob/main/docs/TROUBLESHOOTING.md")!)
            Link("Releases", destination: URL(string: "https://github.com/keylight-macos/keylight/releases")!)
        }
        .accessibilityElement(children: .contain)
    }

    private var powerEnvironmentDescription: String {
        let lowPower = model.powerEnvironmentState.isLowPowerModeEnabled
            ? "Low Power Mode on"
            : "Low Power Mode off"
        return "\(lowPower), thermal \(model.powerEnvironmentState.thermalState.displayName.lowercased())"
    }
}

/// A deliberately local recorder: capture begins only after the user presses
/// the button, consumes one key-down event, and stores key-code metadata only.
private struct GlobalShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: GlobalShortcut

    func makeCoordinator() -> Coordinator {
        Coordinator(shortcut: $shortcut)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: shortcut.displayName, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = context.coordinator
        button.action = #selector(Coordinator.beginRecording)
        button.toolTip = "Press, then type a shortcut with Command, Option, Control, or Shift. Escape cancels."
        button.setAccessibilityLabel("Record global shortcut")
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.shortcut = $shortcut
        if !context.coordinator.isRecording {
            button.title = shortcut.displayName
            button.setAccessibilityValue(shortcut.displayName)
        }
    }

    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        coordinator.stopRecording(restoreTitle: true)
    }

    @MainActor
    final class Coordinator: NSObject {
        var shortcut: Binding<GlobalShortcut>
        weak var button: NSButton?
        private var localMonitor: Any?

        var isRecording: Bool { localMonitor != nil }

        init(shortcut: Binding<GlobalShortcut>) {
            self.shortcut = shortcut
        }

        @objc func beginRecording() {
            guard localMonitor == nil else {
                stopRecording(restoreTitle: true)
                return
            }

            button?.title = "Press Shortcut…"
            button?.setAccessibilityValue("Waiting for shortcut")
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.capture(event)
            }
        }

        func stopRecording(restoreTitle: Bool) {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            if restoreTitle {
                button?.title = shortcut.wrappedValue.displayName
                button?.setAccessibilityValue(shortcut.wrappedValue.displayName)
            }
        }

        private func capture(_ event: NSEvent) -> NSEvent? {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == UInt16(kVK_Escape),
               flags.intersection([.command, .option, .control, .shift]).isEmpty {
                stopRecording(restoreTitle: true)
                return nil
            }

            var carbonModifiers: UInt32 = 0
            if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
            if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
            if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
            if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

            guard let recorded = GlobalShortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: carbonModifiers
            ) else {
                NSSound.beep()
                return nil
            }

            shortcut.wrappedValue = recorded
            stopRecording(restoreTitle: true)
            return nil
        }
    }
}
