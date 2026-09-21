# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

OnTime — a personal iOS app for Mustafa: given a deadline and a sequence of
blocks (fixed tasks, drives, walks, and one open-ended block), it solves for either the
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
CoreDevice UUID that xcodebuild rejects), deletes this app's own provisioning
profiles before building to ensure a fresh signature, and stamps a moving
`CURRENT_PROJECT_VERSION` (a static one leaves SpringBoard showing a stale
cached icon). Provisioning is good for a year under the paid Apple Developer
Program membership. See `tools/install.sh` for the full story; it is the
canonical version of this pattern, referenced by name from the other apps'
install scripts.

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
OnTime/Views/     Now/ (the front screen pager), Countdowns/ (the Active
                   tab), Routines/ (the Scheduled sheet), Run/ (live
                   countdown), Settings/, Templates/ (learned steps),
                   Theme/ (the animated spectrum components), Components/.
OnTimeWidget/     Live Activity UI (Dynamic Island / Lock Screen).
Shared/           Compiled into both the app and the widget extension —
                   ActivityAttributes, App Intents, OnTimeSpectrum (the
                   palette). Data and pure functions, no stateful views.
```

**The ground is true black and content sits on it as hairline cards.**
`Shared/OnTimeSpectrum.swift` is the palette (compiled into the widget too,
so the phone and the Lock Screen cannot drift into two products);
`OnTime/Views/Theme/InkComponents.swift` is the set of rows, labels, cards and
controls every screen is built from, and `SpectrumViews.swift` holds the card,
the button style and the one animated piece left. `RootView` pins
`.preferredColorScheme(.dark)` deliberately: the palette only reads as lit
with nothing behind it.

Four rules hold the whole look together.

- **Three whites do the hierarchy.** `primaryText` 100%, `secondaryText` 62%,
  `tertiaryText` 38%. Progress and rails use white at 0.95 / 0.30 / 0.12 for
  current / done / ahead. A grey that is not one of those is a mistake.
- **Colour is a signal or it is absent.** `late` red once a target is past
  (always behind an explicit `+`), `done` green for finished, `waiting` amber
  for a solver problem, a stale value or a missing permission. `accent` exists
  only so a `Toggle` can be seen wearing something; it is never text, never an
  icon, never the tab bar. Nothing else on any screen is coloured, and a
  *kind* is never coloured, only a state.
- **The Final Time number on the composer is the only spectrum element in the
  product.** `SpectrumText` fills it, and nothing else calls that view. The
  page dots, the step rails, the Live Activity's pips and its ring are all
  plain white. The per step hue and the green to red ramp are gone from the
  palette entirely, so a caller cannot reach for them by accident.
- **`List` and `Form` are not used for anything the user sees.** On a forced
  dark scheme they render grey grouped panels, grey section headers and a cyan
  tint on every value, which is a different product beside the ink. A screen
  is a `ScrollView` of labelled cards. The two screens that genuinely need
  `swipeActions` keep a `List` stripped to nothing by `.inkList()`, with a
  card in every row.

Every section is a `SectionLabel` (small, bold, uppercase, tracked) over its
card, never a `navigationTitle`. A pushed screen or sheet gets its title as a
principal toolbar item through `.inkNavigation(title:)`, in the same label
style, over a black bar.

**A Live Activity cannot animate, so it is monochrome and informational.**
Only `Text(timerInterval:)` and `ProgressView(timerInterval:)` move without
the app; everything else freezes at the last pushed state, and the app is
suspended for most of a run. The step pips are therefore the same three whites
the Home Screen widget and the run page use, and the ring stays a
`ProgressView(timerInterval:)` tinted white so it keeps depleting on its own.
Do not "improve" that ring into a gradient: it would stop moving.
`RunEngine.rampBucket` still throttles the pushes; nothing takes a colour from
it any more.

**Four tabs: Now, Active, Work, Settings.** It used to be six — Plans, Routines
and Templates each had their own, which exposed the persistence schema
(`TaskTemplate` → `Routine` → `Plan` → `Run`) as navigation, so no tab label
meant anything until you already knew the model. Don't add a tab per model
type again. In particular there is **no Plans screen**: `Plan` still exists,
but `RunLauncher` mints one per run and nothing lists them.

**Now is a pager: one page per open run, the composer last.** `NowView` is a
thin shell (`TabView(.page)`, `SpectrumPageDots`, routing); `LiveRunPage` is
one run's live countdown; `SequenceComposer` is the build-and-start half that
used to be all of `NowView`. Dots render only when there is more than one
page, because a single dot is a control that says nothing.

This is what fixed "I start a run, press Close, and it's gone." A hand
started run used to live only inside a `fullScreenCover`; dismissing it left
the run going with no trace on the front screen, findable only by knowing to
switch to the Active tab and read a one-line row. An armed *routine* got a
banner; a run you started yourself got nothing. Starting a run now slides the
pager onto its page instead of pushing a cover, and you can swipe back to the
builder without ending anything. `RunView` still exists behind the Steps
button and is still where a sequence is edited mid-run.

`page` is clamped whenever `openRuns.count` changes — a run finishing pulls a
page out from under the pager, and an unclamped selection lands on a blank
pane.

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
same bug again; `PlanTests` asserts field fidelity, and
`copyForSpawnAccountsForEveryPersistedBlockField` walks the schema's
property list against an explicit copied/excluded split, so a new field
that lands in neither fails the suite instead of shipping.

**Stable identity is `uuid`, never `persistentModelID`.** `Plan`, `Run`,
`ScheduledRoutine`, and `Block` each carry a persisted `uuid`. Everything
that outlives the store's autosave timing keys on it: `RunEngineStore`'s
engine map (`run.uuid`), Live Activity `planId`s and run notification
identifiers (`plan.uuid.uuidString`), arm alarm identifiers
(`routine.uuid`), and `TravelTimeService`'s per-block source/error maps
(`block.uuid`). A `persistentModelID` is temporary until the first save and
changes under you after autosave — keying on it minted duplicate engines
and duplicate Live Activities. `Block.uuid` is deliberately NOT copied by
`copyForSpawn`; a copy is a new block.

**Deleting a `TaskTemplate`, `Place`, or `ScheduledRoutine` goes through
`DeleteCleanup`, never a bare `modelContext.delete`.** Four references are
deliberately unpaired (no inverse): `Block.template`, the place pointers on
`Block` and `TaskTemplate`, and `Plan.routine`. SwiftData cannot nullify an
unpaired reference on delete, and a referrer left dangling crashes with the
uncatchable "backing data could no longer be found" fatalError on the next
property read — every launch, until the store is wiped. `DeleteCleanup`
nils every referrer first; any new deletion affordance for these types must
use it.

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

**The Pi starts a routine's Live Activity by push, because nothing on the
phone can.** `Activity.request` only works in the foreground and iOS will not
wake the app at the arm moment, so until Sep 2026 the Dynamic Island stayed
empty at arm time until the notification was tapped. Now
`ScheduleService.refreshArmAlarms` also hands its occurrence list to
`PiSchedule`, which uploads it to `tools/pi/ontime_pushd.py` on the Pi
(warden, `ontime-push.service`, port 8790 on the Tailscale address only). Each
event is an absolute clock time plus the exact APNs payload to deliver then,
built by the app from the real `ContentState`; the Pi does no scheduling math.
An upload replaces the Pi's whole list. `tools/pi/deploy.sh` deploys the
daemon; the APNs key lives only in `~/.ontime-push` on the Pi, never in the
repo. `curl http://100.88.112.8:8790/status` shows what is pending and what
APNs answered for the last sends.

