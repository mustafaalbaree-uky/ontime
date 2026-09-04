import Foundation

/// What the activity is actually showing right now, which is not always
/// what the app last pushed. The app is suspended for most of a run, so a
/// step whose target has passed cannot be updated by anyone; the widget
/// works it out from the clock and from `context.isStale`, which
/// ActivityKit sets by re-rendering at the stale date the app asked for
/// (the step's target time; see `LiveActivityManager.staleDate`).
///
/// Lives in `Shared/` rather than inside the widget so the app's test
/// target can pin the truth table down; the widget target has no tests of
/// its own, and this logic is exactly where its past bugs have lived.
public enum OnTimeActivityPhase: Equatable {
    /// Still counting down to the step's target.
    case running
    /// The run is over: either the app said so (`isFinished`), or the last
    /// step's target passed on a step that ends the run by itself.
    case finished
    /// The target passed on a step that waits for a tap. Time is counting
    /// up, and that is correct, but it needs to be labeled as over rather
    /// than left as a bare climbing number.
    case over

    public static func resolve(_ state: OnTimeActivityAttributes.ContentState,
                               isStale: Bool,
                               now: Date = Date()) -> OnTimeActivityPhase {
        if state.isFinished { return .finished }
        let past = isStale || state.isOverrun || state.targetLeaveBy <= now
        guard past else { return .running }
        return state.endsRunAtTarget ? .finished : .over
    }
}

public enum OnTimeActivityLogic {
    /// The step's span, or nil when it would be degenerate:
    /// `ProgressView(timerInterval:)` traps on a non-ascending range.
    public static func ringInterval(segmentStart: Date, targetLeaveBy: Date) -> ClosedRange<Date>? {
        guard segmentStart < targetLeaveBy else { return nil }
        return segmentStart...targetLeaveBy
    }

    /// 0 at the start of the span, 1 at the target. This is the green to
    /// red ramp's input, and it is the one formula both sides of the
    /// process seam must agree on: `RunEngine.rampBucket` gates pushes on
    /// it and the widget's ring tints from it. A span of zero or less
    /// counts as fully elapsed.
    public static func spanFraction(now: Date, segmentStart: Date, target: Date) -> Double {
        let span = target.timeIntervalSince(segmentStart)
        guard span > 0 else { return 1 }
        return min(max(now.timeIntervalSince(segmentStart) / span, 0), 1)
    }

    /// The range a counting-*up* timer needs for the `.over` phase: it starts
    /// at the moment the target passed, so the number shown is honestly "how
    /// far past", rendered beside an explicit plus sign.
    ///
    /// This exists because the old activity used a bare
    /// `Text(_:style: .timer)` for every phase, and that view free-runs: it
    /// counts down to the target and then, with no sign, no colour change
    /// and no relabelling of its own, starts counting up. A number rising
    /// through 00:41 looks exactly like a number falling through 00:41. That
    /// single view is the whole "why did it start going the other way"
    /// confusion, and the fix is in two parts: the running phase counts down
    /// inside a `ClosedRange`, which clamps at 0:00 by itself, and the over
    /// phase uses this range with a plus in front of it.
    public static func lateInterval(target: Date) -> ClosedRange<Date> {
        target...target.addingTimeInterval(60 * 60 * 24)
    }

    /// Subtitle for the `.over` state. `latenessMinutes` is only sent while
    /// the app knows the overrun's cost; nil during the wait phase means
    /// the wait target passed, and `startsRunAtTarget` distinguishes a run
    /// that will begin step 1 on its own from one genuinely waiting on a
    /// tap.
    public static func overCaption(latenessMinutes: Int?, isWaiting: Bool, startsRunAtTarget: Bool) -> String {
        if let minutes = latenessMinutes {
            return minutes > 0 ? "over, about \(minutes)m late" : "over, still on time"
        }
        if isWaiting && startsRunAtTarget { return "step 1 underway" }
        return "over, waiting on you"
    }
}
