import Foundation
import SwiftUI
import Testing
@testable import OnTime

/// The widget's display logic, testable at last: phase resolution, the
/// ring's span guard, the shared ramp fraction, and the over-state caption
/// all live in `Shared/OnTimeActivityLogic.swift`, compiled into the app
/// target too. The `isFinished` bug (a finished run showing a live
/// countdown and button through its dismissal window) is exactly the kind
/// this truth table would have caught.
struct ActivityLogicTests {
    private let now = Date(timeIntervalSince1970: 1_755_000_000)

    private func state(target: TimeInterval,
                       segmentStart: TimeInterval = -600,
                       isFinished: Bool = false,
                       isWaiting: Bool = false,
                       isOverrun: Bool = false,
                       endsRunAtTarget: Bool = false,
                       startsRunAtTarget: Bool = false,
                       latenessMinutes: Int? = nil) -> OnTimeActivityAttributes.ContentState {
        OnTimeActivityAttributes.ContentState(
            planName: "Plan",
            blockName: "Step",
            blockIndex: 0,
            totalBlocks: 2,
            targetLeaveBy: now.addingTimeInterval(target),
            segmentStart: now.addingTimeInterval(segmentStart),
            isFinished: isFinished,
            isWaiting: isWaiting,
            isOverrun: isOverrun,
            latenessMinutes: latenessMinutes,
            startsRunAtTarget: startsRunAtTarget,
            endsRunAtTarget: endsRunAtTarget
        )
    }

    // MARK: Phase truth table

    @Test func futureTargetIsRunning() {
        #expect(OnTimeActivityPhase.resolve(state(target: 300), isStale: false, now: now) == .running)
    }

    @Test func isFinishedWinsOverEverything() {
        // A finished run with a still-future target (finished early) must
        // show the Done frame, not a live countdown with a live button.
        #expect(OnTimeActivityPhase.resolve(state(target: 300, isFinished: true), isStale: false, now: now) == .finished)
    }

    @Test func pastTargetOnASelfEndingStepIsFinished() {
        #expect(OnTimeActivityPhase.resolve(state(target: -60, endsRunAtTarget: true), isStale: false, now: now) == .finished)
    }

    @Test func pastTargetOnATapWaitingStepIsOver() {
        #expect(OnTimeActivityPhase.resolve(state(target: -60), isStale: false, now: now) == .over)
    }

    @Test func staleFlagAloneCountsAsPast() {
        #expect(OnTimeActivityPhase.resolve(state(target: 300), isStale: true, now: now) == .over)
        #expect(OnTimeActivityPhase.resolve(state(target: 300, endsRunAtTarget: true), isStale: true, now: now) == .finished)
    }

    @Test func overrunFlagAloneCountsAsPast() {
        #expect(OnTimeActivityPhase.resolve(state(target: 300, isOverrun: true), isStale: false, now: now) == .over)
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

    // MARK: Over caption

    @Test func overCaptionDistinguishesLatenessAndWaiting() {
        #expect(OnTimeActivityLogic.overCaption(latenessMinutes: 5, isWaiting: false, startsRunAtTarget: false)
                == "over, about 5m late")
        #expect(OnTimeActivityLogic.overCaption(latenessMinutes: 0, isWaiting: false, startsRunAtTarget: false)
                == "over, still on time")
        #expect(OnTimeActivityLogic.overCaption(latenessMinutes: nil, isWaiting: false, startsRunAtTarget: false)
                == "over, waiting on you")
        // A passed wait target on a run that begins step 1 on its own must
        // not claim to be waiting on the user.
        #expect(OnTimeActivityLogic.overCaption(latenessMinutes: nil, isWaiting: true, startsRunAtTarget: true)
                == "step 1 underway")
    }

    // MARK: The late range

    /// The over-phase timer counts *up* from the target, so its range has to
    /// start exactly there: the number rendered is then how far past, and it
    /// is drawn behind an explicit plus sign in red.
    ///
    /// The countdown itself used to be a bare `Text(_:style: .timer)` in
    /// every phase, which free-runs — it reaches zero and starts climbing
    /// with no sign and no change of any kind. That single view is the whole
    /// "why did it turn around and start going up" confusion.
    @Test func lateIntervalStartsAtTheTargetAndAscends() {
        let target = now.addingTimeInterval(300)
        let range = OnTimeActivityLogic.lateInterval(target: target)
        #expect(range.lowerBound == target)
        #expect(range.upperBound > range.lowerBound)
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
