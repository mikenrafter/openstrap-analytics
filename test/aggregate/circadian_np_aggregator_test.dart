// EpochSeries + circadianNpAggregator must reproduce circadianNonparametric
// (the reference, unchanged) under every slicing / chunking, and obey the laws.
//
// Contract: EpochSeries(Float64List x, {firstIndex = 0}); copyRange copies and
// shifts firstIndex; join asserts other.firstIndex == firstIndex + length.
// circadianNpAggregator(epochsPerDay, {m10Epochs, l5Epochs}) never throws;
// epochsPerDay <= 0 is the reference's absent Metric.
//
// Parity: integer data -> IS/IV/M10/L5/RA within relTol 1e-12 and start epochs
// EXACT. Real data -> values within relTol 1e-9, start epochs NOT compared (the
// window margin is not available to the equality, so only integer cases check
// starts).

import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/property.dart' show Rng;

List<Object?> _meta(Metric<CircadianNp> m) =>
    [m.present, m.confidence, m.tier, m.inputs_used.join(','), m.note];

List<Object?> _vals(Metric<CircadianNp> m) {
  final v = m.value;
  return [
    ..._meta(m),
    v?.interdailyStability, v?.intradailyVariability, v?.m10, v?.l5,
    v?.relativeAmplitude,
  ];
}

List<Object?> _withStarts(Metric<CircadianNp> m) =>
    [..._vals(m), m.value?.m10StartEpoch, m.value?.l5StartEpoch];

final _exact = fieldsEqual<Metric<CircadianNp>>(_withStarts, relTol: 1e-12);
final _real = fieldsEqual<Metric<CircadianNp>>(_vals, relTol: 1e-9);

EpochSeries _es(List<num> x, {int first = 0}) => EpochSeries(
    Float64List.fromList([for (final v in x) v.toDouble()]),
    firstIndex: first);

/// Seeded series: [count] lengths in 0..10 days plus a partial day.
List<EpochSeries> _cases(int seed, int p, double Function(Rng) draw,
    {int count = 10}) {
  final r = Rng(seed);
  return [
    _es([]),
    _es([draw(r)]),
    for (var i = 0; i < count; i++)
      _es([
        for (var k = r.intIn(0, 10 * p + p - 1); k > 0; k--) draw(r)
      ]),
    _es([for (var k = 0; k < 3 * p; k++) draw(r)]),
  ];
}

void _parity(String name, int p, {int? m10, int? l5, bool ints = true}) {
  test(name, () {
    final draw = ints
        ? (Rng r) => r.intIn(0, 500).toDouble()
        : (Rng r) => r.nextDouble() * 300 - 20;
    expectConversion<dynamic, EpochSeries, Metric<CircadianNp>>(
      (_) => circadianNpAggregator(p, m10Epochs: m10, l5Epochs: l5),
      _cases(p * 31 + (ints ? 1 : 0), p, draw),
      (b) => circadianNonparametric(b.x, p, m10Epochs: m10, l5Epochs: l5),
      equals: ints ? _exact : _real,
      seed: p,
    );
  });
}

void main() {
  group('EpochSeries batch', () {
    final e = _es([for (var i = 0; i < 10; i++) i * 1.5]);

    test('copyRange shifts firstIndex and copies', () {
      final c = e.copyRange(3, 8);
      expect(c.length, 5);
      expect(c.firstIndex, 3);
      expect(c.x, e.x.sublist(3, 8));
      expect(c.copyRange(2, 4).firstIndex, 5);
      expect(_es([1, 2, 3], first: 100).copyRange(1, 3).firstIndex, 101);
      expect(e.copyRange(4, 4).length, 0);
      e.x[4] = -1;
      expect(c.x[1], 6.0);
      e.x[4] = 6.0;
    });

    test('join of adjacent batches', () {
      final j = e.copyRange(2, 5).join(e.copyRange(5, 5)).join(e.copyRange(5, 9));
      expect(j.firstIndex, 2);
      expect(j.x, e.x.sublist(2, 9));
      final l = e.copyRange(0, 3);
      final k = l.join(e.copyRange(3, 10));
      l.x[0] = 99;
      expect(k.x[0], 0.0);
    });

    test('non-adjacent join asserts', () {
      expect(() => e.copyRange(0, 3).join(e.copyRange(4, 10)),
          throwsA(isA<AssertionError>()));
      expect(() => e.copyRange(3, 6).join(e.copyRange(0, 3)),
          throwsA(isA<AssertionError>()));
    });
  });

  group('parity with circadianNonparametric', () {
    for (final p in [6, 7, 12, 24]) {
      _parity('integer data, p=$p', p);
      _parity('real data, p=$p', p, ints: false);
    }
    _parity('custom windows, integers', 12, m10: 5, l5: 3);
    _parity('custom windows, real', 12, m10: 5, l5: 3, ints: false);
    _parity('windows w >= p', 8, m10: 8, l5: 20);
    _parity('window w == 1', 8, m10: 1, l5: 1);

    test('3 days of 1440 epochs, integers', () {
      final r = Rng(1440);
      final x = _es([for (var i = 0; i < 3 * 1440; i++) r.intIn(0, 900)]);
      expectConversion<dynamic, EpochSeries, Metric<CircadianNp>>(
          (_) => circadianNpAggregator(1440), [x],
          (b) => circadianNonparametric(b.x, 1440),
          // Laws are covered by the small-p cases above; here each finish runs
          // the O(p·w) window search, so the law sweep alone took ~9 s.
          equals: _exact, chunkings: 4, laws: false);
    });
  });

  group('absent cases and extremes', () {
    void same(String name, EpochSeries s, int p, {int? m10, int? l5}) =>
        test(name, () {
          final want = circadianNonparametric(s.x, p, m10Epochs: m10, l5Epochs: l5);
          final got = circadianNpAggregator(p, m10Epochs: m10, l5Epochs: l5)
              .run(s);
          expect(_exact(got, want), isTrue, reason: '$got vs $want');
          expect(got.present, want.present);
        });

    same('empty', _es([]), 4);
    same('shorter than a day', _es([1, 2, 3]), 4);
    same('constant series (no variance)', _es(List.filled(12, 7)), 4);
    same('constant zero series', _es(List.filled(8, 0)), 4);
    same('exactly one day', _es([1, 5, 2, 8]), 4);
    same('partial trailing day uses n', _es([1, 5, 2, 8, 3, 9, 1]), 4);
    for (final p in [0, -1, -24]) {
      same('epochsPerDay $p', _es([1, 5, 2, 8, 3, 9, 1, 4]), p);
      same('epochsPerDay $p, empty', _es([]), p);
    }

    test('absent reasons differ', () {
      expect(circadianNpAggregator(4).run(_es([1, 2])).note,
          contains('≥1 full day'));
      expect(circadianNpAggregator(4).run(_es(List.filled(8, 3))).note,
          'no variance in activity series');
    });

    test('epochsPerDay <= 0 never throws on any path', () {
      final s = _es([for (var i = 0; i < 9; i++) i * 1.0]);
      final a = circadianNpAggregator(0);
      expect(a.finish(a.empty()).present, isFalse);
      expect(runChunked(a, s, [0, 4, 9]).present, isFalse);
      expect(runSliced(a, s, [0, 0, 5, 9]).present, isFalse);
    });
  });
}
