// CLINICAL — incremental irregular-rhythm screen.
//
// [IrregularScreenState] is `irregularBeatScreen` as a fold over the corrected
// NN series that `RrCorrector` settles. Feed it each fold's settled NN with
// [IrregularScreenState.fold], and ask [IrregularScreenState.evaluate] with the
// corrector's provisional tail: the Metric equals
// `irregularBeatScreen(allNn, nnTimesMs: allTimes, ...)` over settled ++ tail.
//
// The aggregates (SD1/SD2 from the spread of successive differences and of the
// levels, pNNx) are running sums (Welford), equal to the batch's two-pass
// figures to ~1e-13. The "sustained across 5-minute windows" test is a COUNT of
// flagged / valid closed windows plus the one open window, which is evaluated
// on a copy at the end of the data, so it is exact. The per-window verdict is
// the batch's own (`irregularWindowVerdict`).

import 'dart:math' as math;

import '../types.dart';
import 'irregular_diagnostics.dart';
import 'irregular_rhythm.dart';
import 'irregular_window.dart';

class IrregularScreenState {
  final double sd1sd2Flag, pnnThresholdMs, pnnFlagPct, windowMinutes;
  final int minWindowBeats;
  final double sustainedFraction;

  // ---- running state over the corrected NN list ----
  bool _prevKept = false; // the previous INPUT beat was inside [300, 2000]
  double _prevV = 0;
  int _nKept = 0;
  // successive differences between adjacent kept beats
  int _dN = 0;
  double _dMean = 0, _dM2 = 0;
  int _over = 0;
  // levels of kept beats
  int _lN = 0;
  double _lMean = 0, _lM2 = 0;
  // sustained-window bookkeeping
  double? _winStart;
  List<double> _bk = [];
  List<bool> _bkAdj = [];
  int _valid = 0, _flagged = 0;

  IrregularScreenState({
    this.sd1sd2Flag = 0.70,
    this.pnnThresholdMs = 70,
    this.pnnFlagPct = 30,
    this.windowMinutes = 5,
    this.minWindowBeats = 40,
    this.sustainedFraction = 0.5,
  });

  /// A broken window config fails CLOSED in the batch (never sustained). Here it
  /// also means no windows are tracked, so a bad config cannot grow the state.
  bool get _windowsOk => irregularWindowConfigOk(
      windowMinutes: windowMinutes,
      minWindowBeats: minWindowBeats,
      sustainedFraction: sustainedFraction);

  /// Restores a state from [toJson], parameters included. Throws
  /// [FormatException] on a checkpoint of another type or version, or one that
  /// is malformed.
  factory IrregularScreenState.fromJson(Map<String, dynamic> json) {
    try {
      return _restore(json);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('malformed IrregularScreenState checkpoint: $e');
    }
  }

  static IrregularScreenState _restore(Map<String, dynamic> j) {
    if (j['type'] != 'IrregularScreenState') {
      throw FormatException(
          'not an IrregularScreenState checkpoint: ${j['type']}');
    }
    if (j['version'] != 1) {
      throw FormatException(
          'unsupported IrregularScreenState version ${j['version']}');
    }
    double d(String k) => (j[k] as num).toDouble();
    final s = IrregularScreenState(
      sd1sd2Flag: d('sd1sd2Flag'),
      pnnThresholdMs: d('pnnThresholdMs'),
      pnnFlagPct: d('pnnFlagPct'),
      windowMinutes: d('windowMinutes'),
      minWindowBeats: j['minWindowBeats'] as int,
      sustainedFraction: d('sustainedFraction'),
    );
    s._prevKept = j['prevKept'] as bool;
    s._prevV = d('prevV');
    s._nKept = j['nKept'] as int;
    s._dN = j['dN'] as int;
    s._dMean = d('dMean');
    s._dM2 = d('dM2');
    s._over = j['over'] as int;
    s._lN = j['lN'] as int;
    s._lMean = d('lMean');
    s._lM2 = d('lM2');
    s._winStart = (j['winStart'] as num?)?.toDouble();
    s._bk = [for (final x in j['bk'] as List) (x as num).toDouble()];
    s._bkAdj = [for (final x in j['bkAdj'] as List) (x as int) == 1];
    s._valid = j['valid'] as int;
    s._flagged = j['flagged'] as int;
    final ok = s._bk.length == s._bkAdj.length &&
        s._nKept >= 0 &&
        s._dN >= 0 &&
        s._lN >= 0 &&
        s._over >= 0 &&
        s._over <= s._dN &&
        s._flagged >= 0 &&
        s._flagged <= s._valid;
    if (!ok) {
      throw const FormatException('inconsistent IrregularScreenState checkpoint');
    }
    return s;
  }

