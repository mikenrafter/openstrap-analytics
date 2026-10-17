// Run with: dart run tool/bench_aggregate.dart
//
// Timings are medians of seven warmed runs on this process and machine.
import 'dart:math' as math;

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';

typedef Beat = ({double nnMs, double? timeMs});

Object? _sink;

void main() {
  final ints = List<int>.generate(86400, (i) => (i * 7919) % 2003 - 1001);
  final intAggregator = both(
      both(IntSum<int>((value) => value), const Count<int>()),
      both(Min<int>((value) => value), Max<int>((value) => value)));

  final beats = _beats(30000);
  final nn = [for (final beat in beats) beat.nnMs];
  final times = [for (final beat in beats) beat.timeMs!];
  final origin = beats.first.timeMs!;
  final hand = HrvTimeAggregator(originMs: origin);
  final composed = hrvTimeComposed(originMs: origin);

  final rows = <(String, String, int)>[
    ('86,400 ints', 'hand loop', _medianMicros(() => _intHandLoop(ints))),
    ('86,400 ints', 'both(both(sum, count), both(min, max)).run',
        _medianMicros(() => intAggregator.run(ints))),
    ('30,000 beats', 'hrvTime batch',
        _medianMicros(() => hrvTime(nn, nnTimesMs: times))),
    ('30,000 beats', 'HrvTimeAggregator.run',
        _medianMicros(() => hand.run(beats))),
    ('30,000 beats', 'hrvTimeComposed.run',
        _medianMicros(() => composed.run(beats))),
    ('30,000 beats', 'HrvTimeAggregator, 24 chunks + combine',
        _medianMicros(() => _runChunks(hand, beats, 24))),
    ('30,000 beats', 'hrvTimeComposed, 24 chunks + combine',
        _medianMicros(() => _runChunks(composed, beats, 24))),
  ];

  final handResult = hand.run(beats);
  final composedResult = composed.run(beats);
  final parity = _sameWithin(handResult.rmssd, composedResult.rmssd) &&
      _sameWithin(handResult.sdnn, composedResult.sdnn);

  print('Median microseconds (7 timed runs after 3 warm-up runs)');
  print('${'workload'.padRight(14)}  ${'operation'.padRight(46)}  us');
  for (final row in rows) {
    print('${row.$1.padRight(14)}  ${row.$2.padRight(46)}  ${row.$3}');
  }
  print('parity composed vs hand state: rmssd/sdnn within 1e-9 = $parity');
  if (!parity || _sink == null) {
    throw StateError('Benchmark parity or result observability failed');
  }
}

(int, int, int, int) _intHandLoop(List<int> values) {
  var sum = 0;
  var count = 0;
  var min = values.first;
  var max = values.first;
  for (final value in values) {
    sum += value;
    count++;
    if (value < min) min = value;
    if (value > max) max = value;
  }
  return (sum, count, min, max);
}

List<Beat> _beats(int count) {
  final random = math.Random(0xA661E6A7);
  final beats = <Beat>[];
  var time = 1000000.0;
  var nn = 900.0;
  for (var i = 0; i < count; i++) {
    nn = (nn + (random.nextDouble() - .5) * 24)
        .clamp(800.0, 1100.0)
        .toDouble();
    final gap = i > 0 && random.nextDouble() < .0007
        ? 1000 + random.nextDouble() * 30000
        : 0.0;
    time += nn + gap;
    beats.add((nnMs: nn, timeMs: time));
  }
  return beats;
}

R _runChunks<S, A, R>(Aggregator<S, A, R> aggregator, List<A> values,
    int chunkCount) {
  var state = aggregator.empty();
  for (var chunk = 0; chunk < chunkCount; chunk++) {
    final start = values.length * chunk ~/ chunkCount;
    final end = values.length * (chunk + 1) ~/ chunkCount;
    state = aggregator.combine(state, aggregator.foldRange(values, start, end));
  }
  return aggregator.finish(state);
}

int _medianMicros(Object? Function() action) {
  for (var warm = 0; warm < 3; warm++) {
    _sink = action();
  }
  final samples = <int>[];
  for (var run = 0; run < 7; run++) {
    final watch = Stopwatch()..start();
    _sink = action();
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

bool _sameWithin(double? a, double? b) {
  if (a == null || b == null) return a == b;
  return (a - b).abs() <= 1e-9;
}
