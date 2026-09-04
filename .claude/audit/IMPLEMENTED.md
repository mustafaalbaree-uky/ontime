# Phase 2 Implementation Record

Date: 2026-08-24. Every change is in the working tree, uncommitted. Build
passes; the full suite (88 tests, 10 suites) passes on the iPhone 16
simulator. Findings reference `AUDIT.md` and the subsystem files beside it.

## The one thing to know before launching on the phone

`Plan`, `Run`, `ScheduledRoutine`, and `Block` gained a persisted `uuid`,
and `Block` gained `resolvedAt`. Under the documented no-migration policy
the on-device store rebuilds on the first launch of this build. The old
store files are now moved aside (`.incompatible-<epoch>` suffix in
Application Support), not deleted.

## Cross-cutting findings: all ten addressed

- **CC-1 (swallowed solver errors, unenforced one-open-block invariant)**:
  `RunEngine.solutionErrorMessage` keeps the `SolverError` reason and
  `RunView` shows it; `QuickBlockEditorSheet` and `TemplateDrawerSheet`
  hide flex/walk once the sequence has one (`allowsOpenDuration`);
  `NowView.mustStartAt`, `RunEngine.naturalStart`, and the occurrence math
  map an open block to `.known(0)` (the zero-flex latest start) instead of
  an underdetermined solve — this also gives armed flex/walk routines a
  real wait countdown, auto-start, and a Live Activity (ro-6, ui-1, ui-12).
- **CC-2 (walk alarm self-disarm)**: policy extracted to the pure
  `WalkMath.alarmDecision` (tested): a past turnaround fires an immediate
  alert once via `Notifications.deliverAlarmNow` instead of disarming;
  `armAlarm` no longer removes the pending request before refusing a past
  date; the late alarm arms once per crossing with hysteresis instead of
  being re-deferred every tick.
- **CC-3 (authorization never re-read)**: Settings shows a denial warning
  with an Open Settings button, refreshed on foreground; `WalkTracker`
  checks at `begin` and `WalkCard` says the alarm cannot fire; every
  `center.add` result is now at least logged.
- **CC-4 (Complete Step round trip)**: the notification name and pending
  advance key live in `Shared/OnTimeShared.swift`; `CompleteStepIntent`
  persists the tap before posting and `RunEngineStore.consumePendingAdvance`
  replays it at the next launch; `OnTimeApp.init` registers the delegate
  and the observer synchronously before launch completes.
- **CC-5 (dangling references)**: `DeleteCleanup` nils every unpaired
  referrer before deleting a TaskTemplate, Place, or ScheduledRoutine; all
  three delete sites use it; covered by a container-backed test.
- **CC-6 (unstable identity)**: engines key on `Run.uuid`, activities and
  notifications on `Plan.uuid`, arm alarms on `ScheduledRoutine.uuid`,
  travel maps on `Block.uuid`; the BG task uses `container.mainContext`
  instead of a throwaway autosave-off context.
- **CC-7 (ageless travel data)**: `Block.resolvedAt` persists; the drive
  tier of `manualEstimateMinutes` honors the resolved ETA only within
  `resolvedFreshness` (45 min), then override, learned, stale resolved,
  default — the D-1 ruling, documented in CLAUDE.md; the ETA cache is
  age-gated the same way; `ScheduleService.durations` no longer duplicates
  the chain.
- **CC-8 (stale Live Activities)**: `current(for:)` treats `.stale` as
  live, so overrun activities update and end instead of duplicating; the
  widget reads `isFinished` first in phase resolution; the staleDate
  contract is documented at its one implementation point.
- **CC-9 (twice-found duplicates)**: QuickShortcut uses max-plus-one
  ordering and renumbers on delete; `ScheduledRoutineEditor.delete` (and
  LearnedSteps/Places deletes) snapshot before deleting.
- **CC-10 (launch ordering)**: `cancelAllRunNotifications` removes only
  run-prefixed requests (arm alarms untouched); a failed open-runs fetch
  aborts instead of tearing everything down; `ScheduleService.catchUp` is
  the single arm-then-refresh entry point.

## Ranked findings

Tier 1 and 2: all implemented (store retry plus move-aside; midnight
double-arm fixed by keying `lastArmedDay` on the occurrence's deadline day;
picker Cancel actually cancels via a working copy; walk ownership stops
cross-run teardown; walk home coordinate resets per walk; LocationService
rejects stale/garbage fixes and stamps the fix's own timestamp; arm alarm
budget; backdated-at-birth runs; `advanceStep` finished guard; wait-phase
widget copy via `startsRunAtTarget`; seeded places require a real fix;
mid-run template inserts carry their places; honest cancel copy; orphan
sweep covers finished runs; estimator effective-weight blend plus
interpolated quantile; `TravelTimeService` is `@MainActor`; forced route
refresh cancels in-flight; location errors no longer masquerade as route
errors; near-duplicate arm alerts gapped; engines self-retire; routine
draft rows cleaned up; snapshot places dedupe; template-selection onChange
guard; startAt pinned to front on drag).

Tier 3: implemented, including deterministic notification identifiers,
sentinel fetch hardening, kindRaw assertion, delivered-notification
cleanup, endAll double sweep, dead quick countdown pair removed,
synthesized Equatable, AppSettings single-definition keys with clamped
loads and injectable defaults, shared TimeFormatting (locale-honoring,
fixes missing AM/PM), TimerShortcut helper with failure haptic, place
editing with coordinate validation, secondary sort on routines,
parseTime POSIX locale, PlaceSearchField resolution errors surfaced,
NowView timer gated on scenePhase, timer tolerance, per-tick solve
reduction, deinit timer safety net, widget placeholder container
background, lock screen explicit colors, trailing-space label
normalization, ramp fraction shared via `OnTimeActivityLogic`.

Deliberately not done (documented): weekdays-empty model guard beyond the
picker (unchanged, single writer); implicit template accumulation (by
design per CLAUDE.md); run history and the real home screen widget
(Phases 4 and 5, separate features).

## Test gaps: closed

New or extended: numeric leaveBy assertions and the given-start slack case
(SolverTests); midnight/equality/clamping (DeadlineResolverTests); stale
cluster, fresh-weight pin (EstimatorTests); clamp-up region,
projectedArrival, fourth fallback combination, negative fraction, and the
whole alarm policy (WalkTests); arming against a real in-memory store with
the midnight straddle and backdate assertions, the alert-gap test, and the
open-duration occurrence test (ScheduleServiceTests); the full
manualEstimateMinutes precedence chain and cache staleness
(TravelTimeTests); the schema-driven copyForSpawn tripwire, Schema0 round
trip, and DeleteCleanup coverage (PlanTests); the widget phase truth
table, ring guard, span fraction, and over captions (ActivityLogicTests);
parseTime and AppSettings loads (UIHelperTests).

Not covered (out of reach of the simulator suite): RunEngine.reconcile
end-to-end after suspension, ActivityKit stale-state transitions, the
BGAppRefreshTask, and anything requiring the physical phone — see
AUDIT.md section 5.
