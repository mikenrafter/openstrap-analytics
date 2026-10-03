# Changelog

## Unreleased

### Added
- `Calories.minuteEnergy` — per-minute energy (basal, active, walking, total,
  and an abstention reason) from the same computation `Calories.dailyEnergy`
  does. A minute with no usable HR and no billable cadence abstains: all values
  null, `abstained: MinuteEnergyAbstain.noHr`. Nothing is filled or interpolated.
  `MinuteEnergySeries.active` / `.walking` are `==` `dailyEnergy`'s, and
  `basalKcalPerMin * dayMinutes` is its `basal`.
- `Calories.hourlyRollup` — hourly sums of covered minutes with per-hour
  coverage; an hour with no covered minute is null, not zero.

### Unchanged
- `Calories.dailyEnergy` outputs are bit-for-bit identical. Its loop body moved
  into a helper shared with `minuteEnergy`; golden tests in
  `test/onehz/minute_energy_test.dart` pin the pre-change values with `==`.
  No `kAlgoVersion` bump is needed for this change.
