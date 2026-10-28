// RED/GREEN for the ground-truth addendum (hmm-all-deep-diagnosis.md section
// 12; hmm-fix-spec.md "Ground-truth addendum"). The owner's 10-27 night showed
// that Option A alone (whole-session baselines) lets wake fire again and calls
// 158 min of false wake in a still, asleep owner (sleep/wake accuracy 52%
// against 75% shipped); A plus a movement-density wake gate gave 79% with 2 min
// false wake. These tests encode that with SYNTHETIC, deterministic data built
// from the diagnosis's recipe, not from owner rows. Engineering regression
// checks on an unvalidated model; the gate constants are fitted to one night.
import 'dart:math' as math;
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const _t0 = 1700000000;
const _raw0 = 1782532800;

// ---- unit fixtures: the hand-derived types used by hmm628_baseline_test ----
const _types = {
  'N': (62.0, 40.0), // neutral
  'W': (85.0, 22.0), // wake-like
  'R': (72.0, 48.0), // REM-like
  'P': (46.0, 60.0), // deep-like
  'A': (140.0, 110.0), // artifact: RMSSD > 100 ms at HR > 100
};

List<HmmEpoch> _seq(String s, {bool? Function(int i, String ch)? moved,
    Map<String, (double, double)> override = const {}}) => [
      for (var i = 0; i < s.length; i++)
        HmmEpoch(_t0 + i * 30,
            hr: (override[s[i]] ?? _types[s[i]]!).$1,
            rmssd: (override[s[i]] ?? _types[s[i]]!).$2,
            moved: moved?.call(i, s[i]))
    ];
String _p(List<String> l) =>
    l.map((x) => {'wake': 'W', 'light': 'L', 'deep': 'D', 'rem': 'R'}[x] ?? '.').join();
String _rep(String c, int n) => List.filled(n, c).join();

/// Segments tile [lo, hi) exactly (sorted, contiguous, no empty piece).
void _tile(List<StageSegment> segs, int lo, int hi) {
  expect(segs, isNotEmpty);
  expect(segs.first.start, lo);
  expect(segs.last.end, hi);
  for (var i = 0; i < segs.length; i++) {
    expect(segs[i].end, greaterThan(segs[i].start), reason: 'empty segment $i');
    if (i > 0) expect(segs[i].start, segs[i - 1].end, reason: 'gap/overlap before $i');
  }
}

/// The unobserved ranges of [segs], as (start, end) offsets from _raw0.
List<(int, int)> _gaps(List<StageSegment> segs) => [
      for (final s in segs)
        if (s.stage == 'unobserved') (s.start - _raw0, s.end - _raw0)
    ];

/// Flat 8 h night (HMM-degenerate): HR 60, RMSSD 100, still wrist, with
/// [override] choosing HR / RMSSD per second.
({List<GravTs> grav, List<HrTs> hr, List<RrTs> rr}) _flat8h(
    {(double, double)? Function(int sec)? override}) {
  const n = 8 * 3600;
  final grav = <GravTs>[], hr = <HrTs>[], rr = <RrTs>[];
  for (var i = 0; i < n; i++) {
    final o = override?.call(i) ?? (60.0, 100.0);
    grav.add(GravTs(_raw0 + i, 0, 0, 1));
    hr.add(HrTs(_raw0 + i, o.$1));
    rr.add(RrTs(_raw0 + i, 1000.0 + (i.isEven ? -1 : 1) * o.$2 / 2));
  }
  return (grav: grav, hr: hr, rr: rr);
}

