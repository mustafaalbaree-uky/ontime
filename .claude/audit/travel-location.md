# Audit: travel-location

Subsystem: layered travel time resolution (live MapKit ETA, in-memory cache, manual estimate chain) in TravelTimeProvider.swift and LocationService.swift, plus live walk measurement and absolute-time turnaround alarms in WalkTracker.swift.
Overall: the continuation handling in LocationService is genuinely solid; the serious problems are in the alarm re-arm logic in WalkTracker (two ways the "guaranteed" alarm can silently never fire) and in stale state that outlives its validity (persisted resolvedMinutes, cache entries with no age limit, per-walk home coordinate).

## Pass A: mechanical review

```
ID:        travel-location-1
Location:  OnTime/Core/WalkTracker.swift:317
Class:     correctness
Claim:     When the turnaround estimate slips into the past while the app is alive, the re-arm cancels both the pending turnaround and heads-up alarms and arms nothing, so the user never hears "turn around now" at all.
Evidence:  rearmAlarmsIfNeeded (lines 317 to 337) calls Notifications.armAlarm for both alarms; armAlarm (Notifications.swift:127 to 128) first removes the pending request with that id, then does `guard fireAt > Date() else { return }`. A turnaround now in the past therefore deletes the previously armed future alarm and adds no replacement. There is no outbound-phase "you are already past it" alarm; the late alarm exists only in the returning phase (line 298).
Trigger:   Outbound, the return estimate worsens by more than 30 seconds (route refetch finds a longer way home, pace estimate drops) and the recomputed turnaround lands before now, with the phone in a pocket.
Blast:     The one alert the feature exists to deliver is silently dropped in exactly the marginal case where it matters most; the user learns they are late only from the returning-phase late alarm, which has its own defect (travel-location-2).
Confidence: high
```

```
ID:        travel-location-2
Location:  OnTime/Core/WalkTracker.swift:308
Class:     correctness
Claim:     The "Running late" alarm is re-armed 30 seconds into the future on every tick and every fix, so while the app is alive (which background location keeps true for the whole walk) it is perpetually deferred and never fires.
Evidence:  In the returning branch, whenever `arrival > homeBy`, armAlarm is called with `fireAt: Date().addingTimeInterval(30)` (line 310). armAlarm removes the pending request with the same id before adding (Notifications.swift:127). RunEngine.swift:131 calls WalkTracker.shared.tick() every second, and each tick reaches this code unconditionally (there is no dedupe like armedTurnaround for the late alarm). So the pending fire time is rewritten to now+30 once per second and the trigger date never arrives.
Trigger:   Any returning-phase walk whose projected arrival is past homeBy while the app is running, foreground or background.
Blast:     The user walking home too slowly gets no notification about it; the alarm only fires if the app is killed or the tick stops, inverting the intended safety layering.
Confidence: high
```

```
ID:        travel-location-3
Location:  OnTime/Core/WalkTracker.swift:116
Class:     correctness
Claim:     begin() never resets homeCoordinate and homeName, so a walk block with no destination (or a "Current Location" destination) inherits the previous walk's home point.
Evidence:  Lines 116 to 119 set homeCoordinate/homeName only when `home != nil && !home.isCurrentLocation`; the fresh-walk reset block (lines 126 to 141) resets every other piece of per-walk state but not these two.
Trigger:   Two walk blocks in different plans over the app's lifetime, where the second has destinationPlace nil or the current-location sentinel, and the first had a concrete place.
Blast:     directDistanceMeters, the arrived detection (60 m radius), the automatic phase flip, and the MapKit route home are all computed against the wrong coordinate; alarm bodies name the wrong place. The walk looks tracked but every routed number is for somewhere else.
Confidence: high
```

```
ID:        travel-location-4
Location:  OnTime/Core/WalkTracker.swift:100
Class:     correctness
Claim:     The comment on activityType claims automatic pausing is "the single biggest battery saving available here" while the very next line disables it (`pausesLocationUpdatesAutomatically = false`).
Evidence:  Lines 100 to 105. Disabling pausing is the right call (a paused manager in the background never resumes on its own and the walk would go blind), but the comment documents the opposite decision.
Trigger:   Any future edit guided by the comment, for example "restoring" pausing to save battery.
Blast:     Restoring pausing would permanently stop background fixes mid-walk, degrading the alarm to whatever was last armed; the misleading comment is the trap that invites it.
Confidence: high
```

