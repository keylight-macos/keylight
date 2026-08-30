import XCTest
import CoreGraphics
import AppKit
@testable import KeyLight

private enum TestDefaultsKeys {
    static let all: [String] = [
        "isEnabled",
        "glowColorHex",
        "glowOpacity",
        "physicalRefractionStrength",
        "glowSize",
        "glowWidth",
        "glowRoundness",
        "glowFullness",
        "fadeDuration",
        "fadeDurationDefaultMigratedV2",
        "launchAtLogin",
        "colorMode",
        "effectStyle",
        "chordSurfaceStyle",
        "chordIntensityMultiplier",
        "powerSavingMode",
        "effectConfigurationsByStyleV1",
        "surfaceShapeProfile",
        "savedThemes",
        "currentThemeName",
        "keyMappingProfiles",
        "currentKeyMappingProfileName",
        "gradientStartHex",
        "gradientEndHex",
        "gradientPresets",
        "defaultExperienceSeedVersion",
        "defaultLayoutMigrationVersion",
        "bundledLayoutProfilesSeedVersion",
        "hasSeenPermissionExplanation",
        "activeThemeID",
        "activeLayoutID",
        "overlayDisplaySelection",
        "mirroredDisplayIDs",
        "displayLayoutProfileBindings",
        "globalShortcut",
        "stableSelectionMigrationVersion",
        "onboardingCompletedVersion",
        "onboardingDeferredVersion",
        "configurationSnapshotsV1",
        "configurationSnapshotRecoveryV1",
        "KeyPositionOffsets",
        "KeyWidthOverrides"
    ]
}

private final class DefaultsSnapshot {
    private let defaults = UserDefaults.standard
    private let keys: [String]
    private var values: [String: Any] = [:]
    private var missing: Set<String> = []

    init(keys: [String]) {
        self.keys = keys
        for key in keys {
            if let value = defaults.object(forKey: key) {
                values[key] = value
            } else {
                missing.insert(key)
            }
        }
    }

    func clear() {
        for key in keys {
            defaults.removeObject(forKey: key)
        }
    }

    func restore() {
        for key in keys {
            if missing.contains(key) {
                defaults.removeObject(forKey: key)
            } else if let value = values[key] {
                defaults.set(value, forKey: key)
            }
        }
    }
}

final class SettingsManagerContractTests: XCTestCase {
    private var snapshot: DefaultsSnapshot!

    override func setUp() {
        super.setUp()
        snapshot = DefaultsSnapshot(keys: TestDefaultsKeys.all)
        snapshot.clear()
    }

    override func tearDown() {
        snapshot.restore()
        snapshot = nil
        super.tearDown()
    }

