import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

const now = 12 * 3600000;
List<List<double>> hr(int minutes, double value, {int end = now - 180000}) => [
      for (var s = 0; s < minutes * 60; s++)
        [end - (minutes * 60 - s) * 1000.0, value],
    ];
List<List<double>> motion(double Function(int) g) => [
      for (var s = 0; s < 300; s++) [now - (300 - s) * 1000.0, 0, 0, 1 + g(s)],
    ];
void main() {
  test('baseline layers and independent historical fallback', () {
    expect(wakeHrBaseline(hr(180, 50), now).source,
        WakeBaselineSource.percentile3h);
    expect(wakeHrBaseline([], now, nightMin: 47).bpm, 47);
    expect(wakeHrBaseline([], now, nightMin: double.nan).bpm, isNull);
    final short = hr(20, 55);
    expect(wakeHrBaseline(short, now).source, WakeBaselineSource.median90m);
    expect(wakeHrBaseline(hr(2, 50), now).bpm, isNull);
    // #630 order statistic floor(n*.1): sorted index 600 is 51.
    final varied = [
      for (var i = 0; i < 6000; i++) [now - 7200000.0 + i * 1000, 50.0 + i % 10]
    ];
    expect(wakeHrBaseline(varied, now).bpm, 51);
  });
  test('same timestamps produce distinct three/five minute trends', () {
    // In 3 min: 0 then .03 => .03 rise; in 5 min: .02 then .018 => -.002.
    final rows = motion((s) => s >= 210
        ? .03
        : s < 120
            ? .025
            : 0);
    expect(wakeEnmoTrend(rows, now, windowMinutes: 3, threshold: .02), isTrue);
    expect(wakeEnmoTrend(rows, now, windowMinutes: 5, threshold: .02), isFalse);
  });
  test('trend exact boundary and missing coverage abstain separately', () {
    final rows = motion((s) => s < 150 ? 0 : .03125);
    expect(
        wakeEnmoTrend(rows, now, windowMinutes: 5, threshold: .03125), isFalse);
    expect(wakeEnmoTrend(rows, now, windowMinutes: 5, threshold: .031), isTrue);
    expect(wakeEnmoTrend([], now, windowMinutes: 5, threshold: .02), isNull);
    expect(
        wakeEnmoTrend(rows.take(10).toList(), now,
            windowMinutes: 5, threshold: .02),
        isNull);
    expect(
        wakeEnmoTrend([for (var i = 0; i < 300; i++) rows.first], now,
            windowMinutes: 5, threshold: .02),
        isNull);
  });
  test('recent HR/ENMO reject invalid future and duplicate evidence', () {
    expect(wakeRecentHr(hr(3, 56, end: now), now), 56);
    expect(
        wakeRecentHr([
          [now + 1, 90]
        ], now),
        isNull);
    expect(wakeRecentHr(hr(3, double.nan, end: now), now), isNull);
    expect(wakeRecentEnmo(motion((_) => .03125), now), closeTo(.03125, 1e-9));
    expect(
        wakeRecentEnmo([
          [now - 1000, 0, 0, 0]
        ], now),
        isNull);
  });
  test('baseline priority, validity and separate 90-minute median', () {
    expect(wakeHrBaseline(hr(60, 50), now, nightMin: 47).bpm, 50);
    expect(wakeHrBaseline(hr(20, 55), now, nightMin: 47).source,
        WakeBaselineSource.nightPayload);
    // Twenty minutes cannot support the primary percentile. The median of
    // equal counts at 50 and 60 is 55, independently of the older HR=90.
    final short = hr(20, 50);
    for (var i = 600; i < short.length; i++) {
      short[i][1] = 60;
    }
    final rows = [...hr(10, 90, end: now - 120 * 60000), ...short];
    expect(wakeHrBaseline(rows, now).bpm, 55);
    for (final invalid in [30.0, 200.0, double.nan, double.infinity]) {
      expect(wakeHrBaseline([], now, nightMin: invalid).source,
          WakeBaselineSource.absent);
    }
    expect(wakeHrBaseline(hr(60, 0), now).bpm, isNull);
  });
  test('gaps, conflicting duplicates and stale windows cannot approve', () {
    final split = [...hr(10, 50), ...hr(10, 50, end: now - 60 * 60000)];
    expect(wakeHrBaseline(split, now).bpm, isNull);
    final recent = hr(3, 56, end: now);
    expect(wakeRecentHr([...recent, ...recent], now), isNull);
    expect(wakeRecentHr(hr(3, 56, end: now - 61000), now), isNull);
    final rows = motion((_) => .03125);
    expect(
        wakeEnmoTrend([...rows, ...rows], now,
            windowMinutes: 5, threshold: .02),
        isNull);
    expect(
        wakeEnmoTrend(rows.take(230).toList(), now,
            windowMinutes: 5, threshold: .02),
        isNull);
    expect(
        wakeRecentEnmo([
          for (final r in rows) [r[0], double.nan, 0, 1]
        ], now),
        isNull);
    expect(wakeBaselineEnmo([], now), isNull);
  });
  test('trend splits elapsed time even when sample counts differ', () {
    // First half has 150 points at zero; second half has 50 points at .04.
    // A count-based split would mix zeros into the latter half and report .02.
    final rows = [
      for (var s = 0; s < 300; s++)
        if (s < 150 || s % 3 == 0)
          [now - (300 - s) * 1000.0, 0.0, 0.0, s < 150 ? 1.0 : 1.04]
    ];
    expect(wakeEnmoTrend(rows, now, windowMinutes: 5, threshold: .03), isTrue);
  });
}
