# Changelog

## Unreleased

### Added
- `stageMinuteRanges`: a [lo, hi] range of minutes per sleep stage (wake,
  light, deep, REM, and NREM = light + deep). `lo` counts epochs that can only
  be that stage: HR-covered, labelled so, and every deciding score at least
  `kStageScoreMargin` (0.1) from its cutoff. `hi` adds epochs that could still
  be that stage: uncovered or unlabelled epochs (any stage), and epochs with a
  score inside the margin (REM score: REM and its NREM substage; deep score:
  light and deep). An honest bound, not a confidence interval: the stager has
  no per-epoch probabilities. Null for no epochs.
- `CardioStagerResult.epochEvidence` (with `StageEpochEvidence`): per final
  epoch, the label, deep flag, HR coverage and the REM/deep scores the classify
  loop computed. `CardioStagerResult` carries `remScores`, `deepScores` and
  `hrCovered` for it. Stage labels are unchanged.
- `irregularBeatScreenDetailed` and `IrregularScreenState.evaluateDetailed`: the
  irregular-rhythm screen's verdict plus its evidence (`IrregularDiagnostics`) —
  beats in / kept after the [300, 2000] ms filter, the corrector's raw /
  corrected / dropped counts (passed in as `RrCleaningCounts`), artifact
  fraction, window counts (total, voting, flagged, the final OPEN window and
  what became of it, sustained share seen vs required) and the thresholds — for
  a screen that ran and for one that abstained (with the reason). Batch and
  streamed results are identical. `irregularBeatScreen` returns the same Metric
  as before. `IrregularScreenState` checkpoints are now version 2 (two more
  counters); a version 1 checkpoint is refused rather than restored with counts
  it never kept. A NaN beat no longer makes the checkpoint unencodable.
  `IrregularDiagnostics.artifactFraction` is null (absent) when the corrector was
  handed no beats: a share of nothing has no value, and the `1 - cleanFraction`
  of an empty series (1.0) must not read as "every beat is an artifact".
  Verdicts are unchanged.
- Incremental states for centered moments, fixed-grid Lomb–Scargle, time-domain
  HRV, motion with a measured gravity reference, and keyed minute TRIMP/energy.
  Appends reuse retained contributions; edits, removals and changed dependencies
  update or rebuild them. Batch algorithms remain available as test oracles.
- Bounded dependency-aware `CalculationCache` and explicit `CalculationMode`.
  Only `periodicAwake` permits reuse. Sleep, heavy and forced runs use full math.
- Minute summary mode avoids constructing per-minute energy records when only
  totals are needed. See `docs/INCREMENTAL_USAGE.md` for contracts and limitations.
- Parameterized incremental parity tests, checked-in capture fixtures, checkpoint
  tests, work counters and a deterministic timing comparison tool.
- `hrDipFromDayTotals`: `hrDip` from the day side's running count and sum, for
  callers that keep the waking day as totals. `hrDip` shares its scoring, so
  both give the same result for the same samples.
- `IncrementalMinuteMetrics.sync` takes `dayMinutes` as an `int`, as
  `Calories.dailyEnergy` does; a fractional day can no longer be passed.
- Long-run drift tests: 30 000 Lomb–Scargle appends and 100 000-step sliding
  moments stay within 1e-9 of the batch results.
- `IntHistogram`: exact, mergeable order statistics for integer-valued series
  (heart rate), kept as a sorted `value -> count` list. `percentile` and `median`
  return the same doubles as `percentileSorted` on the expanded sorted list,
  and null when empty. Not wired into any caller yet; see
  `docs/INCREMENTAL_USAGE.md` for which batch callers could adopt it.
- Pinned Nix devshell with Flutter 3.41.6 / Dart 3.11.4 and native build tooling.
- `Calories.minuteEnergy` — per-minute energy (basal, active, walking, total,
  and an abstention reason) from the same computation `Calories.dailyEnergy`
  does. A minute with no usable HR and no billable cadence abstains: all values
  null, `abstained: MinuteEnergyAbstain.noHr`. Nothing is filled or interpolated.
  `MinuteEnergySeries.active` / `.walking` are `==` `dailyEnergy`'s, and
  `basalKcalPerMin * dayMinutes` is its `basal`.
