# Incremental calculations

Import `package:openstrap_analytics/onehz.dart`. The batch functions remain
available and are the reference algorithms used by the tests.

| State | Cached math | Rebuild conditions |
|---|---|---|
| `RunningMoments` | Centered count, mean and sum of squared deviations; add, remove and merge | Caller owns membership when removing a value |
| `IncrementalLombScargle` | Seven trigonometric sums per frequency, centered moments and time span | Earlier point edits, removals, a changed origin, or `force: true` |
| `IncrementalHrvTime` | NN moments, contiguous differences, lag-one products and five-minute bins | Earlier beat/time edits, removals, timing-mode changes, or force |
| `IncrementalEnmoSeries` | Trailing gravity sums and motion-minute buckets | Earlier sample edits, parameter changes, automatic gravity calibration, or force |
| `IncrementalMinuteMetrics` | TRIMP and energy contributions indexed by minute key | Changed minutes are repriced; changed HR anchors, sex or profile reprice all minutes |
| `CalculationCache` | Results with complete, owned dependency snapshots | Changed dependencies, explicit full evaluation, or eviction |

Pass the complete current input to `sync`. Each state checks that retained data
still matches, so replacing an old timestamp or value cannot silently leave a
stale result. Input comparison and output construction still visit retained
data. The work counters count samples whose math was evaluated, not every
array read or allocation.

Minute keys must be unique and aligned with HR and optional cadence. Day duration
must be a finite whole number of minutes, matching `Calories.dailyEnergy`.
Changing day duration or the quiet-waking strain reference changes the summary
without repricing minute contributions.

Use `includeMinuteSeries: false` when a caller needs only TRIMP, strain and
energy totals. It avoids rebuilding the minute output list. Turning that view
back on exposes the same retained contributions without repricing them.

ENMO with an automatic gravity reference uses the full `enmoSeries` algorithm.
That reference comes from the whole record's median and can change earlier
minutes. Pass an explicit measured reference to use the incremental gravity
queue. The RR corrector also remains a full calculation because new beats can
change which earlier beats survive correction.

HRV preserves time gaps, partially filled five-minute bins, the beat-timing
jitter refusal, confidence and notes. Ill-conditioned autocorrelation sums and
values near the refusal threshold fall back to the batch calculation.

State checkpoints use `toJson` / `fromJson`, with version and type checks.
They retain double precision before public metric formatting. An unsupported
or malformed checkpoint throws; discard it and perform a full rebuild.

Cache dependencies should be JSON-compatible maps, lists and scalars. Cached
results should be immutable objects or JSON-compatible collections. The cache
owns copies of collection results and dependencies and evicts the least
recently used entries at its configured limit.

`CalculationMode.periodicAwake` is the only mode that permits reuse. Sleep,
heavy and forced runs must evaluate the full algorithms. The app owns awake
evidence, phone charging state and when a successfully persisted result may
replace its previous cache. These are orchestration decisions, so the math
package has no clock, battery API or database dependency.

Run the deterministic timing comparison with:

```sh
nix develop -c dart run tool/incremental_benchmark.dart
```

The benchmark reports local elapsed times and math-work counts. The parameterized
tests compare values, absent results, confidence, notes and provenance against
the batch algorithms after appends, revisions, deletions and checkpoint restores.
They also read subsets of the checked-in July 2026 overnight capture. Missing
capture files fail these tests rather than skipping them.
