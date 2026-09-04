# Audit: run-orchestration

Subsystem: decides when a `ScheduledRoutine` arms, mints a `Plan`/`Run` (`ScheduleService`, `RunLauncher`), drives the live countdown (`RunEngine`), and reconstructs state after suspension (`RunEngineStore`, reconcile, backdated `startedAt`).
The absolute wall clock invariant is well built and mostly holds; the sharpest problems are an arm window that straddles midnight double arming, lifecycle calls that assume a single run owns shared singletons, and identity keys derived from SwiftData persistent identifiers before the first save.

Reviewed: RunEngine.swift, RunLauncher.swift, ScheduleService.swift, RunEngineStore.swift, ScheduleServiceTests.swift. Read as evidence: OnTimeApp.swift, Info.plist, RootView.swift, Notifications.swift, LiveActivityManager.swift, WalkTracker.swift, TravelTimeProvider.swift, Run/Plan/Block/ScheduledRoutine models.

---

## Pass A: mechanical review

```
ID:        run-orchestration-1
Location:  OnTime/Core/ScheduleService.swift:157
Class:     correctness
Claim:     A routine whose arm window straddles midnight arms twice for the same occurrence, once before midnight and again after.
Evidence:  hasArmedToday (lines 154 to 159) compares lastArmedDay with the calendar day of "now", while arm (line 190) stamps lastArmedDay with the day of arming, not the day of the occurrence's deadline. For a routine anchored at 00:30 with 40 minutes of steps and a 60 minute lead, armAt is 22:50 the previous evening: foregrounding at 23:00 arms and stamps yesterday; foregrounding at 00:05 finds lastArmedDay != today, nextOccurrence still returns the same 00:30 deadline (armAt 22:50 <= now), and armDueRoutines arms a second Run for the identical occurrence.
Trigger:   Any routine whose anchor time minus step durations minus armLeadMinutes crosses midnight, foregrounded on both sides of midnight.
Blast:     Two live Runs, two Live Activities, two step notification sets for one occurrence; the duplicate also survives as a second open run in the Active tab.
Confidence: high
```

```
ID:        run-orchestration-2
Location:  OnTime/Core/ScheduleService.swift:189
Class:     correctness
Claim:     run.startedAt is backdated to armAt only after RunLauncher.start has already built the RunEngine and pushed the first Live Activity with the wrong start.
Evidence:  arm (lines 182 to 189) calls RunLauncher.start, which creates the Run with startedAt Date() and calls RunEngineStore.shared.engine(for:) (RunLauncher.swift:32 to 34); RunEngine.init runs resume(), which recomputes the solution and syncs the Live Activity using the not yet backdated startedAt (activitySegmentStart, RunEngine.swift:147 to 150). Only afterwards does arm set run.startedAt = occurrence.armAt. run.plan?.routine is also assigned after the refreshPlan Task was launched.
Trigger:   Every scheduled arm where the app is opened well into the arm window.
Blast:     The first pushed activity's ring span starts at "now" instead of armAt, so its fill fraction is wrong until the next ramp bucket change forces a re push; self corrects, but the very state backdating exists to protect is briefly wrong.
Confidence: medium
```

```
ID:        run-orchestration-3
Location:  OnTime/Core/RunEngine.swift:253
Class:     correctness
Claim:     advanceStep has no isFinished guard, so a stale "Next Step" notification action on an already finished run pushes currentIndex past blocks.count and overwrites the backdated finishedAt with Date().
Evidence:  RunEngineStore.advanceRun (RunEngineStore.swift:37 to 40) finds the engine (a finished engine stays registered until retire) and calls advanceStep unconditionally. With currentIndex == blocks.count, the indices.contains guard skips the completion stamps, nextIdx becomes count + 1, currentIndex is written, and the else branch (line 292) sets run.finishedAt = Date() over the value reconcile backdated at line 243.
Trigger:   A delivered step notification tapped after the run already finished via reconcile or auto advance, before the finished screen retired the engine.
Blast:     finishedAt loses its honest backdated value and currentIndex holds an out of range number persisted to the store; low spread since finished runs are only read as "not open".
Confidence: medium
```

