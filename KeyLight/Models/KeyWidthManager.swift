import Foundation
import CoreGraphics
import Combine

/// Manages custom per-key width multipliers that persist across app launches
@MainActor
final class KeyWidthManager: ObservableObject {
    static let shared = KeyWidthManager()

    /// Width multiplier for each key (keyCode -> multiplier, 1.0 = default)
    @Published private(set) var keyWidthOverrides: [UInt16: CGFloat] = [:]

    private let userDefaultsKey = "KeyWidthOverrides"

    // Undo/Redo support
    private var undoStack: [[UInt16: CGFloat]] = []
    private var redoStack: [[UInt16: CGFloat]] = []
    private let maxUndoLevels = 50

    // Debouncing for saves and notifications
    private var saveWorkItem: DispatchWorkItem?
    private var notificationWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.1

    private static let maxOverridesCount = 512
    private static let allowedKeyCodes: Set<UInt16> = Set(KeyboardLayoutInfo.allKeys.map(\.id))
    private static let minWidthMultiplier: CGFloat = 0.1
    private static let maxWidthMultiplier: CGFloat = 5.0

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private init() {
        loadOverrides()
    }

    /// Get the effective width for a key (default width * override multiplier)
    func effectiveWidth(for keyCode: UInt16, defaultWidth: CGFloat) -> CGFloat {
        let multiplier = effectiveWidthMultiplier(for: keyCode)
        return defaultWidth * multiplier
    }

    func effectiveWidthMultiplier(for keyCode: UInt16) -> CGFloat {
        let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
        if let direct = keyWidthOverrides[canonicalKeyCode] {
            return direct
        }
        if canonicalKeyCode != keyCode, let legacyDirect = keyWidthOverrides[keyCode] {
            return legacyDirect
        }
        return 1.0
    }

    func hasDirectOverride(for keyCode: UInt16) -> Bool {
        keyWidthOverrides[keyCode] != nil
    }

    /// Set a width multiplier for a key
    func setWidthMultiplier(_ multiplier: CGFloat, for keyCode: UInt16) {
        pushUndo()
        let sanitizedMultiplier: CGFloat
        if multiplier.isFinite {
            sanitizedMultiplier = min(max(multiplier, Self.minWidthMultiplier), Self.maxWidthMultiplier)
        } else {
            sanitizedMultiplier = 1.0
        }
        let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
        keyWidthOverrides[canonicalKeyCode] = sanitizedMultiplier
        if canonicalKeyCode != keyCode {
            keyWidthOverrides.removeValue(forKey: keyCode)
        }
        debouncedSave()
        debouncedNotify()
    }

    /// Reset a single key to its default width
    func resetKey(_ keyCode: UInt16) {
        pushUndo()
        let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
        keyWidthOverrides.removeValue(forKey: canonicalKeyCode)
        if canonicalKeyCode != keyCode {
            keyWidthOverrides.removeValue(forKey: keyCode)
        }
        saveImmediately()
        NotificationCenter.default.post(name: .keyWidthsChanged, object: nil)
    }

    /// Reset all keys to their default widths
    func resetAllKeys() {
        pushUndo()
        keyWidthOverrides.removeAll()
        saveImmediately()
        NotificationCenter.default.post(name: .keyWidthsChanged, object: nil)
    }

    /// Replace all overrides at once (for profile loading)
    func replaceAllOverrides(_ overrides: [UInt16: CGFloat]) {
        pushUndo()
        keyWidthOverrides = normalizedOverrides(from: overrides)
        saveImmediately()
        NotificationCenter.default.post(name: .keyWidthsChanged, object: nil)
    }

    /// Export overrides as a string-keyed dictionary.
    func exportOverrides() -> [String: CGFloat] {
        keyWidthOverrides.reduce(into: [String: CGFloat]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
    }

    // MARK: - Undo/Redo

    private func pushUndo() {
        undoStack.append(keyWidthOverrides)
        if undoStack.count > maxUndoLevels {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func undo() {
        guard let previousState = undoStack.popLast() else { return }
        redoStack.append(keyWidthOverrides)
        keyWidthOverrides = previousState
        saveImmediately()
        NotificationCenter.default.post(name: .keyWidthsChanged, object: nil)
    }

    func redo() {
        guard let nextState = redoStack.popLast() else { return }
        undoStack.append(keyWidthOverrides)
        keyWidthOverrides = nextState
        saveImmediately()
        NotificationCenter.default.post(name: .keyWidthsChanged, object: nil)
    }

    // MARK: - Debounced Operations

    private func debouncedSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveImmediately()
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func debouncedNotify() {
        notificationWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            NotificationCenter.default.post(name: .keyWidthsChanged, object: nil)
        }
        notificationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    // MARK: - Persistence

    private func saveImmediately() {
        saveWorkItem?.cancel()
        let stringKeyedDict = keyWidthOverrides.reduce(into: [String: CGFloat]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
        UserDefaults.standard.set(stringKeyedDict, forKey: userDefaultsKey)
    }

    private func normalizedOverrides(from overrides: [UInt16: CGFloat]) -> [UInt16: CGFloat] {
        var canonicalValues: [UInt16: CGFloat] = [:]
        var aliasFallbackValues: [UInt16: CGFloat] = [:]

        for keyCode in overrides.keys.sorted() {
            guard let value = overrides[keyCode], value.isFinite else { continue }
            let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
            guard Self.allowedKeyCodes.contains(canonicalKeyCode) else { continue }

            let clamped = min(max(value, Self.minWidthMultiplier), Self.maxWidthMultiplier)
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
        normalized.reserveCapacity(min(merged.count, Self.maxOverridesCount))
        for keyCode in merged.keys.sorted() {
            if normalized.count >= Self.maxOverridesCount { break }
            if let value = merged[keyCode] {
                normalized[keyCode] = value
            }
        }

        return normalized
    }

    private func loadOverrides() {
        guard let dict = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: CGFloat] else {
            return
        }

        var decoded: [UInt16: CGFloat] = [:]
        decoded.reserveCapacity(min(dict.count, Self.maxOverridesCount))
        for (key, value) in dict {
            if decoded.count >= Self.maxOverridesCount { break }
            if let keyCode = UInt16(key) {
                decoded[keyCode] = value
            }
        }

        keyWidthOverrides = normalizedOverrides(from: decoded)
    }
}
