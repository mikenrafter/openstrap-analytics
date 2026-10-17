/// A mergeable summary over inputs of type [A].
abstract class Aggregator<S, A, R> {
  const Aggregator();

  S empty();
  S add(S state, A input);
  S combine(S left, S right);
  R finish(S state);
}

/// Convenience operations and compositional adapters for [Aggregator].
extension AggregatorOps<S, A, R> on Aggregator<S, A, R> {
  S fold(Iterable<A> inputs) {
    var state = empty();
    for (final input in inputs) {
      state = add(state, input);
    }
    return state;
  }

  S foldRange(List<A> inputs, int start, int end) {
    var state = empty();
    for (var i = start; i < end; i++) {
      state = add(state, inputs[i]);
    }
    return state;
  }

  R run(Iterable<A> inputs) => finish(fold(inputs));

  Aggregator<S, A, T> map<T>(T Function(R result) transform) =>
      _MappedAggregator<S, A, R, T>(this, transform);

  Aggregator<S, B, R> contramap<B>(A Function(B input) transform) =>
      _ContramappedAggregator<S, A, B, R>(this, transform);

  Aggregator<S, A, R> where(bool Function(A input) test) =>
      _WhereAggregator<S, A, R>(this, test);
}

class _MappedAggregator<S, A, R, T> extends Aggregator<S, A, T> {
  const _MappedAggregator(this.inner, this.transform);

  final Aggregator<S, A, R> inner;
  final T Function(R result) transform;

  @override
  S empty() => inner.empty();

  @override
  S add(S state, A input) => inner.add(state, input);

  @override
  S combine(S left, S right) => inner.combine(left, right);

  @override
  T finish(S state) => transform(inner.finish(state));
}

class _ContramappedAggregator<S, A, B, R> extends Aggregator<S, B, R> {
  const _ContramappedAggregator(this.inner, this.transform);

  final Aggregator<S, A, R> inner;
  final A Function(B input) transform;

  @override
  S empty() => inner.empty();

  @override
  S add(S state, B input) => inner.add(state, transform(input));

  @override
  S combine(S left, S right) => inner.combine(left, right);

  @override
  R finish(S state) => inner.finish(state);
}

class _WhereAggregator<S, A, R> extends Aggregator<S, A, R> {
  const _WhereAggregator(this.inner, this.test);

  final Aggregator<S, A, R> inner;
  final bool Function(A input) test;

  @override
  S empty() => inner.empty();

  @override
  S add(S state, A input) => test(input) ? inner.add(state, input) : state;

  @override
  S combine(S left, S right) => inner.combine(left, right);

  @override
  R finish(S state) => inner.finish(state);
}

/// Mutable state for [both].
class Pair<A, B> {
  Pair(this.first, this.second);

  A first;
  B second;
}

/// Runs two aggregators over the same input stream.
Aggregator<Pair<SA, SB>, A, (RA, RB)> both<SA, SB, A, RA, RB>(
  Aggregator<SA, A, RA> first,
  Aggregator<SB, A, RB> second,
) =>
    _BothAggregator<SA, SB, A, RA, RB>(first, second);

class _BothAggregator<SA, SB, A, RA, RB>
    extends Aggregator<Pair<SA, SB>, A, (RA, RB)> {
  const _BothAggregator(this.first, this.second);

  final Aggregator<SA, A, RA> first;
  final Aggregator<SB, A, RB> second;

  @override
  Pair<SA, SB> empty() => Pair(first.empty(), second.empty());

  @override
  Pair<SA, SB> add(Pair<SA, SB> state, A input) {
    state.first = first.add(state.first, input);
    state.second = second.add(state.second, input);
    return state;
  }

  @override
  Pair<SA, SB> combine(Pair<SA, SB> left, Pair<SA, SB> right) {
    left.first = first.combine(left.first, right.first);
    left.second = second.combine(left.second, right.second);
    return left;
  }

  @override
  (RA, RB) finish(Pair<SA, SB> state) =>
      (first.finish(state.first), second.finish(state.second));
}
