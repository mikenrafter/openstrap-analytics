// RESEARCH PROTOTYPES — incremental HRV scalars and curves.
//
// Common shape: `fold(settled input)` mutates the carried state; `evaluate`
// / `curve` answers for "settled + provisional tail" WITHOUT mutating it (the
// tail is re-evaluated on a copy). The settled input is what RrCorrector.fold
// returns; the provisional tail is RrSnapshot.tailNn/tailNnTimes.
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

// ===========================================================================
// 1. hrvTime scalars: RMSSD, pNN50, SDNN, SDANN, SDNN-index, diffAcf1
// ===========================================================================
//
// RMSSD/pNN50/pairs: sums of d*d, count of |d|>50 taken in beat order are the
// SAME float sequence as the batch loop, so they are BIT-identical.
// SDNN: Welford instead of the batch's two-pass (mean, then sum (x-m)^2) —
//   agrees to ~1e-13 relative, NOT bit-identical (a two-pass over the whole
//   series cannot be folded).
// ACF1: algebraic form from (n, S1, S2, P, E, L); ~1e-14 absolute. The jitter
//   gate (acf1 < -0.35) can only differ when |acf1 + 0.35| < ~1e-12.
// SDANN/SDNN-index: the 5-min segments close for good once a later beat
//   arrives; their (mean, sd) are computed ONCE with the batch's own
//   mean()/stddev() => bit-identical, and the final stddev(means)/mean(sds)
//   run over <= 288 numbers with the batch's own functions.
class HrvTimeAcc {
  int n = 0;
  double prevNn = 0, prevT = 0, t0 = 0;
  double wMean = 0, wM2 = 0;
  int pairs = 0, over50 = 0, lagPairs = 0;
  double ssd = 0, s1 = 0, s2 = 0, prod = 0, endp = 0;
  double? lastDiff;
  int segIdx = 0;
  List<double> cur = [];
  List<double> segMeans = [], segSds = [];

  HrvTimeAcc();

  HrvTimeAcc copy() {
    final c = HrvTimeAcc()
      ..n = n
      ..prevNn = prevNn
      ..prevT = prevT
      ..t0 = t0
      ..wMean = wMean
      ..wM2 = wM2
      ..pairs = pairs
      ..over50 = over50
      ..lagPairs = lagPairs
      ..ssd = ssd
      ..s1 = s1
      ..s2 = s2
      ..prod = prod
      ..endp = endp
      ..lastDiff = lastDiff
      ..segIdx = segIdx
      ..cur = List.of(cur)
      ..segMeans = List.of(segMeans)
      ..segSds = List.of(segSds);
    return c;
  }

  void add(double v, double t) {
    if (n == 0) {
      t0 = t;
    } else if (t - prevT > v + .5) {
      lastDiff = null; // seam: ends a diff run
    } else {
      final d = v - prevNn;
      pairs++;
      ssd += d * d;
      s1 += d;
      s2 += d * d;
      if (d.abs() > 50) over50++;
      if (lastDiff != null) {
        lagPairs++;
        prod += lastDiff! * d;
        endp += lastDiff! + d;
      }
      lastDiff = d;
    }
    n++;
    final dl = v - wMean;
    wMean += dl / n;
    wM2 += dl * (v - wMean);
    final idx = ((t - t0) / 300000.0).floor();
    if (idx != segIdx) {
      if (cur.length >= 2) {
        segMeans.add(mean(cur)!);
        segSds.add(stddev(cur)!);
      }
      cur = <double>[];
      segIdx = idx;
    }
    cur.add(v);
    prevNn = v;
    prevT = t;
  }

  void fold(List<double> nn, List<double> t) {
    for (var i = 0; i < nn.length; i++) {
      add(nn[i], t[i]);
    }
  }

  /// `hrvTime(settled ++ tail, nnTimesMs: ..., artifactFraction)`.
  Metric<HrvTime> evaluate(List<double> tailNn, List<double> tailT,
      {double artifactFraction = 0.0}) {
    final a = copy()..fold(tailNn, tailT);
    return a._finish(artifactFraction);
  }