  /// Checkpoint: `{'version': 1, 'type': 'IrregularScreenState', ...}`, plain
  /// JSON, bounded (running sums plus at most one open 5-minute window).
  Map<String, dynamic> toJson() => {
        'version': 1,
        'type': 'IrregularScreenState',
        'sd1sd2Flag': sd1sd2Flag,
        'pnnThresholdMs': pnnThresholdMs,
        'pnnFlagPct': pnnFlagPct,
        'windowMinutes': windowMinutes,
        'minWindowBeats': minWindowBeats,
        'sustainedFraction': sustainedFraction,
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

  IrregularScreenState _copy() => IrregularScreenState(
        sd1sd2Flag: sd1sd2Flag,
        pnnThresholdMs: pnnThresholdMs,
        pnnFlagPct: pnnFlagPct,
        windowMinutes: windowMinutes,
        minWindowBeats: minWindowBeats,
        sustainedFraction: sustainedFraction,
      )
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

  /// Closes the open window into the valid / flagged counts.
  void _closeWindow() {
    final verdict = irregularWindowVerdict(_bk, _bkAdj,
        sd1sd2Flag: sd1sd2Flag,
        pnnThresholdMs: pnnThresholdMs,
        pnnFlagPct: pnnFlagPct,
        minWindowBeats: minWindowBeats);
    if (verdict != null) {
      _valid++;
      if (verdict) _flagged++;
    }
    _bk = [];
    _bkAdj = [];
  }

  void _add(double v, double tm) {
    final kept = v >= 300 && v <= 2000;
    if (kept) {
      // Adjacent = the previous INPUT beat was kept too: no difference is ever
      // taken across a skipped beat.
      final adjacent = _prevKept;
      if (adjacent) {
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
      if (_windowsOk) {
        final start = _winStart ??= tm;
        if (tm - start >= windowMinutes * 60000) {
          _closeWindow();
          _winStart = tm;
        }
        _bk.add(v);
        _bkAdj.add(adjacent);
      }
    }
    _prevKept = kept;
    _prevV = v;
  }

  /// Appends settled NN ([nn], ms) and their beat times ([nnTimesMs], same
  /// length). Beats outside [300, 2000] ms are skipped exactly as
  /// `irregularBeatScreen` skips them, including its no-diff-across-a-gap rule.
  void fold(List<double> nn, List<double> nnTimesMs) {
    if (nn.length != nnTimesMs.length) {
      throw ArgumentError('nn has ${nn.length} entries, nnTimesMs '
          '${nnTimesMs.length}');
    }
    for (var i = 0; i < nn.length; i++) {
      _add(nn[i], nnTimesMs[i]);
    }
  }

  /// [evaluate] plus the evidence behind the verdict, equal to
  /// `irregularBeatScreenDetailed(allNn, ...)` over settled ++ tail. RED STUB.
  IrregularScreenResult evaluateDetailed(
    List<double> tailNn,
    List<double> tailNnTimesMs, {
    double artifactFraction = 0.0,
    int minBeats = irregularScreenMinBeats,
    double maxArtifact = 0.30,
    RrCleaningCounts? cleaning,
  }) =>
      throw UnimplementedError('red stub');

  /// The screen over everything folded plus the provisional ([tailNn],
  /// [tailNnTimesMs]). Does not change the state. Absent (same note) exactly
  /// where `irregularBeatScreen` is absent.
  Metric<IrregularRhythm> evaluate(
    List<double> tailNn,
    List<double> tailNnTimesMs, {
    double artifactFraction = 0.0,
    int minBeats = irregularScreenMinBeats,
    double maxArtifact = 0.30,
  }) {
    const inputs = ['rr_cleaned'];
    final c = _copy()..fold(tailNn, tailNnTimesMs);
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
    if (aggregateHigh && c._windowsOk) {
      c._closeWindow(); // the open window closes at the end of the data
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
}
