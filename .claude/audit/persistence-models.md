# Audit: persistence-models

Subsystem summary: the eight SwiftData @Model types under OnTime/Models plus the store construction in OnTimeApp (openStore, deleteOrphanedRuns). The three documented invariants (Schema0 completeness, copyForSpawn fidelity, orderedBlocks/renumber discipline) all hold in the current code; the substantive risk is elsewhere, in unpaired to-one references that dangle when the UI deletes a TaskTemplate, Place, or ScheduledRoutine, and in a store rebuild that wipes data on any open error rather than only on schema mismatch.

Verified clean results, stated explicitly:

- Schema0.models is complete right now. A repo wide grep for `@Model` finds exactly eight types (TaskTemplate, DurationSample, Place, Plan, Block, Run, ScheduledRoutine, QuickShortcut) and all eight appear in OnTime/Models/Schema0.swift lines 9 to 16.
- Block.copyForSpawn is exhaustive today. Block's stored properties are: order, name, kindRaw, template, estimateOverrideMinutes, resolvedMinutes, originPlace, destinationPlace, useManualEstimateOnly, targetHour, targetMinute, actualStart, actualEnd, statusRaw, isOpenEnded, plan, routine. copyForSpawn (Block.swift:90) copies the first twelve; actualStart, actualEnd, and statusRaw are deliberately excluded run state, and plan/routine are deliberately excluded ownership. Nothing is missing by accident.
- No direct `.blocks` reads bypass orderedBlocks. Every `.blocks` hit outside the model files themselves is `Solution.blocks` or `RunEngine.blocks`, and RunEngine.blocks (RunEngine.swift:46) is itself `plan?.orderedBlocks ?? []`. The only raw appends are inside spawn code and tests, where order is assigned explicitly.
- Every current mutator renumbers: RunLauncher.start (RunLauncher.swift:30), RunView delete (RunView.swift:490), ScheduledRoutineEditor delete (line 161) and move (lines 152 to 154, inline equivalent), NowView scratch delete (NowView.swift:558 to 561, inline equivalent). I looked for a mutation site missing renumber and found none among Block mutators. QuickShortcut, which is not a relationship but does carry an `order`, is the one exception; see finding 5.

## Pass A: mechanical review

```
ID:        persistence-models-1
Location:  OnTime/Views/Templates/LearnedStepsView.swift:41 (and OnTime/Models/Block.swift:19)
Class:     correctness
Claim:     Deleting a TaskTemplate leaves every Block whose `template` points at it holding a dangling reference, and the app reads properties through that reference on nearly every screen.
Evidence:  Block.template (Block.swift:19) has no @Relationship inverse and TaskTemplate declares no blocks collection, so SwiftData cannot nullify it on delete. LearnedStepsView.delete (line 41) calls modelContext.delete with no referrer cleanup. Property reads through the pointer are widespread: block.template?.symbol at NowView.swift:465, RunView.swift:154 and 234, RunEngine.swift:494 and 512, CountdownsView.swift:49, ScheduledRoutineEditor.swift:184; TravelTimeProvider.swift:203 reads estimates through it. Plan.swift lines 20 to 28 document exactly this failure mode for Run.plan: reading a property off a reference whose backing row is gone is the uncatchable "backing data could no longer be found" fatalError.
Trigger:   User deletes a learned step in Settings while any Block (a scratch block on Now, a routine step, a block of an open run) still references that template, then any referencing screen renders.
Blast:     Hard crash at launch or on tab switch, recurring every launch until the store is wiped, since the dangling row persists. The store rebuild policy will not save you because the schema still matches.
Confidence: medium
Note:      Inferred from Core Data/SwiftData semantics for unpaired relationships plus this codebase's own documented precedent in Plan.swift; not reproduced on device.
```

