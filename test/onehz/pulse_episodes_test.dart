import 'dart:convert';
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


/// Shaped like the production `decoded_rr` rows: one record per second holding
/// the 0-4 beats that ended in it, beats placed by walking the record's
/// intervals back from its anchor (`beatTimesMs`), and anchor jitter that now
/// and then puts a record's first beat before the previous record's last one.
/// Time order is record order, the index is the detection order.
List<PulseBeatInput> bandTrace(int minutes,
    {int seed = 17, String source = '', int offset = 0, double overlapRate = 0.03}) {
  final random = Random(seed);
  final truth = <double>[];
  final rrs = <double>[];
  var t = offset.toDouble();
  while (t < offset + minutes * 60000) {
    final rr = 750 + random.nextDouble() * 500;
    t += rr;
    truth.add(t);
    rrs.add(rr);
  }
  final out = <PulseBeatInput>[];
  var k = 0;
  while (k < truth.length) {
    final second = truth[k] ~/ 1000;
    final ids = <int>[];
    while (k < truth.length && truth[k] ~/ 1000 == second) {
      ids.add(k++);
    }
    final jitter = random.nextDouble() < overlapRate
        ? (random.nextBool() ? 1 : -1) * (500 + random.nextInt(900))
        : random.nextInt(60) - 30;
    var anchor = (truth[ids.last] + jitter).round();
    final times = List<int>.filled(ids.length, 0);
    for (var j = ids.length - 1; j >= 0; j--) {
      times[j] = anchor;
      anchor -= rrs[ids[j]].round();
    }
    for (var j = 0; j < ids.length; j++) {
      out.add(PulseBeatInput(
          id: '$source:${second * 1000}:$j',
          source: source,
          index: out.length,
          timeMs: times[j],
          rawMs: rrs[ids[j]].roundToDouble()));
    }
  }
  return out;
}

int stepsBack(List<PulseBeatInput> beats) {
  var n = 0;
  for (var i = 1; i < beats.length; i++) {
    if (beats[i].timeMs <= beats[i - 1].timeMs) n++;
  }
  return n;
}

// Literal policy control: the same RR spread at sleeping and faster rates.
List<PulseBeatInput> breathingTrace({bool random = false, double meanMs = 1150}) {
  final rng = Random(53), out = <PulseBeatInput>[];
  var time = 0.0, index = 0;
  while (time < 25 * 60000) {
    final rr = meanMs + (random ? rng.nextDouble() * 400 - 200
      : 90 * sin(2 * pi * index / 3.7));
    time += rr;
    out.add(PulseBeatInput(id:'sleep:$index',source:'strap',index:index++,
      timeMs:time.round(),rawMs:rr));
  }
  return out;
}

