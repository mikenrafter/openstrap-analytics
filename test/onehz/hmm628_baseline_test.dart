// RED phase for the experimental #628 HMM fix (edge.research/wake-pr/
// hmm-fix-spec.md, hmm-all-deep-diagnosis.md). Every night here is SYNTHETIC
// and seeded; no owner data is used or committed. Expected values come from
// the spec's thresholds (deep share, run length, wake/REM presence), never from
// a snapshot of the current output. These are engineering checks on an
// unvalidated model, not evidence of staging accuracy against PSG.
//
// Tests tagged RED fail on the shipped decoder (baseline from the first 120
// minutes only) and pass once the decoder baseline covers the whole session
// (spec Option A). Tests tagged CONTROL pass today and must keep passing.
import 'dart:math' as math;
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const _t0 = 1700000000;

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

/// A night shaped like the owner's 2026-10-27 night (diagnosis section 11),
/// built from first principles, not from the owner's rows:
///  - 1044 epochs (8.7 h). HR falls from ~92 at onset along a 140-min
///    exponential toward ~70, so the first-120-min p10 lands near 78-80 (the
///    stored owner value was 77.9) while the rest of the night sits ~70.
///  - RMSSD rises from ~40 to ~62 ms.
///  - From minute 120, 90-minute cycles: a 4-minute wake bump (HR +16, RMSSD
///    -20), a deep-like dip in the first five cycles (HR -6, RMSSD +12) and an
///    18-minute REM bump (HR +8, RMSSD +3) at the end of each cycle.
List<HmmEpoch> _ownerShapedNight({int awakePrefixEpochs = 0, int seed = 27}) {
  final n = _Noise(seed);
  final out = <HmmEpoch>[];
  var i = 0;
  // Optional pre-sleep wakefulness: HR ~76, RMSSD ~27 (spec red test 2).
  for (; i < awakePrefixEpochs; i++) {
    out.add(HmmEpoch(_t0 + i * 30,
        hr: 76 + n.next() * 1.2, rmssd: 27 + n.next() * 1.5));
  }
  for (var k = 0; k < 1044; k++, i++) {
    final m = k / 2; // minutes since sleep onset
    var hr = 70 + 22 * math.exp(-m / 140) - 3 * m / 520;
    var rm = 62 - 22 * math.exp(-m / 100);
    if (m >= 120) {
      final c = (m - 30) % 90; // minutes into the 90-min cycle
      final cycle = ((m - 30) / 90).floor();
      if (c < 4) {
        hr += 16;
        rm -= 20;
      } else if (c >= 20 && c < 40 && cycle < 5) {
        hr -= 6;
        rm += 12;
      } else if (c >= 70 && c < 88) {
        hr += 8;
        rm += 3;
      }
    }
    out.add(HmmEpoch(_t0 + i * 30,
        hr: hr + n.next() * 1.0, rmssd: rm + n.next() * 2.0));
  }
  return out;
}

/// Spec red test 1: 240 epochs (120 min) at HR 62 / RMSSD 35, then 720 epochs
/// at 55 / 50, with +-0.5 bpm and +-2 ms seeded jitter. [stepAt]=0 gives the
/// same night with no step (control).
List<HmmEpoch> _stepDownNight({int stepAt = 240, int seed = 1}) {
  final r = math.Random(seed);
  return [
    for (var i = 0; i < 960; i++)
      HmmEpoch(_t0 + i * 30,
          hr: (i < stepAt ? 62.0 : 55.0) + (r.nextDouble() - .5),
          rmssd: (i < stepAt ? 35.0 : 50.0) + (r.nextDouble() - .5) * 4),
  ];
}

double _share(List<String> labels, String stage) {
  final observed = labels.where((l) => l != 'unobserved').length;
  expect(observed, greaterThan(0), reason: 'precondition: labels observed');
  return labels.where((l) => l == stage).length / observed;
}

/// Maximal runs of equal contiguous labels, as (label, epoch count, first idx).
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

int _longestMinutes(List<HmmEpoch> e, List<String> l) =>
    _runs(e, l).fold<int>(0, (m, r) => math.max(m, r.len)) ~/ 2;

/// True when, from [fromSec] on, the labels hold a wake epoch or a REM bout of
/// at least [remMinEpochs] epochs (spec red test 6).
bool _hasWakeOrRemAfter(
    List<HmmEpoch> e, List<String> l, int fromSec, int remMinEpochs) {
  for (final r in _runs(e, l)) {
    if (e[r.first].startSec < fromSec) continue;
    if (r.label == 'wake') return true;
    if (r.label == 'rem' && r.len >= remMinEpochs) return true;
  }
  return false;
}

// ---- raw-input builders for the guard test (segmentSleep path) ----

