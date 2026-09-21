import Foundation
import Testing
@testable import OnTime

/// The Pi changes the Live Activity at moments the app computed in advance,
/// with the app suspended and unable to correct anything. A wrong time or a
/// wrong id here is a wrong Dynamic Island with nobody watching, so the two
/// pure pieces the whole path rests on are pinned down.
@MainActor
struct PiPushTests {

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

    // MARK: - The id a pushed activity and its run share

    /// The Pi uses the id computed when the schedule was uploaded; the app
    /// computes it again when it arms. They must agree or the run raises a
    /// second activity beside the pushed one.
    @Test func theSameRoutineAndDayAlwaysGiveTheSamePlanId() {
        let routine = UUID()
        let a = OccurrenceIdentity.planUUID(routine: routine, deadline: date(2026, 9, 21, 6, 15), calendar: calendar)
        let b = OccurrenceIdentity.planUUID(routine: routine, deadline: date(2026, 9, 21, 6, 15), calendar: calendar)
        #expect(a == b)
    }

    /// An iqama moved fifteen minutes after the Pi already has the schedule
    /// must keep the id, so the app updates the pushed activity to the new
    /// time instead of orphaning it and starting another.
    @Test func movingTheAnchorTimeWithinTheDayKeepsThePlanId() {
        let routine = UUID()
        let before = OccurrenceIdentity.planUUID(routine: routine, deadline: date(2026, 9, 21, 13, 30), calendar: calendar)
        let after = OccurrenceIdentity.planUUID(routine: routine, deadline: date(2026, 9, 21, 13, 45), calendar: calendar)
        #expect(before == after)
    }

    @Test func anotherDayOrAnotherRoutineGivesAnotherPlanId() {
        let routine = UUID()
        let monday = OccurrenceIdentity.planUUID(routine: routine, deadline: date(2026, 9, 21, 6, 15), calendar: calendar)
        let tuesday = OccurrenceIdentity.planUUID(routine: routine, deadline: date(2026, 9, 22, 6, 15), calendar: calendar)
        let other = OccurrenceIdentity.planUUID(routine: UUID(), deadline: date(2026, 9, 21, 6, 15), calendar: calendar)
        #expect(monday != tuesday)
        #expect(monday != other)
    }

    // MARK: - When the surfaces leave each step

    private func step(_ minutes: Double, target: Date, auto: Bool = true) -> RunProjection.Step {
        .init(seconds: minutes * 60, autoAdvances: auto, target: target)
    }

    /// On schedule, every step ends on its estimate, which is its target.
    @Test func aRunOnScheduleLeavesEachStepAtItsTarget() {
        let start = date(2026, 9, 21, 7, 0)
        let found = RunProjection.untils(steps: [step(10, target: date(2026, 9, 21, 7, 10)),
                                                 step(20, target: date(2026, 9, 21, 7, 30)),
                                                 step(5, target: date(2026, 9, 21, 7, 35))],
                                         from: start)
        #expect(found == [date(2026, 9, 21, 7, 10), date(2026, 9, 21, 7, 30), date(2026, 9, 21, 7, 35)])
    }

    /// Started five minutes early: the engine moves on when each estimate
    /// runs out, five minutes before each target, and the surfaces go with
    /// it.
    @Test func aRunAheadOfScheduleLeavesEachStepOnItsEstimate() {
        let start = date(2026, 9, 21, 6, 55)
        let found = RunProjection.untils(steps: [step(10, target: date(2026, 9, 21, 7, 10)),
                                                 step(20, target: date(2026, 9, 21, 7, 30))],
                                         from: start)
        #expect(found == [date(2026, 9, 21, 7, 5), date(2026, 9, 21, 7, 25)])
    }

    /// Started three minutes late: each target passes with the engine still
    /// on the step. This is where the plate used to go red for three minutes
    /// at the end of every step. The surfaces move on at the target.
    @Test func aRunBehindScheduleLeavesEachStepAtItsTarget() {
        let start = date(2026, 9, 21, 7, 3)
        let found = RunProjection.untils(steps: [step(10, target: date(2026, 9, 21, 7, 10)),
                                                 step(20, target: date(2026, 9, 21, 7, 30))],
                                         from: start)
        #expect(found == [date(2026, 9, 21, 7, 10), date(2026, 9, 21, 7, 30)])
    }

    /// A step that waits for a tap is left at its target, not held until the
    /// tap, and projection carries on past it. It used to stop there, and the
    /// plate sat on that step red and counting up. Past it the engine's own
    /// walk is unknowable, so later steps are left at their targets even
    /// though the run began early.
    @Test func aStepThatWaitsForATapIsLeftAtItsTargetAndSoIsEverythingAfterIt() {
        let start = date(2026, 9, 21, 6, 55)
        let found = RunProjection.untils(steps: [step(10, target: date(2026, 9, 21, 7, 10)),
                                                 step(20, target: date(2026, 9, 21, 7, 30), auto: false),
                                                 step(5, target: date(2026, 9, 21, 7, 35))],
                                         from: start)
        #expect(found == [date(2026, 9, 21, 7, 5), date(2026, 9, 21, 7, 30), date(2026, 9, 21, 7, 35)])
    }
}
