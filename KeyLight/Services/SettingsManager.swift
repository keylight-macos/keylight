import Foundation

enum ConfigurationSnapshotError: LocalizedError, Equatable {
    case invalidName
    case nameConflict(String)
    case snapshotNotFound
    case invalidDocument
    case unsupportedVersion(Int)
    case importTooLarge
    case persistentDataTooLarge
    case invalidConfiguration(String)
    case noPreviousSetup
    case transactionFailed

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return String(localized: "Choose a name up to 100 characters.")
        case .nameConflict(let name):
            return String(localized: "A snapshot named \"\(name)\" already exists.")
        case .snapshotNotFound:
            return String(localized: "The configuration snapshot could not be found.")
        case .invalidDocument:
            return String(localized: "The file is not a valid KeyLight configuration snapshot.")
        case .unsupportedVersion(let version):
            return String(localized: "Snapshot version \(version) is not supported by this build.")
        case .importTooLarge:
            return String(localized: "The snapshot file is too large (maximum 1 MB).")
        case .persistentDataTooLarge:
            return String(localized: "The saved snapshot data is too large (maximum 500 KB).")
        case .invalidConfiguration(let reason):
            return reason
        case .noPreviousSetup:
            return String(localized: "There is no previous setup to restore.")
        case .transactionFailed:
            return String(localized: "The configuration could not be applied. Your previous setup was restored.")
        }
    }
}

enum ConfigurationSnapshotImportPolicy {
    case rejectConflict
    case replace
    case saveCopy
}

/// Manages persistent storage of all app settings
@MainActor
final class SettingsManager {
    typealias SnapshotCommitVerifier = (ConfigurationSnapshotPayload) -> Bool

    private let defaults: PreferencesStore
    private let launchAtLoginService: any LaunchAtLoginServicing
    private let snapshotCommitVerifier: SnapshotCommitVerifier
    private static let defaultExperienceSeedVersion = 1
    private static let defaultLayoutMigrationVersion = 1
    private static let bundledLayoutProfilesSeedVersion = 1
    private static let stableSelectionMigrationVersion = 1
    static let currentOnboardingVersion = 1
    private static let defaultSeededLayoutPresetID = "macbook-air-13-m4-default"
    private static let bundledMacBookProPresetID = "macbook-pro-14-m4"
    private static let defaultSeededLayoutName = "MacBook Air 13 M4 Default"
    private static let invalidLayoutProfileMessage = String(
        localized: "The file is not a valid KeyLight layout profile."
    )
    private static let defaultSolidHex = "68B8FF"
    private static let defaultGradientEndHex = "00E69A"
    private static let maxGradientPresetCount = 24
    static let maximumConfigurationSnapshotImportSize =
        PersistenceValidation.maximumLayoutImportSize
    static let maximumConfigurationSnapshotPersistentSize = 500_000

    // Keys for UserDefaults
    private enum Keys {
        static let isEnabled = "isEnabled"
        static let hasSeenPermissionExplanation = "hasSeenPermissionExplanation"
        static let glowColorHex = "glowColorHex"
        static let glowOpacity = "glowOpacity"
        static let physicalRefractionStrength = "physicalRefractionStrength"
        static let glowSize = "glowSize"
        static let glowWidth = "glowWidth"
        static let glowRoundness = "glowRoundness"
        static let glowFullness = "glowFullness"
        static let fadeDuration = "fadeDuration"
        static let fadeDurationDefaultMigratedV2 = "fadeDurationDefaultMigratedV2"
        static let launchAtLogin = "launchAtLogin"
        static let colorMode = "colorMode"
        static let effectStyle = "effectStyle"
        static let chordSurfaceStyle = "chordSurfaceStyle"
        static let chordIntensityMultiplier = "chordIntensityMultiplier"
        static let powerSavingMode = "powerSavingMode"
        static let effectConfigurationsByStyle =
            "effectConfigurationsByStyleV1"
        static let surfaceShapeProfile = "surfaceShapeProfile"
        static let savedThemes = "savedThemes"
        static let currentThemeName = "currentThemeName"
        static let activeThemeID = "activeThemeID"
        static let keyMappingProfiles = "keyMappingProfiles"
        static let currentKeyMappingProfileName = "currentKeyMappingProfileName"
        static let activeLayoutID = "activeLayoutID"
        static let overlayDisplaySelection = "overlayDisplaySelection"
        static let mirroredDisplayIDs = "mirroredDisplayIDs"
        static let displayLayoutProfileBindings = "displayLayoutProfileBindings"
        static let globalShortcut = "globalShortcut"
        static let gradientStartHex = "gradientStartHex"
        static let gradientEndHex = "gradientEndHex"
        static let gradientPresets = "gradientPresets"
        static let defaultExperienceSeedVersion = "defaultExperienceSeedVersion"
        static let defaultLayoutMigrationVersion = "defaultLayoutMigrationVersion"
        static let bundledLayoutProfilesSeedVersion = "bundledLayoutProfilesSeedVersion"
        static let stableSelectionMigrationVersion = "stableSelectionMigrationVersion"
        static let onboardingCompletedVersion = "onboardingCompletedVersion"
        static let onboardingDeferredVersion = "onboardingDeferredVersion"
        static let configurationSnapshots = "configurationSnapshotsV1"
        static let configurationSnapshotRecovery =
            "configurationSnapshotRecoveryV1"
    }

    private static let managedLocalPreferenceKeys: [String] = [
        Keys.isEnabled,
        Keys.hasSeenPermissionExplanation,
        Keys.glowColorHex,
        Keys.glowOpacity,
        Keys.physicalRefractionStrength,
        Keys.glowSize,
        Keys.glowWidth,
        Keys.glowRoundness,
        Keys.glowFullness,
        Keys.fadeDuration,
        Keys.fadeDurationDefaultMigratedV2,
        Keys.launchAtLogin,
        Keys.colorMode,
        Keys.effectStyle,
        Keys.chordSurfaceStyle,
        Keys.chordIntensityMultiplier,
        Keys.powerSavingMode,
        Keys.effectConfigurationsByStyle,
        Keys.surfaceShapeProfile,
        Keys.savedThemes,
        Keys.currentThemeName,
        Keys.activeThemeID,
        Keys.keyMappingProfiles,
        Keys.currentKeyMappingProfileName,
        Keys.activeLayoutID,
        Keys.overlayDisplaySelection,
        Keys.mirroredDisplayIDs,
        Keys.displayLayoutProfileBindings,
        Keys.globalShortcut,
        Keys.gradientStartHex,
        Keys.gradientEndHex,
        Keys.gradientPresets,
        Keys.defaultExperienceSeedVersion,
        Keys.defaultLayoutMigrationVersion,
        Keys.bundledLayoutProfilesSeedVersion,
        Keys.stableSelectionMigrationVersion,
        Keys.onboardingCompletedVersion,
        Keys.onboardingDeferredVersion,
        Keys.configurationSnapshots,
        Keys.configurationSnapshotRecovery,
        KeyLayoutStore.offsetsKey,
        "KeyWidthOverrides"
    ]

    /// The only persisted keys a snapshot application transaction may touch.
    /// Keeping this registry separate from all managed preferences makes the
    /// exclusions auditable and prevents imported JSON from becoming keys.
    private static let configurationSnapshotStorageKeyRegistry: [String] = [
        Keys.glowColorHex,
        Keys.glowOpacity,
        Keys.physicalRefractionStrength,
        Keys.glowSize,
        Keys.glowWidth,
        Keys.glowRoundness,
        Keys.glowFullness,
        Keys.fadeDuration,
        Keys.colorMode,
        Keys.effectStyle,
        Keys.chordSurfaceStyle,
        Keys.chordIntensityMultiplier,
        Keys.powerSavingMode,
        Keys.effectConfigurationsByStyle,
        Keys.surfaceShapeProfile,
        Keys.savedThemes,
        Keys.currentThemeName,
        Keys.activeThemeID,
        Keys.keyMappingProfiles,
        Keys.currentKeyMappingProfileName,
        Keys.activeLayoutID,
        Keys.overlayDisplaySelection,
        Keys.mirroredDisplayIDs,
        Keys.displayLayoutProfileBindings,
        Keys.globalShortcut,
        Keys.gradientStartHex,
        Keys.gradientEndHex,
        Keys.gradientPresets,
        KeyLayoutStore.offsetsKey,
        KeyLayoutStore.widthMultipliersKey
    ]

    #if DEBUG
    static let _testUserDefaultsKeyContract = managedLocalPreferenceKeys
    static let _testConfigurationSnapshotStorageKeyRegistry =
        configurationSnapshotStorageKeyRegistry
    static let _testConfigurationSnapshotPayloadKeyRegistry = Set(
        ConfigurationSnapshotPayload.CodingKeys.allCases.map(\.rawValue)
    )
    #endif

    init(
        preferencesStore: PreferencesStore = .standard,
        launchAtLoginService: any LaunchAtLoginServicing = LaunchAtLoginService(),
        snapshotCommitVerifier: @escaping SnapshotCommitVerifier = { _ in true }
    ) {
        defaults = preferencesStore
        self.launchAtLoginService = launchAtLoginService
        self.snapshotCommitVerifier = snapshotCommitVerifier
        // Determine whether this is a fresh install before any migration writes
        // a default value. Otherwise the migration-created fade-duration key
        // makes the first-run seed incorrectly look like existing user data.
        let wasFreshInstall = isFreshInstallForDefaultSeed
        seedDefaultExperienceIfNeeded()
        migrateFadeDurationDefaultIfNeeded()
        initializeEffectConfigurationsIfNeeded()
        applyDefaultLayoutIfMissingOnce()
        seedBundledLayoutProfilesIfNeededOnce()
        migrateStableSelectionIDsIfNeeded()
        initializeOnboardingState(wasFreshInstall: wasFreshInstall)
    }

    /// Sanitize a hex color string: keep only valid hex characters, pad to 6 chars with zeros
    private func sanitizedHex(_ hex: String) -> String {
        let valid = hex.prefix(6).filter { "0123456789ABCDEFabcdef".contains($0) }
        if valid.isEmpty { return Self.defaultSolidHex }
        // Pad short strings (e.g. "FF00" → "FF0000") so Color(hex:) always receives 6 chars
        return String(valid).padding(toLength: 6, withPad: "0", startingAt: 0)
    }