Things about it that were each found the hard way:

- **The pushed activity and the run share an id without talking.** An
  activity's `planId` is fixed when it starts, and the run that owns it is
  minted later. `OccurrenceIdentity.planUUID` derives the plan's uuid from the
  routine and the occurrence's day, so `LiveActivityManager.current(for:)`
  adopts the pushed activity instead of raising a second one. `armNow` opts
  out, or a restarted run would share a uuid with the cancelled plan.
- **Launch arms before it sweeps** (`RootView.task`). The sweep ends any
  activity with no open run behind it, which is exactly what a pushed
  activity is until the arming pass mints its run.
- **The Pi is addressed by tailnet name, not IP.** ATS refuses plain HTTP,
  its exceptions cannot name an IP, and `NSAllowsLocalNetworking` does not
  cover 100.x addresses. Info.plist carries one exception for
  `warden.taile3f2ad.ts.net`.
- **Dates inside `content-state` are seconds since 2001; `stale-date` and
  `timestamp` are Unix seconds.** The first belongs to the app's Codable type
  and ActivityKit's default decoder, the other two to APNs.
- **A build installed from Xcode is on the APNs sandbox host.** The daemon
  reuses one provider token for 40 minutes; APNs rejects a provider that
  mints one more often than every 20.
- **`print` is not evidence on a phone.** An app launched outside Xcode
  buffers stdout, so `devicectl --console` shows nothing. `PiSchedule` and
  `PushTokens` write their state to files in Documents that
  `devicectl device copy from` can read (`pi-schedule-status.json`,
  `push-tokens.json`).

