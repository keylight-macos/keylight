import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin

private enum SettingsImportValidationError: LocalizedError {
    case notRegularFile
    case fileTooLarge
    case fileSizeUnavailable

    var errorDescription: String? {
        switch self {
        case .notRegularFile:
            return "Selected item is not a regular file."
        case .fileTooLarge:
            return "file too large (max 1MB)"
        case .fileSizeUnavailable:
            return "Could not determine file size."
        }
    }
}

private func loadValidatedSettingsImportData(from url: URL, maxFileSize: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
        try? handle.close()
    }

    var fileStatus = stat()
    guard fstat(handle.fileDescriptor, &fileStatus) == 0 else {
        throw SettingsImportValidationError.fileSizeUnavailable
    }
    guard (fileStatus.st_mode & S_IFMT) == S_IFREG else {
        throw SettingsImportValidationError.notRegularFile
    }
    guard fileStatus.st_size >= 0 else {
        throw SettingsImportValidationError.fileSizeUnavailable
    }
    if fileStatus.st_size > Int64(maxFileSize) {
        throw SettingsImportValidationError.fileTooLarge
    }

    let data = try handle.read(upToCount: maxFileSize + 1) ?? Data()
    guard data.count <= maxFileSize else {
        throw SettingsImportValidationError.fileTooLarge
    }
    return data
}

struct SettingsView: View {
    @Bindable var model: KeyLightModel
    @Environment(\.openWindow) var openWindow
    let settings: SettingsManager
    @ObservedObject var keyLayoutStore: KeyLayoutStore
    let updateService: UpdateService

    @State var hexColor: String = "68B8FF"
    @State var isUpdatingColor = false
    @State var gradientPresets: [GradientPreset] = []
    @State private var selectedSettingsTab: SettingsTab = .appearance
    @State var showingThemeSaveField = false
    @State var newThemeName: String = ""
    @State var showingLayoutSaveField = false
    @State var newLayoutProfileName: String = ""
    @State var editingThemeID: UUID?
    @State var themeRenameDraft: String = ""
    @State var themeRenameError: String?
    @State var editingLayoutProfileID: UUID?
    @State var layoutRenameDraft: String = ""
    @State var layoutRenameError: String?
    @State var themeTransferFeedback: UserFeedback?
    @State var themeTransferString: String = ""
    @State var themeTransferMode: ThemeTransferMode?
    @State var layoutTransferFeedback: UserFeedback?
    @State var screenCaptureAccessGranted = ScreenCaptureAuthorization.isGranted
    @State private var settingsScrollView: NSScrollView?
    @State private var settingsPreviewSession: SettingsGlowPreviewSession
    @State var chordPreviewActive = false
    @State var chordPreviewTask: Task<Void, Never>?
    @State var configurationSnapshots: [ConfigurationSnapshotDocument] = []
    @State var newConfigurationSnapshotName = ""
    @State var editingConfigurationSnapshotID: UUID?
    @State var configurationSnapshotRenameDraft = ""
    @State var configurationSnapshotRenameError: String?
    @State var snapshotConfirmation: SnapshotConfirmation?
    @State var snapshotFilePanelHelper =
        ConfigurationSnapshotFilePanelHelper()

    @State var pendingDeletions: [PendingDeletionID: PendingDeletionState] = [:]
    @State private var pendingDeletionTasks: [PendingDeletionID: Task<Void, Never>] = [:]
    @State private var deletionConfirmation: PendingDeletionConfirmation?

    private let inlineUndoSeconds = 10
    private let maxLayoutImportFileSize = PersistenceValidation.maximumLayoutImportSize

    init(
        model: KeyLightModel,
        settings: SettingsManager,
        keyLayoutStore: KeyLayoutStore,
        updateService: UpdateService
    ) {
        self.model = model
        self.settings = settings
        self.updateService = updateService
        _keyLayoutStore = ObservedObject(wrappedValue: keyLayoutStore)
        _settingsPreviewSession = State(initialValue: SettingsGlowPreviewSession(
            show: { [weak model] in
                model?.setPreview(
                    .preview(
                        .settings,
                        horizontalPosition: 0.5,
                        keyWidth: 1
                    ),
                    source: .settings
                )
            },
            hide: { [weak model] in
                model?.clearPreview(.settings)
            }
        ))
    }

    private enum SettingsTab: Hashable {
        case appearance
        case keyboard
        case snapshots
        case general
    }

    enum PendingDeletionID: Hashable {
        case theme(UUID)
        case layout(UUID)
        case configurationSnapshot(UUID)
    }