  Metric<HrvTime> _finish(double artifactFraction) {
    const inputs = ['rr_cleaned'];
    if (n < 2) {
      return const Metric<HrvTime>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'too few NN intervals',
      );
    }
    double? acf1;
    if (pairs >= 30) {
      final m = s1 / pairs;
      final varSum = s2 - m * s1;
      final cov = prod - m * endp + lagPairs * m * m;
      acf1 = varSum > 0 ? cov / varSum : null;
    }
    final jittery = acf1 != null && acf1 < kNnDiffAcf1Floor;
    final rmssd = (pairs > 0 && !jittery) ? math.sqrt(ssd / pairs) : null;
    final pnn50 = (pairs > 0 && !jittery) ? 100.0 * over50 / pairs : null;
    final sdnn = n >= 2 ? math.sqrt(wM2 / (n - 1)) : null;
    double? sdann, sdnnIndex;
    final means = [...segMeans], sds = [...segSds];
    if (cur.length >= 2) {
      means.add(mean(cur)!);
      sds.add(stddev(cur)!);
    }
    if (means.length >= 2) {
      sdann = stddev(means);
      sdnnIndex = sds.isEmpty ? null : mean(sds);
    }
    final q = acf1 == null ? 1.0 : (1 - acf1 / kNnDiffAcf1Floor).clamp(0.0, 1.0);
    final conf =
        ((n / 250.0).clamp(0.0, 1.0) * q * (1 - artifactFraction)).clamp(0.3, 0.95);
    return Metric<HrvTime>(
      value: HrvTime(
        rmssd: rmssd,
        sdnn: sdnn,
        sdann: sdann,
        sdnnIndex: sdnnIndex,
        pnn50: pnn50,
        nBeats: n,
        diffAcf1: acf1,
      ),
      confidence: conf,
      tier: Tier.high,
      inputs_used: inputs,
      note: jittery
          ? 'rmssd_refused:acf1=${acf1.toStringAsFixed(3)} — the NN successive '
              'differences are essentially differenced white noise (−0.5 = pure, floor '
              '$kNnDiffAcf1Floor), so RMSSD/pNN50 would measure beat-timing jitter, not '
              'vagal tone. SDNN/SDANN survive it and are the lead here. PRV not ECG-HRV.'
          : 'PRV not ECG-HRV; RMSSD/pNN50 are quantization-sensitive at 1 Hz '
              '— lead with SDNN/SDANN',
    );
  }

  Map<String, dynamic> toJson() => {
        'n': n,
        'prevNn': prevNn,
        'prevT': prevT,
        't0': t0,
        'wMean': wMean,
        'wM2': wM2,
        'pairs': pairs,
        'over50': over50,
        'lagPairs': lagPairs,
        'ssd': ssd,
        's1': s1,
        's2': s2,
        'prod': prod,
        'endp': endp,
        'lastDiff': lastDiff,
        'segIdx': segIdx,
        'cur': cur,
        'segMeans': segMeans,
        'segSds': segSds,
      };

  factory HrvTimeAcc.fromJson(Map<String, dynamic> j) {
    List<double> dl(Object? o) => [for (final x in o as List) (x as num).toDouble()];
    return HrvTimeAcc()
      ..n = j['n'] as int
      ..prevNn = (j['prevNn'] as num).toDouble()
      ..prevT = (j['prevT'] as num).toDouble()
      ..t0 = (j['t0'] as num).toDouble()
      ..wMean = (j['wMean'] as num).toDouble()
      ..wM2 = (j['wM2'] as num).toDouble()
      ..pairs = j['pairs'] as int
      ..over50 = j['over50'] as int
      ..lagPairs = j['lagPairs'] as int
      ..ssd = (j['ssd'] as num).toDouble()
      ..s1 = (j['s1'] as num).toDouble()
      ..s2 = (j['s2'] as num).toDouble()
      ..prod = (j['prod'] as num).toDouble()
      ..endp = (j['endp'] as num).toDouble()
      ..lastDiff = (j['lastDiff'] as num?)?.toDouble()
      ..segIdx = j['segIdx'] as int
      ..cur = dl(j['cur'])
      ..segMeans = dl(j['segMeans'])
      ..segSds = dl(j['segSds']);
  }
}

// ===========================================================================
// 2. edge `_hrvTimeline`: trailing 5-min RMSSD of the corrected NN, >60 s apart
// ===========================================================================
// Right-context 0 over the NN list, so a point is final the moment its NN beat
// is settled. State = ring of the last 5 min of NN, first time, last emitted t.
class HrvTimelineState {
  final double originMs;
  List<double> _nn = [], _t = [];
  int _head = 0;
  double? _t0;
  int? _lastT;
  final List<Map<String, num>> out = [];

  HrvTimelineState(this.originMs);

  static double _round(double v, int dp) {
    final p = math.pow(10, dp);
    return (v * p).round() / p;
  }

  void _step(double v, double tm, List<Map<String, num>> sink) {
    _t0 ??= tm;
    _nn.add(v);
    _t.add(tm);
    while (tm - _t[_head] > 300000.0) {
      _head++;
    }
    if (tm - _t0! < 300000.0) return;
    final cnt = _nn.length - 1 - _head;
    if (cnt >= 10) {
      var ssd = 0.0;
      for (var k = _head + 1; k < _nn.length; k++) {
        final diff = _nn[k] - _nn[k - 1];
        ssd += diff * diff;
      }
      final rmssd = math.sqrt(ssd / cnt);
      final tSec = ((originMs + tm) / 1000).round();
      if (_lastT == null || tSec - _lastT! > 60) {
        sink.add({'t': tSec, 'v': _round(rmssd, 1)});
        _lastT = tSec;
      }
    }
  }

  void _trim() {
    if (_head > 512) {
      _nn = _nn.sublist(_head);
      _t = _t.sublist(_head);
      _head = 0;
    }
  }

  void fold(List<double> nn, List<double> t) {
    for (var i = 0; i < nn.length; i++) {
      _step(nn[i], t[i], out);
    }
    _trim();
  }

  /// settled points ++ provisional points from [tailNn].
  List<Map<String, num>> curve(List<double> tailNn, List<double> tailT) {
    final c = HrvTimelineState(originMs)
      .._nn = List.of(_nn)
      .._t = List.of(_t)
      .._head = _head
      .._t0 = _t0
      .._lastT = _lastT;
    final extra = <Map<String, num>>[];
    for (var i = 0; i < tailNn.length; i++) {
      c._step(tailNn[i], tailT[i], extra);
    }
    return [...out, ...extra];
  }
}

// ===========================================================================
// 3. nightHrvShape: per-30-min-bin RMSSD (+ band) over the night
// ===========================================================================
class NightShapeState {
  final double binMin;
  final int minBeatsPerBin;
  double? _t0;
  int _bin = 0;
  List<double> _nn = [], _t = [];
  int _count = 0;
  double _firstT = 0, _lastT = 0;
  // closed bins by index (holes included): [n, rmssd?, lo?, hi?]
  final List<List<num?>> closed = [];