    @MainActor
    func testUserDefaultsKeyContractForCoreSettings() {
        let expected: Set<String> = [
            "isEnabled",
            "glowColorHex",
            "glowOpacity",
            "physicalRefractionStrength",
            "glowSize",
            "glowWidth",
            "glowRoundness",
            "glowFullness",
            "fadeDuration",
            "fadeDurationDefaultMigratedV2",
            "launchAtLogin",
            "colorMode",
            "effectStyle",
            "chordSurfaceStyle",
            "chordIntensityMultiplier",
            "powerSavingMode",
            "effectConfigurationsByStyleV1",
            "surfaceShapeProfile",
            "savedThemes",
            "currentThemeName",
            "keyMappingProfiles",
            "currentKeyMappingProfileName",
            "gradientStartHex",
            "gradientEndHex",
            "gradientPresets",
            "defaultExperienceSeedVersion",
            "defaultLayoutMigrationVersion",
            "bundledLayoutProfilesSeedVersion",
            "hasSeenPermissionExplanation",
            "activeThemeID",
            "activeLayoutID",
            "overlayDisplaySelection",
            "mirroredDisplayIDs",
            "displayLayoutProfileBindings",
            "globalShortcut",
            "stableSelectionMigrationVersion",
            "onboardingCompletedVersion",
            "onboardingDeferredVersion",
            "configurationSnapshotsV1",
            "configurationSnapshotRecoveryV1",
            "KeyPositionOffsets",
            "KeyWidthOverrides"
        ]
        XCTAssertEqual(Set(TestDefaultsKeys.all), expected)
        #if DEBUG
        XCTAssertEqual(Set(SettingsManager._testUserDefaultsKeyContract), expected)
        #endif

        let settings = SettingsManager()
        let defaults = UserDefaults.standard
        settings.isEnabled = false
        settings.glowColorHex = "ABCDEF"
        settings.glowOpacity = 0.42
        settings.physicalRefractionStrength = 2.25
        settings.glowSize = 88
        settings.glowWidth = 1.25
        settings.glowRoundness = 0.75
        settings.glowFullness = 0.33
        settings.fadeDuration = 0.9
        settings.colorMode = .rainbow
        settings.effectStyle = .physicalRefraction
        settings.chordAppearance = ChordAppearance(
            style: .independent,
            intensityMultiplier: 1.35
        )
        settings.powerSavingMode = .off
        settings.mirroredDisplayIDs = ["display-b", "display-a"]
        settings.surfaceShapeProfile = .currentWave
        settings.gradientStartHex = "112233"
        settings.gradientEndHex = "445566"
        // The launch-at-login setter talks to SMAppService and is intentionally
        // covered outside this storage-only contract. Exercise its persisted key
        // through the getter so unsigned test hosts remain deterministic.
        defaults.set(true, forKey: "launchAtLogin")

        XCTAssertEqual(defaults.object(forKey: "isEnabled") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "glowColorHex"), "ABCDEF")
        XCTAssertEqual(defaults.object(forKey: "glowOpacity") as? Double, 0.42)
        XCTAssertEqual(
            defaults.object(
                forKey: "physicalRefractionStrength"
            ) as? Double,
            2.25
        )
        XCTAssertEqual(defaults.object(forKey: "glowSize") as? Double, 88)
        XCTAssertEqual(defaults.object(forKey: "glowWidth") as? Double, 1.25)
        XCTAssertEqual(defaults.object(forKey: "glowRoundness") as? Double, 0.75)
        XCTAssertEqual(defaults.object(forKey: "glowFullness") as? Double, 0.33)
        XCTAssertEqual(defaults.object(forKey: "fadeDuration") as? Double, 0.9)
        XCTAssertEqual(defaults.string(forKey: "colorMode"), "rainbow")
        XCTAssertEqual(
            defaults.string(forKey: "effectStyle"),
            "physicalRefraction"
        )
        XCTAssertEqual(defaults.string(forKey: "chordSurfaceStyle"), "independent")
        XCTAssertEqual(
            defaults.object(forKey: "chordIntensityMultiplier") as? Double,
            1.35
        )
        XCTAssertEqual(defaults.string(forKey: "powerSavingMode"), "off")
        XCTAssertEqual(
            defaults.object(forKey: "mirroredDisplayIDs") as? [String],
            ["display-a", "display-b"]
        )
        XCTAssertEqual(
            defaults.string(forKey: "surfaceShapeProfile"),
            "currentWave"
        )
        XCTAssertEqual(defaults.string(forKey: "gradientStartHex"), "112233")
        XCTAssertEqual(defaults.string(forKey: "gradientEndHex"), "445566")
        XCTAssertTrue(defaults.bool(forKey: "launchAtLogin"))
    }

    @MainActor
    func testLegacyGradientColorModeFallback() {
        let defaults = UserDefaults.standard
        defaults.set("gradient", forKey: "colorMode")
        XCTAssertEqual(SettingsManager().colorMode, .positionGradient)
    }

    @MainActor
    func testTinyHeightEndpointPersistsWithoutBeingRaisedToLegacyMinimum() {
        let settings = SettingsManager()
        settings.glowSize = 4

        XCTAssertEqual(settings.glowSize, 4)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "glowSize") as? Double, 4)
    }

    @MainActor
    func testDefaultEffectStyleIsClassicGlow() {
        XCTAssertEqual(SettingsManager().effectStyle, .classicGlow)
    }

    @MainActor
    func testChordAppearanceDefaultsAndNormalizesPersistedValues() {
        let defaults = UserDefaults.standard
        let settings = SettingsManager()
        XCTAssertEqual(settings.chordAppearance, .default)

        defaults.set("futureStyle", forKey: "chordSurfaceStyle")
        defaults.set(9.0, forKey: "chordIntensityMultiplier")
        XCTAssertEqual(settings.chordAppearance.style, .naturalMerge)
        XCTAssertEqual(settings.chordAppearance.intensityMultiplier, 1.5)

        settings.chordAppearance = ChordAppearance(
            style: .independent,
            intensityMultiplier: -4
        )
        XCTAssertEqual(settings.chordAppearance.style, .independent)
        XCTAssertEqual(settings.chordAppearance.intensityMultiplier, 0.5)
    }

    @MainActor
    func testPowerSavingDefaultsToAutomaticAndRejectsUnknownValues() {
        let defaults = UserDefaults.standard
        let settings = SettingsManager()
        XCTAssertEqual(settings.powerSavingMode, .automatic)

        settings.powerSavingMode = .off
        XCTAssertEqual(settings.powerSavingMode, .off)

        defaults.set("futureMode", forKey: "powerSavingMode")
        XCTAssertEqual(settings.powerSavingMode, .automatic)
    }

    @MainActor
    func testMirroredDisplayIDsPersistUnavailableSelectionsAndNormalizeInput() {
        let defaults = UserDefaults.standard
        let settings = SettingsManager()
        defaults.set(
            ["connected", " disconnected ", "", String(repeating: "x", count: 201)],
            forKey: "mirroredDisplayIDs"
        )

        XCTAssertEqual(
            settings.mirroredDisplayIDs,
            Set(["connected", "disconnected"])
        )

        settings.mirroredDisplayIDs = ["offline", "connected"]
        XCTAssertEqual(
            defaults.object(forKey: "mirroredDisplayIDs") as? [String],
            ["connected", "offline"]
        )
    }

    @MainActor
    func testInvalidPersistedEffectStyleFallsBackToClassicGlow() {
        UserDefaults.standard.set("futureEffect", forKey: "effectStyle")
        XCTAssertEqual(SettingsManager().effectStyle, .classicGlow)
    }

    @MainActor
    func testSystemGlassPersistsAsADistinctEffectRoute() {
        let settings = SettingsManager()
        settings.effectStyle = .systemGlass

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "effectStyle"),
            "systemGlass"
        )
        XCTAssertEqual(SettingsManager().effectStyle, .systemGlass)
    }

    @MainActor
    func testRetiredEffectPreferencesMigrateToSupportedRoutes() {
        let settings = SettingsManager()
        settings.effectStyle = .classicPlus

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "effectStyle"),
            "classicGlow"
        )
        XCTAssertEqual(SettingsManager().effectStyle, .classicGlow)
        XCTAssertEqual(
            EffectStyle.classicPlus.resolved(liquidGlassAvailable: false),
            .classicGlow
        )
        XCTAssertTrue(EffectStyle.classicPlus.usesClassicColorConfiguration)
        XCTAssertFalse(EffectStyle.classicPlus.usesScreenCapture)
        XCTAssertFalse(EffectStyle.classicPlus.requiresMacOS26)

        settings.effectStyle = .liquidGlass
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "effectStyle"),
            "systemGlass"
        )
        XCTAssertEqual(SettingsManager().effectStyle, .systemGlass)
    }

    @MainActor
    func testEffectStyleAvailabilityResolvesSupportedGlassRoutes() {
        let settings = SettingsManager()
        settings.effectStyle = .systemGlass

        XCTAssertTrue(EffectStyle.classicGlow.isAvailableOnCurrentSystem)
        XCTAssertEqual(EffectStyle.classicGlow.resolvedForCurrentSystem, .classicGlow)

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            XCTAssertTrue(EffectStyle.systemGlass.isAvailableOnCurrentSystem)
            XCTAssertEqual(EffectStyle.systemGlass.resolvedForCurrentSystem, .systemGlass)
        } else {
            XCTAssertFalse(EffectStyle.systemGlass.isAvailableOnCurrentSystem)
            XCTAssertEqual(EffectStyle.systemGlass.resolvedForCurrentSystem, .classicGlow)
        }
        #else
        XCTAssertFalse(EffectStyle.systemGlass.isAvailableOnCurrentSystem)
        XCTAssertEqual(EffectStyle.systemGlass.resolvedForCurrentSystem, .classicGlow)
        #endif

        XCTAssertEqual(settings.effectStyle, .systemGlass)
    }

    @MainActor
    func testEffectStyleResolverCoversSupportedAndUnsupportedSystems() {
        XCTAssertEqual(
            EffectStyle.liquidGlass.resolved(liquidGlassAvailable: true),
            .systemGlass
        )
        XCTAssertEqual(
            EffectStyle.liquidGlass.resolved(liquidGlassAvailable: false),
            .classicGlow
        )
        XCTAssertEqual(
            EffectStyle.systemGlass.resolved(liquidGlassAvailable: true),
            .systemGlass
        )
        XCTAssertEqual(
            EffectStyle.systemGlass.resolved(liquidGlassAvailable: false),
            .classicGlow
        )
        XCTAssertEqual(
            EffectStyle.classicGlow.resolved(liquidGlassAvailable: false),
            .classicGlow
        )
    }

    @MainActor
    func testEachSupportedEffectKeepsIndependentSettingsAndDefaults() {
        let settings = SettingsManager()

        var classic = settings.effectConfiguration(for: .classicGlow)
        classic.opacity = 0.31
        classic.height = 47
        settings.setEffectConfiguration(classic, for: .classicGlow)

        var physical = settings.effectConfiguration(for: .physicalRefraction)
        physical.opacity = 0.84
        physical.refractionStrength = 2.2
        physical.height = 91
        settings.setEffectConfiguration(physical, for: .physicalRefraction)

        let reloaded = SettingsManager()
        XCTAssertEqual(
            reloaded.effectConfiguration(for: .classicGlow).opacity,
            0.31,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            reloaded.effectConfiguration(for: .classicGlow).height,
            47,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            reloaded.effectConfiguration(for: .physicalRefraction).opacity,
            0.84,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            reloaded.effectConfiguration(for: .physicalRefraction)
                .refractionStrength,
            2.2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            reloaded.effectConfiguration(for: .physicalRefraction).height,
            91,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            reloaded.effectConfiguration(for: .solidBlack).opacity,
            1,
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testSelectingEffectsRestoresTheirOwnLiveSliderValues() {
        let settings = SettingsManager()
        let model = KeyLightModel(
            settings: settings,
            feedbackAnnouncer: { _ in }
        )

        model.glowOpacity = 0.29
        model.glowSize = 44
        model.flushPendingPersist()

        model.selectEffect(.physicalRefraction)
        XCTAssertEqual(model.glowOpacity, 0.80, accuracy: 0.000_001)
        XCTAssertEqual(
            model.physicalRefractionStrength,
            1,
            accuracy: 0.000_001
        )

        model.glowOpacity = 0.87
        model.glowSize = 93
        model.physicalRefractionStrength = 2.3
        model.flushPendingPersist()

        model.selectEffect(.classicGlow)
        XCTAssertEqual(model.glowOpacity, 0.29, accuracy: 0.000_001)
        XCTAssertEqual(model.glowSize, 44, accuracy: 0.000_001)

        model.selectEffect(.physicalRefraction)
        XCTAssertEqual(model.glowOpacity, 0.87, accuracy: 0.000_001)
        XCTAssertEqual(model.glowSize, 93, accuracy: 0.000_001)
        XCTAssertEqual(
            model.physicalRefractionStrength,
            2.3,
            accuracy: 0.000_001
        )
    }
}

final class ConfigurationSnapshotTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "KeyLight.ConfigurationSnapshotTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testRoundTripCapturesAllowlistedSetupAndPreservesExclusions() throws {
        let settings = makeSettings()
        let theme = Theme(
            name: "Snapshot Theme",
            colorHex: "123456",
            opacity: 0.61,
            refractionStrength: 1.7,
            size: 91,
            width: 1.4,
            glowRoundness: 0.4,
            glowFullness: 0.3,
            fadeDuration: 1.8,
            colorMode: .rainbow,
            effectStyle: .physicalRefraction,
            gradientStartHex: "112233",
            gradientEndHex: "AABBCC"
        )
        let layout = KeyMappingProfile(
            name: "Snapshot Layout",
            keyOffsets: [0: 0.2, 1: -0.1],
            keyWidthOverrides: [0: 1.25]
        )
        settings.savedThemes = [theme]
        settings.activeThemeID = theme.id
        settings.savedKeyMappingProfiles = [layout]
        settings.activeLayoutID = layout.id
        settings.displayLayoutProfileBindings = ["display-main": layout.id]
        settings.overlayDisplaySelection = .specific("display-main")
        settings.mirroredDisplayIDs = ["display-left", "display-right"]
        settings.chordAppearance = ChordAppearance(
            style: .independent,
            intensityMultiplier: 1.35
        )
        settings.powerSavingMode = .off
        settings.savedGradientPresets = [GradientPreset(
            startHex: "010203",
            endHex: "A0B0C0",
            name: "Snapshot Gradient"
        )]
        settings.globalShortcut = GlobalShortcut(
            keyCode: 7,
            modifiers: 512
        )!
        var effect = EffectConfiguration.defaultConfiguration(
            for: .physicalRefraction
        )
        effect.color.solidHex = "123456"
        effect.opacity = 0.61
        effect.refractionStrength = 1.7
        effect.height = 91
        settings.effectConfiguration = effect
        var classic = EffectConfiguration.defaultConfiguration(
            for: .classicGlow
        )
        classic.height = 42
        settings.setEffectConfiguration(classic, for: .classicGlow)
        defaults.set(["0": 0.2, "1": -0.1], forKey: "KeyPositionOffsets")
        defaults.set(["0": 1.25], forKey: "KeyWidthOverrides")

        // Explicit exclusions are changed after capture and must survive apply.
        settings.isEnabled = false
        defaults.set(true, forKey: "launchAtLogin")
        settings.hasSeenPermissionExplanation = false
        defaults.set(11, forKey: "onboardingCompletedVersion")

        let document = try settings.saveCurrentConfigurationSnapshot(
            named: "Studio"
        )
        let exported = try settings.exportConfigurationSnapshotData(
            id: document.id
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exported) as? [String: Any]
        )
        XCTAssertEqual(
            object["kind"] as? String,
            ConfigurationSnapshotDocument.documentKind
        )
        XCTAssertEqual(object["version"] as? Int, 1)
        let configuration = try XCTUnwrap(
            object["configuration"] as? [String: Any]
        )
        #if DEBUG
        XCTAssertEqual(
            Set(configuration.keys),
            SettingsManager._testConfigurationSnapshotPayloadKeyRegistry
        )
        let storageKeys = Set(
            SettingsManager._testConfigurationSnapshotStorageKeyRegistry
        )
        XCTAssertFalse(storageKeys.contains("isEnabled"))
        XCTAssertFalse(storageKeys.contains("launchAtLogin"))
        XCTAssertFalse(storageKeys.contains("hasSeenPermissionExplanation"))
        XCTAssertFalse(storageKeys.contains("onboardingCompletedVersion"))
        XCTAssertFalse(storageKeys.contains("configurationSnapshotsV1"))
        XCTAssertFalse(storageKeys.contains("configurationSnapshotRecoveryV1"))
        #endif
        XCTAssertNil(configuration["isEnabled"])
        XCTAssertNil(configuration["launchAtLogin"])
        XCTAssertNil(configuration["permissions"])

        settings.glowSize = 17
        settings.chordAppearance = .default
        settings.powerSavingMode = .automatic
        settings.overlayDisplaySelection = .automatic
        settings.mirroredDisplayIDs = []
        settings.globalShortcut = .default
        defaults.set(["0": -0.4], forKey: "KeyPositionOffsets")
        settings.isEnabled = true
        defaults.set(false, forKey: "launchAtLogin")
        settings.hasSeenPermissionExplanation = true
        defaults.set(99, forKey: "onboardingCompletedVersion")

        try settings.applyConfigurationSnapshot(id: document.id)

        XCTAssertEqual(settings.effectStyle, .physicalRefraction)
        XCTAssertEqual(settings.glowSize, 91, accuracy: 0.000_001)
        XCTAssertEqual(
            settings.effectConfiguration(for: .classicGlow).height,
            42,
            accuracy: 0.000_001
        )
        XCTAssertEqual(settings.chordAppearance.style, .independent)
        XCTAssertEqual(
            settings.chordAppearance.intensityMultiplier,
            1.35,
            accuracy: 0.000_001
        )
        XCTAssertEqual(settings.powerSavingMode, .off)
        XCTAssertEqual(
            settings.overlayDisplaySelection,
            .specific("display-main")
        )
        XCTAssertEqual(
            settings.mirroredDisplayIDs,
            ["display-left", "display-right"]
        )
        XCTAssertEqual(
            settings.displayLayoutProfileBindings,
            ["display-main": layout.id]
        )
        XCTAssertEqual(settings.globalShortcut.keyCode, 7)
        let restoredOffset = try XCTUnwrap(
            defaults.dictionary(forKey: "KeyPositionOffsets")?["0"]
                as? Double
        )
        XCTAssertEqual(restoredOffset, 0.2, accuracy: 0.000_001)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: "launchAtLogin"))
        XCTAssertTrue(settings.hasSeenPermissionExplanation)
        XCTAssertEqual(defaults.integer(forKey: "onboardingCompletedVersion"), 99)
        XCTAssertEqual(settings.configurationSnapshots.count, 1)
        XCTAssertTrue(settings.hasPreviousConfigurationSnapshot)
    }

    @MainActor
    func testMalformedFutureUnknownAndOldFieldDocuments() throws {
        let settings = makeSettings()
        XCTAssertThrowsError(
            try settings.decodeConfigurationSnapshotDocument(Data("not json".utf8))
        ) { error in
            XCTAssertEqual(error as? ConfigurationSnapshotError, .invalidDocument)
        }

        let future = ConfigurationSnapshotDocument(
            version: 99,
            name: "Future",
            configuration: .default
        )
        XCTAssertThrowsError(
            try settings.decodeConfigurationSnapshotDocument(
                JSONEncoder().encode(future)
            )
        ) { error in
            XCTAssertEqual(
                error as? ConfigurationSnapshotError,
                .unsupportedVersion(99)
            )
        }

        let oldFieldJSON = """
        {
          "kind": "keylightConfigurationSnapshot",
          "version": 1,
          "name": "Older",
          "configuration": {
            "unknownFutureField": {"ignored": true}
          },
          "unknownTopLevelField": true
        }
        """
        let older = try settings.decodeConfigurationSnapshotDocument(
            Data(oldFieldJSON.utf8)
        )
        XCTAssertEqual(older.configuration.currentEffect, .default)
        XCTAssertEqual(older.configuration.chordAppearance, .default)
        XCTAssertEqual(older.configuration.powerSavingMode, .automatic)
        XCTAssertEqual(older.configuration.primaryDisplaySelection, "automatic")
        XCTAssertEqual(older.configuration.mirroredDisplayIDs, [])

        XCTAssertThrowsError(
            try settings.decodeConfigurationSnapshotDocument(
                Data(
                    count: SettingsManager
                        .maximumConfigurationSnapshotImportSize + 1
                )
            )
        ) { error in
            XCTAssertEqual(error as? ConfigurationSnapshotError, .importTooLarge)
        }
    }

    @MainActor
    func testImportConflictsReplaceOrSaveCopyWithoutApplying() throws {
        let settings = makeSettings()
        settings.glowColorHex = "111111"
        let original = try settings.saveCurrentConfigurationSnapshot(
            named: "Portable"
        )
        let imported = try settings.decodeConfigurationSnapshotDocument(
            settings.exportConfigurationSnapshotData(id: original.id)
        )

        settings.glowColorHex = "ABCDEF"
        XCTAssertThrowsError(
            try settings.importConfigurationSnapshot(
                imported,
                policy: .rejectConflict
            )
        ) { error in
            XCTAssertEqual(
                error as? ConfigurationSnapshotError,
                .nameConflict("Portable")
            )
        }
        _ = try settings.importConfigurationSnapshot(
            imported,
            policy: .replace
        )
        let copy = try settings.importConfigurationSnapshot(
            imported,
            policy: .saveCopy
        )

        XCTAssertEqual(settings.glowColorHex, "ABCDEF")
        XCTAssertEqual(settings.configurationSnapshots.count, 2)
        XCTAssertEqual(copy.name, "Portable Copy")

        let renamed = try settings.renameConfigurationSnapshot(
            id: copy.id,
            to: "Travel"
        )
        XCTAssertEqual(renamed.name, "Travel")
        let deleted = try settings.deleteConfigurationSnapshot(id: copy.id)
        XCTAssertEqual(settings.configurationSnapshots.count, 1)
        try settings.restoreDeletedConfigurationSnapshot(
            deleted.document,
            at: deleted.index
        )
        XCTAssertEqual(settings.configurationSnapshots.map(\.name), [
            "Portable",
            "Travel"
        ])
    }

    @MainActor
    func testAtomicFailureRollsBackAndDoesNotReplaceRecovery() throws {
        let settings = makeSettings(snapshotCommitVerifier: { _ in false })
        settings.glowOpacity = 0.2
        settings.mirroredDisplayIDs = ["before"]
        let document = try settings.saveCurrentConfigurationSnapshot(
            named: "Rollback"
        )

        settings.glowOpacity = 0.8
        settings.mirroredDisplayIDs = ["current"]
        XCTAssertThrowsError(
            try settings.applyConfigurationSnapshot(id: document.id)
        ) { error in
            XCTAssertEqual(
                error as? ConfigurationSnapshotError,
                .transactionFailed
            )
        }

        XCTAssertEqual(settings.glowOpacity, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(settings.mirroredDisplayIDs, ["current"])
        XCTAssertFalse(settings.hasPreviousConfigurationSnapshot)
        XCTAssertEqual(settings.configurationSnapshots.count, 1)
    }

    @MainActor
    func testRestorePreviousSetupSwapsForOneLevelUndoRedo() throws {
        let settings = makeSettings()
        settings.glowOpacity = 0.2
        let document = try settings.saveCurrentConfigurationSnapshot(
            named: "Low Opacity"
        )

        settings.glowOpacity = 0.8
        settings.mirroredDisplayIDs = ["second"]
        try settings.applyConfigurationSnapshot(id: document.id)
        XCTAssertEqual(settings.glowOpacity, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(settings.mirroredDisplayIDs, [])

        try settings.restorePreviousConfigurationSnapshot()
        XCTAssertEqual(settings.glowOpacity, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(settings.mirroredDisplayIDs, ["second"])

        try settings.restorePreviousConfigurationSnapshot()
        XCTAssertEqual(settings.glowOpacity, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(settings.mirroredDisplayIDs, [])
    }

    @MainActor
    func testModelReloadBroadcastsCompleteAppliedStateAndKeepsConflictingShortcut() throws {
        let settings = makeSettings()
        let capturedShortcut = GlobalShortcut(
            keyCode: 7,
            modifiers: 512
        )!
        settings.globalShortcut = capturedShortcut
        settings.overlayDisplaySelection = .specific("captured-primary")
        settings.mirroredDisplayIDs = ["captured-mirror"]
        settings.glowOpacity = 0.24
        let document = try settings.saveCurrentConfigurationSnapshot(
            named: "Runtime Reload"
        )

        settings.globalShortcut = .default
        settings.overlayDisplaySelection = .automatic
        settings.mirroredDisplayIDs = []
        settings.glowOpacity = 0.91
        let model = KeyLightModel(
            settings: settings,
            feedbackAnnouncer: { _ in }
        )
        var configurationReloadCount = 0
        var displaySelections: [OverlayDisplaySelection] = []
        var mirrorSelections: [Set<String>] = []
        var shortcutSelections: [GlobalShortcut] = []
        model.connectRuntime(
            onEnabledChange: { _ in },
            onConfigurationChange: { configurationReloadCount += 1 },
            onPermissionRequest: {},
            onPermissionRetry: {},
            onDisplaySelectionChange: { displaySelections.append($0) },
            onMirroredDisplaysChange: { mirrorSelections.append($0) },
            onShortcutChange: { shortcutSelections.append($0) }
        )

        try settings.applyConfigurationSnapshot(id: document.id)
        model.reloadManagedConfiguration()

        XCTAssertEqual(configurationReloadCount, 1)
        XCTAssertEqual(displaySelections, [.specific("captured-primary")])
        XCTAssertEqual(mirrorSelections, [["captured-mirror"]])
        XCTAssertEqual(shortcutSelections, [capturedShortcut])
        XCTAssertEqual(model.glowOpacity, 0.24, accuracy: 0.000_001)
        XCTAssertEqual(model.globalShortcut, capturedShortcut)

        // Carbon may report a structurally valid shortcut as occupied. The
        // applied setup remains intact and surfaces the conflict for editing.
        model.updateGlobalHotKeyStatus(.unavailable)
        XCTAssertEqual(model.globalHotKeyStatus, .unavailable)
        XCTAssertEqual(model.globalShortcut, capturedShortcut)
        XCTAssertEqual(settings.globalShortcut, capturedShortcut)
    }

    @MainActor
    func testInvalidShortcutAndPersistentLibraryLimitAreRejected() throws {
        let settings = makeSettings()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(ConfigurationSnapshotDocument(
                    name: "Invalid Shortcut",
                    configuration: .default
                ))
            ) as? [String: Any]
        )
        var configuration = try XCTUnwrap(
            object["configuration"] as? [String: Any]
        )
        configuration["globalShortcut"] = [
            "keyCode": 9_999,
            "modifiers": 0
        ]
        object["configuration"] = configuration
        let invalidShortcut = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try settings.decodeConfigurationSnapshotDocument(invalidShortcut)
        ) { error in
            guard let snapshotError = error as? ConfigurationSnapshotError,
                  case .invalidConfiguration = snapshotError else {
                return XCTFail("Expected invalid configuration, got \(error)")
            }
        }

        let keyCodes = KeyboardLayoutInfo.allKeys.map(\.id)
        let layouts = (0..<128).map { index in
            KeyMappingProfile(
                name: "Large Layout \(index)",
                keyOffsets: Dictionary(uniqueKeysWithValues: keyCodes.map {
                    ($0, CGFloat(index % 5) / 20)
                }),
                keyWidthOverrides: Dictionary(
                    uniqueKeysWithValues: keyCodes.map {
                        ($0, 1 + CGFloat(index % 3) / 10)
                    }
                )
            )
        }
        var large = ConfigurationSnapshotPayload.default
        large.layoutProfiles = layouts
        let largeDocument = ConfigurationSnapshotDocument(
            name: "Large 0",
            configuration: large
        )
        var reachedLimit = false
        for index in 0..<6 {
            var copy = largeDocument
            copy.id = UUID()
            copy.name = "Large \(index)"
            do {
                _ = try settings.importConfigurationSnapshot(
                    copy,
                    policy: .rejectConflict
                )
            } catch ConfigurationSnapshotError.persistentDataTooLarge {
                reachedLimit = true
                break
            }
        }
        XCTAssertTrue(reachedLimit, "The 500 KB persistent-data limit must be enforced")
    }

    @MainActor
    private func makeSettings(
        snapshotCommitVerifier: @escaping SettingsManager.SnapshotCommitVerifier = { _ in true }
    ) -> SettingsManager {
        SettingsManager(
            preferencesStore: PreferencesStore(
                userDefaults: defaults,
                usesSystemPreferences: false
            ),
            snapshotCommitVerifier: snapshotCommitVerifier
        )
    }
}

