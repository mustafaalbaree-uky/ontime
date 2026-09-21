import Foundation
import SwiftUI
import Testing
@testable import OnTime

/// The widget's display logic, testable at last: which step is on show, the
/// ring's span guard and the shared ramp fraction all live in
/// `Shared/OnTimeActivityLogic.swift`, compiled into the app target too. The
/// `isFinished` bug (a finished run showing a live countdown and button
/// through its dismissal window) is exactly the kind this truth table would
/// have caught.
struct ActivityLogicTests {
    private let now = Date(timeIntervalSince1970: 1_755_000_000)

    private func step(_ index: Int, until: TimeInterval, target: TimeInterval? = nil) -> OnTimeShownStep {
        OnTimeShownStep(name: "Step \(index + 1)", symbol: "circle", index: index,
                        target: now.addingTimeInterval(target ?? until), targetLabel: "Finish by",
                        until: now.addingTimeInterval(until))
    }

    private func state(target: TimeInterval,
                       segmentStart: TimeInterval = -600,
                       isFinished: Bool = false,
                       isWaiting: Bool = false,
                       later: [OnTimeShownStep] = []) -> OnTimeActivityAttributes.ContentState {
        OnTimeActivityAttributes.ContentState(
            planName: "Plan",
            blockName: "Step 1",
            blockIndex: 0,
            totalBlocks: 3,
            targetLeaveBy: now.addingTimeInterval(target),
            segmentStart: now.addingTimeInterval(segmentStart),
            isFinished: isFinished,
            isWaiting: isWaiting,
            later: later
        )
    }

    // MARK: Which step is on show

    @Test func aStepWhoseTimeIsStillAheadStaysOnShow() {
        #expect(OnTimeShown.resolve(until: now.addingTimeInterval(300), later: [step(1, until: 900)], now: now) == .head)
    }

    /// The whole point: a step whose time has passed is never shown as over.
    /// The one after it is on show, counting from the moment the first was
    /// left.
    @Test func aStepWhoseTimeHasPassedGivesWayToTheNext() {
        let next = step(1, until: 600)
        let last = step(2, until: 900)
        let shown = OnTimeShown.resolve(until: now.addingTimeInterval(-60), later: [next, last], now: now)
        #expect(shown == .later(next, from: now.addingTimeInterval(-60), rest: [last]))
    }

    /// The app may be gone for several boundaries. The surface lands on the
    /// step the clock has reached, not on the one after the last it was told
    /// about.
    @Test func severalPassedStepsAreSkippedInOneGo() {
        let second = step(1, until: -30)
        let third = step(2, until: 600)
        let shown = OnTimeShown.resolve(until: now.addingTimeInterval(-300), later: [second, third], now: now)
        #expect(shown == .later(third, from: second.until, rest: []))
    }

    @Test func aRunWithNoStepLeftIsOver() {
        #expect(OnTimeShown.resolve(until: now.addingTimeInterval(-60), later: [], now: now) == .over)
        #expect(OnTimeShown.resolve(until: now.addingTimeInterval(-60), later: [step(1, until: -1)], now: now) == .over)
    }

