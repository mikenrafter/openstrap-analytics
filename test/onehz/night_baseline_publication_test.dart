import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  test('default cardio segmentation publishes measured baselines', () {
    const start = 1782532800, span = 4 * 3600;
    final result = segmentSleep(
      [for (var i = 0; i < span; i++) AccelSample((start+i)*1000.0,0,0,1)],
      List<double>.filled(span, 60),
      rrMs: [for (var i = 0; i < span; i++) i.isEven ? 1000.0 : 1100.0],
      rrTsMs: [for (var i = 0; i < span; i++) (start+i)*1000.0],
      forcedWindow: (onsetSec: start, offsetSec: start + span),
    );
    expect(result.tstSec, greaterThan(0)); // positive control: measured night
    final json = result.toJson();
    expect(json['hr_min_night'], 60);
    // All adjacent differences are 100: sqrt(mean(100^2))=100 ms.
    expect(json['rmssd_mean_night'], closeTo(100, 1e-9));
  });
}