- `Calories.hourlyRollup` — hourly sums of covered minutes with per-hour
  coverage; an hour with no covered minute is null, not zero.

### Changed
- **Output change (combined bump, planned; edge must bump kAlgoVersion when
  pinning this): RR artifact-run cap and a gap-anchored 30 s epoch grid.**
  `correctRr(maxArtifactRun:)` and `RrCorrector(maxArtifactRun:)` (default
  `kMaxArtifactRun` = 32; null = uncapped) turn an artifact run longer than the
  cap into a gap: the series splits there and each side is corrected on its own.
  Runs of 32 or fewer, the only kind on 18 days of real data, give today's
  output exactly. Sleep staging lays its 30 s epochs from the first sample of
  each gap-free run (a gap the stager's 60 s accel carry-forward cannot bridge
  starts a new run), not from the start of the detected session; the anchor
  depends on the data only, so it streams. New `EpochRows` accumulates the
  per-epoch feature rows. `RrSandwich` / `RawRr` / `NnColumn` feed capped,
  corrected NN into the night aggregators from raw RR in mergeable chunks, each
  NN with the absolute timestamp of the beat it came from
  (`RrCorrectionResult.nnSourceIndex` says which beat that was). Registry counters
  `found.rr_correction` and `sleep.stage` go to 2.
- `IrregularScreenState` checkpoints are version 3: they carry the previous kept
  beat's time, because a pair across a time hole is no longer successive.
  Versions 1 and 2, and a version 3 checkpoint without `prevT`, are refused.
- `IncrementalHrvTime` follows `hrvTime`'s jitter gate under the ACF floor
  (respiratory-line exemption, breathing-line fallback): when either could
  apply it hands the night to the batch, so the incremental output equals
  `hrvTime` where it used to refuse RMSSD. Checkpoint format unchanged.
- `hrvTimeAggregator` follows `hrvTime`'s jitter gate under the ACF floor
  (respiratory-line exemption, breathing-line fallback) from mergeable
  evidence (O(5-min windows), never the beats). Its checkpoint state is now
  `[core, evidence]`; a checkpoint without the evidence is refused whole.
- `cvhrApneaScreen` abstains with 'non-finite beat time' on a NaN or infinite
  beat time (as `rsaRespRate` / `hrvFreq` do); `CvhrStream` refuses such a
  fold and answers a snapshot with such a tail the same way. Finite input:
  output unchanged.
- **Output change: hrvFreq / cardiacCoherence move at the ~1e-6 relative level;
  edge must bump kAlgoVersion when pinning this.** `lombScargle` now measures
  time from the first sample (`t - t.first`) instead of raw epoch seconds,
  whose trig arguments reach ~1e10 rad and carried up to ~5e-6 relative error
  per frequency. Every `lombScargle` caller moves: `hrvFreq`, `cardiacCoherence`,
  the respiration RSA/peak rate, and the cardio stager's LF/HF. Band-integrated
  results move far less than the per-frequency worst case (on the checked-in
  July 2026 night at epoch timestamps, LF/HF/total and coherence ratio change by
  about 1e-14 relative), but any threshold they feed can in principle flip, so
  recompute stored rows. `IncrementalLombScargle` already used first-sample
  time and is unchanged; it now agrees with batch on epoch seconds to within 1e-9
  (the new precision test saw 9e-6 before the change).

### Unchanged
- `Calories.dailyEnergy` outputs are bit-for-bit identical. Its loop body moved
  into a helper shared with `minuteEnergy`; golden tests in
  `test/onehz/minute_energy_test.dart` pin the pre-change values with `==`.
  No `kAlgoVersion` bump is needed for this change.
