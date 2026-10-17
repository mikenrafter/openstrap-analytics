import '../onehz/incremental_core.dart' show IntHistogram, RunningMoments;

import 'aggregator.dart';

/// Counts every input.
class Count<A> extends Aggregator<int, A, int> {
  const Count();

  @override
  int empty() => 0;

  @override
  int add(int state, A input) => state + 1;

  @override
  int combine(int left, int right) => left + right;

  @override
  int finish(int state) => state;
}

/// Sums integer projections of every input.
class IntSum<A> extends Aggregator<int, A, int> {
  const IntSum(this.project);

  final int Function(A input) project;

  @override
  int empty() => 0;

  @override
  int add(int state, A input) => state + project(input);

  @override
  int combine(int left, int right) => left + right;

  @override
  int finish(int state) => state;
}

/// Neumaier-compensated sum of double projections.
class DoubleSum<A> extends Aggregator<_DoubleSumState, A, double> {
  const DoubleSum(this.project);

  final double Function(A input) project;

  @override
  _DoubleSumState empty() => _DoubleSumState();

  @override
  _DoubleSumState add(_DoubleSumState state, A input) {
    state.add(project(input));
    return state;
  }

  @override
  _DoubleSumState combine(_DoubleSumState left, _DoubleSumState right) {
    left.add(right.sum);
    left.add(right.correction);
    return left;
  }

  @override
  double finish(_DoubleSumState state) => state.sum + state.correction;
}

class _DoubleSumState {
  double sum = 0;
  double correction = 0;

  void add(double value) {
    final next = sum + value;
    if (sum.abs() >= value.abs()) {
      correction += (sum - next) + value;
    } else {
      correction += (value - next) + sum;
    }
    sum = next;
  }
}

/// Finds the smallest numeric projection, or null for no inputs.
class Min<A> extends Aggregator<num?, A, num?> {
  const Min(this.project);

  final num Function(A input) project;

  @override
  num? empty() => null;

  @override
  num? add(num? state, A input) {
    final value = project(input);
    return state == null || value < state ? value : state;
  }

  @override
  num? combine(num? left, num? right) {
    if (left == null) return right;
    if (right == null) return left;
    return right < left ? right : left;
  }

  @override
  num? finish(num? state) => state;
}

/// Finds the largest numeric projection, or null for no inputs.
class Max<A> extends Aggregator<num?, A, num?> {
  const Max(this.project);

  final num Function(A input) project;

  @override
  num? empty() => null;

  @override
  num? add(num? state, A input) {
    final value = project(input);
    return state == null || value > state ? value : state;
  }

  @override
  num? combine(num? left, num? right) {
    if (left == null) return right;
    if (right == null) return left;
    return right > left ? right : left;
  }

  @override
  num? finish(num? state) => state;
}

/// Keeps the first input, or null for no inputs.
class First<A> extends Aggregator<_ValueState<A>, A, A?> {
  const First();

  @override
  _ValueState<A> empty() => _ValueState<A>();

  @override
  _ValueState<A> add(_ValueState<A> state, A input) {
    if (!state.hasValue) {
      state
        ..hasValue = true
        ..value = input;
    }
    return state;
  }

  @override
  _ValueState<A> combine(_ValueState<A> left, _ValueState<A> right) {
    if (!left.hasValue && right.hasValue) {
      left
        ..hasValue = true
        ..value = right.value;
    }
    return left;
  }

  @override
  A? finish(_ValueState<A> state) => state.hasValue ? state.value : null;
}

/// Keeps the last input, or null for no inputs.
class Last<A> extends Aggregator<_ValueState<A>, A, A?> {
  const Last();

  @override
  _ValueState<A> empty() => _ValueState<A>();

  @override
  _ValueState<A> add(_ValueState<A> state, A input) {
    state
      ..hasValue = true
      ..value = input;
    return state;
  }

  @override
  _ValueState<A> combine(_ValueState<A> left, _ValueState<A> right) {
    if (right.hasValue) {
      left
        ..hasValue = true
        ..value = right.value;
    }
    return left;
  }

