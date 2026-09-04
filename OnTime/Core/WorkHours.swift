import Foundation

/// A session reduced to two dates, so the week math can be tested without a
/// store. An open session becomes an interval ending at "now" at the moment
/// it is asked about.
struct WorkInterval: Equatable, Sendable {
    var start: Date
    var end: Date

    var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// The arithmetic behind the work clock: which week a date belongs to, how
/// many seconds of a session landed on a given day, and the two forms a
/// total gets shown in. Pure, in the same spirit as `WalkMath`, because
/// every interesting case here is a date edge (midnight, a spring forward
/// Sunday, a session still running) and none of them are reachable through
/// the UI on demand.
enum WorkHours {

    /// Timesheet granularity. The exact total is always shown too; this is
    /// only what gets typed into the timesheet.
    static let roundingIncrement: TimeInterval = 15 * 60

    // MARK: Week and day boundaries

    /// The first instant of the week containing `date`.
    ///
    /// Derived from the calendar rather than hardcoded, so it follows the
    /// device's first day of week (Sunday in the US locale, Monday in most
    /// others) instead of quietly disagreeing with every other calendar on
    /// the phone.
    static func weekStart(containing date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start
            ?? calendar.startOfDay(for: date)
    }

    /// The seven day starts of a week, in order.
    ///
    /// Built by adding calendar days rather than 86,400 seconds: on the two
    /// DST changeover weekends one of these days is 23 or 25 hours long,
    /// and fixed second arithmetic walks off the start of day by an hour
    /// for the rest of the week.
    static func days(inWeekStarting weekStart: Date, calendar: Calendar = .current) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    static func weekStart(offsetBy weeks: Int, from weekStart: Date,
                          calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .weekOfYear, value: weeks, to: weekStart) ?? weekStart
    }

    // MARK: Per day totals

    /// How much of one interval fell inside the calendar day beginning at
    /// `dayStart`.
    ///
    /// A session that runs past midnight is split, not attributed whole to
    /// the day it began on: a shift from 9 PM to 2 AM is three hours on one
    /// day and two on the next, which is what a timesheet asks for and what
    /// the day rows in the week view have to add up to.
    static func seconds(of interval: WorkInterval, withinDayStarting dayStart: Date,
                        calendar: Calendar = .current) -> TimeInterval {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return 0 }
        let start = max(interval.start, dayStart)
        let end = min(interval.end, dayEnd)
        return max(0, end.timeIntervalSince(start))
    }

    /// Total seconds per day, in the order `days` was given.
    static func dailySeconds(intervals: [WorkInterval], days: [Date],
                             calendar: Calendar = .current) -> [TimeInterval] {
        days.map { day in
            intervals.reduce(0) { $0 + seconds(of: $1, withinDayStarting: day, calendar: calendar) }
        }
    }

    // MARK: Rounding and display

    /// Nearest quarter hour, halves going up. This is applied once, to the
    /// week total, never to each day and then summed: seven days each
    /// rounded can drift up to about 52 minutes away from the hours
    /// actually worked, and the number on the timesheet should be the one
    /// closest to the truth.
    static func roundedToQuarterHour(_ seconds: TimeInterval) -> TimeInterval {
        (seconds / roundingIncrement).rounded(.toNearestOrAwayFromZero) * roundingIncrement
    }

    /// "7:45" — hours and minutes, the way a clock reads. Seconds are
    /// truncated rather than rounded so a running total never shows a
    /// minute it has not finished.
    static func clockString(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
    }

    /// "7.75" — decimal hours, which is what a timesheet field wants.
    /// Trailing zeros kept to two places on purpose: 8.00 and 8 read
    /// differently when you are copying a column of them.
    static func decimalHoursString(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", max(0, seconds) / 3600)
    }

    /// "1:23:45" — the live readout on the timer face, where the seconds
    /// ticking are the whole point of the screen being open.
    static func stopwatchString(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: Overlap

    /// Whether two sessions claim the same moment. Touching ends do not
    /// count: clocking back in at exactly the second you clocked out is a
    /// normal thing to do and is not double counted by the day math.
    static func overlaps(_ a: WorkInterval, _ b: WorkInterval) -> Bool {
        a.start < b.end && b.start < a.end
    }
}
