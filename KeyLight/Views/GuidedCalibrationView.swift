import AppKit
import SwiftUI

struct GuidedCalibrationAnchor: Identifiable, Equatable {
    let keyCode: UInt16
    let label: String
    let row: Int
    let column: Int

    var id: UInt16 { keyCode }
}

/// Pure calibration math kept separate from the scene so fitting, cancellation,
/// and persistence boundaries can be tested without presenting a window.
@MainActor
struct GuidedCalibrationDraft: Equatable {
    static let anchors: [GuidedCalibrationAnchor] = [
        GuidedCalibrationAnchor(keyCode: 18, label: "1", row: 1, column: 0),
        GuidedCalibrationAnchor(keyCode: 22, label: "6", row: 1, column: 1),
        GuidedCalibrationAnchor(keyCode: 24, label: "=", row: 1, column: 2),
        GuidedCalibrationAnchor(keyCode: 0, label: "A", row: 3, column: 0),
        GuidedCalibrationAnchor(keyCode: 4, label: "H", row: 3, column: 1),
        GuidedCalibrationAnchor(keyCode: 36, label: "Return", row: 3, column: 2),
        GuidedCalibrationAnchor(keyCode: 55, label: "Left Command", row: 5, column: 0),
        GuidedCalibrationAnchor(keyCode: 49, label: "Space", row: 5, column: 1),
        GuidedCalibrationAnchor(keyCode: 124, label: "Right Arrow", row: 5, column: 2)
    ]

    let baseline: KeyLayout
    private(set) var alignedPositions: [UInt16: CGFloat]

    init(baseline: KeyLayout) {
        self.baseline = KeyLayoutStore.normalized(baseline)
        alignedPositions = Dictionary(uniqueKeysWithValues: Self.anchors.map { anchor in
            (anchor.keyCode, Self.baselinePosition(for: anchor.keyCode, in: baseline))
        })
    }

    mutating func setAlignedPosition(_ position: CGFloat, for keyCode: UInt16) {
        guard Self.anchors.contains(where: { $0.keyCode == keyCode }) else { return }
        let finite = position.isFinite ? position : Self.baselinePosition(
            for: keyCode,
            in: baseline
        )
        alignedPositions[keyCode] = min(max(finite, 0.02), 0.98)
    }

    func alignedPosition(for keyCode: UInt16) -> CGFloat {
        alignedPositions[keyCode] ?? Self.baselinePosition(for: keyCode, in: baseline)
    }

    var fittedLayout: KeyLayout {
        let bands = Self.referenceRows.map { referenceRow in
            Self.makeBand(
                row: referenceRow,
                baseline: baseline,
                alignedPositions: alignedPositions
            )
        }

        var offsets: [UInt16: CGFloat] = [:]
        var widths: [UInt16: CGFloat] = [:]
        for key in KeyboardLayoutInfo.allKeys {
            let baselinePosition = Self.baselinePosition(for: key.id, in: baseline)
            let vertical = Self.verticalBands(for: key.row)
            let lower = bands[vertical.lowerIndex]
            let upper = bands[vertical.upperIndex]
            let lowerPosition = lower.mappedPosition(for: baselinePosition)
            let upperPosition = upper.mappedPosition(for: baselinePosition)
            let mappedPosition = Self.interpolate(
                lowerPosition,
                upperPosition,
                fraction: vertical.fraction
            )
            let newOffset = min(max(mappedPosition, 0), 1) - key.position
            if abs(newOffset) > 0.000_001 {
                offsets[key.id] = newOffset
            }

            let lowerScale = lower.scale(at: baselinePosition)
            let upperScale = upper.scale(at: baselinePosition)
            let localScale = Self.interpolate(
                lowerScale,
                upperScale,
                fraction: vertical.fraction
            )
            let baselineWidth = baseline.widthMultipliers[key.id] ?? 1
            let fittedWidth = baselineWidth * localScale
            if abs(fittedWidth - 1) > 0.000_001 {
                widths[key.id] = fittedWidth
            }
        }
        return KeyLayoutStore.normalized(KeyLayout(
            offsets: offsets,
            widthMultipliers: widths
        ))
    }

