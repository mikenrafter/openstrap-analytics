// FOUNDATION — the per-beat pieces of Lipponen–Tarvainen correction that both
// `correctRr` (whole series) and `RrCorrector` (streaming) run.
//
// One copy of the sorted window, the threshold, the leave-one-out median, the
// class decision, the compensatory-pair rule and the spline, so the batch and
// the stream cannot drift apart: the stream's contract is bit-identity with
// `correctRr`, and sharing the arithmetic is what keeps that cheap to hold.
//
// Not exported from `onehz.dart` — internal to foundations/.

import 'dart:math' as math;
import '../util.dart';
import 'rr_correction.dart' show BeatClass;

/// First index whose element is not less than [v] under `compareTo` — the same
/// total order `List<double>.sort()` uses (-0.0 < 0.0, NaN last), so a window
/// kept in this order matches the one a per-beat sort produced.
int lowerBound(List<double> a, double v) {
  var lo = 0;
  var hi = a.length;
  while (lo < hi) {
    final m = (lo + hi) >> 1;
    if (a[m].compareTo(v) < 0) {
      lo = m + 1;
    } else {
      hi = m;
    }
  }
  return lo;
}

/// An ascending multiset of doubles: O(log w) search plus a w-element memmove
/// per add / remove, instead of an O(w log w) sort per beat.
class SortedMultiset {
  /// The values, ascending. Read-only to callers.
  final List<double> a = [];

  void add(double v) => a.insert(lowerBound(a, v), v);

  /// Removes one occurrence of [v], which must be present.
  void remove(double v) => a.removeAt(lowerBound(a, v));

  void resetFrom(Iterable<double> xs) {
    a
      ..clear()
      ..addAll(xs)
      ..sort();
  }
}

/// `alpha × QD` of an ascending window, floored: QD = (Q3 − Q1)/2.
///
/// Floor keeps a gross outlier detectable on (near-)quantized clean data where
/// the QD genuinely collapses to 0 (constant RR). On any series with real
/// beat-to-beat variability α·QD dominates the floor.
double thresholdOfSorted(List<double> sorted, double alpha, double floor) {
  final q1 = percentileSorted(sorted, 25) ?? 0;
  final q3 = percentileSorted(sorted, 75) ?? 0;
  final qd = (q3 - q1) / 2;
  return math.max(alpha * qd, floor);
}

/// `median(sorted minus one occurrence of v)` — [percentile]'s linear
/// interpolation at p = 50 over the sorted list with v's slot skipped, in the
/// same operation order so the result is bit-identical. Null if nothing is left.
double? medianExcluding(List<double> sorted, double v) {
  final len = sorted.length - 1;
  if (len <= 0) return null;
  final skip = lowerBound(sorted, v);
  double at(int j) => j < skip ? sorted[j] : sorted[j + 1];
  if (len == 1) return at(0);
  final rank = (50.0 / 100) * (len - 1);
  final lo = rank.floor();
  final hi = rank.ceil();
  if (lo == hi) return at(lo);
  final frac = rank - lo;
  return at(lo) + (at(hi) - at(lo)) * frac;
}

/// The paper's asymmetric deviation from the local median: below-median
/// deviations count double.
double medianDeviation(double rr, double med) {
  final d = rr - med;
  return d < 0 ? d * 2 : d;
}

/// First-pass class of one beat from its dRR, mRR and the two thresholds.
BeatClass classifyBeat(
    double rr, double dRR, double th1, double med, double mRR, double th2) {
  final hardLong = rr > 2000;
  final hardShort = rr < 300;
  final bigJump = dRR.abs() > th1;
  final bigDev = mRR.abs() > th2;
  if (hardLong || (bigDev && mRR > 0)) {
    // Long interval: likely a MISSED beat (interval ~ multiple of normal).
    return (med > 0 && rr > 1.5 * med) ? BeatClass.missed : BeatClass.longShort;
  } else if (hardShort || (bigDev && mRR < 0)) {
    // Short interval: likely an EXTRA (spurious) beat.
    return (med > 0 && rr < 0.6 * med) ? BeatClass.extra : BeatClass.longShort;
  } else if (bigJump) {
    return BeatClass.ectopic;
  }
  return BeatClass.normal;
}

/// Compensatory-pair rule: beat k was flagged ONLY by its dRR jump, the beat
/// before it was an artifact, the two dRR spikes have opposite sign and k's own
/// value is normal and close to the local median — k is just the recovery from
/// the previous beat's event, so it is demoted to normal.
bool isRecoveryBeat({
  required bool prevIsArtifact,
  required double rr,
  required double dRR,
  required double dRRPrev,
  required double med,
}) {
  if (!prevIsArtifact) return false;
  final oppositeSign = dRR * dRRPrev < 0;
  final valueNormal =
      med > 0 && rr >= 300 && rr <= 2000 && (rr - med).abs() <= 0.2 * med;
  return oppositeSign && valueNormal;
}

/// Catmull-Rom at t = 0.5 between the nearest NORMAL beats either side of an
/// isolated artifact. [left] / [right] hold up to two values each, nearest to
/// the artifact LAST in [left] and FIRST in [right]. Null without an anchor on
/// both sides.
double? splineMid(List<double> left, List<double> right) {
  if (left.isEmpty || right.isEmpty) return null;
  final p1 = left.last;
  final p2 = right.first;
  final p0 = left.length >= 2 ? left.first : p1;
  final p3 = right.length >= 2 ? right.last : p2;
  const t = 0.5;
  final t2 = t * t;
  final t3 = t2 * t;
  return 0.5 *
      ((2 * p1) +
          (-p0 + p2) * t +
          (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
          (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
}
