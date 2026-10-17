# Aggregators: mergeable summaries without a rigid monoid

Goal: make it cheap to turn an analytics calculation into something that can be
computed in chunks (checkpoint/resume, segment recompute, parallel work) and
merged, with one generic law check instead of hand-written chunking tests.

## Why not a plain monoid

A textbook monoid on summary values asks for three things that cost speed or
honesty in this package:

1. Immutable values. Folding 86,400 samples a day through an immutable
   `combine(summary, singleton(x))` allocated per sample: ~180,000 µs against a
   141 µs hand loop (edge.research/experiments/dart-monoid/REPORT.md).
2. Structural equality of states. Two states can differ (float rounding order,
   a dropped field `finish` never reads) and still give the same metric.
3. One global operation. Several calculations depend on context known before
   any data arrives: session bounds, a bin origin. A fixed, context-free
   identity can't express that.

## The relaxed contract

An `Aggregator<S, A, R>` is a dictionary of four operations (the Beam
`CombineFn` / Algebird shape):

| op | role |
|---|---|
| `S empty()` | fresh identity state |
| `S add(S s, A x)` | per-element step; MAY mutate `s` and return it (the hot loop) |
| `S combine(S left, S right)` | merge two ADJACENT chunks, `left` before `right`; MAY mutate and return `left`; both arguments are consumed |
| `R finish(S s)` | state → result; must not mutate `s` |

Relaxations against a textbook monoid, each one deliberate:

- **Mutation and consumption.** `add` and `combine` may reuse their inputs.
  The laws are stated on fresh folds, so the harness never reuses a consumed
  state.
- **Equality after `finish`.** Laws compare `finish` outputs with a
  caller-supplied equality (exact by default, tolerance for floats). State
  layout is free.
- **Order matters; commutativity is not required.** `combine` only joins a chunk
  with the chunk that follows it. That is what lets a state carry bounded edge
  context (last beat, pending run) across a seam.
- **Context-indexed instances.** An aggregator may be constructed from context
  (e.g. `HypnogramAggregator(sessionStart, sessionEnd)`); the laws hold per
  instance.

The laws (checked by `checkLaws`, all through `finish` + equality):

1. left identity: `combine(empty, fold xs) ≈ fold xs`
2. right identity: `combine(fold xs, empty) ≈ fold xs`
3. split: for every split point k, `combine(fold xs[..k], fold xs[k..]) ≈ fold xs`
4. associativity on three adjacent chunks
5. singleton consistency: left-combining the singleton folds `fold([x])` of
   every element ≈ `fold xs` (the `add` path agrees with the `combine` path)

Law 3 is the property the app needs: any chunking gives the same metric.

## Building blocks

Aggregators compose, so a calculation is assembled from parts that are already
lawful and inherits the laws:

- primitives: `Count`, `IntSum`, `DoubleSum` (Neumaier-compensated), `Min`,
  `Max`, `First`, `Last`, `Moments` (wraps `RunningMoments`), `Histogram` (wraps
  `IntHistogram`)
- combinators: `both(a, b)` (run two over the same input; mutable pair state,
  no per-element allocation), `.map(f)` on the result, `.contramap(f)` on the
  input, `.where(p)` to filter input
- seams: `AdjacentPairs(inner)` feeds every consecutive pair `(prev, cur)` to
  `inner`, including the one pair that straddles a chunk boundary (formed in
  `combine` from `left.last` and `right.first`). Nest it for lag-2 context
  (pairs of pairs). This is the general tool for "needs the neighbour".

## What still needs raw data

Unchanged from the 2026-10-10 Q&A: exact medians/quantiles over floats,
pairwise statistics (sample entropy), Viterbi backtrack, and anything whose
context is unbounded (current RR artifact correction). Those stay batch, or
get a bounded variant behind a kAlgoVersion bump.

## Pilots (this branch)

1. Core + primitives + combinators + law harness, with self-tests proving the
   harness catches broken aggregators.
2. `HypnogramAggregator`: `hypnogramMetrics` rewired in place to fold through
   it; exact integer parity with the old implementation on arbitrary input.
3. `HrvTimeAggregator`: RMSSD, pNN50, SDNN, SDANN, SDNN index and lag-1 diff
   ACF from beats, gap-aware, any chunking; additive (hrvTime unchanged), parity
   within float tolerance.
4. Benchmark: hand loop vs composed aggregator over 86,400 samples.
