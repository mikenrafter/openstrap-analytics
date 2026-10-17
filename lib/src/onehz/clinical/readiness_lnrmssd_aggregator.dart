import '../../aggregate/aggregator.dart';
import '../../aggregate/primitives.dart';
import '../types.dart';
import 'readiness_lnrmssd.dart';

/// Builds a mergeable lnRMSSD readiness summary over a nightly history column
/// (oldest first, tonight last), matching [readinessLnRmssd] exactly.
///
/// Only the history length and the last [windowDays] + 1 nights matter, so the
/// state is a count and a bounded suffix. [windowDays] must be at least 0.
Aggregator<dynamic, DoubleColumn, Metric<ReadinessLnRmssd>>
    readinessLnRmssdAggregator({
  double? meanNnTodayMs,
  int windowDays = 7,
  int minNights = readinessLnRmssdMinNights,
}) {
  assert(windowDays >= 0);
  return both(
    const Count<DoubleColumn>(),
    LastRows<DoubleColumn>(windowDays + 1,
        batchFromJson: DoubleColumn.fromJson),
  ).map((result) {
    final n = result.$1;
    if (n < minNights) {
      return Metric<ReadinessLnRmssd>.absent(
        tier: Tier.high,
        inputs_used: const ['ln_rmssd_history'],
        note: needBaselineNote(have: n, need: minNights),
      );
    }
    return readinessLnRmssdFromSuffix(
      n,
      result.$2!.values.toList(),
      meanNnTodayMs: meanNnTodayMs,
      windowDays: windowDays,
      minNights: minNights,
    );
  });
}
