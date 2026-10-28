// RED phase for the experimental #628 HMM fix, revised after spec review
// round 1 (edge.research/wake-pr/hmm-fix-spec.md, spec-review-hmm-r1-findings.md,
// hmm-all-deep-diagnosis.md). Every night here is SYNTHETIC and seeded; no
// owner data is used or committed.
//
// WHAT THESE TESTS ARE NOT: they are regression and contract checks on an
// unvalidated model. The fixtures are MODEL-TARGETED stimuli (authored to
// exercise this decoder's emission thresholds); their authored stage names are
// not truth, and agreement with them is not staging validation. The bounds
// (deep < 50%, <= 40%, runs <= 120 min) are engineering regression bounds, not
// physiological standards.
//
// Fixture input inconsistency (H11, disclosed): the raw adapter below feeds
// one RR per second whose mean stays near 1000 ms while the HR series varies.
// HR comes from the HR series, RMSSD from successive RR differences; the two
// are not tied together as they would be on a real strap.
//
// Tags: RED fails on the shipped decoder (baseline from the first 120 min,
// no fallback) and passes under the spec (Option A + provenance + guard).
// CONTROL passes today and must keep passing. A test tagged ORACLE compares
// the production decoder with the independent reference decoder at the bottom
// of the helpers (upstream #628 formulas, whole-session baselines).
import 'dart:math' as math;
import 'dart:mirrors';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const _t0 = 1700000000;
const _raw0 = 1782532800; // 2026-06-27 04:00 UTC: a plausible night start.
const _fallback = 'hmm628_degenerate';
const _stages = ['wake', 'light', 'deep', 'rem'];

/// Seeded approximately-normal noise (sum of 6 uniforms, unit variance).
class _Noise {
  final math.Random _r;
  _Noise(int seed) : _r = math.Random(seed);
  double next() {
    var s = 0.0;
    for (var k = 0; k < 6; k++) {
      s += _r.nextDouble();
    }
    return (s - 3) * math.sqrt2;
  }
}

/// A scripted window, in epoch indices of the SLEEPING core.
typedef _Win = ({int from, int to});

class _Core {
  final List<({double hr, double rmssd})> epochs;
  final List<_Win> remWins, wakeWins;
  _Core(this.epochs, this.remWins, this.wakeWins);
}

/// The sleeping core of a night shaped like the owner's 2026-10-27 night
/// (diagnosis section 11), built from first principles, not from owner rows:
///  - 1044 epochs (8.7 h). HR falls from ~92 at onset along a 140-min
///    exponential toward ~70, so the first-120-min p10 lands near 78-80 (the
///    stored owner value was 77.9) while the rest of the night sits ~70.
///  - RMSSD rises from ~40 to ~62 ms.
///  - From minute 120: a 4-minute wake bump (HR +16, RMSSD -20), a deep-like
///    dip in the first five cycles (HR -6, RMSSD +12) and a REM bump (HR +8,
///    RMSSD + [remRmssdDelta]) at the end of each cycle.
/// [periodic] = true: exact 90-minute cycles. false: cycle lengths 80-105 min,
/// amplitudes x0.75-1.25 and a slow +-1.5 bpm drift (H11, nonperiodic).
_Core _core({int seed = 27, bool periodic = true, double remRmssdDelta = 3}) {
  final n = _Noise(seed), shape = math.Random(seed + 500);
  final starts = <double>[30];
  final lens = <double>[];
  final amps = <double>[];
  while (starts.last < 600) {
    final l = periodic ? 90.0 : 80 + shape.nextDouble() * 25;
    lens.add(l);
    amps.add(periodic ? 1.0 : 0.75 + shape.nextDouble() * 0.5);
    starts.add(starts.last + l);
  }
  final out = <({double hr, double rmssd})>[];
  final rem = <_Win>[], wake = <_Win>[];
  int? remFrom, wakeFrom;
  for (var k = 0; k < 1044; k++) {
    final m = k / 2;
    var hr = 70 + 22 * math.exp(-m / 140) - 3 * m / 520;
    var rm = 62 - 22 * math.exp(-m / 100);
    if (!periodic) hr += 1.5 * math.sin(m / 37);
    var isRem = false, isWake = false;
    if (m >= 120) {
      var ci = 0;
      while (ci + 1 < starts.length - 1 && starts[ci + 1] <= m) {
        ci++;
      }
      if (m >= starts[ci]) {
        final c = (m - starts[ci]) * 90 / lens[ci], a = amps[ci];
        if (c < 4) {
          hr += 16 * a;
          rm -= 20 * a;
          isWake = true;
        } else if (c >= 20 && c < 40 && ci < 5) {
          hr -= 6 * a;
          rm += 12 * a;
        } else if (c >= 70 && c < 88) {
          hr += 8 * a;
          rm += remRmssdDelta * a;
          isRem = true;
        }
      }
    }
    if (isRem) {
      remFrom ??= k;
    } else if (remFrom != null) {
      rem.add((from: remFrom, to: k));
      remFrom = null;
    }
    if (isWake) {
      wakeFrom ??= k;
    } else if (wakeFrom != null) {
      wake.add((from: wakeFrom, to: k));
      wakeFrom = null;
    }
    out.add((hr: hr + n.next() * 1.0, rmssd: rm + n.next() * 2.0));
  }
  return _Core(out, rem, wake);
}

/// Awake-level epochs (HR ~76, RMSSD ~27), own seeded noise so the sleeping
/// core's epochs are identical with and without them (H9).
List<({double hr, double rmssd})> _awake(int count, int seed) {
  final n = _Noise(seed);
  return [
    for (var i = 0; i < count; i++)
      (hr: 76 + n.next() * 1.2, rmssd: 27 + n.next() * 1.5)
  ];
}

