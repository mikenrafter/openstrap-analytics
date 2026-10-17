// The law harness itself: lawful aggregators pass, deliberately broken ones are
// caught under the right law name, and fieldsEqual compares as documented.

import 'package:openstrap_analytics/aggregate.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';

/// A correct sum over ints.
class _Sum extends Aggregator<int, int, int> {
  const _Sum();
  @override
  int empty() => 0;
  @override
  int add(int s, int x) => s + x;
  @override
  int combine(int left, int right) => left + right;
  @override
  int finish(int s) => s;
}

/// Sum whose identity is 1: breaks the identity laws.
class _SumFromOne extends _Sum {
  const _SumFromOne();
  @override
  int empty() => 1;
}

/// Combine drops the right side.
class _DropRight extends _Sum {
  const _DropRight();
  @override
  int combine(int left, int right) => left;
}

/// Mean kept as (mean, count); combine averages the two means unweighted.
class _UnweightedMean extends Aggregator<List<double>, int, double> {
  const _UnweightedMean();
  @override
  List<double> empty() => [0, 0];
  @override
  List<double> add(List<double> s, int x) {
    final n = s[1] + 1;
    return [s[0] + (x - s[0]) / n, n];
  }

  @override
  List<double> combine(List<double> l, List<double> r) {
    if (r[1] == 0) return l;
    if (l[1] == 0) return r;
    return [(l[0] + r[0]) / 2, l[1] + r[1]];
  }

  @override
  double finish(List<double> s) => s[0];
}

/// add counts 1 per element, but joining two NON-empty chunks adds a bonus, so
/// the add path and the combine path disagree. Identities still hold.
class _JoinBonus extends Aggregator<int, int, int> {
  const _JoinBonus();
  @override
  int empty() => 0;
  @override
  int add(int s, int x) => s + 1;
  @override
  int combine(int left, int right) =>
      left > 0 && right > 0 ? left + right + 1 : left + right;
  @override
  int finish(int s) => s;
}

/// Wrong only when exactly 3 elements meet exactly 2 (a split of a 5 list).
class _WrongAtThreeTwo extends Aggregator<List<int>, int, int> {
  const _WrongAtThreeTwo();
  @override
  List<int> empty() => [0, 0]; // sum, count
  @override
  List<int> add(List<int> s, int x) => [s[0] + x, s[1] + 1];
  @override
  List<int> combine(List<int> l, List<int> r) =>
      [l[0] + r[0] + (l[1] == 3 && r[1] == 2 ? 1000 : 0), l[1] + r[1]];
  @override
  int finish(List<int> s) => s[0];
}

/// A correct sum that consumes (poisons) both arguments in combine.
class _MutatingSum extends Aggregator<List<int>, int, int> {
  const _MutatingSum();
  @override
  List<int> empty() => [0];
  @override
  List<int> add(List<int> s, int x) {
    s[0] += x;
    return s;
  }

  @override
  List<int> combine(List<int> left, List<int> right) {
    left[0] += right[0];
    right[0] = -999999; // consumed
    return left;
  }

  @override
  int finish(List<int> s) => s[0];
}

/// Same, but wipes `left` too and returns a brand new state.
class _ConsumingSum extends Aggregator<List<int>, int, int> {
  const _ConsumingSum();
  @override
  List<int> empty() => [0];
  @override
  List<int> add(List<int> s, int x) {
    s[0] += x;
    return s;
  }

  @override
  List<int> combine(List<int> left, List<int> right) {
    final out = [left[0] + right[0]];
    left[0] = -1;
    right[0] = -1;
    return out;
  }

  @override
  int finish(List<int> s) => s[0];
}

Set<String> _laws(List<LawViolation> v) => {for (final x in v) x.law};

