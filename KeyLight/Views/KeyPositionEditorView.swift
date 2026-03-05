import SwiftUI
import AppKit

/// Window that displays the key position editor
@MainActor
final class KeyPositionEditorWindow: NSWindow {
    init() {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let windowWidth: CGFloat = min(screenFrame.width * 0.9, 1200)
        let windowHeight: CGFloat = 460

        let contentRect = NSRect(
            x: (screenFrame.width - windowWidth) / 2,
            y: (screenFrame.height - windowHeight) / 2,
            width: windowWidth,
            height: windowHeight
        )

        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "Adjust Key Positions"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 800, height: 380)

        let hostingView = NSHostingView(rootView: KeyPositionEditorView())
        contentView = hostingView
    }
}

/// Main view for adjusting key positions by dragging
struct KeyPositionEditorView: View {
    @ObservedObject private var positionManager = KeyPositionManager.shared
    @ObservedObject private var keyWidthManager = KeyWidthManager.shared

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

                Button(action: { positionManager.undo() }) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!positionManager.canUndo)
                .help("Undo (Cmd+Z)")
                .keyboardShortcut("z", modifiers: .command)

                Button(action: { positionManager.redo() }) {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!positionManager.canRedo)
                .help("Redo (Cmd+Shift+Z)")
                .keyboardShortcut("z", modifiers: [.command, .shift])

                Button("Reset All") {
                    showResetConfirmation = true
                }
                .focusable(false)
                .confirmationDialog(
                    "Reset all key positions to defaults?",
                    isPresented: $showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset All", role: .destructive) {
                        positionManager.resetAllKeys()
                        keyWidthManager.resetAllKeys()
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
                    let effectiveOffset = positionManager.effectiveOffset(for: keyCode)
                    HStack {
                        Text("Selected: \(keyInfo.label)")
                            .font(.subheadline)
                            .bold()
                        Text("Offset: \(String(format: "%.1f%%", effectiveOffset * 100))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Reset This Key") {
                            positionManager.resetKey(keyCode)
                            keyWidthManager.resetKey(keyCode)
                        }
                        .buttonStyle(.link)
                        .focusable(false)
                    }

                    HStack(spacing: 8) {
                        Text("Glow Width:")
                            .font(.caption)
                        Slider(
                            value: Binding(
                                get: { keyWidthManager.effectiveWidthMultiplier(for: keyCode) },
                                set: { newValue in
                                    keyWidthManager.setWidthMultiplier(newValue, for: keyCode)
                                    postWidthPreview(for: keyCode)
                                }
                            ),
                            in: 0.3...3.0,
                            onEditingChanged: { isEditing in
                                if isEditing {
                                    postWidthPreview(for: keyCode)
                                } else {
                                    scheduleHidePreview()
                                }
                            }
                        )
                        .frame(width: 200)
                        Text("\(Int(keyWidthManager.effectiveWidthMultiplier(for: keyCode) * 100))%")
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
        .onReceive(NotificationCenter.default.publisher(for: .physicalKeyDown)) { notification in
            handlePhysicalKeyDown(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .physicalKeyUp)) { notification in
            handlePhysicalKeyUp(notification)
        }
        .onDisappear {
            pressedKeys.removeAll()
        }
    }

    private func postWidthPreview(for keyCode: UInt16) {
        guard let keyInfo = KeyboardLayoutInfo.allKeys.first(where: { $0.id == keyCode }) else {
            return
        }
        let position = positionManager.adjustedPosition(for: keyCode, originalPosition: keyInfo.position)
        let keyWidth = keyWidthManager.effectiveWidth(for: keyCode, defaultWidth: keyInfo.width)
        postPreview(keyCode: keyCode, position: position, keyWidth: keyWidth)
    }

    private func scheduleHidePreview() {
        postHidePreview(after: 0.5)
    }

    private func postPreview(keyCode: UInt16, position: CGFloat, keyWidth: CGFloat) {
        NotificationCenter.default.post(
            name: .showGlowPreview,
            object: nil,
            userInfo: [
                "keyCode": keyCode,
                "position": position,
                "keyWidth": keyWidth
            ]
        )
    }

    private func postHidePreview(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NotificationCenter.default.post(name: .hideGlowPreview, object: nil)
        }
    }

    private func handlePhysicalKeyDown(_ notification: Notification) {
        guard let keyCode = physicalKeyCode(from: notification) else { return }
        pressedKeys.insert(keyCode)
    }

    private func handlePhysicalKeyUp(_ notification: Notification) {
        guard let keyCode = physicalKeyCode(from: notification) else { return }
        pressedKeys.remove(keyCode)
    }

    private func physicalKeyCode(from notification: Notification) -> UInt16? {
        let rawKeyCode: UInt16?
        if let direct = notification.userInfo?["keyCode"] as? UInt16 {
            rawKeyCode = direct
        } else if let number = notification.userInfo?["keyCode"] as? NSNumber {
            rawKeyCode = number.uint16Value
        } else if let intCode = notification.userInfo?["keyCode"] as? Int,
                  intCode >= 0,
                  intCode <= Int(UInt16.max) {
            rawKeyCode = UInt16(intCode)
        } else {
            rawKeyCode = nil
        }
        guard let rawKeyCode else { return nil }
        return KeyboardLayoutInfo.canonicalKeyCode(for: rawKeyCode)
    }
}

/// A row of keys on the keyboard
struct KeyRow: View {
    let row: Int
    let containerWidth: CGFloat
    @Binding var selectedKey: UInt16?
    let pressedKeys: Set<UInt16>
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
    let onSelect: () -> Void
    var verticalOffset: CGFloat = 0

    @ObservedObject private var positionManager = KeyPositionManager.shared
    @ObservedObject private var keyWidthManager = KeyWidthManager.shared
    @State private var dragOffset: CGFloat = 0

    private var keyWidth: CGFloat {
        28 * key.width
    }

    private var currentOffset: CGFloat {
        positionManager.effectiveOffset(for: key.id)
    }

    private var hasWidthOverride: Bool {
        keyWidthManager.hasDirectOverride(for: key.id)
    }

    private var effectiveWidthMultiplier: CGFloat {
        keyWidthManager.effectiveWidthMultiplier(for: key.id)
    }

    private var effectiveKeyWidth: CGFloat {
        keyWidthManager.effectiveWidth(for: key.id, defaultWidth: key.width)
    }

    private var adjustedPosition: CGFloat {
        key.position + currentOffset + dragOffset / containerWidth
    }

    private var isModified: Bool {
        currentOffset != 0 || effectiveWidthMultiplier != 1.0
    }

    private func postPreview(position: CGFloat) {
        NotificationCenter.default.post(
            name: .showGlowPreview,
            object: nil,
            userInfo: [
                "keyCode": key.id,
                "position": position,
                "keyWidth": effectiveKeyWidth
            ]
        )
    }

    private func scheduleHidePreview(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NotificationCenter.default.post(name: .hideGlowPreview, object: nil)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let xPosition = adjustedPosition * containerWidth

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
                .position(x: xPosition, y: geometry.size.height / 2 + verticalOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            onSelect()
                            dragOffset = value.translation.width

                            let previewPosition = adjustedPosition
                            postPreview(position: previewPosition)
                        }
                        .onEnded { value in
                            let newOffset = currentOffset + value.translation.width / containerWidth
                            positionManager.setOffset(newOffset, for: key.id)
                            dragOffset = 0

                            scheduleHidePreview(after: 0.5)
                        }
                )
                .onTapGesture {
                    onSelect()
                    postPreview(position: key.position + currentOffset)
                    scheduleHidePreview(after: 1.0)
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
