import Security
import XCTest
@testable import MySHSMU

/// The login password is encrypted with the school's RSA key before it leaves
/// the device, so this path has to be exact — a wrong padding mode or a
/// mis-parsed key means every login fails.
final class RsaCryptoTests: XCTestCase {

    func testUnwrapsSubjectPublicKeyInfoFromBundledKey() throws {
        let der = try Self.derFromPEM(AppConfig.loginPublicKeyPEM)
        let pkcs1 = try XCTUnwrap(RsaCrypto.pkcs1PublicKey(fromDER: der))

        // The unwrapped form is the bare RSAPublicKey SEQUENCE.
        XCTAssertEqual(pkcs1.first, 0x30)
        XCTAssertEqual(RsaCrypto.modulusBitCount(pkcs1DER: pkcs1), 1024)
    }

    func testPassesThroughAnAlreadyUnwrappedKey() throws {
        let der = try Self.derFromPEM(AppConfig.loginPublicKeyPEM)
        let pkcs1 = try XCTUnwrap(RsaCrypto.pkcs1PublicKey(fromDER: der))

        // Feeding PKCS#1 back in must be idempotent, not an error.
        XCTAssertEqual(RsaCrypto.pkcs1PublicKey(fromDER: pkcs1), pkcs1)
    }

    func testCiphertextIsOneModulusLong() throws {
        let ciphertext = try RsaCrypto.encryptPassword(
            "hunter2",
            publicKeyPEM: AppConfig.loginPublicKeyPEM
        )
        let raw = try XCTUnwrap(Data(base64Encoded: ciphertext))

        // 1024-bit modulus, PKCS#1 v1.5 never produces a shorter block.
        XCTAssertEqual(raw.count, 128)
        // `Base64.NO_WRAP` on Android means no embedded line breaks.
        XCTAssertFalse(ciphertext.contains("\n"))
    }

    /// Encrypts with a freshly generated key and decrypts it again, which
    /// exercises the whole SPKI unwrap → `SecKey` → encrypt path end to end.
    func testRoundTripAgainstAGeneratedKeyPair() throws {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 1024,
        ]
        let privateKey = try XCTUnwrap(
            SecKeyCreateRandomKey(attributes as CFDictionary, &error),
            "key generation failed: \(error?.takeRetainedValue().localizedDescription ?? "?")"
        )
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let pkcs1 = try XCTUnwrap(
            SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
            "public key export failed"
        )

        // Re-wrap it as a PEM the way a real key file looks.
        let spki = Self.subjectPublicKeyInfo(pkcs1: pkcs1)
        let pem = """
        -----BEGIN PUBLIC KEY-----
        \(spki.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))
        -----END PUBLIC KEY-----
        """

        let password = "P@ssw0rd-测试"
        let ciphertext = try RsaCrypto.encryptPassword(password, publicKeyPEM: pem)
        let ciphertextData = try XCTUnwrap(Data(base64Encoded: ciphertext))

        let plaintext = SecKeyCreateDecryptedData(
            privateKey, .rsaEncryptionPKCS1, ciphertextData as CFData, &error
        )
        let decrypted = try XCTUnwrap(plaintext as Data?, "decryption failed")
        XCTAssertEqual(String(data: decrypted, encoding: .utf8), password)
    }

    // MARK: - Helpers

    private static func derFromPEM(_ pem: String) throws -> Data {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return try XCTUnwrap(Data(base64Encoded: base64))
    }

    /// Minimal DER writer: rebuilds
    /// `SEQUENCE { AlgorithmIdentifier, BIT STRING { pkcs1 } }`.
    private static func subjectPublicKeyInfo(pkcs1: Data) -> Data {
        let oid = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
        let null = Data([0x05, 0x00])
        let algorithm = tlv(0x30, oid + null)
        let bitString = tlv(0x03, Data([0x00]) + pkcs1)
        return tlv(0x30, algorithm + bitString)
    }

    private static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }

    private static func length(_ value: Int) -> Data {
        if value < 0x80 { return Data([UInt8(value)]) }
        var remaining = value
        var bytes: [UInt8] = []
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
