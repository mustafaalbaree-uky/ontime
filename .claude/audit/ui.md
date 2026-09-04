# UI subsystem audit (OnTime/Views/, plus OnTimeApp scene wiring)

The three tabs, the run screen, the routine editor, and shared components: about 3,750 lines with zero tests, carrying real scheduling logic (solver input assembly, order renumbering, implicit template creation) inside view code.
Depth went to NowView, RunView, QuickBlockEditorSheet, ScheduledRoutineEditor, WalkCard, PlaceSearchField, and ArmedRoutineBanner; SettingsView, CountdownsView, LearnedStepsView, TemplateDetailView, TemplateDrawerSheet, DurationScrubber, ScrubTrack, and RadarDot got a lighter pass and were unremarkable beyond the findings below.

Checked against known history: the PlaceSearchField selection clearing bug is properly fixed in the current code (the `isSelecting` guard at PlaceSearchField.swift:37 to 54, including the no op assignment subtlety at line 184), but the same shape has reappeared in QuickBlockEditorSheet (ui-2). Every display and scheduling read of a plan's or routine's blocks in the Views tree goes through `orderedBlocks` (verified by sweep: the only `.blocks` reads are `engine.blocks`, which is `plan?.orderedBlocks` per RunEngine.swift:46, and `routine.orderedBlocks`), and every move, insert, and delete either calls `renumber()` or assigns a contiguous 0 to n minus 1 by hand. Both conventions hold. The scene wiring in OnTimeApp (scenePhase arming in RootView, BG task resubmission, launch time orphan cleanup) is clean apart from the ordering assumption noted in ui-20.

---

## Pass A: mechanical review

```
ID:        ui-1
Location:  OnTime/Views/Now/NowView.swift:71
Class:     correctness
Claim:     With any flex or walk step on the board, mustStartAt silently falls back to the bare deadline, so the headline countdown and "Start step 1 by" ignore every fixed and drive duration.
Evidence:  mustStartAt builds SolverInput(durations:, deadline:, start: nil, pinnedFlex: nil) mapping open duration blocks to .flex (lines 73 to 78). Solver.solve throws SolverError.underdetermined whenever a flex index exists and start is nil (Solver.swift, the unpinned flex branch guards on input.start). The `try? Solver.solve` at NowView.swift:79 swallows that and returns `deadline`.
Trigger:   Adding one flex or walk step to a sequence that also contains fixed or drive steps. This is the app's flagship composition (prep steps plus one open block).
Blast:     The number the user plans their departure around overstates available time by the sum of all known durations (a 20 minute drive plus flex shows the deadline itself, 20 minutes too late). armTimer arms a Clock timer to the same wrong instant. The correct display is deadline minus the known durations (latest start with zero flex).
Confidence: high
```

```
ID:        ui-2
Location:  OnTime/Views/Now/QuickBlockEditorSheet.swift:71
Class:     correctness
Claim:     onChange(of: name) clears the selectedTemplate that apply(template) just set, the exact shape of the historical PlaceSearchField bug (a handler undoing state its own selection path just wrote).
Evidence:  apply(template) at lines 250 to 253 sets `name = template.name` then `selectedTemplate = template`. On the next view update, onChange(of: name) at line 71 fires (the name always changes, because matchingTemplates at line 62 excludes exact matches, so the row only exists when the names differ) and sets `selectedTemplate = nil`. PlaceSearchField solved the identical problem with an isSelecting guard; this field has none.
Trigger:   Tapping any autocomplete row in the Title section.
Blast:     Cosmetic today, not data loss: save() is rescued because resolveTemplate (line 359) refinds the template by exact name match. What breaks is the "Linked to X, this run will count toward its history" confirmation at lines 92 to 96, which can never render after a tap, so the one visual proof the linkage worked is dead. Any future code that trusts selectedTemplate directly inherits the full bug.
Confidence: high
```

