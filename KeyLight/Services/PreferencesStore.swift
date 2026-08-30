import Foundation

/// Injectable adapter for KeyLight's existing UserDefaults persistence.
///
/// The adapter deliberately mirrors only the operations used by
/// `SettingsManager`; it is not a second persistence system or a generic data
/// access framework.
final class PreferencesStore: @unchecked Sendable {
    static let standard = PreferencesStore(userDefaults: .standard)

    private let userDefaults: UserDefaults
    let usesSystemPreferences: Bool

    init(
        userDefaults: UserDefaults,
        usesSystemPreferences: Bool? = nil
    ) {
        self.userDefaults = userDefaults
        self.usesSystemPreferences = usesSystemPreferences
            ?? (userDefaults === UserDefaults.standard)
    }

    func object(forKey key: String) -> Any? {
        userDefaults.object(forKey: key)
    }

    func string(forKey key: String) -> String? {
        userDefaults.string(forKey: key)
    }

    func data(forKey key: String) -> Data? {
        userDefaults.data(forKey: key)
    }

    func dictionary(forKey key: String) -> [String: Any]? {
        userDefaults.dictionary(forKey: key)
    }

    func bool(forKey key: String) -> Bool {
        userDefaults.bool(forKey: key)
    }

    func integer(forKey key: String) -> Int {
        userDefaults.integer(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) {
        userDefaults.set(value, forKey: key)
    }

    func removeObject(forKey key: String) {
        userDefaults.removeObject(forKey: key)
    }
}
