import Foundation

/// The established color-selection modes used by preferences, saved themes,
/// and renderer configuration. Raw values are part of KeyLight's compatibility
/// contract and must not change.
enum ColorMode: String, CaseIterable, Codable, Sendable {
    case solid = "solid"
    case positionGradient = "positionGradient"
    case randomPerKey = "randomPerKey"
    case rainbow = "rainbow"
}

/// The renderer styles supported by KeyLight.
///
/// Availability resolution belongs to the domain value rather than the
/// persistence store so views and renderers do not depend on SettingsManager.
enum EffectStyle: String, CaseIterable, Codable, Sendable {
    case classicGlow = "classicGlow"
    // Retained only as wire-format migration tokens for preview-era themes
    // and preferences. They are deliberately absent from `allCases` and never
    // reach a renderer.
    case classicPlus = "classicPlus"
    case liquidGlass = "liquidGlass"
    case systemGlass = "systemGlass"
    case physicalRefraction = "physicalRefraction"
    case solidBlack = "solidBlack"

    static var allCases: [EffectStyle] {
        [.classicGlow, .systemGlass, .physicalRefraction, .solidBlack]
    }

    var supportedStyle: EffectStyle {
        switch self {
        case .classicPlus:
            return .classicGlow
        case .liquidGlass:
            return .systemGlass
        case .classicGlow, .systemGlass, .physicalRefraction, .solidBlack:
            return self
        }
    }

    var isRetired: Bool {
        self != supportedStyle
    }

    var displayName: String {
        switch self {
        case .classicGlow:
            return String(localized: "Classic Glow")
        case .classicPlus:
            return String(localized: "Classic Glow")
        case .liquidGlass:
            return String(localized: "System Glass")
        case .systemGlass:
            return String(localized: "System Glass")
        case .physicalRefraction:
            return String(localized: "Physical Refraction")
        case .solidBlack:
            return String(localized: "Solid Black")
        }
    }

    var isAvailableOnCurrentSystem: Bool {
        switch supportedStyle {
        case .classicGlow:
            return true
        case .systemGlass, .physicalRefraction, .solidBlack:
            return Self.liquidGlassAvailableOnCurrentSystem
        case .classicPlus, .liquidGlass:
            return false
        }
    }

    var resolvedForCurrentSystem: EffectStyle {
        resolved(liquidGlassAvailable: Self.liquidGlassAvailableOnCurrentSystem)
    }

    func resolved(liquidGlassAvailable: Bool) -> EffectStyle {
        let supported = supportedStyle
        return supported.requiresMacOS26 && !liquidGlassAvailable
            ? .classicGlow
            : supported
    }

    var requiresMacOS26: Bool {
        switch supportedStyle {
        case .classicGlow:
            false
        case .systemGlass, .physicalRefraction, .solidBlack:
            true
        case .classicPlus, .liquidGlass:
            false
        }
    }

    var usesClassicColorConfiguration: Bool {
        supportedStyle == .classicGlow
    }

    var usesScreenCapture: Bool {
        supportedStyle == .physicalRefraction
    }

    private static var liquidGlassAvailableOnCurrentSystem: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return true
        }
        #endif
        return false
    }
}

/// Controls whether simultaneous keys form one cohesive surface or retain
/// visibly independent material boundaries.
enum ChordSurfaceStyle: String, CaseIterable, Codable, Sendable {
    case naturalMerge = "naturalMerge"
    case independent = "independent"

    var displayName: String {
        switch self {
        case .naturalMerge:
            return String(localized: "Natural Merge")
        case .independent:
            return String(localized: "Independent")
        }
    }
}

/// Appearance applied only while at least two physical or chord-test keys are
/// active. A multiplier of 1 preserves the established single-key rendering.
struct ChordAppearance: Codable, Equatable, Sendable {
    static let intensityRange: ClosedRange<Double> = 0.5 ... 1.5

    var style: ChordSurfaceStyle
    var intensityMultiplier: Double

    init(
        style: ChordSurfaceStyle = .naturalMerge,
        intensityMultiplier: Double = 1
    ) {
        self.style = style
        self.intensityMultiplier = Self.normalizedIntensity(
            intensityMultiplier
        )
    }

    static let `default` = ChordAppearance()

    private enum CodingKeys: String, CodingKey {
        case style
        case intensityMultiplier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            style: try container.decodeIfPresent(
                ChordSurfaceStyle.self,
                forKey: .style
            ) ?? .naturalMerge,
            intensityMultiplier: try container.decodeIfPresent(
                Double.self,
                forKey: .intensityMultiplier
            ) ?? 1
        )
    }

    var normalized: ChordAppearance {
        ChordAppearance(
            style: style,
            intensityMultiplier: intensityMultiplier
        )
    }

    func opacity(_ baseOpacity: Float, activeMemberCount: Int) -> Float {
        guard activeMemberCount >= 2 else { return baseOpacity }
        let scaled = Double(baseOpacity) * intensityMultiplier
        guard scaled.isFinite else { return baseOpacity }
        return Float(min(max(scaled, 0), 1))
    }

    private static func normalizedIntensity(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, intensityRange.lowerBound), intensityRange.upperBound)
    }
}

enum PowerSavingMode: String, CaseIterable, Codable, Sendable {
    case off = "off"
    case automatic = "automatic"

    var displayName: String {
        switch self {
        case .off:
            return String(localized: "Off")
        case .automatic:
            return String(localized: "Automatic")
        }
    }
}

