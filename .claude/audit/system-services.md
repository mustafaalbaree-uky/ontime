# Subsystem audit: system-services

Wrappers over UserNotifications (Notifications.swift), ActivityKit (LiveActivityManager.swift), and observable persisted settings (AppSettings.swift). These files are the delivery layer for the app's core safety promise: the arm alarm and the walk turnaround alarm must fire even when the app is dead, and the Live Activity must show the truth when it is suspended.

Scope reviewed: OnTime/Services/Notifications.swift (405 lines), OnTime/Services/LiveActivityManager.swift (217 lines), OnTime/Services/AppSettings.swift (108 lines), plus every caller of their public API (RunEngine, ScheduleService, WalkTracker, RootView, OnTimeApp, RunEngineStore) read for seam verification only.

---

## Pass A: mechanical review

```
ID:        system-services-1
Location:  OnTime/Services/LiveActivityManager.swift:45
Class:     correctness
Claim:     A Live Activity whose staleDate has passed is invisible to the manager, so it is never updated, never ended, and gets a duplicate requested next to it.
Evidence:  current(for:) at lines 44 to 51 filters on activityState == .active in both the cache check and the Activity.activities scan. staleDate(for:) at line 179 is max(target, now + 1), so the state transitions to .stale one second after any update once the target has passed (ActivityKit moves activityState to .stale when staleDate passes). From then on: hasActivity (line 65) returns false, so RunEngine.syncLiveActivityAndNotifications (RunEngine.swift:484) takes the start branch instead of update; start's "end previous" step (line 97) also uses current(for:), misses the stale activity, and requests a brand new one. finish (line 184) and end (line 194) likewise no op, leaving the stale card on the Lock Screen.
Trigger:   Any run whose current target passes while the app is suspended (the normal overrun case the staleDate was added for), followed by any later sync, finish, or cancel.
Blast:     Two cards for the same plan on the Lock Screen, or a dead card that survives finishing the run until the next launch's endOrphans or the system's eight hour cleanup. This may be the same symptom the `starting` set was added to fix (its doc at lines 34 to 42 describes duplicate countdowns appearing at random); that fix closed the concurrent request race but not this path.
Confidence: high on the code path; the .stale transition at staleDate is per ActivityKit documented behavior, not re-verified on device.
```

```
ID:        system-services-2
Location:  OnTime/Services/Notifications.swift:127
Class:     correctness
Claim:     armAlarm removes the existing pending alarm and then silently schedules nothing when the new fire time is already past, so a walk turnaround estimate that degrades into the past disarms the very alarm it was refining.
Evidence:  Line 127 removes the pending request for the id, line 128 is `guard fireAt > Date() else { return }`. WalkTracker.rearmAlarmsIfNeeded (WalkTracker.swift:317 to 337) calls this with turnaroundAt, which is homeBy minus the return estimate with no clamp to the future (WalkTracker.swift:258 to 261). If a fix arrives showing a slower pace and the recomputed turnaround is now in the past, the previously armed "Turn around now" request (which would at least have fired, merely late) is removed and no notification of any kind replaces it.
Trigger:   Outbound walk phase, background location updates flowing, return estimate grows enough that homeBy minus estimate crosses behind now before the previously armed time arrives. Exactly the moment the user is already late to turn around.
Blast:     No turnaround alert at all on that walk; the file's own safety argument ("the last alarm armed still fires") is violated because the last alarm armed was deleted. The heads up alarm dies the same way ten minutes earlier. Fix direction: when fireAt is past, fire immediately (schedule with a nil or one second trigger) instead of disarming.
Confidence: high
```