    /// Clamp a value to a range, returning the default if value is NaN or infinity
    private func validated(_ value: Double, range: ClosedRange<Double>, default defaultValue: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// One-time migration: treat legacy default-ish fade duration as "unset" and move to new default (1.0s).
    private func migrateFadeDurationDefaultIfNeeded() {
        guard !defaults.bool(forKey: Keys.fadeDurationDefaultMigratedV2) else { return }
        defer { defaults.set(true, forKey: Keys.fadeDurationDefaultMigratedV2) }

        guard let raw = defaults.object(forKey: Keys.fadeDuration) else {
            defaults.set(1.0, forKey: Keys.fadeDuration)
            return
        }

        let value: Double?
        if let doubleValue = raw as? Double {
            value = doubleValue
        } else if let number = raw as? NSNumber {
            value = number.doubleValue
        } else {
            value = nil
        }

        if let v = value, abs(v - 0.35) < 0.0001 {
            defaults.set(1.0, forKey: Keys.fadeDuration)
        }
    }

    // MARK: - Basic Settings

    var isEnabled: Bool {
        get { defaults.object(forKey: Keys.isEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.isEnabled) }
    }

    var hasSeenPermissionExplanation: Bool {
        get { defaults.object(forKey: Keys.hasSeenPermissionExplanation) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.hasSeenPermissionExplanation) }
    }

    var shouldPresentOnboarding: Bool {
        defaults.integer(forKey: Keys.onboardingCompletedVersion)
            < Self.currentOnboardingVersion
            && defaults.integer(forKey: Keys.onboardingDeferredVersion)
                < Self.currentOnboardingVersion
    }

    func completeOnboarding() {
        defaults.set(
            Self.currentOnboardingVersion,
            forKey: Keys.onboardingCompletedVersion
        )
        defaults.removeObject(forKey: Keys.onboardingDeferredVersion)
    }

    func deferOnboarding() {
        defaults.set(
            Self.currentOnboardingVersion,
            forKey: Keys.onboardingDeferredVersion
        )
    }

    var glowColorHex: String {
        get { defaults.string(forKey: Keys.glowColorHex) ?? Self.defaultSolidHex }
        set { defaults.set(newValue, forKey: Keys.glowColorHex) }
    }

    var glowOpacity: Double {
        get { validated(defaults.object(forKey: Keys.glowOpacity) as? Double ?? 0.8013, range: 0.0...1.0, default: 0.8013) }
        set { defaults.set(newValue, forKey: Keys.glowOpacity) }
    }

    var physicalRefractionStrength: Double {
        get {
            validated(
                defaults.object(
                    forKey: Keys.physicalRefractionStrength
                ) as? Double ?? 1.0,
                range: 0.5...2.5,
                default: 1.0
            )
        }
        set { defaults.set(newValue, forKey: Keys.physicalRefractionStrength) }
    }

    var glowSize: Double {
        get { validated(defaults.object(forKey: Keys.glowSize) as? Double ?? 80.5536, range: 4.0...200.0, default: 80.5536) }
        set { defaults.set(newValue, forKey: Keys.glowSize) }
    }

    var glowWidth: Double {
        get { validated(defaults.object(forKey: Keys.glowWidth) as? Double ?? 1.0, range: 0.1...5.0, default: 1.0) }
        set { defaults.set(newValue, forKey: Keys.glowWidth) }
    }

    var glowRoundness: Double {
        get { validated(defaults.object(forKey: Keys.glowRoundness) as? Double ?? 0.7069, range: 0.0...1.0, default: 0.7069) }
        set { defaults.set(newValue, forKey: Keys.glowRoundness) }
    }

    var glowFullness: Double {
        get { validated(defaults.object(forKey: Keys.glowFullness) as? Double ?? 0.6046, range: 0.0...1.0, default: 0.6046) }
        set { defaults.set(newValue, forKey: Keys.glowFullness) }
    }

    var fadeDuration: Double {
        get { validated(defaults.object(forKey: Keys.fadeDuration) as? Double ?? 1.0004, range: 0.05...5.0, default: 1.0004) }
        set { defaults.set(newValue, forKey: Keys.fadeDuration) }
    }

    var gradientStartHex: String {
        get { defaults.string(forKey: Keys.gradientStartHex) ?? Self.defaultSolidHex }
        set { defaults.set(newValue, forKey: Keys.gradientStartHex) }
    }

    var gradientEndHex: String {
        get { defaults.string(forKey: Keys.gradientEndHex) ?? Self.defaultGradientEndHex }
        set { defaults.set(newValue, forKey: Keys.gradientEndHex) }
    }

    // MARK: - Launch at Login

    var launchAtLogin: Bool {
        get {
            guard defaults.usesSystemPreferences else {
                return defaults.bool(forKey: Keys.launchAtLogin)
            }

            let enabled = launchAtLoginService.status.isEnabled
            defaults.set(enabled, forKey: Keys.launchAtLogin)
            return enabled
        }
        set {
            setLaunchAtLogin(newValue)
        }
    }

    /// Applies a launch-at-login request and returns the system result for
    /// coordinators that need to distinguish approval from operation failure.
    /// The legacy preference mirrors only the authoritative resulting state.
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> LaunchAtLoginChangeResult {
        guard defaults.usesSystemPreferences else {
            defaults.set(enabled, forKey: Keys.launchAtLogin)
            return LaunchAtLoginChangeResult(
                requestedEnabled: enabled,
                status: enabled ? .enabled : .disabled,
                outcome: .applied
            )
        }

        let result = launchAtLoginService.setEnabled(enabled)
        defaults.set(result.status.isEnabled, forKey: Keys.launchAtLogin)

        if case .failed = result.outcome {
            KeyLightLogger.storage.error("Launch-at-login change failed")
        }
        return result
    }

    // MARK: - Color Mode