  NightShapeState({this.binMin = 30, this.minBeatsPerBin = kMinBeatsPerHrvBin});

  double get _binMs => binMin * 60000.0;
  double _hi(int b) => _t0! + (b + 1) * _binMs;

  static List<num?> _binValue(
      List<double> nn, List<double> t, int minBeats) {
    final n = nn.length;
    if (n < minBeats) return [n, null, null, null];
    final m = hrvTime(nn, nnTimesMs: t);
    final rmssd = m.value?.rmssd;
    final se = rmssd == null ? null : rmssd / math.sqrt(2 * n);
    return [
      n,
      rmssd,
      se == null ? null : math.max(0.0, rmssd! - 1.96 * se),
      se == null ? null : rmssd! + 1.96 * se,
    ];
  }

  void _step(double v, double tm, List<List<num?>> sink) {
    if (_t0 == null) {
      _t0 = tm;
      _firstT = tm;
    }
    _lastT = tm;
    _count++;
    while (tm >= _hi(_bin)) {
      sink.add(_binValue(_nn, _t, minBeatsPerBin));
      _nn = [];
      _t = [];
      _bin++;
    }
    _nn.add(v);
    _t.add(tm);
  }

  void fold(List<double> nn, List<double> t) {
    for (var i = 0; i < nn.length; i++) {
      _step(nn[i], t[i], closed);
    }
  }

  Metric<NightHrvShape> evaluate(List<double> tailNn, List<double> tailT) {
    const inputs = ['rr_cleaned', 'beat_times'];
    final c = NightShapeState(binMin: binMin, minBeatsPerBin: minBeatsPerBin)
      .._t0 = _t0
      .._bin = _bin
      .._nn = List.of(_nn)
      .._t = List.of(_t)
      .._count = _count
      .._firstT = _firstT
      .._lastT = _lastT
      ..closed.addAll(closed);
    for (var i = 0; i < tailNn.length; i++) {
      c._step(tailNn[i], tailT[i], c.closed);
    }
    final total = c._count;
    if (total < minBeatsPerBin) {
      return Metric<NightHrvShape>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'too few beats for a nightly shape '
            '($total, need ≥$minBeatsPerBin)',
      );
    }
    final binMs = _binMs;
    final span = c._lastT - c._firstT;
    final nBins = math.max(1, (span / binMs).ceil());
    if (nBins < 3) {
      return Metric<NightHrvShape>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note:
            'night spans ${(span / 3600000).toStringAsFixed(1)} h — under three '
            '${binMin.round()}-min bins there is no shape to describe',
      );
    }
    final bins = <NightHrvBin>[];
    for (var b = 0; b < nBins; b++) {
      final List<num?> v = b < c.closed.length
          ? c.closed[b]
          : (b == c._bin
              ? _binValue(c._nn, c._t, minBeatsPerBin)
              : [0, null, null, null]);
      bins.add(NightHrvBin(
        startSec: (b * binMs / 1000).round(),
        nBeats: v[0]!.toInt(),
        rmssdMs: v[1]?.toDouble(),
        loMs: v[2]?.toDouble(),
        hiMs: v[3]?.toDouble(),
      ));
    }
    final third = bins.length ~/ 3;
    double? meanOf(Iterable<NightHrvBin> xs) {
      final v = [
        for (final b in xs)
          if (b.present) b.rmssdMs!
      ];
      return v.length < 2 ? null : mean(v);
    }

    final first = meanOf(bins.take(third));
    final last = meanOf(bins.skip(bins.length - third));
    final ratio =
        (first == null || last == null || first == 0) ? null : last / first;
    return Metric<NightHrvShape>(
      value: NightHrvShape(
        bins: bins,
        firstThirdMs: first,
        lastThirdMs: last,
        lastOverFirst: ratio,
      ),
      confidence: (0.8 * bins.where((b) => b.present).length / bins.length)
          .clamp(0.0, 0.8),
      tier: Tier.high,
      inputs_used: inputs,
      note: 'per-bin RMSSD (${binMin.round()}-min bins, PRV not ECG-HRV) — a '
          'DESCRIPTION of the night, never a cause. A low first third is equally '
          'consistent with alcohol, a late meal, late training, a warm room, '
          'illness onset, or nothing. Render each bin as a band, not a point.',
    );
  }
}

// ===========================================================================
// 4. edge `dayHrvCurve`: trailing 5-min RMSSD on gated RR, emitted every 60 s
// ===========================================================================
// Right-context 0. Exact append-only. State: ring of gated beats of the last
// 5 min, lastEmit, emitted list. (Works on raw substrate RR, not on NN.)
class DayHrvCurveState {
  List<double> _ts = [], _rr = [];
  int _head = 0;
  double _lastEmit = -1e18;
  final List<Map<String, num>> out = [];

  DayHrvCurveState();