```
ID:        system-services-3
Location:  OnTime/Services/Notifications.swift:249
Class:     correctness
Claim:     Delivered notifications are never removed anywhere in the app, so the doc's promise that "the next refreshArmAlarms clears whatever is left over" is only true for alerts that have not fired yet.
Evidence:  cancelAllArmAlarms calls only removePendingNotificationRequests (lines 251 and 272), which does not touch delivered notifications. A repo wide search for removeDeliveredNotifications and removeAllDeliveredNotifications finds zero hits. The design comment at lines 158 to 165 builds a chain of up to seven alerts precisely so they pile up in Notification Center, and claims the refresh clears the leftovers once the routine arms.
Trigger:   A routine arms and the user starts the run partway through the alert chain; the already delivered "Starts in N min" banners stay stacked in Notification Center after the run is underway, and stale ones from cancelled runs stay after cancellation.
Blast:     Cosmetic but recurring: outdated instructions ("Starts in 20 min") sit on the Lock Screen during and after the run they announced. Same applies to delivered step notifications after a run is cancelled.
Confidence: high
```

```
ID:        system-services-4
Location:  OnTime/Services/Notifications.swift:39
Class:     boundary
Claim:     The notification center delegate is set asynchronously after app init, so a notification action that cold launches the app can be delivered before the delegate exists and the action is dropped.
Evidence:  center.delegate = self runs in Notifications.init, and Notifications.shared is first touched inside `Task { @MainActor in ... }` in OnTimeApp.init (OnTimeApp.swift:28 to 31). That task body runs when the main actor next yields, which is not guaranteed to be before the launch sequence delivers the response; UNUserNotificationCenter documentation requires the delegate to be in place before the app finishes launching to receive the launching notification's didReceive. Additionally, the didReceive handler posts NSNotification "OnTimeAdvanceStepFromIntent" (line 395), whose only observer is registered in RunEngineStore.init (RunEngineStore.swift:26), first touched from RootView.resumeOpenRuns; on a cold launch the post can precede the observer.
Trigger:   App not running, user taps "Next Step" on a run step notification (or the notification body).
Blast:     The app opens but the step does not advance; the user thinks the tap did not register. Both orderings are timing dependent, so it works in testing and fails intermittently.
Confidence: medium (inferred from documented UNUserNotificationCenter behavior and main actor scheduling; not reproduced on device)
```

```
ID:        system-services-5
Location:  OnTime/Services/Notifications.swift:114
Class:     error-handling
Claim:     Every center.add call in the file discards its result, and requestAuthorization flattens thrown errors into false, so a failed schedule is indistinguishable from a successful one everywhere.
Evidence:  center.add(req) with no completion handler at lines 114, 139, 200, 315, 338. requestAuthorization (line 78) is `(try? ...) ?? false`. No add failure is logged, retried, or surfaced.
Trigger:   Authorization denied or revoked, the 64 pending request limit exceeded, or any UserNotifications error.
Blast:     Alarms the code believes are armed do not exist. Because scheduledIdentifiers and armAlarmIdentifiers are updated unconditionally after add, the bookkeeping also claims requests that were never accepted.
Confidence: high
```

```
ID:        system-services-6
Location:  OnTime/App/OnTimeApp.swift:30
Class:     error-handling
Claim:     Nothing in the app ever reads notification authorization status after the one launch prompt, so a denial permanently and silently disables the guaranteed arming layer and every walk alarm.
Evidence:  `_ = await Notifications.shared.requestAuthorization()` discards the grant. A repo wide search for getNotificationSettings and UNAuthorizationStatus finds zero hits (the authorizationStatus hits are all CLLocationManager). SettingsView shows location fix state (SettingsView.swift:64) but nothing about notifications.
Trigger:   User taps "Don't Allow" once, or later disables notifications in system Settings.
Blast:     Scheduled routines never announce themselves and the walk turnaround alarm never fires, with no indication anywhere in the app that this is why. CLAUDE.md calls the local notification "the one guaranteed layer"; after a denial there is no guaranteed layer.
Confidence: high
```

```
ID:        system-services-7
Location:  OnTime/Services/Notifications.swift:81
Class:     state
Claim:     cancelAllRunNotifications removes every pending request in the app, not just run notifications, and the only thing preventing it from erasing future routine arm alarms is call ordering in RootView that nothing enforces.
Evidence:  Line 82 is removeAllPendingNotificationRequests. RootView.resumeOpenRuns calls it when no runs are open (RootView.swift:69), which wipes any arm alarms scheduled in a previous session; they come back only because armScheduledRoutines runs immediately after in the same .task (RootView.swift:29 to 32). The method also does not clear armAlarmIdentifiers, leaving that set pointing at requests that no longer exist.
Trigger:   Any future caller trusting the name and calling it while routines have pending arm alarms, without a refreshArmAlarms afterward.
Blast:     Every scheduled routine loses its guaranteed notification layer until the next foreground. Latent today, one refactor away from real.
Confidence: high on behavior, medium on likelihood of it biting
```

