// HrvTimeAggregator parity with hrvTime(): same numbers (within float
// tolerance) for any beat series and any chunking.
//
// Contract used here:
//  * gapAware (default): every beat carries its time; originMs is the first
//    beat's time. run(beats) == hrvTime(nn, nnTimesMs: times).value.
//  * gapAware false: times are ignored; run(beats) == hrvTime(nn).value
//    (so sdann / sdnnIndex are null and seams are not skipped).
//  * hrvTime returns an absent Metric below 2 beats. The aggregator then
//    reports nBeats = the beat count and null for every other field.

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/fold_law_support.dart' show foldBounds;
import '../support/property.dart' show Rng;

typedef Beat = ({double nnMs, double? timeMs});

const double _t0 = 1000000.0;
const _tol = 1e-9;

List<Object?> _fields(HrvTime v) =>
    [v.rmssd, v.sdnn, v.sdann, v.sdnnIndex, v.pnn50, v.diffAcf1];

final _eqAll = fieldsEqual<HrvTime>(
    (v) => [..._fields(v), v.nBeats],
    relTol: _tol,
    absTol: _tol);

/// What hrvTime says, mapped to the aggregator's expectation.
HrvTime _expected(List<Beat> beats, {required bool gapAware}) {
  final nn = [for (final b in beats) b.nnMs];
  final times = [for (final b in beats) b.timeMs ?? 0.0];
  final m = hrvTime(nn, nnTimesMs: gapAware ? times : null);
  return m.value ?? HrvTime(nBeats: beats.length);
}

HrvTimeAggregator _agg(List<Beat> beats, {bool gapAware = true}) =>
    HrvTimeAggregator(
        originMs: gapAware && beats.isNotEmpty ? beats.first.timeMs : null,
        gapAware: gapAware);

void _expectParity(HrvTime got, HrvTime want, String tag) {
  expect(got.nBeats, want.nBeats, reason: '$tag: nBeats');
  for (final (name, a, b) in [
    ('rmssd', got.rmssd, want.rmssd),
    ('sdnn', got.sdnn, want.sdnn),
    ('sdann', got.sdann, want.sdann),
    ('sdnnIndex', got.sdnnIndex, want.sdnnIndex),
    ('pnn50', got.pnn50, want.pnn50),
    ('diffAcf1', got.diffAcf1, want.diffAcf1),
  ]) {
    expect(a == null, b == null, reason: '$tag: $name null-ness ($a vs $b)');
    if (a != null && b != null) {
      expect((a - b).abs() <= _tol + _tol * b.abs(), isTrue,
          reason: '$tag: $name $a vs $b');
    }
  }
}

/// Builds a beat series with times. Values are multiples of 0.5 so the gap
/// rule's float arithmetic is exact in both implementations.
///  mode 0: smooth (random walk), mode 1: white noise (jittery, so the
///  RMSSD/pNN50 floor nulls them), mode 2: slow beats (spans several 5-minute
///  bins in few beats).
/// [gapP] is the chance a beat is preceded by a hole; [withTimes] false leaves
/// every timeMs null.
List<Beat> _series(Rng r, int n, int mode,
    {double gapP = .05, bool withTimes = true}) {
  final out = <Beat>[];
  var t = _t0;
  var nn = mode == 2 ? 1700.0 : 800.0;
  for (var i = 0; i < n; i++) {
    switch (mode) {
      case 1:
        nn = 600 + r.intIn(0, 800) / 1.0;
      case 2:
        nn = (nn + r.intIn(-60, 60)).clamp(1200, 2000).toDouble();
      default:
        nn = (nn + r.intIn(-40, 40)).clamp(450, 1300).toDouble();
    }
    if (r.nextBool(.04)) nn += r.intIn(40, 200); // an occasional big step
    var extra = 0.0;
    if (i > 0) {
      final p = r.nextDouble();
      if (p < gapP) {
        // a hole; sometimes a whole 5-minute bin or more
        extra = r.nextBool(.15)
            ? r.intIn(300000, 700000).toDouble()
            : r.intIn(600, 30000).toDouble();
      } else if (p < gapP + .04) {
        extra = [0.5, 1.0, 0.0][r.nextInt(3)]; // right at the 0.5 ms tolerance
      }
    }
    t += nn + extra;
    out.add((nnMs: nn, timeMs: withTimes ? t : null));
  }
  return out;
}

/// Contiguous series with exact constant nn (acf1 undefined: zero variance).
List<Beat> _constant(int n, double nn) =>
    [for (var i = 1; i <= n; i++) (nnMs: nn, timeMs: _t0 + i * nn)];

