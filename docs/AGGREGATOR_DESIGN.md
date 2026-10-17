# Aggregators: mergeable summaries without a rigid monoid

Goal: make it cheap to turn an analytics calculation into something that can
be computed in chunks (checkpoint/resume, segment recompute, parallel work)
and merged, with one generic law check instead of hand-written chunking tests.

## Why not a plain monoid

A textbook monoid on summary values asks for three things that cost speed or
honesty here:

1. Immutable values combined one element at a time. Folding 86,400 samples a
   day through `combine(summary, singleton(x))` allocated per sample: about
   180,000 µs against a 141 µs hand loop
   (edge.research/experiments/dart-monoid/REPORT.md).
2. Structural equality of states. Two states can differ (float rounding
   order, a field `finish` never reads) and still give the same metric.
3. One context-free operation. Several calculations depend on context known
   before any data arrives: session bounds, a bin origin, heart-rate anchors.

## The contract

An `Aggregator<S, B, R>` is a dictionary of four operations over slices of a
column batch `B`:

| op | role |
|---|---|
| `S empty()` | fresh identity state |
| `S addSlice(S s, B batch, int start, int end)` | fold rows `[start, end)`; may mutate `s` and return it |
| `S combine(S left, S right)` | merge two adjacent chunks, `left` first; may mutate and return `left`; consumes both |
| `R finish(S s)` | state to result; must not mutate `s` |

`Batch<B>` is a run of rows stored column-wise (`length`, `copyRange`,
`join`). Missing doubles are NaN, so filtering happens inside tight loops
instead of through per-row closures. `ListBatch<A>` wraps a plain list for
calculations over objects (hypnogram segments); `DoubleColumn` wraps one
`Float64List`. A module defines its own batch when it needs several columns
(`Beats`, `Epochs`, `TimedValues`).

What this relaxes, each one on purpose:

- **Slices, not elements.** The unit of `add` is a slice. Generic dispatch
  then costs once per slice and the per-row work is a plain loop.
- **Mutation and consumption.** `addSlice` and `combine` reuse their inputs.
  The laws are stated on fresh folds, so nothing reuses a consumed state.
- **Equality after `finish`.** Laws compare finished results with a
  caller-supplied equality (exact for integer outputs, a tolerance for
  floats). State layout is free.
- **Order matters.** `combine` joins a chunk with the one that follows it, so
  a state can carry bounded edge context across a seam. No commutativity.
- **Context-indexed instances.** An aggregator may be built from context
  (`HypnogramAggregator(sessionStart, sessionEnd)`,
  `hrvTimeAggregator(originMs: …)`, `banisterTrimpAggregator(restingHr: …)`).
  The laws hold per instance.

## Laws

`checkLaws(agg, cases, equals: …)` (lib/src/aggregate/laws.dart) checks, all
through `finish` and `equals`:

1. left identity: `combine(empty, fold xs) ≈ fold xs`
2. right identity: `combine(fold xs, empty) ≈ fold xs`
3. split: for split points k (every k for short cases),
   `combine(fold [0,k), fold [k,n)) ≈ fold xs`
4. associativity on three adjacent slices
5. singletons: left-combining one-row folds ≈ `fold xs`
6. slicing: one state fed random consecutive sub-slices ≈ `fold xs` (the
   `addSlice`-after-data path, separate from `combine`)

Law 3 is what the app needs: any chunking gives the same metric. The harness
tests itself against deliberately broken aggregators
(test/aggregate/laws_harness_test.dart), so a lawful verdict means something.
In tests, `expectLawful(agg, cases, equals: …)` is the one-liner.

## Building blocks

All lawful, so anything assembled from them is lawful too:

- counts and sums: `Count`, `CountFinite`, `CountWhere`, `Sum`
  (Neumaier-compensated), `SumSq`, `SumOf(col, f)` (sum of `f(x)`, NaN skips)
- extremes and edges: `Min`, `Max`, `First`, `Last`
- moments: `Moments` (wraps `RunningMoments`)
- composition: `both(a, b)` (mutable pair state, no per-row allocation),
  `.map(f)` on the result
- grouping: `GroupBy(key, inner)` (consecutive equal keys reach `inner` as one
  slice; per-key order kept)
- neighbour context: `Lookback(k, inner)`. `inner` processes every length-k
  window inside each slice it is given. `Lookback` keeps the first and last
  k−1 rows and hands `inner` the seam rows on `combine` and on
  `addSlice`-after-data, so each window is counted exactly once under any
  chunking. `Lookback(2)` gives successive differences, `Lookback(3)` lag
  pairs, and `Lookback(epochsPerDay + 1)` the SRI day-to-day comparison.

Where no block fits, a small hand-written inner (an `Aggregator` with a tight
loop) is fine. It is still checked by the same laws.

## Converting a module: recipe

1. Pick the batch: an existing one, or a small `Batch` subclass with one typed
   column per input.
2. List the sufficient statistics `finish` needs. If they're sums, counts,
   extremes or moments, use the blocks; if they need neighbours, wrap them in
   `Lookback(k)`; if they're per bin or per day, wrap them in `GroupBy`.
3. Write `finish` (`.map`) from the old function's formulas, including its
   absent cases and notes.
4. Tests: parity with the old function under random slicings and chunkings
   (`runChunked`, `runSliced` in test/support/aggregator_laws.dart), plus one
   `expectLawful`.
5. Integer outputs: rewire the old function in place to run the aggregator,
   and keep a frozen copy of the old body in the test. Float outputs: keep
   the aggregator additive beside the old function, so no published value
   moves and no kAlgoVersion bump is needed.

## Results so far

| module | how | parity | shape |
|---|---|---|---|
| hypnogram metrics | rewired in place | exact | hand inner over `ListBatch<StageSegment>`; wake spans kept as a list (clipped at finish) |
| HRV time domain | additive | 1e-9 | `Lookback(2)`, `Lookback(3)`, `Moments`, `GroupBy` over `Beats` |
| Phillips SRI | rewired in place | exact | `Lookback(epochsPerDay + 1)` + `GroupBy` per day pair over `Epochs` |
| Banister TRIMP | additive | 1e-12 | `both(Count, SumOf)` |
| cosinor | additive | 1e-9 (R² 1e-7) | one inner computing cos/sin once per row, ten sums |

Speed, AOT, Dart 3.11.4 on this box (`tool/bench_aggregate.dart`):

| 30,000 beats, HRV time domain | µs |
|---|---:|
| `hrvTime()` (current batch code) | 4,956 |
| hand loop, same statistics | 596 |
| composed, one slice | 1,030 |
| composed, 24 slices + combine | 1,048 |
| composed, one-row slices | 10,106 |
| per-element composed (earlier API) | ~24,800 |

The composed version is 1.7× a hand loop and 5× faster than the current batch
function. Chunking costs nothing extra.

## Known limits

- `Lookback` copies k−1 rows per seam. With large k and tiny slices this
  dominates: SRI over 7 days at 1,440 epochs/day takes 0.2 ms as one slice,
  0.5 ms in hourly slices, 17.7 ms in one-epoch slices. Feed slices of at
  least k rows, or give `Lookback` an appendable edge buffer if a caller
  can't.
- Still batch-only: exact medians and quantiles over floats, pairwise
  statistics (sample entropy), Viterbi backtrack, and anything whose context
  is unbounded (current RR artifact correction). These need a bounded variant
  behind a kAlgoVersion bump, or stay batch.
- Float results are equal within a tolerance, not bit-identical, across
  chunkings. That is why float modules stay additive.
