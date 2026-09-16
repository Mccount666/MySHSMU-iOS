import Foundation
import Security

enum RsaCryptoError: LocalizedError {
    case invalidPEM
    case invalidKey
    case unsupportedAlgorithm
    case encryptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPEM: return "无法解析加密公钥"
        case .invalidKey: return "无法加载加密公钥"
        case .unsupportedAlgorithm: return "当前设备不支持 RSA 加密"
        case .encryptionFailed(let reason): return "密码加密失败：\(reason)"
        }
    }
}

/// RSA PKCS#1 v1.5 encryption of the login password, matching
/// `utils/RsaCrypto.kt`.
///
/// `SecKeyCreateWithData` wants a bare PKCS#1 `RSAPublicKey` while PEM files
/// normally carry an X.509 `SubjectPublicKeyInfo` wrapper, so the wrapper is
/// stripped before the key is handed to Security.
enum RsaCrypto {

    static func loadPublicKey(pem: String) throws -> SecKey {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PUBLIC KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        guard let der = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
            throw RsaCryptoError.invalidPEM
        }
        guard let pkcs1 = pkcs1PublicKey(fromDER: der) else {
            throw RsaCryptoError.invalidKey
        }

        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        if let bits = modulusBitCount(pkcs1DER: pkcs1) {
            attributes[kSecAttrKeySizeInBits as String] = bits
        }

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown"
            Log.error("RsaCrypto", "SecKeyCreateWithData failed: \(reason)")
            throw RsaCryptoError.invalidKey
        }
        return key
    }

    /// Encrypts `password` and returns base64 with no line wrapping, the same
    /// shape Kotlin's `Base64.encodeToString(out, Base64.NO_WRAP)` produces.
    static func encryptPassword(_ password: String, publicKeyPEM: String) throws -> String {
        let key = try loadPublicKey(pem: publicKeyPEM)
        let plaintext = Data(password.utf8)

        guard SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionPKCS1) else {
            throw RsaCryptoError.unsupportedAlgorithm
        }

        var error: Unmanaged<CFError>?
        guard let ciphertext = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, plaintext as CFData, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown"
            Log.error("RsaCrypto", "Encryption failed: \(reason)")
            throw RsaCryptoError.encryptionFailed(reason)
        }
        return (ciphertext as Data).base64EncodedString()
    }

    // MARK: - DER handling

    /// Unwraps `SubjectPublicKeyInfo` and returns the inner PKCS#1 key.
    ///
    /// `SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { RSAPublicKey } }`
    /// becomes `SEQUENCE { INTEGER modulus, INTEGER exponent }`. Input that is
    /// already PKCS#1 (its first element is an INTEGER) is passed through.
    static func pkcs1PublicKey(fromDER der: Data) -> Data? {
        var reader = DERReader(der)
        guard let outer = reader.readConstructed(tag: 0x30) else { return nil }

        var inner = DERReader(outer)
        guard let first = inner.peekTag() else { return nil }

        if first == 0x02 {
            // Already a bare RSAPublicKey.
            return der
        }
        guard first == 0x30 else { return nil }

        // Skip the AlgorithmIdentifier, then unwrap the BIT STRING.
        guard inner.readConstructed(tag: 0x30) != nil else { return nil }
        guard let bitString = inner.readPrimitive(tag: 0x03), !bitString.isEmpty else { return nil }
        // The first byte of a BIT STRING counts unused trailing bits; for a DER
        // encoded key it is always zero.
        return Data(bitString.dropFirst())
    }

    /// Bit length of the modulus, read from the first INTEGER of the PKCS#1
    /// structure. Passing this to Security avoids it having to guess.
    static func modulusBitCount(pkcs1DER der: Data) -> Int? {
        var reader = DERReader(der)
        guard let sequence = reader.readConstructed(tag: 0x30) else { return nil }
        var inner = DERReader(sequence)
        guard let modulus = inner.readPrimitive(tag: 0x02) else { return nil }

        var bytes = Array(modulus)
        while let first = bytes.first, first == 0x00 { bytes.removeFirst() }
        guard let firstByte = bytes.first else { return nil }

        let leadingZeroBits = firstByte.leadingZeroBitCount
        return bytes.count * 8 - leadingZeroBits
    }
}

/// Just enough ASN.1 BER/DER to walk the two structures above.
struct DERReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    init(_ slice: ArraySlice<UInt8>) {
        bytes = Array(slice)
    }

    var isAtEnd: Bool { offset >= bytes.count }

    func peekTag() -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    /// Reads a constructed element (a SEQUENCE) and returns its contents.
    mutating func readConstructed(tag: UInt8) -> ArraySlice<UInt8>? {
        readElement(expectedTag: tag)
    }

    /// Reads a primitive element (INTEGER, BIT STRING, …) and returns its
    /// contents.
    mutating func readPrimitive(tag: UInt8) -> ArraySlice<UInt8>? {
        readElement(expectedTag: tag)
    }

    private mutating func readElement(expectedTag: UInt8) -> ArraySlice<UInt8>? {
        guard offset < bytes.count, bytes[offset] == expectedTag else { return nil }
        offset += 1

        guard offset < bytes.count else { return nil }
        var length = Int(bytes[offset])
        offset += 1

        if length & 0x80 != 0 {
            let lengthBytes = length & 0x7F
            guard lengthBytes > 0, lengthBytes <= 4, offset + lengthBytes <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<lengthBytes {
                value = (value << 8) | Int(bytes[offset])
                offset += 1
            }
            length = value
        }

        guard length >= 0, offset + length <= bytes.count else { return nil }
        let start = offset
        offset += length
        return bytes[start..<(start + length)]
    }

    mutating func skip() {
        _ = readElement(expectedTag: peekTag() ?? 0)
    }
}
