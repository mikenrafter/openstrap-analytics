import 'dart:math' as math;
import 'dart:typed_data';

import '../../aggregate/aggregator.dart';
import '../../aggregate/primitives.dart';
import '../incremental_core.dart';
import 'hrv_time.dart';

const double _fiveMinutesMs = 300000.0;

/// NN intervals and their beat times. A missing time is represented by NaN.
class Beats extends Batch<Beats> {
  Beats(this.nnMs, this.timeMs) : assert(nnMs.length == timeMs.length);

  final Float64List nnMs;
  final Float64List timeMs;

  @override
  int get length => nnMs.length;

  @override
  Beats copyRange(int start, int end) => Beats(
      Float64List(end - start)..setRange(0, end - start, nnMs, start),
      Float64List(end - start)..setRange(0, end - start, timeMs, start));

  @override
  Beats join(Beats other) {
    final nn = Float64List(length + other.length);
    final times = Float64List(length + other.length);
    nn
      ..setRange(0, length, nnMs)
      ..setRange(length, nn.length, other.nnMs);
    times
      ..setRange(0, length, timeMs)
      ..setRange(length, times.length, other.timeMs);
    return Beats(nn, times);
  }
}

/// Builds the composed time-domain HRV summary for a columnar beat batch.
///
/// With [gapAware] false, times and five-minute bins are deliberately ignored.
Aggregator<dynamic, Beats, HrvTime> hrvTimeAggregator({
  double? originMs,
  bool gapAware = true,
}) {
  final diffs = both(
    Lookback<Beats, _DiffState, _DiffSummary>(
        2, _DiffStats(gapAware: gapAware)),
    Lookback<Beats, _LagState, _LagSummary>(
        3, _LagStats(gapAware: gapAware)),
  );
  final levels = Moments<Beats>((batch) => batch.nnMs);

  if (!gapAware) {
    final core = both(diffs, levels);
    return core.map((result) => _finish(
        result.$1.$1, result.$1.$2, result.$2, const <int, RunningMoments>{},
        gapAware: false));
  }

  final bins = GroupBy<Beats, RunningMoments, RunningMoments>(
    (batch, row) {
      final origin = originMs;
      if (origin == null) throw StateError('gap-aware HRV needs originMs');
      return ((_timeAt(batch, row) - origin) / _fiveMinutesMs).floor();
    },
    Moments<Beats>((batch) => batch.nnMs),
  );
  final core = both(diffs, both(levels, bins));
  return core.map((result) => _finish(
      result.$1.$1, result.$1.$2, result.$2.$1, result.$2.$2,
      gapAware: true));
}

double _timeAt(Beats batch, int row) {
  final time = batch.timeMs[row];
  return time.isNaN ? 0.0 : time;
}

bool _contiguous(Beats batch, int previous, int current, bool gapAware) =>
    !gapAware ||
    _timeAt(batch, current) - _timeAt(batch, previous) <=
        batch.nnMs[current] + 0.5;

class _DiffSummary {
  const _DiffSummary(
      this.pairs, this.over50, this.mean, this.m2, this.squares);
  final int pairs;
  final int over50;
  final double mean;
  final double m2;
  final double squares;
}

class _DiffState {
  int pairs = 0;
  int over50 = 0;
  double mean = 0.0;
  double m2 = 0.0;
  double squares = 0.0;

  @pragma('vm:prefer-inline')
  void add(double value) {
    final nextPairs = pairs + 1;
    final delta = value - mean;
    mean += delta / nextPairs;
    m2 += delta * (value - mean);
    pairs = nextPairs;
  }

  @pragma('vm:prefer-inline')
  void merge(_DiffState other) {
    if (other.pairs == 0) return;
    if (pairs == 0) {
      pairs = other.pairs;
      over50 = other.over50;
      mean = other.mean;
      m2 = other.m2;
      squares = other.squares;
      return;
    }
    final leftPairs = pairs;
    final combinedPairs = leftPairs + other.pairs;
    final delta = other.mean - mean;
    m2 += other.m2 + delta * delta * leftPairs * other.pairs / combinedPairs;
    mean += delta * other.pairs / combinedPairs;
    pairs = combinedPairs;
    over50 += other.over50;
    squares += other.squares;
  }
}

/// Processes every two-row window supplied by [Lookback].
class _DiffStats extends Aggregator<_DiffState, Beats, _DiffSummary> {
  const _DiffStats({required this.gapAware});
  final bool gapAware;

  @override
  _DiffState empty() => _DiffState();

