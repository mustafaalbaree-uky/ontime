import Foundation

/// When a run will move from one step to the next with nobody touching the
/// phone. The arithmetic half of `RunEngine.projectedActivitySteps`, kept
/// pure so the tests can reach it: an engine cannot be built in a test
/// without raising a Live Activity.
enum RunProjection {
    struct Step: Equatable {
        /// The step's estimate. Ignored when `autoAdvances` is false.
        let seconds: TimeInterval
        /// Whether the step moves on by itself when its estimate runs out.
        /// False for a step that waits for a tap, for an open duration
        /// step, and for every step when auto advance is off.
        let autoAdvances: Bool
    }

    struct Boundary: Equatable {
        /// The step being entered. Equal to the step count when the last
        /// step ran out and the run is over.
        let entering: Int
        let at: Date
    }

    /// `reconcile()` run forward in imagination: from the current step's
    /// start, each auto advancing step ends on its estimate and the next
    /// begins at that instant. Stops at the first step that does not move on
    /// by itself, because past it the next change is a tap and no clock can
    /// say when. Boundaries at or before `now` are left out: they are the
    /// engine's to collapse on its next tick, not future changes.
    static func boundaries(steps: [Step], currentIndex: Int, currentStart: Date, now: Date) -> [Boundary] {
        var found: [Boundary] = []
        var index = currentIndex
        var cursor = currentStart
        while steps.indices.contains(index), steps[index].autoAdvances {
            cursor = cursor.addingTimeInterval(max(0, steps[index].seconds))
            index += 1
            if cursor > now {
                found.append(Boundary(entering: index, at: cursor))
            }
        }
        return found
    }
}
