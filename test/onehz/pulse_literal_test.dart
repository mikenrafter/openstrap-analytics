import 'package:test/test.dart';
import 'pulse_respiratory_pair_test.dart' as f;
import 'pulse_sleep_rr_fixture.dart';

void main() {
  // WHY/CLAIM(pulse-respiratory-residual): owner-approved v4 leaves seven
  // literal excerpts eligible, rather than erasing independent irregularity.
  // # catches: spectral-only exclusion, weak-fit exclusion, changed residual floors.
  const retained = {2, 3, 4, 6, 7, 9, 11};
  for (var i = 0; i < sleepRrFixtures.length; i++) {
    final capture = i + 1;
    test('accepted literal sleep capture $capture', () {
      final rr = sleepRrFixtures[i];
      final result = f.run(f.trace(f.target, 25, (i, _) => rr[i % rr.length]),
        from: f.target, to: f.target + 600000);
      expect(result.episodes.length, retained.contains(capture) ? 1 : 0);
      if (!retained.contains(capture)) {
        expect(result.windows.any((w) => w.exclusionReasons.contains('sleepBreathing')), isTrue);
        return;
      }
      final residuals = result.windows.map((w) => w.breathingResidual!).toList();
      expect(residuals, hasLength(2));
      for (final residual in residuals) {
        expect(residual['excludes'], false);
        expect(residual['domain'], 'original_beats');
        expect(residual['ratioFloor'], .7);
        expect(residual['pnnFloor'], 30);
        if (capture != 7) {
          expect(residual['status'], 'weak');
          expect(residual['explainedVariance'], lessThan(.12));
        }
      }
      if (capture == 7) {
        expect(residuals.any((r) => r['status'] == 'supported' &&
          (r['ratio'] as num) >= .7 && (r['pnnPct'] as num) >= 30), isTrue);
      }
    });
  }
}
