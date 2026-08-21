import Foundation
import SwiftData

/// One live-running `Run`'s clock and business logic, detached from any
/// particular view. This used to all live inside `RunView` — which meant
/// dismissing that screen (by design or by mistake) silently stopped the
/// tick and auto-advance, even though nothing about the run itself was
/// supposed to end. Owned by `RunEngineStore`, one engine per open `Run`;
/// `RunView` (and the Current Countdowns list) are thin observers of
/// whichever engine backs the `Run` they're showing.
///
/// A `Timer` does not fire while the app is suspended, so this is not a
/// true background scheduler — the tick simply resumes on its normal
/// cadence once the process is foregrounded again, and `reconcile()` (run
/// on every tick, including that first post-resume one) walks the block
/// sequence forward using each block's own known duration rather than
/// `Date()`, so a gap of any length collapses correctly instead of
/// stamping every skipped block with today's timestamp. `Notifications`
/// still cover the truly-backgrounded case (the OS fires those without the
/// process running at all).
@MainActor
@Observable
final class RunEngine {
    let run: Run
    private let modelContext: ModelContext

    private(set) var now = Date()
    private(set) var currentSolution: Solution?
    var autoAdvance: Bool
    var showingActivitiesDisabledAlert = false
    var startFailureMessage: String?

    private var timer: Timer?
    private var lastPushedOverrun = false
    /// Which twentieth of the current span the last pushed Live Activity
    /// state was drawn at. The Dynamic Island's ring depletes on its own
    /// (the system animates `ProgressView(timerInterval:)` without the app
    /// running), but its *color* is fixed at whatever was pushed, so the
    /// green-to-red ramp only moves when a new state goes out. Pushing on
    /// every 1s tick would be twenty times more traffic than the ramp can
    /// show; pushing on a bucket change gives twenty steps per step, which
    /// is finer than the eye reads on a 20pt ring.
    private var lastPushedRampBucket = -1

    var plan: Plan? { run.plan }
    var blocks: [Block] { plan?.orderedBlocks ?? [] }

    var currentBlock: Block? {
        guard blocks.indices.contains(run.currentIndex) else { return nil }
        return blocks[run.currentIndex]
    }

    var isFinished: Bool {
        run.finishedAt != nil || run.currentIndex >= blocks.count
    }

    /// True from the moment Start is tapped until Step 1 actually begins.
    var isWaitingToStart: Bool {
        !isFinished && run.currentIndex == 0 && currentBlock?.actualStart == nil
    }

    /// The plan's own required start time — deadline minus every known
    /// block's duration, ignoring `run.startedAt` entirely. nil for a
    /// flex-block plan (see `Solver` — start is underdetermined with a flex
    /// block present).
    var naturalStart: Date? {
        guard let p = plan, !blocks.isEmpty, !blocks.contains(where: { $0.kind == .flex }) else { return nil }
        let durations: [BlockDuration] = blocks.map { block in
            .known(TimeInterval(TravelTimeService.shared.manualEstimateMinutes(for: block) * 60))
        }
        let input = SolverInput(durations: durations, deadline: p.deadline, start: nil, pinnedFlex: nil)
        return (try? Solver.solve(input))?.start
    }

    /// Whether the current block will move itself along on its own.
    func autoAdvanceEligible(_ block: Block) -> Bool {
        autoAdvance && block.kind != .flex && block.isOpenEnded
    }

    /// True once the current block has run past its own estimate and
    /// nothing is going to move it along automatically.
    var isCurrentBlockOverrun: Bool {
        guard !isFinished, let block = currentBlock, block.kind != .flex,
              !autoAdvanceEligible(block), let target = leaveByDate(for: block) else { return false }
        return target < now
    }

    var latenessMinutes: Int? {
        guard let lateness = currentSolution?.lateness else { return nil }
        return Int((lateness / 60.0).rounded())
    }

    init(run: Run, modelContext: ModelContext) {
        self.run = run
        self.modelContext = modelContext
        self.autoAdvance = AppSettings.shared.autoAdvanceEnabled
        resume()
    }