  void fold(List<double> rrMs, List<double> rrTsMs) {
    for (var q = 0; q < rrMs.length; q++) {
      final v = rrMs[q];
      if (!(v >= 300 && v <= 2000)) continue;
      _ts.add(rrTsMs[q]);
      _rr.add(v);
      final i = _ts.length - 1;
      while (_ts[i] - _ts[_head] > 300000.0) {
        _head++;
      }
      if (i - _head >= 10 && _ts[i] - _lastEmit > 60000) {
        double? value;
        var ssd = 0.0;
        var nd = 0;
        for (var k = _head + 1; k <= i; k++) {
          final d = _rr[k] - _rr[k - 1];
          if (d.abs() > 0.20 * _rr[k - 1] || d.abs() > 200) continue;
          ssd += d * d;
          nd++;
        }
        if (nd >= 8) {
          final rmssd = math.sqrt(ssd / nd);
          value = rmssd <= 220 ? double.parse(rmssd.toStringAsFixed(1)) : null;
        }
        _lastEmit = _ts[i];
        if (value != null) out.add({'t': (_ts[i] / 1000).round(), 'v': value});
      }
    }
    if (_head > 512) {
      _ts = _ts.sublist(_head);
      _rr = _rr.sublist(_head);
      _head = 0;
    }
  }

  int get ringSize => _ts.length - _head;

  Map<String, dynamic> toJson() => {
        'ts': _ts.sublist(_head),
        'rr': _rr.sublist(_head),
        'lastEmit': _lastEmit,
        'out': out,
      };

  factory DayHrvCurveState.fromJson(Map<String, dynamic> j) {
    final s = DayHrvCurveState();
    s._ts = [for (final x in j['ts'] as List) (x as num).toDouble()];
    s._rr = [for (final x in j['rr'] as List) (x as num).toDouble()];
    s._lastEmit = (j['lastEmit'] as num).toDouble();
    for (final m in j['out'] as List) {
      final mm = m as Map;
      s.out.add({'t': mm['t'] as num, 'v': mm['v'] as num});
    }
    return s;
  }
}

// ===========================================================================
// 5. edge `_daytimeHrv`: 5-min bins of squared successive differences over
//    quiet seconds, outside the (known) sleep window
// ===========================================================================
// Each pair (prev, v) lands in bin tSec~/300 and only needs (a) whether the
// second of each beat is quiet and (b) the previous beat in the quiet chain.
// State: per-bin (sum of d^2, count) in beat order, the chain's `prev`, quiet
// seconds near the head, pending beats whose second the accelerometer has not
// reported yet (watermark). Sleep window fixed at construction; a changed
// window means refold (only bins straddling onset/offset differ — see report).
class DaytimeHrvState {
  final int onsetSec, offsetSec;
  final double cut;
  final Map<int, double> _sum = {};
  final Map<int, int> _cnt = {};
  double? _prev;
  final Set<int> _quiet = {};
  final List<double> _pendRr = [], _pendTs = [];
  int _maxBeatSec = 0;

  DaytimeHrvState(this.onsetSec, this.offsetSec, {this.cut = 0.02});

  static bool _isQuiet(double ax, double ay, double az, double cut) {
    final magSq = ax * ax + ay * ay + az * az;
    if (!(magSq > 0 && magSq <= 16.0)) return false;
    final mag = math.sqrt(ax * ax + ay * ay + az * az);
    return (mag - 1.0).abs() <= cut;
  }

  /// [watermarkSec]: every accel row with tsSec < watermarkSec has been given.
  void fold(List<double> rrMs, List<double> rrTsMs, List<int> accTs,
      List<double> ax, List<double> ay, List<double> az, int watermarkSec) {
    for (var i = 0; i < accTs.length; i++) {
      if (_isQuiet(ax[i], ay[i], az[i], cut)) _quiet.add(accTs[i]);
    }
    _pendRr.addAll(rrMs);
    _pendTs.addAll(rrTsMs);
    var used = 0;
    for (; used < _pendRr.length; used++) {
      final tSec = _pendTs[used] ~/ 1000;
      if (tSec >= watermarkSec) break; // second not fully known yet
      _beat(_pendRr[used], tSec);
    }
    _pendRr.removeRange(0, used);
    _pendTs.removeRange(0, used);
    // forget quiet seconds far behind the head (RR is time-ordered)
    if (_quiet.length > 4000) {
      final keep = _maxBeatSec - 120;
      _quiet.removeWhere((s) => s < keep);
    }
  }

  void _beat(double v, int tSec) {
    if (tSec > _maxBeatSec) _maxBeatSec = tSec;
    if (offsetSec > onsetSec && tSec >= onsetSec && tSec < offsetSec) {
      _prev = null;
      return;
    }
    if (!_quiet.contains(tSec)) {
      _prev = null;
      return;
    }
    if (v < 300 || v > 2000) {
      _prev = null;
      return;
    }
    if (_prev != null) {
      final d = v - _prev!;
      if (d.abs() <= 200) {
        final b = tSec ~/ 300;
        _sum[b] = (_sum[b] ?? 0.0) + d * d;
        _cnt[b] = (_cnt[b] ?? 0) + 1;
      }
    }
    _prev = v;
  }

  Map<String, dynamic> result() {
    final timeline = <Map<String, dynamic>>[];
    final means = <double>[];
    final keys = _sum.keys.toList()..sort();
    for (final b in keys) {
      final n = _cnt[b]!;
      if (n < 5) continue;
      final rmssd = math.sqrt(_sum[b]! / n);
      timeline.add({'t': b * 300, 'rmssd': (rmssd * 10).round() / 10.0, 'n': n});
      means.add(rmssd);
    }
    final mean = means.isEmpty ? null : means.reduce((a, c) => a + c) / means.length;
    return {
      'timeline': timeline,
      'mean_rmssd': mean == null ? null : (mean * 10).round() / 10.0,
      'n_buckets': timeline.length,
    };
  }

