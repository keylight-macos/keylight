import SwiftUI

extension SettingsView {
  @ViewBuilder
  var appearanceTabContent: some View {
    let liquidGlassUsesNeutralMaterial =
      !model.effectStyle.usesClassicColorConfiguration
    let solidBlackSelected = model.effectStyle == .solidBlack
    let systemGlassSelected = model.effectStyle == .systemGlass
    let physicalRefractionSelected = model.effectStyle == .physicalRefraction
    let displayedHeight =
      liquidGlassUsesNeutralMaterial
      ? Double(
        LiquidGlassTransitionMath.bezelHeight(
          glowHeight: CGFloat(model.glowSize),
          containerHeight: 120
        )
      )
      : model.glowSize
    let heightRange: ClosedRange<Double> =
      liquidGlassUsesNeutralMaterial
      ? 4...53
      : 4...200
    let heightBinding = Binding<Double>(
      get: {
        liquidGlassUsesNeutralMaterial
          ? Double(
            LiquidGlassTransitionMath.bezelHeight(
              glowHeight: CGFloat(model.glowSize),
              containerHeight: 120
            )
          )
          : model.glowSize
      },
      set: { newHeight in
        if liquidGlassUsesNeutralMaterial {
          model.glowSize = min(max((newHeight - 3) / 0.25, 4), 200)
        } else {
          model.glowSize = newHeight
        }
      }
    )
    let chordStyleBinding = Binding<ChordSurfaceStyle>(
      get: { model.chordAppearance.style },
      set: { style in
        model.chordAppearance = ChordAppearance(
          style: style,
          intensityMultiplier: model.chordAppearance.intensityMultiplier
        )
      }
    )
    let chordIntensityBinding = Binding<Double>(
      get: { model.chordAppearance.intensityMultiplier },
      set: { intensity in
        model.chordAppearance = ChordAppearance(
          style: model.chordAppearance.style,
          intensityMultiplier: intensity
        )
      }
    )

    VStack(alignment: .leading, spacing: 8) {
      Text("Effect Style")
        .font(.headline)
      LazyVGrid(
        columns: [
          GridItem(.flexible(), spacing: 8),
          GridItem(.flexible(), spacing: 8),
        ],
        spacing: 8
      ) {
        ForEach(EffectStyle.allCases, id: \.self) { effect in
          appearanceEffectCard(effect)
        }
      }

      if model.effectStyle.requiresMacOS26 && !liquidGlassRuntimeAvailable {
        Text("Classic Glow fallback is active on this macOS version.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      if systemGlassSelected && liquidGlassRuntimeAvailable {
        Text(
          "Capture-free comparison: Apple controls the clear-glass optics. KeyLight supplies only the key shape, grouping, and motion."
        )
        .font(.caption)
        .foregroundColor(.secondary)
      }

      if physicalRefractionSelected {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Image(
              systemName: screenCaptureAccessGranted
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(
              screenCaptureAccessGranted ? .green : .orange
            )
            Text(
              screenCaptureAccessGranted
                ? "Screen Recording allowed"
                : "Screen Recording permission required"
            )
            .font(.callout)
          }

          HStack {
            if screenCaptureAccessGranted {
              Button("Open Screen Recording Settings") {
                ScreenCaptureAuthorization.openSettings()
              }
            } else {
              Button("Allow Screen Recording") {
                screenCaptureAccessGranted =
                  ScreenCaptureAuthorization.requestAccess()
                model.refreshEffectRenderer()
              }
              Button("Check Again") {
                screenCaptureAccessGranted =
                  ScreenCaptureAuthorization.isGranted
                model.refreshEffectRenderer()
              }
              Button("Open Settings") {
                ScreenCaptureAuthorization.openSettings()
              }
            }
          }
          .controlSize(.small)

          Text(
            screenCaptureAccessGranted
              ? "Only a 180–200 point strip at the bottom of the selected display is sampled. Frames stay in GPU-backed memory and are never saved."
              : "Until access is allowed, the selected effect safely renders with capture-free System Glass. KeyLight never requests this permission automatically."
          )
          .font(.caption)
          .foregroundColor(.secondary)
        }
        .padding(8)
        .background(
          (screenCaptureAccessGranted ? Color.green : Color.orange)
            .opacity(0.07),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
      }
    }

    Divider()

    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Chord Appearance")
          .font(.headline)
        Spacer()
        Button(chordPreviewActive ? "Testing…" : "Test Four Keys") {
          startChordPreviewTest()
        }
        .controlSize(.small)
        .disabled(chordPreviewActive || !model.isEnabled)
      }

      Picker("Surface Style", selection: chordStyleBinding) {
        ForEach(ChordSurfaceStyle.allCases, id: \.self) { style in
          Text(style.displayName).tag(style)
        }
      }
      .pickerStyle(.segmented)

      HStack {
        Text("Chord Intensity")
        Spacer()
        Text("\(Int((model.chordAppearance.intensityMultiplier * 100).rounded()))%")
          .foregroundColor(.secondary)
          .monospacedDigit()
      }
      Slider(
        value: chordIntensityBinding,
        in: ChordAppearance.intensityRange,
        step: 0.05
      )
      .accessibilityLabel("Chord intensity")
      .accessibilityValue(
        "\(Int((model.chordAppearance.intensityMultiplier * 100).rounded())) percent"
      )

      Text(
        model.chordAppearance.style == .naturalMerge
          ? "Adjacent held keys keep the current cohesive surface. Intensity applies only while two or more keys are held."
          : "Each held key keeps its own material boundary. Intensity applies only while two or more keys are held."
      )
      .font(.caption)
      .foregroundColor(.secondary)
    }