    /// Starts (or resumes) this engine's own tick — idempotent, safe to
    /// call every time a view attaches to an already-running engine.
    func resume() {
        reconcile()
        recomputeSolution()
        syncLiveActivityAndNotifications()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stops ticking without touching the `Run`/Live Activity/notifications
    /// — used only when the engine itself is being torn down (run finished
    /// or explicitly canceled), never for "the view went away."
    func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        now = Date()
        checkWaitTimeElapsed()
        recomputeSolution()
        let advancedIndex = reconcile()
        let overrun = isCurrentBlockOverrun
        let bucket = rampBucket
        if advancedIndex || overrun != lastPushedOverrun || bucket != lastPushedRampBucket {
            lastPushedOverrun = overrun
            lastPushedRampBucket = bucket
            recomputeSolution()
            syncLiveActivityAndNotifications()
        }
    }

    /// Start of the span the Live Activity is currently counting down:
    /// the active block's own start, or the moment the run was launched
    /// while it's still waiting for Step 1's clock time.
    var activitySegmentStart: Date {
        if isWaitingToStart { return run.startedAt }
        return currentBlock?.actualStart ?? run.startedAt
    }

    /// How far through that span we are, in twentieths. -1 when there is no
    /// span to speak of, so a run with nothing to count down doesn't push.
    private var rampBucket: Int {
        let target = isWaitingToStart ? naturalStart : currentBlock.flatMap(leaveByDate(for:))
        guard let target else { return -1 }
        let span = target.timeIntervalSince(activitySegmentStart)
        guard span > 0 else { return -1 }
        let fraction = now.timeIntervalSince(activitySegmentStart) / span
        return Int((min(max(fraction, 0), 1) * 20).rounded(.down))
    }

    /// Ends the wait phase, whether triggered by the clock reaching
    /// `naturalStart` or by the user tapping through early.
    func checkWaitTimeElapsed() {
        guard isWaitingToStart, let target = naturalStart, now >= target else { return }
        // Backdated to the moment it was *due*, not the moment the app
        // noticed. The tick only runs while the process is alive, so a
        // rollover that came due while the phone was in a pocket was
        // stamped minutes late, and every downstream target inherited the
        // drift — the "arrive by 3:52" that the deadline-anchored 3:50 in
        // the same screen disagreed with. Same principle as
        // `ScheduleService`: the timeline is absolute wall clock, and a
        // late observation of it doesn't move it.
        beginFirstStepNow(at: target)
    }

    /// `at` is the moment Step 1 is considered to have begun. Defaults to
    /// now, which is right for tapping "Start Step 1 Now" early; the clock
    /// rollover passes the due time instead.
    func beginFirstStepNow(at start: Date = Date()) {
        guard let block = currentBlock, block.actualStart == nil else { return }
        block.actualStart = start
        block.status = .active
        run.startedAt = start
        lastPushedOverrun = false
        lastPushedRampBucket = -1
        recomputeSolution()
        syncLiveActivityAndNotifications()
    }

    /// Walks the block sequence forward from the current block's
    /// `actualStart`, using each block's own known duration, finalizing
    /// every block whose computed boundary has already passed as of `now`.
    /// Stops at the first block that either hasn't finished yet, or isn't
    /// eligible to auto-advance (flex, pinned-manual, or auto-advance off)
    /// — that block is left active, waiting on a manual "Next Step" tap,
    /// same as the always-wanted behavior: move on automatically, or wait
    /// for the user to say they're done. Never marks anything "overdue."
    /// Returns whether it actually advanced the run's current index.
    @discardableResult
    private func reconcile() -> Bool {
        guard !isFinished, let block = currentBlock, let cursorStart = block.actualStart else { return false }

        var idx = run.currentIndex
        var cursor = cursorStart
        while idx < blocks.count {
            let b = blocks[idx]
            guard autoAdvanceEligible(b) else { break }
            let minutes = TravelTimeService.shared.manualEstimateMinutes(for: b)
            let boundary = cursor.addingTimeInterval(TimeInterval(minutes * 60))
            guard boundary <= now else { break }

            b.actualStart = cursor
            b.actualEnd = boundary
            b.status = .done
            cursor = boundary
            idx += 1

            if idx < blocks.count {
                let next = blocks[idx]
                next.actualStart = cursor
                next.status = .active
                if next.kind == .flex && run.pinnedFlexMinutes == nil {
                    pinFlexIfNeeded()
                }
                if next.kind == .drive {
                    Task {
                        await TravelTimeService.shared.resolve(block: next, departingAt: cursor)
                        self.recomputeSolution()
                        self.syncLiveActivityAndNotifications()
                    }
                }
            }
        }

        guard idx != run.currentIndex else { return false }
        run.currentIndex = idx
        lastPushedOverrun = false
        if idx >= blocks.count {
            run.finishedAt = cursor
        }
        return true
    }

