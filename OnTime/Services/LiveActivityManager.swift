import ActivityKit
import Foundation

/// What happened when starting a Live Activity — `start()` used to be
/// fire-and-forget, so a disabled-Activities setting or a thrown request
/// error both looked identical to the user: nothing happened, with no
/// feedback anywhere. Callers now see which of the three occurred and can
/// surface it instead of silently no-op'ing.
enum LiveActivityStartOutcome: Equatable {
    case started
    case activitiesDisabled
    case failed(String)

    static func == (lhs: LiveActivityStartOutcome, rhs: LiveActivityStartOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.started, .started), (.activitiesDisabled, .activitiesDisabled): return true
        case let (.failed(a), .failed(b)): return a == b
        default: return false
        }
    }
}

/// Keyed by `planId` rather than a single static handle — this used to
/// track exactly one activity system-wide and unconditionally end it
/// before starting any new one, which meant a second concurrent `Run`
/// always killed the first. One plan's activity is still replaced when
/// re-requested (a stale one from an earlier run of the same plan), but
/// starting a different plan's run now leaves every other plan's activity
/// alone.
@MainActor
enum LiveActivityManager {
    private static var activities: [String: Activity<OnTimeActivityAttributes>] = [:]

    /// Plans whose `Activity.request` is in flight right now. `request` is
    /// `async` and `RunEngine.syncLiveActivityAndNotifications` fires its
    /// work off in an unstructured `Task` from a 1s tick, so without this
    /// two ticks could both observe "no activity yet" before the first
    /// request came back and each request one — which is exactly how a
    /// second copy of the same countdown appeared on the Lock Screen at
    /// random. Mutated only from the `@MainActor`, and every check-and-claim
    /// below runs with no `await` in between, so the claim is atomic.
    private static var starting: Set<String> = []

    private static func current(for planId: String) -> Activity<OnTimeActivityAttributes>? {
        if let a = activities[planId], a.activityState == .active { return a }
        let found = Activity<OnTimeActivityAttributes>.activities.first {
            $0.attributes.planId == planId && $0.activityState == .active
        }
        activities[planId] = found
        return found
    }

    /// Whether a plan already has a live activity — callers should prefer
    /// `update(planId:...)` over `start(...)` when this is true.
    /// `start` unconditionally ends-and-re-requests, which is the right
    /// move the *first* time a run's activity is created but visibly
    /// flickers the Lock Screen (and burns into ActivityKit's request rate
    /// limit) if called on every sync — which, once a `RunEngine` ticks
    /// independent of any view, is far more often than "once per step."
    /// Counts an in-flight request as "has one" so a caller polling this to
    /// choose between `start` and `update` doesn't launch a second request
    /// while the first is still awaiting. The `update` it takes instead is a
    /// harmless no-op until the activity exists; the in-flight `start`
    /// carries the current state anyway.
    static func hasActivity(planId: String) -> Bool {
        starting.contains(planId) || current(for: planId) != nil
    }

    @discardableResult
    static func start(
        planId: String,
        planName: String,
        blockName: String,
        blockIndex: Int,
        totalBlocks: Int,
        targetLeaveBy: Date,
        segmentStart: Date,
        isFlex: Bool = false,
        symbol: String = "circle.fill",
        isWaiting: Bool = false,
        targetLabel: String = "Finish by ",
        isOverrun: Bool = false,
        latenessMinutes: Int? = nil,
        endsRunAtTarget: Bool = false
    ) async -> LiveActivityStartOutcome {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return .activitiesDisabled }
        // Claim this plan before the first `await` below. A concurrent
        // caller that lost the race reports `.started` rather than
        // requesting its own activity — the winner is about to publish one
        // with the same state.
        guard !starting.contains(planId) else { return .started }
        starting.insert(planId)
        defer { starting.remove(planId) }

