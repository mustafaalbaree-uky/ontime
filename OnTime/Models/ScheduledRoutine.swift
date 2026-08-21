import Foundation
import SwiftData

/// A thing done on the same days, by the same deadline, with the same steps
/// before it — the app's whole reason to exist as something other than a
/// stopwatch. Replaces the old `Routine`, which asked for an "anchor kind"
/// (manual time vs. mosque iqama) before you could add a single step and
/// then silently read a weekly grid you had to hand-fill. There is one
/// anchor here and it is a time. If that time changes, you edit one number.
///
/// Nothing about today's occurrence is stored — `ScheduleService` derives
/// the deadline, the must-start time and the arm moment from `anchorHour`/
/// `anchorMinute` plus the current step durations every time it's asked. A
/// stored schedule would go stale the moment a step's learned duration
/// moved, which is exactly the kind of drift `Solver` exists to prevent.
@Model
final class ScheduledRoutine {
    var name: String = ""
    /// The one number. Local wall-clock, resolved through `DeadlineResolver`
    /// so it rolls to tomorrow on its own once today's has passed.
    var anchorHour: Int = 0
    var anchorMinute: Int = 0
    /// `Calendar` weekdays (1 = Sunday). Stored as a sorted comma-joined
    /// string because SwiftData can't index a `Set<Int>` usefully and this
    /// is only ever read whole.
    var weekdaysRaw: String = "1,2,3,4,5,6,7"
    /// How far ahead of the *must-start* time this routine wakes up and
    /// starts showing a countdown. Not ahead of the deadline — an hour
    /// before you have to start is a useful warning; an hour before the
    /// deadline could already be too late.
    var armLeadMinutes: Int = 60
    var isEnabled: Bool = true
    /// Start-of-day for the last day this armed, so a routine arms once per
    /// day no matter how many times the app is foregrounded inside the
    /// window.
    var lastArmedDay: Date?
    /// Start-of-day entries the user swiped away ("not today").
    var skippedDays: [Date] = []

    @Relationship(deleteRule: .cascade, inverse: \Block.routine)
    var blocks: [Block] = []

    init(name: String, anchorHour: Int, anchorMinute: Int,
         weekdays: Set<Int> = Set(1...7), armLeadMinutes: Int = 60,
         isEnabled: Bool = true) {
        self.name = name
        self.anchorHour = anchorHour
        self.anchorMinute = anchorMinute
        self.weekdaysRaw = Self.encode(weekdays)
        self.armLeadMinutes = armLeadMinutes
        self.isEnabled = isEnabled
    }

    var weekdays: Set<Int> {
        get { Set(weekdaysRaw.split(separator: ",").compactMap { Int($0) }) }
        set { weekdaysRaw = Self.encode(newValue) }
    }

    private static func encode(_ days: Set<Int>) -> String {
        days.sorted().map(String.init).joined(separator: ",")
    }

    var runsEveryDay: Bool { weekdays.count == 7 }

    /// See `Plan.orderedBlocks` — the same unordered-relationship caveat
    /// applies: `blocks` is a SwiftData relationship with no inherent order.
    var orderedBlocks: [Block] {
        blocks.sorted { $0.order < $1.order }
    }

    /// See `Plan.renumber`.
    func renumber() {
        for (index, block) in orderedBlocks.enumerated() {
            block.order = index
        }
    }

    func isSkipped(on day: Date, calendar: Calendar = .current) -> Bool {
        let target = calendar.startOfDay(for: day)
        return skippedDays.contains { calendar.isDate($0, inSameDayAs: target) }
    }

    func skip(on day: Date, calendar: Calendar = .current) {
        let target = calendar.startOfDay(for: day)
        guard !isSkipped(on: target, calendar: calendar) else { return }
        skippedDays.append(target)
        // Keep this from growing without bound — anything older than a week
        // can never be asked about again.
        let cutoff = calendar.date(byAdding: .day, value: -7, to: target) ?? target
        skippedDays.removeAll { $0 < cutoff }
    }
}
