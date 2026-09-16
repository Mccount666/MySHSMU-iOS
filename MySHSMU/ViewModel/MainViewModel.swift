import Foundation
import Observation
import UIKit
import WidgetKit

/// Port of `MainViewModel.kt`.
///
/// The Kotlin version leans on `viewModelScope.launch`; the public methods here
/// follow the same shape — they start work and return immediately — while
/// `perform*` methods hold the awaitable bodies.
@Observable
@MainActor
final class MainViewModel {

    /// Year used before the API has told us which years exist.
    ///
    /// Kotlin hard-codes `"2025-2026"` here, which is only correct for one
    /// academic year; deriving it from the current date keeps the first request
    /// useful. The response carries the authoritative list either way, so this
    /// only affects which year the very first screenful shows.
    static let defaultScoreYear: String = {        // September starts a new academic year: 2026-09 → "2026-2027".
        let calendar = AppCalendar.calendar
        let now = Date()
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let startYear = month >= 9 ? year : year - 1
        return "\(startYear)-\(startYear + 1)"
    }()

    var state = MySHSMUUiState()

    private let service: ShsmuService
    private let prefs: Preferences

    /// Mirror of the Kotlin runtime cache for the fetched date range.
    private var cachedStart: Date?
    private var cachedEnd: Date?

    /// Serialises silent re-login so a screenful of failing requests triggers
    /// only one authentication attempt.
    private var reLoginTask: Task<Bool, Never>?

    private var notificationDismissTask: Task<Void, Never>?

    private struct AutoReLoginFailed: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    init(service: ShsmuService = ShsmuService(), prefs: Preferences = .shared) {
        self.service = service
        self.prefs = prefs

        loadPersistentData()
        checkAutoLogin()
        checkForUpdates()
    }

    // MARK: - Persistence

    private func loadPersistentData() {
        if let json = prefs.curriculumJSON {
            state.curriculumJson = json
            state.courseList = CurriculumUtils.parseJsonToCourseList(json)
        }

        state.firstWeekStartDate = prefs.firstWeekStartDate
        state.weekCount = prefs.weekCount
        state.courseBlockHeight = prefs.courseBlockHeight

        if let raw = prefs.curriculumRangeStart { cachedStart = AppCalendar.date(fromISODate: raw) }
        if let raw = prefs.curriculumRangeEnd { cachedEnd = AppCalendar.date(fromISODate: raw) }
    }

    private func checkAutoLogin() {
        let user = prefs.username
        let storedPassword = SecureStore.get(.password) ?? ""

        guard !user.isEmpty, !storedPassword.isEmpty else { return }

        state.savedUsername = user
        state.savedPassword = storedPassword
        state.isLoggedIn = prefs.hasLoggedInOnce

        // A previous successful login means the stored cookies are worth
        // trusting; refresh in the background instead of showing the login form.
        if prefs.hasLoggedInOnce {
            onWeekPageChanged(Date())
            fetchScoreData()
        }
    }

    func logout() {
        prefs.clearAll()
        cachedStart = nil
        cachedEnd = nil
        PersistentCookieStorage.app.clear()
        reLoginTask?.cancel()
        reLoginTask = nil
        state = MySHSMUUiState()
    }

    // MARK: - Login