**The Pi also moves a running activity to its next step, and ends it.** The
app is suspended within seconds of leaving the foreground, so a step that ran
out used to sit in the Island red and counting up until the app was opened,
with the run in fact two steps further on. `RunEngine.projectedActivitySteps`
is `reconcile()` run forward in imagination (the pure walk is
`RunProjection.boundaries`, which is where the tests are): every auto
advancing step ends on its estimate, and projection stops at the first step
that waits for a tap, because past it "over, waiting on you" is the truth and
the staleness re-render already shows it. While waiting, the first entry is
the rollover into step 1. Each entry carries the full `ContentState` for the
step being entered, with its target read from the solution exactly as
`leaveByDate` reads it, so a pushed step and the step the app would have shown
cannot disagree. `PiSchedule.publishRun` is called on every engine sync and
dedupes on the encoded body.

- **An update goes to the activity's own token, not the push to start
  token.** `LiveActivityManager.start` requests with `pushType: .token`, and
  `PushTokens.observeActivities` follows every activity, pushed or local, and
  reports its token. A run's steps are only uploaded once its activity has one.
- **A push that wakes the app arms the routine on the spot.**
  `PushTokens.track` runs `ScheduleService.catchUp` when a new activity
  appears, because a background launch may never build the view hierarchy
  that runs the foreground catch up. That mints the run, whose first sync
  uploads the step changes for the rest of the routine. Without it a routine
  the Pi started would get its start and nothing after.
- **Step event ids contain their time.** A tap moves every later boundary;
  the moved boundaries have to be new events, not ones the Pi believes it
  already sent.
- **The Pi sends two seconds early** (`PiSchedule.pushLead`). The activity
  goes stale at the boundary and re-renders as over, so a push landing just
  after it shows a flash of red first.
- **One upload at a time.** An upload replaces the Pi's whole list, so two in
  flight could land out of order and leave the older list in place.
- A walk entered by push has no `WalkTracker` behind it until the app runs, so
  it is labelled "Home by" rather than counting to a turnaround.

The Pi is given a week of occurrences per routine
(`ScheduleService.upcomingOccurrences`), for the reason the widget snapshot
holds a week: it acts on days the app may never be opened.

With Tailscale off on the phone, or the Pi down, the upload fails, the Pi
keeps its last list, and anything it does not know about behaves the old way:
local notification, then foreground.

**An edit to a routine that already armed reaches today**
(`ScheduleService.applyEdit`, run from `syncAllLiveRuns`). With no run open,
an edit clears `lastArmedDay` so the occurrence arms again if its window is
open: moving an iqama fifteen minutes after stopping the run used to change
the routine and start nothing, and the Start Now swipe was the only way back.
With a run open but still waiting to start, the run's steps are replaced with
fresh copies. A run that has begun step 1 is left alone. An edit is told from
the editor merely being opened by an in memory signature per routine.