  @override
  A? finish(_ValueState<A> state) => state.hasValue ? state.value : null;
}

class _ValueState<A> {
  bool hasValue = false;
  A? value;
}

/// Mergeable centered moments of double projections.
class Moments<A> extends Aggregator<RunningMoments, A, RunningMoments> {
  const Moments(this.project);

  final double Function(A input) project;

  @override
  RunningMoments empty() => RunningMoments();

  @override
  RunningMoments add(RunningMoments state, A input) {
    state.add(project(input));
    return state;
  }

  @override
  RunningMoments combine(RunningMoments left, RunningMoments right) {
    left.merge(right);
    return left;
  }

  @override
  RunningMoments finish(RunningMoments state) => state;
}

/// Exact histogram of integer projections.
class Histogram<A> extends Aggregator<IntHistogram, A, IntHistogram> {
  const Histogram(this.project);

  final int Function(A input) project;

  @override
  IntHistogram empty() => IntHistogram();

  @override
  IntHistogram add(IntHistogram state, A input) {
    state.add(project(input));
    return state;
  }

  @override
  IntHistogram combine(IntHistogram left, IntHistogram right) {
    left.merge(right);
    return left;
  }

  @override
  IntHistogram finish(IntHistogram state) => state;
}

/// Feeds an inner aggregator every pair of adjacent inputs.
class AdjacentPairs<A, S, R>
    extends Aggregator<_AdjacentPairsState<A, S>, A, R> {
  const AdjacentPairs(this.inner);

  final Aggregator<S, (A, A), R> inner;

  @override
  _AdjacentPairsState<A, S> empty() =>
      _AdjacentPairsState<A, S>(inner.empty());

  @override
  _AdjacentPairsState<A, S> add(_AdjacentPairsState<A, S> state, A input) {
    if (state.hasValue) {
      state.innerState = inner.add(state.innerState, (state.last as A, input));
    } else {
      state.first = input;
      state.hasValue = true;
    }
    state.last = input;
    return state;
  }

  @override
  _AdjacentPairsState<A, S> combine(
      _AdjacentPairsState<A, S> left, _AdjacentPairsState<A, S> right) {
    final leftHasValue = left.hasValue;
    if (leftHasValue && right.hasValue) {
      left.innerState =
          inner.add(left.innerState, (left.last as A, right.first as A));
    }
    left.innerState = inner.combine(left.innerState, right.innerState);
    if (!leftHasValue && right.hasValue) left.first = right.first;
    if (right.hasValue) left.last = right.last;
    left.hasValue = leftHasValue || right.hasValue;
    return left;
  }

  @override
  R finish(_AdjacentPairsState<A, S> state) => inner.finish(state.innerState);
}

class _AdjacentPairsState<A, S> {
  _AdjacentPairsState(this.innerState);

  S innerState;
  bool hasValue = false;
  A? first;
  A? last;
}

/// Routes inputs by key to independent instances of [inner].
///
/// Its state is mutable: each map entry holds the corresponding inner state.
class GroupBy<A, K, S, R> extends Aggregator<Map<K, S>, A, Map<K, R>> {
  const GroupBy(this.key, this.inner);

  final K Function(A input) key;
  final Aggregator<S, A, R> inner;

  @override
  Map<K, S> empty() => <K, S>{};

  @override
  Map<K, S> add(Map<K, S> state, A input) {
    final group = key(input);
    final innerState = state.containsKey(group) ? state[group] as S : inner.empty();
    state[group] = inner.add(innerState, input);
    return state;
  }

  @override
  Map<K, S> combine(Map<K, S> left, Map<K, S> right) {
    for (final entry in right.entries) {
      if (left.containsKey(entry.key)) {
        left[entry.key] = inner.combine(left[entry.key] as S, entry.value);
      } else {
        left[entry.key] = entry.value;
      }
    }
    return left;
  }

  @override
  Map<K, R> finish(Map<K, S> state) => {
        for (final entry in state.entries) entry.key: inner.finish(entry.value),
      };
}
