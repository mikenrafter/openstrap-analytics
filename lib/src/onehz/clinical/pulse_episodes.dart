// Owner: analytics. Versioned experimental pulse timing policy, not diagnosis.
// CLAIM(pulse-closed): only certified, supported UTC windows vote [pulse_episodes_test].
import 'dart:math' as math;
import '../foundations/rr_correction.dart';
import '../foundations/rr_correction_kernel.dart';
import '../util.dart';

const pulseWindowMs = 300000;
const pulseDetectorVersion = 1;

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
  final String? day;
  const PulseWindowContext({this.asleep, this.motion, this.wear, this.charging, this.day});
}

class PulseBeatInput {
  final String id, source;
  final int index, timeMs, revision;
  final double rawMs;
  final bool timestampValid;
  const PulseBeatInput(
      {required this.id,
      required this.source,
      required this.index,
      required this.timeMs,
      required this.rawMs,
      this.revision = 0,
      this.timestampValid = true});
}

class PulseBeatEvidence {
  final String id, source, cleaningClass;
  final String? predecessorId, pairId;
  final int timeMs, index;
  final double rawMs, thresholdMs, baselineMs;
  final double? correctedMs, changeMs;
  final bool plausible, retained, corrected, dropped, featureUse, validAdjacent;
  final List<String> labels;
  const PulseBeatEvidence(
      {required this.id,
      required this.source,
      required this.timeMs,
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
  final List<String> reasons;
  final List<PulseBeatEvidence> beats;
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
      this.wear});
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
        'motion': motion,
        'wear': wear,
        'thresholds': {
          'ratio': 0.70,
          'pnnPct': 30,
          'pnnMs': 70,
          'pairs': 200,
          'coverage': 0.8,
          'gapMs': 5000,
          'cleaning': 0.3
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
  Map<String, List<List<int>>> baselineExclusions = const {},
}) {
  final sources = <String, List<PulseBeatInput>>{};
  for (final b in input) {
    (sources[b.source] ??= []).add(b);
  }
  final windows = <PulseWindow>[];
  final episodes = <PulseEpisode>[];
  for (final source in sources.keys.toList()..sort()) {
    final byId = <String, PulseBeatInput>{};
    final conflicts = <String>{};
    for (final b in sources[source]!) {
      final prior = byId[b.id];
      if (prior == null || b.revision > prior.revision) {
        byId[b.id] = b;
      } else if (b.revision == prior.revision &&
          (b.timeMs != prior.timeMs || b.rawMs != prior.rawMs)) {
        conflicts.add(b.id);
        // A refused conflicting revision still has deterministic evidence.
        if (b.timeMs < prior.timeMs ||
            (b.timeMs == prior.timeMs && b.rawMs.compareTo(prior.rawMs) < 0)) {
          byId[b.id] = b;
        }
      }
    }
    final ordered = byId.values.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final invalid = <String>{...conflicts};
    final beats = <PulseBeatInput>[];
    for (var i = 0; i < ordered.length; i++) {
      final b = ordered[i];
      if (!b.timestampValid || !b.rawMs.isFinite) invalid.add(b.id);
      var time = b.timeMs;
      if (i > 0 && time <= beats[i - 1].timeMs) {
        final previous = beats[i - 1].timeMs;
        if (previous - time > pulseOverlapToleranceMs) {
          invalid.add(b.id);
          invalid.add(ordered[i - 1].id);
        } else {
          time = previous;
        }
      }
      beats.add(time == b.timeMs
          ? b
          : PulseBeatInput(
              id: b.id,
              source: b.source,
              index: b.index,
              timeMs: time,
              rawMs: b.rawMs,
              revision: b.revision,
              timestampValid: b.timestampValid));
    }
    // Held times never decrease along the index, so this is detection order;
    // only a refused wrong clock can reorder anything.
    beats.sort((a, b) {
      final t = a.timeMs.compareTo(b.timeMs);
      return t == 0 ? a.index.compareTo(b.index) : t;
    });
    if (beats.isEmpty) continue;
    final first = math.max(
        (evaluateFromMs ?? sourceStartMs) ~/ pulseWindowMs * pulseWindowMs,
        beats.first.timeMs ~/ pulseWindowMs * pulseWindowMs);
    final last = math.min(
            math.min(completeThroughMs, beats.last.timeMs),
            evaluateToMs == null ? beats.last.timeMs : evaluateToMs - 1) ~/
        pulseWindowMs *
        pulseWindowMs;
    final ownWindows = <PulseWindow>[];
    // Binary cuts keep a long input O(w log n + n * bounded context).
    int cut(int time) {
      var lo = 0, hi = beats.length;
      while (lo < hi) {
        final mid = (lo + hi) ~/ 2;
        if (beats[mid].timeMs < time) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      return lo;
    }

    for (var start = first; start <= last; start += pulseWindowMs) {
      final end = start + pulseWindowMs;
      final supportStart = math.max(sourceStartMs, start - pulseWindowMs);
      final supportEnd = sourceEndMs == null
          ? end + pulseWindowMs
          : math.min(sourceEndMs, end + pulseWindowMs);
      final pending = end > completeThroughMs || supportEnd > completeThroughMs;
      final context = beats.sublist(cut(supportStart), cut(supportEnd));
      final evidence = _evidence(context);
      final evidenceById = {for (final b in evidence) b.id: b};
      final own = [
        for (final b in evidence)
          if (b.timeMs >= start && b.timeMs < end) b
      ];
      final diffs = <double>[];
      for (final b in own) {
        if (b.validAdjacent && b.correctedMs != null) {
          final prev = evidenceById[b.predecessorId]!;
          diffs.add(b.correctedMs! - prev.correctedMs!);
        }
      }
      final values = [
        for (final b in own)
          if (b.featureUse) b.correctedMs!
      ];
      final sdsd = stddev(diffs), sdnn = stddev(values);
      final sd1 = sdsd == null ? null : sdsd / math.sqrt2;
      final variance =
          sd1 == null || sdnn == null ? null : 2 * sdnn * sdnn - sd1 * sd1;
      final sd2 = variance != null && variance > 0 ? math.sqrt(variance) : null;
      final ratio = sd1 != null && sd2 != null ? sd1 / sd2 : null;
      final pnn = diffs.isEmpty
          ? null
          : 100 * diffs.where((d) => d.abs() > 70).length / diffs.length;
      var coverage = 0.0, cursor = start.toDouble(), gap = 0.0;
      // Union of usable raw interval support, never a sum of overlapping intervals.
      for (final b in own) {
        if (!b.featureUse) continue;
        final lo = math.max(start.toDouble(), b.timeMs - b.rawMs);
        final hi = math.min(end.toDouble(), b.timeMs.toDouble());
        gap = math.max(gap, lo - cursor);
        if (hi > cursor) {
          coverage += hi - math.max(cursor, lo);
          cursor = hi;
        }
      }
      gap = math.max(gap, end - cursor);
      final cleaned = own.where((b) => b.corrected || b.dropped).length;
      final reasons = <String>[
        if (context.any((b) => invalid.contains(b.id))) 'timestamps',
        if (start < sourceStartMs) 'incompleteSupport',
        if (diffs.length < 200) 'pairs',
        if (coverage / pulseWindowMs < 0.8) 'coverage',
        if (gap > 5000) 'gaps',
        if (own.isNotEmpty && cleaned / own.length > 0.3) 'cleaning',
        if (ratio == null) 'degenerate',
      ];
      ownWindows.add(PulseWindow(
          source: source,
          startMs: start,
          endMs: end,
          pairs: diffs.length,
          totalBeats: own.length,
          cleanedBeats: cleaned,
          coverageMs: coverage,
          longestGapMs: gap,
          sd1: sd1,
          sd2: sd2,
          ratio: ratio,
          pnnPct: pnn,
          pending: pending,
          qualified: !pending && reasons.isEmpty && ratio! >= 0.7 && pnn! >= 30,
          reasons: reasons,
          beats: own));
    }
    var run = <PulseWindow>[];
    void finish(bool ongoing) {
      if (run.length >= 2)
        episodes.add(
            PulseEpisode(source, List.unmodifiable(run), ongoing: ongoing));
      run = [];
    }

    for (final w in ownWindows) {
      if (w.pending) {
        finish(true);
        break;
      }
      if (w.qualified) {
        run.add(w);
      } else {
        finish(false);
      }
    }
    finish(true);
    windows.addAll(ownWindows);
  }
  return PulseDetection(
      List.unmodifiable(windows), List.unmodifiable(episodes));
}

List<PulseBeatEvidence> _evidence(List<PulseBeatInput> input) {
  if (input.isEmpty) return [];
  final raw = [for (final b in input) b.rawMs.isFinite ? b.rawMs : 0.0];
  final correction = correctRr(raw);
  final classes = correction.classes;
  final artifacts = [for (final c in classes) c != BeatClass.normal];
  final corrected = List<double?>.filled(raw.length, null);
  for (var j = 0; j < correction.nnSourceIndex.length; j++) {
    corrected[correction.nnSourceIndex[j]] = correction.nn[j];
  }
  final differences = [
    0.0,
    for (var i = 1; i < raw.length; i++) raw[i] - raw[i - 1]
  ];
  final thresholds = <double>[], baselines = <double>[];
  for (var i = 0; i < raw.length; i++) {
    final lo = math.max(0, i - 45), hi = math.min(raw.length, i + 46);
    final d = differences.sublist(lo, hi)..sort();
    final r = raw.sublist(lo, hi)..sort();
    thresholds.add(thresholdOfSorted(d, 5.2, 100));
    baselines.add(medianExcluding(r, raw[i]) ?? raw[i]);
  }
  bool adjacent(int i) =>
      i > 0 &&
      input[i].index == input[i - 1].index + 1 &&
      input[i].timeMs > input[i - 1].timeMs &&
      ((input[i].timeMs - input[i - 1].timeMs) - raw[i]).abs() <= 1000;
  final pairs = <int, String>{};
  for (var i = 1; i < raw.length; i++) {
    if (!adjacent(i) || i < 2 || !adjacent(i - 1)) continue;
    if (differences[i] * differences[i - 1] < 0 &&
        differences[i].abs() > thresholds[i] &&
        differences[i - 1].abs() > thresholds[i - 1] &&
        (raw[i] + raw[i - 1] - 2 * baselines[i]).abs() <= 0.4 * baselines[i]) {
      pairs[i - 1] = pairs[i] = '${input[i - 1].id}/${input[i].id}';
    }
  }
  return [
    for (var i = 0; i < raw.length; i++)
      PulseBeatEvidence(
          id: input[i].id,
          source: input[i].source,
          timeMs: input[i].timeMs,
          index: input[i].index,
          rawMs: raw[i],
          correctedMs: corrected[i],
          changeMs: adjacent(i) ? differences[i] : null,
          predecessorId: i > 0 ? input[i - 1].id : null,
          pairId: pairs[i],
          thresholdMs: thresholds[i],
          baselineMs: baselines[i],
          cleaningClass: classes[i].name,
          plausible: raw[i] >= 300 && raw[i] <= 2000,
          retained: corrected[i] != null,
          corrected: artifacts[i] && corrected[i] != null,
          dropped: corrected[i] == null,
          featureUse: corrected[i] != null &&
              corrected[i]! >= 300 &&
              corrected[i]! <= 2000,
          validAdjacent: adjacent(i) &&
              corrected[i] != null &&
              corrected[i - 1] != null &&
              corrected[i]! >= 300 &&
              corrected[i]! <= 2000 &&
              corrected[i - 1]! >= 300 &&
              corrected[i - 1]! <= 2000,
          labels: [
            if (adjacent(i) && differences[i] > thresholds[i]) 'suddenLong',
            if (adjacent(i) && differences[i] < -thresholds[i]) 'suddenShort',
            if (pairs.containsKey(i)) 'shortLongPair',
            if (classes[i] == BeatClass.extra) 'likelyExtra',
            if (classes[i] == BeatClass.missed) 'likelyMissed',
            if (artifacts[i] && corrected[i] != null) 'corrected',
            if (corrected[i] == null) 'dropped'
          ])
  ];
}
