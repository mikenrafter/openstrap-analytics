# Changelog

## Unreleased

### Added
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
