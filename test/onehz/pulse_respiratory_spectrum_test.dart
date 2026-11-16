import 'dart:math';
import 'package:test/test.dart';
import 'package:openstrap_analytics/src/onehz/clinical/pulse_respiratory_spectrum.dart';

void main() {
  // WHY/CLAIM(pulse-respiratory-spectrum): an independent four-second sinusoid
  // has a known 0.25 Hz peak. # catches: unit errors or a broken FFT/resampler.
  test('four-second sinusoid has the known respiratory peak', () {
    final spectrum = pulseRespiratorySpectrum(
      [for (var i = 0; i < 301; i++) i * 1000],
      [for (var i = 0; i < 301; i++) 1150 + 100 * sin(2 * pi * i / 4)],
      0,
      300000,
    )!;
    expect(spectrum.frequencyHz, 0.25);
    expect(spectrum.concentration, greaterThan(0.90));
    expect(spectrum.prominence, greaterThan(10));
  });
  // WHY: source-free or gapped recordings cannot manufacture spectral support.
  // # catches: extrapolating window edges or interpolating arbitrary missing spans.
  test('missing edges and large gaps refuse respiratory evidence', () {
    final times = [for (var i = 0; i < 301; i++) i * 1000];
    final values = [
      for (var i = 0; i < 301; i++) 1150 + 100 * sin(2 * pi * i / 4),
    ];
    expect(
      pulseRespiratorySpectrum(
        times.sublist(10),
        values.sublist(10),
        0,
        300000,
      ),
      isNull,
    );
    expect(
      pulseRespiratorySpectrum(
        [...times.take(140), ...times.skip(150)],
        [...values.take(140), ...values.skip(150)],
        0,
        300000,
      ),
      isNull,
    );
  });
  // WHY/CLAIM(pulse-respiratory-residual): a narrow fit removes only its known
  // component. # catches: a broad filter or a wrong frequency/time unit.
  test('narrow sinusoid fit has the known interpolation attenuation', () {
    final times = [for (var i = 0; i <= 300; i++) i * 1000];
    final values = [
      for (var i = 0; i <= 300; i++) 1150 + 100 * sin(2 * pi * i / 4)
    ];
    final fit = pulseRespiratoryFit(times, values, 0, 300000, .25)!;
    expect(fit.strong, isTrue);
    expect(fit.frequencyHz, .25);
    // Linear interpolation on half-second grid has fundamental amplitude
    // 100*(1+cos(pi/4))/2 = 85.3553 ms. Fitting does not undo attenuation.
    expect(fit.componentAt(1000), closeTo(85.3553, .1));
    expect(fit.componentAt(0), closeTo(0, .1));
    expect(fit.explainedVariance, closeTo(0.9714, .001));
  });
  // WHY: weak or unsupported fits must keep the fixed-floor decision.
  // # catches: treating any least-squares solution as independent exclusion.
  test('fit refuses degenerate, missing, out-of-band and weak evidence', () {
    final times = [for (var i = 0; i <= 300; i++) i * 1000];
    final random = Random(40);
    final noise = [
      for (var i = 0; i <= 300; i++) 1150 + 120 * (2 * random.nextDouble() - 1)
    ];
    expect(
        pulseRespiratoryFit(
            times, List.filled(times.length, 1150), 0, 300000, .25),
        isNull);
    expect(
        pulseRespiratoryFit(
            times.sublist(10), noise.sublist(10), 0, 300000, .25),
        isNull);
    expect(pulseRespiratoryFit(times, noise, 0, 300000, .10), isNull);
    expect(pulseRespiratoryFit(times, noise, 0, 300000, .25)!.strong, isFalse);
  });
}
