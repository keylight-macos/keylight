import Foundation

/// A persisted appearance snapshot. Coding keys and defaults are part of the
/// compatibility contract for the existing `savedThemes` UserDefaults value.
struct Theme: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var colorHex: String
    var opacity: Double
    var refractionStrength: Double
    var size: Double
    var width: Double
    var glowRoundness: Double
    var glowFullness: Double
    var fadeDuration: Double
    var colorMode: ColorMode
    var effectStyle: EffectStyle
    var shapeProfile: SurfaceShapeProfile
    var gradientStartHex: String?
    var gradientEndHex: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case colorHex
        case opacity
        case refractionStrength
        case size
        case width
        case glowRoundness
        case glowFullness
        case fadeDuration
        case colorMode
        case effectStyle
        case shapeProfile
        case gradientStartHex
        case gradientEndHex
    }

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        opacity: Double,
        refractionStrength: Double = 1.0,
        size: Double,
        width: Double,
        glowRoundness: Double = 1.0,
        glowFullness: Double = 0.5,
        fadeDuration: Double,
        colorMode: ColorMode,
        effectStyle: EffectStyle = .classicGlow,
        shapeProfile: SurfaceShapeProfile = .currentWave,
        gradientStartHex: String?,
        gradientEndHex: String?
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.opacity = opacity
        self.refractionStrength = refractionStrength
        self.size = size
        self.width = width
        self.glowRoundness = glowRoundness
        self.glowFullness = glowFullness
        self.fadeDuration = fadeDuration
        self.colorMode = colorMode
        self.effectStyle = effectStyle
        self.shapeProfile = shapeProfile
        self.gradientStartHex = gradientStartHex
        self.gradientEndHex = gradientEndHex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? "Imported"
        id = (try? container.decode(UUID.self, forKey: .id))
            ?? LegacyRecordIdentity.id(kind: "theme", name: name)
        colorHex = (try? container.decode(String.self, forKey: .colorHex)) ?? "68B8FF"
        opacity = (try? container.decode(Double.self, forKey: .opacity)) ?? 0.8013
        refractionStrength =
            (try? container.decode(Double.self, forKey: .refractionStrength))
            ?? 1.0
        size = (try? container.decode(Double.self, forKey: .size)) ?? 80.5536
        width = (try? container.decode(Double.self, forKey: .width)) ?? 1.0
        glowRoundness = (try? container.decode(Double.self, forKey: .glowRoundness)) ?? 0.7069
        glowFullness = (try? container.decode(Double.self, forKey: .glowFullness)) ?? 0.6046
        fadeDuration = (try? container.decode(Double.self, forKey: .fadeDuration)) ?? 1.0004

        if let mode = try? container.decode(ColorMode.self, forKey: .colorMode) {
            colorMode = mode
        } else {
            let rawMode = (try? container.decode(String.self, forKey: .colorMode))
                ?? ColorMode.positionGradient.rawValue
            colorMode = rawMode == "gradient"
                ? .positionGradient
                : (ColorMode(rawValue: rawMode) ?? .positionGradient)
        }

        effectStyle = (
            (try? container.decode(EffectStyle.self, forKey: .effectStyle))
                ?? .classicGlow
        ).supportedStyle
        shapeProfile = (try? container.decode(
            SurfaceShapeProfile.self,
            forKey: .shapeProfile
        )) ?? .currentWave
        gradientStartHex = try? container.decode(String.self, forKey: .gradientStartHex)
        gradientEndHex = try? container.decode(String.self, forKey: .gradientEndHex)
    }

    static let defaultTheme = Theme(
        name: "current",
        colorHex: "68B8FF",
        opacity: 0.8013,
        refractionStrength: 1.0,
        size: 80.5536,
        width: 1.0,
        glowRoundness: 0.7069,
        glowFullness: 0.6046,
        fadeDuration: 1.0004,
        colorMode: .positionGradient,
        effectStyle: .classicGlow,
        shapeProfile: .currentWave,
        gradientStartHex: "68B8FF",
        gradientEndHex: "00E69A"
    )
}

