import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  // why: main's unfinished-night refusal must retain the fork's requested
  // method; otherwise the serialized absence claims cardio for an HMM request.
  // CLAIM(unfinished-staging-provenance): no metric is produced at a day cut.
  test('unfinished HMM night keeps the requested method and abstains', () {
    const midnight = 1699920000;
    final accel = <AccelSample>[];
    final hr = <double>[];
    final noise = math.Random(11);
    for (var t = midnight + 12 * 3600; t < midnight + 86400; t++) {
      final still = t >= midnight + 20 * 3600 + 30 * 60;
      accel.add(AccelSample(t * 1000.0,
          still ? 0.01 * noise.nextDouble() : 0.4 * math.cos(t / 2), 0,
          still ? 1 : 1 + 0.3 * math.sin(t / 3)));
      hr.add(still ? 55 : 85);
    }
    final result = segmentSleep(accel, hr, tzOffsetSec: 0,
        recordContinues: true, method: StagingMethod.hmm628);
    expect(result.unfinished, isTrue);
    expect(result.tstSec, isNull);
    expect(result.stagingMethod, StagingMethod.hmm628);
    expect(result.toJson()['staging_method'], 'hmm628');
    expect(result.stagingEffectiveMethod, isNull);
  });
}
