import 'dart:math' as math;

import '../../aggregate/aggregator.dart';
import '../incremental_core.dart';
import 'hrv_time.dart';

/// Mergeable time-domain HRV summary over cleaned NN intervals.
///
/// When [gapAware] is true, adjacent beats whose elapsed time is more than the
/// latter interval plus 0.5 ms end a difference run.  [originMs] fixes the
/// five-minute bin grid (hrvTime uses the first beat time) and is required
/// before the first beat when [gapAware] is true: a chunk can't place its
/// bins without it.
class HrvTimeAggregator
    extends Aggregator<_HrvTimeState, ({double nnMs, double? timeMs}), HrvTime> {
  HrvTimeAggregator({this.originMs, this.gapAware = true});

  final double? originMs;
  final bool gapAware;

  @override
  _HrvTimeState empty() => _HrvTimeState();

  @override
  _HrvTimeState add(_HrvTimeState state, ({double nnMs, double? timeMs}) beat) {
    _addBeat(state, beat);
    return state;
  }

  @override
  _HrvTimeState combine(_HrvTimeState left, _HrvTimeState right) {
    if (right.nBeats == 0) return left;
    if (left.nBeats == 0) {
      left.copyFrom(right);
      return left;
    }

    final leftLast = left.last!;
    final rightFirst = right.first!;
    final seamContiguous = _contiguous(leftLast, rightFirst);
    final seamDiff = rightFirst.nnMs - leftLast.nnMs;

    left.levels.merge(right.levels);
    left
      ..nBeats += right.nBeats
      ..pairs += right.pairs
      ..over50 += right.over50
      ..diffSum += right.diffSum
      ..diffSquares += right.diffSquares
      ..lagPairs += right.lagPairs
      ..products += right.products
      ..endpoints += right.endpoints;

    if (seamContiguous) {
      _addDiff(left, seamDiff);
      if (left.endedWithDiff) _addLagPair(left, left.lastDiff!, seamDiff);
      if (right.startsWithDiff) _addLagPair(left, seamDiff, right.firstDiff!);
    }

    final leftWasOne = left.nBeats - right.nBeats == 1;
    final rightWasOne = right.nBeats == 1;
    if (leftWasOne) {
      left
        ..startsWithDiff = seamContiguous
        ..firstDiff = seamContiguous ? seamDiff : null;
    }
    if (rightWasOne) {
      left
        ..endedWithDiff = seamContiguous
        ..lastDiff = seamContiguous ? seamDiff : null;
    } else {
      left
        ..endedWithDiff = right.endedWithDiff
        ..lastDiff = right.lastDiff;
    }
    left.last = right.last;

    if (gapAware) _mergeBins(left, right);
    return left;
  }

  @override
  HrvTime finish(_HrvTimeState state) {
    if (state.nBeats < 2) return HrvTime(nBeats: state.nBeats);

    double? acf1;
    if (state.pairs >= 30) {
      final mean = state.diffSum / state.pairs;
      final variance = state.diffSquares - state.diffSum * mean;
      if (variance > 0) {
        acf1 = (state.products - mean * state.endpoints +
                state.lagPairs * mean * mean) /
            variance;
      }
    }
    final jittery = acf1 != null && acf1 < kNnDiffAcf1Floor;

    double? sdann;
    double? sdnnIndex;
    if (gapAware) {
      final usableBins = state.bins.values.where((bin) => bin.count >= 2);
      final binMeans = RunningMoments();
      var binSdSum = 0.0;
      var binCount = 0;
      for (final bin in usableBins) {
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
      nBeats: state.nBeats,
      rmssd: state.pairs > 0 && !jittery
          ? math.sqrt(state.diffSquares / state.pairs)
          : null,
      pnn50: state.pairs > 0 && !jittery
          ? 100.0 * state.over50 / state.pairs
          : null,
      sdnn: state.levels.sampleSd,
      sdann: sdann,
      sdnnIndex: sdnnIndex,
      diffAcf1: acf1,
    );
  }

  void _addBeat(_HrvTimeState state, ({double nnMs, double? timeMs}) beat) {
    if (state.nBeats == 0) {
      state
        ..first = beat
        ..last = beat
        ..nBeats = 1;
      state.levels.add(beat.nnMs);
      if (gapAware) _addToBin(state, beat);
      return;
    }

    final previous = state.last!;
    final contiguous = _contiguous(previous, beat);
    final diff = beat.nnMs - previous.nnMs;
    if (contiguous) {
      _addDiff(state, diff);
      if (state.endedWithDiff) _addLagPair(state, state.lastDiff!, diff);
    }
    if (state.nBeats == 1) {
      state
        ..startsWithDiff = contiguous
        ..firstDiff = contiguous ? diff : null;
    }
    state
      ..endedWithDiff = contiguous
      ..lastDiff = contiguous ? diff : null
      ..last = beat;
    state.nBeats++;
    state.levels.add(beat.nnMs);
    if (gapAware) _addToBin(state, beat);
  }

  bool _contiguous(
      ({double nnMs, double? timeMs}) previous, ({double nnMs, double? timeMs}) current) {
    if (!gapAware) return true;
    final previousTime = previous.timeMs ?? 0.0;
    final currentTime = current.timeMs ?? 0.0;
    return currentTime - previousTime <= current.nnMs + 0.5;
  }

  void _addDiff(_HrvTimeState state, double diff) {
    state.pairs++;
    state
      ..diffSum += diff
      ..diffSquares += diff * diff;
    if (diff.abs() > 50) state.over50++;
  }

  void _addLagPair(_HrvTimeState state, double previous, double current) {
    state.lagPairs++;
    state
      ..products += previous * current
      ..endpoints += previous + current;
  }

  void _addToBin(_HrvTimeState state, ({double nnMs, double? timeMs}) beat) {
    final origin = originMs;
    if (origin == null) throw StateError('gap-aware HRV needs originMs');
    final time = beat.timeMs ?? 0.0;
    final index = ((time - origin) / _fiveMinutesMs).floor();
    (state.bins[index] ??= RunningMoments()).add(beat.nnMs);
  }

  void _mergeBins(_HrvTimeState left, _HrvTimeState right) {
    for (final entry in right.bins.entries) {
      (left.bins[entry.key] ??= RunningMoments()).merge(entry.value);
    }
  }

}

const _fiveMinutesMs = 300000.0;

class _HrvTimeState {
  int nBeats = 0;
  final RunningMoments levels = RunningMoments();
  final Map<int, RunningMoments> bins = {};

  ({double nnMs, double? timeMs})? first;
  ({double nnMs, double? timeMs})? last;
  bool startsWithDiff = false;
  bool endedWithDiff = false;
  double? firstDiff;
  double? lastDiff;

  int pairs = 0;
  int over50 = 0;
  int lagPairs = 0;
  double diffSum = 0;
  double diffSquares = 0;
  double products = 0;
  double endpoints = 0;

  void copyFrom(_HrvTimeState other) {
    nBeats = other.nBeats;
    levels.merge(other.levels);
    for (final entry in other.bins.entries) {
      (bins[entry.key] ??= RunningMoments()).merge(entry.value);
    }
    first = other.first;
    last = other.last;
    startsWithDiff = other.startsWithDiff;
    endedWithDiff = other.endedWithDiff;
    firstDiff = other.firstDiff;
    lastDiff = other.lastDiff;
    pairs = other.pairs;
    over50 = other.over50;
    lagPairs = other.lagPairs;
    diffSum = other.diffSum;
    diffSquares = other.diffSquares;
    products = other.products;
    endpoints = other.endpoints;
  }
}
