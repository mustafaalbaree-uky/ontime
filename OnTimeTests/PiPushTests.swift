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

    // MARK: - Step boundaries

    private func step(_ minutes: Double, auto: Bool = true) -> RunProjection.Step {
        .init(seconds: minutes * 60, autoAdvances: auto)
    }

    @Test func everyAutoAdvancingStepEndsOnItsEstimateAndTheLastEndsTheRun() {
        let start = date(2026, 9, 21, 7, 0)
        let found = RunProjection.boundaries(steps: [step(10), step(20), step(5)],
                                             currentIndex: 0, currentStart: start, now: start)
        #expect(found == [
            .init(entering: 1, at: date(2026, 9, 21, 7, 10)),
            .init(entering: 2, at: date(2026, 9, 21, 7, 30)),
            .init(entering: 3, at: date(2026, 9, 21, 7, 35))
        ])
    }

    /// Past a step that waits for a tap, nothing can be known: the next
    /// change happens when he taps. Entering that step is still projected.
    @Test func projectionStopsAtTheFirstStepThatWaitsForATap() {
        let start = date(2026, 9, 21, 7, 0)
        let found = RunProjection.boundaries(steps: [step(10), step(20, auto: false), step(5)],
                                             currentIndex: 0, currentStart: start, now: start)
        #expect(found == [.init(entering: 1, at: date(2026, 9, 21, 7, 10))])
    }

    @Test func aCurrentStepThatWaitsForATapProjectsNothing() {
        let start = date(2026, 9, 21, 7, 0)
        let found = RunProjection.boundaries(steps: [step(10, auto: false), step(20)],
                                             currentIndex: 0, currentStart: start, now: start)
        #expect(found.isEmpty)
    }

    /// Mid run, from the step he is on, with the time already spent in it.
    @Test func projectionStartsFromTheCurrentStepsOwnStart() {
        let stepTwoBegan = date(2026, 9, 21, 7, 12)
        let found = RunProjection.boundaries(steps: [step(10), step(20), step(5)],
                                             currentIndex: 1, currentStart: stepTwoBegan,
                                             now: date(2026, 9, 21, 7, 20))
        #expect(found == [
            .init(entering: 2, at: date(2026, 9, 21, 7, 32)),
            .init(entering: 3, at: date(2026, 9, 21, 7, 37))
        ])
    }

    /// A boundary that already went by belongs to `reconcile`, not to the
    /// Pi. Later ones still count from it, not from now.
    @Test func boundariesAlreadyPassedAreLeftOutButStillAnchorTheRest() {
        let start = date(2026, 9, 21, 7, 0)
        let found = RunProjection.boundaries(steps: [step(10), step(20)],
                                             currentIndex: 0, currentStart: start,
                                             now: date(2026, 9, 21, 7, 15))
        #expect(found == [.init(entering: 2, at: date(2026, 9, 21, 7, 30))])
    }
}