    Divider()

    if !liquidGlassUsesNeutralMaterial {
      Group {
        VStack(alignment: .leading, spacing: 8) {
          Text("Color Mode")
            .font(.headline)
          Picker("", selection: $model.colorMode) {
            Text("Solid").tag(ColorMode.solid)
            Text("Position Gradient").tag(ColorMode.positionGradient)
            Text("Random Per Key").tag(ColorMode.randomPerKey)
            Text("Rainbow").tag(ColorMode.rainbow)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .accessibilityLabel("Color mode")
          .accessibilityValue(colorModeAccessibilityValue)
          .accessibilityHint("Available with Classic Glow")
        }

        if model.colorMode == .solid {
          VStack(alignment: .leading, spacing: 8) {
            Text("Color")
              .font(.headline)
            HStack(spacing: 12) {
              ColorPicker("Glow Color", selection: $model.glowColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44, height: 28)
                .accessibilityLabel("Glow color")
                .accessibilityValue(
                  "Hex \(normalizedHex(model.glowColor.toHex(), fallback: "68B8FF"))")

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
                      model.glowColor = color
                    }
                  }
              }

              HStack(spacing: 6) {
                ColorPresetButton(
                  color: Color(hex: "68B8FF") ?? .blue, model: model, hexColor: $hexColor)
                ColorPresetButton(
                  color: Color(hex: "00E69A") ?? .green, model: model, hexColor: $hexColor)
                ColorPresetButton(
                  color: Color(hex: "FF6B6B") ?? .red, model: model, hexColor: $hexColor)
                ColorPresetButton(
                  color: Color(hex: "FFD93D") ?? .yellow, model: model, hexColor: $hexColor)
                ColorPresetButton(
                  color: Color(hex: "C77DFF") ?? .purple, model: model, hexColor: $hexColor)
              }
            }
            .onChange(of: model.glowColor) { _, newColor in
              guard !isUpdatingColor else { return }
              isUpdatingColor = true
              defer { isUpdatingColor = false }
              hexColor = newColor.toHex() ?? "68B8FF"
            }
          }
        }

