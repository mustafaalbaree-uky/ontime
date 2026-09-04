import Foundation
import SwiftData

/// Turns a `ScheduledRoutine` into today's actual times, and materializes a
/// `Run` once its arm window has opened.
///
/// **The timeline is absolute.** Everything below is derived from the
/// routine's anchor time and the current step durations — never from the
/// moment the user tapped something. If the arm moment was 5:14 PM and the
/// app isn't opened until 5:29, the run is fifteen minutes in, not starting
/// fresh. That is the whole design: iOS gives no way to run code at an exact
/// wall-clock time in the background (a scheduled Live Activity needs an
/// APNs push, and there is no backend), so nothing *runs* at the arm moment.
/// The state only has to be reconstructible afterwards, and it is, because
/// it's a pure function of the clock.
///
/// `RunEngine` already cooperates with this: `naturalStart` derives step 1's
/// start from the deadline backwards ignoring `run.startedAt` entirely, and
/// `reconcile()` fast-forwards through any block whose boundary has already
/// passed. Backdating `run.startedAt` is therefore enough — the engine
/// catches itself up on the first tick.
@MainActor
enum ScheduleService {

    /// One resolved occurrence of a routine. All three are wall-clock.
    struct Occurrence: Equatable {
        /// When the routine must be *finished* by.
        let deadline: Date
        /// When step 1 has to begin for the deadline to hold.
        let mustStartAt: Date
        /// When the routine wakes up and starts showing a countdown —
        /// `armLeadMinutes` before `mustStartAt`.
        let armAt: Date

        func isArmed(at now: Date) -> Bool { now >= armAt }
    }

    // MARK: - Deriving times

    /// The durations `Solver` should schedule against, resolved the same
    /// way every other scheduling site resolves them:
    /// `TravelTimeService.manualEstimateMinutes` is the one precedence
    /// chain (fresh live ETA, then override, then learned, then stale
    /// resolved, then default). A hand-rolled "drive prefers
    /// resolvedMinutes" branch used to live here as a second copy of that
    /// rule, which is exactly the class of drift the chain's history
    /// documents.
    static func durations(for blocks: [Block], now: Date = Date()) -> [BlockDuration] {
        blocks.map { block in
            if block.kind.isOpenDuration { return .flex }
            let minutes = TravelTimeService.shared.manualEstimateMinutes(for: block, now: now)
            return .known(TimeInterval(minutes * 60))
        }
    }

    /// The next occurrence at or after `now`, or nil if the routine is
    /// disabled or has no eligible weekday in the next week.
    ///
    /// Scans forward a full 7 days rather than assuming "today or tomorrow":
    /// a routine set to Fridays only, asked on a Saturday, is six days out.
    ///
    /// `requiringFutureArm` additionally skips an occurrence whose arm
    /// moment has already gone by. Callers that *display* the schedule want
    /// today's occurrence even once it has armed (that's the banner you're
    /// looking at); the alarm scheduler does not, because there is nothing
    /// left to notify about on a window that already opened — see
    /// `refreshArmAlarms`.
    static func nextOccurrence(for routine: ScheduledRoutine,
                               now: Date = Date(),
                               calendar: Calendar = .current,
                               requiringFutureArm: Bool = false) -> Occurrence? {
        guard routine.isEnabled else { return nil }

        let weekdays = routine.weekdays
        guard !weekdays.isEmpty else { return nil }

        let blocks = routine.orderedBlocks
        let durs = durations(for: blocks, now: now)

        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            guard weekdays.contains(calendar.component(.weekday, from: day)) else { continue }
            guard !routine.isSkipped(on: day, calendar: calendar) else { continue }

            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = routine.anchorHour
            comps.minute = routine.anchorMinute
            guard let deadline = calendar.date(from: comps) else { continue }

            // Today's slot may already be gone. Only the deadline itself
            // passing disqualifies it — a *start* time in the past just
            // means the routine is late, which is a real state worth
            // showing, not a reason to skip to next week. Same rule
            // `DeadlineResolver` documents.
            guard deadline > now else { continue }

            let mustStartAt: Date
            if blocks.isEmpty {
                mustStartAt = deadline
            } else if let solution = try? Solver.solve(
                SolverInput(durations: durs, deadline: deadline, start: nil, pinnedFlex: nil)
            ) {
                mustStartAt = solution.start
            } else {
                // An open duration step makes the start underdetermined,
                // but the *latest* possible start (zero flex left) is still
                // well defined: deadline minus every known duration. That
                // is what the arm window should key on — falling back to
                // the deadline itself armed such routines with no lead over
                // their fixed steps at all.
                let zeroFlex = durs.map { $0 == BlockDuration.flex ? BlockDuration.known(0) : $0 }
                if let solution = try? Solver.solve(
                    SolverInput(durations: zeroFlex, deadline: deadline, start: nil, pinnedFlex: nil)
                ) {
                    mustStartAt = solution.start
                } else {
                    mustStartAt = deadline
                }
            }

            let armAt = mustStartAt.addingTimeInterval(TimeInterval(-routine.armLeadMinutes * 60))
            if requiringFutureArm && armAt <= now { continue }
            return Occurrence(deadline: deadline, mustStartAt: mustStartAt, armAt: armAt)
        }

