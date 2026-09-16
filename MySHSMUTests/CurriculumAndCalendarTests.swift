import XCTest
@testable import MySHSMU

/// Course colours are derived from a Java string hash. If the port used Swift's
/// own `hashValue` instead, colours would differ from the Android build and
/// change on every launch.
final class CurriculumUtilsTests: XCTestCase {

    func testJavaHashCodeMatchesTheJVM() {
        XCTAssertEqual(CurriculumUtils.javaHashCode(""), 0)
        XCTAssertEqual(CurriculumUtils.javaHashCode("abc"), 96354)
        XCTAssertEqual(CurriculumUtils.javaHashCode("Hello"), 69609650)
        XCTAssertEqual(CurriculumUtils.javaHashCode("高等数学"), 1212073767)
    }

    func testPaletteIndexIsStableAndInRange() {
        XCTAssertEqual(CurriculumUtils.paletteIndex(for: "高等数学"), 0)
        XCTAssertEqual(CurriculumUtils.paletteIndex(for: "大学物理"), 8)
        XCTAssertEqual(CurriculumUtils.paletteIndex(for: "理论课"), 3)

        for title in ["", "a", "课程", "非常长的一门课程名称"] {
            let index = CurriculumUtils.paletteIndex(for: title)
            XCTAssertTrue(
                (0..<CurriculumUtils.colorPalette.count).contains(index),
                "index \(index) out of range for \(title)"
            )
        }
    }

    func testParsesACachedCourseList() throws {
        let json = """
        {"List":[
          {"Curriculum":"高等数学","CurriculumType":"理论课","CourseCount":2,
           "Classroom":"A101&nbsp;","Start":"2026-09-16T08:00:00","End":"2026-09-16T09:30:00",
           "MCSID":"m1","CSID":12,"CurriculumID":34,"XXKMID":"x1"}
        ]}
        """

        let courses = CurriculumUtils.parseJsonToCourseList(json)
        XCTAssertEqual(courses.count, 1)

        let course = try XCTUnwrap(courses.first)
        XCTAssertEqual(course.title, "高等数学")
        XCTAssertEqual(course.type, "理论课")
        XCTAssertEqual(course.count, 2)
        // The non-breaking space the API appends is stripped.
        XCTAssertEqual(course.location, "A101")
        XCTAssertEqual(course.ids, CourseItemIds(mcsId: "m1", csId: 12, curriculumId: 34, xxkmId: "x1"))
        XCTAssertEqual(course.colorIndex, CurriculumUtils.paletteIndex(for: "高等数学"))
        XCTAssertEqual(AppCalendar.timeString(course.startTime), "08:00")
        XCTAssertEqual(AppCalendar.timeString(course.endTime), "09:30")
    }

    func testSkipsEntriesWithMissingOrUnparseableTimes() {
        let json = """
        {"List":[
          {"Curriculum":"没有时间","Start":"","End":""},
          {"Curriculum":"坏时间","Start":"not-a-date","End":"also-bad"},
          {"Curriculum":"正常","Start":"2026-09-16T10:00:00","End":"2026-09-16T10:40:00"}
        ]}
        """
        let courses = CurriculumUtils.parseJsonToCourseList(json)
        XCTAssertEqual(courses.map(\.title), ["正常"])
    }

    func testReturnsNothingForAnArrayRootOrGarbage() {
        // The Kotlin reader bails out early when the payload is an array.
        XCTAssertTrue(CurriculumUtils.parseJsonToCourseList("[]").isEmpty)
        XCTAssertTrue(CurriculumUtils.parseJsonToCourseList("not json").isEmpty)
        XCTAssertTrue(CurriculumUtils.parseJsonToCourseList("{}").isEmpty)
    }

