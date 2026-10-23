The RR cap, the epoch accumulator, the RR sandwich and the gap-anchored grid
are implemented. One existing guard still fails: the advanced-stager still-night
efficiency (0.808 against the required 0.85), for the reason given under
"Grid". The branch is not fully green until that is decided.

Implemented APIs:

- `correctRr(..., maxArtifactRun: K)` defaults to 32. `null` retains the
  uncapped implementation. A hard artifact run over K is cut before its
  neighbours are classified. Longer detected soft runs also split the input.
  Each side has separate correction windows; dropped gap beats keep an input
  class. Runs under the cap use the original batch implementation verbatim.
- `RrCorrector(maxArtifactRun:)` persists K and uses a bounded raw window for
  the capped path. The uncapped path retains the original incremental kernel.
  Settled output plus the snapshot equals the capped batch in the cap tests,
  including one-beat folds, JSON restarts, and 10,000 junk beats.
- `NnColumn(inner)` delegates fold, combine, finish, and persistence to a
  `DoubleColumn` aggregator over `Beats.nnMs`.
- `EpochRows` implements the gap-anchored grid (below), fold,
  final/provisional/all rows, `newestMs`, JSON restore (checkpoint version 2),
  and `stageWindow`. It keeps final features and a
  raw time tail. The provisional watermark is four minutes behind the newest
  sample. Gravity references use a sliding sorted time window. Partial HR
  coverage is retained so sparse cardiac evidence cannot appear complete
  merely because each epoch has a mean. Carry-only epochs also remain in the
  classifier's coverage denominator.
- The default advanced stager delegates to these rows. Feature
  context extends beyond the requested session. The existing bounded accel
  coverage and unobserved-run semantics remain in use.
- Registry counters `found.rr_correction` and `sleep.stage` are 2. Other
  counters remain 1; the registry's dependency closure covers `epoch_rows.dart`.

The corrector checkpoint is version 2. Version 1 is refused, including a
pre-cap checkpoint whose already-settled output could conflict with a later
cap decision. K, including null, is explicit. The capped path's conservative
settle delay is **4H + 2K + 4 = 248 beats**, plus up to a short artifact run.
This exceeds the brief's approximately 124-beat target. It needs further work
before the latency requirement can be called satisfied.

The LF/HF grid is unchanged. Complete, identical per-row beat windows do not
need a fixed spectral grid to give exact chunk parity. Probing fixed lower
frequencies of 1/180 Hz and 0.04 Hz did not change this night's stage agreement.

Sandwich (owner decision 2026-10-22: absolute timestamps). `RrSandwich`
hands its inner aggregator `Beats(nnMs, timeMs)` where each NN's time is the
ABSOLUTE `rrTsMs` of the input beat it came from (the beat itself, or for a
spline-corrected beat its own timestamp), not `correctRr`'s first-beat-relative
clock. `RrCorrectionResult.nnSourceIndex` (new, optional, default empty on a
hand-built result) says which input index each NN came from; no existing field
changed. With absolute times a seam needs no clock translation, which removes
the counterexample that blocked the first attempt (an inner aggregator keyed on
one fixed time).

State: a chunk of m beats keeps the first and last W = 2 * reach raw beats
(reach = 4H + 3K + 4 = 280 at the defaults; H = windowBeats ~/ 2, K = the cap)
and the inner state over the NN of beats [reach, m - reach), which no beat
outside the chunk can change. `combine` re-corrects only `left.tail ++
right.head` (via `correctRr`, `nnSourceIndex` selecting the seam beats) and
feeds the newly settled NN, so state is head + tail + whatever the inner keeps.
`finish` corrects the head and tail windows (clipped exactly as the whole
series is) and combines them around a copy of the settled middle.
`addSlice` is `combine(state, fold(slice))`. A one-beat append therefore costs
a ~1,100-beat correction; use larger chunks when streaming.

The reach is the streaming corrector's proven settle horizon (4H + 2K + 4) plus
one K for a run straddling an edge. It is not a proof for every adversarial
input: an artifact pattern alternating normal and compensatory-pair beats could
in principle carry the previous-class dependency further than one run. Tests do
not detect a reach down to about 2H (they fail at reach 6), so the margin is
conservative and unmeasured. With `maxArtifactRun: null` the reach is sized as
for the default cap and a run longer than that is not bounded-state exact.

Grid (owner decision 2026-10-22: gap-anchored, replacing the wall-clock grid).
Epochs are 30 s steps from the first valid accelerometer sample of each
gap-free run. A run starts at the first sample and again at the first sample
after any gap the stager's usable-run split cannot bridge, i.e. more than
`AdvancedSleepStager.maxAccelCarryForwardSec` (60 s) of carry plus the
sample's own second: the next valid sample must come within 61 s of the last or
a new run starts. The constant is reused, not copied. The anchor depends only
on the data; a run's anchor is final when its first sample is folded.

