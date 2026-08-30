import XCTest
import Carbon.HIToolbox
@testable import KeyLight

private final class IsolatedDefaults {
    let name = "KeyLightTests.PreferencesCompatibility.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }

    func bypassUnrelatedStartupMigrations(includeStableSelection: Bool = true) {
        defaults.set(true, forKey: "fadeDurationDefaultMigratedV2")
        defaults.set(1, forKey: "defaultExperienceSeedVersion")
        defaults.set(1, forKey: "defaultLayoutMigrationVersion")
        defaults.set(1, forKey: "bundledLayoutProfilesSeedVersion")
        if includeStableSelection {
            defaults.set(1, forKey: "stableSelectionMigrationVersion")
        }
    }
}

final class ConfigurationValueTests: XCTestCase {
    func testDefaultConfigurationPreservesEstablishedDefaults() {
        XCTAssertEqual(AppPreferences.default.isEnabled, true)
        XCTAssertEqual(AppPreferences.default.launchAtLogin, false)
        XCTAssertEqual(AppPreferences.default.effect.style, .classicGlow)
        XCTAssertEqual(AppPreferences.default.effect.color.mode, .positionGradient)
        XCTAssertEqual(AppPreferences.default.effect.color.solidHex, "68B8FF")
        XCTAssertEqual(AppPreferences.default.effect.color.gradientStartHex, "68B8FF")
        XCTAssertEqual(AppPreferences.default.effect.color.gradientEndHex, "00E69A")
        XCTAssertEqual(AppPreferences.default.effect.opacity, 0.8013)
        XCTAssertEqual(AppPreferences.default.effect.refractionStrength, 1.0)
        XCTAssertEqual(AppPreferences.default.effect.height, 80.5536)
        XCTAssertEqual(AppPreferences.default.effect.width, 1.0)
        XCTAssertEqual(AppPreferences.default.effect.roundness, 0.7069)
        XCTAssertEqual(AppPreferences.default.effect.hardness, 0.6046)
        XCTAssertEqual(AppPreferences.default.effect.fadeDuration, 1.0004)
    }

    func testFeedbackIsTypedAndEquatable() {
        let id = UUID()
        let first = UserFeedback(
            id: id,
            severity: .warning,
            title: "Input Monitoring unavailable",
            detail: "KeyLight cannot observe keys.",
            recoveryAction: .openInputMonitoringSettings
        )
        let second = UserFeedback(
            id: id,
            severity: .warning,
            title: "Input Monitoring unavailable",
            detail: "KeyLight cannot observe keys.",
            recoveryAction: .openInputMonitoringSettings
        )

        XCTAssertEqual(first, second)
    }
}

final class SavedDomainValueCompatibilityTests: XCTestCase {
    func testStandaloneThemeKeepsPersistedJSONShape() throws {
        let theme = Theme(
            id: try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")),
            name: "Fixture",
            colorHex: "112233",
            opacity: 0.5,
            size: 80,
            width: 1.2,
            glowRoundness: 0.7,
            glowFullness: 0.6,
            fadeDuration: 1,
            colorMode: .positionGradient,
            effectStyle: .liquidGlass,
            gradientStartHex: "445566",
            gradientEndHex: "778899"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(theme)) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), [
            "id", "name", "colorHex", "opacity", "size", "width",
            "glowRoundness", "glowFullness", "fadeDuration", "colorMode",
            "effectStyle", "shapeProfile", "refractionStrength",
            "gradientStartHex", "gradientEndHex"
        ])
        XCTAssertEqual(object["colorMode"] as? String, "positionGradient")
        XCTAssertEqual(object["effectStyle"] as? String, "liquidGlass")
        XCTAssertEqual(object["shapeProfile"] as? String, "currentWave")
    }

    func testStandaloneLayoutAndGradientKeepPersistedJSONShapes() throws {
        var layout = KeyMappingProfile(
            name: "Fixture Layout",
            keyOffsets: [122: 0.1],
            keyWidthOverrides: [122: 1.25]
        )
        layout.id = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF"))
        let layoutObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as? [String: Any]
        )

        XCTAssertEqual(Set(layoutObject.keys), ["id", "name", "keyOffsets", "keyWidthOverrides"])
        let offsets = try XCTUnwrap(layoutObject["keyOffsets"] as? [String: Any])
        let widths = try XCTUnwrap(layoutObject["keyWidthOverrides"] as? [String: Any])
        XCTAssertEqual((offsets["122"] as? NSNumber)?.doubleValue, 0.1)
        XCTAssertEqual((widths["122"] as? NSNumber)?.doubleValue, 1.25)

        let gradient = GradientPreset(
            id: try XCTUnwrap(UUID(uuidString: "CCCCCCCC-DDDD-4EEE-8FFF-AAAAAAAAAAAA")),
            startHex: "112233",
            endHex: "445566",
            name: "Fixture Gradient"
        )
        let gradientObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(gradient)) as? [String: Any]
        )
        XCTAssertEqual(Set(gradientObject.keys), ["id", "startHex", "endHex", "name"])
    }
}