```
ID:        persistence-models-2
Location:  OnTime/Views/Settings/PlacesView.swift:121 (and OnTime/Models/Block.swift:22)
Class:     correctness
Claim:     Deleting a Place leaves Block.originPlace, Block.destinationPlace, TaskTemplate.originPlace, and TaskTemplate.destinationPlace dangling; same failure class as finding 1.
Evidence:  All four pointers are plain optionals with no inverse (Block.swift:22 and 23, TaskTemplate.swift:61 and 62). PlacesView.deletePlaces (line 121) deletes with no referrer cleanup. Travel resolution and the block editor read these pointers' properties (name, latitude, longitude) whenever a drive or walk block is displayed or resolved.
Trigger:   User deletes a saved place that any block or template still routes through, then that block is rendered or resolved.
Blast:     Same uncatchable fatalError as finding 1, plus the walk feature's return point (destinationPlace) can die mid run.
Confidence: medium
```

```
ID:        persistence-models-3
Location:  OnTime/Views/Routines/ScheduledRoutinesView.swift:85 (and OnTime/Models/Plan.swift:13)
Class:     correctness
Claim:     Deleting a ScheduledRoutine cascades its own template blocks but leaves every spawned Plan's `routine` pointer dangling, which ArmedRoutineBanner then reads.
Evidence:  Plan.routine (Plan.swift:13) is an unpaired optional; ScheduledRoutine declares only a blocks inverse (ScheduledRoutine.swift:40). ScheduledRoutinesView.delete (line 85) does no Plan cleanup. ArmedRoutineBanner.swift:22 filters open runs on `$0.plan?.routine != nil`; ScheduleService.swift:188 writes the pointer at arm time.
Trigger:   A routine armed today (spawning a Plan and open Run) is then deleted from the Scheduled sheet.
Blast:     The nil check itself likely survives (a fault object is non nil), so the dead routine's run keeps showing as routine provenance; any future property read through plan.routine (a name, an anchor) is the same fatalError class. Also a correctness wart: the banner classifies by a pointer that can no longer be verified.
Confidence: medium
```

```
ID:        persistence-models-4
Location:  OnTime/App/OnTimeApp.swift:67
Class:     error-handling
Claim:     openStore wipes and rebuilds the store on any ModelContainer error, not only on schema incompatibility, so a transient failure (disk full, file lock, a momentary Core Data hiccup) permanently destroys all data.
Evidence:  The catch at line 67 is untyped: any thrown error reaches `print("Store incompatible...")` and the sidecar deletion at lines 73 to 77. Nothing inspects the error to confirm it is actually a schema mismatch before deleting the store file.
Trigger:   ModelContainer init throws for any reason other than schema drift on a launch.
Blast:     Total data loss (routines, learned durations, places) on a launch where a retry would have succeeded. The documented policy ("trading the contents for a launchable app") intends to pay this price only for schema changes.
Confidence: high for the code path; medium for how often non schema errors occur in practice.
```

```
ID:        persistence-models-5
Location:  OnTime/Views/Now/NowView.swift:570 and 575
Class:     correctness
Claim:     QuickShortcut deletion never renumbers and addShortcut assigns `order: shortcuts.count`, so after a delete a new chip can duplicate an existing order value and the `@Query(sort: \QuickShortcut.order)` list becomes ambiguously ordered.
Evidence:  delete(_ shortcut:) at line 575 only deletes. addShortcut at line 570 uses count. With orders {0,1,2}, deleting 0 leaves {1,2} and count 2, so the next add also gets order 2. The file's own comment at line 553 explains this exact collision mechanism for scratch blocks and fixes it there but not here.
Trigger:   Delete any shortcut that is not the last one, then add a new one.
Blast:     Cosmetic: two chips with equal sort keys can swap positions between fetches. No crash.
Confidence: high
```

```
ID:        persistence-models-6
Location:  OnTime/Views/Routines/ScheduledRoutineEditor.swift:157
Class:     correctness
Claim:     delete(at:) indexes into a live computed array (`blocks` is `routine.orderedBlocks`, line 20) while deleting inside the loop, so a multi row delete can remove the wrong block or trap out of range if the relationship updates between iterations.
Evidence:  Lines 157 to 160: `for index in offsets { modelContext.delete(blocks[index]) }` where each `blocks` access re evaluates routine.orderedBlocks. Contrast the safe pattern in the same repo: LearnedStepsView and PlacesView index a @Query snapshot, and NowView.delete snapshots into a local before touching orders.
Trigger:   Edit mode multi select delete of two or more steps, if SwiftData removes deleted objects from the relationship before the loop finishes. Single swipe deletes (one index) are safe either way.
Blast:     Wrong step silently removed from a routine, or an index trap. Contained to the editor.
Confidence: medium, contingent on SwiftData's delete propagation timing, which I did not verify experimentally.
```

