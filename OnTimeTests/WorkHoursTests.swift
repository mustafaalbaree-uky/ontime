import Foundation
import Testing
@testable import OnTime

/// Tests for `WorkHours`, the date arithmetic behind the work clock. Every
/// interesting case here is an edge that cannot be produced on demand
/// through the UI: a shift crossing midnight, the two DST weekends, a
/// session still running, and the quarter hour boundaries the timesheet
/// number lands on.
struct WorkHoursTests {

    /// A fixed calendar so a test does not pass or fail depending on the
    /// machine's locale. Sunday first, matching the US locale the app is
    /// used in; `weekStart` itself reads whatever the device says.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US")
        c.firstWeekday = 1
        return c
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    // MARK: Week boundaries

    @Test func weekStartsOnTheCalendarsFirstWeekday() {
        // Wednesday 27 August 2026 belongs to the week beginning Sunday the 23rd.
        let start = WorkHours.weekStart(containing: date(2026, 8, 27, 14, 30), calendar: calendar)
        #expect(start == date(2026, 8, 23))
    }

    @Test func weekStartIsIdempotent() {
        let start = WorkHours.weekStart(containing: date(2026, 8, 23), calendar: calendar)
        #expect(WorkHours.weekStart(containing: start, calendar: calendar) == start)
    }

    @Test func aWeekIsSevenDayStarts() {
        let days = WorkHours.days(inWeekStarting: date(2026, 8, 23), calendar: calendar)
        #expect(days.count == 7)
        #expect(days.first == date(2026, 8, 23))
        #expect(days.last == date(2026, 8, 29))
    }

    /// Days are added as calendar days, not as 86,400 seconds. On the
    /// spring forward weekend one day is 23 hours long, and fixed second
    /// arithmetic walks an hour off the start of day and stays there for
    /// the rest of the week.
    @Test func daysStayAtMidnightAcrossSpringForward() {
        // DST begins Sunday 8 March 2026 in America/New_York.
        let days = WorkHours.days(inWeekStarting: date(2026, 3, 8), calendar: calendar)
        for day in days {
            let hour = calendar.component(.hour, from: day)
            #expect(hour == 0)
        }
        #expect(days.last == date(2026, 3, 14))
    }

    @Test func pagingBackAndForwardReturnsToTheSameWeek() {
        let start = date(2026, 8, 23)
        let back = WorkHours.weekStart(offsetBy: -3, from: start, calendar: calendar)
        #expect(back == date(2026, 8, 2))
        #expect(WorkHours.weekStart(offsetBy: 3, from: back, calendar: calendar) == start)
    }

    // MARK: Day attribution

    @Test func aSessionInsideOneDayCountsWholeOnThatDay() {
        let interval = WorkInterval(start: date(2026, 8, 25, 9, 0), end: date(2026, 8, 25, 17, 30))
        let seconds = WorkHours.seconds(of: interval,
                                        withinDayStarting: date(2026, 8, 25),
                                        calendar: calendar)
        #expect(seconds == 8.5 * 3600)
    }

