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
}
