import Foundation

/// Pure codec for KeyLight's established shareable theme-string formats.
///
/// Field names, ordering, formatting, validation, and NSError values are part
/// of the v1/v2 compatibility contract and must remain stable. V3's retired
/// shape field remains in the wire format so preview-era themes still import;
/// V4 adds the independently adjustable physical-refraction path length. V5
/// keeps the same fields and accepts the retired Classic+ value only so those
/// preview-era payloads can migrate to Classic Glow.
enum ThemeStringCodec {
    static let defaultThemeString = "keylight-theme-v5;name=current;mode=positionGradient;effect=classicGlow;shape=currentWave;refraction=1.0000;color=68B8FF;opacity=0.8013;size=80.5536;width=1.0000;round=0.7069;hard=0.6046;fade=1.0004;gstart=68B8FF;gend=00E69A"

    private static let prefixV1 = "keylight-theme-v1"
    private static let prefixV2 = "keylight-theme-v2"
    private static let prefixV3 = "keylight-theme-v3"
    private static let prefixV4 = "keylight-theme-v4"
    private static let prefixV5 = "keylight-theme-v5"
    private static let maximumLength = 2_048
    private static let fieldOrderV1 = [
        "name", "mode", "color", "opacity", "size", "width", "round", "hard", "fade", "gstart", "gend"
    ]
    private static let fieldOrderV2 = [
        "name", "mode", "effect", "color", "opacity", "size", "width", "round", "hard", "fade", "gstart", "gend"
    ]
    private static let fieldOrderV3 = [
        "name", "mode", "effect", "shape", "color", "opacity", "size", "width", "round", "hard", "fade", "gstart", "gend"
    ]
    private static let fieldOrderV4 = [
        "name", "mode", "effect", "shape", "refraction", "color", "opacity", "size", "width", "round", "hard", "fade", "gstart", "gend"
    ]
    private static let requiredFieldsV1 = Set(fieldOrderV1)
    private static let requiredFieldsV2 = Set(fieldOrderV2)
    private static let requiredFieldsV3 = Set(fieldOrderV3)
    private static let requiredFieldsV4 = Set(fieldOrderV4)
    private static let requiredFieldsV5 = Set(fieldOrderV4)
    private static let defaultSolidHex = "68B8FF"
    private static let defaultGradientEndHex = "00E69A"

    static func encode(_ theme: Theme) -> String {
        let theme = sanitized(theme)
        let encodedName = percentEncodedName(theme.name)
        let gradientStart = (theme.gradientStartHex ?? defaultSolidHex).uppercased()
        let gradientEnd = (theme.gradientEndHex ?? defaultGradientEndHex).uppercased()

        return [
            prefixV5,
            "name=\(encodedName)",
            "mode=\(theme.colorMode.rawValue)",
            "effect=\(theme.effectStyle.rawValue)",
            "shape=\(theme.shapeProfile.rawValue)",
            "refraction=\(formatted(theme.refractionStrength))",
            "color=\(theme.colorHex.uppercased())",
            "opacity=\(formatted(theme.opacity))",
            "size=\(formatted(theme.size))",
            "width=\(formatted(theme.width))",
            "round=\(formatted(theme.glowRoundness))",
            "hard=\(formatted(theme.glowFullness))",
            "fade=\(formatted(theme.fadeDuration))",
            "gstart=\(gradientStart)",
            "gend=\(gradientEnd)"
        ].joined(separator: ";")
    }

