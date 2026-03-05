import Foundation
import SwiftUI
import ServiceManagement
import AppKit

/// Manages persistent storage of all app settings
@MainActor
final class SettingsManager {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard
    private static let invalidThemeStringMessage = "Invalid theme string."
    private static let themeStringPrefix = "keylight-theme-v1"
    private static let defaultThemeString = "keylight-theme-v1;name=current;mode=positionGradient;color=68B8FF;opacity=0.8013;size=80.5536;width=1.0000;round=0.7069;hard=0.6046;fade=1.0004;gstart=68B8FF;gend=00E69A"
    private static let maxThemeStringLength = 2_048
    private static let themeStringFieldOrder = [
        "name", "mode", "color", "opacity", "size", "width", "round", "hard", "fade", "gstart", "gend"
    ]
    private static let themeStringRequiredFields = Set(themeStringFieldOrder)
    private static let defaultExperienceSeedVersion = 1
    private static let defaultLayoutMigrationVersion = 1
    private static let bundledLayoutProfilesSeedVersion = 1
    private static let defaultSeededLayoutPresetID = "macbook-air-13-m4-default"
    private static let bundledMacBookProPresetID = "macbook-pro-14-m4"
    private static let defaultSeededLayoutName = "MacBook Air 13 M4 Default"
    private static let layoutProfileSchemaVersion = 1
    private static let maxLayoutProfileImportSize = 1_000_000
    private static let invalidLayoutProfileMessage = "The file is not a valid KeyLight layout profile."
    private static let defaultSolidHex = "68B8FF"
    private static let defaultGradientEndHex = "00E69A"
    private static let maxGradientPresetCount = 24

    // Keys for UserDefaults
    private enum Keys {
        static let isEnabled = "isEnabled"
        static let glowColorHex = "glowColorHex"
        static let glowOpacity = "glowOpacity"
        static let glowSize = "glowSize"
        static let glowWidth = "glowWidth"
        static let glowRoundness = "glowRoundness"
        static let glowFullness = "glowFullness"
        static let fadeDuration = "fadeDuration"
        static let fadeDurationDefaultMigratedV2 = "fadeDurationDefaultMigratedV2"
        static let launchAtLogin = "launchAtLogin"
        static let colorMode = "colorMode"
        static let savedThemes = "savedThemes"
        static let currentThemeName = "currentThemeName"
        static let keyMappingProfiles = "keyMappingProfiles"
        static let currentKeyMappingProfileName = "currentKeyMappingProfileName"
        static let gradientStartHex = "gradientStartHex"
        static let gradientEndHex = "gradientEndHex"
        static let gradientPresets = "gradientPresets"
        static let defaultExperienceSeedVersion = "defaultExperienceSeedVersion"
        static let defaultLayoutMigrationVersion = "defaultLayoutMigrationVersion"
        static let bundledLayoutProfilesSeedVersion = "bundledLayoutProfilesSeedVersion"
    }

    #if DEBUG
    static let _testUserDefaultsKeyContract: [String] = [
        Keys.isEnabled,
        Keys.glowColorHex,
        Keys.glowOpacity,
        Keys.glowSize,
        Keys.glowWidth,
        Keys.glowRoundness,
        Keys.glowFullness,
        Keys.fadeDuration,
        Keys.fadeDurationDefaultMigratedV2,
        Keys.launchAtLogin,
        Keys.colorMode,
        Keys.savedThemes,
        Keys.currentThemeName,
        Keys.keyMappingProfiles,
        Keys.currentKeyMappingProfileName,
        Keys.gradientStartHex,
        Keys.gradientEndHex,
        Keys.gradientPresets,
        Keys.defaultExperienceSeedVersion,
        Keys.defaultLayoutMigrationVersion,
        Keys.bundledLayoutProfilesSeedVersion,
        KeyPositionManager.offsetsKey,
        "KeyWidthOverrides"
    ]
    #endif