```
ID:        persistence-models-7
Location:  OnTime/Models/Place.swift:32
Class:     error-handling
Claim:     currentLocationSentinel swallows a fetch failure with try? and then falls through to inserting a fresh sentinel, recreating the duplicate sentinel bug the function exists to prevent.
Evidence:  Lines 32 to 38: `let existing = try? context.fetch(...)`; a thrown fetch makes `existing` nil, so `existing?.first` is nil and a new sentinel row is inserted even though one may exist.
Trigger:   Any fetch error at a call site of the sentinel.
Blast:     Multiple "Current Location" rows: identical in the UI, distinct TravelCacheKeys, clutter in the places list. Exactly the pathology the doc comment describes.
Confidence: high for the code path; low for how often fetch actually throws.
```

## Pass B: structural audit

### 1. Boundaries

- Spawn copy (Block.copyForSpawn, Block.swift:90): validated by PlanTests field by field; assumed exhaustive; when the assumption breaks (a new field), configuration silently vanishes on every routine spawn, the documented recurring bug. Enforcement is hand maintained, see test gap finding 10.
- Raw value bridging (Block.swift:74 and 107, TaskTemplate.swift:87): an unknown kindRaw or statusRaw silently becomes .fixed or .pending with no log. See finding 12.
- Weekday encoding (ScheduledRoutine.swift:54 to 61): compactMap silently drops any non integer garbage in weekdaysRaw; an empty set makes the routine never occur. The only guard against emptiness is the WeekdayPicker UI (ScheduledRoutineEditor.swift:228, which refuses to remove the last day); the model setter accepts an empty set without complaint. See finding 14.
- Store rebuild (OnTimeApp.swift:63 to 80): the seam validates nothing about why the open failed. See finding 4. Also, the sidecar removal at line 75 is try? so a failed removal leads to a second open failure and a fatalError at init, with the original incompatibility error already discarded from view (printed only).
- Template resolution (QuickBlockEditorSheet.resolveTemplate) creates TaskTemplates implicitly; that seam belongs to another subagent, noted here only as the sole producer of the pointer that finding 1 dangles.

### 2. Error handling

- OnTimeApp.deleteOrphanedRuns (lines 127 and 137): both the fetch and the save are try? with no fallback. A failed fetch skips cleanup entirely, and the very crash the function exists to prevent (documented at lines 108 to 124) then fires downstream in CountdownsView with no breadcrumb. A failed save silently undoes the deletions for next launch, which at least retries.
- openStore: see finding 4. The `print` at line 68 is the only record of a data wiping decision; on device it goes nowhere retrievable after the fact.
- Place.currentLocationSentinel: see finding 7.
- No caught and rethrown or logged errors exist anywhere else in the subsystem; the models themselves have no throwing paths. That is a clean result: within the model files, nothing swallows errors because nothing produces them.

### 3. State and lifetime

```
ID:        persistence-models-8
Location:  OnTime/Core/RunLauncher.swift:23 (creation site; no deletion site exists)
Class:     state
Claim:     Plans and finished Runs are never deleted anywhere in the codebase, so one Plan plus its Blocks plus one Run accumulate per run forever with no reader for the finished ones.
Evidence:  The complete set of delete sites (grep for context.delete/modelContext.delete) touches Run only in deleteOrphanedRuns (open runs with dead plans), Block, Place, TaskTemplate, DurationSample, QuickShortcut, and ScheduledRoutine. No site deletes a Plan or a finished Run. CountdownsView (line 12) and ArmedRoutineBanner (line 15) both filter `finishedAt == nil`, so finished rows are write only.
Trigger:   Normal daily use; a daily routine adds roughly 365 Plan plus Run plus N Block rows a year.
Blast:     Unbounded but slow store growth on a personal device. Also feeds finding 9. Partially deliberate: the memory notes say a Phase 4 run history feature will read these rows, so this is a known deferred cost rather than an oversight, but nothing caps it in the meantime.
Confidence: high
```