    @Test func aSessionOnAnotherDayCountsForNothing() {
        let interval = WorkInterval(start: date(2026, 8, 25, 9, 0), end: date(2026, 8, 25, 17, 0))
        #expect(WorkHours.seconds(of: interval,
                                  withinDayStarting: date(2026, 8, 26),
                                  calendar: calendar) == 0)
    }

    /// The overnight shift, which is the whole reason day attribution is
    /// not just "the day it started on."
    @Test func aSessionCrossingMidnightSplitsAcrossBothDays() {
        let interval = WorkInterval(start: date(2026, 8, 25, 21, 0), end: date(2026, 8, 26, 2, 0))
        let first = WorkHours.seconds(of: interval, withinDayStarting: date(2026, 8, 25), calendar: calendar)
        let second = WorkHours.seconds(of: interval, withinDayStarting: date(2026, 8, 26), calendar: calendar)
        #expect(first == 3 * 3600)
        #expect(second == 2 * 3600)
        #expect(first + second == interval.seconds)
    }

    /// A shift running through the spring forward hour is five hours on the
    /// clock face and four hours worked. The wall clock is what the day
    /// boundaries are made of, so the split has to add up to the elapsed
    /// time, not to the clock face difference.
    @Test func anOvernightSplitAddsUpAcrossSpringForward() {
        let interval = WorkInterval(start: date(2026, 3, 7, 23, 0), end: date(2026, 3, 8, 4, 0))
        let saturday = WorkHours.seconds(of: interval, withinDayStarting: date(2026, 3, 7), calendar: calendar)
        let sunday = WorkHours.seconds(of: interval, withinDayStarting: date(2026, 3, 8), calendar: calendar)
        #expect(saturday == 1 * 3600)
        #expect(saturday + sunday == interval.seconds)
        #expect(interval.seconds == 4 * 3600)
    }

    @Test func dailyTotalsSumEverySessionOnThatDay() {
        let days = WorkHours.days(inWeekStarting: date(2026, 8, 23), calendar: calendar)
        let intervals = [
            WorkInterval(start: date(2026, 8, 24, 9, 0), end: date(2026, 8, 24, 12, 0)),
            WorkInterval(start: date(2026, 8, 24, 13, 0), end: date(2026, 8, 24, 17, 0)),
            WorkInterval(start: date(2026, 8, 27, 8, 0), end: date(2026, 8, 27, 10, 30))
        ]
        let daily = WorkHours.dailySeconds(intervals: intervals, days: days, calendar: calendar)
        #expect(daily[0] == 0)              // Sunday
        #expect(daily[1] == 7 * 3600)       // Monday
        #expect(daily[4] == 2.5 * 3600)     // Thursday
        #expect(daily.reduce(0, +) == 9.5 * 3600)
    }

    /// A session outside the week must not leak into it, including one that
    /// began before the week and is still running inside it.
    @Test func sessionsOutsideTheWeekAreIgnored() {
        let days = WorkHours.days(inWeekStarting: date(2026, 8, 23), calendar: calendar)
        let intervals = [WorkInterval(start: date(2026, 8, 20, 9, 0), end: date(2026, 8, 20, 17, 0))]
        #expect(WorkHours.dailySeconds(intervals: intervals, days: days, calendar: calendar)
                    .reduce(0, +) == 0)
    }

    // MARK: Rounding

    @Test func roundsToTheNearestQuarterHour() {
        #expect(WorkHours.roundedToQuarterHour(0) == 0)
        #expect(WorkHours.roundedToQuarterHour(7 * 60) == 0)                  // 7 min down
        #expect(WorkHours.roundedToQuarterHour(8 * 60) == 15 * 60)            // 8 min up
        #expect(WorkHours.roundedToQuarterHour(7.5 * 60) == 15 * 60)          // half goes up
        #expect(WorkHours.roundedToQuarterHour(8 * 3600) == 8 * 3600)         // already exact
        #expect(WorkHours.roundedToQuarterHour(38 * 3600 + 12 * 60) == 38 * 3600 + 15 * 60)
    }

    /// Rounding once at the end is not the same as rounding each day and
    /// summing, and the difference is what goes on the timesheet. Seven
    /// days of 7 hours 52 minutes are 55.07 hours worked, which rounds once
    /// to 55.00. Rounded per day, each day loses 7 minutes to the nearest
    /// quarter and the week totals 54.25, three quarters of an hour that
    /// was worked and would never have been paid.
    @Test func theWeekRoundsOnceRatherThanPerDay() {
        let daily = Array(repeating: TimeInterval(7 * 3600 + 52 * 60), count: 7)
        let exact = daily.reduce(0, +)
        let roundedOnce = WorkHours.roundedToQuarterHour(exact)
        let roundedPerDay = daily.map(WorkHours.roundedToQuarterHour).reduce(0, +)
        #expect(roundedOnce == 55 * 3600)
        #expect(roundedPerDay == 54 * 3600 + 15 * 60)
        #expect(roundedOnce - roundedPerDay == 45 * 60)
    }

    // MARK: Display

    @Test func clockAndDecimalFormsAgree() {
        let seconds: TimeInterval = 7 * 3600 + 45 * 60
        #expect(WorkHours.clockString(seconds) == "7:45")
        #expect(WorkHours.decimalHoursString(seconds) == "7.75")
        #expect(WorkHours.stopwatchString(seconds + 9) == "7:45:09")
    }

    @Test func minutesAreTruncatedNotRounded() {
        // 59 seconds into a minute is still the minute before it.
        #expect(WorkHours.clockString(3600 + 59) == "1:00")
        #expect(WorkHours.stopwatchString(3600 + 59) == "1:00:59")
    }

    @Test func negativeAndZeroReadAsEmpty() {
        #expect(WorkHours.clockString(-500) == "0:00")
        #expect(WorkHours.decimalHoursString(-500) == "0.00")
        #expect(WorkInterval(start: date(2026, 8, 25, 12, 0),
                             end: date(2026, 8, 25, 9, 0)).seconds == 0)
    }

    // MARK: Overlap

    @Test func overlapIsDetectedButTouchingEndsAreNot() {
        let a = WorkInterval(start: date(2026, 8, 25, 9, 0), end: date(2026, 8, 25, 12, 0))
        let b = WorkInterval(start: date(2026, 8, 25, 11, 0), end: date(2026, 8, 25, 13, 0))
        let c = WorkInterval(start: date(2026, 8, 25, 12, 0), end: date(2026, 8, 25, 14, 0))
        #expect(WorkHours.overlaps(a, b))
        #expect(WorkHours.overlaps(b, a))
        // Clocking back in at the second you clocked out is not an overlap.
        #expect(WorkHours.overlaps(a, c) == false)
    }
}

/// The model side: the invariants `WorkSession` itself carries, without a
/// store. `WorkClock` needs a `ModelContext` and is exercised on device.
struct WorkSessionTests {

    @Test func anOpenSessionCountsUpToNow() {
        let start = Date(timeIntervalSince1970: 1_755_000_000)
        let session = WorkSession(startedAt: start)
        #expect(session.isRunning)
        #expect(session.seconds(now: start.addingTimeInterval(3600)) == 3600)
    }

    @Test func aClosedSessionIgnoresNow() {
        let start = Date(timeIntervalSince1970: 1_755_000_000)
        let session = WorkSession(startedAt: start, endedAt: start.addingTimeInterval(1800))
        #expect(session.isRunning == false)
        #expect(session.seconds(now: start.addingTimeInterval(99_999)) == 1800)
    }

    /// An end time hand edited to before the start reads as empty rather
    /// than as negative work, which would subtract hours from the day.
    @Test func aBackwardsSessionIsZeroNotNegative() {
        let start = Date(timeIntervalSince1970: 1_755_000_000)
        let session = WorkSession(startedAt: start, endedAt: start.addingTimeInterval(-600))
        #expect(session.seconds(now: start) == 0)
        #expect(session.interval(now: start).seconds == 0)
    }
}