```
ID:        travel-location-5
Location:  OnTime/Core/TravelTimeProvider.swift:240
Class:     correctness
Claim:     resolve(block:) and resolveETA are non-isolated async methods on a non-MainActor @Observable class, so their synchronous sections run off the main actor while mutating state SwiftUI reads on it, including a SwiftData Block.
Evidence:  TravelTimeService is declared @Observable but not @MainActor (lines 111 to 112). resolve(block:) mutates `cache`, `blockSources`, `blockErrors`, `blockResolvedAt` (lines 250 to 253, 292 to 296, 299 to 308) and writes `block.resolvedMinutes` (lines 250, 261, 293), a persisted SwiftData model bound to the main-actor ModelContext. Callers are @MainActor (RunEngine.swift:231, NowView.swift:155), but in Swift a non-isolated async function hops off the caller's actor. The project builds under SWIFT_VERSION 5.9 (project.yml:14), so nothing diagnoses this.
Trigger:   Every ETA resolution; observable races are intermittent, and a Swift 6 language-mode migration turns the whole file into errors.
Blast:     Off-main SwiftData mutation and off-main observation notifications; in practice occasional glitches or crashes under load, and a guaranteed migration cost. Marking the class @MainActor would fix all four dictionaries and the model write at once.
Confidence: medium
```

```
ID:        travel-location-6
Location:  OnTime/Services/LocationService.swift:187
Class:     correctness
Claim:     apply(fix:) stamps lastFixAt with Date() rather than the fix's own timestamp and applies no accuracy or age filter, so a cached stale fix that CoreLocation replays is recorded as a fresh current position.
Evidence:  didUpdateLocations takes `locs.last` with no filtering (lines 170 to 173); apply sets `settings.lastFixAt = Date()` (line 190) and resolves all waiters with that coordinate (line 201). CoreLocation documents that the first delivery after requestLocation can be a cached fix; WalkTracker by contrast filters on horizontalAccuracy (WalkTracker.swift:444), so the codebase already knows this class of problem.
Trigger:   First fix after a long gap, especially right after launch or in a garage, when CoreLocation serves the last known location before a new one.
Blast:     hasFix(fresherThan: 120) then answers true for up to two minutes on a position that may be from this morning across town, and every "Current Location" drive ETA routes from the wrong origin, which is precisely the failure the currentCoordinate doc comment (lines 79 to 82) promises to prevent.
Confidence: medium
```

```
ID:        travel-location-7
Location:  OnTime/Core/TravelTimeProvider.swift:221
Class:     correctness
Claim:     In resolveETA, when the live fix cannot be had, the cache key for a current-location endpoint is built from bucket(nil) = (0, 0), recreating on this one path the exact collapse the TravelCacheKey comment (lines 68 to 74) exists to prevent.
Evidence:  Line 221 to 224: `live = try? await ... currentCoordinate()` then `TravelCacheKey(from:to:live:)`; bucket(nil) returns (0, 0) (line 95). cachedDuration/setCached (lines 129 to 136) similarly fall back to storedCoordinate which can be nil before any real fix.
Trigger:   Narrow: a provider that can compute an ETA without LocationService (a stub, or a future provider) while currentCoordinate throws, or repeated failures caching under the shared (0, 0) key from different real locations. With the production MapKitTravelProvider, its own coordinate lookup fails identically, so the path usually ends at the manual tier.
Blast:     A cached ETA from one place served as "cached" at another; today mostly a latent trap rather than a live bug.
Confidence: low
```

```
ID:        travel-location-8
Location:  OnTime/Core/WalkTracker.swift:361
Class:     correctness
Claim:     refreshRouteIfStale(force: true) silently does nothing when a route task is already in flight, so markReturning's forced refetch can be skipped without any retry.
Evidence:  Line 361: `guard routeTask == nil else { return }` sits before the force check; markReturning (line 210) relies on force to get a fresh route for the return leg.
Trigger:   The phase flips (tap or the automatic 150 m detection) during the window an outbound route request is still awaiting MapKit.
Blast:     The return leg briefly uses the pre-turnaround route; bounded by the next fix reaching routeRefreshDistance or routeMaxAge (180 s), so self-healing, but the "force" contract is not honored.
Confidence: high
```