```
ID:        run-orchestration-4
Location:  OnTime/Services/RunEngineStore.swift:55
Class:     assumption
Claim:     Engines are keyed by run.persistentModelID and activities/notifications by the string of plan.id, but a SwiftData persistent identifier is temporary until the first save, so both keys can change under the subsystem after autosave.
Evidence:  engine(for:) keys the dictionary on run.persistentModelID at creation time (line 56, 69, 73), which for a just inserted Run is a temporary identifier; RunEngine.syncLiveActivityAndNotifications derives planId as "\(p.id)" every call (RunEngine.swift:474), and LiveActivityManager.hasActivity matches on that string. RunLauncher inserts the plan and syncs immediately (RunLauncher.swift:24 to 34), before any save. After the main context autosaves, the same objects report permanent identifiers: an engine(for:) lookup with the same Run then misses and mints a second engine (two 1 second timers driving the same rows), and a Live Activity started under the temporary planId is no longer found, so a second activity can be requested while the first stays live until the next launch's endOrphans.
Trigger:   The temporary to permanent identifier transition landing between engine creation or first activity request and a later lookup; timing depends on SwiftData autosave, which nothing here controls.
Blast:     Duplicate engines and duplicate Live Activities for one run; orphaned notification identifier sets in Notifications.scheduledIdentifiers keyed under the dead string.
Confidence: medium (the transition behavior is documented SwiftData/Core Data behavior, but I did not reproduce the miss at runtime; inferred, not verified)
```

```
ID:        run-orchestration-5
Location:  OnTime/Core/RunEngine.swift:306
Class:     correctness
Claim:     cancel() and the isFinished branch of syncLiveActivityAndNotifications call WalkTracker.shared.end() unconditionally, so ending any run kills a different run's active walk.
Evidence:  Line 306 (cancel) and line 445 (isFinished branch) call WalkTracker.shared.end() with no check that this run's current block is a walk. WalkTracker is a singleton with one homeBy, one alarm set, and one isActive flag; end() stops location updates and cancels the turnaround/heads up/late alarms (WalkTracker.swift:158 to 169). The store supports multiple concurrent engines by design (RunEngineStore doc, lines 4 to 8).
Trigger:   Two runs open at once, one mid walk; the other is cancelled or completes.
Blast:     The walking run silently loses GPS tracking and, worse, its already armed turnaround alarm, which is the one layer documented as guaranteed; the walk screen keeps rendering but nothing is measuring or protecting the be back by time.
Confidence: medium
```

```
ID:        run-orchestration-6
Location:  OnTime/Core/ScheduleService.swift:105
Class:     boundary
Claim:     A scheduled routine containing a flex or walk block arms into a run that never starts on its own and shows no Live Activity during the wait phase.
Evidence:  nextOccurrence falls back to mustStartAt = deadline when the solver is underdetermined (lines 102 to 107). The armed run is created waiting to start, but RunEngine.naturalStart returns nil for any plan containing an open duration block (RunEngine.swift:67 to 68), so checkWaitTimeElapsed (line 166) never fires, and syncLiveActivityAndNotifications computes target = nil while waiting (line 468), so the `if let block, let target` at line 473 never requests an activity and no step notifications are scheduled (line 458 requires !isWaitingToStart). ScheduledRoutineEditor renders .flex and .walk template rows (ScheduledRoutineEditor.swift:197, 201), so such routines are constructible.
Trigger:   Arming any routine whose steps include a flex or walk block.
Blast:     The only surfaces are the arm notification chain and the in app banner; the countdown, auto start at the must start moment, and lock screen presence all silently vanish for exactly the routines with the most timing risk.
Confidence: medium
```

```
ID:        run-orchestration-7
Location:  OnTime/Services/RunEngineStore.swift:66
Class:     error-handling
Claim:     The no context fallback in engine(for:) is an unreachable by assumption path that, if ever reached in release, either crashes on try! or silently splits writes into a second store.
Evidence:  Lines 66 to 71: after assertionFailure (a no op in release), it builds ModelContext(try! ModelContainer(for: Schema(Schema0.models))), a brand new container on the default store URL, not the named "OnTimeStore" configuration OnTimeApp opens (OnTimeApp.swift:22). An engine built on it would insert DurationSamples into a store nothing else reads.
Trigger:   engine(for:) called before configure with a Run that was never inserted; believed impossible today, which is exactly why the fallback would go unnoticed if a new call site broke the assumption.
Blast:     Crash (container open failure under try!) or silent data divergence; either way invisible until long after the call site regression.
Confidence: medium
```