  int get pending => _pendRr.length;

  Map<String, dynamic> toJson() => {
        'sum': {for (final e in _sum.entries) '${e.key}': e.value},
        'cnt': {for (final e in _cnt.entries) '${e.key}': e.value},
        'prev': _prev,
        'quiet': _quiet.toList(),
        'pendRr': _pendRr,
        'pendTs': _pendTs,
        'maxBeatSec': _maxBeatSec,
      };

  factory DaytimeHrvState.fromJson(
      Map<String, dynamic> j, int onsetSec, int offsetSec,
      {double cut = 0.02}) {
    final s = DaytimeHrvState(onsetSec, offsetSec, cut: cut);
    (j['sum'] as Map).forEach((k, v) => s._sum[int.parse(k as String)] = (v as num).toDouble());
    (j['cnt'] as Map).forEach((k, v) => s._cnt[int.parse(k as String)] = v as int);
    s._prev = (j['prev'] as num?)?.toDouble();
    s._quiet.addAll((j['quiet'] as List).cast<int>());
    s._pendRr.addAll([for (final x in j['pendRr'] as List) (x as num).toDouble()]);
    s._pendTs.addAll([for (final x in j['pendTs'] as List) (x as num).toDouble()]);
    s._maxBeatSec = j['maxBeatSec'] as int;
    return s;
  }
}

// ===========================================================================
// 6. nocturnalRmssd (median of 5-min window RMSSDs) and
//    sleepSessionWindowedRmssd (mean of cleaned 5-min window RMSSDs)
// ===========================================================================
// Both are "closed windows" estimators: a window's RMSSD is a pure function of
// the beats inside it, and the headline is an order-statistic / mean over the
// <= ~100 window values. State = per-window record. The stage mask (nocturnal)
// and the session bounds (session) are applied at READ time over those records,
// so a re-staged night does not invalidate them. The pooled ACF1 jitter gate is
// rebuilt from per-window additive sums (S1,S2,P,E,L): same value to ~1e-15.

double? _acfFromSums(int n, double s1, double s2, double prod, double endp, int lag) {
  if (n < 30) return null; // _acf1MinDiffs
  final m = s1 / n;
  final varSum = s2 - m * s1;
  final cov = prod - m * endp + lag * m * m;
  return varSum > 0 ? cov / varSum : null;
}

class _WinRec {
  final int idx;
  final double rmssd;
  final int nd;
  final double s1, s2, prod, endp;
  final int lag;
  _WinRec(this.idx, this.rmssd, this.nd, this.s1, this.s2, this.prod, this.endp, this.lag);
  List<num> toJson() => [idx, rmssd, nd, s1, s2, prod, endp, lag];
}

/// Accumulates diff runs -> (nd, ssd, S1, S2, P, E, L).
class _RunSums {
  int nd = 0, lag = 0;
  double ssd = 0, s1 = 0, s2 = 0, prod = 0, endp = 0;
  void addRuns(List<List<double>> runs) {
    for (final r in runs) {
      for (var i = 0; i < r.length; i++) {
        final d = r[i];
        ssd += d * d;
        nd++;
        s1 += d;
        s2 += d * d;
        if (i > 0) {
          lag++;
          prod += r[i - 1] * d;
          endp += r[i - 1] + d;
        }
      }
    }
  }
}

class NocturnalRmssdState {
  final double windowMs;
  final int minBeatsPerWindow;
  double? _t0;
  int _idx = 0;
  List<double> _nn = [], _t = [];
  final List<_WinRec> recs = [];

  NocturnalRmssdState({this.windowMs = 300000.0, this.minBeatsPerWindow = 5});

  _WinRec? _close(int idx, List<double> nn, List<double> t) {
    if (nn.length < minBeatsPerWindow + 1) return null;
    final winRuns = <List<double>>[];
    var run = <double>[];
    for (var k = 1; k < nn.length; k++) {
      if (t[k] - t[k - 1] > nn[k] + 0.5) {
        if (run.isNotEmpty) {
          winRuns.add(run);
          run = <double>[];
        }
        continue;
      }
      run.add(nn[k] - nn[k - 1]);
    }
    if (run.isNotEmpty) winRuns.add(run);
    final s = _RunSums()..addRuns(winRuns);
    if (s.nd < minBeatsPerWindow) return null;
    return _WinRec(idx, math.sqrt(s.ssd / s.nd), s.nd, s.s1, s.s2, s.prod, s.endp, s.lag);
  }

  void _step(double v, double tm, List<_WinRec> sink) {
    _t0 ??= tm;
    final idx = ((tm - _t0!) / windowMs).floor();
    if (idx != _idx && _nn.isNotEmpty) {
      final r = _close(_idx, _nn, _t);
      if (r != null) sink.add(r);
      _nn = [];
      _t = [];
    }
    _idx = idx;
    _nn.add(v);
    _t.add(tm);
  }

  int _count = 0;
  void fold(List<double> nn, List<double> t) {
    for (var i = 0; i < nn.length; i++) {
      _step(nn[i], t[i], recs);
    }
    _count += nn.length;
  }