```
ID:        ui-3
Location:  OnTime/Views/Run/RunView.swift:100
Class:     correctness
Claim:     User facing copy in two places directs the user to the "Plans" screen, which was deleted; the instruction is unfollowable.
Evidence:  RunView.swift:100, the cancel dialog: "Your plan and its steps aren't deleted — you can start it again from Plans." CountdownsView.swift:24, the empty state: "Start a plan from Now or Plans and it'll show up here". CLAUDE.md states there is no Plans screen and nothing lists Plans.
Trigger:   Cancelling a run, or looking at the empty Active tab.
Blast:     The cancel dialog's reassurance is false in practice: the plan survives but is unreachable, so "Cancel Run" is effectively destructive for a hand built sequence (the scratch blocks were claimed by the plan at start, so the Now board is empty too). The copy hides that.
Confidence: high
```

```
ID:        ui-4
Location:  OnTime/Views/Now/NowView.swift:570
Class:     correctness
Claim:     QuickShortcut rows reintroduce the duplicate order key bug that was already diagnosed and fixed for blocks in this same file.
Evidence:  addShortcut assigns `order: shortcuts.count` (line 570) and delete(shortcut) (lines 575 to 577) never renumbers survivors. The comment at lines 96 to 101 documents precisely this failure for blocks: after a delete, count collides with a surviving row's order, giving two rows the same sort key and nondeterministic ordering between fetches (the "flash into place then swap" symptom). nextScratchOrder (line 102) is the fix pattern, max plus one, not applied here.
Trigger:   Delete any shortcut that is not the last one, then add a new shortcut.
Blast:     Shortcut chips in the header scroller reorder unpredictably between renders. Cosmetic but recurrent, and it is a solved bug regressing in the same file.
Confidence: high
```

```
ID:        ui-5
Location:  OnTime/Views/Routines/ScheduledRoutineEditor.swift:157
Class:     correctness
Claim:     delete(at:) indexes into the computed `blocks` property while deleting from it, so a multi element IndexSet deletes the wrong rows or reads out of range.
Evidence:  `blocks` is `routine.orderedBlocks` recomputed on every access (line 20). The loop `for index in offsets { modelContext.delete(blocks[index]) }` reevaluates the relationship after each delete; SwiftData removes a deleted block from the relationship immediately, so every index after the first refers to a shifted array. RunView.deleteUpcomingSteps (RunView.swift:484 to 489) does this correctly by snapshotting `var ordered = p.orderedBlocks` first, and TemplateDetailView.deleteSample (TemplateDetailView.swift:101 to 106) maps offsets before deleting.
Trigger:   An onDelete callback carrying more than one offset. The list is permanently in edit mode (line 96), where single row deletion is the common path, so this is latent rather than daily.
Blast:     Wrong step silently deleted from a routine, or an index crash. Same latent pattern, lower risk, in LearnedStepsView.delete (LearnedStepsView.swift:39 to 43) and PlacesView.deletePlaces (PlacesView.swift:119 to 123), which index live @Query arrays.
Confidence: medium (mechanism verified, multi element trigger not exercised)
```

```
ID:        ui-6
Location:  OnTime/Views/Components/FullScreenTimePicker.swift:65
Class:     state
Claim:     Cancel does not cancel: the wheel writes through the live binding on every detent, so edits are already committed to AppSettings or the routine before either toolbar button is tapped.
Evidence:  DatePicker(selection: $date) at line 106 mutates the caller's binding continuously. NowView.deadlineTimeBinding (NowView.swift:234 to 238) writes settings.quickDeadlineHour/Minute in its setter, and ScheduledRoutineEditor.anchorBinding (ScheduledRoutineEditor.swift:141 to 145) writes the routine, both persisted immediately. The Cancel button (line 66) only dismisses. Same for the duration mode scrubber at line 124.
Trigger:   Open Final Time or Be Done By, spin the wheel, tap Cancel (or swipe the sheet down).
Blast:     The deadline every countdown on the Now screen is computed from, or a routine's anchor that drives its arm alarms, changes despite an explicit Cancel. For a routine the stale alarms persist until the routines sheet next dismisses and refreshes them.
Confidence: high
```

