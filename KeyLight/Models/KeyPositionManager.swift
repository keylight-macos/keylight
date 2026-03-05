import Foundation
import CoreGraphics
import Combine

/// Manages custom per-key position offsets that persist across app launches
@MainActor
final class KeyPositionManager: ObservableObject {
    static let shared = KeyPositionManager()

    /// UserDefaults key for storing position offsets (shared with SettingsManager for export/import)
    static let offsetsKey = "KeyPositionOffsets"

    /// Position offset for each key (keyCode -> horizontal offset as fraction of screen width)
    @Published private(set) var keyOffsets: [UInt16: CGFloat] = [:]

    private let userDefaultsKey = offsetsKey

    private var undoStack: [[UInt16: CGFloat]] = []
    private var redoStack: [[UInt16: CGFloat]] = []
    private let maxUndoLevels = 50

    private var saveWorkItem: DispatchWorkItem?
    private var notificationWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.1

    private static let maxOffsetsCount = 512
    private static let allowedKeyCodes: Set<UInt16> = Set(KeyboardLayoutInfo.allKeys.map(\.id))

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private init() {
        loadOffsets()
    }

    func adjustedPosition(for keyCode: UInt16, originalPosition: CGFloat) -> CGFloat {
        guard !keyOffsets.isEmpty else { return originalPosition }
        let offset = effectiveOffset(for: keyCode)
        if offset == 0 {
            return originalPosition
        }
        return max(0.0, min(1.0, originalPosition + offset))
    }

    func effectiveOffset(for keyCode: UInt16) -> CGFloat {
        let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
        if let direct = keyOffsets[canonicalKeyCode] {
            return direct
        }
        if canonicalKeyCode != keyCode, let legacyDirect = keyOffsets[keyCode] {
            return legacyDirect
        }
        return 0.0
    }

    func setOffset(_ offset: CGFloat, for keyCode: UInt16) {
        pushUndo()
        let clampedOffset = max(-0.5, min(0.5, offset.isFinite ? offset : 0))
        let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
        keyOffsets[canonicalKeyCode] = clampedOffset
        if canonicalKeyCode != keyCode {
            keyOffsets.removeValue(forKey: keyCode)
        }
        debouncedSave()
        debouncedNotify()
    }

    func resetKey(_ keyCode: UInt16) {
        pushUndo()
        let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
        keyOffsets.removeValue(forKey: canonicalKeyCode)
        if canonicalKeyCode != keyCode {
            keyOffsets.removeValue(forKey: keyCode)
        }
        saveOffsetsImmediately()
        NotificationCenter.default.post(name: .keyPositionsChanged, object: nil)
    }

    func resetAllKeys() {
        pushUndo()
        keyOffsets.removeAll()
        saveOffsetsImmediately()
        NotificationCenter.default.post(name: .keyPositionsChanged, object: nil)
    }

    /// Replace all offsets at once.
    func replaceAllOffsets(_ offsets: [UInt16: CGFloat]) {
        pushUndo()
        keyOffsets = normalizedOffsets(from: offsets)
        saveOffsetsImmediately()
        NotificationCenter.default.post(name: .keyPositionsChanged, object: nil)
    }

