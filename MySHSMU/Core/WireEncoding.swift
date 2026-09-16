import Foundation

/// A `application/x-www-form-urlencoded` field, order-preserving.
struct FormField: Hashable, Sendable {
    var name: String
    var value: String
}

/// Percent-encoding that produces the same bytes OkHttp puts on the wire.
///
/// The distinction matters: `URLComponents.queryItems` leaves `&`, `=` and `+`
/// untouched because they are members of `CharacterSet.urlQueryAllowed`, so a
/// base64 RSA ciphertext (which contains `+`, `/` and `=`) would be corrupted on
/// the way out. Everything unreserved is emitted literally and everything else
/// is escaped, which is always safe — the server decodes it back to the same
/// value.
enum WireEncoding {

    /// Bytes that may appear literally: `ALPHA / DIGIT / "-" / "." / "_" / "~"`.
    private static let unreserved: Set<UInt8> = {
        var set = Set<UInt8>()
        for byte in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(byte) }
        for byte in UInt8(ascii: "A")...UInt8(ascii: "Z") { set.insert(byte) }
        for byte in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(byte) }
        for character in "-._~" { set.insert(character.asciiValue!) }
        return set
    }()

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    /// Percent-encodes a single query component or form value.
    /// `spaceAsPlus` selects the form-body convention (`+`) over the query
    /// convention (`%20`), matching OkHttp's `FormBody`.
    static func percentEncode(_ value: String, spaceAsPlus: Bool = false) -> String {
        var out = [UInt8]()
        out.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if unreserved.contains(byte) {
                out.append(byte)
            } else if byte == 0x20 && spaceAsPlus {
                out.append(UInt8(ascii: "+"))
            } else {
                out.append(UInt8(ascii: "%"))
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Builds an `application/x-www-form-urlencoded` request body.
    static func formBody(_ fields: [FormField]) -> Data {
        let encoded = fields
            .map { "\(percentEncode($0.name, spaceAsPlus: true))=\(percentEncode($0.value, spaceAsPlus: true))" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    /// Appends `name=value` pairs to a URL's query string, preserving any query
    /// already present. Used where the Kotlin code calls
    /// `HttpUrl.Builder.addQueryParameter`.
    static func appendingQuery(to url: URL, parameters: [(String, String?)]) -> URL {
        let present = parameters.compactMap { key, value -> String? in
            guard let value else { return nil }
            return "\(percentEncode(key))=\(percentEncode(value))"
        }
        guard !present.isEmpty else { return url }
        // A bare marker such as `?vpn-12-o2-host` still counts as a query.
        let joiner = url.query == nil ? "?" : "&"
        return URL(string: url.absoluteString + joiner + present.joined(separator: "&")) ?? url
    }
}
