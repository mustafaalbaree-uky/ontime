import Foundation
import SwiftData

/// The one place a `Run` gets created and handed to `RunEngineStore`.
/// Several screens used to construct a `Run` inline instead; two of those
/// hand-rolled copies also dropped block fields on the way (see
/// `Block.copyForSpawn`). Now that more than one run can be live at once
/// (the Active tab), every one of them has to register with the store or it
/// simply won't show up there — routing them all through here is what
/// guarantees that.
///
/// Current callers: `NowView.startRun` (the Start button) and
/// `ScheduleService.arm` (a scheduled routine waking itself up).
@MainActor
enum RunLauncher {
    /// `blocks` must already be inserted into `context` (or about to be —
    /// SwiftData doesn't care about insert order as long as it happens
    /// before save). Their `order` is renumbered via `Plan.renumber()`
    /// after being claimed, so callers don't need to pre-sort them. Always
    /// builds a brand-new `Plan`, so there's nothing to conflict with.
    ///
    /// `startedAt` and `routine` exist for `ScheduleService.arm`: the run
    /// must be *born* backdated to the arm moment with its provenance set,
    /// because the engine (created here, synchronously) computes its first
    /// solution and pushes its first Live Activity during this call — a
    /// backdate applied afterwards left that first push with the wrong
    /// span, exactly the state backdating exists to protect.
    @discardableResult
    static func start(deadline: Date, name: String, blocks: [Block], in context: ModelContext,
                      startedAt: Date = Date(), routine: ScheduledRoutine? = nil) -> Run {
        let plan = Plan(name: name, deadline: deadline, routine: routine)
        context.insert(plan)

        for block in blocks {
            block.plan = plan
            block.routine = nil
        }
        plan.renumber()

        let run = Run(plan: plan, startedAt: startedAt, currentIndex: 0)
        context.insert(run)
        RunEngineStore.shared.engine(for: run)

        Task {
            await TravelTimeService.shared.refreshPlan(plan, departingAt: Date())
        }

        return run
    }

    /// Starts a run against an already-existing `Plan` — e.g. tapping
    /// "Start Run" in `PlanEditorView`. Unlike `start(deadline:name:blocks:)`
    /// above, this plan might already have an open run against it (the
    /// user re-opened it after Exit, or from Current Countdowns): since
    /// `Block`s belong to the `Plan` and are shared by whichever `Run` is
    /// driving them, two simultaneously-open runs of the same plan would
    /// fight over the same block rows, and a fresh `resetForNewRun()` would
    /// wipe a run that's still genuinely in progress. So this resumes the
    /// existing open run instead of creating a second one.
    @discardableResult
    static func startOrResume(plan: Plan, in context: ModelContext) -> Run {
        let openDescriptor = FetchDescriptor<Run>(predicate: #Predicate<Run> { $0.finishedAt == nil })
        if let openRuns = try? context.fetch(openDescriptor),
           let existing = openRuns.first(where: { $0.plan?.persistentModelID == plan.persistentModelID }) {
            return RunEngineStore.shared.engine(for: existing).run
        }

        plan.resetForNewRun()
        let run = Run(plan: plan, startedAt: Date(), currentIndex: 0)
        context.insert(run)
        RunEngineStore.shared.engine(for: run)

        Task {
            await TravelTimeService.shared.refreshPlan(plan, departingAt: Date())
        }

        return run
    }
}
