# Audit: solver-math

Subsystem summary: four pure modules turn durations plus a deadline into scheduled times (Solver), resolve a clock time to an absolute Date (DeadlineResolver), learn durations from decayed samples (Estimator), and compute walk return estimates (WalkMath). The algebra itself is correct in every case I could construct; the findings are about a stale documentation claim, error signals that every caller discards, blend weighting that ignores sample age, and untested numeric outputs.

I looked specifically for division by zero and empty sample crashes in Estimator and WalkMath and found none: `Estimator.estimate` guards n > 0, `weightedQuantile` guards zero total weight, and `WalkMath.returnEstimate` guards `measuredPace > 0` before dividing. I looked for sign and off by one errors in `suffixAfter` and the leaveBy computation and found none: `suffixAfter[i]` correctly sums durations strictly after i, and `leaveBy = deadline - suffixAfter[i]` is the correct end boundary for block i. Midnight rollover in DeadlineResolver is correct (a 00:30 deadline at 23:50 rolls to tomorrow, 40 minutes away).

## Pass A: mechanical review

```
ID:        solver-math-1
Location:  OnTime/Core/Solver.swift:59
Class:     correctness
Claim:     SolverError.overdetermined is dead code, and the contract documented at lines 21 to 22 ("Exactly one of start / the flex block's duration must be unknown") is not enforced.
Evidence:  .overdetermined appears nowhere else in the repo. The path with no flex block and a supplied start (line 74 comment, line 80) accepts a fully determined input deliberately and reports mismatch via lateness.
Trigger:   Reading the type to learn the contract; the doc comment and the behavior disagree.
Blast:     Confusion only. No runtime effect, but a future caller may match on a case that cannot occur, or trust the header comment over the code.
Confidence: high
```

```
ID:        solver-math-2
Location:  OnTime/Core/Solver.swift:17
Class:     correctness
Claim:     The flexAbsorbs doc comment says the payload "carries the flex time currently remaining, which the UI shows counting down live," but remainingFlex is a static solved value that does not move with the wall clock.
Evidence:  remainingFlex is set to flexDuration (line 157), which equals deadline minus start minus knownSum (line 112). RunEngine.recomputeSolution (RunEngine.swift:348 to 370) rebuilds the input every tick from run.startedAt (fixed) and manualEstimateMinutes (static during a run), so the solved flex value is identical on every tick. RunView.swift:349 to 351 prints it directly as "flex: Nm".
Trigger:   Any run with a pre flex block: while that block overruns in real time, the displayed remaining flex does not shrink, because actual elapsed time is never fed into the solve.
Blast:     The row label is a constant presented as a live number. The misdescription lives in Solver; whether the display should instead consume actuals is a RunEngine design question outside this scope.
Confidence: high
```

```
ID:        solver-math-3
Location:  OnTime/Core/Solver.swift:64
Class:     boundary
Claim:     Solver performs no validation that known durations are nonnegative; a negative .known value produces a scheduledEnd earlier than scheduledStart and non monotonic leaveBy values with no error.
Evidence:  Durations flow straight from the input into resolvedDurations, elapsed accumulation (line 138), and suffixAfter (line 131). Nothing checks sign. Negative flex is legal by design (test 7), but a negative known duration is nonsense the solver still schedules.
Trigger:   An upstream bug in estimate resolution handing back a negative minute count. I traced manualEstimateMinutes far enough to see positive fallbacks, but did not prove every tier is nonnegative; this is inferred, not verified.
Blast:     A silently inverted schedule: blocks whose leaveBy precedes their scheduledStart, notifications armed in the past.
Confidence: low
```

```
ID:        solver-math-4
Location:  OnTime/Core/Estimator.swift:56
Class:     correctness
Claim:     The blend weight n / (n + 3) uses the raw observation count, not the decayed effective weight, so a pile of stale observations keeps near full authority over the manual prior even after the half life has reduced their weights to almost nothing.
Evidence:  wData = Double(n) / (Double(n) + priorPseudoCount) at line 56 counts observations; the decay computed at lines 48 to 52 only redistributes weight among observations inside weightedQuantile. Ten samples all 180 days old give wData = 10/13, about 77 percent, exactly as if they were recorded today.
Trigger:   A step not run for months, then estimated: the estimate still reports the old learned value at high weight instead of drifting back toward the typed prior. The header comment sells decay as "old outliers fade," which is only true relative to newer samples, never relative to the prior.
Blast:     Estimates for dormant steps are more confident than the data warrants. Bounded harm: the values themselves are still the best available history, so this may also be read as intended behavior.
Confidence: medium
```