```
ID:        system-services-8
Location:  OnTime/Services/Notifications.swift:225
Class:     correctness
Claim:     armAlertTimes dedupes only instants within one second of each other, while its own comment claims anything within half a reminder interval of the start reads as a duplicate, so two alerts can fire under a minute apart.
Evidence:  Comment at lines 222 to 223 says "Near identical instants (within half a reminder interval of the start)"; the code at line 225 keeps any element more than 1 second after its predecessor. With armAt 12:00 and mustStartAt 12:50:30, the 12:50 reminder and the 12:50:30 final alert both survive.
Trigger:   A lead time whose length modulo the ten minute reminder step is between about 2 seconds and a few minutes.
Blast:     Two near simultaneous notifications at the most attention critical moment; cosmetic, but exactly what the dedup was written to prevent.
Confidence: high
```

```
ID:        system-services-9
Location:  OnTime/Services/LiveActivityManager.swift:91
Class:     correctness
Claim:     A start call that loses the in flight race reports .started even though the winning request may subsequently fail, so the caller can show success feedback for an activity that never appeared.
Evidence:  `guard !starting.contains(planId) else { return .started }` returns before the winner's Activity.request has resolved; the winner may return .failed at line 131.
Trigger:   Two syncs race a start and the underlying request throws (rate limit, system cap).
Blast:     One RunEngine sees .failed and sets startFailureMessage, the other saw .started; whichever ran the UI path last wins. Small, and self heals on the next sync.
Confidence: high on the code, low on user visible impact
```

```
ID:        system-services-10
Location:  OnTime/Services/LiveActivityManager.swift:199
Class:     state
Claim:     endAll clears the starting set while a start may still be awaiting Activity.request, so the surviving request can register a live activity after endAll finished ending everything.
Evidence:  Lines 200 to 201 clear activities and starting synchronously; an in flight start already past its guard proceeds to line 121 and stores a fresh activity. endAll's loop over Activity.activities (line 202) ran before that request existed.
Trigger:   endAll (RootView.swift:70, the no open runs launch path) racing a start fired from a still ticking engine. Narrow, since that launch path implies no engines, but nothing in the type system keeps a future caller in that window.
Blast:     One orphan Live Activity that outlives the reset until the next launch.
Confidence: medium (race verified by reading, window plausibility inferred)
```

```
ID:        system-services-11
Location:  OnTime/Services/Notifications.swift:19
Class:     state
Claim:     scheduledIdentifiers is in memory only, so after a relaunch cancelRunNotifications(planId:) is a no op for requests scheduled in the previous session, and the thing that rescues it is the deterministic identifier scheme, which is enforced nowhere.
Evidence:  The map is a plain instance property; nothing persists it. Cancellation removes only ids found in the map (line 90). It works across relaunches only because a resumed engine calls scheduleRunNotifications first (RunEngine.swift:111 then 459), whose identifiers "ontime-lead/due-planId-blockId-index" (lines 313 and 336) reproduce the previous session's exactly, so the re add replaces them and repopulates the map.
Trigger:   Cancelling a resumed run before its first sync, or any change that makes the identifier scheme non deterministic (adding a timestamp or UUID component).
Blast:     Ghost step notifications from the previous session fire for a cancelled run.
Confidence: medium
```

```
ID:        system-services-12
Location:  OnTime/Services/Notifications.swift:101
Class:     enhancement
Claim:     scheduleQuickCountdownNotification and cancelQuickCountdownNotification have zero callers anywhere in the repo; the pair and its identifier are dead code whose doc comment still claims NowView uses it.
Evidence:  Repo wide search for QuickCountdownNotification and "quick-leaveby" matches only Notifications.swift lines 94 to 119. NowView's quick countdown, per the armAlarm doc at lines 121 to 125, was evidently migrated to armAlarm(id:), though armAlarm's only current callers are in WalkTracker.
Trigger:   Always; it is unreachable.
Blast:     None at runtime; misleads readers about how the quick countdown notifies.
Confidence: high
```

