import Combine
import CoreGraphics
import Foundation

/// A complete, value-semantic snapshot of the user's keyboard calibration.
///
/// The persisted representation intentionally remains split across the legacy
/// `KeyPositionOffsets` and `KeyWidthOverrides` UserDefaults keys. This value is
/// only the in-memory boundary that lets position and width edits participate in
/// the same transaction and undo history.
struct KeyLayout: Equatable {
    var offsets: [UInt16: CGFloat]
    var widthMultipliers: [UInt16: CGFloat]

    init(
        offsets: [UInt16: CGFloat] = [:],
        widthMultipliers: [UInt16: CGFloat] = [:]
    ) {
        self.offsets = offsets
        self.widthMultipliers = widthMultipliers
    }

    static let empty = KeyLayout()
}

/// Owns the live keyboard calibration, its saved baseline, history, and legacy
/// persistence. It reads and writes the established position and width keys as
/// one atomic value without an internal notification bus.
@MainActor
final class KeyLayoutStore: ObservableObject {
    static let offsetsKey = "KeyPositionOffsets"
    static let widthMultipliersKey = "KeyWidthOverrides"

    static let maximumEntryCount = 512
    static let minimumOffset: CGFloat = -0.5
    static let maximumOffset: CGFloat = 0.5
    static let minimumWidthMultiplier: CGFloat = 0.1
    static let maximumWidthMultiplier: CGFloat = 5.0

    @Published private(set) var layout: KeyLayout
    @Published private(set) var baseline: KeyLayout
    @Published private(set) var savedProfiles: [KeyMappingProfile]
    @Published private(set) var selectedProfileID: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    var keyOffsets: [UInt16: CGFloat] { layout.offsets }
    var widthMultipliers: [UInt16: CGFloat] { layout.widthMultipliers }
    var isEdited: Bool { layout != baseline }
    var selectedProfile: KeyMappingProfile? {
        selectedProfileID.flatMap { id in savedProfiles.first(where: { $0.id == id }) }
    }
    var selectedProfileIsEdited: Bool {
        guard let selectedProfile else { return false }
        let savedLayout = Self.normalized(KeyLayout(
            offsets: selectedProfile.keyOffsets,
            widthMultipliers: selectedProfile.keyWidthOverrides
        ))
        return savedLayout != layout
    }

    private let preferencesStore: PreferencesStore
    private let settingsManager: SettingsManager?
    private let debounceNanoseconds: UInt64
    private let maximumUndoLevels: Int

    private var undoStack: [KeyLayout] = []
    private var redoStack: [KeyLayout] = []
    private var gestureStartLayout: KeyLayout?
    private var pendingCommitTask: Task<Void, Never>?

    private static let allowedKeyCodes = Set(KeyboardLayoutInfo.allKeys.map(\.id))

    init(
        preferencesStore: PreferencesStore = .standard,
        settingsManager: SettingsManager? = nil,
        debounceInterval: TimeInterval = 0.1,
        maximumUndoLevels: Int = 50
    ) {
        self.preferencesStore = preferencesStore
        self.settingsManager = settingsManager
        self.debounceNanoseconds = Self.nanoseconds(for: debounceInterval)
        self.maximumUndoLevels = max(1, maximumUndoLevels)

        let loaded = Self.loadLayout(from: preferencesStore)
        self.layout = loaded
        self.baseline = loaded
        let profiles = settingsManager?.savedKeyMappingProfiles ?? []
        self.savedProfiles = profiles
        self.selectedProfileID = settingsManager?.activeLayoutID
            ?? settingsManager.flatMap { manager in
                profiles.first(where: { $0.name == manager.currentKeyMappingProfileName })?.id
            }
    }

    /// Test/source-compatibility initializer. All reads and writes still cross
    /// the PreferencesStore adapter; KeyLayoutStore never talks to defaults
    /// directly.
    convenience init(
        defaults: UserDefaults,
        debounceInterval: TimeInterval = 0.1,
        maximumUndoLevels: Int = 50
    ) {
        self.init(
            preferencesStore: PreferencesStore(userDefaults: defaults),
            settingsManager: nil,
            debounceInterval: debounceInterval,
            maximumUndoLevels: maximumUndoLevels
        )
    }

    // MARK: - Read access