final class ThemeAndLayoutProfileContractTests: XCTestCase {
    private var snapshot: DefaultsSnapshot!

    override func setUp() {
        super.setUp()
        snapshot = DefaultsSnapshot(keys: TestDefaultsKeys.all)
        snapshot.clear()
    }

    override func tearDown() {
        snapshot.restore()
        snapshot = nil
        super.tearDown()
    }

    @MainActor
    func testThemeRenameRejectsCaseInsensitiveCollisions() {
        let settings = SettingsManager()

        let one = Theme(
            name: "Alpha",
            colorHex: "111111",
            opacity: 0.7,
            size: 60,
            width: 1.0,
            glowRoundness: 1.0,
            glowFullness: 0.5,
            fadeDuration: 1.0,
            colorMode: .solid,
            gradientStartHex: "3399FF",
            gradientEndHex: "00FF88"
        )
        let two = Theme(
            name: "Beta",
            colorHex: "222222",
            opacity: 0.7,
            size: 60,
            width: 1.0,
            glowRoundness: 1.0,
            glowFullness: 0.5,
            fadeDuration: 1.0,
            colorMode: .solid,
            gradientStartHex: "3399FF",
            gradientEndHex: "00FF88"
        )

        settings.savedThemes = [one, two]
        XCTAssertFalse(settings.renameTheme(from: "Alpha", to: "bEtA"))

        let names = settings.savedThemes.map(\.name)
        XCTAssertTrue(names.contains("Alpha"))
        XCTAssertTrue(names.contains("Beta"))
    }

