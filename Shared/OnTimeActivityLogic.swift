import Foundation

/// One step of a run as the Lock Screen, the Island and the Home Screen
/// widget show it: what it is called, what its countdown is aimed at, and the
/// moment the surface leaves it for the next one.
///
/// Every date is an absolute wall-clock time the app already computed, the
/// same principle the arm timeline and the widget snapshot run on. A surface
/// holding a list of these needs nothing but a clock to stay right.
public struct OnTimeShownStep: Codable, Hashable, Sendable {
    public var name: String
    public var symbol: String
    public var index: Int
    /// What the countdown is aimed at.
    public var target: Date
    public var targetLabel: String
    /// When the surface moves on. The target, or sooner when the run is ahead
    /// of its schedule and the step ends on its estimate before that.
    public var until: Date

    public init(name: String, symbol: String, index: Int, target: Date, targetLabel: String, until: Date) {
        self.name = name
        self.symbol = symbol
        self.index = index
        self.target = target
        self.targetLabel = targetLabel
        self.until = until
    }
}

/// Which step a surface is showing right now, which is not always the one
/// the app last handed it. The app is suspended for most of a run and cannot
/// update anything, so the surface works it out from the clock.
///
/// A surface never says a step is over. It used to: a step whose time had
/// passed turned red and counted up behind a plus sign until the app was
/// opened, and the Home Screen widget, which only ever knew the current
/// step, sat red from the first boundary to the end of the routine. Now the
/// step after it is on show from that moment, and a run with no step left is
/// gone from the surface.
///
/// Lives in `Shared/` rather than inside the widget so the app's test target
/// can pin the truth table down; the widget target has no tests of its own,
/// and this logic is exactly where its past bugs have lived.
public enum OnTimeShown: Equatable {
    /// The step the app handed over is still the one on show.
    case head
    /// A later step is, on show since `from`. `rest` are the ones after it.
    case later(OnTimeShownStep, from: Date, rest: [OnTimeShownStep])
    /// Every step's time has gone by.
    case over

    /// `isStale` is `context.isStale`, which ActivityKit sets by re-rendering
    /// at the stale date the app asked for: the head's own `until` (see
    /// `LiveActivityManager.staleDate`). It counts as the head having passed
    /// whatever the clock reads, so a re-render that lands a hair early does
    /// not leave the head on show at 0:00 with nothing due to redraw it.
    public static func resolve(until: Date, later: [OnTimeShownStep],
                               isStale: Bool = false, now: Date) -> OnTimeShown {
        var passed = ([until] + later.map(\.until)).prefix { $0 <= now }.count
        if isStale { passed = max(passed, 1) }
        guard passed > 0 else { return .head }
        guard later.indices.contains(passed - 1) else { return .over }
        return .later(later[passed - 1],
                      from: passed == 1 ? until : later[passed - 2].until,
                      rest: Array(later.dropFirst(passed)))
    }
}

public enum OnTimeActivityLogic {
    /// The step's span, or nil when it would be degenerate:
    /// `ProgressView(timerInterval:)` traps on a non-ascending range.
    public static func ringInterval(segmentStart: Date, targetLeaveBy: Date) -> ClosedRange<Date>? {
        guard segmentStart < targetLeaveBy else { return nil }
        return segmentStart...targetLeaveBy
    }

    /// 0 at the start of the span, 1 at the target. `RunEngine.rampBucket`
    /// throttles its pushes on it. A span of zero or less counts as fully
    /// elapsed.
    public static func spanFraction(now: Date, segmentStart: Date, target: Date) -> Double {
        let span = target.timeIntervalSince(segmentStart)
        guard span > 0 else { return 1 }
        return min(max(now.timeIntervalSince(segmentStart) / span, 0), 1)
    }
}