    var colorMode: ColorMode {
        get {
            guard let rawValue = defaults.string(forKey: Keys.colorMode) else {
                return .positionGradient
            }
            if rawValue == "gradient" {
                return .positionGradient
            }
            return ColorMode(rawValue: rawValue) ?? .positionGradient
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.colorMode) }
    }

    var effectStyle: EffectStyle {
        get {
            guard let rawValue = defaults.string(forKey: Keys.effectStyle) else {
                return .classicGlow
            }
            let parsed = EffectStyle(rawValue: rawValue) ?? .classicGlow
            let supported = parsed.supportedStyle
            if supported.rawValue != rawValue {
                defaults.set(supported.rawValue, forKey: Keys.effectStyle)
            }
            return supported
        }
        set {
            defaults.set(
                newValue.supportedStyle.rawValue,
                forKey: Keys.effectStyle
            )
        }
    }

    var chordAppearance: ChordAppearance {
        get {
            ChordAppearance(
                style: defaults.string(forKey: Keys.chordSurfaceStyle)
                    .flatMap(ChordSurfaceStyle.init(rawValue:))
                    ?? .naturalMerge,
                intensityMultiplier: validated(
                    defaults.object(forKey: Keys.chordIntensityMultiplier)
                        as? Double ?? 1,
                    range: ChordAppearance.intensityRange,
                    default: 1
                )
            )
        }
        set {
            let normalized = newValue.normalized
            defaults.set(
                normalized.style.rawValue,
                forKey: Keys.chordSurfaceStyle
            )
            defaults.set(
                normalized.intensityMultiplier,
                forKey: Keys.chordIntensityMultiplier
            )
        }
    }

    var powerSavingMode: PowerSavingMode {
        get {
            defaults.string(forKey: Keys.powerSavingMode)
                .flatMap(PowerSavingMode.init(rawValue:))
                ?? .automatic
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.powerSavingMode)
        }
    }

    var surfaceShapeProfile: SurfaceShapeProfile {
        get {
            guard let rawValue = defaults.string(forKey: Keys.surfaceShapeProfile) else {
                return .currentWave
            }
            return SurfaceShapeProfile.persistedValue(rawValue: rawValue)
                ?? .currentWave
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.surfaceShapeProfile) }
    }

    /// Compatibility-safe value snapshot over the existing color preference keys.
    var colorConfiguration: ColorConfiguration {
        get {
            ColorConfiguration(
                mode: colorMode,
                solidHex: glowColorHex,
                gradientStartHex: gradientStartHex,
                gradientEndHex: gradientEndHex
            )
        }
        set {
            colorMode = newValue.mode
            glowColorHex = newValue.solidHex
            gradientStartHex = newValue.gradientStartHex
            gradientEndHex = newValue.gradientEndHex
        }
    }

    /// Compatibility-safe value snapshot over the existing effect preference keys.
    var effectConfiguration: EffectConfiguration {
        get {
            validatedEffectConfiguration(EffectConfiguration(
                style: effectStyle,
                shapeProfile: surfaceShapeProfile,
                color: colorConfiguration,
                opacity: glowOpacity,
                refractionStrength: physicalRefractionStrength,
                height: glowSize,
                width: glowWidth,
                roundness: glowRoundness,
                hardness: glowFullness,
                fadeDuration: fadeDuration
            ), for: effectStyle)
        }
        set {
            let normalized = validatedEffectConfiguration(
                newValue,
                for: newValue.style
            )
            writeCurrentEffectConfiguration(normalized)
            setEffectConfiguration(normalized, for: normalized.style)
        }
    }

    /// Returns the independently persisted controls for one supported effect.
    /// Missing profiles receive a visible, route-appropriate default without
    /// borrowing the currently selected effect's sliders.
    func effectConfiguration(for requestedStyle: EffectStyle) -> EffectConfiguration {
        let style = requestedStyle.supportedStyle
        let profiles = loadEffectConfigurations()
        return profiles[style.rawValue]
            .map { validatedEffectConfiguration($0, for: style) }
            ?? .defaultConfiguration(for: style)
    }

    func setEffectConfiguration(
        _ configuration: EffectConfiguration,
        for requestedStyle: EffectStyle
    ) {
        let style = requestedStyle.supportedStyle
        var profiles = loadEffectConfigurations()
        profiles[style.rawValue] = validatedEffectConfiguration(
            configuration,
            for: style
        )
        persistEffectConfigurations(profiles)
    }

    private func initializeEffectConfigurationsIfNeeded() {
        let selectedStyle = effectStyle.supportedStyle
        var profiles = loadEffectConfigurations()

        // The established scalar keys remain the compatibility boundary for
        // older builds. Only on first migration are they authoritative for the
        // currently selected route; subsequent launches preserve every route's
        // independently saved profile.
        if profiles.isEmpty {
            profiles[selectedStyle.rawValue] = validatedEffectConfiguration(
                currentScalarEffectConfiguration(style: selectedStyle),
                for: selectedStyle
            )
        }

        for style in EffectStyle.allCases where profiles[style.rawValue] == nil {
            profiles[style.rawValue] = .defaultConfiguration(for: style)
        }

        persistEffectConfigurations(profiles)
        if let selected = profiles[selectedStyle.rawValue] {
            writeCurrentEffectConfiguration(selected)
        }
    }

    private func loadEffectConfigurations() -> [String: EffectConfiguration] {
        guard let data = defaults.data(
            forKey: Keys.effectConfigurationsByStyle
        ),
        data.count < Self.maxUserDefaultsDataSize,
        let decoded = try? JSONDecoder().decode(
            [String: EffectConfiguration].self,
            from: data
        ) else {
            return [:]
        }

        var normalized: [String: EffectConfiguration] = [:]
        for (rawStyle, configuration) in decoded {
            let style = (
                EffectStyle(rawValue: rawStyle)
                    ?? configuration.style
            ).supportedStyle
            normalized[style.rawValue] = validatedEffectConfiguration(
                configuration,
                for: style
            )
        }
        return normalized
    }

    private func persistEffectConfigurations(
        _ profiles: [String: EffectConfiguration]
    ) {
        let supportedProfiles = Dictionary(uniqueKeysWithValues:
            EffectStyle.allCases.map { style in
                let configuration = profiles[style.rawValue]
                    ?? .defaultConfiguration(for: style)
                return (
                    style.rawValue,
                    validatedEffectConfiguration(configuration, for: style)
                )
            }
        )
        do {
            defaults.set(
                try JSONEncoder().encode(supportedProfiles),
                forKey: Keys.effectConfigurationsByStyle
            )
        } catch {
            KeyLightLogger.storage.error(
                "Effect settings profiles could not be encoded"
            )
        }
    }

    private func currentScalarEffectConfiguration(
        style: EffectStyle
    ) -> EffectConfiguration {
        EffectConfiguration(
            style: style.supportedStyle,
            shapeProfile: surfaceShapeProfile,
            color: colorConfiguration,
            opacity: glowOpacity,
            refractionStrength: physicalRefractionStrength,
            height: glowSize,
            width: glowWidth,
            roundness: glowRoundness,
            hardness: glowFullness,
            fadeDuration: fadeDuration
        )
    }

    private func writeCurrentEffectConfiguration(
        _ configuration: EffectConfiguration
    ) {
        let normalized = validatedEffectConfiguration(
            configuration,
            for: configuration.style
        )
        effectStyle = normalized.style
        surfaceShapeProfile = normalized.shapeProfile
        colorConfiguration = normalized.color
        glowOpacity = normalized.opacity
        physicalRefractionStrength = normalized.refractionStrength
        glowSize = normalized.height
        glowWidth = normalized.width
        glowRoundness = normalized.roundness
        glowFullness = normalized.hardness
        fadeDuration = normalized.fadeDuration
    }

    private func validatedEffectConfiguration(
        _ configuration: EffectConfiguration,
        for requestedStyle: EffectStyle
    ) -> EffectConfiguration {
        let style = requestedStyle.supportedStyle
        return EffectConfiguration(
            style: style,
            shapeProfile: .currentWave,
            color: ColorConfiguration(
                mode: configuration.color.mode,
                solidHex: sanitizedHex(configuration.color.solidHex),
                gradientStartHex: sanitizedHex(
                    configuration.color.gradientStartHex
                ),
                gradientEndHex: sanitizedHex(
                    configuration.color.gradientEndHex
                )
            ),
            opacity: style == .solidBlack
                ? 1.0
                : validated(
                    configuration.opacity,
                    range: 0.0...1.0,
                    default: 0.8013
                ),
            refractionStrength: validated(
                configuration.refractionStrength,
                range: 0.5...2.5,
                default: 1.0
            ),
            height: validated(
                configuration.height,
                range: 4.0...200.0,
                default: 80.5536
            ),
            width: validated(
                configuration.width,
                range: 0.1...5.0,
                default: 1.0
            ),
            roundness: validated(
                configuration.roundness,
                range: 0.0...1.0,
                default: 0.7069
            ),
            hardness: validated(
                configuration.hardness,
                range: 0.0...1.0,
                default: 0.6046
            ),
            fadeDuration: validated(
                configuration.fadeDuration,
                range: 0.05...5.0,
                default: 1.0004
            )
        )
    }

    /// A read-only value snapshot. Launch-at-login writes continue through the
    /// established setter because they also reconcile the system login item.
    var appPreferences: AppPreferences {
        AppPreferences(
            isEnabled: isEnabled,
            launchAtLogin: launchAtLogin,
            effect: effectConfiguration,
            chordAppearance: chordAppearance,
            powerSavingMode: powerSavingMode
        )
    }

    // MARK: - Themes

    /// Maximum data size for UserDefaults JSON reads (guards against injection from other processes)
    private static let maxUserDefaultsDataSize = 500_000  // 500KB

    private static func recordIndicesNeedingStableIDRepair(_ data: Data) -> Set<Int>? {
        guard let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        return Set(records.indices.filter { index in
            guard let rawID = records[index]["id"] as? String else { return true }
            return UUID(uuidString: rawID) == nil
        })
    }

    var savedThemes: [Theme] {
        get {
            loadStoredThemes() ?? [Theme.defaultTheme]
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                defaults.set(data, forKey: Keys.savedThemes)
            } catch {
                KeyLightLogger.storage.error("Saved themes could not be encoded")
            }
        }
    }

    private func loadStoredThemes() -> [Theme]? {
        guard let data = defaults.data(forKey: Keys.savedThemes),
              data.count < Self.maxUserDefaultsDataSize,
              var themes = try? JSONDecoder().decode([Theme].self, from: data) else {
            return nil
        }
        if let repairIndices = Self.recordIndicesNeedingStableIDRepair(data), !repairIndices.isEmpty {
            themes = persistRepairedThemes(themes, repairIndices: repairIndices)
        }
        return themes
    }

    var currentThemeName: String {
        get { defaults.string(forKey: Keys.currentThemeName) ?? Theme.defaultTheme.name }
        set {
            defaults.set(newValue, forKey: Keys.currentThemeName)
            if let theme = savedThemes.first(where: { $0.name == newValue }) {
                writeSelectionID(theme.id, forKey: Keys.activeThemeID)
            } else {
                writeSelectionID(nil, forKey: Keys.activeThemeID)
            }
        }
    }

    var activeThemeID: UUID? {
        get {
            let themes = savedThemes
            guard let id = selectionID(forKey: Keys.activeThemeID),
                  themes.contains(where: { $0.id == id }) else {
                return nil
            }
            return id
        }
        set {
            let selection = newValue.flatMap { id in savedThemes.first(where: { $0.id == id }) }
            persistThemeSelection(selection)
        }
    }

    var currentKeyMappingProfileName: String {
        get { defaults.string(forKey: Keys.currentKeyMappingProfileName) ?? "None" }
        set {
            defaults.set(newValue, forKey: Keys.currentKeyMappingProfileName)
            if let profile = savedKeyMappingProfiles.first(where: { $0.name == newValue }) {
                writeSelectionID(profile.id, forKey: Keys.activeLayoutID)
            } else {
                writeSelectionID(nil, forKey: Keys.activeLayoutID)
            }
        }
    }

    var activeLayoutID: UUID? {
        get {
            let profiles = savedKeyMappingProfiles
            guard let id = selectionID(forKey: Keys.activeLayoutID),
                  profiles.contains(where: { $0.id == id }) else {
                return nil
            }
            return id
        }
        set {
            let selection = newValue.flatMap { id in savedKeyMappingProfiles.first(where: { $0.id == id }) }
            persistLayoutSelection(selection)
        }
    }

    var overlayDisplaySelection: OverlayDisplaySelection {
        get { OverlayDisplaySelection(persistedValue: defaults.string(forKey: Keys.overlayDisplaySelection)) }
        set { defaults.set(newValue.persistedValue, forKey: Keys.overlayDisplaySelection) }
    }

    var mirroredDisplayIDs: Set<String> {
        get {
            let stored = defaults.object(forKey: Keys.mirroredDisplayIDs)
                as? [String] ?? []
            return Set(stored.compactMap { value in
                let trimmed = value.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !trimmed.isEmpty, trimmed.count <= 200 else {
                    return nil
                }
                return trimmed
            }.prefix(16))
        }
        set {
            let normalized = newValue.compactMap { value -> String? in
                let trimmed = value.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                return !trimmed.isEmpty && trimmed.count <= 200
                    ? trimmed
                    : nil
            }
                .sorted()
                .prefix(16)
            defaults.set(Array(normalized), forKey: Keys.mirroredDisplayIDs)
        }
    }

    var globalShortcut: GlobalShortcut {
        get {
            guard let data = defaults.data(forKey: Keys.globalShortcut),
                  data.count < 1_024,
                  let decoded = try? JSONDecoder().decode(GlobalShortcut.self, from: data),
                  let validated = GlobalShortcut(
                    keyCode: decoded.keyCode,
                    modifiers: decoded.modifiers
                  ) else {
                return .default
            }
            return validated
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.globalShortcut)
        }
    }

    var displayLayoutProfileBindings: [String: UUID] {
        get {
            guard let stored = defaults.dictionary(forKey: Keys.displayLayoutProfileBindings) else {
                return [:]
            }
            let validProfileIDs = Set(savedKeyMappingProfiles.map(\.id))
            var bindings: [String: UUID] = [:]
            for persistentDisplayID in stored.keys.sorted().prefix(32) {
                guard !persistentDisplayID.isEmpty,
                      persistentDisplayID.count <= 200,
                      let value = stored[persistentDisplayID] as? String,
                      let profileID = UUID(uuidString: value),
                      validProfileIDs.contains(profileID) else {
                    continue
                }
                bindings[persistentDisplayID] = profileID
            }
            return bindings
        }
        set {
            let validProfileIDs = Set(savedKeyMappingProfiles.map(\.id))
            var encoded: [String: String] = [:]
            for persistentDisplayID in newValue.keys.sorted().prefix(32) {
                guard !persistentDisplayID.isEmpty,
                      persistentDisplayID.count <= 200,
                      let profileID = newValue[persistentDisplayID],
                      validProfileIDs.contains(profileID) else {
                    continue
                }
                encoded[persistentDisplayID] = profileID.uuidString
            }
            if encoded.isEmpty {
                defaults.removeObject(forKey: Keys.displayLayoutProfileBindings)
            } else {
                defaults.set(encoded, forKey: Keys.displayLayoutProfileBindings)
            }
        }
    }

    func setLayoutProfileBinding(_ profileID: UUID?, forDisplay persistentDisplayID: String) {
        var bindings = displayLayoutProfileBindings
        bindings[persistentDisplayID] = profileID
        displayLayoutProfileBindings = bindings
    }

    private func selectionID(forKey key: String) -> UUID? {
        defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    private func writeSelectionID(_ id: UUID?, forKey key: String) {
        if let id {
            defaults.set(id.uuidString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func persistThemeSelection(_ theme: Theme?) {
        writeSelectionID(theme?.id, forKey: Keys.activeThemeID)
        defaults.set(theme?.name ?? Theme.defaultTheme.name, forKey: Keys.currentThemeName)
    }

    private func persistLayoutSelection(_ profile: KeyMappingProfile?) {
        writeSelectionID(profile?.id, forKey: Keys.activeLayoutID)
        defaults.set(profile?.name ?? "None", forKey: Keys.currentKeyMappingProfileName)
    }

    private func reconcileThemeSelection(in themes: [Theme]) {
        let storedThemeID = selectionID(forKey: Keys.activeThemeID)
        let legacyThemeName = defaults.string(forKey: Keys.currentThemeName) ?? Theme.defaultTheme.name
        let selectedTheme = storedThemeID.flatMap { id in themes.first(where: { $0.id == id }) }
            ?? themes.first(where: { $0.name == legacyThemeName })
            ?? themes.first
        persistThemeSelection(selectedTheme)
    }

    private func reconcileLayoutSelection(in profiles: [KeyMappingProfile]) {
        let storedLayoutID = selectionID(forKey: Keys.activeLayoutID)
        let legacyLayoutName = defaults.string(forKey: Keys.currentKeyMappingProfileName) ?? "None"
        let selectedProfile = storedLayoutID.flatMap { id in profiles.first(where: { $0.id == id }) }
            ?? profiles.first(where: { $0.name == legacyLayoutName })
            ?? profiles.first
        persistLayoutSelection(selectedProfile)
    }

    private func persistRepairedThemes(_ decodedThemes: [Theme], repairIndices: Set<Int>) -> [Theme] {
        var themes = decodedThemes
        let storedThemeID = selectionID(forKey: Keys.activeThemeID)
        let legacyThemeName = defaults.string(forKey: Keys.currentThemeName) ?? Theme.defaultTheme.name
        if let storedThemeID,
           !themes.contains(where: { $0.id == storedThemeID }),
           let selectedIndex = themes.firstIndex(where: { $0.name == legacyThemeName }),
           repairIndices.contains(selectedIndex) {
            // If a previous current build had already selected this legacy
            // record, keep that established identity when an older build strips
            // the UUID field. Other missing IDs use the deterministic fallback.
            themes[selectedIndex].id = storedThemeID
        }

        do {
            defaults.set(try JSONEncoder().encode(themes), forKey: Keys.savedThemes)
            reconcileThemeSelection(in: themes)
        } catch {
            KeyLightLogger.storage.error("Legacy theme identities could not be repaired")
        }
        return themes
    }

    private func persistRepairedLayoutProfiles(
        _ decodedProfiles: [KeyMappingProfile],
        repairIndices: Set<Int>
    ) -> [KeyMappingProfile] {
        var profiles = decodedProfiles
        let storedLayoutID = selectionID(forKey: Keys.activeLayoutID)
        let legacyLayoutName = defaults.string(forKey: Keys.currentKeyMappingProfileName) ?? "None"
        if let storedLayoutID,
           !profiles.contains(where: { $0.id == storedLayoutID }),
           let selectedIndex = profiles.firstIndex(where: { $0.name == legacyLayoutName }),
           repairIndices.contains(selectedIndex) {
            profiles[selectedIndex].id = storedLayoutID
        }

        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: Keys.keyMappingProfiles)
            reconcileLayoutSelection(in: profiles)
        } catch {
            KeyLightLogger.storage.error("Legacy layout identities could not be repaired")
        }
        return profiles
    }

    func saveTheme(_ theme: Theme) {
        var theme = theme
        guard let normalizedName = PersistenceValidation.normalizedName(theme.name) else { return }
        theme.name = normalizedName
        theme.colorHex = sanitizedHex(theme.colorHex)
        theme.opacity = validated(theme.opacity, range: 0.0...1.0, default: 0.8013)
        theme.refractionStrength = validated(
            theme.refractionStrength,
            range: 0.5...2.5,
            default: 1.0
        )
        theme.size = validated(theme.size, range: 4.0...200.0, default: 80.5536)
        theme.width = validated(theme.width, range: 0.1...5.0, default: 1.0)
        theme.glowRoundness = validated(theme.glowRoundness, range: 0.0...1.0, default: 0.7069)
        theme.glowFullness = validated(theme.glowFullness, range: 0.0...1.0, default: 0.6046)
        theme.fadeDuration = validated(theme.fadeDuration, range: 0.05...5.0, default: 1.0004)
        theme.effectStyle = (
            EffectStyle(rawValue: theme.effectStyle.rawValue) ?? .classicGlow
        ).supportedStyle
        theme.shapeProfile = .currentWave
        if let startHex = theme.gradientStartHex {
            theme.gradientStartHex = sanitizedHex(startHex)
        }
        if let endHex = theme.gradientEndHex {
            theme.gradientEndHex = sanitizedHex(endHex)
        }

        var themes = savedThemes
        if let index = themes.firstIndex(where: { $0.name == theme.name }) {
            theme.id = themes[index].id
            themes[index] = theme
        } else if let index = themes.firstIndex(where: { $0.id == theme.id }) {
            let lowercasedName = theme.name.lowercased()
            guard !themes.contains(where: { $0.id != theme.id && $0.name.lowercased() == lowercasedName }) else {
                return
            }
            themes[index] = theme
        } else {
            themes.append(theme)
        }
        savedThemes = themes
        if activeThemeID == theme.id || currentThemeName == theme.name {
            persistThemeSelection(theme)
        }
    }

    func deleteTheme(named name: String) {
        var themes = savedThemes
        let removedIDs = Set(themes.filter { $0.name == name }.map(\.id))
        let storedActiveID = selectionID(forKey: Keys.activeThemeID)
        let wasActive = currentThemeName == name || storedActiveID.map(removedIDs.contains) == true
        themes.removeAll { $0.name == name }
        if themes.isEmpty {
            themes = [Theme.defaultTheme]
        }
        savedThemes = themes

        if wasActive {
            persistThemeSelection(themes.first)
        }
    }

    func restoreTheme(_ theme: Theme, at index: Int, makeCurrent: Bool) {
        var themes = savedThemes
        themes.removeAll { $0.id == theme.id }
        let safeIndex = min(max(index, 0), themes.count)
        themes.insert(theme, at: safeIndex)
        savedThemes = themes
        if makeCurrent {
            persistThemeSelection(theme)
        }
    }

    @discardableResult
    func renameTheme(from oldName: String, to newName: String) -> Bool {
        var themes = savedThemes
        guard let index = themes.firstIndex(where: { $0.name == oldName }) else { return false }
        guard let trimmed = PersistenceValidation.normalizedName(newName) else { return false }
        let oldNameLower = oldName.lowercased()
        let trimmedLower = trimmed.lowercased()
        let hasCollision = themes.contains { theme in
            theme.name.lowercased() == trimmedLower && theme.name.lowercased() != oldNameLower
        }
        guard !hasCollision else { return false }

        let renamedThemeID = themes[index].id
        let wasActive = selectionID(forKey: Keys.activeThemeID) == renamedThemeID || currentThemeName == oldName
        themes[index].name = trimmed
        savedThemes = themes
        if wasActive {
            persistThemeSelection(themes[index])
        }
        return true
    }

    func exportThemeString(_ theme: Theme) -> String? {
        ThemeStringCodec.encode(theme)
    }

    func importThemeString(_ value: String) throws -> Theme {
        try ThemeStringCodec.decode(value)
    }

    // MARK: - Gradient Presets

    static let defaultGradientPresets: [GradientPreset] = [
        GradientPreset(startHex: defaultSolidHex, endHex: defaultGradientEndHex, name: "Ocean"),
        GradientPreset(startHex: "C77DFF", endHex: "FF6B9D", name: "Neon"),
        GradientPreset(startHex: "FF6B6B", endHex: "FFD93D", name: "Sunset"),
        GradientPreset(startHex: "00D2FF", endHex: "C77DFF", name: "Sky"),
        GradientPreset(startHex: "FF6B6B", endHex: "3399FF", name: "Fire-Ice")
    ]

    var savedGradientPresets: [GradientPreset] {
        get {
            guard let data = defaults.data(forKey: Keys.gradientPresets),
                  data.count < Self.maxUserDefaultsDataSize,
                  let presets = try? JSONDecoder().decode([GradientPreset].self, from: data) else {
                return Self.defaultGradientPresets
            }
            return presets
        }
        set {
            let sanitized = Array(newValue.prefix(Self.maxGradientPresetCount)).map { preset in
                GradientPreset(
                    id: preset.id,
                    startHex: sanitizedHex(preset.startHex),
                    endHex: sanitizedHex(preset.endHex),
                    name: preset.name.map { String($0.prefix(40)) }
                )
            }
            do {
                let data = try JSONEncoder().encode(sanitized)
                defaults.set(data, forKey: Keys.gradientPresets)
            } catch {
                KeyLightLogger.storage.error("Gradient presets could not be encoded")
            }
        }
    }

    func saveGradientPreset(startHex: String, endHex: String, name: String? = nil) {
        let start = sanitizedHex(startHex)
        let end = sanitizedHex(endHex)
        var presets = savedGradientPresets
        if let index = presets.firstIndex(where: { $0.startHex == start && $0.endHex == end }) {
            // Move existing preset to the front
            let existing = presets.remove(at: index)
            presets.insert(existing, at: 0)
        } else {
            let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            presets.insert(
                GradientPreset(startHex: start, endHex: end, name: trimmedName?.isEmpty == false ? trimmedName : nil),
                at: 0
            )
            if presets.count > Self.maxGradientPresetCount {
                presets = Array(presets.prefix(Self.maxGradientPresetCount))
            }
        }
        savedGradientPresets = presets
    }

    func deleteGradientPreset(id: UUID) {
        var presets = savedGradientPresets
        presets.removeAll { $0.id == id }
        if presets.isEmpty {
            presets = Self.defaultGradientPresets
        }
        savedGradientPresets = presets
    }

    // MARK: - Bundled Variant Presets

    struct BundledLayoutPreset: Codable, Identifiable, Hashable {
        let id: String
        let variantId: String
        let displayName: String
        let resourcePath: String
    }

    private struct BundledLayoutPresetManifest: Codable {
        let version: Int
        let presets: [BundledLayoutPreset]
    }

    func bundledLayoutPresets() -> [BundledLayoutPreset] {
        guard let manifestData = bundledPresetData(resourcePath: "variant-presets-manifest.json"),
              let manifest = try? JSONDecoder().decode(BundledLayoutPresetManifest.self, from: manifestData) else {
            return []
        }

        guard manifest.version == 1 else {
            KeyLightLogger.imports.warning("Bundled layout manifest version is unsupported")
            return []
        }

        return manifest.presets.filter { preset in
            !preset.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !preset.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !preset.resourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func importBundledLayoutPreset(_ preset: BundledLayoutPreset, forcedName: String? = nil) throws -> KeyMappingProfile {
        let data = try loadBundledPresetData(resourcePath: preset.resourcePath)
        var profile = try importLayoutProfileData(data)
        if let preferredName = PersistenceValidation.normalizedName(forcedName ?? preset.displayName) {
            profile.name = preferredName
        }
        return profile
    }

    private func bundledPresetData(resourcePath: String) -> Data? {
        try? loadBundledPresetData(resourcePath: resourcePath)
    }

    private func loadBundledPresetData(resourcePath: String) throws -> Data {
        let normalizedPath = resourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty,
              !normalizedPath.hasPrefix("/"),
              !normalizedPath.contains("..") else {
            throw NSError(domain: "KeyLight", code: 24, userInfo: [
                NSLocalizedDescriptionKey: Self.invalidLayoutProfileMessage
            ])
        }

        guard let baseURL = Bundle.main.resourceURL?.appendingPathComponent("VariantPresets", isDirectory: true) else {
            throw NSError(domain: "KeyLight", code: 24, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Bundled presets are unavailable in this build.")
            ])
        }

        let url = baseURL.appendingPathComponent(normalizedPath)
        do {
            return try Data(contentsOf: url)
        } catch {
            #if DEBUG
            let sourceFallbackBase = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Services
                .deletingLastPathComponent() // KeyLight
                .appendingPathComponent("KeyLight/Resources/VariantPresets", isDirectory: true)
            let fallbackURL = sourceFallbackBase.appendingPathComponent(normalizedPath)
            if let fallbackData = try? Data(contentsOf: fallbackURL) {
                return fallbackData
            }
            #endif
            throw NSError(domain: "KeyLight", code: 24, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Bundled preset file not found: \(normalizedPath).")
            ])
        }
    }

    // MARK: - Key Mapping Profiles

    var savedKeyMappingProfiles: [KeyMappingProfile] {
        get {
            loadStoredLayoutProfiles() ?? []
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                defaults.set(data, forKey: Keys.keyMappingProfiles)
            } catch {
                KeyLightLogger.storage.error("Saved layouts could not be encoded")
            }
        }
    }

    private func loadStoredLayoutProfiles() -> [KeyMappingProfile]? {
        guard let data = defaults.data(forKey: Keys.keyMappingProfiles),
              data.count < Self.maxUserDefaultsDataSize,
              var profiles = try? JSONDecoder().decode([KeyMappingProfile].self, from: data) else {
            return nil
        }
        if let repairIndices = Self.recordIndicesNeedingStableIDRepair(data), !repairIndices.isEmpty {
            profiles = persistRepairedLayoutProfiles(profiles, repairIndices: repairIndices)
        }
        return profiles
    }

    @discardableResult
    func saveKeyMappingProfile(_ profile: KeyMappingProfile) -> KeyMappingProfile? {
        guard let normalizedName = PersistenceValidation.normalizedName(profile.name) else { return nil }
        var profile = profile
        profile.name = normalizedName
        let normalizedLayout = KeyLayoutStore.normalized(KeyLayout(
            offsets: profile.keyOffsets,
            widthMultipliers: profile.keyWidthOverrides
        ))
        profile.keyOffsets = normalizedLayout.offsets
        profile.keyWidthOverrides = normalizedLayout.widthMultipliers
        var profiles = savedKeyMappingProfiles
        if let index = profiles.firstIndex(where: { $0.name == profile.name }) {
            profile.id = profiles[index].id
            profiles[index] = profile
        } else if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            let lowercasedName = profile.name.lowercased()
            guard !profiles.contains(where: { $0.id != profile.id && $0.name.lowercased() == lowercasedName }) else {
                return nil
            }
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        savedKeyMappingProfiles = profiles
        persistLayoutSelection(profile)
        return profile
    }

    func deleteKeyMappingProfile(named name: String) {
        var profiles = savedKeyMappingProfiles
        let removedIDs = Set(profiles.filter { $0.name == name }.map(\.id))
        let storedActiveID = selectionID(forKey: Keys.activeLayoutID)
        let wasActive = currentKeyMappingProfileName == name || storedActiveID.map(removedIDs.contains) == true
        profiles.removeAll { $0.name == name }
        savedKeyMappingProfiles = profiles
        if wasActive {
            persistLayoutSelection(profiles.first)
        }
    }

    func restoreKeyMappingProfile(_ profile: KeyMappingProfile, at index: Int, makeCurrent: Bool) {
        var profiles = savedKeyMappingProfiles
        profiles.removeAll { $0.id == profile.id }
        let safeIndex = min(max(index, 0), profiles.count)
        profiles.insert(profile, at: safeIndex)
        savedKeyMappingProfiles = profiles
        if makeCurrent {
            persistLayoutSelection(profile)
        }
    }

    @discardableResult
    func renameKeyMappingProfile(from oldName: String, to newName: String) -> Bool {
        var profiles = savedKeyMappingProfiles
        guard let index = profiles.firstIndex(where: { $0.name == oldName }) else { return false }
        guard let trimmed = PersistenceValidation.normalizedName(newName) else { return false }
        let oldNameLower = oldName.lowercased()
        let trimmedLower = trimmed.lowercased()
        let hasCollision = profiles.contains { profile in
            profile.name.lowercased() == trimmedLower && profile.name.lowercased() != oldNameLower
        }
        guard !hasCollision else { return false }

        let renamedProfileID = profiles[index].id
        let wasActive = selectionID(forKey: Keys.activeLayoutID) == renamedProfileID || currentKeyMappingProfileName == oldName
        profiles[index].name = trimmed
        savedKeyMappingProfiles = profiles
        if wasActive {
            persistLayoutSelection(profiles[index])
        }
        return true
    }

    func exportLayoutProfileData(_ profile: KeyMappingProfile) -> Data? {
        LayoutProfileCodec.encode(profile)
    }

    func importLayoutProfileData(_ data: Data) throws -> KeyMappingProfile {
        try LayoutProfileCodec.decode(data)
    }

    /// Adds stable selection identities once by matching the established legacy
    /// names. Both forms remain persisted so older KeyLight builds continue to
    /// understand the active selections.
    private func migrateStableSelectionIDsIfNeeded() {
        // Always decode both collections. Their load paths repair any records
        // whose UUID field was stripped after the one-time migration ran.
        // Keep corrupt/oversized storage untouched, matching the legacy path.
        let themes: [Theme]?
        if defaults.data(forKey: Keys.savedThemes) == nil {
            themes = [Theme.defaultTheme]
        } else {
            themes = loadStoredThemes()
        }

        let profiles: [KeyMappingProfile]?
        if defaults.data(forKey: Keys.keyMappingProfiles) == nil {
            profiles = []
        } else {
            profiles = loadStoredLayoutProfiles()
        }

        guard defaults.integer(forKey: Keys.stableSelectionMigrationVersion) < Self.stableSelectionMigrationVersion else {
            return
        }

        if let themes {
            // Re-encoding upgrades legacy records that predate UUIDs without
            // changing the shape understood by current builds.
            savedThemes = themes
            reconcileThemeSelection(in: themes)
        }

        if let profiles {
            // Re-encoding likewise stabilizes any legacy profile UUIDs.
            savedKeyMappingProfiles = profiles
            reconcileLayoutSelection(in: profiles)
        }

        defaults.set(Self.stableSelectionMigrationVersion, forKey: Keys.stableSelectionMigrationVersion)
    }

    private func seedDefaultExperienceIfNeeded() {
        guard defaults.integer(forKey: Keys.defaultExperienceSeedVersion) < Self.defaultExperienceSeedVersion else {
            return
        }
        guard isFreshInstallForDefaultSeed else { return }

        do {
            let seededTheme = try importThemeString(ThemeStringCodec.defaultThemeString)
            savedThemes = [seededTheme]
            currentThemeName = seededTheme.name
            glowColorHex = seededTheme.colorHex
            glowOpacity = seededTheme.opacity
            physicalRefractionStrength = seededTheme.refractionStrength
            glowSize = seededTheme.size
            glowWidth = seededTheme.width
            glowRoundness = seededTheme.glowRoundness
            glowFullness = seededTheme.glowFullness
            fadeDuration = seededTheme.fadeDuration
            colorMode = seededTheme.colorMode
            effectStyle = seededTheme.effectStyle
            surfaceShapeProfile = seededTheme.shapeProfile
            gradientStartHex = seededTheme.gradientStartHex ?? Self.defaultSolidHex
            gradientEndHex = seededTheme.gradientEndHex ?? Self.defaultGradientEndHex
        } catch {
            KeyLightLogger.storage.error("Default theme could not be seeded")
            return
        }

        if let preset = bundledLayoutPresets().first(where: { $0.id == Self.defaultSeededLayoutPresetID }),
           let seededLayout = try? importBundledLayoutPreset(preset, forcedName: Self.defaultSeededLayoutName) {
            persistActiveLayoutProfile(seededLayout)
        }

        defaults.set(Self.defaultExperienceSeedVersion, forKey: Keys.defaultExperienceSeedVersion)
    }

    private func initializeOnboardingState(wasFreshInstall: Bool) {
        guard !wasFreshInstall,
              defaults.object(forKey: Keys.onboardingCompletedVersion) == nil,
              defaults.object(forKey: Keys.onboardingDeferredVersion) == nil else {
            return
        }
        // The new chooser must not replace an existing installation's selected
        // effect. Setup remains manually accessible from the menu.
        defaults.set(
            Self.currentOnboardingVersion,
            forKey: Keys.onboardingCompletedVersion
        )
    }

    /// One-time layout migration:
    /// Apply bundled default layout if and only if no layout profile/geometry exists yet.
    /// Never overwrite user-defined layout state.
    private func applyDefaultLayoutIfMissingOnce() {
        guard defaults.integer(forKey: Keys.defaultLayoutMigrationVersion) < Self.defaultLayoutMigrationVersion else {
            return
        }

        let profiles = savedKeyMappingProfiles
        let activeName = currentKeyMappingProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasValidActiveProfile = !activeName.isEmpty &&
            activeName != "None" &&
            profiles.contains(where: { $0.name == activeName })

        let hasSavedProfiles = !profiles.isEmpty
        let hasOffsetData = !(defaults.dictionary(forKey: KeyLayoutStore.offsetsKey) ?? [:]).isEmpty
        let hasWidthData = !(defaults.dictionary(forKey: "KeyWidthOverrides") ?? [:]).isEmpty
        let hasPersistedGeometry = hasOffsetData || hasWidthData

        let shouldApplyDefaultLayout = !hasValidActiveProfile && !hasSavedProfiles && !hasPersistedGeometry
        guard shouldApplyDefaultLayout else {
            // Existing layout state is present (or explicitly selected); keep user data untouched.
            defaults.set(Self.defaultLayoutMigrationVersion, forKey: Keys.defaultLayoutMigrationVersion)
            return
        }

        guard let preset = bundledLayoutPresets().first(where: { $0.id == Self.defaultSeededLayoutPresetID }),
              let seededLayout = try? importBundledLayoutPreset(preset, forcedName: Self.defaultSeededLayoutName) else {
            // Leave migration pending so it can retry next launch if bundled resources become available.
            return
        }

        persistActiveLayoutProfile(seededLayout)
        defaults.set(Self.defaultLayoutMigrationVersion, forKey: Keys.defaultLayoutMigrationVersion)
    }

    /// One-time seed to ensure bundled reference profiles are available in the Key Layout list.
    /// This appends missing bundled profiles without overriding user-customized profiles.
    private func seedBundledLayoutProfilesIfNeededOnce() {
        guard defaults.integer(forKey: Keys.bundledLayoutProfilesSeedVersion) < Self.bundledLayoutProfilesSeedVersion else {
            return
        }

        let presets = bundledLayoutPresets()
        guard !presets.isEmpty else {
            // Keep migration pending if bundled presets are unavailable.
            return
        }

        var profiles = savedKeyMappingProfiles
        var existingNames = Set(profiles.map { $0.name.lowercased() })
        var didChange = false

        let targetPresetIDs: [(id: String, forcedName: String?)] = [
            (Self.defaultSeededLayoutPresetID, Self.defaultSeededLayoutName),
            (Self.bundledMacBookProPresetID, nil)
        ]

        for target in targetPresetIDs {
            guard let preset = presets.first(where: { $0.id == target.id }) else { continue }
            let preferredName = (target.forcedName ?? preset.displayName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !preferredName.isEmpty else { continue }
            guard !existingNames.contains(preferredName.lowercased()) else { continue }

            guard let profile = try? importBundledLayoutPreset(preset, forcedName: preferredName) else { continue }
            profiles.append(profile)
            existingNames.insert(profile.name.lowercased())
            didChange = true
        }

        if didChange {
            savedKeyMappingProfiles = profiles
        }

        let activeName = currentKeyMappingProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasValidActive = !activeName.isEmpty &&
            activeName != "None" &&
            profiles.contains(where: { $0.name == activeName })
        if !hasValidActive {
            if profiles.contains(where: { $0.name == Self.defaultSeededLayoutName }) {
                currentKeyMappingProfileName = Self.defaultSeededLayoutName
            } else {
                currentKeyMappingProfileName = profiles.first?.name ?? "None"
            }
            didChange = true
        }

        defaults.set(Self.bundledLayoutProfilesSeedVersion, forKey: Keys.bundledLayoutProfilesSeedVersion)
    }

    private func persistActiveLayoutProfile(_ profile: KeyMappingProfile) {
        savedKeyMappingProfiles = [profile]
        persistLayoutSelection(profile)

        let offsets = profile.keyOffsets.reduce(into: [String: CGFloat]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
        defaults.set(offsets, forKey: KeyLayoutStore.offsetsKey)

        let widths = profile.keyWidthOverrides.reduce(into: [String: CGFloat]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
        defaults.set(widths, forKey: "KeyWidthOverrides")
    }

    private var isFreshInstallForDefaultSeed: Bool {
        let keysToCheck = [
            Keys.isEnabled,
            Keys.hasSeenPermissionExplanation,
            Keys.glowColorHex,
            Keys.glowOpacity,
            Keys.physicalRefractionStrength,
            Keys.glowSize,
            Keys.glowWidth,
            Keys.glowRoundness,
            Keys.glowFullness,
            Keys.fadeDuration,
            Keys.launchAtLogin,
            Keys.colorMode,
            Keys.effectStyle,
            Keys.chordSurfaceStyle,
            Keys.chordIntensityMultiplier,
            Keys.powerSavingMode,
            Keys.effectConfigurationsByStyle,
            Keys.surfaceShapeProfile,
            Keys.gradientStartHex,
            Keys.gradientEndHex,
            Keys.savedThemes,
            Keys.currentThemeName,
            Keys.activeThemeID,
            Keys.keyMappingProfiles,
            Keys.currentKeyMappingProfileName,
            Keys.activeLayoutID,
            Keys.overlayDisplaySelection,
            Keys.mirroredDisplayIDs,
            Keys.displayLayoutProfileBindings,
            Keys.globalShortcut,
            Keys.gradientPresets,
            KeyLayoutStore.offsetsKey,
            "KeyWidthOverrides"
        ]
        return keysToCheck.allSatisfy { defaults.object(forKey: $0) == nil }
    }

    // MARK: - Complete Configuration Snapshots

    var configurationSnapshots: [ConfigurationSnapshotDocument] {
        loadConfigurationSnapshots()
    }

    var hasPreviousConfigurationSnapshot: Bool {
        defaults.data(forKey: Keys.configurationSnapshotRecovery) != nil
    }

    @discardableResult
    func saveCurrentConfigurationSnapshot(
        named requestedName: String
    ) throws -> ConfigurationSnapshotDocument {
        let name = try validatedSnapshotName(requestedName)
        var snapshots = loadConfigurationSnapshots()
        guard !snapshots.contains(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw ConfigurationSnapshotError.nameConflict(name)
        }

        let document = ConfigurationSnapshotDocument(
            name: name,
            configuration: try currentConfigurationSnapshotPayload()
        )
        snapshots.append(document)
        try persistConfigurationSnapshots(snapshots)
        return document
    }

    @discardableResult
    func renameConfigurationSnapshot(
        id: UUID,
        to requestedName: String
    ) throws -> ConfigurationSnapshotDocument {
        let name = try validatedSnapshotName(requestedName)
        var snapshots = loadConfigurationSnapshots()
        guard let index = snapshots.firstIndex(where: { $0.id == id }) else {
            throw ConfigurationSnapshotError.snapshotNotFound
        }
        guard !snapshots.contains(where: {
            $0.id != id
                && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw ConfigurationSnapshotError.nameConflict(name)
        }

        snapshots[index].name = name
        try persistConfigurationSnapshots(snapshots)
        return snapshots[index]
    }

    @discardableResult
    func deleteConfigurationSnapshot(
        id: UUID
    ) throws -> (document: ConfigurationSnapshotDocument, index: Int) {
        var snapshots = loadConfigurationSnapshots()
        guard let index = snapshots.firstIndex(where: { $0.id == id }) else {
            throw ConfigurationSnapshotError.snapshotNotFound
        }
        let document = snapshots.remove(at: index)
        try persistConfigurationSnapshots(snapshots)
        return (document, index)
    }

    func restoreDeletedConfigurationSnapshot(
        _ document: ConfigurationSnapshotDocument,
        at index: Int
    ) throws {
        var snapshots = loadConfigurationSnapshots()
        guard !snapshots.contains(where: {
            $0.id == document.id
                || $0.name.caseInsensitiveCompare(document.name) == .orderedSame
        }) else {
            throw ConfigurationSnapshotError.nameConflict(document.name)
        }
        let normalized = try normalizedSnapshotDocument(document)
        snapshots.insert(normalized, at: min(max(index, 0), snapshots.count))
        try persistConfigurationSnapshots(snapshots)
    }

    func decodeConfigurationSnapshotDocument(
        _ data: Data
    ) throws -> ConfigurationSnapshotDocument {
        guard data.count <= Self.maximumConfigurationSnapshotImportSize else {
            throw ConfigurationSnapshotError.importTooLarge
        }
        guard let document = try? JSONDecoder().decode(
            ConfigurationSnapshotDocument.self,
            from: data
        ) else {
            throw ConfigurationSnapshotError.invalidDocument
        }
        return try normalizedSnapshotDocument(document)
    }

    func configurationSnapshotNameConflicts(
        with document: ConfigurationSnapshotDocument
    ) -> Bool {
        loadConfigurationSnapshots().contains {
            $0.name.caseInsensitiveCompare(document.name) == .orderedSame
        }
    }

    @discardableResult
    func importConfigurationSnapshot(
        _ document: ConfigurationSnapshotDocument,
        policy: ConfigurationSnapshotImportPolicy
    ) throws -> ConfigurationSnapshotDocument {
        var imported = try normalizedSnapshotDocument(document)
        var snapshots = loadConfigurationSnapshots()
        let conflictIndex = snapshots.firstIndex {
            $0.name.caseInsensitiveCompare(imported.name) == .orderedSame
        }

        switch (conflictIndex, policy) {
        case (.some, .rejectConflict):
            throw ConfigurationSnapshotError.nameConflict(imported.name)
        case (.some(let index), .replace):
            imported.id = snapshots[index].id
            snapshots[index] = imported
        case (.some, .saveCopy):
            imported.id = UUID()
            imported.createdAt = Date()
            imported.name = uniqueSnapshotCopyName(
                for: imported.name,
                in: snapshots
            )
            snapshots.append(imported)
        case (.none, _):
            if snapshots.contains(where: { $0.id == imported.id }) {
                imported.id = UUID()
            }
            snapshots.append(imported)
        }

        try persistConfigurationSnapshots(snapshots)
        return imported
    }

    func exportConfigurationSnapshotData(id: UUID) throws -> Data {
        guard let document = loadConfigurationSnapshots().first(where: {
            $0.id == id
        }) else {
            throw ConfigurationSnapshotError.snapshotNotFound
        }
        let data = try encodedSnapshotDocument(document, prettyPrinted: true)
        guard data.count <= Self.maximumConfigurationSnapshotImportSize else {
            throw ConfigurationSnapshotError.importTooLarge
        }
        return data
    }

    func applyConfigurationSnapshot(id: UUID) throws {
        guard let document = loadConfigurationSnapshots().first(where: {
            $0.id == id
        }) else {
            throw ConfigurationSnapshotError.snapshotNotFound
        }
        try applyConfigurationSnapshot(document)
    }

    func applyConfigurationSnapshot(
        _ document: ConfigurationSnapshotDocument
    ) throws {
        let normalized = try normalizedSnapshotDocument(document)
        let previous = ConfigurationSnapshotDocument(
            name: "Previous Setup",
            configuration: try currentConfigurationSnapshotPayload()
        )
        let recoveryData = try encodedSnapshotDocument(
            previous,
            prettyPrinted: false
        )
        guard recoveryData.count <= Self.maximumConfigurationSnapshotPersistentSize else {
            throw ConfigurationSnapshotError.persistentDataTooLarge
        }

        try replaceConfiguration(with: normalized.configuration)
        defaults.set(recoveryData, forKey: Keys.configurationSnapshotRecovery)
    }

    func restorePreviousConfigurationSnapshot() throws {
        guard let recoveryData = defaults.data(
            forKey: Keys.configurationSnapshotRecovery
        ) else {
            throw ConfigurationSnapshotError.noPreviousSetup
        }
        guard recoveryData.count <= Self.maximumConfigurationSnapshotPersistentSize,
              let decoded = try? JSONDecoder().decode(
                ConfigurationSnapshotDocument.self,
                from: recoveryData
              ) else {
            throw ConfigurationSnapshotError.invalidDocument
        }

        let recovery = try normalizedSnapshotDocument(decoded)
        let current = ConfigurationSnapshotDocument(
            name: "Previous Setup",
            configuration: try currentConfigurationSnapshotPayload()
        )
        let swappedRecoveryData = try encodedSnapshotDocument(
            current,
            prettyPrinted: false
        )
        guard swappedRecoveryData.count <= Self.maximumConfigurationSnapshotPersistentSize else {
            throw ConfigurationSnapshotError.persistentDataTooLarge
        }

        try replaceConfiguration(with: recovery.configuration)
        defaults.set(
            swappedRecoveryData,
            forKey: Keys.configurationSnapshotRecovery
        )
    }

    private func currentConfigurationSnapshotPayload() throws
        -> ConfigurationSnapshotPayload {
        let liveLayout = KeyLayoutStore.normalized(KeyLayout(
            offsets: storedLayoutValues(forKey: KeyLayoutStore.offsetsKey),
            widthMultipliers: storedLayoutValues(
                forKey: KeyLayoutStore.widthMultipliersKey
            )
        ))
        return try normalizedSnapshotPayload(ConfigurationSnapshotPayload(
            currentEffect: effectConfiguration,
            effectConfigurations: loadEffectConfigurations(),
            chordAppearance: chordAppearance,
            powerSavingMode: powerSavingMode,
            themes: savedThemes,
            currentThemeName: currentThemeName,
            activeThemeID: activeThemeID,
            layoutProfiles: savedKeyMappingProfiles,
            currentLayoutName: currentKeyMappingProfileName,
            activeLayoutID: activeLayoutID,
            currentCalibration: ConfigurationSnapshotCalibration(
                offsets: liveLayout.offsets,
                widthMultipliers: liveLayout.widthMultipliers
            ),
            primaryDisplaySelection: overlayDisplaySelection.persistedValue,
            mirroredDisplayIDs: mirroredDisplayIDs.sorted(),
            displayLayoutProfileBindings: displayLayoutProfileBindings,
            globalShortcut: globalShortcut,
            gradientPresets: savedGradientPresets
        ))
    }

    private func replaceConfiguration(
        with proposed: ConfigurationSnapshotPayload
    ) throws {
        let normalized = try normalizedSnapshotPayload(proposed)
        let backup = captureSnapshotStorageBackup()

        do {
            writeSnapshotPayload(normalized)
            let persisted = try currentConfigurationSnapshotPayload()
            guard persisted == normalized,
                  snapshotCommitVerifier(persisted) else {
                throw ConfigurationSnapshotError.transactionFailed
            }
        } catch {
            restoreSnapshotStorageBackup(backup)
            throw ConfigurationSnapshotError.transactionFailed
        }
    }

    private func writeSnapshotPayload(
        _ payload: ConfigurationSnapshotPayload
    ) {
        savedThemes = payload.themes
        savedKeyMappingProfiles = payload.layoutProfiles
        savedGradientPresets = payload.gradientPresets
        persistEffectConfigurations(payload.effectConfigurations)
        writeCurrentEffectConfiguration(payload.currentEffect)
        chordAppearance = payload.chordAppearance
        powerSavingMode = payload.powerSavingMode

        writeSelectionID(payload.activeThemeID, forKey: Keys.activeThemeID)
        defaults.set(payload.currentThemeName, forKey: Keys.currentThemeName)
        writeSelectionID(payload.activeLayoutID, forKey: Keys.activeLayoutID)
        defaults.set(
            payload.currentLayoutName,
            forKey: Keys.currentKeyMappingProfileName
        )

        overlayDisplaySelection = OverlayDisplaySelection(
            persistedValue: payload.primaryDisplaySelection
        )
        mirroredDisplayIDs = Set(payload.mirroredDisplayIDs)
        displayLayoutProfileBindings = payload.displayLayoutProfileBindings
        globalShortcut = payload.globalShortcut

        defaults.set(
            stringKeyed(payload.currentCalibration.offsets),
            forKey: KeyLayoutStore.offsetsKey
        )
        defaults.set(
            stringKeyed(payload.currentCalibration.widthMultipliers),
            forKey: KeyLayoutStore.widthMultipliersKey
        )
    }

    private func normalizedSnapshotDocument(
        _ document: ConfigurationSnapshotDocument
    ) throws -> ConfigurationSnapshotDocument {
        guard document.kind == ConfigurationSnapshotDocument.documentKind else {
            throw ConfigurationSnapshotError.invalidDocument
        }
        guard document.version == ConfigurationSnapshotDocument.currentVersion else {
            throw ConfigurationSnapshotError.unsupportedVersion(document.version)
        }
        var normalized = document
        normalized.name = try validatedSnapshotName(document.name)
        normalized.configuration = try normalizedSnapshotPayload(
            document.configuration
        )
        return normalized
    }

    private func normalizedSnapshotPayload(
        _ payload: ConfigurationSnapshotPayload
    ) throws -> ConfigurationSnapshotPayload {
        let currentEffect = try normalizedSnapshotEffect(
            payload.currentEffect,
            for: payload.currentEffect.style
        )

        var effectProfiles = ConfigurationSnapshotPayload
            .defaultEffectConfigurations
        for style in EffectStyle.allCases {
            if let proposed = payload.effectConfigurations[style.rawValue] {
                effectProfiles[style.rawValue] = try normalizedSnapshotEffect(
                    proposed,
                    for: style
                )
            }
        }
        effectProfiles[currentEffect.style.rawValue] = currentEffect

        let themes = try normalizedSnapshotThemes(payload.themes)
        let layouts = try normalizedSnapshotLayouts(payload.layoutProfiles)
        let themeIDs = Set(themes.map(\.id))
        let layoutIDs = Set(layouts.map(\.id))

        var activeThemeID = payload.activeThemeID
        var currentThemeName = try validatedSnapshotName(
            payload.currentThemeName
        )
        if activeThemeID == nil {
            activeThemeID = themes.first(where: {
                $0.name.caseInsensitiveCompare(currentThemeName) == .orderedSame
            })?.id
        }
        if let activeThemeID {
            guard themeIDs.contains(activeThemeID),
                  let activeTheme = themes.first(where: {
                      $0.id == activeThemeID
                  }) else {
                throw ConfigurationSnapshotError.invalidConfiguration(
                    String(localized: "The selected theme is not present in the snapshot library.")
                )
            }
            currentThemeName = activeTheme.name
        }

        var activeLayoutID = payload.activeLayoutID
        var currentLayoutName = payload.currentLayoutName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentLayoutName.isEmpty,
              currentLayoutName.count <= PersistenceValidation.maximumNameLength else {
            throw ConfigurationSnapshotError.invalidConfiguration(
                String(localized: "The selected layout name is invalid.")
            )
        }
        if activeLayoutID == nil {
            activeLayoutID = layouts.first(where: {
                $0.name.caseInsensitiveCompare(currentLayoutName) == .orderedSame
            })?.id
        }
        if let activeLayoutID {
            guard layoutIDs.contains(activeLayoutID),
                  let activeLayout = layouts.first(where: {
                      $0.id == activeLayoutID
                  }) else {
                throw ConfigurationSnapshotError.invalidConfiguration(
                    String(localized: "The selected keyboard layout is not present in the snapshot library.")
                )
            }
            currentLayoutName = activeLayout.name
        }

        let liveLayout = KeyLayoutStore.normalized(KeyLayout(
            offsets: payload.currentCalibration.offsets,
            widthMultipliers: payload.currentCalibration.widthMultipliers
        ))
        let primarySelection = try validatedDisplaySelection(
            payload.primaryDisplaySelection
        )
        let mirrors = try normalizedSnapshotDisplayIDs(
            payload.mirroredDisplayIDs,
            maximumCount: 16
        )
        let bindings = try normalizedSnapshotBindings(
            payload.displayLayoutProfileBindings,
            validLayoutIDs: layoutIDs
        )
        guard let shortcut = GlobalShortcut(
            keyCode: payload.globalShortcut.keyCode,
            modifiers: payload.globalShortcut.modifiers
        ) else {
            throw ConfigurationSnapshotError.invalidConfiguration(
                String(localized: "The global shortcut is invalid.")
            )
        }
        let gradients = try normalizedSnapshotGradients(
            payload.gradientPresets
        )

        let normalized = ConfigurationSnapshotPayload(
            currentEffect: currentEffect,
            effectConfigurations: effectProfiles,
            chordAppearance: payload.chordAppearance.normalized,
            powerSavingMode: payload.powerSavingMode,
            themes: themes,
            currentThemeName: currentThemeName,
            activeThemeID: activeThemeID,
            layoutProfiles: layouts,
            currentLayoutName: currentLayoutName,
            activeLayoutID: activeLayoutID,
            currentCalibration: ConfigurationSnapshotCalibration(
                offsets: liveLayout.offsets,
                widthMultipliers: liveLayout.widthMultipliers
            ),
            primaryDisplaySelection: primarySelection,
            mirroredDisplayIDs: mirrors,
            displayLayoutProfileBindings: bindings,
            globalShortcut: shortcut,
            gradientPresets: gradients
        )
        guard let data = try? JSONEncoder().encode(normalized),
              data.count <= Self.maximumConfigurationSnapshotPersistentSize else {
            throw ConfigurationSnapshotError.persistentDataTooLarge
        }
        return normalized
    }

    private func normalizedSnapshotEffect(
        _ proposed: EffectConfiguration,
        for requestedStyle: EffectStyle
    ) throws -> EffectConfiguration {
        let values = [
            proposed.opacity,
            proposed.refractionStrength,
            proposed.height,
            proposed.width,
            proposed.roundness,
            proposed.hardness,
            proposed.fadeDuration
        ]
        guard values.allSatisfy(\.isFinite),
              isValidSnapshotHex(proposed.color.solidHex),
              isValidSnapshotHex(proposed.color.gradientStartHex),
              isValidSnapshotHex(proposed.color.gradientEndHex) else {
            throw ConfigurationSnapshotError.invalidConfiguration(
                String(localized: "The snapshot contains invalid visual settings.")
            )
        }
        return validatedEffectConfiguration(proposed, for: requestedStyle)
    }

    private func normalizedSnapshotThemes(
        _ proposed: [Theme]
    ) throws -> [Theme] {
        let source = proposed.isEmpty ? [Theme.defaultTheme] : proposed
        guard source.count <= 128 else {
            throw ConfigurationSnapshotError.invalidConfiguration(
                String(localized: "The snapshot contains too many themes.")
            )
        }
        var seenIDs = Set<UUID>()
        var seenNames = Set<String>()
        return try source.map { theme in
            var normalized = theme
            normalized.name = try validatedSnapshotName(theme.name)
            let foldedName = normalized.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seenIDs.insert(theme.id).inserted,
                  seenNames.insert(foldedName).inserted,
                  isValidSnapshotHex(theme.colorHex),
                  theme.gradientStartHex.map(isValidSnapshotHex) ?? true,
                  theme.gradientEndHex.map(isValidSnapshotHex) ?? true else {
                throw ConfigurationSnapshotError.invalidConfiguration(
                    String(localized: "The snapshot contains duplicate or invalid themes.")
                )
            }
            let effect = try normalizedSnapshotEffect(
                EffectConfiguration(
                    style: theme.effectStyle,
                    shapeProfile: theme.shapeProfile,
                    color: ColorConfiguration(
                        mode: theme.colorMode,
                        solidHex: theme.colorHex,
                        gradientStartHex: theme.gradientStartHex
                            ?? theme.colorHex,
                        gradientEndHex: theme.gradientEndHex
                            ?? Self.defaultGradientEndHex
                    ),
                    opacity: theme.opacity,
                    refractionStrength: theme.refractionStrength,
                    height: theme.size,
                    width: theme.width,
                    roundness: theme.glowRoundness,
                    hardness: theme.glowFullness,
                    fadeDuration: theme.fadeDuration
                ),
                for: theme.effectStyle
            )
            normalized.colorHex = effect.color.solidHex
            normalized.opacity = effect.opacity
            normalized.refractionStrength = effect.refractionStrength
            normalized.size = effect.height
            normalized.width = effect.width
            normalized.glowRoundness = effect.roundness
            normalized.glowFullness = effect.hardness
            normalized.fadeDuration = effect.fadeDuration
            normalized.colorMode = effect.color.mode
            normalized.effectStyle = effect.style
            normalized.shapeProfile = effect.shapeProfile
            if theme.gradientStartHex != nil {
                normalized.gradientStartHex = effect.color.gradientStartHex
            }
            if theme.gradientEndHex != nil {
                normalized.gradientEndHex = effect.color.gradientEndHex
            }
            return normalized
        }
    }

    private func normalizedSnapshotLayouts(
        _ proposed: [KeyMappingProfile]
    ) throws -> [KeyMappingProfile] {
        guard proposed.count <= 128 else {
            throw ConfigurationSnapshotError.invalidConfiguration(
                String(localized: "The snapshot contains too many keyboard layouts.")
            )
        }
        var seenIDs = Set<UUID>()
        var seenNames = Set<String>()
        return try proposed.map { profile in
            var normalized = profile
            normalized.name = try validatedSnapshotName(profile.name)
            let foldedName = normalized.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seenIDs.insert(profile.id).inserted,
                  seenNames.insert(foldedName).inserted else {
                throw ConfigurationSnapshotError.invalidConfiguration(
                    String(localized: "The snapshot contains duplicate keyboard layouts.")
                )
            }
            let layout = KeyLayoutStore.normalized(KeyLayout(
                offsets: profile.keyOffsets,
                widthMultipliers: profile.keyWidthOverrides
            ))
            normalized.keyOffsets = layout.offsets
            normalized.keyWidthOverrides = layout.widthMultipliers
            return normalized
        }
    }

    private func normalizedSnapshotGradients(
        _ proposed: [GradientPreset]
    ) throws -> [GradientPreset] {
        let source = proposed.isEmpty ? Self.defaultGradientPresets : proposed
        guard source.count <= Self.maxGradientPresetCount else {
            throw ConfigurationSnapshotError.invalidConfiguration(
                String(localized: "The snapshot contains too many gradient presets.")
            )
        }
        var seenIDs = Set<UUID>()
        return try source.map { preset in
            guard seenIDs.insert(preset.id).inserted,
                  isValidSnapshotHex(preset.startHex),
                  isValidSnapshotHex(preset.endHex) else {
                throw ConfigurationSnapshotError.invalidConfiguration(
                    String(localized: "The snapshot contains invalid gradient presets.")
                )
            }
            let name = preset.name.map {
                String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            }
            return GradientPreset(
                id: preset.id,
                startHex: sanitizedHex(preset.startHex),
                endHex: sanitizedHex(preset.endHex),
                name: name?.isEmpty == false ? name : nil
            )
        }
    }

    private func normalizedSnapshotDisplayIDs(
        _ proposed: [String],
        maximumCount: Int
    ) throws -> [String] {
        guard proposed.count <= maximumCount else {
            throw ConfigurationSnapshotError.invalidConfiguration(
                String(localized: "The snapshot contains too many display selections.")
            )
        }
        let normalized = proposed.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard normalized.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else {
            throw ConfigurationSnapshotError.invalidConfiguration(
                String(localized: "The snapshot contains an invalid display identifier.")
            )
        }
        return Array(Set(normalized)).sorted()
    }

    private func normalizedSnapshotBindings(
        _ proposed: [String: UUID],
        validLayoutIDs: Set<UUID>
    ) throws -> [String: UUID] {
        guard proposed.count <= 32,
              proposed.allSatisfy({ key, value in
                  !key.isEmpty
                      && key.count <= 200
                      && validLayoutIDs.contains(value)
              }) else {
            throw ConfigurationSnapshotError.invalidConfiguration(
                String(localized: "The snapshot contains invalid display layout bindings.")
            )
        }
        return proposed
    }

    private func validatedDisplaySelection(_ rawValue: String) throws
        -> String {
        switch rawValue {
        case "automatic", "builtIn", "main":
            return rawValue
        default:
            let prefix = "display:"
            guard rawValue.hasPrefix(prefix) else {
                throw ConfigurationSnapshotError.invalidConfiguration(
                    String(localized: "The primary display selection is invalid.")
                )
            }
            let identifier = String(rawValue.dropFirst(prefix.count))
            guard !identifier.isEmpty, identifier.count <= 200 else {
                throw ConfigurationSnapshotError.invalidConfiguration(
                    String(localized: "The primary display identifier is invalid.")
                )
            }
            return rawValue
        }
    }

    private func validatedSnapshotName(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= PersistenceValidation.maximumNameLength else {
            throw ConfigurationSnapshotError.invalidName
        }
        return trimmed
    }

    private func isValidSnapshotHex(_ value: String) -> Bool {
        value.count == 6
            && value.allSatisfy { "0123456789ABCDEFabcdef".contains($0) }
    }

    private func storedLayoutValues(forKey key: String) -> [UInt16: CGFloat] {
        guard let stored = defaults.dictionary(forKey: key) else { return [:] }
        return stored.reduce(into: [:]) { result, pair in
            guard let keyCode = UInt16(pair.key),
                  let number = pair.value as? NSNumber else {
                return
            }
            result[keyCode] = CGFloat(truncating: number)
        }
    }

    private func stringKeyed(
        _ values: [UInt16: CGFloat]
    ) -> [String: CGFloat] {
        values.reduce(into: [:]) { result, pair in
            result[String(pair.key)] = pair.value
        }
    }

    private struct SnapshotStorageBackup {
        var values: [String: Any]
        var absentKeys: Set<String>
    }

    private func captureSnapshotStorageBackup() -> SnapshotStorageBackup {
        var values: [String: Any] = [:]
        var absentKeys = Set<String>()
        for key in Self.configurationSnapshotStorageKeyRegistry {
            if let value = defaults.object(forKey: key) {
                values[key] = value
            } else {
                absentKeys.insert(key)
            }
        }
        return SnapshotStorageBackup(values: values, absentKeys: absentKeys)
    }

    private func restoreSnapshotStorageBackup(
        _ backup: SnapshotStorageBackup
    ) {
        for key in Self.configurationSnapshotStorageKeyRegistry {
            if backup.absentKeys.contains(key) {
                defaults.removeObject(forKey: key)
            } else {
                defaults.set(backup.values[key], forKey: key)
            }
        }
    }

    private func loadConfigurationSnapshots()
        -> [ConfigurationSnapshotDocument] {
        guard let data = defaults.data(forKey: Keys.configurationSnapshots),
              data.count <= Self.maximumConfigurationSnapshotPersistentSize,
              let decoded = try? JSONDecoder().decode(
                [ConfigurationSnapshotDocument].self,
                from: data
              ) else {
            return []
        }

        var seenNames = Set<String>()
        var seenIDs = Set<UUID>()
        return decoded.compactMap { document in
            guard let normalized = try? normalizedSnapshotDocument(document) else {
                return nil
            }
            let name = normalized.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seenNames.insert(name).inserted,
                  seenIDs.insert(normalized.id).inserted else {
                return nil
            }
            return normalized
        }
    }

    private func persistConfigurationSnapshots(
        _ snapshots: [ConfigurationSnapshotDocument]
    ) throws {
        let normalized = try snapshots.map(normalizedSnapshotDocument)
        guard let data = try? JSONEncoder().encode(normalized),
              data.count <= Self.maximumConfigurationSnapshotPersistentSize else {
            throw ConfigurationSnapshotError.persistentDataTooLarge
        }
        defaults.set(data, forKey: Keys.configurationSnapshots)
    }

    private func encodedSnapshotDocument(
        _ document: ConfigurationSnapshotDocument,
        prettyPrinted: Bool
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(try normalizedSnapshotDocument(document))
        } catch let error as ConfigurationSnapshotError {
            throw error
        } catch {
            throw ConfigurationSnapshotError.invalidDocument
        }
    }

    private func uniqueSnapshotCopyName(
        for originalName: String,
        in snapshots: [ConfigurationSnapshotDocument]
    ) -> String {
        let existing = Set(snapshots.map {
            $0.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
        })
        var copyNumber = 1
        while true {
            let suffix = copyNumber == 1 ? " Copy" : " Copy \(copyNumber)"
            let maximumBaseLength = max(
                1,
                PersistenceValidation.maximumNameLength - suffix.count
            )
            let candidate = String(originalName.prefix(maximumBaseLength))
                + suffix
            let folded = candidate.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if !existing.contains(folded) {
                return candidate
            }
            copyNumber += 1
        }
    }

    #if DEBUG
    func _testApplyDefaultExperienceSeedIfNeeded() {
        seedDefaultExperienceIfNeeded()
    }

    func _testApplyDefaultLayoutIfMissingOnce() {
        applyDefaultLayoutIfMissingOnce()
    }

    func _testSeedBundledLayoutProfilesIfNeededOnce() {
        seedBundledLayoutProfilesIfNeededOnce()
    }
    #endif

}