```
ID:        ui-7
Location:  OnTime/Views/Settings/PlacesView.swift:125
Class:     boundary
Claim:     seedDefaultPlacesIfNeeded creates Home and Masjid pinned to whatever coordinate is stored, with no hasRealLocation guard, so on a fresh install without a GPS fix both are silently created at (0, 0).
Evidence:  Lines 128 to 131 read AppSettings.shared.lastLatitude/lastLongitude unconditionally. QuickBlockEditorSheet.snapshotCurrentLocation (QuickBlockEditorSheet.swift:389 to 391) guards this exact hazard and its comment names the failure ("would silently pin every future use to the Gulf of Guinea"). The seed path predates or ignores that lesson. Both places also get the same coordinate even with a fix, and there is no UI to edit a place afterward (see ui-15), so the seeds can never be corrected in app.
Trigger:   Opening Settings, then Saved Places, before the first location fix, or before ever leaving the default coordinate.
Blast:     Drive blocks routed from or to Home or Masjid produce absurd MapKit ETAs or fall back to manual estimates with no explanation; the developer panel is the only place the cause is visible.
Confidence: high
```

```
ID:        ui-8
Location:  OnTime/Views/Routines/ScheduledRoutinesView.swift:15
Class:     correctness
Claim:     The routines list sorts by anchorHour only, so routines within the same hour appear in arbitrary order (7:30 can list before 7:05).
Evidence:  `@Query(sort: \ScheduledRoutine.anchorHour)` with no secondary key on anchorMinute.
Trigger:   Two routines anchored in the same hour.
Blast:     Display order only.
Confidence: high
```

```
ID:        ui-9
Location:  OnTime/Views/Now/NowView.swift:617
Class:     enhancement
Claim:     A fresh DateFormatter is allocated per call inside bodies that reinvalidate every second, and armTimer plus timeString are duplicated verbatim across files.
Evidence:  NowView.timeString (617 to 621) runs on every one second tick (onReceive at 121); RunView.timeString (526 to 530) runs once per scheduled row per engine tick; WalkCard.clock (255 to 260) likewise; ScheduledRoutineEditor:164 to 176, RoutineRow:155 to 163, and FullScreenTimePicker:212 to 216 each define their own. armTimer in NowView (600 to 613) and RunView (509 to 522) are character for character copies, including comments.
Trigger:   Always, while the relevant screen is live.
Blast:     Wasted allocations on a per second path (DateFormatter construction is famously expensive) and two copies of the Shortcuts URL logic that can drift. One shared cached formatter and one shared timer helper fix both.
Confidence: high
```

```
ID:        ui-10
Location:  OnTime/Views/Now/NowView.swift:37
Class:     state
Claim:     NowView's one second timer keeps ticking, and the whole body (including a Solver.solve call and per block estimate lookups) keeps recomputing, while the Now tab is not visible.
Evidence:  `Timer.publish(every: 1).autoconnect()` lives in @State (line 38), subscribed via onReceive (line 121); TabView keeps all three tab views alive, and the timer also runs under every presented sheet and under the RunView fullScreenCover. Each tick recomputes `deadline` (DeadlineResolver), `mustStartAt` (Solver.solve plus a TravelTimeService lookup per block), and reformats strings.
Trigger:   App foregrounded on any tab or with any sheet up.
Blast:     Steady CPU and battery cost proportional to board size, invisible in behavior. ScheduledRoutinesView's 30 second ticker (ScheduledRoutinesView.swift:19) is the same pattern at lower cost.
Confidence: medium (tick while non visible inferred from TabView keep alive behavior, not profiled)
```

