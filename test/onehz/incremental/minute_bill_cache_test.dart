import 'dart:convert';
import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/energy_day.dart';

const _profile = WorkoutUserProfile(
    weightKg: 75, heightCm: 178, age: 35, sex: 'male');

List<int> _doubleBytes(double? value) => value == null
    ? [255]
    : (ByteData(8)..setFloat64(0, value)).buffer.asUint8List();

void _exact(MinuteMetrics actual, List<int> keys, List<double> hr,
    List<double?> cadence, {bool series = false, double? rhr = 54}) {
  final trimp = banisterTrimp(hr, restingHr: rhr, maxHr: 190, sex: Sex.male);
  final strain = strainScoreMetric(trimp.value,
      wakeMinutes: hr.length.toDouble(), quietHrr: .12, quietSettled: false);
  expect(jsonEncode(actual.trimp.toJson()), jsonEncode(trimp.toJson()));
  expect(_doubleBytes(actual.trimp.value), _doubleBytes(trimp.value));
  expect(jsonEncode(actual.strain.toJson()), jsonEncode(strain.toJson()));
  expect(_doubleBytes(actual.strain.value), _doubleBytes(strain.value));
  final energy = rhr == null ? null : Calories.dailyEnergy(hr,
      profile: _profile, hrmax: 190, restingHr: rhr,
      cadenceSpmPerMin: cadence);
  expect(actual.energy, energy);
  for (final pair in [
    (actual.energy?.total, energy?.total),
    (actual.energy?.active, energy?.active),
    (actual.energy?.walking, energy?.walking),
    (actual.energy?.basal, energy?.basal),
  ]) {
    expect(_doubleBytes(pair.$1), _doubleBytes(pair.$2));
  }
  if (!series || rhr == null) {
    expect(actual.minutes, isNull);
    return;
  }
  final expected = Calories.minuteEnergy(hr, profile: _profile,
      hrmax: 190, restingHr: rhr, cadenceSpmPerMin: cadence,
      epochMinutes: keys)!;
  expect(actual.minutes!.coveredMinutes, expected.coveredMinutes);
  expect(actual.minutes!.active, expected.active);
  expect(actual.minutes!.walking, expected.walking);
  expect(actual.minutes!.minutes.map((m) =>
      (m.minute, m.source, m.abstained, m.basal, m.active, m.walking, m.total)),
      expected.minutes.map((m) =>
      (m.minute, m.source, m.abstained, m.basal, m.active, m.walking, m.total)));
}

void main() {
  // WHY: cached bills must retain batch's floating-point addition order.
  // Proves CLAIM(minute-bill-order). Catches delta totals and reversed sums.
  for (final series in [false, true]) {
    test('exact batch bytes after edits/removal/reorder/insertion series=$series', () {
      final day = energyDay();
      var keys = List.generate(1440, (i) => 30000000 + i);
      var hr = [...day.hr];
      var cadence = [...day.cadence];
      var state = IncrementalMinuteMetrics();
      void check(int priced) {
        final before = state.processedMinutes;
        final result = state.sync(keys, hr, cadenceSpm: cadence,
            restingHr: 54, maxHr: 190, profile: _profile, quietHrr: .12,
            includeMinuteSeries: series);
        expect(state.processedMinutes - before, priced);
        _exact(result, keys, hr, cadence, series: series);
      }
      check(1440);
      for (var edit = 0; edit < 20; edit++) {
        hr[720] = edit.isEven ? 81 : 82;
        check(1);
      }
      cadence[718] = 120;
      check(1);
      keys.removeAt(19); hr.removeAt(19); cadence.removeAt(19);
      check(0);
      keys = keys.reversed.toList(); hr = hr.reversed.toList();
      cadence = cadence.reversed.toList();
      check(0);
      keys.insert(123, 29999999); hr.insert(123, 146.123456789);
      cadence.insert(123, null);
      check(1);
      state = IncrementalMinuteMetrics.fromJson(
          jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>);
      check(0);
      hr[400] = 151.7654321;
      check(1);
      check(0);
      keys.clear(); hr.clear(); cadence.clear();
      check(0);
    });
  }

  // WHY: pre-column checkpoints must migrate once, without hiding pricing work.
  // Proves CLAIM(minute-bill-migration). Catches trusting legacy delta totals.
  test('legacy checkpoint without bill columns reprices once', () {
    final keys = List.generate(1440, (i) => 30000000 + i);
    final hr = List.generate(1440, (i) => 60.0 + (i * 17 % 100));
    final cadence = List<double?>.generate(1440, (i) => i % 3 == 0 ? 110 : null);
    final original = IncrementalMinuteMetrics();
    original.sync(keys, hr, cadenceSpm: cadence, restingHr: 54,
        maxHr: 190, profile: _profile, includeMinuteSeries: false);
    final legacy = jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>;
    legacy.remove('billColumns');
    final restored = IncrementalMinuteMetrics.fromJson(legacy);
    for (final work in [1440, 0]) {
      final before = restored.processedMinutes;
      final result = restored.sync(keys, hr, cadenceSpm: cadence, restingHr: 54,
          maxHr: 190, profile: _profile, quietHrr: .12,
          includeMinuteSeries: false);
      expect(restored.processedMinutes - before, work);
      _exact(result, keys, hr, cadence);
    }
  });
}