**An auto advanced step logs a sample equal to its estimate**
(`RunEngine.logOnTimeCompletion`). It used to log nothing, which left taps as
the only samples, and with auto advance on a tap can only land before the
estimate runs out: every sample was short, learned durations could only fall,
and start times crept later.

**There is no schema migration.** `OnTimeApp.openStore` rebuilds the store
when it cannot be opened against `Schema0.models`. That is deliberate for a
personal app whose data re-accumulates, but it means any model change wipes
the device's *visible* contents on next launch. The mechanics are gentler
than they used to be: one immediate retry first (a transient failure such
as a file lock must not cost the store), and on a second failure the old
store files are moved aside with a timestamp suffix rather than deleted,
so the bytes stay recoverable by hand.

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
duration (flex block present, start given). That invariant is now enforced
at input time too — `QuickBlockEditorSheet` and `TemplateDrawerSheet` hide
the flex/walk kinds once the sequence has one (`allowsOpenDuration`) — and
surfaced when violated anyway: `RunEngine.recomputeSolution` keeps the
`SolverError`'s reason in `solutionErrorMessage` and `RunView` shows it,
instead of the old `try?` everywhere that blanked the schedule silently.
Where a *latest start* is needed with an open block on the board
(`NowView.mustStartAt`, `RunEngine.naturalStart`, the occurrence math), the
open block is mapped to `.known(0)` — the zero-flex start — never to
`.flex` with no start, which is underdetermined. A flex block's duration, once
the user pins it by starting the run, is treated as an ordinary known
duration for every downstream purpose, including which blocks get a hard
`leaveBy` vs. which just absorb slack — see `BlockConstraint` and the
`isPinned` / `absorbBoundary` logic in `Solver.buildSolution`. Lateness is
never rolled forward a day to hide it; `Solution.lateness` says plainly how
far past the deadline the plan now runs.

**A `.walk` block is a flex block that knows what it costs to come back.**
It has no duration, so `RunEngine.recomputeSolution` maps it to
`BlockDuration.flex` exactly like a `.flex` block, and `BlockKind.isOpenDuration`
is what every scheduling site tests instead of `== .flex`. That means the
`Solver` needed no changes at all: the walk's `leaveBy` falls out as
"deadline minus everything after it," which is the be-back-by time the
whole feature compares against. Only one open-duration block per plan, same
one-equation limit as before.

`WalkMath` is the pure arithmetic (pace smoothing, return estimate,
turnaround, slack) and is where the tests live. `WalkTracker` is the
sensors: its own `CLLocationManager` streaming in the background, plus a
MapKit walking route home. It is deliberately **not** part of
`LocationService`, which is a one-shot fix service built on continuations
and would have had to hold two incompatible lifecycles.

Three things about it that are load-bearing:

- **The alarm does not depend on the tracker staying alive.** Every time the
  estimate moves more than 30 seconds, `WalkTracker` re-arms the turnaround
  as a local notification at an absolute clock time. If iOS suspends or
  kills the app, or the GPS goes quiet, the last alarm armed still fires.
  Location updates make the alarm more accurate; they are not what makes it
  fire. Do not "simplify" this into a timer or a foreground check. The
  *policy* (when to arm, cancel, keep, or fire immediately) is the pure
  function `WalkMath.alarmDecision`, with tests pinning its two historical
  failure modes: a turnaround estimate that slips into the past fires an
  immediate alert once instead of silently disarming (`armAlarm` refuses
  past dates, and used to remove the pending request first), and the
  returning-phase late alarm arms once per crossing instead of being
  re-deferred to now+30s on every tick, which meant it never fired at all
  while the app was alive. The walk is also owned by its run
  (`WalkTracker.ownerRunId`): another run finishing no longer tears down a
  concurrent run's walk and its armed alarm.