```
ID:        run-orchestration-8
Location:  OnTime/Services/RunEngineStore.swift:82
Class:     correctness
Claim:     cancel(_ run:) on a run with no registered engine constructs and resumes a full engine just to cancel it, and the enqueued activity start Task can race the cancel's end Task.
Evidence:  `engines[run.persistentModelID] ?? engine(for: run)`: engine(for:) runs RunEngine.init -> resume() -> syncLiveActivityAndNotifications, which enqueues an unstructured Task that may request a Live Activity; cancel() then enqueues LiveActivityManager.end in its own Task. If the start Task executes after the end Task, a Live Activity for a cancelled run survives until the next launch's endOrphans sweep.
Trigger:   Cancelling a run whose engine was already retired or never registered (both Tasks land on the MainActor, so ordering is usually FIFO, which is why this is rare).
Blast:     One stale lock screen countdown until next app launch.
Confidence: low
```

```
ID:        run-orchestration-9
Location:  OnTime/Core/ScheduleService.swift:47
Class:     enhancement
Claim:     durations(for:) hand rolls the "drive prefers resolvedMinutes" rule that manualEstimateMinutes already implements, creating a second copy of the precedence chain that can drift.
Evidence:  Lines 47 to 49 check `block.kind == .drive && block.resolvedMinutes > 0` before calling TravelTimeService.shared.manualEstimateMinutes, but that function performs the identical check first (TravelTimeProvider.swift:187 to 189). The branch is redundant today; it becomes a divergence the next time the estimate chain's ordering changes.
Trigger:   Any future edit to the estimate precedence in TravelTimeProvider.
Blast:     ScheduleService quietly schedules against a different duration than every other caller, precisely the class of bug the CLAUDE.md history documents for manualEstimateMinutes.
Confidence: high
```

```
ID:        run-orchestration-10
Location:  OnTime/Core/RunEngine.swift:253
Class:     enhancement
Claim:     advanceStep's `auto:` parameter is never passed true by any caller, so the DurationSample skip branch is dead code.
Evidence:  A repo wide grep for "advanceStep(auto" matches only the definition; reconcile stamps blocks directly rather than calling advanceStep, and RunView/RunEngineStore call it with the default.
Trigger:   Always; the branch simply never runs.
Blast:     None functionally; it misleads a reader into thinking auto advances flow through this method.
Confidence: high
```

```
ID:        run-orchestration-11
Location:  OnTime/Core/ScheduleService.swift:148
Class:     enhancement
Claim:     armDueRoutines' internal refreshArmAlarms call is redundant with both external call sites, so alarms are rebuilt twice on every arming foreground.
Evidence:  Lines 148 to 150 refresh when any run started; RootView.armScheduledRoutines (RootView.swift:44 to 45) and the BGTask handler (OnTimeApp.swift:92 to 93) each call refreshArmAlarms unconditionally right after armDueRoutines.
Trigger:   Every foreground or background refresh that arms a routine.
Blast:     Double cancelAllArmAlarms plus double reschedule, including the async pending request sweep; harmless today because the sweep filters against the live identifier set, but it doubles the surface of that race.
Confidence: high
```

```
ID:        run-orchestration-12
Location:  OnTime/Core/RunEngine.swift:132
Class:     enhancement
Claim:     tick() runs recomputeSolution twice on every push tick, and the waiting phase solves the plan up to three extra times per tick through repeated naturalStart accesses.
Evidence:  recomputeSolution at line 132, again at line 139 inside the push branch; naturalStart (a full Solver.solve) is computed separately by checkWaitTimeElapsed (line 166), rampBucket (line 155), and syncLiveActivityAndNotifications (line 468) within one tick.
Trigger:   Every second of a running or waiting run.
Blast:     Wasted CPU only; the solver is small, so this is efficiency, not correctness.
Confidence: high
```

```
ID:        run-orchestration-13
Location:  OnTime/Core/ScheduleService.swift:190
Class:     correctness
Claim:     arm() stamps lastArmedDay from Date() rather than the injected now, so the injected clock the rest of the file honors is silently ignored at the one point that gates idempotence.
Evidence:  `routine.lastArmedDay = calendar.startOfDay(for: Date())` at line 190, while armDueRoutines, nextOccurrence and hasArmedToday all thread a `now` parameter for testability.
Trigger:   Any test or replay that drives armDueRoutines with a simulated now; production behavior matches only because now == Date() there.
Blast:     Makes the arm path untestable with a controlled clock (see run-orchestration-21) and would misdate the idempotence stamp in any future replay/catch up caller.
Confidence: high
```

