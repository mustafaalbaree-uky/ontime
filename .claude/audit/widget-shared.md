# Audit: widget-shared

Subsystem: Live Activity rendering (Dynamic Island and Lock Screen) in OnTimeWidget/, plus the data only types in Shared/ that compile into both the app and the widget extension. The seam is ContentState (serialized by ActivityKit) plus one App Intent that hops back to the app process via NotificationCenter.

Scope reviewed: OnTimeWidget/OnTimeLiveActivity.swift, OnTimeWidget/OnTimeWidgetBundle.swift, OnTimeWidget/Info.plist, Shared/OnTimeActivityAttributes.swift, Shared/OnTimeIntents.swift, Shared/OnTimeShared.swift. Evidence consulted (findings not located there): OnTime/Services/LiveActivityManager.swift, OnTime/Services/RunEngineStore.swift, OnTime/Services/Notifications.swift, OnTime/Core/RunEngine.swift, OnTime/Views/RootView.swift, project.yml.

## Pass A: mechanical review

```
ID:        widget-shared-1
Location:  Shared/OnTimeActivityAttributes.swift:18
Class:     correctness
Claim:     ContentState.isFinished is written by the app (LiveActivityManager.finish sets it true) but never read by any view in OnTimeLiveActivity.swift, so the final "run finished" frame designed for it never renders.
Evidence:  grep for isFinished over OnTimeWidget/*.swift returns nothing. RunPhase.resolve (OnTimeLiveActivity.swift:22) consults only isStale, isOverrun, targetLeaveBy, and endsRunAtTarget. LiveActivityManager.finish (LiveActivityManager.swift:183) sets state.isFinished = true and ends with dismissalPolicy .after(.now + 10).
Trigger:   User completes the last step early (before its targetLeaveBy) in the app or via the button. The end content has a future target, isStale false (staleDate nil), isOverrun false, so phase resolves to .running.
Blast:     For the roughly 10 second dismissal window, the Lock Screen and Dynamic Island show a still ticking countdown and a live "Finish Plan" button on a run that is already over; tapping the button posts an advance for a retired engine (silent no op). The green "Done" frame the field exists for is unreachable.
Confidence: high
```

```
ID:        widget-shared-2
Location:  OnTimeWidget/OnTimeWidgetBundle.swift:16
Class:     correctness
Claim:     PlaceholderWidget's content view has no .containerBackground(for: .widget), which on the iOS 17 deployment target makes the home screen widget render the system "Please adopt containerBackground API" error view instead of the text.
Evidence:  StaticConfiguration closure at line 16 returns bare Text("On Time") with no containerBackground modifier and no .containerBackgroundRemovable; project.yml sets deploymentTarget iOS 17.0, where WidgetKit requires the API for non Live Activity widgets.
Trigger:   User adds the "On Time" widget from the widget gallery, or browses the gallery preview.
Blast:     Cosmetic but user visible: the only home screen widget the bundle offers is broken looking. Does not affect the Live Activity.
Confidence: medium (well known iOS 17 behavior; not verified on this device in this audit)
```

```
ID:        widget-shared-3
Location:  OnTimeWidget/OnTimeLiveActivity.swift:48
Class:     correctness
Claim:     The Lock Screen view pins a dark background (activityBackgroundTint black at 0.75) while its text uses adaptive Color.primary and Color.secondary, so in a light rendering context the text can resolve to near black on the forced dark background.
Evidence:  Line 48 sets the tint; lines 211, 215, 228, 240, 247, 255 use .primary or .secondary. Nothing forces .environment(\.colorScheme, .dark) or explicit white text.
Trigger:   iOS renders the Lock Screen activity (or StandBy or banner presentation) with a light color scheme, which the system chooses based on wallpaper and context; a custom background tint does not flip the scheme.
Blast:     Low contrast or unreadable text on the primary surface of the whole feature.
Confidence: low (mechanism is real, but whether this device ever renders the activity in light scheme was not verified)
```

```
ID:        widget-shared-4
Location:  OnTimeWidget/OnTimeLiveActivity.swift:90
Class:     correctness
Claim:     When the wait phase's target passes while the app is suspended, the widget shows an "over" state ("over — waiting on you", orange, counting up) even though the run is not stuck on the user: checkWaitTimeElapsed auto starts step 1 on the next app wake, and the widget offers no button because isWaiting suppresses it.
Evidence:  RunPhase.resolve (line 22) maps any past target with endsRunAtTarget false to .over; during the wait, RunEngine sends endsRunAtTarget false (RunEngine.swift:478 gates it on !isWaitingToStart) and latenessMinutes nil, so lines 90 and 249 render the "waiting on you" text; lines 110 and 261 hide the button while isWaiting.
Trigger:   Run launched ahead of its natural start, then the phone sits locked past the step 1 start time.
Blast:     Misleading urgency on the Lock Screen ("waiting on you" with nothing to tap) until the app next runs; the state is self healing but the message is wrong for its whole duration.
Confidence: medium
```