Checked for and not found in scope: identifier collisions between the notification families (prefixes ontime-lead, ontime-due, ontime-quick-leaveby, ontime-walk-*, ontime-routine-arm- are mutually exclusive); async misuse inside cancelAllArmAlarms (the completion time filter at lines 266 to 274 correctly handles the reschedule race its comment describes); and re entrancy in start (the starting set claim at lines 91 to 93 has no await between check and insert, as documented).

---

## Pass B: structural audit

### 1. Boundaries

Data enters and leaves this subsystem at four seams.

Notification payloads out and back: only run step notifications carry userInfo, a single "planId" string (Notifications.swift:309, 332). It comes back through didReceive as an unvalidated `as? String` cast (line 394) and is rebroadcast via NSNotification for RunEngineStore to match against "\(p.id)". Nothing validates that the plan still exists; a stale planId simply matches no engine and the tap silently does nothing, which is acceptable, but see system-services-4 for the case where the observer does not exist yet.

```
ID:        system-services-13
Location:  OnTime/Services/Notifications.swift:394
Class:     boundary
Claim:     The planId round trip through notification userInfo fails silently at every step: missing key, wrong type, or a plan deleted since scheduling all produce a no op with no log.
Evidence:  `as? String` guard at line 394 drops mismatches; the NSNotification post has no acknowledgement; RunEngineStore matches by string equality against live engines.
Trigger:   Tapping Next Step on a notification for a plan cancelled after the notification fired.
Blast:     None functionally (the right outcome is nothing), but a genuine bug here would be undiagnosable.
Confidence: high
```

ActivityKit process boundary: OnTimeActivityAttributes.ContentState is fully typed and Codable; targetLabel and symbol are prebuilt strings so the widget carries no semantics. Nothing to validate; the widget trusts everything. The one behavioral contract, staleDate meaning "the target passed, re render," is where system-services-1 lives on the app side.

UserDefaults: AppSettings trusts stored values completely.

```
ID:        system-services-14
Location:  OnTime/Services/AppSettings.swift:94
Class:     boundary
Claim:     Integer settings loaded from UserDefaults are not clamped, so an out of range persisted value (negative walkSafetyPercent, walkHeadsUpMinutes over 30, quickDeadlineHour of 30) is honored forever because the Stepper bounds in SettingsView only constrain edits, not loads.
Evidence:  init lines 90 to 104 assign d.integer(forKey:) results directly; the only range enforcement found is SettingsView Stepper "in:" ranges.
Trigger:   Requires a corrupted or externally written defaults value, which on this single device personal app is unlikely.
Blast:     A negative safety percent would shrink walk return estimates instead of padding them; quiet and wrong in the dangerous direction.
Confidence: medium (impact verified, trigger unlikely)
```

Category and action identifiers cross to the system as raw strings from the two enums (lines 21 to 29); registration happens once per launch in the OnTimeApp task, subject to the same timing caveat as system-services-4.

### 2. Error handling

Handled well: Activity.request failure is caught, printed, and surfaced as .failed to RunEngine, which shows it (RunEngine.swift:520 to 524); activitiesDisabled is a first class outcome; the cancelAllArmAlarms prefix sweep is written defensively against its own async completion racing a reschedule.

Swallowed: every center.add result (system-services-5), requestAuthorization's thrown error (line 78), and the authorization grant itself (system-services-6). Also Activity.update and Activity.end do not throw, so those paths are genuinely error free rather than error blind.

Unreachable by assumption: update() returning silently when no active activity exists (LiveActivityManager.swift:151) is documented as a harmless no op during an in flight start, which is true; it also masks the stale activity case in system-services-1, where a silent no op is exactly wrong.

### 3. State and lifetime

