import Foundation
import Security

/// Key/value store backing the app, replacing `SharedPreferences("auth_prefs")`.
///
/// Writes go to the App Group container when it is available so the widget
/// extension can read the cached curriculum, and fall back to standard defaults
/// otherwise. That way the app builds and runs before the group is provisioned,
/// and starts sharing automatically once it is.
final class Preferences {

    static let shared = Preferences()

    enum Key {
        static let username = "username"
        static let curriculumRangeStart = "curriculum_range_start"
        static let curriculumRangeEnd = "curriculum_range_end"
        static let curriculumJSON = "curriculum_json"
        static let firstWeekStartDate = "first_week_start_date"
        static let weekCount = "week_count"
        static let courseBlockHeight = "course_block_height"
        static let hasLoggedInOnce = "has_logged_in_once"
    }

    /// Every key the app owns, so `clearAll()` can wipe the store the way
    /// `prefs.edit { clear() }` does.
    private static let ownedKeys = [
        Key.username,
        Key.curriculumRangeStart,
        Key.curriculumRangeEnd,
        Key.curriculumJSON,
        Key.firstWeekStartDate,
        Key.weekCount,
        Key.courseBlockHeight,
        Key.hasLoggedInOnce,
    ]

    private let defaults: UserDefaults

    init(suiteName: String = AppConfig.appGroupID) {
        defaults = Preferences.resolveStore(suiteName: suiteName)
    }

    /// Only trusts the App Group when the container actually exists. An
    /// unentitled suite still hands back a usable-looking `UserDefaults` whose
    /// writes land in this app's own container, which the widget could never
    /// read — so the container URL is the real test.
    private static func resolveStore(suiteName: String) -> UserDefaults {
        guard FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName) != nil,
            let shared = UserDefaults(suiteName: suiteName) else {
            Log.info("Preferences", "App Group \(suiteName) unavailable; using standard defaults")
            return .standard
        }
        return shared
    }

    // MARK: - Typed accessors

    var username: String {
        get { defaults.string(forKey: Key.username) ?? "" }
        set { defaults.set(newValue, forKey: Key.username) }
    }

    var hasLoggedInOnce: Bool {
        get { defaults.bool(forKey: Key.hasLoggedInOnce) }
        set { defaults.set(newValue, forKey: Key.hasLoggedInOnce) }
    }

    var curriculumJSON: String? {
        get { defaults.string(forKey: Key.curriculumJSON) }
        set { defaults.set(newValue, forKey: Key.curriculumJSON) }
    }

    var curriculumRangeStart: String? {
        get { defaults.string(forKey: Key.curriculumRangeStart) }
        set { defaults.set(newValue, forKey: Key.curriculumRangeStart) }
    }

    var curriculumRangeEnd: String? {
        get { defaults.string(forKey: Key.curriculumRangeEnd) }
        set { defaults.set(newValue, forKey: Key.curriculumRangeEnd) }
    }

    var firstWeekStartDate: String? {
        get { defaults.string(forKey: Key.firstWeekStartDate) }
        set { defaults.set(newValue, forKey: Key.firstWeekStartDate) }
    }

    var weekCount: Int {
        get { defaults.integer(forKey: Key.weekCount) }
        set { defaults.set(newValue, forKey: Key.weekCount) }
    }

    var courseBlockHeight: Int {
        get {
            let stored = defaults.integer(forKey: Key.courseBlockHeight)
            return stored == 0 ? 60 : stored
        }
        set { defaults.set(newValue, forKey: Key.courseBlockHeight) }
    }

    /// Wipes every key this app writes, leaving unrelated defaults alone.
    func clearAll() {
        for key in Preferences.ownedKeys {
            defaults.removeObject(forKey: key)
        }
        SecureStore.delete(.password)
    }
}

/// Keychain wrapper for the one secret the app holds.
///
/// The Android build keeps the password in plain `SharedPreferences`; the
/// Keychain is the platform-correct place for it on iOS and costs nothing at the
/// call sites, so the credential is stored there instead.
enum SecureStore {

    enum Item: String {
        case password = "xyz.reqwey.myshsmu.password"
    }

    private static var service: String {
        Bundle.main.bundleIdentifier ?? "xyz.reqwey.myshsmu"
    }

    static func set(_ value: String, for item: Item) {
        guard let data = value.data(using: .utf8) else { return }
        delete(item)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecValueData as String: data,
            // The app is used while unlocked and never in the background, so
            // the strictest accessibility tier is appropriate.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Log.error("Keychain", "Failed to store \(item.rawValue): OSStatus \(status)")
        }
    }

    static func get(_ item: Item) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ item: Item) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
