import 'dart:math' as math;

import 'aggregator.dart';

typedef ResultEquals<R> = bool Function(R left, R right);

class LawViolation {
  const LawViolation(this.law, this.detail);
  final String law;
  final String detail;
}

/// Checks aggregator merge and slicing laws on each batch in [cases].
List<LawViolation> checkLaws<S, B extends Batch<B>, R>(
  Aggregator<S, B, R> aggregator,
  List<B> cases, {
  ResultEquals<R>? equals,
  int maxSplits = 64,
  int seed = 0,
}) {
  final equal = equals ?? (R left, R right) => left == right;
  final violations = <LawViolation>[];

  R whole(B batch) => aggregator.finish(aggregator.fold(batch));
  R joined(B batch, int split) => aggregator.finish(aggregator.combine(
      aggregator.fold(batch, 0, split),
      aggregator.fold(batch, split, batch.length)));

  for (var caseIndex = 0; caseIndex < cases.length; caseIndex++) {
    final batch = cases[caseIndex];
    final detail = 'case $caseIndex: $batch';
    final expected = whole(batch);
    final leftIdentity = aggregator.finish(
        aggregator.combine(aggregator.empty(), aggregator.fold(batch)));
    if (!equal(leftIdentity, expected)) {
      violations.add(LawViolation('leftIdentity', detail));
    }
    final rightIdentity = aggregator.finish(
        aggregator.combine(aggregator.fold(batch), aggregator.empty()));
    if (!equal(rightIdentity, expected)) {
      violations.add(LawViolation('rightIdentity', detail));
    }

    final splits = _splitPoints(batch.length, maxSplits, seed + caseIndex);
    for (final split in splits) {
      if (!equal(joined(batch, split), expected)) {
        violations.add(LawViolation('split', '$detail; split $split'));
      }
    }
    for (var i = 0; i < splits.length; i++) {
      for (var j = i; j < splits.length; j++) {
        final first = splits[i];
        final second = splits[j];
        final left = aggregator.finish(aggregator.combine(
            aggregator.combine(aggregator.fold(batch, 0, first),
                aggregator.fold(batch, first, second)),
            aggregator.fold(batch, second, batch.length)));
        final right = aggregator.finish(aggregator.combine(
            aggregator.fold(batch, 0, first),
            aggregator.combine(aggregator.fold(batch, first, second),
                aggregator.fold(batch, second, batch.length))));
        if (!equal(left, right)) {
          violations.add(
              LawViolation('associativity', '$detail; splits $first, $second'));
        }
      }
    }

    var singletonState = aggregator.empty();
    for (var i = 0; i < batch.length; i++) {
      singletonState = aggregator.combine(
          singletonState, aggregator.fold(batch, i, i + 1));
    }
    if (!equal(aggregator.finish(singletonState), expected)) {
      violations.add(LawViolation('singletons', detail));
    }

    var sliced = aggregator.empty();
    final slicePoints = _splitPoints(batch.length, maxSplits, seed ^ caseIndex);
    for (var i = 0; i + 1 < slicePoints.length; i++) {
      sliced = aggregator.addSlice(sliced, batch, slicePoints[i], slicePoints[i + 1]);
    }
    if (!equal(aggregator.finish(sliced), expected)) {
      violations.add(LawViolation('slicing', detail));
    }

    // finish must not consume or otherwise close a state. Keep separate
    // states for the add and combine continuations: combine is allowed to
    // consume either input.
    final continuationStart = batch.length ~/ 2;
    var afterFinish = aggregator.fold(batch, 0, continuationStart);
    final firstFinish = aggregator.finish(afterFinish);
    final secondFinish = aggregator.finish(afterFinish);
    var finishIsPure = equal(firstFinish, secondFinish);

    afterFinish = aggregator.addSlice(
        afterFinish, batch, continuationStart, batch.length);
    var addReference = aggregator.fold(batch, 0, continuationStart);
    addReference = aggregator.addSlice(
        addReference, batch, continuationStart, batch.length);
    if (!equal(aggregator.finish(afterFinish), aggregator.finish(addReference))) {
      finishIsPure = false;
    }

    var combinedAfterFinish = aggregator.fold(batch, 0, continuationStart);
    aggregator.finish(combinedAfterFinish);
    aggregator.finish(combinedAfterFinish);
    combinedAfterFinish = aggregator.combine(
        combinedAfterFinish,
        aggregator.fold(batch, continuationStart, batch.length));
    var combineReference = aggregator.fold(batch, 0, continuationStart);
    combineReference = aggregator.combine(
        combineReference,
        aggregator.fold(batch, continuationStart, batch.length));
    if (!equal(aggregator.finish(combinedAfterFinish),
        aggregator.finish(combineReference))) {
      finishIsPure = false;
    }
    if (!finishIsPure) {
      violations.add(LawViolation('finishPure', detail));
    }
  }
  return violations;
}

List<int> _splitPoints(int length, int maxSplits, int seed) {
  if (length == 0) return [0];
  final wanted = math.max(2, maxSplits);
  if (length + 1 <= wanted) return [for (var i = 0; i <= length; i++) i];
  final points = <int>{0, length};
  var state = seed & 0x7fffffff;
  while (points.length < wanted) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    points.add(1 + state % (length - 1));
  }
  return points.toList()..sort();
}

ResultEquals<R> fieldsEqual<R>(
  List<Object?> Function(R value) fields, {
  double relTol = 0,
  double absTol = 0,
}) =>
    (left, right) {
      final a = fields(left);
      final b = fields(right);
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_fieldEqual(a[i], b[i], relTol, absTol)) return false;
      }
      return true;
    };

bool _fieldEqual(Object? left, Object? right, double relTol, double absTol) {
  // Converting two ints to double loses distinctions above 2^53.
  if (left is int && right is int) return left == right;
  if (left == right) return true;
  if (left == null || right == null) return false;
  if (left is! num || right is! num) return false;
  if (left.isNaN || right.isNaN) return left.isNaN && right.isNaN;
  if (!left.isFinite || !right.isFinite) return false;
  final a = left.toDouble();
  final b = right.toDouble();
  final tolerance = absTol + relTol * math.max(a.abs(), b.abs());
  return (a - b).abs() <= tolerance;
}
