import XCTest
@testable import MySHSMU

/// Captcha reading and evaluation. The OCR itself needs a real image, but the
/// normalisation and arithmetic that follow it are pure functions and are where
/// a porting mistake would silently break every login.
final class CaptchaSolverTests: XCTestCase {

    func testFoldsLettersThatResembleDigits() {
        XCTAssertEqual(CaptchaSolver.cleanText("1Ol"), "101")
        XCTAssertEqual(CaptchaSolver.cleanText("I2l"), "121")
        XCTAssertEqual(CaptchaSolver.cleanText("ZS"), "25")
    }

    func testMapsSymbolsToOperators() {
        XCTAssertEqual(CaptchaSolver.cleanText("3x4"), "3*4")
        XCTAssertEqual(CaptchaSolver.cleanText("6÷2"), "6/2")
        XCTAssertEqual(CaptchaSolver.cleanText("7_3"), "7-3")
    }

    func testDropsEverythingOutsideTheAllowedAlphabet() {
        XCTAssertEqual(CaptchaSolver.cleanText("a1b2"), "162")
        XCTAssertEqual(CaptchaSolver.cleanText("计算：1+1=?"), "1+1=?")
    }

    func testEvaluatesEachOperator() {
        XCTAssertEqual(CaptchaSolver.calculateExpression("1+2=?"), "3")
        XCTAssertEqual(CaptchaSolver.calculateExpression("9-4=?"), "5")
        XCTAssertEqual(CaptchaSolver.calculateExpression("3*7=?"), "21")
        XCTAssertEqual(CaptchaSolver.calculateExpression("8/2=?"), "4")
    }

    func testAcceptsABareNumber() {
        XCTAssertEqual(CaptchaSolver.calculateExpression("42"), "42")
        XCTAssertEqual(CaptchaSolver.calculateExpression("42?"), "42")
    }

    func testRejectsUnusableInput() {
        XCTAssertNil(CaptchaSolver.calculateExpression(""))
        XCTAssertNil(CaptchaSolver.calculateExpression("=?"))
        XCTAssertNil(CaptchaSolver.calculateExpression("8/0=?"))
        XCTAssertNil(CaptchaSolver.calculateExpression("+"))
    }

    func testEndToEndFromRawOcrText() {
        // Typical ML Kit / Vision output for a captcha reading "3 x 4 = ?".
        let raw = "3 x 4 = ?\n"
        XCTAssertEqual(CaptchaSolver.calculateExpression(CaptchaSolver.cleanText(raw)), "12")
    }
}