        if model.colorMode == .positionGradient {
          VStack(alignment: .leading, spacing: 8) {
            Text("Gradient Colors")
              .font(.headline)

            HStack(spacing: 16) {
              VStack(spacing: 4) {
                Text("Start")
                  .font(.caption)
                  .foregroundColor(.secondary)
                ColorPicker(
                  "Gradient Start", selection: $model.gradientStartColor, supportsOpacity: false
                )
                .labelsHidden()
                .frame(width: 44, height: 28)
                .accessibilityLabel("Gradient start color")
                .accessibilityValue(
                  "Hex \(normalizedHex(model.gradientStartColor.toHex(), fallback: "68B8FF"))")
              }

              LinearGradient(
                colors: [model.gradientStartColor, model.gradientEndColor],
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
                ColorPicker(
                  "Gradient End", selection: $model.gradientEndColor, supportsOpacity: false
                )
                .labelsHidden()
                .frame(width: 44, height: 28)
                .accessibilityLabel("Gradient end color")
                .accessibilityValue(
                  "Hex \(normalizedHex(model.gradientEndColor.toHex(), fallback: "00E69A"))")
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
                  GradientPresetButton(
                    startHex: preset.startHex, endHex: preset.endHex, model: model)
                }
              }
            }
          }
        }

        if model.colorMode == .randomPerKey {
          Text("Each key uses a deterministic random color derived from its key code.")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        if model.colorMode == .rainbow {
          Text("Colors are distributed left-to-right by key position.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
    }

    if !liquidGlassUsesNeutralMaterial {
      Divider()
    }

    VStack(alignment: .leading, spacing: 12) {
      Text("Optics")
        .font(.headline)

      if solidBlackSelected {
        Text("Solid Black is always fully opaque inside the active silhouette.")
          .font(.caption)
          .foregroundColor(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Opacity")
            Spacer()
            Text("\(Int(model.glowOpacity * 100))%")
              .foregroundColor(.secondary)
              .monospacedDigit()
          }
          Slider(
            value: $model.glowOpacity,
            in: 0.05...1.0,
            onEditingChanged: settingsPreviewEditingChanged
          )
          .accessibilityLabel("Opacity")
          .accessibilityValue("\(Int(model.glowOpacity * 100)) percent")
          if physicalRefractionSelected {
            Text("Controls the visibility of the optical contour. The body remains clear.")
              .font(.caption)
              .foregroundColor(.secondary)
          } else if systemGlassSelected {
            Text(
              "Controls the visibility of Apple's system glass; the system controls its lensing and refraction."
            )
            .font(.caption)
            .foregroundColor(.secondary)
          } else if liquidGlassUsesNeutralMaterial {
            Text(
              "Lower values clear the body while preserving native lensing and strengthening chromatic top and side refraction."
            )
            .font(.caption)
            .foregroundColor(.secondary)
          }
        }
      }

      if physicalRefractionSelected {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Refraction Strength")
            Spacer()
            Text(
              "\(Int((model.physicalRefractionStrength * 100).rounded()))%"
            )
            .foregroundColor(.secondary)
            .monospacedDigit()
          }
          Slider(
            value: $model.physicalRefractionStrength,
            in: 0.5...2.5,
            onEditingChanged: settingsPreviewEditingChanged
          )
          .accessibilityLabel("Refraction strength")
          .accessibilityValue(
            "\(Int((model.physicalRefractionStrength * 100).rounded())) percent"
          )
          .accessibilityHint(
            "Adjusts backdrop displacement at the top and side edges only"
          )
          Text(
            "100% preserves the current tuned glass. Higher values increase the optical path length and color separation only at the top and side edges; the bottom stays transparent."
          )
          .font(.caption)
          .foregroundColor(.secondary)
        }
      }

      Text("Geometry")
        .font(.headline)

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("Height")
          Spacer()
          Text("\(Int(displayedHeight.rounded()))")
            .foregroundColor(.secondary)
            .monospacedDigit()
        }
        Slider(
          value: heightBinding,
          in: heightRange,
          onEditingChanged: settingsPreviewEditingChanged
        )
        .accessibilityLabel("Height")
        .accessibilityValue("\(Int(displayedHeight.rounded())) points")
      }

      if !liquidGlassUsesNeutralMaterial {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Width")
            Spacer()
            Text("\(Int(model.glowWidth * 100))%")
              .foregroundColor(.secondary)
              .monospacedDigit()
          }
          Slider(
            value: $model.glowWidth,
            in: 0.3...3.0,
            onEditingChanged: settingsPreviewEditingChanged
          )
          .accessibilityLabel("Width")
          .accessibilityValue("\(Int(model.glowWidth * 100)) percent")
        }

        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(liquidGlassUsesNeutralMaterial ? "Smoothness" : "Roundness")
            Spacer()
            Text(
              model.glowRoundness < 0.05
                ? (liquidGlassUsesNeutralMaterial ? "Compact" : "Sharp")
                : model.glowRoundness > 0.95
                  ? (liquidGlassUsesNeutralMaterial ? "Wide + Soft" : "Round")
                  : "\(Int(model.glowRoundness * 100))%"
            )
            .foregroundColor(.secondary)
            .monospacedDigit()
          }
          Slider(
            value: $model.glowRoundness,
            in: 0.0...1.0,
            onEditingChanged: settingsPreviewEditingChanged
          )
          .accessibilityLabel(liquidGlassUsesNeutralMaterial ? "Smoothness" : "Roundness")
          .accessibilityValue(
            liquidGlassUsesNeutralMaterial
              ? liquidGlassSmoothnessAccessibilityValue
              : roundnessAccessibilityValue
          )
          .accessibilityHint(
            liquidGlassUsesNeutralMaterial
              ? "Move left for a compact wave or right for a wider, softer wave"
              : "Controls the corner profile of Classic Glow"
          )
          if liquidGlassUsesNeutralMaterial {
            Text(
              "The left side strongly compresses the wave; the right side spreads and softens it."
            )
            .font(.caption)
            .foregroundColor(.secondary)
          }
        }

        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Hardness")
            Spacer()
            Text("\(Int(model.glowFullness * 100))%")
              .foregroundColor(.secondary)
              .monospacedDigit()
          }
          Slider(
            value: $model.glowFullness,
            in: 0.0...1.0,
            onEditingChanged: settingsPreviewEditingChanged
          )
          .accessibilityLabel("Hardness")
          .accessibilityValue("\(Int(model.glowFullness * 100)) percent")
          .accessibilityHint("Available with Classic Glow")
          Text("Controls glow boundary feather (0% soft, 100% crisp).")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      Text("Motion")
        .font(.headline)
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("Fade Duration")
          Spacer()
          Text("\(String(format: "%.2f", model.fadeDuration))s")
            .foregroundColor(.secondary)
            .monospacedDigit()
        }
        Slider(
          value: $model.fadeDuration,
          in: 0.05...2.0,
          onEditingChanged: settingsPreviewEditingChanged
        )
        .accessibilityLabel("Fade duration")
        .accessibilityValue("\(String(format: "%.2f", model.fadeDuration)) seconds")
        if liquidGlassUsesNeutralMaterial {
          Text(
            solidBlackSelected
              ? "Sets the tempo for reveal, key-to-key flow, and geometric retraction."
              : "Sets the tempo for reveal, key-to-key flow, and fade-out."
          )
          .font(.caption)
          .foregroundColor(.secondary)
        }
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
          let isActive = currentThemeID == theme.id
          let pendingID = PendingDeletionID.theme(theme.id)
          let pendingState = pendingDeletions[pendingID]

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
                Button {
                  selectTheme(theme, isActive: isActive)
                } label: {
                  HStack(spacing: 7) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                      .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                      .accessibilityHidden(true)
                    Text(themeDisplayName(theme, isActive: isActive))
                      .font(.subheadline)
                      .lineLimit(1)
                    Spacer(minLength: 0)
                  }
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isActive)
                .accessibilityLabel("Theme \(theme.name)")
                .accessibilityValue(
                  themeSelectionAccessibilityValue(
                    isActive: isActive, isEdited: isActive && activeThemeIsEdited))

                if let pendingState {
                  Button("Undo (\(pendingState.secondsRemaining)s)") {
                    cancelPendingDeletion(for: pendingID)
                  }
                  .buttonStyle(.borderedProminent)
                  .controlSize(.small)
                } else {
                  Menu {
                    Button("Rename…") {
                      startThemeRename(theme)
                    }
                    .disabled(theme.name == Theme.defaultTheme.name)

                    Button("Delete", role: .destructive) {
                      queueThemeDeletion(theme)
                    }
                    .disabled(theme.name == Theme.defaultTheme.name)
                  } label: {
                    Image(systemName: "ellipsis.circle")
                  }
                  .menuStyle(.borderlessButton)
                  .menuIndicator(.hidden)
                  .fixedSize()
                  .help("Theme actions")
                  .accessibilityLabel("Actions for theme \(theme.name)")
                }
              }
            }
            .frame(minHeight: 30)

            if editingThemeID == theme.id,
              let error = themeRenameError ?? themeRenameValidation(for: theme)
            {
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
      }

      if showingThemeSaveField {
        HStack {
          TextField("Theme name", text: $newThemeName)
            .textFieldStyle(.roundedBorder)

          Button("Save") {
            let trimmed = trimmed(newThemeName)
            guard !trimmed.isEmpty else { return }
            if saveCurrentThemeAs(trimmed) {
              showingThemeSaveField = false
              newThemeName = ""
            }
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
        HStack(spacing: 8) {
          Button("Update Theme") {
            updateActiveTheme()
          }
          .controlSize(.small)
          .disabled(activeTheme == nil || !activeThemeIsEdited)
          .accessibilityHint("Replaces the selected theme with the current appearance")

          Button("Save As…") {
            showingThemeSaveField = true
          }
          .controlSize(.small)

          Button("Revert") {
            revertActiveTheme()
          }
          .controlSize(.small)
          .disabled(activeTheme == nil || !activeThemeIsEdited)
          .accessibilityHint("Restores the selected theme's saved appearance")

          Spacer()

          Button("Share…") {
            refreshThemeTransferStringFromActiveTheme()
            themeTransferFeedback = nil
            themeTransferMode = .share
          }
          .controlSize(.small)
          .disabled(activeTheme == nil)

          Button("Import…") {
            themeTransferString = ""
            themeTransferFeedback = nil
            themeTransferMode = .importTheme
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        }
      }

      if let themeTransferFeedback {
        InlineSettingsFeedback(feedback: themeTransferFeedback)
      }
    }
  }

  private func appearanceEffectCard(_ effect: EffectStyle) -> some View {
    let selected = model.effectStyle == effect
    let available = effect.isAvailableOnCurrentSystem
    return Button {
      guard available else { return }
      model.selectEffect(effect)
    } label: {
      HStack(alignment: .top, spacing: 8) {
        Image(
          systemName: selected
            ? "checkmark.circle.fill"
            : "circle"
        )
        .foregroundStyle(selected ? Color.accentColor : .secondary)
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 3) {
          Text(effect.displayName)
            .font(.callout.weight(.semibold))
          Text(effect.appearanceSummary)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          HStack(spacing: 5) {
            Text(
              effect.usesScreenCapture
                ? "Optional Screen Recording"
                : "No Screen Capture")
            if effect.requiresMacOS26 {
              Text("macOS 26+")
            }
          }
          .font(.caption2)
          .foregroundStyle(effect.usesScreenCapture ? .orange : .secondary)
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
      .padding(8)
      .background(
        selected
          ? Color.accentColor.opacity(0.10)
          : Color.secondary.opacity(0.05),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(
            selected
              ? Color.accentColor.opacity(0.55)
              : Color.secondary.opacity(0.16),
            lineWidth: 1
          )
      )
      .opacity(available ? 1 : 0.55)
    }
    .buttonStyle(.plain)
    .disabled(!available)
    .accessibilityLabel(effect.displayName)
    .accessibilityValue(
      selected
        ? String(localized: "Selected")
        : String(localized: "Not selected")
    )
    .accessibilityHint(effect.appearanceAccessibilityHint)
  }
}

extension EffectStyle {
  fileprivate var appearanceSummary: String {
    switch self {
    case .classicGlow:
      String(localized: "Original single-target glow with unchanged timing.")
    case .classicPlus:
      String(localized: "Retired preview effect; migrated to Classic Glow.")
    case .liquidGlass:
      String(localized: "Retired preview effect; migrated to System Glass.")
    case .systemGlass:
      String(localized: "Capture-free optics controlled by macOS.")
    case .physicalRefraction:
      String(localized: "Backdrop refraction with System Glass fallback.")
    case .solidBlack:
      String(localized: "Opaque silhouette with geometric retraction.")
    }
  }

  fileprivate var appearanceAccessibilityHint: String {
    if !isAvailableOnCurrentSystem {
      return String(
        localized: "Unavailable on this macOS version; Classic Glow remains the fallback.")
    }
    if usesScreenCapture {
      return String(
        localized:
          "Uses optional Screen Recording only while a physical surface is active; System Glass is the capture-free fallback."
      )
    }
    return String(localized: "Selects this capture-free effect and updates the live preview.")
  }
}
