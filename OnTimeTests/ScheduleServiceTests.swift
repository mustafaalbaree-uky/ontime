import Foundation
import Testing
import SwiftData
@testable import OnTime

/// The arming model's core claim is that a routine's times are a pure
/// function of the clock — never of when the user happened to interact. That
/// is what lets a notification tapped fifteen minutes late land on the
/// correct remaining time instead of restarting the countdown, and it is the
/// only reason the feature works at all without a push server. These tests
/// pin that property down.
@MainActor
struct ScheduleServiceTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        return calendar.date(from: comps)!
    }

    private func routine(anchorHour: Int, anchorMinute: Int,
                         stepMinutes: [Int],
                         weekdays: Set<Int> = Set(1...7),
                         armLead: Int = 60) -> ScheduledRoutine {
        let r = ScheduledRoutine(name: "Test", anchorHour: anchorHour, anchorMinute: anchorMinute,
                                 weekdays: weekdays, armLeadMinutes: armLead)
        var blocks: [Block] = []
        for (index, minutes) in stepMinutes.enumerated() {
            let b = Block(order: index, name: "Step \(index)", kind: .fixed,
                          estimateOverrideMinutes: minutes)
            b.routine = r
            blocks.append(b)
        }
        r.blocks = blocks
        return r
    }

    // MARK: - Deriving the occurrence

    @Test func mustStartIsDeadlineMinusTotalDuration() {
        // 30 min of steps, anchored at 20:00 → start 19:30, arm 18:30.
        let r = routine(anchorHour: 20, anchorMinute: 0, stepMinutes: [10, 20])
        let now = date(2026, 8, 20, 12, 0)

        let occurrence = ScheduleService.nextOccurrence(for: r, now: now, calendar: calendar)

        #expect(occurrence?.deadline == date(2026, 8, 20, 20, 0))
        #expect(occurrence?.mustStartAt == date(2026, 8, 20, 19, 30))
        #expect(occurrence?.armAt == date(2026, 8, 20, 18, 30))
    }

    /// The arm lead is measured from the *start* time, not the deadline — an
    /// hour before the deadline can already be too late when the sequence
    /// itself is longer than an hour.
    @Test func armLeadIsRelativeToStartNotDeadline() {
        let r = routine(anchorHour: 20, anchorMinute: 0, stepMinutes: [90], armLead: 60)
        let now = date(2026, 8, 20, 6, 0)

        let occurrence = ScheduleService.nextOccurrence(for: r, now: now, calendar: calendar)

        #expect(occurrence?.mustStartAt == date(2026, 8, 20, 18, 30))
        #expect(occurrence?.armAt == date(2026, 8, 20, 17, 30))
    }

    @Test func armTimeMovesWhenAStepDurationChanges() {
        let r = routine(anchorHour: 20, anchorMinute: 0, stepMinutes: [10, 20])
        let now = date(2026, 8, 20, 12, 0)
        let before = ScheduleService.nextOccurrence(for: r, now: now, calendar: calendar)

        r.orderedBlocks[0].estimateOverrideMinutes = 40  // +30 min

        let after = ScheduleService.nextOccurrence(for: r, now: now, calendar: calendar)

        #expect(after?.deadline == before?.deadline)
        #expect(after?.mustStartAt == before!.mustStartAt.addingTimeInterval(-30 * 60))
        #expect(after?.armAt == before!.armAt.addingTimeInterval(-30 * 60))
    }

    // MARK: - Rolling forward

    /// Once today's deadline has passed the occurrence is tomorrow's. Note
    /// this keys on the *deadline* passing, not the start time — a start time
    /// in the past just means you're late, which is a real state worth
    /// showing rather than a reason to skip a day. Same rule
    /// `DeadlineResolver` documents.
    @Test func rollsToTomorrowOnlyAfterTheDeadlineItselfPasses() {
        let r = routine(anchorHour: 20, anchorMinute: 0, stepMinutes: [30])

        // 19:45 — start time (19:30) is already gone, deadline is not.
        let late = ScheduleService.nextOccurrence(for: r, now: date(2026, 8, 20, 19, 45), calendar: calendar)
        #expect(late?.deadline == date(2026, 8, 20, 20, 0))

        // 20:15 — deadline gone, so it's tomorrow's.
        let tomorrow = ScheduleService.nextOccurrence(for: r, now: date(2026, 8, 20, 20, 15), calendar: calendar)
        #expect(tomorrow?.deadline == date(2026, 8, 21, 20, 0))
    }

    @Test func skipsToNextEligibleWeekday() {
        // Fridays only (Calendar weekday 6), asked on Saturday 2026-08-22.
        let r = routine(anchorHour: 20, anchorMinute: 0, stepMinutes: [30], weekdays: [6])
        let saturday = date(2026, 8, 22, 9, 0)
        #expect(calendar.component(.weekday, from: saturday) == 7)

        let occurrence = ScheduleService.nextOccurrence(for: r, now: saturday, calendar: calendar)

        #expect(occurrence?.deadline == date(2026, 8, 28, 20, 0))
    }

    @Test func skippedDayIsPassedOver() {
        let r = routine(anchorHour: 20, anchorMinute: 0, stepMinutes: [30])
        let now = date(2026, 8, 20, 9, 0)
        r.skip(on: now, calendar: calendar)

        let occurrence = ScheduleService.nextOccurrence(for: r, now: now, calendar: calendar)

        #expect(occurrence?.deadline == date(2026, 8, 21, 20, 0))
    }

    @Test func disabledRoutineHasNoOccurrence() {
        let r = routine(anchorHour: 20, anchorMinute: 0, stepMinutes: [30])
        r.isEnabled = false
        #expect(ScheduleService.nextOccurrence(for: r, now: date(2026, 8, 20, 9, 0), calendar: calendar) == nil)
    }

    // MARK: - The arm window

    @Test func isArmedOnlyOnceTheWindowOpens() {
        let r = routine(anchorHour: 20, anchorMinute: 0, stepMinutes: [30], armLead: 60)
        let now = date(2026, 8, 20, 12, 0)
        let occurrence = ScheduleService.nextOccurrence(for: r, now: now, calendar: calendar)!

        // Window opens at 18:30 (start 19:30 minus 60).
        #expect(occurrence.armAt == date(2026, 8, 20, 18, 30))
        #expect(occurrence.isArmed(at: date(2026, 8, 20, 18, 29)) == false)
        #expect(occurrence.isArmed(at: date(2026, 8, 20, 18, 30)) == true)
        #expect(occurrence.isArmed(at: date(2026, 8, 20, 19, 45)) == true)
    }

    /// A routine with no steps still has a deadline worth counting to; it
    /// just has nothing to work backwards through.
    @Test func emptyRoutineAnchorsStartToTheDeadline() {
        let r = routine(anchorHour: 20, anchorMinute: 0, stepMinutes: [])
        let occurrence = ScheduleService.nextOccurrence(for: r, now: date(2026, 8, 20, 9, 0), calendar: calendar)

        #expect(occurrence?.mustStartAt == occurrence?.deadline)
    }

    @Test func weekdaysRoundTripThroughStorage() {
        let r = routine(anchorHour: 6, anchorMinute: 0, stepMinutes: [], weekdays: [2, 4, 6])
        #expect(r.weekdays == [2, 4, 6])
        #expect(r.runsEveryDay == false)

        r.weekdays = Set(1...7)
        #expect(r.runsEveryDay)
    }
}
