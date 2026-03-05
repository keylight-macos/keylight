import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum SettingsImportValidationError: LocalizedError {
    case notRegularFile
    case fileTooLarge
    case fileSizeUnavailable

    var errorDescription: String? {
        switch self {
        case .notRegularFile:
            return "Selected item is not a regular file."
        case .fileTooLarge:
            return "file too large (max 5MB)"
        case .fileSizeUnavailable:
            return "Could not determine file size."
        }
    }
}

private func loadValidatedSettingsImportData(from url: URL, maxFileSize: Int) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard settingsImportIsRegularFile(attributes: attributes) else {
        throw SettingsImportValidationError.notRegularFile
    }

    guard let sizeValue = attributes[.size],
          let fileSize = settingsImportFileSizeInBytes(sizeValue),
          fileSize >= 0 else {
        throw SettingsImportValidationError.fileSizeUnavailable
    }

    if fileSize > Int64(maxFileSize) {
        throw SettingsImportValidationError.fileTooLarge
    }

    return try Data(contentsOf: url)
}

private func settingsImportIsRegularFile(attributes: [FileAttributeKey: Any]) -> Bool {
    if let fileType = attributes[.type] as? FileAttributeType {
        return fileType == .typeRegular
    }
    if let fileType = attributes[.type] as? String {
        return fileType == FileAttributeType.typeRegular.rawValue
    }
    return false
}