    func startLogin(user: String, password: String) {
        let username = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            updateNotification(.failed, "请将学号与密码填写完整")
            return
        }
        Task { await performLogin(username: username, password: password) }
    }

    private func performLogin(username: String, password: String) async {
        state.isLoggingIn = true
        defer { state.isLoggingIn = false }

        do {
            // An existing session cookie is still good: skip the captcha dance.
            if await service.checkSessionValid() {
                updateNotification(.success, "登录成功")
                completeLogin(username: username, password: password)
                return
            }

            updateNotification(.loading, "正在登录...")
            let (success, message) = await service.autoLogin(
                username: username,
                password: password,
                publicKeyPEM: AppConfig.loginPublicKeyPEM
            )

            if success {
                updateNotification(.success, "登录成功")
                completeLogin(username: username, password: password)
            } else {
                updateNotification(.failed, message)
            }
        }
    }

    private func completeLogin(username: String, password: String) {
        saveCredentials(username: username, password: password)
        prefs.hasLoggedInOnce = true
        state.isLoggedIn = true
        state.savedUsername = username
        state.savedPassword = password
        onWeekPageChanged(Date())
        fetchScoreData()
    }

    private func saveCredentials(username: String, password: String) {
        prefs.username = username
        SecureStore.set(password, for: .password)
    }

    // MARK: - Settings

    func updateFirstWeekStartDate(_ value: String) {
        prefs.firstWeekStartDate = value
        state.firstWeekStartDate = value
    }

    func updateWeekCount(_ value: Int) {
        prefs.weekCount = value
        state.weekCount = value
    }

    func updateCourseBlockHeight(_ value: Int) {
        prefs.courseBlockHeight = value
        state.courseBlockHeight = value
    }

    func refreshAllData() {
        let center = Date()
        fetchWeekData(from: AppCalendar.addMonths(-2, to: center), to: AppCalendar.addMonths(2, to: center))
        fetchScoreData()
    }

    // MARK: - Curriculum

    func onWeekPageChanged(_ date: Date) {
        guard let start = cachedStart, let end = cachedEnd else {
            fetchWeekData(from: AppCalendar.addWeeks(-2, to: date), to: AppCalendar.addWeeks(2, to: date))
            return
        }

        // Keep two weeks of slack on either side of what is already cached.
        let threshold = 1
        if date < AppCalendar.addWeeks(threshold, to: start) {
            fetchWeekData(from: AppCalendar.addWeeks(-4, to: date), to: start)
        } else if date > AppCalendar.addWeeks(-threshold, to: end) {
            fetchWeekData(from: end, to: AppCalendar.addWeeks(4, to: date))
        }
    }

    private func fetchWeekData(from start: Date, to end: Date) {
        guard state.isLoggedIn else { return }
        Task { await performFetchWeekData(from: start, to: end) }
    }

    private func performFetchWeekData(from start: Date, to end: Date) async {
        state.isCourseListLoading = true
        defer { state.isCourseListLoading = false }

        do {
            updateNotification(.loading, "正在加载课程...")
            let json = try await executeWithAutoReLogin {
                try await self.service.getCurriculum(
                    start: AppCalendar.isoString(start),
                    end: AppCalendar.isoString(end)
                )
            }
            mergeAndSaveCurriculumData(json, fetchStart: start, fetchEnd: end)
            updateNotification(.success, "加载成功")
        } catch let error as AutoReLoginFailed {
            handleSessionExpired(error.message)
        } catch {
            handleFailure(error)
        }
    }

    func onCourseSelected(_ course: CourseItem) {
        Task { await performCourseDetail(course) }
    }

    private func performCourseDetail(_ course: CourseItem) async {
        do {
            state.courseDetail = nil
            let rows = try await executeWithAutoReLogin {
                try await self.service.getCourseDetail(course: course)
            }
            state.courseDetail = Self.parseCourseDetail(rows)
        } catch let error as AutoReLoginFailed {
            handleSessionExpired(error.message)
        } catch {
            handleFailure(error)
        }
    }

    private static func parseCourseDetail(_ rows: [Any]) -> CourseDetail? {
        guard let object = rows.first as? [String: Any] else { return nil }
        let teacher = JSONValue.cleanString(object, "Teacher")
        let title = JSONValue.cleanString(object, "Title", default: "")
        return CourseDetail(
            name: JSONValue.cleanString(object, "CourseName"),
            college: JSONValue.cleanString(object, "College"),
            teacher: title.isEmpty ? teacher : "\(teacher) \(title)",
            content: JSONValue.cleanString(object, "Content"),
            classes: JSONValue.cleanString(object, "ClassCode"),
            location: JSONValue.cleanString(object, "Classroom_Name")
        )
    }

    /// Folds newly fetched weeks into the cached timetable and persists the
    /// result, so the widget and the next cold start both see the full range.
    private func mergeAndSaveCurriculumData(_ newData: [String: Any], fetchStart: Date, fetchEnd: Date) {
        let oldJSON = prefs.curriculumJSON ?? "{\"List\":[]}"
        let oldList = CurriculumUtils.parseJsonToCourseList(oldJSON)

        let newJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: newData),
           let text = String(data: data, encoding: .utf8) {
            newJSON = text
        } else {
            newJSON = "{\"List\":[]}"
        }
        let newList = CurriculumUtils.parseJsonToCourseList(newJSON)

        var merged: [String: CourseItem] = [:]
        for course in oldList { merged[CurriculumUtils.mergeKey(course)] = course }
        for course in newList { merged[CurriculumUtils.mergeKey(course)] = course }
        let finalList = merged.values.sorted { $0.startTime < $1.startTime }

        let encoded = CurriculumUtils.encodeCourseList(finalList)

        let newStart = cachedStart.map { min($0, fetchStart) } ?? fetchStart
        let newEnd = cachedEnd.map { max($0, fetchEnd) } ?? fetchEnd
        cachedStart = newStart
        cachedEnd = newEnd

        prefs.curriculumJSON = encoded
        prefs.curriculumRangeStart = AppCalendar.isoString(newStart)
        prefs.curriculumRangeEnd = AppCalendar.isoString(newEnd)

        state.courseList = finalList
        state.curriculumJson = encoded

        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Scores

    func fetchScoreData(year: String? = nil, semester: Int? = nil) {
        guard state.isLoggedIn else { return }
        Task { await performFetchScoreData(year: year, semester: semester) }
    }

    private func performFetchScoreData(year: String?, semester: Int?) async {
        state.isScoreListLoading = true
        defer { state.isScoreListLoading = false }

        do {
            let targetYear = year ?? state.selectedYear ?? Self.defaultScoreYear
            let targetSemester = semester ?? state.selectedSemester

            let json = try await executeWithAutoReLogin {
                try await self.service.getScore(grade: targetYear, semester: targetSemester)
            }

            var years: [String] = []
            if let raw = JSONValue.array(json, "1") {
                years = raw.compactMap { $0 as? String }
            }

            var scores: [ScoreItem] = []
            if let grouped = JSONValue.array(json, "2") {
                for semesterGroup in grouped {
                    guard let rows = semesterGroup as? [Any] else { continue }
                    for row in rows {
                        guard let object = row as? [String: Any] else { continue }
                        guard JSONValue.int(object, "Semester", default: 0) == targetSemester else { continue }
                        scores.append(Self.parseScore(object))
                    }
                }
            }

            let gpa = JSONValue.cleanString(json, "4")
            let finalYear = targetYear.isEmpty && !years.isEmpty ? (years.last ?? "") : targetYear

            state.scoreYears = years
            state.selectedYear = finalYear.isEmpty ? nil : finalYear
            state.selectedSemester = targetSemester
            state.scoreList = scores
            state.gpaInfo = gpa

            // The very first call has no year to work with; the response tells
            // us which years exist, so ask again for the newest one.
            if targetYear.isEmpty && !finalYear.isEmpty {
                fetchScoreData(year: finalYear, semester: targetSemester)
            }
        } catch let error as AutoReLoginFailed {
            handleSessionExpired(error.message)
        } catch {
            handleFailure(error)
        }
    }

    private static func parseScore(_ object: [String: Any]) -> ScoreItem {
        ScoreItem(
            courseName: JSONValue.cleanString(object, "CurriculumName", default: "Unknown"),
            score: JSONValue.double(object, "Score", default: 0),
            fScore: JSONValue.double(object, "FScore", default: 0),
            achievementGrade: JSONValue.cleanString(object, "AchievementGrade"),
            credit: JSONValue.double(object, "Credit", default: 0),
            examSituation: JSONValue.cleanString(object, "ExaminationSituationStr"),
            semester: JSONValue.int(object, "Semester", default: 0)
        )
    }

    // MARK: - Classrooms

    func ensureClassroomOptionsLoaded() {
        guard state.isLoggedIn else { return }
        guard state.classroomCampusOptions.isEmpty else { return }
        Task { await loadClassroomOptions(type: "AnswerAuxiliaryCampus", area: nil, buildCode: nil, floorNo: nil, target: .campus) }
    }

    func onCampusSelected(_ code: String) {
        guard state.isLoggedIn, state.selectedCampusCode != code else { return }

        state.selectedCampusCode = code
        state.classroomBuildingOptions = []
        state.classroomFloorOptions = []
        state.classroomRoomOptions = []
        state.selectedBuildingCode = nil
        state.selectedFloorCode = nil
        state.selectedClassroomCode = nil
        state.classroomScheduleList = []

        Task { await loadClassroomOptions(type: "BuildCode", area: code, buildCode: nil, floorNo: nil, target: .building) }
    }

    func onBuildingSelected(_ code: String) {
        guard state.isLoggedIn, state.selectedBuildingCode != code else { return }

        state.selectedBuildingCode = code
        state.classroomFloorOptions = []
        state.classroomRoomOptions = []
        state.selectedFloorCode = nil
        state.selectedClassroomCode = nil
        state.classroomScheduleList = []

        guard let area = state.selectedCampusCode else { return }
        Task { await loadClassroomOptions(type: "ClassroomFloor", area: area, buildCode: code, floorNo: nil, target: .floor) }
    }

    func onFloorSelected(_ code: String) {
        guard state.isLoggedIn, state.selectedFloorCode != code else { return }

        state.selectedFloorCode = code
        state.classroomRoomOptions = []
        state.selectedClassroomCode = nil
        state.classroomScheduleList = []

        guard let area = state.selectedCampusCode, let building = state.selectedBuildingCode else { return }
        Task { await loadClassroomOptions(type: "Classroom", area: area, buildCode: building, floorNo: code, target: .room) }
    }

    func onClassroomSelected(_ code: String) {
        guard state.isLoggedIn else { return }
        state.selectedClassroomCode = code
        state.classroomScheduleList = []

        let date = AppCalendar.date(fromISODate: state.classroomSelectedDate) ?? Date()
        fetchClassroomSchedule(date)
    }

    private enum OptionTarget {
        case campus, building, floor, room
    }

    private func loadClassroomOptions(
        type: String,
        area: String?,
        buildCode: String?,
        floorNo: String?,
        target: OptionTarget
    ) async {
        state.isClassroomOptionsLoading = true
        defer { state.isClassroomOptionsLoading = false }

        do {
            let json = try await executeWithAutoReLogin {
                try await self.service.getClassroomInfoMap(
                    type: type, area: area, buildCode: buildCode, floorNo: floorNo
                )
            }
            let options = Self.parseClassroomOptions(json)

            switch target {
            case .campus:
                state.classroomCampusOptions = options
                state.selectedCampusCode = nil
                state.classroomBuildingOptions = []
                state.classroomFloorOptions = []
                state.classroomRoomOptions = []
                state.selectedBuildingCode = nil
                state.selectedFloorCode = nil
                state.selectedClassroomCode = nil
                state.classroomScheduleList = []
            case .building:
                state.classroomBuildingOptions = options
                state.selectedBuildingCode = nil
                state.classroomFloorOptions = []
                state.classroomRoomOptions = []
                state.selectedFloorCode = nil
                state.selectedClassroomCode = nil
                state.classroomScheduleList = []
            case .floor:
                state.classroomFloorOptions = options
                state.selectedFloorCode = nil
                state.classroomRoomOptions = []
                state.selectedClassroomCode = nil
                state.classroomScheduleList = []
            case .room:
                state.classroomRoomOptions = options
                state.selectedClassroomCode = nil
                state.classroomScheduleList = []
            }
        } catch let error as AutoReLoginFailed {
            handleSessionExpired(error.message)
        } catch {
            let fallback: String
            switch target {
            case .campus, .building, .floor: fallback = "教室信息加载失败"
            case .room: fallback = "教室列表加载失败"
            }
            handleFailure(error, fallback: fallback)
        }
    }

    func fetchClassroomSchedule(_ date: Date) {
        guard state.isLoggedIn else { return }
        guard let area = state.selectedCampusCode,
              let building = state.selectedBuildingCode,
              let floor = state.selectedFloorCode,
              let room = state.selectedClassroomCode else { return }

        Task { await performFetchClassroomSchedule(date: date, area: area, building: building, floor: floor, room: room) }
    }

    private func performFetchClassroomSchedule(
        date: Date, area: String, building: String, floor: String, room: String
    ) async {
        state.isClassroomScheduleLoading = true
        state.classroomSelectedDate = AppCalendar.isoString(date)
        state.classroomScheduleList = []
        defer { state.isClassroomScheduleLoading = false }

        do {
            let json = try await executeWithAutoReLogin {
                try await self.service.getClassroomInfoDetail(
                    date: AppCalendar.isoString(date),
                    area: area,
                    buildCode: building,
                    floorNo: floor,
                    classroomId: room
                )
            }
            state.classroomScheduleList = Self.parseClassroomSchedule(json)
        } catch let error as AutoReLoginFailed {
            handleSessionExpired(error.message)
        } catch {
            handleFailure(error, fallback: "教室占用信息加载失败")
        }
    }

    private static func parseClassroomOptions(_ json: [String: Any]) -> [ClassroomOption] {
        guard let data = JSONValue.array(json, "data") else { return [] }
        var options: [ClassroomOption] = []
        for element in data {
            guard let object = element as? [String: Any] else { continue }
            let code = JSONValue.cleanString(object, "code").trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty else { continue }
            var name = JSONValue.cleanString(object, "name", default: code).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = code }
            options.append(ClassroomOption(code: code, name: name))
        }
        return options
    }

    private static func parseClassroomSchedule(_ json: [String: Any]) -> [ClassroomScheduleItem] {
        guard let data = JSONValue.array(json, "data") else { return [] }
        var items: [ClassroomScheduleItem] = []

        for (index, element) in data.enumerated() {
            guard let object = element as? [String: Any] else { continue }

            guard let begin = AppCalendar.minutes(fromTimeString: JSONValue.cleanString(object, "periodbegintime")),
                  let end = AppCalendar.minutes(fromTimeString: JSONValue.cleanString(object, "periodendtime")),
                  end > begin else { continue }

            let teacher = JSONValue.cleanString(object, "teachertitle")
            let teacherFallback = JSONValue.cleanString(object, "teachername")

            items.append(
                ClassroomScheduleItem(
                    guid: JSONValue.cleanString(object, "guid", default: String(index)),
                    courseName: JSONValue.cleanString(object, "coursename", default: "未知课程"),
                    className: JSONValue.cleanString(object, "classname"),
                    content: JSONValue.cleanString(object, "tcContent"),
                    teacher: teacher.isEmpty ? teacherFallback : teacher,
                    beginMinutes: begin,
                    endMinutes: end,
                    category: JSONValue.cleanString(object, "ctypeId2")
                )
            )
        }

        return items.sorted { $0.beginMinutes < $1.beginMinutes }
    }

    // MARK: - Updates

    func checkForUpdates(manual: Bool = false) {
        guard !state.isCheckingUpdate else { return }
        Task { await performCheckForUpdates(manual: manual) }
    }

    private func performCheckForUpdates(manual: Bool) async {
        state.isCheckingUpdate = true
        if manual { updateNotification(.loading, "正在检查更新...") }
        defer { state.isCheckingUpdate = false }

        do {
            let (data, response) = try await NetworkClient.shared.data(for: AppConfig.updateJSONURL)
            guard (200...299).contains(response.statusCode) else {
                if manual { updateNotification(.failed, "HTTP \(response.statusCode)") }
                return
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            guard !body.isEmpty else {
                if manual { updateNotification(.failed, "响应为空") }
                return
            }
            guard let update = JSONValue.parse(body) else {
                if manual { updateNotification(.failed, "响应格式错误") }
                return
            }

            let currentVersionCode = AppConfig.currentVersionCode
            let remoteVersionCode = JSONValue.int(update, "versionCode", default: -1)

            if remoteVersionCode <= currentVersionCode {
                state.updateInfo = nil
                state.showUpdateDialog = false
                if manual { updateNotification(.success, "当前已是最新版本") }
                return
            }

            guard let downloadURL = Self.normalizeDownloadURL(JSONValue.cleanString(update, "downloadUrl")) else {
                if manual { updateNotification(.failed, "下载地址无效") }
                return
            }

            let info = AppUpdateInfo(
                version: JSONValue.cleanString(update, "version", default: String(remoteVersionCode)),
                versionCode: remoteVersionCode,
                downloadUrl: downloadURL,
                updateLog: JSONValue.cleanString(update, "updateLog"),
                forceUpdate: JSONValue.bool(update, "forceUpdate", default: false)
            )

            state.updateInfo = info
            state.showUpdateDialog = true
            if manual { updateNotification(.success, "发现新版本 v\(info.version)") }
        } catch {
            Log.error("CheckForUpdates", "Request failed: \(error.localizedDescription)")
            if manual { updateNotification(.failed, localizedMessage(error)) }
        }
    }

    func dismissUpdateDialog() {
        guard state.updateInfo?.forceUpdate != true else { return }
        state.showUpdateDialog = false
    }

    /// Opens the download page in the browser. The link points at the Android
    /// build, so on iOS this is a "view the release page" action.
    func startUpdateDownload() {
        guard let info = state.updateInfo,
              let url = URL(string: info.downloadUrl) else { return }
        // Reject anything that is not a public http(s) destination.
        do {
            _ = try URLGuard.validated(url)
        } catch {
            updateNotification(.failed, "无法打开下载链接：\(error.localizedDescription)")
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                self?.updateNotification(.failed, "无法打开下载链接")
            }
        }
    }

    private static func normalizeDownloadURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let absolute: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            absolute = trimmed
        } else if trimmed.hasPrefix("/") {
            absolute = AppConfig.updateHost + trimmed
        } else {
            absolute = AppConfig.updateHost + "/" + trimmed
        }

        guard let url = URL(string: absolute),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return absolute
    }

    // MARK: - Silent re-login

    /// Runs `block`, and when the gateway reports a stale session, logs back in
    /// with the stored credentials and runs it once more.
    private func executeWithAutoReLogin<T>(_ block: @escaping @MainActor () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch {
            guard service.isSessionExpired(error) else { throw error }

            let recovered = await attemptBackgroundReLogin()
            guard recovered else {
                throw AutoReLoginFailed(message: "登录状态已失效，请重新登录")
            }
            return try await block()
        }
    }

    private func attemptBackgroundReLogin() async -> Bool {
        if let existing = reLoginTask {
            return await existing.value
        }

        let task = Task { @MainActor in await self.performBackgroundReLogin() }
        reLoginTask = task
        let result = await task.value
        reLoginTask = nil
        return result
    }

    private func performBackgroundReLogin() async -> Bool {
        if await service.checkSessionValid() {
            state.isLoggedIn = true
            return true
        }

        let username = state.savedUsername.isEmpty ? prefs.username : state.savedUsername
        var password = state.savedPassword.isEmpty ? (SecureStore.get(.password) ?? "") : state.savedPassword
        if password.isEmpty { password = SecureStore.get(.password) ?? "" }

        guard !username.isEmpty, !password.isEmpty else { return false }

        let (success, _) = await service.autoLogin(
            username: username,
            password: password,
            publicKeyPEM: AppConfig.loginPublicKeyPEM
        )

        if success {
            saveCredentials(username: username, password: password)
            prefs.hasLoggedInOnce = true
            state.isLoggedIn = true
            state.savedUsername = username
            state.savedPassword = password
        }
        return success
    }

    private func handleSessionExpired(_ message: String?) {
        updateNotification(.failed, message ?? "登录状态已失效，请重新登录")
        state.isLoggedIn = false
        state.courseDetail = nil
    }

    /// Routes a failure to the right handler: a session that could not be
    /// silently restored returns to the login screen, anything else becomes a
    /// toast.
    private func handleFailure(_ error: Error, fallback: String? = nil) {
        if let failure = error as? AutoReLoginFailed {
            handleSessionExpired(failure.message)
        } else if service.isSessionExpired(error) {
            handleSessionExpired(error.localizedDescription)
        } else {
            updateNotification(.failed, localizedMessage(error, fallback: fallback))
        }
    }

    // MARK: - Notifications

    private func updateNotification(_ status: NotificationStatus, _ message: String) {
        state.notificationState = NotificationState(message: message, isVisible: true, status: status)

        notificationDismissTask?.cancel()
        // A loading toast stays until the work it describes finishes.
        guard status != .loading else { return }

        notificationDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.state.notificationState.isVisible = false
        }
    }

    private func localizedMessage(_ error: Error, fallback: String? = nil) -> String {
        if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        if let fallback { return fallback }
        return error.localizedDescription
    }
}