/// One still-wrist second per sample; HR and RR per second (the same
/// convention hmm628_dispatch_test.dart uses). RR alternates +-rmssd/2, so
/// successive differences are exactly rmssd ms.
({List<AccelSample> accel, List<double> hr, List<double> rr, List<double> rrTs})
    _rawNight(int seconds, double Function(int sec) hrAt,
        double Function(int sec) rmssdAt) {
  return (
    accel: [
      for (var i = 0; i < seconds; i++) AccelSample((_t0 + i) * 1000.0, 0, 0, 1)
    ],
    hr: [for (var i = 0; i < seconds; i++) hrAt(i)],
    rr: [
      for (var i = 0; i < seconds; i++)
        1000.0 + (i.isEven ? -1 : 1) * rmssdAt(i) / 2
    ],
    rrTs: [for (var i = 0; i < seconds; i++) (_t0 + i) * 1000.0],
  );
}

SleepSegmentation _segment(
    ({List<AccelSample> accel, List<double> hr, List<double> rr, List<double> rrTs}) n,
    StagingMethod method) {
  return segmentSleep(n.accel, n.hr,
      rrMs: n.rr,
      rrTsMs: n.rrTs,
      forcedWindow: (onsetSec: _t0, offsetSec: _t0 + n.hr.length),
      method: method);
}

