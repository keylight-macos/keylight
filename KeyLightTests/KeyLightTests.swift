import XCTest
import CoreGraphics
import AppKit
@testable import KeyLight

private enum TestDefaultsKeys {
    static let all: [String] = [
        "isEnabled",
        "glowColorHex",
        "glowOpacity",
        "glowSize",
        "glowWidth",
        "glowRoundness",
        "glowFullness",
        "fadeDuration",
        "fadeDurationDefaultMigratedV2",
        "launchAtLogin",
        "colorMode",
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

private func repositoryRootURL(from filePath: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(filePath)")
        .deletingLastPathComponent()  // KeyLightTests/
        .deletingLastPathComponent()  // repo root
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
            "glowSize",
            "glowWidth",
            "glowRoundness",
            "glowFullness",
            "fadeDuration",
            "fadeDurationDefaultMigratedV2",
            "launchAtLogin",
            "colorMode",
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
            "KeyPositionOffsets",
            "KeyWidthOverrides"
        ]
        XCTAssertEqual(Set(TestDefaultsKeys.all), expected)

        let settings = SettingsManager.shared
        settings.isEnabled = false
        settings.glowColorHex = "ABCDEF"
        settings.glowOpacity = 0.42
        settings.glowSize = 88
        settings.glowWidth = 1.25
        settings.glowRoundness = 0.75
        settings.glowFullness = 0.33
        settings.fadeDuration = 0.9
        settings.colorMode = .rainbow
        settings.gradientStartHex = "112233"
        settings.gradientEndHex = "445566"
        settings.launchAtLogin = false

        let defaults = UserDefaults.standard
        XCTAssertEqual(defaults.object(forKey: "isEnabled") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "glowColorHex"), "ABCDEF")
        XCTAssertEqual(defaults.object(forKey: "glowOpacity") as? Double, 0.42)
        XCTAssertEqual(defaults.object(forKey: "glowSize") as? Double, 88)
        XCTAssertEqual(defaults.object(forKey: "glowWidth") as? Double, 1.25)
        XCTAssertEqual(defaults.object(forKey: "glowRoundness") as? Double, 0.75)
        XCTAssertEqual(defaults.object(forKey: "glowFullness") as? Double, 0.33)
        XCTAssertEqual(defaults.object(forKey: "fadeDuration") as? Double, 0.9)
        XCTAssertEqual(defaults.string(forKey: "colorMode"), "rainbow")
        XCTAssertEqual(defaults.string(forKey: "gradientStartHex"), "112233")
        XCTAssertEqual(defaults.string(forKey: "gradientEndHex"), "445566")
        XCTAssertEqual(defaults.object(forKey: "launchAtLogin") as? Bool, false)
    }

    @MainActor
    func testLegacyGradientColorModeFallback() {
        let defaults = UserDefaults.standard
        defaults.set("gradient", forKey: "colorMode")
        XCTAssertEqual(SettingsManager.shared.colorMode, .positionGradient)
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
        let settings = SettingsManager.shared

        let one = SettingsManager.Theme(
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
        let two = SettingsManager.Theme(
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
        settings.renameTheme(from: "Alpha", to: "bEtA")

        let names = settings.savedThemes.map(\.name)
        XCTAssertTrue(names.contains("Alpha"))
        XCTAssertTrue(names.contains("Beta"))
    }

    @MainActor
    func testLayoutProfileRenameRejectsCaseInsensitiveCollisions() {
        let settings = SettingsManager.shared

        let one = SettingsManager.KeyMappingProfile(name: "Desk", keyOffsets: [122: 0.1])
        let two = SettingsManager.KeyMappingProfile(name: "Laptop", keyOffsets: [120: -0.1])
        settings.savedKeyMappingProfiles = [one, two]

        settings.renameKeyMappingProfile(from: "Desk", to: "lApToP")

        let names = settings.savedKeyMappingProfiles.map(\.name)
        XCTAssertTrue(names.contains("Desk"))
        XCTAssertTrue(names.contains("Laptop"))
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
        let manager = KeyPositionManager.shared
        manager.resetAllKeys()

        // Media aliases normalize to canonical function keys, with canonical values winning conflicts.
        manager.replaceAllOffsets([
            500: 0.4,
            122: 0.1,
            126: 1.0,
            9999: 0.2
        ])

        let exported = manager.exportOffsets()
        XCTAssertEqual(exported["122"], 0.1)
        XCTAssertNil(exported["500"])
        XCTAssertEqual(exported["126"], 0.5) // clamped from 1.0
        XCTAssertNil(exported["9999"])

        manager.replaceAllOffsets([500: 0.4])
        let aliasOnlyExport = manager.exportOffsets()
        XCTAssertEqual(aliasOnlyExport["122"], 0.4)
        XCTAssertNil(aliasOnlyExport["500"])
    }

    @MainActor
    func testKeyWidthNormalizationCanonicalizationClampUndoRedo() {
        let manager = KeyWidthManager.shared
        manager.resetAllKeys()

        // Media aliases normalize to canonical function keys, with canonical values winning conflicts.
        manager.replaceAllOverrides([
            500: 2.5,
            122: 0.2,
            126: 8.0,
            9999: 1.5
        ])

        var exported = manager.exportOverrides()
        XCTAssertEqual(exported["122"], 0.2)
        XCTAssertNil(exported["500"])
        XCTAssertEqual(exported["126"], 5.0) // clamped max
        XCTAssertNil(exported["9999"])

        manager.setWidthMultiplier(1.8, for: 122)
        exported = manager.exportOverrides()
        XCTAssertEqual(exported["122"], 1.8)

        manager.undo()
        exported = manager.exportOverrides()
        XCTAssertEqual(exported["122"], 0.2)

        manager.redo()
        exported = manager.exportOverrides()
        XCTAssertEqual(exported["122"], 1.8)

        manager.replaceAllOverrides([500: 2.5])
        let aliasOnlyExport = manager.exportOverrides()
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
        let normalized = KeyPositionManager.normalizedImportedOffsets(from: [
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
        let positionManager = KeyPositionManager.shared
        let widthManager = KeyWidthManager.shared
        positionManager.resetAllKeys()
        widthManager.resetAllKeys()

        positionManager.setOffset(0.08, for: 122) // F1
        widthManager.setWidthMultiplier(1.6, for: 122)

        let fallbackPosition = positionManager.adjustedPosition(for: 500, originalPosition: 0.195)
        XCTAssertEqual(fallbackPosition, 0.275, accuracy: 0.0001)

        let fallbackWidth = widthManager.effectiveWidth(for: 500, defaultWidth: 0.8)
        XCTAssertEqual(fallbackWidth, 1.28, accuracy: 0.0001)

        // Setting media aliases writes canonical function-key overrides.
        positionManager.setOffset(-0.03, for: 500)
        widthManager.setWidthMultiplier(1.1, for: 500)

        let directPosition = positionManager.adjustedPosition(for: 500, originalPosition: 0.195)
        XCTAssertEqual(directPosition, 0.165, accuracy: 0.0001)

        let directWidth = widthManager.effectiveWidth(for: 500, defaultWidth: 0.8)
        XCTAssertEqual(directWidth, 0.88, accuracy: 0.0001)

        let exportedOffsets = positionManager.exportOffsets()
        let exportedWidths = widthManager.exportOverrides()
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
        let settings = SettingsManager.shared
        let raw = SettingsManager.Theme(
            name: "  Imported Theme  ",
            colorHex: "GGGGGG",
            opacity: 3.0,
            size: 500.0,
            width: 0.05,
            glowRoundness: -1.0,
            glowFullness: 3.0,
            fadeDuration: .infinity,
            colorMode: .rainbow,
            gradientStartHex: "12",
            gradientEndHex: "!"
        )

        let serialized = try XCTUnwrap(settings.exportThemeString(raw))
        XCTAssertTrue(serialized.hasPrefix("keylight-theme-v1;"))
        XCTAssertTrue(serialized.contains("name=Imported%20Theme"))
        XCTAssertTrue(serialized.contains("mode=rainbow"))
        let imported = try settings.importThemeString(serialized)

        XCTAssertEqual(imported.name, "Imported Theme")
        XCTAssertEqual(imported.colorHex, "68B8FF")
        XCTAssertEqual(imported.opacity, 1.0)
        XCTAssertEqual(imported.size, 200.0)
        XCTAssertEqual(imported.width, 0.1)
        XCTAssertEqual(imported.glowRoundness, 0.0)
        XCTAssertEqual(imported.glowFullness, 1.0)
        XCTAssertEqual(imported.fadeDuration, 1.0004, accuracy: 0.0001)
        XCTAssertEqual(imported.gradientStartHex, "120000")
        XCTAssertEqual(imported.gradientEndHex, "68B8FF")
    }

    @MainActor
    func testThemeStringRejectsMalformedAndOversizedInput() {
        let settings = SettingsManager.shared
        XCTAssertThrowsError(try settings.importThemeString("not-a-keylight-theme"))
        XCTAssertThrowsError(try settings.importThemeString("keylight-theme-v1;name=test;name=dup"))
        XCTAssertThrowsError(try settings.importThemeString("keylight-theme-v1;name=test;mode=solid"))

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

        let imported = try SettingsManager.shared.importLayoutProfileData(data)
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
        XCTAssertThrowsError(try SettingsManager.shared.importLayoutProfileData(invalid))
    }

    @MainActor
    func testVariantLayoutTemplateImportsOffsetsAndWidths() throws {
        let profileURL = repositoryRootURL()
            .appendingPathComponent("docs/variants/macbook-air-13-m4/keylight-layout-profile-template.json")
        let data = try Data(contentsOf: profileURL)
        let imported = try SettingsManager.shared.importLayoutProfileData(data)

        XCTAssertEqual(try XCTUnwrap(imported.keyOffsets[10]), 0.012, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(imported.keyOffsets[44]), -0.008, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(imported.keyOffsets[123]), 0.006, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(imported.keyWidthOverrides[10]), 1.12, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(imported.keyWidthOverrides[49]), 1.03, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(imported.keyWidthOverrides[123]), 0.95, accuracy: 0.0001)
    }

    @MainActor
    func testFreshInstallSeedAppliesCurrentThemeAndDefaultAirLayout() throws {
        let settings = SettingsManager.shared
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
        let settings = SettingsManager.shared
        let existingTheme = SettingsManager.Theme(
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

        let existingLayout = SettingsManager.KeyMappingProfile(
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

        let settings = SettingsManager.shared
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
        let settings = SettingsManager.shared

        let existingLayout = SettingsManager.KeyMappingProfile(
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
        let settings = SettingsManager.shared
        let presets = settings.bundledLayoutPresets()
        let airPreset = try XCTUnwrap(presets.first(where: { $0.id == "macbook-air-13-m4-default" }))
        let imported = try settings.importBundledLayoutPreset(airPreset)

        XCTAssertEqual(imported.name, "MacBook Air 13 M4 Default")
        XCTAssertEqual(try XCTUnwrap(imported.keyOffsets[10]), -0.08656901041666668, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(imported.keyWidthOverrides[49]), 1.1005078124999996, accuracy: 0.0001)

        let proPreset = try XCTUnwrap(presets.first(where: { $0.id == "macbook-pro-14-m4" }))
        let importedPro = try settings.importBundledLayoutPreset(proPreset)
        XCTAssertEqual(importedPro.name, "MacBook Pro 14 M4")
        XCTAssertFalse(importedPro.keyOffsets.isEmpty)
    }

    @MainActor
    func testBundledLayoutProfileSeedAddsMissingMBPWithoutChangingActiveAir() throws {
        let defaults = UserDefaults.standard
        let settings = SettingsManager.shared
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
        let settings = SettingsManager.shared
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

final class KeyboardMonitorContractTests: XCTestCase {
    func testMediaVirtualKeyResolutionAndDedupeWindow() {
        let monitor = KeyboardMonitor { _ in }

        XCTAssertEqual(monitor._testResolveVirtualKeyCode(nxCode: 0), 520)  // sound up
        XCTAssertEqual(monitor._testResolveVirtualKeyCode(nxCode: 3), 500)  // brightness down
        XCTAssertEqual(monitor._testResolveVirtualKeyCode(nxCode: 7), 518)  // mute
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 4))
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 5))
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 6))
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 19))
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 20))
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 999))

        let t0: CFAbsoluteTime = 1000
        XCTAssertFalse(monitor._testShouldDedupeMediaEvent(keyCode: 516, isKeyDown: true, now: t0))
        XCTAssertTrue(monitor._testShouldDedupeMediaEvent(keyCode: 516, isKeyDown: true, now: t0 + 0.01))
        XCTAssertFalse(monitor._testShouldDedupeMediaEvent(keyCode: 516, isKeyDown: true, now: t0 + 0.05))

        // HID wins when both sources report the same physical press in a short window.
        XCTAssertFalse(
            monitor._testShouldDedupeMediaEventWithSource(
                keyCode: 517,
                isKeyDown: true,
                source: "hid",
                now: t0 + 1.0
            )
        )
        XCTAssertTrue(
            monitor._testShouldDedupeMediaEventWithSource(
                keyCode: 517,
                isKeyDown: true,
                source: "system",
                now: t0 + 1.01
            )
        )
    }

    func testDeterministicTopRowMappingAndUnknownRawBehavior() {
        let monitor = KeyboardMonitor { _ in }

        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCode(
                rawKeyCode: 160,
                charactersIgnoringModifiers: String(UnicodeScalar(0xF706)!)
            ),
            99 // F3
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventConfidence(
                rawKeyCode: 160,
                charactersIgnoringModifiers: String(UnicodeScalar(0xF706)!)
            ),
            "high"
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCode(
                rawKeyCode: 161,
                charactersIgnoringModifiers: String(UnicodeScalar(0xF707)!)
            ),
            118 // F4
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCode(
                rawKeyCode: 162,
                charactersIgnoringModifiers: String(UnicodeScalar(0xF708)!)
            ),
            96 // F5
        )

        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCode(
                rawKeyCode: 163,
                charactersIgnoringModifiers: "A"
            ),
            163
        )

        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCode(
                rawKeyCode: 122,
                charactersIgnoringModifiers: String(UnicodeScalar(0xF706)!)
            ),
            122
        )

        let trustedRawMappings: [(UInt16, UInt16)] = [
            (145, 122),
            (144, 120),
            (160, 99),
            (131, 118),
            (177, 96),
            (176, 97),
            (173, 98),
            (174, 100),
            (175, 101),
            (74, 109),
            (73, 103),
            (72, 111)
        ]

        for (raw, expected) in trustedRawMappings {
            XCTAssertEqual(
                monitor._testResolveKeyboardEventKeyCode(
                    rawKeyCode: raw,
                    charactersIgnoringModifiers: nil
                ),
                expected
            )
            XCTAssertEqual(
                monitor._testResolveKeyboardEventConfidence(
                    rawKeyCode: raw,
                    charactersIgnoringModifiers: nil
                ),
                "high"
            )
        }

        // Unknown raw key remains unresolved.
        XCTAssertEqual(
            monitor._testResolveKeyboardEventConfidence(
                rawKeyCode: 163,
                charactersIgnoringModifiers: nil
            ),
            "unknown"
        )

        // NSEvent specialKey provides deterministic top-row mapping for hardware-specific raw codes.
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 160,
                specialKeyRawValue: NSEvent.SpecialKey.f4.rawValue
            ),
            118
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 177,
                specialKeyRawValue: NSEvent.SpecialKey.f5.rawValue
            ),
            96
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 173,
                specialKeyRawValue: NSEvent.SpecialKey.f7.rawValue
            ),
            98
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 175,
                specialKeyRawValue: NSEvent.SpecialKey.f9.rawValue
            ),
            101
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventConfidenceWithSpecialKey(
                rawKeyCode: 173,
                specialKeyRawValue: NSEvent.SpecialKey.f7.rawValue
            ),
            "high"
        )
    }

    func testUnresolvedKeyboardRawDoesNotSuppressMediaSource() {
        let monitor = KeyboardMonitor { _ in }
        let t0: CFAbsoluteTime = 2100

        XCTAssertEqual(
            monitor._testResolveKeyboardEventConfidence(
                rawKeyCode: 163,
                charactersIgnoringModifiers: nil
            ),
            "unknown"
        )

        // No keyboard-first suppression: first media event for this key/state should pass.
        XCTAssertFalse(
            monitor._testShouldDedupeMediaEventWithSource(
                keyCode: 506,
                isKeyDown: true,
                source: "system",
                now: t0 + 0.01
            )
        )
        // Duplicate key/state in-window still dedupes normally.
        XCTAssertTrue(
            monitor._testShouldDedupeMediaEventWithSource(
                keyCode: 506,
                isKeyDown: true,
                source: "system",
                now: t0 + 0.02
            )
        )
    }

    func testTrustedRawTopRowMediaCodesMapToFunctionKeys() {
        let monitor = KeyboardMonitor { _ in }

        let rawMediaCodesToExpected: [(UInt16, UInt16)] = [
            (145, 122),
            (144, 120),
            (160, 99),
            (131, 118),
            (177, 96),
            (176, 97),
            (173, 98),
            (174, 100),
            (175, 101),
            (74, 109),
            (73, 103),
            (72, 111)
        ]
        for (code, expected) in rawMediaCodesToExpected {
            XCTAssertEqual(
                monitor._testResolveKeyboardEventKeyCode(
                    rawKeyCode: code,
                    charactersIgnoringModifiers: nil
                ),
                expected,
                "Raw top-row code \(code) should resolve to F-key \(expected)"
            )
            XCTAssertEqual(
                monitor._testResolveKeyboardEventConfidence(
                    rawKeyCode: code,
                    charactersIgnoringModifiers: nil
                ),
                "high",
                "Raw top-row code \(code) should be trusted via explicit map"
            )
        }
    }

    func testTrustedMetadataStillMapsF4F5F7F9() {
        let monitor = KeyboardMonitor { _ in }

        XCTAssertEqual(
            monitor._testResolveKeyboardEventConfidenceWithSpecialKey(
                rawKeyCode: 160,
                specialKeyRawValue: NSEvent.SpecialKey.f4.rawValue
            ),
            "high"
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 160,
                specialKeyRawValue: NSEvent.SpecialKey.f4.rawValue
            ),
            118
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 177,
                specialKeyRawValue: NSEvent.SpecialKey.f5.rawValue
            ),
            96
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 173,
                specialKeyRawValue: NSEvent.SpecialKey.f7.rawValue
            ),
            98
        )
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCodeWithSpecialKey(
                rawKeyCode: 175,
                specialKeyRawValue: NSEvent.SpecialKey.f9.rawValue
            ),
            101
        )
    }

    func testLegacyNXTopRowOverridesAreDisabled() {
        let monitor = KeyboardMonitor { _ in }

        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 4))
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 5))
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 6))
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 19))
        XCTAssertNil(monitor._testResolveVirtualKeyCode(nxCode: 20))
    }

    func testModifierFlagsChangedResolutionForCommandOptionControlAndFn() {
        let monitor = KeyboardMonitor { _ in }

        // Left and right Command
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 55, flags: [.maskCommand]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 54, flags: [.maskCommand]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 54, flags: [.maskCommand]), false)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 55, flags: []), false)

        // Left and right Option
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 58, flags: [.maskAlternate]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 61, flags: [.maskAlternate]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 61, flags: [.maskAlternate]), false)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 58, flags: []), false)

        // Left and right Control
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 59, flags: [.maskControl]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 62, flags: [.maskControl]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 62, flags: [.maskControl]), false)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 59, flags: []), false)

        // Fn
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 63, flags: [.maskSecondaryFn]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 63, flags: []), false)

        // Caps Lock stays isolated to key 57 and never maps to top-row aliases.
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 57, flags: [.maskAlphaShift]), true)
        XCTAssertEqual(monitor._testResolveModifierFlagsChanged(keyCode: 57, flags: []), false)
        XCTAssertEqual(
            monitor._testResolveKeyboardEventKeyCode(
                rawKeyCode: 57,
                charactersIgnoringModifiers: nil
            ),
            57
        )
        XCTAssertEqual(monitor._testCapsLockEmitSequence(isKeyDown: true), [true, false])
        XCTAssertEqual(monitor._testCapsLockEmitSequence(isKeyDown: false), [false])

        // Unknown/non-modifier key should be ignored
        XCTAssertNil(monitor._testResolveModifierFlagsChanged(keyCode: 12, flags: [.maskCommand]))
    }
}