---

## Pass B: structural audit

### 1. Boundaries

- **ScheduledRoutine -> Occurrence** (ScheduleService.swift:66 to 115). Validated: isEnabled, non empty weekdays, skipped days, deadline strictly future. Assumed: anchorHour/anchorMinute are sane (nothing here range checks them; a bad value makes calendar.date(from:) produce an odd date or nil and the occurrence is silently skipped for that day) and armLeadMinutes is non negative (a negative lead would place armAt after mustStartAt; armAlertTimes degrades to a single alert, so this fails soft). Solver failure falls back to mustStartAt = deadline, which is deliberate but produces the silent flex routine behavior in run-orchestration-6.
- **Occurrence -> Run** (ScheduleService.arm, lines 171 to 192). Blocks are copied via copyForSpawn (exhaustiveness is a documented invariant tested in PlanTests, not here) and renumbered inside RunLauncher. startedAt is backdated, but after the engine already observed the wrong value (run-orchestration-2).
- **Notification action -> engine** (RunEngineStore.swift:25 to 40). The planId string in userInfo is matched against live engines by recomputing "\(p.id)"; no validation, and a mismatch (stale id, retired engine) is a silent no op. That is the right failure mode, but combined with run-orchestration-4 a mismatch can occur for a live run.
- **BGAppRefreshTask -> ScheduleService** (OnTimeApp.swift:83 to 98, as evidence). The task hands ScheduleService a throwaway ModelContext with autosave off and saves once, immediately after arming. See run-orchestration-17 for what leaks across that seam.
- **Persisted resolvedMinutes -> armAt**: see run-orchestration-18.

```
ID:        run-orchestration-18
Location:  OnTime/Core/ScheduleService.swift:47
Class:     boundary
Claim:     durations(for:) trusts a drive block's persisted resolvedMinutes with no staleness bound when deriving mustStartAt and armAt for a future occurrence.
Evidence:  Line 47 uses block.resolvedMinutes whenever it is > 0; for a routine's template blocks that value is whatever the last resolve wrote, possibly days old and fetched at a different time of day, while the live ETA layer and its freshness reporting (TravelTimeService.source(for:)/resolvedAt) are bypassed for scheduling the alarm chain.
Trigger:   A routine with a drive step whose traffic conditions differ between when the ETA was last resolved and the actual departure window.
Blast:     armAt and the alarm chain shift by the ETA error; bounded by the arm lead, and the run itself re resolves on arm, so this only misplaces the warning window.
Confidence: low
```

### 2. Error handling

- Handled well: LiveActivityStartOutcome is surfaced to the UI (RunEngine.swift:519 to 523) instead of being swallowed; the isFinished branch reliably tears down activity, notifications, and the timer even with no view attached (RunEngine.swift:444 to 455).
- Swallowed: every fetch in this subsystem is `try?` with an empty default: armDueRoutines (ScheduleService.swift:133), refreshArmAlarms (line 217), RunLauncher.startOrResume (line 55), RootView.resumeOpenRuns. See run-orchestration-19. Solver failures are `try?` in three places (RunEngine.swift:73, 370; ScheduleService.swift:98) with reasonable fallbacks, but no path ever records that a solve failed, so a malformed plan (two flex blocks, for instance) degrades every leave by time to projectedEnd with no signal anywhere.
- Unreachable by assumption: the RunEngineStore fallback container (run-orchestration-7); the BG task's `try? context.save()` (OnTimeApp.swift:94), where a save failure silently discards the freshly armed run.

```
ID:        run-orchestration-19
Location:  OnTime/Core/ScheduleService.swift:217
Class:     error-handling
Claim:     A failed routine fetch in refreshArmAlarms cancels every pending arm alarm and schedules nothing back.
Evidence:  Line 217 guards `try? context.fetch` and returns on nil, but line 219 (cancelAllArmAlarms) runs before the loop only in the success path; on fetch failure the function returns early before cancelling, which is safe. The real hole is armDueRoutines (line 133): a fetch failure returns [] silently, so a transient store error at foreground time means routines simply do not arm, indistinguishable from "nothing due", with no log or retry.
Trigger:   Any ModelContext fetch error at foreground or BG refresh time (rare; store corruption or migration edge).
Blast:     Missed arming for that foreground; the notification layer still fires, so the user sees the alarm but no armed run until the next successful foreground.
Confidence: medium
```

