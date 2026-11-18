// Owner: analytics. Versioned experimental pulse timing policy, not diagnosis.
// CLAIM(pulse-closed): only certified, supported UTC windows vote [pulse_episodes_test].
import 'pulse_respiratory_spectrum.dart';

const pulseWindowMs = 300000;
// v4: matched respiratory spectra only trigger a narrow sinusoid fit;
// original beat-domain residuals must fail fixed floors before exclusion.
// V1 stored decisions stay frozen; v2 and later decisions remain correctable.
const pulseDetectorVersion = 4;
const pulseSleepMaxBpm = 65.0;
const pulseMotionThresholdG = 0.05;
const pulseContextMinSamples = 240;
const pulseMovingMinSamples = 30;

/// How far one record's first beat may sit before the previous record's last
/// beat before the clock is called wrong. `beat_ts_ms` is a modelled position
/// (the last beat of a record is put at its stamp, earlier beats walk back by
/// their intervals), so adjacent records overlap by under one interval; two
/// real exports show steps back of 1.7-1.8 s at most, 0.2-0.4% of beats. One
/// maximal plausible interval (2 s) is the bound on that model error.
const pulseOverlapToleranceMs = 2000;

/// Per-window committed context. Null measurements are explicitly unknown.
class PulseWindowContext {
  final bool? asleep, motion, wear, charging;
  const PulseWindowContext({this.asleep, this.motion, this.wear, this.charging});
}

class PulseBeatInput {
  final String id, source;
  final int index, timeMs, revision;
  final int originalTimeMs;
  final double rawMs;
  final bool timestampValid;
  const PulseBeatInput(
      {required this.id,
      required this.source,
      required this.index,
      required this.timeMs,
      required this.rawMs,
      this.revision = 0,
      this.timestampValid = true,
      int? originalTimeMs}) : originalTimeMs = originalTimeMs ?? timeMs;
}

class PulseBeatEvidence {
  final String id, source, cleaningClass;
  final String? predecessorId, pairId;
  final int timeMs, originalTimeMs, index;
  final double rawMs, thresholdMs, baselineMs;
  final double? correctedMs, changeMs;
  final bool plausible, retained, corrected, dropped, featureUse, validAdjacent;
  final List<String> labels;
  const PulseBeatEvidence(
      {required this.id,
      required this.source,
      required this.timeMs,
      required this.originalTimeMs,
      required this.index,
      required this.rawMs,
      required this.correctedMs,
      required this.changeMs,
      required this.predecessorId,
      required this.pairId,
      required this.thresholdMs,
      required this.baselineMs,
      required this.cleaningClass,
      required this.plausible,
      required this.retained,
      required this.corrected,
      required this.dropped,
      required this.featureUse,
      required this.validAdjacent,
      required this.labels});
  Map<String, dynamic> toJson() => {
        'id': id,
        'source': source,
        'time': timeMs,
        'originalTime': originalTimeMs,
        'placement': timeMs == originalTimeMs ? 'original' : 'heldOverlap',
        'index': index,
        'raw': rawMs,
        'value': correctedMs,
        'change': changeMs,
        'predecessor': predecessorId,
        'pair': pairId,
        'threshold': thresholdMs,
        'baseline': baselineMs,
        'class': cleaningClass,
        'plausible': plausible,
        'retained': retained,
        'corrected': corrected,
        'dropped': dropped,
        'feature': featureUse,
        'adjacent': validAdjacent,
        'labels': labels
      };
}