final class NotificationContractTests: XCTestCase {
    func testNotificationNameRawValuesRemainStable() {
        XCTAssertEqual(Notification.Name.glowSettingsChanged.rawValue, "glowSettingsChanged")
        XCTAssertEqual(Notification.Name.settingsStorageChanged.rawValue, "settingsStorageChanged")
        XCTAssertEqual(Notification.Name.openKeyPositionEditor.rawValue, "openKeyPositionEditor")
        XCTAssertEqual(Notification.Name.openSettingsWindow.rawValue, "openSettingsWindow")
        XCTAssertEqual(Notification.Name.permissionStatusChanged.rawValue, "permissionStatusChanged")
        XCTAssertEqual(Notification.Name.keyPositionsChanged.rawValue, "keyPositionsChanged")
        XCTAssertEqual(Notification.Name.keyWidthsChanged.rawValue, "keyWidthsChanged")
        XCTAssertEqual(Notification.Name.showGlowPreview.rawValue, "showGlowPreview")
        XCTAssertEqual(Notification.Name.hideGlowPreview.rawValue, "hideGlowPreview")
        XCTAssertEqual(Notification.Name.physicalKeyDown.rawValue, "physicalKeyDown")
        XCTAssertEqual(Notification.Name.physicalKeyUp.rawValue, "physicalKeyUp")
    }
}
