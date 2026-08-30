import Foundation

/// Pure codec for KeyLight's established layout-profile JSON transfer format.
/// It validates and normalizes a complete value before returning it and owns no
/// defaults, UI, or live editor state.
enum LayoutProfileCodec {
    private static let schemaVersion = 1
    private static let invalidProfileMessage = String(
        localized: "The file is not a valid KeyLight layout profile."
    )
    private static let allowedKeyCodes = Set(KeyboardLayoutInfo.allKeys.map(\.id))

    private struct Payload: Codable {
        var version: Int
        var kind: String?
        var name: String
        var keyOffsets: [String: CGFloat]
        var keyWidthOverrides: [String: CGFloat]?
    }

    static func encode(_ profile: KeyMappingProfile) -> Data? {
        guard let normalizedName = PersistenceValidation.normalizedName(profile.name) else {
            return nil
        }

        let offsets = normalizedValues(
            profile.keyOffsets.reduce(into: [String: CGFloat]()) { result, pair in
                result[String(pair.key)] = pair.value
            },
            range: -0.5...0.5
        )
        let widths = normalizedValues(
            profile.keyWidthOverrides.reduce(into: [String: CGFloat]()) { result, pair in
                result[String(pair.key)] = pair.value
            },
            range: 0.1...5.0
        )

        let payload = Payload(
            version: schemaVersion,
            kind: "layoutProfile",
            name: normalizedName,
            keyOffsets: stringKeyed(offsets),
            keyWidthOverrides: stringKeyed(widths)
        )
        return try? JSONEncoder().encode(payload)
    }

    static func decode(_ data: Data) throws -> KeyMappingProfile {
        guard data.count <= PersistenceValidation.maximumLayoutImportSize else {
            throw NSError(domain: "KeyLight", code: 20, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Layout profile file is too large (max 1MB).")
            ])
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw invalidProfileError()
        }

        guard payload.version <= schemaVersion else {
            throw NSError(domain: "KeyLight", code: 22, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Unsupported layout profile version (\(payload.version)). Please update KeyLight.")
            ])
        }
        if let kind = payload.kind, kind != "layoutProfile" {
            throw invalidProfileError()
        }

        guard PersistenceValidation.layoutEntryCountIsValid(
            offsetKeys: payload.keyOffsets.keys,
            widthKeys: (payload.keyWidthOverrides ?? [:]).keys
        ) else {
            throw NSError(domain: "KeyLight", code: 25, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Layout profile contains too many key entries (max 512).")
            ])
        }

        guard let normalizedName = PersistenceValidation.normalizedName(payload.name) else {
            throw NSError(domain: "KeyLight", code: 23, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Layout profile name is missing.")
            ])
        }

        return KeyMappingProfile(
            name: normalizedName,
            keyOffsets: normalizedValues(payload.keyOffsets, range: -0.5...0.5),
            keyWidthOverrides: normalizedValues(payload.keyWidthOverrides ?? [:], range: 0.1...5.0)
        )
    }

    private static func normalizedValues(
        _ values: [String: CGFloat],
        range: ClosedRange<CGFloat>
    ) -> [UInt16: CGFloat] {
        var decoded: [UInt16: CGFloat] = [:]
        decoded.reserveCapacity(values.count)
        for (key, value) in values {
            guard let keyCode = UInt16(key), value.isFinite else { continue }
            decoded[keyCode] = value
        }

        var canonicalValues: [UInt16: CGFloat] = [:]
        var aliasFallbackValues: [UInt16: CGFloat] = [:]
        for keyCode in decoded.keys.sorted() {
            guard let value = decoded[keyCode], value.isFinite else { continue }
            let canonicalKeyCode = KeyboardLayoutInfo.canonicalKeyCode(for: keyCode)
            guard allowedKeyCodes.contains(canonicalKeyCode) else { continue }

            let clamped = min(max(value, range.lowerBound), range.upperBound)
            if keyCode == canonicalKeyCode {
                canonicalValues[canonicalKeyCode] = clamped
            } else if aliasFallbackValues[canonicalKeyCode] == nil {
                aliasFallbackValues[canonicalKeyCode] = clamped
            }
        }

        var normalized = aliasFallbackValues
        for (keyCode, value) in canonicalValues {
            normalized[keyCode] = value
        }
        return normalized
    }

    private static func stringKeyed(_ values: [UInt16: CGFloat]) -> [String: CGFloat] {
        values.reduce(into: [String: CGFloat]()) { result, pair in
            result[String(pair.key)] = pair.value
        }
    }

    private static func invalidProfileError() -> NSError {
        NSError(domain: "KeyLight", code: 21, userInfo: [
            NSLocalizedDescriptionKey: invalidProfileMessage
        ])
    }
}
