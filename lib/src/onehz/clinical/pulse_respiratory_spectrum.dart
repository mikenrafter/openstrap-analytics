// Owner: analytics. Bounded respiratory evidence for pulse screening.
import 'dart:math' as math;

const pulseRespiratoryMinHz = 0.15;
const pulseRespiratoryMaxHz = 0.40;
const pulseRespiratoryConcentration = 0.12;
const pulseRespiratoryToleranceHz = 0.0234375;
const pulseRespiratoryProminence = 4.0;
const pulseRespiratoryBaselineRadius = 10;
const pulseRespiratorySampleMs = 500;
const pulseRespiratorySegmentSamples = 256;

/// Welch power on a linearly resampled 2 Hz tachogram. Missing interpolation
/// support refuses evidence. Interpolation anchors are at most seven seconds
/// apart (the recording policy's five-second gap plus one plausible RR).
/// Remove a centered 10-second moving mean before estimating Welch power.
/// Concentration is three-bin peak power / total non-DC DETRENDED RR power.
/// Prominence compares its mean bin power with bins three through seven away.
/// CLAIM(pulse-respiratory-spectrum): a broad noise hump cannot alone establish
/// a respiratory cycle [pulse_respiratory_pair_test; pulse_respiratory_spectrum_test].
({double frequencyHz, double concentration, double prominence})?
pulseRespiratorySpectrum(
  List<int> times,
  List<double> values,
  int startMs,
  int endMs,
) {
  if (times.length < 200 || times.length != values.length) return null;
  final grid = <double>[];
  var next = 1;
  // Five-second edge trim leaves interpolation and detrending support.
  for (
    var t = startMs + 5000;
    t < endMs - 5000;
    t += pulseRespiratorySampleMs
  ) {
    while (next < times.length && times[next] < t) {
      next++;
    }
    if (next == times.length ||
        times[next - 1] > t ||
        times[next] - times[next - 1] > 7000 ||
        times[next] <= times[next - 1])
      return null;
    final fraction = (t - times[next - 1]) / (times[next] - times[next - 1]);
    grid.add(values[next - 1] + fraction * (values[next] - values[next - 1]));
  }
  const detrendSamples = pulseRespiratoryBaselineRadius;
  if (detrendSamples > 0) {
    final raw = [...grid];
    for (var i = 0; i < grid.length; i++) {
      final lo = math.max(0, i - detrendSamples),
          hi = math.min(raw.length, i + detrendSamples + 1);
      var baseline = 0.0;
      for (var j = lo; j < hi; j++) {
        baseline += raw[j];
      }
      grid[i] -= baseline / (hi - lo);
    }
  }
  const size = pulseRespiratorySegmentSamples;
  final power = List<double>.filled(size ~/ 2 + 1, 0);
  for (var offset = 0; offset + size <= grid.length; offset += size ~/ 2) {
    var center = 0.0;
    for (var i = 0; i < size; i++) {
      center += grid[offset + i];
    }
    center /= size;
    final real = [
      for (var i = 0; i < size; i++)
        (grid[offset + i] - center) *
            (0.5 - 0.5 * math.cos(2 * math.pi * i / (size - 1))),
    ];
    final imaginary = List<double>.filled(size, 0);
    _fft(real, imaginary);
    for (var k = 1; k <= size ~/ 2; k++) {
      power[k] +=
          (real[k] * real[k] + imaginary[k] * imaginary[k]) *
          (k == size ~/ 2 ? 1 : 2);
    }
  }
  var total = 0.0, peak = (pulseRespiratoryMinHz * size / 2).ceil();
  for (var k = 1; k < power.length; k++) {
    total += power[k];
    if (k * 2 / size >= pulseRespiratoryMinHz &&
        k * 2 / size <= pulseRespiratoryMaxHz &&
        power[k] > power[peak])
      peak = k;
  }
  if (total <= 0) return null;
  var concentrated = 0.0;
  for (
    var k = math.max(1, peak - 1);
    k <= math.min(power.length - 1, peak + 1);
    k++
  ) {
    concentrated += power[k];
  }
  // Nearby bins define the spectral background; a broad hump is not a peak.
  var background = 0.0, bins = 0;
  for (
    var k = math.max(1, peak - 7);
    k <= math.min(power.length - 1, peak + 7);
    k++
  ) {
    if ((k - peak).abs() <= 2) continue;
    background += power[k];
    bins++;
  }
  return (
    frequencyHz: peak * 2 / size,
    concentration: concentrated / total,
    prominence: background > 0 ? concentrated / (3 * background / bins) : 1e12,
  );
}

// Radix-2 FFT has bounded O(256 log 256) cost; no per-frequency trigonometry.
void _fft(List<double> real, List<double> imaginary) {
  final size = real.length;
  for (var i = 1, j = 0; i < size; i++) {
    var bit = size >> 1;
    while ((j & bit) != 0) {
      j ^= bit;
      bit >>= 1;
    }
    j ^= bit;
    if (i < j) {
      final r = real[i];
      real[i] = real[j];
      real[j] = r;
    }
  }
  for (var width = 2; width <= size; width <<= 1) {
    final angle = -2 * math.pi / width;
    final stepReal = math.cos(angle), stepImaginary = math.sin(angle);
    for (var offset = 0; offset < size; offset += width) {
      var wr = 1.0, wi = 0.0;
      for (var j = 0; j < width ~/ 2; j++) {
        final a = offset + j, b = a + width ~/ 2;
        final tr = wr * real[b] - wi * imaginary[b],
            ti = wr * imaginary[b] + wi * real[b];
        real[b] = real[a] - tr;
        imaginary[b] = imaginary[a] - ti;
        real[a] += tr;
        imaginary[a] += ti;
        final nextReal = wr * stepReal - wi * stepImaginary;
        wi = wr * stepImaginary + wi * stepReal;
        wr = nextReal;
      }
    }
  }
}