    @MainActor
    func testLayoutProfileRenameRejectsCaseInsensitiveCollisions() {
        let settings = SettingsManager()

        let one = KeyMappingProfile(name: "Desk", keyOffsets: [122: 0.1])
        let two = KeyMappingProfile(name: "Laptop", keyOffsets: [120: -0.1])
        settings.savedKeyMappingProfiles = [one, two]

        XCTAssertFalse(settings.renameKeyMappingProfile(from: "Desk", to: "lApToP"))

        let names = settings.savedKeyMappingProfiles.map(\.name)
        XCTAssertTrue(names.contains("Desk"))
        XCTAssertTrue(names.contains("Laptop"))
    }

    @MainActor
    func testRenameCollisionIsCheckedAfterNameLengthNormalization() {
        let settings = SettingsManager()
        let maximumName = String(repeating: "A", count: PersistenceValidation.maximumNameLength)
        let existingTheme = Theme(
            name: maximumName,
            colorHex: "111111",
            opacity: 0.7,
            size: 60,
            width: 1,
            fadeDuration: 1,
            colorMode: .solid,
            gradientStartHex: nil,
            gradientEndHex: nil
        )
        let renamedTheme = Theme(
            name: "Rename Me",
            colorHex: "222222",
            opacity: 0.7,
            size: 60,
            width: 1,
            fadeDuration: 1,
            colorMode: .solid,
            gradientStartHex: nil,
            gradientEndHex: nil
        )
        settings.savedThemes = [existingTheme, renamedTheme]

        XCTAssertFalse(
            settings.renameTheme(
                from: renamedTheme.name,
                to: maximumName + " suffix"
            )
        )

        let existingLayout = KeyMappingProfile(name: maximumName, keyOffsets: [:])
        let renamedLayout = KeyMappingProfile(name: "Rename Layout", keyOffsets: [:])
        settings.savedKeyMappingProfiles = [existingLayout, renamedLayout]

        XCTAssertFalse(
            settings.renameKeyMappingProfile(
                from: renamedLayout.name,
                to: maximumName + " suffix"
            )
        )
    }
}

