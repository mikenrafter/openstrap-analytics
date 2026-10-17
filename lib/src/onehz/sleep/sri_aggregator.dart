import 'dart:typed_data';

import '../../aggregate/aggregator.dart';
import '../../aggregate/primitives.dart';
import '../types.dart';
import 'sri.dart';

/// Clock-aligned sleep/wake epochs, optionally accompanied by a validity mask.
///
/// [firstIndex] is the absolute index of row zero. It lets [Lookback] preserve
/// the day a comparison belongs to when it joins copied chunks at a seam.
class Epochs extends Batch<Epochs> {
  Epochs(this.asleep, {this.valid, this.firstIndex = 0});

  final Uint8List asleep;
  final Uint8List? valid;
  final int firstIndex;

  @override
  int get length => asleep.length;

  @override
  Epochs copyRange(int start, int end) => Epochs(
        Uint8List.fromList(asleep.sublist(start, end)),
        valid: valid == null ? null : Uint8List.fromList(valid!.sublist(start, end)),
        firstIndex: firstIndex + start,
      );

  @override
  Epochs join(Epochs other) {
    assert(other.firstIndex == firstIndex + length);
    final joinedAsleep = Uint8List(length + other.length)
      ..setRange(0, length, asleep)
      ..setRange(length, length + other.length, other.asleep);
    Uint8List? joinedValid;
    if (valid != null || other.valid != null) {
      joinedValid = Uint8List(length + other.length);
      for (var i = 0; i < length; i++) {
        joinedValid[i] = valid == null ? 1 : valid![i];
      }
      for (var i = 0; i < other.length; i++) {
        joinedValid[length + i] = other.valid == null ? 1 : other.valid![i];
      }
    }
    return Epochs(joinedAsleep, valid: joinedValid, firstIndex: firstIndex);
  }
}

class _PairCounts {
  var agreement = 0;
  var cases = 0;
}

class _PairCountsAggregator
    extends Aggregator<_PairCounts, Epochs, _PairCounts> {
  const _PairCountsAggregator(this.epochsPerDay);

  final int epochsPerDay;

  @override
  _PairCounts empty() => _PairCounts();

  @override
  _PairCounts addSlice(_PairCounts state, Epochs batch, int start, int end) {
    final valid = batch.valid;
    for (var i = start; i < end; i++) {
      final previous = i - epochsPerDay;
      if (valid == null || (valid[previous] != 0 && valid[i] != 0)) {
        state.cases++;
        if (batch.asleep[previous] == batch.asleep[i]) state.agreement++;
      }
    }
    return state;
  }

  @override
  _PairCounts combine(_PairCounts left, _PairCounts right) {
    left
      ..agreement += right.agreement
      ..cases += right.cases;
    return left;
  }

  @override
  _PairCounts finish(_PairCounts state) => state;
}

/// Applies [GroupBy] only to windows that [Lookback] says are complete.
///
/// A Lookback inner sees a length-k window ending at `start + k - 1` through
/// `end - 1`. GroupBy would otherwise reset that origin for each day run, so
/// this small adapter advances to the first complete window before grouping.
class _GroupedPairWindows
    extends Aggregator<Map<int, _PairCounts>, Epochs, Map<int, _PairCounts>> {
  _GroupedPairWindows(this.epochsPerDay)
      : _groups = GroupBy<Epochs, _PairCounts, _PairCounts>(
          (batch, row) => (batch.firstIndex + row) ~/ epochsPerDay,
          _PairCountsAggregator(epochsPerDay),
        );

  final int epochsPerDay;
  final GroupBy<Epochs, _PairCounts, _PairCounts> _groups;

  @override
  Map<int, _PairCounts> empty() => _groups.empty();

  @override
  Map<int, _PairCounts> addSlice(
      Map<int, _PairCounts> state, Epochs batch, int start, int end) {
    final firstWindowEnd = start + epochsPerDay;
    if (firstWindowEnd < end) {
      return _groups.addSlice(state, batch, firstWindowEnd, end);
    }
    return state;
  }

  @override
  Map<int, _PairCounts> combine(
          Map<int, _PairCounts> left, Map<int, _PairCounts> right) =>
      _groups.combine(left, right);

  @override
  Map<int, _PairCounts> finish(Map<int, _PairCounts> state) =>
      _groups.finish(state);
}

/// Mergeable Phillips SRI over [Epochs].
///
/// The Lookback window has one row from each of two adjacent clock days. Its
/// last row determines the later-day key used by GroupBy.
Aggregator<dynamic, Epochs, Metric<SriResult>> sriAggregator(
  int epochsPerDay, {
  int? minPairCases,
}) {
  final pairs = Lookback<Epochs, Map<int, _PairCounts>, Map<int, _PairCounts>>(
    epochsPerDay + 1,
    _GroupedPairWindows(epochsPerDay),
  );
  return both(Count<Epochs>(), pairs).map((result) {
    const inputs = ['sleep_wake_epochs'];
    final n = result.$1;
    if (n < 2 * epochsPerDay) {
      return const Metric<SriResult>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'need ≥2 full days of clock-aligned sleep/wake epochs for SRI',
      );
    }
    final days = n ~/ epochsPerDay;
    if (days < 2) {
      return const Metric<SriResult>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'need ≥2 full days for SRI',
      );
    }

    final pairFloor = minPairCases ?? (epochsPerDay ~/ 2);
    var agreement = 0;
    var cases = 0;
    final sriPairs = <SriPair>[];
    for (var day = 1; day < days; day++) {
      final pair = result.$2[day];
      if (pair == null) continue;
      agreement += pair.agreement;
      cases += pair.cases;
      if (pair.cases > 0 && pair.cases >= pairFloor) {
        sriPairs.add(SriPair(day, pair.agreement, pair.cases));
      }
    }
    if (cases == 0) {
      return const Metric<SriResult>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'no valid epoch pairs for SRI',
      );
    }

    final sri = 200.0 * agreement / cases - 100.0;
    final confidence = ((days - 1) / 7.0).clamp(0.3, 0.95);
    return Metric<SriResult>(
      value: SriResult(sri, days, cases, sriPairs),
      confidence: confidence,
      tier: Tier.high,
      inputs_used: inputs,
      note: 'epoch-by-epoch 24-h concordance (Phillips 2017), '
          'SRI=200·agreement/cases−100; NOT SD-of-midsleep',
    );
  });
}
