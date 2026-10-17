// AdjacentPairs: the inner aggregator sees every consecutive pair of the whole
// input, in order, including the pair that straddles a chunk boundary.

import 'package:openstrap_analytics/aggregate.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/fold_law_support.dart' show foldBounds;
import '../support/property.dart' show Rng;

/// Collects its input into a list (mutating state; combine consumes both).
class _Collect<T> extends Aggregator<List<T>, T, List<T>> {
  const _Collect();
  @override
  List<T> empty() => <T>[];
  @override
  List<T> add(List<T> s, T x) => s..add(x);
  @override
  List<T> combine(List<T> left, List<T> right) {
    left.addAll(right);
    right.clear();
    return left;
  }

  @override
  List<T> finish(List<T> s) => List<T>.of(s);
}

typedef _P = (int, int);
typedef _PP = (_P, _P);

AdjacentPairs<int, dynamic, List<_P>> _pairs() =>
    AdjacentPairs<int, dynamic, List<_P>>(_Collect<_P>());

AdjacentPairs<int, dynamic, List<_PP>> _lag2() =>
    AdjacentPairs<int, dynamic, List<_PP>>(
        AdjacentPairs<_P, dynamic, List<_PP>>(_Collect<_PP>()));

List<_P> _batchPairs(List<int> xs) =>
    [for (var i = 1; i < xs.length; i++) (xs[i - 1], xs[i])];

List<_PP> _batchLag2(List<int> xs) => [
      for (var i = 2; i < xs.length; i++)
        ((xs[i - 2], xs[i - 1]), (xs[i - 1], xs[i]))
    ];

