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
    /// Why `currentSolution` is nil, when it is nil for a reason the user
    /// caused (two open duration blocks, most likely). Every call site used
    /// to `try?` the solver and discard the reason, so an invalid plan just
    /// went blank — no leave-by times, no lateness, nothing on screen
    /// saying why.
    private(set) var solutionErrorMessage: String?
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
    /// block's duration, ignoring `run.startedAt` entirely.
    ///
    /// An open duration block contributes zero: the latest possible start
    /// (zero flex left) is still perfectly well defined, and it is exactly
    /// the moment a waiting flex or walk plan must begin. Treating such
    /// plans as having *no* natural start meant an armed flex routine never
    /// auto-started, never showed a wait countdown, and never got a Live
    /// Activity — the silent failure was for precisely the routines with
    /// the most timing risk.
    var naturalStart: Date? {
        guard let p = plan, !blocks.isEmpty else { return nil }
        let durations: [BlockDuration] = blocks.map { block in
            block.kind.isOpenDuration
                ? .known(0)
                : .known(TimeInterval(TravelTimeService.shared.manualEstimateMinutes(for: block) * 60))
        }
        let input = SolverInput(durations: durations, deadline: p.deadline, start: nil, pinnedFlex: nil)
        return (try? Solver.solve(input))?.start
    }

    /// Whether the current block will move itself along on its own.
    func autoAdvanceEligible(_ block: Block) -> Bool {
        // A walk is excluded for the same reason a flex block is: its
        // duration is not a number anyone knew in advance, so there is no
        // moment for a timer to declare it over. It ends when you say you
        // are back.
        autoAdvance && !block.kind.isOpenDuration && block.isOpenEnded
    }

    /// True once the current block has run past its own estimate and
    /// nothing is going to move it along automatically.
    var isCurrentBlockOverrun: Bool {
        guard !isFinished, let block = currentBlock, !block.kind.isOpenDuration,
              !autoAdvanceEligible(block), let target = leaveByDate(for: block) else { return false }
        return target < now
    }

    var latenessMinutes: Int? {
        guard let lateness = currentSolution?.lateness else { return nil }
        return Int((lateness / 60.0).rounded())
    }

    init(run: Run, modelContext: ModelContext, now: Date = Date()) {
        self.run = run
        self.modelContext = modelContext
        self.autoAdvance = AppSettings.shared.autoAdvanceEnabled
        resume(at: now)
    }

    deinit {
        // Every removal path stops the timer first, but a RunLoop retains
        // its timers, so an engine dropped without `stopTicking` would leak
        // a once-per-second closure forever. Safety net only. Deinit is
        // nonisolated; every owner of an engine (the store's dictionary,
        // view state) lives on the main actor, so deallocation happens
        // there — `assumeIsolated` asserts that instead of assuming it
        // silently.
        MainActor.assumeIsolated {
            timer?.invalidate()
        }
    }

    /// Starts (or resumes) this engine's own tick — idempotent, safe to
    /// call every time a view attaches to an already-running engine.
    func resume(at date: Date = Date()) {
        now = date
        checkWaitTimeElapsed()
        recomputeSolution()
        reconcile()
        recomputeSolution()
        resumeWalkIfNeeded()
        syncLiveActivityAndNotifications()
        guard !isFinished, timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Lets iOS coalesce wakeups across several open runs' engines.
        t.tolerance = 0.2
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
        if currentBlock?.kind == .walk {
            WalkTracker.shared.tick()
        }
        recomputeSolution()
        let advancedIndex = reconcile()
        if advancedIndex {
            // Only an actual advance changes the solution's inputs
            // mid-tick; recomputing unconditionally on the push branch was
            // a second full solve every push for nothing.
            recomputeSolution()
        }
        let overrun = isCurrentBlockOverrun
        let bucket = rampBucket
        if advancedIndex || overrun != lastPushedOverrun || bucket != lastPushedRampBucket {
            lastPushedOverrun = overrun
            lastPushedRampBucket = bucket
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
    /// The fraction itself is `OnTimeActivityLogic.spanFraction` — the same
    /// formula the widget's ring tint uses, on purpose: the two sides of
    /// the process seam drift apart the moment either grows its own copy.
    private var rampBucket: Int {
        let target = isWaitingToStart ? naturalStart : currentBlock.flatMap(leaveByDate(for:))
        guard let target else { return -1 }
        guard target > activitySegmentStart else { return -1 }
        let fraction = OnTimeActivityLogic.spanFraction(now: now, segmentStart: activitySegmentStart, target: target)
        return Int((fraction * 20).rounded(.down))
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
        if block.kind.isOpenDuration && run.pinnedFlexMinutes == nil {
            pinFlexIfNeeded()
            recomputeSolution()
        }
        resumeWalkIfNeeded()
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
            logOnTimeCompletion(of: b, minutes: minutes, at: boundary)
            cursor = boundary
            idx += 1

            if idx < blocks.count {
                let next = blocks[idx]
                next.actualStart = cursor
                next.status = .active
                if next.kind.isOpenDuration && run.pinnedFlexMinutes == nil {
                    pinFlexIfNeeded()
                }
                if next.kind == .walk { beginWalk(next) }
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

    /// A step that ran out its estimate and moved on by itself is recorded
    /// as having taken its estimate.
    ///
    /// It used to record nothing, on the reasoning that nobody observed when
    /// the step really ended. But the only other way a sample gets written is
    /// a tap in `advanceStep`, and with auto advance on a tap can only land
    /// *before* the estimate runs out. So every sample a template ever
    /// collected was shorter than its estimate, the learned duration could
    /// only fall, and the solver scheduled against it: start times crept
    /// later week by week with nothing on screen saying why. An on time
    /// completion is the evidence that the estimate was enough, and it is
    /// what stops a few early taps from dragging the p80 down.
    ///
    /// What this cannot learn is a step that really took longer, because the
    /// app has moved on by then and sees nothing. Only a step set to wait for
    /// a tap measures that.
    private func logOnTimeCompletion(of block: Block, minutes: Int, at completedAt: Date) {
        guard !block.kind.isOpenDuration, let template = block.template else { return }
        modelContext.insert(DurationSample(minutes: max(1, minutes), recordedAt: completedAt, template: template))
    }

    /// Every caller of this is a tap (button, Live Activity intent, or
    /// notification action) — auto advances flow through `reconcile`, which
    /// stamps blocks directly and logs through `logOnTimeCompletion`; every
    /// manual advance logs the measured `DurationSample` here. (An `auto:` parameter used to exist for a skip
    /// branch nothing ever exercised.)
    func advanceStep(at completedAt: Date = Date()) {
        // A stale "Next Step" tap can arrive after the run already finished
        // (a delivered notification acted on late, or the Live Activity's
        // button during its dismissal window). Without this guard it pushed
        // `currentIndex` past `blocks.count` and overwrote the honestly
        // backdated `finishedAt` with `Date()`.
        guard !isFinished else { return }
        now = completedAt

        let currentIdx = run.currentIndex
        if blocks.indices.contains(currentIdx) {
            let completedBlock = blocks[currentIdx]
            completedBlock.actualEnd = completedAt
            completedBlock.status = .done

            if completedBlock.kind == .walk { WalkTracker.shared.end(for: run.uuid) }

            if !completedBlock.kind.isOpenDuration, let template = completedBlock.template {
                let elapsedSec = completedAt.timeIntervalSince(completedBlock.actualStart ?? run.startedAt)
                let elapsedMins = max(1, Int((elapsedSec / 60.0).rounded()))
                let sample = DurationSample(minutes: elapsedMins, recordedAt: completedAt, template: template)
                modelContext.insert(sample)
            }
        }

        lastPushedOverrun = false
        let nextIdx = currentIdx + 1
        run.currentIndex = nextIdx

        if blocks.indices.contains(nextIdx) {
            let nextBlock = blocks[nextIdx]
            nextBlock.actualStart = completedAt
            nextBlock.status = .active

            if nextBlock.kind.isOpenDuration && run.pinnedFlexMinutes == nil {
                pinFlexIfNeeded()
            }
            if nextBlock.kind == .walk { beginWalk(nextBlock) }

            if nextBlock.kind == .drive {
                Task {
                    await TravelTimeService.shared.resolve(block: nextBlock, departingAt: completedAt)
                    self.recomputeSolution()
                    self.syncLiveActivityAndNotifications()
                }
            }
        } else {
            run.finishedAt = completedAt
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
        // Owner-scoped: with two runs open at once, cancelling this one
        // must not kill the other run's active walk and its armed
        // turnaround alarm.
        WalkTracker.shared.end(for: run.uuid)
        if let p = plan {
            Task { await LiveActivityManager.end(planId: p.uuid.uuidString) }
            PiSchedule.clearRun(planId: p.uuid.uuidString)
        }
        // `RunEngineStore.cancel` removes this plan's own pending step
        // notifications right after.
    }

    func pinFlexIfNeeded() {
        // Include the step just completed before fixing the remaining allowance.
        recomputeSolution()
        guard let sol = currentSolution, let flexDur = sol.flexDuration else { return }
        let flexMins = max(0, Int((flexDur / 60.0).rounded()))
        run.pinnedFlexMinutes = flexMins
    }

    // MARK: - Walk blocks

    /// Hands the walk tracker its deadline and its way home. Called on
    /// entry to a `.walk` block and again from every `recomputeSolution`,
    /// because the be-home-by time is not fixed: adding, editing or
    /// removing a later step moves it, and the whole feature is a
    /// comparison against that one number.
    ///
    /// `begin` is idempotent for an already-running walk — it updates the
    /// deadline and leaves the measured path, pace and phase alone — so
    /// calling it repeatedly is the intended use, not a guard failure.
    private func beginWalk(_ block: Block) {
        guard block.kind == .walk, let homeBy = leaveByDate(for: block) else { return }
        WalkTracker.shared.begin(homeBy: homeBy, home: block.destinationPlace, owner: run.uuid)
    }

    /// Re-attaches the tracker after the app was killed and relaunched
    /// mid-walk. `RunEngineStore` rebuilds the engine from the persisted
    /// `Run`, but `WalkTracker` holds no persisted state of its own, so
    /// without this the walk would come back with its screen intact and
    /// nothing behind it. What is lost is the measured path and pace,
    /// which restart from zero; what survives is the deadline, which is
    /// the part that matters.
    private func resumeWalkIfNeeded() {
        guard let block = currentBlock, block.kind == .walk, !isFinished else { return }
        beginWalk(block)
    }

    func recomputeSolution() {
        guard let p = plan, !blocks.isEmpty else { return }

        var durations: [BlockDuration] = []
        for block in blocks {
            if let start = block.actualStart, let end = block.actualEnd {
                durations.append(.known(max(0, end.timeIntervalSince(start))))
            } else if block.kind.isOpenDuration {
                durations.append(.flex)
            } else {
                let mins = TravelTimeService.shared.manualEstimateMinutes(for: block, now: now)
                var duration = TimeInterval(mins * 60)
                if let start = block.actualStart, !autoAdvanceEligible(block) {
                    // A step awaiting a tap has consumed at least this much time.
                    duration = max(duration, now.timeIntervalSince(start))
                }
                durations.append(.known(duration))
            }
        }

        var pinnedFlexSeconds: TimeInterval? = run.pinnedFlexMinutes.map { Double($0 * 60) }
        if let pinned = pinnedFlexSeconds, let block = currentBlock,
           block.kind.isOpenDuration, let start = block.actualStart, block.actualEnd == nil {
            pinnedFlexSeconds = max(pinned, now.timeIntervalSince(start))
        }

        let input = SolverInput(
            durations: durations,
            deadline: p.deadline,
            start: run.startedAt,
            pinnedFlex: pinnedFlexSeconds
        )

        do {
            currentSolution = try Solver.solve(input)
            solutionErrorMessage = nil
        } catch let error as SolverError {
            currentSolution = nil
            solutionErrorMessage = Self.describe(error)
        } catch {
            currentSolution = nil
            solutionErrorMessage = error.localizedDescription
        }

        // The walk's deadline is derived from the solution that was just
        // computed, so it is refreshed here rather than only on entry.
        if let block = currentBlock, block.kind == .walk, WalkTracker.shared.isActive {
            beginWalk(block)
        }
    }

    private static func describe(_ error: SolverError) -> String {
        switch error {
        case .multipleFlexBlocks:
            return "This plan has more than one flex or walk step, so its times can't be solved. Remove one to get the schedule back."
        case .underdetermined:
            return "This plan can't be solved without a start time."
        case .empty:
            return "No steps to schedule."
        }
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
        guard !block.kind.isOpenDuration else { return nil }
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
        return stepLabel(for: block)
    }

    /// The label for a step that is running, whatever the run is doing now.
    /// `projectedActivitySteps` labels steps that have not begun yet, some
    /// of them while the run is still waiting to start.
    private func stepLabel(for block: Block) -> String {
        if block.kind == .drive { return "Arrive by" }
        if block.kind == .walk {
            return WalkTracker.shared.phase == .returning ? "Home by" : "Turn back by"
        }
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

    // MARK: - Projection for the Pi

    /// Every moment from now on at which the Live Activity has to change
    /// with nobody touching the phone, and what it has to change to.
    ///
    /// The app is suspended for most of a run, so it cannot make these
    /// changes: the Island sat on a finished step, went red and counted up
    /// until the app was opened. `PiSchedule` hands this list to the Pi,
    /// which delivers each state by push at its time.
    ///
    /// It is `reconcile()` run forward in imagination: the same walk, the
    /// same estimates, the same stop at the first step that waits for a tap
    /// or has no duration to run out. Past that step nothing is projected,
    /// because "over, waiting on you" is then the truth and the staleness
    /// re-render already shows it. While waiting, the first entry is the
    /// rollover into step 1 at `naturalStart`.
    ///
    /// A projected target comes from the solution, the same place
    /// `leaveByDate` reads it, so a pushed step and the step the app would
    /// have shown cannot disagree. An auto advanced step ends exactly on its
    /// estimate, which leaves the solution as it was, so today's solution is
    /// still right for steps that have not begun.
    func projectedActivitySteps() -> [PiSchedule.RunStep] {
        guard !isFinished, let p = plan, !blocks.isEmpty else { return [] }

        var steps: [PiSchedule.RunStep] = []
        let index = run.currentIndex
        let cursor: Date
        let solution: Solution?

        if isWaitingToStart {
            guard let start = naturalStart else { return [] }
            solution = projectedSolution(startingAt: start)
            cursor = start
            steps.append(.init(fireAt: start,
                               state: projectedState(index: 0, segmentStart: start, solution: solution, plan: p),
                               endsRun: false))
        } else {
            guard let start = currentBlock?.actualStart else { return [] }
            solution = currentSolution
            cursor = start
        }

        let timeline = blocks.map { block in
            RunProjection.Step(
                seconds: TimeInterval(TravelTimeService.shared.manualEstimateMinutes(for: block, now: now) * 60),
                autoAdvances: autoAdvanceEligible(block)
            )
        }
        for boundary in RunProjection.boundaries(steps: timeline, currentIndex: index,
                                                 currentStart: cursor, now: now) {
            if blocks.indices.contains(boundary.entering) {
                steps.append(.init(fireAt: boundary.at,
                                   state: projectedState(index: boundary.entering, segmentStart: boundary.at,
                                                         solution: solution, plan: p),
                                   endsRun: false))
            } else {
                var finished = projectedState(index: blocks.count - 1, segmentStart: boundary.at,
                                              solution: solution, plan: p)
                finished.isFinished = true
                steps.append(.init(fireAt: boundary.at, state: finished, endsRun: true))
            }
        }
        return steps
    }

    /// The solution `recomputeSolution` will produce at the moment a waiting
    /// run rolls into step 1: nothing has an actual time yet and the run
    /// starts at `start`.
    private func projectedSolution(startingAt start: Date) -> Solution? {
        guard let p = plan else { return nil }
        let durations: [BlockDuration] = blocks.map { block in
            block.kind.isOpenDuration
                ? .flex
                : .known(TimeInterval(TravelTimeService.shared.manualEstimateMinutes(for: block, now: now) * 60))
        }
        return try? Solver.solve(SolverInput(durations: durations, deadline: p.deadline,
                                             start: start, pinnedFlex: nil))
    }

    private func projectedState(index: Int, segmentStart: Date, solution: Solution?,
                                plan p: Plan) -> OnTimeActivityAttributes.ContentState {
        let block = blocks[index]
        var target = p.deadline
        if let sched = solution?.blocks.first(where: { $0.index == block.order }) {
            switch sched.constraint {
            case .hardLeaveBy(let date): target = date
            case .flexAbsorbs: target = sched.scheduledEnd
            }
        }
        return .init(
            planName: p.name,
            blockName: block.name,
            blockIndex: index,
            totalBlocks: blocks.count,
            targetLeaveBy: target,
            segmentStart: segmentStart,
            isFlex: block.kind.isOpenDuration,
            symbol: block.template?.symbol ?? block.kind.defaultSymbol,
            isWaiting: false,
            // A walk entered by push has no tracker running behind it, so
            // there is no turnaround to count to, only the time to be back.
            targetLabel: (block.kind == .walk ? "Home by" : stepLabel(for: block)) + " ",
            endsRunAtTarget: endsRunAtTarget(block)
        )
    }

    func syncLiveActivityAndNotifications() {
        guard let p = plan else { return }
        let planId = p.uuid.uuidString

        // The Home Screen widget's snapshot moves with the same state the
        // Live Activity does. `WidgetBridge` compares the encoded payload
        // before writing, so the twenty ramp-bucket pushes per step do not
        // become twenty widget reloads.
        WidgetBridge.shared.setNeedsRefresh()

        if isFinished {
            WalkTracker.shared.end(for: run.uuid)
            // Reached the last step (or was cancelled) while nothing was
            // necessarily watching — `RunEngineStore.retire` only ran from
            // the finished screen's `onAppear`/Done button, so a run that
            // completed in the background kept a 1s timer alive forever.
            stopTicking()
            Task {
                await LiveActivityManager.finish(planId: planId)
                Notifications.shared.cancelRunNotifications(planId: planId)
            }
            // Self-retire so an unattended completion doesn't leave a dead
            // engine (and its whole Run/Plan/Block graph) in the store
            // until a RunView for this exact run happens to appear.
            RunEngineStore.shared.retire(run)
            PiSchedule.clearRun(planId: planId)
            return
        }

        PiSchedule.publishRun(planId: planId, steps: projectedActivitySteps())

        if !isWaitingToStart, let sol = currentSolution {
            Notifications.shared.scheduleRunNotifications(for: p, solution: sol)
        }

        // A walk counts down to its turnaround, not to its own end — and
        // once you have turned around, to the be-home-by time. Feeding that
        // through the existing `targetLeaveBy` / `targetLabel` pair is why
        // `OnTimeWidget` needed no changes at all for this feature: the ring
        // and its green-to-red ramp already draw whatever span they are
        // handed.
        var target = isWaitingToStart ? naturalStart : currentBlock.flatMap(leaveByDate(for:))
        if !isWaitingToStart, currentBlock?.kind == .walk, WalkTracker.shared.isActive,
           let walkTarget = WalkTracker.shared.activityTarget {
            target = walkTarget
        }
        if let block = currentBlock, let target {
            let label = targetLabel(for: block) + " "
            let overrun = isCurrentBlockOverrun
            let segmentStart = activitySegmentStart
            let waiting = isWaitingToStart
            let endsAtTarget = !waiting && endsRunAtTarget(block)
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
                        isFlex: block.kind.isOpenDuration,
                        symbol: block.template?.symbol ?? block.kind.defaultSymbol,
                        isWaiting: waiting,
                        targetLabel: label,
                        isOverrun: overrun,
                        latenessMinutes: overrun ? latenessMinutes : nil,
                        startsRunAtTarget: waiting,
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
                    isFlex: block.kind.isOpenDuration,
                    symbol: block.template?.symbol ?? block.kind.defaultSymbol,
                    isWaiting: waiting,
                    targetLabel: label,
                    isOverrun: overrun,
                    latenessMinutes: overrun ? latenessMinutes : nil,
                    startsRunAtTarget: waiting,
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