### 3. State and lifetime

- Outlives an operation: RunEngineStore.engines (process lifetime), each engine's 1 second Timer on the main RunLoop, Notifications.scheduledIdentifiers (in memory, plan keyed), armAlarmIdentifiers, LiveActivityManager.activities, WalkTracker's singleton state.
- Observable inconsistency: mid reconcile, blocks are stamped done one by one before run.currentIndex is written (RunEngine.swift:215 to 240); everything runs on the MainActor so no other code observes the intermediate state, but an @Observable view re render triggered by the block mutations before the index write could in principle draw one frame where a done block is still "current". Self heals next frame.
- Not cleaned up: see run-orchestration-14 and 15. Also, an armed run the user never opens stays open past its deadline forever: nothing in this subsystem ever expires or auto finishes a run whose deadline passed un-interacted with (reconcile only advances auto advance eligible blocks that have started). It accumulates in the Active tab by design, but each one also keeps a live engine and timer once anything (banner, list row) has asked for its engine.

```
ID:        run-orchestration-14
Location:  OnTime/Services/RunEngineStore.swift:94
Class:     state
Claim:     An engine whose run finishes while no view is watching stays registered in the store until a RunView for that exact run happens to show its finished screen.
Evidence:  retire is called only from RunView (RunView.swift:429, 438). The engine stops its own timer via the isFinished sync branch (RunEngine.swift:450), but the store entry, the engine, and its whole Run/Plan/Block object graph stay retained; openEngines filters them out of the UI, so nothing ever prompts retirement.
Trigger:   A run auto completes in the background or from the Active tab and the user never re opens its RunView.
Blast:     Unbounded slow growth of dead engines over the app's process lifetime; memory only, no behavior change.
Confidence: medium
```

```
ID:        run-orchestration-15
Location:  OnTime/Core/RunEngine.swift:113
Class:     state
Claim:     RunEngine has no deinit safety net for its timer, so an engine released without stopTicking leaks a repeating RunLoop timer forever.
Evidence:  The Timer closure captures self weakly (line 113), so no retain cycle, but the RunLoop retains the timer itself; only stopTicking invalidates it. Today every removal path (cancel, retire) stops first, so this is a latent hazard, not a live leak.
Trigger:   Any future code path that drops an engine reference without calling stopTicking.
Blast:     A permanent once per second no op closure per leaked engine.
Confidence: low
```

```
ID:        run-orchestration-17
Location:  OnTime/Core/RunLauncher.swift:34
Class:     state
Claim:     A run armed from the BGAppRefreshTask lives in a throwaway context with autosave off, so its engine's subsequent mutations never persist, and later DurationSample inserts can cross contexts.
Evidence:  The BG handler builds ModelContext(container) (OnTimeApp.swift:91, hand made contexts default to autosave off) and saves once right after armDueRoutines; RunLauncher.start registers the engine immediately (line 34). The engine's later writes to run/blocks land in that abandoned context. If RunEngineStore was configured (or is configured on the next foreground), engine.modelContext is the view context while completedBlock.template belongs to the BG context, so the DurationSample insert at RunEngine.swift:262 to 266 establishes a cross context relationship. The wall clock design masks most of the persistence loss (reconcile reconstructs from startedAt), which is why this has stayed invisible.
Trigger:   iOS actually granting the BG refresh during an arm window (documented as "may never fire"), followed by the user interacting with that run.
Blast:     Unsaved run progress (self healing) and a possible save error or crash on the cross context relationship; also a second engine for the same run once the foreground fetches it as a different instance (see run-orchestration-4).
Confidence: low (mechanism inferred from SwiftData context semantics; whether scene connection occurs during a BG launch was not verified on device)
```

### 4. Test gaps

The occurrence math is genuinely well tested (derivation, roll forward, requiringFutureArm regression, skip days, arm window, alert chain shape). What a reader would expect and does not find:

