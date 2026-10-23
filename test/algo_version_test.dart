// RED: the analytics-side algorithm counters for the combined bump
// (wall-clock epoch grid + RR artifact-run cap).
//
// This package has no `kAlgoVersion` (that lives in edge). What it versions is
// the calculation-group registry: `GroupDecl.counter` is "a plain integer,
// bumped when the group's algorithm changes" (group_registry.dart). The
// combined bump changes two groups' outputs:
//   * found.rr_correction: correctRr / RrCorrector cap artifact runs at
//     kMaxArtifactRun (a longer run is a gap);
//   * sleep.stage: the epoch grid is the 30 s wall clock, not the usable run's
//     start.
// Everything else keeps its counter (groups that depend on these re-derive
// through `deps`, not through their own counter).
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  int counterOf(String id) =>
      kAnalyticsGroupRegistry.groups.firstWhere((g) => g.id == id).counter;

  test('found.rr_correction and sleep.stage are on counter 2', () {
    expect(counterOf('found.rr_correction'), 2);
    expect(counterOf('sleep.stage'), 2);
  });

  test('no other group\'s counter moved', () {
    final moved = {
      for (final g in kAnalyticsGroupRegistry.groups)
        if (g.counter != 1 &&
            g.id != 'found.rr_correction' &&
            g.id != 'sleep.stage')
          g.id: g.counter
    };
    expect(moved, isEmpty);
  });
}
