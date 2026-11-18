// Owner: analytics. Bounded respiratory evidence for pulse screening.
// Welch 1967, IEEE Trans. Audio Electroacoustics 15(2):70–73, supplies the
// segmented spectral estimator. Peak thresholds and single-fit exclusion are
// internal ESTIMATE policy with low confidence [Pulse structural spec 5.2].
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
  final grid = _tachogram(times, values, startMs, endMs);
  if (grid == null) return null;
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
      power[k] += (real[k] * real[k] + imaginary[k] * imaginary[k]) *
          (k == size ~/ 2 ? 1 : 2);
    }
  }
  var total = 0.0, peak = (pulseRespiratoryMinHz * size / 2).ceil();
  for (var k = 1; k < power.length; k++) {
    total += power[k];
    if (k * 2 / size >= pulseRespiratoryMinHz &&
        k * 2 / size <= pulseRespiratoryMaxHz &&
        power[k] > power[peak]) peak = k;
  }
  if (total <= 0) return null;
  var concentrated = 0.0;
  for (var k = math.max(1, peak - 1);
      k <= math.min(power.length - 1, peak + 1);
      k++) {
    concentrated += power[k];
  }
  // Nearby bins define the spectral background; a broad hump is not a peak.
  var background = 0.0, bins = 0;
  for (var k = math.max(1, peak - 7);
      k <= math.min(power.length - 1, peak + 7);
      k++) {
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

// A single frequency, refined only inside its Welch bin. This cannot subtract
// an arbitrary respiratory band, harmonics, or a freely varying phase envelope.
const pulseRespiratoryFitHalfWidthHz = 1 / 256;
const pulseRespiratoryFitMinVariance = 0.12;

class PulseRespiratoryFit {
  final double frequencyHz, sineMs, cosineMs, explainedVariance;
  const PulseRespiratoryFit(
      this.frequencyHz, this.sineMs, this.cosineMs, this.explainedVariance);
  bool get strong => explainedVariance >= pulseRespiratoryFitMinVariance;
  double componentAt(double timeMs) {
    final phase = 2 * math.pi * frequencyHz * timeMs / 1000;
    return sineMs * math.sin(phase) + cosineMs * math.cos(phase);
  }

  Map<String, Object?> toJson() => {
        'status': strong ? 'supported' : 'weak',
        'frequencyHz': frequencyHz,
        'sineMs': sineMs,
        'cosineMs': cosineMs,
        'explainedVariance': explainedVariance,
        'minExplainedVariance': pulseRespiratoryFitMinVariance,
        'halfWidthHz': pulseRespiratoryFitHalfWidthHz,
      };
}

/// Least squares intercept + one sinusoid on the ORIGINAL (not detrended)
/// 2 Hz tachogram. Returns null on missing support or degenerate variance.
/// A weak fit is diagnostic only; it must never justify an exclusion.
/// CLAIM(pulse-respiratory-residual): only a narrow explained component is
/// removed before beat-domain floors are reapplied [pulse_residual_test].
PulseRespiratoryFit? pulseRespiratoryFit(List<int> times, List<double> values,
    int startMs, int endMs, double peakHz) {
  if (!peakHz.isFinite ||
      peakHz < pulseRespiratoryMinHz ||
      peakHz > pulseRespiratoryMaxHz) return null;
  final grid = _tachogram(times, values, startMs, endMs);
  if (grid == null || grid.any((v) => !v.isFinite)) return null;
  final n = grid.length;
  final center = grid.reduce((a, b) => a + b) / n;
  final y = [for (final v in grid) v - center];
  final total = y.fold<double>(0, (s, v) => s + v * v);
  if (!total.isFinite || total <= 1e-9) return null;
  PulseRespiratoryFit? best;
  // 33 candidates span ONE FFT bin (0.0078125 Hz), not the respiratory band.
  for (var k = -16; k <= 16; k++) {
    final hz = peakHz + k * pulseRespiratoryFitHalfWidthHz / 16;
    if (hz < pulseRespiratoryMinHz || hz > pulseRespiratoryMaxHz) continue;
    final angle = 2 * math.pi * hz * (startMs + 5000) / 1000;
    final step = 2 * math.pi * hz * pulseRespiratorySampleMs / 1000;
    final stepSin = math.sin(step), stepCos = math.cos(step);
    var sn = math.sin(angle), cs = math.cos(angle);
    var ss = 0.0,
        cc = 0.0,
        sc = 0.0,
        sy = 0.0,
        cy = 0.0,
        sumS = 0.0,
        sumC = 0.0;
    for (var i = 0; i < n; i++) {
      sumS += sn;
      sumC += cs;
      ss += sn * sn;
      cc += cs * cs;
      sc += sn * cs;
      sy += sn * y[i];
      cy += cs * y[i];
      final next = sn * stepCos + cs * stepSin;
      cs = cs * stepCos - sn * stepSin;
      sn = next;
    }
    ss -= sumS * sumS / n;
    cc -= sumC * sumC / n;
    sc -= sumS * sumC / n;
    final determinant = ss * cc - sc * sc;
    if (determinant <= 1e-9 || !determinant.isFinite) continue;
    final a = (sy * cc - cy * sc) / determinant,
        b = (cy * ss - sy * sc) / determinant;
    final explained = (a * sy + b * cy) / total;
    if (!explained.isFinite || explained < 0 || explained > 1 + 1e-6) continue;
    if (best == null || explained > best.explainedVariance) {
      best = PulseRespiratoryFit(hz, a, b, explained);
    }
  }
  return best;
}

List<double>? _tachogram(
    List<int> times, List<double> values, int startMs, int endMs) {
  if (times.length < 200 || times.length != values.length) return null;
  final grid = <double>[];
  var next = 1;
  // Five-second edge trim leaves interpolation and detrending support.
  for (var t = startMs + 5000;
      t < endMs - 5000;
      t += pulseRespiratorySampleMs) {
    while (next < times.length && times[next] < t) {
      next++;
    }
    if (next == times.length ||
        times[next - 1] > t ||
        times[next] - times[next - 1] > 7000 ||
        times[next] <= times[next - 1]) return null;
    final fraction = (t - times[next - 1]) / (times[next] - times[next - 1]);
    grid.add(values[next - 1] + fraction * (values[next] - values[next - 1]));
  }
  return grid.length >= 256 ? grid : null;
}
