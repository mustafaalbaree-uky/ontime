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
        /// When the plate leaves this step for the next one. The target, or
        /// sooner when the run is ahead of its schedule. It is also the stale
        /// date, so ActivityKit re-renders the plate at exactly this moment.
        public var until: Date
        /// The steps after this one, in order. The app is usually suspended
        /// when a step's time runs out and cannot update anything, so the
        /// plate carries what comes next and `shown(isStale:now:)` moves on
        /// by the clock. It used to turn red and count up behind a plus sign
        /// instead.
        public var later: [OnTimeShownStep]

        /// ActivityKit refuses a content state over 4 KB, and so does APNs.
        /// A step is about 170 bytes, and every push and every update brings
        /// a fresh list, so a long routine loses nothing by carrying only
        /// its next few.
        public static let laterLimit = 8

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
            until: Date? = nil,
            later: [OnTimeShownStep] = []
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
            self.until = until ?? targetLeaveBy
            self.later = Array(later.prefix(Self.laterLimit))
        }

        /// A payload built before `until` and `later` existed still decodes.
        /// The Pi holds a week of start pushes, and a build installed and
        /// not yet opened would otherwise fail to decode every one of them,
        /// which ActivityKit answers by doing nothing at all.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            planName = try values.decode(String.self, forKey: .planName)
            blockName = try values.decode(String.self, forKey: .blockName)
            blockIndex = try values.decode(Int.self, forKey: .blockIndex)
            totalBlocks = try values.decode(Int.self, forKey: .totalBlocks)
            targetLeaveBy = try values.decode(Date.self, forKey: .targetLeaveBy)
            segmentStart = try values.decode(Date.self, forKey: .segmentStart)
            isFlex = try values.decode(Bool.self, forKey: .isFlex)
            isFinished = try values.decode(Bool.self, forKey: .isFinished)
            symbol = try values.decode(String.self, forKey: .symbol)
            isWaiting = try values.decode(Bool.self, forKey: .isWaiting)
            targetLabel = try values.decode(String.self, forKey: .targetLabel)
            until = try values.decodeIfPresent(Date.self, forKey: .until) ?? targetLeaveBy
            later = try values.decodeIfPresent([OnTimeShownStep].self, forKey: .later) ?? []
        }

        /// What to draw at `now`: this state while its step is still on
        /// show, the step the clock has reached once it is not, and a
        /// finished plate when there is none left. See `OnTimeShown`.
        public func shown(isStale: Bool, now: Date = Date()) -> ContentState {
            guard !isFinished else { return self }
            var state = self
            switch OnTimeShown.resolve(until: until, later: later, isStale: isStale, now: now) {
            case .head:
                break
            case .later(let step, let from, let rest):
                state.blockName = step.name
                state.blockIndex = step.index
                state.symbol = step.symbol
                state.targetLeaveBy = step.target
                state.targetLabel = step.targetLabel + " "
                state.until = step.until
                state.segmentStart = from
                state.isWaiting = false
                state.later = rest
            case .over:
                // The wait before step 1 is never the end of a run. Only a
                // payload from before `later` existed can get here, and it
                // holds at 0:00 rather than claim a routine that has not
                // begun is done.
                state.isFinished = !isWaiting
            }
            return state
        }
    }

    public var planId: String

    public init(planId: String) {
        self.planId = planId
    }
}
