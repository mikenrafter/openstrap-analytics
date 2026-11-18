import 'dart:convert';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';
import 'pulse_episodes_test.dart' as f;

PulseWindow window(List<PulseBeatInput> beats) => detectPulseEpisodes(beats,
  sourceStartMs: 0, sourceEndMs: 300000, completeThroughMs: 300000,
  evaluateFromMs: 0, evaluateToMs: 300000).windows.single;
List<PulseBeatInput> steady(int count, {double rr = 1000, int offset = 1000}) => [
  for (var i = 0; i < count; i++) PulseBeatInput(id: 's:$i', source: 'strap',
    index: i, timeMs: offset + i * 1000, rawMs: rr),
];
void main() {
  // WHY/CLAIM(pulse-closed): replacement history cannot change the outcome
  // depending on admission order. Only the highest revision owns the beat.
  // # catches: leaving an obsolete equal-revision conflict latched forever.
  test('newer revisions supersede obsolete conflicts in either arrival order', () {
    final beats = f.trace(25), b = f.trace(25)[100];
    final conflict = PulseBeatInput(id: b.id, source: b.source, index: b.index,
      timeMs: b.timeMs + 1, rawMs: b.rawMs + 100);
    final replacement = PulseBeatInput(id: b.id, source: b.source, index: b.index,
      timeMs: b.timeMs, rawMs: b.rawMs, revision: 1);
    String run(List<PulseBeatInput> input) => jsonEncode(detectPulseEpisodes(input,
      sourceStartMs: 0, completeThroughMs: 1200000).toJson());
    expect(run([...beats, conflict, replacement]), run([replacement, conflict, ...beats]));
    expect(run([...beats, conflict, replacement]), run(beats));
  });
  // WHY/CLAIM(pulse-closed): two arbitrary transport chunkings reconstruct
  // byte-identical closed evidence and stable seeds from canonical inputs.
  // # catches: retaining per-chunk cleaner state or map insertion ordering.
  test('all-at-once and two chunkings have byte-identical closed evidence', () {
    final beats = f.bandTrace(30);
    String evidence(List<PulseBeatInput> input) => jsonEncode(detectPulseEpisodes(input,
      sourceStartMs: 0, completeThroughMs: 1500000).toJson());
    final all = evidence(beats);
    for (final cut in [177, beats.length ~/ 2]) {
      final durable = <String, PulseBeatInput>{};
      for (final chunk in [beats.sublist(0, cut), beats.sublist(cut)]) {
        for (final b in chunk) { durable[b.id] = b; }
        detectPulseEpisodes(durable.values.toList(), sourceStartMs: 0,
          completeThroughMs: chunk.last.timeMs);
      }
      expect(evidence(durable.values.toList()), all);
      expect(evidence(durable.values.toList().reversed.toList()), all);
    }
  });
  // WHY/CLAIM(pulse-fixed-support): equality at each documented floor matters.
  // # catches: off-by-one pair/coverage tests and summing interval coverage.
  test('199/200 usable pairs and 79.9/80 percent union coverage', () {
    final few = window(steady(200));
    final enough = window(steady(201));
    expect(few.pairs, 199);
    expect(few.qualityReasons, contains('pairs'));
    expect(enough.pairs, 200);
    expect(enough.qualityReasons, isNot(contains('pairs')));
    final below = window(steady(300, rr: 799, offset: 799));
    final exact = window(steady(300, rr: 800, offset: 800));
    expect(below.coverageMs, 239700);
    expect(below.qualityReasons, contains('coverage'));
    expect(exact.coverageMs, 240000);
    expect(exact.qualityReasons, isNot(contains('coverage')));
    expect(exact.toJson()['thresholds'], containsPair('coverageComparison', '>='));
  });
  // WHY/CLAIM(pulse-fixed-support): five seconds is inclusive, without gap pairs.
  // # catches: >= gap refusal and pairing filtered survivors.
  test('five-second gap passes; six seconds refuses; neither bridges adjacency', () {
    final exact = window(steady(299)..removeWhere((b) => b.index >= 99 && b.index < 104));
    final over = window(steady(299)..removeWhere((b) => b.index >= 99 && b.index < 105));
    expect(exact.longestGapMs, 5000);
    expect(exact.qualityReasons, isNot(contains('gaps')));
    expect(over.longestGapMs, 6000);
    expect(over.qualityReasons, contains('gaps'));
    expect(exact.beats.firstWhere((b) => b.index == 104).validAdjacent, false);
  });
  // WHY/CLAIM(pulse-fixed-support): corrected-plus-dropped share is inclusive.
  // # catches: rejecting exactly 30 percent or counting only corrected beats.
  test('30 percent cleaning passes; the next dropped beat refuses', () {
    PulseWindow cleaned(int count) => window([
      for (var i = 0; i < 300; i++) PulseBeatInput(id: 's:$i', source: 'strap',
        index: i, timeMs: 500 + i * 1000, rawMs: i < count ? 2500 : 1000),
    ]);
    final exact = cleaned(90), over = cleaned(91);
    expect(exact.totalBeats, 300);
    expect(exact.cleanedBeats, 90);
    expect(exact.qualityReasons, isNot(contains('cleaning')));
    expect(over.cleanedBeats, 91);
    expect(over.qualityReasons, contains('cleaning'));
  });
  // WHY/CLAIM(pulse-fixed-support): pNN70 counts differences strictly over 70 ms,
  // and uses original adjacent-pair count as denominator.
  // # catches: >=70, percent/fraction confusion and compacted pair counts.
  test('literal 70/71 ms differences and 60 of 200 pairs at 30 percent', () {
    PulseWindow jumps(double amount) => window([
      for (var i = 0; i < 201; i++) PulseBeatInput(id: 's:$i', source: 'strap',
        index: i, timeMs: 1000 + i * 1000,
        rawMs: i < 60 && i.isOdd ? 1000 + amount : 1000),
    ]);
    expect(jumps(70).pnnPct, 0);
    final exact = jumps(71);
    expect(exact.pairs, 200);
    expect(exact.pnnPct, 30);
    expect(exact.pnnThreshold, 30);
    expect(exact.ratioThreshold, .7);
  });
  // WHY/CLAIM(pulse-fixed-support): the pNN70 floor is inclusive at exactly 30 percent
  // on a window that clears every other floor, and refuses just below it.
  // # catches: `pnn >= 30` turned into `pnn > 30` (the 70/71 ms test above is
  // refused for coverage and gaps, so it never reaches qualification).
  test('pNN70 floor qualifies at exactly 90 of 300 differences and refuses 89', () {
    // 301 beats near 980 ms, full coverage. Each isolated +80 ms bump makes two
    // differences over 70 ms (up, then down); every other difference is 0.
    PulseWindow floor(int bumps, {bool step = false}) {
      final rr = List<double>.filled(301, 980);
      for (var k = 0; k < bumps; k++) {
        rr[5 + 6 * k] = 1060;
      }
      // One more big difference: +80 once, then back down in two 40 ms steps.
      if (step) {
        rr[275] = 1060;
        rr[276] = 1020;
      }
      var t = 0.0;
      return window([for (var i = 0; i < rr.length; i++)
        PulseBeatInput(id: 'f:$i', source: 'strap', index: i,
          timeMs: (t += rr[i]).round(), rawMs: rr[i])]);
    }
    final exact = floor(45), below = floor(44, step: true);
    expect(exact.pairs, 300);
    expect(exact.totalBeats, 301);
    expect(exact.pnnPct, 30.0);
    expect(exact.reasons, isEmpty);
    expect(exact.ratio, greaterThan(0.7), reason: 'only the pNN floor is at stake');
    expect(exact.qualified, isTrue);
    expect(below.pairs, 300);
    expect(below.pnnPct, closeTo(100 * 89 / 300, 1e-9));
    expect(below.reasons, isEmpty);
    expect(below.ratio, greaterThan(0.7));
    expect(below.qualified, isFalse);
  });
  // WHY/CLAIM(pulse-fixed-support): the SD1/SD2 floor is inclusive at exactly 0.70.
  // The fixture is built from plain IEEE operations only (no libm), tuned so the
  // computed double ratio IS the literal 0.7; the first assertion guards that.
  // # catches: `ratio >= 0.7` turned into `ratio > 0.7`.
  test('SD1/SD2 floor qualifies at exactly 0.70 and refuses just below', () {
    List<PulseBeatInput> shaped(double slow, double tweak) {
      final out = <PulseBeatInput>[];
      var t = 0.0;
      for (var i = 0;; i++) {
        final tri = (i % 40 < 20 ? i % 40 : 40 - i % 40) - 10;
        final rr = 1000 + slow * (tri / 10) + (i.isEven ? 60.0 : -60.0) +
            tweak * ((i * 7) % 11 - 5);
        if (t + rr > 299999) break;
        t += rr;
        out.add(PulseBeatInput(id: 'r:$i', source: 'strap', index: i,
          timeMs: t.round(), rawMs: rr));
      }
      return out;
    }
    const slow = 150.32120906854246;
    final exact = window(shaped(slow, -2.98e-13));
    expect(exact.ratio, 0.7, reason: 'fixture must compute exactly the floor');
    expect(exact.reasons, isEmpty);
    expect(exact.pnnPct, greaterThan(90));
    expect(exact.qualified, isTrue);
    final below = window(shaped(slow + 1e-9, 0));
    expect(below.ratio, lessThan(0.7));
    expect(below.reasons, isEmpty);
    expect(below.qualified, isFalse);
  });
  // WHY/CLAIM(pulse-corrector-mapping): the sudden-change labels and the pair
  // test read the corrector's own th1, not a second threshold computation.
  // # catches: a recomputed threshold that drifts when the corrector's window,
  // alpha or floor change, or that ignores a segment cut at a capped gap.
  test('beat thresholds are the corrector th1 for dispersed, flat and capped series', () {
    final dispersed = [for (final b in f.trace(5)) if (b.timeMs < 300000) b];
    final flat = steady(299);
    final capped = [for (var i = 0; i < 299; i++) PulseBeatInput(id: 's:$i',
      source: 'strap', index: i, timeMs: 1000 + i * 1000,
      rawMs: i >= 100 && i < 145 ? 2500.0 : 1000.0)];
    for (final beats in [dispersed, flat, capped]) {
      final corrected = correctRr([for (final b in beats) b.rawMs]);
      final actual = window(beats).beats;
      expect(corrected.th1, hasLength(beats.length));
      for (var i = 0; i < beats.length; i++) {
        expect(actual[i].thresholdMs, corrected.th1[i], reason: 'beat $i');
      }
    }
    expect(correctRr([for (final b in dispersed) b.rawMs]).th1.first, greaterThan(100),
        reason: 'the dispersed series is above the 100 ms floor, so th1 is not a constant');
  });
  // WHY/CLAIM(pulse-fixed-support): evidence stays small: sensor context is
  // stored once per window, and the lag correlations of the retired veto are gone.
  // # catches: duplicated motion/wear fields and unconsumed lag diagnostics.
  test('window JSON holds context once and no lag diagnostics', () {
    final json = detectPulseEpisodes(steady(299), sourceStartMs: 0,
      sourceEndMs: 300000, completeThroughMs: 300000, evaluateFromMs: 0,
      evaluateToMs: 300000,
      context: {0: PulseWindowContext(asleep: false, motion: false, wear: true)})
      .windows.single.toJson(evidence: false);
    expect(json.containsKey('motion'), isFalse);
    expect(json.containsKey('wear'), isFalse);
    expect((json['breathing'] as Map).containsKey('lag3'), isFalse);
    expect((json['breathing'] as Map).containsKey('lag4'), isFalse);
    expect(json['context'], containsPair('motion', false));
    expect(json['context'], containsPair('wear', true));
    expect(json['context'], containsPair('status', 'known'));
  });
  // WHY/CLAIM(pulse-corrector-mapping): duplicate values cannot identify NN owners.
  // # catches: value searching, a second cleaner, or rolling back capped-gap behavior.
  test('current corrector source mapping and capped gaps survive the detector', () {
    final input = steady(299);
    final raw = [for (var i = 0; i < input.length; i++)
      i >= 100 && i < 145 ? 2500.0 : 1000.0];
    final beats = [for (var i = 0; i < input.length; i++) PulseBeatInput(
      id: input[i].id, source: 'strap', index: i,
      timeMs: input[i].timeMs, rawMs: raw[i])];
    final corrected = correctRr(raw);
    final actual = window(beats).beats;
    final nn = {for (var j = 0; j < corrected.nn.length; j++)
      corrected.nnSourceIndex[j]: corrected.nn[j]};
    expect(actual.where((b) => b.cleaningClass == 'gap').length, 45);
    for (var i = 0; i < actual.length; i++) {
      expect(actual[i].correctedMs, nn[i], reason: 'source beat $i');
      expect(actual[i].cleaningClass, corrected.classes[i].name);
    }
    expect(actual[145].validAdjacent, false);
  });
  // WHY/CLAIM(pulse-fixed-support): independent sources and positive sensor
  // exclusions cannot disappear when optional context is missing.
  // # catches: dropping semantic context or treating unknown as off-wrist.
  test('source-specific motion wear and charging exclude with distinct reasons', () {
    for (final entry in <String, PulseWindowContext>{
      'motion': PulseWindowContext(motion: true),
      'offWrist': PulseWindowContext(wear: false),
      'charging': PulseWindowContext(charging: true),
    }.entries) {
      final r = detectPulseEpisodes(f.trace(25), sourceStartMs: 0,
        completeThroughMs: 1200000, context: {
          for (var t = 0; t < 1200000; t += pulseWindowMs) t: entry.value});
      expect(r.episodes, isEmpty);
      expect(r.windows.first.exclusionReasons, [entry.key]);
      expect(r.windows.first.qualityReasons, isEmpty);
    }
  });
}