private func settingsImportFileSizeInBytes(_ value: Any) -> Int64? {
    switch value {
    case let number as NSNumber:
        return number.int64Value
    case let intValue as Int:
        return Int64(intValue)
    case let int64Value as Int64:
        return int64Value
    case let uintValue as UInt:
        return Int64(exactly: uintValue)
    case let uint64Value as UInt64:
        return uint64Value <= UInt64(Int64.max) ? Int64(uint64Value) : nil
    case let stringValue as String:
        return Int64(stringValue)
    default:
        return nil
    }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var hexColor: String = "68B8FF"
    @State private var hasPermission: Bool = false
    @State private var isUpdatingColor = false
    @State private var gradientPresets: [SettingsManager.GradientPreset] = []
    @State private var savedThemes: [SettingsManager.Theme] = []
    @State private var savedLayoutProfiles: [SettingsManager.KeyMappingProfile] = []
    @State private var currentThemeName: String = "current"
    @State private var currentLayoutProfileName: String = "None"
    @State private var showingThemeSaveField = false
    @State private var newThemeName: String = ""
    @State private var showingLayoutSaveField = false
    @State private var newLayoutProfileName: String = ""
    @State private var editingThemeID: UUID?
    @State private var themeRenameDraft: String = ""
    @State private var themeRenameError: String?
    @State private var editingLayoutProfileID: UUID?
    @State private var layoutRenameDraft: String = ""
    @State private var layoutRenameError: String?
    @State private var themeTransferStatus: String = ""
    @State private var themeTransferString: String = ""
    @State private var layoutTransferStatus: String = ""
    @State private var hoveredThemeID: UUID?
    @State private var hoveredLayoutProfileID: UUID?
    @State private var settingsScrollView: NSScrollView?

    @State private var pendingDeletions: [PendingDeletionID: PendingDeletionState] = [:]
    @State private var pendingDeletionTasks: [PendingDeletionID: Task<Void, Never>] = [:]

    private let inlineUndoSeconds = 5
    private let maxLayoutImportFileSize = 5_000_000

    private enum PendingDeletionID: Hashable {
        case theme(UUID)
        case layout(UUID)
    }

    private enum PendingDeletionKind {
        case theme(item: SettingsManager.Theme)
        case layout(item: SettingsManager.KeyMappingProfile)
    }

    private struct PendingDeletionState {
        let deletion: PendingDeletionKind
        var secondsRemaining: Int
    }

    private var selectedGradientPresetID: UUID? {
        let currentStart = appState.gradientStartColor.toHex()?.uppercased()
        let currentEnd = appState.gradientEndColor.toHex()?.uppercased()
        return gradientPresets.first(where: { preset in
            preset.startHex.uppercased() == currentStart && preset.endHex.uppercased() == currentEnd
        })?.id
    }

    private var activeLayoutProfile: SettingsManager.KeyMappingProfile? {
        savedLayoutProfiles.first(where: { $0.name == currentLayoutProfileName })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("KeyLight")
                        .font(.title2)
                        .bold()
                    Spacer()
                    Text("⌘⇧K")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                    Toggle("", isOn: $appState.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Color Mode")
                        .font(.headline)
                    Picker("", selection: $appState.colorMode) {
                        Text("Solid").tag(SettingsManager.ColorMode.solid)
                        Text("Position Gradient").tag(SettingsManager.ColorMode.positionGradient)
                        Text("Random Per Key").tag(SettingsManager.ColorMode.randomPerKey)
                        Text("Rainbow").tag(SettingsManager.ColorMode.rainbow)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if appState.colorMode == .solid {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color")
                            .font(.headline)
                        HStack(spacing: 12) {
                            ColorPicker("Glow Color", selection: $appState.glowColor, supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 44, height: 28)

                            HStack(spacing: 4) {
                                Text("#")
                                    .foregroundColor(.secondary)
                                TextField("Hex", text: $hexColor)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                                    .onChange(of: hexColor) { _, newValue in
                                        guard !isUpdatingColor else { return }
                                        isUpdatingColor = true
                                        defer { isUpdatingColor = false }
                                        if let color = Color(hex: newValue) {
                                            appState.glowColor = color
                                        }
                                    }
                            }

                            HStack(spacing: 6) {
                                ColorPresetButton(color: Color(hex: "68B8FF") ?? .blue, appState: appState, hexColor: $hexColor)
                                ColorPresetButton(color: Color(hex: "00E69A") ?? .green, appState: appState, hexColor: $hexColor)
                                ColorPresetButton(color: Color(hex: "FF6B6B") ?? .red, appState: appState, hexColor: $hexColor)
                                ColorPresetButton(color: Color(hex: "FFD93D") ?? .yellow, appState: appState, hexColor: $hexColor)
                                ColorPresetButton(color: Color(hex: "C77DFF") ?? .purple, appState: appState, hexColor: $hexColor)
                            }
                        }
                        .onChange(of: appState.glowColor) { _, newColor in
                            guard !isUpdatingColor else { return }
                            isUpdatingColor = true
                            defer { isUpdatingColor = false }
                            hexColor = newColor.toHex() ?? "68B8FF"
                        }
                    }
                }

                if appState.colorMode == .positionGradient {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Gradient Colors")
                            .font(.headline)

                        HStack(spacing: 16) {
                            VStack(spacing: 4) {
                                Text("Start")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                ColorPicker("Gradient Start", selection: $appState.gradientStartColor, supportsOpacity: false)
                                    .labelsHidden()
                                    .frame(width: 44, height: 28)
                            }

                            LinearGradient(
                                colors: [appState.gradientStartColor, appState.gradientEndColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(height: 12)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                            )

                            VStack(spacing: 4) {
                                Text("End")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                ColorPicker("Gradient End", selection: $appState.gradientEndColor, supportsOpacity: false)
                                    .labelsHidden()
                                    .frame(width: 44, height: 28)
                            }
                        }

                        HStack {
                            Text("Presets")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Delete Selected") {
                                deleteSelectedGradientPreset()
                            }
                            .font(.caption)
                            .disabled(selectedGradientPresetID == nil || gradientPresets.count <= 1)
                            Button("Add Gradient Colors") {
                                saveCurrentGradientPreset()
                            }
                            .font(.caption)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(gradientPresets) { preset in
                                    GradientPresetButton(startHex: preset.startHex, endHex: preset.endHex, appState: appState)
                                }
                            }
                        }
                    }
                }

                if appState.colorMode == .randomPerKey {
                    Text("Each key uses a deterministic random color derived from its key code.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if appState.colorMode == .rainbow {
                    Text("Colors are distributed left-to-right by key position.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Effect Settings")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Opacity")
                            Spacer()
                            Text("\(Int(appState.glowOpacity * 100))%")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $appState.glowOpacity, in: 0.05...1.0)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Height")
                            Spacer()
                            Text("\(Int(appState.glowSize))")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $appState.glowSize, in: 30...200)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Width")
                            Spacer()
                            Text("\(Int(appState.glowWidth * 100))%")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $appState.glowWidth, in: 0.3...3.0)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Roundness")
                            Spacer()
                            Text(appState.glowRoundness < 0.05 ? "Sharp" : appState.glowRoundness > 0.95 ? "Round" : "\(Int(appState.glowRoundness * 100))%")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $appState.glowRoundness, in: 0.0...1.0)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Hardness")
                            Spacer()
                            Text("\(Int(appState.glowFullness * 100))%")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $appState.glowFullness, in: 0.0...1.0)
                        Text("Controls glow boundary feather (0% soft, 100% crisp).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Fade Duration")
                            Spacer()
                            Text("\(String(format: "%.2f", appState.fadeDuration))s")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $appState.fadeDuration, in: 0.05...2.0)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Themes")
                        .font(.headline)

                    Text("Themes store glow style settings only (color, effect, and fade).")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if savedThemes.isEmpty {
                        Text("No saved themes yet.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(savedThemes) { theme in
                            let isActive = currentThemeName == theme.name
                            let pendingID = PendingDeletionID.theme(theme.id)
                            let pendingState = pendingDeletions[pendingID]
                            let isHovered = hoveredThemeID == theme.id

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    if editingThemeID == theme.id {
                                        TextField("Theme name", text: $themeRenameDraft)
                                            .textFieldStyle(.roundedBorder)
                                            .onChange(of: themeRenameDraft) { _, _ in
                                                themeRenameError = nil
                                            }
                                        Spacer(minLength: 10)

                                        Button("Save") {
                                            saveThemeRename(theme)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(themeRenameValidation(for: theme) != nil)

                                        Button("Cancel") {
                                            cancelThemeRename()
                                        }
                                        .controlSize(.small)
                                    } else {
                                        Text(theme.name)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                        if isActive {
                                            activeBadge()
                                        }

                                        if theme.name != SettingsManager.Theme.defaultTheme.name && isHovered {
                                            Button {
                                                startThemeRename(theme)
                                            } label: {
                                                Image(systemName: "square.and.pencil")
                                                    .font(.system(size: 13, weight: .semibold))
                                            }
                                            .buttonStyle(.borderless)
                                            .help("Rename theme")
                                        }

                                        Spacer(minLength: 0)

                                        if let pendingState {
                                            Button("Undo (\(pendingState.secondsRemaining)s)") {
                                                cancelPendingDeletion(for: pendingID)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                        } else if theme.name != SettingsManager.Theme.defaultTheme.name && isHovered {
                                            Button {
                                                queueThemeDeletion(theme)
                                            } label: {
                                                Image(systemName: "trash")
                                                    .foregroundColor(.red)
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                    }
                                }
                                .frame(minHeight: 30)

                                if editingThemeID == theme.id,
                                   let error = themeRenameError ?? themeRenameValidation(for: theme) {
                                    Text(error)
                                        .font(.caption2)
                                        .foregroundColor(.red)
                                        .padding(.leading, 24)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        isActive ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.2),
                                        lineWidth: 1
                                    )
                            )
                            .contentShape(Rectangle())
                            .gesture(
                                TapGesture().onEnded {
                                    guard editingThemeID == nil else { return }
                                    selectTheme(theme, isActive: isActive)
                                },
                                including: .gesture
                            )
                            .onHover { hovering in
                                hoveredThemeID = hovering ? theme.id : (hoveredThemeID == theme.id ? nil : hoveredThemeID)
                            }
                            .padding(.vertical, 0.5)
                        }
                    }

                    if showingThemeSaveField {
                        HStack {
                            TextField("Theme name", text: $newThemeName)
                                .textFieldStyle(.roundedBorder)

                            Button("Save") {
                                let trimmed = trimmed(newThemeName)
                                guard !trimmed.isEmpty else { return }
                                var theme = appState.currentTheme()
                                theme.name = trimmed
                                SettingsManager.shared.saveTheme(theme)
                                SettingsManager.shared.currentThemeName = trimmed
                                reloadPersistedState()
                                showingThemeSaveField = false
                                newThemeName = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(trimmed(newThemeName).isEmpty)

                            Button("Cancel") {
                                showingThemeSaveField = false
                                newThemeName = ""
                            }
                            .controlSize(.small)
                        }
                    } else {
                        HStack {
                            Button("Save Current...") {
                                showingThemeSaveField = true
                            }
                            .controlSize(.small)

                            Spacer()

                            Button("Copy Theme String") {
                                copyThemeStringToClipboard()
                            }
                            .controlSize(.small)

                            Button("Import") {
                                importThemeString(themeTransferString)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(trimmed(themeTransferString).isEmpty)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Theme String")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextEditor(text: $themeTransferString)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 78)
                            .padding(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                            )
                    }

                    if !themeTransferStatus.isEmpty {
                        Text(themeTransferStatus)
                            .font(.caption2)
                            .foregroundColor(isStatusError(themeTransferStatus) ? .red : .secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Key Layout (Position + Width)")
                        .font(.headline)

                    Text("Key layout profiles store keyboard geometry only: per-key offsets and per-key glow width overrides.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(savedLayoutProfiles) { profile in
                        let isActive = currentLayoutProfileName == profile.name
                        let pendingID = PendingDeletionID.layout(profile.id)
                        let pendingState = pendingDeletions[pendingID]
                        let isHovered = hoveredLayoutProfileID == profile.id

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                if editingLayoutProfileID == profile.id {
                                    TextField("Layout profile name", text: $layoutRenameDraft)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: layoutRenameDraft) { _, _ in
                                            layoutRenameError = nil
                                        }
                                    Spacer(minLength: 10)

                                    Button("Save") {
                                        saveLayoutProfileRename(profile)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(layoutRenameValidation(for: profile) != nil)

                                    Button("Cancel") {
                                        cancelLayoutProfileRename()
                                    }
                                    .controlSize(.small)
                                } else {
                                    Text(profile.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    if isActive {
                                        activeBadge()
                                    }

                                    if isHovered {
                                        Button {
                                            startLayoutProfileRename(profile)
                                        } label: {
                                            Image(systemName: "square.and.pencil")
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Rename layout profile")
                                    }

                                    Spacer(minLength: 0)

                                    if let pendingState {
                                        Button("Undo (\(pendingState.secondsRemaining)s)") {
                                            cancelPendingDeletion(for: pendingID)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    } else if isHovered {
                                        Button {
                                            queueLayoutDeletion(profile)
                                        } label: {
                                            Image(systemName: "trash")
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                            .frame(minHeight: 30)

                            if editingLayoutProfileID == profile.id,
                               let error = layoutRenameError ?? layoutRenameValidation(for: profile) {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .padding(.leading, 24)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isActive ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    isActive ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.2),
                                    lineWidth: 1
                                )
                        )
                        .contentShape(Rectangle())
                        .gesture(
                            TapGesture().onEnded {
                                guard editingLayoutProfileID == nil else { return }
                                selectLayoutProfile(profile, isActive: isActive)
                            },
                            including: .gesture
                        )
                        .onHover { hovering in
                            hoveredLayoutProfileID = hovering ? profile.id : (hoveredLayoutProfileID == profile.id ? nil : hoveredLayoutProfileID)
                        }
                        .padding(.vertical, 0.5)
                    }

                    if showingLayoutSaveField {
                        HStack {
                            TextField("Layout profile name", text: $newLayoutProfileName)
                                .textFieldStyle(.roundedBorder)

                            Button("Save") {
                                let trimmed = trimmed(newLayoutProfileName)
                                guard !trimmed.isEmpty else { return }
                                let profile = SettingsManager.KeyMappingProfile(
                                    name: trimmed,
                                    keyOffsets: KeyPositionManager.shared.keyOffsets,
                                    keyWidthOverrides: KeyWidthManager.shared.keyWidthOverrides
                                )
                                SettingsManager.shared.saveKeyMappingProfile(profile)
                                reloadPersistedState()
                                showingLayoutSaveField = false
                                newLayoutProfileName = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(trimmed(newLayoutProfileName).isEmpty)

                            Button("Cancel") {
                                showingLayoutSaveField = false
                                newLayoutProfileName = ""
                            }
                            .controlSize(.small)
                        }
                    } else {
                        HStack {
                            Button("Save Current...") {
                                showingLayoutSaveField = true
                            }
                            .controlSize(.small)

                            Spacer()

                            Button("Export Active") {
                                exportActiveLayoutProfile()
                            }
                            .controlSize(.small)
                            .disabled(activeLayoutProfile == nil)

                            Button("Import") {
                                importLayoutProfile()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    HStack {
                        Button("Adjust Key Positions...") {
                            NotificationCenter.default.post(name: .openKeyPositionEditor, object: nil)
                        }
                        .buttonStyle(.link)
                    }

                    if !layoutTransferStatus.isEmpty {
                        Text(layoutTransferStatus)
                            .font(.caption2)
                            .foregroundColor(isStatusError(layoutTransferStatus) ? .red : .secondary)
                    }
                }

                Divider()

                Toggle("Launch at Login", isOn: $appState.launchAtLogin)

                HStack {
                    Circle()
                        .fill(hasPermission ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Permission: \(hasPermission ? "Granted" : "Required")")
                    Text(hasPermission ? "Input Monitoring enabled" : "Input Monitoring required")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Open Settings") {
                        PermissionManager.shared.openInputMonitoringSettings()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .padding(20)
            .background(
                SettingsScrollViewBridge { scrollView in
                    if settingsScrollView !== scrollView {
                        settingsScrollView = scrollView
                    }
                }
            )
        }
        .frame(minWidth: 460, minHeight: 520)
        .onAppear {
            hexColor = appState.glowColor.toHex() ?? "68B8FF"
            hasPermission = PermissionManager.shared.hasInputMonitoringPermission()
            reloadPersistedState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .permissionStatusChanged)) { _ in
            hasPermission = PermissionManager.shared.hasInputMonitoringPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsStorageChanged)) { _ in
            reloadPersistedState()
        }
        .onDisappear {
            clearPendingDeletionState()
        }
    }

    private func saveCurrentGradientPreset() {
        let startHex = appState.gradientStartColor.toHex() ?? "68B8FF"
        let endHex = appState.gradientEndColor.toHex() ?? "00E69A"
        SettingsManager.shared.saveGradientPreset(startHex: startHex, endHex: endHex)
        gradientPresets = SettingsManager.shared.savedGradientPresets
    }

    private func deleteGradientPreset(_ id: UUID) {
        SettingsManager.shared.deleteGradientPreset(id: id)
        gradientPresets = SettingsManager.shared.savedGradientPresets
    }

    private func deleteSelectedGradientPreset() {
        guard let selectedID = selectedGradientPresetID, gradientPresets.count > 1 else { return }
        deleteGradientPreset(selectedID)
    }

    private func activeBadge() -> some View {
        Text("Active")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundColor(.accentColor)
            .background(
                Capsule()
                    .fill(Color.accentColor.opacity(0.16))
            )
    }

    private func queueThemeDeletion(_ theme: SettingsManager.Theme) {
        guard theme.name != SettingsManager.Theme.defaultTheme.name else { return }
        if editingThemeID == theme.id {
            cancelThemeRename()
        }
        queuePendingDeletion(id: .theme(theme.id), deletion: .theme(item: theme))
    }

    private func queueLayoutDeletion(_ profile: SettingsManager.KeyMappingProfile) {
        if editingLayoutProfileID == profile.id {
            cancelLayoutProfileRename()
        }
        queuePendingDeletion(id: .layout(profile.id), deletion: .layout(item: profile))
    }

    private func queuePendingDeletion(id: PendingDeletionID, deletion: PendingDeletionKind) {
        pendingDeletionTasks[id]?.cancel()
        pendingDeletions[id] = PendingDeletionState(deletion: deletion, secondsRemaining: inlineUndoSeconds)
        pendingDeletionTasks[id] = Task {
            var remaining = inlineUndoSeconds
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                remaining -= 1

                await MainActor.run {
                    guard var pending = pendingDeletions[id] else { return }
                    if remaining == 0 {
                        applyPendingDeletion(id: id, pending: pending)
                    } else {
                        pending.secondsRemaining = remaining
                        pendingDeletions[id] = pending
                    }
                }
            }
        }
    }

    private func applyPendingDeletion(id: PendingDeletionID, pending: PendingDeletionState) {
        pendingDeletions[id] = nil
        pendingDeletionTasks[id]?.cancel()
        pendingDeletionTasks[id] = nil

        switch pending.deletion {
        case .theme(let item):
            SettingsManager.shared.deleteTheme(named: item.name)
            if editingThemeID == item.id {
                cancelThemeRename()
            }
        case .layout(let item):
            SettingsManager.shared.deleteKeyMappingProfile(named: item.name)
            if editingLayoutProfileID == item.id {
                cancelLayoutProfileRename()
            }
        }

        reloadPersistedState()
    }

    private func cancelPendingDeletion(for id: PendingDeletionID) {
        pendingDeletionTasks[id]?.cancel()
        pendingDeletionTasks[id] = nil
        pendingDeletions[id] = nil
    }

    private func clearPendingDeletionState() {
        for task in pendingDeletionTasks.values {
            task.cancel()
        }
        pendingDeletionTasks.removeAll()
        pendingDeletions.removeAll()
    }

    private func copyThemeStringToClipboard() {
        if themeTransferString.isEmpty {
            refreshThemeTransferStringFromActiveTheme()
        }
        guard !themeTransferString.isEmpty else {
            themeTransferStatus = "Export failed: could not encode theme."
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(themeTransferString, forType: .string) {
            themeTransferStatus = "Theme string copied."
        } else {
            themeTransferStatus = "Export failed: could not copy to clipboard."
        }
    }

    private func importThemeString(_ value: String) {
        do {
            let theme = try SettingsManager.shared.importThemeString(value)
            SettingsManager.shared.saveTheme(theme)
            preserveScrollOffset {
                appState.applyTheme(theme)
                reloadPersistedState()
            }
            themeTransferStatus = "Imported and applied theme \"\(theme.name)\"."
        } catch {
            themeTransferStatus = "Import failed: \(error.localizedDescription)"
        }
    }

    private func selectTheme(_ theme: SettingsManager.Theme, isActive: Bool) {
        guard !isActive else { return }
        preserveScrollOffset {
            appState.applyTheme(theme)
            reloadPersistedState()
        }
    }

    private func selectLayoutProfile(_ profile: SettingsManager.KeyMappingProfile, isActive: Bool) {
        guard !isActive else { return }
        preserveScrollOffset {
            KeyPositionManager.shared.loadProfile(profile)
            reloadPersistedState()
        }
    }

    private func preserveScrollOffset(_ action: () -> Void) {
        let currentOffset = settingsScrollView?.contentView.bounds.origin.y ?? 0
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            action()
        }
        DispatchQueue.main.async {
            restoreScrollOffset(currentOffset)
        }
    }

    private func restoreScrollOffset(_ offset: CGFloat) {
        guard let scrollView = settingsScrollView else { return }
        let clipView = scrollView.contentView
        let maxOffset = max(0, (scrollView.documentView?.bounds.height ?? 0) - clipView.bounds.height)
        let clamped = min(max(offset, 0), maxOffset)
        guard abs(clipView.bounds.origin.y - clamped) > 0.5 else { return }
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: clamped))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func exportActiveLayoutProfile() {
        guard let activeProfile = activeLayoutProfile else {
            layoutTransferStatus = "Export failed: no active layout profile."
            return
        }
        guard let data = SettingsManager.shared.exportLayoutProfileData(activeProfile) else {
            layoutTransferStatus = "Export failed: could not encode layout profile."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "KeyLight-Layout-\(safeFilename(activeProfile.name)).json"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                layoutTransferStatus = "Exported \"\(activeProfile.name)\"."
            } catch {
                layoutTransferStatus = "Export failed: \(error.localizedDescription)"
            }
        } else {
            layoutTransferStatus = ""
        }
    }

    private func importLayoutProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            performLayoutProfileImport(from: url)
        }
    }

    private func performLayoutProfileImport(from url: URL) {
        let maxFileSize = maxLayoutImportFileSize
        Task { @MainActor in
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try loadValidatedSettingsImportData(from: url, maxFileSize: maxFileSize)
                }.value

                let importedProfile = try SettingsManager.shared.importLayoutProfileData(data)
                SettingsManager.shared.saveKeyMappingProfile(importedProfile)
                KeyPositionManager.shared.loadProfile(importedProfile)
                reloadPersistedState()
                layoutTransferStatus = "Imported and applied layout profile \"\(importedProfile.name)\"."
            } catch SettingsImportValidationError.fileTooLarge {
                layoutTransferStatus = "Import failed: file too large (max 5MB)"
            } catch {
                layoutTransferStatus = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func safeFilename(_ value: String) -> String {
        let allowed = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || CharacterSet(charactersIn: "-_").contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let sanitized = String(allowed)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "Layout-Profile" : sanitized
    }

    private func startThemeRename(_ theme: SettingsManager.Theme) {
        editingThemeID = theme.id
        themeRenameDraft = theme.name
        themeRenameError = nil
    }

    private func cancelThemeRename() {
        editingThemeID = nil
        themeRenameDraft = ""
        themeRenameError = nil
    }

    private func themeRenameValidation(for theme: SettingsManager.Theme) -> String? {
        let trimmed = trimmed(themeRenameDraft)
        if trimmed.isEmpty {
            return "Name cannot be empty."
        }
        if trimmed.caseInsensitiveCompare(theme.name) == .orderedSame {
            return nil
        }
        let exists = savedThemes.contains { existing in
            existing.id != theme.id && existing.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        return exists ? "Theme name already exists." : nil
    }

    private func saveThemeRename(_ theme: SettingsManager.Theme) {
        if let error = themeRenameValidation(for: theme) {
            themeRenameError = error
            return
        }
        SettingsManager.shared.renameTheme(from: theme.name, to: themeRenameDraft)
        reloadPersistedState()
        cancelThemeRename()
    }

    private func startLayoutProfileRename(_ profile: SettingsManager.KeyMappingProfile) {
        editingLayoutProfileID = profile.id
        layoutRenameDraft = profile.name
        layoutRenameError = nil
    }

    private func cancelLayoutProfileRename() {
        editingLayoutProfileID = nil
        layoutRenameDraft = ""
        layoutRenameError = nil
    }

    private func layoutRenameValidation(for profile: SettingsManager.KeyMappingProfile) -> String? {
        let trimmed = trimmed(layoutRenameDraft)
        if trimmed.isEmpty {
            return "Name cannot be empty."
        }
        if trimmed.caseInsensitiveCompare(profile.name) == .orderedSame {
            return nil
        }
        let exists = savedLayoutProfiles.contains { existing in
            existing.id != profile.id && existing.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        return exists ? "Layout profile name already exists." : nil
    }

    private func saveLayoutProfileRename(_ profile: SettingsManager.KeyMappingProfile) {
        if let error = layoutRenameValidation(for: profile) {
            layoutRenameError = error
            return
        }
        SettingsManager.shared.renameKeyMappingProfile(from: profile.name, to: layoutRenameDraft)
        reloadPersistedState()
        cancelLayoutProfileRename()
    }

    private func isStatusError(_ status: String) -> Bool {
        let lowered = status.lowercased()
        return lowered.contains("failed") || lowered.contains("invalid") || lowered.contains("unsupported")
    }

    private func reloadPersistedState() {
        gradientPresets = SettingsManager.shared.savedGradientPresets
        savedThemes = SettingsManager.shared.savedThemes
        savedLayoutProfiles = SettingsManager.shared.savedKeyMappingProfiles
        currentThemeName = SettingsManager.shared.currentThemeName
        currentLayoutProfileName = SettingsManager.shared.currentKeyMappingProfileName
        refreshThemeTransferStringFromActiveTheme()

        if let editingThemeID, !savedThemes.contains(where: { $0.id == editingThemeID }) {
            cancelThemeRename()
        }
        if let editingLayoutProfileID, !savedLayoutProfiles.contains(where: { $0.id == editingLayoutProfileID }) {
            cancelLayoutProfileRename()
        }
    }

    private func refreshThemeTransferStringFromActiveTheme() {
        let activeTheme = savedThemes.first(where: { $0.name == currentThemeName }) ?? appState.currentTheme()
        themeTransferString = SettingsManager.shared.exportThemeString(activeTheme) ?? ""
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct SettingsScrollViewBridge: NSViewRepresentable {
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
    @ObservedObject var appState: AppState
    @Binding var hexColor: String

    var body: some View {
        Button(action: {
            appState.glowColor = color
            hexColor = color.toHex() ?? ""
        }) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

struct GradientPresetButton: View {
    let startHex: String
    let endHex: String
    @ObservedObject var appState: AppState

    private var isSelected: Bool {
        let currentStart = appState.gradientStartColor.toHex()?.uppercased()
        let currentEnd = appState.gradientEndColor.toHex()?.uppercased()
        return currentStart == startHex.uppercased() && currentEnd == endHex.uppercased()
    }

    var body: some View {
        Button(action: {
            appState.gradientStartColor = Color(hex: startHex) ?? .blue
            appState.gradientEndColor = Color(hex: endHex) ?? .green
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
        }
        .buttonStyle(.plain)
    }
}
