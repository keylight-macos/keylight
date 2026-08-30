import SwiftUI

extension SettingsView {
    @ViewBuilder
    var keyboardTabContent: some View {
        Divider()

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Multi-Key Chord Test")
                        .font(.headline)
                    Text("Temporarily lights A–S–D–F together using the active layout. The test is not saved and records no typing.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 12)
                Button(chordPreviewActive ? "Testing…" : "Test Four Keys") {
                    startChordPreviewTest()
                }
                .buttonStyle(.borderedProminent)
                .disabled(chordPreviewActive || !model.isEnabled)
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text("Display Routing")
                .font(.headline)

            Text("Choose where KeyLight appears. Automatic keeps the original built-in-first behavior and safely falls back when a display disconnects.")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Glow Display", selection: Binding(
                get: { model.overlayDisplaySelection },
                set: { model.overlayDisplaySelection = $0 }
            )) {
                Text("Automatic (Built-in First)").tag(OverlayDisplaySelection.automatic)
                Text("Built-in Display").tag(OverlayDisplaySelection.builtIn)
                Text("Main Display").tag(OverlayDisplaySelection.main)

                ForEach(model.availableDisplays) { display in
                    Text(displaySelectionLabel(display))
                        .tag(OverlayDisplaySelection.specific(display.id))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Mirror to Additional Displays")
                    .font(.subheadline.weight(.semibold))

                let additionalDisplays = model.availableDisplays.filter {
                    $0.id != model.activeDisplayPersistentID
                }
                if additionalDisplays.isEmpty
                    && unavailableMirroredDisplayIDs.isEmpty {
                    Text("No additional displays are connected.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(additionalDisplays) { display in
                        Toggle(
                            displaySelectionLabel(display),
                            isOn: mirroredDisplayBinding(for: display.id)
                        )
                    }
                    ForEach(unavailableMirroredDisplayIDs, id: \.self) { displayID in
                        Toggle(
                            "Unavailable display (\(displayID))",
                            isOn: mirroredDisplayBinding(for: displayID)
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                Text("Every selected display uses the currently active keyboard layout and the same held-key state.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let activeDisplay = activeOverlayDisplay {
                Text("Active: \(displaySelectionLabel(activeDisplay))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Layout on This Display", selection: Binding<UUID?>(
                    get: { model.boundLayoutProfileID(forDisplay: activeDisplay.id) },
                    set: { model.setLayoutProfileBinding($0, forDisplay: activeDisplay.id) }
                )) {
                    Text("Keep Current Layout").tag(Optional<UUID>.none)
                    ForEach(savedLayoutProfiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .disabled(savedLayoutProfiles.isEmpty)

                Text("A bound profile is applied when this display becomes active. Unsaved calibration edits are never discarded.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("No active display is available.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if model.activeDisplayPersistentIDs.count > 1 {
                Text("Rendering on \(model.activeDisplayPersistentIDs.count) displays")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                let isActive = currentLayoutProfileID == profile.id
                let pendingID = PendingDeletionID.layout(profile.id)
                let pendingState = pendingDeletions[pendingID]

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
                            Button {
                                selectLayoutProfile(profile, isActive: isActive)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                                        .accessibilityHidden(true)
                                    Text(layoutDisplayName(profile, isActive: isActive))
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isActive)
                            .accessibilityLabel("Keyboard layout \(profile.name)")
                            .accessibilityValue(themeSelectionAccessibilityValue(isActive: isActive, isEdited: isActive && activeLayoutIsEdited))

                            if let pendingState {
                                Button("Undo (\(pendingState.secondsRemaining)s)") {
                                    cancelPendingDeletion(for: pendingID)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            } else {
                                Menu {
                                    Button("Rename…") {
                                        startLayoutProfileRename(profile)
                                    }

                                    Button("Delete", role: .destructive) {
                                        queueLayoutDeletion(profile)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("Layout profile actions")
                                .accessibilityLabel("Actions for keyboard layout \(profile.name)")
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
                .padding(.vertical, 0.5)
            }

            if showingLayoutSaveField {
                HStack {
                    TextField("Layout profile name", text: $newLayoutProfileName)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        guard let normalizedName = PersistenceValidation.normalizedName(
                            newLayoutProfileName
                        ) else {
                            return
                        }
                        guard !savedLayoutProfiles.contains(where: {
                            $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
                        }) else {
                            layoutTransferFeedback = UserFeedback(
                                severity: .error,
                                title: String(localized: "Layout Couldn’t Be Saved"),
                                detail: String(localized: "A layout named \"\(normalizedName)\" already exists.")
                            )
                            return
                        }
                        let profile = KeyMappingProfile(
                            name: normalizedName,
                            keyOffsets: keyLayoutStore.layout.offsets,
                            keyWidthOverrides: keyLayoutStore.layout.widthMultipliers
                        )
                        if let persisted = settings.saveKeyMappingProfile(profile) {
                            keyLayoutStore.markCurrentAsBaseline()
                            reloadPersistedState()
                            showingLayoutSaveField = false
                            newLayoutProfileName = ""
                            layoutTransferFeedback = UserFeedback(
                                severity: .success,
                                title: String(localized: "Layout Saved"),
                                detail: String(localized: "Saved \"\(persisted.name)\".")
                            )
                        } else {
                            layoutTransferFeedback = UserFeedback(
                                severity: .error,
                                title: String(localized: "Layout Couldn’t Be Saved"),
                                detail: String(localized: "Choose a unique name up to 100 characters.")
                            )
                        }
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
                HStack(spacing: 8) {
                    Button("Update Layout") {
                        updateActiveLayoutProfile()
                    }
                    .controlSize(.small)
                    .disabled(activeLayoutProfile == nil || !activeLayoutIsEdited)
                    .accessibilityHint("Replaces the selected layout with the current calibration")

                    Button("Save As…") {
                        showingLayoutSaveField = true
                    }
                    .controlSize(.small)

                    Menu("Add Preset…") {
                        ForEach(bundledLayoutPresets) { preset in
                            Button(preset.displayName) {
                                applyBundledLayoutPreset(preset)
                            }
                        }
                    }
                    .controlSize(.small)
                    .disabled(bundledLayoutPresets.isEmpty)

                    Button("Revert") {
                        revertActiveLayoutProfile()
                    }
                    .controlSize(.small)
                    .disabled(activeLayoutProfile == nil || !activeLayoutIsEdited)
                    .accessibilityHint("Restores the selected layout's saved calibration")

                    Spacer()

                    Button("Export Current…") {
                        exportActiveLayoutProfile()
                    }
                    .controlSize(.small)

                    Button("Import…") {
                        importLayoutProfile()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                Button("Guided Calibration…") {
                    KeyLightWindowActivation.present(.guidedCalibration) {
                        openWindow(id: KeyLightSceneID.guidedCalibration)
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Fine-Tune Manually…") {
                    KeyLightWindowActivation.present(.keyEditor) {
                        openWindow(id: KeyLightSceneID.keyEditor)
                    }
                }
                .buttonStyle(.link)
            }

            if let layoutTransferFeedback {
                InlineSettingsFeedback(feedback: layoutTransferFeedback)
            }
        }
    }

    private var activeOverlayDisplay: OverlayDisplayDescriptor? {
        guard let activeID = model.activeDisplayPersistentID else { return nil }
        return model.availableDisplays.first(where: { $0.id == activeID })
    }

    private func displaySelectionLabel(_ display: OverlayDisplayDescriptor) -> String {
        var details: [String] = []
        if display.isBuiltIn { details.append(String(localized: "Built-in")) }
        if display.isMain { details.append(String(localized: "Main")) }
        return details.isEmpty
            ? display.name
            : "\(display.name) (\(details.joined(separator: ", ")))"
    }

    private var unavailableMirroredDisplayIDs: [String] {
        let connected = Set(model.availableDisplays.map(\.id))
        return model.mirroredDisplayIDs
            .subtracting(connected)
            .sorted()
    }

    private func mirroredDisplayBinding(for persistentID: String) -> Binding<Bool> {
        Binding(
            get: { model.mirroredDisplayIDs.contains(persistentID) },
            set: { isSelected in
                var selected = model.mirroredDisplayIDs
                if isSelected {
                    selected.insert(persistentID)
                } else {
                    selected.remove(persistentID)
                }
                model.mirroredDisplayIDs = selected
            }
        )
    }
}