void main() {
  // WHY/CLAIM(pulse-sleep-pattern): periodic low-HR sleep and independent
  // irregular RR at the same HR must take different decisions.
  // # catches: a blanket sleep veto or retaining only the old two metric floors.
  test('breathing veto is confined to confirmed low-HR sleep', () {
    final sleeping = <int,PulseWindowContext>{
      for(var t=0;t<25*60000;t+=pulseWindowMs)
        t:const PulseWindowContext(asleep:true,motion:false,wear:true)};
    PulseDetection run(List<PulseBeatInput> beats, Map<int,PulseWindowContext> ctx) =>
      detectPulseEpisodes(beats,completeThroughMs:1200000,sourceStartMs:0,context:ctx);
    expect(run(breathingTrace(),sleeping).episodes,isEmpty);
    expect(run(breathingTrace(),sleeping).windows.first.reasons,contains('sleepBreathing'));
    expect(run(breathingTrace(),{}).episodes,hasLength(1));
    expect(run(breathingTrace(meanMs:60000/66),sleeping).episodes,hasLength(1));
    expect(run(breathingTrace(random:true),sleeping).episodes,hasLength(1));
  });
  // WHY/CLAIM(pulse-context): unknown optional inputs cannot switch off alerts.
  // # catches: treating unknown wear as off-wrist or dropping context diagnostics.
  test('unknown sensor context preserves irregular alert eligibility and fixed floors', () {
    final result = detectPulseEpisodes(breathingTrace(random:true),
      completeThroughMs:1200000,sourceStartMs:0);
    expect(result.episodes.single.alertEligible,isTrue);
    expect(result.windows.first.toJson()['context'],containsPair('status','unknown'));
    expect(result.windows.first.ratioThreshold,0.7);
    expect(result.windows.first.pnnThreshold,30);
  });
  // WHY/CLAIM(pulse-closed): a transport boundary cannot vote or qualify ten minutes.
  test(
      'requires two consecutive closed supported windows; unknown wear permits alert',
      () {
    final beats = trace(25);
    final open =
        detectPulseEpisodes(beats, completeThroughMs: 899999, sourceStartMs: 0);
    expect(open.episodes, isEmpty);
    expect(open.windows.where((w)=>w.pending).every((w)=>!w.qualified), isTrue,
      reason:'unresolved support cannot produce a qualified window decision');
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
    // Each source alone has one qualified window, and the two are adjacent in
    // time: a merged timeline would be a ten minute episode. Evidence must exist
    // for the refusal to mean anything (an empty result also has no episodes).
    List<int> qualified(String source) => [
      for (final w in result.windows)
        if (w.source == source && w.qualified) w.startMs];
    expect(qualified('a'), [0]);
    expect(qualified('b'), [300000]);
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
    final conflicted =
        detectPulseEpisodes(input, completeThroughMs: 1200000, sourceStartMs: 0);
    expect(conflicted.toJson(),
        detectPulseEpisodes(reversed,
                completeThroughMs: 1200000, sourceStartMs: 0)
            .toJson());
    // The conflict is refused where it sits and nowhere else; an empty result
    // would also compare equal to itself.
    final clean =
        detectPulseEpisodes(beats, completeThroughMs: 1200000, sourceStartMs: 0);
    final home = b.timeMs ~/ pulseWindowMs * pulseWindowMs;
    expect(conflicted.windows.firstWhere((w) => w.startMs == home).reasons,
        contains('timestamps'));
    expect(clean.windows.any((w) => w.reasons.contains('timestamps')), isFalse);
    expect(clean.episodes, hasLength(1));
    for (final watermark in [900000, 1200000, 1500000]) {
      final batch = detectPulseEpisodes(beats,
          completeThroughMs: watermark, sourceStartMs: 0);
      expect(batch.windows.where((w) => !w.pending), isNotEmpty);
      final prefix = detectPulseEpisodes(
          beats.where((b) => b.timeMs < watermark).toList(),
          completeThroughMs: watermark,
          sourceStartMs: 0);
      expect(jsonEncode([for (final e in prefix.episodes) e.toJson()]),
          jsonEncode([for (final e in batch.episodes) e.toJson()]));
      expect(jsonEncode([for (final w in prefix.windows) if (!w.pending) w.toJson()]),
          jsonEncode([for (final w in batch.windows) if (!w.pending) w.toJson()]),
          reason: 'byte-identical closed evidence at watermark $watermark');
    }
  });

  // WHY/CLAIM(pulse-timestamps): real records hold several beats and overlap
  // their neighbours by under one interval; that must refuse only the pairs it
  // touches, not the 15-minute context (review r1 finding 4).
  test('record overlaps from real band rows refuse pairs, not windows', () {
    final beats = bandTrace(25);
    expect(stepsBack(beats), greaterThan(10),
        reason: 'the fixture must contain the overlaps real rows have');
    expect(beats.where((b) => b.id.endsWith(':1')), isNotEmpty,
        reason: 'and records holding several beats');
    final result = detectPulseEpisodes(beats,
        completeThroughMs: 1500000, sourceStartMs: 0);
    final closed = result.windows.where((w) => !w.pending).toList();
    expect(closed, isNotEmpty);
    expect(closed.expand((w) => w.reasons), isNot(contains('timestamps')));
    expect(result.episodes, hasLength(1));
    expect(result.episodes.single.startMs, 0);
    expect(result.episodes.single.endMs, 1200000);
  });
  // WHY/CLAIM(pulse-timestamps): holding an overlapped beat keeps detection
  // order (the rhythm), and only the pair across the overlap loses adjacency.
  test('an overlap holds the beat in order and breaks only its own pair', () {
    final beats = bandTrace(25, overlapRate: 0.0);
    final shifted = [
      for (final b in beats)
        b.index == 100
            ? PulseBeatInput(
                id: b.id,
                source: b.source,
                index: b.index,
                timeMs: beats[99].timeMs - 600,
                rawMs: b.rawMs)
            : b
    ];
    Map<int, PulseBeatEvidence> evidenceOf(List<PulseBeatInput> input) => {
          for (final w in detectPulseEpisodes(input,
                  completeThroughMs: 1500000, sourceStartMs: 0)
              .windows)
            for (final b in w.beats) b.index: b
        };
    final base = evidenceOf(beats), now = evidenceOf(shifted);
    final result = detectPulseEpisodes(shifted,
        completeThroughMs: 1500000, sourceStartMs: 0);
    expect(result.windows.expand((w) => w.reasons),
        isNot(contains('timestamps')));
    expect(now[100]!.validAdjacent, isFalse);
    expect(now[100]!.timeMs, greaterThanOrEqualTo(now[99]!.timeMs));
    for (var i = 1; i < 250; i++) {
      expect(now[i]!.predecessorId, now[i - 1]!.id,
          reason: 'the interval series keeps the order the band detected it in');
      expect(now[i]!.cleaningClass, base[i]!.cleaningClass);
      if (i != 100 && i != 101) {
        expect(now[i]!.validAdjacent, base[i]!.validAdjacent, reason: '$i');
      }
    }
  });
  // WHY/CLAIM(pulse-timestamps): a clock that really goes backwards is still refused.
  test('a backwards step beyond one interval refuses the neighbourhood', () {
    final beats = bandTrace(25, overlapRate: 0.0);
    final bad = [
      for (final b in beats)
        b.index == 100
            ? PulseBeatInput(
                id: b.id,
                source: b.source,
                index: b.index,
                timeMs: beats[99].timeMs - 6000,
                rawMs: b.rawMs)
            : b
    ];
    final result = detectPulseEpisodes(bad,
        completeThroughMs: 1500000, sourceStartMs: 0);
    expect(result.windows.first.reasons, contains('timestamps'));
  });
  // WHY/CLAIM(pulse-range): the same window gets the same decision whichever
  // query range evaluates it (review r1 finding 5).
  test('a window evaluated near a range end equals the full evaluation', () {
    final beats = bandTrace(40, overlapRate: 0.01);
    final full = detectPulseEpisodes(beats,
        completeThroughMs: 3000000, sourceStartMs: 0);
    for (final range in [(600000, 1200000), (900000, 1500000), (1200000, 1800000)]) {
      final rows = [
        for (final b in beats)
          if (b.timeMs >= range.$1 - pulseWindowMs - 10000 &&
              b.timeMs < range.$2 + pulseWindowMs + 10000)
            b
      ];
      final part = detectPulseEpisodes(rows,
          completeThroughMs: 3000000,
          sourceStartMs: 0,
          evaluateFromMs: range.$1,
          evaluateToMs: range.$2);
      expect(part.windows.map((w) => w.startMs).toList(),
          [for (var s = range.$1; s < range.$2; s += pulseWindowMs) s]);
      for (final w in part.windows) {
        final same = full.windows.firstWhere((x) => x.startMs == w.startMs);
        expect(w.toJson(), same.toJson(), reason: 'window ${w.startMs}');
      }
    }
  });
  // WHY/CLAIM(pulse-range): `ongoing` is stored with the episode, so it is a
  // decision like any window and cannot depend on where the query range ends.
  // The window one past the range is already drafted; if it is closed and
  // refused the episode is over, whichever range asked.
  // # catches: finishing the last run as ongoing just because the range ended.
  test('episode closure does not depend on the query range', () {
    final beats = trace(40)
      ..removeWhere((b) => b.timeMs >= 900000 && b.timeMs < 1200000);
    final full = detectPulseEpisodes(beats,
        completeThroughMs: 3000000, sourceStartMs: 0);
    final over = full.episodes.first;
    expect([over.source, over.startMs, over.endMs, over.ongoing],
        ['strap', 0, 900000, false]);
    PulseDetection ranged(int from, int to) => detectPulseEpisodes([
      for (final b in beats)
        if (b.timeMs >= from - pulseWindowMs - 10000 &&
            b.timeMs < to + pulseWindowMs + 10000) b],
      completeThroughMs: 3000000, sourceStartMs: 0,
      evaluateFromMs: from, evaluateToMs: to);
    // The range ends on the last window of the episode; the hole follows it.
    expect(jsonEncode(ranged(0, 900000).episodes.single.toJson()),
        jsonEncode(over.toJson()));
    // The range ends inside the episode: the next window is still qualified, so
    // the episode may well continue and stays open.
    final early = ranged(0, 600000).episodes.single;
    expect([early.endMs, early.ongoing], [600000, true]);
  });
}
