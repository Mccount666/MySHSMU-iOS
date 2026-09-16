import Foundation

enum ShsmuError: LocalizedError {
    /// Raised when the gateway answers with the login page instead of data.
    /// `MainViewModel` keys its silent re-login on this case.
    case sessionExpired
    case pageDownloadFailed
    case loginFormMissing
    case captchaSolveFailed
    case networkFailed
    case malformedResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .sessionExpired: return "SESSION_EXPIRED"
        case .pageDownloadFailed: return "未能下载登录页面"
        case .loginFormMissing: return "没有找到登录表单"
        case .captchaSolveFailed: return "验证码AI处理失败，请再试一次"
        case .networkFailed: return "网络连接失败"
        case .malformedResponse: return "Response body is empty"
        case .message(let text): return text
        }
    }
}

/// Teaching-affairs client, ported from `service/ShsmuService.kt`.
///
/// Every call goes through the WebVPN gateway, which keeps the session in a
/// cookie. When that cookie goes stale the gateway answers with the login page
/// instead of JSON; that is detected by looking for `login_box` in the body and
/// surfaced as `ShsmuError.sessionExpired` so the caller can re-authenticate.
final class ShsmuService: @unchecked Sendable {

    private let client: NetworkClient
    private let cookieStorage: PersistentCookieStorage

    private static let loginSuccessMarker = "login_box"
    private static let maxLoginAttempts = 5

    init(client: NetworkClient = .shared, cookieStorage: PersistentCookieStorage = .app) {
        self.client = client
        self.cookieStorage = cookieStorage
    }

    // MARK: - Session

    /// `true` when the stored cookies still satisfy the gateway, i.e. the login
    /// page is no longer returned.
    func checkSessionValid() async -> Bool {
        guard let html = await client.text(for: AppConfig.loginURL) else { return false }
        return Self.isLoginSuccessful(html)
    }

    /// The gateway returns the login form (`login_box`) for unauthenticated
    /// requests, and the requested resource otherwise.
    static func isLoginSuccessful(_ content: String) -> Bool {
        !content.contains(loginSuccessMarker)
    }

    func isSessionExpired(_ error: Error) -> Bool {
        if case ShsmuError.sessionExpired = error { return true }
        return (error as NSError).localizedDescription == ShsmuError.sessionExpired.errorDescription
    }

    /// Data endpoints answer with the login page once the session lapses;
    /// raising here is what drives `MainViewModel`'s silent re-login.
    private func throwIfSessionExpired(_ body: String) throws {
        guard Self.isLoginSuccessful(body) else {
            Log.warn("ShsmuService", "Session expired while fetching data")
            throw ShsmuError.sessionExpired
        }
    }

    // MARK: - Login

