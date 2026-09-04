import Foundation
import Testing
@testable import OnTime

struct DeadlineResolverTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ hour: Int, _ minute: Int, day: Int = 19) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)!
    }

    // MARK: 9. Deadline later today stays today.

    @Test func deadlineLaterTodayStaysToday() {
        let now = date(10, 0)
        let resolved = DeadlineResolver.resolve(hour: 19, minute: 30, now: now, calendar: calendar)
        #expect(resolved == date(19, 30))
    }

    // MARK: 10. Deadline already past rolls to tomorrow.

    @Test func deadlineAlreadyPastRollsToTomorrow() {
        let now = date(20, 0)
        let resolved = DeadlineResolver.resolve(hour: 19, minute: 30, now: now, calendar: calendar)
        #expect(resolved == date(19, 30, day: 20))
    }

    // MARK: 10b. Midnight boundary: a 00:30 deadline at 23:50 is 40 minutes
    // away, not a day and 40 minutes.

    @Test func justBeforeMidnightRollsToEarlyTomorrowCorrectly() {
        let now = date(23, 50)
        let resolved = DeadlineResolver.resolve(hour: 0, minute: 30, now: now, calendar: calendar)
        #expect(resolved == date(0, 30, day: 20))
        #expect(resolved.timeIntervalSince(now) == 40 * 60)
    }

    // MARK: 10c. Exactly at the deadline second: not yet past, stays today.

    @Test func exactlyAtTheDeadlineStaysToday() {
        let now = date(19, 30)
        let resolved = DeadlineResolver.resolve(hour: 19, minute: 30, now: now, calendar: calendar)
        #expect(resolved == now)
    }

    // MARK: 10d. Out-of-range components clamp instead of silently
    // normalizing onto the wrong day (Calendar rolls hour 25 into
    // tomorrow's 01:00 with no error).

    @Test func outOfRangeHourClampsInsteadOfRollingDays() {
        // Release behavior (assertionFailure is a no-op there): clamped to
        // 23:59, still today.
        let now = date(10, 0)
        let resolved = DeadlineResolver.resolve(hour: 25, minute: 75, now: now, calendar: calendar)
        #expect(calendar.isDate(resolved, inSameDayAs: now))
        #expect(calendar.component(.hour, from: resolved) == 23)
        #expect(calendar.component(.minute, from: resolved) == 59)
    }

    // MARK: 11. Deadline ahead but required start already past -> stays TODAY, reports lateness.
    // This is the bug in `time app.html`: it rolled the whole deadline to
    // tomorrow just because (deadline - prep) was already behind `now`.

    @Test func deadlineAheadWithPastRequiredStartStaysTodayAndIsLate() {
        // Iqama in 4 minutes; prep takes 7 minutes, so the required start
        // time is already 3 minutes behind us. The deadline itself has NOT
        // passed yet.
        let now = date(19, 26)
        let resolved = DeadlineResolver.resolve(hour: 19, minute: 30, now: now, calendar: calendar)

        // Must stay today, not roll to tomorrow.
        #expect(resolved == date(19, 30))
        #expect(calendar.isDate(resolved, inSameDayAs: now))

        // Independently, confirm the "already late" scenario this guards:
        // the required start time (deadline - prep) is behind `now`, which
        // must surface as lateness rather than silently pushing the whole
        // plan to tomorrow.
        let prep: TimeInterval = 7 * 60
        let requiredStart = resolved.addingTimeInterval(-prep)
        #expect(requiredStart < now)

        // And the solver reports this as first-class lateness, not as a
        // rolled deadline.
        let solverInput = SolverInput(durations: [.known(prep)], deadline: resolved, start: now, pinnedFlex: nil)
        let solution = try? Solver.solve(solverInput)
        #expect(solution?.lateness == now.addingTimeInterval(prep).timeIntervalSince(resolved))
        #expect((solution?.lateness ?? 0) > 0)
    }
}