```
ID:        ui-11
Location:  OnTime/Views/Run/RunView.swift:452
Class:     correctness
Claim:     insertStep drops a template's origin and destination, so a drive step added mid run can never resolve a live ETA and a walk step added mid run has no home coordinate.
Evidence:  The Block created at lines 461 to 468 passes template but not originPlace or destinationPlace, though TaskTemplate carries both and QuickBlockEditorSheet.apply (QuickBlockEditorSheet.swift:257 to 259) copies them in the equivalent flow. TravelTimeService routes from the block's own places, and WalkCard's Route button is disabled and the tracker reports unavailable when the walk has no destination.
Trigger:   Add Step mid run, pick a remembered drive (or walk) template.
Blast:     The inserted drive step schedules on the manual estimate forever with no indication why; an inserted walk step arms no meaningful turnaround.
Confidence: medium (template place fields verified; walk template selectability inferred from templates list being unfiltered at RunView.swift:15)
```

```
ID:        ui-12
Location:  OnTime/Views/Run/RunView.swift:102
Class:     assumption
Claim:     "At most one open duration block per plan" is enforced nowhere in the UI, and violating it mid run silently blanks every scheduled time on the run screen.
Evidence:  TemplateDrawerSheet offers Flex as a custom kind (TemplateDrawerSheet.swift:57) and lists flex and walk templates unfiltered (lines 26 to 48); insertStep adds whatever it is handed. RunEngine.recomputeSolution does `currentSolution = try? Solver.solve(input)` (RunEngine.swift:370), and Solver throws multipleFlexBlocks; nil solution means schedule(for:) and leaveByDate(for:) go quiet. On the Now board, QuickBlockEditorSheet's kind picker (QuickBlockEditorSheet.swift:104 to 111) likewise allows a second flex or walk, which lands in ui-1's fallback.
Trigger:   A plan already containing a flex or walk block gets a second one via Add Step (mid run) or the step editor (before start).
Blast:     Mid run: every leave by time, the flex countdown, and the Live Activity content silently stop updating, with no message anywhere. Before start: the headline countdown degrades per ui-1.
Confidence: high
```

```
ID:        ui-13
Location:  OnTime/Views/Components/PlaceSearchField.swift:213
Class:     error-handling
Claim:     A failed MKLocalSearch resolution is silently discarded, so tapping a search suggestion can visibly do nothing.
Evidence:  `guard let item = response?.mapItems.first else { return }` after isResolving is reset; the error parameter of the completion is ignored and locationFailure is never set on this path.
Trigger:   Network failure or an unresolvable completion at the moment of tap.
Blast:     Spinner stops, no place selected, no message; the user's most likely read is "the tap did not register", the exact confusion the file's own comments fight elsewhere.
Confidence: high
```

```
ID:        ui-14
Location:  OnTime/Views/Now/NowView.swift:601
Class:     error-handling
Claim:     armTimer silently no ops when the target is already past, and gives no feedback if the "OnTime Timer" shortcut does not exist on the phone.
Evidence:  `guard target > Date() else { return }` (NowView.swift:601, RunView.swift:510) with no UI response; UIApplication.shared.open of the shortcuts URL is fire and forget, and a missing shortcut surfaces only as an error inside the Shortcuts app.
Trigger:   Tapping the timer affordance while overdue, or on a device without the shortcut installed.
Blast:     A dead tap on a button that looks live; low stakes but on the primary screen.
Confidence: high
```

```
ID:        ui-15
Location:  OnTime/Views/Settings/PlacesView.swift:64
Class:     boundary
Claim:     Manual place entry accepts any Double as latitude and longitude, and no screen can edit a place after creation.
Evidence:  The lat and lon TextFields (lines 64 to 78) have format: .number with no range validation (91, 500, negatives all accepted); the list body offers only add and swipe delete, no edit destination. "Fill Current Coordinates" (lines 79 to 84) silently does nothing without a fix.
Trigger:   Typo during manual entry, or any need to correct a seeded or searched place.
Blast:     An invalid place feeds MapKit routing, which fails into the manual estimate tier with the cause visible only in the developer panel; fixing anything means delete and recreate, which orphans blocks and templates pointing at the old row (their destination silently nulls).
Confidence: high
```

