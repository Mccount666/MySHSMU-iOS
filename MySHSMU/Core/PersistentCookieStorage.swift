import Foundation

/// Cookie storage that survives app restarts, mirroring
/// `network/PersistentCookieJar.kt`.
///
/// Cookies are keyed by the host of the request that received them — the same
/// coarse scheme OkHttp's jar uses — and persisted as JSON. `HTTPCookieStorage`
/// is documented as subclassable, which lets URLSession itself handle the wire
/// format (including responses that carry several `Set-Cookie` headers) while
/// the persistence policy stays ours.
final class PersistentCookieStorage: HTTPCookieStorage {

    /// The app's single cookie store.
    ///
    /// Not named `shared`: `HTTPCookieStorage` already declares a static
    /// `shared`, and Swift rejects re-declaring it as a stored property in a
    /// subclass.
    static let app = PersistentCookieStorage()

    private let defaultsKey = "CookiePrefs"
    private let store: UserDefaults
    private let lock = NSLock()
    private var memory: [String: [HTTPCookie]] = [:]

    private init(store: UserDefaults = .standard) {
        self.store = store
        super.init()
        load()
    }

    // MARK: - HTTPCookieStorage overrides

    override var cookies: [HTTPCookie]? {
        lock.lock()
        defer { lock.unlock() }
        return memory.values.flatMap { $0 }
    }

    override func getCookiesFor(_ task: URLSessionTask, completionHandler: @escaping ([HTTPCookie]?) -> Void) {
        guard let host = Self.host(of: task) else {
            completionHandler([])
            return
        }
        completionHandler(validCookies(for: host))
    }

    override func storeCookies(_ cookies: [HTTPCookie], for task: URLSessionTask) {
        guard let host = Self.host(of: task), !cookies.isEmpty else { return }
        save(cookies, for: host)
    }

    override func setCookie(_ cookie: HTTPCookie) {
        let host = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        save([cookie], for: host)
    }

    /// Drops every stored cookie, matching `PersistentCookieJar.clear()`.
    func clear() {
        lock.lock()
        memory.removeAll()
        lock.unlock()
        store.removeObject(forKey: defaultsKey)
    }

    // MARK: - Internals

    /// Session cookies arrive with no expiry. OkHttp resolves those to
    /// `Long.MAX_VALUE`; treating a missing date as "never expires" reproduces
    /// that, so a session cookie is kept until the app explicitly logs out.
    private func isExpired(_ cookie: HTTPCookie) -> Bool {
        guard let expires = cookie.expiresDate else { return false }
        return expires <= Date()
    }

    private static func host(of task: URLSessionTask) -> String? {
        task.originalRequest?.url?.host ?? task.currentRequest?.url?.host
    }

    private func validCookies(for host: String) -> [HTTPCookie] {
        lock.lock()
        let all = memory[host] ?? []
        let valid = all.filter { !isExpired($0) }
        let needsPersist = valid.count != all.count
        if needsPersist { memory[host] = valid }
        lock.unlock()

        if needsPersist { persist() }
        return valid
    }

    private func save(_ cookies: [HTTPCookie], for host: String) {
        lock.lock()
        var list = memory[host] ?? []
        for cookie in cookies {
            // Replace any cookie with the same name and domain, as the Android
            // jar does.
            list.removeAll { $0.name == cookie.name && $0.domain == cookie.domain }
            list.append(cookie)
        }
        memory[host] = list
        lock.unlock()
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = store.data(forKey: defaultsKey),
              let raw = try? JSONDecoder().decode([String: [StoredCookie]].self, from: data)
        else { return }

        var restored: [String: [HTTPCookie]] = [:]
        for (host, stored) in raw {
            let cookies = stored.compactMap { $0.toCookie() }
            if !cookies.isEmpty { restored[host] = cookies }
        }
        lock.lock()
        memory = restored
        lock.unlock()
    }

    private func persist() {
        lock.lock()
        let snapshot = memory
        lock.unlock()

        let encodable = snapshot.mapValues { $0.map(StoredCookie.init) }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        store.set(data, forKey: defaultsKey)
    }
}

/// JSON-friendly projection of an `HTTPCookie`.
private struct StoredCookie: Codable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expiresAt: Date?
    var secure: Bool
    var httpOnly: Bool

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expiresAt = cookie.expiresDate
        secure = cookie.isSecure
        httpOnly = cookie.isHTTPOnly
    }

    func toCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .secure: secure ? "TRUE" : "FALSE",
        ]
        if let expiresAt {
            properties[.expires] = expiresAt
        }
        return HTTPCookie(properties: properties)
    }
}
