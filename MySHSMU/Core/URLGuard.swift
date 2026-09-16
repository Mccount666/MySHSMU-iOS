import Foundation

enum URLGuardError: LocalizedError, Equatable {
    case unsupportedScheme(String)
    case missingHost
    case blockedHost(String)
    case nonPublicAddress(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme):
            return "不支持的协议：\(scheme)"
        case .missingHost:
            return "请求地址缺少主机名"
        case .blockedHost(let host):
            return "禁止访问的主机：\(host)"
        case .nonPublicAddress(let host):
            return "禁止访问的内网地址：\(host)"
        }
    }
}

/// Pre-flight validation applied to every outgoing request.
///
/// The app talks to a fixed set of public HTTPS endpoints, but one of them
/// (the CAS login form) hands back a `form action` that we then POST to. That
/// makes the destination partly server-controlled, so the URL is checked before
/// it is fetched: only `http`/`https`, no loopback or private network targets,
/// and no reserved ranges.
enum URLGuard {

    private static let blockedSuffixes = [".localhost", ".local", ".internal", ".home.arpa"]

    /// Suffixes that are only reachable from the local network and must never
    /// be contacted even if a DNS answer points there.
    static func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw URLGuardError.unsupportedScheme(url.scheme ?? "(none)")
        }
        guard let host = url.host, !host.isEmpty else {
            throw URLGuardError.missingHost
        }

        let lowercased = host.lowercased()
        if lowercased == "localhost" || blockedSuffixes.contains(where: { lowercased.hasSuffix($0) }) {
            throw URLGuardError.blockedHost(host)
        }

        // A literal address is judged directly; a name is resolved and every
        // answer must be publicly routable. Results are cached because the same
        // handful of hosts is contacted on every screen.
        if let literal = IPAddress(lowercased) {
            guard literal.isPublic else { throw URLGuardError.nonPublicAddress(host) }
            return
        }

        guard !ResolvedAddressCache.shared.hasNonPublicAddress(for: host) else {
            throw URLGuardError.nonPublicAddress(host)
        }
    }

    /// Convenience wrapper used right before a request is handed to URLSession.
    static func validated(_ url: URL) throws -> URL {
        try validate(url)
        return url
    }
}

// MARK: - Address classification

/// Minimal IPv4/IPv6 literal parser plus the "is this routable on the public
/// internet" test.
struct IPAddress {
    let isPublic: Bool

    init?(_ text: String) {
        let trimmed = text.hasPrefix("[") && text.hasSuffix("]")
            ? String(text.dropFirst().dropLast())
            : text

        if trimmed.contains(":") {
            guard let blocked = IPAddress.classifyIPv6(trimmed) else { return nil }
            self.isPublic = !blocked
        } else {
            guard let blocked = IPAddress.classifyIPv4(trimmed) else { return nil }
            self.isPublic = !blocked
        }
    }

    /// Returns `true` when the address is loopback, private, link-local,
    /// multicast, reserved or unspecified.
    private static func classifyIPv4(_ text: String) -> Bool? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets = [Int]()
        for part in parts {
            guard !part.isEmpty, part.count <= 3, let value = Int(part), (0...255).contains(value) else {
                return nil
            }
            octets.append(value)
        }
        let a = octets[0], b = octets[1]

        switch a {
        case 0: return true                      // "this network"
        case 10: return true                     // private
        case 127: return true                    // loopback
        case 100 where (64...127).contains(b): return true      // carrier-grade NAT
        case 169 where b == 254: return true                     // link-local
        case 172 where (16...31).contains(b): return true        // private
        case 192 where b == 0: return true                       // 192.0.0.0/24 and 192.0.2.0/24
        case 192 where b == 168: return true                     // private
        case 198 where b == 18 || b == 19: return true            // benchmarking
        case 198 where b == 51 && octets[2] == 100: return true   // TEST-NET-2
        case 203 where b == 0 && octets[2] == 113: return true    // TEST-NET-3
        case 224...239: return true              // multicast
        case 240...255: return true              // reserved and broadcast
        default: return false
        }
    }

    /// Returns `true` when the address is loopback, link-local, unique-local,
    /// multicast or otherwise not globally routable.
    private static func classifyIPv6(_ text: String) -> Bool? {
        // Strip a zone identifier such as `fe80::1%en0`.
        let address = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        let groups = expandIPv6(address)
        guard let groups, groups.count == 8 else { return nil }

        let isUnspecified = groups.allSatisfy { $0 == 0 }
        let isLoopback = groups[0...6].allSatisfy { $0 == 0 } && groups[7] == 1
        let isLinkLocal = (groups[0] & 0xFFC0) == 0xFE80
        let isUniqueLocal = (groups[0] & 0xFE00) == 0xFC00
        let isMulticast = (groups[0] & 0xFF00) == 0xFF00
        // IPv4-mapped (::ffff:a.b.c.d) inherits the v4 classification.
        let isIPv4Mapped = groups[0...5].allSatisfy { $0 == 0 } && groups[5] == 0xFFFF
        if isIPv4Mapped {
            let high = groups[6], low = groups[7]
            let dotted = "\(high >> 8).\(high & 0xFF).\(low >> 8).\(low & 0xFF)"
            return classifyIPv4(dotted) ?? true
        }

        return isUnspecified || isLoopback || isLinkLocal || isUniqueLocal || isMulticast
    }

    /// Expands `::` shorthand into eight 16-bit groups.
    private static func expandIPv6(_ text: String) -> [Int]? {
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        func parseGroups(_ chunk: String) -> [Int]? {
            guard !chunk.isEmpty else { return [] }
            var result = [Int]()
            for piece in chunk.split(separator: ":", omittingEmptySubsequences: false) {
                guard piece.count <= 4,
                      let value = Int(piece, radix: 16) else { return nil }
                result.append(value)
            }
            return result
        }

        guard let head = parseGroups(halves[0]) else { return nil }
        if halves.count == 1 { return head }
        guard let tail = parseGroups(halves[1]) else { return nil }
        let fill = 8 - head.count - tail.count
        guard fill >= 0 else { return nil }
        return head + Array(repeating: 0, count: fill) + tail
    }
}

/// Caches DNS answers so the guard does not add a lookup to every request.
private final class ResolvedAddressCache {
    static let shared = ResolvedAddressCache()

    private let lock = NSLock()
    private var cache: [String: (blocked: Bool, expires: Date)] = [:]
    private let lifetime: TimeInterval = 300

    func hasNonPublicAddress(for host: String) -> Bool {
        lock.lock()
        if let entry = cache[host], entry.expires > Date() {
            lock.unlock()
            return entry.blocked
        }
        lock.unlock()

        let blocked = ResolvedAddressCache.lookup(host).contains { !$0.isPublic }

        lock.lock()
        cache[host] = (blocked, Date().addingTimeInterval(lifetime))
        lock.unlock()
        return blocked
    }

    /// Resolves `host` to its addresses. An unresolvable name is not treated as
    /// blocked — the request itself will fail with a clearer error than we could
    /// raise here.
    private static func lookup(_ host: String) -> [IPAddress] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let head = info else { return [] }
        defer { freeaddrinfo(head) }

        var addresses = [IPAddress]()
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let node = cursor {
            if let sa = node.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, node.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(cString: buffer)
                    if let address = IPAddress(text) { addresses.append(address) }
                }
            }
            cursor = node.pointee.ai_next
        }
        return addresses
    }
}
