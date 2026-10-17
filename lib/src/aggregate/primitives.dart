import 'dart:typed_data';

import '../onehz/incremental_core.dart' show RunningMoments;

import 'aggregator.dart';

/// Counts every row, including rows whose column value is NaN.
class Count<B extends Batch<B>> extends Aggregator<int, B, int> {
  const Count();
  @override
  int empty() => 0;
  @override
  int addSlice(int state, B batch, int start, int end) => state + end - start;
  @override
  int combine(int left, int right) => left + right;
  @override
  int finish(int state) => state;
}

/// Counts non-missing values in a double column.
class CountFinite<B extends Batch<B>> extends Aggregator<int, B, int> {
  const CountFinite(this.column);
  final Float64List Function(B batch) column;
  @override
  int empty() => 0;
  @override
  int addSlice(int state, B batch, int start, int end) {
    final values = column(batch);
    var count = state;
    for (var i = start; i < end; i++) {
      if (!values[i].isNaN) count++;
    }
    return count;
  }
  @override
  int combine(int left, int right) => left + right;
  @override
  int finish(int state) => state;
}

/// Counts non-missing values in a double column which pass [test].
class CountWhere<B extends Batch<B>> extends Aggregator<int, B, int> {
  const CountWhere(this.column, this.test);
  final Float64List Function(B batch) column;
  final bool Function(double value) test;
  @override
  int empty() => 0;
  @override
  int addSlice(int state, B batch, int start, int end) {
    final values = column(batch);
    var count = state;
    for (var i = start; i < end; i++) {
      final value = values[i];
      if (!value.isNaN && test(value)) count++;
    }
    return count;
  }
  @override
  int combine(int left, int right) => left + right;
  @override
  int finish(int state) => state;
}

/// Neumaier-compensated sum of non-missing double column values.
class Sum<B extends Batch<B>> extends Aggregator<_SumState, B, double> {
  const Sum(this.column);
  final Float64List Function(B batch) column;
  @override
  _SumState empty() => _SumState();
  @override
  _SumState addSlice(_SumState state, B batch, int start, int end) {
    final values = column(batch);
    for (var i = start; i < end; i++) {
      final value = values[i];
      if (!value.isNaN) state.add(value);
    }
    return state;
  }
  @override
  _SumState combine(_SumState left, _SumState right) {
    left.add(right.sum);
    left.add(right.correction);
    return left;
  }
  @override
  double finish(_SumState state) => state.sum + state.correction;
}