final class KeyGeometryContractTests: XCTestCase {
    private var snapshot: DefaultsSnapshot!

    override func setUp() {
        super.setUp()
        snapshot = DefaultsSnapshot(keys: TestDefaultsKeys.all)
        snapshot.clear()
    }

    override func tearDown() {
        snapshot.restore()
        snapshot = nil
        super.tearDown()
    }

    @MainActor
    func testKeyPositionNormalizationCanonicalizationAndClamp() {
        let store = KeyLayoutStore(defaults: .standard, debounceInterval: 60)
        store.resetAll()

        // Media aliases normalize to canonical function keys, with canonical values winning conflicts.
        store.replaceAllOffsets([
            500: 0.4,
            122: 0.1,
            126: 1.0,
            9999: 0.2
        ])

        let exported = store.exportOffsets()
        XCTAssertEqual(exported["122"], 0.1)
        XCTAssertNil(exported["500"])
        XCTAssertEqual(exported["126"], 0.5) // clamped from 1.0
        XCTAssertNil(exported["9999"])

        store.replaceAllOffsets([500: 0.4])
        let aliasOnlyExport = store.exportOffsets()
        XCTAssertEqual(aliasOnlyExport["122"], 0.4)
        XCTAssertNil(aliasOnlyExport["500"])
    }

    @MainActor
    func testKeyWidthNormalizationCanonicalizationClampUndoRedo() {
        let store = KeyLayoutStore(defaults: .standard, debounceInterval: 60)
        store.resetAll()

        // Media aliases normalize to canonical function keys, with canonical values winning conflicts.
        store.replaceAllWidthMultipliers([
            500: 2.5,
            122: 0.2,
            126: 8.0,
            9999: 1.5
        ])

        var exported = store.exportWidthMultipliers()
        XCTAssertEqual(exported["122"], 0.2)
        XCTAssertNil(exported["500"])
        XCTAssertEqual(exported["126"], 5.0) // clamped max
        XCTAssertNil(exported["9999"])

        store.setWidthMultiplier(1.8, for: 122)
        exported = store.exportWidthMultipliers()
        XCTAssertEqual(exported["122"], 1.8)

        store.undo()
        exported = store.exportWidthMultipliers()
        XCTAssertEqual(exported["122"], 0.2)

        store.redo()
        exported = store.exportWidthMultipliers()
        XCTAssertEqual(exported["122"], 1.8)

        store.replaceAllWidthMultipliers([500: 2.5])
        let aliasOnlyExport = store.exportWidthMultipliers()
        XCTAssertEqual(aliasOnlyExport["122"], 2.5)
        XCTAssertNil(aliasOnlyExport["500"])
    }

    @MainActor
    func testRuntimeEditorParityContracts() {
        #if DEBUG
        KeyMapping.assertParityContracts()
        #endif
    }

    @MainActor
    func testImportedStringKeyOffsetsNormalizationContract() {
        let normalized = KeyLayoutStore.normalizedImportedOffsets(from: [
            "500": 0.4,
            "122": 0.1,
            "125": -0.8,  // lower clamp
            "126": .infinity,
            "9999": 0.2,  // unsupported key
            "abc": 0.3    // invalid key string
        ])

        XCTAssertEqual(normalized["122"], 0.1)
        XCTAssertNil(normalized["500"])
        XCTAssertEqual(normalized["125"], -0.5)
        XCTAssertNil(normalized["126"])
        XCTAssertNil(normalized["9999"])
        XCTAssertNil(normalized["abc"])
        XCTAssertLessThanOrEqual(normalized.count, 512)
    }

    @MainActor
    func testMediaKeyFallbackUsesFunctionOverridesWhenMediaOverridesMissing() {
        let store = KeyLayoutStore(defaults: .standard, debounceInterval: 60)
        store.resetAll()

        store.setOffset(0.08, for: 122) // F1
        store.setWidthMultiplier(1.6, for: 122)

        let fallbackPosition = store.adjustedPosition(for: 500, originalPosition: 0.195)
        XCTAssertEqual(fallbackPosition, 0.275, accuracy: 0.0001)

        let fallbackWidth = store.effectiveWidth(for: 500, defaultWidth: 0.8)
        XCTAssertEqual(fallbackWidth, 1.28, accuracy: 0.0001)

        // Setting media aliases writes canonical function-key overrides.
        store.setOffset(-0.03, for: 500)
        store.setWidthMultiplier(1.1, for: 500)

        let directPosition = store.adjustedPosition(for: 500, originalPosition: 0.195)
        XCTAssertEqual(directPosition, 0.165, accuracy: 0.0001)

        let directWidth = store.effectiveWidth(for: 500, defaultWidth: 0.8)
        XCTAssertEqual(directWidth, 0.88, accuracy: 0.0001)

        let exportedOffsets = store.exportOffsets()
        let exportedWidths = store.exportWidthMultipliers()
        XCTAssertEqual(exportedOffsets["122"], -0.03)
        XCTAssertEqual(exportedWidths["122"], 1.1)
        XCTAssertNil(exportedOffsets["500"])
        XCTAssertNil(exportedWidths["500"])
    }
}

final class ThemeAndLayoutTransferTests: XCTestCase {
    private var snapshot: DefaultsSnapshot!

    override func setUp() {
        super.setUp()
        snapshot = DefaultsSnapshot(keys: TestDefaultsKeys.all)
        snapshot.clear()
    }

    override func tearDown() {
        snapshot.restore()
        snapshot = nil
        super.tearDown()
    }

    @MainActor
    func testThemeStringRoundTripAndSanitization() throws {
        let settings = SettingsManager()
        let raw = Theme(
            name: "  Imported Theme  ",
            colorHex: "GGGGGG",
            opacity: 3.0,
            refractionStrength: 3.0,
            size: 500.0,
            width: 0.05,
            glowRoundness: -1.0,
            glowFullness: 3.0,
            fadeDuration: .infinity,
            colorMode: .rainbow,
            effectStyle: .physicalRefraction,
            shapeProfile: .currentWave,
            gradientStartHex: "12",
            gradientEndHex: "!"
        )

        let serialized = try XCTUnwrap(settings.exportThemeString(raw))
        XCTAssertTrue(serialized.hasPrefix("keylight-theme-v5;"))
        XCTAssertTrue(serialized.contains("name=Imported%20Theme"))
        XCTAssertTrue(serialized.contains("mode=rainbow"))
        XCTAssertTrue(serialized.contains("effect=physicalRefraction"))
        XCTAssertTrue(serialized.contains("shape=currentWave"))
        XCTAssertTrue(serialized.contains("refraction=2.5000"))
        let imported = try settings.importThemeString(serialized)

        XCTAssertEqual(imported.name, "Imported Theme")
        XCTAssertEqual(imported.colorHex, "68B8FF")
        XCTAssertEqual(imported.opacity, 1.0)
        XCTAssertEqual(imported.refractionStrength, 2.5)
        XCTAssertEqual(imported.size, 200.0)
        XCTAssertEqual(imported.width, 0.1)
        XCTAssertEqual(imported.glowRoundness, 0.0)
        XCTAssertEqual(imported.glowFullness, 1.0)
        XCTAssertEqual(imported.fadeDuration, 1.0004, accuracy: 0.0001)
        XCTAssertEqual(imported.effectStyle, .physicalRefraction)
        XCTAssertEqual(imported.shapeProfile, .currentWave)
        XCTAssertEqual(imported.gradientStartHex, "120000")
        XCTAssertEqual(imported.gradientEndHex, "68B8FF")
    }

    @MainActor
    func testThemeStringRoundTripPreservesTinySystemGlassHeight() throws {
        let settings = SettingsManager()
        let theme = Theme(
            name: "Tiny Glass",
            colorHex: "68B8FF",
            opacity: 0.8,
            size: 4,
            width: 1,
            glowRoundness: 0.7,
            glowFullness: 0.6,
            fadeDuration: 1,
            colorMode: .solid,
            effectStyle: .systemGlass,
            gradientStartHex: nil,
            gradientEndHex: nil
        )

        let encoded = try XCTUnwrap(settings.exportThemeString(theme))
        XCTAssertEqual(try settings.importThemeString(encoded).size, 4)
    }