/// A persisted keyboard-calibration snapshot. The custom string-keyed encoding
/// preserves the existing layout JSON representation exactly.
struct KeyMappingProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var keyOffsets: [UInt16: CGFloat]
    var keyWidthOverrides: [UInt16: CGFloat]

    enum CodingKeys: String, CodingKey {
        case id, name, keyOffsets, keyWidthOverrides
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        let stringKeyedOffsets = keyOffsets.reduce(into: [String: CGFloat]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
        try container.encode(stringKeyedOffsets, forKey: .keyOffsets)

        let stringKeyedWidths = keyWidthOverrides.reduce(into: [String: CGFloat]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
        try container.encode(stringKeyedWidths, forKey: .keyWidthOverrides)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        id = (try? container.decode(UUID.self, forKey: .id))
            ?? LegacyRecordIdentity.id(kind: "layout", name: name)
        let stringKeyed = try container.decode([String: CGFloat].self, forKey: .keyOffsets)
        keyOffsets = stringKeyed.reduce(into: [UInt16: CGFloat]()) { result, pair in
            if let keyCode = UInt16(pair.key) {
                result[keyCode] = pair.value
            }
        }

        let widthKeyed = (try? container.decode([String: CGFloat].self, forKey: .keyWidthOverrides)) ?? [:]
        keyWidthOverrides = widthKeyed.reduce(into: [UInt16: CGFloat]()) { result, pair in
            if let keyCode = UInt16(pair.key) {
                result[keyCode] = pair.value
            }
        }
    }

    init(name: String, keyOffsets: [UInt16: CGFloat], keyWidthOverrides: [UInt16: CGFloat] = [:]) {
        self.name = name
        self.keyOffsets = keyOffsets
        self.keyWidthOverrides = keyWidthOverrides
    }
}

/// A persisted reusable gradient pair.
struct GradientPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var startHex: String
    var endHex: String
    var name: String?
}

/// The live calibration embedded in a complete configuration snapshot.
/// String-keyed coding keeps the JSON readable and matches KeyLight's existing
/// layout transfer format without making UserDefaults the interchange format.
struct ConfigurationSnapshotCalibration: Codable, Equatable {
    var offsets: [UInt16: CGFloat]
    var widthMultipliers: [UInt16: CGFloat]

    init(
        offsets: [UInt16: CGFloat] = [:],
        widthMultipliers: [UInt16: CGFloat] = [:]
    ) {
        self.offsets = offsets
        self.widthMultipliers = widthMultipliers
    }

    static let empty = ConfigurationSnapshotCalibration()

    private enum CodingKeys: String, CodingKey {
        case offsets
        case widthMultipliers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offsets = Self.decodeValues(
            try container.decodeIfPresent(
                [String: CGFloat].self,
                forKey: .offsets
            ) ?? [:]
        )
        widthMultipliers = Self.decodeValues(
            try container.decodeIfPresent(
                [String: CGFloat].self,
                forKey: .widthMultipliers
            ) ?? [:]
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.encodeValues(offsets), forKey: .offsets)
        try container.encode(
            Self.encodeValues(widthMultipliers),
            forKey: .widthMultipliers
        )
    }

    private static func decodeValues(
        _ values: [String: CGFloat]
    ) -> [UInt16: CGFloat] {
        values.reduce(into: [:]) { result, pair in
            guard let keyCode = UInt16(pair.key) else { return }
            result[keyCode] = pair.value
        }
    }

    private static func encodeValues(
        _ values: [UInt16: CGFloat]
    ) -> [String: CGFloat] {
        values.reduce(into: [:]) { result, pair in
            result[String(pair.key)] = pair.value
        }
    }
}