```
ID:        widget-shared-5
Location:  Shared/OnTimeShared.swift:6
Class:     correctness
Claim:     The OnTimeShared doc comment is stale: it says the file is "Empty for now" and that "later stages put the Live Activity attributes and App Group constants here", but the attributes have long lived in Shared/OnTimeActivityAttributes.swift and the enum has stayed an empty placeholder.
Evidence:  Lines 3 through 6 versus the existence of OnTimeActivityAttributes.swift in the same directory.
Trigger:   Anyone reading Shared/ to learn where the cross target contract lives.
Blast:     Documentation only, but it points at the one natural home for the shared constants that finding widget-shared-10 shows are currently duplicated string literals.
Confidence: high
```

Checked and clean (Pass A):

- The ring genuinely guards every degenerate span. ringInterval (OnTimeLiveActivity.swift:32) returns nil unless segmentStart < targetLeaveBy, so a zero length or inverted span cannot reach ProgressView(timerInterval:), which traps on a non ascending range; the fallback is a static tinted circle (line 194). A span entirely in the past resolves to phase .over before the ring branch (line 23), and a span whose start is past but whose end is future renders a partially depleted ring, which is correct. The walk feature's reused targetLeaveBy therefore draws safely for any values.
- Negative interval formatting: every countdown uses Text(style: .timer), which counts up past the target instead of showing a negative value, and the .over phase relabels it in orange. No hand rolled interval formatting exists to get a sign wrong.
- Hours rollover in the compact trailing slot: 7 to 8 monospaced callout glyphs at minimumScaleFactor 0.7 fit inside the fixed 52 point frame (line 143) by arithmetic; no clipping expected below 10 hours, which the domain cannot produce.
- Date based text going stale: the only Date() reads at render time are RunPhase.resolve and CountdownRing.tint, and both are re evaluated at the app pushed updates and at the staleDate re render; the ticking text itself is all system driven (style .timer, style .time). No Text renders a snapshot interval that would freeze.
- Info.plist is a minimal correct widgetkit extension plist; NSSupportsLiveActivities is correctly declared in the app target's Info.plist (OnTime/Info.plist:33), not the extension's.

## Pass B: structural audit

### 1. Boundaries: the ContentState seam and intent execution context

What the widget assumes about app sent values, and what renders when the assumption is wrong:

- segmentStart <= targetLeaveBy and both meaningful: guarded (ringInterval nil fallback). Wrong values degrade to a static circle, never a crash.
- blockIndex in 0..<totalBlocks and totalBlocks >= 1: not guarded. Lines 63, 114, 130, 213, 265 render "Step \(blockIndex + 1) of \(totalBlocks)" and choose the "Finish Plan" button label from blockIndex + 1 >= totalBlocks. Out of range values render nonsense text and can mislabel the button, nothing crashes. Today RunEngine sends run.currentIndex and blocks.count consistently (RunEngine.swift:489, 490).
- targetLabel ends with a trailing space: not guarded (see widget-shared-9).
- staleDate always equals the step target: the entire phase inference rests on it (see widget-shared-8).
- latenessMinutes semantics: doc and rendering disagree (see widget-shared-7).
- isFinished meaningful: assumed by the app side, ignored by the widget (widget-shared-1).

Intent execution context: CompleteStepIntent is a LiveActivityIntent, so perform() runs in the app's process, not the extension's; the system launches the app in the background when it is not running. See widget-shared-6 for what happens on that cold path.

```
ID:        widget-shared-6
Location:  Shared/OnTimeIntents.swift:25
Class:     boundary
Claim:     A "Complete Step" tap is silently lost when the app process is dead: perform() posts an in process NotificationCenter notification whose only observer is registered lazily in RunEngineStore.init, which is first touched from RootView's .task, and a background app launch to service a LiveActivityIntent never brings RootView on screen.
Evidence:  perform() (lines 25 to 32) posts "OnTimeAdvanceStepFromIntent" and returns .result() unconditionally. The observer registers in RunEngineStore.init (RunEngineStore.swift:25), reached only via RunEngineStore.shared, whose first touch is RootView.swift:60 inside resumeOpenRuns, called from the .task at RootView.swift:29. Even with the observer live, advanceRun (RunEngineStore.swift:37) silently returns when no engine matches the planId, and on a cold background launch no engines exist.
Trigger:   The app is terminated (jetsam or force quit) while the Live Activity is still showing, then the user taps Complete Step or Finish Plan on the Lock Screen or expanded island.
Blast:     The button animates, the intent reports success, and nothing happens: the step is not completed, the activity keeps counting, and there is no error anywhere. The tap is unrecoverable because nothing persists it for the next real launch.
Confidence: medium (the in process post and lazy observer are verified in code; the exact scene behavior of a background intent launch is inferred from AppIntents documentation)
```