    private struct Band {
        let source: [CGFloat]
        let target: [CGFloat]

        func mappedPosition(for position: CGFloat) -> CGFloat {
            let segment = position <= source[1] ? 0 : 1
            let denominator = max(source[segment + 1] - source[segment], 0.000_001)
            let fraction = (position - source[segment]) / denominator
            return target[segment] + (target[segment + 1] - target[segment]) * fraction
        }

        func scale(at position: CGFloat) -> CGFloat {
            let segment = position <= source[1] ? 0 : 1
            let sourceDistance = max(source[segment + 1] - source[segment], 0.000_001)
            return max((target[segment + 1] - target[segment]) / sourceDistance, 0.05)
        }
    }

    private static let referenceRows = [1, 3, 5]

    private static func makeBand(
        row: Int,
        baseline: KeyLayout,
        alignedPositions: [UInt16: CGFloat]
    ) -> Band {
        let rowAnchors = anchors
            .filter { $0.row == row }
            .sorted { $0.column < $1.column }
        let source = rowAnchors.map { baselinePosition(for: $0.keyCode, in: baseline) }
        let requested = rowAnchors.map {
            alignedPositions[$0.keyCode] ?? baselinePosition(for: $0.keyCode, in: baseline)
        }
        let left = min(max(requested[0], 0.02), 0.92)
        let center = min(max(requested[1], left + 0.02), 0.96)
        let right = min(max(requested[2], center + 0.02), 0.98)
        return Band(source: source, target: [left, center, right])
    }

    private static func verticalBands(
        for row: Int
    ) -> (lowerIndex: Int, upperIndex: Int, fraction: CGFloat) {
        if row <= referenceRows[0] { return (0, 0, 0) }
        if row >= referenceRows[2] { return (2, 2, 0) }
        if row <= referenceRows[1] {
            let fraction = CGFloat(row - referenceRows[0])
                / CGFloat(referenceRows[1] - referenceRows[0])
            return (0, 1, fraction)
        }
        let fraction = CGFloat(row - referenceRows[1])
            / CGFloat(referenceRows[2] - referenceRows[1])
        return (1, 2, fraction)
    }

    private static func baselinePosition(for keyCode: UInt16, in layout: KeyLayout) -> CGFloat {
        guard let key = KeyboardLayoutInfo.allKeys.first(where: { $0.id == keyCode }) else {
            return 0.5
        }
        let offset = layout.offsets[keyCode] ?? 0
        return min(max(key.position + offset, 0), 1)
    }

    private static func interpolate(
        _ start: CGFloat,
        _ end: CGFloat,
        fraction: CGFloat
    ) -> CGFloat {
        start + (end - start) * min(max(fraction, 0), 1)
    }
}

@MainActor
struct GuidedCalibrationSceneRoot: View {
    let model: KeyLightModel
    let settings: SettingsManager
    @ObservedObject var layoutStore: KeyLayoutStore

    @Environment(\.dismiss) private var dismiss
    @State private var draft: GuidedCalibrationDraft
    @State private var stepIndex = 0
    @State private var isReviewing = false
    @State private var profileName: String
    @State private var errorMessage: String?
    @State private var detectedCurrentAnchor = false
    @State private var chordPreviewTask: Task<Void, Never>?

    init(
        model: KeyLightModel,
        settings: SettingsManager,
        layoutStore: KeyLayoutStore
    ) {
        self.model = model
        self.settings = settings
        _layoutStore = ObservedObject(wrappedValue: layoutStore)
        _draft = State(initialValue: GuidedCalibrationDraft(baseline: layoutStore.layout))
        _profileName = State(initialValue: Self.suggestedProfileName(in: settings))
    }