  Metric<double> evaluate(List<double> tailNn, List<double> tailT,
      {List<bool>? stageMaskPerSec}) {
    const inputs = ['rr_cleaned', 'beat_times'];
    final c = NocturnalRmssdState(
        windowMs: windowMs, minBeatsPerWindow: minBeatsPerWindow)
      .._t0 = _t0
      .._idx = _idx
      .._nn = List.of(_nn)
      .._t = List.of(_t)
      ..recs.addAll(recs);
    for (var i = 0; i < tailNn.length; i++) {
      c._step(tailNn[i], tailT[i], c.recs);
    }
    final total = _count + tailNn.length;
    if (total < minBeatsPerWindow + 1) {
      return const Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'too few NN intervals for windowed nocturnal RMSSD',
      );
    }
    final all = [...c.recs];
    final open = c._close(c._idx, c._nn, c._t);
    if (open != null) all.add(open);
    final rmssds = <double>[];
    var nd = 0, lag = 0;
    var s1 = 0.0, s2 = 0.0, prod = 0.0, endp = 0.0;
    for (final r in all) {
      if (stageMaskPerSec != null) {
        final midSec = ((r.idx + 0.5) * windowMs / 1000.0).floor();
        final keep = midSec >= 0 &&
            midSec < stageMaskPerSec.length &&
            stageMaskPerSec[midSec];
        if (!keep) continue;
      }
      rmssds.add(r.rmssd);
      nd += r.nd;
      lag += r.lag;
      s1 += r.s1;
      s2 += r.s2;
      prod += r.prod;
      endp += r.endp;
    }
    final acf1 = _acfFromSums(nd, s1, s2, prod, endp, lag);
    if (acf1 != null && acf1 < kNnDiffAcf1Floor) {
      return Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'rmssd_refused:acf1=${acf1.toStringAsFixed(3)} — the NN successive '
            'differences are essentially differenced white noise (−0.5 = pure, floor '
            '$kNnDiffAcf1Floor), so RMSSD/pNN50 would measure beat-timing jitter, not '
            'vagal tone',
      );
    }
    if (rmssds.isEmpty) {
      return const Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'no usable 5-min windows for nocturnal RMSSD',
      );
    }
    final robust = median(rmssds)!;
    final q = acf1 == null ? 1.0 : (1 - acf1 / kNnDiffAcf1Floor).clamp(0.0, 1.0);
    final conf = ((rmssds.length / 12.0).clamp(0.0, 1.0) * q).clamp(0.3, 0.95);
    return Metric<double>(
      value: robust,
      confidence: conf,
      tier: Tier.high,
      inputs_used: inputs,
      note: 'robust nocturnal RMSSD = MEDIAN of ${rmssds.length} consecutive '
          '5-min-window RMSSDs (REM/arousal-robust). PRV not ECG-HRV; '
          'RMSSD is quantization-sensitive at 1 Hz.',
    );
  }
}

// ---- verbatim copy of hrv_time.dart `_cleanWindowRuns` (private there) ----
List<List<double>> _cleanWindowRuns(List<double> rr, List<double> ts) {
  const radius = 2;
  const threshold = 0.20;
  final nn = <double>[];
  final at = <int>[];
  final nnTs = <double>[];
  for (var i = 0; i < rr.length; i++) {
    if (rr[i] >= 300 && rr[i] <= 2000) {
      nn.add(rr[i]);
      at.add(i);
      nnTs.add(ts[i]);
    }
  }
  final runs = <List<double>>[];
  var run = <double>[];
  var lastKept = -2;
  var lastTs = 0.0;
  for (var i = 0; i < nn.length; i++) {
    var keep = true;
    if (nn.length > radius) {
      final lo = math.max(0, i - radius);
      final hi = math.min(nn.length - 1, i + radius);
      final neighbors = <double>[];
      for (var j = lo; j <= hi; j++) {
        if (j != i) neighbors.add(nn[j]);
      }
      final med = neighbors.length < 2 ? null : median(neighbors);
      if (med != null && med > 0) keep = (nn[i] - med).abs() / med <= threshold;
    }
    if (!keep) {
      if (run.isNotEmpty) {
        runs.add(run);
        run = <double>[];
      }
      continue;
    }
    if (run.isNotEmpty &&
        (at[i] != lastKept + 1 || nnTs[i] - lastTs > nn[i] + 1000.0)) {
      runs.add(run);
      run = <double>[];
    }
    run.add(nn[i]);
    lastKept = at[i];
    lastTs = nnTs[i];
  }
  if (run.isNotEmpty) runs.add(run);
  return runs;
}

/// Raw-RR stream (NOT the corrected NN): a bucket is final the moment a beat of
/// a later bucket arrives. Session bounds fixed at construction.
class SessionRmssdState {
  final int startSec, endSec, windowSec;
  int _idx = -1;
  List<double> _rr = [], _ts = [];
  final List<_WinRec> recs = [];
  bool _any = false;

  SessionRmssdState(this.startSec, this.endSec, {this.windowSec = 300});

  _WinRec? _close(int idx, List<double> rr, List<double> ts) {
    final diffRuns = [
      for (final r in _cleanWindowRuns(rr, ts))
        if (r.length >= 2) [for (var i = 1; i < r.length; i++) r[i] - r[i - 1]]
    ];
    final s = _RunSums()..addRuns(diffRuns);
    if (s.nd == 0) return null;
    return _WinRec(idx, math.sqrt(s.ssd / s.nd), s.nd, s.s1, s.s2, s.prod, s.endp, s.lag);
  }

  void _step(double rr, double ts, List<_WinRec> sink) {
    final tsSec = (ts / 1000.0).round();
    if (tsSec < startSec || tsSec >= endSec) return;
    _any = true;
    final idx = (tsSec - startSec) ~/ windowSec;
    if (idx != _idx && _rr.isNotEmpty) {
      final r = _close(_idx, _rr, _ts);
      if (r != null) sink.add(r);
      _rr = [];
      _ts = [];
    }
    _idx = idx;
    _rr.add(rr);
    _ts.add(ts);
  }