### 2. Error handling

- CompleteStepIntent.perform (Shared/OnTimeIntents.swift:25) has no failure path at all: it cannot throw, it does not check that anyone received the notification, and it returns .result() regardless. Combined with widget-shared-6, every lost tap is reported to the system, and the user, as success. A perform that instead touched the store directly (or persisted a pending advance for launch time reconciliation) could fail loudly or recover.
- Rendering has no error states to handle: all ContentState fields are non optional except latenessMinutes, so a decode failure surfaces only as ActivityKit dropping the update (outside this code). The widget's fallbacks (ringInterval nil circle, nil lateness text) are total; no rendering path can crash on data.
- The intent's parameterless init (line 16) sets planId to "", which advanceRun drops silently; acceptable, but it is a third silent path on this button.

### 3. State and lifetime

- The widget itself is stateless: RunPhase and tint are recomputed per render, ringInterval is derived, nothing is cached across renders. Renders happen only on app pushes and at the staleDate.
- After the app is killed: the ring keeps depleting (system animated), the .timer text keeps ticking (system animated), and the staleDate re render at the target flips the display to finished or over. That is the designed degradation and it works because staleDate is always the target.

```
ID:        widget-shared-7
Location:  Shared/OnTimeActivityAttributes.swift:41 and OnTimeWidget/OnTimeLiveActivity.swift:90
Class:     boundary
Claim:     The documented latenessMinutes contract ("nil / <= 0 means still on track") does not match the rendering, which distinguishes nil ("over — waiting on you") from <= 0 ("over — still on time"), so a nil that means "solver has no current solution" renders as a claim about what the user is doing.
Evidence:  Doc comment at OnTimeActivityAttributes.swift:36 to 41; rendering at OnTimeLiveActivity.swift:90 and 249 maps nil and non positive values to different strings. App side, RunEngine.swift:498 sends overrun ? latenessMinutes : nil, and RunEngine.latenessMinutes (RunEngine.swift:93) is itself nil whenever currentSolution is nil, so an overrun with no solution sends nil.
Trigger:   Any overrun state where the solver currently has no solution, and any future app side caller that takes the doc comment at its word and sends nil for "on track" during an overrun.
Blast:     Wrong subtitle on the most attention grabbing state the widget has; the field's meaning is defined informally in two places that already disagree.
Confidence: medium
```

```
ID:        widget-shared-8
Location:  OnTimeWidget/OnTimeLiveActivity.swift:23
Class:     state
Claim:     Phase inference after the app dies works only because every app push sets staleDate to the step target; nothing on either side of the seam enforces that, and an update path that passes a nil or distant staleDate silently reverts to the old bug of a bare number ticking upward forever.
Evidence:  RunPhase.resolve's own comment (lines 5 to 10) names LiveActivityManager.staleDate as the mechanism; the contract lives entirely in LiveActivityManager.swift:178 (max(target, now + 1)) and is applied per call at lines 123 and 168. finish() at line 187 already legitimately passes staleDate nil, so the convention has exceptions and no assertion.
Trigger:   A future update call (new feature, refactor of LiveActivityManager) that forgets staleDate or sets it past the target, then a step target passing while the app is suspended.
Blast:     The widget shows a live looking countdown counting up with no over or finished labeling until the app next runs; exactly the historical bug the comment describes, reintroduced with no compile time or test signal.
Confidence: high (that it is unenforced; the break requires a future change)
```

```
ID:        widget-shared-9
Location:  OnTimeWidget/OnTimeLiveActivity.swift:66
Class:     assumption
Claim:     Readable target text depends on targetLabel arriving with a trailing space, a convention enforced nowhere on either side of the seam.
Evidence:  Lines 66 and 226 render Text(state.targetLabel) + Text(state.targetLeaveBy, style: .time) with no separator; the space comes from the app appending " " at RunEngine.swift:475 and from the default value "Finish by " at OnTimeActivityAttributes.swift:61.
Trigger:   Any new app side call site that passes a label without the trailing space.
Blast:     Cosmetic ("Finish by7:15") on both Lock Screen and expanded island; quiet because both current sources happen to comply.
Confidence: high
```