```
ID:        ui-16
Location:  OnTime/Views/Routines/ScheduledRoutinesView.swift:63
Class:     state
Claim:     The plus button inserts an empty ScheduledRoutine into the store before the editor opens, and no path removes it if the user backs out without configuring it.
Evidence:  Lines 64 to 66 insert then present; ScheduledRoutineEditor's only exit is Done (line 98 to 101), there is no cancel and delete, and dismissal leaves the row.
Trigger:   Tap plus, change your mind, tap Done or swipe the sheet away.
Blast:     A permanent "Untitled, 7:00 AM, every day, no steps" row accumulates per aborted attempt. Harmless to scheduling (no steps means no occurrence per RoutineRow), but it is stored garbage the user has to notice and delete.
Confidence: high
```

```
ID:        ui-17
Location:  OnTime/Views/Now/NowView.swift:438
Class:     enhancement
Claim:     The comment justifying driveMinutes is stale: TravelTimeService.manualEstimateMinutes now prefers resolvedMinutes for drive blocks itself, making the local precedence redundant (though not wrong).
Evidence:  The comment (lines 438 to 443) claims manualEstimateMinutes "checks estimateOverrideMinutes first" so "a live ETA would otherwise never be shown"; TravelTimeProvider.swift:187 to 189 now returns resolvedMinutes for a drive block before consulting the override.
Trigger:   Reading or extending this code.
Blast:     A future edit trusting the comment reintroduces complexity to solve a problem the service already solved.
Confidence: high
```

```
ID:        ui-18
Location:  OnTime/Views/Now/NowView.swift:623
Class:     boundary
Claim:     timeString(hour:minute:) renders 12 hour times without AM or PM, so shortcut chips and a startAt row's "at 5:30" are ambiguous between morning and evening.
Evidence:  Line 624 formats hour mod 12 with no period suffix; used by the chips (line 202) and the startAt row caption (line 372).
Trigger:   Any shortcut or startAt target; matters most for times a routine could plausibly mean either way.
Blast:     Misreading only; the underlying stored hour is correct.
Confidence: high
```

```
ID:        ui-19
Location:  OnTime/Views/Routines/ScheduledRoutineEditor.swift:149
Class:     assumption
Claim:     The "Starts At only as the first step" rule is enforced only at creation and edit time (isFirstPosition), and drag reordering bypasses it entirely.
Evidence:  QuickBlockEditorSheet offers .startAt only when isFirstPosition (QuickBlockEditorSheet.swift:109 to 111), but move (ScheduledRoutineEditor.swift:149 to 155) renumbers freely with no kind check, so a startAt block can land mid sequence. Its duration then computes as "time from actualStart or now until the clock time" (TravelTimeProvider.swift:170 to 174), which is meaningless before its predecessors run.
Trigger:   Drag the first step of a routine below another step when step one is a Starts At block.
Blast:     The routine's derived mustStartAt and arm time go quietly wrong; nothing flags the invalid arrangement.
Confidence: medium (bypass verified in code; downstream scheduling effect reasoned, not executed)
```

```
ID:        ui-20
Location:  OnTime/Views/RootView.swift:29
Class:     assumption
Claim:     The view layer assumes deleteOrphanedRuns and RunEngineStore.configure both happened before any row builds an engine, and the ordering is only partly guaranteed.
Evidence:  RootView.resumeOpenRuns's own comment (lines 62 to 64) leans on OnTimeApp.deleteOrphanedRuns having run synchronously in init (OnTimeApp.swift:27, verified). But RootView's `.task` (line 29) races sibling tab onAppear: CountdownsView rows call RunEngineStore.shared.engine(for:) in onAppear (CountdownsView.swift:77) and RunEngineStore's own comment concedes the configure ordering "if it's ever wrong" case, falling back to run.modelContext.
Trigger:   SwiftUI constructing and appearing a Countdowns row before RootView's task runs (tab restoration, fast relaunch).
Blast:     Today: degrades gracefully to the run's own context. The hazard is that the fallback masks any future change that breaks the ordering for real.
Confidence: medium
```

