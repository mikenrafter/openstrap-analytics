// GroupBy: routes each input to an inner aggregator under key(input); combine
// merges per key; finish maps every key through inner.finish.

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart' show RunningMoments;
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/fold_law_support.dart' show foldBounds;
import '../support/property.dart' show Rng;

int _id(int x) => x;
int _mod3(int x) => x % 3;
int _mod2(int x) => x % 2;
double _d(int x) => x.toDouble();

/// Exact deep equality for (nested) maps; Map == is identity in Dart.
bool _mapsEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_mapsEqual(a[k], b[k])) return false;
    }
    return true;
  }
  return a == b;
}

List<Object?> _momentFields(Map<int, RunningMoments> m) {
  final keys = m.keys.toList()..sort();
  return [
    keys.length,
    for (final k in keys) ...[k, m[k]!.count, m[k]!.mean, m[k]!.sampleSd],
  ];
}

void main() {
  group('values', () {
    test('counts per key', () {
      final a = GroupBy<int, int, int, int>(_mod3, const Count<int>());
      expect(a.run([1, 2, 3, 4, 5, 6, 7]), {0: 2, 1: 3, 2: 2});
    });

    test('sums per key', () {
      final a = GroupBy<int, int, int, int>(_mod2, IntSum<int>(_id));
      expect(a.run([1, 2, 3, 4, 5]), {1: 9, 0: 6});
    });

    test('empty input gives an empty map', () {
      final a = GroupBy<int, int, int, int>(_mod3, const Count<int>());
      expect(a.run(<int>[]), isEmpty);
      expect(a.finish(a.empty()), <int, int>{});
    });

    test('a key that never occurs is absent', () {
      final a = GroupBy<int, int, int, int>(_mod3, const Count<int>());
      expect(a.run([3, 6]).keys, [0]);
    });
  });

  group('combine', () {
    final a = GroupBy<int, int, int, int>(_mod3, IntSum<int>(_id));

    test('disjoint keys are adopted', () {
      final s = a.combine(a.fold([3, 6]), a.fold([1, 4]));
      expect(a.finish(s), {0: 9, 1: 5});
    });

    test('overlapping keys merge with the inner combine', () {
      final s = a.combine(a.fold([1, 2, 3]), a.fold([4, 5, 6]));
      expect(a.finish(s), {0: 9, 1: 5, 2: 7});
    });

    test('mixed shared and one-sided keys', () {
      final s = a.combine(a.fold([1, 3]), a.fold([4, 5]));
      expect(a.finish(s), {0: 3, 1: 5, 2: 5});
    });

    test('combining with empty on either side changes nothing', () {
      final xs = [1, 2, 3, 4];
      expect(a.finish(a.combine(a.empty(), a.fold(xs))), a.run(xs));
      expect(a.finish(a.combine(a.fold(xs), a.empty())), a.run(xs));
    });
  });

  group('laws', () {
    final ints = randomCases<int>(0x6B01, (r) => r.intIn(-20, 20));

    test('GroupBy(key, Count) is lawful with exact equality', () {
      expectLawful(GroupBy<int, int, int, int>(_mod3, const Count<int>()), ints,
          equals: _mapsEqual);
    });

    test('GroupBy(key, IntSum) is lawful with exact equality', () {
      expectLawful(GroupBy<int, int, int, int>(_mod3, IntSum<int>(_id)), ints,
          equals: _mapsEqual);
    });

    test('nested GroupBy', () {
      final nested = GroupBy<int, int, Map<int, int>, Map<int, int>>(
          _mod2, GroupBy<int, int, int, int>(_mod3, IntSum<int>(_id)));
      expect(nested.run([1, 2, 3, 4, 5, 6]), {
        1: {1: 1, 0: 3, 2: 5},
        0: {2: 2, 1: 4, 0: 6},
      });
      expect(nested.run(<int>[]), isEmpty);
      expectLawful(nested, ints, equals: _mapsEqual);
    });

    test('tolerance-compared inner (Moments per key)', () {
      final g = GroupBy<int, int, RunningMoments, RunningMoments>(
          _mod3, Moments<int>(_d));
      final r = g.run([1, 2, 3, 4, 5, 10]);
      expect(r.keys.toSet(), {0, 1, 2});
      expect(r[1]!.count, 3);
      expect(r[1]!.mean, closeTo(5.0, 1e-12)); // (1+4+10)/3
      expect(r[1]!.sampleSd, closeTo(4.58257569495584, 1e-9));
      expectLawful(g, ints,
          equals: fieldsEqual<Map<int, RunningMoments>>(_momentFields,
              relTol: 1e-9, absTol: 1e-9));
    });

    test('random chunkings agree with the whole fold', () {
      final g = GroupBy<int, int, int, int>(_mod3, IntSum<int>(_id));
      final r = Rng(0x6B02);
      for (var t = 0; t < 40; t++) {
        final xs = [for (var i = r.intIn(0, 60); i > 0; i--) r.intIn(-9, 9)];
        final b = foldBounds(xs.length, r.intIn(0, 6), r.nextInt(1 << 20));
        expect(runChunked(g, xs, b), g.run(xs), reason: 'case $t chunks $b');
      }
    });
  });
}
