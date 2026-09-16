import Foundation

/// Date helpers that reproduce the semantics of the Kotlin `LocalDate` /
/// `LocalTime` / `LocalDateTime` values used throughout the Android app.
///
/// Kotlin's `LocalDateTime` is timezone-free: `2025-03-04T08:00` means 08:00 on
/// the wall clock of whoever is looking at it. `Date` is an instant, so every
/// conversion here pins the components to `Calendar.current`'s time zone. For a
/// device in China (the app's only supported region, and a zone without DST)
/// the round trip is exact.
enum AppCalendar {

    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    // MARK: - Formatting

    private static func formatter(_ format: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = calendar
        df.timeZone = TimeZone.current
        df.dateFormat = format
        return df
    }

    /// `yyyy-MM-dd`
    static func isoString(_ date: Date) -> String {
        formatter("yyyy-MM-dd").string(from: date)
    }

    /// `yyyy-MM-dd`
    static func date(fromISODate string: String) -> Date? {
        formatter("yyyy-MM-dd").date(from: string)
    }

    /// Parses both `yyyy-MM-dd HH:mm:ss` and `yyyy-MM-ddTHH:mm:ss` (the two
    /// shapes the teaching-affairs API and the local cache use) as a naive
    /// local timestamp.
    static func dateTime(from string: String) -> Date? {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "T", with: " ")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            if let value = formatter(format).date(from: normalized) { return value }
        }
        return nil
    }

    /// The shape written into the local curriculum cache, matching
    /// `LocalDateTime.toString()` so both platforms read the same file layout.
    static func dateTimeString(_ date: Date) -> String {
        formatter("yyyy-MM-dd'T'HH:mm:ss").string(from: date)
    }

    static func timeString(_ date: Date) -> String {
        formatter("HH:mm").string(from: date)
    }

    /// Locale-aware display formatters, matching Kotlin's
    /// `getDisplayName(TextStyle.SHORT, Locale.getDefault())` — "周一" on a
    /// Chinese device, "Mon" on an English one.
    private static func displayFormatter(_ format: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale.current
        df.calendar = calendar
        df.timeZone = TimeZone.current
        df.dateFormat = format
        return df
    }

    /// Weekday abbreviation, e.g. `周一`.
    static func shortWeekday(_ date: Date) -> String {
        displayFormatter("EEE").string(from: date)
    }

    /// Month abbreviation, e.g. `9月`.
    static func shortMonth(_ date: Date) -> String {
        displayFormatter("MMM").string(from: date)
    }

    /// Full date with weekday, used by the classroom header,
    /// e.g. `2026-09-16 周三`.
    static func longDateWithWeekday(_ date: Date) -> String {
        displayFormatter("yyyy-MM-dd EEEE").string(from: date)
    }

    // MARK: - Date arithmetic

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    static func addDays(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    static func addWeeks(_ weeks: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: weeks * 7, to: date) ?? date
    }

    static func addMonths(_ months: Int, to date: Date) -> Date {
        calendar.date(byAdding: .month, value: months, to: date) ?? date
    }

    /// Whole days from `start` to `end`, ignoring the time of day.
    static func daysBetween(_ start: Date, _ end: Date) -> Int {
        calendar.dateComponents([.day], from: startOfDay(start), to: startOfDay(end)).day ?? 0
    }

    /// Monday-based start of the week containing `date`.
    ///
    /// Equivalent to `date.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))`.
    static func startOfWeek(_ date: Date) -> Date {
        let day = startOfDay(date)
        // `weekday` is 1 = Sunday … 7 = Saturday in the Gregorian calendar.
        let weekday = calendar.component(.weekday, from: day)
        let daysSinceMonday = (weekday + 5) % 7
        return addDays(-daysSinceMonday, to: day)
    }

    /// Minutes elapsed since midnight, the comparison unit for timetable slots.
    static func minutesSinceMidnight(_ date: Date) -> Int {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    /// Formats minutes-since-midnight as `HH:mm`.
    static func timeString(minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// Parses `HH:mm` or `HH:mm:ss` into minutes-since-midnight, for classroom
    /// availability payloads which arrive as raw time strings.
    static func minutes(fromTimeString string: String) -> Int? {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return hour * 60 + minute
    }
}