List<HmmEpoch> _lay(List<({double hr, double rmssd})> rows, {int from = 0}) => [
      for (var i = 0; i < rows.length; i++)
        HmmEpoch(_t0 + (from + i) * 30, hr: rows[i].hr, rmssd: rows[i].rmssd)
    ];

/// [prefix] awake epochs, then the core, then [suffix] awake epochs.
List<HmmEpoch> _night(_Core c, {int prefix = 0, int suffix = 0}) => _lay([
      ..._awake(prefix, 9001),
      ...c.epochs,
      ..._awake(suffix, 9002),
    ]);

/// Spec red test 1: 240 epochs (120 min) at HR 62 / RMSSD 35, then 720 epochs
/// at 55 / 50, with +-0.5 bpm and +-2 ms seeded jitter. [stepAt] = 0 gives the
/// same night with no step (control).
List<HmmEpoch> _stepDownNight({int stepAt = 240, int seed = 1}) {
  final r = math.Random(seed);
  return [
    for (var i = 0; i < 960; i++)
      HmmEpoch(_t0 + i * 30,
          hr: (i < stepAt ? 62.0 : 55.0) + (r.nextDouble() - .5),
          rmssd: (i < stepAt ? 35.0 : 50.0) + (r.nextDouble() - .5) * 4)
  ];
}

// ---- measurement helpers ----

String _shares(List<String> l) {
  final n = l.length;
  String p(String s) =>
      '$s ${(100 * l.where((x) => x == s).length / n).toStringAsFixed(1)}%';
  return [..._stages.map(p), p('unobserved')].join(', ');
}

double _share(List<String> labels, String stage) {
  final observed = labels.where((l) => l != 'unobserved').length;
  expect(observed, greaterThan(0), reason: 'precondition: labels observed');
  return labels.where((l) => l == stage).length / observed;
}

void _expectComplete(List<String> labels) => expect(
    labels.where((l) => l == 'unobserved'), isEmpty,
    reason: 'a complete fixture must be completely staged');

/// Maximal runs of equal contiguous labels (epoch counts).
List<({String label, int len, int first})> _runs(
    List<HmmEpoch> e, List<String> l) {
  final out = <({String label, int len, int first})>[];
  var first = 0;
  for (var i = 1; i <= l.length; i++) {
    final brk = i == l.length ||
        l[i] != l[i - 1] ||
        e[i].startSec - e[i - 1].startSec != 30;
    if (brk) {
      out.add((label: l[first], len: i - first, first: first));
      first = i;
    }
  }
  return out;
}

int _longestEpochs(List<HmmEpoch> e, List<String> l) =>
    _runs(e, l).fold<int>(0, (m, r) => math.max(m, r.len));

/// Longest wake-or-REM interval, in epochs, counting only the part at or after
/// [fromSec] (a bout that straddles the cutoff counts its later part; H10).
int _longestWakeOrRemAfter(List<HmmEpoch> e, List<String> l, int fromSec) {
  var best = 0;
  for (final r in _runs(e, l)) {
    if (r.label != 'wake' && r.label != 'rem') continue;
    var inside = 0;
    for (var i = r.first; i < r.first + r.len; i++) {
      if (e[i].startSec >= fromSec) inside++;
    }
    best = math.max(best, inside);
  }
  return best;
}

int _countIn(List<String> l, String s, int from, int to) =>
    l.sublist(from, to).where((x) => x == s).length;

// ---- independent reference decoder (upstream #628 formulas) ----
// Spec (Option A): baselines from EVERY epoch of the list: HR p10 order
// statistic floor(n*.1) over finite 30<hr<200 without contact loss; mean RMSSD
// over finite 0<r<500 without contact loss (channels filtered independently).
// Emissions, 0.05 scales, transitions, initials, chain-termination rules are
// upstream's, unchanged.
List<String> _reference(List<HmmEpoch> e) {
  final hrs = <double>[], rms = <double>[];
  for (final x in e) {
    if (x.contactLost) continue;
    if (x.hr != null && x.hr!.isFinite && x.hr! > 30 && x.hr! < 200) {
      hrs.add(x.hr!);
    }
    if (x.rmssd != null && x.rmssd!.isFinite && x.rmssd! > 0 && x.rmssd! < 500) {
      rms.add(x.rmssd!);
    }
  }
  final out = List<String>.filled(e.length, 'unobserved');
  if (hrs.isEmpty || rms.isEmpty) return out;
  hrs.sort();
  final hb = hrs[(hrs.length * .1).floor()];
  final rb = rms.reduce((a, b) => a + b) / rms.length;
  double sig(double x, double c) => 1 / (1 + math.exp(-(x - c) / .05));
  List<double> em(HmmEpoch x) {
    final h = x.hr! / hb, r = x.rmssd! / rb;
    return [
      sig(h, 1.2) * (1 - sig(r, .8)),
      .4,
      (1 - sig(h, 1)) * sig(r, 1.1),
      sig(h, 1.05) * sig(r, 1),
    ].map((p) => math.log(math.max(.01, p))).toList();
  }

  const tr = [
    [.90, .09, .005, .005],
    [.05, .80, .10, .05],
    [.02, .15, .80, .03],
    [.05, .10, .00, .85],
  ];
  bool ok(HmmEpoch x) =>
      !x.contactLost &&
      x.hr != null && x.hr!.isFinite && x.hr! > 30 && x.hr! < 200 &&
      x.rmssd != null && x.rmssd!.isFinite && x.rmssd! > 0 && x.rmssd! < 500;
  var i = 0;
  while (i < e.length) {
    if (!ok(e[i])) {
      i++;
      continue;
    }
    var j = i + 1;
    while (j < e.length && ok(e[j]) && e[j].startSec - e[j - 1].startSec == 30) {
      j++;
    }
    final e0 = em(e[i]);
    var score = [
      for (var s = 0; s < 4; s++)
        (s < 2 ? math.log(.5) : double.negativeInfinity) + e0[s]
    ];
    final from = <List<int>>[];
    for (var t = i + 1; t < j; t++) {
      final et = em(e[t]);
      final nx = List<double>.filled(4, double.negativeInfinity);
      final bp = List<int>.filled(4, 0);
      for (var s = 0; s < 4; s++) {
        for (var p = 0; p < 4; p++) {
          final v = score[p] + math.log(tr[p][s]) + et[s];
          if (v > nx[s]) {
            nx[s] = v;
            bp[s] = p;
          }
        }
      }
      from.add(bp);
      score = nx;
    }
    var st = 0;
    for (var s = 1; s < 4; s++) {
      if (score[s] > score[st]) st = s;
    }
    for (var t = j - 1; t >= i; t--) {
      out[t] = _stages[st];
      if (t > i) st = from[t - i - 1][st];
    }
    i = j;
  }
  return out;
}