    private init() {
        migrateFadeDurationDefaultIfNeeded()
        seedDefaultExperienceIfNeeded()
        applyDefaultLayoutIfMissingOnce()
        seedBundledLayoutProfilesIfNeededOnce()
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

    private func notifyStorageChanged() {
        NotificationCenter.default.post(name: .settingsStorageChanged, object: nil)
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

    var glowColorHex: String {
        get { defaults.string(forKey: Keys.glowColorHex) ?? Self.defaultSolidHex }
        set { defaults.set(newValue, forKey: Keys.glowColorHex) }
    }

    var glowOpacity: Double {
        get { validated(defaults.object(forKey: Keys.glowOpacity) as? Double ?? 0.8013, range: 0.0...1.0, default: 0.8013) }
        set { defaults.set(newValue, forKey: Keys.glowOpacity) }
    }

    var glowSize: Double {
        get { validated(defaults.object(forKey: Keys.glowSize) as? Double ?? 80.5536, range: 10.0...200.0, default: 80.5536) }
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
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            updateLaunchAtLogin(newValue)
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                KeyLightLog("Failed to update launch at login: \(error)")
                // Revert the stored value since the system state didn't change
                defaults.set(!enabled, forKey: Keys.launchAtLogin)
            }
        }
    }

    // MARK: - Color Mode

    enum ColorMode: String, CaseIterable, Codable {
        case solid = "solid"
        case positionGradient = "positionGradient"  // Left to right gradient
        case randomPerKey = "randomPerKey"
        case rainbow = "rainbow"  // Cycles through colors
    }

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

    // MARK: - Themes

    struct Theme: Codable, Identifiable {
        var id = UUID()
        var name: String
        var colorHex: String
        var opacity: Double
        var size: Double
        var width: Double
        var glowRoundness: Double
        var glowFullness: Double
        var fadeDuration: Double
        var colorMode: ColorMode
        var gradientStartHex: String?
        var gradientEndHex: String?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case colorHex
            case opacity
            case size
            case width
            case glowRoundness
            case glowFullness
            case fadeDuration
            case colorMode
            case gradientStartHex
            case gradientEndHex
        }

        init(
            id: UUID = UUID(),
            name: String,
            colorHex: String,
            opacity: Double,
            size: Double,
            width: Double,
            glowRoundness: Double = 1.0,
            glowFullness: Double = 0.5,
            fadeDuration: Double,
            colorMode: ColorMode,
            gradientStartHex: String?,
            gradientEndHex: String?
        ) {
            self.id = id
            self.name = name
            self.colorHex = colorHex
            self.opacity = opacity
            self.size = size
            self.width = width
            self.glowRoundness = glowRoundness
            self.glowFullness = glowFullness
            self.fadeDuration = fadeDuration
            self.colorMode = colorMode
            self.gradientStartHex = gradientStartHex
            self.gradientEndHex = gradientEndHex
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
            name = (try? container.decode(String.self, forKey: .name)) ?? "Imported"
            colorHex = (try? container.decode(String.self, forKey: .colorHex)) ?? "68B8FF"
            opacity = (try? container.decode(Double.self, forKey: .opacity)) ?? 0.8013
            size = (try? container.decode(Double.self, forKey: .size)) ?? 80.5536
            width = (try? container.decode(Double.self, forKey: .width)) ?? 1.0
            glowRoundness = (try? container.decode(Double.self, forKey: .glowRoundness)) ?? 0.7069
            glowFullness = (try? container.decode(Double.self, forKey: .glowFullness)) ?? 0.6046
            fadeDuration = (try? container.decode(Double.self, forKey: .fadeDuration)) ?? 1.0004

            if let mode = try? container.decode(ColorMode.self, forKey: .colorMode) {
                colorMode = mode
            } else {
                let rawMode = (try? container.decode(String.self, forKey: .colorMode)) ?? ColorMode.positionGradient.rawValue
                colorMode = rawMode == "gradient" ? .positionGradient : (ColorMode(rawValue: rawMode) ?? .positionGradient)
            }

            gradientStartHex = try? container.decode(String.self, forKey: .gradientStartHex)
            gradientEndHex = try? container.decode(String.self, forKey: .gradientEndHex)
        }

