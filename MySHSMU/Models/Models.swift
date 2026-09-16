import Foundation

// MARK: - Curriculum

/// Identifiers the teaching-affairs backend needs to resolve a course detail.
struct CourseItemIds: Hashable, Sendable {
    var mcsId: String
    var csId: Int
    var curriculumId: Int
    var xxkmId: String
}

/// A single scheduled course block.
///
/// The Android model carries a `Color`; here the palette index is stored
/// instead so the value stays `Hashable` and free of UI types.
struct CourseItem: Identifiable, Hashable, Sendable {
    var title: String
    var type: String
    var location: String
    var startTime: Date
    var endTime: Date
    var count: Int
    var colorIndex: Int
    var ids: CourseItemIds

    var id: String { "\(title)_\(startTime.timeIntervalSince1970)" }

    /// Day index within the week starting on `weekStart`, or `nil` when the
    /// course falls outside that week.
    func dayIndex(weekStart: Date, calendar: Calendar = AppCalendar.calendar) -> Int? {
        let start = calendar.startOfDay(for: weekStart)
        let courseDay = calendar.startOfDay(for: startTime)
        let delta = calendar.dateComponents([.day], from: start, to: courseDay).day ?? -1
        return (0...6).contains(delta) ? delta : nil
    }
}

/// Detail panel contents for a tapped course.
struct CourseDetail: Sendable, Equatable {
    var name: String
    var college: String
    var teacher: String
    var content: String
    var classes: String
    var location: String
}

// MARK: - Scores

struct ScoreItem: Identifiable, Hashable, Sendable {
    var courseName: String
    var score: Double
    var fScore: Double
    var achievementGrade: String
    var credit: Double
    var examSituation: String
    var semester: Int

    var id: String { "\(courseName)_\(semester)_\(score)" }
}

// MARK: - Classrooms

struct ClassroomOption: Identifiable, Hashable, Sendable {
    var code: String
    var name: String

    var id: String { code }
}

struct ClassroomScheduleItem: Identifiable, Hashable, Sendable {
    var guid: String
    var courseName: String
    var className: String
    var content: String
    var teacher: String
    /// Minutes since midnight, mirroring the Kotlin `LocalTime` values.
    var beginMinutes: Int
    var endMinutes: Int
    var category: String

    var id: String { guid }
}

// MARK: - Updates

struct AppUpdateInfo: Sendable, Equatable {
    var version: String
    var versionCode: Int
    var downloadUrl: String
    var updateLog: String
    var forceUpdate: Bool
}

// MARK: - Transient notifications

enum NotificationStatus: Sendable {
    case loading
    case success
    case failed
}

struct NotificationState: Sendable, Equatable {
    var message: String = ""
    var isVisible: Bool = false
    var status: NotificationStatus = .success
}

// MARK: - Root UI state

/// Mirror of `MySHSMUUiState`.
struct MySHSMUUiState: Sendable {
    var notificationState = NotificationState()
    var curriculumJson: String?
    var isLoggingIn = false
    var isLoggedIn = false
    var savedUsername = ""
    var savedPassword = ""

    var isCourseListLoading = false
    var courseList: [CourseItem] = []
    var courseDetail: CourseDetail?

    var scoreYears: [String] = []
    var selectedYear: String?
    var selectedSemester = 1
    var isScoreListLoading = false
    var scoreList: [ScoreItem] = []
    var gpaInfo: String?

    var firstWeekStartDate: String?
    var weekCount = 0
    var courseBlockHeight = 60

    var isClassroomOptionsLoading = false
    var isClassroomScheduleLoading = false
    var classroomCampusOptions: [ClassroomOption] = []
    var classroomBuildingOptions: [ClassroomOption] = []
    var classroomFloorOptions: [ClassroomOption] = []
    var classroomRoomOptions: [ClassroomOption] = []
    var selectedCampusCode: String?
    var selectedBuildingCode: String?
    var selectedFloorCode: String?
    var selectedClassroomCode: String?
    var classroomSelectedDate = AppCalendar.isoString(Date())
    var classroomScheduleList: [ClassroomScheduleItem] = []

    var isCheckingUpdate = false
    var updateInfo: AppUpdateInfo?
    var showUpdateDialog = false
}