```
ID:        widget-shared-10
Location:  Shared/OnTimeIntents.swift:27
Class:     assumption
Claim:     The routing key of the whole button path, the string "OnTimeAdvanceStepFromIntent", is a bare literal duplicated in three files across the target seam, so a rename in one place disconnects the button or the notification action with no compile error.
Evidence:  Identical literals at Shared/OnTimeIntents.swift:27, OnTime/Services/RunEngineStore.swift:26, OnTime/Services/Notifications.swift:396. Shared/OnTimeShared.swift:6 is the declared home for exactly such constants and is empty.
Trigger:   Any rename or typo in one of the three literals.
Blast:     Complete Step (from the activity or from a notification action) silently stops working; the failure looks identical to widget-shared-6.
Confidence: high
```

```
ID:        widget-shared-11
Location:  OnTimeWidget/OnTimeLiveActivity.swift:169
Class:     state
Claim:     The green to red ramp exists twice, computed independently on each side of the seam: CountdownRing.tint derives the fraction from Date() at render time while RunEngine.rampBucket decides when renders happen, so the tint is only as fresh as the last push and freezes (documented) once the app stops pushing, and the two formulas agree only informally.
Evidence:  tint at lines 169 to 174 (hue from fraction of span); RunEngine.swift:154 to 161 computes the same fraction in twentieths to gate pushes; the comment at lines 157 to 162 states the freeze behavior outright. isStale re render at the target gives one final tint update; between the last push and the target the ring depletes while the color lags.
Trigger:   App suspended or killed mid step; also any future change to one formula but not the other (for example a ramp that starts amber at 50 percent).
Blast:     A visibly desynchronized ring color near the end of a step with the app dead; drift risk if either formula changes alone. Not incorrect today, and partly by design.
Confidence: high
```

### 4. Test gaps

```
ID:        widget-shared-12
Location:  OnTimeWidget/OnTimeLiveActivity.swift:22
Class:     test-gap
Claim:     Every piece of pure logic in the widget (RunPhase.resolve's four way truth table, ringInterval's span guard, the tint hue formula, and the lateness label mapping) is untestable as written because it is private to a widget extension target that no test target compiles.
Evidence:  RunPhase, the ContentState extension, and CountdownRing are all private in OnTimeLiveActivity.swift (lines 11, 29, 163); project.yml's OnTimeTests depends only on the OnTime app target, and no test file references any of these. These functions are exactly the ones findings 1, 4, 7, and 8 turn on.
Trigger:   Any change to phase resolution or the ramp; today's isFinished bug (widget-shared-1) is the kind a truth table test would have caught.
Blast:     The subsystem's only correctness signal is looking at a phone.
Confidence: high
```

### 5. Load bearing assumptions (true today, enforced nowhere)

- Both targets compile the same Shared/ sources: project.yml lists path Shared under both OnTime and OnTimeWidget sources, so drift between two copies cannot happen; this one is enforced by the build and is fine.
- staleDate always equals the current step target: widget-shared-8.
- targetLabel carries its own trailing space: widget-shared-9.
- The notification name literal matches in three files: widget-shared-10.
- latenessMinutes nil versus non positive meaning: widget-shared-7.
- blockIndex and totalBlocks are consistent and in range: unguarded but currently upheld by a single producer (RunEngine.swift:489).
- planId equality across the seam: attributes.planId is "\(plan.id)" string interpolation on both sides (RunEngine.swift:474, RunEngineStore.swift:38); stable, but it is a stringly typed key with its format defined by convention at every call site.
- Color.accentColor in the widget currently matches the app only because the app's AccentColor.colorset is empty (system default); if the app ever gets a real accent, the widget target, which includes no asset catalog and sets no global accent build setting in project.yml, silently keeps default blue.

### 6. Enhancements (ranked, not bugs)

1. Extract RunPhase, ringInterval, the tint formula, and the lateness label mapping into Shared/ as internal pure functions so OnTimeTests can cover them (directly addresses widget-shared-12, and gives findings 1, 4, 7, 8 a place to be pinned by tests).
2. Give OnTimeShared its promised job: the notification name, the planId formatting, and the label building ("Finish by" plus separator handled in one place) as constants and helpers used by all three current literal sites (retires widget-shared-9 and widget-shared-10, unstales widget-shared-5).
3. Make CompleteStepIntent robust to a dead app: have perform() call into the store (or persist a pending advance keyed by planId that launch time reconcile consumes) instead of posting a notification, so a Lock Screen tap survives process death (addresses widget-shared-6 structurally, not just its symptom).
4. Add a distinct wait elapsed presentation (for example a startsRunAtTarget flag mirroring endsRunAtTarget) so a passed wait target reads as "Step 1 underway" rather than "over — waiting on you" (the honest version of widget-shared-4).
5. Either finish the placeholder home screen widget (memory notes Phase 5 is a planned home screen widget) or remove it from the bundle; as shipped it is a visible gallery entry that renders an error view (widget-shared-2).