- **The route supplies metres, the walk supplies seconds per metre.** MapKit
  is authoritative about distance (it knows the footbridge); its duration is
  a guess about a generic walker, and this app has been measuring the actual
  one for the last twenty minutes. So `returnEstimate` re-times the route
  distance at the measured pace and only falls back to
  `expectedTravelTime` before any pace exists, then to retracing the path
  walked. Path distance, not elapsed time, drives the retrace: ten minutes
  on a bench is zero metres of walking home.
- **Phase flips on its own.** The phone is in a pocket, so a feature that
  only left `.outbound` on a tap would be in the wrong phase most of the
  time. A sustained 150 m of closing distance counts as a turnaround.

The walk feeds its own `targetLeaveBy` / `targetLabel` into the Live
Activity (the turnaround while heading out, the be-home-by time once heading
back): the ring and its green-to-red ramp draw whatever span they are
handed. The widget's display logic (phase resolution, the ring's span
guard, the ramp fraction, the over-state caption) lives in
`Shared/OnTimeActivityLogic.swift` as pure functions both targets compile,
so `ActivityLogicTests` in the app's test target covers it — the widget
target itself has no tests. The cross-process string constants (the
Complete Step notification name, the persisted pending-advance key) live in
`Shared/OnTimeShared.swift`; never spell them as literals at a call site.

**Never use `Text(_:style: .timer)` for a countdown.** That view free-runs:
it counts down to its date and then, with no sign, no colour change and no
relabelling of its own, starts counting up. A number rising through 00:41
looks exactly like a number falling through 00:41, which is the whole reason
the activity read as broken once a step ran over. Every countdown in this app
now takes one of two forms, and `LiveRunPage` uses the same two so the phone
and the Lock Screen say the same thing at the same moment:

- Running: `Text(timerInterval:countsDown:)` over the step's `ClosedRange`.
  The range form clamps at both ends by itself, which is the entire fix.
  **Do not add `pauseTime` to get that clamp.** Passing it renders the timer
  as *paused* rather than as running-until-paused, so the number sits frozen
  and never counts at all — which is how the first attempt at this fix
  shipped a Lock Screen countdown that did not count down.
- Over: `OnTimeActivityLogic.lateInterval(target:)` counted *up*, in
  `OnTimeSpectrum.late` red, behind an explicit `+`.

`OnTimeActivityPhase` still decides which of the two (and `endsRunAtTarget`
still replaces the number entirely with "Done" for a last step that ends
itself), so the phase truth table is unchanged; only the rendering is.

**One `.sheet` modifier per view, driven by one optional route enum.**
SwiftUI honours a single sheet presentation per view: stack several `.sheet`
modifiers on the same view and only one of them can ever open, whatever the
other flags say. `SequenceComposer` had five and `ScheduledRoutineEditor`
had three, so on the Now screen "+", "Scheduled" and tapping a step row all
opened the Final Time picker — every button appeared broken while every
button was in fact setting its own flag correctly. Both now nest a private
`Sheet: Identifiable` enum and switch on it inside one `.sheet(item:)`. A
new sheet is a new case, never a new modifier.

**Do not present a `confirmationDialog` from a page of the Now pager.** An
action sheet raised from inside a paged `TabView` regularly swallows its
first tap while the pager settles, which reads as a dead button. `.alert`
presents on the first tap; `LiveRunPage`'s Stop confirmation uses one.

**The tint is `OnTimeSpectrum.accent`, and it must never be white.** A
`Toggle` draws its on state by filling the track with the tint behind a
white knob, so `.tint(.white)` made on and off render identically and every
switch in Settings became unreadable. Same trap for anything else the system
draws in the tint. The palette's whites are for *text*, not for controls.
Likewise, never colour a view with `Color.accentColor` here: the accent
asset and the environment tint are two different values that resolve at
different moments, which is what made `FullScreenTimePicker`'s big number
appear to start white and then turn blue on its own.

