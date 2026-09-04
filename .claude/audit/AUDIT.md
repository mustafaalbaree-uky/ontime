# OnTime Codebase Audit, Phase 1 Consolidated Report

Date: 2026-08-23. Read only audit; no code was modified.
Inputs: seven subsystem reports in this directory (solver-math.md, run-orchestration.md, travel-location.md, persistence-models.md, system-services.md, ui.md, widget-shared.md). Every ID below refers to a full finding in its subsystem file, with file, line, evidence, trigger, blast, and confidence.

Totals: 121 findings in the bug classes (correctness 41, boundary 16, error-handling 12, state 15, assumption 19, test-gap 18) plus 42 enhancement items.

---

## 1. Findings that span subsystems

These appeared in two or more subsystem reports, or live in the seam between subsystems where no single agent owns them. They are listed before everything else because each one is a system property, not a local defect.

### CC-1. Solver failures are swallowed at every call site, and the invariant that would prevent them is enforced nowhere
Members: solver-math-7, solver-math-13, ui-1, ui-12, run-orchestration-6.
Every production consumer of `Solver.solve` uses `try?` (RunEngine.swift:73 and 370, ScheduleService.swift:98, NowView.swift:79), so `multipleFlexBlocks` and `underdetermined` both degrade to a nil solution with no signal anywhere. The UI neither prevents nor reports a second flex or walk block (ui-12 verified the editor and the mid run Add Step path both allow it). The consequences differ by surface and are all silent: on the Now screen, any flex or walk step makes the headline countdown fall back to the bare deadline, overstating available time by the sum of every fixed and drive duration (ui-1, live today in the app's flagship composition); mid run, a second open duration block blanks every leave by time and the Live Activity content (ui-12); a scheduled routine containing a flex or walk block arms into a run that never starts on its own and shows no Live Activity while waiting (run-orchestration-6). Three subsystems each hold a piece; no piece can see the whole failure.

### CC-2. The walk alarm arming seam can silently disarm the feature's one guaranteed layer
Members: system-services-2 and travel-location-1 (the same defect, found independently by both agents), travel-location-2.
`Notifications.armAlarm` removes the pending request for its id and then refuses a fire date in the past (Notifications.swift:127 to 128). When a walk's turnaround estimate slips into the past, the re-arm therefore deletes the previously armed future alarm and schedules nothing, so no turnaround alert fires at all, exactly when the user is already late (WalkTracker.swift:317). Separately, the returning phase "Running late" alarm is re-armed at now plus 30 seconds on every one second tick with no dedupe, so while the app is alive (which background location keeps true for the whole walk) it is perpetually deferred and never fires (WalkTracker.swift:308). Together these invert the design's safety argument: the alarms fire only if the app dies at a lucky moment.

### CC-3. Notification authorization is requested once and never consulted again
Members: system-services-6 and travel-location-12 (same defect, found independently), supported by system-services-5.
The single `requestAuthorization` result is discarded (OnTimeApp.swift:30) and no code anywhere reads notification settings afterward. One "Don't Allow", or a later revocation in system Settings, silently disables the routine arm alarms, every run step alert, and every walk alarm, with no indication anywhere in the app. Every `center.add` result is also discarded (system-services-5), and the in memory bookkeeping records requests as scheduled whether or not the system accepted them, so the code cannot tell an armed alarm from a refused one even in principle.

### CC-4. The Complete Step round trip is fragile at every hop
Members: widget-shared-6, system-services-4, widget-shared-10 and system-services-17 (same defect, found independently).
A Lock Screen or Dynamic Island "Complete Step" tap travels: LiveActivityIntent perform() in the app process, an in process NSNotification, an observer registered lazily in RunEngineStore.init, a planId string match against live engines. If the app process is dead, the observer never registers (RootView's `.task` does not run on a background intent launch) and the tap is silently lost while the intent reports success (widget-shared-6). On a cold launch from a notification action, the delegate and observer registration can race the delivery (system-services-4). The routing key "OnTimeAdvanceStepFromIntent" is an independent literal in three files across the target seam (Shared/OnTimeIntents.swift:27, RunEngineStore.swift:26, Notifications.swift:396); a typo in any one severs the path with no compile error (widget-shared-10, system-services-17).

### CC-5. UI delete affordances dangle unpaired persisted references, which later crash uncatchably
Members: persistence-models-1, 2, 3, 13, with the delete sites in ui scope (LearnedStepsView.swift:41, PlacesView.swift:121, ScheduledRoutinesView.swift:85) and ui-15's observation that deleting a place silently nulls referring blocks.
Block.template, Block/TaskTemplate origin and destination place pointers, and Plan.routine are plain optionals with no inverse relationship. Deleting a TaskTemplate, Place, or ScheduledRoutine from Settings leaves every referrer dangling, and property reads through those pointers happen on nearly every screen (`block.template?.symbol` in NowView, RunView, RunEngine, CountdownsView, ScheduledRoutineEditor). Reading a property through a dangling reference is the uncatchable "backing data could no longer be found" fatalError this codebase already documents for Run.plan; the crash recurs on every launch until the store is wiped, and the schema rebuild policy does not help because the schema still matches. The convention "targets are never deleted while referenced" is written down for Run.plan only, and the UI already violates it for the other three (persistence-models-13).

### CC-6. Identity throughout run orchestration is keyed on unstable identifiers
Members: run-orchestration-4, run-orchestration-17, system-services-11, widget-shared load bearing assumptions list.
Engines are keyed on `run.persistentModelID` and Live Activities plus notifications on the string of `plan.id`, both of which are temporary until the first save; the temporary to permanent transition can mint a duplicate engine (two timers on one run) and a duplicate Live Activity (run-orchestration-4). A run armed from the BGAppRefreshTask lives in a throwaway context with autosave off, compounding this and risking cross context relationship writes (run-orchestration-17). Cancellation across relaunches works only because the notification identifier scheme happens to be deterministic, a property enforced nowhere (system-services-11). The planId string format itself is convention repeated at every call site.

### CC-7. Resolved travel times are trusted with no age bound anywhere in the chain
Members: travel-location-9, travel-location-14, run-orchestration-18.
A drive block's persisted `resolvedMinutes` has no timestamp and outranks the user's typed override indefinitely (travel-location-9); the in memory ETA cache stores a timestamp that nothing ever reads and is never evicted, so an 8am ETA is served as "cached" at 10pm (travel-location-14); and ScheduleService derives a future occurrence's armAt from that same possibly days old `resolvedMinutes` (run-orchestration-18). Freshness is displayed in the UI but never enforced by any consumer. See also Disagreement D-1 on whether the override precedence is a bug or the design.

### CC-8. The Live Activity staleness contract is load bearing on one side and unknown on the other
Members: system-services-1, widget-shared-8, widget-shared-1.
The widget's entire after death display logic assumes every app push sets staleDate to the step target (widget-shared-8, unenforced convention). Meanwhile the app side manager filters on `activityState == .active`, which makes an activity whose staleDate has passed invisible: it is never updated, never ended, and a duplicate is requested next to it, which is likely the very symptom an earlier fix in the same file was chasing (system-services-1). And `ContentState.isFinished`, which the app sets on finish, is read by no widget view, so the designed "Done" frame is unreachable and a finished run shows a live countdown and button during the dismissal window (widget-shared-1).

### CC-9. Two defects were found independently by two agents in identical form
QuickShortcut ordering: `addShortcut` assigns `order: shortcuts.count` and delete never renumbers, reintroducing the duplicate sort key bug already diagnosed and fixed for blocks in the same file (persistence-models-5 and ui-4, NowView.swift:570). Multi element delete over a live computed array: `ScheduledRoutineEditor.delete(at:)` indexes `routine.orderedBlocks`, recomputed per access, while deleting inside the loop (persistence-models-6 and ui-5, ScheduledRoutineEditor.swift:157; ui-5 notes the same latent pattern in LearnedStepsView and PlacesView). Independent rediscovery raises confidence in both.

### CC-10. RootView's launch ordering is an unenforced contract three subsystems rely on
Members: system-services-7, run-orchestration's out of path observation, ui-20, ui-21.
`cancelAllRunNotifications` is actually `removeAllPendingNotificationRequests`: it wipes routine arm alarms too, and the only thing repairing them is that `armScheduledRoutines` runs immediately afterward in the same task (system-services-7). A failed open runs fetch at launch reads as "no open runs" and triggers that same teardown for genuinely live runs (ui-21). CountdownsView rows can race RootView's `.task` for RunEngineStore configuration, degrading through a fallback that masks any future real breakage (ui-20).

---

## 2. Ranked findings, by blast radius

Everything not absorbed into section 1, bug classes only (enhancements are in section 3). Ordering is by how far the damage spreads when it fires, not by severity label; each line is a pointer, the full finding is in the subsystem file.

### Tier 1: wide dependency, silent, or destroys data

1. **persistence-models-4** (OnTimeApp.swift:67): openStore wipes and rebuilds the store on any container open error, not only schema mismatch; a transient failure destroys all data where a retry would have succeeded. Everything depends on the store.
2. **run-orchestration-1** (ScheduleService.swift:157): a routine whose arm window straddles midnight arms twice for the same occurrence (lastArmedDay records the arming day, the occurrence is identified by the deadline's day); two live Runs, two Live Activities, two notification sets.
3. **ui-6** (FullScreenTimePicker.swift:65): Cancel does not cancel; the wheel writes through live bindings into the persisted deadline or a routine's anchor on every detent, and those values drive every countdown and the arm alarm chain.
4. **run-orchestration-5** (RunEngine.swift:306, 445): cancelling or finishing any run calls `WalkTracker.shared.end()` unconditionally, killing a different concurrent run's walk tracking and its already armed turnaround alarm.
5. **travel-location-3** (WalkTracker.swift:116): begin() never resets homeCoordinate/homeName, so a walk with no destination inherits the previous walk's home point; arrival detection, phase flip, routing, and alarm text all compute against the wrong place.
6. **travel-location-6** (LocationService.swift:187): fixes are stamped with Date() and unfiltered for age or accuracy, so a cached stale fix reads as fresh for two minutes and every "Current Location" drive ETA routes from the wrong origin.
7. **system-services-19** (Notifications.swift:170): the seven alert cap is per routine; nothing bounds the app's total pending requests against the system's limit of 64, and the requests scheduled furthest out (tomorrow's arm alarms) are the ones silently discarded.

### Tier 2: a real feature degrades or misleads, bounded to one surface

8. **run-orchestration-2** (ScheduleService.swift:189): startedAt is backdated only after the engine already pushed the first Live Activity with the wrong start; self corrects, but the state backdating exists to protect is briefly wrong.
9. **run-orchestration-3** (RunEngine.swift:253): advanceStep has no isFinished guard; a stale notification tap pushes currentIndex out of range and overwrites the backdated finishedAt.
10. **widget-shared-4** (OnTimeLiveActivity.swift:90): a wait phase target passing while suspended renders "over, waiting on you" with no button, though the app will auto start the step on next wake; misleading urgency for its whole duration.
11. **ui-7** (PlacesView.swift:125): seeding creates Home and Masjid at the stored coordinate with no hasRealLocation guard, so on a fresh install both pin to (0, 0), and no edit UI exists to fix them.
12. **ui-11** (RunView.swift:452): insertStep drops a template's origin and destination, so a drive step added mid run never resolves a live ETA and a walk step added mid run has no home coordinate.
13. **ui-3** (RunView.swift:100, CountdownsView.swift:24): user facing copy directs to the deleted "Plans" screen; the cancel dialog's reassurance is false and cancel is effectively destructive for a hand built sequence.
14. **system-services-3** (Notifications.swift:249): delivered notifications are never removed, so outdated "Starts in N min" banners stack in Notification Center during and after the run they announced.
15. **persistence-models-8, 9** (RunLauncher.swift:23, OnTimeApp.swift:127): Plans and finished Runs are never deleted, growing unboundedly, and orphan cleanup skips finished runs, a guaranteed crash for the planned Phase 4 run history feature.
16. **travel-location-5** (TravelTimeProvider.swift:240): TravelTimeService is @Observable but not @MainActor and mutates observed state plus a SwiftData model off the main actor; intermittent today, guaranteed errors on a Swift 6 migration.
17. **solver-math-4** (Estimator.swift:56): the blend weight uses raw sample count, not decayed weight, so months old observations keep near full authority over the manual prior, half contradicting the documented design.
18. **travel-location-17** (WalkTracker.swift:152): with location denied, the initial alarm arms at approximately homeBy itself and nothing revises it once suspended; the safety net fires at a useless time.
19. **run-orchestration-16** (ScheduleService.swift:243): two routines sharing a lowercased name and anchor time silently share an alarm identifier key; one of them never fires its guaranteed layer.
20. **system-services-1 companion, run-orchestration-14, 15** (RunEngineStore.swift:94, RunEngine.swift:113): engines finishing unwatched are never retired (unbounded slow growth), and the engine timer has no deinit safety net.
21. **ui-16** (ScheduledRoutinesView.swift:63): the plus button inserts an empty routine before the editor opens and no path removes it on abandonment; permanent garbage rows accumulate.
22. **ui-23** (QuickBlockEditorSheet.swift:392): every save with "Follow My Location" off inserts a new identical "Saved Location" place; the picker fills with indistinguishable entries.
23. **ui-2** (QuickBlockEditorSheet.swift:71): onChange(of: name) clears the selectedTemplate its own apply() just set, the same shape as the historical PlaceSearchField bug; the linkage confirmation UI can never render.
24. **ui-19** (ScheduledRoutineEditor.swift:149): drag reordering bypasses the "Starts At only first" rule; a mid sequence startAt block quietly corrupts the routine's derived timings.

### Tier 3: narrow trigger, cosmetic, or latent

25. **run-orchestration-13** (ScheduleService.swift:190): arm() stamps lastArmedDay from Date() instead of the injected now, breaking clock injected testability of the idempotence gate.
26. **travel-location-8** (WalkTracker.swift:361): a forced route refresh is silently skipped when a request is already in flight; the return leg briefly uses the outbound route.
27. **travel-location-11** (WalkTracker.swift:432): CLLocationManager failures are written into routeError, misattributing a GPS problem to routing.
28. **system-services-8** (Notifications.swift:225): armAlertTimes dedupes only within one second, so two alerts can fire under a minute apart at the most attention critical moment.
29. **system-services-9, 10** (LiveActivityManager.swift:91, 199): a start losing the in flight race reports .started though the winner may fail; endAll can be outrun by an in flight start, orphaning one activity.
30. **ui-13** (PlaceSearchField.swift:213): a failed MKLocalSearch resolution is silently discarded; tapping a suggestion can visibly do nothing.
31. **ui-21** covered in CC-10; **ui-14** (NowView.swift:601): armTimer silently no ops on a past target or a missing shortcut.
32. **persistence-models-7** (Place.swift:32): the current location sentinel fetch swallows errors and can insert the duplicate sentinel it exists to prevent.
33. **persistence-models-12** (Block.swift:74): unknown kindRaw/statusRaw silently coerce to .fixed/.pending; a renamed enum case reclassifies stored rows with no signal and no schema wipe.
34. **persistence-models-14** (ScheduledRoutine.swift:54): an empty weekdays set is representable and means "never occurs"; the only guard is one picker widget.
35. **run-orchestration-7** (RunEngineStore.swift:66): the unreachable fallback context either crashes on try! or silently splits writes into a second store.
36. **run-orchestration-19** (ScheduleService.swift:133): a failed routine fetch at foreground reads as "nothing due", indistinguishable from success.
37. **run-orchestration-8** (RunEngineStore.swift:82): cancelling an engineless run builds a full engine whose activity start Task can race the cancel's end Task.
38. **run-orchestration-23** (RunEngine.swift:380): contiguous order values equal to solver indices are assumed at three sites; a renumber miss silently degrades targets from deadline anchored to start anchored.
39. **solver-math-2** (Solver.swift:17): the flexAbsorbs doc claims a live countdown; remainingFlex is a static solved value rendered as if live.
40. **solver-math-1, 3, 5, 6, 15** (Solver.swift, DeadlineResolver.swift:27, WalkMath.swift:117): dead error case with a stale contract comment; negative known durations schedule without error; out of range hour/minute silently normalize to the wrong day; unclamped safetyFraction can invert the padding; pinnedFlex without a flex block is silently inert.
41. **travel-location-7, 13** (TravelTimeProvider.swift:221, 117): the (0, 0) cache key collapse survives on one path; ObjectIdentifier keyed maps never pruned, misattribution possible on address reuse.
42. **travel-location-18** (LocationService.swift:21): delegate delivery assumes first touch happens on a run loop thread; enforced nowhere.
43. **system-services-13, 14** (Notifications.swift:394, AppSettings.swift:94): the planId round trip fails silently at every step; integer settings load unclamped from defaults.
44. **system-services-18** (AppSettings.swift:21): every settings key and default exists as two free literals that nothing checks for agreement.
45. **ui-8, 18, 22** (ScheduledRoutinesView.swift:15, NowView.swift:623, FullScreenTimePicker.swift:224): hour only sort; 12 hour times without AM/PM; locale dependent parse silently discards typed times.
46. **widget-shared-2, 3, 5, 7, 9, 11**: placeholder widget renders the containerBackground error view; forced dark tint with adaptive text; stale doc in OnTimeShared; latenessMinutes doc and rendering disagree; trailing space label convention; the ramp formula duplicated informally on both sides of the seam.

### Test gaps, ordered by what an uncaught regression would cost

47. **run-orchestration-20**: reconcile, the mechanism the entire wall clock invariant depends on after suspension, has zero coverage; RunEngine has no tests at all.
48. **run-orchestration-21**: armDueRoutines/arm are untested (idempotence, backdating, block copying, the midnight straddle a test would have caught).
49. **solver-math-8**: no test asserts any hardLeaveBy value numerically; a uniform shift of every leaveBy passes the suite, and the flex block's leaveBy is the walk feature's whole output.
50. **travel-location-15**: manualEstimateMinutes, sole feeder of SolverInput and the site of two memorialized shipped bugs, has no precedence chain test.
51. **travel-location-16**: the alarm re-arm policy and phase flip are untestable as written; CC-2's two bugs are exactly what the tests could not catch.
52. **persistence-models-10**: the copyForSpawn fidelity test asserts only fields it already names; the recurring bug it exists to catch would not fail it.
53. **persistence-models-11**: no test builds a ModelContainer at all; Schema0 completeness, renumber healing, weekday round trips, and orphan cleanup are unexercised against real SwiftData.
54. **system-services-15, 16**: armAlertTimes (pure, four edge behaviors, one already disagreeing with its spec) and AppSettings (untestable via hardcoded .standard) have no tests.
55. **ui-25, 26, 27**: parseTime (pure, latently locale broken), the mustStartAt input assembly (a test would have caught ui-1), and the order maintenance invariant (already regressed once) are untested.
56. **solver-math-9, 10, 11, 12**: DeadlineResolver has no midnight/DST/equality tests; the no flex with start path is untested with slack; EstimatorTests pin implementation constants while the stale data behavior has no test; WalkTests miss the clamp up region and projectedArrival.
57. **run-orchestration-22**: alarmKey stability, the subject of a documented past bug, is untested.
58. **widget-shared-12**: all pure widget logic (phase truth table, span guard, tint, lateness label) is private to an untested target; the isFinished bug is the kind a truth table test would have caught.

---

## 3. Enhancements

Strictly separate from bugs. Each subsystem file carries its own ranked list of at most five, plus enhancement class findings from the mechanical passes. The consolidated themes, deduplicated:

1. **Surface solver errors** instead of discarding them at four call sites, and guard the one open duration block invariant at input time (solver-math-17, ui enhancement 2). This single theme retires most of CC-1.
2. **Referrer nullification helper before delete** for TaskTemplate, Place, and ScheduledRoutine, the same pattern deleteOrphanedRuns already uses (persistence enhancement 1); retires CC-5.
3. **Stable identity**: an explicit UUID attribute on Plan and Run to key engines, activities, and notifications (run-orchestration-24); retires CC-6.
4. **Age gate travel data**: honor the cache timestamp, persist a resolvedAt beside resolvedMinutes (travel enhancements 1, 2); retires CC-7.
5. **Fire now instead of disarming** when an alarm's fire date is already past, and extract the re-arm decision into WalkMath for testability (travel enhancements 3, 5, system-services-2's fix direction); retires CC-2.
6. **Surface notification authorization** in Settings and at walk start (system-services-20, travel enhancement 4); retires CC-3's visibility half.
7. **Give Shared/OnTimeShared its promised job**: the notification name, planId formatting, and label building as shared constants (widget enhancements 2, 3); retires CC-4's literal drift and enables a dead app safe intent.
8. **Extract pure widget logic into Shared/** so tests can cover phase resolution and the ramp (widget enhancement 1).
9. **Self retiring engines** (run-orchestration-25), a single catchUp entry point for the arm ritual (run-orchestration-26), timer tolerance and fewer solves per tick (run-orchestration-27, 12), saves at step boundaries (run-orchestration-28).
10. **Estimator refinements**: effective sample size in the blend, interpolated quantiles (solver-math-16, 18); unstack the double safety margin on outbound slack (solver-math-19); validate DeadlineResolver inputs loudly (solver-math-20).
11. **Mechanical exhaustiveness tests**: Mirror based copyForSpawn coverage, one in memory container test over Schema0.models (persistence enhancements 3, 4).
12. **Settings hygiene**: one definition per key and default, injectable defaults suite (system-services-22, 16); delete the dead quick countdown pair (system-services-21); synthesized Equatable (system-services-24); cached locale aware time formatters shared across the five private copies (system-services-23, ui enhancement 1).
13. **UI affordances**: place editing with validated input and delete warnings (ui enhancement 3), learned estimate shown in the template drawer (ui enhancement 4), visible feedback when armTimer or search resolution declines (ui enhancement 5), a distinct wait elapsed Live Activity presentation (widget enhancement 4), finish or remove the placeholder home screen widget (widget enhancement 5), rename Block.isOpenEnded (persistence enhancement 5).

---

## 4. Disagreements

**D-1. Is drive `resolvedMinutes` beating the user's override a bug or the design?** travel-location-9 flags it as a correctness deviation: an ETA fetched days ago (no timestamp survives relaunch) outranks an estimate the user typed a minute ago, and CLAUDE.md's documented chain puts "last resolved value" last. But the in file comment (TravelTimeProvider.swift:176 to 186) argues the live ETA must beat the scrubber value, and both run-orchestration-9 and ui-17 treated the same precedence as the service's intended behavior, flagging only that other code re-implements it redundantly. Both readings cannot be right about intent: either the precedence is a deliberate fix that outgrew its documentation, or a regression from the documented chain. The code, its comment, and CLAUDE.md currently disagree three ways; only the owner can rule. The undisputed part is that no freshness bound exists (CC-7).

**D-2. What should the Live Activity say when a wait target passes?** widget-shared-4 calls "over, waiting on you" wrong because checkWaitTimeElapsed auto starts step 1 on the next app wake, so the run is not waiting on the user. run-orchestration-6 shows that for plans containing an open duration block, naturalStart is nil and that auto start never fires, in which case the copy is accurate. Both are right for different plan shapes, which means the single copy string is wrong for at least one of them; the widget cannot distinguish the cases with the fields it currently receives.

**D-3. Mechanical versus structural on the Estimator blend.** solver-math-4 (mechanical pass) flags the age blind blend weight as a correctness defect against the "old outliers fade" design comment; the same agent's structural pass concedes it "may also be read as intended behavior" since the stale values are still the best available history. Unresolved without a statement of intent; the structural conclusion (solver-math-11) is that the behavior is unspecified precisely where the design comment makes its only claim.

**D-4. Reachability of the two open duration plan.** solver-math-13 marked the trigger medium confidence, not having read the whole editor; ui-12 subsequently verified the editor and the mid run path both permit it, at high confidence. Recorded as a resolution in favor of "reachable", not a standing disagreement.

---

## 5. What the audit could not determine

- **SwiftData runtime semantics were inferred, not reproduced.** The dangling reference fatalError (CC-5), the temporary to permanent identifier transition and its effect on dictionary keys (CC-6), relationship mutation timing during a multi element delete (CC-9), and whether a BG launched context actually crosses with the view context (run-orchestration-17) all rest on documented Core Data/SwiftData behavior. Determining them requires a device or simulator harness that builds a ModelContainer and reproduces each sequence; persistence enhancement 4 (an in memory container test) is the first step.
- **ActivityKit and AppIntents platform behavior.** That an activity's state flips to .stale at staleDate (CC-8), and that a background LiveActivityIntent launch never runs RootView's `.task` (CC-4), are per documentation; both need on device confirmation with the app force quit.
- **Whether the BGAppRefreshTask ever actually fires** on this device and what context lifecycle it gets (run-orchestration-17) requires device logging over days; the design deliberately depends on nothing from it.
- **Real notification pressure against the 64 request limit** (system-services-19) depends on this user's actual routine and run counts, which the audit cannot see.
- **Locale and rendering context issues** (ui-22's parse failures, widget-shared-3's light scheme contrast) need a device in a non en_US locale and an observed light context Lock Screen render.
- **Intent, in three places.** D-1 (override precedence), D-3 (estimator staleness), and the desired Cancel semantics of FullScreenTimePicker (ui-6 assumes Cancel should revert; nothing written says so) each need a ruling from the owner, not more code reading.
