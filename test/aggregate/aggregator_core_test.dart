// Aggregator core: fold / foldRange / run, the combinators, and every
// primitive on small known inputs plus the laws on random seeded inputs.

import 'dart:math' as math;

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart' show IntHistogram, RunningMoments;
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/fold_law_support.dart' show foldBounds;
import '../support/property.dart' show Rng;

List<Object?> _momentFields(RunningMoments m) =>
    [m.count, m.mean, m.sampleSd, m.populationSd];

List<Object?> _histFields(IntHistogram h) =>
    [h.count, h.distinct, h.median, h.percentile(10), h.percentile(90)];

bool _listEq<T>(List<T> a, List<T> b) => a.toString() == b.toString();

void main() {
  final ints = randomCases<int>(1, (r) => r.intIn(-1000, 1000));
  final smallInts = randomCases<int>(2, (r) => r.intIn(0, 9));
  final doubles = randomCases<double>(
      3, (r) => (r.nextDouble() - .5) * math.pow(10, r.intIn(0, 8)));
  final pos = randomCases<double>(4, (r) => 1 + r.nextDouble() * 100);

  group('fold, foldRange, run', () {
    final sum = IntSum<int>(_id);

    test('run of nothing is the identity result', () {
      expect(sum.run(<int>[]), 0);
      expect(Count<int>().run(<int>[]), 0);
    });

    test('run folds in order and finishes', () {
      expect(sum.run([1, 2, 3, 4]), 10);
      expect(Last<int>().run([1, 2, 3]), 3);
      expect(First<int>().run([1, 2, 3]), 1);
    });

    test('run accepts any Iterable', () {
      expect(sum.run(Iterable<int>.generate(5, (i) => i + 1)), 15);
      expect(sum.run({1, 2, 3}), 6);
    });

    test('run equals finish(fold)', () {
      final xs = [4, 5, 6];
      expect(sum.finish(sum.fold(xs)), sum.run(xs));
    });

    test('foldRange folds the half-open slice', () {
      final xs = [1, 2, 3, 4, 5];
      expect(sum.finish(sum.foldRange(xs, 1, 4)), 9);
      expect(sum.finish(sum.foldRange(xs, 0, 5)), 15);
      expect(sum.finish(sum.foldRange(xs, 2, 2)), 0);
      expect(sum.finish(sum.foldRange(xs, 5, 5)), 0);
    });

    test('foldRange slices combine back to the whole', () {
      final xs = [for (var i = 1; i <= 20; i++) i];
      for (var k = 0; k <= xs.length; k++) {
        final s = sum.combine(sum.foldRange(xs, 0, k), sum.foldRange(xs, k, 20));
        expect(sum.finish(s), 210, reason: 'split at $k');
      }
    });

    test('empty() returns independent states', () {
      final a = sum.empty(), b = sum.empty();
      sum.add(a, 5);
      expect(sum.finish(b), 0);
      final m = Moments<double>(_idD);
      final ma = m.empty(), mb = m.empty();
      m.add(ma, 3.0);
      expect(m.finish(mb).count, 0);
      final h = Histogram<int>(_id);
      final ha = h.empty(), hb = h.empty();
      h.add(ha, 3);
      expect(h.finish(hb).count, 0);
    });

    test('finish does not mutate the state: finish twice, keep adding', () {
      final m = Moments<double>(_idD);
      var s = m.fold([1.0, 2.0, 3.0]);
      final first = _momentFields(m.finish(s));
      expect(_momentFields(m.finish(s)), first);
      s = m.add(s, 10.0);
      expect(m.finish(s).count, 4);
      expect(m.finish(m.fold([1.0, 2.0, 3.0, 10.0])).mean, m.finish(s).mean);

      final h = Histogram<int>(_id);
      var hs = h.fold([1, 2, 2]);
      expect(h.finish(hs).count, 3);
      expect(h.finish(hs).count, 3);
      hs = h.add(hs, 9);
      expect(h.finish(hs).count, 4);
    });
  });

  group('combinators', () {
    test('map transforms the result only', () {
      final a = IntSum<int>(_id).map((n) => 'n=$n');
      expect(a.run([1, 2, 3]), 'n=6');
      expect(a.run(<int>[]), 'n=0');
      expectLawful(a, ints);
    });

    test('map composes', () {
      final a = Count<int>().map((n) => n * 2).map((n) => n + 1);
      expect(a.run([7, 7, 7]), 7);
    });

    test('contramap changes the input type', () {
      final a = IntSum<int>(_id).contramap<String>((s) => s.length);
      expect(a.run(['a', 'bb', 'ccc']), 6);
      final b = Max<double>(_idD).contramap<(int, double)>((p) => p.$2);
      expect(b.run([(1, 2.5), (2, 9.0), (3, 1.0)]), 9.0);
    });

    test('where filters the input before the aggregator sees it', () {
      final even = IntSum<int>(_id).where((x) => x.isEven);
      expect(even.run([1, 2, 3, 4, 5, 6]), 12);
      expect(even.run([1, 3]), 0);
      expectLawful(even, ints);
    });

    test('where applies across a seam', () {
      final even = Count<int>().where((x) => x.isEven);
      final xs = [2, 3, 4, 5, 6];
      final s = even.combine(even.foldRange(xs, 0, 2), even.foldRange(xs, 2, 5));
      expect(even.finish(s), 3);
    });

    test('where then map then contramap compose and stay lawful', () {
      final a = IntSum<int>(_id)
          .where((x) => x > 0)
          .map((n) => n * 10)
          .contramap<int>((x) => x - 5);
      expect(a.run([1, 6, 10, 3]), (1 + 5) * 10);
      expectLawful(a, ints);
    });

    test('both runs two aggregators over the same input', () {
      final a = both(Count<int>(), IntSum<int>(_id));
      expect(a.run([3, 4, 5]), (3, 12));
      expect(a.run(<int>[]), (0, 0));
    });

    test('both nests and stays lawful', () {
      final a = both(
          both(Count<int>(), IntSum<int>(_id)),
          Max<int>(_id));
      expect(a.run([3, 9, 5]), ((3, 17), 9));
      expectLawful(a, ints);
    });

    test('both gives each side an independent fresh state', () {
      final a = both(Count<int>(), IntSum<int>(_id));
      final p = a.add(a.empty(), 5);
      final q = a.empty();
      expect(a.finish(q), (0, 0));
      expect(a.finish(p), (1, 5));
    });

    test('Pair is a mutable holder', () {
      final p = Pair<int, String>(1, 'a');
      p.first = 2;
      p.second = 'b';
      expect((p.first, p.second), (2, 'b'));
    });

    test('both combines across a seam', () {
      final a = both(First<int>(), Last<int>());
      final xs = [1, 2, 3, 4];
      final s = a.combine(a.foldRange(xs, 0, 2), a.foldRange(xs, 2, 4));
      expect(a.finish(s), (1, 4));
    });
  });

  group('primitives: known values', () {
    test('Count', () {
      expect(Count<String>().run(['a', 'b', 'c']), 3);
      expect(Count<String>().run([]), 0);
    });

    test('IntSum applies the projection', () {
      expect(IntSum<String>((s) => s.length).run(['ab', 'c', '']), 3);
      expect(IntSum<int>(_id).run([-5, 5, 7]), 7);
    });

    test('DoubleSum: empty is 0.0 and plain sums are right', () {
      expect(DoubleSum<double>(_idD).run([]), 0.0);
      expect(DoubleSum<double>(_idD).run([1.5, 2.5, -1.0]), 3.0);
    });

    test('DoubleSum is compensated (ten times 0.1 is exactly 1.0)', () {
      expect(DoubleSum<int>((_) => 0.1).run(List.filled(10, 0)), 1.0);
    });

    test('DoubleSum is Neumaier compensated (big, small, minus big)', () {
      expect(DoubleSum<double>(_idD).run([1e16, 1.0, -1e16]), 1.0);
      expect(DoubleSum<double>(_idD).run([1.0, 1e16, -1e16]), 1.0);
    });

    test('DoubleSum compensation survives chunking', () {
      final a = DoubleSum<double>(_idD);
      final xs = [1e16, 1.0, -1e16, 1.0];
      for (var k = 0; k <= xs.length; k++) {
        final s = a.combine(a.foldRange(xs, 0, k), a.foldRange(xs, k, 4));
        expect(a.finish(s), 2.0, reason: 'split at $k');
      }
    });

    test('Min and Max, null when empty', () {
      final mn = Min<int>(_id), mx = Max<int>(_id);
      expect(mn.run([3, -1, 2]), -1);
      expect(mx.run([3, -1, 2]), 3);
      expect(mn.run(<int>[]), isNull);
      expect(mx.run(<int>[]), isNull);
      expect(mn.run([7]), 7);
      expect(Min<double>(_idD).run([2.5, 1.5]), 1.5);
      expect(Max<double>(_idD).run([2.5, 1.5]), 2.5);
      expect(mx.run([-4, -9]), -4);
    });

    test('Min and Max use the projection and return the number', () {
      expect(Min<String>((s) => s.length).run(['abc', 'a', 'ab']), 1);
      expect(Max<String>((s) => s.length).run(['abc', 'a', 'ab']), 3);
    });

    test('Min and Max with an empty side on either end of a seam', () {
      final mx = Max<int>(_id);
      expect(mx.finish(mx.combine(mx.empty(), mx.fold([4, 2]))), 4);
      expect(mx.finish(mx.combine(mx.fold([4, 2]), mx.empty())), 4);
      expect(mx.finish(mx.combine(mx.empty(), mx.empty())), isNull);
    });

    test('First and Last, null when empty', () {
      expect(First<String>().run(['x', 'y', 'z']), 'x');
      expect(Last<String>().run(['x', 'y', 'z']), 'z');
      expect(First<String>().run([]), isNull);
      expect(Last<String>().run([]), isNull);
    });

    test('First and Last keep a seam in order, skipping empty chunks', () {
      final f = First<int>(), l = Last<int>();
      final xs = [10, 20, 30];
      final fs = f.combine(f.combine(f.foldRange(xs, 0, 0), f.foldRange(xs, 0, 2)),
          f.foldRange(xs, 2, 3));
      expect(f.finish(fs), 10);
      final ls = l.combine(l.combine(l.foldRange(xs, 0, 2), l.foldRange(xs, 2, 3)),
          l.foldRange(xs, 3, 3));
      expect(l.finish(ls), 30);
    });

    test('Moments on a textbook sample', () {
      final m = Moments<double>(_idD)
          .run([2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]);
      expect(m.count, 8);
      expect(m.mean, closeTo(5.0, 1e-12));
      expect(m.populationSd, closeTo(2.0, 1e-12));
      expect(m.sampleSd, closeTo(math.sqrt(32 / 7), 1e-12));
    });

    test('Moments: empty and one value', () {
      final e = Moments<double>(_idD).run([]);
      expect((e.count, e.mean, e.sampleSd), (0, null, null));
      final one = Moments<double>(_idD).run([4.0]);
      expect((one.count, one.mean, one.sampleSd), (1, 4.0, null));
    });

    test('Moments merged across a seam matches the whole', () {
      final a = Moments<double>(_idD);
      final xs = [for (var i = 0; i < 30; i++) math.sin(i) * 100 + 500];
      final whole = a.run(xs);
      for (final k in [0, 1, 15, 29, 30]) {
        final r = a.finish(a.combine(a.foldRange(xs, 0, k), a.foldRange(xs, k, 30)));
        expect(r.count, whole.count);
        expect(r.mean, closeTo(whole.mean!, 1e-9));
        expect(r.sampleSd, closeTo(whole.sampleSd!, 1e-9));
      }
    });

    test('Histogram counts, distinct, median', () {
      final h = Histogram<int>(_id).run([3, 1, 3, 2]);
      expect(h.count, 4);
      expect(h.distinct, 3);
      expect(h.median, 2.5);
      expect(Histogram<int>(_id).run(<int>[]).median, isNull);
    });

    test('Histogram uses the projection and merges across a seam', () {
      final a = Histogram<String>((s) => s.length);
      final xs = ['a', 'bb', 'ccc', 'bb', 'a', 'a'];
      final r = a.finish(a.combine(a.foldRange(xs, 0, 3), a.foldRange(xs, 3, 6)));
      expect(_histFields(r), _histFields(a.run(xs)));
      expect(r.count, 6);
      expect(r.distinct, 3);
    });
  });

  group('primitives: laws on random cases', () {
    test('Count', () => expectLawful(Count<int>(), ints));
    test('IntSum', () => expectLawful(IntSum<int>(_id), ints));
    test('IntSum with a projection',
        () => expectLawful(IntSum<int>((x) => x * x), ints));
    test('Min', () => expectLawful(Min<int>(_id), ints));
    test('Max', () => expectLawful(Max<int>(_id), ints));
    test('Min on doubles', () => expectLawful(Min<double>(_idD), doubles));
    test('First', () => expectLawful(First<int>(), ints));
    test('Last', () => expectLawful(Last<int>(), ints));

    test('DoubleSum (tolerance)', () {
      expectLawful(DoubleSum<double>(_idD), doubles,
          equals: fieldsEqual<double>((x) => [x], relTol: 1e-12, absTol: 1e-6));
    });

    test('Moments (tolerance)', () {
      expectLawful(Moments<double>(_idD), pos,
          equals: fieldsEqual<RunningMoments>(_momentFields,
              relTol: 1e-9, absTol: 1e-9));
    });

    test('Histogram (exact)', () {
      expectLawful(Histogram<int>(_id), smallInts,
          equals: fieldsEqual<IntHistogram>(_histFields));
    });

    test('both of primitives with mixed result types', () {
      expectLawful(
          both(Min<int>(_id), Histogram<int>(_id))
              .map((r) => [r.$1, ..._histFields(r.$2)]),
          smallInts,
          equals: _listEq);
    });
  });

  group('chunked runs agree with the unchunked run', () {
    test('random chunk bounds, sum and compound aggregator', () {
      final agg = both(IntSum<int>(_id), Max<int>(_id));
      final r = Rng(99);
      for (final xs in ints) {
        final want = agg.run(xs);
        for (var t = 0; t < 8; t++) {
          final b = foldBounds(xs.length, r.intIn(0, 6), r.nextInt(1 << 20));
          expect(runChunked(agg, xs, b), want, reason: '$b');
        }
      }
    });
  });
}

int _id(int x) => x;
double _idD(double x) => x;
