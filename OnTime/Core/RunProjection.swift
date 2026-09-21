import Foundation

/// When the Live Activity and the Home Screen widget leave each step of a
/// run, with nobody touching the phone. The arithmetic half of
/// `RunEngine.shownTimeline`, kept pure so the tests can reach it: an engine
/// cannot be built in a test without raising a Live Activity.
enum RunProjection {
    struct Step: Equatable {
        /// The step's estimate. Ignored when `autoAdvances` is false.
        let seconds: TimeInterval
        /// Whether the step moves on by itself when its estimate runs out.
        /// False for a step that waits for a tap, for an open duration
        /// step, and for every step when auto advance is off.
        let autoAdvances: Bool
        /// What the step's countdown is aimed at.
        let target: Date
    }

    /// One date per step: the moment the surfaces move past it. `steps` are
    /// the ones still to come, the first being the step the run is on, which
    /// began at `start`.
    ///
    /// While every step so far moves on by itself this is `reconcile()` run
    /// forward in imagination: from the current step's start, each step ends
    /// on its estimate and the next begins at that instant. A run ahead of
    /// its schedule therefore leaves a step before its target, exactly when
    /// the engine does.
    ///
    /// It is never later than the step's target. A run that is behind, a
    /// step that waits for a tap and an open duration step all reach their
    /// target with the engine still on them, and the surfaces move on anyway
    /// rather than say the step is over. Past the first step that does not
    /// move on by itself the engine's own walk is unknowable, so every later
    /// step is left at its target.
    static func untils(steps: [Step], from start: Date) -> [Date] {
        var cursor: Date? = start
        return steps.map { step in
            guard let began = cursor, step.autoAdvances else {
                cursor = nil
                return step.target
            }
            let boundary = began.addingTimeInterval(max(0, step.seconds))
            cursor = boundary
            return min(boundary, step.target)
        }
    }
}
