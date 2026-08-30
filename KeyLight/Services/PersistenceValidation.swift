import Foundation

/// Shared limits for names and the existing layout-profile transfer format.
enum PersistenceValidation {
    static let maximumNameLength = 100
    static let maximumLayoutImportSize = 1_000_000
    static let maximumLayoutEntryCount = 512

    static func normalizedName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumNameLength))
    }

    static func layoutEntryCountIsValid(
        offsetKeys: some Sequence<String>,
        widthKeys: some Sequence<String>
    ) -> Bool {
        var uniqueKeys = Set(offsetKeys)
        uniqueKeys.formUnion(widthKeys)
        return uniqueKeys.count <= maximumLayoutEntryCount
    }
}
