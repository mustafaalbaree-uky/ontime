# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

OnTime — a personal iOS app for Mustafa: given a deadline and a sequence of
blocks (fixed tasks, drives, and one flex block), it solves for either the
start time or the flex block's duration and runs a live countdown against
each block's leave-by time. Native SwiftUI + SwiftData, no backend. Same free
Apple ID / XcodeGen setup as the other iOS apps in this workspace (shadiliya,
ClipKeyboard, qada-tracker).

A deadline is always a plain clock time. There was once an offline
solar/prayer-time engine (`OnTime/Engine/`, `PrayerService`, a hand-filled
weekly `IqamaEntry` grid) that computed athan times to anchor routines
against; it was removed as unwanted. A prayer time is one number that changes
a few times a year, so it's typed in like any other. **Don't reintroduce
calculated prayer times.**

There is a prior HTML prototype at `~/Code/time app.html` — `DeadlineResolver`
documents a rounding bug it had (rolling the deadline to tomorrow when the
*required start time* was already past, instead of only when the deadline
itself had passed) that this app deliberately does not repeat.

## Build, install, test

```
xcodegen generate           # regenerates OnTime.xcodeproj from project.yml (gitignored, not authored directly)
./tools/install.sh          # xcodegen -> xcodebuild -> devicectl install to the connected iPhone
```

`install.sh` resolves the device UDID via `xcodebuild -showdestinations`
rather than `xcrun devicectl list devices` (which prints a different
CoreDevice UUID that xcodebuild rejects), deletes this app's own stale
provisioning profiles before building (Xcode reuses a still-valid profile
otherwise, so the 7-day free-provisioning clock does not actually restart on
rebuild), and stamps a moving `CURRENT_PROJECT_VERSION` (a static one leaves
SpringBoard showing a stale cached icon). See `tools/install.sh` for the full
story; it is the canonical version of this pattern, referenced by name from
the other apps' install scripts.

Tests use **Swift Testing** (`@Test` / `#expect`), not XCTest:

```
xcodebuild test -project OnTime.xcodeproj -scheme OnTime -destination 'platform=iOS Simulator,name=iPhone 16'
```

Run a single test with `-only-testing:OnTimeTests/SolverTests/solvesForStartWithNoFlexBlock`.

Registered in PhoneDeck (`~/Code/PhoneDeck`, `AppRegistry.swift`, id `ontime`)
— reinstalling from the PhoneDeck menu bar app runs the same `tools/install.sh`.

## Architecture

```
OnTime/Core/      The actual scheduling logic: Solver (the algebra), Estimator
                   (duration learning from history), TravelTimeProvider
                   (MapKit ETA + cache + manual fallback), DeadlineResolver,
                   ScheduleService (when a routine arms), RunEngine/RunLauncher.
OnTime/Models/    SwiftData @Model types.
OnTime/Services/  Singletons wrapping system frameworks + app-wide state:
                   LocationService, Notifications, LiveActivityManager,
                   AppSettings, RunEngineStore.
OnTime/Views/     Now/ (the front screen), Countdowns/ (the Active tab),
                   Routines/ (the Scheduled sheet), Run/ (live countdown),
                   Settings/, Templates/ (learned steps), Components/.
OnTimeWidget/     Live Activity UI (Dynamic Island / Lock Screen).
Shared/           Compiled into both the app and the widget extension —
                   ActivityAttributes, App Intents. Data only, no views.
```

**Three tabs: Now, Active, Settings.** It used to be six — Plans, Routines
and Templates each had their own, which exposed the persistence schema
(`TaskTemplate` → `Routine` → `Plan` → `Run`) as navigation, so no tab label
meant anything until you already knew the model. Don't add a tab per model
type again. In particular there is **no Plans screen**: `Plan` still exists,
but `RunLauncher` mints one per run and nothing lists them.

**Domain model.** `ScheduledRoutine` is a reusable sequence of `Block`s plus
one anchor time and the weekdays it runs — no "anchor kind", no prayer
lookup. A `Plan` is a concrete instance working toward one `deadline`; its
`Block`s are copies (`Block.copyForSpawn`), never shared with the routine's
template rows. A `Run` is one live execution of a `Plan`. `TaskTemplate` is a
reusable kind of block (e.g. "Shower") that logs `DurationSample`s so
`Estimator` can learn real durations; it is created implicitly by naming a
step (`QuickBlockEditorSheet.resolveTemplate`), never by hand.

