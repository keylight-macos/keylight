import CoreGraphics
import Foundation
import XCTest
@testable import KeyLight

final class KeyLayoutStoreTests: XCTestCase {
    @MainActor
    func testGuidedCalibrationUsesNineStableReferenceAnchors() {
        XCTAssertEqual(GuidedCalibrationDraft.anchors.map(\.keyCode), [
            18, 22, 24,
            0, 4, 36,
            55, 49, 124
        ])
        XCTAssertEqual(Set(GuidedCalibrationDraft.anchors.map(\.row)), Set([1, 3, 5]))
    }

    @MainActor
    func testGuidedCalibrationPreservesBaselineWhenAnchorsDoNotMove() {
        let baseline = KeyLayout(
            offsets: [18: 0.01, 4: -0.02, 49: 0.015],
            widthMultipliers: [18: 1.1, 49: 0.95]
        )
        let draft = GuidedCalibrationDraft(baseline: baseline)
        let fitted = draft.fittedLayout

        for key in KeyboardLayoutInfo.allKeys {
            XCTAssertEqual(
                key.position + (fitted.offsets[key.id] ?? 0),
                key.position + (baseline.offsets[key.id] ?? 0),
                accuracy: 0.000_001,
                "Position changed for \(key.label)"
            )
        }
    }

    @MainActor
    func testGuidedCalibrationInterpolatesAndNormalizesFittedLayout() {
        var draft = GuidedCalibrationDraft(baseline: .empty)
        for anchor in GuidedCalibrationDraft.anchors {
            draft.setAlignedPosition(
                draft.alignedPosition(for: anchor.keyCode) + 0.04,
                for: anchor.keyCode
            )
        }

        let fitted = draft.fittedLayout
        XCTAssertEqual(fitted.offsets[0] ?? .nan, 0.04, accuracy: 0.000_001)
        XCTAssertEqual(fitted.offsets[49] ?? .nan, 0.04, accuracy: 0.000_001)
        XCTAssertTrue(fitted.offsets.values.allSatisfy {
            $0 >= KeyLayoutStore.minimumOffset && $0 <= KeyLayoutStore.maximumOffset
        })
        XCTAssertTrue(fitted.widthMultipliers.values.allSatisfy {
            $0 >= KeyLayoutStore.minimumWidthMultiplier
                && $0 <= KeyLayoutStore.maximumWidthMultiplier
        })
    }

    @MainActor
    func testGuidedCalibrationCanCreateAndActivateNewProfileWithoutReplacingExisting() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(userDefaults: defaults)
        let settings = SettingsManager(preferencesStore: preferences)
        let existing = KeyMappingProfile(name: "Existing", keyOffsets: [49: 0.1])
        _ = settings.saveKeyMappingProfile(existing)
        let profilesBefore = settings.savedKeyMappingProfiles
        let store = KeyLayoutStore(
            preferencesStore: preferences,
            settingsManager: settings,
            debounceInterval: 60
        )
        defer { store.cancelPendingWork() }

        var draft = GuidedCalibrationDraft(baseline: store.layout)
        draft.setAlignedPosition(0.55, for: 49)
        let fitted = draft.fittedLayout
        let requested = KeyMappingProfile(
            name: "Guided Calibration",
            keyOffsets: fitted.offsets,
            keyWidthOverrides: fitted.widthMultipliers
        )
        let saved = try XCTUnwrap(settings.saveKeyMappingProfile(requested))
        store.reloadSavedProfiles(from: settings)
        XCTAssertTrue(store.selectSavedProfile(id: saved.id))