final class PreferencesStoreAdapterTests: XCTestCase {
    func testAdapterUsesOnlyItsInjectedSuite() {
        let isolated = IsolatedDefaults()
        let store = PreferencesStore(userDefaults: isolated.defaults)

        let sentinelKey = "KeyLightTests.injected-store-sentinel"
        store.set(true, forKey: sentinelKey)
        store.set("value", forKey: "string")
        store.set(Data([1, 2, 3]), forKey: "data")
        store.set(["one": 1], forKey: "dictionary")

        XCTAssertTrue(store.bool(forKey: sentinelKey))
        XCTAssertEqual(store.string(forKey: "string"), "value")
        XCTAssertEqual(store.data(forKey: "data"), Data([1, 2, 3]))
        XCTAssertEqual(store.dictionary(forKey: "dictionary")?["one"] as? Int, 1)
        XCTAssertNil(UserDefaults.standard.object(forKey: "KeyLightTests.injected-store-sentinel"))

        store.removeObject(forKey: sentinelKey)
        XCTAssertNil(store.object(forKey: sentinelKey))
    }
}

final class StableSelectionPersistenceTests: XCTestCase {
    @MainActor
    func testLegacyRecordsAreRepairedAfterMigrationAndKeepDeterministicIDs() throws {
        let isolated = IsolatedDefaults()
        isolated.bypassUnrelatedStartupMigrations(includeStableSelection: true)
        let store = PreferencesStore(userDefaults: isolated.defaults)

        let legacyThemes = Data("""
        [
          {
            "name": "First",
            "colorHex": "112233",
            "opacity": 0.4,
            "size": 70,
            "width": 1,
            "fadeDuration": 0.8,
            "colorMode": "solid"
          },
          {
            "name": "Selected",
            "colorHex": "68B8FF",
            "opacity": 0.75,
            "size": 90,
            "width": 1.2,
            "fadeDuration": 1,
            "colorMode": "positionGradient"
          }
        ]
        """.utf8)
        let legacyLayouts = Data("""
        [
          {
            "name": "First Layout",
            "keyOffsets": { "122": 0.1 }
          },
          {
            "name": "Selected Layout",
            "keyOffsets": { "120": -0.2 },
            "keyWidthOverrides": { "120": 1.25 }
          }
        ]
        """.utf8)

        let previouslySelectedThemeID = UUID()
        let previouslySelectedLayoutID = UUID()
        store.set(legacyThemes, forKey: "savedThemes")
        store.set("Selected", forKey: "currentThemeName")
        store.set(previouslySelectedThemeID.uuidString, forKey: "activeThemeID")
        store.set(legacyLayouts, forKey: "keyMappingProfiles")
        store.set("Selected Layout", forKey: "currentKeyMappingProfileName")
        store.set(previouslySelectedLayoutID.uuidString, forKey: "activeLayoutID")

        let firstLoad = SettingsManager(preferencesStore: store)
        let firstThemeIDs = firstLoad.savedThemes.map(\.id)
        let firstLayoutIDs = firstLoad.savedKeyMappingProfiles.map(\.id)

        XCTAssertEqual(firstThemeIDs.count, 2)
        XCTAssertEqual(firstLayoutIDs.count, 2)
        XCTAssertEqual(firstThemeIDs[1], previouslySelectedThemeID)
        XCTAssertEqual(firstLayoutIDs[1], previouslySelectedLayoutID)
        XCTAssertEqual(firstLoad.activeThemeID, firstThemeIDs[1])
        XCTAssertEqual(firstLoad.activeLayoutID, firstLayoutIDs[1])
        XCTAssertEqual(firstLoad.savedThemes[1].effectStyle, .classicGlow)
        XCTAssertEqual(firstLoad.savedKeyMappingProfiles[1].keyWidthOverrides[120], 1.25)
        try assertEveryRecordHasUUID(in: XCTUnwrap(store.data(forKey: "savedThemes")))
        try assertEveryRecordHasUUID(in: XCTUnwrap(store.data(forKey: "keyMappingProfiles")))

        // Simulate an older KeyLight build rewriting the arrays without the
        // fields it does not know, after migration version 1 is already set.
        store.set(legacyThemes, forKey: "savedThemes")
        store.set(legacyLayouts, forKey: "keyMappingProfiles")

        let secondLoad = SettingsManager(preferencesStore: store)

        XCTAssertEqual(secondLoad.savedThemes.map(\.id), firstThemeIDs)
        XCTAssertEqual(secondLoad.savedKeyMappingProfiles.map(\.id), firstLayoutIDs)
        XCTAssertEqual(secondLoad.activeThemeID, firstThemeIDs[1])
        XCTAssertEqual(secondLoad.activeLayoutID, firstLayoutIDs[1])
        XCTAssertEqual(store.integer(forKey: "stableSelectionMigrationVersion"), 1)
        try assertEveryRecordHasUUID(in: XCTUnwrap(store.data(forKey: "savedThemes")))
        try assertEveryRecordHasUUID(in: XCTUnwrap(store.data(forKey: "keyMappingProfiles")))
    }

