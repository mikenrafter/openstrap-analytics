// Shared by the module aggregator tests: a mid-stream checkpoint must resume.

import 'dart:convert';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:test/test.dart';

/// Asserts that [agg] is persistable and that a mid-stream checkpoint resumes:
/// fold the first half of [batch], checkpoint it through JSON text, restore,
/// keep folding the second half, and compare with the one-pass result.
void expectCheckpointResumes<S, B extends Batch<B>, R>(
  Aggregator<S, B, R> agg,
  B batch, {
  ResultEquals<R>? equals,
}) {
  expect(agg.persistable, isTrue);
  final half = batch.length ~/ 2;
  final env = jsonDecode(jsonEncode(encodeCheckpoint(
      agg, agg.fold(batch, 0, half),
      kind: 'test', version: 1)));
  final restored = decodeCheckpoint<S>(agg, env, kind: 'test', version: 1);
  expect(restored, isNotNull);
  final got = agg.finish(agg.addSlice(restored as S, batch, half, batch.length));
  final want = agg.run(batch);
  final same = equals ?? (R a, R b) => a == b;
  expect(same(got, want), isTrue, reason: 'resumed $got vs one-pass $want');
}