    /// ActivityKit re-renders at the stale date, which is the head's own
    /// `until`. A clock reading a hair before it must not leave the head on
    /// show, because nothing is due to redraw the plate after that.
    @Test func staleAloneCountsAsTheHeadHavingPassed() {
        let next = step(1, until: 600)
        let until = now.addingTimeInterval(0.4)
        #expect(OnTimeShown.resolve(until: until, later: [next], isStale: true, now: now)
                == .later(next, from: until, rest: []))
        #expect(OnTimeShown.resolve(until: until, later: [], isStale: true, now: now) == .over)
    }

    /// A run ahead of its schedule leaves a step on its estimate, before the
    /// countdown reaches its target.
    @Test func aStepIsLeftAtItsUntilNotItsTarget() {
        let next = step(1, until: 600)
        let shown = OnTimeShown.resolve(until: now.addingTimeInterval(-5), later: [next], now: now)
        #expect(shown == .later(next, from: now.addingTimeInterval(-5), rest: []))
    }

    // MARK: The plate

    @Test func thePlateTakesOnTheStepTheClockHasReached() {
        let next = step(1, until: 600, target: 660)
        let shown = state(target: -60, isWaiting: true, later: [next, step(2, until: 900)]).shown(isStale: false, now: now)
        #expect(shown.blockName == "Step 2")
        #expect(shown.blockIndex == 1)
        #expect(shown.targetLeaveBy == next.target)
        #expect(shown.until == next.until)
        #expect(shown.segmentStart == now.addingTimeInterval(-60))
        #expect(!shown.isWaiting)
        #expect(!shown.isFinished)
        #expect(shown.later == [step(2, until: 900)])
    }

    @Test func thePlateIsFinishedOnlyWhenNoStepIsLeft() {
        #expect(!state(target: 300).shown(isStale: false, now: now).isFinished)
        #expect(state(target: -60).shown(isStale: false, now: now).isFinished)
        #expect(state(target: 300).shown(isStale: true, now: now).isFinished)
    }

    @Test func isFinishedWinsOverEverything() {
        // A finished run with a still-future target (finished early) must
        // show the Done frame, not a live countdown with a live button.
        let shown = state(target: 300, isFinished: true, later: [step(1, until: 600)]).shown(isStale: false, now: now)
        #expect(shown.isFinished)
        #expect(shown.blockIndex == 0)
    }

    /// A start push built before `later` existed is a wait with nothing
    /// after it. It holds at 0:00 rather than call a routine that has not
    /// begun done.
    @Test func aWaitWithNothingAfterItIsNeverFinished() {
        #expect(!state(target: -60, isWaiting: true).shown(isStale: true, now: now).isFinished)
    }

    @Test func aPayloadFromBeforeLaterExistedStillDecodes() throws {
        let old = """
        {"planName":"Fajr","blockName":"Wake up","blockIndex":0,"totalBlocks":4,"targetLeaveBy":780000000,
         "segmentStart":779999000,"isFlex":false,"isFinished":false,"symbol":"alarm","isWaiting":true,
         "targetLabel":"Start by ","isOverrun":false,"startsRunAtTarget":true,"endsRunAtTarget":false}
        """
        let decoded = try JSONDecoder().decode(OnTimeActivityAttributes.ContentState.self, from: Data(old.utf8))
        #expect(decoded.until == decoded.targetLeaveBy)
        #expect(decoded.later.isEmpty)
    }

    @Test func thePlateCarriesOnlyItsNextFewSteps() {
        let many = (1...20).map { step($0, until: TimeInterval($0) * 60) }
        #expect(state(target: 30, later: many).later.count == OnTimeActivityAttributes.ContentState.laterLimit)
    }

    // MARK: Ring interval guard

    @Test func degenerateSpansProduceNoRingInterval() {
        #expect(OnTimeActivityLogic.ringInterval(segmentStart: now, targetLeaveBy: now) == nil)
        #expect(OnTimeActivityLogic.ringInterval(segmentStart: now.addingTimeInterval(10), targetLeaveBy: now) == nil)
        #expect(OnTimeActivityLogic.ringInterval(segmentStart: now, targetLeaveBy: now.addingTimeInterval(10)) != nil)
    }

    // MARK: Span fraction (the ramp's shared input)

    @Test func spanFractionClampsAndHandlesZeroSpans() {
        let start = now.addingTimeInterval(-100)
        let target = now.addingTimeInterval(100)
        #expect(OnTimeActivityLogic.spanFraction(now: now, segmentStart: start, target: target) == 0.5)
        #expect(OnTimeActivityLogic.spanFraction(now: start.addingTimeInterval(-50), segmentStart: start, target: target) == 0)
        #expect(OnTimeActivityLogic.spanFraction(now: target.addingTimeInterval(50), segmentStart: start, target: target) == 1)
        #expect(OnTimeActivityLogic.spanFraction(now: now, segmentStart: target, target: start) == 1)
    }

    // MARK: Countdown formatting

    @Test func countdownStringDropsTheHourFieldUnderAnHour() {
        #expect(TimeFormatting.countdownString(0) == "0:00")
        #expect(TimeFormatting.countdownString(59) == "0:59")
        #expect(TimeFormatting.countdownString(605) == "10:05")
        #expect(TimeFormatting.countdownString(3665) == "1:01:05")
    }

    /// Never negative. A caller past its target says so with a sign and a
    /// colour of its own; a minus buried in the digits is unreadable at a
    /// glance, which is the thing being fixed.
    @Test func countdownStringClampsAtZero() {
        #expect(TimeFormatting.countdownString(-90) == "0:00")
    }

    @Test func spanWordsReadsAsSpeech() {
        #expect(TimeFormatting.spanWords(0) == "0 min")
        #expect(TimeFormatting.spanWords(45 * 60) == "45 min")
        #expect(TimeFormatting.spanWords(60 * 60) == "1 hr")
        #expect(TimeFormatting.spanWords(65 * 60) == "1 hr 5 min")
    }
}
