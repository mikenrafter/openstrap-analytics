// Experimental #628 contract: expected values are from the upstream formulas,
// not from a snapshot of the implementation. These are engineering choices,
// not evidence of staging accuracy against PSG.
import 'dart:convert';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const _start = 1700000000;
HmmEpoch _e(int offset, {double? hr = 60, double? rmssd = 40,
    bool contactLost = false}) => HmmEpoch(_start + offset,
    hr: hr, rmssd: rmssd, contactLost: contactLost);
List<HmmEpoch> _baseline() => [for (var i = 0; i < 240; i++) _e(i * 30)];

void main() {
  group('measured nightly baselines', () {
    test('uses upstream p10 order statistic and arithmetic mean RMSSD', () {
      // Sorted HR: 40,45,50,55,60,65,70,75,80,85.
      // floor(10*.1)=1 => 45, not minimum 40 or interpolated p10 44.5.
      // RMSSD: 10+20+30+40=100; 100/4=25.
      final rows = [for (var i = 0; i < 10; i++)
        _e(i * 30, hr: (85 - i * 5).toDouble(),
            rmssd: i < 4 ? (10 + i * 10).toDouble() : null)];
      final b = computeNightBaselines(rows, sessionStartSec: _start);
      expect(b.hrMinNight, 45);
      expect(b.rmssdMeanNight, 25);
      expect(b.toJson()['hr_min_night'], 45);
      expect(b.toJson()['rmssd_mean_night'], 25);
    });

    test('first 120 minutes are elapsed session time, with exclusive end', () {
      final b = computeNightBaselines([
        _e(-30, hr: 31, rmssd: 499),
        _e(0, hr: 50, rmssd: 20),
        _e(7199, hr: 70, rmssd: 40),
        _e(7200, hr: 32, rmssd: 498),
        // Row count is not elapsed time: this must not enter the first 240.
        _e(8000, hr: 33, rmssd: 497),
      ], sessionStartSec: _start);
      expect(b.hrMinNight, 50);
      expect(b.rmssdMeanNight, 30);
    });

    test('independent channels omit missing, nonfinite, invalid and lost contact', () {
      final b = computeNightBaselines([
        _e(0, hr: 60, rmssd: null),
        _e(30, hr: null, rmssd: 20),
        _e(60, hr: double.nan, rmssd: double.infinity),
        _e(90, hr: double.infinity, rmssd: double.nan),
        _e(120, hr: 30, rmssd: 0),
        _e(150, hr: 200, rmssd: 500),
        _e(180, hr: 31, rmssd: 499, contactLost: true),
      ], sessionStartSec: _start);
      expect(b.hrMinNight, 60);
      expect(b.rmssdMeanNight, 20);
      // JSON encoding must not be poisoned by NaN or infinity.
      expect(jsonDecode(jsonEncode(b.toJson()))['hr_min_night'], 60);
    });

    test('empty or entirely invalid session abstains, with no prior-session leak', () {
      final good = computeNightBaselines([_e(0)], sessionStartSec: _start);
      expect(good.hrMinNight, 60); // Positive control before the absent session.
      for (final rows in <List<HmmEpoch>>[
        [], [_e(0, hr: null, rmssd: null)],
        [_e(0, contactLost: true)],
      ]) {
        final b = computeNightBaselines(rows, sessionStartSec: _start);
        expect(b.hrMinNight, isNull);
        expect(b.rmssdMeanNight, isNull);
      }
    });
  });

  group('experimental decoder', () {
    test('flat reference has light emissions, no generic nrem labels', () {
      // At HR/baseline=RMSSD/baseline=1, light emission=.4 exceeds
      // REM=.13447, deep=.05960 and wake=.0003235. Sticky light stays light.
      expect(hmm628Stages(_baseline(), sessionStartSec: _start),
          List.filled(240, 'light'));
    });

    test('contact loss is forwarded at the first epoch and every later epoch', () {
      final rows = _baseline();
      rows[0] = _e(0, contactLost: true);
      rows[80] = _e(2400, contactLost: true);
      rows[239] = _e(7170, contactLost: true);
      final labels = hmm628Stages(rows, sessionStartSec: _start);
      expect(labels.length, 240);
      expect([labels[0], labels[80], labels[239]],
          ['unobserved', 'unobserved', 'unobserved']);
      expect(labels[1], 'light');
      expect(labels[81], 'light');
    });

    test('null and nonfinite measurements preserve holes without invented stages', () {
      final rows = [
        ..._baseline(),
        _e(7200, hr: null), _e(7230, rmssd: null),
        _e(7260, hr: double.nan), _e(7290, rmssd: double.infinity),
      ];
      final labels = hmm628Stages(rows, sessionStartSec: _start);
      expect(labels.take(240), List.filled(240, 'light'));
      expect(labels.skip(240), List.filled(4, 'unobserved'));
    });

    test('Viterbi continuity stops at an unobserved epoch', () {
      final rows = [
        ..._baseline(),
        for (var i = 0; i < 30; i++) _e(7200 + i * 30, hr: 78, rmssd: 60),
        _e(8100, contactLost: true),
        _e(8130),
      ];
      final labels = hmm628Stages(rows, sessionStartSec: _start);
      expect(labels[269], 'rem', reason: 'positive control: strong REM before gap');
      expect(labels[270], 'unobserved');
      expect(labels[271], 'light', reason: 'fresh light emission wins after gap; '
          'a retained REM transition would incorrectly keep REM');
    });

    test('an omitted time interval also resets continuity', () {
      final rows = [
        ..._baseline(),
        for (var i = 0; i < 30; i++) _e(7200 + i * 30, hr: 78, rmssd: 60),
        _e(8400), // no 8100..8370 epochs were observed
      ];
      final labels = hmm628Stages(rows, sessionStartSec: _start);
      expect(labels[269], 'rem');
      expect(labels[270], 'light');
    });

    test('a later session does not inherit a previous baseline', () {
      expect(hmm628Stages(_baseline(), sessionStartSec: _start).first, 'light');
      expect(hmm628Stages([_e(7200)], sessionStartSec: _start), ['unobserved'],
          reason: 'no valid measurements in this selected session baseline window');
    });
  });
}