  @override
  _DiffState addSlice(_DiffState state, Beats batch, int start, int end) {
    for (var i = start + 1; i < end; i++) {
      if (!_contiguous(batch, i - 1, i, gapAware)) continue;
      final diff = batch.nnMs[i] - batch.nnMs[i - 1];
      state.add(diff);
      state.squares += diff * diff;
      if (diff.abs() > 50) state.over50++;
    }
    return state;
  }

  @override
  _DiffState combine(_DiffState left, _DiffState right) {
    left.merge(right);
    return left;
  }

  @override
  _DiffSummary finish(_DiffState state) =>
      _DiffSummary(
          state.pairs, state.over50, state.mean, state.m2, state.squares);
}

class _LagSummary {
  const _LagSummary(this.pairs, this.meanA, this.meanB, this.coMoment);
  final int pairs;
  final double meanA;
  final double meanB;
  final double coMoment;
}

class _LagState {
  int pairs = 0;
  double meanA = 0.0;
  double meanB = 0.0;
  double coMoment = 0.0;

  @pragma('vm:prefer-inline')
  void add(double a, double b) {
    final nextPairs = pairs + 1;
    final deltaA = a - meanA;
    final deltaB = b - meanB;
    meanA += deltaA / nextPairs;
    meanB += deltaB / nextPairs;
    coMoment += deltaA * (b - meanB);
    pairs = nextPairs;
  }

  @pragma('vm:prefer-inline')
  void merge(_LagState other) {
    if (other.pairs == 0) return;
    if (pairs == 0) {
      pairs = other.pairs;
      meanA = other.meanA;
      meanB = other.meanB;
      coMoment = other.coMoment;
      return;
    }
    final leftPairs = pairs;
    final combinedPairs = leftPairs + other.pairs;
    final deltaA = other.meanA - meanA;
    final deltaB = other.meanB - meanB;
    coMoment += other.coMoment +
        deltaA * deltaB * leftPairs * other.pairs / combinedPairs;
    meanA += deltaA * other.pairs / combinedPairs;
    meanB += deltaB * other.pairs / combinedPairs;
    pairs = combinedPairs;
  }
}

/// Processes every three-row window supplied by [Lookback].
class _LagStats extends Aggregator<_LagState, Beats, _LagSummary> {
  const _LagStats({required this.gapAware});
  final bool gapAware;

  @override
  _LagState empty() => _LagState();

  @override
  _LagState addSlice(_LagState state, Beats batch, int start, int end) {
    for (var i = start + 2; i < end; i++) {
      if (!_contiguous(batch, i - 2, i - 1, gapAware) ||
          !_contiguous(batch, i - 1, i, gapAware)) {
        continue;
      }
      final first = batch.nnMs[i - 1] - batch.nnMs[i - 2];
      final second = batch.nnMs[i] - batch.nnMs[i - 1];
      state.add(first, second);
    }
    return state;
  }

  @override
  _LagState combine(_LagState left, _LagState right) {
    left.merge(right);
    return left;
  }

  @override
  _LagSummary finish(_LagState state) =>
      _LagSummary(state.pairs, state.meanA, state.meanB, state.coMoment);
}

HrvTime _finish(_DiffSummary diffs, _LagSummary lags, RunningMoments levels,
    Map<int, RunningMoments> bins, {required bool gapAware}) {
  if (levels.count < 2) return HrvTime(nBeats: levels.count);

  double? acf1;
  if (diffs.pairs >= 30) {
    if (diffs.m2 > 0) {
      acf1 = (lags.coMoment +
              lags.pairs *
                  (lags.meanA - diffs.mean) *
                  (lags.meanB - diffs.mean)) /
          diffs.m2;
    }
  }
  final jittery = acf1 != null && acf1 < kNnDiffAcf1Floor;

  double? sdann;
  double? sdnnIndex;
  if (gapAware) {
    final binMeans = RunningMoments();
    var binSdSum = 0.0;
    var binCount = 0;
    for (final bin in bins.values) {
      if (bin.count < 2) continue;
      binMeans.add(bin.mean!);
      binSdSum += bin.sampleSd!;
      binCount++;
    }
    if (binCount >= 2) {
      sdann = binMeans.sampleSd;
      sdnnIndex = binSdSum / binCount;
    }
  }

  return HrvTime(
    nBeats: levels.count,
    rmssd: diffs.pairs > 0 && !jittery
        ? math.sqrt(diffs.squares / diffs.pairs)
        : null,
    pnn50: diffs.pairs > 0 && !jittery
        ? 100.0 * diffs.over50 / diffs.pairs
        : null,
    sdnn: levels.sampleSd,
    sdann: sdann,
    sdnnIndex: sdnnIndex,
    diffAcf1: acf1,
  );
}
