import 'dart:typed_data';

/// A run of rows stored column-wise.
abstract class Batch<B extends Batch<B>> {
  int get length;
  B copyRange(int start, int end);
  B join(B other);
}

/// A batch backed by a normal Dart list.
class ListBatch<A> extends Batch<ListBatch<A>> {
  ListBatch(this.rows);

  final List<A> rows;

  @override
  int get length => rows.length;

  @override
  ListBatch<A> copyRange(int start, int end) =>
      ListBatch<A>(rows.sublist(start, end));

  @override
  ListBatch<A> join(ListBatch<A> other) =>
      ListBatch<A>([...rows, ...other.rows]);
}

/// A batch containing one double column. NaN represents a missing row.
class DoubleColumn extends Batch<DoubleColumn> {
  DoubleColumn(this.values);

  final Float64List values;

  @override
  int get length => values.length;

  @override
  DoubleColumn copyRange(int start, int end) =>
      DoubleColumn(Float64List.fromList(values.sublist(start, end)));

  @override
  DoubleColumn join(DoubleColumn other) {
    final joined = Float64List(length + other.length);
    joined.setRange(0, length, values);
    joined.setRange(length, joined.length, other.values);
    return DoubleColumn(joined);
  }
}

/// A mergeable summary over slices of a [Batch].
abstract class Aggregator<S, B extends Batch<B>, R> {
  const Aggregator();

  S empty();
  S addSlice(S state, B batch, int start, int end);
  S combine(S left, S right);
  R finish(S state);
}

/// Convenience operations and result adapters for [Aggregator].
extension AggregatorOps<S, B extends Batch<B>, R> on Aggregator<S, B, R> {
  S fold(B batch, [int start = 0, int? end]) {
    final actualEnd = end ?? batch.length;
    return addSlice(empty(), batch, start, actualEnd);
  }

  R run(B batch) => finish(fold(batch));

  Aggregator<S, B, R2> map<R2>(R2 Function(R result) transform) =>
      _MappedAggregator<S, B, R, R2>(this, transform);
}

/// Element-world convenience for aggregators over [ListBatch].
extension ListAggregatorOps<S, A, R> on Aggregator<S, ListBatch<A>, R> {
  R runList(List<A> rows) => run(ListBatch<A>(rows));
}

class _MappedAggregator<S, B extends Batch<B>, R, R2>
    extends Aggregator<S, B, R2> {
  const _MappedAggregator(this.inner, this.transform);

  final Aggregator<S, B, R> inner;
  final R2 Function(R result) transform;

  @override
  S empty() => inner.empty();

  @override
  S addSlice(S state, B batch, int start, int end) =>
      inner.addSlice(state, batch, start, end);

  @override
  S combine(S left, S right) => inner.combine(left, right);

  @override
  R2 finish(S state) => transform(inner.finish(state));
}

/// Mutable state for [both].
class Pair<A, B> {
  Pair(this.first, this.second);

  A first;
  B second;
}

/// Runs two aggregators over each same slice.
Aggregator<Pair<S1, S2>, B, (R1, R2)>
    both<S1, S2, B extends Batch<B>, R1, R2>(
  Aggregator<S1, B, R1> first,
  Aggregator<S2, B, R2> second,
) =>
        _BothAggregator<S1, S2, B, R1, R2>(first, second);

class _BothAggregator<S1, S2, B extends Batch<B>, R1, R2>
    extends Aggregator<Pair<S1, S2>, B, (R1, R2)> {
  const _BothAggregator(this.first, this.second);

  final Aggregator<S1, B, R1> first;
  final Aggregator<S2, B, R2> second;

  @override
  Pair<S1, S2> empty() => Pair<S1, S2>(first.empty(), second.empty());

  @override
  Pair<S1, S2> addSlice(Pair<S1, S2> state, B batch, int start, int end) {
    state.first = first.addSlice(state.first, batch, start, end);
    state.second = second.addSlice(state.second, batch, start, end);
    return state;
  }

  @override
  Pair<S1, S2> combine(Pair<S1, S2> left, Pair<S1, S2> right) {
    left.first = first.combine(left.first, right.first);
    left.second = second.combine(left.second, right.second);
    return left;
  }

  @override
  (R1, R2) finish(Pair<S1, S2> state) =>
      (first.finish(state.first), second.finish(state.second));
}