    /// Refreshes saved-profile identity after a persistence transaction. The
    /// layout draft itself remains untouched so imports and renames cannot
    /// silently discard unsaved calibration edits.
    func reloadSavedProfiles(from manager: SettingsManager? = nil) {
        guard let manager = manager ?? settingsManager else { return }
        let profiles = manager.savedKeyMappingProfiles
        savedProfiles = profiles
        selectedProfileID = manager.activeLayoutID
            ?? profiles.first(where: { $0.name == manager.currentKeyMappingProfileName })?.id
    }

    /// Applies a saved layout by stable identity. Display routing uses this
    /// same transaction as the Settings profile picker so geometry and legacy
    /// selection persistence cannot drift apart.
    @discardableResult
    func selectSavedProfile(id: UUID) -> Bool {
        guard let profile = savedProfiles.first(where: { $0.id == id }) else {
            return false
        }
        apply(
            KeyLayout(
                offsets: profile.keyOffsets,
                widthMultipliers: profile.keyWidthOverrides
            ),
            asBaseline: true
        )
        settingsManager?.activeLayoutID = profile.id
        selectedProfileID = profile.id
        return true
    }

    func effectiveOffset(for keyCode: UInt16) -> CGFloat {
        layout.offsets[KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)] ?? 0
    }

    func adjustedPosition(for keyCode: UInt16, originalPosition: CGFloat) -> CGFloat {
        let adjusted = originalPosition + effectiveOffset(for: keyCode)
        return min(max(adjusted, 0), 1)
    }

    func effectiveWidthMultiplier(for keyCode: UInt16) -> CGFloat {
        layout.widthMultipliers[KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)] ?? 1
    }

    func effectiveWidth(for keyCode: UInt16, defaultWidth: CGFloat) -> CGFloat {
        defaultWidth * effectiveWidthMultiplier(for: keyCode)
    }

    func hasWidthMultiplierOverride(for keyCode: UInt16) -> Bool {
        layout.widthMultipliers[KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)] != nil
    }

    // MARK: - Editing

    func setOffset(_ offset: CGFloat, for keyCode: UInt16) {
        guard let canonicalKeyCode = Self.allowedCanonicalKeyCode(for: keyCode) else { return }

        var next = layout
        let finiteOffset = offset.isFinite ? offset : 0
        next.offsets[canonicalKeyCode] = Self.clampOffset(finiteOffset)
        mutate(to: next)
    }

    func setWidthMultiplier(_ multiplier: CGFloat, for keyCode: UInt16) {
        guard let canonicalKeyCode = Self.allowedCanonicalKeyCode(for: keyCode) else { return }

        var next = layout
        let finiteMultiplier = multiplier.isFinite ? multiplier : 1
        next.widthMultipliers[canonicalKeyCode] = Self.clampWidthMultiplier(finiteMultiplier)
        mutate(to: next)
    }

    /// Begins a coalesced editor gesture. All position and width changes until
    /// `endGestureTransaction()` become one undo step.
    func beginGestureTransaction() {
        guard gestureStartLayout == nil else { return }
        gestureStartLayout = layout
    }

    func endGestureTransaction() {
        finishGestureTransactionIfNeeded()
    }

    /// Replaces offsets and widths together and records one undo step.
    /// Passing `asBaseline` is appropriate when selecting a saved profile.
    func apply(_ newLayout: KeyLayout, asBaseline: Bool = false) {
        finishGestureTransactionIfNeeded()
        let normalized = Self.normalized(newLayout)
        mutate(to: normalized)
        if asBaseline {
            baseline = normalized
        }
    }

    /// Removes both calibration dimensions for one key as one undo step.
    func resetKey(_ keyCode: UInt16) {
        guard let canonicalKeyCode = Self.allowedCanonicalKeyCode(for: keyCode) else { return }
        finishGestureTransactionIfNeeded()

        var next = layout
        next.offsets.removeValue(forKey: canonicalKeyCode)
        next.widthMultipliers.removeValue(forKey: canonicalKeyCode)
        mutate(to: next)
    }

    /// Compatibility operation for callers that still edit position and width
    /// independently. New calibration UI should prefer `resetKey(_:)`.
    func resetOffset(for keyCode: UInt16) {
        guard let canonicalKeyCode = Self.allowedCanonicalKeyCode(for: keyCode) else { return }
        finishGestureTransactionIfNeeded()

        var next = layout
        next.offsets.removeValue(forKey: canonicalKeyCode)
        mutate(to: next)
    }

    func resetWidthMultiplier(for keyCode: UInt16) {
        guard let canonicalKeyCode = Self.allowedCanonicalKeyCode(for: keyCode) else { return }
        finishGestureTransactionIfNeeded()

        var next = layout
        next.widthMultipliers.removeValue(forKey: canonicalKeyCode)
        mutate(to: next)
    }

    /// Restores the unmodified keyboard as one atomic operation.
    func resetAll() {
        finishGestureTransactionIfNeeded()
        mutate(to: .empty)
    }

    func resetAllOffsets() {
        finishGestureTransactionIfNeeded()
        var next = layout
        next.offsets.removeAll()
        mutate(to: next)
    }

    func resetAllWidthMultipliers() {
        finishGestureTransactionIfNeeded()
        var next = layout
        next.widthMultipliers.removeAll()
        mutate(to: next)
    }

    func replaceAllOffsets(_ offsets: [UInt16: CGFloat]) {
        finishGestureTransactionIfNeeded()
        var next = layout
        next.offsets = offsets
        mutate(to: next)
    }

    func replaceAllWidthMultipliers(_ multipliers: [UInt16: CGFloat]) {
        finishGestureTransactionIfNeeded()
        var next = layout
        next.widthMultipliers = multipliers
        mutate(to: next)
    }

    /// Restores the last saved/profile baseline as one atomic operation.
    func revert() {
        finishGestureTransactionIfNeeded()
        mutate(to: baseline)
    }

    /// Marks the live value as the saved/profile baseline without changing its
    /// persistence format or clearing useful undo history.
    func markCurrentAsBaseline() {
        baseline = layout
    }

    // MARK: - History

    func undo() {
        finishGestureTransactionIfNeeded()
        guard let previous = undoStack.popLast() else { return }

        appendToRedo(layout)
        replaceLiveLayout(with: previous)
        updateHistoryAvailability()
    }

    func redo() {
        finishGestureTransactionIfNeeded()
        guard let next = redoStack.popLast() else { return }

        appendToUndo(layout)
        replaceLiveLayout(with: next)
        updateHistoryAvailability()
    }

    // MARK: - Persistence

    /// Immediately writes the current value. Call this during orderly termination.
    func flush() {
        pendingCommitTask?.cancel()
        pendingCommitTask = nil
        persistCurrentLayout()
    }

    /// Cancels trailing persistence without discarding current in-memory edits.
    func cancelPendingWork() {
        pendingCommitTask?.cancel()
        pendingCommitTask = nil
    }

    /// Reloads legacy values written by an older build and treats them as the
    /// new saved baseline. This is a migration bridge, not a second format.
    func reloadFromPersistence() {
        cancelPendingWork()
        let loaded = Self.loadLayout(from: preferencesStore)
        guard loaded != layout else { return }

        gestureStartLayout = nil
        undoStack.removeAll()
        redoStack.removeAll()
        layout = loaded
        baseline = loaded
        updateHistoryAvailability()
    }

    // MARK: - Compatibility helpers

    static func normalized(_ layout: KeyLayout) -> KeyLayout {
        KeyLayout(
            offsets: normalizedOffsets(layout.offsets),
            widthMultipliers: normalizedWidthMultipliers(layout.widthMultipliers)
        )
    }

    static func normalizedOffsets(_ offsets: [UInt16: CGFloat]) -> [UInt16: CGFloat] {
        normalizedValues(offsets, clamp: clampOffset)
    }

    static func normalizedWidthMultipliers(_ multipliers: [UInt16: CGFloat]) -> [UInt16: CGFloat] {
        normalizedValues(multipliers, clamp: clampWidthMultiplier)
    }

    static func normalizedImportedOffsets(from offsets: [String: CGFloat]) -> [String: CGFloat] {
        let decoded = offsets.reduce(into: [UInt16: CGFloat]()) { result, pair in
            guard let keyCode = UInt16(pair.key), pair.value.isFinite else { return }
            result[keyCode] = pair.value
        }
        return normalizedOffsets(decoded).reduce(into: [String: CGFloat]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
    }

    func exportOffsets() -> [String: CGFloat] {
        Self.stringKeyed(layout.offsets)
    }

    func exportWidthMultipliers() -> [String: CGFloat] {
        Self.stringKeyed(layout.widthMultipliers)
    }

    // MARK: - Internal mutation

    private func mutate(to proposed: KeyLayout) {
        let normalized = Self.normalized(proposed)
        guard normalized != layout else { return }

        if gestureStartLayout == nil {
            appendToUndo(layout)
            redoStack.removeAll()
        }
        replaceLiveLayout(with: normalized)
        updateHistoryAvailability()
    }

    private func replaceLiveLayout(with replacement: KeyLayout) {
        guard replacement != layout else { return }

        layout = replacement
        scheduleCommit()
    }

    private func finishGestureTransactionIfNeeded() {
        guard let start = gestureStartLayout else { return }
        gestureStartLayout = nil

        if start != layout {
            appendToUndo(start)
            redoStack.removeAll()
        }
        updateHistoryAvailability()
    }

    private func appendToUndo(_ snapshot: KeyLayout) {
        undoStack.append(snapshot)
        trim(&undoStack)
    }

    private func appendToRedo(_ snapshot: KeyLayout) {
        redoStack.append(snapshot)
        trim(&redoStack)
    }

    private func trim(_ history: inout [KeyLayout]) {
        if history.count > maximumUndoLevels {
            history.removeFirst(history.count - maximumUndoLevels)
        }
    }

    private func updateHistoryAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Deferred compatibility commit

    private func scheduleCommit() {
        pendingCommitTask?.cancel()
        let delay = debounceNanoseconds
        pendingCommitTask = Task { @MainActor [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingCommitTask = nil
            self.persistCurrentLayout()
        }
    }

    private func persistCurrentLayout() {
        preferencesStore.set(Self.stringKeyed(layout.offsets), forKey: Self.offsetsKey)
        preferencesStore.set(Self.stringKeyed(layout.widthMultipliers), forKey: Self.widthMultipliersKey)
    }

    // MARK: - Normalization

    private static func loadLayout(from preferencesStore: PreferencesStore) -> KeyLayout {
        KeyLayout(
            offsets: normalizedOffsets(numericDictionary(in: preferencesStore, forKey: offsetsKey)),
            widthMultipliers: normalizedWidthMultipliers(
                numericDictionary(in: preferencesStore, forKey: widthMultipliersKey)
            )
        )
    }

    private static func numericDictionary(
        in preferencesStore: PreferencesStore,
        forKey key: String
    ) -> [UInt16: CGFloat] {
        guard let stored = preferencesStore.dictionary(forKey: key) else { return [:] }

        var result: [UInt16: CGFloat] = [:]
        result.reserveCapacity(min(stored.count, maximumEntryCount))
        for stringKey in stored.keys.sorted() {
            guard let keyCode = UInt16(stringKey),
                  let rawValue = stored[stringKey] as? NSNumber else {
                continue
            }
            result[keyCode] = CGFloat(truncating: rawValue)
        }
        return result
    }

    private static func normalizedValues(
        _ values: [UInt16: CGFloat],
        clamp: (CGFloat) -> CGFloat
    ) -> [UInt16: CGFloat] {
        var canonicalValues: [UInt16: CGFloat] = [:]
        var aliasFallbackValues: [UInt16: CGFloat] = [:]

        for keyCode in values.keys.sorted() {
            guard let value = values[keyCode], value.isFinite,
                  let canonicalKeyCode = allowedCanonicalKeyCode(for: keyCode) else {
                continue
            }

            let normalizedValue = clamp(value)
            if keyCode == canonicalKeyCode {
                canonicalValues[canonicalKeyCode] = normalizedValue
            } else if aliasFallbackValues[canonicalKeyCode] == nil {
                aliasFallbackValues[canonicalKeyCode] = normalizedValue
            }
        }

        var merged = aliasFallbackValues
        for (keyCode, value) in canonicalValues {
            merged[keyCode] = value
        }

        var result: [UInt16: CGFloat] = [:]
        result.reserveCapacity(min(merged.count, maximumEntryCount))
        for keyCode in merged.keys.sorted().prefix(maximumEntryCount) {
            result[keyCode] = merged[keyCode]
        }
        return result
    }

    private static func allowedCanonicalKeyCode(for keyCode: UInt16) -> UInt16? {
        let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
        return allowedKeyCodes.contains(canonicalKeyCode) ? canonicalKeyCode : nil
    }

    private static func clampOffset(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumOffset), maximumOffset)
    }

    private static func clampWidthMultiplier(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumWidthMultiplier), maximumWidthMultiplier)
    }

    private static func stringKeyed(_ values: [UInt16: CGFloat]) -> [String: CGFloat] {
        values.reduce(into: [String: CGFloat]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else { return 0 }
        let nanoseconds = interval * 1_000_000_000
        return UInt64(min(nanoseconds, Double(UInt64.max)))
    }
}