/// Epoch-for-epoch comparison of the production decoder with the reference.
void _expectMatchesReference(List<HmmEpoch> e) {
  final got = hmm628Stages(e, sessionStartSec: _t0);
  final want = _reference(e);
  final bad = <int>[
    for (var i = 0; i < e.length; i++)
      if (got[i] != want[i]) i
  ];
  expect(bad, isEmpty,
      reason: '${bad.length} of ${e.length} epochs differ from the '
          'whole-session reference (first at index ${bad.isEmpty ? '-' : bad.first}); '
          'production: ${_shares(got)}; reference: ${_shares(want)}');
}

// ---- raw-input builders (production path) ----

typedef _Raw = ({
  List<AccelSample> accel,
  List<double> hr,
  List<double> rr,
  List<double> rrTs,
  List<GravTs> grav,
  List<HrTs> hrTs,
  List<RrTs> rrRows,
  List<bool> contact,
});

/// One still-wrist second per sample; HR and RR per second (the convention of
/// hmm628_dispatch_test.dart). RR alternates +-rmssd/2, so successive
/// differences are exactly rmssd ms. [moving] makes the wrist move that second.
/// [contactLostAt] marks explicit contact loss; [invalidAccelAt] marks a sample
/// whose accel vector never decoded (an unsupported-sensor interval).
_Raw _rawNight(int seconds, double Function(int) hrAt, double Function(int) rmssdAt,
    {bool Function(int)? moving,
    bool Function(int)? contactLostAt,
    bool Function(int)? invalidAccelAt}) {
  final r = math.Random(5);
  final accel = <AccelSample>[], grav = <GravTs>[], contact = <bool>[];
  for (var i = 0; i < seconds; i++) {
    final mv = moving?.call(i) ?? false;
    final cl = contactLostAt?.call(i) ?? false;
    final bad = invalidAccelAt?.call(i) ?? false;
    final x = mv ? r.nextDouble() * 2 - 1 : 0.0;
    final y = mv ? r.nextDouble() * 2 - 1 : 0.0;
    final z = mv ? r.nextDouble() * 2 - 1 : 1.0;
    accel.add(AccelSample((_raw0 + i) * 1000.0, bad ? 0 : x, bad ? 0 : y, bad ? 0 : z,
        valid: !bad));
    grav.add(GravTs(_raw0 + i, x, y, z, valid: !bad, contactLost: cl));
    contact.add(cl);
  }
  final hr = [for (var i = 0; i < seconds; i++) hrAt(i)];
  final rr = [
    for (var i = 0; i < seconds; i++) 1000.0 + (i.isEven ? -1 : 1) * rmssdAt(i) / 2
  ];
  return (
    accel: accel,
    hr: hr,
    rr: rr,
    rrTs: [for (var i = 0; i < seconds; i++) (_raw0 + i) * 1000.0],
    grav: grav,
    hrTs: [for (var i = 0; i < seconds; i++) HrTs(_raw0 + i, hr[i])],
    rrRows: [for (var i = 0; i < seconds; i++) RrTs(_raw0 + i, rr[i])],
    contact: contact,
  );
}

SleepSegmentation _segment(_Raw n, StagingMethod method, {bool contact = false}) =>
    segmentSleep(n.accel, n.hr,
        rrMs: n.rr,
        rrTsMs: n.rrTs,
        contactLost: contact ? n.contact : null,
        forcedWindow: (onsetSec: _raw0, offsetSec: _raw0 + n.hr.length),
        method: method);

SleepSession _window(_Raw n, StagingMethod method) => AdvancedSleepStager.stageWindow(
    _raw0, _raw0 + n.hr.length, n.grav, n.hrTs,
    rr: n.rrRows, method: method);

/// Reads a property that the spec adds. Absent (as shipped) reads as null so
/// the assertion fails, instead of the test dying on NoSuchMethodError.
dynamic _prop(Object o, String name) {
  try {
    final d = o as dynamic;
    return switch (name) {
      'stagingFallback' => d.stagingFallback,
      'effectiveMethod' => d.effectiveMethod,
      _ => null,
    };
  } on NoSuchMethodError {
    return null;
  }
}

