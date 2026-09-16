import SwiftUI
import WidgetKit

// MARK: - Shared model
//
// This file is deliberately self-contained: it carries its own copy of the
// curriculum payload reader and colour palette so the widget extension can be
// dropped into Xcode on its own, without adding the app's Core/Models sources
// to a second target. The parsing rules and palette match
// `Core/CurriculumUtils.swift` — keep the two in step if either changes.

/// Plain value type for one class in the widget's list. Internal rather than
/// private because `CurriculumEntry` exposes an array of these.
struct WidgetCourse: Identifiable {
    let id: String
    let title: String
    let location: String
    let start: Date
    let end: Date
    let colorIndex: Int

    var locationSuffix: String { location.isEmpty ? "" : "@\(location)" }
}

private enum WidgetCourseReader {

    /// Palette from `ui/theme/Color.kt`'s `colorPalette`.
    static let palette: [Color] = [
        Color(red: 1.0, green: 0.804, blue: 0.824),
        Color(red: 0.784, green: 0.902, blue: 0.788),
        Color(red: 0.733, green: 0.871, blue: 0.984),
        Color(red: 0.882, green: 0.745, blue: 0.906),
        Color(red: 1.0, green: 0.976, blue: 0.769),
        Color(red: 1.0, green: 0.878, blue: 0.698),
        Color(red: 0.820, green: 0.769, blue: 0.914),
        Color(red: 0.698, green: 0.875, blue: 0.859),
        Color(red: 0.973, green: 0.733, blue: 0.816),
    ]

    static func color(at index: Int) -> Color {
        let count = palette.count
        return palette[((index % count) + count) % count]
    }

    /// Java's `String.hashCode()`, so a course keeps the same colour it has in
    /// the app and on Android.
    static func javaHashCode(_ value: String) -> Int32 {
        var hash: Int32 = 0
        for unit in value.utf16 {
            hash = hash &* 31 &+ Int32(truncatingIfNeeded: unit)
        }
        return hash
    }

    static func paletteIndex(for title: String) -> Int {
        let hash = javaHashCode(title)
        // `abs(Int32.min)` would trap, so widen before taking the magnitude.
        let magnitude = hash == Int32.min ? Int64(Int32.max) + 1 : Int64(abs(hash))
        return Int(magnitude % Int64(palette.count))
    }

    private static func dateTime(from text: String) -> Date? {
        let normalized = text.replacingOccurrences(of: "T", with: " ")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone.current
            df.dateFormat = format
            if let value = df.date(from: normalized) { return value }
        }
        return nil
    }

    /// Today's remaining classes, ordered by start time — the same filter the
    /// Glance widget applies.
    static func remainingCoursesToday(from json: String?, now: Date = Date()) -> [WidgetCourse] {
        guard let json,
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["List"] as? [Any] else { return [] }

        let calendar = Calendar.current
        var courses: [WidgetCourse] = []

        for element in list {
            guard let object = element as? [String: Any],
                  let startText = object["Start"] as? String,
                  let endText = object["End"] as? String,
                  let start = dateTime(from: startText),
                  let end = dateTime(from: endText) else { continue }

            guard calendar.isDate(start, inSameDayAs: now), end > now else { continue }

            let title = (object["Curriculum"] as? String) ?? "未知课程"
            let rawLocation = (object["Classroom"] as? String) ?? ""
            let location = rawLocation.replacingOccurrences(of: "&nbsp;", with: "")

            courses.append(
                WidgetCourse(
                    id: "\(title)_\(start.timeIntervalSince1970)",
                    title: title,
                    location: location,
                    start: start,
                    end: end,
                    colorIndex: paletteIndex(for: title)
                )
            )
        }

        return courses.sorted { $0.start < $1.start }
    }
}

// MARK: - Timeline

struct CurriculumEntry: TimelineEntry {
    let date: Date
    let courses: [WidgetCourse]
}

struct CurriculumProvider: TimelineProvider {

    func placeholder(in context: Context) -> CurriculumEntry {
        CurriculumEntry(date: Date(), courses: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (CurriculumEntry) -> Void) {
        completion(CurriculumEntry(date: Date(), courses: loadCourses()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CurriculumEntry>) -> Void) {
        let now = Date()
        let entry = CurriculumEntry(date: now, courses: loadCourses(now: now))

        // Refresh on the half hour, and again right after the last class of the
        // day ends so the widget clears itself promptly.
        var nextRefresh = now.addingTimeInterval(30 * 60)
        if let lastEnd = entry.courses.last?.end, lastEnd < nextRefresh, lastEnd > now {
            nextRefresh = lastEnd.addingTimeInterval(60)
        }

        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadCourses(now: Date = Date()) -> [WidgetCourse] {
        let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        let json = defaults.string(forKey: "curriculum_json")
        return WidgetCourseReader.remainingCoursesToday(from: json, now: now)
    }
}

enum AppGroup {
    /// Must match `AppConfig.appGroupID` in the app target, and be enabled as a
    /// capability on both targets.
    static let identifier = "group.xyz.reqwey.myshsmu"
}

// MARK: - Views

struct CurriculumWidgetEntryView: View {
    var entry: CurriculumEntry

    var body: some View {
        Group {
            if entry.courses.isEmpty {
                VStack {
                    Spacer()
                    Text("🎉今天没有课啦！")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.tint)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("今日剩余课程")
                        .font(.system(size: 16, weight: .bold))
                        .padding(.bottom, 8)

                    ForEach(entry.courses.prefix(4)) { course in
                        CourseRow(course: course)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct CourseRow: View {
    let course: WidgetCourse

    var body: some View {
        HStack(spacing: 8) {
            Text("\(timeText(course.start))\n\(timeText(course.end))")
                .font(.system(size: 12))
                .foregroundStyle(Color.black.opacity(0.7))
                .multilineTextAlignment(.leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(course.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                if !course.location.isEmpty {
                    Text(course.locationSuffix)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.black.opacity(0.7))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(WidgetCourseReader.color(at: course.colorIndex))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.bottom, 8)
    }

    private func timeText(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "HH:mm"
        return df.string(from: date)
    }
}

struct CurriculumWidget: Widget {
    let kind = "CurriculumWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CurriculumProvider()) { entry in
            CurriculumWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("今日课程")
        .description("显示今天剩余的课程。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