```
ID:        travel-location-9
Location:  OnTime/Core/TravelTimeProvider.swift:187
Class:     correctness
Claim:     A drive block's persisted resolvedMinutes has no timestamp and outranks a user-set override forever, so an ETA fetched days ago beats an estimate the user typed a minute ago, and the tier order deviates from the chain CLAUDE.md documents.
Evidence:  Lines 187 to 189 check `block.resolvedMinutes > 0` before `estimateOverrideMinutes` (line 190). resolvedMinutes is a persisted model field copied by copyForSpawn (Models/Block.swift:21, 97); the freshness record (blockResolvedAt, line 123) is in-memory only and empty after relaunch. CLAUDE.md documents the manual chain as "override -> learned blend -> template prior -> last resolved value -> 10 min", with the resolved value last. The in-file comment (lines 176 to 186) argues the live ETA must beat the scrubber value, which is right while the ETA is fresh; nothing bounds how old it may be.
Trigger:   A drive block resolved once, then the app relaunches or a day passes without a successful re-resolve (offline, MapKit failing), while the user adjusts the estimate scrubber expecting it to be used.
Blast:     The schedule quietly runs on a stale ETA the UI cannot distinguish from a fresh one, and the user's explicit correction is ignored; the documented resolution order in CLAUDE.md is also now wrong for drive blocks.
Confidence: medium
```

```
ID:        travel-location-10
Location:  OnTime/Core/TravelTimeProvider.swift:145
Class:     correctness
Claim:     clearCache() has no callers anywhere in the app, and setCached(from:to:duration:) is called only by tests, so the cache has no production write path except resolve itself and no eviction path at all.
Evidence:  Grep across OnTime/ finds no call site for either outside TravelTimeProvider.swift and OnTimeTests/TravelTimeTests.swift.
Trigger:   Always true; visible when reasoning about cache lifetime.
Blast:     Dead surface area that suggests an eviction/reset facility exists when nothing uses it; combined with travel-location-14 the cache is append-only for the process lifetime.
Confidence: high
```

Looked for and did not find: continuation misuse in LocationService. finish() removes the waiter before resuming (line 125 to 135), which makes double resume impossible regardless of the ordering of fix, timeout, and cancellation; finishAll drains the map before resuming; the timeout is an unstructured sibling task so a pile-up behind the authorization prompt cannot leak a continuation past 10 seconds; isAcquiring is cleared on every terminal path including timeout. The one residual quirk is benign: a call that enters already cancelled runs onCancel before the waiter is registered, so it resolves via the 10 second timeout instead of promptly, but it does resolve.

Also verified clean: the fallback chain in resolveETA and resolve(block:) does match the documented live -> cached -> manual order (the deviation in travel-location-9 is inside the manual tier only), and WalkTracker's GPS ingestion correctly filters accuracy (0 to 50 m), requires dt > 0, prefers doppler speed when available, and adds path distance independently of the moving threshold so loitering does not inflate pace but does count metres walked.

## Pass B: structural audit

### 1. Boundaries

CLLocation stream into WalkTracker (WalkTracker.swift:421 to 479): validated for horizontal accuracy (0 to 50 m), finite delta, positive dt, and non-negative doppler speed. Assumed: fix timestamps are ordered and honest. Wrong assumption cost: a replayed cached fix at walk start becomes the path origin; bounded because lastFix starts nil each walk.

CLLocation stream into LocationService (LocationService.swift:170): nothing validated; see travel-location-6.

MKDirections responses: WalkTracker keeps distance and expectedTravelTime with no sanity check (lines 383 to 384); a zero-distance response would produce a zero-second return estimate and a turnaround equal to homeBy. TravelTimeProvider trusts expectedTravelTime wholesale (line 42 to 43). Assumed sane because MapKit; wrong assumption produces one absurd schedule, self-corrected on the next resolve.

Cache seam: see travel-location-14 (no TTL) and travel-location-7 ((0, 0) key on a failed fix).

Notification arm seam: armAlarm silently refuses past fire dates after having already removed the pending alarm; see travel-location-1. Nothing at this seam checks notification authorization; see travel-location-13.

### 2. Error handling

Handled well: LocationService propagates denial and hardware failure to every waiter (lines 161 to 163, 175 to 184); resolve(block:) records every failure into blockErrors for the dev panel and clears it on success, as the comment promises (lines 118 to 122).

Swallowed deliberately and acceptably: reverse geocode failure (LocationService.swift:214 to 219, display-only); route failure mid-walk keeps the last good route (WalkTracker.swift:390 to 398, with the staleness bounded argument in the comment).

```
ID:        travel-location-11
Location:  OnTime/Core/WalkTracker.swift:432
Class:     error-handling
Claim:     A CLLocationManager failure (GPS lost, denied mid-walk) is recorded into routeError, the field that means "MapKit could not route home", so the screen misattributes a location failure to routing.
Evidence:  didFailWithError writes `self.routeError = message` (line 432); unavailableReason exists for exactly this class of problem (lines 66 to 71) but is only ever set from authorization status.
Trigger:   kCLErrorDenied or transient location failures during a walk.
Blast:     Cosmetic to misleading: the user is told the route failed while the actual problem is no fixes are arriving, which has a different remedy.
Confidence: high
```

