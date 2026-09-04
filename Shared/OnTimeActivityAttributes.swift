import ActivityKit
import Foundation

public struct OnTimeActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var planName: String
        public var blockName: String
        public var blockIndex: Int
        public var totalBlocks: Int
        public var targetLeaveBy: Date
        /// When the currently displayed span began — the active block's
        /// `actualStart` (or the moment the wait phase began). Only
        /// `targetLeaveBy` used to cross into the widget, which is enough
        /// to count down but not enough to draw a ring: a depleting arc
        /// needs both ends of the span to know what fraction is left.
        public var segmentStart: Date
        public var isFlex: Bool
        public var isFinished: Bool
        public var symbol: String
        /// True while `RunView.isWaitingToStart` is — Step 1 hasn't begun
        /// yet, so `targetLeaveBy` here means "start by," not "finish by."
        public var isWaiting: Bool
        /// Prebuilt by `RunView` (e.g. "Arrive by ", "Finish by ", "Start by ")
        /// so the widget never has to know block-kind semantics itself —
        /// it used to hardcode "Arrive by " unconditionally, which was wrong
        /// for any non-drive block ("Arrive by 7:15" on a "Get Ready" step).
        public var targetLabel: String
        /// True once `targetLeaveBy` has passed for a currently-active,
        /// non-flex block that isn't eligible to auto-advance (either
        /// auto-advance is off, or this block is pinned open-ended-false) —
        /// i.e. the run is genuinely just waiting on a manual "Complete
        /// Step" tap, not broken. Lets the widget stop implying urgency
        /// (no more bare countdown ticking past zero with no explanation)
        /// and instead say plainly that it's waiting on you.
        public var isOverrun: Bool
        /// How many minutes past `plan.deadline` the run is currently
        /// projected to finish, recomputed live from the solver — only
        /// shown once `isOverrun`, answering "how is this pushing my final
        /// deadline" instead of just showing a step counting up with no
        /// context. <= 0 means still on track; nil means the app has no
        /// current number (no solution, or the wait phase), and the widget
        /// renders it via `OnTimeActivityLogic.overCaption` rather than
        /// claiming anything about lateness.
        public var latenessMinutes: Int?
        /// True while waiting when the run will begin step 1 on its own the
        /// moment the start time arrives (backdated on the next app wake).
        /// Lets the widget say "step 1 underway" for a passed wait target
        /// instead of the false "waiting on you".
        public var startsRunAtTarget: Bool
        /// True when this is the last step and it ends the run by itself
        /// at `targetLeaveBy`. The app is usually suspended by then and
        /// cannot end anything, so the widget uses this together with
        /// `context.isStale` to show a finished run at the deadline
        /// instead of a countdown that ticks upward until someone opens
        /// the app.
        public var endsRunAtTarget: Bool

        public init(
            planName: String,
            blockName: String,
            blockIndex: Int,
            totalBlocks: Int,
            targetLeaveBy: Date,
            segmentStart: Date,
            isFlex: Bool = false,
            isFinished: Bool = false,
            symbol: String = "circle.fill",
            isWaiting: Bool = false,
            targetLabel: String = "Finish by ",
            isOverrun: Bool = false,
            latenessMinutes: Int? = nil,
            startsRunAtTarget: Bool = false,
            endsRunAtTarget: Bool = false
        ) {
            self.planName = planName
            self.blockName = blockName
            self.blockIndex = blockIndex
            self.totalBlocks = totalBlocks
            self.targetLeaveBy = targetLeaveBy
            self.segmentStart = segmentStart
            self.isFlex = isFlex
            self.isFinished = isFinished
            self.symbol = symbol
            self.isWaiting = isWaiting
            self.targetLabel = targetLabel
            self.isOverrun = isOverrun
            self.latenessMinutes = latenessMinutes
            self.startsRunAtTarget = startsRunAtTarget
            self.endsRunAtTarget = endsRunAtTarget
        }
    }

    public var planId: String

    public init(planId: String) {
        self.planId = planId
    }
}