```
ID:        solver-math-5
Location:  OnTime/Core/DeadlineResolver.swift:27
Class:     boundary
Claim:     The nil guard is effectively unreachable because Calendar.date(from:) normalizes out of range components instead of failing, so an invalid hour (for example 25) silently yields a deadline on the wrong day rather than hitting the fallback.
Evidence:  Foundation's Calendar rolls overflowing components forward (hour 25 becomes 01:00 the next day); it does not return nil for them. The comment at line 28 already suspects the guard is unreachable but frames the risk as "malformed calendar," not as silent normalization of malformed input.
Trigger:   A caller passing an unvalidated hour or minute. Current callers pass picker backed settings, so this is latent. Inferred from documented Foundation behavior, not executed.
Blast:     A wrong day deadline with no error anywhere, which downstream reads as a routine armed for the wrong time.
Confidence: medium
```

```
ID:        solver-math-6
Location:  OnTime/Core/WalkMath.swift:117
Class:     boundary
Claim:     safetyFraction is applied unvalidated; a negative value silently shrinks the padded estimate below the raw one, inverting the documented "pad because late costs more" asymmetry.
Evidence:  seconds: raw * (1 + safetyFraction) at line 117 with no clamp. The value arrives from AppSettings.walkSafetyFraction (WalkTracker.swift:254).
Trigger:   A settings bug or a future UI exposing the fraction without bounds.
Blast:     The turnaround alarm fires later than the raw estimate says it should, which is the one failure the padding exists to prevent.
Confidence: low
```

```
ID:        solver-math-7
Location:  OnTime/Core/Solver.swift:56
Class:     error-handling
Claim:     Every production call site consumes SolverError with try? and discards the reason, so multipleFlexBlocks and underdetermined degrade to "no solution" with no signal to anyone.
Evidence:  RunEngine.swift:73 and 370, ScheduleService.swift:98, NowView.swift:79 all use try?. I found no editor guard in QuickBlockEditorSheet preventing a second open duration block in one plan, so the multipleFlexBlocks path appears reachable from the UI.
Trigger:   A plan containing both a walk block and a flex block (both map to .flex in recomputeSolution, RunEngine.swift:353 to 354).
Blast:     currentSolution stays nil: no leaveBy times, no lateness, no step notifications, and nothing on screen says why. The plan looks broken rather than invalid.
Confidence: high (that errors are discarded); medium (that the UI actually permits building the triggering plan, since I did not read the whole editor)
```

## Pass B: structural audit

### 1. Boundaries

Data enters Solver as `[BlockDuration]` built by RunEngine.recomputeSolution, RunEngine.naturalStart, NowView, and ScheduleService from minute estimates times 60. Validated at the seam: at most one flex (throw), start present when a flex exists (throw), non empty (throw). Assumed but unvalidated: known durations are nonnegative (solver-math-3), and pinnedFlex is only set when a flex block exists (a pinned value with no flex block is silently ignored, see assumption solver-math-15).

Data enters Estimator as `[DurationObservation]` plus an Int prior in minutes. Assumed: minutes and prior share units, recordedAt is not in the future (a future date is clamped to weight 1 by the max(0, ...) at line 49, which is correct handling). Nothing constrains minutes to be positive; a zero or negative sample would flow through the quantile arithmetic without error.