void main() {
  // n=46: N x20, W x6 (indices 20..25), N x20. Without a gate: L20 W6 L20
  // (hand-derived like C5 in hmm628_baseline_test: six wake epochs repay the
  // light->wake entry cost). Each wake epoch's window is +-300 s = +-10 epochs,
  // so the 21 epochs 10..30 .. 15..35 all contain indices 15..30, where the
  // moved epochs are placed. Known motion per window = 21; the gate needs
  // moved >= 0.25 * 21 = 5.25, i.e. 6 moved epochs pass and 5 do not.
  final wakeRun = _rep('N', 20) + _rep('W', 6) + _rep('N', 20);
  final wakeOn = _rep('L', 20) + _rep('W', 6) + _rep('L', 20);
  final allLight = _rep('L', 46);
  List<HmmEpoch> withMoved(Set<int> yes, {Set<int> unknown = const {}}) => _seq(wakeRun,
      moved: (i, _) => unknown.contains(i) ? null : yes.contains(i));

  group('movement-density wake gate (spec addendum, section 12)', () {
    test('CONTROL: missing motion (null everywhere) leaves wake allowed', () {
      // why: unknown motion must not erase wake; the gate only applies when
      // motion is known. Also the baseline behaviour without motion data.
      expect(_p(hmm628Stages(_seq(wakeRun), sessionStartSec: _t0)), wakeOn);
    });

    test('CONTROL: 6 of 21 epochs moved (28.6% >= 25%) keeps wake', () {
      final e = withMoved({15, 17, 19, 22, 27, 30});
      expect(_p(hmm628Stages(e, sessionStartSec: _t0)), wakeOn);
    });

    test('RED: 5 of 21 epochs moved (23.8% < 25%) gates wake to light', () {
      final e = withMoved({15, 18, 22, 27, 30});
      expect(_p(hmm628Stages(e, sessionStartSec: _t0)), allLight);
    });

    test('RED: observed stillness everywhere (moved == false) gates wake to light', () {
      final e = withMoved({});
      expect(_p(hmm628Stages(e, sessionStartSec: _t0)), allLight);
    });

    test('RED: movement outside +-5 minutes does not open the gate', () {
      // Epochs 0..9 are 600+ s before the first wake epoch (index 20).
      final e = withMoved({0, 1, 2, 3, 4, 5, 6, 7, 8, 9});
      expect(_p(hmm628Stages(e, sessionStartSec: _t0)), allLight);
    });

    test('CONTROL: an epoch with unknown own motion is not gated', () {
      // The six wake epochs have null motion; neighbours are known and still.
      final e = withMoved({}, unknown: {20, 21, 22, 23, 24, 25});
      expect(_p(hmm628Stages(e, sessionStartSec: _t0)), wakeOn);
    });

    test('CONTROL: unknown epochs leave the denominator: 5 of 20 known = 25% passes', () {
      // One unknown epoch inside every window (index 31 is outside the earliest
      // window 10..30 but inside the rest; use 16 which is in all of them).
      // Known per window = 20, moved 5 => exactly 25% => gate open.
      final e = withMoved({15, 17, 19, 22, 27}, unknown: {16});
      expect(_p(hmm628Stages(e, sessionStartSec: _t0)), wakeOn);
    });

    test('the gate leaves non-wake stages alone (deep run still deep with no movement)', () {
      final e = _seq(_rep('N', 24) + _rep('P', 6) + _rep('N', 30), moved: (_, __) => false);
      expect(_p(hmm628Stages(e, sessionStartSec: _t0)),
          _rep('L', 24) + _rep('D', 6) + _rep('L', 30));
    });
  });

  group('baseline artifact rejection (spec addendum, section 12)', () {
    // 20 artifact epochs (HR 140, RMSSD 110) then 30 N, 8 R, 30 N. Hand-derived:
    // hb = 62 either way. rb: with artifacts (20*110+30*40+8*48+30*40)/88 = 56.64;
    // without: (30*40+8*48+30*40)/68 = 2784/68 = 40.94. R: r=48/40.94=1.172,
    // h=72/62=1.161: REM=sg(2.22)*sg(3.44)=.902*.969=.874 > .4 => REM found.
    // With rb=56.64: r=.848, REM=.902*sg(-3.0)=.902*.047=.043 => light.
    final body = _rep('N', 30) + _rep('R', 8) + _rep('N', 30);
    String bodyOf(String s, {Map<String, (double, double)> override = const {}}) =>
        _p(hmm628Stages(_seq(s, override: override), sessionStartSec: _t0)).substring(20);

    test('RED: artifact epochs are left out of the decoder baseline (REM found)', () {
      expect(bodyOf(_rep('A', 20) + body), _rep('L', 30) + _rep('R', 8) + _rep('L', 30));
    });

    test('CONTROL: RMSSD exactly 100 ms is not an artifact (REM missed)', () {
      expect(bodyOf(_rep('A', 20) + body, override: {'A': (140.0, 100.0)}), _rep('L', 68));
    });

    test('CONTROL: HR exactly 100 bpm is not an artifact (REM missed)', () {
      expect(bodyOf(_rep('A', 20) + body, override: {'A': (100.0, 110.0)}), _rep('L', 68));
    });

    test('RED: just over both thresholds (HR 101, RMSSD 100.5) is an artifact', () {
      expect(bodyOf(_rep('A', 20) + body, override: {'A': (101.0, 100.5)}),
          _rep('L', 30) + _rep('R', 8) + _rep('L', 30));
    });

    test('RED K2: the artifact test ignores the HR validity ceiling (HR 200, RMSSD 110)', () {
      // why: review K2. HR 200 fails the validity ceiling (hr < 200) but is
      // still above the artifact threshold; its RMSSD must not feed the baseline.
      final l = _p(hmm628Stages(_seq(_rep('A', 20) + body, override: {'A': (200.0, 110.0)}),
          sessionStartSec: _t0));
      expect(l.substring(0, 20), _rep('.', 20));
      expect(l.substring(20), _rep('L', 30) + _rep('R', 8) + _rep('L', 30));
    });

    test('CONTROL K2: RMSSD 500 (above its validity ceiling) at HR 140 stays out of the baseline', () {
      // RMSSD 500 fails rmssd < 500 but is above the artifact threshold; its HR
      // must not feed the baseline. (An excluded high-HR epoch cannot move a p10
      // here, so this pins the boundary without discriminating; HR 200 above does.)
      final l = _p(hmm628Stages(_seq(_rep('A', 20) + body, override: {'A': (140.0, 500.0)}),
          sessionStartSec: _t0));
      expect(l.substring(0, 20), _rep('.', 20));
      expect(l.substring(20), _rep('L', 30) + _rep('R', 8) + _rep('L', 30));
    });

    test('CONTROL K2: invalid but not artifact (HR 200, RMSSD 100) still feeds the baseline', () {
      // RMSSD 100 is valid and not > 100, so it enters the mean; REM is missed.
      final l = _p(hmm628Stages(_seq(_rep('A', 20) + body, override: {'A': (200.0, 100.0)}),
          sessionStartSec: _t0));
      expect(l.substring(0, 20), _rep('.', 20), reason: 'HR 200 is not a valid epoch');
      expect(l.substring(20), _rep('L', 68));
    });

    test('RED K1: rejected artifact epochs are unobserved and the chain breaks there', () {
      // why: review K1. The decoder must not publish stages from evidence it
      // rejects (all 28 rejected epochs of the 10-27 replay came out REM).
      final l = _p(hmm628Stages(_seq(_rep('A', 20) + body), sessionStartSec: _t0));
      expect(l.substring(0, 20), _rep('.', 20));
      expect(l.substring(20), _rep('L', 30) + _rep('R', 8) + _rep('L', 30));
    });

    test('RED K1: the first epoch after a rejected epoch starts a fresh chain', () {
      // A fresh chain cannot begin in REM (initial probability 0), so the
      // epoch right after the artifact is not REM even though a REM run follows.
      // Without the break it would continue the REM run across the artifact.
      final s = _rep('N', 20) + _rep('R', 8) + 'A' + _rep('R', 8) + _rep('N', 20);
      final l = _p(hmm628Stages(_seq(s), sessionStartSec: _t0));
      expect(l[28], '.', reason: 'the artifact epoch');
      expect(l[27], 'R', reason: 'positive control: REM before the artifact');
      expect(l[29], isNot('R'), reason: 'fresh chain: REM cannot start a chain');
    });

    test('CONTROL: the published onset baselines still include the artifact epochs', () {
      final b = computeNightBaselines(_seq(_rep('A', 20) + body), sessionStartSec: _t0);
      expect(b.hrMinNight, 62);
      expect(b.rmssdMeanNight, closeTo(4984 / 88, 1e-9),
          reason: 'published metadata is unchanged for every method');
    });
  });

  group('rejected artifact epochs through the cardio fallback (review K1)', () {
    test('RED K1: a flat night with a 10-minute artifact stretch falls back and keeps it as a gap', () {
      // 7200-7800 s: HR 140, RMSSD 110 (artifact). Rest: HR 60, RMSSD 100.
      final n = _flat8h(override: (i) => (i >= 7200 && i < 7800) ? (140.0, 110.0) : null);
      final s = AdvancedSleepStager.stageWindow(_raw0, _raw0 + 8 * 3600, n.grav, n.hr,
          rr: n.rr, method: StagingMethod.hmm628);
      expect(s.stagingFallback, 'hmm628_degenerate', reason: 'precondition: flat => degenerate');
      _tile(s.stages, _raw0, _raw0 + 8 * 3600);
      expect(_gaps(s.stages), [(7200, 7800)],
          reason: 'only the rejected stretch is a gap (aligned to the 30-s grid)');
    });
  });

  group('duplicate-timestamp sensor gaps through the fallback (review K3)', () {
    // why: a valid sample must not outvote an explicit contact-loss or invalid
    // sample at the same timestamp; measuredEpochs already rejects the epoch.
    test('RED K3: a contact-loss duplicate beats a valid sample at the same second', () {
      final n = _flat8h();
      final grav = [
        ...n.grav,
        for (var i = 7200; i < 7800; i++) GravTs(_raw0 + i, 0, 0, 1, contactLost: true),
      ];
      final s = AdvancedSleepStager.stageWindow(_raw0, _raw0 + 8 * 3600, grav, n.hr,
          rr: n.rr, method: StagingMethod.hmm628);
      expect(s.stagingFallback, 'hmm628_degenerate');
      _tile(s.stages, _raw0, _raw0 + 8 * 3600);
      expect(_gaps(s.stages), [(7200, 7800)]);
    });

    test('RED K3: an invalid duplicate beats a valid sample at the same second', () {
      final n = _flat8h();
      final grav = [
        ...n.grav,
        for (var i = 9000; i < 9600; i++) GravTs(_raw0 + i, 0, 0, 0, valid: false),
      ];
      final s = AdvancedSleepStager.stageWindow(_raw0, _raw0 + 8 * 3600, grav, n.hr,
          rr: n.rr, method: StagingMethod.hmm628);
      expect(s.stagingFallback, 'hmm628_degenerate');
      _tile(s.stages, _raw0, _raw0 + 8 * 3600);
      expect(_gaps(s.stages), [(9000, 9600)]);
    });

    test('CONTROL K3: a harmless valid duplicate leaves no gap', () {
      final n = _flat8h();
      final grav = [...n.grav, for (var i = 7200; i < 7800; i++) GravTs(_raw0 + i, 0, 0, 1)];
      final s = AdvancedSleepStager.stageWindow(_raw0, _raw0 + 8 * 3600, grav, n.hr,
          rr: n.rr, method: StagingMethod.hmm628);
      expect(s.stagingFallback, 'hmm628_degenerate');
      expect(_gaps(s.stages), isEmpty);
    });
  });

  group('measured movement reaches the gate (review K4)', () {
    // why: with moved: false hard-coded in measuredEpochs every test used to
    // stay green. These pin the extraction itself.
    ({List<GravTs> grav, List<HrTs> hr, List<RrTs> rr}) raw(int secs,
        double Function(int sec) thetaDeg,
        {double Function(int)? hrAt, double Function(int)? rmAt, bool Function(int)? lost}) {
      final grav = <GravTs>[], hr = <HrTs>[], rr = <RrTs>[];
      for (var i = 0; i < secs; i++) {
        final th = thetaDeg(i) * math.pi / 180;
        grav.add(GravTs(_raw0 + i, 0, math.sin(th), math.cos(th), contactLost: lost?.call(i) ?? false));
        hr.add(HrTs(_raw0 + i, hrAt?.call(i) ?? 62));
        rr.add(RrTs(_raw0 + i, 1000.0 + (i.isEven ? -1 : 1) * (rmAt?.call(i) ?? 40) / 2));
      }
      return (grav: grav, hr: hr, rr: rr);
    }

    test('literal flags around the 5 degree boundary and across an epoch edge', () {
      // theta steps: +4.9 at second 10 (epoch 0), +5.1 at second 40 (epoch 1),
      // +6 at second 60 (the 59 -> 60 pair belongs to the epoch holding second
      // 60, i.e. epoch 2), none in epoch 3.
      double theta(int s) => (s >= 10 ? 4.9 : 0) + (s >= 40 ? 5.1 : 0) + (s >= 60 ? 6 : 0);
      final n = raw(120, theta);
      final e = AdvancedSleepStager.measuredEpochs(_raw0, _raw0 + 120, n.grav, n.hr, n.rr);
      expect([for (final x in e) x.startSec - _raw0], [0, 30, 60, 90]);
      expect([for (final x in e) x.moved], [false, true, true, false]);
    });

    test('an epoch with no usable gravity has unknown motion (null), not false', () {
      final n = raw(150, (_) => 0, lost: (s) => s >= 60 && s < 90);
      final e = AdvancedSleepStager.measuredEpochs(_raw0, _raw0 + 150, n.grav, n.hr, n.rr);
      final lostEpoch = e.where((x) => x.startSec - _raw0 == 60).single;
      expect(lostEpoch.contactLost, isTrue);
      expect(lostEpoch.moved, isNull);
      expect(e.where((x) => x.startSec - _raw0 == 0).single.moved, false);
    });

    // 60 epochs neutral, 20 wake-like (HR 85, RMSSD 22), 60 neutral, 40 REM-like
    // (HR 72, RMSSD 48): not degenerate (light ~67%), so HMM stays in charge.
    (double, double) vitals(int sec) {
      final ep = sec ~/ 30;
      if (ep >= 60 && ep < 80) return (85, 22);
      if (ep >= 140) return (72, 48);
      return (62, 40);
    }

    SleepSession stage(double Function(int) theta) {
      final n = raw(180 * 30, theta,
          hrAt: (s) => vitals(s).$1, rmAt: (s) => vitals(s).$2);
      return AdvancedSleepStager.stageWindow(_raw0, _raw0 + 180 * 30, n.grav, n.hr,
          rr: n.rr, method: StagingMethod.hmm628);
    }

    int wakeSecIn(SleepSession s, int lo, int hi) {
      var t = 0;
      for (final x in s.stages) {
        if (x.stage != 'wake') continue;
        t += math.max(0, math.min(x.end, _raw0 + hi) - math.max(x.start, _raw0 + lo));
      }
      return t;
    }

    test('a moving wrist keeps wake: 20 wake-like epochs while turning 20 degrees a second', () {
      // 1800..2400 s: the wrist turns +-20 degrees every second.
      final s = stage((sec) => (sec >= 1800 && sec < 2400) ? (sec.isEven ? 0 : 20) : 0);
      expect(s.stagingFallback, isNull, reason: 'precondition: not degenerate');
      expect(wakeSecIn(s, 1800, 2400), greaterThanOrEqualTo(300),
          reason: 'wake must survive where movement agrees');
    });

    test('the same vitals on a still wrist are gated to light', () {
      final s = stage((_) => 0);
      expect(s.stagingFallback, isNull, reason: 'precondition: not degenerate');
      expect(wakeSecIn(s, 0, 180 * 30), 0);
    });
  });

  group('the 10-27 night, synthetic (section 12 recipe)', () {
    // Minutes 0-25 still wrist, HR 90 -> 140 -> 105, RMSSD ~110 (artifact);
    // 25-80 awake in bed (a 30-90 degree turn in ~45% of minutes, HR 82-90);
    // 80 onset: HR steps to ~76; 80-150 perfectly still, HR 78 -> 88, RMSSD
    // 38 -> 14 (REM-like), one 100 degree reposition at 120; 150-330 still, HR
    // 64-70, RMSSD 50-90, with a 40-min still stretch from 250 at HR +10 and
    // RMSSD 15; 330-332 a two-minute large movement (the mask); then HR 60,
    // RMSSD 85, still until 480; 480-510 awake with movement, HR 70-85.
    const total = 510 * 60;
    final rnd = math.Random(1027);
    double noise(double a) => (rnd.nextDouble() - .5) * 2 * a;
    final hrS = List<double>.filled(total, 0), rmS = List<double>.filled(total, 0);
    final theta = List<double>.filled(total, 0); // wrist orientation, degrees
    var cur = 0.0, jump = 0;
    void turn(int sec, double deg) {
      cur += (jump++ % 2 == 0 ? 1 : -1) * deg;
      for (var k = sec; k < total; k++) {
        theta[k] = cur;
      }
    }

    for (var i = 0; i < total; i++) {
      final m = i / 60.0;
      double hr, rm;
      if (m < 12) {
        hr = 90 + 50 * m / 12;
        rm = 110;
      } else if (m < 25) {
        hr = 140 - 35 * (m - 12) / 13;
        rm = 110;
      } else if (m < 80) {
        hr = 86 + 4 * math.sin(m / 3);
        rm = 35;
      } else if (m < 150) {
        hr = 78 + 10 * (m - 80) / 70;
        rm = 38 - 24 * (m - 80) / 70;
      } else if (m >= 250 && m < 290) {
        hr = 77 + 3 * math.sin(m / 5);
        rm = 15;
      } else if (m < 330) {
        hr = 67 + 3 * math.sin(m / 5);
        rm = 70 + 20 * math.sin(m / 9);
      } else if (m < 332) {
        hr = 90;
        rm = 40;
      } else if (m < 480) {
        hr = 60;
        rm = 85;
      } else {
        hr = 77 + 8 * math.sin(m);
        rm = 35;
      }
      hrS[i] = hr + noise(1);
      rmS[i] = (rm + noise(m < 25 ? 6 : 3)).clamp(5.0, 200.0);
    }
    // Orientation changes (each is a >5 degree turn between two seconds).
    for (var mnt = 25; mnt < 80; mnt++) {
      if ((mnt * 7) % 20 < 9) turn(mnt * 60 + 10, 30.0 + (mnt * 13) % 60);
    }
    turn(120 * 60, 100);
    for (var s = 330 * 60; s < 332 * 60; s++) {
      turn(s, 40);
    }
    for (var mnt = 480; mnt < 510; mnt++) {
      turn(mnt * 60 + 20, 40.0 + (mnt * 11) % 40);
    }
    final grav = [
      for (var i = 0; i < total; i++)
        GravTs(_raw0 + i, 0, math.sin(theta[i] * math.pi / 180), math.cos(theta[i] * math.pi / 180))
    ];
    final hr = [for (var i = 0; i < total; i++) HrTs(_raw0 + i, hrS[i])];
    final rr = [
      for (var i = 0; i < total; i++) RrTs(_raw0 + i, 1000.0 + (i.isEven ? -1 : 1) * rmS[i] / 2)
    ];
    final session = AdvancedSleepStager.stageWindow(_raw0, _raw0 + total, grav, hr,
        rr: rr, method: StagingMethod.hmm628);

    int sec(int minute) => _raw0 + minute * 60;
    /// Longest clipped run of [stages] inside [fromMin, toMin).
    int longest(Set<String> stages, int fromMin, int toMin) {
      var best = 0;
      for (final s in session.stages) {
        if (!stages.contains(s.stage)) continue;
        final lo = math.max(s.start, sec(fromMin)), hi = math.min(s.end, sec(toMin));
        best = math.max(best, hi - lo);
      }
      return best;
    }

    String report() {
      final c = <String, int>{};
      for (final s in session.stages) {
        c[s.stage] = (c[s.stage] ?? 0) + s.end - s.start;
      }
      return c.toString();
    }

    test('PRECONDITION: the night is staged by HMM (not the degenerate fallback), all observed', () {
      expect(session.stagingFallback, isNull, reason: report());
      expect(session.effectiveMethod, StagingMethod.hmm628);
      expect(session.stages.where((s) => s.stage == 'unobserved').length, lessThanOrEqualTo(1),
          reason: report());
    });

    test('RED: no wake run over 5 minutes during scripted sleep (minute 85 to 480)', () {
      // why: Option A alone calls ~100 min of wake in the still high-HR block.
      final w = longest({'wake'}, 85, 480);
      expect(w, lessThanOrEqualTo(300), reason: 'longest wake run $w s; ${report()}');
    });

    test('CONTROL: no single stage holds 90% of the session', () {
      final c = <String, int>{};
      var total = 0;
      for (final s in session.stages) {
        if (s.stage == 'unobserved') continue;
        c[s.stage] = (c[s.stage] ?? 0) + s.end - s.start;
        total += s.end - s.start;
      }
      for (final e in c.entries) {
        expect(e.value / total, lessThan(0.90), reason: '${e.key}: ${report()}');
      }
    });

    test('RED: REM or light holds a 5-minute run inside each still high-HR block', () {
      // Block 1: minutes 85-150 (HR 78-88, RMSSD 38-14). Block 2: 250-290
      // (HR +10, RMSSD 15). The owner was asleep (band state 2; accel at the
      // noise floor); HR and HRV alone cannot separate REM from light here, so
      // either is accepted, wake is not.
      expect(longest({'rem', 'light'}, 85, 150), greaterThanOrEqualTo(300),
          reason: 'block 1; ${report()}');
      expect(longest({'rem', 'light'}, 250, 290), greaterThanOrEqualTo(300),
          reason: 'block 2; ${report()}');
    });
  });
}