        // Only this plan's previous activity, if any — not every other
        // concurrently running plan's.
        if let existing = current(for: planId) {
            await existing.end(nil, dismissalPolicy: .immediate)
            activities[planId] = nil
        }

        let attributes = OnTimeActivityAttributes(planId: planId)
        let state = OnTimeActivityAttributes.ContentState(
            planName: planName,
            blockName: blockName,
            blockIndex: blockIndex,
            totalBlocks: totalBlocks,
            targetLeaveBy: targetLeaveBy,
            segmentStart: segmentStart,
            isFlex: isFlex,
            isFinished: false,
            symbol: symbol,
            isWaiting: isWaiting,
            targetLabel: targetLabel,
            isOverrun: isOverrun,
            latenessMinutes: latenessMinutes,
            endsRunAtTarget: endsRunAtTarget
        )

        do {
            activities[planId] = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: staleDate(for: targetLeaveBy))
            )
            return .started
        } catch {
            // A system-wide cap on concurrent Live Activities is a real
            // possibility now that more than one can be requested — this
            // still surfaces as `.failed` rather than a silent no-op.
            print("Failed to start Live Activity: \(error)")
            return .failed(error.localizedDescription)
        }
    }

    static func update(
        planId: String,
        planName: String,
        blockName: String,
        blockIndex: Int,
        totalBlocks: Int,
        targetLeaveBy: Date,
        segmentStart: Date,
        isFlex: Bool = false,
        symbol: String = "circle.fill",
        isWaiting: Bool = false,
        targetLabel: String = "Finish by ",
        isOverrun: Bool = false,
        latenessMinutes: Int? = nil,
        endsRunAtTarget: Bool = false
    ) async {
        guard let activity = current(for: planId) else { return }
        let state = OnTimeActivityAttributes.ContentState(
            planName: planName,
            blockName: blockName,
            blockIndex: blockIndex,
            totalBlocks: totalBlocks,
            targetLeaveBy: targetLeaveBy,
            segmentStart: segmentStart,
            isFlex: isFlex,
            isFinished: false,
            symbol: symbol,
            isWaiting: isWaiting,
            targetLabel: targetLabel,
            isOverrun: isOverrun,
            latenessMinutes: latenessMinutes,
            endsRunAtTarget: endsRunAtTarget
        )
        await activity.update(.init(state: state, staleDate: staleDate(for: targetLeaveBy)))
    }

    /// The step's own target, so ActivityKit re-renders the activity at
    /// exactly that moment and the widget can say what is true from then
    /// on. This used to sit an hour past the target, which is why a run
    /// whose deadline came and went while the phone was in a pocket kept
    /// showing a bare number climbing: nothing was scheduled to tell the
    /// widget anything had changed, and the app was suspended and could
    /// not.
    private static func staleDate(for target: Date) -> Date {
        max(target, Date().addingTimeInterval(1))
    }

    /// Normal end-of-run: reached the last step successfully.
    static func finish(planId: String) async {
        guard let activity = current(for: planId) else { return }
        var state = activity.content.state
        state.isFinished = true
        await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 10))
        activities[planId] = nil
    }

    /// Explicit cancel of one run's activity — immediate dismissal, no
    /// "finished" state shown, since the run wasn't actually completed.
    static func end(planId: String) async {
        guard let activity = current(for: planId) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        activities[planId] = nil
    }

    static func endAll() async {
        activities.removeAll()
        starting.removeAll()
        for activity in Activity<OnTimeActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Ends every activity that isn't one of `planIds` — used at launch to
    /// clear activities left behind by runs that no longer have an open
    /// `Run` row (app force-quit mid-run), without touching activities for
    /// runs that legitimately resumed. See `RootView.resumeOpenRuns`.
    static func endOrphans(keeping planIds: Set<String>) async {
        for activity in Activity<OnTimeActivityAttributes>.activities where !planIds.contains(activity.attributes.planId) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activities = activities.filter { planIds.contains($0.key) }
    }
}
