import Foundation
import SwiftUI

/// Readers with the same tolerance as Android's `JSONObject.opt*` family: a
/// missing key, a JSON `null`, or the literal string `"null"` all fall back to
/// the supplied default.
enum JSONValue {

    static func cleanString(_ object: [String: Any], _ key: String, default fallback: String = "") -> String {
        guard let raw = object[key], !(raw is NSNull) else { return fallback }
        let text = stringify(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.lowercased() == "null" { return fallback }
        return text
    }

    static func int(_ object: [String: Any], _ key: String, default fallback: Int = 0) -> Int {
        guard let raw = object[key], !(raw is NSNull) else { return fallback }
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text.trimmingCharacters(in: .whitespaces)) ?? fallback }
        return fallback
    }

    static func double(_ object: [String: Any], _ key: String, default fallback: Double = 0) -> Double {
        guard let raw = object[key], !(raw is NSNull) else { return fallback }
        if let number = raw as? NSNumber { return number.doubleValue }
        if let text = raw as? String { return Double(text.trimmingCharacters(in: .whitespaces)) ?? fallback }
        return fallback
    }

    static func bool(_ object: [String: Any], _ key: String, default fallback: Bool = false) -> Bool {
        guard let raw = object[key], !(raw is NSNull) else { return fallback }
        if let number = raw as? NSNumber { return number.boolValue }
        if let text = raw as? String {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return fallback
            }
        }
        return fallback
    }

    static func array(_ object: [String: Any], _ key: String) -> [Any]? {
        object[key] as? [Any]
    }

    static func dictionary(_ object: [String: Any], _ key: String) -> [String: Any]? {
        object[key] as? [String: Any]
    }

    /// Renders a scalar the way Kotlin's `value.toString()` would.
    static func stringify(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber:
            // Booleans arrive as NSNumber too; distinguish them before printing
            // so `true` does not become `1`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            if number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e15 {
                return String(number.int64Value)
            }
            return number.stringValue
        default: return String(describing: value)
        }
    }

    static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func parse(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return parse(data)
    }

    static func parseArray(_ data: Data) -> [Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [Any]
    }
}

/// Port of `utils/CurriculumUtils.kt`: the course palette and the reader for
/// the locally cached curriculum JSON.
enum CurriculumUtils {

    /// Pastel palette indexed by a stable hash of the course title.
    static let colorPalette: [Color] = [
        Color(red: 1.0, green: 0.804, blue: 0.824),   // 0xFFFFCDD2
        Color(red: 0.784, green: 0.902, blue: 0.788), // 0xFFC8E6C9
        Color(red: 0.733, green: 0.871, blue: 0.984), // 0xFFBBDEFB
        Color(red: 0.882, green: 0.745, blue: 0.906), // 0xFFE1BEE7
        Color(red: 1.0, green: 0.976, blue: 0.769),   // 0xFFFFF9C4
        Color(red: 1.0, green: 0.878, blue: 0.698),   // 0xFFFFE0B2
        Color(red: 0.820, green: 0.769, blue: 0.914), // 0xFFD1C4E9
        Color(red: 0.698, green: 0.875, blue: 0.859), // 0xFFB2DFDB
        Color(red: 0.973, green: 0.733, blue: 0.816), // 0xFFF8BBD0
    ]

    static func color(at index: Int) -> Color {
        guard !colorPalette.isEmpty else { return .gray }
        return colorPalette[((index % colorPalette.count) + colorPalette.count) % colorPalette.count]
    }

    /// Java's `String.hashCode()`: `h = 31 * h + utf16Unit`, wrapping at 32 bits.
    ///
    /// Reproduced exactly so a given course gets the same colour here as it
    /// does on Android — Swift's own `hashValue` is randomly seeded per process
    /// and would assign different colours on every launch.
    static func javaHashCode(_ value: String) -> Int32 {
        var hash: Int32 = 0
        for unit in value.utf16 {
            hash = hash &* 31 &+ Int32(truncatingIfNeeded: unit)
        }
        return hash
    }

    /// Palette slot for a course title, following
    /// `abs(title.hashCode()) % colorPalette.size` but never negative.
    static func paletteIndex(for title: String) -> Int {
        let hash = javaHashCode(title)
        let magnitude = hash == Int32.min ? Int64(Int32.max) + 1 : Int64(abs(Int32(hash)))
        return Int(magnitude % Int64(colorPalette.count))
    }

    /// Parses the cached curriculum payload.
    ///
    /// Both the raw API response and the local cache use the same `List` shape,
    /// where `Start` / `End` are `yyyy-MM-ddTHH:mm:ss` strings.
    static func parseJsonToCourseList(_ json: String) -> [CourseItem] {
        guard !json.hasPrefix("[") else { return [] }
        guard let root = JSONValue.parse(json),
              let list = JSONValue.array(root, "List") else { return [] }

        var courses: [CourseItem] = []
        courses.reserveCapacity(list.count)

        for element in list {
            guard let object = element as? [String: Any] else { continue }

            let title = JSONValue.cleanString(object, "Curriculum", default: "Unknown")
            let type = JSONValue.cleanString(object, "CurriculumType", default: "Unknown")
            let count = JSONValue.int(object, "CourseCount", default: 0)
            let classroom = JSONValue.cleanString(object, "Classroom", default: "Unknown")
                .replacingOccurrences(of: "&nbsp;", with: "")
            let startText = JSONValue.cleanString(object, "Start")
            let endText = JSONValue.cleanString(object, "End")

            guard !startText.isEmpty, !endText.isEmpty else { continue }
            guard let start = AppCalendar.dateTime(from: startText),
                  let end = AppCalendar.dateTime(from: endText) else { continue }

            let ids = CourseItemIds(
                mcsId: JSONValue.cleanString(object, "MCSID"),
                csId: JSONValue.int(object, "CSID", default: 0),
                curriculumId: JSONValue.int(object, "CurriculumID", default: 0),
                xxkmId: JSONValue.cleanString(object, "XXKMID")
            )

            courses.append(
                CourseItem(
                    title: title,
                    type: type,
                    location: classroom,
                    startTime: start,
                    endTime: end,
                    count: count,
                    colorIndex: paletteIndex(for: title),
                    ids: ids
                )
            )
        }

        return courses
    }

    /// Serialises the merged course list back into the cache format.
    static func encodeCourseList(_ courses: [CourseItem]) -> String {
        let list: [[String: Any]] = courses.map { course in
            [
                "Curriculum": course.title,
                "CurriculumType": course.type,
                "CourseCount": course.count,
                "Classroom": course.location,
                "Start": AppCalendar.dateTimeString(course.startTime),
                "End": AppCalendar.dateTimeString(course.endTime),
                "MCSID": course.ids.mcsId,
                "CSID": course.ids.csId,
                "CurriculumID": course.ids.curriculumId,
                "XXKMID": course.ids.xxkmId,
            ]
        }
        let root: [String: Any] = ["List": list]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"List\":[]}"
        }
        return text
    }

    /// Merge key used when new weeks are folded into the cache.
    static func mergeKey(_ course: CourseItem) -> String {
        "\(course.title)_\(AppCalendar.dateTimeString(course.startTime))"
    }
}