    @MainActor
    func testLegacySavedThemeJSONDefaultsToClassicGlow() throws {
        let legacyJSON = """
        [
          {
            "name": "Legacy JSON Theme",
            "colorHex": "68B8FF",
            "opacity": 0.8,
            "size": 80.0,
            "width": 1.0,
            "glowRoundness": 0.7,
            "glowFullness": 0.6,
            "fadeDuration": 1.0,
            "colorMode": "positionGradient",
            "gradientStartHex": "68B8FF",
            "gradientEndHex": "00E69A"
          }
        ]
        """
        UserDefaults.standard.set(Data(legacyJSON.utf8), forKey: "savedThemes")

        let imported = try XCTUnwrap(SettingsManager().savedThemes.first)
        XCTAssertEqual(imported.name, "Legacy JSON Theme")
        XCTAssertEqual(imported.effectStyle, .classicGlow)
        XCTAssertEqual(imported.shapeProfile, .currentWave)
        XCTAssertEqual(imported.refractionStrength, 1.0)
    }

    @MainActor
    func testSavedThemeJSONMigratesRetiredLiquidGlassToSystemGlass() throws {
        let settings = SettingsManager()
        let theme = Theme(
            name: "Native Glass",
            colorHex: "68B8FF",
            opacity: 0.8,
            size: 80,
            width: 1,
            glowRoundness: 0.7,
            glowFullness: 0.6,
            fadeDuration: 1,
            colorMode: .positionGradient,
            effectStyle: .liquidGlass,
            gradientStartHex: "68B8FF",
            gradientEndHex: "00E69A"
        )

        settings.savedThemes = [theme]

        let reloaded = try XCTUnwrap(settings.savedThemes.first)
        XCTAssertEqual(reloaded.name, "Native Glass")
        XCTAssertEqual(reloaded.effectStyle, .systemGlass)
    }

    @MainActor
    func testThemeStringRoundTripPreservesSystemGlassRoute() throws {
        let settings = SettingsManager()
        let theme = Theme(
            name: "System Optics",
            colorHex: "68B8FF",
            opacity: 0.8,
            size: 80,
            width: 1,
            glowRoundness: 0.7,
            glowFullness: 0.6,
            fadeDuration: 1,
            colorMode: .positionGradient,
            effectStyle: .systemGlass,
            gradientStartHex: "68B8FF",
            gradientEndHex: "00E69A"
        )

        let encoded = try XCTUnwrap(settings.exportThemeString(theme))
        XCTAssertTrue(encoded.contains("effect=systemGlass"))
        XCTAssertEqual(
            try settings.importThemeString(encoded).effectStyle,
            .systemGlass
        )
    }

    @MainActor
    func testThemeStringV5MigratesClassicPlusAndV4StillRejectsIt() throws {
        let settings = SettingsManager()
        let theme = Theme(
            name: "Classic Plus",
            colorHex: "68B8FF",
            opacity: 0.8,
            size: 80,
            width: 1,
            glowRoundness: 0.7,
            glowFullness: 0.6,
            fadeDuration: 1,
            colorMode: .positionGradient,
            effectStyle: .classicPlus,
            gradientStartHex: "68B8FF",
            gradientEndHex: "00E69A"
        )

        let encoded = try XCTUnwrap(settings.exportThemeString(theme))
        XCTAssertTrue(encoded.hasPrefix("keylight-theme-v5;"))
        XCTAssertTrue(encoded.contains("effect=classicGlow"))
        XCTAssertEqual(
            try settings.importThemeString(encoded).effectStyle,
            .classicGlow
        )

        let previewEraV5 = encoded.replacingOccurrences(
            of: "effect=classicGlow",
            with: "effect=classicPlus"
        )
        XCTAssertEqual(
            try settings.importThemeString(previewEraV5).effectStyle,
            .classicGlow
        )

        let legacySmuggle = previewEraV5.replacingOccurrences(
            of: "keylight-theme-v5;",
            with: "keylight-theme-v4;"
        )
        XCTAssertThrowsError(try settings.importThemeString(legacySmuggle))
    }

    @MainActor
    func testThemeStringV1ImportDefaultsToClassicGlow() throws {
        let v1 = "keylight-theme-v1;name=Legacy;mode=solid;color=68B8FF;opacity=0.5000;size=60.0000;width=1.0000;round=0.7000;hard=0.6000;fade=1.0000;gstart=68B8FF;gend=00E69A"
        let imported = try SettingsManager().importThemeString(v1)
        XCTAssertEqual(imported.name, "Legacy")
        XCTAssertEqual(imported.effectStyle, .classicGlow)
        XCTAssertEqual(imported.shapeProfile, .currentWave)
        XCTAssertEqual(imported.refractionStrength, 1.0)
    }

    @MainActor
    func testThemeStringV2MigratesRetiredEffectAndDefaultsToCurrentWave() throws {
        let v2 = "keylight-theme-v2;name=V2%20Glass;mode=solid;effect=liquidGlass;color=68B8FF;opacity=0.5000;size=60.0000;width=1.0000;round=0.7000;hard=0.6000;fade=1.0000;gstart=68B8FF;gend=00E69A"
        let imported = try SettingsManager().importThemeString(v2)
        XCTAssertEqual(imported.name, "V2 Glass")
        XCTAssertEqual(imported.effectStyle, .systemGlass)
        XCTAssertEqual(imported.shapeProfile, .currentWave)
        XCTAssertEqual(imported.refractionStrength, 1.0)
    }

    @MainActor
    func testPreviewEraShapeValuesNormalizeToCurrentWave() throws {
        let settings = SettingsManager()
        let legacyV3 = "keylight-theme-v3;name=Old%20Shape;mode=solid;effect=liquidGlass;shape=opticalDome;color=68B8FF;opacity=0.5;size=60;width=1;round=0.7;hard=0.6;fade=1;gstart=68B8FF;gend=00E69A"

        XCTAssertEqual(
            try settings.importThemeString(legacyV3).shapeProfile,
            .currentWave
        )
        XCTAssertEqual(
            try settings.importThemeString(legacyV3).refractionStrength,
            1.0
        )

        UserDefaults.standard.set(
            "softPillow",
            forKey: "surfaceShapeProfile"
        )
        XCTAssertEqual(settings.surfaceShapeProfile, .currentWave)
    }

    @MainActor
    func testThemeStringRejectsMalformedAndOversizedInput() {
        let settings = SettingsManager()
        XCTAssertThrowsError(try settings.importThemeString("not-a-keylight-theme"))
        XCTAssertThrowsError(try settings.importThemeString("keylight-theme-v1;name=test;name=dup"))
        XCTAssertThrowsError(try settings.importThemeString("keylight-theme-v1;name=test;mode=solid"))
        XCTAssertThrowsError(try settings.importThemeString("keylight-theme-v2;name=test;mode=solid;effect=unknown;color=68B8FF;opacity=0.5;size=60;width=1;round=0.7;hard=0.6;fade=1;gstart=68B8FF;gend=00E69A"))
        XCTAssertThrowsError(try settings.importThemeString("keylight-theme-v3;name=test;mode=solid;effect=liquidGlass;shape=unknown;color=68B8FF;opacity=0.5;size=60;width=1;round=0.7;hard=0.6;fade=1;gstart=68B8FF;gend=00E69A"))
        XCTAssertThrowsError(try settings.importThemeString("keylight-theme-v4;name=test;mode=solid;effect=physicalRefraction;shape=currentWave;color=68B8FF;opacity=0.5;size=60;width=1;round=0.7;hard=0.6;fade=1;gstart=68B8FF;gend=00E69A"))

        let oversized = "keylight-theme-v1;" + String(repeating: "a", count: 20_000)
        XCTAssertThrowsError(try settings.importThemeString(oversized))
    }

