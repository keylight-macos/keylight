import SwiftUI

extension SettingsView {
    @ViewBuilder
    var snapshotsTabContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Configuration Snapshots")
                .font(.title2.bold())
            Text("Save or transfer the complete KeyLight-managed appearance, keyboard, display-routing, and shortcut setup. Permissions, enabled state, and Launch at Login are never included.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        Divider()

        VStack(alignment: .leading, spacing: 10) {
            Text("Save Current")
                .font(.headline)
            HStack {
                TextField(
                    "Snapshot name",
                    text: $newConfigurationSnapshotName
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveCurrentConfigurationSnapshot() }

                Button("Save Current") {
                    saveCurrentConfigurationSnapshot()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    PersistenceValidation.normalizedName(
                        newConfigurationSnapshotName
                    ) == nil
                )
            }

            HStack {
                Button("Import…") {
                    importConfigurationSnapshot()
                }
                Button("Restore Previous Setup") {
                    snapshotConfirmation = .restorePrevious
                }
                .disabled(!settings.hasPreviousConfigurationSnapshot)
                Spacer()
                Text("Up to 1 MB per import · 500 KB saved data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        Divider()

        if configurationSnapshots.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No Saved Snapshots")
                    .font(.headline)
                Text("Save the current setup or import a .keylight-snapshot.json file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Saved Snapshots")
                    .font(.headline)

                ForEach(configurationSnapshots) { document in
                    configurationSnapshotRow(document)
                    if document.id != configurationSnapshots.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func configurationSnapshotRow(
        _ document: ConfigurationSnapshotDocument
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                if editingConfigurationSnapshotID == document.id {
                    TextField(
                        "Snapshot name",
                        text: $configurationSnapshotRenameDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        saveConfigurationSnapshotRename(document)
                    }
                    Button("Save") {
                        saveConfigurationSnapshotRename(document)
                    }
                    Button("Cancel") {
                        cancelConfigurationSnapshotRename()
                    }
                } else {
                    Text(document.name)
                        .font(.body.weight(.semibold))
                    Spacer()
                    Text(
                        document.createdAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if editingConfigurationSnapshotID == document.id,
               let configurationSnapshotRenameError {
                Text(configurationSnapshotRenameError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text(configurationSnapshotSummary(document))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Apply") {
                    snapshotConfirmation = .apply(document)
                }
                .buttonStyle(.borderedProminent)
                Button("Rename") {
                    startConfigurationSnapshotRename(document)
                }
                .disabled(editingConfigurationSnapshotID == document.id)
                Button("Export…") {
                    exportConfigurationSnapshot(document)
                }
                Button("Delete", role: .destructive) {
                    queueConfigurationSnapshotDeletion(document)
                }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    func saveCurrentConfigurationSnapshot() {
        model.flushPendingPersist()
        keyLayoutStore.flush()
        do {
            let document = try settings.saveCurrentConfigurationSnapshot(
                named: newConfigurationSnapshotName
            )
            newConfigurationSnapshotName = ""
            reloadPersistedState()
            model.feedback = UserFeedback(
                severity: .success,
                title: String(localized: "Configuration Snapshot Saved"),
                detail: String(localized: "Saved \"\(document.name)\".")
            )
        } catch {
            model.feedback = UserFeedback(
                severity: .error,
                title: String(localized: "Snapshot Couldn’t Be Saved"),
                detail: error.localizedDescription
            )
        }
    }

    func startConfigurationSnapshotRename(
        _ document: ConfigurationSnapshotDocument
    ) {
        editingConfigurationSnapshotID = document.id
        configurationSnapshotRenameDraft = document.name
        configurationSnapshotRenameError = nil
    }

    func cancelConfigurationSnapshotRename() {
        editingConfigurationSnapshotID = nil
        configurationSnapshotRenameDraft = ""
        configurationSnapshotRenameError = nil
    }

    func saveConfigurationSnapshotRename(
        _ document: ConfigurationSnapshotDocument
    ) {
        do {
            let renamed = try settings.renameConfigurationSnapshot(
                id: document.id,
                to: configurationSnapshotRenameDraft
            )
            cancelConfigurationSnapshotRename()
            reloadPersistedState()
            model.feedback = UserFeedback(
                severity: .success,
                title: String(localized: "Configuration Snapshot Renamed"),
                detail: String(localized: "Renamed to \"\(renamed.name)\".")
            )
        } catch {
            configurationSnapshotRenameError = error.localizedDescription
        }
    }

    func applyConfigurationSnapshot(
        _ document: ConfigurationSnapshotDocument
    ) {
        prepareCurrentConfigurationForSnapshotTransaction()
        do {
            try settings.applyConfigurationSnapshot(document)
            reloadAfterConfigurationSnapshotTransaction()
            model.feedback = UserFeedback(
                severity: .success,
                title: String(localized: "Configuration Snapshot Applied"),
                detail: String(
                    localized: "Applied \"\(document.name)\". Restore Previous Setup can reverse this change."
                )
            )
        } catch {
            reloadAfterConfigurationSnapshotTransaction()
            model.feedback = UserFeedback(
                severity: .error,
                title: String(localized: "Snapshot Couldn’t Be Applied"),
                detail: error.localizedDescription
            )
        }
    }

    func restorePreviousConfigurationSnapshot() {
        prepareCurrentConfigurationForSnapshotTransaction()
        do {
            try settings.restorePreviousConfigurationSnapshot()
            reloadAfterConfigurationSnapshotTransaction()
            model.feedback = UserFeedback(
                severity: .success,
                title: String(localized: "Previous Setup Restored"),
                detail: String(
                    localized: "The setup was swapped successfully. Choose Restore Previous Setup again to swap back."
                )
            )
        } catch {
            reloadAfterConfigurationSnapshotTransaction()
            model.feedback = UserFeedback(
                severity: .error,
                title: String(localized: "Previous Setup Couldn’t Be Restored"),
                detail: error.localizedDescription
            )
        }
    }

    func importConfigurationSnapshot() {
        do {
            guard let data = try snapshotFilePanelHelper.chooseImportData()
            else { return }
            let document = try settings.decodeConfigurationSnapshotDocument(
                data
            )
            if settings.configurationSnapshotNameConflicts(with: document) {
                snapshotConfirmation = .importConflict(document)
            } else {
                storeImportedConfigurationSnapshot(
                    document,
                    policy: .rejectConflict
                )
            }
        } catch {
            model.feedback = UserFeedback(
                severity: .error,
                title: String(localized: "Snapshot Import Failed"),
                detail: error.localizedDescription
            )
        }
    }

    func storeImportedConfigurationSnapshot(
        _ document: ConfigurationSnapshotDocument,
        policy: ConfigurationSnapshotImportPolicy
    ) {
        do {
            let imported = try settings.importConfigurationSnapshot(
                document,
                policy: policy
            )
            reloadPersistedState()
            model.feedback = UserFeedback(
                severity: .success,
                title: String(localized: "Configuration Snapshot Imported"),
                detail: String(
                    localized: "Stored \"\(imported.name)\" without applying it."
                )
            )
        } catch {
            model.feedback = UserFeedback(
                severity: .error,
                title: String(localized: "Snapshot Import Failed"),
                detail: error.localizedDescription
            )
        }
    }

    func exportConfigurationSnapshot(
        _ document: ConfigurationSnapshotDocument
    ) {
        do {
            let data = try settings.exportConfigurationSnapshotData(
                id: document.id
            )
            guard let url = try snapshotFilePanelHelper.export(
                data,
                suggestedName: document.name
            ) else { return }
            model.feedback = UserFeedback(
                severity: .success,
                title: String(localized: "Configuration Snapshot Exported"),
                detail: String(localized: "Saved \"\(url.lastPathComponent)\".")
            )
        } catch {
            model.feedback = UserFeedback(
                severity: .error,
                title: String(localized: "Snapshot Export Failed"),
                detail: error.localizedDescription
            )
        }
    }

    private func prepareCurrentConfigurationForSnapshotTransaction() {
        stopSettingsPreview()
        stopChordPreviewTest()
        model.flushPendingPersist()
        keyLayoutStore.flush()
        keyLayoutStore.cancelPendingWork()
    }

    private func reloadAfterConfigurationSnapshotTransaction() {
        keyLayoutStore.reloadFromPersistence()
        keyLayoutStore.reloadSavedProfiles(from: settings)
        model.reloadManagedConfiguration()
        hexColor = model.glowColor.toHex() ?? "68B8FF"
        reloadPersistedState()
    }

    private func configurationSnapshotSummary(
        _ document: ConfigurationSnapshotDocument
    ) -> String {
        let configuration = document.configuration
        let displayCount = 1 + configuration.mirroredDisplayIDs.count
        return String(
            localized: "\(configuration.themes.count) themes · \(configuration.layoutProfiles.count) layouts · \(displayCount) display routes · \(configuration.currentEffect.style.displayName)"
        )
    }
}
