import 'dart:math';
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

List<PulseBeatInput> trace(int minutes,
    {String source = 'strap', int offset = 0}) {
  final random = Random(17);
  final beats = <PulseBeatInput>[];
  var time = offset.toDouble();
  while (time < offset + minutes * 60000) {
    final rr = 750 + random.nextDouble() * 500;
    time += rr;
    beats.add(PulseBeatInput(
        id: '$source:${beats.length}',
        source: source,
        index: beats.length,
        timeMs: time.round(),
        rawMs: rr));
  }
  return beats;
}

void main() {
  // WHY/CLAIM(pulse-closed): a transport boundary cannot vote or qualify ten minutes.
  test(
      'requires two consecutive closed supported windows; unknown wear permits alert',
      () {
    final beats = trace(25);
    final open =
        detectPulseEpisodes(beats, completeThroughMs: 899999, sourceStartMs: 0);
    expect(open.episodes, isEmpty);
    final closed = detectPulseEpisodes(beats,
        completeThroughMs: 1200000, sourceStartMs: 0);
    expect(closed.episodes, hasLength(1));
    expect(closed.episodes.single.startMs, 0);
    expect(closed.episodes.single.endMs, 900000);
    expect(closed.episodes.single.alertEligible, isTrue);
    expect(closed.windows.first.motion, isNull);
    expect(closed.windows.first.wear, isNull);
  });
  // WHY/CLAIM(pulse-deterministic): input arrival order and repeated evaluation preserve identity.
  test('canonical ordering, extension, restart preserve the seed', () {
    final beats = trace(30);
    final first =
        detectPulseEpisodes(beats, completeThroughMs: 900000, sourceStartMs: 0);
    final shuffled = [...beats]..shuffle(Random(9));
    final again = detectPulseEpisodes(shuffled,
        completeThroughMs: 900000, sourceStartMs: 0);
    expect(again.toJson(), first.toJson());
    final extended = detectPulseEpisodes(beats,
        completeThroughMs: 1500000, sourceStartMs: 0);
    expect(extended.episodes.single.id, first.episodes.single.id);
    expect(extended.episodes.single.endMs, 1200000);
  });
  // WHY/CLAIM(pulse-gap): no adjacent pair or episode may bridge missing recording.
  test('refused window breaks joining and gaps cannot fabricate pairs', () {
    final beats = trace(35)
      ..removeWhere((b) => b.timeMs >= 600000 && b.timeMs < 900000);
    final result = detectPulseEpisodes(beats,
        completeThroughMs: 1800000, sourceStartMs: 0);
    expect(result.windows.firstWhere((w) => w.startMs == 600000).reasons,
        contains('coverage'));
    expect(result.episodes, hasLength(2));
    expect(result.episodes.first.endMs, 600000);
    expect(result.episodes.last.startMs, 900000);
  });
  // WHY/CLAIM(pulse-labels): cleaning hypotheses retain raw values, masks and original adjacency.
  test('labels isolated missed, extra, pair and dropped intervals with values',
      () {
    final beats = [
      for (var i = 0; i < 400; i++)
        PulseBeatInput(
            id: 'b$i',
            source: 'strap',
            index: i,
            timeMs: (i + 1) * 1000,
            rawMs: i == 100
                ? 2100
                : i == 150
                    ? 400
                    : i == 200
                        ? 600
                        : i == 201
                            ? 1400
                            : 1000)
    ];
    final result =
        detectPulseEpisodes(beats, completeThroughMs: 600000, sourceStartMs: 0);
    final evidence = result.windows.first.beats;
    expect(evidence.firstWhere((b) => b.id == 'b100').labels,
        contains('likelyMissed'));
    expect(evidence.firstWhere((b) => b.id == 'b150').labels,
        contains('likelyExtra'));
    final pair = evidence.firstWhere((b) => b.id == 'b200');
    expect(pair.labels, contains('shortLongPair'));
    expect(pair.rawMs, 600);
    expect(pair.dropped, isTrue);
    expect(evidence.firstWhere((b) => b.id == 'b202').validAdjacent, isFalse);
  });
  // WHY/CLAIM(pulse-quality): measurable quality fails closed; unknown measurements stay null.
  test('thin, nonmonotone and excessive cleaning have explicit refusal reasons',
      () {
    final thin = trace(20)..removeWhere((b) => b.index % 2 == 0);
    expect(
        detectPulseEpisodes(thin, completeThroughMs: 900000, sourceStartMs: 0)
            .windows
            .first
            .reasons,
        contains('coverage'));
    final bad = trace(20);
    bad[10] = PulseBeatInput(
        id: bad[10].id, source: 'strap', index: 10, timeMs: 1, rawMs: 1000);
    expect(
        detectPulseEpisodes(bad, completeThroughMs: 900000, sourceStartMs: 0)
            .windows
            .first
            .reasons,
        contains('timestamps'));
  });
  // WHY/CLAIM(pulse-source): separate physical sources never join.
  test('sources cannot create a ten minute episode together', () {
    final result = detectPulseEpisodes(
        [...trace(5, source: 'a'), ...trace(5, source: 'b', offset: 300000)],
        completeThroughMs: 900000, sourceStartMs: 0);
    expect(result.episodes, isEmpty);
  });
  // WHY/CLAIM(pulse-deterministic): conflicting duplicates refuse without arrival-order evidence drift.
  test('conflicting revisions and checkpoint prefixes are deterministic', () {
    final beats = trace(30);
    final b = beats[100];
    final conflict = PulseBeatInput(
        id: b.id,
        source: b.source,
        index: b.index,
        timeMs: b.timeMs + 1,
        rawMs: b.rawMs + 100);
    final input = [...beats, conflict];
    final reversed = input.reversed.toList();
    expect(
        detectPulseEpisodes(input, completeThroughMs: 1200000, sourceStartMs: 0)
            .toJson(),
        detectPulseEpisodes(reversed,
                completeThroughMs: 1200000, sourceStartMs: 0)
            .toJson());
    for (final watermark in [900000, 1200000, 1500000]) {
      final batch = detectPulseEpisodes(beats,
          completeThroughMs: watermark, sourceStartMs: 0);
      final prefix = detectPulseEpisodes(
          beats.where((b) => b.timeMs < watermark).toList(),
          completeThroughMs: watermark,
          sourceStartMs: 0);
      expect([for (final e in prefix.episodes) e.toJson()],
          [for (final e in batch.episodes) e.toJson()]);
    }
  });
}
