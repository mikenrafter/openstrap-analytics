// hrvTimeComposed (assembled from lawful building blocks) must agree with
// hrvTime() and with the hand-written HrvTimeAggregator for any beat series and
// any chunking, and must itself obey the aggregator laws.

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/fold_law_support.dart' show foldBounds;
import '../support/hrv_beats.dart';
import '../support/property.dart' show Rng;

Aggregator<dynamic, Beat, HrvTime> _composed(List<Beat> beats,
        {bool gapAware = true}) =>
    hrvTimeComposed(
        originMs: gapAware && beats.isNotEmpty ? beats.first.timeMs : null,
        gapAware: gapAware);

HrvTimeAggregator _hand(List<Beat> beats, {bool gapAware = true}) =>
    HrvTimeAggregator(
        originMs: gapAware && beats.isNotEmpty ? beats.first.timeMs : null,
        gapAware: gapAware);

/// Composed vs hrvTime and vs the hand state, whole and chunked.
void _checkAll(List<Beat> beats, String tag,
    {bool gapAware = true, List<int>? bounds}) {
  final want = hrvExpected(beats, gapAware: gapAware);
  final c = _composed(beats, gapAware: gapAware);
  final h = _hand(beats, gapAware: gapAware);
  expectHrvParity(c.run(beats), want, '$tag whole vs hrvTime');
  expectHrvParity(c.run(beats), h.run(beats), '$tag whole vs hand');
  if (bounds != null) {
    expectHrvParity(runChunked(c, beats, bounds), want, '$tag $bounds vs hrvTime');
    expectHrvParity(
        runChunked(c, beats, bounds), runChunked(h, beats, bounds),
        '$tag $bounds vs hand');
  }
}

/// [segments] runs of 12 beats alternating 860/800 ms, each starting at 860,
/// with a 5 s hole between runs. Inside a run the diffs alternate -60/+60 (diff
/// acf strongly negative). Run k ends with a -60 diff and run k+1 opens with a
/// -60 diff, so a lag pair formed across the hole would be (-60, -60), a
/// positive product that drags acf1 up.
List<Beat> _alternatingRuns(int segments) {
  final out = <Beat>[];
  var t = hrvT0;
  for (var s = 0; s < segments; s++) {
    for (var i = 0; i < 12; i++) {
      final nn = i.isEven ? 860.0 : 800.0;
      t += nn + (s > 0 && i == 0 ? 5000 : 0);
      out.add((nnMs: nn, timeMs: t));
    }
  }
  return out;
}