```
ID:        ui-21
Location:  OnTime/Views/RootView.swift:66
Class:     error-handling
Claim:     A failed open runs fetch is treated as "no open runs", which then cancels all run notifications and ends every Live Activity.
Evidence:  `(try? modelContext.fetch(...)) ?? []` at line 66 flows into the empty guard at lines 68 to 72, whose branch tears down all activities and notifications.
Trigger:   Any fetch error at launch (rare; store corruption or schema mismatch window).
Blast:     Live runs lose their Lock Screen presence and alarms while still being live in the store; recoverable by reopening each run.
Confidence: high
```

```
ID:        ui-22
Location:  OnTime/Views/Components/FullScreenTimePicker.swift:224
Class:     boundary
Claim:     parseTime builds DateFormatters without a fixed locale, so typed times like "2:47 PM" fail to parse under a 24 hour or non English device locale and the entry is silently discarded.
Evidence:  Lines 228 to 232 use raw dateFormat strings ("h:mm a" etc.) on locale default formatters; commitTypedIfNeeded (lines 199 to 202) keeps the old value on parse failure with no error shown.
Trigger:   Device set to a locale whose AM PM symbols differ or that rejects 12 hour patterns; personal device today is en_US so latent.
Blast:     Typed entry silently ignored; wheel still works.
Confidence: medium
```

```
ID:        ui-23
Location:  OnTime/Views/Now/QuickBlockEditorSheet.swift:392
Class:     boundary
Claim:     Every save with "Follow My Location" off inserts a brand new Place named "Saved Location", accumulating indistinguishable rows and orphaning the previous snapshot.
Evidence:  snapshotCurrentLocation (lines 389 to 395) unconditionally inserts a new Place; nothing dedupes by coordinate or deletes the template's prior snapshot when template.originPlace is reassigned (line 338). All snapshots surface in the origin Menu (savedPlaces at line 17) and in PlacesView, all with the same name.
Trigger:   Editing and resaving the same drive step with the toggle off more than once.
Blast:     Place list pollution and an origin picker full of identical "Saved Location" entries with no way to tell which is current.
Confidence: high
```

```
ID:        ui-24
Location:  OnTime/Views/Now/QuickBlockEditorSheet.swift:354
Class:     assumption
Claim:     Implicit template creation assumes every typed name is worth remembering, so renaming or mistyping a step mints a permanent zero sample template with no cleanup path in the flow.
Evidence:  resolveTemplate creates a TaskTemplate for any nonempty name with no case insensitive match (lines 359 to 364); editing an existing block's name leaves the old template behind and creates a new one. Deletion exists only in LearnedStepsView.
Trigger:   Typos and renames during normal step editing.
Blast:     Autocomplete (matchingTemplates) and the Learned Steps list fill with dead entries; by design per CLAUDE.md, but the cost is unbounded and invisible at the point it is incurred.
Confidence: high
```

```
ID:        ui-25
Location:  OnTime/Views/Components/FullScreenTimePicker.swift:224
Class:     test-gap
Claim:     parseTime is a pure static function with five accepted formats and documented loose input goals, and it has no tests.
Evidence:  Static, no view dependencies, five format branches plus trimming; OnTimeTests contains no view or component tests (verified: only Solver, Schedule, Plan, Walk suites exist).
Trigger:   Any change to the format list or a locale issue (ui-22).
Blast:     The single easiest to test behavior in the subsystem, guarding the only typed entry path for times.
Confidence: high
```

```
ID:        ui-26
Location:  OnTime/Views/Now/NowView.swift:71
Class:     test-gap
Claim:     The solver input assembly in mustStartAt (kind mapping, drive minutes precedence, fallback behavior) is untested, and a test would have caught ui-1.
Evidence:  The mapping at lines 73 to 78 is business logic living in a computed view property; no test constructs it. An extracted function taking blocks, deadline, and an estimate lookup would be trivially testable.
Trigger:   Every change to block kinds or estimate precedence.
Blast:     Silent wrong countdowns, per ui-1.
Confidence: high
```

