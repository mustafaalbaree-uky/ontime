import Foundation
import Testing
@testable import OnTime

/// Tests for `WalkMath`, the part of a walk block that can be reasoned
/// about without a GPS. `WalkTracker` is the sensor plumbing around this;
/// everything that decides when to buzz lives here.
struct WalkTests {

    private func at(_ minute: Int) -> Date {
        Date(timeIntervalSince1970: 1_755_000_000).addingTimeInterval(Double(minute) * 60)
    }

    // MARK: Pace

    @Test func firstMovingSampleIsTakenWhole() {
        #expect(WalkMath.updatedPace(previous: nil, sampleMetersPerSecond: 1.4) == 1.4)
    }

    /// Standing at a crosswalk must not drag the pace estimate down: the
    /// walk back will be walked, not loitered.
    @Test func standingStillDoesNotMovePace() {
        let pace = WalkMath.updatedPace(previous: 1.4, sampleMetersPerSecond: 0.05)
        #expect(pace == 1.4)
    }

    @Test func standingStillBeforeAnyMeasurementLeavesPaceUnknown() {
        #expect(WalkMath.updatedPace(previous: nil, sampleMetersPerSecond: 0.1) == nil)
    }

    /// A GPS jump that implies a sprint gets clamped rather than laundered
    /// into the return estimate, which is the number the alarm rests on.
    @Test func wildSampleIsClamped() throws {
        let pace = try #require(WalkMath.updatedPace(previous: nil, sampleMetersPerSecond: 40))
        #expect(pace == WalkMath.maxPace)
    }

    /// The region between the moving threshold (0.4) and the minimum
    /// plausible pace (0.6): counted as moving, clamped *up*. This is
    /// exactly where "moving" and "plausible pace" disagree, so a guard
    /// reorder changes behavior here first.
    @Test func slowButMovingSampleClampsUpToMinPace() throws {
        let pace = try #require(WalkMath.updatedPace(previous: nil, sampleMetersPerSecond: 0.5))
        #expect(pace == WalkMath.minPace)
    }

    @Test func paceMovesGraduallyTowardNewSamples() throws {
        var pace = WalkMath.updatedPace(previous: nil, sampleMetersPerSecond: 1.0)
        for _ in 0..<20 {
            pace = WalkMath.updatedPace(previous: pace, sampleMetersPerSecond: 1.6)
        }
        let settled = try #require(pace)
        // One sample must not jump it, twenty must nearly get it there.
        #expect(settled > 1.5 && settled <= 1.6)
    }

    // MARK: Return estimate

    /// The whole idea: a route supplies the metres, the walk supplies the
    /// seconds per metre. 1200 m at 1.0 m/s is 20 minutes even though Maps,
    /// walking its generic 1.4 m/s, would have said 14.
    @Test func routeDistanceIsTimedAtTheMeasuredPace() {
        let e = WalkMath.returnEstimate(
            routeDistanceMeters: 1200,
            routeSeconds: 857,
            retraceSeconds: 3000,
            measuredPace: 1.0,
            safetyFraction: 0
        )
        #expect(e.source == .routedAtMyPace)
        #expect(e.rawSeconds == 1200)
    }

    @Test func mapsOwnDurationIsUsedUntilAPaceIsMeasured() {
        let e = WalkMath.returnEstimate(
            routeDistanceMeters: 1200,
            routeSeconds: 857,
            retraceSeconds: 3000,
            measuredPace: nil,
            safetyFraction: 0
        )
        #expect(e.source == .routed)
        #expect(e.rawSeconds == 857)
    }

    /// Off-road, or with no signal, it falls back to exactly the rule
    /// Mustafa described: the way back costs what the way out cost.
    @Test func retraceIsTheFallbackWhenNothingRoutes() {
        let e = WalkMath.returnEstimate(
            routeDistanceMeters: nil,
            routeSeconds: nil,
            retraceSeconds: 1320,
            measuredPace: 1.3,
            safetyFraction: 0
        )
        #expect(e.source == .retrace)
        #expect(e.rawSeconds == 1320)
    }