Outliving a single operation: pending notification requests (survive process death, the point of the design), delivered notifications (survive and are never reaped, system-services-3), running Live Activities (survive process death; reconciled at launch by endOrphans), three singleton scale in memory structures (scheduledIdentifiers, armAlarmIdentifiers, LiveActivityManager.activities and starting).

Observable inconsistent: after any relaunch every in memory map is empty while its system side counterpart is populated; the repair mechanisms are, respectively, deterministic identifiers plus first sync (system-services-11), the prefix sweep in cancelAllArmAlarms (sound), and current(for:)'s rescan of Activity.activities (sound for active, broken for stale, system-services-1).

Not cleaned up: delivered notifications (system-services-3); stale activities between staleness and next launch (system-services-1); armAlarmIdentifiers after cancelAllRunNotifications empties the center behind its back (system-services-7, harmless today because that call only happens before any arm alarms exist in the session).

### 4. Test gaps

These files have no dedicated tests. Two areas are pure enough to test today and carry real logic:

```
ID:        system-services-15
Location:  OnTime/Services/Notifications.swift:210
Class:     test-gap
Claim:     armAlertTimes is a pure static function with four edge behaviors (reminder chain, one second dedup, front trimming at the seven alert cap, the mustStartAt equal to armAt case) and zero tests, and system-services-8 shows one of those behaviors already disagrees with its spec.
Evidence:  Function is static, takes and returns values, no dependencies. OnTimeTests contains no reference to it. armBody (line 234) and the dueTitle/dueBody/leadBody copy builders (lines 350 to 367) are equally pure and equally untested.
Trigger:   Any future edit to the chain logic.
Blast:     Silent regressions in exactly the notification chain the arming model calls its guaranteed layer.
Confidence: high
```

```
ID:        system-services-16
Location:  OnTime/Services/AppSettings.swift:15
Class:     test-gap
Claim:     AppSettings is untestable as written because it hardcodes UserDefaults.standard inside a private init singleton, so its two real behaviors (first launch defaults, didSet persistence round trip) cannot be exercised without polluting real defaults.
Evidence:  Line 15 binds `d` to .standard; line 87 makes init private; shared at line 14 is the only instance. An injectable suite name (UserDefaults(suiteName:)) would make both behaviors trivially testable.
Trigger:   Any future settings addition, which is exactly when the duplicated key and default literals (system-services-18) drift.
Blast:     Key drift or a default mismatch ships unnoticed.
Confidence: high
```

LiveActivityManager and the notification center interactions are wrappers over system frameworks and are not unit testable without a protocol seam; that is a defensible choice for this app and I am not recommending one.

### 5. Load bearing assumptions

The documented AppSettings invariant was checked property by property and holds: all twelve persisted properties (confidenceIsSafe, lastLatitude, lastLongitude, hasRealLocation, lastFixAt, walkSafetyPercent, walkHeadsUpMinutes, defaultLeadWarningMinutes, autoAdvanceEnabled, quickDeadlineHour, quickDeadlineMinute, developerModeEnabled) are stored properties with a didSet that persists. walkSafetyFraction (line 46) is computed but persists nothing and derives from stored walkSafetyPercent, so observation still fires; its comment explains exactly this. Every didSet key literal matches its init read key. Clean result.

Assumptions that are true today and enforced nowhere:

```
ID:        system-services-17
Location:  OnTime/Services/Notifications.swift:396
Class:     assumption
Claim:     The string "OnTimeAdvanceStepFromIntent" is spelled as an independent literal in three files, and a typo in any one of them silently severs the notification action from the step advance.
Evidence:  Notifications.swift:396, Shared/OnTimeIntents.swift:27, RunEngineStore.swift:26, each constructing NSNotification.Name from its own literal.
Trigger:   Rename or typo during any future edit.
Blast:     Next Step taps foreground the app and do nothing; no error anywhere.
Confidence: high
```

