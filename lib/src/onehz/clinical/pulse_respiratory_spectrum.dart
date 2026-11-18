// Owner: analytics. Bounded respiratory evidence for pulse screening.

const pulseRespiratoryMinHz = 0.15;
const pulseRespiratoryMaxHz = 0.40;
const pulseRespiratoryConcentration = 0.12;
const pulseRespiratoryToleranceHz = 0.0234375;
const pulseRespiratoryProminence = 4.0;
const pulseRespiratoryBaselineRadius = 10;
const pulseRespiratorySampleMs = 500;
const pulseRespiratorySegmentSamples = 256;

const pulseRespiratoryFitHalfWidthHz = 1 / 256;
const pulseRespiratoryFitMinVariance = 0.12;
class PulseRespiratoryFit {
  final double frequencyHz, sineMs, cosineMs, explainedVariance;
  const PulseRespiratoryFit(
      this.frequencyHz, this.sineMs, this.cosineMs, this.explainedVariance);
  bool get strong => explainedVariance >= pulseRespiratoryFitMinVariance;
  double componentAt(double timeMs) => 0;

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

({double frequencyHz, double concentration, double prominence})?
pulseRespiratorySpectrum(List<int> times, List<double> values, int startMs, int endMs) => null;
PulseRespiratoryFit? pulseRespiratoryFit(List<int> times, List<double> values,
  int startMs, int endMs, double peakHz) => null;