```
ID:        ui-27
Location:  OnTime/Views/Now/NowView.swift:556
Class:     test-gap
Claim:     The order maintenance logic spread across views (delete renumbering, nextScratchOrder, move renumbering, shortcut ordering) encodes a subtle invariant that already regressed once and is untested.
Evidence:  NowView.delete (556 to 562) and nextScratchOrder (102) exist because of a documented ordering bug; ScheduledRoutineEditor.move and delete (149 to 162) reimplement the same invariant; addShortcut (570) violates it today (ui-4). PlanTests covers copyForSpawn fidelity but nothing covers these view side mutations.
Trigger:   Any future edit to add, move, or delete flows.
Blast:     Nondeterministic list ordering, the known failure mode.
Confidence: high
```

---

## Pass B: structural audit

### 1. Boundaries where user input changes form

- **Typed step name to TaskTemplate** (QuickBlockEditorSheet.swift:291 to 295, 354 to 365): trimmed; empty falls back to a generic name and creates no template; nonempty implicitly creates a template (ui-24). Case insensitive matching dedupes exact names. No length cap. Assumed: a name identifies one template; two templates differing only in punctuation coexist.
- **Wheel and typed time to stored hour and minute** (FullScreenTimePicker, NowView.deadlineTimeBinding:226 to 240, ScheduledRoutineEditor.anchorBinding:133 to 147): the wheel is inherently valid; typed entry validates by parse and silently discards failures (ui-22). The write is live, so Cancel is not a boundary at all (ui-6). Deadline rolling to tomorrow happens downstream in DeadlineResolver, correctly only when the deadline itself passed.
- **Minutes entry** (DurationScrubber:51 to 60, ScrubTrack, FullScreenTimePicker duration mode): the strongest seam in the subsystem. Range clamped (1 to 300 or 600), zero unreachable, non numeric typed input silently keeps the old value. No finding.
- **Place selection to coordinates** (PlaceSearchField:208 to 236): search results resolve through MKLocalSearch and dedupe by name plus a 0.0001 degree box; failures silent (ui-13). Manual entry in PlacesView is unvalidated (ui-15); seeding is unguarded (ui-7); snapshots accumulate (ui-23). The (0, 0) sentinel hazard is guarded on exactly one of its three entry paths.
- **Weekdays** (ScheduledRoutineEditor WeekdayPicker:214 to 247): cannot be emptied, by explicit guard with a comment explaining why. Clean.
- **Past deadlines**: entering a past clock time is legal everywhere by design; NowView shows "overdue" and RunLauncher starts a countdown from now. Consistent, no finding.

### 2. Error handling

Surfaced to the user: Live Activity denial and start failure (RunView:109 to 129, alerts bridged from engine state), per drive block resolution errors (NowView rows at 380 to 384 and the developer panel), GPS acquisition state and failure (PlaceSearchField:69 to 86), walk estimate unavailability (WalkCard sourceLine:147 to 161). This is a genuinely good set for a personal app.

Swallowed: every Solver failure (`try?` at NowView:79 and RunEngine:370, findings ui-1 and ui-12, the two most serious in the subsystem); MKLocalSearch resolution (ui-13); the open runs fetch at launch (ui-21); armTimer preconditions (ui-14); "Fill Current Coordinates" without a fix (PlacesView:79 to 84). Views never call modelContext.save() explicitly anywhere in the subsystem; everything rides the main context's autosave, which is conventional but means a save failure is invisible by construction (the BGTask path in OnTimeApp:94 does `try? context.save()`, also silent, though that line belongs to the scene wiring I audited and is consistent with the app's posture).

### 3. State and lifetime

