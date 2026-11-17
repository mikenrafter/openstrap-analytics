import 'dart:convert';

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

Map<String, dynamic> _copy(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

void main() {
  const profile = WorkoutUserProfile(
      weightKg: 80, heightCm: 180, age: 30, sex: 'male');
  IncrementalMinuteMetrics fixture() => IncrementalMinuteMetrics()
    ..sync([10, 20, 30], [60, 150, 0],
        cadenceSpm: [110, null, null],
        restingHr: 54, maxHr: 186, profile: profile);

  // WHY: the additive column encoding must reject contradictory checkpoints.
  // Catches accepting a truncated, nonnumeric, or altered contribution column.
  test('bill checkpoint columns validate length, shape and row agreement', () {
    for (final name in ['trimp', 'active', 'walking', 'source']) {
      for (final bad in [null, 'bad', <num>[], [double.infinity, 0, 0], [99, 0, 0]]) {
        final saved = _copy(fixture().toJson());
        (saved['billColumns'] as Map)[name] = bad;
        expect(() => IncrementalMinuteMetrics.fromJson(saved),
            throwsFormatException, reason: '$name=$bad');
      }
    }
  });

  // WHY: JSON input/output belongs to the caller; it cannot mutate cached bills.
  // Catches retaining checkpoint list references or returning internal arrays.
  test('bill columns own restored and exported checkpoint storage', () {
    final saved = fixture().toJson();
    final restored = IncrementalMinuteMetrics.fromJson(saved);
    final expected = _copy(restored.toJson());
    ((saved['billColumns'] as Map)['trimp'] as List)[0] = 99.0;
    (saved['bills'] as List)[0]['hr'] = 199;
    expect(_copy(restored.toJson()), expected);
    final exported = restored.toJson();
    ((exported['billColumns'] as Map)['walking'] as List)[0] = 99.0;
    expect(_copy(restored.toJson()), expected);
  });

  // WHY: saving a migrated checkpoint before its first sync must not mark its
  // legacy, noncanonical bills as ready. Proves CLAIM(minute-bill-migration).
  test('legacy re-checkpoint still requires exactly one rebuild', () {
    final legacy = _copy(fixture().toJson())..remove('billColumns');
    final pending = IncrementalMinuteMetrics.fromJson(legacy);
    expect(pending.toJson().containsKey('billColumns'), isTrue);
    expect(pending.toJson()['billColumns'], isNull);
    final restored = IncrementalMinuteMetrics.fromJson(_copy(pending.toJson()));
    final before = restored.processedMinutes;
    for (var pass = 0; pass < 2; pass++) {
      restored.sync([10, 20, 30], [60, 150, 0],
          cadenceSpm: [110, null, null], restingHr: 54, maxHr: 186,
          profile: profile);
      expect(restored.processedMinutes - before, 3);
    }
    expect(restored.toJson().containsKey('billColumns'), isTrue);
  });

  // WHY: null cadence and nonfinite cadence have different input identities,
  // even though both abstain from walking. Catches a NaN null sentinel collision.
  test('cadence presence survives checkpoints and pricing work detection', () {
    final state = IncrementalMinuteMetrics();
    for (final cadence in <double?>[null, double.nan, double.nan, null]) {
      state.sync([0], [60], cadenceSpm: [cadence], restingHr: 54,
          maxHr: 186, profile: profile, includeMinuteSeries: false);
    }
    expect(state.processedMinutes, 3);
    final restored = IncrementalMinuteMetrics.fromJson(_copy(state.toJson()));
    restored.sync([0], [60], cadenceSpm: [null], restingHr: 54,
        maxHr: 186, profile: profile, includeMinuteSeries: false);
    expect(restored.processedMinutes, 3);
    restored.sync([0], [60], cadenceSpm: [double.nan], restingHr: 54,
        maxHr: 186, profile: profile, includeMinuteSeries: false);
    expect(restored.processedMinutes, 4);
  });

  // WHY: migration must accept the actual pre-column shape independently of
  // today's serializer, including an absent energy profile.
  test('literal version-one checkpoint migrates without fabricating energy', () {
    final restored = IncrementalMinuteMetrics.fromJson({
      'version': 1,
      'type': 'IncrementalMinuteMetrics',
      'processedMinutes': 1,
      'parameters': [54.0, 186.0, 'male', null],
      'trimpTotal': 0.0,
      'basalPerMinute': null,
      'bills': [
        {'key': 10, 'hr': 54.0, 'cadence': null, 'trimp': 0.0,
         'source': null, 'active': 0.0, 'walking': 0.0},
      ],
    });
    for (var pass = 0; pass < 2; pass++) {
      final result = restored.sync([10], [54], restingHr: 54, maxHr: 186);
      expect(restored.processedMinutes, 2);
      expect(result.trimp.value, 0);
      expect(result.energy, isNull);
      expect(result.minutes, isNull);
    }
  });
}
