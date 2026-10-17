// Shared helpers for the aggregator tests: the law assertion, seeded case
// generation, and chunked evaluation.

import 'package:openstrap_analytics/aggregate.dart';
import 'package:test/test.dart';

import 'fold_law_support.dart' show foldBounds;
import 'property.dart' show Rng;

/// Asserts that [agg] satisfies every aggregator law on [cases]. The failure
/// message lists each violated law with its detail.
void expectLawful<S, A, R>(
  Aggregator<S, A, R> agg,
  List<List<A>> cases, {
  ResultEquals<R>? equals,
}) {
  final violations = checkLaws<S, A, R>(agg, cases, equals: equals);
  expect(violations, isEmpty,
      reason: violations.isEmpty
          ? null
          : 'aggregator laws violated:\n'
              '${violations.map((v) => '  ${v.law}: ${v.detail}').join('\n')}');
}

/// Seeded random input lists. Always includes the empty list, a singleton and
/// a pair, then [count] lists of length `0..maxLen`.
List<List<A>> randomCases<A>(int seed, A Function(Rng) elem,
    {int count = 30, int maxLen = 40}) {
  final r = Rng(seed);
  List<A> list(int n) => [for (var i = 0; i < n; i++) elem(r)];
  return [
    <A>[],
    list(1),
    list(2),
    for (var i = 0; i < count; i++) list(r.intIn(0, maxLen)),
  ];
}

/// Folds each chunk `xs[bounds[k]..bounds[k+1])` from a fresh state and
/// combines the chunk states left to right, then finishes. Bounds are as from
/// [foldBounds] (`[0, ...cuts, n]`, cuts may repeat so chunks may be empty).
R runChunked<S, A, R>(Aggregator<S, A, R> agg, List<A> xs, List<int> bounds) {
  var acc = agg.foldRange(xs, bounds[0], bounds[1]);
  for (var k = 1; k + 1 < bounds.length; k++) {
    acc = agg.combine(acc, agg.foldRange(xs, bounds[k], bounds[k + 1]));
  }
  return agg.finish(acc);
}

/// Random chunk bounds for a list of [n] elements.
List<int> randomBounds(Rng r, int n) =>
    foldBounds(n, r.intIn(0, 6), r.nextInt(1 << 30), special: [0, 1, 2, 3]);