    /// `auto: true` means the timer/reconcile fired this, not a tap — skip
    /// logging a `DurationSample` in that case (an auto-fired advance
    /// happens at roughly the estimate itself, so it would just echo the
    /// Estimator's own prior back). Manual taps and the notification-action
    /// observer keep logging.
    func advanceStep(auto: Bool = false) {
        let currentIdx = run.currentIndex
        if blocks.indices.contains(currentIdx) {
            let completedBlock = blocks[currentIdx]
            completedBlock.actualEnd = Date()
            completedBlock.status = .done

            if !auto, completedBlock.kind != .flex, let template = completedBlock.template {
                let elapsedSec = Date().timeIntervalSince(completedBlock.actualStart ?? run.startedAt)
                let elapsedMins = max(1, Int((elapsedSec / 60.0).rounded()))
                let sample = DurationSample(minutes: elapsedMins, recordedAt: Date(), template: template)
                modelContext.insert(sample)
            }
        }

        lastPushedOverrun = false
        let nextIdx = currentIdx + 1
        run.currentIndex = nextIdx

        if blocks.indices.contains(nextIdx) {
            let nextBlock = blocks[nextIdx]
            nextBlock.actualStart = Date()
            nextBlock.status = .active

            if nextBlock.kind == .flex && run.pinnedFlexMinutes == nil {
                pinFlexIfNeeded()
            }

            if nextBlock.kind == .drive {
                Task {
                    await TravelTimeService.shared.resolve(block: nextBlock, departingAt: Date())
                    self.recomputeSolution()
                    self.syncLiveActivityAndNotifications()
                }
            }
        } else {
            run.finishedAt = Date()
        }

        recomputeSolution()
        syncLiveActivityAndNotifications()
    }

    /// True cancellation: stops ticking, marks the run finished, tears down
    /// its own Live Activity and pending notifications. Distinct from a
    /// view simply being dismissed, which leaves the engine (and the Live
    /// Activity) running.
    func cancel() {
        run.finishedAt = Date()
        stopTicking()
        if let p = plan {
            Task { await LiveActivityManager.end(planId: "\(p.id)") }
        }
        // Only safe to blanket-cancel notifications if nothing else is
        // running — `RunEngineStore` handles that check before calling this.
    }

    func pinFlexIfNeeded() {
        guard let sol = currentSolution, let flexDur = sol.flexDuration else { return }
        let flexMins = max(0, Int((flexDur / 60.0).rounded()))
        run.pinnedFlexMinutes = flexMins
    }

    func recomputeSolution() {
        guard let p = plan, !blocks.isEmpty else { return }

        var durations: [BlockDuration] = []
        for block in blocks {
            if block.kind == .flex {
                durations.append(.flex)
            } else {
                let mins = TravelTimeService.shared.manualEstimateMinutes(for: block)
                durations.append(.known(TimeInterval(mins * 60)))
            }
        }

        let pinnedFlexSeconds: TimeInterval? = run.pinnedFlexMinutes.map { Double($0 * 60) }

        let input = SolverInput(
            durations: durations,
            deadline: p.deadline,
            start: run.startedAt,
            pinnedFlex: pinnedFlexSeconds
        )

        currentSolution = try? Solver.solve(input)
    }

    func schedule(for block: Block) -> BlockSchedule? {
        currentSolution?.blocks.first(where: { $0.index == block.order })
    }

    /// The one time a step is judged against: the solver's deadline-anchored
    /// boundary (deadline minus everything that comes after it), which is
    /// also what the steps list shows per row and what the step
    /// notifications fire on.
    ///
    /// This used to be the step's own duration counted from its actual
    /// start, which put two different times for the same step on one
    /// screen: a drive that began two minutes late read "3:52" in the
    /// header and "3:50" in the list, and the notification went off at
    /// 3:50 while the countdown still claimed two minutes left. Starting
    /// late does not move the deadline, so it does not move this either;
    /// `projectedEnd(for:)` is where the drift shows up instead, shown
    /// beside this as a projection rather than competing with it.
    func leaveByDate(for block: Block) -> Date? {
        if let sched = schedule(for: block) {
            switch sched.constraint {
            case .hardLeaveBy(let d): return d
            case .flexAbsorbs: return sched.scheduledEnd
            }
        }
        // No solution yet (or a block the solver doesn't know about) —
        // fall back to the step's own span so the UI still has a number.
        return projectedEnd(for: block)
    }

