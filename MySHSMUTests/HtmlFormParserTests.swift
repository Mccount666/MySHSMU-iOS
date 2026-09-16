import XCTest
@testable import MySHSMU

final class HtmlFormParserTests: XCTestCase {

    private let loginHTML = """
    <!DOCTYPE html>
    <html><head><!-- <form action="/decoy"> --></head>
    <body>
      <div id="login_box">
        <form id="fm1" action="/cas/login;jsessionid=ABC123?service=x" method="post">
          <input type="hidden" name="lt" value="LT-1-abc" />
          <input type="hidden" name="execution" value="e1s1">
          <input name="username" value="" autocomplete="off">
          <input type="password" name="password">
          <input name="authcode" value="">
          <input type="submit" name="submit" value="登录">
          <img id="captchaImg" src="/cas/captcha.jpg?vpn-1&amp;t=1" width="80">
        </form>
      </div>
      <script>var x = "<form action='/nope'>";</script>
    </body></html>
    """

    private let baseURL = URL(string: "https://webvpn2.shsmu.edu.cn/https/TOKEN/cas/login?service=y")!

    func testReadsActionResolvedAgainstTheDocumentBase() throws {
        let form = try XCTUnwrap(HtmlFormParser.firstForm(in: loginHTML, baseURL: baseURL))
        XCTAssertEqual(
            form.action?.absoluteString,
            "https://webvpn2.shsmu.edu.cn/cas/login;jsessionid=ABC123?service=x"
        )
    }

    func testKeepsFieldOrderAndSkipsTheSubmitButton() throws {
        let form = try XCTUnwrap(HtmlFormParser.firstForm(in: loginHTML, baseURL: baseURL))
        XCTAssertEqual(form.fields.map(\.name), ["lt", "execution", "username", "password", "authcode"])
        XCTAssertEqual(form.fields.first?.value, "LT-1-abc")
        XCTAssertFalse(form.fields.contains { $0.name == "submit" })
    }

    func testFindsTheCaptchaImageAndDecodesItsEntities() throws {
        let url = try XCTUnwrap(HtmlFormParser.captchaImageURL(in: loginHTML, baseURL: baseURL))
        XCTAssertEqual(
            url.absoluteString,
            "https://webvpn2.shsmu.edu.cn/cas/captcha.jpg?vpn-1&t=1"
        )
    }

    func testIgnoresMarkupInsideCommentsAndScripts() throws {
        let form = try XCTUnwrap(HtmlFormParser.firstForm(in: loginHTML, baseURL: baseURL))
        // The decoy form inside the comment must not win.
        XCTAssertEqual(form.fields.count, 5)
        XCTAssertNotEqual(form.action?.absoluteString, "https://webvpn2.shsmu.edu.cn/decoy")
    }

    func testResolvesUnquotedAttributeValues() throws {
        let html = "<form action=/cas/login><input type=hidden name=lt value=abc></form>"
        let form = try XCTUnwrap(HtmlFormParser.firstForm(in: html, baseURL: baseURL))
        XCTAssertEqual(form.action?.absoluteString, "https://webvpn2.shsmu.edu.cn/cas/login")
        XCTAssertEqual(form.fields, [FormField(name: "lt", value: "abc")])
    }

    func testHonoursABaseElement() throws {
        let html = """
        <html><head><base href="https://elsewhere.example/cas/"></head>
        <body><form action="login"><input name="a" value="1"></form></body></html>
        """
        let form = try XCTUnwrap(HtmlFormParser.firstForm(in: html, baseURL: baseURL))
        XCTAssertEqual(form.action?.absoluteString, "https://elsewhere.example/cas/login")
    }

    func testDecodesEntities() {
        XCTAssertEqual(
            HtmlFormParser.decodeEntities("a&amp;b&lt;c&gt;d&quot;e&#39;f&nbsp;g"),
            "a&b<c>d\"e'f\u{00A0}g"
        )
        XCTAssertEqual(HtmlFormParser.decodeEntities("&#65;&#x42;"), "AB")
    }

    func testReturnsNilWhenThereIsNoForm() {
        XCTAssertNil(HtmlFormParser.firstForm(in: "<html><body>nope</body></html>", baseURL: baseURL))
    }

    /// A stray `<` inside a tag consumes no characters under the attribute
    /// rules, so the scanner has to step past it instead of spinning.
    func testTerminatestOnMalformedMarkup() {
        let html = "<html><body><a<>x</a><form action=\"/cas/login\"><input name=\"lt\" value=\"v\"></form></body></html>"
        let form = HtmlFormParser.firstForm(in: html, baseURL: baseURL)
        XCTAssertEqual(form?.fields.first?.name, "lt")

        // Also terminates when the whole document is unterminated junk.
        _ = HtmlFormParser.firstForm(in: "<div<<<<", baseURL: baseURL)
        _ = HtmlFormParser.firstForm(in: "<form action=x", baseURL: baseURL)
        _ = HtmlFormParser.captchaImageURL(in: "<img src=<<<", baseURL: baseURL)
    }

    func testSessionExpiryIsDetectedByTheLoginMarker() {
        XCTAssertFalse(ShsmuService.isLoginSuccessful("<div id=\"login_box\">登录</div>"))
        XCTAssertTrue(ShsmuService.isLoginSuccessful("{\"List\":[],\"Total\":0}"))
    }
}