    private var currentAnchor: GuidedCalibrationAnchor {
        GuidedCalibrationDraft.anchors[stepIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Guided Keyboard Calibration")
                        .font(.title2.bold())
                    Text(isReviewing ? "Review and save a new layout profile" : "Align nine reference glows; KeyLight fills in the rest")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isReviewing {
                    Text("\(stepIndex + 1) of \(GuidedCalibrationDraft.anchors.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            if isReviewing {
                reviewContent
            } else {
                anchorContent
            }

            Divider()

            HStack {
                Button("Cancel") {
                    close()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if isReviewing {
                    Button("Back") {
                        isReviewing = false
                        postCurrentPreview()
                    }
                    Button("Save New Profile") {
                        saveProfile()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(profileValidationError != nil)
                } else {
                    Button("Back") {
                        stepIndex = max(stepIndex - 1, 0)
                    }
                    .disabled(stepIndex == 0)
                    Button(stepIndex == GuidedCalibrationDraft.anchors.count - 1 ? "Review" : "Next") {
                        if stepIndex == GuidedCalibrationDraft.anchors.count - 1 {
                            isReviewing = true
                            model.clearPreview(.guidedCalibration)
                        } else {
                            stepIndex += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 680, minHeight: 520)
        .onAppear { postCurrentPreview() }
        .onChange(of: stepIndex) { _, _ in
            detectedCurrentAnchor = false
            postCurrentPreview()
        }
        .onChange(of: model.physicalKeyActivity) { _, activity in
            guard let activity, activity.isDown else { return }
            detectedCurrentAnchor = KeyboardLayoutInfo.canonicalKeyCode(for: activity.keyCode)
                == currentAnchor.keyCode
        }
        .onDisappear { clearTransientPreviews() }
    }

    private var anchorContent: some View {
        VStack(spacing: 22) {
            ProgressView(
                value: Double(stepIndex + 1),
                total: Double(GuidedCalibrationDraft.anchors.count)
            )
            .frame(maxWidth: 460)

            VStack(spacing: 8) {
                Text("Align \(currentAnchor.label)")
                    .font(.system(size: 30, weight: .semibold))
                Text("Move the slider until the glow sits beneath the matching physical key. Use the arrow keys while the slider is focused for fine adjustment.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
            }

            Slider(
                value: Binding(
                    get: { Double(draft.alignedPosition(for: currentAnchor.keyCode)) },
                    set: { value in
                        draft.setAlignedPosition(CGFloat(value), for: currentAnchor.keyCode)
                        postCurrentPreview()
                    }
                ),
                in: 0.02 ... 0.98
            )
            .frame(maxWidth: 520)
            .accessibilityLabel("Horizontal position for \(currentAnchor.label)")

            HStack(spacing: 18) {
                Button {
                    nudgeCurrentAnchor(by: -0.001)
                } label: {
                    Label("Nudge Left", systemImage: "arrow.left")
                }
                Button {
                    nudgeCurrentAnchor(by: 0.001)
                } label: {
                    Label("Nudge Right", systemImage: "arrow.right")
                }
            }
            .controlSize(.small)

            Label(
                detectedCurrentAnchor ? "Reference key detected" : "Press the reference key to verify identification (optional)",
                systemImage: detectedCurrentAnchor ? "checkmark.circle.fill" : "keyboard"
            )
            .foregroundStyle(detectedCurrentAnchor ? Color.green : Color.secondary)

            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            GuidedCalibrationKeyboardPreview(layout: draft.fittedLayout)
                .frame(height: 245)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Multi-Key Review")
                        .font(.headline)
                    Text("Temporarily preview A–S–D–F using the fitted layout.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Test Four Keys") {
                    startChordPreview()
                }
                .disabled(!model.isEnabled)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("New Profile Name")
                    .font(.headline)
                TextField("Layout profile name", text: $profileName)
                    .textFieldStyle(.roundedBorder)
                if let validation = errorMessage ?? profileValidationError {
                    Text(validation)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Finishing creates and activates a new profile. Existing profiles are not changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private var profileValidationError: String? {
        guard let normalized = PersistenceValidation.normalizedName(profileName) else {
            return "Enter a profile name."
        }
        if settings.savedKeyMappingProfiles.contains(where: {
            $0.name.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return "A layout named \"\(normalized)\" already exists."
        }
        return nil
    }

    private func nudgeCurrentAnchor(by delta: CGFloat) {
        draft.setAlignedPosition(
            draft.alignedPosition(for: currentAnchor.keyCode) + delta,
            for: currentAnchor.keyCode
        )
        postCurrentPreview()
    }

    private func postCurrentPreview() {
        guard !isReviewing, model.isEnabled,
              let key = KeyboardLayoutInfo.allKeys.first(where: { $0.id == currentAnchor.keyCode }) else {
            model.clearPreview(.guidedCalibration)
            return
        }
        let baselineWidth = draft.baseline.widthMultipliers[key.id] ?? 1
        model.setPreview(
            .preview(
                .guidedCalibration,
                colorReferenceKeyCode: key.id,
                horizontalPosition: Double(draft.alignedPosition(for: key.id)),
                keyWidth: Double(key.width * baselineWidth)
            ),
            source: .guidedCalibration
        )
    }

    private func startChordPreview() {
        chordPreviewTask?.cancel()
        let layout = draft.fittedLayout
        let keyCodes: [UInt16] = [0, 1, 2, 3]
        let targets = zip(PreviewSource.chordTestSources, keyCodes).compactMap { pair -> GlowTarget? in
            let (source, keyCode) = pair
            guard let key = KeyboardLayoutInfo.allKeys.first(where: { $0.id == keyCode }) else {
                return nil
            }
            let offset = layout.offsets[keyCode] ?? 0
            let width = layout.widthMultipliers[keyCode] ?? 1
            return GlowTarget.preview(
                source,
                colorReferenceKeyCode: keyCode,
                horizontalPosition: Double(min(max(key.position + offset, 0), 1)),
                keyWidth: Double(key.width * width)
            )
        }
        model.setChordPreview(targets)
        chordPreviewTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            model.clearChordPreview()
            chordPreviewTask = nil
        }
    }

    private func saveProfile() {
        guard profileValidationError == nil,
              let normalizedName = PersistenceValidation.normalizedName(profileName) else {
            return
        }
        let layout = draft.fittedLayout
        let profile = KeyMappingProfile(
            name: normalizedName,
            keyOffsets: layout.offsets,
            keyWidthOverrides: layout.widthMultipliers
        )
        guard let saved = settings.saveKeyMappingProfile(profile) else {
            errorMessage = "The profile could not be saved."
            return
        }
        layoutStore.reloadSavedProfiles(from: settings)
        guard layoutStore.selectSavedProfile(id: saved.id) else {
            errorMessage = "The profile was saved but could not be activated."
            return
        }
        layoutStore.flush()
        model.feedback = UserFeedback(
            severity: .success,
            title: String(localized: "Calibration Saved"),
            detail: String(localized: "Created and activated \"\(saved.name)\".")
        )
        close()
    }

    private func close() {
        clearTransientPreviews()
        dismiss()
    }

    private func clearTransientPreviews() {
        chordPreviewTask?.cancel()
        chordPreviewTask = nil
        model.clearPreview(.guidedCalibration)
        model.clearChordPreview()
    }

    private static func suggestedProfileName(in settings: SettingsManager) -> String {
        let base = "Guided Calibration"
        let names = Set(settings.savedKeyMappingProfiles.map { $0.name.lowercased() })
        guard names.contains(base.lowercased()) else { return base }
        var suffix = 2
        while names.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }
}

private struct GuidedCalibrationKeyboardPreview: View {
    let layout: KeyLayout

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
                ForEach(KeyboardLayoutInfo.allKeys) { key in
                    let position = min(max(key.position + (layout.offsets[key.id] ?? 0), 0), 1)
                    let widthScale = layout.widthMultipliers[key.id] ?? 1
                    Text(key.label)
                        .font(.system(size: 7, weight: .medium))
                        .lineLimit(1)
                        .frame(
                            width: max(14, 22 * key.width * widthScale),
                            height: 23
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.primary.opacity(0.22), lineWidth: 1)
                        )
                        .position(
                            x: position * proxy.size.width,
                            y: 22 + CGFloat(key.row) * 35
                        )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the fitted keyboard layout")
    }
}