Data enters WalkMath as GPS derived pace samples and MapKit route numbers. Validation is real here: movingThreshold discards standing samples (which also silently absorbs CLLocation's invalid speed of minus 1, a nice property), and the min and max pace clamps launder instrument error. Unvalidated: safetyFraction (solver-math-6) and routeDistanceMeters sign.

DeadlineResolver assumes hour and minute are in range; out of range values are normalized by Calendar rather than rejected (solver-math-5).

### 2. Error handling

Solver throws typed, equatable errors, which is the right shape, but the information dies at every call site (solver-math-7). DeadlineResolver's fallback returns `now` for a failure it cannot distinguish from a valid answer, though the branch is effectively unreachable (solver-math-5). Estimator's zero total weight fallback (Estimator.swift:69 to 74) is defensively correct but practically unreachable: pow(0.5, ageDays / 30) underflows to zero only when ageDays exceeds roughly 32000 days, about 88 years. It is safe against the empty array because estimate guards n > 0 before calling. No caught and discarded errors exist inside these four files themselves; the discarding happens one layer up.

### 3. State and lifetime

Clean. All four modules are caseless enums with only static functions and static constants; nothing outlives a call, nothing can be observed inconsistent, nothing needs cleanup. The only mutable state in the subsystem's orbit (running pace, path distance) lives in WalkTracker, outside this scope, and WalkMath's API is shaped so that state stays there.

### 4. Test gaps

```
ID:        solver-math-8
Location:  OnTimeTests/SolverTests.swift:67
Class:     test-gap
Claim:     No test asserts any hardLeaveBy value numerically, so a uniform shift of every leaveBy by one block's duration would pass the whole suite.
Evidence:  Tests 3 through 6 assert only case membership (.flexAbsorbs vs .hardLeaveBy) and invariance across a later start or an overrun. A suffixAfter indexing error that shifted all leaveBy dates equally is invariant under both, and no test compares a leaveBy against an expected clock time.
Trigger:   Any future refactor of buildSolution.
Blast:     The flex block's own leaveBy is the walk feature's whole output (the time by which the walker must head back, per CLAUDE.md); it is exactly the untested number.
Confidence: high
```

```
ID:        solver-math-9
Location:  OnTimeTests/DeadlineResolverTests.swift:5
Class:     test-gap
Claim:     DeadlineResolver has no midnight boundary test, no exact equality test (candidate equal to now), and no DST test; everything runs in UTC on one fixed day.
Evidence:  Three tests, all with the calendar pinned to UTC and day 19. The interesting inputs (now 23:50 with a 00:30 deadline, now exactly at the deadline second, a deadline inside a spring forward gap) are absent.
Trigger:   Regression in the comparison or in the day roll arithmetic.
Blast:     The one function that decides today versus tomorrow for every quick deadline is tested only in its easy region.
Confidence: high
```

```
ID:        solver-math-10
Location:  OnTimeTests/SolverTests.swift:25
Class:     test-gap
Claim:     The path with no flex block and a supplied start is never tested with slack (negative lateness), and only incidentally tested at all.
Evidence:  SolverTests never passes both a start and all known durations; the single such case lives in DeadlineResolverTests.swift:64 and covers positive lateness only.
Trigger:   A regression in the lateness sign convention (the doc at Solver.swift:51 to 52 promises a specific sign).
Blast:     Lateness feeds RunEngine.latenessMinutes and the UI's over or under badge; a sign flip would surface as being told you are late while early.
Confidence: high
```

```
ID:        solver-math-11
Location:  OnTimeTests/EstimatorTests.swift:37
Class:     test-gap
Claim:     EstimatorTests pin exact outputs (13, 15, 23) that encode priorPseudoCount equal to 3 and the rounding rule, asserting implementation constants rather than behavior, while the genuinely questionable behavior (purely stale observations against the prior, solver-math-4) has no test at all.
Evidence:  Lines 37, 39, 83 hardcode blend arithmetic results. No test builds a sample set that is entirely old and checks where the estimate lands relative to the prior.
Trigger:   Tuning priorPseudoCount breaks three tests that were never about it; meanwhile the stale data behavior can change silently.
Blast:     Test suite friction plus an unspecified behavior in the one place the design comment makes a claim ("old outliers fade") that the code only half implements.
Confidence: high
```

```
ID:        solver-math-12
Location:  OnTimeTests/WalkTests.swift:16
Class:     test-gap
Claim:     WalkTests never covers a sample between movingThreshold and minPace (0.4 to 0.6, which clamps up), nor the fallback ordering when routeDistance is present but both routeSeconds and pace are nil, nor projectedArrival.
Evidence:  Pace tests use 0.05, 0.1, 1.0, 1.4, 1.6 and 40; the clamp up region is untested. returnEstimate tests cover three of the four meaningful nil combinations. projectedArrival appears in no test.
Trigger:   Refactoring the guard order in updatedPace or returnEstimate.
Blast:     Small: the functions are short, but the clamp up case is the one where "moving" and "plausible pace" disagree, which is precisely where a guard reorder changes behavior.
Confidence: high
```

### 5. Load bearing assumptions

```
ID:        solver-math-13
Location:  OnTime/Core/Solver.swift:68
Class:     assumption
Claim:     "At most one open duration block per plan" is enforced only by a throw that every caller discards; nothing I found in the block editor prevents building a plan with a walk block and a flex block.
Evidence:  The guard at line 68 throws; solver-math-7 shows all callers use try?. A grep of the Views and Models for isOpenDuration shows no count check in QuickBlockEditorSheet.
Trigger:   The user adds a second open duration step to a plan.
Blast:     The entire schedule silently disappears for that plan (nil solution), with the failure indistinguishable from a bug.
Confidence: medium (editor not read end to end)
```

```
ID:        solver-math-14
Location:  OnTime/Core/Solver.swift:37
Class:     assumption
Claim:     BlockSchedule.index is the position in the durations array, and consumers treat it as equal to Block.order, so the whole subsystem assumes order values are gapless 0..<n, enforced only by the renumber() convention documented in CLAUDE.md.
Evidence:  RunEngine.swift:380 matches sched.index against block.order. Solver assigns index from the loop counter (line 163).
Trigger:   A move, insert, or delete path that forgets renumber(), leaving a gap or duplicate.
Blast:     schedule(for:) returns nil for the misnumbered block; leaveByDate falls back to projectedEnd (RunEngine.swift:405), so the row shows a subtly different time with no error, the exact two clocks on one screen bug the leaveByDate comment says was already fixed once.
Confidence: high
```

```
ID:        solver-math-15
Location:  OnTime/Core/Solver.swift:87
Class:     assumption
Claim:     pinnedFlex is assumed to be set only when a flex block exists; when no flex block is present the pinned value is silently ignored rather than rejected.
Evidence:  The pinned branch at line 87 sits under flexIndex != nil; the no flex path at lines 71 to 83 never reads input.pinnedFlex for duration purposes (buildSolution reads it at line 145 only to compute an absorb boundary that is nil regardless when flexIndex is nil).
Trigger:   A run pins its flex, then the flex step is deleted from the plan mid run; run.pinnedFlexMinutes survives with nothing to pin.
Blast:     None today (the value is inert), but the contract is invisible: a future reader may believe pinning without a flex block throws.
Confidence: high
```

### 6. Enhancements

Ranked, strictly improvements, not bugs.

```
ID:        solver-math-16
Location:  OnTime/Core/Estimator.swift:56
Class:     enhancement
Claim:     Use effective sample size (the sum of decayed weights, or a Kish style effective n) instead of raw n in the blend, so stale data cedes authority back to the manual prior as it ages.
Evidence:  Ties directly to solver-math-4; the weights are already computed two lines above and could feed the blend for free.
Trigger:   n/a
Blast:     n/a
Confidence: high
```

```
ID:        solver-math-17
Location:  OnTime/Core/Solver.swift:64
Class:     enhancement
Claim:     Surface the SolverError reason to the UI (for example a Result valued solve, or a currentSolutionError alongside currentSolution) so an invalid plan says why it has no schedule instead of rendering blank.
Evidence:  solver-math-7 shows four call sites independently discarding the same information.
Trigger:   n/a
Blast:     n/a
Confidence: high
```

```
ID:        solver-math-18
Location:  OnTime/Core/Estimator.swift:66
Class:     enhancement
Claim:     Interpolate the weighted quantile between adjacent sorted values instead of returning the first value whose cumulative weight crosses the target, so p80 on a small sample moves smoothly rather than jumping between observed values.
Evidence:  With five equal weight samples, p80 snaps to the fourth value exactly; one added sample can move the reported safe estimate by the full gap between neighbors.
Trigger:   n/a
Blast:     n/a
Confidence: medium
```

```
ID:        solver-math-19
Location:  OnTime/Core/WalkMath.swift:156
Class:     enhancement
Claim:     Consider computing remainingOutbound from the raw (unpadded) return estimate rather than the padded one, since the halving rule is itself documented as a pessimistic floor and stacking it on the safety fraction compounds two safety margins.
Evidence:  WalkTracker.slack (WalkTracker.swift:265) feeds estimate.seconds (padded) into slack, which remainingOutbound then halves; the pad is thus counted twice on the outbound budget.
Trigger:   n/a
Blast:     n/a
Confidence: medium
```

```
ID:        solver-math-20
Location:  OnTime/Core/DeadlineResolver.swift:21
Class:     enhancement
Claim:     Validate hour and minute ranges (a precondition in debug, or clamp with a documented rule) so Calendar's silent normalization of out of range components (solver-math-5) fails loudly during development instead of producing a wrong day deadline.
Evidence:  The existing guard cannot catch this class of input; a range check would.
Trigger:   n/a
Blast:     n/a
Confidence: high
```
