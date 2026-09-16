import Foundation

/// One row of the timetable gutter.
struct TimeSlot: Hashable, Sendable {
    /// Minutes since midnight; the slot's start boundary.
    let startMinutes: Int
    /// Label drawn in the gutter. Two lines are separated by `\n`, exactly as
    /// in `constants/ScheduleTimeSlots.kt`.
    let label: String
}

/// A class period is 40 minutes long; slot matching allows a one-minute margin,
/// mirroring the `plusMinutes(41)` window in the Kotlin layout code.
let slotMatchWindowMinutes = 41

let standardTimeSlots: [TimeSlot] = [
    TimeSlot(startMinutes: 8 * 60, label: "08:00\n08:40"),
    TimeSlot(startMinutes: 8 * 60 + 50, label: "08:50\n09:30"),
    TimeSlot(startMinutes: 9 * 60 + 40, label: "09:40\n10:20"),
    TimeSlot(startMinutes: 10 * 60 + 30, label: "10:30\n11:10"),
    TimeSlot(startMinutes: 11 * 60 + 20, label: "11:20\n12:00"),
    TimeSlot(startMinutes: 12 * 60, label: "午间"),
    TimeSlot(startMinutes: 13 * 60 + 30, label: "13:30\n14:10"),
    TimeSlot(startMinutes: 14 * 60 + 20, label: "14:20\n15:00"),
    TimeSlot(startMinutes: 15 * 60 + 10, label: "15:10\n15:50"),
    TimeSlot(startMinutes: 16 * 60, label: "16:00\n16:40"),
    TimeSlot(startMinutes: 16 * 60 + 50, label: "16:50\n17:30"),
    TimeSlot(startMinutes: 17 * 60 + 40, label: "17:40\n18:20"),
    TimeSlot(startMinutes: 18 * 60 + 30, label: "18:30\n19:10"),
    TimeSlot(startMinutes: 19 * 60 + 20, label: "19:20\n20:00"),
    TimeSlot(startMinutes: 20 * 60 + 10, label: "20:10\n20:50"),
]

enum SlotResolver {

    /// Index of the slot a lesson starting at `minutes` belongs to.
    ///
    /// Matches the Kotlin search: the first slot whose window
    /// `[start, start + 41min)` contains the lesson start. Falls back to the
    /// first slot in the same hour, then to slot 0, so a lesson never vanishes
    /// from the grid because the backend reported an off-grid time.
    static func startSlot(forMinutes minutes: Int) -> Int {
        for (index, slot) in standardTimeSlots.enumerated() {
            if minutes >= slot.startMinutes && minutes < slot.startMinutes + slotMatchWindowMinutes {
                return index
            }
        }
        let hour = minutes / 60
        if let index = standardTimeSlots.firstIndex(where: { $0.startMinutes / 60 == hour }) {
            return index
        }
        return 0
    }

    /// Number of rows a block should span, given its start slot and end time.
    ///
    /// Mirrors the Kotlin logic: prefer the slot the end time lands in, and when
    /// that produces a nonsensical span fall back to `ceil(duration / 50min)`.
    static func slotCount(startSlot: Int, beginMinutes: Int, endMinutes: Int) -> Int {
        let matchedEndSlot = standardTimeSlots.firstIndex { slot in
            endMinutes >= slot.startMinutes && endMinutes < slot.startMinutes + slotMatchWindowMinutes
        }

        let fallbackCount = max(1, (endMinutes - beginMinutes + 49) / 50)
        let span: Int
        if let matchedEndSlot, matchedEndSlot >= startSlot {
            span = matchedEndSlot - startSlot + 1
        } else {
            span = fallbackCount
        }

        let maxAvailable = standardTimeSlots.count - startSlot
        return min(max(span, 1), max(maxAvailable, 1))
    }
}
