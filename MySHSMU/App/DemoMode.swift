#if DEBUG
import Foundation

/// Seeds the app with representative data so screenshots can be captured where
/// there is no account to log in with.
///
/// Enabled only by the `-uiDemoMode` launch argument, and only in DEBUG builds.
/// `MainViewModel` short-circuits every network entry point while it is on, so
/// nothing can fail mid-capture and bounce back to the login screen.
///
/// The data below is invented. It is here to exercise layout — a full week of
/// classes, passing and failing grades, a partly-booked room — not to describe
/// any real student's timetable.
enum DemoMode {

    // Read from the environment as well as from launch arguments: `simctl
    // launch` can mistake a leading `-` for one of its own options, whereas
    // `SIMCTL_CHILD_*` environment variables always reach the app.

    static var isRequested: Bool {
        flag("UI_DEMO_MODE") || argumentPresent("uiDemoMode")
    }

    /// Suppresses network access without seeding anything, so the login screen
    /// can be captured without the update check raising a dialog over it.
    static var isLoginOnly: Bool {
        !isRequested && (flag("UI_DEMO_LOGIN") || argumentPresent("uiDemoLogin"))
    }

    /// Either mode turns the network off.
    static var active: Bool { isRequested || isLoginOnly }

    /// Which tab to open. `nil` when unspecified.
    static var tab: Int? {
        value("UI_DEMO_TAB") ?? argumentValue("uiDemoTab")
    }

    // MARK: - Launch configuration

    private static func flag(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment[name] == "1"
    }