    func testEncodeThenParseRoundTrips() throws {
        let original = CurriculumUtils.parseJsonToCourseList("""
        {"List":[
          {"Curriculum":"大学物理","CurriculumType":"实验课","CourseCount":3,
           "Classroom":"B203","Start":"2026-09-17T13:30:00","End":"2026-09-17T15:50:00",
           "MCSID":"m2","CSID":56,"CurriculumID":78,"XXKMID":"x2"}
        ]}
        """)

        let restored = CurriculumUtils.parseJsonToCourseList(CurriculumUtils.encodeCourseList(original))
        XCTAssertEqual(restored.count, 1)

        let before = try XCTUnwrap(original.first)
        let after = try XCTUnwrap(restored.first)
        XCTAssertEqual(after.title, before.title)
        XCTAssertEqual(after.type, before.type)
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after.location, before.location)
        XCTAssertEqual(after.ids, before.ids)
        XCTAssertEqual(after.startTime, before.startTime)
        XCTAssertEqual(after.endTime, before.endTime)
    }

    func testMergeKeyMatchesOnTitleAndStartTime() {
        let courses = CurriculumUtils.parseJsonToCourseList("""
        {"List":[{"Curriculum":"化学","CourseCount":1,"Classroom":"C1",
         "Start":"2026-09-18T08:00:00","End":"2026-09-18T08:40:00"}]}
        """)
        XCTAssertEqual(CurriculumUtils.mergeKey(try! XCTUnwrap(courses.first)), "化学_2026-09-18T08:00:00")
    }
}

/// Date handling has to preserve Kotlin's timezone-free `LocalDate` /
/// `LocalDateTime` semantics.
final class AppCalendarTests: XCTestCase {

    func testISODateRoundTrips() throws {
        let date = try XCTUnwrap(AppCalendar.date(fromISODate: "2026-09-16"))
        XCTAssertEqual(AppCalendar.isoString(date), "2026-09-16")
    }

    func testStartOfWeekIsMonday() throws {
        // 2026-09-16 is a Wednesday.
        let wednesday = try XCTUnwrap(AppCalendar.date(fromISODate: "2026-09-16"))
        let monday = AppCalendar.startOfWeek(wednesday)
        XCTAssertEqual(AppCalendar.isoString(monday), "2026-09-14")
        XCTAssertEqual(AppCalendar.calendar.component(.weekday, from: monday), 2)

        // A Monday maps to itself, and Sunday belongs to the week that started
        // six days earlier.
        XCTAssertEqual(AppCalendar.isoString(AppCalendar.startOfWeek(monday)), "2026-09-14")
        let sunday = try XCTUnwrap(AppCalendar.date(fromISODate: "2026-09-20"))
        XCTAssertEqual(AppCalendar.isoString(AppCalendar.startOfWeek(sunday)), "2026-09-14")
    }

    func testDaysBetweenIgnoresTimeOfDay() throws {
        let a = try XCTUnwrap(AppCalendar.dateTime(from: "2026-09-14 23:30:00"))
        let b = try XCTUnwrap(AppCalendar.dateTime(from: "2026-09-16 00:10:00"))
        XCTAssertEqual(AppCalendar.daysBetween(a, b), 2)
    }

    func testParsesBothDateTimeSeparators() {
        XCTAssertEqual(AppCalendar.dateTime(from: "2026-09-16 08:00:00"), AppCalendar.dateTime(from: "2026-09-16T08:00:00"))
        XCTAssertNil(AppCalendar.dateTime(from: "nonsense"))
    }

    func testMinutesFromTimeString() {
        XCTAssertEqual(AppCalendar.minutes(fromTimeString: "08:00:00"), 480)
        XCTAssertEqual(AppCalendar.minutes(fromTimeString: "13:30"), 810)
        XCTAssertNil(AppCalendar.minutes(fromTimeString: "8"))
        XCTAssertNil(AppCalendar.minutes(fromTimeString: "25:00"))
    }

    func testTimeStringFormatsMinutes() {
        XCTAssertEqual(AppCalendar.timeString(minutes: 480), "08:00")
        XCTAssertEqual(AppCalendar.timeString(minutes: 810), "13:30")
    }

    func testCourseItemDayIndexUsesMondayBasedWeeks() throws {
        let weekStart = try XCTUnwrap(AppCalendar.date(fromISODate: "2026-09-14"))
        let course = CourseItem(
            title: "测试",
            type: "理论课",
            location: "",
            startTime: try XCTUnwrap(AppCalendar.dateTime(from: "2026-09-16 08:00:00")),
            endTime: try XCTUnwrap(AppCalendar.dateTime(from: "2026-09-16 08:40:00")),
            count: 1,
            colorIndex: 0,
            ids: CourseItemIds(mcsId: "", csId: 0, curriculumId: 0, xxkmId: "")
        )
        XCTAssertEqual(course.dayIndex(weekStart: weekStart), 2)

        let nextWeek = AppCalendar.addWeeks(1, to: weekStart)
        XCTAssertNil(course.dayIndex(weekStart: nextWeek))
    }
}