class PulseWindow {
  final String source;
  final int startMs, endMs, pairs, totalBeats, cleanedBeats;
  final double coverageMs, longestGapMs;
  final double? sd1, sd2, ratio, pnnPct;
  final bool pending, qualified;
  final bool? motion, wear;
  final PulseWindowContext context;
  final double? lag3, lag4, heartRate;
  final double? breathingPeakHz, breathingConcentration, breathingProminence;
  final int? breathingPartnerMs;
  final Map<String, Object?>? breathingResidual;
  final double ratioThreshold, pnnThreshold;
  final List<String> reasons;
  final List<PulseBeatEvidence> beats;
  // Semantic exclusion never means that the recording itself was inadequate.
  static const semanticReasons = {'motion', 'offWrist', 'charging', 'sleepBreathing'};
  List<String> get qualityReasons => reasons.where((r) => !semanticReasons.contains(r)).toList();
  List<String> get exclusionReasons => reasons.where(semanticReasons.contains).toList();
  const PulseWindow(
      {required this.source,
      required this.startMs,
      required this.endMs,
      required this.pairs,
      required this.totalBeats,
      required this.cleanedBeats,
      required this.coverageMs,
      required this.longestGapMs,
      required this.sd1,
      required this.sd2,
      required this.ratio,
      required this.pnnPct,
      required this.pending,
      required this.qualified,
      required this.reasons,
      required this.beats,
      this.motion,
      this.wear,
      this.context = const PulseWindowContext(),
      this.lag3, this.lag4, this.heartRate,
      this.breathingPeakHz, this.breathingConcentration, this.breathingProminence, this.breathingPartnerMs, this.breathingResidual,
      this.ratioThreshold = 0.7, this.pnnThreshold = 30,
});
  Map<String, dynamic> toJson({bool evidence = true}) => {
        'source': source,
        'start': startMs,
        'end': endMs,
        'pairs': pairs,
        'total': totalBeats,
        'cleaned': cleanedBeats,
        'coverageMs': coverageMs,
        'durationMs': pulseWindowMs,
        'gapMs': longestGapMs,
        'sd1': sd1,
        'sd2': sd2,
        'ratio': ratio,
        'pnnPct': pnnPct,
        'pending': pending,
        'qualified': qualified,
        'reasons': reasons,
        'qualityReasons': qualityReasons, 'exclusionReasons': exclusionReasons,
        'motion': motion,
        'wear': wear,
        'context': {
          'status': motion == null || wear == null ? 'unknown' : 'known',
          'asleep': context.asleep, 'motion': motion, 'wear': wear,
          'charging': context.charging,
          'motionThresholdG': pulseMotionThresholdG,
          'minContextSamples': pulseContextMinSamples,
          'minMovingSamples': pulseMovingMinSamples,
        },
        'breathing': {'lag3': lag3, 'lag4': lag4, 'heartRate': heartRate,
          'peakHz': breathingPeakHz, 'concentration': breathingConcentration,
          'prominence': breathingProminence, 'minProminence': pulseRespiratoryProminence,
          'baselineRadiusSamples': pulseRespiratoryBaselineRadius, 'edgeTrimMs': 5000,
          'partnerStartMs': breathingPartnerMs, 'residual': breathingResidual,
          'minHz': pulseRespiratoryMinHz, 'maxHz': pulseRespiratoryMaxHz,
          'minConcentration': pulseRespiratoryConcentration,
          'frequencyToleranceHz': pulseRespiratoryToleranceHz,
          'sampleMs': pulseRespiratorySampleMs, 'clock': 'rr_cumulative',
          'segmentSamples': pulseRespiratorySegmentSamples,
          'maxSleepBpm': pulseSleepMaxBpm},
        'thresholds': {
          'ratio': ratioThreshold,
          'pnnPct': pnnThreshold,
          'pnnMs': 70,
          'pairs': 200,
          'coverage': 0.8,
          'gapMs': 5000,
          'cleaning': 0.3,
          'ratioComparison': '>=', 'pnnComparison': '>=',
          'pairsComparison': '>=', 'coverageComparison': '>=',
          'gapComparison': '<=', 'cleaningComparison': '<='
        },
        if (evidence) 'beats': [for (final b in beats) b.toJson()]
      };
}

class PulseEpisode {
  final String source;
  final List<PulseWindow> windows;
  final bool ongoing;
  const PulseEpisode(this.source, this.windows, {required this.ongoing});
  // Namespace and seed are independent of algorithm/revision and interval values.
  String get id => '$source:$startMs';
  int get startMs => windows.first.startMs;
  int get endMs => windows.last.endMs;
  bool get alertEligible =>
      windows.every((w) => w.qualified && w.reasons.isEmpty);
  List<PulseBeatEvidence> get beats => [for (final w in windows) ...w.beats];
  Map<String, dynamic> toJson() => {
        'id': id,
        'source': source,
        'start': startMs,
        'end': endMs,
        'ongoing': ongoing,
        'version': pulseDetectorVersion,
        'alertEligible': alertEligible,
        'windows': [for (final w in windows) w.toJson(evidence: false)],
        'beats': [for (final b in beats) b.toJson()]
      };
}

class PulseDetection {
  final List<PulseWindow> windows;
  final List<PulseEpisode> episodes;
  const PulseDetection(this.windows, this.episodes);
  Map<String, dynamic> toJson() => {
        'windows': [for (final w in windows) w.toJson()],
        'episodes': [for (final e in episodes) e.toJson()]
      };
}

/// Reconstructable streaming contract: pass canonical durable inputs plus a
/// certified completeness watermark, not wall time. Fixed +/-5 minute cleaning
/// context is clipped only at explicit source boundaries. Re-evaluation is pure.
/// Callers must persist revisions on late replacements behind the watermark.
///
/// [sourceStartMs] is where the source REALLY starts: the cleaning context is
/// clipped there and nowhere else. A query range is not a source boundary, so a
/// caller that reads only part of a source passes [evaluateFromMs] /
/// [evaluateToMs] (window starts in `[from, to)`) and supplies every beat from
/// five minutes before `from` to five minutes after `to`; each window then has
/// its whole context and decides exactly as it would in any other range.
///
/// Context belongs to one source. Evaluate sources separately when their
/// sensor contexts differ. Missing context never blocks fixed-floor qualification.
/// No personal-history read or learned threshold is part of detector v4.
///
/// Time order and detection order are not the same thing at a record overlap:
/// a beat that lands before its predecessor (by at most
/// [pulseOverlapToleranceMs]) is HELD at the predecessor's time, so the
/// interval series keeps the order the band detected it in and only the pair
/// across the overlap loses adjacency. A step back by more than the tolerance
/// is a wrong clock, and refuses the whole context.
PulseDetection detectPulseEpisodes(
  List<PulseBeatInput> input, {
  required int completeThroughMs,
  required int sourceStartMs,
  int? sourceEndMs,
  int? evaluateFromMs,
  int? evaluateToMs,
  Map<int, PulseWindowContext> context = const {},
}) => const PulseDetection([], []);