    /// Export offsets as a string-keyed dictionary.
    func exportOffsets() -> [String: CGFloat] {
        keyOffsets.reduce(into: [String: CGFloat]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
    }

    /// Normalize imported string-keyed offsets using the same canonicalization/clamping rules as runtime edits.
    static func normalizedImportedOffsets(from offsets: [String: CGFloat]) -> [String: CGFloat] {
        var decoded: [UInt16: CGFloat] = [:]
        decoded.reserveCapacity(offsets.count)

        for (key, value) in offsets {
            guard let keyCode = UInt16(key), value.isFinite else { continue }
            decoded[keyCode] = value
        }

        let normalized = KeyPositionManager.shared.normalizedOffsets(from: decoded)
        return normalized.reduce(into: [String: CGFloat]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
    }

    func undo() {
        guard let previousState = undoStack.popLast() else { return }
        redoStack.append(keyOffsets)
        keyOffsets = previousState
        saveOffsetsImmediately()
        NotificationCenter.default.post(name: .keyPositionsChanged, object: nil)
    }

    func redo() {
        guard let nextState = redoStack.popLast() else { return }
        undoStack.append(keyOffsets)
        keyOffsets = nextState
        saveOffsetsImmediately()
        NotificationCenter.default.post(name: .keyPositionsChanged, object: nil)
    }

    func loadProfile(_ profile: SettingsManager.KeyMappingProfile) {
        pushUndo()
        keyOffsets = normalizedOffsets(from: profile.keyOffsets)
        KeyWidthManager.shared.replaceAllOverrides(profile.keyWidthOverrides)
        SettingsManager.shared.currentKeyMappingProfileName = profile.name
        saveOffsetsImmediately()
        NotificationCenter.default.post(name: .keyPositionsChanged, object: nil)
    }

    func reloadOffsets() {
        loadOffsets()
    }

    func cancelPendingWork() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        notificationWorkItem?.cancel()
        notificationWorkItem = nil
    }

    private func pushUndo() {
        undoStack.append(keyOffsets)
        if undoStack.count > maxUndoLevels {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    private func debouncedSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveOffsetsImmediately()
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func debouncedNotify() {
        notificationWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            NotificationCenter.default.post(name: .keyPositionsChanged, object: nil)
        }
        notificationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func saveOffsetsImmediately() {
        saveWorkItem?.cancel()
        let stringKeyedDict = keyOffsets.reduce(into: [String: CGFloat]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
        UserDefaults.standard.set(stringKeyedDict, forKey: userDefaultsKey)
    }

    private func normalizedOffsets(from offsets: [UInt16: CGFloat]) -> [UInt16: CGFloat] {
        var canonicalValues: [UInt16: CGFloat] = [:]
        var aliasFallbackValues: [UInt16: CGFloat] = [:]

        for keyCode in offsets.keys.sorted() {
            guard let value = offsets[keyCode], value.isFinite else { continue }
            let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
            guard Self.allowedKeyCodes.contains(canonicalKeyCode) else { continue }

            let clamped = max(-0.5, min(0.5, value))
            if keyCode == canonicalKeyCode {
                canonicalValues[canonicalKeyCode] = clamped
            } else if aliasFallbackValues[canonicalKeyCode] == nil {
                aliasFallbackValues[canonicalKeyCode] = clamped
            }
        }

        var merged: [UInt16: CGFloat] = aliasFallbackValues
        for (keyCode, value) in canonicalValues {
            merged[keyCode] = value
        }

        var normalized: [UInt16: CGFloat] = [:]
        normalized.reserveCapacity(min(merged.count, Self.maxOffsetsCount))
        for keyCode in merged.keys.sorted() {
            if normalized.count >= Self.maxOffsetsCount { break }
            if let value = merged[keyCode] {
                normalized[keyCode] = value
            }
        }
        return normalized
    }

    #if DEBUG
    func _testNormalizedOffsets(from offsets: [UInt16: CGFloat]) -> [UInt16: CGFloat] {
        normalizedOffsets(from: offsets)
    }
    #endif

    private func loadOffsets() {
        guard let dict = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: CGFloat] else {
            return
        }

        var decoded: [UInt16: CGFloat] = [:]
        decoded.reserveCapacity(min(dict.count, Self.maxOffsetsCount))
        for (key, value) in dict {
            if decoded.count >= Self.maxOffsetsCount { break }
            if let keyCode = UInt16(key) {
                decoded[keyCode] = value
            }
        }

        keyOffsets = normalizedOffsets(from: decoded)
    }
}

/// Provides keyboard layout info for the position editor
struct KeyboardLayoutInfo {
    struct KeyDisplayInfo: Identifiable {
        let id: UInt16
        let label: String
        let position: CGFloat
        let width: CGFloat
        let row: Int
    }

    // Media keys share physical function-key positions on Mac keyboards.
    private static let mediaToFunctionKeyAliases: [UInt16: UInt16] = [
        500: 122,  // Brightness down -> F1
        501: 120,  // Brightness up -> F2
        502: 99,   // Mission Control -> F3
        503: 118,  // Spotlight/Launchpad -> F4
        504: 96,   // Dictation -> F5
        505: 97,   // DND -> F6
        506: 98,   // Previous/Rewind -> F7
        507: 100,  // Legacy F8 media code -> F8
        516: 100,  // Play/Pause -> F8
        517: 101,  // Next -> F9
        518: 109,  // Mute -> F10
        519: 103,  // Volume down -> F11
        520: 111   // Volume up -> F12
    ]

    static func canonicalKeyCode(for keyCode: UInt16) -> UInt16 {
        mediaToFunctionKeyAliases[keyCode] ?? keyCode
    }

    static func isMediaAliasKey(_ keyCode: UInt16) -> Bool {
        mediaToFunctionKeyAliases[keyCode] != nil
    }

    static func fallbackKeyCode(for keyCode: UInt16) -> UInt16? {
        mediaToFunctionKeyAliases[keyCode]
    }

    // Source of truth for key editor positions/rows shown in the in-app layout calibrator.
    static let allKeys: [KeyDisplayInfo] = {
        var keys: [KeyDisplayInfo] = []

        // Function row (row 0)
        keys.append(KeyDisplayInfo(id: 53, label: "esc", position: 0.135, width: 1.0, row: 0))
        keys.append(KeyDisplayInfo(id: 122, label: "F1", position: 0.195, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 120, label: "F2", position: 0.250, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 99, label: "F3", position: 0.305, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 118, label: "F4", position: 0.360, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 96, label: "F5", position: 0.420, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 97, label: "F6", position: 0.475, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 98, label: "F7", position: 0.530, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 100, label: "F8", position: 0.585, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 101, label: "F9", position: 0.640, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 109, label: "F10", position: 0.695, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 103, label: "F11", position: 0.750, width: 0.8, row: 0))
        keys.append(KeyDisplayInfo(id: 111, label: "F12", position: 0.805, width: 0.8, row: 0))

        // Number row (row 1)
        keys.append(KeyDisplayInfo(id: 50, label: "`", position: 0.150, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 18, label: "1", position: 0.205, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 19, label: "2", position: 0.260, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 20, label: "3", position: 0.315, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 21, label: "4", position: 0.370, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 23, label: "5", position: 0.425, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 22, label: "6", position: 0.480, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 26, label: "7", position: 0.535, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 28, label: "8", position: 0.590, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 25, label: "9", position: 0.645, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 29, label: "0", position: 0.700, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 27, label: "-", position: 0.755, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 24, label: "=", position: 0.810, width: 1.0, row: 1))
        keys.append(KeyDisplayInfo(id: 51, label: "⌫", position: 0.860, width: 1.5, row: 1))

        // QWERTY row (row 2)
        keys.append(KeyDisplayInfo(id: 48, label: "⇥", position: 0.162, width: 1.5, row: 2))
        keys.append(KeyDisplayInfo(id: 12, label: "Q", position: 0.225, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 13, label: "W", position: 0.280, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 14, label: "E", position: 0.335, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 15, label: "R", position: 0.390, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 17, label: "T", position: 0.445, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 16, label: "Y", position: 0.500, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 32, label: "U", position: 0.555, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 34, label: "I", position: 0.610, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 31, label: "O", position: 0.665, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 35, label: "P", position: 0.720, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 33, label: "[", position: 0.775, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 30, label: "]", position: 0.830, width: 1.0, row: 2))
        keys.append(KeyDisplayInfo(id: 42, label: "\\", position: 0.872, width: 1.5, row: 2))

        // ASDF row (row 3)
        keys.append(KeyDisplayInfo(id: 57, label: "⇪", position: 0.168, width: 1.75, row: 3))
        keys.append(KeyDisplayInfo(id: 0, label: "A", position: 0.240, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 1, label: "S", position: 0.295, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 2, label: "D", position: 0.350, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 3, label: "F", position: 0.405, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 5, label: "G", position: 0.460, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 4, label: "H", position: 0.515, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 38, label: "J", position: 0.570, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 40, label: "K", position: 0.625, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 37, label: "L", position: 0.680, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 41, label: ";", position: 0.735, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 39, label: "'", position: 0.790, width: 1.0, row: 3))
        keys.append(KeyDisplayInfo(id: 36, label: "⏎", position: 0.855, width: 1.75, row: 3))

        // ZXCV row (row 4) - ISO layout with extra key
        keys.append(KeyDisplayInfo(id: 56, label: "⇧", position: 0.155, width: 1.25, row: 4))
        keys.append(KeyDisplayInfo(id: 10, label: "ISO <>", position: 0.220, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 6, label: "Z", position: 0.260, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 7, label: "X", position: 0.315, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 8, label: "C", position: 0.370, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 9, label: "V", position: 0.425, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 11, label: "B", position: 0.480, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 45, label: "N", position: 0.535, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 46, label: "M", position: 0.590, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 43, label: ",", position: 0.645, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 47, label: ".", position: 0.700, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 44, label: "/", position: 0.755, width: 1.0, row: 4))
        keys.append(KeyDisplayInfo(id: 60, label: "⇧", position: 0.840, width: 2.75, row: 4))

        // Bottom row (row 5)
        keys.append(KeyDisplayInfo(id: 63, label: "fn", position: 0.145, width: 1.0, row: 5))
        keys.append(KeyDisplayInfo(id: 59, label: "⌃", position: 0.200, width: 1.0, row: 5))
        keys.append(KeyDisplayInfo(id: 58, label: "⌥", position: 0.255, width: 1.0, row: 5))
        keys.append(KeyDisplayInfo(id: 55, label: "⌘", position: 0.320, width: 1.25, row: 5))
        keys.append(KeyDisplayInfo(id: 49, label: "space", position: 0.500, width: 6.0, row: 5))
        keys.append(KeyDisplayInfo(id: 54, label: "⌘", position: 0.680, width: 1.25, row: 5))
        keys.append(KeyDisplayInfo(id: 61, label: "⌥", position: 0.745, width: 1.0, row: 5))
        keys.append(KeyDisplayInfo(id: 123, label: "←", position: 0.810, width: 1.0, row: 5))
        keys.append(KeyDisplayInfo(id: 126, label: "↑", position: 0.860, width: 0.8, row: 5))
        keys.append(KeyDisplayInfo(id: 125, label: "↓", position: 0.860, width: 0.8, row: 5))
        keys.append(KeyDisplayInfo(id: 124, label: "→", position: 0.910, width: 1.0, row: 5))

        return keys
    }()

    static var maxRow: Int {
        allKeys.map(\.row).max() ?? 0
    }

    static func keys(forRow row: Int) -> [KeyDisplayInfo] {
        allKeys.filter { $0.row == row }
    }
}