**`Block.copyForSpawn` must stay exhaustive.** The two hand-rolled copy loops
it replaced each carried their own subset of fields, and both dropped
`isOpenEnded`, `useManualEstimateOnly`, `targetHour` and `targetMinute` —
which silently made a routine unable to hold a `.startAt` step or one pinned
to wait for a tap. Adding a field to `Block` and not adding it there is the
same bug again; `PlanTests` asserts field fidelity to catch it.

**An armed routine's timeline is absolute wall-clock.** `ScheduleService`
derives `deadline` / `mustStartAt` / `armAt` from the anchor time and the
current step durations, never from when the user interacted. This is what
lets an arm notification tapped fifteen minutes late land on the correct
remaining time instead of restarting the countdown — and it is the only
reason scheduled routines work without a push server, since iOS won't wake
the app at an exact time to start a Live Activity. Nothing *runs* at the arm
moment; the state is merely reconstructible, so `armDueRoutines` backdates
`run.startedAt` and `RunEngine.reconcile()` catches up. Arming is layered:
a local notification (guaranteed), `scenePhase` → `.active` (common), and a
`BGAppRefreshTask` (opportunistic, may never fire — depend on nothing here).

**There is no schema migration.** `OnTimeApp.openStore` deletes and rebuilds
the store when it no longer matches `Schema0.models`. That is deliberate for
a personal app whose data re-accumulates, but it means any model change wipes
the device's contents on next launch.

**`Schema0.models` is the single source of truth for persisted types.**
`OnTimeApp` builds its container from `Schema(Schema0.models)`; a model added
elsewhere but not to that list has no table and every fetch of it silently
returns nothing, with no error anywhere. Same convention as shadiliya.

**`Plan.blocks` / `ScheduledRoutine.blocks` are unordered SwiftData relationships.**
Always read `orderedBlocks`, never `blocks`, for display or scheduling. Call
`renumber()` after any move/insert/delete on either — a gap or duplicate
`order` value is what makes `orderedBlocks` ambiguous on the next fetch.

**`Solver` is the one place that turns durations + a deadline into scheduled
times.** At most one block in a `Plan` may be `.flex`; the solver either
solves for the overall start time (no flex block) or for the flex block's
duration (flex block present, start given). A flex block's duration, once
the user pins it by starting the run, is treated as an ordinary known
duration for every downstream purpose, including which blocks get a hard
`leaveBy` vs. which just absorb slack — see `BlockConstraint` and the
`isPinned` / `absorbBoundary` logic in `Solver.buildSolution`. Lateness is
never rolled forward a day to hide it; `Solution.lateness` says plainly how
far past the deadline the plan now runs.

**Every `AppSettings` property must be a stored property with a `didSet`
that persists**, never a computed property backed by `UserDefaults` — the
`@Observable` macro only tracks stored properties, so a computed one reads
and writes correctly but never tells SwiftUI to re-render. (Documented from
a real bug hit this way in shadiliya's settings.)

**Travel time resolution is layered, not a single call.** `TravelTimeService`
tries the live MapKit ETA first, falls back to its own in-memory cache keyed
on origin/destination coordinates, and falls back again to the block's
manual estimate (override -> **learned blend** -> template prior -> last
resolved value -> 10 min) if both of those are unavailable. `source(for:)`
reports which tier actually answered, for the UI to show freshness.

`manualEstimateMinutes` is also the *only* thing that feeds `SolverInput`, so
it is where the learned estimate has to be consulted — it used to read
`template.manualEstimateMinutes` directly, which meant the app displayed a
learned duration on every screen while quietly scheduling against the guess
you typed the first time, however many times you had since run the step.

**`Estimator` blends learned duration data toward a manual prior**, weighted
by `n / (n + 3)` so a single sample doesn't dominate, with observations
decaying at a 30-day half-life so old outliers fade but a genuine habit
change (new commute) still shows up within a couple of half-lives.
`Confidence.safe` (p80) vs `.typical` (p50) picks which side of the
distribution to report; `AppSettings.confidenceIsSafe` controls which one the
app uses by default.