    private static func value(_ name: String) -> Int? {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init)
    }

    private static func argumentPresent(_ name: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains("-" + name)
    }

    private static func argumentValue(_ name: String) -> Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-" + name),
              index + 1 < arguments.count,
              let parsed = Int(arguments[index + 1]) else { return nil }
        return parsed
    }

    // MARK: - Seeding

    static func seed(_ state: inout MySHSMUUiState) {
        let calendar = AppCalendar.calendar
        let today = Date()
        let monday = AppCalendar.startOfWeek(today)

        state.isLoggedIn = true
        state.savedUsername = "20230001"
        state.savedPassword = "demo"

        // A term that started a few weeks ago and runs for 18 weeks, so the
        // header shows a realistic "第 N 周".
        let weeksSinceStart = 4
        let firstWeek = AppCalendar.addWeeks(-weeksSinceStart, to: monday)
        state.firstWeekStartDate = AppCalendar.isoString(firstWeek)
        state.weekCount = 18
        state.courseBlockHeight = 60

        state.courseList = weeklyCourses(weekStart: monday, calendar: calendar)
        state.curriculumJson = CurriculumUtils.encodeCourseList(state.courseList)

        state.courseDetail = CourseDetail(
            name: "高等数学（一）",
            college: "基础医学院",
            teacher: "王建国 教授",
            content: "第八章 多元函数微分学。掌握偏导数与全微分的计算。",
            classes: "临床医学 2023 级 1 班",
            location: "东一号楼 302"
        )

        seedScores(&state)
        seedClassroom(&state, today: today)
    }

    private static func seedScores(_ state: inout MySHSMUUiState) {
        state.scoreYears = ["2023-2024", "2024-2025", "2025-2026"]
        state.selectedYear = "2025-2026"
        state.selectedSemester = 1
        state.gpaInfo = "平均绩点 3.82 / 4.0　已获学分 28.5"
        state.scoreList = [
            ScoreItem(courseName: "高等数学（一）", score: 94, fScore: 0,
                      achievementGrade: "优秀", credit: 5, examSituation: "正常", semester: 1),
            ScoreItem(courseName: "大学物理", score: 88, fScore: 0,
                      achievementGrade: "良好", credit: 4, examSituation: "正常", semester: 1),
            ScoreItem(courseName: "有机化学", score: 76, fScore: 0,
                      achievementGrade: "中等", credit: 4, examSituation: "正常", semester: 1),
            ScoreItem(courseName: "医学细胞生物学", score: 91, fScore: 0,
                      achievementGrade: "优秀", credit: 3, examSituation: "正常", semester: 1),
            ScoreItem(courseName: "大学英语（三）", score: 82, fScore: 0,
                      achievementGrade: "良好", credit: 3, examSituation: "正常", semester: 1),
            ScoreItem(courseName: "体育（一）", score: 0, fScore: 0,
                      achievementGrade: "合格", credit: 1, examSituation: "免修", semester: 1),
            ScoreItem(courseName: "线性代数", score: 58, fScore: 71,
                      achievementGrade: "及格", credit: 3, examSituation: "正常", semester: 1),
            ScoreItem(courseName: "计算机基础", score: 85, fScore: 0,
                      achievementGrade: "良好", credit: 2, examSituation: "正常", semester: 1),
        ]
    }

    private static func seedClassroom(_ state: inout MySHSMUUiState, today: Date) {
        state.classroomCampusOptions = [
            ClassroomOption(code: "01", name: "黄浦校区"),
            ClassroomOption(code: "02", name: "重庆南路校区"),
        ]
        state.classroomBuildingOptions = [
            ClassroomOption(code: "0101", name: "东一号楼"),
            ClassroomOption(code: "0102", name: "西二号楼"),
            ClassroomOption(code: "0103", name: "图书馆"),
        ]
        state.classroomFloorOptions = [
            ClassroomOption(code: "1", name: "1 层"),
            ClassroomOption(code: "2", name: "2 层"),
            ClassroomOption(code: "3", name: "3 层"),
            ClassroomOption(code: "4", name: "4 层"),
        ]
        state.classroomRoomOptions = [
            ClassroomOption(code: "302", name: "东302"),
            ClassroomOption(code: "303", name: "东303"),
            ClassroomOption(code: "304", name: "东304"),
        ]
        state.selectedCampusCode = "01"
        state.selectedBuildingCode = "0101"
        state.selectedFloorCode = "3"
        state.selectedClassroomCode = "302"
        state.classroomSelectedDate = AppCalendar.isoString(today)

        state.classroomScheduleList = [
            ClassroomScheduleItem(guid: "1", courseName: "高等数学（一）", className: "临床 2023-1",
                                  content: "多元函数微分学", teacher: "王建国",
                                  beginMinutes: 8 * 60, endMinutes: 9 * 60 + 30, category: "理论课"),
            ClassroomScheduleItem(guid: "2", courseName: "大学物理", className: "临床 2023-2",
                                  content: "-", teacher: "李慧",
                                  beginMinutes: 10 * 60 + 30, endMinutes: 12 * 60, category: "理论课"),
            ClassroomScheduleItem(guid: "3", courseName: "自习", className: "",
                                  content: "自主复习", teacher: "",
                                  beginMinutes: 13 * 60 + 30, endMinutes: 15 * 60, category: "自习"),
            ClassroomScheduleItem(guid: "4", courseName: "有机化学", className: "临床 2023-1",
                                  content: "期末考试", teacher: "张伟",
                                  beginMinutes: 18 * 60 + 30, endMinutes: 20 * 60, category: "考试"),
        ]
    }

    /// A plausible week: a heavy Monday, a light Friday, one exam-style block.
    private static func weeklyCourses(weekStart: Date, calendar: Calendar) -> [CourseItem] {
        let plan: [(day: Int, title: String, type: String, room: String,
                    start: (Int, Int), periods: Int)] = [
            (0, "高等数学（一）", "理论课", "东302", (8, 0), 2),
            (0, "大学物理", "理论课", "东201", (10, 30), 2),
            (0, "大学英语（三）", "理论课", "语言楼 405", (13, 30), 2),
            (1, "有机化学", "实验课", "化学楼 B12", (8, 50), 3),
            (1, "医学细胞生物学", "理论课", "西101", (14, 20), 2),
            (2, "高等数学（一）", "理论课", "东302", (8, 0), 2),
            (2, "体育（一）", "实践课", "体育馆", (15, 10), 2),
            (2, "线性代数", "理论课", "西204", (18, 30), 2),
            (3, "大学物理实验", "实验课", "物理楼 210", (9, 40), 3),
            (3, "计算机基础", "理论课", "机房 3", (13, 30), 2),
            (4, "医学细胞生物学", "理论课", "西101", (8, 0), 2),
            (4, "高等数学（一）", "理论课", "东302", (10, 30), 2),
        ]

        return plan.enumerated().map { index, item in
            let day = AppCalendar.addDays(item.day, to: weekStart)
            let start = calendar.date(
                bySettingHour: item.start.0, minute: item.start.1, second: 0, of: day
            ) ?? day
            // Consecutive 40-minute periods with a 10-minute break between.
            let minutes = item.periods * 40 + (item.periods - 1) * 10
            let end = start.addingTimeInterval(TimeInterval(minutes * 60))

            return CourseItem(
                title: item.title,
                type: item.type,
                location: item.room,
                startTime: start,
                endTime: end,
                count: item.periods,
                colorIndex: CurriculumUtils.paletteIndex(for: item.title),
                ids: CourseItemIds(
                    mcsId: "demo-mcs-\(index)",
                    csId: 1000 + index,
                    curriculumId: 2000 + index,
                    xxkmId: "demo-xxkm-\(index)"
                )
            )
        }
    }
}
#endif
