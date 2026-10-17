import 'dart:typed_data';

import '../../aggregate/aggregator.dart';
import '../../aggregate/json_support.dart';
import '../../aggregate/primitives.dart';
import '../types.dart';
import 'circadian_np.dart';
import 'circadian_window.dart';

/// Epoch-binned activity (or HR) values.
///
/// [firstIndex] is the absolute index of row zero, so the epoch of day of a
/// row survives slicing and joining.
class EpochSeries extends Batch<EpochSeries> {
  EpochSeries(this.x, {this.firstIndex = 0});

  factory EpochSeries.fromJson(Object? json) {
    final map = decodeMap(json);
    return EpochSeries(decodeDoubles(field(map, 'x')),
        firstIndex: decodeCount(field(map, 'firstIndex')));
  }

  final Float64List x;
  final int firstIndex;

  @override
  Object? toJson() => {'x': encodeDoubles(x), 'firstIndex': firstIndex};

  @override
  int get length => x.length;

  @override
  EpochSeries copyRange(int start, int end) => EpochSeries(
      Float64List(end - start)..setRange(0, end - start, x, start),
      firstIndex: firstIndex + start);

  @override
  EpochSeries join(EpochSeries other) {
    assert(other.firstIndex == firstIndex + length);
    return EpochSeries(
        Float64List(length + other.length)
          ..setRange(0, length, x)
          ..setRange(length, length + other.length, other.x),
        firstIndex: firstIndex);
  }
}

/// Sum of squared successive differences. Run under `Lookback(2)`, which
/// feeds the pair across each chunk seam.
class _SquaredDiffs extends Aggregator<double, EpochSeries, double> {
  const _SquaredDiffs();
  @override
  double empty() => 0.0;
  @override
  double addSlice(double state, EpochSeries batch, int start, int end) {
    for (var i = start + 1; i < end; i++) {
      final d = batch.x[i] - batch.x[i - 1];
      state += d * d;
    }
    return state;
  }

  @override
  double combine(double left, double right) => left + right;
  @override
  double finish(double state) => state;
  @override
  bool get persistable => true;
  @override
  Object? encodeState(double state) => encodeDouble(state);
  @override
  double decodeState(Object? json) => decodeDouble(json);
}

/// Mergeable nonparametric circadian metrics, matching
/// [circadianNonparametric].
Aggregator<dynamic, EpochSeries, Metric<CircadianNp>> circadianNpAggregator(
  int epochsPerDay, {
  int? m10Epochs,
  int? l5Epochs,
}) {
  const inputs = ['activity_or_hr_epochs'];
  const tooShort = Metric<CircadianNp>.absent(
    tier: Tier.high,
    inputs_used: inputs,
    note: 'need ≥1 full day of epochs for circadian metrics',
  );
  if (epochsPerDay <= 0) {
    return Count<EpochSeries>().map((_) => tooShort);
  }
  final p = epochsPerDay;
  final mEp = m10Epochs ?? (p * 10 ~/ 24);
  final lEp = l5Epochs ?? (p * 5 ~/ 24);
  Float64List column(EpochSeries b) => b.x;
  final core = both(
    both(Count<EpochSeries>(), Moments<EpochSeries>(column)),
    both(
      GroupBy(
        (EpochSeries batch, int row) => (batch.firstIndex + row) % p,
        both(Count<EpochSeries>(), Sum<EpochSeries>(column)),
      ),
      Lookback<EpochSeries, double, double>(2, const _SquaredDiffs(),
          batchFromJson: EpochSeries.fromJson),
    ),
  );
  return core.map((result) {
    final ((n, moments), (byEpoch, ssDiff)) = result;
    if (n < p) return tooShort;
    final grand = moments.mean!;
    final sd = moments.populationSd!;
    final ssTot = sd * sd * n;
    if (ssTot == 0) {
      return const Metric<CircadianNp>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'no variance in activity series',
      );
    }
    final profile = List<double>.filled(p, 0);
    var ssHour = 0.0;
    for (var h = 0; h < p; h++) {
      final (count, sum) = byEpoch[h]!;
      profile[h] = sum / count;
      final d = profile[h] - grand;
      ssHour += d * d;
    }
    final is_ = (n * ssHour) / (p * ssTot);
    final iv = (n * ssDiff) / ((n - 1) * ssTot);
    final m10 = bestCircularWindow(profile, mEp, maximize: true);
    final l5 = bestCircularWindow(profile, lEp, maximize: false);
    final ra = (m10.value + l5.value) > 0
        ? (m10.value - l5.value) / (m10.value + l5.value)
        : 0.0;
    return Metric<CircadianNp>(
      value: CircadianNp(
        interdailyStability: is_.clamp(0, 1),
        intradailyVariability: iv < 0 ? 0 : iv,
        m10: m10.value,
        l5: l5.value,
        relativeAmplitude: ra.clamp(0, 1),
        m10StartEpoch: m10.start,
        l5StartEpoch: l5.start,
      ),
      confidence: (n / p / 7.0).clamp(0.3, 0.95),
      tier: Tier.high,
      inputs_used: inputs,
      note: 'IS/IV/RA/L5/M10 (van Someren 1999); circadian phase anchored on '
          'the L5 nocturnal trough, not the daytime peak',
    );
  });
}
