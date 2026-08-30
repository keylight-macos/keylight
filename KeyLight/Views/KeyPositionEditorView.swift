import SwiftUI
import AppKit

@MainActor
final class KeyEditorGlowPreviewSession {
    typealias ShowHandler = @MainActor (UInt16, CGFloat, CGFloat) -> Void
    typealias HideHandler = @MainActor () -> Void

    private var hideTask: Task<Void, Never>?
    private let showHandler: ShowHandler
    private let hideHandler: HideHandler

    init(
        show: @escaping ShowHandler,
        hide: @escaping HideHandler
    ) {
        showHandler = show
        hideHandler = hide
    }

    func show(keyCode: UInt16, position: CGFloat, keyWidth: CGFloat) {
        hideTask?.cancel()
        hideTask = nil
        showHandler(keyCode, position, keyWidth)
    }

    func scheduleHide(after delay: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.hideTask = nil
            self?.hideHandler()
        }
    }

    func stop() {
        hideTask?.cancel()
        hideTask = nil
        hideHandler()
    }
}

/// SwiftUI scene root used by the native singleton calibration window.
/// The preview session is scene-owned so delayed hides cannot outlive the window.
@MainActor
struct KeyPositionEditorSceneRoot: View {
    let model: KeyLightModel

    @State private var previewSession: KeyEditorGlowPreviewSession
    @ObservedObject private var layoutStore: KeyLayoutStore

    init(model: KeyLightModel, layoutStore: KeyLayoutStore) {
        self.model = model
        _layoutStore = ObservedObject(wrappedValue: layoutStore)
        _previewSession = State(initialValue: KeyEditorGlowPreviewSession(
            show: { [weak model] keyCode, position, keyWidth in
                model?.setPreview(
                    .preview(
                        .keyEditor,
                        colorReferenceKeyCode: keyCode,
                        horizontalPosition: Double(position),
                        keyWidth: Double(keyWidth)
                    ),
                    source: .keyEditor
                )
            },
            hide: { [weak model] in
                model?.clearPreview(.keyEditor)
            }
        ))
    }

    var body: some View {
        KeyPositionEditorView(
            model: model,
            previewSession: previewSession,
            layoutStore: layoutStore
        )
            .onDisappear {
                layoutStore.endGestureTransaction()
                previewSession.stop()
            }
    }
}

/// Main view for adjusting key positions by dragging
struct KeyPositionEditorView: View {
    let model: KeyLightModel
    let previewSession: KeyEditorGlowPreviewSession

    @ObservedObject var layoutStore: KeyLayoutStore

    @State private var selectedKey: UInt16? = nil
    @State private var showResetConfirmation = false
    @State private var pressedKeys: Set<UInt16> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Drag keys horizontally to align the glow effect with your physical keyboard")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()

