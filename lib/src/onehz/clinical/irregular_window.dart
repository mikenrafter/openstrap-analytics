// Internal rule for SD1/SD2, pNNx thresholds and sustained-window voting.
// Task Force 1996 supports successive-difference HRV components, not this
// classifier or its SD1/SD2 thresholds; see hrv_time.dart.
// Internal irregular-rhythm screen, ESTIMATE with low confidence. Batch and
// stream share irregularWindowVerdict(); centered moments reorder floating-point
// sums, while exact counters preserve window evidence. Shared adjacency excludes
// timestamp-gap pairs. Diagnostics account for evidence without adding a
// clinical estimator.
// CLINICAL — the per-window pieces of the irregular-rhythm screen, shared by
// `irregularBeatScreen` (whole series) and `IrregularScreenState` (streaming)
// so the two cannot disagree about what a flagged window is.
//
// Not exported from `onehz.dart`.

import 'dart:math' as math;
import '../util.dart';

/// Fail-CLOSED check on the sustained-window config: a misconfigured caller
/// must never manufacture a medical false positive.
bool irregularWindowConfigOk(
    {required double windowMinutes,
    required int minWindowBeats,
    required double sustainedFraction}) {
  return windowMinutes.isFinite &&
      windowMinutes > 0 &&
      minWindowBeats >= 2 &&
      sustainedFraction.isFinite &&
      sustainedFraction >= 0 &&
      sustainedFraction <= 1;
}

/// One closed window of clean beats: null when it is too thin to count as a
/// window, otherwise whether SD1/SD2 and pNNx both clear their flag lines.
/// [adjacent] is aligned to [bucket]: whether each beat directly followed the
/// previous one in the ORIGINAL series, with no time hole between them (never
/// diff across a dropped beat or a dropout).
bool? irregularWindowVerdict(
  List<double> bucket,
  List<bool> adjacent, {
  required double sd1sd2Flag,
  required double pnnThresholdMs,
  required double pnnFlagPct,
  required int minWindowBeats,
}) {
  // Mirror the aggregate's `keep[i] && keep[i-1]` guard: never diff across a
  // beat that was dropped as an artifact in the original series, even though
  // it's now a consecutive pair in this compacted bucket.
  final diffs = <double>[
    for (var i = 1; i < bucket.length; i++)
      if (adjacent[i]) bucket[i] - bucket[i - 1]
  ];
  // Valid on contiguous pairs, not beats (same reason as the aggregate).
  if (diffs.length < minWindowBeats - 1) return null;
  final features = irregularBeatFeatures(bucket, diffs,
      pnnThresholdMs: pnnThresholdMs);
  final ratio = features.ratio, pnn = features.pnnPct;
  return ratio != null && pnn != null &&
      ratio >= sd1sd2Flag && pnn >= pnnFlagPct;
}

/// Shared original-beat descriptors for the daily screen's windows and Pulse's
/// raw/residual windows. Callers own the feature and adjacency masks, including
/// any predecessor outside the window. No filtering or re-cleaning occurs here.
/// CLAIM(pulse-feature-owner): both Pulse passes and irregularWindowVerdict use
/// this one formula [pulse_contract_test; irregular_rhythm_test].
({double? sd1, double? sd2, double? ratio, double? pnnPct})
    irregularBeatFeatures(List<double> values, List<double> diffs,
        {required double pnnThresholdMs}) {
  final sdsd = stddev(diffs), sdnn = stddev(values);
  final sd1 = sdsd == null ? null : sdsd / math.sqrt2;
  final variance = sd1 == null || sdnn == null ? null : 2 * sdnn * sdnn - sd1 * sd1;
  final sd2 = variance != null && variance > 0 ? math.sqrt(variance) : null;
  final ratio = sd1 != null && sd2 != null ? sd1 / sd2 : null;
  final pnn = diffs.isEmpty ? null :
      100.0 * diffs.where((d) => d.abs() > pnnThresholdMs).length / diffs.length;
  return (sd1: sd1, sd2: sd2, ratio: ratio, pnnPct: pnn);
}
