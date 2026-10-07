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
/// previous one in the ORIGINAL series (never diff across a dropped beat).
bool? irregularWindowVerdict(
  List<double> bucket,
  List<bool> adjacent, {
  required double sd1sd2Flag,
  required double pnnThresholdMs,
  required double pnnFlagPct,
  required int minWindowBeats,
}) {
  if (bucket.length < minWindowBeats) return null;
  // Mirror the aggregate's `keep[i] && keep[i-1]` guard: never diff across a
  // beat that was dropped as an artifact in the original series, even though
  // it's now a consecutive pair in this compacted bucket.
  final diffs = <double>[
    for (var i = 1; i < bucket.length; i++)
      if (adjacent[i]) bucket[i] - bucket[i - 1]
  ];
  final sdsd = stddev(diffs);
  final sdnn = stddev(bucket);
  if (sdsd == null || sdnn == null) return false;
  final sd1 = sdsd / math.sqrt2;
  final v = 2 * sdnn * sdnn - sd1 * sd1;
  final sd2 = v > 0 ? math.sqrt(v) : 0.0;
  if (sd2 <= 0) return false;
  final ratio = sd1 / sd2;
  final over = diffs.where((d) => d.abs() > pnnThresholdMs).length;
  final pnn = 100.0 * over / diffs.length;
  return ratio >= sd1sd2Flag && pnn >= pnnFlagPct;
}