  void fold(List<double> rr, List<double> ts) {
    for (var i = 0; i < rr.length; i++) {
      _step(rr[i], ts[i], recs);
    }
  }

  /// [lateBeats]: beats of the still-open bucket arrive via the same fold; this
  /// just closes the open bucket on a copy.
  Metric<double> evaluate() {
    const inputs = ['rr_sleep_window'];
    if (!_any) {
      return const Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'no RR beats inside the session window',
      );
    }
    final all = [...recs];
    final open = _rr.isEmpty ? null : _close(_idx, _rr, _ts);
    if (open != null) all.add(open);
    final rmssds = <double>[];
    var nd = 0, lag = 0;
    var s1 = 0.0, s2 = 0.0, prod = 0.0, endp = 0.0;
    for (final r in all) {
      rmssds.add(r.rmssd);
      nd += r.nd;
      lag += r.lag;
      s1 += r.s1;
      s2 += r.s2;
      prod += r.prod;
      endp += r.endp;
    }
    final acf1 = _acfFromSums(nd, s1, s2, prod, endp, lag);
    if (acf1 != null && acf1 < kNnDiffAcf1Floor) {
      return Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'rmssd_refused:acf1=${acf1.toStringAsFixed(3)} — the NN successive '
            'differences are essentially differenced white noise (−0.5 = pure, floor '
            '$kNnDiffAcf1Floor), so RMSSD/pNN50 would measure beat-timing jitter, not '
            'vagal tone',
      );
    }
    if (rmssds.isEmpty) {
      return const Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'no valid 5-min windows for sleep-session RMSSD',
      );
    }
    final q = acf1 == null ? 1.0 : (1 - acf1 / kNnDiffAcf1Floor).clamp(0.0, 1.0);
    final conf = ((rmssds.length / 12.0).clamp(0.0, 1.0) * q).clamp(0.3, 0.95);
    return Metric<double>(
      value: mean(rmssds)!,
      confidence: conf,
      tier: Tier.high,
      inputs_used: inputs,
      note: 'sleep-session HRV: mean RMSSD over cleaned 5-min windows.',
    );
  }
}

// ===========================================================================
// 7. irregularBeatScreen over the (day-long) corrected NN
// ===========================================================================
// Aggregates (SD1/SD2 from stddev of diffs and of levels, pNN70) are sums =>
// Welford, ~1e-13. The "sustained across 5-min windows" test is a COUNT of
// flagged/valid closed windows plus one open window evaluated on a copy => exact.
class IrregularScreenState {
  // elementwise stream state over the corrected NN list
  bool _prevKept = false;
  double _prevV = 0;
  int _nKept = 0;
  // diff stats (adjacent kept pairs)
  int _dN = 0;
  double _dMean = 0, _dM2 = 0;
  int _over = 0;
  // level stats (kept beats)
  int _lN = 0;
  double _lMean = 0, _lM2 = 0;
  // windows
  double? _winStart;
  List<double> _bk = [];
  List<bool> _bkAdj = [];
  int _valid = 0, _flagged = 0;

  final double sd1sd2Flag, pnnThresholdMs, pnnFlagPct, windowMs, sustainedFraction;
  final int minWindowBeats;

  IrregularScreenState({
    this.sd1sd2Flag = 0.70,
    this.pnnThresholdMs = 70,
    this.pnnFlagPct = 30,
    double windowMinutes = 5,
    this.minWindowBeats = 40,
    this.sustainedFraction = 0.5,
  }) : windowMs = windowMinutes * 60000;

  IrregularScreenState _copy() {
    final c = IrregularScreenState(
        sd1sd2Flag: sd1sd2Flag,
        pnnThresholdMs: pnnThresholdMs,
        pnnFlagPct: pnnFlagPct,
        windowMinutes: windowMs / 60000,
        minWindowBeats: minWindowBeats,
        sustainedFraction: sustainedFraction)
      .._prevKept = _prevKept
      .._prevV = _prevV
      .._nKept = _nKept
      .._dN = _dN
      .._dMean = _dMean
      .._dM2 = _dM2
      .._over = _over
      .._lN = _lN
      .._lMean = _lMean
      .._lM2 = _lM2
      .._winStart = _winStart
      .._bk = List.of(_bk)
      .._bkAdj = List.of(_bkAdj)
      .._valid = _valid
      .._flagged = _flagged;
    return c;
  }

  void _flush() {
    if (_bk.length >= minWindowBeats) {
      _valid++;
      final diffs = <double>[
        for (var i = 1; i < _bk.length; i++)
          if (_bkAdj[i]) _bk[i] - _bk[i - 1]
      ];
      final sdsd = stddev(diffs);
      final sdnn = stddev(_bk);
      if (sdsd != null && sdnn != null) {
        final sd1 = sdsd / math.sqrt2;
        final v = 2 * sdnn * sdnn - sd1 * sd1;
        final sd2 = v > 0 ? math.sqrt(v) : 0.0;
        if (sd2 > 0) {
          final ratio = sd1 / sd2;
          final over = diffs.where((d) => d.abs() > pnnThresholdMs).length;
          final pnn = 100.0 * over / diffs.length;
          if (ratio >= sd1sd2Flag && pnn >= pnnFlagPct) _flagged++;
        }
      }
    }
    _bk = [];
    _bkAdj = [];
  }