    @MainActor
    func testPartialLegacyRepairDoesNotReplaceExistingRecordIDs() throws {
        let isolated = IsolatedDefaults()
        isolated.bypassUnrelatedStartupMigrations(includeStableSelection: true)
        let store = PreferencesStore(userDefaults: isolated.defaults)
        let existingThemeID = UUID()
        let existingLayoutID = UUID()
        let themes = Data("""
        [
          { "id": "\(existingThemeID.uuidString)", "name": "Selected" },
          { "name": "Legacy" }
        ]
        """.utf8)
        let layouts = Data("""
        [
          {
            "id": "\(existingLayoutID.uuidString)",
            "name": "Selected Layout",
            "keyOffsets": {}
          },
          { "name": "Legacy Layout", "keyOffsets": {} }
        ]
        """.utf8)

        store.set(themes, forKey: "savedThemes")
        store.set("Selected", forKey: "currentThemeName")
        store.set(existingThemeID.uuidString, forKey: "activeThemeID")
        store.set(layouts, forKey: "keyMappingProfiles")
        store.set("Selected Layout", forKey: "currentKeyMappingProfileName")
        store.set(existingLayoutID.uuidString, forKey: "activeLayoutID")

        let settings = SettingsManager(preferencesStore: store)

        XCTAssertEqual(settings.savedThemes.first?.id, existingThemeID)
        XCTAssertEqual(settings.savedKeyMappingProfiles.first?.id, existingLayoutID)
        XCTAssertEqual(settings.activeThemeID, existingThemeID)
        XCTAssertEqual(settings.activeLayoutID, existingLayoutID)
        try assertEveryRecordHasUUID(in: XCTUnwrap(store.data(forKey: "savedThemes")))
        try assertEveryRecordHasUUID(in: XCTUnwrap(store.data(forKey: "keyMappingProfiles")))
    }

    @MainActor
    func testLegacyNamesMigrateOnceToStableIDsAndRemainDualWritten() throws {
        let isolated = IsolatedDefaults()
        isolated.bypassUnrelatedStartupMigrations(includeStableSelection: false)
        let store = PreferencesStore(userDefaults: isolated.defaults)

        let firstTheme = makeTheme(id: UUID(), name: "First")
        let selectedTheme = makeTheme(id: UUID(), name: "Selected")
        var firstLayout = KeyMappingProfile(name: "First Layout", keyOffsets: [122: 0.1])
        firstLayout.id = UUID()
        var selectedLayout = KeyMappingProfile(name: "Selected Layout", keyOffsets: [120: -0.1])
        selectedLayout.id = UUID()

        store.set(try JSONEncoder().encode([firstTheme, selectedTheme]), forKey: "savedThemes")
        store.set("Selected", forKey: "currentThemeName")
        store.set(try JSONEncoder().encode([firstLayout, selectedLayout]), forKey: "keyMappingProfiles")
        store.set("Selected Layout", forKey: "currentKeyMappingProfileName")

        let settings = SettingsManager(preferencesStore: store)

        XCTAssertEqual(settings.activeThemeID, selectedTheme.id)
        XCTAssertEqual(settings.activeLayoutID, selectedLayout.id)
        XCTAssertEqual(store.string(forKey: "activeThemeID"), selectedTheme.id.uuidString)
        XCTAssertEqual(store.string(forKey: "activeLayoutID"), selectedLayout.id.uuidString)
        XCTAssertEqual(store.string(forKey: "currentThemeName"), "Selected")
        XCTAssertEqual(store.string(forKey: "currentKeyMappingProfileName"), "Selected Layout")
        XCTAssertEqual(store.integer(forKey: "stableSelectionMigrationVersion"), 1)
    }