```
ID:        run-orchestration-20
Location:  OnTime/Core/RunEngine.swift:203
Class:     test-gap
Claim:     reconcile, the mechanism the whole wall clock invariant depends on after suspension, has zero test coverage.
Evidence:  OnTimeTests contains no RunEngine tests at all (DeadlineResolver, Estimator, Plan, ScheduleService, Solver, TravelTime, Walk only). The catch up walk (backdated boundaries, stopping at a non eligible block, pinning flex on entry, finishing with a backdated finishedAt), checkWaitTimeElapsed's backdated begin, and advanceStep's sample logging are all untested behaviors, each documented in prose as a past bug or a load bearing property.
Trigger:   Any refactor of the reconcile loop or the eligibility predicate.
Blast:     The exact regression class the comments warn about (interaction relative timelines) would ship silently; nothing red would appear in CI.
Confidence: high
```

```
ID:        run-orchestration-21
Location:  OnTime/Core/ScheduleService.swift:127
Class:     test-gap
Claim:     armDueRoutines and arm, the materialization half of ScheduleService, are untested: per day idempotence, startedAt backdating, block copying, and the midnight straddle have no coverage.
Evidence:  ScheduleServiceTests exercises only nextOccurrence, Occurrence.isArmed, and Notifications.armAlertTimes; nothing constructs a ModelContext and calls armDueRoutines. The Date() call at line 190 (run-orchestration-13) currently makes a controlled clock test of idempotence impossible without change.
Trigger:   Any change to the arming gate or RunLauncher wiring.
Blast:     Double arm or never arm regressions (including run-orchestration-1, which a midnight test would have caught) reach the device.
Confidence: high
```

```
ID:        run-orchestration-22
Location:  OnTime/Core/ScheduleService.swift:243
Class:     test-gap
Claim:     alarmKey's stability and collision behavior are untested despite the comment documenting a past identifier stability bug.
Evidence:  No test asserts that alarmKey is stable across processes, that it sanitizes names, or what happens when two routines collide on (name, anchorHour, anchorMinute).
Trigger:   Any edit to the key derivation.
Blast:     The exact per launch identifier churn the comment describes, back again with nothing to catch it.
Confidence: medium
```

Checked for tests asserting implementation rather than behavior: armAlertsCoverTheWindowAndEndAtTheStartTime asserts the concrete count 7 and the concrete cadence, which couples to armReminderMinutes and maxArmAlerts constants; borderline, but the cadence is user visible behavior, so I do not flag it. No other implementation coupled assertions found.

### 5. Load bearing assumptions

```
ID:        run-orchestration-16
Location:  OnTime/Core/ScheduleService.swift:243
Class:     assumption
Claim:     alarmKey assumes two routines never share a lowercased name and anchor time; when they do, the later scheduled routine's alarm chain silently replaces the earlier one's.
Evidence:  The key is name plus anchorHour plus anchorMinute (lines 243 to 249); scheduleArmAlarm builds identifiers "prefix key index", and UNUserNotificationCenter replaces a request with an existing identifier. Two same named routines at the same anchor with different weekdays or steps (a weekday and a weekend variant of the same errand) have different armAt times but identical identifiers.
Trigger:   Creating two routines that agree on name and anchor time; nothing prevents or warns about it.
Blast:     One of the two routines never fires its guaranteed notification layer; foreground arming still works, so the failure looks like "the alarm sometimes does not come".
Confidence: medium
```

```
ID:        run-orchestration-23
Location:  OnTime/Core/RunEngine.swift:380
Class:     assumption
Claim:     schedule(for:), endsRunAtTarget, and targetLabel all assume block.order values are contiguous 0..n-1 and equal to solver indices, enforced only by the renumber call at run creation.
Evidence:  schedule(for:) matches solution rows by `$0.index == block.order` (line 380); endsRunAtTarget and targetLabel compare `block.order >= blocks.count - 1` (lines 428, 438). RunLauncher renumbers once at start (RunLauncher.swift:30); any mid run block insertion or deletion that skips renumber (QuickBlockEditorSheet edits plan blocks during a run) leaves gaps, after which schedule(for:) silently returns nil and leaveByDate degrades to projectedEnd for every affected block, exactly the interaction relative drift the file's own comment (lines 388 to 395) says was a real bug.
Trigger:   Any editing path that mutates a live plan's blocks without calling Plan.renumber().
Blast:     Per step targets, notifications, and the Live Activity quietly switch from deadline anchored to start anchored times; no error anywhere.
Confidence: medium
```