    static func decode(_ value: String) throws -> Theme {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw invalidThemeError()
        }
        guard trimmed.count <= maximumLength else {
            throw NSError(domain: "KeyLight", code: 11, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Theme string is too large.")
            ])
        }

        let segments = trimmed.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let prefix = segments.first,
              prefix == prefixV1
                || prefix == prefixV2
                || prefix == prefixV3
                || prefix == prefixV4
                || prefix == prefixV5 else {
            throw invalidThemeError()
        }

        let requiredFields: Set<String>
        switch prefix {
        case prefixV5:
            requiredFields = requiredFieldsV5
        case prefixV4:
            requiredFields = requiredFieldsV4
        case prefixV3:
            requiredFields = requiredFieldsV3
        case prefixV2:
            requiredFields = requiredFieldsV2
        default:
            requiredFields = requiredFieldsV1
        }
        var fields: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard !segment.isEmpty,
                  let splitIndex = segment.firstIndex(of: "="),
                  splitIndex != segment.startIndex else {
                throw invalidThemeError()
            }

            let key = String(segment[..<splitIndex])
            let valueStart = segment.index(after: splitIndex)
            let parsedValue = String(segment[valueStart...])
            guard requiredFields.contains(key), fields[key] == nil else {
                throw invalidThemeError()
            }
            fields[key] = parsedValue
        }

        guard Set(fields.keys) == requiredFields,
              let encodedName = fields["name"],
              let decodedName = encodedName.removingPercentEncoding,
              let modeRaw = fields["mode"],
              let mode = ColorMode(rawValue: modeRaw) else {
            throw invalidThemeError()
        }

        let effectStyle: EffectStyle
        if prefix == prefixV2
            || prefix == prefixV3
            || prefix == prefixV4
            || prefix == prefixV5 {
            guard let effectRaw = fields["effect"],
                  let parsedEffect = EffectStyle(rawValue: effectRaw) else {
                throw invalidThemeError()
            }
            if prefix != prefixV5, parsedEffect == .classicPlus {
                throw invalidThemeError()
            }
            effectStyle = parsedEffect.supportedStyle
        } else {
            effectStyle = .classicGlow
        }

        let shapeProfile: SurfaceShapeProfile
        if prefix == prefixV3 || prefix == prefixV4 || prefix == prefixV5 {
            guard let shapeRaw = fields["shape"],
                  let parsedShape = SurfaceShapeProfile.persistedValue(
                      rawValue: shapeRaw
                  ) else {
                throw invalidThemeError()
            }
            shapeProfile = parsedShape
        } else {
            shapeProfile = .currentWave
        }

        let refractionStrength: Double
        if prefix == prefixV4 || prefix == prefixV5 {
            guard let parsedRefraction = parsedNumber(
                fields["refraction"]
            ) else {
                throw invalidThemeError()
            }
            refractionStrength = parsedRefraction
        } else {
            refractionStrength = 1.0
        }

        guard let color = fields["color"],
              let opacity = parsedNumber(fields["opacity"]),
              let size = parsedNumber(fields["size"]),
              let width = parsedNumber(fields["width"]),
              let roundness = parsedNumber(fields["round"]),
              let hardness = parsedNumber(fields["hard"]),
              let fade = parsedNumber(fields["fade"]),
              let gradientStart = fields["gstart"],
              let gradientEnd = fields["gend"] else {
            throw invalidThemeError()
        }

        return sanitized(
            Theme(
                name: decodedName,
                colorHex: color,
                opacity: opacity,
                refractionStrength: refractionStrength,
                size: size,
                width: width,
                glowRoundness: roundness,
                glowFullness: hardness,
                fadeDuration: fade,
                colorMode: mode,
                effectStyle: effectStyle,
                shapeProfile: shapeProfile,
                gradientStartHex: gradientStart,
                gradientEndHex: gradientEnd
            )
        )
    }

    private static func sanitized(_ theme: Theme) -> Theme {
        var sanitized = theme
        sanitized.name = PersistenceValidation.normalizedName(theme.name) ?? "Imported Theme"
        sanitized.colorHex = sanitizedHex(theme.colorHex)
        sanitized.opacity = validated(theme.opacity, range: 0.0...1.0, default: 0.8013)
        sanitized.refractionStrength = validated(
            theme.refractionStrength,
            range: 0.5...2.5,
            default: 1.0
        )
        sanitized.size = validated(theme.size, range: 4.0...200.0, default: 80.5536)
        sanitized.width = validated(theme.width, range: 0.1...5.0, default: 1.0)
        sanitized.glowRoundness = validated(theme.glowRoundness, range: 0.0...1.0, default: 0.7069)
        sanitized.glowFullness = validated(theme.glowFullness, range: 0.0...1.0, default: 0.6046)
        sanitized.fadeDuration = validated(theme.fadeDuration, range: 0.05...5.0, default: 1.0004)
        sanitized.effectStyle = (
            EffectStyle(rawValue: theme.effectStyle.rawValue) ?? .classicGlow
        ).supportedStyle
        sanitized.shapeProfile = .currentWave
        sanitized.gradientStartHex = sanitizedHex(theme.gradientStartHex ?? defaultSolidHex)
        sanitized.gradientEndHex = sanitizedHex(theme.gradientEndHex ?? defaultGradientEndHex)
        return sanitized
    }

    private static func sanitizedHex(_ hex: String) -> String {
        let valid = hex.prefix(6).filter { "0123456789ABCDEFabcdef".contains($0) }
        guard !valid.isEmpty else { return defaultSolidHex }
        return String(valid).padding(toLength: 6, withPad: "0", startingAt: 0)
    }

    private static func validated(
        _ value: Double,
        range: ClosedRange<Double>,
        default defaultValue: Double
    ) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private static func parsedNumber(_ raw: String?) -> Double? {
        guard let raw, let parsed = Double(raw), parsed.isFinite else { return nil }
        return parsed
    }

    private static func percentEncodedName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func invalidThemeError() -> NSError {
        NSError(domain: "KeyLight", code: 10, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "Invalid theme string.")
        ])
    }
}