void main() {
  // Distinct values so a misplaced pair is visible.
  List<int> seq(int n) => [for (var i = 0; i < n; i++) i * 7 + 3];

  group('pair stream', () {
    test('unchunked run is the batch consecutive-pair list', () {
      for (final n in [0, 1, 2, 3, 10, 50]) {
        expect(_pairs().run(seq(n)), _batchPairs(seq(n)), reason: 'n=$n');
      }
    });

    test('empty and singleton inputs have no pairs', () {
      expect(_pairs().run(<int>[]), isEmpty);
      expect(_pairs().run([5]), isEmpty);
    });

    test('every single split point gives the same stream', () {
      final xs = seq(12);
      final a = _pairs();
      for (var k = 0; k <= xs.length; k++) {
        final s = a.combine(a.foldRange(xs, 0, k), a.foldRange(xs, k, xs.length));
        expect(a.finish(s), _batchPairs(xs), reason: 'split at $k');
      }
    });

    test('random chunkings (including empty chunks) give the same stream', () {
      final r = Rng(2024);
      for (var t = 0; t < 60; t++) {
        final xs = seq(r.intIn(0, 40));
        final b = foldBounds(xs.length, r.intIn(0, 8), r.nextInt(1 << 20));
        expect(runChunked(_pairs(), xs, b), _batchPairs(xs), reason: '$b');
      }
    });

    test('one element per chunk', () {
      final xs = seq(9);
      final a = _pairs();
      var acc = a.foldRange(xs, 0, 1);
      for (var i = 1; i < xs.length; i++) {
        acc = a.combine(acc, a.foldRange(xs, i, i + 1));
      }
      expect(a.finish(acc), _batchPairs(xs));
    });

    test('combine right-nested gives the same stream', () {
      final xs = seq(9);
      final a = _pairs();
      var acc = a.foldRange(xs, 8, 9);
      for (var i = 7; i >= 0; i--) {
        acc = a.combine(a.foldRange(xs, i, i + 1), acc);
      }
      expect(a.finish(acc), _batchPairs(xs));
    });
  });

  group('empty and singleton chunks around seams', () {
    test('empty chunks between non-empty ones do not lose the straddling pair',
        () {
      final a = _pairs();
      final xs = [1, 2, 3, 4];
      final s = a.combine(
          a.combine(a.foldRange(xs, 0, 2), a.foldRange(xs, 2, 2)),
          a.foldRange(xs, 2, 4));
      expect(a.finish(s), [(1, 2), (2, 3), (3, 4)]);
    });

    test('empty on both ends', () {
      final a = _pairs();
      final xs = [1, 2, 3];
      final s = a.combine(
          a.combine(a.empty(), a.foldRange(xs, 0, 3)), a.empty());
      expect(a.finish(s), [(1, 2), (2, 3)]);
    });

    test('a singleton chunk joins both neighbours', () {
      final a = _pairs();
      final xs = [1, 2, 3, 4, 5];
      final s = a.combine(
          a.combine(a.foldRange(xs, 0, 2), a.foldRange(xs, 2, 3)),
          a.foldRange(xs, 3, 5));
      expect(a.finish(s), _batchPairs(xs));
    });

    test('two singletons make exactly one pair, one singleton none', () {
      final a = _pairs();
      expect(a.finish(a.combine(a.fold([1]), a.fold([2]))), [(1, 2)]);
      expect(a.finish(a.combine(a.fold([1]), a.empty())), isEmpty);
      expect(a.finish(a.combine(a.empty(), a.fold([1]))), isEmpty);
      expect(a.finish(a.combine(a.empty(), a.empty())), isEmpty);
    });

    test('runs of empty chunks in the middle', () {
      final a = _pairs();
      final xs = [10, 20, 30];
      var acc = a.fold([xs[0]]);
      for (var i = 0; i < 4; i++) {
        acc = a.combine(acc, a.empty());
      }
      acc = a.combine(acc, a.fold([xs[1], xs[2]]));
      expect(a.finish(acc), _batchPairs(xs));
    });
  });

  group('nested AdjacentPairs is lag-2 context', () {
    test('unchunked run is the batch overlapping-triple list', () {
      for (final n in [0, 1, 2, 3, 4, 10, 40]) {
        expect(_lag2().run(seq(n)), _batchLag2(seq(n)), reason: 'n=$n');
      }
    });

    test('every single split point', () {
      final xs = seq(10);
      final a = _lag2();
      for (var k = 0; k <= xs.length; k++) {
        final s = a.combine(a.foldRange(xs, 0, k), a.foldRange(xs, k, xs.length));
        expect(a.finish(s), _batchLag2(xs), reason: 'split at $k');
      }
    });

    test('random chunkings with empty and singleton chunks', () {
      final r = Rng(77);
      for (var t = 0; t < 60; t++) {
        final xs = seq(r.intIn(0, 40));
        final b = foldBounds(xs.length, r.intIn(0, 8), r.nextInt(1 << 20),
            special: [0, 1, 2, 3]);
        expect(runChunked(_lag2(), xs, b), _batchLag2(xs), reason: '$b');
      }
    });

    test('all chunks singletons', () {
      final xs = seq(8);
      final a = _lag2();
      var acc = a.foldRange(xs, 0, 1);
      for (var i = 1; i < xs.length; i++) {
        acc = a.combine(acc, a.foldRange(xs, i, i + 1));
      }
      expect(a.finish(acc), _batchLag2(xs));
    });
  });

  group('laws', () {
    final cases = randomCases<int>(5, (r) => r.intIn(0, 99), maxLen: 30);

    test('pair collector is lawful', () {
      expectLawful(_pairs(), cases, equals: _same);
    });

    test('lag-2 collector is lawful', () {
      expectLawful(_lag2(), cases, equals: _same);
    });

    test('a sum of absolute successive differences is lawful', () {
      final a = AdjacentPairs<int, dynamic, int>(
          IntSum<(int, int)>((p) => (p.$2 - p.$1).abs()));
      expectLawful(a, cases);
      expect(a.run([1, 5, 2, 2, 10]), 4 + 3 + 0 + 8);
    });

    test('composes with where and both', () {
      final a = both(
          AdjacentPairs<int, dynamic, int>(Count<(int, int)>()),
          Count<int>());
      expect(a.run([4, 5, 6]), (2, 3));
      expectLawful(a, cases);
    });
  });
}

bool _same<T>(T a, T b) => a.toString() == b.toString();
