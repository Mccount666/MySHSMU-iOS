import Foundation

enum NetworkError: LocalizedError {
    case http(status: Int, body: String)
    case emptyBody
    case notTextual
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            return "HTTP \(status): \(body)"
        case .emptyBody:
            return "Response body is empty"
        case .notTextual:
            return "Response body is not text"
        case .invalidResponse:
            return "Invalid response"
        }
    }
}

/// Thin HTTP layer mirroring the OkHttp client configured in
/// `network/NetworkModule.kt`: a persistent host-keyed cookie jar, a 15 second
/// timeout, and no response caching.
final class NetworkClient: @unchecked Sendable {

    static let shared = NetworkClient()

    private let session: URLSession

    init(cookieStorage: HTTPCookieStorage = PersistentCookieStorage.app) {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = cookieStorage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        // OkHttp has no cache unless one is installed; leaving URLSession's
        // shared cache on would serve stale timetable and score payloads.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    /// GET returning the raw body. Throws only on transport failures, matching
    /// `ShsmuService.getUrlContent`, which returns `nil` for any non-2xx.
    func data(for url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: try URLGuard.validated(url))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await perform(request)
    }

    /// GET returning text, or `nil` when the server answered with a non-2xx
    /// status — the Kotlin `getUrlContent` contract.
    func text(for url: URL, headers: [String: String] = [:]) async -> String? {
        do {
            let (data, response) = try await data(for: url, headers: headers)
            guard (200...299).contains(response.statusCode) else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            Log.warn("Network", "GET \(url.absoluteString) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// GET with the JSON accept header every teaching-affairs call uses.
    func json(for url: URL, label: String) async throws -> Data {
        let (data, response) = try await data(for: url, headers: [
            "Accept": "application/json, text/javascript, */*; q=0.01",
        ])
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200...299).contains(response.statusCode) else {
            Log.error(label, "HTTP \(response.statusCode): \(body)")
            throw NetworkError.http(status: response.statusCode, body: body)
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkError.emptyBody
        }
        return data
    }

    /// POSTs an `application/x-www-form-urlencoded` body.
    func form(_ url: URL, fields: [FormField], headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: try URLGuard.validated(url))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = WireEncoding.formBody(fields)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        Log.debug("Network", "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "") -> \(http.statusCode)")
        return (data, http)
    }
}

/// Lightweight logging, tagged like the `Log.i` / `Log.e` calls in the Kotlin
/// sources. Compiled out of release builds except for warnings and errors.
enum Log {
    static func debug(_ tag: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        print("[\(tag)] \(message())")
        #endif
    }

    static func info(_ tag: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        print("[\(tag)] \(message())")
        #endif
    }

    static func warn(_ tag: String, _ message: @autoclosure () -> String) {
        print("[\(tag)] ⚠️ \(message())")
    }

    static func error(_ tag: String, _ message: @autoclosure () -> String) {
        print("[\(tag)] ❌ \(message())")
    }
}