void main() {
  group('checker controls (the red tests below are not vacuous)', () {
    // why: tests 2 and 6 only mean something if the run/bout helpers detect
    // the pathologies they hunt. Hand-made labels, no decoder involved.
    final e = [for (var i = 0; i < 500; i++) HmmEpoch(_t0 + i * 30, hr: 60, rmssd: 40)];
    test('flags a 175-minute single-stage block and finds no wake/REM in it', () {
      final blob = List<String>.filled(500, 'light');
      expect(_longestMinutes(e, blob), 250);
      expect(_hasWakeOrRemAfter(e, blob, _t0 + 3600, 10), isFalse);
    });
    test('finds a late wake epoch and a 5-minute REM bout, ignores a 4.5-minute one', () {
      final wake = List<String>.filled(500, 'light')..[300] = 'wake';
      expect(_hasWakeOrRemAfter(e, wake, _t0 + 3600, 10), isTrue);
      final rem10 = List<String>.filled(500, 'light');
      for (var i = 300; i < 310; i++) {
        rem10[i] = 'rem';
      }
      expect(_hasWakeOrRemAfter(e, rem10, _t0 + 3600, 10), isTrue);
      final rem9 = List<String>.filled(500, 'light');
      for (var i = 300; i < 309; i++) {
        rem9[i] = 'rem';
      }
      expect(_hasWakeOrRemAfter(e, rem9, _t0 + 3600, 10), isFalse);
      // A bout inside the first hour does not count.
      final early = List<String>.filled(500, 'light')..[10] = 'wake';
      expect(_hasWakeOrRemAfter(e, early, _t0 + 3600, 10), isFalse);
    });
  });

  group('generator preconditions (owner-shaped night, diagnosis section 11)', () {
    // why: the owner's baselines were hr_min_night 77.933 / rmssd_mean_night
    // 49.871 against a settled night near HR 70. If the synthetic night drifts
    // away from that shape, tests 2 and 6 stop modelling the reported bug.
    test('onset baselines near 78 bpm / 50 ms, later HR near 70', () {
      final e = _ownerShapedNight();
      final b = computeNightBaselines(e, sessionStartSec: _t0);
      expect(b.hrMinNight, closeTo(78, 3));
      expect(b.rmssdMeanNight, closeTo(50, 4));
      final late = [for (final x in e.skip(480)) x.hr!]..sort();
      expect(late[late.length ~/ 2], closeTo(70, 3), reason: 'median HR after hour 4');
    });
    test('a 90-minute awake prefix drags the onset RMSSD mean far under the settled level', () {
      final e = _ownerShapedNight(awakePrefixEpochs: 180);
      final b = computeNightBaselines(e, sessionStartSec: _t0);
      final settled = [for (final x in e.skip(600)) x.rmssd!];
      final settledMean = settled.reduce((a, c) => a + c) / settled.length;
      expect(b.rmssdMeanNight!, lessThan(0.6 * settledMean),
          reason: 'prefix puts ~27 ms awake epochs into the 120-min window');
    });
  });

  group('whole-night baseline (spec Option A; diagnosis section 8A)', () {
    test('RED 1: a step-down night is not mostly deep', () {
      // why: diagnosis section 9 test 1, section 6 cause 1. The decoder baseline
      // comes from the first 120 min (HR 62, RMSSD 35); every later epoch
      // (HR 55, RMSSD 50) reads h=.89, r=1.43 => deep emission .90 > light .4,
      // so 75% of the night is deep. The whole-night baseline (p10 HR ~54.6,
      // mean RMSSD ~46) puts the late epochs near h=1, r=1.1: light.
      // Spec bound: deep < 50% of observed labels.
      final e = _stepDownNight();
      final labels = hmm628Stages(e, sessionStartSec: _t0);
      expect(_share(labels, 'deep'), lessThan(0.50),
          reason: 'deep share ${(100 * _share(labels, 'deep')).toStringAsFixed(1)}%');
    });

    test('CONTROL 1: the same night without a step is not mostly deep', () {
      // why: isolates the baseline window as the cause. Identical noise and
      // levels, but no onset transient: baseline == the night.
      final labels = hmm628Stages(_stepDownNight(stepAt: 0), sessionStartSec: _t0);
      expect(_share(labels, 'deep'), lessThan(0.50));
    });

    test('RED 2: 90 minutes awake at the start does not make the night deep', () {
      // why: diagnosis section 9 test 2 and section 5 ("opening the window
      // early"). 180 awake epochs (HR ~76, RMSSD ~27) fill most of the first
      // 120 min, so the baseline is the awake level and sleep reads as deep.
      // Spec bound: deep <= 40% of observed labels.
      final e = _ownerShapedNight(awakePrefixEpochs: 180);
      final labels = hmm628Stages(e, sessionStartSec: _t0);
      expect(_share(labels, 'deep'), lessThanOrEqualTo(0.40),
          reason: 'deep share ${(100 * _share(labels, 'deep')).toStringAsFixed(1)}%');
    });

    test('CONTROL 5: no stage covers 90% of a realistic night', () {
      // why: diagnosis section 9 guard rail 5. Green before and after; it
      // keeps the fix from trading "all deep" for "all light". It does NOT
      // catch the shipped bug (tests 1, 2, 6 do).
      for (final e in [_ownerShapedNight(), _ownerShapedNight(awakePrefixEpochs: 180)]) {
        final labels = hmm628Stages(e, sessionStartSec: _t0);
        for (final s in ['wake', 'light', 'deep', 'rem']) {
          expect(_share(labels, s), lessThan(0.90), reason: 'stage $s');
        }
      }
    });
  });

  group('oscillation on an owner-shaped night (diagnosis section 11)', () {
    // why: on the owner's 10-27 night the shipped model gave one unbroken
    // 175-minute light block, then deep: no wake, no REM after the first 45
    // minutes. Cause: baseline p10 HR 77.9 (onset transient) makes wake need
    // HR >= 93.5 and REM need HR >= 82, neither of which the settled night
    // reaches. The synthetic night has wake and REM bumps that clear the
    // whole-night thresholds (HR p10 ~66) but not the onset ones (~80).
    test('RED 6a: after hour 1 there is a wake epoch or a REM bout of 5 minutes or more', () {
      final e = _ownerShapedNight();
      final labels = hmm628Stages(e, sessionStartSec: _t0);
      expect(_hasWakeOrRemAfter(e, labels, _t0 + 3600, 10), isTrue,
          reason: 'no wake epoch and no REM bout >= 5 min after minute 60');
    });

    test('RED 6b: no single stage run exceeds 120 minutes', () {
      final e = _ownerShapedNight();
      final labels = hmm628Stages(e, sessionStartSec: _t0);
      expect(_longestMinutes(e, labels), lessThanOrEqualTo(120),
          reason: 'longest run ${_longestMinutes(e, labels)} min');
    });
  });

  group('degenerate-output guard (diagnosis section 8A; analytics owns it)', () {
    // why: _stageSessionHmm lives in this package (advanced_stager.dart), so
    // the guard test belongs here, not in edge. Rule: >= 120 observed epochs
    // and one stage >= 90% of them => cardio staging plus
    // staging_fallback: hmm628_degenerate in the segmentation JSON.
    final flat8h = _rawNight(8 * 3600, (_) => 60, (_) => 100);

    test('RED 4: a flat 8 h night falls back to cardio and says so', () {
      final hmm = _segment(flat8h, StagingMethod.hmm628);
      final cardio = _segment(flat8h, StagingMethod.cardio);
      // Preconditions: HMM really is degenerate here, cardio really stages it.
      final hmmJson = hmm.toJson();
      expect(hmm.stages4, isNotEmpty);
      expect(hmmJson['light_sec'], greaterThan(0.9 * (hmmJson['tst_sec'] as int)),
          reason: 'precondition: flat input => HMM is ~all light');
      expect(hmmJson['staging_fallback'], 'hmm628_degenerate');
      expect(hmm.stages4, cardio.stages4,
          reason: 'fallback stages must be exactly the default cardio stages');
    });

    test('CONTROL 4a: cardio staging never carries the fallback key', () {
      expect(_segment(flat8h, StagingMethod.cardio).toJson(),
          isNot(contains('staging_fallback')));
    });

    test('CONTROL 4b: a night with varied HR and RMSSD is not flagged', () {
      // Owner-shaped HR/RMSSD per epoch, expanded to one value per second.
      final e = _ownerShapedNight();
      final n = _rawNight(e.length * 30, (s) => e[s ~/ 30].hr!, (s) => e[s ~/ 30].rmssd!);
      expect(_segment(n, StagingMethod.hmm628).toJson(),
          isNot(contains('staging_fallback')),
          reason: 'a fixed fix must not trip the guard on a cycling night');
    });

    test('CONTROL 4c: fewer than 120 observed epochs never falls back', () {
      // 100 epochs (50 min) of flat input is one stage, but below the floor.
      final short = _rawNight(50 * 60, (_) => 60, (_) => 100);
      final json = _segment(short, StagingMethod.hmm628).toJson();
      expect(json['staging_method'], 'hmm628');
      expect(json, isNot(contains('staging_fallback')));
    });
  });
}