    /// Where this step actually lands if it takes its full estimate from
    /// when it really began: the honest projection, which drifts past
    /// `leaveByDate` exactly as far as the run is behind.
    func projectedEnd(for block: Block) -> Date? {
        guard block.kind != .flex else { return nil }
        let start = block.actualStart ?? run.startedAt
        let minutes = TravelTimeService.shared.manualEstimateMinutes(for: block)
        return start.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// What the step's target time means, in the step's own terms. A drive
    /// ends by arriving; everything else ends by being finished. The last
    /// step's target is the plan's deadline itself, which is worth saying
    /// out loud rather than calling it just another step boundary.
    func targetLabel(for block: Block) -> String {
        if isWaitingToStart { return "Start by" }
        if block.kind == .drive { return "Arrive by" }
        if block.order >= blocks.count - 1 { return "Done by" }
        return "Finish by"
    }

    /// True when this step is the last one and will end the run on its own
    /// at its target time. The widget needs to know: it is what lets the
    /// Live Activity show "finished" at the deadline instead of a number
    /// ticking upward for half an hour while the app sits suspended and
    /// unable to end anything.
    func endsRunAtTarget(_ block: Block) -> Bool {
        block.order >= blocks.count - 1 && autoAdvanceEligible(block)
    }

    func syncLiveActivityAndNotifications() {
        guard let p = plan else { return }

        if isFinished {
            // Reached the last step (or was cancelled) while nothing was
            // necessarily watching — `RunEngineStore.retire` only ran from
            // the finished screen's `onAppear`/Done button, so a run that
            // completed in the background kept a 1s timer alive forever.
            stopTicking()
            Task {
                await LiveActivityManager.finish(planId: "\(p.id)")
                Notifications.shared.cancelRunNotifications(planId: "\(p.id)")
            }
            return
        }

        if !isWaitingToStart, let sol = currentSolution {
            Notifications.shared.scheduleRunNotifications(for: p, solution: sol)
        }

        let target = isWaitingToStart ? naturalStart : currentBlock.flatMap(leaveByDate(for:))
        if let block = currentBlock, let target {
            let planId = "\(p.id)"
            let label = targetLabel(for: block) + " "
            let overrun = isCurrentBlockOverrun
            let segmentStart = activitySegmentStart
            let endsAtTarget = !isWaitingToStart && endsRunAtTarget(block)
            Task {
                // Update in place whenever this plan already has a live
                // activity — see `LiveActivityManager.hasActivity` doc.
                // `start` (full end-and-re-request) is only for the very
                // first sync of a run.
                if LiveActivityManager.hasActivity(planId: planId) {
                    await LiveActivityManager.update(
                        planId: planId,
                        planName: p.name,
                        blockName: block.name,
                        blockIndex: run.currentIndex,
                        totalBlocks: blocks.count,
                        targetLeaveBy: target,
                        segmentStart: segmentStart,
                        isFlex: block.kind == .flex,
                        symbol: block.template?.symbol ?? block.kind.defaultSymbol,
                        isWaiting: isWaitingToStart,
                        targetLabel: label,
                        isOverrun: overrun,
                        latenessMinutes: overrun ? latenessMinutes : nil,
                        endsRunAtTarget: endsAtTarget
                    )
                    return
                }
                let outcome = await LiveActivityManager.start(
                    planId: planId,
                    planName: p.name,
                    blockName: block.name,
                    blockIndex: run.currentIndex,
                    totalBlocks: blocks.count,
                    targetLeaveBy: target,
                    segmentStart: segmentStart,
                    isFlex: block.kind == .flex,
                    symbol: block.template?.symbol ?? block.kind.defaultSymbol,
                    isWaiting: isWaitingToStart,
                    targetLabel: label,
                    isOverrun: overrun,
                    latenessMinutes: overrun ? latenessMinutes : nil,
                    endsRunAtTarget: endsAtTarget
                )
                switch outcome {
                case .started: break
                case .activitiesDisabled: self.showingActivitiesDisabledAlert = true
                case .failed(let message): self.startFailureMessage = message
                }
            }
        }
    }
}