    @MainActor
    func testRenameKeepsIdentityAndActiveDeletionUsesStableFirstFallback() {
        let isolated = IsolatedDefaults()
        isolated.bypassUnrelatedStartupMigrations()
        let store = PreferencesStore(userDefaults: isolated.defaults)
        let settings = SettingsManager(preferencesStore: store)

        let fallbackTheme = makeTheme(id: UUID(), name: "Fallback")
        let activeTheme = makeTheme(id: UUID(), name: "Active")
        settings.savedThemes = [fallbackTheme, activeTheme]
        settings.activeThemeID = activeTheme.id
        settings.renameTheme(from: "Active", to: "Renamed")

        XCTAssertEqual(settings.activeThemeID, activeTheme.id)
        XCTAssertEqual(settings.currentThemeName, "Renamed")

        settings.deleteTheme(named: "Renamed")
        XCTAssertEqual(settings.activeThemeID, fallbackTheme.id)
        XCTAssertEqual(settings.currentThemeName, "Fallback")

        var fallbackLayout = KeyMappingProfile(name: "Fallback Layout", keyOffsets: [:])
        fallbackLayout.id = UUID()
        var activeLayout = KeyMappingProfile(name: "Active Layout", keyOffsets: [:])
        activeLayout.id = UUID()
        settings.savedKeyMappingProfiles = [fallbackLayout, activeLayout]
        settings.activeLayoutID = activeLayout.id
        settings.renameKeyMappingProfile(from: "Active Layout", to: "Renamed Layout")

        XCTAssertEqual(settings.activeLayoutID, activeLayout.id)
        XCTAssertEqual(settings.currentKeyMappingProfileName, "Renamed Layout")

        settings.deleteKeyMappingProfile(named: "Renamed Layout")
        XCTAssertEqual(settings.activeLayoutID, fallbackLayout.id)
        XCTAssertEqual(settings.currentKeyMappingProfileName, "Fallback Layout")
    }

    @MainActor
    func testDisplayRoutingPersistsStableSelectionAndValidatedLayoutBindings() {
        let isolated = IsolatedDefaults()
        isolated.bypassUnrelatedStartupMigrations()
        let store = PreferencesStore(userDefaults: isolated.defaults)
        let settings = SettingsManager(preferencesStore: store)
        var profile = KeyMappingProfile(name: "Studio Layout", keyOffsets: [:])
        profile.id = UUID()
        settings.savedKeyMappingProfiles = [profile]

        settings.overlayDisplaySelection = .specific("stable-display-uuid")
        settings.setLayoutProfileBinding(profile.id, forDisplay: "stable-display-uuid")

        XCTAssertEqual(settings.overlayDisplaySelection, .specific("stable-display-uuid"))
        XCTAssertEqual(
            settings.displayLayoutProfileBindings["stable-display-uuid"],
            profile.id
        )
        XCTAssertEqual(
            store.string(forKey: "overlayDisplaySelection"),
            "display:stable-display-uuid"
        )

        store.set(
            [
                "stable-display-uuid": profile.id.uuidString,
                "invalid-profile": UUID().uuidString,
                "malformed": "not-a-uuid"
            ],
            forKey: "displayLayoutProfileBindings"
        )
        XCTAssertEqual(settings.displayLayoutProfileBindings, ["stable-display-uuid": profile.id])

        settings.setLayoutProfileBinding(nil, forDisplay: "stable-display-uuid")
        XCTAssertTrue(settings.displayLayoutProfileBindings.isEmpty)
        XCTAssertNil(store.object(forKey: "displayLayoutProfileBindings"))
    }