    /// Runs the full CAS login: fetch the page, solve its captcha, submit the
    /// form, and retry with a fresh captcha when the answer is rejected.
    ///
    /// - Returns: `(true, "")` on success, otherwise `(false, reason)`.
    func autoLogin(username: String, password: String, publicKeyPEM: String) async -> (Bool, String) {
        let encryptedPassword: String
        do {
            encryptedPassword = try RsaCrypto.encryptPassword(password, publicKeyPEM: publicKeyPEM)
        } catch {
            Log.error("Login", "Password encryption failed: \(error.localizedDescription)")
            return (false, "错误：\(error.localizedDescription)")
        }

        var currentLoginURL = AppConfig.loginURL

        for attempt in 1...Self.maxLoginAttempts {
            // A fresh captcha and a fresh session each round.
            cookieStorage.clear()
            Log.info("Login", "Attempt \(attempt) against \(currentLoginURL.absoluteString)")

            guard let html = await client.text(for: currentLoginURL) else {
                return (false, ShsmuError.pageDownloadFailed.localizedDescription)
            }

            let submission: (url: URL, fields: [FormField])
            do {
                submission = try await buildLoginForm(
                    html: html,
                    baseURL: currentLoginURL,
                    username: username,
                    encryptedPassword: encryptedPassword
                )
            } catch {
                Log.error("Login", "Form preparation failed: \(error.localizedDescription)")
                return (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }

            do {
                let (data, response) = try await client.form(submission.url, fields: submission.fields)
                let body = String(data: data, encoding: .utf8) ?? ""

                guard (200...299).contains(response.statusCode) else {
                    return (false, ShsmuError.networkFailed.localizedDescription)
                }
                if Self.isLoginSuccessful(body) {
                    return (true, "")
                }
                // Wrong captcha: the gateway re-serves the form, so retry
                // against the URL we just posted to.
                currentLoginURL = submission.url
            } catch {
                Log.error("Login", "Submission failed: \(error.localizedDescription)")
                return (false, "错误：\(error.localizedDescription)")
            }
        }

        return (false, "用户名或密码错误")
    }

    /// Reads the login form, downloads its captcha, solves it, and returns the
    /// URL to post to along with the fully populated fields.
    func buildLoginForm(
        html: String,
        baseURL: URL,
        username: String,
        encryptedPassword: String
    ) async throws -> (url: URL, fields: [FormField]) {
        guard let form = HtmlFormParser.firstForm(in: html, baseURL: baseURL) else {
            throw ShsmuError.loginFormMissing
        }

        let submitURL = form.action ?? AppConfig.loginURL

        let captchaURL = HtmlFormParser.captchaImageURL(in: html, baseURL: baseURL)
            ?? AppConfig.url(AppConfig.casBaseURL, "captcha.jpg?vpn-1")
        Log.info("Login", "Downloading captcha from: \(captchaURL.absoluteString)")

        guard let (imageData, response) = try? await client.data(for: captchaURL),
              (200...299).contains(response.statusCode) else {
            throw ShsmuError.pageDownloadFailed
        }
        guard let answer = await CaptchaSolver.solve(imageData: imageData) else {
            throw ShsmuError.captchaSolveFailed
        }
        Log.info("Login", "Solved captcha: \(answer)")

        // Overwrite the fields in place so the payload keeps the document order
        // the server expects.
        var fields = form.fields
        let overrides: [String: String] = [
            "username": username,
            "password": encryptedPassword,
            "authcode": answer,
        ]
        for (name, value) in overrides {
            if let index = fields.firstIndex(where: { $0.name == name }) {
                fields[index].value = value
            } else {
                fields.append(FormField(name: name, value: value))
            }
        }

        return (submitURL, fields)
    }

    // MARK: - Curriculum

    /// Timetable rows between two dates (inclusive), as returned raw by the
    /// gateway.
    func getCurriculum(start: String, end: String) async throws -> [String: Any] {
        let base = AppConfig.url(AppConfig.homeBaseURL, "Home/GetCurriculumTable")
        let query = [
            AppConfig.upstreamMarker,
            "Start=\(WireEncoding.percentEncode(start))",
            "End=\(WireEncoding.percentEncode(end))",
        ].joined(separator: "&")
        guard let url = URL(string: base.absoluteString + "?" + query) else {
            throw ShsmuError.malformedResponse
        }

        Log.info("Curriculum", "Requesting: \(url.absoluteString)")
        let data = try await client.json(for: url, label: "Curriculum")
        let body = String(data: data, encoding: .utf8) ?? ""
        try throwIfSessionExpired(body)
        guard let object = JSONValue.parse(data) else { throw ShsmuError.malformedResponse }
        return object
    }

    /// Detail rows for one course block.
    func getCourseDetail(course: CourseItem) async throws -> [Any] {
        let base = AppConfig.url(AppConfig.homeBaseURL, "Home/GetCalendarTable")
        let withMarker = URL(string: base.absoluteString + "?" + AppConfig.upstreamMarker) ?? base
        let url = WireEncoding.appendingQuery(to: withMarker, parameters: [
            ("MCSID", course.ids.mcsId),
            ("CSID", String(course.ids.csId)),
            ("CurriculumID", String(course.ids.curriculumId)),
            ("XXKMID", course.ids.xxkmId),
            ("CurriculumType", course.type),
        ])

        Log.info("CourseDetail", "Requesting: \(url.absoluteString)")
        let data = try await client.json(for: url, label: "CourseDetail")
        let body = String(data: data, encoding: .utf8) ?? ""
        try throwIfSessionExpired(body)
        guard let array = JSONValue.parseArray(data) else { throw ShsmuError.malformedResponse }
        return array
    }

    // MARK: - Scores

    func getScore(grade: String, semester: Int) async throws -> [String: Any] {
        let base = AppConfig.url(AppConfig.homeBaseURL, "Score/GetStuYearScore")
        let query = [
            AppConfig.upstreamMarker,
            "Grade=\(WireEncoding.percentEncode(grade))",
            "Semester=\(semester)",
        ].joined(separator: "&")
        guard let url = URL(string: base.absoluteString + "?" + query) else {
            throw ShsmuError.malformedResponse
        }

        Log.info("Score", "Requesting: \(url.absoluteString)")
        let data = try await client.json(for: url, label: "Score")
        let body = String(data: data, encoding: .utf8) ?? ""
        try throwIfSessionExpired(body)
        guard let object = JSONValue.parse(data) else { throw ShsmuError.malformedResponse }
        return object
    }

    // MARK: - Classrooms

    /// Options for one level of the campus → building → floor → room cascade.
    /// `type` is one of `AnswerAuxiliaryCampus`, `BuildCode`,
    /// `ClassroomFloor`, `Classroom`.
    func getClassroomInfoMap(
        type: String,
        area: String?,
        buildCode: String?,
        floorNo: String?
    ) async throws -> [String: Any] {
        let base = AppConfig.url(AppConfig.jfzxBaseURL, "api/edu/jfSelectData/getDict")
        let url = WireEncoding.appendingQuery(to: base, parameters: [
            ("type", type),
            ("Area", area),
            ("BuildCode", buildCode),
            ("FloorNo", floorNo),
        ])

        Log.info("ClassroomInfoMap", "Requesting: \(url.absoluteString)")
        let data = try await client.json(for: url, label: "ClassroomInfoMap")
        let body = String(data: data, encoding: .utf8) ?? ""
        try throwIfSessionExpired(body)
        guard let object = JSONValue.parse(data) else { throw ShsmuError.malformedResponse }
        return object
    }

    /// Occupancy for one room on one day.
    func getClassroomInfoDetail(
        date: String,
        area: String,
        buildCode: String,
        floorNo: String,
        classroomId: String
    ) async throws -> [String: Any] {
        let base = AppConfig.url(AppConfig.jfzxBaseURL, "api/edu/jfTeachingcalendar/page3")
        let url = WireEncoding.appendingQuery(to: base, parameters: [
            ("state", "通过"),
            ("searchDate", date),
            ("area", area),
            // The backend really does spell it `buliding`; keep the typo.
            ("buliding", buildCode),
            ("floor", floorNo),
            ("classroomId", classroomId),
        ])

        Log.info("ClassroomInfoDetail", "Requesting: \(url.absoluteString)")
        let data = try await client.json(for: url, label: "ClassroomInfoDetail")
        let body = String(data: data, encoding: .utf8) ?? ""
        try throwIfSessionExpired(body)
        guard let object = JSONValue.parse(data) else { throw ShsmuError.malformedResponse }
        return object
    }
}
