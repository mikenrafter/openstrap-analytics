import 'dart:convert';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const _start = 1782532800; // 2026-06-27 04:00 UTC, explicit night.
const _span = 4 * 3600;
List<GravTs> _gravity({bool contactLoss = false}) => [
  for (var i = 0; i < _span; i++) GravTs(_start + i, 0, 0, 1,
      contactLost: contactLoss && (i < 30 || (i >= 90 && i < 120))),
];
List<HrTs> _hr() => [for (var i = 0; i < _span; i++) HrTs(_start + i, 60)];
List<RrTs> _rr() => [for (var i = 0; i < _span; i++)
  RrTs(_start + i, i.isEven ? 1000 : 1100)];
List<AccelSample> _accel() => [for (var i = 0; i < _span; i++)
  AccelSample((_start + i) * 1000.0, 0, 0, 1)];

void main() {
  test('stageWindow dispatches HMM and forwards contact at every epoch', () {
    final session = AdvancedSleepStager.stageWindow(
      _start, _start + _span, _gravity(contactLoss: true), _hr(), rr: _rr(),
      method: StagingMethod.hmm628,
    );
    final observed = session.stages.where((s) => s.stage != 'unobserved').toList();
    expect(observed, isNotEmpty, reason: 'positive control after contact returns');
    // No observed stage may overlap either explicit contact-loss epoch.
    for (final s in observed) {
      expect(s.start >= _start + 30, isTrue);
      expect(s.end <= _start + 90 || s.start >= _start + 120, isTrue,
          reason: 'stage ${s.stage} [${s.start},${s.end}) crosses contact loss');
      expect(s.stage, isIn(['wake', 'light', 'deep', 'rem']));
    }
  });

  test('window staging preserves a short omitted interval without continuity', () {
    final gravity = _gravity().where((g) =>
        g.ts < _start + 7210 || g.ts >= _start + 7220).toList();
    final session = AdvancedSleepStager.stageWindow(
        _start, _start + _span, gravity, _hr(), rr: _rr(),
        method: StagingMethod.hmm628);
    final observed = session.stages.where((s) => s.stage != 'unobserved');
    expect(observed, isNotEmpty);
    for (final s in observed) {
      expect(s.end <= _start + 7210 || s.start >= _start + 7220, isTrue,
          reason: 'observed ${s.stage} [${s.start},${s.end}) crosses missing seconds');
    }
  });

  test('window staging preserves non-aligned invalid accel as unobserved', () {
    final gravity = _gravity();
    gravity[299] = GravTs(_start + 299, 0, 0, 0, valid: false);
    final session = AdvancedSleepStager.stageWindow(
        _start, _start + _span, gravity, _hr(), rr: _rr(),
        method: StagingMethod.hmm628);
    final observed = session.stages.where((s) => s.stage != 'unobserved');
    expect(observed, isNotEmpty);
    for (final s in observed) {
      expect(s.end <= _start + 299 || s.start >= _start + 300, isTrue,
          reason: 'observed ${s.stage} [${s.start},${s.end}) covers invalid accel');
    }
  });

  test('baseline horizon reuses exact epoch features with full lookahead', () {
    final cache = CardioRowCache();
    final full = AdvancedSleepStager.measuredEpochs(
        _start, _start + _span, _gravity(), _hr(), _rr(), rowCache: cache);
    final hits = cache.hits;
    final prefix = AdvancedSleepStager.measuredEpochs(
        _start, _start + 7200 + 180, _gravity(), _hr(), _rr(), rowCache: cache);
    // All 240 baseline epochs have their entire +180s context in the prefix,
    // so their exact cached features must be reused. Tail rows may differ.
    expect(cache.hits - hits, greaterThanOrEqualTo(240));
    for (final rows in [full, prefix]) {
      final b = computeNightBaselines(rows, sessionStartSec: _start);
      expect(b.hrMinNight, 60);
      expect(b.rmssdMeanNight, closeTo(100, 1e-9));
    }
  });

  test('detected-session path dispatches HMM, without falling back to cardio', () {
    // HMM requires both measured channels. No RR => unobserved, even though
    // cardio can produce an HR+motion estimate on the same night.
    final cardio = AdvancedSleepStager.detectSleep(_gravity(), _hr(),
        method: StagingMethod.cardio, tzOffsetSec: 0);
    final hmm = AdvancedSleepStager.detectSleep(_gravity(), _hr(),
        method: StagingMethod.hmm628, tzOffsetSec: 0);
    expect(cardio, isNotEmpty);
    expect(cardio.expand((s) => s.stages).where((s) => s.stage != 'unobserved'),
        isNotEmpty, reason: 'cardio positive control');
    expect(hmm.expand((s) => s.stages).where((s) => s.stage != 'unobserved'),
        isEmpty, reason: 'HMM must abstain without measured RMSSD');
  });

  test('segmentation publishes measured baselines for cardio and HMM', () {
    final accel = _accel();
    final hr = List<double>.filled(_span, 60);
    final rr = _rr();
    final reference = segmentSleep(accel, hr,
        rrMs: [for (final r in rr) r.rrMs],
        rrTsMs: [for (final r in rr) r.ts * 1000.0],
        forcedWindow: (onsetSec: _start, offsetSec: _start + _span));
    for (final method in [StagingMethod.cardio, StagingMethod.hmm628]) {
      final result = segmentSleep(accel, hr,
          rrMs: [for (final r in rr) r.rrMs],
          rrTsMs: [for (final r in rr) r.ts * 1000.0],
          forcedWindow: (onsetSec: _start, offsetSec: _start + _span),
          method: method);
      // Every adjacent pair is 100 ms apart: sqrt(mean(100^2))=100.
      expect(result.hrMinNight, 60);
      expect(result.rmssdMeanNight, closeTo(100, 1e-9));
      final payload = result.toJson();
      expect(payload['hr_min_night'], 60);
      expect(payload['rmssd_mean_night'], closeTo(100, 1e-9));
      expect(payload['staging_method'], method.name);
      expect(payload['staging_note'], contains('not a medical'));
      if (method == StagingMethod.cardio) {
        expect(jsonEncode(payload), jsonEncode(reference.toJson()),
            reason: 'the omitted default must be exactly explicit cardio');
        expect(result.stages, reference.stages);
      }
    }
  });
}
