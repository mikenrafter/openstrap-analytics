// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:math';
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'pulse_respiratory_pair_test.dart' as f;
import 'pulse_residual_cases.dart';
import 'pulse_sleep_rr_fixture.dart';

List<ana.PulseBeatInput> mixedTrace(
  bool physical,
  double bpm,
  double amplitude,
  int seed, {
  bool mixture = true,
}) {
  final random = Random(seed);
  return f.trace(f.target, 20, (i, t) {
    final mean = 60000 / bpm, noise = 120 * (2 * random.nextDouble() - 1);
    final phase = 2 * pi * .25 * (physical ? t / 1000 : (i + 1) * mean / 1000);
    return t >= 300000 && t < 900000
        ? (mean + noise + (mixture ? amplitude * sin(phase) : 0)).round()
        : mean.round();
  });
}

void main() {
  // WHY/CLAIM(pulse-respiratory-residual): respiration can coexist with independent irregularity.
  // # catches: spectral matching alone, resampled-domain floors, and personal thresholds suppressing a residual.
  test(
    '997 frozen counterfactual pairs survive fixed-floor policy',
    () {
      final lost = <String>[];
      var cases = 0;
      double? minRatio, minPnn;
      for (final cell in protectedRespiratoryCases) {
        for (final seed in cell.seeds) {
          final key = '${cell.physical}:${cell.bpm}:${cell.amplitude}:$seed';
          final beats = mixedTrace(
            cell.physical,
            cell.bpm,
            cell.amplitude,
            seed,
          );
          // Frozen membership is never selected by this implementation's decisions.
          expect(
            f.run(beats, sleeping: false).episodes,
            hasLength(1),
            reason: 'mixture control $key',
          );
          expect(
            f
                .run(
                  mixedTrace(
                    cell.physical,
                    cell.bpm,
                    cell.amplitude,
                    seed,
                    mixture: false,
                  ),
                )
                .episodes,
            hasLength(1),
            reason: 'sinusoid-free control $key',
          );
          {
            final result = f.run(beats);
            if (result.episodes.isEmpty) lost.add(key);
            for (final w in result.windows) {
              final residual = w.toJson()['breathing']['residual'] as Map?;
              final ratio = residual?['ratio'] as double?,
                  pnn = residual?['pnnPct'] as double?;
              if (ratio != null) {
                minRatio = minRatio == null ? ratio : min(minRatio, ratio);
              }
              if (pnn != null) {
                minPnn = minPnn == null ? pnn : min(minPnn, pnn);
              }
            }
          }
          cases++;
        }
        print('RESIDUAL_PROGRESS cases=$cases lost=${lost.length}');
      }
      print(
        'PROTECTED_RESIDUAL ${jsonEncode({'cases': cases, 'lost': lost, 'minResidualRatio': minRatio, 'minResidualPnnPct': minPnn})}',
      );
      expect(cases, 997, reason: 'membership frozen before changing the veto');
      expect(lost, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 12)),
    tags: 'sweep',
  );
  // WHY: keep the concrete counterexample cheap enough for every pulse gate.
  // # catches: failing to connect the residual decision to production detection.
  test(
    '52 bpm random RR with 50 ms respiratory modulation remains eligible',
    () {
      {
        final result = f.run(mixedTrace(true, 52, 50, 0));
        expect(result.episodes, hasLength(1));
        expect(result.windows.every((w) => w.qualified), isTrue);
      }
    },
  );
  // WHY: subtraction must not re-clean residuals or create pairs across dropped beats.
  // # catches: recomputing adjacency on a dense or re-cleaned residual series.
  test(
    'residual evidence retains the original quality and adjacency masks',
    () {
      final rr = sleepRrFixtures.first;
      final beats = f.trace(f.target, 25, (i, _) => rr[i % rr.length]);
      final asleep = f.run(beats, from: f.target, to: f.target + 600000);
      final awake = f.run(
        beats,
        sleeping: false,
        from: f.target,
        to: f.target + 600000,
      );
      final window = asleep.windows.first;
      final residual = window.toJson()['breathing']['residual'] as Map;
      expect(window.cleanedBeats, greaterThan(0));
      expect(residual['status'], 'supported');
      expect(residual['domain'], 'original_beats');
      expect(residual['pairs'], window.pairs);
      expect(residual['ratioFloor'], .7);
      expect(residual['pnnFloor'], 30);
      expect(
        window.beats.map((b) => b.toJson()).toList(),
        awake.windows.first.beats.map((b) => b.toJson()).toList(),
      );
    },
  );
  // WHY: a numerically computable but weak respiratory fit is not exclusion evidence.
  // # catches: dropping the fit-strength guard before applying residual floors.
  test('weak five-minute fits preserve fixed-floor eligibility', () {
    final rr = sleepRrFixtures[5];
    final beats = f.trace(f.target, 25, (i, _) => rr[i % rr.length]);
    {
      final result = f.run(
        beats,
        
        from: f.target,
        to: f.target + 600000,
      );
      expect(result.episodes, hasLength(1));
      for (final w in result.windows) {
        expect(
          w.toJson()['breathing']['residual'],
          containsPair('status', 'weak'),
        );
        expect(w.qualified, isTrue);
      }
    }
  });
}