        let profilesAfter = settings.savedKeyMappingProfiles
        XCTAssertEqual(profilesAfter.count, profilesBefore.count + 1)
        for profile in profilesBefore {
            XCTAssertTrue(profilesAfter.contains(profile))
        }
        XCTAssertEqual(store.selectedProfileID, saved.id)
        XCTAssertEqual(store.layout, fitted)
    }

    @MainActor
    func testGuidedCalibrationDraftDoesNotMutateLayoutUntilCommitted() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(userDefaults: defaults)
        let settings = SettingsManager(preferencesStore: preferences)
        let store = KeyLayoutStore(
            preferencesStore: preferences,
            settingsManager: settings,
            debounceInterval: 60
        )
        defer { store.cancelPendingWork() }
        let baseline = store.layout
        let profilesBefore = settings.savedKeyMappingProfiles
        let offsetsBefore = defaults.dictionary(forKey: KeyLayoutStore.offsetsKey)
        let widthsBefore = defaults.dictionary(forKey: KeyLayoutStore.widthMultipliersKey)

        var abandonedDraft = GuidedCalibrationDraft(baseline: baseline)
        abandonedDraft.setAlignedPosition(0.61, for: 49)
        _ = abandonedDraft.fittedLayout

        XCTAssertEqual(store.layout, baseline)
        XCTAssertEqual(settings.savedKeyMappingProfiles, profilesBefore)
        XCTAssertEqual(
            defaults.dictionary(forKey: KeyLayoutStore.offsetsKey) as NSDictionary?,
            offsetsBefore as NSDictionary?
        )
        XCTAssertEqual(
            defaults.dictionary(forKey: KeyLayoutStore.widthMultipliersKey) as NSDictionary?,
            widthsBefore as NSDictionary?
        )
    }

    @MainActor
    func testSavedProfileIdentityAndEditedStateLiveInLayoutStore() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(userDefaults: defaults)
        let settings = SettingsManager(preferencesStore: preferences)
        var profile = KeyMappingProfile(
            name: "Baseline Layout",
            keyOffsets: [49: 0.1],
            keyWidthOverrides: [49: 1.25]
        )
        profile.id = UUID()
        settings.savedKeyMappingProfiles = [profile]
        settings.activeLayoutID = profile.id
        defaults.set(["49": 0.1], forKey: KeyLayoutStore.offsetsKey)
        defaults.set(["49": 1.25], forKey: KeyLayoutStore.widthMultipliersKey)

        let store = KeyLayoutStore(
            preferencesStore: preferences,
            settingsManager: settings,
            debounceInterval: 60
        )
        defer { store.cancelPendingWork() }

        XCTAssertEqual(store.selectedProfile?.id, profile.id)
        XCTAssertFalse(store.selectedProfileIsEdited)

        store.setOffset(0.2, for: 49)
        XCTAssertTrue(store.selectedProfileIsEdited)

        store.revert()
        XCTAssertFalse(store.selectedProfileIsEdited)

        settings.renameKeyMappingProfile(from: profile.name, to: "Renamed Layout")
        store.reloadSavedProfiles()
        XCTAssertEqual(store.selectedProfile?.id, profile.id)
        XCTAssertEqual(store.selectedProfile?.name, "Renamed Layout")
        XCTAssertFalse(store.selectedProfileIsEdited)
    }

    @MainActor
    func testLoadsLegacyKeysAndNormalizesBothCalibrationDimensions() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set([
            "500": 0.4,
            "122": 0.1,
            "125": -0.8,
            "9999": 0.2
        ], forKey: "KeyPositionOffsets")
        defaults.set([
            "500": 2.5,
            "122": 0.2,
            "126": 9.0,
            "9999": 1.5
        ], forKey: "KeyWidthOverrides")

        let store = KeyLayoutStore(defaults: defaults)
        defer { store.cancelPendingWork() }

        XCTAssertEqual(KeyLayoutStore.offsetsKey, "KeyPositionOffsets")
        XCTAssertEqual(KeyLayoutStore.widthMultipliersKey, "KeyWidthOverrides")
        XCTAssertEqual(store.layout.offsets[122], 0.1)
        XCTAssertEqual(store.layout.offsets[125], -0.5)
        XCTAssertNil(store.layout.offsets[500])
        XCTAssertNil(store.layout.offsets[9999])
        XCTAssertEqual(store.layout.widthMultipliers[122], 0.2)
        XCTAssertEqual(store.layout.widthMultipliers[126], 5.0)
        XCTAssertNil(store.layout.widthMultipliers[500])
        XCTAssertNil(store.layout.widthMultipliers[9999])
        XCTAssertEqual(store.layout, store.baseline)
        XCTAssertFalse(store.isEdited)
    }

    @MainActor
    func testNormalizationRejectsInvalidValuesAndPrefersCanonicalKeys() {
        let normalized = KeyLayoutStore.normalized(KeyLayout(
            offsets: [500: 0.3, 122: 0.2, 125: -.infinity, 9_999: 0.1],
            widthMultipliers: [500: 2.4, 122: 1.4, 126: .nan, 9_999: 2]
        ))

        XCTAssertEqual(normalized.offsets, [122: 0.2])
        XCTAssertEqual(normalized.widthMultipliers, [122: 1.4])
        XCTAssertLessThanOrEqual(normalized.offsets.count, KeyLayoutStore.maximumEntryCount)
        XCTAssertLessThanOrEqual(normalized.widthMultipliers.count, KeyLayoutStore.maximumEntryCount)
    }

    @MainActor
    func testMixedGestureIsOneUndoAndRedoTransaction() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        let store = KeyLayoutStore(defaults: defaults, debounceInterval: 60)
        defer {
            store.cancelPendingWork()
            defaults.removePersistentDomain(forName: suiteName)
        }

        store.beginGestureTransaction()
        store.setOffset(0.1, for: 500)
        store.setOffset(0.25, for: 500)
        store.setWidthMultiplier(1.8, for: 500)
        store.endGestureTransaction()

        XCTAssertEqual(store.layout.offsets[122], 0.25)
        XCTAssertEqual(store.layout.widthMultipliers[122], 1.8)
        XCTAssertTrue(store.canUndo)
        XCTAssertFalse(store.canRedo)

        store.undo()
        XCTAssertEqual(store.layout, .empty)
        XCTAssertFalse(store.canUndo)
        XCTAssertTrue(store.canRedo)

        store.redo()
        XCTAssertEqual(store.layout.offsets[122], 0.25)
        XCTAssertEqual(store.layout.widthMultipliers[122], 1.8)
        XCTAssertTrue(store.canUndo)
        XCTAssertFalse(store.canRedo)
    }

    @MainActor
    func testEmptyGestureDoesNotCreateHistory() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        let store = KeyLayoutStore(defaults: defaults)
        defer {
            store.cancelPendingWork()
            defaults.removePersistentDomain(forName: suiteName)
        }

        store.beginGestureTransaction()
        store.endGestureTransaction()

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.canRedo)
    }

    @MainActor
    func testApplyResetKeyResetAllAndRevertAreAtomic() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defaults.set(["10": 0.05], forKey: "KeyPositionOffsets")
        defaults.set(["10": 1.2], forKey: "KeyWidthOverrides")

        let store = KeyLayoutStore(defaults: defaults, debounceInterval: 60)
        defer {
            store.cancelPendingWork()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let replacement = KeyLayout(
            offsets: [10: 0.2, 49: -0.1],
            widthMultipliers: [10: 1.5, 49: 1.1]
        )
        store.apply(replacement)
        XCTAssertEqual(store.layout, replacement)
        XCTAssertTrue(store.isEdited)

        store.resetKey(10)
        XCTAssertNil(store.layout.offsets[10])
        XCTAssertNil(store.layout.widthMultipliers[10])
        store.undo()
        XCTAssertEqual(store.layout, replacement)

        store.resetAll()
        XCTAssertEqual(store.layout, .empty)
        store.undo()
        XCTAssertEqual(store.layout, replacement)

        store.revert()
        XCTAssertEqual(store.layout.offsets, [10: 0.05])
        XCTAssertEqual(store.layout.widthMultipliers, [10: 1.2])
        XCTAssertFalse(store.isEdited)
    }

    @MainActor
    func testApplyAsBaselineAndMarkCurrentAsBaselineTrackEditedState() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        let store = KeyLayoutStore(defaults: defaults, debounceInterval: 60)
        defer {
            store.cancelPendingWork()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let profile = KeyLayout(offsets: [49: 0.1], widthMultipliers: [49: 1.3])
        store.apply(profile, asBaseline: true)
        XCTAssertEqual(store.layout, profile)
        XCTAssertEqual(store.baseline, profile)
        XCTAssertFalse(store.isEdited)

        store.setOffset(0.2, for: 49)
        XCTAssertTrue(store.isEdited)
        store.markCurrentAsBaseline()
        XCTAssertFalse(store.isEdited)
    }

    @MainActor
    func testDimensionSpecificCompatibilityOperationsPreserveOtherCalibration() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        let initial = KeyLayout(
            offsets: [49: 0.1],
            widthMultipliers: [49: 1.4]
        )
        let store = KeyLayoutStore(defaults: defaults, debounceInterval: 60)
        defer {
            store.cancelPendingWork()
            defaults.removePersistentDomain(forName: suiteName)
        }

        store.apply(initial, asBaseline: true)
        store.resetAllOffsets()
        XCTAssertTrue(store.layout.offsets.isEmpty)
        XCTAssertEqual(store.layout.widthMultipliers, initial.widthMultipliers)

        store.replaceAllOffsets([49: -0.2])
        store.resetWidthMultiplier(for: 49)
        XCTAssertEqual(store.layout.offsets, [49: -0.2])
        XCTAssertTrue(store.layout.widthMultipliers.isEmpty)

        store.replaceAllWidthMultipliers([49: 2.2])
        store.resetOffset(for: 49)
        XCTAssertTrue(store.layout.offsets.isEmpty)
        XCTAssertEqual(store.layout.widthMultipliers, [49: 2.2])
    }

    @MainActor
    func testReloadingOwnPersistedSnapshotDoesNotDestroyUndoHistory() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        let store = KeyLayoutStore(defaults: defaults, debounceInterval: 60)
        defer {
            store.cancelPendingWork()
            defaults.removePersistentDomain(forName: suiteName)
        }

        store.setOffset(0.2, for: 49)
        store.flush()
        XCTAssertTrue(store.canUndo)

        // An identical persisted snapshot must be a no-op so a lifecycle
        // reconciliation cannot destroy editor history.
        store.reloadFromPersistence()
        XCTAssertTrue(store.canUndo)
        store.undo()
        XCTAssertEqual(store.layout, .empty)
    }

    @MainActor
    func testFlushWritesLegacyDictionariesWithoutAnInternalEventBus() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        let store = KeyLayoutStore(
            defaults: defaults,
            debounceInterval: 60
        )
        defer {
            store.cancelPendingWork()
            defaults.removePersistentDomain(forName: suiteName)
        }

        store.beginGestureTransaction()
        store.setOffset(0.2, for: 500)
        store.setWidthMultiplier(1.75, for: 500)
        store.endGestureTransaction()

        XCTAssertNil(defaults.object(forKey: "KeyPositionOffsets"))
        XCTAssertNil(defaults.object(forKey: "KeyWidthOverrides"))

        store.flush()

        XCTAssertEqual(persistedNumber(defaults, key: "KeyPositionOffsets", entry: "122"), 0.2)
        XCTAssertEqual(persistedNumber(defaults, key: "KeyWidthOverrides", entry: "122"), 1.75)
    }

    @MainActor
    func testTrailingPersistenceUsesLatestSnapshot() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        let store = KeyLayoutStore(defaults: defaults, debounceInterval: 0.02)
        defer {
            store.cancelPendingWork()
            defaults.removePersistentDomain(forName: suiteName)
        }

        store.setOffset(0.1, for: 49)
        try await Task.sleep(nanoseconds: 5_000_000)
        store.setOffset(0.3, for: 49)
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(persistedNumber(defaults, key: "KeyPositionOffsets", entry: "49"), 0.3)
    }

    @MainActor
    func testCancelPendingWorkPreventsDeferredPersistence() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        let store = KeyLayoutStore(defaults: defaults, debounceInterval: 0.01)
        defer {
            store.cancelPendingWork()
            defaults.removePersistentDomain(forName: suiteName)
        }

        store.setOffset(0.2, for: 49)
        store.cancelPendingWork()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertNil(defaults.object(forKey: "KeyPositionOffsets"))
        XCTAssertNil(defaults.object(forKey: "KeyWidthOverrides"))
    }

    @MainActor
    func testRuntimeEditsCanonicalizeClampAndFilter() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        let store = KeyLayoutStore(defaults: defaults, debounceInterval: 60)
        defer {
            store.cancelPendingWork()
            defaults.removePersistentDomain(forName: suiteName)
        }

        store.beginGestureTransaction()
        store.setOffset(9, for: 500)
        store.setWidthMultiplier(-2, for: 500)
        store.setOffset(.nan, for: 49)
        store.setWidthMultiplier(.infinity, for: 49)
        store.setOffset(0.2, for: 9_999)
        store.setWidthMultiplier(2, for: 9_999)
        store.endGestureTransaction()

        XCTAssertEqual(store.layout.offsets[122], 0.5)
        XCTAssertEqual(store.layout.widthMultipliers[122], 0.1)
        XCTAssertEqual(store.layout.offsets[49], 0)
        XCTAssertEqual(store.layout.widthMultipliers[49], 1)
        XCTAssertNil(store.layout.offsets[9_999])
        XCTAssertNil(store.layout.widthMultipliers[9_999])
        XCTAssertEqual(store.adjustedPosition(for: 500, originalPosition: 0.8), 1)
        XCTAssertEqual(store.effectiveWidth(for: 500, defaultWidth: 0.8), 0.08, accuracy: 0.0001)
    }

    private func makeIsolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "KeyLayoutStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func persistedNumber(
        _ defaults: UserDefaults,
        key: String,
        entry: String
    ) -> CGFloat? {
        guard let number = defaults.dictionary(forKey: key)?[entry] as? NSNumber else { return nil }
        return CGFloat(truncating: number)
    }
}