        return nil
    }

    // MARK: - Arming

    /// Materializes a `Run` for every routine whose arm window has opened
    /// and that hasn't already armed today. Safe to call as often as you
    /// like — `lastArmedDay` makes it idempotent per day, which matters
    /// because this runs on every foreground.
    ///
    /// Returns the runs it started, newest first, for a caller that wants to
    /// present one.
    /// The one entry point for "catch up now": arms whatever is due, then
    /// rebuilds the pending alarm chains. The three call sites (foreground,
    /// launch, background task) used to hand-sequence the pair themselves
    /// while `armDueRoutines` *also* refreshed internally, so every arming
    /// foreground rebuilt the alarms twice.
    static func catchUp(in context: ModelContext,
                        now: Date = Date(),
                        calendar: Calendar = .current) {
        armDueRoutines(in: context, now: now, calendar: calendar)
        refreshArmAlarms(in: context, now: now, calendar: calendar)
    }

    @discardableResult
    static func armDueRoutines(in context: ModelContext,
                               now: Date = Date(),
                               calendar: Calendar = .current) -> [Run] {
        let descriptor = FetchDescriptor<ScheduledRoutine>(
            predicate: #Predicate { $0.isEnabled }
        )
        let routines: [ScheduledRoutine]
        do {
            routines = try context.fetch(descriptor)
        } catch {
            // Returning [] would be indistinguishable from "nothing due";
            // at least leave a trace that arming was skipped.
            print("armDueRoutines: routine fetch failed (\(error)); arming skipped this pass")
            return []
        }

        var started: [Run] = []
        for routine in routines {
            guard let occurrence = nextOccurrence(for: routine, now: now, calendar: calendar),
                  occurrence.isArmed(at: now),
                  !hasArmed(routine, for: occurrence, calendar: calendar),
                  !routine.orderedBlocks.isEmpty
            else { continue }

            if let run = arm(routine, occurrence: occurrence, in: context, calendar: calendar) {
                started.append(run)
            }
        }
        return started
    }

    /// Idempotence is keyed on the *occurrence's* day (its deadline), not
    /// on the day the arming happened. Comparing `lastArmedDay` against
    /// "today" double-armed any routine whose arm window straddled
    /// midnight: armed at 23:00 it stamped yesterday, and a foreground at
    /// 00:05 saw a different day, the same 00:30 occurrence still pending,
    /// and armed a second run for it.
    private static func hasArmed(_ routine: ScheduledRoutine,
                                 for occurrence: Occurrence,
                                 calendar: Calendar) -> Bool {
        guard let last = routine.lastArmedDay else { return false }
        return calendar.isDate(last, inSameDayAs: occurrence.deadline)
    }

    /// Builds the run. `startedAt` is backdated to the arm moment so the
    /// engine's own reconcile puts the run exactly where the clock says it
    /// should be, rather than restarting the countdown from this instant.
    ///
    /// Note the run is created *waiting to start* — the arm window sits
    /// entirely before step 1 begins, so there is normally nothing to fast
    /// forward through. Backdating matters when the app is opened after
    /// `mustStartAt` too: `RunEngine.checkWaitTimeElapsed` then begins step 1
    /// immediately and `reconcile()` walks forward from there.
    @discardableResult
    static func arm(_ routine: ScheduledRoutine,
                    occurrence: Occurrence,
                    in context: ModelContext,
                    calendar: Calendar = .current) -> Run? {
        let copies = routine.orderedBlocks.enumerated().map { index, block in
            let copy = block.copyForSpawn(order: index)
            context.insert(copy)
            return copy
        }
        guard !copies.isEmpty else { return nil }

        // `startedAt` and provenance go in through the launcher so the run
        // is *born* backdated — the engine computes its first solution and
        // pushes its first Live Activity inside `RunLauncher.start`, and a
        // backdate applied afterwards left that first push spanning from
        // "now" instead of the arm moment.
        let run = RunLauncher.start(
            deadline: occurrence.deadline,
            name: routine.name,
            blocks: copies,
            in: context,
            startedAt: occurrence.armAt,
            routine: routine
        )
        // Stamped from the occurrence's own deadline, never from the clock
        // — see `hasArmed(_:for:calendar:)`.
        routine.lastArmedDay = calendar.startOfDay(for: occurrence.deadline)
        return run
    }

    /// Arms a routine right now, on purpose, ignoring `lastArmedDay` and
    /// today's skip.
    ///
    /// This is the way back from a cancelled run. Cancelling a routine's run
    /// deliberately does *not* re-arm it — a run that reappeared the moment
    /// you stopped it would be worse than one that stayed gone — but until
    /// this existed there was no way back at all: `lastArmedDay` was stamped,
    /// so the routine was finished for the day and the only remedy was to
    /// wait for tomorrow.
    ///
    /// Returns the run already open for this routine when there is one,
    /// rather than minting a second one against the same routine.
    @discardableResult
    static func armNow(_ routine: ScheduledRoutine,
                       in context: ModelContext,
                       now: Date = Date(),
                       calendar: Calendar = .current) -> Run? {
        if let existing = openRun(for: routine, in: context) { return existing }
        guard !routine.orderedBlocks.isEmpty else { return nil }

        routine.unskip(on: now, calendar: calendar)
        routine.lastArmedDay = nil
        guard let occurrence = nextOccurrence(for: routine, now: now, calendar: calendar) else { return nil }

        // Backdated to `armAt` like any other arming, so a routine started
        // by hand inside its own window lands on the same remaining time a
        // routine that armed itself would have. Starting one *before* its
        // window opens would backdate into the future, which reads as a run
        // that has not begun; the arm moment is clamped to now for that case.
        let clamped = Occurrence(deadline: occurrence.deadline,
                                 mustStartAt: occurrence.mustStartAt,
                                 armAt: min(occurrence.armAt, now))
        let run = arm(routine, occurrence: clamped, in: context, calendar: calendar)
        refreshArmAlarms(in: context, now: now, calendar: calendar)
        return run
    }

    /// The open run this routine spawned, if one is live.
    static func openRun(for routine: ScheduledRoutine, in context: ModelContext) -> Run? {
        let descriptor = FetchDescriptor<Run>(predicate: #Predicate<Run> { $0.finishedAt == nil })
        guard let runs = try? context.fetch(descriptor) else { return nil }
        let key = routine.uuid
        return runs.first { $0.plan?.routine?.uuid == key }
    }

    /// True when this routine has already armed the occurrence it is
    /// currently pointed at — so "Active now" would be a lie if the run it
    /// armed has since been cancelled.
    static func hasArmed(_ routine: ScheduledRoutine,
                         occurrence: Occurrence,
                         calendar: Calendar = .current) -> Bool {
        hasArmed(routine, for: occurrence, calendar: calendar)
    }

    /// Every routine's live run, resynced. Called after any edit made in the
    /// routines list, since a `Form` writes straight through to the model
    /// and there is no single "saved" moment to hook.
    static func syncAllLiveRuns(in context: ModelContext, calendar: Calendar = .current) {
        guard let routines = try? context.fetch(FetchDescriptor<ScheduledRoutine>()) else { return }
        for routine in routines {
            syncLiveRuns(for: routine, in: context, calendar: calendar)
        }
    }

    /// Pushes an edit made to a `ScheduledRoutine` onto the run it already
    /// armed.
    ///
    /// A routine's blocks are *copies* (`Block.copyForSpawn`), so nothing
    /// about an armed run tracks the routine it came from. That is right for
    /// the steps — a run half way through its sequence cannot have rows
    /// swapped out from under it — and wrong for the anchor time, which is
    /// the one number the whole app is built around: changing "be done by
    /// 12:50" to "be done by 1:10" while the routine was live left the
    /// countdown on screen still working toward 12:50, with no indication
    /// that the edit had not taken.
    ///
    /// The new deadline is the new anchor applied to the *run's own day*,
    /// not `nextOccurrence` — an anchor moved to a time that has already
    /// passed would otherwise re-point a run in progress at tomorrow.
    @discardableResult
    static func syncLiveRuns(for routine: ScheduledRoutine,
                             in context: ModelContext,
                             calendar: Calendar = .current) -> Bool {
        guard let run = openRun(for: routine, in: context), let plan = run.plan else { return false }

        var changed = false

        var comps = calendar.dateComponents([.year, .month, .day], from: plan.deadline)
        comps.hour = routine.anchorHour
        comps.minute = routine.anchorMinute
        comps.second = 0
        if let newDeadline = calendar.date(from: comps), newDeadline != plan.deadline {
            plan.deadline = newDeadline
            changed = true
        }

        let name = routine.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, plan.name != name {
            plan.name = name
            changed = true
        }

        guard changed else { return false }
        // Straight through the live engine: recompute the solution against
        // the new deadline and re-push the Live Activity, so the Lock Screen
        // and the phone move together instead of the widget keeping the old
        // target until the next step boundary.
        if let engine = RunEngineStore.shared.engines[run.uuid] {
            engine.recomputeSolution()
            engine.syncLiveActivityAndNotifications()
        }
        return true
    }

    // MARK: - Alarms

    /// Schedules the guaranteed layer: a local alert per routine at its arm
    /// moment plus a chain of reminders through the arm window, carrying a
    /// "Start" action so the run can be materialized straight from the Lock
    /// Screen. Foregrounding the app and background refresh are the other
    /// two layers, and both go through `armDueRoutines` above.
    ///
    /// **`requiringFutureArm` is load-bearing.** This used to ask for the
    /// plain next occurrence and then drop it when `armAt` had passed, which
    /// meant that from the moment a routine armed until its deadline went by,
    /// every refresh left *no* pending alarm at all. Arming happens on
    /// foreground, and a refresh runs immediately after it, so the routine
    /// reliably erased its own next alarm the instant it fired — and tomorrow
    /// only got one if the app happened to be opened again after today's
    /// deadline. A daily routine could therefore notify exactly once, on the
    /// day it was created, and never again. Asking for the next occurrence
    /// whose arm moment is still ahead skips past the window already open and
    /// schedules the following day's.
    /// The total requests one refresh may schedule across every routine.
    /// iOS silently keeps only the soonest 64 pending requests app-wide,
    /// and running plans' step notifications draw on the same budget — the
    /// requests the system discards are the ones scheduled furthest out,
    /// which is the guaranteed layer failing for exactly the routines that
    /// most depend on it. Scheduling nearest arm windows first and stopping
    /// at a cap means *we* choose what gets dropped, and it is the far
    /// future, re-schedulable ones.
    private static let armAlarmBudget = 40

    static func refreshArmAlarms(in context: ModelContext,
                                 now: Date = Date(),
                                 calendar: Calendar = .current) {
        let routines: [ScheduledRoutine]
        do {
            routines = try context.fetch(FetchDescriptor<ScheduledRoutine>())
        } catch {
            // Deliberately does NOT cancel anything on a failed fetch:
            // whatever alarms are already pending are better than none.
            print("refreshArmAlarms: routine fetch failed (\(error)); keeping existing alarms")
            return
        }

        Notifications.shared.cancelAllArmAlarms()

        let occurrences = routines
            .compactMap { routine -> (ScheduledRoutine, Occurrence)? in
                guard !routine.orderedBlocks.isEmpty,
                      let occurrence = nextOccurrence(for: routine, now: now,
                                                      calendar: calendar,
                                                      requiringFutureArm: true)
                else { return nil }
                return (routine, occurrence)
            }
            .sorted { $0.1.armAt < $1.1.armAt }

        var budget = Self.armAlarmBudget
        for (routine, occurrence) in occurrences {
            let count = Notifications.armAlertTimes(from: occurrence.armAt, to: occurrence.mustStartAt).count
            guard budget >= count else { break }
            budget -= count

            Notifications.shared.scheduleArmAlarm(
                routineId: alarmKey(for: routine),
                name: routine.name,
                fireAt: occurrence.armAt,
                mustStartAt: occurrence.mustStartAt
            )
        }
    }

    /// A notification identifier has to survive a relaunch, and
    /// `persistentModelID.hashValue` does not — Swift's `Hashable` is seeded
    /// per process. The routine's persisted `uuid` is stable across
    /// launches and, unlike the name-plus-anchor key it replaces, unique
    /// per routine: two routines sharing a name and anchor time (a weekday
    /// and a weekend variant of one errand) used to collide, and the later
    /// scheduled one silently replaced the earlier one's alarm chain.
    private static func alarmKey(for routine: ScheduledRoutine) -> String {
        routine.uuid.uuidString
    }
}