    /// The fourth nil-combination: a route distance with no route duration
    /// and no measured pace can't be timed, so it falls through to retrace.
    @Test func routeDistanceAloneWithoutPaceFallsToRetrace() {
        let e = WalkMath.returnEstimate(
            routeDistanceMeters: 1200,
            routeSeconds: nil,
            retraceSeconds: 900,
            measuredPace: nil,
            safetyFraction: 0
        )
        #expect(e.source == .retrace)
        #expect(e.rawSeconds == 900)
    }

    /// A negative safety fraction would shrink the padded estimate below
    /// the raw one, inverting the entire justification for padding.
    @Test func negativeSafetyFractionIsClampedToZero() {
        let e = WalkMath.returnEstimate(
            routeDistanceMeters: 1000,
            routeSeconds: nil,
            retraceSeconds: 0,
            measuredPace: 1.0,
            safetyFraction: -0.5
        )
        #expect(e.seconds == e.rawSeconds)
    }

    @Test func safetyMarginPadsTheEstimateButNotTheRawNumber() {
        let e = WalkMath.returnEstimate(
            routeDistanceMeters: 1000,
            routeSeconds: nil,
            retraceSeconds: 0,
            measuredPace: 1.0,
            safetyFraction: 0.15
        )
        #expect(e.rawSeconds == 1000)
        #expect(e.seconds == 1150)
    }

    // MARK: Turnaround

    /// The case that started this: be home by 7:50, eighteen minutes back
    /// from where you are standing, so turn around at 7:32.
    @Test func turnaroundIsTheDeadlineMinusTheWayBack() {
        let homeBy = at(470)
        let turn = WalkMath.turnaroundTime(homeBy: homeBy, returnSeconds: 18 * 60)
        #expect(turn == at(452))
    }

    @Test func slackIsPositiveWhileThereIsStillRoom() {
        let slack = WalkMath.slack(now: at(440), homeBy: at(470), returnSeconds: 18 * 60)
        #expect(slack == 12 * 60)
    }

    /// Past the turnaround the slack goes negative rather than clamping to
    /// zero, because "you are four minutes past the point of no return" is
    /// a different situation from "turn around exactly now" and the screen
    /// has to be able to tell them apart.
    @Test func slackGoesNegativePastTheTurnaround() {
        let slack = WalkMath.slack(now: at(456), homeBy: at(470), returnSeconds: 18 * 60)
        #expect(slack == -4 * 60)
    }

    /// Every extra minute walked away is paid for twice, so the room left
    /// is half the slack, never all of it.
    @Test func remainingOutboundIsHalfTheSlack() {
        #expect(WalkMath.remainingOutbound(slack: 12 * 60) == 6 * 60)
    }

    @Test func remainingOutboundNeverGoesNegative() {
        #expect(WalkMath.remainingOutbound(slack: -600) == 0)
    }

    /// A walk with a shortcut home gets *more* room as it goes, not less:
    /// the same wall clock moment, with a cheaper way back, turns around
    /// later. This is what a routed estimate buys over retracing.
    @Test func aShorterWayHomeBuysMoreWalkingTime() {
        let homeBy = at(470)
        let retracing = WalkMath.turnaroundTime(homeBy: homeBy, returnSeconds: 22 * 60)
        let shortcut = WalkMath.turnaroundTime(homeBy: homeBy, returnSeconds: 14 * 60)
        #expect(shortcut > retracing)
        #expect(shortcut.timeIntervalSince(retracing) == 8 * 60)
    }

    @Test func projectedArrivalIsNowPlusTheWayBack() {
        #expect(WalkMath.projectedArrival(now: at(440), returnSeconds: 18 * 60) == at(458))
    }