                Button(action: { layoutStore.undo() }) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!layoutStore.canUndo)
                .help("Undo (Cmd+Z)")
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityLabel("Undo keyboard calibration")

                Button(action: { layoutStore.redo() }) {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!layoutStore.canRedo)
                .help("Redo (Cmd+Shift+Z)")
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .accessibilityLabel("Redo keyboard calibration")

                Button("Reset All") {
                    showResetConfirmation = true
                }
                .confirmationDialog(
                    "Reset all key positions to defaults?",
                    isPresented: $showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset All", role: .destructive) {
                        layoutStore.resetAll()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            HStack(spacing: 14) {
                EditorLegendItem(
                    title: "Selected",
                    fill: Color.accentColor,
                    stroke: Color.accentColor,
                    lineWidth: 2,
                    dot: nil
                )
                EditorLegendItem(
                    title: "Moved",
                    fill: Color(NSColor.controlBackgroundColor),
                    stroke: Color.orange,
                    lineWidth: 2,
                    dot: nil
                )
                EditorLegendItem(
                    title: "Width",
                    fill: Color(NSColor.controlBackgroundColor),
                    stroke: Color(NSColor.separatorColor),
                    lineWidth: 1,
                    dot: .purple
                )
                EditorLegendItem(
                    title: "Pressed",
                    fill: Color.accentColor.opacity(0.22),
                    stroke: Color.accentColor,
                    lineWidth: 2,
                    dot: nil
                )
                Spacer()
                Text("ISO <> is between left Shift and Z/Y.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            GeometryReader { geometry in
                VStack(spacing: 4) {
                    ForEach(0...KeyboardLayoutInfo.maxRow, id: \.self) { row in
                        KeyRow(
                            row: row,
                            containerWidth: geometry.size.width,
                            selectedKey: $selectedKey,
                            pressedKeys: pressedKeys,
                            previewSession: previewSession,
                            layoutStore: layoutStore,
                            showArrowSubRow: row == KeyboardLayoutInfo.maxRow
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let keyCode = selectedKey,
                   let keyInfo = KeyboardLayoutInfo.allKeys.first(where: { $0.id == keyCode }) {
                    let effectiveOffset = layoutStore.effectiveOffset(for: keyCode)
                    let isModified = effectiveOffset != 0 ||
                        layoutStore.effectiveWidthMultiplier(for: keyCode) != 1
                    HStack {
                        Text("Selected: \(keyInfo.label)")
                            .font(.subheadline)
                            .bold()
                        Text("Offset: \(String(format: "%.1f%%", effectiveOffset * 100))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Label(
                            isModified ? "Modified" : "Default",
                            systemImage: isModified ? "pencil.circle.fill" : "checkmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(isModified ? Color.orange : Color.secondary)
                        .accessibilityLabel(isModified ? "Selected key is modified" : "Selected key uses defaults")
                        Spacer()
                        Button("Reset This Key") {
                            layoutStore.resetKey(keyCode)
                            postWidthPreview(for: keyCode)
                            scheduleHidePreview()
                        }
                        .buttonStyle(.link)
                        .accessibilityHint("Restores this key's position and glow width")
                    }

                    HStack(spacing: 8) {
                        Text("Glow Width:")
                            .font(.caption)
                        Slider(
                            value: Binding(
                                get: { layoutStore.effectiveWidthMultiplier(for: keyCode) },
                                set: { newValue in
                                    layoutStore.setWidthMultiplier(newValue, for: keyCode)
                                    postWidthPreview(for: keyCode)
                                }
                            ),
                            in: 0.3...3.0,
                            onEditingChanged: { isEditing in
                                if isEditing {
                                    layoutStore.beginGestureTransaction()
                                    postWidthPreview(for: keyCode)
                                } else {
                                    layoutStore.endGestureTransaction()
                                    scheduleHidePreview()
                                }
                            }
                        )
                        .frame(width: 200)
                        .accessibilityLabel("Glow width for \(keyInfo.label)")
                        .accessibilityValue("\(Int(layoutStore.effectiveWidthMultiplier(for: keyCode) * 100)) percent")
                        Text("\(Int(layoutStore.effectiveWidthMultiplier(for: keyCode) * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                } else {
                    Text("Click a key to select, then drag to adjust its glow position. Use the slider to adjust glow width.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .onChange(of: model.physicalKeyActivity) { _, activity in
            handlePhysicalKeyActivity(activity)
        }
        .onDisappear {
            layoutStore.endGestureTransaction()
            pressedKeys.removeAll()
            previewSession.stop()
        }
    }

    private func postWidthPreview(for keyCode: UInt16) {
        guard let keyInfo = KeyboardLayoutInfo.allKeys.first(where: { $0.id == keyCode }) else {
            return
        }
        let position = layoutStore.adjustedPosition(for: keyCode, originalPosition: keyInfo.position)
        let keyWidth = layoutStore.effectiveWidth(for: keyCode, defaultWidth: keyInfo.width)
        postPreview(keyCode: keyCode, position: position, keyWidth: keyWidth)
    }

    private func scheduleHidePreview() {
        postHidePreview(after: 0.5)
    }

    private func postPreview(keyCode: UInt16, position: CGFloat, keyWidth: CGFloat) {
        previewSession.show(keyCode: keyCode, position: position, keyWidth: keyWidth)
    }

    private func postHidePreview(after delay: TimeInterval) {
        previewSession.scheduleHide(after: delay)
    }

    private func handlePhysicalKeyActivity(_ activity: PhysicalKeyActivity?) {
        guard let activity else {
            pressedKeys.removeAll()
            return
        }
        let keyCode = KeyboardLayoutInfo.canonicalKeyCode(for: activity.keyCode)
        if activity.isDown {
            pressedKeys.insert(keyCode)
            if KeyboardLayoutInfo.allKeys.contains(where: { $0.id == keyCode }) {
                selectedKey = keyCode
            }
        } else {
            pressedKeys.remove(keyCode)
        }
    }
}

/// A row of keys on the keyboard
struct KeyRow: View {
    let row: Int
    let containerWidth: CGFloat
    @Binding var selectedKey: UInt16?
    let pressedKeys: Set<UInt16>
    let previewSession: KeyEditorGlowPreviewSession
    @ObservedObject var layoutStore: KeyLayoutStore
    let showArrowSubRow: Bool

    var body: some View {
        let keys = KeyboardLayoutInfo.keys(forRow: row)
        let arrowRow = KeyboardLayoutInfo.maxRow
        let standardKeys = row == arrowRow ? keys.filter { ![126, 125].contains($0.id) } : keys
        let arrowKeys = row == arrowRow ? keys.filter { [126, 125].contains($0.id) } : []

        ZStack {
            ForEach(standardKeys) { key in
                DraggableKeyView(
                    key: key,
                    containerWidth: containerWidth,
                    isSelected: selectedKey == key.id,
                    isPressed: pressedKeys.contains(key.id),
                    previewSession: previewSession,
                    layoutStore: layoutStore,
                    onSelect: { selectedKey = key.id }
                )
            }

            if showArrowSubRow {
                ForEach(arrowKeys) { key in
                    DraggableKeyView(
                        key: key,
                        containerWidth: containerWidth,
                        isSelected: selectedKey == key.id,
                        isPressed: pressedKeys.contains(key.id),
                        previewSession: previewSession,
                        layoutStore: layoutStore,
                        onSelect: { selectedKey = key.id },
                        verticalOffset: key.id == 126 ? -12 : 12
                    )
                }
            }
        }
        .frame(height: 36)
    }
}

/// Individual draggable key
struct DraggableKeyView: View {
    let key: KeyboardLayoutInfo.KeyDisplayInfo
    let containerWidth: CGFloat
    let isSelected: Bool
    let isPressed: Bool
    let previewSession: KeyEditorGlowPreviewSession
    @ObservedObject var layoutStore: KeyLayoutStore
    let onSelect: () -> Void
    var verticalOffset: CGFloat = 0

    @State private var dragOffset: CGFloat = 0

    private var keyWidth: CGFloat {
        28 * key.width
    }

    private var currentOffset: CGFloat {
        layoutStore.effectiveOffset(for: key.id)
    }

    private var hasWidthOverride: Bool {
        layoutStore.hasWidthMultiplierOverride(for: key.id)
    }

    private var effectiveWidthMultiplier: CGFloat {
        layoutStore.effectiveWidthMultiplier(for: key.id)
    }

    private var effectiveKeyWidth: CGFloat {
        layoutStore.effectiveWidth(for: key.id, defaultWidth: key.width)
    }

    private var adjustedPosition: CGFloat {
        key.position + currentOffset + dragOffset / containerWidth
    }

    private var isModified: Bool {
        currentOffset != 0 || effectiveWidthMultiplier != 1.0
    }

    private var accessibilityValue: String {
        let offset = String(format: "%.1f percent", currentOffset * 100)
        let width = Int(effectiveWidthMultiplier * 100)
        return "Offset \(offset), glow width \(width) percent\(isModified ? ", modified" : "")"
    }

    private func postPreview(position: CGFloat) {
        previewSession.show(
            keyCode: key.id,
            position: position,
            keyWidth: effectiveKeyWidth
        )
    }

    private func scheduleHidePreview(after delay: TimeInterval) {
        previewSession.scheduleHide(after: delay)
    }

    private func selectAndPreview() {
        onSelect()
        postPreview(position: key.position + currentOffset)
        scheduleHidePreview(after: 1.0)
    }

    private func nudge(_ direction: MoveCommandDirection, isLargeStep: Bool) {
        guard direction == .left || direction == .right else { return }
        onSelect()
        let step: CGFloat = isLargeStep ? 0.01 : 0.001
        let signedStep = direction == .left ? -step : step
        layoutStore.setOffset(currentOffset + signedStep, for: key.id)
        postPreview(position: key.position + layoutStore.effectiveOffset(for: key.id))
        scheduleHidePreview(after: 0.5)
    }

    var body: some View {
        GeometryReader { geometry in
            let xPosition = adjustedPosition * containerWidth

            Button(action: selectAndPreview) {
                Text(key.label)
                .font(.system(size: key.width > 1.5 ? 10 : 11, weight: .medium))
                .foregroundColor(isSelected ? .white : .primary)
                .frame(width: keyWidth, height: verticalOffset != 0 ? 20 : 32)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            isSelected
                            ? Color.accentColor
                            : (isPressed ? Color.accentColor.opacity(0.22) : Color(NSColor.controlBackgroundColor))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            isPressed ? Color.accentColor : (isModified ? Color.orange : Color(NSColor.separatorColor)),
                            lineWidth: (isPressed || isModified) ? 2 : 1
                        )
                )
                .overlay(alignment: .topTrailing) {
                    if hasWidthOverride {
                        Circle()
                            .fill(Color.purple)
                            .frame(width: 6, height: 6)
                            .offset(x: -3, y: 3)
                        }
                }
            }
                .buttonStyle(.plain)
                .position(x: xPosition, y: geometry.size.height / 2 + verticalOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            onSelect()
                            layoutStore.beginGestureTransaction()
                            dragOffset = value.translation.width

                            let previewPosition = adjustedPosition
                            postPreview(position: previewPosition)
                        }
                        .onEnded { value in
                            let newOffset = currentOffset + value.translation.width / containerWidth
                            layoutStore.setOffset(newOffset, for: key.id)
                            layoutStore.endGestureTransaction()
                            dragOffset = 0

                            scheduleHidePreview(after: 0.5)
                        }
                )
                .onMoveCommand { direction in
                    nudge(direction, isLargeStep: NSEvent.modifierFlags.contains(.shift))
                }
                .accessibilityLabel(key.label)
                .accessibilityValue(accessibilityValue)
                .accessibilityHint("Press to preview. Use Left and Right Arrow to adjust position; hold Shift for larger steps.")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        nudge(.right, isLargeStep: false)
                    case .decrement:
                        nudge(.left, isLargeStep: false)
                    @unknown default:
                        break
                    }
                }
        }
    }
}

struct EditorLegendItem: View {
    let title: String
    let fill: Color
    let stroke: Color
    let lineWidth: CGFloat
    let dot: Color?

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(fill)
                .frame(width: 16, height: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(stroke, lineWidth: lineWidth)
                )
                .overlay(alignment: .topTrailing) {
                    if let dot {
                        Circle()
                            .fill(dot)
                            .frame(width: 4, height: 4)
                            .offset(x: 2, y: -2)
                    }
                }
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
