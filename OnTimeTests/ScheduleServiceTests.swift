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

    /// Regression: the alarm scheduler asks for the next occurrence whose
    /// *arm moment* is still ahead, not just the next occurrence. Asking for
    /// the plain next one meant that between arming and the deadline there
    /// was no future arm time to schedule, so `refreshArmAlarms` (which runs
    /// immediately after `armDueRoutines`) erased the routine's own next
    /// alarm the moment it fired, and a daily routine could notify exactly
    /// once ever.
    @Test func futureArmSkipsAnOccurrenceWhoseWindowAlreadyOpened() {
        let r = routine(anchorHour: 20, anchorMinute: 0, stepMinutes: [30], armLead: 60)

        // 19:00 — armed at 18:30, deadline 20:00 not yet reached.
        let now = date(2026, 8, 20, 19, 0)

        let plain = ScheduleService.nextOccurrence(for: r, now: now, calendar: calendar)
        #expect(plain?.deadline == date(2026, 8, 20, 20, 0))
        #expect(plain?.armAt == date(2026, 8, 20, 18, 30))

        let forAlarms = ScheduleService.nextOccurrence(for: r, now: now, calendar: calendar,
                                                      requiringFutureArm: true)
        #expect(forAlarms?.deadline == date(2026, 8, 21, 20, 0))
        #expect(forAlarms?.armAt == date(2026, 8, 21, 18, 30))
    }

    @Test func futureArmKeepsTodaysOccurrenceBeforeTheWindowOpens() {
        let r = routine(anchorHour: 20, anchorMinute: 0, stepMinutes: [30], armLead: 60)
        let occurrence = ScheduleService.nextOccurrence(for: r, now: date(2026, 8, 20, 12, 0),
                                                       calendar: calendar,
                                                       requiringFutureArm: true)
        #expect(occurrence?.armAt == date(2026, 8, 20, 18, 30))
    }

    // MARK: - The arm alerts

    /// Two alerts per occurrence and no more: the window opening, and the
    /// moment you have to go.
    ///
    /// This used to be a chain — one every ten minutes across the whole
    /// window, capped at seven — on the theory that iOS won't pin a banner
    /// so persistence had to be built out of repetition. Seven
    /// time-sensitive sounding interruptions saying near-identical sentences
    /// about a number already on the Lock Screen is not persistence, and it
    /// was the single loudest thing the app did.
    @Test func armAlertsAreTheWindowOpeningAndTheGoMoment() {
        let armAt = date(2026, 8, 20, 18, 30)
        let start = date(2026, 8, 20, 19, 30)
        #expect(Notifications.armAlertTimes(from: armAt, to: start) == [armAt, start])
    }

    /// A four-hour lead is allowed by the editor, and it still produces
    /// exactly two requests, so nothing here can crowd a running plan's step
    /// notifications out of the 64-request pending limit.
    @Test func aLongLeadStillProducesTwoAlerts() {
        let armAt = date(2026, 8, 20, 16, 0)
        let start = date(2026, 8, 20, 20, 0)
        #expect(Notifications.armAlertTimes(from: armAt, to: start) == [armAt, start])
    }

    /// A zero-duration window (no steps, so start == deadline == arm) must
    /// produce one alert, not two identical ones.
    @Test func armAlertsDoNotDuplicateAZeroLengthWindow() {
        let t = date(2026, 8, 20, 18, 30)
        #expect(Notifications.armAlertTimes(from: t, to: t) == [t])
    }

    /// A short window collapses to the go alert alone. Two banners a few
    /// minutes apart, reading "starts in 3 min" and then "start now", is the
    /// repetition the chain was cut to stop, and the second is the one worth
    /// keeping.
    @Test func aShortWindowKeepsOnlyTheGoAlert() {
        let armAt = date(2026, 8, 20, 12, 0)
        let start = date(2026, 8, 20, 12, 3)
        #expect(Notifications.armAlertTimes(from: armAt, to: start) == [start])
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

    /// A routine with an open duration step still gets a real must-start
    /// time: the latest possible start (zero flex), not the deadline
    /// itself. The deadline fallback armed such routines with no lead over
    /// their fixed steps at all.
    @Test func openDurationRoutineDerivesMustStartFromKnownSteps() {
        let r = routine(anchorHour: 20, anchorMinute: 0, stepMinutes: [30])
        let flex = Block(order: 1, name: "Walk", kind: .walk)
        flex.routine = r
        r.blocks.append(flex)
        r.renumber()

        let occurrence = ScheduleService.nextOccurrence(for: r, now: date(2026, 8, 20, 12, 0), calendar: calendar)

        // 30 minutes of known steps, zero for the walk: start 19:30.
        #expect(occurrence?.mustStartAt == date(2026, 8, 20, 19, 30))
    }

    // MARK: - Arming (materialization), against a real in-memory store

    private func inMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Schema(Schema0.models), configurations: config)
        return ModelContext(container)
    }

    /// The midnight straddle: a routine anchored at 00:30 with a window
    /// opening at 22:50 the previous evening must arm exactly once for that
    /// occurrence, whichever side of midnight the app is foregrounded on.
    /// Keying idempotence on "the day arming happened" armed it twice.
    @Test func midnightStraddlingWindowArmsExactlyOnce() throws {
        let context = try inMemoryContext()
        let r = routine(anchorHour: 0, anchorMinute: 30, stepMinutes: [40], armLead: 60)
        context.insert(r)

        // 23:00: window (22:50) is open for tomorrow's 00:30 deadline.
        let eveningRuns = ScheduleService.armDueRoutines(in: context, now: date(2026, 8, 20, 23, 0), calendar: calendar)
        #expect(eveningRuns.count == 1)
        // Born backdated to the arm moment, not to "now".
        #expect(eveningRuns.first?.startedAt == date(2026, 8, 20, 22, 50))

        // Same evening again: idempotent.
        let again = ScheduleService.armDueRoutines(in: context, now: date(2026, 8, 20, 23, 10), calendar: calendar)
        #expect(again.isEmpty)

        // 00:05, past midnight, same occurrence still pending: must NOT
        // arm a second run.
        let midnight = ScheduleService.armDueRoutines(in: context, now: date(2026, 8, 21, 0, 5), calendar: calendar)
        #expect(midnight.isEmpty)

        for run in eveningRuns { RunEngineStore.shared.retire(run) }
    }

    /// Ordinary same-day arming still works and stays idempotent.
    @Test func armingIsIdempotentPerOccurrence() throws {
        let context = try inMemoryContext()
        let r = routine(anchorHour: 20, anchorMinute: 0, stepMinutes: [30], armLead: 60)
        context.insert(r)

        let first = ScheduleService.armDueRoutines(in: context, now: date(2026, 8, 20, 19, 0), calendar: calendar)
        #expect(first.count == 1)
        #expect(first.first?.startedAt == date(2026, 8, 20, 18, 30))
        #expect(first.first?.plan?.routine === r)

        // The spawned blocks are copies, renumbered, owned by the plan.
        let plan = try #require(first.first?.plan)
        #expect(plan.orderedBlocks.count == 1)
        #expect(plan.orderedBlocks.first !== r.orderedBlocks.first)

        let second = ScheduleService.armDueRoutines(in: context, now: date(2026, 8, 20, 19, 30), calendar: calendar)
        #expect(second.isEmpty)

        for run in first { RunEngineStore.shared.retire(run) }
    }
}