    enum PendingDeletionKind {
        case theme(item: Theme, wasActive: Bool)
        case layout(item: KeyMappingProfile, wasActive: Bool)
        case configurationSnapshot(
            item: ConfigurationSnapshotDocument,
            index: Int
        )
    }

    struct PendingDeletionState {
        let deletion: PendingDeletionKind
        var secondsRemaining: Int
    }

    struct PendingDeletionConfirmation: Identifiable {
        let id = UUID()
        let deletion: PendingDeletionKind

        var title: String {
            switch deletion {
            case .theme(let item, _):
                return String(localized: "Delete Theme \"\(item.name)\"?")
            case .layout(let item, _):
                return String(localized: "Delete Layout \"\(item.name)\"?")
            case .configurationSnapshot(let item, _):
                return String(
                    localized: "Delete Snapshot \"\(item.name)\"?"
                )
            }
        }

        var message: String {
            String(localized: "This removes the saved item. You can undo for ten seconds.")
        }
    }

    enum SnapshotConfirmation: Identifiable {
        case apply(ConfigurationSnapshotDocument)
        case importConflict(ConfigurationSnapshotDocument)
        case restorePrevious

        var id: String {
            switch self {
            case .apply(let document):
                return "apply-\(document.id.uuidString)"
            case .importConflict(let document):
                return "import-\(document.id.uuidString)"
            case .restorePrevious:
                return "restore-previous"
            }
        }

        var title: String {
            switch self {
            case .apply(let document):
                return String(localized: "Apply \"\(document.name)\"?")
            case .importConflict(let document):
                return String(
                    localized: "A Snapshot Named \"\(document.name)\" Exists"
                )
            case .restorePrevious:
                return String(localized: "Restore Previous Setup?")
            }
        }

        var message: String {
            switch self {
            case .apply:
                return String(
                    localized: "KeyLight will replace its managed appearance, layout, display routing, and shortcut settings. Restore Previous Setup can reverse it."
                )
            case .importConflict:
                return String(
                    localized: "Replace the saved snapshot or keep both by saving a numbered copy. Importing does not apply it."
                )
            case .restorePrevious:
                return String(
                    localized: "KeyLight will swap the current managed setup with the hidden recovery setup. You can use this button again to swap back."
                )
            }
        }
    }

    private struct EffectPreviewConfiguration: Equatable {
        let effectStyle: EffectStyle
        let shapeProfile: SurfaceShapeProfile
        let colorMode: ColorMode
        let glowColorHex: String?
        let gradientStartHex: String?
        let gradientEndHex: String?
        let opacity: Double
        let height: Double
        let width: Double
        let roundness: Double
        let fullness: Double
        let fadeDuration: Double
    }

    var selectedGradientPresetID: UUID? {
        let currentStart = model.gradientStartColor.toHex()?.uppercased()
        let currentEnd = model.gradientEndColor.toHex()?.uppercased()
        return gradientPresets.first(where: { preset in
            preset.startHex.uppercased() == currentStart && preset.endHex.uppercased() == currentEnd
        })?.id
    }

    var activeLayoutProfile: KeyMappingProfile? {
        keyLayoutStore.selectedProfile
    }

    var activeTheme: Theme? {
        model.selectedTheme
    }

    var activeThemeIsEdited: Bool {
        model.selectedThemeIsEdited
    }

    var activeLayoutIsEdited: Bool {
        keyLayoutStore.selectedProfileIsEdited
    }

    var savedThemes: [Theme] { model.savedThemes }
    var savedLayoutProfiles: [KeyMappingProfile] { keyLayoutStore.savedProfiles }
    var bundledLayoutPresets: [SettingsManager.BundledLayoutPreset] {
        settings.bundledLayoutPresets()
    }
    var currentThemeID: UUID? { model.selectedThemeID }
    var currentLayoutProfileID: UUID? { keyLayoutStore.selectedProfileID }

    var buildIdentity: KeyLightBuildIdentity {
        KeyLightApplicationIdentity.current
    }

    var appVersionDescription: String {
        buildIdentity.versionDescription
    }

    var colorModeAccessibilityValue: String {
        switch model.colorMode {
        case .solid: return "Solid"
        case .positionGradient: return "Position Gradient"
        case .randomPerKey: return "Random Per Key"
        case .rainbow: return "Rainbow"
        }
    }

    var roundnessAccessibilityValue: String {
        if model.glowRoundness < 0.05 { return "Sharp" }
        if model.glowRoundness > 0.95 { return "Round" }
        return "\(Int(model.glowRoundness * 100)) percent"
    }

    var liquidGlassSmoothnessAccessibilityValue: String {
        if model.glowRoundness < 0.05 { return "Compact" }
        if model.glowRoundness > 0.95 { return "Wide and soft" }
        return "\(Int(model.glowRoundness * 100)) percent"
    }