    // MARK: Alarm policy
    //
    // The two shipped bugs these pin: a turnaround estimate that slipped
    // into the past used to cancel the pending alarm and arm nothing, and
    // the returning-phase late alarm was re-armed at now+30s on every
    // one-second tick, perpetually deferred and never firing.

    private func outboundDecision(turnaround: Date, now: Date,
                                  armed: Date? = nil,
                                  pastFired: Bool = false,
                                  force: Bool = false) -> WalkMath.AlarmDecision {
        WalkMath.alarmDecision(
            phase: .outbound, now: now, homeBy: at(470),
            turnaroundAt: turnaround, headsUpLead: 600,
            projectedArrival: at(470),
            armedTurnaround: armed, pastTurnaroundFired: pastFired,
            lateAlarmArmed: false, force: force
        )
    }

    private func returningDecision(arrival: Date, now: Date,
                                   lateArmed: Bool) -> WalkMath.AlarmDecision {
        WalkMath.alarmDecision(
            phase: .returning, now: now, homeBy: at(470),
            turnaroundAt: at(450), headsUpLead: 600,
            projectedArrival: arrival,
            armedTurnaround: nil, pastTurnaroundFired: false,
            lateAlarmArmed: lateArmed, force: false
        )
    }

    @Test func futureTurnaroundArmsBothOutboundAlarms() {
        let d = outboundDecision(turnaround: at(452), now: at(440))
        #expect(d.turnaround == .arm(at(452)))
        #expect(d.headsUp == .arm(at(442)))  // 10 minutes before
        #expect(d.late == .keep)
    }

    @Test func unmovedTurnaroundIsNotRearmed() {
        let d = outboundDecision(turnaround: at(452), now: at(440), armed: at(452).addingTimeInterval(10))
        #expect(d == WalkMath.AlarmDecision(turnaround: .keep, headsUp: .keep, late: .keep))
    }

    @Test func pastTurnaroundFiresImmediatelyInsteadOfDisarming() {
        let d = outboundDecision(turnaround: at(452), now: at(455), armed: at(451))
        #expect(d.turnaround == .fireNow)
        #expect(d.headsUp == .cancel)
    }

    @Test func pastTurnaroundFiresOnlyOncePerCrossing() {
        let d = outboundDecision(turnaround: at(452), now: at(456), pastFired: true)
        #expect(d == WalkMath.AlarmDecision(turnaround: .keep, headsUp: .keep, late: .keep))
    }

    @Test func lateArrivalArmsTheLateAlarmOnce() {
        let now = at(455)
        let first = returningDecision(arrival: at(480), now: now, lateArmed: false)
        #expect(first.late == .arm(now.addingTimeInterval(30)))

        // Already armed: never re-deferred, no matter how many ticks pass.
        let second = returningDecision(arrival: at(481), now: at(456), lateArmed: true)
        #expect(second.late == .keep)
    }

    @Test func backOnTimeCancelsTheLateAlarmWithHysteresis() {
        // A minute or more of margin cancels…
        let clearlyOnTime = returningDecision(arrival: at(468), now: at(455), lateArmed: true)
        #expect(clearlyOnTime.late == .cancel)
        // …but a few seconds inside the boundary keeps it, so a wobbling
        // pace estimate does not arm and cancel every tick.
        let barelyOnTime = returningDecision(arrival: at(470).addingTimeInterval(-20), now: at(455), lateArmed: true)
        #expect(barelyOnTime.late == .keep)
    }

    // MARK: Kind

    @Test func walkAndFlexAreBothSolvedFor() {
        #expect(BlockKind.walk.isOpenDuration)
        #expect(BlockKind.flex.isOpenDuration)
        #expect(!BlockKind.drive.isOpenDuration)
        #expect(!BlockKind.fixed.isOpenDuration)
        #expect(!BlockKind.startAt.isOpenDuration)
    }
}