/// The strict, typed allowlist of app-managed values that a configuration
/// snapshot may replace. Unknown JSON fields are ignored by Codable and never
/// become arbitrary preference writes.
struct ConfigurationSnapshotPayload: Codable, Equatable {
    var currentEffect: EffectConfiguration
    var effectConfigurations: [String: EffectConfiguration]
    var chordAppearance: ChordAppearance
    var powerSavingMode: PowerSavingMode
    var themes: [Theme]
    var currentThemeName: String
    var activeThemeID: UUID?
    var layoutProfiles: [KeyMappingProfile]
    var currentLayoutName: String
    var activeLayoutID: UUID?
    var currentCalibration: ConfigurationSnapshotCalibration
    var primaryDisplaySelection: String
    var mirroredDisplayIDs: [String]
    var displayLayoutProfileBindings: [String: UUID]
    var globalShortcut: GlobalShortcut
    var gradientPresets: [GradientPreset]

    init(
        currentEffect: EffectConfiguration = .default,
        effectConfigurations: [String: EffectConfiguration] = Self.defaultEffectConfigurations,
        chordAppearance: ChordAppearance = .default,
        powerSavingMode: PowerSavingMode = .automatic,
        themes: [Theme] = [Theme.defaultTheme],
        currentThemeName: String = Theme.defaultTheme.name,
        activeThemeID: UUID? = nil,
        layoutProfiles: [KeyMappingProfile] = [],
        currentLayoutName: String = "None",
        activeLayoutID: UUID? = nil,
        currentCalibration: ConfigurationSnapshotCalibration = .empty,
        primaryDisplaySelection: String = "automatic",
        mirroredDisplayIDs: [String] = [],
        displayLayoutProfileBindings: [String: UUID] = [:],
        globalShortcut: GlobalShortcut = .default,
        gradientPresets: [GradientPreset] = []
    ) {
        self.currentEffect = currentEffect
        self.effectConfigurations = effectConfigurations
        self.chordAppearance = chordAppearance
        self.powerSavingMode = powerSavingMode
        self.themes = themes
        self.currentThemeName = currentThemeName
        self.activeThemeID = activeThemeID
        self.layoutProfiles = layoutProfiles
        self.currentLayoutName = currentLayoutName
        self.activeLayoutID = activeLayoutID
        self.currentCalibration = currentCalibration
        self.primaryDisplaySelection = primaryDisplaySelection
        self.mirroredDisplayIDs = mirroredDisplayIDs
        self.displayLayoutProfileBindings = displayLayoutProfileBindings
        self.globalShortcut = globalShortcut
        self.gradientPresets = gradientPresets
    }

    static let `default` = ConfigurationSnapshotPayload()

    static var defaultEffectConfigurations: [String: EffectConfiguration] {
        Dictionary(uniqueKeysWithValues: EffectStyle.allCases.map { style in
            (style.rawValue, EffectConfiguration.defaultConfiguration(for: style))
        })
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case currentEffect
        case effectConfigurations
        case chordAppearance
        case powerSavingMode
        case themes
        case currentThemeName
        case activeThemeID
        case layoutProfiles
        case currentLayoutName
        case activeLayoutID
        case currentCalibration
        case primaryDisplaySelection
        case mirroredDisplayIDs
        case displayLayoutProfileBindings
        case globalShortcut
        case gradientPresets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            currentEffect: try container.decodeIfPresent(
                EffectConfiguration.self,
                forKey: .currentEffect
            ) ?? .default,
            effectConfigurations: try container.decodeIfPresent(
                [String: EffectConfiguration].self,
                forKey: .effectConfigurations
            ) ?? Self.defaultEffectConfigurations,
            chordAppearance: try container.decodeIfPresent(
                ChordAppearance.self,
                forKey: .chordAppearance
            ) ?? .default,
            powerSavingMode: try container.decodeIfPresent(
                PowerSavingMode.self,
                forKey: .powerSavingMode
            ) ?? .automatic,
            themes: try container.decodeIfPresent(
                [Theme].self,
                forKey: .themes
            ) ?? [Theme.defaultTheme],
            currentThemeName: try container.decodeIfPresent(
                String.self,
                forKey: .currentThemeName
            ) ?? Theme.defaultTheme.name,
            activeThemeID: try container.decodeIfPresent(
                UUID.self,
                forKey: .activeThemeID
            ),
            layoutProfiles: try container.decodeIfPresent(
                [KeyMappingProfile].self,
                forKey: .layoutProfiles
            ) ?? [],
            currentLayoutName: try container.decodeIfPresent(
                String.self,
                forKey: .currentLayoutName
            ) ?? "None",
            activeLayoutID: try container.decodeIfPresent(
                UUID.self,
                forKey: .activeLayoutID
            ),
            currentCalibration: try container.decodeIfPresent(
                ConfigurationSnapshotCalibration.self,
                forKey: .currentCalibration
            ) ?? .empty,
            primaryDisplaySelection: try container.decodeIfPresent(
                String.self,
                forKey: .primaryDisplaySelection
            ) ?? "automatic",
            mirroredDisplayIDs: try container.decodeIfPresent(
                [String].self,
                forKey: .mirroredDisplayIDs
            ) ?? [],
            displayLayoutProfileBindings: try container.decodeIfPresent(
                [String: UUID].self,
                forKey: .displayLayoutProfileBindings
            ) ?? [:],
            globalShortcut: try container.decodeIfPresent(
                GlobalShortcut.self,
                forKey: .globalShortcut
            ) ?? .default,
            gradientPresets: try container.decodeIfPresent(
                [GradientPreset].self,
                forKey: .gradientPresets
            ) ?? []
        )
    }
}