    @MainActor
    func testCustomGlobalShortcutPersistsAndMalformedStorageFallsBackToDefault() throws {
        let isolated = IsolatedDefaults()
        isolated.bypassUnrelatedStartupMigrations()
        let store = PreferencesStore(userDefaults: isolated.defaults)
        let settings = SettingsManager(preferencesStore: store)
        let shortcut = try XCTUnwrap(GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(controlKey | optionKey)
        ))

        settings.globalShortcut = shortcut
        XCTAssertEqual(settings.globalShortcut, shortcut)

        store.set(Data("not-json".utf8), forKey: "globalShortcut")
        XCTAssertEqual(settings.globalShortcut, .default)
    }

    @MainActor
    func testSameNameUpdatesPreserveExistingUUIDs() throws {
        let isolated = IsolatedDefaults()
        isolated.bypassUnrelatedStartupMigrations()
        let settings = SettingsManager(preferencesStore: PreferencesStore(userDefaults: isolated.defaults))

        let originalTheme = makeTheme(id: UUID(), name: "Stable")
        settings.savedThemes = [originalTheme]
        settings.activeThemeID = originalTheme.id
        var replacementTheme = makeTheme(id: UUID(), name: "Stable")
        replacementTheme.opacity = 0.25
        settings.saveTheme(replacementTheme)

        XCTAssertEqual(try XCTUnwrap(settings.savedThemes.first).id, originalTheme.id)
        XCTAssertEqual(settings.activeThemeID, originalTheme.id)

        var originalLayout = KeyMappingProfile(name: "Stable Layout", keyOffsets: [122: 0.1])
        originalLayout.id = UUID()
        var replacementLayout = KeyMappingProfile(name: "Stable Layout", keyOffsets: [122: 0.2])
        replacementLayout.id = UUID()
        settings.savedKeyMappingProfiles = [originalLayout]
        let persistedLayout = try XCTUnwrap(settings.saveKeyMappingProfile(replacementLayout))

        XCTAssertEqual(try XCTUnwrap(settings.savedKeyMappingProfiles.first).id, originalLayout.id)
        XCTAssertEqual(persistedLayout.id, originalLayout.id)
        XCTAssertEqual(settings.activeLayoutID, originalLayout.id)
    }

    @MainActor
    func testEffectSnapshotUsesExistingKeysAndPermissionExplanationDefaultsFalse() {
        let isolated = IsolatedDefaults()
        isolated.bypassUnrelatedStartupMigrations()
        let store = PreferencesStore(userDefaults: isolated.defaults)
        let settings = SettingsManager(preferencesStore: store)
        let effect = EffectConfiguration(
            style: .physicalRefraction,
            shapeProfile: .currentWave,
            color: ColorConfiguration(
                mode: .rainbow,
                solidHex: "112233",
                gradientStartHex: "445566",
                gradientEndHex: "778899"
            ),
            opacity: 0.5,
            refractionStrength: 2.2,
            height: 90,
            width: 1.5,
            roundness: 0.4,
            hardness: 0.3,
            fadeDuration: 0.8
        )

        settings.effectConfiguration = effect

        XCTAssertEqual(settings.effectConfiguration, effect)
        XCTAssertEqual(
            store.string(forKey: "effectStyle"),
            "physicalRefraction"
        )
        XCTAssertEqual(
            store.string(forKey: "surfaceShapeProfile"),
            "currentWave"
        )
        XCTAssertEqual(store.string(forKey: "colorMode"), "rainbow")
        XCTAssertEqual(store.object(forKey: "glowSize") as? Double, 90)
        XCTAssertEqual(
            store.object(
                forKey: "physicalRefractionStrength"
            ) as? Double,
            2.2
        )
        XCTAssertFalse(settings.hasSeenPermissionExplanation)
        settings.hasSeenPermissionExplanation = true
        XCTAssertEqual(store.object(forKey: "hasSeenPermissionExplanation") as? Bool, true)
    }

    @MainActor
    private func makeTheme(id: UUID, name: String) -> Theme {
        Theme(
            id: id,
            name: name,
            colorHex: "68B8FF",
            opacity: 0.8,
            size: 80,
            width: 1,
            glowRoundness: 0.7,
            glowFullness: 0.6,
            fadeDuration: 1,
            colorMode: .positionGradient,
            effectStyle: .classicGlow,
            gradientStartHex: "68B8FF",
            gradientEndHex: "00E69A"
        )
    }

    private func assertEveryRecordHasUUID(in data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let records = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            file: file,
            line: line
        )
        XCTAssertFalse(records.isEmpty, file: file, line: line)
        for record in records {
            let rawID = try XCTUnwrap(record["id"] as? String, file: file, line: line)
            XCTAssertNotNil(UUID(uuidString: rawID), file: file, line: line)
        }
    }
}