void main() {
  final cases = randomCases<int>(11, (r) => r.intIn(1, 50));

  group('lawful aggregators', () {
    test('a correct sum has no violations', () {
      expect(checkLaws(const _Sum(), cases), isEmpty);
    });
    test('a mutating combine is judged lawful when otherwise lawful', () {
      expect(checkLaws(const _MutatingSum(), cases), isEmpty);
      expect(checkLaws(const _ConsumingSum(), cases), isEmpty);
    });
    test('no cases is vacuously lawful', () {
      expect(checkLaws(const _Sum(), <List<int>>[]), isEmpty);
    });
    test('long cases are bounded by maxSplits and still pass', () {
      final long = [
        for (var i = 0; i < 300; i++) i,
      ];
      expect(checkLaws(const _Sum(), [long], maxSplits: 8), isEmpty);
    });
    test('expectLawful passes for a lawful aggregator and fails for a broken one',
        () {
      expectLawful(const _Sum(), cases);
      expect(() => expectLawful(const _DropRight(), cases),
          throwsA(isA<TestFailure>()));
    });
  });

  group('broken aggregators are caught', () {
    test('(a) non-identity empty fires the identity laws', () {
      final laws = _laws(checkLaws(const _SumFromOne(), cases));
      expect(laws, containsAll(['leftIdentity', 'rightIdentity']));
    });

    test('(b) combine that drops the right side fires split', () {
      final v = checkLaws(const _DropRight(), cases);
      expect(_laws(v), contains('split'));
      expect(v.every((x) => x.detail.isNotEmpty), isTrue);
    });

    test('(c) unweighted mean combine fires split or associativity', () {
      bool close(double a, double b) => (a - b).abs() < 1e-9;
      final laws = _laws(checkLaws(const _UnweightedMean(), cases, equals: close));
      expect(laws.intersection({'split', 'associativity'}), isNotEmpty);
    });

    test('(d) add inconsistent with combine fires singletons (identities hold)',
        () {
      final laws = _laws(checkLaws(const _JoinBonus(), cases));
      expect(laws, contains('singletons'));
      expect(laws, contains('split'));
      expect(laws, isNot(contains('leftIdentity')));
      expect(laws, isNot(contains('rightIdentity')));
    });

    test('every split point of a short case is tried', () {
      // Only the 3|2 split of a five-element list is wrong.
      final laws = _laws(checkLaws(const _WrongAtThreeTwo(), [
        [1, 2, 3, 4, 5]
      ]));
      expect(laws, contains('split'));
    });

    test('a lawful case alongside a broken one still reports the broken one',
        () {
      final v = checkLaws(const _DropRight(), [
        <int>[],
        [5],
        [1, 2, 3]
      ]);
      expect(_laws(v), contains('split'));
    });

    test('results are deterministic for a given seed', () {
      String render(List<LawViolation> v) =>
          v.map((x) => '${x.law}|${x.detail}').join('\n');
      final a = checkLaws(const _DropRight(), cases, seed: 5);
      final b = checkLaws(const _DropRight(), cases, seed: 5);
      expect(render(a), render(b));
    });

    test('a custom equals is honoured', () {
      // Everything is "equal", so even a broken aggregator passes.
      expect(checkLaws(const _DropRight(), cases, equals: (a, b) => true),
          isEmpty);
    });
  });

  group('fieldsEqual', () {
    List<Object?> same(List<Object?> x) => x;

    test('identical lists are equal; length mismatch is not', () {
      final eq = fieldsEqual<List<Object?>>(same);
      expect(eq([1, 'a', null], [1, 'a', null]), isTrue);
      expect(eq([1, 2], [1, 2, 3]), isFalse);
    });

    test('NaN equals NaN, but not a number', () {
      final eq = fieldsEqual<List<Object?>>(same);
      expect(eq([double.nan], [double.nan]), isTrue);
      expect(eq([double.nan], [1.0]), isFalse);
      expect(eq([1.0], [double.nan]), isFalse);
    });

    test('null equals only null', () {
      final eq = fieldsEqual<List<Object?>>(same, relTol: 1, absTol: 1);
      expect(eq([null], [null]), isTrue);
      expect(eq([null], [0.0]), isFalse);
      expect(eq([0.0], [null]), isFalse);
    });

    test('zero tolerance is exact', () {
      final eq = fieldsEqual<List<Object?>>(same);
      expect(eq([1.0], [1.0]), isTrue);
      expect(eq([1.0], [1.0000000000000002]), isFalse);
      expect(eq([1], [1.0]), isTrue);
    });

    test('relTol scales with magnitude', () {
      final eq = fieldsEqual<List<Object?>>(same, relTol: 1e-9);
      expect(eq([1000.0], [1000.0000001]), isTrue); // 1e-7 abs, 1e-10 rel
      expect(eq([1000.0], [1000.00001]), isFalse); // 1e-5 abs, 1e-8 rel
      expect(eq([0.0], [1e-12]), isFalse); // relTol alone gives nothing at 0
    });

    test('absTol covers values near zero', () {
      final eq = fieldsEqual<List<Object?>>(same, absTol: 1e-6);
      expect(eq([0.0], [1e-7]), isTrue);
      expect(eq([0.0], [1e-5]), isFalse);
    });

    test('infinities match only themselves', () {
      final eq = fieldsEqual<List<Object?>>(same, relTol: 1e-9, absTol: 1e-9);
      expect(eq([double.infinity], [double.infinity]), isTrue);
      expect(eq([double.infinity], [double.negativeInfinity]), isFalse);
    });

    test('non-numeric fields compare with ==', () {
      final eq = fieldsEqual<List<Object?>>(same, relTol: 1, absTol: 1);
      expect(eq(['a'], ['a']), isTrue);
      expect(eq(['a'], ['b']), isFalse);
      expect(eq([true], [true]), isTrue);
      expect(eq([1], ['1']), isFalse);
    });

    test('the projection is applied to both sides', () {
      final eq = fieldsEqual<({int a, double b})>((r) => [r.a, r.b], absTol: 1e-6);
      expect(eq((a: 1, b: 2.0), (a: 1, b: 2.0000001)), isTrue);
      expect(eq((a: 1, b: 2.0), (a: 2, b: 2.0)), isFalse);
    });
  });
}
