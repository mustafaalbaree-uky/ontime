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
    /// How many steps the surfaces still had to show at the last push. A
    /// step's time passing takes one off with the engine standing still (a
    /// run that is behind, a step waiting for a tap), and the push that
    /// follows hands the Live Activity a fresh stale date, so it can move on
    /// by itself again at the next one.
    private var lastPushedShownCount = -1
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
        let shownCount = shownTimeline()?.steps.count ?? -1
        let bucket = rampBucket
        if advancedIndex || shownCount != lastPushedShownCount || bucket != lastPushedRampBucket {
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
        // Started ahead of time by a tap: the alarm set for the start moment
        // would now ring in the middle of step 1. At the rollover itself it
        // is left alone, because that is the alarm ringing as intended.
        if let due = naturalStart, start < due.addingTimeInterval(-5), let p = plan {
            StartAlarms.cancel(id: p.uuid)
        }
        block.actualStart = start
        block.status = .active
        run.startedAt = start
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

    /// A tap on the Live Activity's button, which names the step its plate
    /// was showing. The plate moves on by the clock while the app is
    /// suspended, so that is not always the step the engine is on.
    ///
    /// The engine is caught up first, because this tap may be the first code
    /// to run in an hour. A step the engine has already moved past is done,
    /// and the tap changes nothing: it used to complete whichever step came
    /// next instead. A step the engine has not reached (the plate went ahead
    /// when a step's time passed with the run behind, or with a step waiting
    /// for a tap nobody made) is reached by closing each step before it at
    /// the moment the plate left it. Those log no sample, because nobody saw
    /// them end.
    func completeShownStep(_ index: Int, at completedAt: Date = Date()) {
        guard !isFinished else { return }
        now = completedAt
        checkWaitTimeElapsed()
        recomputeSolution()
        if reconcile() { recomputeSolution() }
        guard !isFinished, !isWaitingToStart, index >= run.currentIndex else {
            syncLiveActivityAndNotifications()
            return
        }

        while run.currentIndex < index, let block = currentBlock, blocks.indices.contains(run.currentIndex + 1) {
            let began = block.actualStart ?? run.startedAt
            let leftAt = min(max(leaveByDate(for: block) ?? completedAt, began), completedAt)
            block.actualEnd = leftAt
            block.status = .done
            if block.kind == .walk { WalkTracker.shared.end(for: run.uuid) }

            run.currentIndex += 1
            let next = blocks[run.currentIndex]
            next.actualStart = leftAt
            next.status = .active
            if next.kind.isOpenDuration && run.pinnedFlexMinutes == nil {
                pinFlexIfNeeded()
            }
            recomputeSolution()
        }
        advanceStep(at: completedAt)
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
            StartAlarms.cancel(id: p.uuid)
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
        // No solution yet (or a block the solver doesn't know about) —
        // fall back to the step's own span so the UI still has a number.
        currentSolution.flatMap { Self.leaveBy(block, in: $0) } ?? projectedEnd(for: block)
    }

    private static func leaveBy(_ block: Block, in solution: Solution) -> Date? {
        guard let sched = solution.blocks.first(where: { $0.index == block.order }) else { return nil }
        switch sched.constraint {
        case .hardLeaveBy(let d): return d
        case .flexAbsorbs: return sched.scheduledEnd
        }
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
    private func stepLabel(for block: Block) -> String {
        if block.kind == .walk, WalkTracker.shared.phase != .returning { return "Turn back by" }
        return Self.shownLabel(for: block, isLast: block.order >= blocks.count - 1)
    }

    /// The label the Live Activity and the widget give a step, which may not
    /// have begun yet. A walk reads "Home by" there: its turnaround is a
    /// plate of its own while a tracker is measuring one (`shownTimeline`),
    /// and a walk entered with the app suspended has no tracker behind it.
    static func shownLabel(for block: Block, isLast: Bool) -> String {
        if block.kind == .drive { return "Arrive by" }
        if block.kind == .walk { return "Home by" }
        return isLast ? "Done by" : "Finish by"
    }

    // MARK: - What the surfaces show

    /// The run as the Live Activity and the Home Screen widget show it from
    /// now on. Nil when there is nothing to count to at all (an unsolvable
    /// sequence). `steps` is empty when every step's time has gone by with
    /// the run still open, and the surfaces are done with it.
    struct ShownTimeline {
        /// Start of the first step's span.
        let segmentStart: Date
        /// True when the first step is the wait before step 1.
        let isWaiting: Bool
        let steps: [OnTimeShownStep]
    }

    /// The step on show, then every step after it, each aimed at its target
    /// and carrying the moment the surfaces leave it
    /// (`RunProjection.untils`). All of it is absolute wall clock, so a
    /// surface holding the list stays right with the app suspended: the Live
    /// Activity moves on at its stale date, the widget at a timeline entry,
    /// and the Pi pushes every boundary.
    ///
    /// A surface never says a step is over, so the first step here is not
    /// always the engine's. A run that is behind, a step waiting for a tap
    /// nobody made and an open duration step all pass their target with the
    /// engine still on them. The surfaces are on the next step from that
    /// moment. LiveRunPage and RunView still say how late the run is.
    ///
    /// A target comes from the solution, the same place `leaveByDate` reads
    /// it, so a pushed step and the step the app would have shown cannot
    /// disagree. While waiting, that is the solution the run will have when
    /// it rolls into step 1 at `naturalStart`.
    func shownTimeline() -> ShownTimeline? {
        // `blocks` sorts the relationship on every read, and this runs on
        // every tick.
        let blocks = self.blocks
        guard run.finishedAt == nil, blocks.indices.contains(run.currentIndex) else { return nil }
        let current = blocks[run.currentIndex]
        let waiting = run.currentIndex == 0 && current.actualStart == nil
        let upcoming = blocks[run.currentIndex...]
        var steps: [OnTimeShownStep] = []
        var segmentStart = current.actualStart ?? run.startedAt
        let solution: Solution?
        let start: Date

        func step(_ block: Block, label: String, target: Date, until: Date) -> OnTimeShownStep {
            .init(name: block.name, symbol: block.template?.symbol ?? block.kind.defaultSymbol,
                  index: block.order, target: target, targetLabel: label, until: until)
        }

        if waiting {
            guard let naturalStart else { return nil }
            start = naturalStart
            solution = projectedSolution(startingAt: start)
            steps.append(step(blocks[0], label: "Start by", target: start, until: start))
        } else {
            guard let began = current.actualStart else { return nil }
            start = began
            solution = currentSolution
            // The surfaces left the step before this one at its target,
            // which is earlier than the engine did when the run is behind.
            if run.currentIndex > 0, let left = leaveByDate(for: blocks[run.currentIndex - 1]) {
                segmentStart = min(segmentStart, left)
            }
        }

        // With no solution only the running step has a time to aim at.
        let aimed: [(block: Block, target: Date)]
        if let solution {
            aimed = upcoming.compactMap { block in Self.leaveBy(block, in: solution).map { (block, $0) } }
        } else if !waiting, let end = projectedEnd(for: current) {
            aimed = [(current, end)]
        } else {
            aimed = []
        }
        let untils = RunProjection.untils(
            steps: aimed.map { block, target in
                .init(seconds: TimeInterval(TravelTimeService.shared.manualEstimateMinutes(for: block, now: now) * 60),
                      autoAdvances: autoAdvanceEligible(block), target: target)
            },
            from: start
        )

        for ((block, target), until) in zip(aimed, untils) {
            // A walk being measured counts down to its turnaround first, and
            // to the time to be home once that has gone by.
            if block === current, !waiting, block.kind == .walk, WalkTracker.shared.isActive,
               WalkTracker.shared.phase != .returning,
               let turnaround = WalkTracker.shared.activityTarget, turnaround < until {
                steps.append(step(block, label: "Turn back by", target: turnaround, until: turnaround))
            }
            steps.append(step(block, label: Self.shownLabel(for: block, isLast: block.order >= blocks.count - 1),
                              target: target, until: until))
        }
        guard !steps.isEmpty else { return nil }

        let passed = steps.prefix { $0.until <= now }.count
        if passed > 0 { segmentStart = steps[passed - 1].until }
        return ShownTimeline(segmentStart: segmentStart, isWaiting: waiting && passed == 0,
                             steps: Array(steps.dropFirst(passed)))
    }

    /// The Live Activity's plate for `steps.first`, on show since `since`,
    /// carrying the steps after it.
    private func plate(_ steps: ArraySlice<OnTimeShownStep>, since: Date, isWaiting: Bool = false,
                       plan p: Plan) -> OnTimeActivityAttributes.ContentState? {
        guard let head = steps.first, blocks.indices.contains(head.index) else { return nil }
        return .init(
            planName: p.name,
            blockName: head.name,
            blockIndex: head.index,
            totalBlocks: blocks.count,
            targetLeaveBy: head.target,
            segmentStart: since,
            isFlex: blocks[head.index].kind.isOpenDuration,
            symbol: head.symbol,
            isWaiting: isWaiting,
            targetLabel: head.targetLabel + " ",
            until: head.until,
            later: Array(steps.dropFirst())
        )
    }

    /// Every moment from now on at which the Live Activity has to change
    /// with nobody touching the phone, and what it has to change to.
    ///
    /// The app is suspended for most of a run, so it cannot make these
    /// changes, and the plate can only make the first of them by itself: it
    /// re-renders once, at its stale date. `PiSchedule` hands this list to
    /// the Pi, which delivers each plate by push at the moment the one before
    /// it is left, and ends the activity when the last one is.
    private func projectedActivitySteps(_ timeline: ShownTimeline?, plan p: Plan) -> [PiSchedule.RunStep] {
        guard let steps = timeline?.steps, let last = steps.last else { return [] }
        var changes: [PiSchedule.RunStep] = steps.indices.dropFirst().compactMap { offset in
            let at = steps[offset - 1].until
            return plate(steps[offset...], since: at, plan: p).map { .init(fireAt: at, state: $0, endsRun: false) }
        }
        if var finished = plate(steps.suffix(1), since: last.until, plan: p) {
            finished.isFinished = true
            changes.append(.init(fireAt: last.until, state: finished, endsRun: true))
        }
        return changes
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
                await LiveActivityManager.end(planId: planId)
                Notifications.shared.cancelRunNotifications(planId: planId)
            }
            // Self-retire so an unattended completion doesn't leave a dead
            // engine (and its whole Run/Plan/Block graph) in the store
            // until a RunView for this exact run happens to appear.
            RunEngineStore.shared.retire(run)
            PiSchedule.clearRun(planId: planId)
            return
        }

        let timeline = shownTimeline()
        lastPushedShownCount = timeline?.steps.count ?? -1
        PiSchedule.publishRun(planId: planId, steps: projectedActivitySteps(timeline, plan: p))

        if !isWaitingToStart, let sol = currentSolution {
            Notifications.shared.scheduleRunNotifications(for: p, solution: sol)
        }

        guard let timeline else { return }
        guard let state = plate(timeline.steps[...], since: timeline.segmentStart,
                                isWaiting: timeline.isWaiting, plan: p) else {
            // Every step's time has gone by with the run still open. The
            // surfaces never say so: the activity goes, and LiveRunPage is
            // where the run is finished by hand.
            Task { await LiveActivityManager.end(planId: planId) }
            return
        }
        Task {
            // Update in place whenever this plan already has a live
            // activity — see `LiveActivityManager.hasActivity` doc.
            // `start` (full end-and-re-request) is only for the very
            // first sync of a run.
            if LiveActivityManager.hasActivity(planId: planId) {
                await LiveActivityManager.update(planId: planId, state: state)
                return
            }
            switch await LiveActivityManager.start(planId: planId, state: state) {
            case .started: break
            case .activitiesDisabled: self.showingActivitiesDisabledAlert = true
            case .failed(let message): self.startFailureMessage = message
            }
        }
    }
}
