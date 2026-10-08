// CLINICAL — the evidence behind an irregular-rhythm screen verdict.
//
// RED STUB (design 04 "PRV diagnostics"): the types exist so the contract
// tests compile; every behaviour throws UnimplementedError. Nothing here is
// computed yet.
//
// What it is for: `irregularBeatScreen` computes the beat counts, the cleaning
// counts and the per-5-minute-window counts on its way to a flag, then throws
// them away. A reader who sees "flagged" or "not screened" cannot tell why.
// [IrregularDiagnostics] keeps them, for a screen that RAN and for one that
// ABSTAINED (an abstention carries the counts that caused it).
//
// Absent stays absent: an input the caller did not give is null, never 0. The
// batch call and the streaming `IrregularScreenState` must produce the same
// diagnostics for the same beats, however chunked or restored.

import '../types.dart';
import 'irregular_rhythm.dart';

/// What the RR corrector did before the screen saw the beats. Only the caller
/// has it (the screen sees the corrected NN), so it is handed in; batch passes
/// the fields of `RrCorrectionResult`, streaming those of `RrSnapshot`.
class RrCleaningCounts {
  /// Beats fed to the corrector.
  final int raw;

  /// Isolated artifacts replaced by the spline.
  final int corrected;

  /// Beats dropped (part of a multi-beat run, or with no anchors to correct from).
  final int dropped;
  const RrCleaningCounts({
    required this.raw,
    required this.corrected,
    required this.dropped,
  });
}

/// Why a screen produced no value. Wire names (toJson): `too_few_beats`,
/// `artifact`, `no_successive_pairs`, `no_long_term_variability`.
enum IrregularAbstain {
  tooFewBeats,
  artifact,
  noSuccessivePairs,
  noLongTermVariability,
}

/// The final window of the series. A series always ends mid-window, so the last
/// window is OPEN; it is counted, not silently dropped. Wire names: `none`
/// (no beats at all), `thin` (fewer than minWindowBeats, excluded from the
/// valid count), `unflagged` (valid, not flagged), `flagged` (valid, flagged).
enum IrregularOpenWindow { none, thin, unflagged, flagged }

/// The thresholds the verdict was made against.
class IrregularThresholds {
  final int minBeats;
  final double maxArtifact;
  final double sd1sd2Flag;
  final double pnnThresholdMs;
  final double pnnFlagPct;
  final double windowMinutes;
  final int minWindowBeats;
  final double sustainedFraction;
  const IrregularThresholds({
    required this.minBeats,
    required this.maxArtifact,
    required this.sd1sd2Flag,
    required this.pnnThresholdMs,
    required this.pnnFlagPct,
    required this.windowMinutes,
    required this.minWindowBeats,
    required this.sustainedFraction,
  });
}

/// Per-window counts. Totals INCLUDE the open window; [open] says what it was.
class IrregularWindowCounts {
  /// Windows with at least one clean beat (a window opens on a beat).
  final int total;

  /// Windows with at least minWindowBeats beats (the ones that vote).
  final int valid;

  /// Valid windows where both SD1/SD2 and pNNx cleared their flag lines.
  final int flagged;

  /// The final window: its beat count and what became of it.
  final int openBeats;
  final IrregularOpenWindow open;
  const IrregularWindowCounts({
    required this.total,
    required this.valid,
    required this.flagged,
    required this.openBeats,
    required this.open,
  });

  /// flagged / valid, null (never 0 or NaN) when no window is valid.
  double? get sustainedObserved => throw UnimplementedError('red stub');
}

class IrregularDiagnostics {
  /// Null when the screen ran and produced a value.
  final IrregularAbstain? abstain;

  /// Beats fed to the corrector / corrected / dropped. Null when the caller did
  /// not hand [RrCleaningCounts] in (unknown, not zero).
  final int? rrRaw, corrected, dropped;

  /// NN entries handed to the screen (NaN and out-of-range included) and the
  /// ones inside [300, 2000] ms that it used (== `IrregularRhythm.nBeats`).
  final int nnIn, nnKept;

  /// The artifact fraction handed in (0 when none was).
  final double artifactFraction;

  /// Null when windows were not evaluated: no beat times (or a length that does
  /// not match the beats), or a window config that fails closed.
  final IrregularWindowCounts? windows;
  final IrregularThresholds thresholds;

  const IrregularDiagnostics({
    required this.abstain,
    required this.rrRaw,
    required this.corrected,
    required this.dropped,
    required this.nnIn,
    required this.nnKept,
    required this.artifactFraction,
    required this.windows,
    required this.thresholds,
  });

  /// See test/onehz/irregular_diagnostics_test.dart for the wire shape.
  Map<String, dynamic> toJson() => throw UnimplementedError('red stub');

  /// Throws [FormatException] on a map of another version or a malformed one.
  factory IrregularDiagnostics.fromJson(Map<String, dynamic> json) =>
      throw UnimplementedError('red stub');
}

/// A screen verdict and the evidence behind it.
class IrregularScreenResult {
  final Metric<IrregularRhythm> metric;
  final IrregularDiagnostics diagnostics;
  const IrregularScreenResult(this.metric, this.diagnostics);

  /// `metric.toJson((v) => v.toJson())` plus a `diagnostics` key: the envelope
  /// edge persists. The existing keys are unchanged.
  Map<String, dynamic> toJson() => throw UnimplementedError('red stub');
}

/// Same arguments and same verdict as [irregularBeatScreen], plus the evidence.
/// [cleaning] is what the corrector did upstream, if the caller knows.
IrregularScreenResult irregularBeatScreenDetailed(
  List<double> rrMs, {
  List<double>? nnTimesMs,
  double artifactFraction = 0.0,
  int minBeats = irregularScreenMinBeats,
  double sd1sd2Flag = 0.70,
  double pnnThresholdMs = 70,
  double pnnFlagPct = 30,
  double maxArtifact = 0.30,
  double windowMinutes = 5,
  int minWindowBeats = 40,
  double sustainedFraction = 0.5,
  RrCleaningCounts? cleaning,
}) =>
    throw UnimplementedError('red stub');