enum PowerThermalState: String, CaseIterable, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:
            self = .nominal
        case .fair:
            self = .fair
        case .serious:
            self = .serious
        case .critical:
            self = .critical
        @unknown default:
            self = .serious
        }
    }

    var displayName: String {
        rawValue.capitalized
    }

    var requiresFallback: Bool {
        self == .serious || self == .critical
    }
}

/// A privacy-safe, serializable snapshot of the two macOS signals used by
/// Automatic Power Saving. It contains no battery percentage or device data.
struct PowerEnvironmentState: Codable, Equatable, Sendable {
    var isLowPowerModeEnabled: Bool
    var thermalState: PowerThermalState

    static let normal = PowerEnvironmentState(
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    )

    var requiresFallback: Bool {
        isLowPowerModeEnabled || thermalState.requiresFallback
    }

    var fallbackReason: String? {
        switch (isLowPowerModeEnabled, thermalState) {
        case (true, .serious):
            return String(localized: "Low Power Mode and serious thermal pressure")
        case (true, .critical):
            return String(localized: "Low Power Mode and critical thermal pressure")
        case (true, _):
            return String(localized: "Low Power Mode")
        case (false, .serious):
            return String(localized: "Serious thermal pressure")
        case (false, .critical):
            return String(localized: "Critical thermal pressure")
        case (false, .nominal), (false, .fair):
            return nil
        }
    }

    static func current(_ processInfo: ProcessInfo = .processInfo) -> Self {
        PowerEnvironmentState(
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: PowerThermalState(processInfo.thermalState)
        )
    }
}

/// The established silhouette for all surface-based effects.
///
/// Shape selection was briefly available in preview builds. Persisted themes
/// from those builds still decode, but every retired profile intentionally
/// normalizes to `currentWave` so removing the control cannot invalidate a
/// user's saved settings.
enum SurfaceShapeProfile: String, CaseIterable, Codable, Sendable {
    case currentWave = "currentWave"

    var displayName: String {
        String(localized: "Current Wave")
    }

    static func persistedValue(rawValue: String) -> SurfaceShapeProfile? {
        switch rawValue {
        case "currentWave", "keyCap", "opticalDome", "softPillow":
            return .currentWave
        default:
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self.persistedValue(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown KeyLight surface shape."
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The color-related portion of KeyLight's appearance configuration.
///
/// This is intentionally a value type and does not define a new persistence
/// format. `SettingsManager` continues to read and write the established
/// UserDefaults keys and theme strings.
struct ColorConfiguration: Codable, Equatable, Sendable {
    var mode: ColorMode
    var solidHex: String
    var gradientStartHex: String
    var gradientEndHex: String

    static let `default` = ColorConfiguration(
        mode: .positionGradient,
        solidHex: "68B8FF",
        gradientStartHex: "68B8FF",
        gradientEndHex: "00E69A"
    )
}

/// A complete, renderer-independent snapshot of the current visual effect.
struct EffectConfiguration: Codable, Equatable, Sendable {
    var style: EffectStyle
    var shapeProfile: SurfaceShapeProfile
    var color: ColorConfiguration
    var opacity: Double
    /// Multiplies the physical lens path length without changing its glass
    /// refractive index. A value of 1 preserves the original tuned appearance.
    var refractionStrength: Double = 1.0
    var height: Double
    var width: Double
    var roundness: Double
    var hardness: Double
    var fadeDuration: Double

    static let `default` = EffectConfiguration(
        style: .classicGlow,
        shapeProfile: .currentWave,
        color: .default,
        opacity: 0.8013,
        refractionStrength: 1.0,
        height: 80.5536,
        width: 1.0,
        roundness: 0.7069,
        hardness: 0.6046,
        fadeDuration: 1.0004
    )

    static func defaultConfiguration(for requestedStyle: EffectStyle) -> EffectConfiguration {
        let style = requestedStyle.supportedStyle
        var configuration = Self.default
        configuration.style = style
        switch style {
        case .classicGlow:
            break
        case .systemGlass:
            configuration.opacity = 0.80
        case .physicalRefraction:
            configuration.opacity = 0.80
            configuration.refractionStrength = 1.0
        case .solidBlack:
            // The renderer remains geometrically animated but fully opaque.
            configuration.opacity = 1.0
        case .classicPlus, .liquidGlass:
            break
        }
        return configuration
    }
}

/// User-facing preferences that are independent from saved themes and layouts.
struct AppPreferences: Equatable, Sendable {
    var isEnabled: Bool
    var launchAtLogin: Bool
    var effect: EffectConfiguration
    var chordAppearance: ChordAppearance
    var powerSavingMode: PowerSavingMode

    static let `default` = AppPreferences(
        isEnabled: true,
        launchAtLogin: false,
        effect: .default,
        chordAppearance: .default,
        powerSavingMode: .automatic
    )
}

/// Structured feedback for UI surfaces. Recovery actions are identifiers rather
/// than closures so feedback remains equatable and can be routed by a coordinator.
struct UserFeedback: Equatable, Identifiable, Sendable {
    enum Severity: String, Equatable, Sendable {
        case information
        case success
        case warning
        case error
    }

    enum RecoveryAction: String, Equatable, Sendable {
        case checkAgain
        case retry
        case undo
        case openInputMonitoringSettings
    }

    var id: UUID
    var severity: Severity
    var title: String
    var detail: String?
    var recoveryAction: RecoveryAction?

    init(
        id: UUID = UUID(),
        severity: Severity,
        title: String,
        detail: String? = nil,
        recoveryAction: RecoveryAction? = nil
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.recoveryAction = recoveryAction
    }
}