```
ID:        system-services-18
Location:  OnTime/Services/AppSettings.swift:21
Class:     assumption
Claim:     Every setting's UserDefaults key appears twice (didSet and init) and every default value appears twice (property declaration and init fallback), as free literals that nothing checks for agreement.
Evidence:  For example "walkSafetyPercent" at lines 38 and 94, default 15 at both; twelve properties follow the pattern. The declaration default is actually dead (init always assigns), which makes a mismatch worse: changing the visible declaration default changes nothing.
Trigger:   Adding or renaming a setting, changing a default in one place.
Blast:     Reads and writes split across two keys, or a first launch default that differs from the one the declaration advertises; both silent.
Confidence: high
```

```
ID:        system-services-19
Location:  OnTime/Services/Notifications.swift:170
Class:     assumption
Claim:     The seven alert cap bounds only one routine's draw on the 64 pending request budget; the total across all routines plus two requests per block of every concurrently running plan is bounded nowhere, and iOS silently keeps only the soonest 64.
Evidence:  maxArmAlerts at line 171 is per scheduleArmAlarm call; ScheduleService.refreshArmAlarms (ScheduleService.swift:220) loops over every routine; scheduleRunNotifications adds up to two per block per plan; no code counts the total.
Trigger:   Roughly nine routines with full alert chains, or several long plans running while several routines are armed for tomorrow.
Blast:     The requests scheduled furthest out (tomorrow's arm alarms) are the ones the system discards, which is the guaranteed layer failing for exactly the routines that most depend on it.
Confidence: medium (limit behavior per platform documentation; realistic counts for this user probably stay under it)
```

Also load bearing, documented under other findings: the deterministic run notification identifier scheme (system-services-11), RootView's cancel then refresh ordering (system-services-7), delegate registration before first notification delivery (system-services-4), and ScheduleService.alarmKey remaining stable across launches (out of my scope, flagged for the run-orchestration auditor).

### 6. Enhancements (ranked)

```
ID:        system-services-20
Location:  OnTime/Views/Settings/SettingsView.swift:60
Class:     enhancement
Claim:     Settings should read UNUserNotificationCenter.notificationSettings and show a plain warning row when authorization is denied, since the entire arming model and walk alarm ride on it and nothing currently surfaces a denial (system-services-6).
Evidence:  SettingsView already has the pattern for location fix state at lines 62 to 82.
Trigger:   n/a
Blast:     n/a
Confidence: high
```

```
ID:        system-services-21
Location:  OnTime/Services/Notifications.swift:94
Class:     enhancement
Claim:     Delete the dead quick countdown pair (system-services-12) and fold its doc's intent into armAlarm's comment, which already describes the id per caller design that replaced it.
Evidence:  Zero callers repo wide.
Trigger:   n/a
Blast:     n/a
Confidence: high
```

```
ID:        system-services-22
Location:  OnTime/Services/AppSettings.swift:82
Class:     enhancement
Claim:     Replace the duplicated key and default literals with one definition per setting (a private enum of keys, or a small read helper taking key and default used by both init and didSet), eliminating the drift class in system-services-18 and making system-services-16's injectable defaults change natural.
Evidence:  Twelve properties currently follow the copy paste pattern.
Trigger:   n/a
Blast:     n/a
Confidence: high
```

```
ID:        system-services-23
Location:  OnTime/Services/Notifications.swift:369
Class:     enhancement
Claim:     formatTimeStatic should be one cached formatter using the user's locale (Date.FormatStyle .hour().minute(), or timeStyle .short) instead of allocating a DateFormatter with hardcoded "h:mm a" per call; WalkTracker.clock has the same pattern and both ignore a 24 hour clock preference. Separately, the notification copy in armBody (lines 241 and 243) uses an em dash, which the repo owner's global writing rule bans in UI copy; reword to a period or comma.
Evidence:  Lines 369 to 373; armBody lines 241 and 243.
Trigger:   n/a
Blast:     n/a
Confidence: high
```

```
ID:        system-services-24
Location:  OnTime/Services/LiveActivityManager.swift:14
Class:     enhancement
Claim:     LiveActivityStartOutcome's hand written == duplicates exactly what synthesized Equatable conformance provides for an enum with Equatable payloads; delete it.
Evidence:  Lines 14 to 20 case match what `enum ... : Equatable` synthesizes.
Trigger:   n/a
Blast:     n/a
Confidence: high
```