void main() {
  group('named series', () {
    final named = <String, List<Beat>>{
      'no beats': [],
      'one beat': [(nnMs: 800.0, timeMs: _t0 + 800)],
      'two beats': _series(Rng(1), 2, 0),
      'three beats': _series(Rng(2), 3, 0),
      '30 beats (29 diffs, acf1 absent)': _series(Rng(3), 30, 0, gapP: 0),
      '31 beats (30 diffs, acf1 present)': _series(Rng(4), 31, 0, gapP: 0),
      '60 smooth beats, no gaps': _series(Rng(5), 60, 0, gapP: 0),
      '300 white-noise beats (jitter floor nulls rmssd and pnn50)':
          _series(Rng(6), 300, 1, gapP: 0),
      'constant 1000 ms, 400 beats (zero variance, bin edge at beat 300)':
          _constant(400, 1000),
      'constant 2000 ms, 400 beats (3 bins)': _constant(400, 2000),
      'slow beats spanning many bins': _series(Rng(7), 380, 2, gapP: .02),
      'many holes': _series(Rng(8), 200, 0, gapP: .3),
      'a hole of several bins': [
        ..._series(Rng(9), 40, 0, gapP: 0),
        (nnMs: 900.0, timeMs: _t0 + 40 * 800 + 900000),
        (nnMs: 910.0, timeMs: _t0 + 40 * 800 + 900910),
        (nnMs: 905.0, timeMs: _t0 + 40 * 800 + 901815),
      ],
    };

    named.forEach((name, beats) {
      test('$name: gap aware matches hrvTime', () {
        _expectParity(_agg(beats).run(beats),
            _expected(beats, gapAware: true), name);
      });
      test('$name: gapAware false matches hrvTime without times', () {
        _expectParity(_agg(beats, gapAware: false).run(beats),
            _expected(beats, gapAware: false), name);
      });
    });

    test('fewer than two beats: nBeats set, everything else null', () {
      for (final n in [0, 1]) {
        final beats = _series(Rng(n), n, 0);
        final v = _agg(beats).run(beats);
        expect(v.nBeats, n);
        expect(_fields(v), everyElement(isNull));
        final w = _agg(beats, gapAware: false).run(beats);
        expect(w.nBeats, n);
        expect(_fields(w), everyElement(isNull));
      }
    });

    test('hand-worked: nn 800, 810, 790 contiguous', () {
      final beats = <Beat>[
        (nnMs: 800.0, timeMs: 1000.0),
        (nnMs: 810.0, timeMs: 1810.0),
        (nnMs: 790.0, timeMs: 2600.0),
      ];
      final v = HrvTimeAggregator(originMs: 1000.0).run(beats);
      expect(v.nBeats, 3);
      // diffs 10, -20 -> rmssd sqrt((100+400)/2)
      expect(v.rmssd, closeTo(15.811388300841896, 1e-9));
      expect(v.pnn50, 0.0);
      expect(v.sdnn, closeTo(10.0, 1e-9));
      expect(v.diffAcf1, isNull); // fewer than 30 diffs
      expect(v.sdann, isNull); // a single 5-minute segment
      expect(v.sdnnIndex, isNull);
    });

    test('the hole rule: a gap above nn + 0.5 ms drops the seam difference',
        () {
      // Same nn values; in the second series beat 2 follows a long hole.
      final contiguous = <Beat>[
        (nnMs: 800.0, timeMs: 1000.0),
        (nnMs: 900.0, timeMs: 1900.0),
        (nnMs: 800.0, timeMs: 2700.0),
      ];
      final holed = <Beat>[
        (nnMs: 800.0, timeMs: 1000.0),
        (nnMs: 900.0, timeMs: 1900.0),
        (nnMs: 800.0, timeMs: 9700.0),
      ];
      final a = HrvTimeAggregator(originMs: 1000.0);
      expect(a.run(contiguous).rmssd, closeTo(100.0, 1e-9));
      expect(a.run(holed).rmssd, closeTo(100.0, 1e-9)); // only 800->900 counts
      // exactly nn + 0.5 is still contiguous; nn + 1.0 is a hole
      final edge = <Beat>[
        (nnMs: 800.0, timeMs: 1000.0),
        (nnMs: 900.0, timeMs: 1900.5),
        (nnMs: 800.0, timeMs: 2701.5),
      ];
      expect(a.run(edge).pnn50, 50.0); // 1 of 2 diffs: |100| > 50, |-100| > 50
    });
  });

  group('random parity (seeded)', () {
    test('gap aware, whole series', () {
      final r = Rng(0x4A11);
      for (var t = 0; t < 60; t++) {
        final n = r.nextBool(.1) ? r.intIn(0, 3) : r.intIn(0, 400);
        final beats = _series(r, n, r.intIn(0, 2), gapP: r.nextBool() ? .02 : .15);
        _expectParity(_agg(beats).run(beats), _expected(beats, gapAware: true),
            'case $t n=$n');
      }
    });

    test('gap aware, random chunkings', () {
      final r = Rng(0x4A12);
      for (var t = 0; t < 60; t++) {
        final n = r.intIn(0, 400);
        final beats = _series(r, n, r.intIn(0, 2), gapP: r.nextBool() ? .02 : .15);
        final want = _expected(beats, gapAware: true);
        final agg = _agg(beats);
        for (var c = 0; c < 4; c++) {
          final b = foldBounds(n, r.intIn(0, 8), r.nextInt(1 << 20));
          _expectParity(runChunked(agg, beats, b), want, 'case $t chunks $b');
        }
      }
    });

    test('gapAware false (times present but ignored), chunked', () {
      final r = Rng(0x4A13);
      for (var t = 0; t < 40; t++) {
        final n = r.intIn(0, 300);
        final beats = _series(r, n, r.intIn(0, 1));
        final want = _expected(beats, gapAware: false);
        final agg = _agg(beats, gapAware: false);
        _expectParity(agg.run(beats), want, 'case $t whole');
        final b = foldBounds(n, r.intIn(0, 8), r.nextInt(1 << 20));
        _expectParity(runChunked(agg, beats, b), want, 'case $t chunks $b');
      }
    });

    test('gapAware false with no times at all', () {
      final r = Rng(0x4A14);
      for (var t = 0; t < 30; t++) {
        final n = r.intIn(0, 250);
        final beats = _series(r, n, r.intIn(0, 1), withTimes: false);
        final want = _expected(beats, gapAware: false);
        final agg = HrvTimeAggregator(gapAware: false);
        final b = foldBounds(n, r.intIn(0, 8), r.nextInt(1 << 20));
        _expectParity(runChunked(agg, beats, b), want, 'case $t chunks $b');
      }
    });

    test('every single split point of a series with holes and several bins', () {
      final beats = _series(Rng(31), 120, 2, gapP: .1);
      final want = _expected(beats, gapAware: true);
      final agg = _agg(beats);
      for (var k = 0; k <= beats.length; k++) {
        final s = agg.combine(
            agg.foldRange(beats, 0, k), agg.foldRange(beats, k, beats.length));
        _expectParity(agg.finish(s), want, 'split at $k');
      }
    });

    test('splits that fall on a hole, a bin edge and a 5-minute boundary', () {
      // constant 1000 ms: beat 299 (index) sits exactly on the edge of bin 1.
      final beats = _constant(400, 1000);
      final want = _expected(beats, gapAware: true);
      final agg = _agg(beats);
      for (final k in [1, 2, 298, 299, 300, 301, 399]) {
        final s = agg.combine(
            agg.foldRange(beats, 0, k), agg.foldRange(beats, k, 400));
        _expectParity(agg.finish(s), want, 'split at $k');
      }
    });

    test('one beat per chunk', () {
      final beats = _series(Rng(41), 80, 0, gapP: .1);
      final want = _expected(beats, gapAware: true);
      final agg = _agg(beats);
      var acc = agg.foldRange(beats, 0, 1);
      for (var i = 1; i < beats.length; i++) {
        acc = agg.combine(acc, agg.foldRange(beats, i, i + 1));
      }
      _expectParity(agg.finish(acc), want, 'singletons');
    });
  });

  group('laws', () {
    // All cases share one origin (_t0 + the first nn): a series starting at the
    // same instant, so a single instance is valid for all of them.
    List<List<Beat>> cases(int seed, {int count = 14, int maxN = 150}) {
      final r = Rng(seed);
      return [
        <Beat>[],
        _series(Rng(seed), 1, 0),
        [
          for (var i = 0; i < count; i++)
            _series(r, r.intIn(0, maxN), r.intIn(0, 2), gapP: .08),
        ].first,
        for (var i = 0; i < count; i++)
          _series(r, r.intIn(0, maxN), r.intIn(0, 2), gapP: .08),
      ];
    }

    test('gap aware is lawful (relTol 1e-9)', () {
      // Origin: the first beat time of each case. Cases start at different
      // first times only through their first nn, so group by origin.
      final all = cases(0x1A01);
      final byOrigin = <double?, List<List<Beat>>>{};
      for (final c in all) {
        (byOrigin[c.isEmpty ? null : c.first.timeMs] ??= []).add(c);
      }
      byOrigin.forEach((origin, group) {
        expectLawful(HrvTimeAggregator(originMs: origin), group, equals: _eqAll);
      });
    });

    test('gap aware with a shared origin is lawful', () {
      // Re-anchor every case so the first beat sits at the same time.
      final shifted = [
        for (final c in cases(0x1A02))
          if (c.isNotEmpty)
            [
              for (final b in c)
                (nnMs: b.nnMs, timeMs: b.timeMs! - c.first.timeMs! + 5000.0)
            ]
          else
            c,
      ];
      expectLawful(HrvTimeAggregator(originMs: 5000.0), shifted, equals: _eqAll);
    });

    test('gapAware false is lawful', () {
      expectLawful(HrvTimeAggregator(gapAware: false), cases(0x1A03),
          equals: _eqAll);
    });

    test('the harness catches nothing on a series with a single 5-min bin', () {
      final r = Rng(0x1A04);
      final c = [
        for (var i = 0; i < 6; i++) _series(r, r.intIn(0, 40), 0, gapP: 0.1),
      ];
      final byOrigin = <double?, List<List<Beat>>>{};
      for (final s in c) {
        (byOrigin[s.isEmpty ? null : s.first.timeMs] ??= []).add(s);
      }
      byOrigin.forEach((o, g) =>
          expectLawful(HrvTimeAggregator(originMs: o), g, equals: _eqAll));
    });
  });
}