  void _add(double v, double tm) {
    final kept = v >= 300 && v <= 2000;
    if (kept) {
      final adjacent = _prevKept; // previous INPUT element was kept
      if (_prevKept) {
        final d = v - _prevV;
        _dN++;
        final dl = d - _dMean;
        _dMean += dl / _dN;
        _dM2 += dl * (d - _dMean);
        if (d.abs() > pnnThresholdMs) _over++;
      }
      _lN++;
      final dl = v - _lMean;
      _lMean += dl / _lN;
      _lM2 += dl * (v - _lMean);
      _nKept++;
      _winStart ??= tm;
      if (tm - _winStart! >= windowMs) {
        _flush();
        _winStart = tm;
      }
      _bk.add(v);
      _bkAdj.add(adjacent);
    }
    _prevKept = kept;
    _prevV = v;
  }

  void fold(List<double> nn, List<double> t) {
    for (var i = 0; i < nn.length; i++) {
      _add(nn[i], t[i]);
    }
  }

  Metric<IrregularRhythm> evaluate(List<double> tailNn, List<double> tailT,
      {double artifactFraction = 0.0,
      int minBeats = irregularScreenMinBeats,
      double maxArtifact = 0.30}) {
    const inputs = ['rr_cleaned'];
    final c = _copy()..fold(tailNn, tailT);
    if (c._nKept < minBeats) {
      return const Metric<IrregularRhythm>.absent(
        tier: Tier.estimate,
        inputs_used: inputs,
        note: 'too few clean beats for an irregular-rhythm screen',
      );
    }
    if (artifactFraction > maxArtifact) {
      return Metric<IrregularRhythm>.absent(
        tier: Tier.estimate,
        inputs_used: inputs,
        note: 'artifact fraction ${(artifactFraction * 100).round()}% > '
            '${(maxArtifact * 100).round()}% — screen suppressed on noisy RR',
      );
    }
    final sdsd = c._dN < 2 ? null : math.sqrt(c._dM2 / (c._dN - 1));
    final sdnn = c._lN < 2 ? null : math.sqrt(c._lM2 / (c._lN - 1));
    if (sdsd == null || sdnn == null) {
      return const Metric<IrregularRhythm>.absent(
        tier: Tier.estimate,
        inputs_used: inputs,
        note: 'no successive clean beats to build a Poincare plot from',
      );
    }
    final sd1 = sdsd / math.sqrt2;
    final v = 2 * sdnn * sdnn - sd1 * sd1;
    final sd2 = v > 0 ? math.sqrt(v) : 0.0;
    if (sd2 <= 0) {
      return const Metric<IrregularRhythm>.absent(
        tier: Tier.estimate,
        inputs_used: inputs,
        note: 'no long-term variability (SD2 = 0) — the SD1/SD2 ratio is '
            'undefined, not "perfectly regular"',
      );
    }
    final ratio = sd1 / sd2;
    final pnnPct = c._dN == 0 ? 0.0 : 100.0 * c._over / c._dN;
    final aggregateHigh = ratio >= sd1sd2Flag && pnnPct >= pnnFlagPct;
    var flag = false;
    if (aggregateHigh) {
      c._flush(); // the open window closes at end of data
      flag = c._valid != 0 && c._flagged / c._valid >= sustainedFraction;
    }
    final conf = (c._nKept / 5000.0 * (1 - artifactFraction)).clamp(0.2, 0.9);
    return Metric<IrregularRhythm>(
      value: IrregularRhythm(
        sd1: sd1,
        sd2: sd2,
        sd1sd2: ratio,
        pnnPct: pnnPct,
        nBeats: c._nKept,
        flag: flag,
      ),
      confidence: conf,
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'irregular-rhythm SCREEN (not a diagnosis): Poincaré SD1/SD2 + pNN'
          '${pnnThresholdMs.round()}. PRV not ECG — wrist pulse misses P-waves. '
          'Discuss with a clinician only if you have symptoms.',
    );
  }

  Map<String, dynamic> toJson() => {
        'prevKept': _prevKept,
        'prevV': _prevV,
        'nKept': _nKept,
        'dN': _dN,
        'dMean': _dMean,
        'dM2': _dM2,
        'over': _over,
        'lN': _lN,
        'lMean': _lMean,
        'lM2': _lM2,
        'winStart': _winStart,
        'bk': _bk,
        'bkAdj': [for (final a in _bkAdj) a ? 1 : 0],
        'valid': _valid,
        'flagged': _flagged,
      };

  factory IrregularScreenState.fromJson(Map<String, dynamic> j) {
    final s = IrregularScreenState();
    s._prevKept = j['prevKept'] as bool;
    s._prevV = (j['prevV'] as num).toDouble();
    s._nKept = j['nKept'] as int;
    s._dN = j['dN'] as int;
    s._dMean = (j['dMean'] as num).toDouble();
    s._dM2 = (j['dM2'] as num).toDouble();
    s._over = j['over'] as int;
    s._lN = j['lN'] as int;
    s._lMean = (j['lMean'] as num).toDouble();
    s._lM2 = (j['lM2'] as num).toDouble();
    s._winStart = (j['winStart'] as num?)?.toDouble();
    s._bk = [for (final x in j['bk'] as List) (x as num).toDouble()];
    s._bkAdj = [for (final x in j['bkAdj'] as List) x == 1];
    s._valid = j['valid'] as int;
    s._flagged = j['flagged'] as int;
    return s;
  }
}