    var hotKeyStatusTitle: String {
        switch model.globalHotKeyStatus {
        case .checking: return "Checking \(model.globalShortcut.displayName)"
        case .registered: return "\(model.globalShortcut.displayName) Registered"
        case .unavailable: return "\(model.globalShortcut.displayName) Unavailable"
        }
    }

    var hotKeyStatusIcon: String {
        switch model.globalHotKeyStatus {
        case .checking: return "clock"
        case .registered: return "checkmark.circle.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    var hotKeyStatusColor: Color {
        switch model.globalHotKeyStatus {
        case .checking: return .secondary
        case .registered: return .green
        case .unavailable: return .orange
        }
    }

    @ViewBuilder
    private var permissionWarning: some View {
        if model.inputMonitoringInstallationIssue != nil ||
            model.inputMonitoringState == .permissionRequired ||
            model.inputMonitoringState == .monitorUnavailable {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Input Monitoring needs attention before KeyLight can detect keys reliably.")
                    .font(.callout)
                Spacer(minLength: 8)
                if selectedSettingsTab != .general {
                    Button("Review") {
                        selectedSettingsTab = .general
                    }
                    .controlSize(.small)
                }
            }
            .padding(10)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Input Monitoring needs attention")
        }
    }

    var liquidGlassRuntimeAvailable: Bool {
        EffectStyle.liquidGlass.isAvailableOnCurrentSystem
    }

    private var resolvedEffectStyle: EffectStyle {
        model.effectStyle.resolvedForCurrentSystem
    }

    private var effectPreviewConfiguration: EffectPreviewConfiguration {
        EffectPreviewConfiguration(
            effectStyle: model.effectStyle,
            shapeProfile: model.surfaceShapeProfile,
            colorMode: model.colorMode,
            glowColorHex: model.glowColor.toHex(),
            gradientStartHex: model.gradientStartColor.toHex(),
            gradientEndHex: model.gradientEndColor.toHex(),
            opacity: model.glowOpacity,
            height: model.glowSize,
            width: model.glowWidth,
            roundness: model.glowRoundness,
            fullness: model.glowFullness,
            fadeDuration: model.fadeDuration
        )
    }