- `EpochRows.epochStartMs` (static, Unix-epoch floor) is removed. New:
  `runAnchorsMs` (anchor of every run seen), `epochStartMsFor(tsMs)` (start of
  the epoch holding a time, null outside any run's coverage), and the
  constructor option `continuingAnchorMs` (the first sample folded joins a run
  that began earlier and is not re-folded). Row starts are no longer multiples
  of 30 s; they are `anchor + k * 30 s`. Epochs are opened for starts inside a
  run's coverage that are not after the newest sample, so a row set is the same
  for any chunking. Checkpoint version 2 (version 1 is refused); a checkpoint
  now carries each run's anchor and generation cursor.
- The stager finds the anchor of the run holding the session start with a
  backward scan over the valid accel timestamps (no rows computed), feeds
  samples from the epoch containing the start minus 165 s, and passes the
  anchor as `continuingAnchorMs` when it precedes that window. So a session
  that starts mid-run is staged on the run's grid, identical to staging from
  the run's first sample.
- Chunk invariance, finality about 4 min behind, checkpoint/resume and staging
  from rows == batch staging all hold exactly (tests below).

Agreement and efficiency, measured:

| Measure | Wall-clock grid | Gap-anchored grid | Required |
| --- | ---: | ---: | ---: |
| Frozen-night agreement (test/onehz/wallclock_agreement_test.dart) | 966/1,067 = 0.9053 | 1,068/1,068 = 1.0 | 0.97 |
| Advanced-stager still-night efficiency (test/onehz/advanced_stager_test.dart) | 0.8081 | 0.8081 | > 0.85 |

The frozen night starts its window at the first sample, so the new grid is the
old grid there: agreement is 1.0 (the previous 1,067 compared epochs became
1,068 because the comparison now steps from the first sample, not from the next
wall-clock boundary). The sleep_honesty SLP-03 change made for the wall-clock
grid (610 s / 14,990 s) is reverted to the original 600 s / 15,000 s, which now
holds again.

The efficiency guard still fails, and the cause is the stager's phase
sensitivity, not the implementation. The fixture is a 2 h active block followed
by a 7 h still night in ONE gap-free run, so the anchor is the first sample,
2 h before the detected session start, and the session starts 19 s into an
epoch of that grid (start 7,369 s, 7,369 mod 30 = 19). The old stager anchored
at the detected session start (phase 0). A control that forces the anchor to
the session start minus p seconds, everything else unchanged, gives:

| p (s) | 0 | 3 | 7 | 11 | 15 | 19 | 23 | 27 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| efficiency | 0.8588 | 0.8262 | 0.7864 | 0.8166 | 0.8166 | 0.8096 | 0.7805 | 0.8214 |

Only phase 0 clears 0.85, and by 0.009; the other seven phases sit 0.03-0.07
below. So the old pass depended on anchoring at the session start. Under the
decided grid the session start is wherever it falls in the run's phase.
Nothing was loosened. Fixing this is the owner's item (c), "fix the stager's
phase sensitivity", which is queued last; the guard needs that fix or a
decision about the fixture, which is a synthetic still night.

Tests changed:

- `test/onehz/incremental/rr_corrector_test.dart`: expect checkpoint v2 and
  reject v1; extend the capped settle-horizon bounds to the implemented delay.
- `test/properties/rr_irregular_laws_test.dart`: run the existing tests of the
  uncapped pipeline layout, stored first difference, and exact 2H class delay
  with `maxArtifactRun: null`. Update invalid checkpoint versions for v2.
  New capped behavior remains covered by `rr_artifact_cap_test.dart`.
- `test/onehz/cardio_row_cache_test.dart`: assert the actual union of cache
  keys. Wall-clock rows shared by adjoining windows now deduplicate at a seam.
- `test/onehz/sleep_honesty_test.dart`: back to the original expectations (600
  s wake, 15,000 s longest sleep run); the wall-clock grid had moved them and
  the gap-anchored grid does not.
- `test/onehz/epoch_rows_test.dart`: B1 rewritten for the gap-anchored grid
  (anchor at the first sample, finality of the anchor, re-anchor after a gap
  of 61 s but not 60 s, gap-only clipping with an unaligned gap, the seeded
  `continuingAnchorMs`); B3 boundaries are checked against the run's grid, plus
  a session that starts mid-run and a hole that re-anchors. B2 is unchanged
  except `whole.length >= 100` (3,000 s of data is exactly 100 epochs from the
  first sample; the wall-clock grid had 101).
- `test/onehz/wallclock_agreement_test.dart`: the agreement loop steps 30 s
  from the first sample (the frozen hypnogram's own grid) instead of from the
  next wall-clock boundary; the boundary test checks the run grid, with run
  anchors recomputed independently from the valid accel timestamps. The 0.97
  guard is unchanged.
- `test/aggregate/rr_sandwich_test.dart`: the oracle is `correctRr(...,
  maxArtifactRun: K)`'s NN paired with the absolute timestamps of its
  `nnSourceIndex` beats (was `nnTimesMs`); the A3 HRV/PRSA references and the
  HRV origin use the same absolute times. Added: series longer than the
  windows (settled middle in play; random cuts, many even chunk sizes around
  W, one-beat chunks, a dense-artifact property), a bounded-size check across
  series length, a longer law case, and long A3 cases. The insertion of a
  definite dropout into the seam fixture stays.
- `test/onehz/rr_artifact_cap_test.dart`: `nnSourceIndex` tests (length,
  order, value, dropped count, over-cap runs, tiny inputs, spline-corrected beat
  is its own source).
- `test/onehz/rr_artifact_cap_test.dart`: add a regression that folds and
  restores through a settled gap into a longer clean tail. It caught a lost
  segment boundary after compaction; the state now persists that boundary and
  whether the active gap is physiological or detected by the soft classifier.

The existing advanced-stager efficiency assertion and the 0.97 agreement
assertion have not been weakened. The former measures 0.8081177843034716
against its required >0.85.

The capped latency is above target, the still-night efficiency guard fails
(see Grid), and the sandwich reach and the adversarial soft-run influence
bounds still need a proof beyond the passing prefix/oracle cases. These are
open limitations, not completed acceptance criteria.

Benchmarks below used the supplied Dart 3.11.4 executable in JIT mode. They
are local measurements, not device timings. The new probe is reproducible via
`dart run tool/combined_bump_probe.dart [bench|rr-bench]`.

| Workload | Accumulated/current | Batch/reference |
| --- | ---: | ---: |
| Real night, EpochRows fold + allRows versus cardioEpochFeatures | 1,937.511 ms | 1,954.044 ms |
| Same night, all 15-minute prefixes, total feature work | 2,446.084 ms | 38,535.495 ms |
| Real night, warmed capped versus uncapped correctRr | 37.871 ms | 37.873 ms |
| bench_phase0 cardioStager, current versus frozen reference | 1,735.504 ms | 1,762.683 ms |
| bench_night_nn seed 1, streaming RR versus repeated batch, 32 passes | 61.78 ms | 547.87 ms |
| Same tool, one whole-day corrector fold + snapshot versus batch | 210.42 ms | 174.75 ms |

The one-shot corrector is about 20% slower than batch on that cold whole-day
measurement, so the blanket no-performance-regression requirement is not
satisfied, although repeated night passes are faster.

The phase-0 benchmark reports exact frozen-reference parity. The night-NN
benchmark reports bit identity for all 32 passes. The real-night EpochRows
checkpoint is 188,121 JSON characters. The 96,712-beat corrector test measured
an 8,114-character maximum checkpoint. The 10,000-junk-beat bound passes.
No RrSandwich benchmark was taken. The benchmark rows above were measured
before the grid change (EpochRows has the same per-fold work, plus a run
lookup).

Final full-suite summary:

```text
+2568 ~7 -1: Some tests failed.
```

That is 2,568 passed, 7 skipped, and 1 failed: the advanced-stager still-night
efficiency guard (0.808 against > 0.85, phase sensitivity, see Grid). The
sandwich tests, the frozen-night agreement guard (1.0 against 0.97), the RR cap,
checkpoint regression, batch oracles, epoch-row parity, cache behavior,
registry closure, and counter tests pass. `dart analyze` reports no issues.
No commits, checkouts, or stashes were run.

Files changed:

- `lib/src/onehz/foundations/rr_correction.dart`
- `lib/src/onehz/foundations/rr_correction_kernel.dart`
- `lib/src/onehz/foundations/rr_correction_stream.dart`
- `lib/src/onehz/foundations/rr_sandwich.dart`
- `lib/src/onehz/sleep/advanced_stager.dart`
- `lib/src/onehz/sleep/epoch_rows.dart`
- `lib/src/onehz/registry/group_registry.dart`
- `CHANGELOG.md`
- `test/aggregate/rr_sandwich_test.dart`
- `test/onehz/cardio_row_cache_test.dart`
- `test/onehz/epoch_rows_test.dart`
- `test/onehz/incremental/rr_corrector_test.dart`
- `test/onehz/rr_artifact_cap_test.dart`
- `test/onehz/sleep_honesty_test.dart` (back to its original content)
- `test/onehz/wallclock_agreement_test.dart`
- `test/properties/rr_irregular_laws_test.dart`
- `tool/combined_bump_probe.dart`
- `docs/COMBINED_BUMP_STATUS.md`
