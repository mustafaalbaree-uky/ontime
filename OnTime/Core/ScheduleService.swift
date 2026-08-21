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

    /// The durations `Solver` should schedule against, resolved the same way
    /// `NowView` and `RunEngine` resolve them: a drive block prefers its
    /// live ETA, everything else goes through the estimate chain (which now
    /// includes learned duration — see `TravelTimeService.manualEstimateMinutes`).
    static func durations(for blocks: [Block], now: Date = Date()) -> [BlockDuration] {
        blocks.map { block in
            if block.kind == .flex { return .flex }
            let minutes = block.kind == .drive && block.resolvedMinutes > 0
                ? block.resolvedMinutes
                : TravelTimeService.shared.manualEstimateMinutes(for: block, now: now)
            return .known(TimeInterval(minutes * 60))
        }
    }

    /// The next occurrence at or after `now`, or nil if the routine is
    /// disabled or has no eligible weekday in the next week.
    ///
    /// Scans forward a full 7 days rather than assuming "today or tomorrow":
    /// a routine set to Fridays only, asked on a Saturday, is six days out.
    static func nextOccurrence(for routine: ScheduledRoutine,
                               now: Date = Date(),
                               calendar: Calendar = .current) -> Occurrence? {
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
                // A flex step with no start time is underdetermined — the
                // routine still has a deadline worth counting down to, so
                // fall back to it rather than dropping the occurrence.
                mustStartAt = deadline
            }

            let armAt = mustStartAt.addingTimeInterval(TimeInterval(-routine.armLeadMinutes * 60))
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
    @discardableResult
    static func armDueRoutines(in context: ModelContext,
                               now: Date = Date(),
                               calendar: Calendar = .current) -> [Run] {
        let descriptor = FetchDescriptor<ScheduledRoutine>(
            predicate: #Predicate { $0.isEnabled }
        )
        guard let routines = try? context.fetch(descriptor) else { return [] }

        var started: [Run] = []
        for routine in routines {
            guard let occurrence = nextOccurrence(for: routine, now: now, calendar: calendar),
                  occurrence.isArmed(at: now),
                  !hasArmedToday(routine, now: now, calendar: calendar),
                  !routine.orderedBlocks.isEmpty
            else { continue }

            if let run = arm(routine, occurrence: occurrence, in: context, calendar: calendar) {
                started.append(run)
            }
        }

        if !started.isEmpty {
            refreshArmAlarms(in: context, now: now, calendar: calendar)
        }
        return started
    }

    private static func hasArmedToday(_ routine: ScheduledRoutine,
                                      now: Date,
                                      calendar: Calendar) -> Bool {
        guard let last = routine.lastArmedDay else { return false }
        return calendar.isDate(last, inSameDayAs: now)
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

        let run = RunLauncher.start(
            deadline: occurrence.deadline,
            name: routine.name,
            blocks: copies,
            in: context
        )
        run.plan?.routine = routine
        run.startedAt = occurrence.armAt
        routine.lastArmedDay = calendar.startOfDay(for: Date())
        return run
    }

    // MARK: - Alarms

    /// Schedules the guaranteed layer: one local notification per routine at
    /// its arm moment, carrying a "Start" action so the run can be
    /// materialized straight from the Lock Screen. Foregrounding the app and
    /// background refresh are the other two layers, and both go through
    /// `armDueRoutines` above.
    static func refreshArmAlarms(in context: ModelContext,
                                 now: Date = Date(),
                                 calendar: Calendar = .current) {
        let descriptor = FetchDescriptor<ScheduledRoutine>()
        guard let routines = try? context.fetch(descriptor) else { return }

        Notifications.shared.cancelAllArmAlarms()
        for routine in routines {
            guard let occurrence = nextOccurrence(for: routine, now: now, calendar: calendar),
                  occurrence.armAt > now,
                  !routine.orderedBlocks.isEmpty
            else { continue }

            Notifications.shared.scheduleArmAlarm(
                routineId: "\(routine.persistentModelID.hashValue)",
                name: routine.name,
                fireAt: occurrence.armAt,
                mustStartAt: occurrence.mustStartAt
            )
        }
    }
}