**Decoration must never be touchable: `.mask` and `.blur` clip pixels, not
touches.** `SpectrumText` fills its glyphs by overlaying a 900pt square
gradient and masking it to the text. The mask made it *look* like text; it
stayed a 900pt tap target, and inside the Final Time `Button`'s label that
gave that one button a hit region covering the whole screen. Every tap on
the Now page opened the time picker regardless of what was under the finger,
so "+", "Scheduled" and every step row read as broken buttons. Any
decorative layer larger than the thing it decorates needs
`.allowsHitTesting(false)`. It is on the text fill, the one decoration of
that shape left, and it belongs on the next one too.

This one is worth remembering as a *diagnostic* habit, not just a rule: the
symptom was "the buttons do not work," which sent two rounds of work into
sheet presentation plumbing (both real bugs, neither the cause). The clue
that settled it was "it used to work before," pointing at the new decoration
rather than the old controls.

**One spectrum element in the product means one.** The first pass put a
gradient border on the Start button, the Steps button, the Stop button, the
"+", the shortcut chips and the Live Activity's Complete button as well as on
each screen's hero, and the result was noise: nothing was emphasised because
everything was, and the colour stopped being able to mean anything. Then even
one per screen was too many, because a run is the screen you read while doing
something else. So the hero is the composer's Final Time number and nothing
else. Every button wears a plain white edge (`SpectrumButtonStyle`).

Two specific things were wrong with the per step hue, not just loud.
`OnTimeSpectrum.step` was a hue by index starting at 0, so **the first step of
any sequence drew its icon and its progress segment in the exact red this app
reserves for running late**: "step 1 of 2" rendered a healthy run in the alarm
colour. And a row of six hues at widget or Lock Screen size is a smear. The
function is deleted, along with the green to red `ramp` and the angular
gradient the old `SpectrumRing` swept.

`LiveRunPage` and `RunView` are monochrome throughout. The ring is gone,
replaced by `TimeBar`, a flat white line under the countdown. Symbols, step
rails, the current step card edge and the "step 1 of 2" strip are all white at
three opacities. Colour on those two screens means exactly two things:
`OnTimeSpectrum.late` red when a step is past its time, `OnTimeSpectrum.done`
green when one is finished.

**Work hours tracking is deliberately not built on `Run`.** A `WorkSession`
is one start time and one end time, and `endedAt == nil` is the only
representation of "running": no flag that could disagree with the
timestamps, and no engine holding state. `WorkClock.start` inserts and
saves immediately rather than leaving it to autosave, which is the whole
crash story (the interesting failure is the phone dying an hour into a
shift), and it is why nothing needs restoring on launch: an open session is
just a row a `@Query` finds. `WorkClock` also owns the one invariant, at
most one open session, and repairs a duplicate by closing the older one at
its own start rather than at now, so a bug can never invent paid hours.

`WorkHours` is the pure arithmetic and is where the tests live. Two rulings
in it are load bearing. A session crossing midnight is **split** between the
two days rather than attributed to the day it began on, so an overnight
shift appears on both days and the day rows still sum to the week. And the
quarter hour timesheet figure rounds the week total **once, at the end**,
never per day and then summed: seven days each rounded can drift about 45
minutes away from the hours actually worked, in either direction, and
`theWeekRoundsOnceRatherThanPerDay` pins that difference. Week boundaries
and day arithmetic go through `Calendar` (`dateInterval(of: .weekOfYear)`,
`date(byAdding: .day)`), never fixed second offsets, or the DST weekends
walk every day start an hour off midnight for the rest of the week.

The **Work tab is the fourth tab**, and it is not the thing the three tab
rule above forbids: it is not another navigational answer to "make a
sequence," it is a separate activity with a live running state that has to
be visible without digging, and `WorkSession` touches none of the
`TaskTemplate` / `Plan` / `Run` machinery. A `WorkSession` also has no
relationships in either direction, so it deletes with a bare
`modelContext.delete` and does **not** need `DeleteCleanup`. If it ever
grows a relationship, that stops being true.

