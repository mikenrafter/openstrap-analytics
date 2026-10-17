// Shared HRV test helpers: beat-series generators and the hrvTime parity
// check. Copied from test/aggregate/hrv_time_aggregator_test.dart.

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import 'property.dart' show Rng;

typedef Beat = ({double nnMs, double? timeMs});

const double hrvT0 = 1000000.0;
const double hrvTol = 1e-9;

List<Object?> hrvFields(HrvTime v) =>
    [v.rmssd, v.sdnn, v.sdann, v.sdnnIndex, v.pnn50, v.diffAcf1];

final hrvEqAll = fieldsEqual<HrvTime>((v) => [...hrvFields(v), v.nBeats],
    relTol: hrvTol, absTol: hrvTol);

/// What hrvTime says, mapped to the aggregator's expectation.
HrvTime hrvExpected(List<Beat> beats, {required bool gapAware}) {
  final nn = [for (final b in beats) b.nnMs];
  final times = [for (final b in beats) b.timeMs ?? 0.0];
  final m = hrvTime(nn, nnTimesMs: gapAware ? times : null);
  return m.value ?? HrvTime(nBeats: beats.length);
}

void expectHrvParity(HrvTime got, HrvTime want, String tag) {
  expect(got.nBeats, want.nBeats, reason: '$tag: nBeats');
  for (final (name, a, b) in [
    ('rmssd', got.rmssd, want.rmssd),
    ('sdnn', got.sdnn, want.sdnn),
    ('sdann', got.sdann, want.sdann),
    ('sdnnIndex', got.sdnnIndex, want.sdnnIndex),
    ('pnn50', got.pnn50, want.pnn50),
    ('diffAcf1', got.diffAcf1, want.diffAcf1),
  ]) {
    expect(a == null, b == null, reason: '$tag: $name null-ness ($a vs $b)');
    if (a != null && b != null) {
      expect((a - b).abs() <= hrvTol + hrvTol * b.abs(), isTrue,
          reason: '$tag: $name $a vs $b');
    }
  }
}

/// Builds a beat series with times. Values are multiples of 0.5 so the gap
/// rule's float arithmetic is exact in both implementations.
///  mode 0: smooth (random walk), mode 1: white noise (jittery, so the
///  RMSSD/pNN50 floor nulls them), mode 2: slow beats (spans several 5-minute
///  bins in few beats).
/// [gapP] is the chance a beat is preceded by a hole; [withTimes] false leaves
/// every timeMs null.
List<Beat> hrvSeries(Rng r, int n, int mode,
    {double gapP = .05, bool withTimes = true}) {
  final out = <Beat>[];
  var t = hrvT0;
  var nn = mode == 2 ? 1700.0 : 800.0;
  for (var i = 0; i < n; i++) {
    switch (mode) {
      case 1:
        nn = 600 + r.intIn(0, 800) / 1.0;
      case 2:
        nn = (nn + r.intIn(-60, 60)).clamp(1200, 2000).toDouble();
      default:
        nn = (nn + r.intIn(-40, 40)).clamp(450, 1300).toDouble();
    }
    if (r.nextBool(.04)) nn += r.intIn(40, 200); // an occasional big step
    var extra = 0.0;
    if (i > 0) {
      final p = r.nextDouble();
      if (p < gapP) {
        // a hole; sometimes a whole 5-minute bin or more
        extra = r.nextBool(.15)
            ? r.intIn(300000, 700000).toDouble()
            : r.intIn(600, 30000).toDouble();
      } else if (p < gapP + .04) {
        extra = [0.5, 1.0, 0.0][r.nextInt(3)]; // right at the 0.5 ms tolerance
      }
    }
    t += nn + extra;
    out.add((nnMs: nn, timeMs: withTimes ? t : null));
  }
  return out;
}

/// Contiguous series with exact constant nn (acf1 undefined: zero variance).
List<Beat> hrvConstant(int n, double nn) =>
    [for (var i = 1; i <= n; i++) (nnMs: nn, timeMs: hrvT0 + i * nn)];