```
ID:        persistence-models-9
Location:  OnTime/App/OnTimeApp.swift:127
Class:     state
Claim:     Orphan cleanup covers only unfinished runs at launch, so a finished Run with a dead Plan pointer persists forever and becomes a guaranteed crash for the planned run history feature the moment it reads run.plan properties.
Evidence:  The fetch predicate at line 127 is `$0.finishedAt == nil`. A run finished before its Plan died (legacy rows from before the current conventions, or any future Plan deletion) is never examined. The comment at lines 108 to 124 explains that reading a property through such a pointer is an uncatchable fatalError.
Trigger:   Today: nothing, since nothing reads finished runs and nothing deletes Plans. Tomorrow: Phase 4 (run history with retroactive naming, per the memory notes) lists finished runs and shows run.plan?.name.
Blast:     A latent landmine shipped into a future feature; the cleanup that exists gives false comfort because it looks like it handles this class.
Confidence: high for the code shape; the row population it protects against is historical and unverified.
```

Other lifetime notes, no finding warranted: scratch blocks (plan nil, routine nil) are consumed by RunLauncher.start, which claims them into the new Plan, so they do not accumulate. ScheduledRoutine.skippedDays self prunes to a seven day window on every skip (ScheduledRoutine.swift:89 to 90); entries only linger if the user never skips again, bounded at seven. The Place sentinel row deliberately outlives everything.

### 4. Test gaps

```
ID:        persistence-models-10
Location:  OnTimeTests/PlanTests.swift:38
Class:     test-gap
Claim:     The copy fidelity test asserts only the twelve fields it already knows about, so the exact recurring bug it exists to catch (adding a Block field and forgetting copyForSpawn) does not fail it: the developer who forgets the copy also never adds the assertion.
Evidence:  spawnCopyCarriesEveryConfiguredField (lines 38 to 73) constructs a Block with explicit values and checks each by name. Nothing enumerates Block's stored properties mechanically (for example via Mirror child labels compared against an allow list of deliberately uncopied fields), so a new property passes untouched.
Trigger:   The next field added to Block.
Blast:     The invariant CLAUDE.md calls out as a known recurring bug regresses silently; routines spawn plans that drop the new configuration.
Confidence: high
```

```
ID:        persistence-models-11
Location:  OnTimeTests/PlanTests.swift:1 (absence)
Class:     test-gap
Claim:     Several behaviors a reader would expect covered here are untested: Schema0 completeness (that a container over Schema0.models can insert and fetch every model type), renumber healing duplicate order values, weekdaysRaw round trip including the empty and garbage string cases, skippedDays pruning, and deleteOrphanedRuns behavior.
Evidence:  The whole persistence test surface is PlanTests.swift (three spawn tests) plus OnTimeTests.swift (one renumber test that covers gaps but not duplicates). No test builds an in memory ModelContainer at all, so nothing exercises actual SwiftData behavior: cascade rules, relationship ordering, or fetch after save fidelity; every existing test runs on unmanaged instances.
Trigger:   Any regression in the untested behaviors, most plausibly a model added to the code but not to Schema0.models, which CLAUDE.md documents as failing with silent empty fetches and no error anywhere.
Blast:     The failure mode the Schema0 comment warns about has no automated tripwire; it would ship and present as data mysteriously missing.
Confidence: high
```

The existing tests assert behavior, not implementation, with one caveat: planRenumberProducesSequentialOrder (OnTimeTests.swift:16) pins the tie handling of a sort on unmanaged in memory arrays, which is fine today but tests instances that never pass through a ModelContext, so it cannot catch SwiftData reordering, the very thing orderedBlocks exists for.

### 5. Load bearing assumptions

```
ID:        persistence-models-12
Location:  OnTime/Models/Block.swift:74
Class:     assumption
Claim:     Unknown kindRaw or statusRaw values silently coerce to .fixed and .pending, so removing or renaming a BlockKind case reclassifies existing rows with no signal, and because kindRaw is a String this does not trip the schema mismatch rebuild.
Evidence:  `BlockKind(rawValue: kindRaw) ?? .fixed` (Block.swift:74), `BlockStatus(rawValue: statusRaw) ?? .pending` (Block.swift:108), same pattern at TaskTemplate.swift:87. The walk feature relied on exactly this looseness to add a case with no migration (per CLAUDE.md), so the same door swings both ways.
Trigger:   A future rename or removal of an enum case with rows already stored under the old string.
Blast:     A walk block quietly becomes a fixed block with no duration logic; no error, no wipe, just wrong scheduling.
Confidence: high
```