    var body: some View {
        TabView(selection: $selectedSettingsTab) {
            settingsPage(.appearance)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(SettingsTab.appearance)

            settingsPage(.keyboard)
                .tabItem { Label("Keyboard Layout", systemImage: "keyboard") }
                .tag(SettingsTab.keyboard)

            settingsPage(.snapshots)
                .tabItem {
                    Label("Snapshots", systemImage: "square.stack.3d.up")
                }
                .tag(SettingsTab.snapshots)

            settingsPage(.general)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

        }
        .frame(minWidth: 640, minHeight: 580)
        .sheet(item: $themeTransferMode) { mode in
            ThemeTransferSheet(
                mode: mode,
                transferString: $themeTransferString,
                feedback: $themeTransferFeedback,
                onCopy: copyThemeStringToClipboard,
                onImport: {
                    if importThemeString(themeTransferString) {
                        themeTransferMode = nil
                    }
                }
            )
        }
        .alert(item: $deletionConfirmation) { confirmation in
            Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: .destructive(Text("Delete")) {
                    confirmDeletion(confirmation.deletion)
                },
                secondaryButton: .cancel()
            )
        }
        .confirmationDialog(
            snapshotConfirmation?.title ?? "",
            isPresented: Binding(
                get: { snapshotConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        snapshotConfirmation = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            switch snapshotConfirmation {
            case .apply(let document):
                Button("Apply Snapshot") {
                    applyConfigurationSnapshot(document)
                    snapshotConfirmation = nil
                }
                Button("Cancel", role: .cancel) {
                    snapshotConfirmation = nil
                }
            case .importConflict(let document):
                Button("Replace") {
                    storeImportedConfigurationSnapshot(
                        document,
                        policy: .replace
                    )
                    snapshotConfirmation = nil
                }
                Button("Save Copy") {
                    storeImportedConfigurationSnapshot(
                        document,
                        policy: .saveCopy
                    )
                    snapshotConfirmation = nil
                }
                Button("Cancel", role: .cancel) {
                    snapshotConfirmation = nil
                }
            case .restorePrevious:
                Button("Restore Previous Setup") {
                    restorePreviousConfigurationSnapshot()
                    snapshotConfirmation = nil
                }
                Button("Cancel", role: .cancel) {
                    snapshotConfirmation = nil
                }
            case nil:
                EmptyView()
            }
        } message: {
            Text(snapshotConfirmation?.message ?? "")
        }
        .onAppear {
            hexColor = model.glowColor.toHex() ?? "68B8FF"
            screenCaptureAccessGranted = ScreenCaptureAuthorization.isGranted
            reloadPersistedState()
        }
        .onChange(of: effectPreviewConfiguration) { _, _ in
            requestSettingsPreview()
        }
        .onChange(of: model.isEnabled) { _, isEnabled in
            if !isEnabled {
                stopSettingsPreview()
            }
        }
        .onChange(of: selectedSettingsTab) { _, selectedTab in
            if selectedTab != .keyboard {
                stopChordPreviewTest()
            }
        }
        .onChange(of: themeTransferFeedback) { _, feedback in
            if let feedback {
                model.announce(feedback)
            }
        }
        .onChange(of: layoutTransferFeedback) { _, feedback in
            if let feedback {
                model.announce(feedback)
            }
        }
        .onDisappear {
            stopSettingsPreview()
            stopChordPreviewTest()
        }
    }

    @ViewBuilder
    private func settingsPage(_ tab: SettingsTab) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                permissionWarning

                if let feedback = model.feedback {
                    SettingsFeedbackBanner(
                        feedback: feedback,
                        onRecovery: { handleFeedbackRecovery(feedback.recoveryAction) },
                        onDismiss: { model.feedback = nil }
                    )
                }

                ForEach(Array(pendingDeletions.keys), id: \.self) { id in
                    if let pending = pendingDeletions[id] {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            Text(deletedItemDescription(pending.deletion))
                                .font(.callout)
                            Spacer(minLength: 8)
                            Button("Undo (\(pending.secondsRemaining)s)") {
                                cancelPendingDeletion(for: id)
                            }
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(
                            .orange.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .accessibilityElement(children: .contain)
                    }
                }


                switch tab {
                case .appearance:
                    appearanceTabContent
                case .keyboard:
                    keyboardTabContent
                case .snapshots:
                    snapshotsTabContent
                case .general:
                    generalTabContent
                }
            }
            .padding(20)
            .background(
                SettingsScrollViewBridge { scrollView in
                    if selectedSettingsTab == tab, settingsScrollView !== scrollView {
                        settingsScrollView = scrollView
                    }
                }
            )
        }
    }

    func settingsPreviewEditingChanged(_ isEditing: Bool) {
        settingsPreviewSession.editingChanged(
            isEditing,
            isEnabled: model.isEnabled
        )
    }

    private func handleFeedbackRecovery(_ action: UserFeedback.RecoveryAction?) {
        guard let action else { return }
        switch action {
        case .checkAgain, .retry:
            model.retryInputMonitoring()
        case .openInputMonitoringSettings:
            model.openInputMonitoringSettings()
        case .undo:
            // Undo feedback is owned by the operation that created it. Settings
            // does not invent a generic undo target.
            break
        }
        model.feedback = nil
    }

    private func requestSettingsPreview() {
        settingsPreviewSession.configurationChanged(isEnabled: model.isEnabled)
    }

    func stopSettingsPreview() {
        settingsPreviewSession.stop()
    }

    func saveCurrentGradientPreset() {
        let startHex = model.gradientStartColor.toHex() ?? "68B8FF"
        let endHex = model.gradientEndColor.toHex() ?? "00E69A"
        settings.saveGradientPreset(startHex: startHex, endHex: endHex)
        gradientPresets = settings.savedGradientPresets
    }

    private func deleteGradientPreset(_ id: UUID) {
        settings.deleteGradientPreset(id: id)
        gradientPresets = settings.savedGradientPresets
    }

    func deleteSelectedGradientPreset() {
        guard let selectedID = selectedGradientPresetID, gradientPresets.count > 1 else { return }
        deleteGradientPreset(selectedID)
    }

    func queueThemeDeletion(_ theme: Theme) {
        guard theme.name != Theme.defaultTheme.name else { return }
        deletionConfirmation = PendingDeletionConfirmation(
            deletion: .theme(item: theme, wasActive: currentThemeID == theme.id)
        )
    }

    func queueLayoutDeletion(_ profile: KeyMappingProfile) {
        deletionConfirmation = PendingDeletionConfirmation(
            deletion: .layout(item: profile, wasActive: currentLayoutProfileID == profile.id)
        )
    }

    func queueConfigurationSnapshotDeletion(
        _ document: ConfigurationSnapshotDocument
    ) {
        guard let index = configurationSnapshots.firstIndex(where: {
            $0.id == document.id
        }) else { return }
        deletionConfirmation = PendingDeletionConfirmation(
            deletion: .configurationSnapshot(
                item: document,
                index: index
            )
        )
    }

    private func confirmDeletion(_ deletion: PendingDeletionKind) {
        let id: PendingDeletionID
        switch deletion {
        case .theme(let item, _):
            id = .theme(item.id)
            if editingThemeID == item.id {
                cancelThemeRename()
            }
            settings.deleteTheme(named: item.name)
        case .layout(let item, _):
            id = .layout(item.id)
            if editingLayoutProfileID == item.id {
                cancelLayoutProfileRename()
            }
            settings.deleteKeyMappingProfile(named: item.name)
        case .configurationSnapshot(let item, _):
            id = .configurationSnapshot(item.id)
            if editingConfigurationSnapshotID == item.id {
                cancelConfigurationSnapshotRename()
            }
            do {
                _ = try settings.deleteConfigurationSnapshot(id: item.id)
            } catch {
                model.feedback = UserFeedback(
                    severity: .error,
                    title: String(localized: "Snapshot Couldn’t Be Deleted"),
                    detail: error.localizedDescription
                )
                return
            }
        }

        pendingDeletionTasks[id]?.cancel()
        pendingDeletions[id] = PendingDeletionState(deletion: deletion, secondsRemaining: inlineUndoSeconds)
        reloadPersistedState()
        model.feedback = UserFeedback(
            severity: .success,
            title: String(localized: "Saved Item Deleted"),
            detail: String(localized: "Choose Undo within ten seconds to restore it."),
            recoveryAction: .undo
        )
        pendingDeletionTasks[id] = Task {
            var remaining = inlineUndoSeconds
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                remaining -= 1

                await MainActor.run {
                    guard var pending = pendingDeletions[id] else { return }
                    if remaining == 0 {
                        pendingDeletions[id] = nil
                        pendingDeletionTasks[id] = nil
                    } else {
                        pending.secondsRemaining = remaining
                        pendingDeletions[id] = pending
                    }
                }
            }
        }
    }

    func cancelPendingDeletion(for id: PendingDeletionID) {
        guard let pending = pendingDeletions[id] else { return }
        pendingDeletionTasks[id]?.cancel()
        pendingDeletionTasks[id] = nil
        pendingDeletions[id] = nil

        switch pending.deletion {
        case .theme(let item, let wasActive):
            settings.saveTheme(item)
            if wasActive {
                settings.activeThemeID = item.id
            }
        case .layout(let item, let wasActive):
            _ = settings.saveKeyMappingProfile(item)
            if wasActive {
                settings.activeLayoutID = item.id
            }
        case .configurationSnapshot(let item, let index):
            do {
                try settings.restoreDeletedConfigurationSnapshot(
                    item,
                    at: index
                )
            } catch {
                model.feedback = UserFeedback(
                    severity: .error,
                    title: String(localized: "Snapshot Couldn’t Be Restored"),
                    detail: error.localizedDescription
                )
                return
            }
        }
        reloadPersistedState()
        model.feedback = UserFeedback(
            severity: .success,
            title: String(localized: "Deletion Undone"),
            detail: String(localized: "The saved item was restored.")
        )
    }

    private func deletedItemDescription(_ deletion: PendingDeletionKind) -> String {
        switch deletion {
        case .theme(let item, _):
            return String(localized: "Deleted theme \"\(item.name)\".")
        case .layout(let item, _):
            return String(localized: "Deleted layout \"\(item.name)\".")
        case .configurationSnapshot(let item, _):
            return String(localized: "Deleted snapshot \"\(item.name)\".")
        }
    }

    private func copyThemeStringToClipboard() {
        if themeTransferString.isEmpty {
            refreshThemeTransferStringFromActiveTheme()
        }
        guard !themeTransferString.isEmpty else {
            themeTransferFeedback = UserFeedback(
                severity: .error,
                title: String(localized: "Theme Couldn’t Be Shared"),
                detail: String(localized: "KeyLight could not encode the current theme.")
            )
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(themeTransferString, forType: .string) {
            themeTransferFeedback = UserFeedback(
                severity: .success,
                title: String(localized: "Theme String Copied")
            )
        } else {
            themeTransferFeedback = UserFeedback(
                severity: .error,
                title: String(localized: "Theme Couldn’t Be Copied"),
                detail: String(localized: "The system pasteboard did not accept the theme string.")
            )
        }
    }

    @discardableResult
    private func importThemeString(_ value: String) -> Bool {
        do {
            let theme = try settings.importThemeString(value)
            settings.saveTheme(theme)
            let persistedTheme = settings.savedThemes.first(where: { $0.name == theme.name }) ?? theme
            preserveScrollOffset {
                model.applyTheme(persistedTheme)
                settings.activeThemeID = persistedTheme.id
                reloadPersistedState()
            }
            requestSettingsPreview()
            themeTransferFeedback = UserFeedback(
                severity: .success,
                title: String(localized: "Theme Imported"),
                detail: String(localized: "Applied \"\(persistedTheme.name)\".")
            )
            return true
        } catch {
            themeTransferFeedback = UserFeedback(
                severity: .error,
                title: String(localized: "Theme Import Failed"),
                detail: error.localizedDescription
            )
            return false
        }
    }

    func selectTheme(_ theme: Theme, isActive: Bool) {
        guard !isActive else { return }
        preserveScrollOffset {
            model.applyTheme(theme)
            settings.activeThemeID = theme.id
            reloadPersistedState()
        }
        requestSettingsPreview()
    }

    func selectLayoutProfile(_ profile: KeyMappingProfile, isActive: Bool) {
        guard !isActive else { return }
        preserveScrollOffset {
            applyLayoutProfile(profile)
            reloadPersistedState()
        }
    }

    func applyBundledLayoutPreset(_ preset: SettingsManager.BundledLayoutPreset) {
        do {
            let profile: KeyMappingProfile
            if let existing = savedLayoutProfiles.first(where: {
                $0.name.caseInsensitiveCompare(preset.displayName) == .orderedSame
            }) {
                profile = existing
            } else {
                let imported = try settings.importBundledLayoutPreset(preset)
                guard let persisted = settings.saveKeyMappingProfile(imported) else {
                    layoutTransferFeedback = UserFeedback(
                        severity: .error,
                        title: String(localized: "Layout Preset Couldn’t Be Applied"),
                        detail: String(localized: "The preset could not be saved as a keyboard layout.")
                    )
                    return
                }
                profile = persisted
            }
            applyLayoutProfile(profile)
            reloadPersistedState()
            layoutTransferFeedback = UserFeedback(
                severity: .success,
                title: String(localized: "Layout Preset Applied"),
                detail: String(localized: "Applied \"\(profile.name)\". Use Calibrate Keyboard for device-specific fine tuning.")
            )
        } catch {
            layoutTransferFeedback = UserFeedback(
                severity: .error,
                title: String(localized: "Layout Preset Couldn’t Be Applied"),
                detail: error.localizedDescription
            )
        }
    }

    private func applyLayoutProfile(_ profile: KeyMappingProfile) {
        keyLayoutStore.apply(
            KeyLayout(
                offsets: profile.keyOffsets,
                widthMultipliers: profile.keyWidthOverrides
            ),
            asBaseline: true
        )
        settings.activeLayoutID = profile.id
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

    func exportActiveLayoutProfile() {
        var liveProfile = activeLayoutProfile ?? KeyMappingProfile(
            name: "Current Layout",
            keyOffsets: [:],
            keyWidthOverrides: [:]
        )
        liveProfile.keyOffsets = keyLayoutStore.layout.offsets
        liveProfile.keyWidthOverrides = keyLayoutStore.layout.widthMultipliers
        guard let data = settings.exportLayoutProfileData(liveProfile) else {
            layoutTransferFeedback = UserFeedback(
                severity: .error,
                title: String(localized: "Layout Couldn’t Be Exported"),
                detail: String(localized: "KeyLight could not encode the current layout.")
            )
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "KeyLight-Layout-\(safeFilename(liveProfile.name)).json"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
                layoutTransferFeedback = UserFeedback(
                    severity: .success,
                    title: String(localized: "Layout Exported"),
                    detail: String(localized: "Saved the current layout as \"\(liveProfile.name)\".")
                )
            } catch {
                layoutTransferFeedback = UserFeedback(
                    severity: .error,
                    title: String(localized: "Layout Export Failed"),
                    detail: error.localizedDescription
                )
            }
        } else {
            layoutTransferFeedback = nil
        }
    }

    func importLayoutProfile() {
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

                let importedProfile = try settings.importLayoutProfileData(data)
                guard let persistedProfile = settings.saveKeyMappingProfile(importedProfile) else {
                    throw NSError(
                        domain: "KeyLight",
                        code: 26,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "A layout with that name already exists."
                            )
                        ]
                    )
                }
                applyLayoutProfile(persistedProfile)
                reloadPersistedState()
                layoutTransferFeedback = UserFeedback(
                    severity: .success,
                    title: String(localized: "Layout Imported"),
                    detail: String(localized: "Applied \"\(persistedProfile.name)\".")
                )
            } catch SettingsImportValidationError.fileTooLarge {
                layoutTransferFeedback = UserFeedback(
                    severity: .error,
                    title: String(localized: "Layout Import Failed"),
                    detail: String(localized: "The file is too large (maximum 1 MB).")
                )
            } catch {
                layoutTransferFeedback = UserFeedback(
                    severity: .error,
                    title: String(localized: "Layout Import Failed"),
                    detail: error.localizedDescription
                )
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

    func startThemeRename(_ theme: Theme) {
        editingThemeID = theme.id
        themeRenameDraft = theme.name
        themeRenameError = nil
    }

    func cancelThemeRename() {
        editingThemeID = nil
        themeRenameDraft = ""
        themeRenameError = nil
    }

    func themeRenameValidation(for theme: Theme) -> String? {
        guard let normalizedName = PersistenceValidation.normalizedName(themeRenameDraft) else {
            return String(localized: "Name cannot be empty.")
        }
        if normalizedName.caseInsensitiveCompare(theme.name) == .orderedSame {
            return nil
        }
        let exists = savedThemes.contains { existing in
            existing.id != theme.id &&
                existing.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }
        return exists ? String(localized: "Theme name already exists.") : nil
    }

    func saveThemeRename(_ theme: Theme) {
        if let error = themeRenameValidation(for: theme) {
            themeRenameError = error
            return
        }
        guard let newName = PersistenceValidation.normalizedName(themeRenameDraft),
              settings.renameTheme(from: theme.name, to: newName) else {
            themeRenameError = String(localized: "Choose a unique name up to 100 characters.")
            return
        }
        reloadPersistedState()
        cancelThemeRename()
        themeTransferFeedback = UserFeedback(
            severity: .success,
            title: String(localized: "Theme Renamed"),
            detail: String(localized: "Renamed \"\(theme.name)\" to \"\(newName)\".")
        )
    }

    func startLayoutProfileRename(_ profile: KeyMappingProfile) {
        editingLayoutProfileID = profile.id
        layoutRenameDraft = profile.name
        layoutRenameError = nil
    }

    func cancelLayoutProfileRename() {
        editingLayoutProfileID = nil
        layoutRenameDraft = ""
        layoutRenameError = nil
    }

    func layoutRenameValidation(for profile: KeyMappingProfile) -> String? {
        guard let normalizedName = PersistenceValidation.normalizedName(layoutRenameDraft) else {
            return String(localized: "Name cannot be empty.")
        }
        if normalizedName.caseInsensitiveCompare(profile.name) == .orderedSame {
            return nil
        }
        let exists = savedLayoutProfiles.contains { existing in
            existing.id != profile.id &&
                existing.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }
        return exists ? String(localized: "Layout profile name already exists.") : nil
    }

    func saveLayoutProfileRename(_ profile: KeyMappingProfile) {
        if let error = layoutRenameValidation(for: profile) {
            layoutRenameError = error
            return
        }
        guard let newName = PersistenceValidation.normalizedName(layoutRenameDraft),
              settings.renameKeyMappingProfile(from: profile.name, to: newName) else {
            layoutRenameError = String(localized: "Choose a unique name up to 100 characters.")
            return
        }
        reloadPersistedState()
        cancelLayoutProfileRename()
        layoutTransferFeedback = UserFeedback(
            severity: .success,
            title: String(localized: "Layout Renamed"),
            detail: String(localized: "Renamed \"\(profile.name)\" to \"\(newName)\".")
        )
    }

    func normalizedHex(_ value: String?, fallback: String = "") -> String {
        (value ?? fallback).uppercased()
    }

    private func liveThemeSnapshot(id: UUID, name: String) -> Theme {
        Theme(
            id: id,
            name: name,
            colorHex: normalizedHex(model.glowColor.toHex(), fallback: "68B8FF"),
            opacity: model.glowOpacity,
            size: model.glowSize,
            width: model.glowWidth,
            glowRoundness: model.glowRoundness,
            glowFullness: model.glowFullness,
            fadeDuration: model.fadeDuration,
            colorMode: model.colorMode,
            effectStyle: model.effectStyle,
            shapeProfile: model.surfaceShapeProfile,
            gradientStartHex: normalizedHex(model.gradientStartColor.toHex(), fallback: "68B8FF"),
            gradientEndHex: normalizedHex(model.gradientEndColor.toHex(), fallback: "00E69A")
        )
    }

    @discardableResult
    func saveCurrentThemeAs(_ requestedName: String) -> Bool {
        guard let name = PersistenceValidation.normalizedName(requestedName) else { return false }
        guard !savedThemes.contains(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            themeTransferFeedback = UserFeedback(
                severity: .error,
                title: String(localized: "Theme Couldn’t Be Saved"),
                detail: String(localized: "A theme named \"\(name)\" already exists.")
            )
            return false
        }
        let theme = liveThemeSnapshot(id: UUID(), name: name)
        settings.saveTheme(theme)
        if let saved = settings.savedThemes.first(where: { $0.name == name }) {
            settings.activeThemeID = saved.id
        }
        reloadPersistedState()
        themeTransferFeedback = UserFeedback(
            severity: .success,
            title: String(localized: "Theme Saved"),
            detail: String(localized: "Saved \"\(name)\".")
        )
        return true
    }

    func updateActiveTheme() {
        guard let activeTheme else { return }
        settings.saveTheme(
            liveThemeSnapshot(id: activeTheme.id, name: activeTheme.name)
        )
        settings.activeThemeID = activeTheme.id
        reloadPersistedState()
        themeTransferFeedback = UserFeedback(
            severity: .success,
            title: String(localized: "Theme Updated"),
            detail: String(localized: "Saved the current appearance to \"\(activeTheme.name)\".")
        )
    }

    func revertActiveTheme() {
        guard let activeTheme else { return }
        model.applyTheme(activeTheme)
        settings.activeThemeID = activeTheme.id
        reloadPersistedState()
        requestSettingsPreview()
    }

    func updateActiveLayoutProfile() {
        guard var profile = activeLayoutProfile else { return }
        profile.keyOffsets = keyLayoutStore.layout.offsets
        profile.keyWidthOverrides = keyLayoutStore.layout.widthMultipliers
        settings.saveKeyMappingProfile(profile)
        keyLayoutStore.markCurrentAsBaseline()
        reloadPersistedState()
        layoutTransferFeedback = UserFeedback(
            severity: .success,
            title: String(localized: "Layout Updated"),
            detail: String(localized: "Saved the current calibration to \"\(profile.name)\".")
        )
    }

    func revertActiveLayoutProfile() {
        guard let activeLayoutProfile else { return }
        applyLayoutProfile(activeLayoutProfile)
        reloadPersistedState()
    }

    func themeDisplayName(_ theme: Theme, isActive: Bool) -> String {
        isActive && activeThemeIsEdited
            ? String(localized: "\(theme.name) · Edited")
            : theme.name
    }

    func layoutDisplayName(_ profile: KeyMappingProfile, isActive: Bool) -> String {
        isActive && activeLayoutIsEdited
            ? String(localized: "\(profile.name) · Edited")
            : profile.name
    }

    func themeSelectionAccessibilityValue(isActive: Bool, isEdited: Bool) -> String {
        guard isActive else { return String(localized: "Not selected") }
        return isEdited
            ? String(localized: "Selected, edited")
            : String(localized: "Selected")
    }

    func reloadPersistedState() {
        gradientPresets = settings.savedGradientPresets
        configurationSnapshots = settings.configurationSnapshots
        model.reloadSavedThemes()
        keyLayoutStore.reloadSavedProfiles(from: settings)

        if let editingThemeID, !savedThemes.contains(where: { $0.id == editingThemeID }) {
            cancelThemeRename()
        }
        if let editingLayoutProfileID, !savedLayoutProfiles.contains(where: { $0.id == editingLayoutProfileID }) {
            cancelLayoutProfileRename()
        }
        if let editingConfigurationSnapshotID,
           !configurationSnapshots.contains(where: {
               $0.id == editingConfigurationSnapshotID
           }) {
            cancelConfigurationSnapshotRename()
        }
    }

    func refreshThemeTransferStringFromActiveTheme() {
        let liveTheme = liveThemeSnapshot(
            id: activeTheme?.id ?? UUID(),
            name: activeTheme?.name ?? settings.currentThemeName
        )
        themeTransferString = settings.exportThemeString(liveTheme) ?? ""
    }

    func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func startChordPreviewTest() {
        chordPreviewTask?.cancel()
        let keyCodes: [UInt16] = [0, 1, 2, 3] // A, S, D, F: adjacent and visually diagnostic.
        let targets = zip(PreviewSource.chordTestSources, keyCodes).map { source, keyCode in
            let keyInfo = KeyMapping.keyInfo(for: keyCode)
            return GlowTarget.preview(
                source,
                colorReferenceKeyCode: keyCode,
                horizontalPosition: Double(keyLayoutStore.adjustedPosition(
                    for: keyCode,
                    originalPosition: keyInfo.position
                )),
                keyWidth: Double(keyLayoutStore.effectiveWidth(
                    for: keyCode,
                    defaultWidth: keyInfo.width
                ))
            )
        }
        model.setChordPreview(targets)
        chordPreviewActive = true
        chordPreviewTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            stopChordPreviewTest()
        }
    }

    func stopChordPreviewTest() {
        chordPreviewTask?.cancel()
        chordPreviewTask = nil
        guard chordPreviewActive else { return }
        chordPreviewActive = false
        model.clearChordPreview()
    }
}