- Sheet state: NowView holds five booleans plus two item bindings for seven distinct presentations (lines 40 to 52); nothing enforces mutual exclusion, SwiftUI's one sheet per attachment point is the only guard. Currently safe because each trigger is a distinct user tap; fragile if any presentation ever becomes programmatic.
- @State duplicating model state: QuickBlockEditorSheet copies the block into locals (34 to 54) and writes back only on Save, which is what gives it correct Cancel semantics; FullScreenTimePicker does the opposite and gets ui-6. The contrast between the two is the clearest statement of the right pattern in the codebase.
- Timers: NowView's one second timer (ui-10) and ScheduledRoutinesView's 30 second ticker are never explicitly cancelled and outlive visibility; CountdownsView correctly avoids a timer entirely with `Text(_, style: .relative)`.
- Uncancelled tasks: refreshDriveEstimates (NowView:153) and selectCurrentLocation (PlaceSearchField:199) spawn detached Tasks per invocation with no cancellation; both are idempotent writes so the cost is redundant network work, not corruption.
- Engines in row @State: BannerRow, CountdownRow, and RunView each hold a RunEngine reference obtained in onAppear; after RunEngineStore.retire the row's reference keeps the engine alive until the view goes away. Harmless today (retire is idempotent, verified RunEngineStore.swift:94 to 98, so the double retire in RunView.finishedView at 428 and 438 is safe).
- Singleton observation: computed properties returning `.shared` (NowView:33 to 35, WalkCard:22) correctly register @Observable dependencies; no view uses the computed UserDefaults antipattern CLAUDE.md warns about. Clean result.

### 4. Test gaps (subsystem has zero tests)

Ranked by extractability times consequence: (1) mustStartAt input assembly, ui-26, would have caught the worst live bug; (2) parseTime, ui-25, pure and already latently broken by locale; (3) order maintenance invariants, ui-27, a regressed once behavior; (4) resolveTemplate's create or reuse decision (case insensitivity, startAt exclusion, the selectedTemplate fast path that ui-2 currently makes dead code); (5) the pure formatting helpers (formatDuration in two incompatible variants, RoutineRow.relative, WalkCard verdict and color thresholds at 224 to 238), each a small pure function a snapshot style unit test covers in minutes.

### 5. Load bearing assumptions (true today, enforced nowhere)

- One open duration block per plan: the Solver enforces it by throwing, the UI neither prevents nor reports it (ui-12, ui-1).
- Starts At blocks are first: enforced at creation only; drag reorder bypasses (ui-19).
- Runs reaching any view have live plans: guaranteed solely by deleteOrphanedRuns running synchronously in OnTimeApp.init before any view exists (OnTimeApp:108 to 138); any new entry point that touches a Run earlier (widget intent, deep link) reopens the uncatchable fault the comment describes (ui-20 adjacent).
- Autosave persists everything: no view saves explicitly; a change to context configuration or a background context would silently stop persisting UI edits.
- PlaceSearchField's dedupe assumes name plus coordinate identifies a place, while PlacesView freely creates duplicates of both, and snapshots multiply under one shared name (ui-23).
- The Now board's scratch blocks (plan nil, routine nil) are claimed, not copied, on start (RunLauncher:26 to 29): the board emptying after Start is load bearing for the "claimed" model, and any future "keep my sequence" feature must copy via copyForSpawn instead.

### 6. Enhancements (ranked, not bugs)

1. Shared TimeFormatting utility with cached DateFormatters plus one shared ShortcutTimer helper, absorbing ui-9 and ui-17 and deleting four private timeString copies.
2. Guard the open duration invariant at input time: hide or disable Flex and Walk in QuickBlockEditorSheet's kind picker and TemplateDrawerSheet when the plan or board already has one, turning ui-12 from silent failure into an impossibility.
3. Place management: edit an existing place (name and coordinates), validate ranges on manual entry, and warn on delete when blocks or templates reference the place.
4. Show the learned estimate (Estimator blend) in TemplateDrawerSheet rows instead of the raw manual prior, matching what QuickBlockEditorSheet.apply and the schedule will actually use.
5. Give armTimer a visible response when it declines (haptic plus a transient label for a past target), and surface MKLocalSearch resolution failure in PlaceSearchField the same way locationFailure already is.
