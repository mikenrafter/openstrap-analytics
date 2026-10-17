import 'dart:math' as math;

import '../../aggregate/aggregator.dart';
import 'hypnogram.dart';

/// Mergeable AASM-style hypnogram metrics over start-sorted segments.
class HypnogramAggregator
    extends Aggregator<_HypnogramState, StageSegment, HypnogramMetrics> {
  HypnogramAggregator(this.sessionStart, this.sessionEnd);

  final int sessionStart;
  final int sessionEnd;

  @override
  _HypnogramState empty() => _HypnogramState();

  @override
  _HypnogramState add(_HypnogramState state, StageSegment segment) {
    switch (segment.stage) {
      case 'light':
      case 'deep':
      case 'rem':
        final duration = segment.end - segment.start;
        state.tst += duration;
        if (segment.stage == 'light') state.light += duration;
        if (segment.stage == 'deep') state.deep += duration;
        if (segment.stage == 'rem') {
          state.rem += duration;
          if (!state.hasRem) {
            state
              ..hasRem = true
              ..firstRemStart = segment.start;
          }
        }
        if (!state.hasSleep) {
          state
            ..hasSleep = true
            ..onset = segment.start;
        }
        state.sptEnd = segment.end;
        return state;
      case 'wake':
        state.wakes.add((segment.start, segment.end));
    }
    return state;
  }

  @override
  _HypnogramState combine(_HypnogramState left, _HypnogramState right) {
    left
      ..tst += right.tst
      ..deep += right.deep
      ..rem += right.rem
      ..light += right.light
      ..wakes.addAll(right.wakes);
    if (!left.hasSleep && right.hasSleep) {
      left
        ..hasSleep = true
        ..onset = right.onset;
    }
    if (right.hasSleep) left.sptEnd = right.sptEnd;
    if (!left.hasRem && right.hasRem) {
      left
        ..hasRem = true
        ..firstRemStart = right.firstRemStart;
    }
    return left;
  }

  @override
  HypnogramMetrics finish(_HypnogramState state) {
    final tib = math.max(0, sessionEnd - sessionStart);
    final onset = state.hasSleep ? state.onset : sessionEnd;
    final sptEnd = state.hasSleep ? state.sptEnd : sessionEnd;
    var waso = 0;
    var disturbances = 0;
    for (final wake in state.wakes) {
      final w0 = math.max(wake.$1, onset);
      final w1 = math.min(wake.$2, sptEnd);
      if (w1 > w0) {
        waso += w1 - w0;
        disturbances++;
      }
    }
    final efficiency = tib > 0 ? state.tst / tib : 0.0;
    double pct(int value) => state.tst > 0 ? value / state.tst * 100 : 0;
    return HypnogramMetrics(
      tibS: tib,
      tstS: state.tst,
      sptS: math.max(0, sptEnd - onset),
      solS: state.hasSleep ? math.max(0, onset - sessionStart) : null,
      remLatencyS:
          state.hasRem ? (state.firstRemStart - onset).toDouble() : double.nan,
      wasoS: waso,
      efficiency: math.min(1.0, efficiency),
      disturbances: disturbances,
      deepMin: state.deep / 60,
      remMin: state.rem / 60,
      lightMin: state.light / 60,
      deepPct: pct(state.deep),
      remPct: pct(state.rem),
      lightPct: pct(state.light),
    );
  }
}

class _HypnogramState {
  var tst = 0;
  var deep = 0;
  var rem = 0;
  var light = 0;
  var hasSleep = false;
  var onset = 0;
  var sptEnd = 0;
  var hasRem = false;
  var firstRemStart = 0;
  final wakes = <(int, int)>[];
}