    @MainActor
    func testLayoutProfileImportSanitizesGeometry() throws {
        let payload: [String: Any] = [
            "version": 1,
            "kind": "layoutProfile",
            "name": "  Imported Layout  ",
            "keyOffsets": [
                "500": 0.3,
                "122": 0.1,
                "125": -0.9,
                "9999": 0.2
            ],
            "keyWidthOverrides": [
                "500": 2.5,
                "122": 0.2,
                "126": 9.0,
                "9999": 1.5
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let imported = try SettingsManager().importLayoutProfileData(data)
        XCTAssertEqual(imported.name, "Imported Layout")
        XCTAssertEqual(imported.keyOffsets[122], 0.1)
        XCTAssertEqual(imported.keyOffsets[125], -0.5)
        XCTAssertNil(imported.keyOffsets[500])
        XCTAssertNil(imported.keyOffsets[9999])

        XCTAssertEqual(imported.keyWidthOverrides[122], 0.2)
        XCTAssertEqual(imported.keyWidthOverrides[126], 5.0)
        XCTAssertNil(imported.keyWidthOverrides[500])
        XCTAssertNil(imported.keyWidthOverrides[9999])
    }

    @MainActor
    func testLayoutProfileImportRejectsInvalidSchema() {
        let invalid = Data("{\"version\":1}".utf8)
        XCTAssertThrowsError(try SettingsManager().importLayoutProfileData(invalid))
    }

    @MainActor
    func testFreshInstallSeedAppliesCurrentThemeAndDefaultAirLayout() throws {
        let settings = SettingsManager()
        settings._testApplyDefaultExperienceSeedIfNeeded()

        XCTAssertEqual(settings.currentThemeName, "current")
        let activeTheme = try XCTUnwrap(settings.savedThemes.first(where: { $0.name == "current" }))
        XCTAssertEqual(activeTheme.colorMode, .positionGradient)
        XCTAssertEqual(activeTheme.colorHex, "68B8FF")
        XCTAssertEqual(activeTheme.opacity, 0.8013, accuracy: 0.0001)
        XCTAssertEqual(activeTheme.size, 80.5536, accuracy: 0.0001)
        XCTAssertEqual(activeTheme.width, 1.0, accuracy: 0.0001)
        XCTAssertEqual(activeTheme.glowRoundness, 0.7069, accuracy: 0.0001)
        XCTAssertEqual(activeTheme.glowFullness, 0.6046, accuracy: 0.0001)
        XCTAssertEqual(activeTheme.fadeDuration, 1.0004, accuracy: 0.0001)
        XCTAssertEqual(activeTheme.effectStyle, .classicGlow)
        XCTAssertEqual(activeTheme.gradientStartHex, "68B8FF")
        XCTAssertEqual(activeTheme.gradientEndHex, "00E69A")

        XCTAssertEqual(settings.currentKeyMappingProfileName, "MacBook Air 13 M4 Default")
        let activeLayout = try XCTUnwrap(settings.savedKeyMappingProfiles.first(where: { $0.name == "MacBook Air 13 M4 Default" }))
        XCTAssertEqual(try XCTUnwrap(activeLayout.keyOffsets[10]), -0.08656901041666668, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(activeLayout.keyWidthOverrides[49]), 1.1005078124999996, accuracy: 0.0001)

        let defaults = UserDefaults.standard
        XCTAssertEqual(defaults.integer(forKey: "defaultExperienceSeedVersion"), 1)
        let persistedOffsets = defaults.dictionary(forKey: "KeyPositionOffsets") as? [String: CGFloat]
        XCTAssertFalse((persistedOffsets ?? [:]).isEmpty)
    }

    @MainActor
    func testFreshInstallSeedDoesNotOverrideExistingUserData() {
        let settings = SettingsManager()
        let existingTheme = Theme(
            name: "Existing",
            colorHex: "FFFFFF",
            opacity: 0.5,
            size: 55,
            width: 1.1,
            glowRoundness: 0.4,
            glowFullness: 0.4,
            fadeDuration: 0.9,
            colorMode: .solid,
            gradientStartHex: "FFFFFF",
            gradientEndHex: "000000"
        )
        settings.savedThemes = [existingTheme]
        settings.currentThemeName = existingTheme.name

        let existingLayout = KeyMappingProfile(
            name: "Existing Layout",
            keyOffsets: [122: 0.02],
            keyWidthOverrides: [122: 1.2]
        )
        settings.savedKeyMappingProfiles = [existingLayout]
        settings.currentKeyMappingProfileName = existingLayout.name

        settings._testApplyDefaultExperienceSeedIfNeeded()

        XCTAssertEqual(settings.currentThemeName, "Existing")
        XCTAssertEqual(settings.savedThemes.first?.name, "Existing")
        XCTAssertEqual(settings.currentKeyMappingProfileName, "Existing Layout")
        XCTAssertEqual(settings.savedKeyMappingProfiles.first?.name, "Existing Layout")
    }

    @MainActor
    func testLayoutMigrationAppliesDefaultWhenLayoutDataIsMissing() throws {
        let defaults = UserDefaults.standard
        // Simulate existing non-layout state so strict fresh-install seeding is skipped.
        defaults.set("ABCDEF", forKey: "glowColorHex")

        let settings = SettingsManager()
        settings.savedKeyMappingProfiles = []
        settings.currentKeyMappingProfileName = "None"
        defaults.removeObject(forKey: "KeyPositionOffsets")
        defaults.removeObject(forKey: "KeyWidthOverrides")
        defaults.removeObject(forKey: "defaultLayoutMigrationVersion")

        settings._testApplyDefaultLayoutIfMissingOnce()

        XCTAssertEqual(settings.currentKeyMappingProfileName, "MacBook Air 13 M4 Default")
        let activeLayout = try XCTUnwrap(settings.savedKeyMappingProfiles.first(where: { $0.name == "MacBook Air 13 M4 Default" }))
        XCTAssertEqual(try XCTUnwrap(activeLayout.keyOffsets[10]), -0.08656901041666668, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(activeLayout.keyWidthOverrides[49]), 1.1005078124999996, accuracy: 0.0001)
        XCTAssertEqual(defaults.integer(forKey: "defaultLayoutMigrationVersion"), 1)
    }

    @MainActor
    func testLayoutMigrationDoesNotOverrideExistingCustomLayout() {
        let defaults = UserDefaults.standard
        let settings = SettingsManager()

        let existingLayout = KeyMappingProfile(
            name: "Existing Layout",
            keyOffsets: [122: 0.02],
            keyWidthOverrides: [122: 1.2]
        )
        settings.savedKeyMappingProfiles = [existingLayout]
        settings.currentKeyMappingProfileName = existingLayout.name
        defaults.set(["122": 0.02], forKey: "KeyPositionOffsets")
        defaults.set(["122": 1.2], forKey: "KeyWidthOverrides")
        defaults.removeObject(forKey: "defaultLayoutMigrationVersion")

        settings._testApplyDefaultLayoutIfMissingOnce()

        XCTAssertEqual(settings.currentKeyMappingProfileName, "Existing Layout")
        XCTAssertEqual(settings.savedKeyMappingProfiles.count, 1)
        XCTAssertEqual(settings.savedKeyMappingProfiles.first?.name, "Existing Layout")
        XCTAssertEqual(defaults.integer(forKey: "defaultLayoutMigrationVersion"), 1)
    }

    @MainActor
    func testBundledLayoutPresetListAndImport() throws {
        let settings = SettingsManager()
        let presets = settings.bundledLayoutPresets()
        XCTAssertEqual(presets.count, 5)
        let airPreset = try XCTUnwrap(presets.first(where: { $0.id == "macbook-air-13-m4-default" }))
        let imported = try settings.importBundledLayoutPreset(airPreset)

        XCTAssertEqual(imported.name, "MacBook Air 13 M4 Default")
        XCTAssertEqual(try XCTUnwrap(imported.keyOffsets[10]), -0.08656901041666668, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(imported.keyWidthOverrides[49]), 1.1005078124999996, accuracy: 0.0001)

        let proPreset = try XCTUnwrap(presets.first(where: { $0.id == "macbook-pro-14-m4" }))
        let importedPro = try settings.importBundledLayoutPreset(proPreset)
        XCTAssertEqual(importedPro.name, "MacBook Pro 14 M4")
        XCTAssertFalse(importedPro.keyOffsets.isEmpty)

        let ansiPreset = try XCTUnwrap(presets.first(where: { $0.id == "macbook-ansi-baseline" }))
        let importedANSI = try settings.importBundledLayoutPreset(ansiPreset)
        XCTAssertEqual(importedANSI.name, "MacBook ANSI Baseline")
        XCTAssertTrue(importedANSI.keyOffsets.isEmpty)
        XCTAssertTrue(importedANSI.keyWidthOverrides.isEmpty)

        let isoPreset = try XCTUnwrap(presets.first(where: { $0.id == "macbook-iso-baseline" }))
        XCTAssertTrue(try settings.importBundledLayoutPreset(isoPreset).keyOffsets.isEmpty)

        let compactPreset = try XCTUnwrap(presets.first(where: {
            $0.id == "magic-keyboard-compact-baseline"
        }))
        XCTAssertTrue(try settings.importBundledLayoutPreset(compactPreset).keyOffsets.isEmpty)
    }

    @MainActor
    func testBundledLayoutProfileSeedAddsMissingMBPWithoutChangingActiveAir() throws {
        let defaults = UserDefaults.standard
        let settings = SettingsManager()
        let presets = settings.bundledLayoutPresets()
        let airPreset = try XCTUnwrap(presets.first(where: { $0.id == "macbook-air-13-m4-default" }))
        let airProfile = try settings.importBundledLayoutPreset(airPreset, forcedName: "MacBook Air 13 M4 Default")

        settings.savedKeyMappingProfiles = [airProfile]
        settings.currentKeyMappingProfileName = "MacBook Air 13 M4 Default"
        defaults.removeObject(forKey: "bundledLayoutProfilesSeedVersion")

        settings._testSeedBundledLayoutProfilesIfNeededOnce()

        let names = settings.savedKeyMappingProfiles.map(\.name)
        XCTAssertTrue(names.contains("MacBook Air 13 M4 Default"))
        XCTAssertTrue(names.contains("MacBook Pro 14 M4"))
        XCTAssertEqual(settings.currentKeyMappingProfileName, "MacBook Air 13 M4 Default")
        XCTAssertEqual(defaults.integer(forKey: "bundledLayoutProfilesSeedVersion"), 1)
    }

    @MainActor
    func testBundledLayoutProfileSeedDoesNotRecreateAfterUserDeletion() throws {
        let defaults = UserDefaults.standard
        let settings = SettingsManager()
        let presets = settings.bundledLayoutPresets()
        let airPreset = try XCTUnwrap(presets.first(where: { $0.id == "macbook-air-13-m4-default" }))
        let airProfile = try settings.importBundledLayoutPreset(airPreset, forcedName: "MacBook Air 13 M4 Default")

        settings.savedKeyMappingProfiles = [airProfile]
        settings.currentKeyMappingProfileName = "MacBook Air 13 M4 Default"
        defaults.set(1, forKey: "bundledLayoutProfilesSeedVersion")

        settings._testSeedBundledLayoutProfilesIfNeededOnce()

        XCTAssertEqual(settings.savedKeyMappingProfiles.map(\.name), ["MacBook Air 13 M4 Default"])
        XCTAssertEqual(settings.currentKeyMappingProfileName, "MacBook Air 13 M4 Default")
    }
}

final class InputMonitoringReconciliationTests: XCTestCase {
    func testDeniedPermissionRequestsOnlyWhenExplicitlyAllowed() {
        XCTAssertEqual(
            InputMonitoringReconciliationResolver.resolve(
                installationIssue: nil,
                authorized: false,
                allowRequest: true,
                isEnabled: true,
                monitorExists: false,
                monitorRunning: false
            ),
            .requestPermission
        )

        XCTAssertEqual(
            InputMonitoringReconciliationResolver.resolve(
                installationIssue: nil,
                authorized: false,
                allowRequest: false,
                isEnabled: true,
                monitorExists: true,
                monitorRunning: true
            ),
            .settle(state: .permissionRequired, stopMonitor: true)
        )

        XCTAssertEqual(
            InputMonitoringReconciliationResolver.resolve(
                installationIssue: nil,
                authorized: false,
                allowRequest: true,
                isEnabled: false,
                monitorExists: false,
                monitorRunning: false
            ),
            .requestPermission
        )
    }

    func testInvalidInstallationBlocksPermissionRequest() {
        XCTAssertEqual(
            InputMonitoringReconciliationResolver.resolve(
                installationIssue: "Running from a disk image",
                authorized: false,
                allowRequest: true,
                isEnabled: true,
                monitorExists: false,
                monitorRunning: false
            ),
            .settle(state: .permissionRequired, stopMonitor: false)
        )
    }

    func testAuthorizedDisabledEffectStopsMonitorAndRemainsAuthorized() {
        XCTAssertEqual(
            InputMonitoringReconciliationResolver.resolve(
                installationIssue: nil,
                authorized: true,
                allowRequest: false,
                isEnabled: false,
                monitorExists: true,
                monitorRunning: true
            ),
            .settle(state: .authorized, stopMonitor: true)
        )
    }

    func testAuthorizedRunningMonitorRemainsActive() {
        XCTAssertEqual(
            InputMonitoringReconciliationResolver.resolve(
                installationIssue: nil,
                authorized: true,
                allowRequest: false,
                isEnabled: true,
                monitorExists: true,
                monitorRunning: true
            ),
            .settle(state: .active, stopMonitor: false)
        )
    }

    func testAuthorizedMissingOrDeadMonitorStartsTruthfully() {
        XCTAssertEqual(
            InputMonitoringReconciliationResolver.resolve(
                installationIssue: nil,
                authorized: true,
                allowRequest: false,
                isEnabled: true,
                monitorExists: false,
                monitorRunning: false
            ),
            .startMonitor(stopExisting: false)
        )
        XCTAssertEqual(
            InputMonitoringReconciliationResolver.resolve(
                installationIssue: nil,
                authorized: true,
                allowRequest: false,
                isEnabled: true,
                monitorExists: true,
                monitorRunning: false
            ),
            .startMonitor(stopExisting: true)
        )
        XCTAssertEqual(InputMonitoringReconciliationResolver.stateAfterMonitorStart(succeeded: true), .active)
        XCTAssertEqual(InputMonitoringReconciliationResolver.stateAfterMonitorStart(succeeded: false), .monitorUnavailable)
    }

    @MainActor
    func testInstallationGuardRecognizesDiskImagesAndFinderRenames() {
        XCTAssertNotNil(
            PermissionManager.installationIssue(
                for: URL(fileURLWithPath: "/Volumes/KeyLight 2.0.0/KeyLight.app")
            )
        )
        XCTAssertNotNil(
            PermissionManager.installationIssue(
                for: URL(fileURLWithPath: "/Applications/KeyLight 2.app")
            )
        )
        XCTAssertNotNil(
            PermissionManager.installationIssue(
                for: URL(fileURLWithPath: "/private/tmp/Downloads/KeyLight.app")
            )
        )
        XCTAssertNotNil(
            PermissionManager.installationIssue(
                for: URL(fileURLWithPath: "/private/var/folders/example/AppTranslocation/KeyLight.app")
            )
        )
        XCTAssertNil(
            PermissionManager.installationIssue(
                for: URL(fileURLWithPath: "/Applications/KeyLight.app")
            )
        )
        XCTAssertNil(
            PermissionManager.installationIssue(
                for: URL(fileURLWithPath: "/tmp/DerivedData/Build/Products/Debug/KeyLight.app"),
                bundleIdentifier: "com.keylight.app.debug"
            )
        )
        XCTAssertNotNil(
            PermissionManager.installationIssue(
                for: URL(fileURLWithPath: "/Volumes/Debug/KeyLight.app"),
                bundleIdentifier: "com.keylight.app.debug"
            )
        )

        XCTAssertNil(
            PermissionManager.installationIssue(
                for: URL(fileURLWithPath: "/Applications/KeyLight 2.0.app"),
                bundleIdentifier: "com.keylight.app.v2",
                expectedBundleName: "KeyLight 2.0.app"
            )
        )
        XCTAssertNotNil(
            PermissionManager.installationIssue(
                for: URL(fileURLWithPath: "/Applications/KeyLight.app"),
                bundleIdentifier: "com.keylight.app.v2",
                expectedBundleName: "KeyLight 2.0.app"
            )
        )
        XCTAssertNotNil(
            PermissionManager.installationIssue(
                for: URL(fileURLWithPath: "/Applications/KeyLight 2.0 2.app"),
                bundleIdentifier: "com.keylight.app.v2",
                expectedBundleName: "KeyLight 2.0.app"
            )
        )
        XCTAssertNotNil(
            PermissionManager.installationIssue(
                for: URL(fileURLWithPath: "/Volumes/KeyLight 2.0/KeyLight 2.0.app"),
                bundleIdentifier: "com.keylight.app.v2",
                expectedBundleName: "KeyLight 2.0.app"
            )
        )
    }

    @MainActor
    func testEveryEnabledStateMutationCallsTheLifecycleReconcilerDirectly() {
        let snapshot = DefaultsSnapshot(keys: TestDefaultsKeys.all)
        snapshot.clear()
        defer { snapshot.restore() }

        let appState = KeyLightModel(settings: SettingsManager())
        var receivedEnabledValues: [Bool] = []
        appState.connectRuntime(
            onEnabledChange: { receivedEnabledValues.append($0) },
            onConfigurationChange: {},
            onPermissionRequest: {},
            onPermissionRetry: {}
        )
        appState.isEnabled.toggle()

        XCTAssertEqual(receivedEnabledValues, [appState.isEnabled])
    }

    func testPrivacyBoundaryUsesListenOnlyTapAtRuntime() {
        XCTAssertEqual(
            KeyboardMonitor.eventTapOptions.rawValue,
            CGEventTapOptions.listenOnly.rawValue
        )
    }
}
