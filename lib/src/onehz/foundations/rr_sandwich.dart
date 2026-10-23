// FOUNDATION — the RR "sandwich": a mergeable summary over RAW RR that feeds
// capped, corrected NN into a downstream aggregator (docs/AGGREGATOR_DESIGN.md,
// "Proposed next step"). RED-phase stub: signatures only, bodies throw.
//
// Contract (test/aggregate/rr_sandwich_test.dart pins it):
//   * any chunking of a beat series (empty chunks and one-beat chunks
//     included), combined left to right or right to left, finishes to what one
//     pass gives, and that is `correctRr(all beats, maxArtifactRun: K)`: the
//     inner aggregator sees exactly the capped NN and its beat times
//     (`nnTimesMs`, relative to the first beat's start as correctRr reports);
//   * state is bounded (raw head, settled middle folded into `inner`, raw
//     tail), never the series;
//   * persistable when `inner` is.

import 'dart:typed_data';

import '../../aggregate/aggregator.dart';
import '../../aggregate/json_support.dart';
import '../clinical/hrv_time_aggregator.dart' show Beats;
import 'rr_correction.dart';

/// Raw RR beats: interval (ms) and the beat's timestamp (epoch ms), the pair
/// `correctRr(rrMs, rrTsMs: tsMs)` takes. Timestamps non-decreasing.
class RawRr extends Batch<RawRr> {
  RawRr(this.rrMs, this.tsMs) : assert(rrMs.length == tsMs.length);

  factory RawRr.of(List<double> rrMs, List<double> tsMs) =>
      RawRr(Float64List.fromList(rrMs), Float64List.fromList(tsMs));

  factory RawRr.fromJson(Object? json) {
    final map = decodeMap(json);
    final rr = decodeDoubles(field(map, 'rrMs'));
    final ts = decodeDoubles(field(map, 'tsMs'));
    if (rr.length != ts.length) {
      throw const FormatException('RawRr columns differ in length');
    }
    return RawRr(rr, ts);
  }

  final Float64List rrMs;
  final Float64List tsMs;

  @override
  int get length => rrMs.length;

  @override
  RawRr copyRange(int start, int end) => RawRr(
      Float64List(end - start)..setRange(0, end - start, rrMs, start),
      Float64List(end - start)..setRange(0, end - start, tsMs, start));

  @override
  RawRr join(RawRr other) => RawRr(
      Float64List(length + other.length)
        ..setRange(0, length, rrMs)
        ..setRange(length, length + other.length, other.rrMs),
      Float64List(length + other.length)
        ..setRange(0, length, tsMs)
        ..setRange(length, length + other.length, other.tsMs));

  @override
  Object? toJson() =>
      {'rrMs': encodeDoubles(rrMs), 'tsMs': encodeDoubles(tsMs)};
}

/// Opaque [RrSandwich] state: raw head, the inner aggregator's state over the
/// settled middle, raw tail.
class RrSandwichState<S> {
  RrSandwichState();
}

/// Raw RR -> capped, corrected NN -> [inner]. Parameters are `correctRr`'s.
class RrSandwich<S, R> extends Aggregator<RrSandwichState<S>, RawRr, R> {
  const RrSandwich(
    this.inner, {
    this.maxArtifactRun = kMaxArtifactRun,
    this.alpha = 5.2,
    this.windowBeats = 91,
    this.minThresholdMs = 100,
    this.reanchorGapMs = 1000,
  });

  /// Receives the settled NN (`nnMs`) with their beat times (`timeMs`).
  final Aggregator<S, Beats, R> inner;
  final int? maxArtifactRun;
  final double alpha;
  final int windowBeats;
  final double minThresholdMs;
  final double reanchorGapMs;

  @override
  RrSandwichState<S> empty() => throw UnimplementedError('RrSandwich.empty');

  @override
  RrSandwichState<S> addSlice(
          RrSandwichState<S> state, RawRr batch, int start, int end) =>
      throw UnimplementedError('RrSandwich.addSlice');

  @override
  RrSandwichState<S> combine(RrSandwichState<S> left, RrSandwichState<S> right) =>
      throw UnimplementedError('RrSandwich.combine');

  @override
  R finish(RrSandwichState<S> state) =>
      throw UnimplementedError('RrSandwich.finish');

  @override
  bool get persistable => inner.persistable;

  @override
  Object? encodeState(RrSandwichState<S> state) =>
      throw UnimplementedError('RrSandwich.encodeState');

  @override
  RrSandwichState<S> decodeState(Object? json) =>
      throw UnimplementedError('RrSandwich.decodeState');
}

/// Adapts a column aggregator over NN (e.g. `prsaAggregator`) to the [Beats]
/// batch [RrSandwich] feeds: it sees `Beats.nnMs` as a [DoubleColumn].
class NnColumn<S, R> extends Aggregator<S, Beats, R> {
  const NnColumn(this.inner);
  final Aggregator<S, DoubleColumn, R> inner;

  @override
  S empty() => inner.empty();

  @override
  S addSlice(S state, Beats batch, int start, int end) =>
      inner.addSlice(state, DoubleColumn(batch.nnMs), start, end);

  @override
  S combine(S left, S right) => inner.combine(left, right);

  @override
  R finish(S state) => inner.finish(state);

  @override
  bool get persistable => inner.persistable;

  @override
  Object? encodeState(S state) => inner.encodeState(state);

  @override
  S decodeState(Object? json) => inner.decodeState(json);
}