final class LayoutImportPolicyTests: XCTestCase {
    func testPolicyCountsUniqueKeysAcrossBothGeometryMaps() {
        let keys = (0..<PersistenceValidation.maximumLayoutEntryCount).map(String.init)
        XCTAssertTrue(PersistenceValidation.layoutEntryCountIsValid(offsetKeys: keys, widthKeys: keys))
        XCTAssertFalse(PersistenceValidation.layoutEntryCountIsValid(
            offsetKeys: keys,
            widthKeys: ["one-too-many"]
        ))
    }

    @MainActor
    func testImportRejectsOversizedDataAndMoreThan512EntriesWithoutPersisting() throws {
        let isolated = IsolatedDefaults()
        isolated.bypassUnrelatedStartupMigrations()
        let store = PreferencesStore(userDefaults: isolated.defaults)
        store.set("Unchanged", forKey: "currentKeyMappingProfileName")
        let settings = SettingsManager(preferencesStore: store)

        XCTAssertThrowsError(
            try settings.importLayoutProfileData(Data(repeating: 0, count: PersistenceValidation.maximumLayoutImportSize + 1))
        ) { error in
            XCTAssertEqual((error as NSError).code, 20)
        }

        let entries = Dictionary(uniqueKeysWithValues: (0...PersistenceValidation.maximumLayoutEntryCount).map {
            ("invalid-\($0)", 0.1)
        })
        let payload: [String: Any] = [
            "version": 1,
            "kind": "layoutProfile",
            "name": "Too Many",
            "keyOffsets": entries,
            "keyWidthOverrides": [:]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertThrowsError(try settings.importLayoutProfileData(data)) { error in
            XCTAssertEqual((error as NSError).code, 25)
        }
        XCTAssertEqual(store.string(forKey: "currentKeyMappingProfileName"), "Unchanged")
        XCTAssertNil(store.data(forKey: "keyMappingProfiles"))
    }

    @MainActor
    func testImportTrimsAndLimitsNamesWithoutChangingJSONShape() throws {
        let isolated = IsolatedDefaults()
        isolated.bypassUnrelatedStartupMigrations()
        let settings = SettingsManager(preferencesStore: PreferencesStore(userDefaults: isolated.defaults))
        let longName = "  " + String(repeating: "N", count: 150) + "  "
        let payload: [String: Any] = [
            "version": 1,
            "kind": "layoutProfile",
            "name": longName,
            "keyOffsets": ["122": 0.1],
            "keyWidthOverrides": ["122": 1.2]
        ]

        let imported = try settings.importLayoutProfileData(
            JSONSerialization.data(withJSONObject: payload)
        )
        XCTAssertEqual(imported.name.count, PersistenceValidation.maximumNameLength)

        let exported = try XCTUnwrap(settings.exportLayoutProfileData(imported))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "kind", "name", "keyOffsets", "keyWidthOverrides"])
        XCTAssertEqual(object["name"] as? String, imported.name)
    }

    @MainActor
    func testSavingLayoutUsesTheSameAllowListAndNumericClamps() throws {
        let isolated = IsolatedDefaults()
        isolated.bypassUnrelatedStartupMigrations()
        let settings = SettingsManager(
            preferencesStore: PreferencesStore(userDefaults: isolated.defaults)
        )
        let profile = KeyMappingProfile(
            name: "  " + String(repeating: "L", count: 140) + "  ",
            keyOffsets: [122: 9, 65_000: 0.1],
            keyWidthOverrides: [122: 9, 65_000: 2]
        )

        let saved = try XCTUnwrap(settings.saveKeyMappingProfile(profile))

        XCTAssertEqual(saved.name.count, PersistenceValidation.maximumNameLength)
        XCTAssertEqual(saved.keyOffsets, [122: KeyLayoutStore.maximumOffset])
        XCTAssertEqual(
            saved.keyWidthOverrides,
            [122: KeyLayoutStore.maximumWidthMultiplier]
        )
        XCTAssertEqual(settings.savedKeyMappingProfiles, [saved])
    }
}