```
ID:        travel-location-12
Location:  OnTime/App/OnTimeApp.swift:30
Class:     error-handling
Claim:     The result of Notifications.requestAuthorization() is discarded at the only call site, so a denial is invisible to every feature whose safety story depends on local notifications firing.
Evidence:  `_ = await Notifications.shared.requestAuthorization()` (OnTimeApp.swift:30); no code anywhere reads notification settings afterward. WalkTracker's header comment (lines 19 to 25) rests the entire safety argument on the armed alarm firing after app death.
Trigger:   User declined the notification prompt, or revoked permission later in Settings.
Blast:     Every armAlarm call succeeds silently while delivering nothing; the walk turnaround, the arm alarms, and the run step alerts all become no-ops with no UI hint, unlike location denial which sets unavailableReason.
Confidence: high
```

### 3. State and lifetime

```
ID:        travel-location-13
Location:  OnTime/Core/TravelTimeProvider.swift:117
Class:     state
Claim:     blockSources, blockErrors, and blockResolvedAt are keyed by ObjectIdentifier and never pruned, so they grow for the process lifetime and a recycled object address can attribute a dead block's source, error, or freshness to a new block.
Evidence:  Lines 117 to 123 declare the maps; entries are only ever set (lines 251 to 253 onward), never removed, and clearCache (line 145) does not touch them. ObjectIdentifier is an address, reusable after deallocation.
Trigger:   Long sessions creating and discarding many plan blocks (each run mints copies via copyForSpawn); the misattribution case needs an address reuse coinciding with a block never yet resolved.
Blast:     Unbounded but slow memory growth; occasional wrong freshness/error shown in the dev panel and the source badge. Keying by the persisted block id would fix both.
Confidence: medium
```

```
ID:        travel-location-14
Location:  OnTime/Core/TravelTimeProvider.swift:231
Class:     state
Claim:     Cached ETAs carry a timestamp that nothing ever reads: the cache tier serves an entry of any age as `.cached`, and the cache is never evicted.
Evidence:  CachedETA stores timestamp (lines 101 to 108); the two lookup sites (lines 231, 302) and cachedDuration (line 129) never compare it to now; clearCache has no callers.
Trigger:   MapKit unavailable (offline, throttled) hours after a successful resolve; rush hour versus midnight for the same key.
Blast:     A 25 minute 8am ETA is served with the "cached" freshness badge at 10pm; the schedule built on it is wrong by the whole congestion delta, and the UI's fetchedAt display is the only hint. In-memory scope caps the age at one process lifetime, which on iOS can still be days.
Confidence: high
```

WalkTracker lifetime: end() correctly stops updates, disables background mode, cancels the route task, and cancels all three alarms (lines 158 to 169); RunEngine calls end() on completion, abandon, and non-walk transitions (RunEngine.swift:260, 306, 445). Armed alarms surviving an app kill mid-walk are the feature, not a leak. The one per-walk residue not reset is homeCoordinate/homeName (travel-location-3). LocationService holds no per-operation residue: waiters drain on every terminal path.

### 4. Test gaps

```
ID:        travel-location-15
Location:  OnTimeTests/TravelTimeTests.swift:18
Class:     test-gap
Claim:     manualEstimateMinutes, the function whose doc comments narrate two real shipped bugs (scrubber beating live ETA, prior beating learned estimate), has no test at all for its precedence chain.
Evidence:  TravelTimeTests covers only resolveETA's three tiers and the cache key semantics (lines 19 to 91); nothing constructs a Block and asserts resolvedMinutes vs override vs learned vs default ordering, nor the .startAt pinned-target arithmetic (TravelTimeProvider.swift:170 to 217).
Trigger:   Any future edit to the chain, which history shows is edited under pressure.
Blast:     The exact regressions the comments memorialize can return silently; this function is the sole feeder of SolverInput durations for non-drive-resolved paths.
Confidence: high
```

```
ID:        travel-location-16
Location:  OnTime/Core/WalkTracker.swift:295
Class:     test-gap
Claim:     The alarm re-arm policy (30 second threshold, cancel-then-guard interaction, late alarm dedupe) and the automatic phase flip live only inside WalkTracker methods entangled with CLLocationManager and the Notifications singleton, so none of it is tested and travel-location-1 and travel-location-2 are exactly the kind of bug the tests could not catch.
Evidence:  WalkTests.swift tests WalkMath only (its header says so, lines 5 to 7); sustainedApproachMeters is defined in WalkMath (WalkMath.swift:178) but the comparison using it lives in ingest (WalkTracker.swift:471 to 474); rearmAlarmsIfNeeded is private and calls Notifications.shared directly.
Trigger:   Already bitten; see travel-location-1 and travel-location-2.
Blast:     The decision layer of the feature's safety mechanism has zero coverage. Extracting "given phase, estimate, armed state, now, decide (cancel/arm at date)" into WalkMath would make both found bugs assertable.
Confidence: high
```

