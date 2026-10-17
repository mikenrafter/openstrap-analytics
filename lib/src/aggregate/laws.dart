import 'dart:math' as math;

import 'aggregator.dart';

/// Equality used to compare finished aggregator results.
typedef ResultEquals<R> = bool Function(R left, R right);

/// One failed aggregator law and the input detail that exposed it.
class LawViolation {
  const LawViolation(this.law, this.detail);

  final String law;
  final String detail;
}

/// Checks the merge laws against each supplied input case.
List<LawViolation> checkLaws<S, A, R>(
  Aggregator<S, A, R> aggregator,
  List<List<A>> cases, {
  ResultEquals<R>? equals,
  int maxSplits = 64,
  int seed = 0,
}) {
  final equal = equals ?? (R left, R right) => left == right;
  final violations = <LawViolation>[];

  R whole(List<A> xs) => aggregator.finish(aggregator.fold(xs));
  R join(List<A> xs, int split) => aggregator.finish(aggregator.combine(
      aggregator.foldRange(xs, 0, split),
      aggregator.foldRange(xs, split, xs.length)));

  for (var caseIndex = 0; caseIndex < cases.length; caseIndex++) {
    final xs = cases[caseIndex];
    final detail = 'case $caseIndex: $xs';

    final leftIdentity = aggregator.finish(
        aggregator.combine(aggregator.empty(), aggregator.fold(xs)));
    if (!equal(leftIdentity, whole(xs))) {
      violations.add(LawViolation('leftIdentity', detail));
    }

    final rightIdentity = aggregator.finish(
        aggregator.combine(aggregator.fold(xs), aggregator.empty()));
    if (!equal(rightIdentity, whole(xs))) {
      violations.add(LawViolation('rightIdentity', detail));
    }

    final splits = _splitPoints(xs.length, maxSplits, seed + caseIndex);
    for (final split in splits) {
      if (!equal(join(xs, split), whole(xs))) {
        violations.add(LawViolation('split', '$detail; split $split'));
      }
    }

    for (var i = 0; i < splits.length; i++) {
      for (var j = i; j < splits.length; j++) {
        final firstSplit = splits[i];
        final secondSplit = splits[j];
        final left = aggregator.finish(aggregator.combine(
            aggregator.combine(aggregator.foldRange(xs, 0, firstSplit),
                aggregator.foldRange(xs, firstSplit, secondSplit)),
            aggregator.foldRange(xs, secondSplit, xs.length)));
        final right = aggregator.finish(aggregator.combine(
            aggregator.foldRange(xs, 0, firstSplit),
            aggregator.combine(
                aggregator.foldRange(xs, firstSplit, secondSplit),
                aggregator.foldRange(xs, secondSplit, xs.length))));
        if (!equal(left, right)) {
          violations.add(LawViolation('associativity',
              '$detail; splits $firstSplit, $secondSplit'));
        }
      }
    }

    var singletonState = aggregator.empty();
    for (var i = 0; i < xs.length; i++) {
      singletonState = aggregator.combine(
          singletonState, aggregator.foldRange(xs, i, i + 1));
    }
    if (!equal(aggregator.finish(singletonState), whole(xs))) {
      violations.add(LawViolation('singletons', detail));
    }
  }
  return violations;
}

List<int> _splitPoints(int length, int maxSplits, int seed) {
  if (maxSplits < 2 || length == 0) return [0];
  if (length + 1 <= maxSplits) return [for (var i = 0; i <= length; i++) i];
  final points = <int>{0, length};
  final usable = maxSplits - points.length;
  for (var i = 1; i <= usable; i++) {
    points.add((i * length ~/ (usable + 1) + seed) % (length + 1));
  }
  final result = points.toList()..sort();
  return result;
}

/// Compares projected fields, with optional relative and absolute tolerances.
ResultEquals<R> fieldsEqual<R>(
  List<Object?> Function(R value) fields, {
  double relTol = 0,
  double absTol = 0,
}) =>
    (left, right) {
      final a = fields(left), b = fields(right);
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_fieldEqual(a[i], b[i], relTol, absTol)) return false;
      }
      return true;
    };

bool _fieldEqual(Object? left, Object? right, double relTol, double absTol) {
  if (left == right) return true;
  if (left == null || right == null) return false;
  if (left is! num || right is! num) return false;
  if (left.isNaN || right.isNaN) return left.isNaN && right.isNaN;
  if (!left.isFinite || !right.isFinite) return false;
  final a = left.toDouble(), b = right.toDouble();
  final tolerance = math.max(absTol, relTol * math.max(a.abs(), b.abs()));
  return (a - b).abs() <= tolerance;
}