/// Calls the spec's pure guard `bool hmm628IsDegenerate(List<String> labels)`
/// in sleep_pipeline_hmm.dart. Mirrors keep this file compiling (and failing on
/// an assertion) before the function exists.
bool? _isDegenerate(List<String> labels) {
  final lib = currentMirrorSystem().libraries[Uri.parse(
      'package:openstrap_analytics/src/onehz/sleep/sleep_pipeline_hmm.dart')];
  if (lib == null || !lib.declarations.containsKey(#hmm628IsDegenerate)) {
    return null;
  }
  return lib.invoke(#hmm628IsDegenerate, [labels]).reflectee as bool;
}

void _expectDegenerate(List<String> labels, bool want, String why) {
  final got = _isDegenerate(labels);
  expect(got, isNotNull,
      reason: 'hmm628IsDegenerate(List<String>) must exist in '
          'sleep_pipeline_hmm.dart (spec H14)');
  expect(got, want, reason: why);
}

List<String> _repeat(Map<String, int> counts) =>
    [for (final e in counts.entries) ...List.filled(e.value, e.key)];

void main() {
  // ===================================================================
  group('checker controls (the red tests below are not vacuous)', () {
    // why: tests 2 and 6 only mean something if the run/bout helpers detect
    // the pathologies they hunt. Hand-made labels, no decoder involved.
    final e = [for (var i = 0; i < 500; i++) HmmEpoch(_t0 + i * 30, hr: 60, rmssd: 40)];
    test('flags a 250-minute single-stage block; no wake/REM in it', () {
      final blob = List<String>.filled(500, 'light');
      expect(_longestEpochs(e, blob), 500);
      expect(_longestWakeOrRemAfter(e, blob, _t0 + 3600), 0);
    });
    test('counts exact epochs, including the part of a bout after the cutoff', () {
      final l = List<String>.filled(500, 'light');
      for (var i = 115; i < 130; i++) {
        l[i] = 'rem'; // 15 epochs, cutoff at epoch 120: 10 count.
      }
      expect(_longestWakeOrRemAfter(e, l, _t0 + 3600), 10);
      final nine = List<String>.filled(500, 'light');
      for (var i = 300; i < 309; i++) {
        nine[i] = 'rem';
      }
      expect(_longestWakeOrRemAfter(e, nine, _t0 + 3600), 9,
          reason: '4.5 minutes is below the 5-minute bar');
      final early = List<String>.filled(500, 'light');
      for (var i = 100; i < 110; i++) {
        early[i] = 'wake';
      }
      expect(_longestWakeOrRemAfter(e, early, _t0 + 3600), 0);
    });
    test('a time gap splits a run (120.5 minutes is not 120)', () {
      final gap = [
        for (var i = 0; i < 241; i++) HmmEpoch(_t0 + i * 30, hr: 60, rmssd: 40)
      ];
      expect(_longestEpochs(gap, List.filled(241, 'light')), 241);
      final holed = [...gap]..[100] = HmmEpoch(_t0 + 100 * 30 + 5, hr: 60, rmssd: 40);
      expect(_longestEpochs(holed, List.filled(241, 'light')), lessThan(241));
    });
  });

  // ===================================================================
  group('reference decoder agrees with shipped decoder where the spec leaves it alone', () {
    // why: the reference below is the oracle for the ORACLE tests. It must match
    // the shipped decoder on every night whose whole session fits in the first
    // 120 minutes (there the baseline window and the whole session coincide).
    // If it did not, it would not be an independent statement of upstream #628.
    test('CONTROL ORACLE: 100-epoch nap (<120 min) matches', () {
      final c = _core();
      _expectMatchesReference(_lay(c.epochs.sublist(0, 100)));
    });
    test('CONTROL ORACLE: 239-epoch short night (<120 min) with a null-RMSSD hole matches', () {
      final rows = _lay(_core(seed: 3).epochs.sublist(0, 239));
      rows[50] = HmmEpoch(rows[50].startSec, hr: rows[50].hr, rmssd: null);
      rows[51] = HmmEpoch(rows[51].startSec, hr: rows[51].hr, rmssd: double.nan);
      _expectMatchesReference(rows);
    });
  });

  // ===================================================================
  group('generator preconditions (model-targeted owner-shaped night)', () {
    // why: the owner's baselines were hr_min_night 77.933 / rmssd_mean_night
    // 49.871 against a settled night near HR 70. If the synthetic night drifts
    // from that shape, the tests below stop modelling the reported bug.
    test('onset baselines near 78 bpm / 50 ms, later HR near 70', () {
      final e = _night(_core());
      final b = computeNightBaselines(e, sessionStartSec: _t0);
      expect(b.hrMinNight, closeTo(78, 3));
      expect(b.rmssdMeanNight, closeTo(50, 4));
      final late = [for (final x in e.skip(480)) x.hr!]..sort();
      expect(late[late.length ~/ 2], closeTo(70, 3), reason: 'median HR after hour 4');
    });
    test('a 90-minute awake prefix drags the onset RMSSD mean far under the settled level', () {
      final e = _night(_core(), prefix: 180);
      final b = computeNightBaselines(e, sessionStartSec: _t0);
      final settled = [for (final x in e.skip(600)) x.rmssd!];
      final settledMean = settled.reduce((a, c) => a + c) / settled.length;
      expect(b.rmssdMeanNight!, lessThan(0.6 * settledMean));
    });
    test('the sleeping core is byte-identical with and without a prefix (H9)', () {
      final c = _core();
      final plain = _night(c), pre = _night(c, prefix: 180);
      for (var i = 0; i < c.epochs.length; i++) {
        expect(pre[180 + i].hr, plain[i].hr);
        expect(pre[180 + i].rmssd, plain[i].rmssd);
      }
    });
    test('scripted windows exist after the cutoff: >= 3 REM windows of >= 9 min, wake bumps of 4 min', () {
      final c = _core();
      final late = c.remWins.where((w) => w.from >= 120).toList();
      expect(late.length, greaterThanOrEqualTo(3));
      for (final w in late) {
        expect(w.to - w.from, greaterThanOrEqualTo(18), reason: '18-min scripted REM bump');
      }
      expect(c.wakeWins.every((w) => w.to - w.from == 8), isTrue);
    });
  });

  // ===================================================================
  group('whole-night baseline (spec Option A; diagnosis section 8A)', () {
    test('RED 1: a step-down night is not mostly deep', () {
      // why: diagnosis section 9 test 1, section 6 cause 1. The decoder baseline
      // comes from the first 120 min (HR 62, RMSSD 35); every later epoch
      // (HR 55, RMSSD 50) reads h=.89, r=1.43 => deep emission .90 > light .4.
      // Bound: deep < 50% (engineering regression bound, not physiology; H8).
      final labels = hmm628Stages(_stepDownNight(), sessionStartSec: _t0);
      _expectComplete(labels);
      expect(_share(labels, 'deep'), lessThan(0.50), reason: _shares(labels));
    });

    test('CONTROL 1: the same night without a step is not mostly deep', () {
      final labels = hmm628Stages(_stepDownNight(stepAt: 0), sessionStartSec: _t0);
      _expectComplete(labels);
      expect(_share(labels, 'deep'), lessThan(0.50), reason: _shares(labels));
    });

    test('RED 2: 90 minutes awake at the start does not make the night deep', () {
      // why: diagnosis section 9 test 2. 180 awake epochs (HR ~76, RMSSD ~27)
      // fill most of the first 120 min, so the baseline is the awake level.
      // Paired with the no-prefix night: identical sleeping epochs (H9). All
      // shares are in the failure message so deep cannot hide a shift into
      // another stage (H12); the sleeping core is judged on its own.
      final e = _night(_core(), prefix: 180);
      final labels = hmm628Stages(e, sessionStartSec: _t0);
      _expectComplete(labels);
      expect(_share(labels, 'deep'), lessThanOrEqualTo(0.40), reason: _shares(labels));
      final core = labels.sublist(180);
      expect(_share(core, 'deep'), lessThanOrEqualTo(0.40),
          reason: 'sleeping core only: ${_shares(core)}');
    });

    test('RED 2b: awake prefix AND awake suffix (60 min) do not make the core deep', () {
      // why: H1. A whole-session statistic is not a sleep-specific baseline; a
      // long awake suffix pulls the p10 and mean the other way. The spec calls A
      // an onset-bias correction, so it must still not stage the core as deep.
      final c = _core();
      final e = _night(c, prefix: 180, suffix: 120);
      final labels = hmm628Stages(e, sessionStartSec: _t0);
      _expectComplete(labels);
      final core = labels.sublist(180, 180 + c.epochs.length);
      expect(_share(core, 'deep'), lessThanOrEqualTo(0.40),
          reason: 'core: ${_shares(core)}; whole: ${_shares(labels)}');
    });

    test('CONTROL 5: no stage covers 90% of a realistic night', () {
      // why: diagnosis section 9 guard rail 5; stops "all deep" turning into
      // "all light". It does NOT catch the shipped bug (tests 1, 2, 6 do).
      for (final e in [_night(_core()), _night(_core(), prefix: 180)]) {
        final labels = hmm628Stages(e, sessionStartSec: _t0);
        for (final s in _stages) {
          expect(_share(labels, s), lessThan(0.90), reason: '$s: ${_shares(labels)}');
        }
      }
    });

    test('CONTROL 1b: a night whose first two hours represent the whole night keeps its shape', () {
      // why: H1 control. Stationary HR 62 / RMSSD 40 with the same 90-min
      // cycles and noise, no onset transient: the onset-window baseline is
      // already right, so neither window should produce a degenerate block.
      final n = _Noise(77);
      final e = [
        for (var i = 0; i < 960; i++)
          () {
            final m = i / 2, c = m % 90;
            var hr = 62.0, rm = 40.0;
            if (c < 4) {
              hr += 18;
              rm -= 14;
            } else if (c >= 20 && c < 40) {
              hr -= 5;
              rm += 14;
            } else if (c >= 70 && c < 88) {
              hr += 9;
              rm += 4;
            }
            return HmmEpoch(_t0 + i * 30, hr: hr + n.next(), rmssd: rm + n.next() * 2);
          }()
      ];
      final labels = hmm628Stages(e, sessionStartSec: _t0);
      _expectComplete(labels);
      for (final s in _stages) {
        expect(_share(labels, s), lessThan(0.90), reason: _shares(labels));
      }
      expect(_longestEpochs(e, labels), lessThanOrEqualTo(240), reason: _shares(labels));
    });

    test('RED 3: a session whose first 2 h have no RMSSD is still staged', () {
      // why: H1 (missing-RMSSD stretch). The shipped baseline window is empty
      // for RMSSD => every epoch of the night is 'unobserved', although 6 h of
      // valid measurements follow. A whole-session baseline stages them.
      final c = _core();
      final e = _night(c);
      final holed = [
        for (var i = 0; i < e.length; i++)
          i < 240
              ? HmmEpoch(e[i].startSec, hr: e[i].hr, rmssd: null)
              : e[i]
      ];
      final labels = hmm628Stages(holed, sessionStartSec: _t0);
      expect(labels.skip(240).where((l) => l != 'unobserved').length,
          holed.length - 240,
          reason: 'epochs after the hole must be staged: ${_shares(labels)}');
      expect(labels.take(240), everyElement('unobserved'),
          reason: 'epochs without RMSSD stay unobserved');
    });

    test('CONTROL 3b: an RMSSD hole in the middle stays a hole and breaks the chain', () {
      // why: H1/H14. Independent channel filtering is kept for baselines, but a
      // classified epoch needs BOTH channels; the hole is unobserved.
      final e = _night(_core());
      final holed = [
        for (var i = 0; i < e.length; i++)
          (i >= 500 && i < 560) ? HmmEpoch(e[i].startSec, hr: e[i].hr, rmssd: null) : e[i]
      ];
      final labels = hmm628Stages(holed, sessionStartSec: _t0);
      expect(labels.sublist(500, 560), everyElement('unobserved'));
      expect(labels.sublist(0, 500).where((l) => l == 'unobserved'), isEmpty);
    });
  });

  // ===================================================================
  group('ORACLE: whole-session decoder equals the reference (nights longer than 2 h)', () {
    // why: H1/H14. Pins the exact Option-A behaviour (same statistics and
    // filters as upstream, window = the whole session) on short nights, split
    // sleep, wake prefix plus suffix, contrasting RMSSD patterns and
    // nonperiodic perturbations. The reference is an independent restatement
    // of the upstream formulas, not a copy of the production code.
    test('RED ORACLE: owner-shaped night', () => _expectMatchesReference(_night(_core())));
    test('RED ORACLE: 3 h short night (window > 2 h)', () {
      _expectMatchesReference(_lay(_core(seed: 4).epochs.sublist(0, 360)));
    });
    test('RED ORACLE: wake prefix plus wake suffix', () {
      _expectMatchesReference(_night(_core(), prefix: 180, suffix: 120));
    });
    test('RED ORACLE: split sleep (two sleeps with a 90-minute gap in one session)', () {
      final c = _core(seed: 11);
      final a = _lay(c.epochs.sublist(0, 400));
      final b = _lay(c.epochs.sublist(400, 900), from: 400 + 180);
      _expectMatchesReference([...a, ...b]);
    });
    test('RED ORACLE: contrasting RMSSD pattern (REM RMSSD lower than NREM)', () {
      _expectMatchesReference(_night(_core(remRmssdDelta: -8)));
    });
    test('RED ORACLE: nonperiodic cycles with drift', () {
      _expectMatchesReference(_night(_core(periodic: false, seed: 31)));
    });
    test('RED ORACLE: contact-loss epochs are excluded from baselines and from labels', () {
      final e = _night(_core());
      final lost = [
        for (var i = 0; i < e.length; i++)
          (i % 97 < 5)
              ? HmmEpoch(e[i].startSec, hr: e[i].hr, rmssd: e[i].rmssd, contactLost: true)
              : e[i]
      ];
      _expectMatchesReference(lost);
    });
    test('CONTROL ORACLE: staging session X then session Y equals staging Y alone', () {
      // why: H1 session boundaries. The decoder carries no state between calls.
      final x = _night(_core(seed: 8));
      final y = _lay(_core(seed: 9).epochs.sublist(0, 700));
      final alone = hmm628Stages(y, sessionStartSec: _t0);
      hmm628Stages(x, sessionStartSec: _t0);
      expect(hmm628Stages(y, sessionStartSec: _t0), alone);
    });
  });

  // ===================================================================
  group('oscillation on a model-targeted owner-shaped night (diagnosis section 11)', () {
    // why: on the owner's 10-27 night the shipped model gave one unbroken
    // 175-minute light block, then deep: no wake, no REM after the first 45
    // minutes (baseline p10 HR 77.9 makes wake need HR >= 93.5 and REM >= 82).
    // These rules apply to THIS scripted fixture only; they do not require
    // cycling on every real night (H10).
    const cutoff = _t0 + 3600;

    test('RED 6a: a 5-minute wake or REM interval exists after minute 60', () {
      final e = _night(_core());
      final labels = hmm628Stages(e, sessionStartSec: _t0);
      expect(_longestWakeOrRemAfter(e, labels, cutoff), greaterThanOrEqualTo(10),
          reason: 'longest wake/REM after minute 60 = '
              '${_longestWakeOrRemAfter(e, labels, cutoff)} epochs; ${_shares(labels)}');
    });

    test('RED 6b: no single stage run exceeds 240 epochs (120 minutes)', () {
      final e = _night(_core());
      final labels = hmm628Stages(e, sessionStartSec: _t0);
      expect(_longestEpochs(e, labels), lessThanOrEqualTo(240),
          reason: 'longest run ${_longestEpochs(e, labels)} epochs; ${_shares(labels)}');
    });

    test('RED 6c: scripted REM windows are answered by REM labels', () {
      // why: ties the bar to the fixture's own scripted change: in each of the
      // first three scripted late REM windows (18 min), at least 10 epochs
      // (5 min) are labelled REM.
      final c = _core();
      final labels = hmm628Stages(_night(c), sessionStartSec: _t0);
      final wins = c.remWins.where((w) => w.from >= 120).take(3).toList();
      expect(wins.length, 3);
      for (final w in wins) {
        expect(_countIn(labels, 'rem', w.from, w.to), greaterThanOrEqualTo(10),
            reason: 'window epochs ${w.from}-${w.to}: ${_shares(labels)}');
      }
    });

    test('RED 6d: nonperiodic cycles with drift also cycle', () {
      final e = _night(_core(periodic: false, seed: 31));
      final labels = hmm628Stages(e, sessionStartSec: _t0);
      expect(_longestEpochs(e, labels), lessThanOrEqualTo(240), reason: _shares(labels));
      expect(_longestWakeOrRemAfter(e, labels, cutoff), greaterThanOrEqualTo(10),
          reason: _shares(labels));
    });

    test('RED 6e: lower-RMSSD REM variant has no 120-minute single-stage run', () {
      // why: H11 contrasting RMSSD pattern. REM is not required here (the REM
      // emission needs RMSSD above the mean; diagnosis 6.3); only that the
      // night is not one block.
      final e = _night(_core(remRmssdDelta: -8));
      final labels = hmm628Stages(e, sessionStartSec: _t0);
      _expectComplete(labels);
      expect(_longestEpochs(e, labels), lessThanOrEqualTo(240), reason: _shares(labels));
    });
  });

  // ===================================================================
  group('published onset baselines stay as shipped (H15; spec: cardio users unchanged)', () {
    test('CONTROL: segmentation publishes the first-120-min values, not the whole-night ones', () {
      // Step-down night, raw: first 120 min HR 62 / RMSSD 35, then 55 / 50.
      final n = _rawNight(8 * 3600, (s) => s < 7200 ? 62 : 55, (s) => s < 7200 ? 35 : 50);
      for (final m in [StagingMethod.cardio, StagingMethod.hmm628]) {
        final j = _segment(n, m).toJson();
        expect(j['hr_min_night'], 62, reason: '${m.name}: p10 of the first 120 min');
        expect(j['rmssd_mean_night'], closeTo(35, 0.5),
            reason: 'raw adapter: RR pairs straddle epoch edges, so not exactly 35');
      }
    });
  });

  // ===================================================================
  group('guard predicate hmm628IsDegenerate (spec H14; pure, required)', () {
    // why: 90% and 120 classified epochs are policy choices (120 epochs = 60
    // minutes). Only classified HMM labels (wake/light/deep/rem) count;
    // 'unobserved' is neither numerator nor denominator.
    test('RED 119 vs 120 classified epochs, all one stage', () {
      _expectDegenerate(_repeat({'light': 119}), false, '119 < 120');
      _expectDegenerate(_repeat({'light': 120}), true, '120 >= 120 and 100%');
    });
    test('RED just below vs exactly 90%, for every dominant stage', () {
      for (final s in _stages) {
        final other = s == 'light' ? 'wake' : 'light';
        _expectDegenerate(_repeat({s: 899, other: 101}), false, '$s 89.9%');
        _expectDegenerate(_repeat({s: 900, other: 100}), true, '$s exactly 90%');
        _expectDegenerate(_repeat({s: 1000}), true, '$s 100%');
      }
    });
    test('RED zero observations and all-unobserved never trigger', () {
      _expectDegenerate(<String>[], false, 'empty');
      _expectDegenerate(_repeat({'unobserved': 5000}), false, 'zero classified');
    });
    test('RED many unobserved epochs: only classified epochs count', () {
      _expectDegenerate(_repeat({'light': 120, 'unobserved': 5000}), true,
          '120 classified, all light, however many holes');
      _expectDegenerate(_repeat({'light': 119, 'unobserved': 5000}), false, '119 classified');
      _expectDegenerate(_repeat({'light': 100, 'wake': 100, 'unobserved': 5000}), false,
          '50/50 over classified epochs');
      _expectDegenerate(_repeat({'light': 880, 'wake': 100, 'unobserved': 20}), false,
          '880/980 = 89.8% of classified, though 88% of all');
    });
  });

  // ===================================================================
  group('production fallback (H4-H7, H14, H18; analytics owns it)', () {
    // why: _stageSessionHmm lives in this package. Rule: >= 120 classified
    // epochs and one stage >= 90% of them => the default cardio staging, with
    // provenance on SleepSession and SleepSegmentation. staging_method keeps
    // the REQUESTED method; staging_effective_method names what ran.
    final flat8h = _rawNight(8 * 3600, (_) => 60, (_) => 100);
    // Degenerate HMM, different cardio: flat RMSSD, HR 66 only while moving.
    // Shipped HMM: ~100% light (checked below). Cardio: 6000 s of wake.
    bool mov(int i) => i > 3600 && i % 5400 >= 4200;
    final differ = _rawNight(8 * 3600, (i) => mov(i) ? 66 : 60, (_) => 100, moving: mov);

    test('PRECONDITION: the differ night is degenerate for HMM and distinct for cardio', () {
      final eps = AdvancedSleepStager.measuredEpochs(
          _raw0, _raw0 + 8 * 3600, differ.grav, differ.hrTs, differ.rrRows);
      final labels = hmm628Stages(eps, sessionStartSec: _raw0);
      expect(_share(labels, 'light'), greaterThanOrEqualTo(0.9), reason: _shares(labels));
      final cardio = _segment(differ, StagingMethod.cardio).toJson();
      expect(cardio['wake_sec'], 6000);
    });

    test('RED 4a: flat 8 h night falls back to cardio, with provenance', () {
      final hmm = _segment(flat8h, StagingMethod.hmm628).toJson();
      expect(hmm['light_sec'], greaterThan(0.9 * (hmm['tst_sec'] as int)),
          reason: 'precondition: flat input => HMM is ~all light');
      expect(hmm['staging_fallback'], _fallback);
      expect(hmm['staging_method'], 'hmm628', reason: 'the REQUESTED method');
      expect(hmm['staging_effective_method'], 'cardio');
    });

    test('RED 4b: where HMM and cardio differ, the fallback IS cardio (stages and totals)', () {
      // why: H7. A flat night cannot tell cardio from HMM, so the flag alone
      // could pass. Here shipped HMM says 100% light and cardio says 6000 s wake.
      final hmm = _segment(differ, StagingMethod.hmm628);
      final cardio = _segment(differ, StagingMethod.cardio);
      final hj = hmm.toJson(), cj = cardio.toJson();
      expect(hj['staging_fallback'], _fallback);
      expect(hmm.stages4, cardio.stages4, reason: 'per-second stages must be cardio\'s');
      for (final k in ['wake_sec', 'light_sec', 'deep_sec', 'rem_sec', 'tst_sec',
          'waso_sec', 'unobserved_sec']) {
        expect(hj[k], cj[k], reason: k);
      }
      expect(hj['wake_sec'], 6000, reason: 'positive control: cardio\'s wake survived');
    });

    test('RED 4c: stageWindow carries the provenance on SleepSession', () {
      final s = _window(differ, StagingMethod.hmm628);
      expect(_prop(s, 'stagingFallback'), _fallback);
      expect(_prop(s, 'effectiveMethod'), StagingMethod.cardio);
      final cardio = _window(differ, StagingMethod.cardio);
      expect(s.stages.map((x) => x.toJson()).toList(),
          cardio.stages.map((x) => x.toJson()).toList());
      expect(_prop(cardio, 'stagingFallback'), isNull);
    });

    test('RED 4d: detectSleep carries the provenance on every degenerate session', () {
      final s = AdvancedSleepStager.detectSleep(differ.grav, differ.hrTs,
          rr: differ.rrRows, method: StagingMethod.hmm628, tzOffsetSec: 0);
      expect(s, isNotEmpty, reason: 'positive control: a night was detected');
      for (final x in s) {
        expect(_prop(x, 'stagingFallback'), _fallback);
        expect(_prop(x, 'effectiveMethod'), StagingMethod.cardio);
      }
    });

    test('RED 4e: a step-down night falls back through the production path (H8)', () {
      // why: under Option A the step-down night is ~100% light (diagnosis 8A),
      // so the guard must fire. The 75% deep of the shipped decoder is not
      // >= 90%, which is why this is red as shipped.
      final n = _rawNight(8 * 3600, (s) => s < 7200 ? 62 : 55, (s) => s < 7200 ? 35 : 50);
      final j = _segment(n, StagingMethod.hmm628).toJson();
      expect(j['staging_fallback'], _fallback, reason: 'deep_sec=${j['deep_sec']} light_sec=${j['light_sec']}');
    });

    test('RED 4f: boundary through the real path: 3600 s (120 epochs) falls back, 3570 s (119) does not', () {
      final at = _rawNight(3600, (_) => 60, (_) => 100);
      final below = _rawNight(3570, (_) => 60, (_) => 100);
      expect(_prop(_window(at, StagingMethod.hmm628), 'stagingFallback'), _fallback);
      expect(_window(below, StagingMethod.hmm628).stages, isNotEmpty);
      expect(_prop(_window(below, StagingMethod.hmm628), 'stagingFallback'), isNull);
    });

    test('CONTROL 4g: cardio staging never carries fallback keys', () {
      final j = _segment(flat8h, StagingMethod.cardio).toJson();
      expect(j, isNot(contains('staging_fallback')));
      expect(j['staging_method'], 'cardio');
      expect(_prop(_window(flat8h, StagingMethod.cardio), 'stagingFallback'), isNull);
    });

    test('RED 4h: a varied night is not flagged, and says hmm628 ran', () {
      final c = _core();
      final e = _night(c);
      final n = _rawNight(e.length * 30, (s) => e[s ~/ 30].hr!, (s) => e[s ~/ 30].rmssd!);
      final j = _segment(n, StagingMethod.hmm628).toJson();
      expect(j, isNot(contains('staging_fallback')),
          reason: 'a cycling night must not trip the guard');
      expect(j['staging_method'], 'hmm628');
      expect(j['staging_effective_method'], 'hmm628');
    });

    test('CONTROL 4i: fewer than 120 classified epochs never falls back', () {
      final short = _rawNight(50 * 60, (_) => 60, (_) => 100);
      final j = _segment(short, StagingMethod.hmm628).toJson();
      expect(j['staging_method'], 'hmm628');
      expect(j, isNot(contains('staging_fallback')));
    });

    test('RED 6f: fallback keeps explicit contact loss as a gap (H6)', () {
      // why: cardio does not forward contactLost (advanced_stager.dart ~1399),
      // so a naive fallback would stage right through a contact-loss interval
      // that HMM had left as a hole. 10 minutes of loss at 2 h.
      bool lost(int i) => i >= 7200 && i < 7800;
      final n = _rawNight(8 * 3600, (_) => 60, (_) => 100, contactLostAt: lost);
      final j = _segment(n, StagingMethod.hmm628, contact: true);
      expect(j.toJson()['staging_fallback'], _fallback,
          reason: 'precondition: flat night with holes is still degenerate');
      expect(j.stages4.sublist(7200, 7800), everyElement('unobserved'));
      expect(j.stages4.sublist(0, 7000).where((s) => s == 'unobserved'), isEmpty,
          reason: 'positive control: other time is staged');
      final w = _window(n, StagingMethod.hmm628);
      expect(_prop(w, 'stagingFallback'), _fallback);
      for (final s in w.stages) {
        if (s.start < _raw0 + 7800 && s.end > _raw0 + 7200) {
          expect(s.stage, 'unobserved',
              reason: 'stageWindow segment [${s.start},${s.end}) crosses contact loss');
        }
      }
    });

    test('RED 6g: fallback keeps unsupported-sensor (invalid accel) intervals as gaps (H6)', () {
      bool bad(int i) => i >= 9000 && i < 9600;
      final n = _rawNight(8 * 3600, (_) => 60, (_) => 100, invalidAccelAt: bad);
      final w = _window(n, StagingMethod.hmm628);
      expect(_prop(w, 'stagingFallback'), _fallback);
      for (final s in w.stages) {
        if (s.start < _raw0 + 9600 && s.end > _raw0 + 9000) {
          expect(s.stage, 'unobserved',
              reason: 'segment [${s.start},${s.end}) crosses invalid accel');
        }
      }
    });

    test('RED 5: notes carry the exact claims (H18) and the low-confidence flag stays', () {
      const claim = 'Experimental sleep-stage estimates. Not validated against a clinical '
          'sleep study. Not for medical decisions.';
      const fb = 'The experimental model showed little stage variation; '
          'showing the default estimate.';
      final varied = _night(_core());
      final nv = _rawNight(varied.length * 30,
          (s) => varied[s ~/ 30].hr!, (s) => varied[s ~/ 30].rmssd!);
      final ordinary = _segment(nv, StagingMethod.hmm628).toJson();
      expect(ordinary['staging_note'], contains(claim));
      expect(ordinary['staging_note'], isNot(contains(fb)));
      final degenerate = _segment(flat8h, StagingMethod.hmm628).toJson();
      expect(degenerate['staging_note'], contains(claim));
      expect(degenerate['staging_note'], contains(fb));
      for (final j in [ordinary, degenerate]) {
        final note = (j['staging_note'] as String).toLowerCase();
        for (final banned in ['recovered', 'corrected', 'validated against psg', 'accurate']) {
          expect(note, isNot(contains(banned)), reason: 'overclaim: $banned');
        }
        expect(j['deep_low_confidence'], true);
      }
    });
  });
}