Other assumptions verified and found sound: the layered arming (notification guaranteed, foreground common, BG opportunistic) genuinely depends on nothing from the BG layer; Info.plist carries the matching BGTaskSchedulerPermittedIdentifiers entry and both background modes; double arming between RootView's .task and the scenePhase handler is prevented by MainActor serialization plus the synchronous lastArmedDay write; RunLauncher.start's `block.routine = nil` is safe for both current callers because ScheduleService passes fresh copies and NowView passes scratch blocks; the weekday scan (0...7 offsets, injected calendar and timezone) is correct including the Friday from Saturday case, and DST anomalies fail soft through calendar.date(from:).

Classes of problem searched with a clean result: no double launch race inside a single context (armDueRoutines is idempotent per day and MainActor serialized); no interaction relative time was found feeding the occurrence math itself (nextOccurrence is a pure function of now, the anchor, and durations); no orderedBlocks versus blocks misuse inside the four files (every read goes through orderedBlocks); no notification identifier reuse between the arm alarm namespace and the run step namespace.

**Out of path observation, for the system-services auditor:** RootView.resumeOpenRuns with zero open runs calls Notifications.cancelAllRunNotifications, which is removeAllPendingNotificationRequests and so wipes arm alarm chains and the quick countdown alert too; refreshArmAlarms runs right after and repairs the arm alarms, but the quick countdown notification is not repaired by anything in this subsystem.

### 6. Enhancements (ranked)

```
ID:        run-orchestration-24
Location:  OnTime/Services/RunEngineStore.swift:56
Class:     enhancement
Claim:     Keying engines, activities, and notification maps on an explicit UUID attribute added to Plan and Run (a persistence-models change) would remove the entire temporary identifier hazard class.
Evidence:  Every identity in this subsystem is derived from PersistentIdentifier (RunEngineStore.swift:56, RunEngine.swift:474); run-orchestration-4 and 17 both stem from that.
Trigger:   n/a (improvement)
Blast:     n/a
Confidence: high
```

```
ID:        run-orchestration-25
Location:  OnTime/Services/RunEngineStore.swift:94
Class:     enhancement
Claim:     Let the engine ask its store to retire it from the isFinished sync branch, instead of waiting for a RunView to appear.
Evidence:  RunEngine.swift:444 to 455 already detects unattended completion and stops its own timer; one more call would close the leak in run-orchestration-14 and shrink the stale advanceStep window in run-orchestration-3.
Trigger:   n/a
Blast:     n/a
Confidence: high
```

```
ID:        run-orchestration-26
Location:  OnTime/Core/ScheduleService.swift:127
Class:     enhancement
Claim:     A single ScheduleService.catchUp(in:) that runs armDueRoutines then refreshArmAlarms would collapse the three call sites that each hand sequence the pair today.
Evidence:  RootView.swift:44 to 45, OnTimeApp.swift:92 to 93, and the internal call at ScheduleService.swift:148 all encode the same two step ritual; run-orchestration-11 exists because they drifted.
Trigger:   n/a
Blast:     n/a
Confidence: high
```

```
ID:        run-orchestration-27
Location:  OnTime/Core/RunEngine.swift:113
Class:     enhancement
Claim:     Add a tolerance to the 1 second timer and skip the walk tracker tick for engines whose current block is not a walk.
Evidence:  Line 113 creates a zero tolerance repeating timer per open run, and line 131 calls WalkTracker.shared.tick() from every engine every second regardless of block kind; tolerance of 0.1 to 0.2 seconds lets iOS coalesce wakeups across engines.
Trigger:   n/a
Blast:     n/a
Confidence: medium
```

```
ID:        run-orchestration-28
Location:  OnTime/Core/RunEngine.swift:253
Class:     enhancement
Claim:     Save the model context at step boundaries (advanceStep, reconcile index writes) so run progress survives a crash without leaning entirely on reconstruction.
Evidence:  Nothing in the engine ever saves; autosave timing is uncontrolled, and the BG arm path (run-orchestration-17) has no autosave at all. The wall clock design reconstructs auto advanced state, but manual taps on non eligible blocks are user facts the clock cannot re derive.
Trigger:   n/a
Blast:     n/a
Confidence: medium
```
