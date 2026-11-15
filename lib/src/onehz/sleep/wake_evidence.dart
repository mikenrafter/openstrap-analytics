// Shared, past-only wake evidence. Pure calculation; no alarm policy or state.
// These are engineering gates, not validated sleep-stage classifications.
import 'dart:math' as math;

enum WakeBaselineSource { percentile3h, nightPayload, median90m, absent }

class WakeHrBaseline {
  final double? bpm;
  final WakeBaselineSource source;
  const WakeHrBaseline(this.bpm, this.source);
}

/// The recent three minutes are excluded from both historical intervals.
/// Engineering coverage floors: >=30 unique values, >=30 min primary span,
/// >=15 min fallback span, no internal gap >5 min. This rejects a single
/// low value without requiring current baseline rows for the payload fallback.
WakeHrBaseline wakeHrBaseline(List<List<double>> hr, int nowMs,
    {double? nightMin}) {
  final primary = _hr(hr, nowMs - 180 * 60000, nowMs - 3 * 60000);
  if (_covered(primary, 30 * 60000, 5 * 60000)) {
    return WakeHrBaseline(
        _percentile10(primary), WakeBaselineSource.percentile3h);
  }
  if (nightMin != null && _validHr(nightMin)) {
    return WakeHrBaseline(nightMin, WakeBaselineSource.nightPayload);
  }
  final fallback = _hr(hr, nowMs - 93 * 60000, nowMs - 3 * 60000);
  if (_covered(fallback, 15 * 60000, 5 * 60000)) {
    return WakeHrBaseline(
        _quantile(fallback, .5), WakeBaselineSource.median90m);
  }
  return const WakeHrBaseline(null, WakeBaselineSource.absent);
}

/// Mean of valid HR in [now-3 min, now). Null is insufficient evidence.
double? wakeRecentHr(List<List<double>> hr, int nowMs) {
  final rows = _hr(hr, nowMs - 180000, nowMs);
  return _covered(rows, 90000, 60000) && nowMs - rows.last[0] <= 60000
      ? _mean(rows)
      : null;
}

/// Wake-gate ENMO is abs(norm(accel)-1) in g, matching #630 thresholds.
/// It deliberately retains the below-1g deviation, unlike rectified ENMO.
double? wakeRecentEnmo(List<List<double>> accel, int nowMs) {
  final rows = _motion(accel, nowMs - 180000, nowMs);
  return _covered(rows, 90000, 60000) && nowMs - rows.last[0] <= 60000
      ? _mean(rows)
      : null;
}

/// True only for a rise strictly above threshold. Null means insufficient
/// evidence, which is a veto rather than evidence of a flat trend.
/// Split by elapsed time, never by sample count. Each half needs >=30 unique
/// samples spanning >=half its duration, with no gap >60 s. Window edges
/// must also lie within 60 s of measurements, so stale data cannot approve.
bool? wakeEnmoTrend(List<List<double>> accel, int nowMs,
    {required int windowMinutes, required double threshold}) {
  if (windowMinutes <= 0 || !threshold.isFinite || threshold < 0) return null;
  final start = nowMs - windowMinutes * 60000;
  final mid = (start + nowMs) / 2;
  final rows = _motion(accel, start, nowMs);
  final first = [
    for (final r in rows)
      if (r[0] < mid) r
  ];
  final last = [
    for (final r in rows)
      if (r[0] >= mid) r
  ];
  final span = windowMinutes * 60000 ~/ 4;
  if (!_covered(first, span, 60000) ||
      !_covered(last, span, 60000) ||
      first.first[0] - start > 60000 ||
      mid - first.last[0] > 60000 ||
      last.first[0] - mid > 60000 ||
      nowMs - last.last[0] > 60000) return null;
  return _mean(last) - _mean(first) > threshold;
}

/// Historical movement median for the personalized trend threshold.
/// No independent movement baseline => use the explicitly fixed .02g floor.
double? wakeBaselineEnmo(List<List<double>> accel, int nowMs) {
  final rows = _motion(accel, nowMs - 180 * 60000, nowMs - 3 * 60000);
  return _covered(rows, 30 * 60000, 5 * 60000) ? _quantile(rows, .5) : null;
}

bool _validHr(double value) => value.isFinite && value > 30 && value < 200;
List<List<double>> _hr(List<List<double>> input, int from, int to) => _unique([
      for (final r in input)
        if (r.length >= 2 &&
            r[0].isFinite &&
            r[0] >= from &&
            r[0] < to &&
            _validHr(r[1]))
          [r[0], r[1]]
    ]);
List<List<double>> _motion(List<List<double>> input, int from, int to) {
  final out = <List<double>>[];
  for (final r in input) {
    if (r.length < 4 ||
        !r[0].isFinite ||
        r[0] < from ||
        r[0] >= to ||
        !r[1].isFinite ||
        !r[2].isFinite ||
        !r[3].isFinite) continue;
    final norm = math.sqrt(r[1] * r[1] + r[2] * r[2] + r[3] * r[3]);
    if (!norm.isFinite || norm <= 0) continue;
    out.add([r[0], (norm - 1).abs()]);
  }
  return _unique(out);
}

List<List<double>> _unique(List<List<double>> rows) {
  rows.sort((a, b) => a[0].compareTo(b[0]));
  // Reject every member of a duplicated timestamp, including conflicting rows.
  return [
    for (var i = 0; i < rows.length; i++)
      if ((i == 0 || rows[i - 1][0] != rows[i][0]) &&
          (i == rows.length - 1 || rows[i + 1][0] != rows[i][0]))
        rows[i]
  ];
}

bool _covered(List<List<double>> rows, int spanMs, int maxGapMs) {
  if (rows.length < 30 || rows.last[0] - rows.first[0] < spanMs) return false;
  for (var i = 1; i < rows.length; i++) {
    if (rows[i][0] - rows[i - 1][0] > maxGapMs) return false;
  }
  return true;
}

double _mean(List<List<double>> rows) =>
    rows.fold(0.0, (s, r) => s + r[1]) / rows.length;
double _quantile(List<List<double>> rows, double q) {
  final values = [for (final r in rows) r[1]]..sort();
  final at = (values.length - 1) * q;
  return values[at.floor()] +
      (values[at.ceil()] - values[at.floor()]) * (at - at.floor());
}

// #630 uses the upper order statistic floor(n*.1), as does hr_min_night.
double _percentile10(List<List<double>> rows) {
  final values = [for (final row in rows) row[1]]..sort();
  return values[(values.length * .1).floor()];
}