Also absent, lower value: no test that resolve(block:) honors useManualEstimateOnly, and no test of LocationService's waiter bookkeeping (hard without a CLLocationManager seam, and the code is currently correct by construction). The existing TravelTimeTests assert behavior through public API rather than implementation; no tests found asserting implementation detail.

### 5. Load-bearing assumptions

```
ID:        travel-location-17
Location:  OnTime/Core/WalkTracker.swift:152
Class:     assumption
Claim:     With location denied (or never granted), the walk's safety net degrades to an alarm at approximately homeBy itself, because the initial arm computes a zero return estimate and nothing keeps revising it once the app suspends.
Evidence:  At begin, pathDistanceMeters is 0 so retraceSeconds = elapsed = 0 (line 239), estimate.seconds = 0, turnaround = homeBy; the immediate arm (line 155) therefore fires "turn around now" at the moment the user must already be home. The tick-driven revision the comment relies on (lines 185 to 197) requires the app to stay alive, but with location denied startUpdates never runs, allowsBackgroundLocationUpdates is never set, and the app suspends normally when pocketed, freezing the alarm near homeBy minus whatever elapsed before suspension. The heads-up alarm at homeBy minus 10 minutes (line 323) is the only mitigation.
Trigger:   Walk started with location denied or restricted, phone then locked.
Blast:     The feature's stated failure mode, missing the deadline, in exactly the degraded case the header comment claims is covered by "the last alarm armed still fires"; the alarm fires, but at a useless time.
Confidence: medium
```

```
ID:        travel-location-18
Location:  OnTime/Services/LocationService.swift:21
Class:     assumption
Claim:     Correct delegate delivery assumes LocationService.shared is first touched on a thread with a running run loop, which is enforced nowhere; the first touch can come from MapKitTravelProvider.eta running off the main actor.
Evidence:  The CLLocationManager is created in init (line 23) on whatever thread first evaluates the static; CoreLocation delivers delegate events on the run loop of the creating thread. MapKitTravelProvider.coordinate(for:) (TravelTimeProvider.swift:54) reaches LocationService.shared from a non-isolated async context. In practice the UI (Settings, NowView) touches the singleton on main first, which is why this has never bitten.
Trigger:   A code path where the very first use of LocationService in a process is a background ETA resolution, for example a future background refresh resolving a plan before any UI appears.
Blast:     Delegate callbacks never delivered on a run-loop-less thread: every currentCoordinate call times out after 10 seconds and all drives fall to the manual tier, looking like a GPS outage. Inferred from CoreLocation documentation, not reproduced.
Confidence: low
```

Verified rather than assumed: Info.plist carries the `location` UIBackgroundModes entry (Info.plist:43 to 47) and both usage strings (lines 29 to 32), so allowsBackgroundLocationUpdates = true is legal and the when-in-use background strategy described at WalkTracker.swift:172 to 178 is entitled. The Swift 5.9 language mode (project.yml:14) is itself a load-bearing assumption for travel-location-5: the isolation holes are legal today and become build errors on migration.

### 6. Enhancements (ranked, not bugs)

1. Age-gate the cached tier: resolve already stores CachedETA.timestamp; refuse entries older than roughly 45 to 60 minutes and fall to manual, and show the age next to the "cached" badge (TravelTimeProvider.swift:231, 302).
2. Persist a resolvedAt date beside Block.resolvedMinutes so the drive tier of manualEstimateMinutes can prefer the live number only while fresh and otherwise honor the override (TravelTimeProvider.swift:187, Models/Block.swift:21).
3. Add an outbound past-turnaround immediate alarm: when the recomputed turnaround is already past, arm a fire-now notification instead of cancelling; this is the enhancement shape of the fix for travel-location-1 (WalkTracker.swift:317).
4. Surface notification authorization in the walk UI alongside unavailableReason, checked when a walk begins, since the whole safety argument rests on it (WalkTracker.swift:114, OnTimeApp.swift:30).
5. Extract the re-arm decision (phase, estimate, armed state, now in; cancel/arm instructions out) into WalkMath so travel-location-16's gap closes and the alarm policy becomes table-testable (WalkTracker.swift:295 to 338).