```
ID:        persistence-models-13
Location:  OnTime/Models/Plan.swift:20
Class:     assumption
Claim:     The safety of the four unpaired to one pointers (Run.plan, Plan.routine, Block.template, Block and TaskTemplate place pointers) rests entirely on the convention that their targets are never deleted while referenced, and only Run.plan has both the documentation and a (partial) compensating cleanup.
Evidence:  Plan.swift lines 15 to 28 document the design for Run.plan and its cleanup contract. No equivalent comment or cleanup exists for Plan.routine, Block.template, or the place pointers, yet the UI deletes their targets today (findings 1 to 3). Nothing enforces the convention; it is invisible at the deletion call sites.
Trigger:   Any new or existing deletion affordance touching TaskTemplate, Place, or ScheduledRoutine.
Blast:     Findings 1 through 3 are this assumption already broken; a future maintainer adding a delete button elsewhere breaks it again with no compiler or test pushback.
Confidence: high
```

```
ID:        persistence-models-14
Location:  OnTime/Models/ScheduledRoutine.swift:54
Class:     boundary
Claim:     An empty weekdays set is representable in the model and means the routine silently never occurs; the only guard lives in one picker widget.
Evidence:  The weekdays setter (line 56) happily encodes an empty set to "", the getter decodes "" to an empty set, and ScheduleService occurrence math then never matches a day. WeekdayPicker (ScheduledRoutineEditor.swift:228) refuses to deselect the last day, which is the sole enforcement.
Trigger:   Any future writer of routine.weekdays that is not that one picker (a new editor, a shortcut intent, a migration script).
Blast:     A routine that looks configured but never arms, with no error and no visible reason.
Confidence: high
```

Also load bearing and verified true today, enforced nowhere: the orderedBlocks/renumber discipline itself. Every current reader and mutator complies (see the clean results list at the top), but compliance is convention plus doc comments; orderedBlocks uses an unstable sort (Plan.swift:42), so the discipline is the only thing standing between duplicate order values and nondeterministic step order.

### 6. Enhancements (ranked, not bugs)

1. Referrer nullification before delete: a small helper that, given a TaskTemplate, Place, or ScheduledRoutine, fetches referrers by predicate and nils the pointers before context.delete, the same pattern deleteOrphanedRuns already uses. One function, three call sites (LearnedStepsView.swift:41, PlacesView.swift:121, ScheduledRoutinesView.swift:85), retires findings 1 to 3 and most of finding 13.
2. Scope the openStore rebuild: match the thrown error against the schema mismatch cases (or at minimum move the old store file aside with a timestamp instead of removing it) so a transient error costs a launch, not the data. Addresses finding 4 within the documented policy.
3. Mechanical exhaustiveness for copyForSpawn: a test that walks Mirror(reflecting: Block()) child labels, subtracts the documented allow list of uncopied fields (actualStart, actualEnd, statusRaw, plan, routine, backing storage noise), and asserts every remaining label round trips through copyForSpawn. Turns the advisory test into a tripwire; addresses finding 10.
4. One in memory ModelContainer test over Schema0.models that inserts and fetches one row of each model type. Cheap, and it is the only automated way to catch the silent empty fetch failure the Schema0 comment warns about; addresses half of finding 11.
5. Rename Block.isOpenEnded to something like autoAdvances. It sits one file away from BlockKind.isOpenDuration while meaning something unrelated (auto advance versus wait for tap), and the doc comment at Block.swift:39 has to spend six lines undoing the name. Rename plus a store wipe is free under the no migration policy.

## Finding count

correctness 5 (findings 1, 2, 3, 5, 6), error-handling 2 (4, 7), state 2 (8, 9), test-gap 2 (10, 11), assumption 2 (12, 13), boundary 1 (14). Total: 14 findings plus 5 ranked enhancements.