**Every `AppSettings` property must be a stored property with a `didSet`
that persists**, never a computed property backed by `UserDefaults` — the
`@Observable` macro only tracks stored properties, so a computed one reads
and writes correctly but never tells SwiftUI to re-render. (Documented from
a real bug hit this way in shadiliya's settings.)

**Travel time resolution is layered, not a single call, and every layer has
an age.** `TravelTimeService` (now `@MainActor` — it is observed state that
also writes SwiftData models) tries the live MapKit ETA first, falls back
to its in-memory cache keyed on origin/destination coordinates (entries
older than `resolvedFreshness`, 45 minutes, are ignored), and falls back
again to the manual estimate chain. For a drive block that chain is: the
resolved ETA while `Block.resolvedAt` is within `resolvedFreshness`, then
the user's override, then the learned template estimate, then the *stale*
resolved value as a last resort before the 10 minute default. The
freshness gate is the ruling on a real conflict: a live ETA must beat the
scrubber value (its UI copy promises so), but a `resolvedMinutes` fetched
days ago must not beat an estimate the user typed a minute ago — before
`resolvedAt` existed it did, forever. `source(for:)` reports which tier
answered; `TravelTimeTests` pins the whole precedence chain.

`manualEstimateMinutes` is also the *only* thing that feeds `SolverInput`, so
it is where the learned estimate has to be consulted — it used to read
`template.manualEstimateMinutes` directly, which meant the app displayed a
learned duration on every screen while quietly scheduling against the guess
you typed the first time, however many times you had since run the step.

**`Estimator` blends learned duration data toward a manual prior**, weighted
by `W / (W + 3)` where `W` is the observations' *decayed* total weight
(30-day half-life), so a single fresh sample doesn't dominate and — the
part the raw count got wrong — a purely stale history cedes authority back
to the typed prior instead of keeping near-full weight forever. The
weighted quantile interpolates between adjacent order statistics rather
than snapping to one. `Confidence.safe` (p80) vs `.typical` (p50) picks
which side of the distribution to report; `AppSettings.confidenceIsSafe`
controls which one the app uses by default.

**A scheduled routine arms once per occurrence, keyed on the occurrence's
own day.** `lastArmedDay` is stamped with the start of the *deadline's*
day, and `hasArmed` compares against that — never against "today", which
double-armed any routine whose arm window straddled midnight.
`ScheduleService.catchUp(in:)` is the one entry point for
foreground/launch/BG-task catch-up (arm, then refresh alarms); the BG task
runs it against `container.mainContext`, never a throwaway context whose
writes nothing saves. The arm alarms are budgeted
(`armAlarmBudget`): iOS keeps only the soonest 64 pending requests
app-wide, so nearest windows are scheduled first and the far future is
what gets dropped, deliberately.

**The Home Screen widget reads a file, never the store.** `UpNextWidget`
shows the live run and the routines coming up, out of an
`OnTimeWidgetSnapshot` the app writes as JSON into the App Group container
(`group.com.mammer55.ontime`, declared in both targets' entitlements).
The obvious alternative — move the SwiftData store into the group and let
the extension run its own `@Query` — was rejected on three counts: the
store URL changing wipes the device once (there is no migration, see
`OnTimeApp.openStore`), the widget process would hold a second
`ModelContainer` against a database the app writes to constantly, and
`Solver`/`Estimator`/`TravelTimeService` would all have to compile into an
extension just to work out when a routine starts.

Everything in the snapshot is an **absolute wall-clock date the app already
computed**, which is the same principle the arm timeline runs on: a
snapshot written twenty minutes ago is still correct twenty minutes later,
and the widget only decides which rows have gone by. That is why it writes
a *week* of occurrences rather than the next one — the widget renders at
moments the app has no say over, and has to stay right through days of not
being launched.

`WidgetBridge` is the only writer. It **dedupes on the encoded payload, not
on call count**: `RunEngine.syncLiveActivityAndNotifications` fires about
twenty times per step (the Live Activity's ramp buckets) and the snapshot
is identical for nineteen of them, so comparing bytes is what keeps that
from becoming twenty `WidgetCenter` reloads. `setNeedsRefresh()` coalesces
a burst within one runloop pass; `refresh()` is the immediate form, used on
background. Timeline entries come from `changePoints` — the moments
something in the snapshot actually changes — plus a 15 minute heartbeat out
to six hours, rather than a fixed every-15-minutes timeline that would
spend the system's whole refresh budget redrawing identical pixels and have
none left at the boundary that mattered.

The widget is monochrome for the same reason the run page is, plus one it
cannot help: a widget cannot animate, and at that size a row of six per-step
hues is a smear. Countdowns in it obey the same two-form rule as everywhere
else — `Text(timerInterval:countsDown:)` over a range while running, an
explicit red `+` counting up once over, never `Text(_:style: .timer)`.

**A `ScheduledRoutine` edit reaches the run it already armed.** A routine's
blocks are copies (`Block.copyForSpawn`), so nothing about an armed run
tracks its routine — right for the steps, since a run half way through its
sequence cannot have rows swapped out from under it, and wrong for the
anchor time, which is the one number the app is built around. Changing "be
done by 12:50" to "be done by 1:10" mid-run left the countdown working
toward 12:50 with no sign the edit had landed. `ScheduleService.syncLiveRuns`
pushes the new anchor (and the name) onto the open run's `Plan` and re-solves
through the live engine. The new deadline is the new anchor applied to the
**run's own day**, never `nextOccurrence` — an anchor moved to a time
already past would otherwise re-point a run in progress at tomorrow.

**Cancelling a routine's run does not re-arm it, so there has to be a way
back by hand.** `lastArmedDay` is stamped at arm time and makes arming
idempotent per occurrence, which means a cancelled run is gone for the day.
That is the right default (a run that reappeared the instant you stopped it
would be worse), but until `ScheduleService.armNow` existed there was no
remedy at all short of waiting for tomorrow — the app had a Skip Today and
no undo for it. `armNow` clears `lastArmedDay` and today's skip, arms the
occurrence with `armAt` clamped to now, and returns any run already open
rather than minting a second one against the same routine. It is the leading
swipe action in `ScheduledRoutinesView`, and the row's status line now says
"Already ran" instead of claiming "Active now" for an occurrence whose run
was cancelled.

**Notification policy: every alert has to earn the interruption, and every
tap has to go somewhere.** The rules, and the thing each one replaced:

- **Two alerts per arm window, not seven.** `armAlertTimes` returns the
  window opening and the go moment, and collapses to just the go moment when
  they are under `armMinimumGap` apart. It used to be a chain every ten
  minutes across the window, capped at seven, on the theory that iOS won't
  pin a banner so persistence had to be built from repetition. It produced
  seven time-sensitive sounding interruptions per occurrence, all saying a
  near-identical sentence about a number the Lock Screen was already showing.
  Repetition is not persistence.
- **Only the go moment and a plan's own final deadline are
  `.timeSensitive`.** Everything else is `.active` or `.passive`, so a
  routine arming inside Do Not Disturb no longer forces its way in an hour
  early.
- **One alert per step, at its time.** The per-step lead warning is
  `AppSettings.leadWarningsEnabled`, off by default and silent/`.passive`
  when on. Both halves used to fire with sound, so a five step routine made
  ten noises describing a span the Live Activity was counting down anyway.
- **A `.walk` block gets no step notification at all.** `WalkTracker` owns
  that moment with alarms computed from measured pace, and they are the
  accurate ones; the step notification fired at the same instant saying
  something vaguer.
- **Nothing sounds in the foreground, and the plan on screen is silent
  entirely.** `Notifications.visiblePlanId` is set by `NowView` from the
  current page (and cleared on background). `willPresent` returned
  `[.banner, .sound, .list]` unconditionally before, so the app interrupted
  you to announce the countdown you were looking at.
- **Every tap routes.** `UNNotificationDefaultActionIdentifier` had no branch
  at all, so "Tap to open the countdown" opened whatever tab the app was last
  on. Taps and the arm alert's Start button now post
  `OnTimeShared.openRunNotification`, and `NowView` pages to the matching
  run; a `routineId` is retried on the next runloop pass because
  `ScheduleService.catchUp` may still be minting that run on this same
  foreground.