/// Versioned interchange document used by both the in-app library and
/// `.keylight-snapshot.json` files.
struct ConfigurationSnapshotDocument: Codable, Identifiable, Equatable {
    static let documentKind = "keylightConfigurationSnapshot"
    static let currentVersion = 1

    var kind: String
    var version: Int
    var id: UUID
    var name: String
    var createdAt: Date
    var configuration: ConfigurationSnapshotPayload

    init(
        kind: String = Self.documentKind,
        version: Int = Self.currentVersion,
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        configuration: ConfigurationSnapshotPayload
    ) {
        self.kind = kind
        self.version = version
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.configuration = configuration
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case id
        case name
        case createdAt
        case configuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? "Imported Snapshot"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? Date(timeIntervalSince1970: 0)
        configuration = try container.decodeIfPresent(
            ConfigurationSnapshotPayload.self,
            forKey: .configuration
        ) ?? .default
    }
}

/// Legacy themes and layouts used their names as identity. Derive a stable,
/// domain-separated UUID so an older build stripping `id` cannot make the same
/// record change identity on every load.
private enum LegacyRecordIdentity {
    static func id(kind: String, name: String) -> UUID {
        let canonicalName = name.precomposedStringWithCanonicalMapping
        let bytes = Array("KeyLight\u{0}\(kind)\u{0}\(canonicalName)".utf8)

        let high = fnv1a64(bytes, seed: 0xcbf29ce484222325)
        let low = fnv1a64(bytes, seed: 0x84222325cbf29ce4)

        var uuidBytes: [UInt8] = [
            UInt8(truncatingIfNeeded: high >> 56),
            UInt8(truncatingIfNeeded: high >> 48),
            UInt8(truncatingIfNeeded: high >> 40),
            UInt8(truncatingIfNeeded: high >> 32),
            UInt8(truncatingIfNeeded: high >> 24),
            UInt8(truncatingIfNeeded: high >> 16),
            UInt8(truncatingIfNeeded: high >> 8),
            UInt8(truncatingIfNeeded: high),
            UInt8(truncatingIfNeeded: low >> 56),
            UInt8(truncatingIfNeeded: low >> 48),
            UInt8(truncatingIfNeeded: low >> 40),
            UInt8(truncatingIfNeeded: low >> 32),
            UInt8(truncatingIfNeeded: low >> 24),
            UInt8(truncatingIfNeeded: low >> 16),
            UInt8(truncatingIfNeeded: low >> 8),
            UInt8(truncatingIfNeeded: low)
        ]

        // RFC 9562 UUIDv8 leaves payload semantics to the application.
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x80
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80

        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }

    private static func fnv1a64(_ bytes: [UInt8], seed: UInt64) -> UInt64 {
        bytes.reduce(seed) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x100000001b3
        }
    }
}