class _SumState {
  double sum = 0.0;
  double correction = 0.0;
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

/// Sum of squares of non-missing double column values.
class SumSq<B extends Batch<B>> extends Aggregator<double, B, double> {
  const SumSq(this.column);
  final Float64List Function(B batch) column;
  @override
  double empty() => 0.0;
  @override
  double addSlice(double state, B batch, int start, int end) {
    final values = column(batch);
    var sum = state;
    for (var i = start; i < end; i++) {
      final value = values[i];
      if (!value.isNaN) sum += value * value;
    }
    return sum;
  }
  @override
  double combine(double left, double right) => left + right;
  @override
  double finish(double state) => state;
}

/// Smallest non-missing value in a double column.
class Min<B extends Batch<B>> extends Aggregator<double?, B, double?> {
  const Min(this.column);
  final Float64List Function(B batch) column;
  @override
  double? empty() => null;
  @override
  double? addSlice(double? state, B batch, int start, int end) {
    final values = column(batch);
    var result = state;
    for (var i = start; i < end; i++) {
      final value = values[i];
      if (!value.isNaN && (result == null || value < result)) result = value;
    }
    return result;
  }
  @override
  double? combine(double? left, double? right) {
    if (left == null || right == null) return left ?? right;
    return right < left ? right : left;
  }
  @override
  double? finish(double? state) => state;
}

/// Largest non-missing value in a double column.
class Max<B extends Batch<B>> extends Aggregator<double?, B, double?> {
  const Max(this.column);
  final Float64List Function(B batch) column;
  @override
  double? empty() => null;
  @override
  double? addSlice(double? state, B batch, int start, int end) {
    final values = column(batch);
    var result = state;
    for (var i = start; i < end; i++) {
      final value = values[i];
      if (!value.isNaN && (result == null || value > result)) result = value;
    }
    return result;
  }
  @override
  double? combine(double? left, double? right) {
    if (left == null || right == null) return left ?? right;
    return right > left ? right : left;
  }
  @override
  double? finish(double? state) => state;
}

/// Centered moments of non-missing double column values.
class Moments<B extends Batch<B>>
    extends Aggregator<RunningMoments, B, RunningMoments> {
  const Moments(this.column);
  final Float64List Function(B batch) column;
  @override
  RunningMoments empty() => RunningMoments();
  @override
  RunningMoments addSlice(RunningMoments state, B batch, int start, int end) {
    final values = column(batch);
    for (var i = start; i < end; i++) {
      final value = values[i];
      if (!value.isNaN) state.add(value);
    }
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

class _EdgeState<B extends Batch<B>> {
  B? value;
}

/// The first row as a one-row copy, or null for no rows.
class First<B extends Batch<B>> extends Aggregator<_EdgeState<B>, B, B?> {
  const First();
  @override
  _EdgeState<B> empty() => _EdgeState<B>();
  @override
  _EdgeState<B> addSlice(_EdgeState<B> state, B batch, int start, int end) {
    if (state.value == null && start < end) {
      state.value = batch.copyRange(start, start + 1);
    }
    return state;
  }
  @override
  _EdgeState<B> combine(_EdgeState<B> left, _EdgeState<B> right) {
    if (left.value == null) left.value = right.value;
    return left;
  }
  @override
  B? finish(_EdgeState<B> state) => state.value;
}

/// The last row as a one-row copy, or null for no rows.
class Last<B extends Batch<B>> extends Aggregator<_EdgeState<B>, B, B?> {
  const Last();
  @override
  _EdgeState<B> empty() => _EdgeState<B>();
  @override
  _EdgeState<B> addSlice(_EdgeState<B> state, B batch, int start, int end) {
    if (start < end) state.value = batch.copyRange(end - 1, end);
    return state;
  }
  @override
  _EdgeState<B> combine(_EdgeState<B> left, _EdgeState<B> right) {
    if (right.value != null) left.value = right.value;
    return left;
  }
  @override
  B? finish(_EdgeState<B> state) => state.value;
}

/// Routes consecutive equal keys to [inner] as one slice per run.
class GroupBy<B extends Batch<B>, S, R>
    extends Aggregator<Map<int, S>, B, Map<int, R>> {
  const GroupBy(this.key, this.inner);
  final int Function(B batch, int row) key;
  final Aggregator<S, B, R> inner;
  @override
  Map<int, S> empty() => <int, S>{};
  @override
  Map<int, S> addSlice(Map<int, S> state, B batch, int start, int end) {
    if (start == end) return state;
    var runStart = start;
    var runKey = key(batch, start);
    for (var i = start + 1; i < end; i++) {
      final nextKey = key(batch, i);
      if (nextKey != runKey) {
        _addRun(state, runKey, batch, runStart, i);
        runStart = i;
        runKey = nextKey;
      }
    }
    _addRun(state, runKey, batch, runStart, end);
    return state;
  }
  void _addRun(Map<int, S> state, int runKey, B batch, int start, int end) {
    final previous = state.containsKey(runKey) ? state[runKey] as S : inner.empty();
    state[runKey] = inner.addSlice(previous, batch, start, end);
  }
  @override
  Map<int, S> combine(Map<int, S> left, Map<int, S> right) {
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
  Map<int, R> finish(Map<int, S> state) => <int, R>{
        for (final entry in state.entries) entry.key: inner.finish(entry.value),
      };
}

/// Makes an inner length-[k] window aggregator invariant to chunk boundaries.
class Lookback<B extends Batch<B>, S, R>
    extends Aggregator<_LookbackState<B, S>, B, R> {
  Lookback(this.k, this.inner) : assert(k >= 1);
  final int k;
  final Aggregator<S, B, R> inner;
  int get _edge => k - 1;
  @override
  _LookbackState<B, S> empty() => _LookbackState<B, S>(inner.empty());
  @override
  _LookbackState<B, S> addSlice(
      _LookbackState<B, S> state, B batch, int start, int end) {
    if (start == end) return state;
    if (state.length > 0 && _edge > 0) {
      final seam = state.last!.join(batch.copyRange(start, _prefixEnd(start, end)));
      state.innerState = inner.addSlice(state.innerState, seam, 0, seam.length);
    }
    state.innerState = inner.addSlice(state.innerState, batch, start, end);
    _appendEdges(state, batch, start, end);
    return state;
  }
  int _prefixEnd(int start, int end) =>
      start + (end - start < _edge ? end - start : _edge);
  void _appendEdges(_LookbackState<B, S> state, B batch, int start, int end) {
    final sliceLength = end - start;
    if (_edge == 0) {
      state.length += sliceLength;
      return;
    }
    if (state.length == 0) {
      state.first = batch.copyRange(start, _prefixEnd(start, end));
      state.last = batch.copyRange(
          end - (sliceLength < _edge ? sliceLength : _edge), end);
    } else {
      if (state.length < _edge) {
        final needed = _edge - state.length;
        final take = sliceLength < needed ? sliceLength : needed;
        if (take > 0) state.first = state.first!.join(batch.copyRange(start, start + take));
      }
      if (sliceLength >= _edge) {
        state.last = batch.copyRange(end - _edge, end);
      } else {
        final joined = state.last!.join(batch.copyRange(start, end));
        final keepStart = joined.length > _edge ? joined.length - _edge : 0;
        state.last = joined.copyRange(keepStart, joined.length);
      }
    }
    state.length += sliceLength;
  }
  @override
  _LookbackState<B, S> combine(
      _LookbackState<B, S> left, _LookbackState<B, S> right) {
    if (left.length > 0 && right.length > 0 && _edge > 0) {
      final seam = left.last!.join(right.first!);
      left.innerState = inner.addSlice(left.innerState, seam, 0, seam.length);
    }
    left.innerState = inner.combine(left.innerState, right.innerState);
    _combineEdges(left, right);
    return left;
  }
  void _combineEdges(_LookbackState<B, S> left, _LookbackState<B, S> right) {
    if (right.length == 0) return;
    if (left.length == 0) {
      left.length = right.length;
      left.first = right.first;
      left.last = right.last;
      return;
    }
    if (_edge > 0) {
      if (left.length < _edge) {
        final needed = _edge - left.length;
        final take = right.length < needed ? right.length : needed;
        if (take > 0) left.first = left.first!.join(right.first!.copyRange(0, take));
      }
      if (right.length >= _edge) {
        left.last = right.last;
      } else {
        final joined = left.last!.join(right.last!);
        final keepStart = joined.length > _edge ? joined.length - _edge : 0;
        left.last = joined.copyRange(keepStart, joined.length);
      }
    }
    left.length += right.length;
  }
  @override
  R finish(_LookbackState<B, S> state) => inner.finish(state.innerState);
}

class _LookbackState<B extends Batch<B>, S> {
  _LookbackState(this.innerState);
  S innerState;
  int length = 0;
  B? first;
  B? last;
}