        static let defaultTheme = Theme(
            name: "current",
            colorHex: "68B8FF",
            opacity: 0.8013,
            size: 80.5536,
            width: 1.0,
            glowRoundness: 0.7069,
            glowFullness: 0.6046,
            fadeDuration: 1.0004,
            colorMode: .positionGradient,
            gradientStartHex: "68B8FF",
            gradientEndHex: "00E69A"
        )
    }

    /// Maximum data size for UserDefaults JSON reads (guards against injection from other processes)
    private static let maxUserDefaultsDataSize = 500_000  // 500KB

    var savedThemes: [Theme] {
        get {
            guard let data = defaults.data(forKey: Keys.savedThemes),
                  data.count < Self.maxUserDefaultsDataSize,
                  let themes = try? JSONDecoder().decode([Theme].self, from: data) else {
                return [Theme.defaultTheme]
            }
            return themes
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                defaults.set(data, forKey: Keys.savedThemes)
            } catch {
                KeyLightLog("Failed to save themes: \(error)")
            }
        }
    }

    var currentThemeName: String {
        get { defaults.string(forKey: Keys.currentThemeName) ?? Theme.defaultTheme.name }
        set {
            defaults.set(newValue, forKey: Keys.currentThemeName)
            notifyStorageChanged()
        }
    }

    var currentKeyMappingProfileName: String {
        get { defaults.string(forKey: Keys.currentKeyMappingProfileName) ?? "None" }
        set {
            defaults.set(newValue, forKey: Keys.currentKeyMappingProfileName)
            notifyStorageChanged()
        }
    }

    func saveTheme(_ theme: Theme) {
        var theme = theme
        theme.name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !theme.name.isEmpty else { return }
        theme.colorHex = sanitizedHex(theme.colorHex)
        theme.opacity = validated(theme.opacity, range: 0.0...1.0, default: 0.8013)
        theme.size = validated(theme.size, range: 10.0...200.0, default: 80.5536)
        theme.width = validated(theme.width, range: 0.1...5.0, default: 1.0)
        theme.glowRoundness = validated(theme.glowRoundness, range: 0.0...1.0, default: 0.7069)
        theme.glowFullness = validated(theme.glowFullness, range: 0.0...1.0, default: 0.6046)
        theme.fadeDuration = validated(theme.fadeDuration, range: 0.05...5.0, default: 1.0004)
        if let startHex = theme.gradientStartHex {
            theme.gradientStartHex = sanitizedHex(startHex)
        }
        if let endHex = theme.gradientEndHex {
            theme.gradientEndHex = sanitizedHex(endHex)
        }

        var themes = savedThemes
        if let index = themes.firstIndex(where: { $0.name == theme.name }) {
            themes[index] = theme
        } else {
            themes.append(theme)
        }
        savedThemes = themes
        notifyStorageChanged()
    }

    func deleteTheme(named name: String) {
        var themes = savedThemes
        themes.removeAll { $0.name == name }
        if themes.isEmpty {
            themes = [Theme.defaultTheme]
        }
        savedThemes = themes

        // Reset current theme if the deleted one was active
        if currentThemeName == name {
            currentThemeName = themes.first?.name ?? Theme.defaultTheme.name
        }
        notifyStorageChanged()
    }

    func restoreTheme(_ theme: Theme, at index: Int, makeCurrent: Bool) {
        var themes = savedThemes
        themes.removeAll { $0.id == theme.id }
        let safeIndex = min(max(index, 0), themes.count)
        themes.insert(theme, at: safeIndex)
        savedThemes = themes
        if makeCurrent {
            currentThemeName = theme.name
        }
        notifyStorageChanged()
    }

    func renameTheme(from oldName: String, to newName: String) {
        var themes = savedThemes
        guard let index = themes.firstIndex(where: { $0.name == oldName }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let oldNameLower = oldName.lowercased()
        let trimmedLower = trimmed.lowercased()
        let hasCollision = themes.contains { theme in
            theme.name.lowercased() == trimmedLower && theme.name.lowercased() != oldNameLower
        }
        guard !hasCollision else { return }

        themes[index].name = trimmed
        savedThemes = themes
        // Update current theme name if it was the renamed theme
        if currentThemeName == oldName {
            currentThemeName = trimmed
        }
        notifyStorageChanged()
    }

    private func sanitizedThemeForImport(_ theme: Theme, fallbackName: String = "Imported Theme") -> Theme {
        var sanitized = theme
        let trimmedName = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized.name = trimmedName.isEmpty ? fallbackName : String(trimmedName.prefix(100))
        sanitized.colorHex = sanitizedHex(theme.colorHex)
        sanitized.opacity = validated(theme.opacity, range: 0.0...1.0, default: 0.8013)
        sanitized.size = validated(theme.size, range: 10.0...200.0, default: 80.5536)
        sanitized.width = validated(theme.width, range: 0.1...5.0, default: 1.0)
        sanitized.glowRoundness = validated(theme.glowRoundness, range: 0.0...1.0, default: 0.7069)
        sanitized.glowFullness = validated(theme.glowFullness, range: 0.0...1.0, default: 0.6046)
        sanitized.fadeDuration = validated(theme.fadeDuration, range: 0.05...5.0, default: 1.0004)
        sanitized.gradientStartHex = sanitizedHex(theme.gradientStartHex ?? Self.defaultSolidHex)
        sanitized.gradientEndHex = sanitizedHex(theme.gradientEndHex ?? Self.defaultGradientEndHex)
        return sanitized
    }

    func exportThemeString(_ theme: Theme) -> String? {
        let sanitized = sanitizedThemeForImport(theme)
        let encodedName = percentEncodeThemeName(sanitized.name)
        let mode = sanitized.colorMode.rawValue
        let color = sanitized.colorHex.uppercased()
        let opacity = formatThemeNumber(sanitized.opacity)
        let size = formatThemeNumber(sanitized.size)
        let width = formatThemeNumber(sanitized.width)
        let roundness = formatThemeNumber(sanitized.glowRoundness)
        let hardness = formatThemeNumber(sanitized.glowFullness)
        let fade = formatThemeNumber(sanitized.fadeDuration)
        let gstart = (sanitized.gradientStartHex ?? Self.defaultSolidHex).uppercased()
        let gend = (sanitized.gradientEndHex ?? Self.defaultGradientEndHex).uppercased()

        return [
            Self.themeStringPrefix,
            "name=\(encodedName)",
            "mode=\(mode)",
            "color=\(color)",
            "opacity=\(opacity)",
            "size=\(size)",
            "width=\(width)",
            "round=\(roundness)",
            "hard=\(hardness)",
            "fade=\(fade)",
            "gstart=\(gstart)",
            "gend=\(gend)"
        ].joined(separator: ";")
    }

    func importThemeString(_ value: String) throws -> Theme {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw invalidThemeStringError()
        }
        guard trimmed.count <= Self.maxThemeStringLength else {
            throw NSError(domain: "KeyLight", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Theme string is too large."
            ])
        }

        let segments = trimmed.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard segments.first == Self.themeStringPrefix else {
            throw invalidThemeStringError()
        }

        var fields: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard !segment.isEmpty,
                  let splitIndex = segment.firstIndex(of: "="),
                  splitIndex != segment.startIndex else {
                throw invalidThemeStringError()
            }

            let key = String(segment[..<splitIndex])
            let valueStart = segment.index(after: splitIndex)
            let parsedValue = String(segment[valueStart...])

            guard Self.themeStringRequiredFields.contains(key),
                  fields[key] == nil else {
                throw invalidThemeStringError()
            }
            fields[key] = parsedValue
        }

        guard Set(fields.keys) == Self.themeStringRequiredFields else {
            throw invalidThemeStringError()
        }

        guard let encodedName = fields["name"],
              let decodedName = encodedName.removingPercentEncoding else {
            throw invalidThemeStringError()
        }

        guard let modeRaw = fields["mode"],
              let mode = ColorMode(rawValue: modeRaw) else {
            throw invalidThemeStringError()
        }

        guard let color = fields["color"],
              let opacity = parseThemeNumber(fields["opacity"]),
              let size = parseThemeNumber(fields["size"]),
              let width = parseThemeNumber(fields["width"]),
              let roundness = parseThemeNumber(fields["round"]),
              let hardness = parseThemeNumber(fields["hard"]),
              let fade = parseThemeNumber(fields["fade"]),
              let gstart = fields["gstart"],
              let gend = fields["gend"] else {
            throw invalidThemeStringError()
        }

        return sanitizedThemeForImport(
            Theme(
                name: decodedName,
                colorHex: color,
                opacity: opacity,
                size: size,
                width: width,
                glowRoundness: roundness,
                glowFullness: hardness,
                fadeDuration: fade,
                colorMode: mode,
                gradientStartHex: gstart,
                gradientEndHex: gend
            )
        )
    }

    private func invalidThemeStringError() -> NSError {
        NSError(domain: "KeyLight", code: 10, userInfo: [
            NSLocalizedDescriptionKey: Self.invalidThemeStringMessage
        ])
    }

    private func formatThemeNumber(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private func parseThemeNumber(_ raw: String?) -> Double? {
        guard let raw, let parsed = Double(raw), parsed.isFinite else { return nil }
        return parsed
    }

    private func percentEncodeThemeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Gradient Presets

    struct GradientPreset: Codable, Identifiable, Equatable {
        var id = UUID()
        var startHex: String
        var endHex: String
        var name: String?
    }

    private static let defaultGradientPresets: [GradientPreset] = [
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
                KeyLightLog("Failed to save gradient presets: \(error)")
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
            KeyLightLog("Unsupported bundled preset manifest version: \(manifest.version)")
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
        let preferredName = (forcedName ?? preset.displayName).trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferredName.isEmpty {
            profile.name = String(preferredName.prefix(100))
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
                NSLocalizedDescriptionKey: "Bundled presets are unavailable in this build."
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
                NSLocalizedDescriptionKey: "Bundled preset file not found: \(normalizedPath)."
            ])
        }
    }

    // MARK: - Key Mapping Profiles

    struct KeyMappingProfile: Codable, Identifiable {
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
            // Convert UInt16 keys to String for JSON compatibility
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
            id = try container.decode(UUID.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
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

    var savedKeyMappingProfiles: [KeyMappingProfile] {
        get {
            guard let data = defaults.data(forKey: Keys.keyMappingProfiles),
                  data.count < Self.maxUserDefaultsDataSize,
                  let profiles = try? JSONDecoder().decode([KeyMappingProfile].self, from: data) else {
                return []
            }
            return profiles
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                defaults.set(data, forKey: Keys.keyMappingProfiles)
            } catch {
                KeyLightLog("Failed to save key mapping profiles: \(error)")
            }
        }
    }

    func saveKeyMappingProfile(_ profile: KeyMappingProfile) {
        var profiles = savedKeyMappingProfiles
        if let index = profiles.firstIndex(where: { $0.name == profile.name }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        savedKeyMappingProfiles = profiles
        currentKeyMappingProfileName = profile.name
        notifyStorageChanged()
    }

    func deleteKeyMappingProfile(named name: String) {
        var profiles = savedKeyMappingProfiles
        profiles.removeAll { $0.name == name }
        savedKeyMappingProfiles = profiles
        if currentKeyMappingProfileName == name {
            currentKeyMappingProfileName = profiles.first?.name ?? "None"
        }
        notifyStorageChanged()
    }

    func restoreKeyMappingProfile(_ profile: KeyMappingProfile, at index: Int, makeCurrent: Bool) {
        var profiles = savedKeyMappingProfiles
        profiles.removeAll { $0.id == profile.id }
        let safeIndex = min(max(index, 0), profiles.count)
        profiles.insert(profile, at: safeIndex)
        savedKeyMappingProfiles = profiles
        if makeCurrent {
            currentKeyMappingProfileName = profile.name
        }
        notifyStorageChanged()
    }

    func renameKeyMappingProfile(from oldName: String, to newName: String) {
        var profiles = savedKeyMappingProfiles
        guard let index = profiles.firstIndex(where: { $0.name == oldName }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let oldNameLower = oldName.lowercased()
        let trimmedLower = trimmed.lowercased()
        let hasCollision = profiles.contains { profile in
            profile.name.lowercased() == trimmedLower && profile.name.lowercased() != oldNameLower
        }
        guard !hasCollision else { return }

        profiles[index].name = trimmed
        savedKeyMappingProfiles = profiles
        if currentKeyMappingProfileName == oldName {
            currentKeyMappingProfileName = trimmed
        }
        notifyStorageChanged()
    }

    private struct LayoutProfileTransferData: Codable {
        var version: Int
        var kind: String?
        var name: String
        var keyOffsets: [String: CGFloat]
        var keyWidthOverrides: [String: CGFloat]?
    }

    private func normalizedImportedWidthOverrides(from overrides: [String: CGFloat]) -> [UInt16: CGFloat] {
        var decoded: [UInt16: CGFloat] = [:]
        decoded.reserveCapacity(overrides.count)
        for (key, value) in overrides {
            guard let keyCode = UInt16(key), value.isFinite else { continue }
            decoded[keyCode] = value
        }

        let allowedKeyCodes = Set(KeyboardLayoutInfo.allKeys.map(\.id))
        var canonicalValues: [UInt16: CGFloat] = [:]
        var aliasFallbackValues: [UInt16: CGFloat] = [:]

        for keyCode in decoded.keys.sorted() {
            guard let value = decoded[keyCode], value.isFinite else { continue }
            let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
            guard allowedKeyCodes.contains(canonicalKeyCode) else { continue }

            let clamped = min(max(value, 0.1), 5.0)
            if keyCode == canonicalKeyCode {
                canonicalValues[canonicalKeyCode] = clamped
            } else if aliasFallbackValues[canonicalKeyCode] == nil {
                aliasFallbackValues[canonicalKeyCode] = clamped
            }
        }

        var normalized: [UInt16: CGFloat] = aliasFallbackValues
        for (keyCode, value) in canonicalValues {
            normalized[keyCode] = value
        }

        return normalized
    }

    func exportLayoutProfileData(_ profile: KeyMappingProfile) -> Data? {
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let canonicalOffsets = KeyPositionManager.normalizedImportedOffsets(
            from: profile.keyOffsets.reduce(into: [String: CGFloat]()) { result, pair in
                result[String(pair.key)] = pair.value
            }
        )
        let canonicalWidths = normalizedImportedWidthOverrides(
            from: profile.keyWidthOverrides.reduce(into: [String: CGFloat]()) { result, pair in
                result[String(pair.key)] = pair.value
            }
        )

        let payload = LayoutProfileTransferData(
            version: Self.layoutProfileSchemaVersion,
            kind: "layoutProfile",
            name: String(trimmedName.prefix(100)),
            keyOffsets: canonicalOffsets,
            keyWidthOverrides: canonicalWidths.reduce(into: [String: CGFloat]()) { result, pair in
                result[String(pair.key)] = pair.value
            }
        )

        do {
            return try JSONEncoder().encode(payload)
        } catch {
            KeyLightLog("Failed to encode layout profile export data: \(error)")
            return nil
        }
    }

    func importLayoutProfileData(_ data: Data) throws -> KeyMappingProfile {
        guard data.count <= Self.maxLayoutProfileImportSize else {
            throw NSError(domain: "KeyLight", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Layout profile file is too large (max 1MB)."
            ])
        }

        let payload: LayoutProfileTransferData
        do {
            payload = try JSONDecoder().decode(LayoutProfileTransferData.self, from: data)
        } catch {
            throw NSError(domain: "KeyLight", code: 21, userInfo: [
                NSLocalizedDescriptionKey: Self.invalidLayoutProfileMessage
            ])
        }

        guard payload.version <= Self.layoutProfileSchemaVersion else {
            throw NSError(domain: "KeyLight", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported layout profile version (\(payload.version)). Please update KeyLight."
            ])
        }
        if let kind = payload.kind, kind != "layoutProfile" {
            throw NSError(domain: "KeyLight", code: 21, userInfo: [
                NSLocalizedDescriptionKey: Self.invalidLayoutProfileMessage
            ])
        }

        let trimmedName = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(domain: "KeyLight", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "Layout profile name is missing."
            ])
        }

        let normalizedOffsets = KeyPositionManager.normalizedImportedOffsets(from: payload.keyOffsets)
            .reduce(into: [UInt16: CGFloat]()) { result, pair in
                if let keyCode = UInt16(pair.key) {
                    result[keyCode] = pair.value
                }
            }
        let normalizedWidths = normalizedImportedWidthOverrides(from: payload.keyWidthOverrides ?? [:])
        return KeyMappingProfile(
            name: String(trimmedName.prefix(100)),
            keyOffsets: normalizedOffsets,
            keyWidthOverrides: normalizedWidths
        )
    }

    private func seedDefaultExperienceIfNeeded() {
        guard defaults.integer(forKey: Keys.defaultExperienceSeedVersion) < Self.defaultExperienceSeedVersion else {
            return
        }
        guard isFreshInstallForDefaultSeed else { return }

        do {
            let seededTheme = try importThemeString(Self.defaultThemeString)
            savedThemes = [seededTheme]
            currentThemeName = seededTheme.name
            glowColorHex = seededTheme.colorHex
            glowOpacity = seededTheme.opacity
            glowSize = seededTheme.size
            glowWidth = seededTheme.width
            glowRoundness = seededTheme.glowRoundness
            glowFullness = seededTheme.glowFullness
            fadeDuration = seededTheme.fadeDuration
            colorMode = seededTheme.colorMode
            gradientStartHex = seededTheme.gradientStartHex ?? Self.defaultSolidHex
            gradientEndHex = seededTheme.gradientEndHex ?? Self.defaultGradientEndHex
        } catch {
            KeyLightLog("Failed to seed default theme: \(error)")
            return
        }

        if let preset = bundledLayoutPresets().first(where: { $0.id == Self.defaultSeededLayoutPresetID }),
           let seededLayout = try? importBundledLayoutPreset(preset, forcedName: Self.defaultSeededLayoutName) {
            persistActiveLayoutProfile(seededLayout)
        }

        defaults.set(Self.defaultExperienceSeedVersion, forKey: Keys.defaultExperienceSeedVersion)
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
        let hasOffsetData = !(defaults.dictionary(forKey: KeyPositionManager.offsetsKey) ?? [:]).isEmpty
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
        if didChange {
            notifyStorageChanged()
        }
    }

    private func persistActiveLayoutProfile(_ profile: KeyMappingProfile) {
        savedKeyMappingProfiles = [profile]
        currentKeyMappingProfileName = profile.name

        let offsets = profile.keyOffsets.reduce(into: [String: CGFloat]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
        defaults.set(offsets, forKey: KeyPositionManager.offsetsKey)

        let widths = profile.keyWidthOverrides.reduce(into: [String: CGFloat]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
        defaults.set(widths, forKey: "KeyWidthOverrides")
    }

    private var isFreshInstallForDefaultSeed: Bool {
        let keysToCheck = [
            Keys.isEnabled,
            Keys.glowColorHex,
            Keys.glowOpacity,
            Keys.glowSize,
            Keys.glowWidth,
            Keys.glowRoundness,
            Keys.glowFullness,
            Keys.fadeDuration,
            Keys.colorMode,
            Keys.gradientStartHex,
            Keys.gradientEndHex,
            Keys.savedThemes,
            Keys.currentThemeName,
            Keys.keyMappingProfiles,
            Keys.currentKeyMappingProfileName,
            KeyPositionManager.offsetsKey,
            "KeyWidthOverrides"
        ]
        return keysToCheck.allSatisfy { defaults.object(forKey: $0) == nil }
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
