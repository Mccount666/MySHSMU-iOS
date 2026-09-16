import XCTest
@testable import MySHSMU

/// The wire format is the part of this port that cannot be checked by reading
/// the code: a single mis-encoded `+` in the form body corrupts the encrypted
/// password and the server rejects every login.
final class WireEncodingTests: XCTestCase {

    func testFormEncodingEscapesBase64Punctuation() {
        // Base64 ciphertext contains exactly these three specials.
        XCTAssertEqual(WireEncoding.percentEncode("a+b/c=", spaceAsPlus: true), "a%2Bb%2Fc%3D")
    }

    func testFormEncodingUsesPlusForSpace() {
        XCTAssertEqual(WireEncoding.percentEncode("a b", spaceAsPlus: true), "a+b")
        XCTAssertEqual(WireEncoding.percentEncode("a b"), "a%20b")
    }

    func testQueryEncodingLeavesUnreservedCharactersAlone() {
        XCTAssertEqual(WireEncoding.percentEncode("2026-09-16"), "2026-09-16")
        XCTAssertEqual(WireEncoding.percentEncode("aZ0-._~"), "aZ0-._~")
    }

    func testQueryEncodingEscapesChineseAsUTF8() {
        // Used by the classroom API's `state=通过` parameter.
        XCTAssertEqual(WireEncoding.percentEncode("通过"), "%E9%80%9A%E8%BF%87")
    }

    func testFormBodyJoinsPairsWithAmpersand() {
        let body = WireEncoding.formBody([
            FormField(name: "username", value: "20230001"),
            FormField(name: "password", value: "a+b="),
        ])
        XCTAssertEqual(String(data: body, encoding: .utf8), "username=20230001&password=a%2Bb%3D")
    }

    func testAppendingQueryKeepsABareMarkerParameter() {
        let url = URL(string: "https://example.com/GetCalendarTable?vpn-12-o2-host")!
        let result = WireEncoding.appendingQuery(to: url, parameters: [
            ("MCSID", "A1B2"),
            ("CurriculumType", "理论课"),
        ])
        XCTAssertEqual(
            result.absoluteString,
            "https://example.com/GetCalendarTable?vpn-12-o2-host&MCSID=A1B2&CurriculumType=%E7%90%86%E8%AE%BA%E8%AF%BE"
        )
    }

    func testAppendingQuerySkipsNilParameters() {
        let url = URL(string: "https://example.com/dict")!
        let result = WireEncoding.appendingQuery(to: url, parameters: [
            ("type", "AnswerAuxiliaryCampus"),
            ("Area", nil),
            ("BuildCode", nil),
        ])
        XCTAssertEqual(result.absoluteString, "https://example.com/dict?type=AnswerAuxiliaryCampus")
    }

    func testAppConfigNeverDoublesPathSlashes() {
        // The Kotlin source concatenates onto a base that already ends in "/".
        let base = URL(string: "https://host/https/TOKEN/")!
        XCTAssertEqual(
            AppConfig.url(base, "Home/GetCurriculumTable").absoluteString,
            "https://host/https/TOKEN/Home/GetCurriculumTable"
        )
        XCTAssertEqual(
            AppConfig.url(base, "/Home/GetCurriculumTable").absoluteString,
            "https://host/https/TOKEN/Home/GetCurriculumTable"
        )
    }
}
