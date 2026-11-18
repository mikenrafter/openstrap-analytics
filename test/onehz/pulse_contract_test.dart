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
