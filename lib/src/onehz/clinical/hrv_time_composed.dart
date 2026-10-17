import 'dart:math' as math;

import '../../aggregate/aggregator.dart';
import '../../aggregate/primitives.dart';
import '../incremental_core.dart';
import 'hrv_time.dart';

typedef HrvBeat = ({double nnMs, double? timeMs});

/// Builds a mergeable time-domain HRV summary from generic aggregators.
///
/// [originMs] fixes the five-minute bin grid. When [gapAware] is true it is
/// required when the first beat is added.
Aggregator<dynamic, HrvBeat, HrvTime> hrvTimeComposed({
  double? originMs,
  bool gapAware = true,
}) {
  final diffStats = both(
    both(
      const Count<double?>().where((diff) => diff != null),
      DoubleSum<double?>((diff) => diff!).where((diff) => diff != null),
    ),
    both(
      DoubleSum<double?>((diff) => diff! * diff)
          .where((diff) => diff != null),
      const Count<double?>()
          .where((diff) => diff != null && diff.abs() > 50),
    ),
  );

  final lagStats = AdjacentPairs<double?, dynamic, dynamic>(
    both(
      both(
        const Count<(double?, double?)>()
            .where((pair) => pair.$1 != null && pair.$2 != null),
        DoubleSum<(double?, double?)>((pair) => pair.$1! * pair.$2!)
            .where((pair) => pair.$1 != null && pair.$2 != null),
      ),
      DoubleSum<(double?, double?)>((pair) => pair.$1! + pair.$2!)
          .where((pair) => pair.$1 != null && pair.$2 != null),
    ),
  );

  final successive = AdjacentPairs<HrvBeat, dynamic, dynamic>(
    both(diffStats, lagStats).contramap<(HrvBeat, HrvBeat)>(
      (pair) => _successiveDiff(pair.$1, pair.$2, gapAware),
    ),
  );
  final levels = Moments<HrvBeat>((beat) => beat.nnMs);
  final bins = GroupBy<HrvBeat, int, RunningMoments, RunningMoments>(
    (beat) {
      if (gapAware && originMs == null) {
        throw StateError('gap-aware HRV needs originMs');
      }
      final origin = gapAware ? originMs! : 0.0;
      return (((beat.timeMs ?? 0.0) - origin) / 300000.0).floor();
    },
    Moments<HrvBeat>((beat) => beat.nnMs),
  );

  return both(successive, both(levels, bins)).map((summary) {
    final differences = summary.$1;
    final diffStats = differences.$1;
    final lagStats = differences.$2;
    final levels = summary.$2.$1;
    final bins = summary.$2.$2;

    final pairCount = diffStats.$1.$1;
    if (levels.count < 2) return HrvTime(nBeats: levels.count);

    final diffSum = diffStats.$1.$2;
    final diffSquares = diffStats.$2.$1;
    final over50 = diffStats.$2.$2;
    final lagCount = lagStats.$1.$1;
    final products = lagStats.$1.$2;
    final endpoints = lagStats.$2;

    double? acf1;
    if (pairCount >= 30) {
      final mean = diffSum / pairCount;
      final variance = diffSquares - diffSum * mean;
      if (variance > 0) {
        acf1 =
            (products - mean * endpoints + lagCount * mean * mean) / variance;
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
      rmssd: pairCount > 0 && !jittery
          ? math.sqrt(diffSquares / pairCount)
          : null,
      pnn50: pairCount > 0 && !jittery ? 100.0 * over50 / pairCount : null,
      sdnn: levels.sampleSd,
      sdann: sdann,
      sdnnIndex: sdnnIndex,
      diffAcf1: acf1,
    );
  });
}

double? _successiveDiff(HrvBeat previous, HrvBeat current, bool gapAware) {
  if (gapAware &&
      (current.timeMs ?? 0.0) - (previous.timeMs ?? 0.0) >
          current.nnMs + 0.5) {
    return null;
  }
  return current.nnMs - previous.nnMs;
}