void main() {
  group('named series', () {
    final named = <String, List<Beat>>{
      'no beats': [],
      'one beat': [(nnMs: 800.0, timeMs: hrvT0 + 800)],
      'two beats': hrvSeries(Rng(1), 2, 0),
      'three beats': hrvSeries(Rng(2), 3, 0),
      '30 beats (acf1 absent)': hrvSeries(Rng(3), 30, 0, gapP: 0),
      '31 beats (acf1 present)': hrvSeries(Rng(4), 31, 0, gapP: 0),
      '60 smooth beats': hrvSeries(Rng(5), 60, 0, gapP: 0),
      '300 white-noise beats': hrvSeries(Rng(6), 300, 1, gapP: 0),
      'constant 1000 ms, 400 beats': hrvConstant(400, 1000),
      'constant 2000 ms, 400 beats': hrvConstant(400, 2000),
      'slow beats spanning many bins': hrvSeries(Rng(7), 380, 2, gapP: .02),
      'many holes': hrvSeries(Rng(8), 200, 0, gapP: .3),
      'alternating runs': _alternatingRuns(4),
    };
    named.forEach((name, beats) {
      test('$name: gap aware', () => _checkAll(beats, name));
      test('$name: gapAware false',
          () => _checkAll(beats, name, gapAware: false));
    });

    test('fewer than two beats: nBeats set, the rest null', () {
      for (final n in [0, 1]) {
        final beats = hrvSeries(Rng(n), n, 0);
        for (final ga in [true, false]) {
          final v = _composed(beats, gapAware: ga).run(beats);
          expect(v.nBeats, n);
          expect(hrvFields(v), everyElement(isNull));
        }
      }
    });
  });

  group('random parity (seeded)', () {
    test('gap aware, whole and chunked', () {
      final r = Rng(0x5C11);
      for (var t = 0; t < 40; t++) {
        final n = r.nextBool(.1) ? r.intIn(0, 3) : r.intIn(0, 400);
        final beats =
            hrvSeries(r, n, r.intIn(0, 2), gapP: r.nextBool() ? .02 : .15);
        _checkAll(beats, 'case $t n=$n',
            bounds: foldBounds(n, r.intIn(0, 8), r.nextInt(1 << 20)));
      }
    });

    test('gapAware false (times present but ignored), chunked', () {
      final r = Rng(0x5C12);
      for (var t = 0; t < 30; t++) {
        final n = r.intIn(0, 300);
        final beats = hrvSeries(r, n, r.intIn(0, 1));
        _checkAll(beats, 'case $t',
            gapAware: false,
            bounds: foldBounds(n, r.intIn(0, 8), r.nextInt(1 << 20)));
      }
    });

    test('gapAware false with no times at all', () {
      final r = Rng(0x5C13);
      for (var t = 0; t < 20; t++) {
        final n = r.intIn(0, 250);
        final beats = hrvSeries(r, n, r.intIn(0, 1), withTimes: false);
        final want = hrvExpected(beats, gapAware: false);
        final c = hrvTimeComposed(gapAware: false);
        final b = foldBounds(n, r.intIn(0, 8), r.nextInt(1 << 20));
        expectHrvParity(runChunked(c, beats, b), want, 'case $t $b');
      }
    });

    test('every single split point of a series with holes and several bins',
        () {
      final beats = hrvSeries(Rng(31), 120, 2, gapP: .1);
      final want = hrvExpected(beats, gapAware: true);
      final c = _composed(beats);
      for (var k = 0; k <= beats.length; k++) {
        final s = c.combine(
            c.foldRange(beats, 0, k), c.foldRange(beats, k, beats.length));
        expectHrvParity(c.finish(s), want, 'split at $k');
      }
    });

    test('splits on a bin edge', () {
      final beats = hrvConstant(400, 1000);
      final want = hrvExpected(beats, gapAware: true);
      final c = _composed(beats);
      for (final k in [1, 2, 298, 299, 300, 301, 399]) {
        final s = c.combine(c.foldRange(beats, 0, k), c.foldRange(beats, k, 400));
        expectHrvParity(c.finish(s), want, 'split at $k');
      }
    });

    test('one beat per chunk', () {
      final beats = hrvSeries(Rng(41), 80, 0, gapP: .1);
      final c = _composed(beats);
      var acc = c.foldRange(beats, 0, 1);
      for (var i = 1; i < beats.length; i++) {
        acc = c.combine(acc, c.foldRange(beats, i, i + 1));
      }
      expectHrvParity(
          c.finish(acc), hrvExpected(beats, gapAware: true), 'singletons');
    });
  });

  group('gaps', () {
    test('lag pairs are not formed across a gap', () {
      final beats = _alternatingRuns(4); // 44 diffs, seams dropped
      final want = hrvExpected(beats, gapAware: true);
      expect(want.diffAcf1, isNotNull);
      // The scenario discriminates: bridging the gap (ignoring times) moves acf1.
      final bridged = hrvExpected(beats, gapAware: false);
      expect((bridged.diffAcf1! - want.diffAcf1!).abs(), greaterThan(.02));
      final got = _composed(beats).run(beats);
      expect(got.diffAcf1, closeTo(want.diffAcf1!, 1e-9));
      // And in chunks cut on and around the seams.
      final c = _composed(beats);
      for (final k in [11, 12, 13, 23, 24, 25, 35, 36, 37]) {
        final s = c.combine(
            c.foldRange(beats, 0, k), c.foldRange(beats, k, beats.length));
        expect(c.finish(s).diffAcf1, closeTo(want.diffAcf1!, 1e-9),
            reason: 'split at $k');
      }
    });

    test('the hole rule: nn + 0.5 ms is contiguous, nn + 1.0 ms is a hole', () {
      final edge = <Beat>[
        (nnMs: 800.0, timeMs: 1000.0),
        (nnMs: 900.0, timeMs: 1900.5), // dt 900.5 = nn + 0.5
        (nnMs: 870.0, timeMs: 2771.0), // dt 870.5 = nn + 0.5
      ];
      final hole = <Beat>[...edge.take(2), (nnMs: 870.0, timeMs: 2772.0)];
      final a = hrvTimeComposed(originMs: 1000.0);
      expect(a.run(edge).pnn50, 50.0); // diffs +100, -30
      expect(a.run(hole).pnn50, 100.0); // the -30 is dropped
      expect(a.run(edge).nBeats, 3);
      expect(a.run(hole).nBeats, 3);
    });

    test('hand-worked: nn 800, 810, 790 contiguous', () {
      final beats = <Beat>[
        (nnMs: 800.0, timeMs: 1000.0),
        (nnMs: 810.0, timeMs: 1810.0),
        (nnMs: 790.0, timeMs: 2600.0),
      ];
      final v = hrvTimeComposed(originMs: 1000.0).run(beats);
      expect(v.rmssd, closeTo(15.811388300841896, 1e-9));
      expect(v.sdnn, closeTo(10.0, 1e-9));
      expect(v.pnn50, 0.0);
      expect(v.diffAcf1, isNull);
      expect(v.sdann, isNull);
    });
  });

  group('laws', () {
    List<List<Beat>> cases(int seed, {int count = 14, int maxN = 150}) {
      final r = Rng(seed);
      return [
        <Beat>[],
        hrvSeries(Rng(seed), 1, 0),
        for (var i = 0; i < count; i++)
          hrvSeries(r, r.intIn(0, maxN), r.intIn(0, 2), gapP: .08),
      ];
    }

    test('gap aware is lawful (cases grouped by origin)', () {
      final byOrigin = <double?, List<List<Beat>>>{};
      for (final c in cases(0x5D01)) {
        (byOrigin[c.isEmpty ? null : c.first.timeMs] ??= []).add(c);
      }
      byOrigin.forEach((origin, group) {
        expectLawful(hrvTimeComposed(originMs: origin), group, equals: hrvEqAll);
      });
    });

    test('gap aware with a shared origin is lawful', () {
      final shifted = [
        for (final c in cases(0x5D02))
          if (c.isNotEmpty)
            [
              for (final b in c)
                (nnMs: b.nnMs, timeMs: b.timeMs! - c.first.timeMs! + 5000.0)
            ]
          else
            c,
      ];
      expectLawful(hrvTimeComposed(originMs: 5000.0), shifted,
          equals: hrvEqAll);
    });

    test('gapAware false is lawful', () {
      expectLawful(hrvTimeComposed(gapAware: false), cases(0x5D03),
          equals: hrvEqAll);
    });

    test('alternating runs are lawful at every split', () {
      final beats = _alternatingRuns(4);
      expectLawful(hrvTimeComposed(originMs: beats.first.timeMs), [beats],
          equals: hrvEqAll);
    });
  });
}
