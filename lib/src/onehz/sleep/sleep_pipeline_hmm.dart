// Experimental #628 offline model. These engineering weights have not been
// validated against polysomnography. This is not a medical device or a basis
// for medical decisions. Mutable decoding state is local to each call/session.
//
// PROVENANCE: ported from upstream #628. Local changes, each reviewed against
// any future upstream change to this file: (1) the decoder's baselines cover the
// whole session, not the first 120 minutes (onset-bias correction); (2) the
// degenerate-output predicate [hmm628IsDegenerate] that lets the stager fall
// back to the default staging. Everything else is upstream's.
import 'dart:math' as math;

/// A measured 30-second epoch. Null/nonfinite channels remain unobserved.
class HmmEpoch {
  final int startSec;
  final double? hr, rmssd;
  final bool contactLost;

  /// Wrist motion in this epoch: true when the gravity vector turned by more
  /// than [kMotionGateDeg] between two consecutive seconds, false when it was
  /// observed and did not, null when motion is unknown (no usable gravity).
  /// Null means the wake gate does not apply to this epoch.
  final bool? moved;
  const HmmEpoch(
    this.startSec, {
    this.hr,
    this.rmssd,
    this.contactLost = false,
    this.moved,
  });
}

/// Measured metadata, independent of the selected staging classifier.
class NightBaselines {
  final double? hrMinNight, rmssdMeanNight;
  const NightBaselines({this.hrMinNight, this.rmssdMeanNight});
  Map<String, dynamic> toJson() => {
    'hr_min_night': hrMinNight,
    'rmssd_mean_night': rmssdMeanNight,
  };
}

// Movement-density wake gate (hmm-all-deep-diagnosis.md section 12; Option A
// alone called 158 min of false wake on the owner's 10-27 night, A + this gate
// 2 min). An epoch may be wake only if at least kMotionGateDensity of the
// epochs with known motion within +-kMotionGateWindowSec contain a turn of more
// than kMotionGateDeg between consecutive seconds. Otherwise the wake emission
// is scaled by kMotionGateWake (it can still win if HR and HRV agree
// overwhelmingly). Unknown motion (moved == null): the gate does not apply and
// wake stays allowed. The constants are engineering choices fitted to one
// night. CLAIM: unvalidated; a still, awake person is read as asleep (the
// classic wrist-actigraphy weakness).
const double kMotionGateDeg = 5;
const int kMotionGateWindowSec = 300;
const double kMotionGateDensity = 0.25;
const double kMotionGateWake = 0.05;

// Baseline artifact rejection (section 12): RMSSD above kArtifactRmssdMs at an
// HR above kArtifactHrBpm is not physiological (the owner's 06:02-06:31 stretch
// read RMSSD 100-125 ms at HR 88-144 on a motionless wrist). Such an epoch is
// left out of the DECODER's baseline statistics, both channels, and is labelled
// 'unobserved' (the chain breaks there; the cardio fallback keeps the gap).
// The published onset baselines are unchanged.
// CLAIM: unvalidated thresholds.
const double kArtifactRmssdMs = 100;
const double kArtifactHrBpm = 100;
/// True for an epoch the decoder rejects as not physiological (see above). It
/// is excluded from the baselines AND left unobserved (the Viterbi chain breaks
/// there), so no stage is published from evidence the decoder rejected.
bool hmm628IsArtifact(HmmEpoch e) =>
    _validHr(e.hr) &&
    _validRmssd(e.rmssd) &&
    e.rmssd! > kArtifactRmssdMs &&
    e.hr! > kArtifactHrBpm;

bool _validHr(double? v) => v != null && v.isFinite && v > 30 && v < 200;
bool _validRmssd(double? v) => v != null && v.isFinite && v > 0 && v < 500;

/// Upstream #628 statistics over [rows]: p10 order statistic HR and mean epoch
/// RMSSD. Channels are filtered independently (an epoch with a valid HR and no
/// RMSSD still feeds the HR statistic); contact loss excludes an epoch from
/// both. No substitution from RHR, readiness, an earlier session or an absent
/// channel.
NightBaselines _baselinesOf(Iterable<HmmEpoch> rows,
    {bool rejectArtifacts = false}) {
  final hr = <double>[], rmssd = <double>[];
  for (final e in rows) {
    if (e.contactLost) continue;
    if (rejectArtifacts && hmm628IsArtifact(e)) continue;
    if (_validHr(e.hr)) hr.add(e.hr!);
    if (_validRmssd(e.rmssd)) rmssd.add(e.rmssd!);
  }
  hr.sort();
  return NightBaselines(
    hrMinNight: hr.isEmpty ? null : hr[(hr.length * .1).floor()],
    rmssdMeanNight: rmssd.isEmpty
        ? null
        : rmssd.reduce((a, b) => a + b) / rmssd.length,
  );
}

/// PUBLISHED onset metadata (`hr_min_night`, `rmssd_mean_night`), unchanged for
/// every staging method: upstream #628's statistics over the first 120 elapsed
/// minutes of this session. This is NOT the decoder's baseline any more; see
/// [hmm628Stages].
NightBaselines computeNightBaselines(
  List<HmmEpoch> epochs, {
  required int sessionStartSec,
}) => _baselinesOf(epochs.where((e) =>
    e.startSec >= sessionStartSec && e.startSec < sessionStartSec + 7200));

/// Per-epoch wake multiplier (1 or [kMotionGateWake]); see the gate note above.
/// [epochs] are in time order.
List<double> _motionGates(List<HmmEpoch> epochs) {
  final out = List<double>.filled(epochs.length, 1);
  var lo = 0, hi = 0, known = 0, moved = 0;
  void add(HmmEpoch e, int sign) {
    if (e.moved == null) return;
    known += sign;
    if (e.moved!) moved += sign;
  }
  for (var i = 0; i < epochs.length; i++) {
    final t = epochs[i].startSec;
    while (hi < epochs.length &&
        epochs[hi].startSec <= t + kMotionGateWindowSec) {
      add(epochs[hi++], 1);
    }
    while (lo < hi && epochs[lo].startSec < t - kMotionGateWindowSec) {
      add(epochs[lo++], -1);
    }
    if (epochs[i].moved == null || known == 0) continue;
    if (moved < kMotionGateDensity * known) out[i] = kMotionGateWake;
  }
  return out;
}

const _labels = ['wake', 'light', 'deep', 'rem'];
const _transitions = [
  [.90, .09, .005, .005],
  [.05, .80, .10, .05],
  [.02, .15, .80, .03],
  [.05, .10, .00, .85],
];

double _sigmoid(double x, double center, double scale) =>
    1 / (1 + math.exp(-(x - center) / scale));
double _emission(int state, HmmEpoch e, NightBaselines b, double gate) {
  final h = e.hr! / b.hrMinNight!, r = e.rmssd! / b.rmssdMeanNight!;
  final p = switch (state) {
    0 => _sigmoid(h, 1.2, .05) * (1 - _sigmoid(r, .8, .05)) * gate,
    1 => .4,
    2 => (1 - _sigmoid(h, 1, .05)) * _sigmoid(r, 1.1, .05),
    _ => _sigmoid(h, 1.05, .05) * _sigmoid(r, 1, .05),
  };
  return math.log(math.max(.01, p));
}

/// One label per input epoch. Missing measurements and time gaps terminate the
/// Viterbi chain rather than becoming uniform emissions and invented stages.
///
/// LOCAL DEVIATION FROM UPSTREAM #628 (hmm-fix-spec.md, Option A): the decoder's
/// baselines come from EVERY epoch of [epochs] (the session), not the first 120
/// minutes. Upstream's onset-only window reads the normal overnight HR fall and
/// HRV rise as deep. This corrects onset bias only; it is not a sleep-specific
/// baseline, and it does NOT correct deep timing (deep stays low and late).
/// Emissions, the .05 scales, transitions, initials and chain-termination rules
/// are upstream's, unchanged. [sessionStartSec] is kept for API compatibility.
/// CLAIM: unvalidated. Experimental sleep-stage estimates; not validated
/// against a clinical sleep study; not for medical decisions.
List<String> hmm628Stages(
  List<HmmEpoch> epochs, {
  required int sessionStartSec,
}) {
  final baseline = _baselinesOf(epochs, rejectArtifacts: true);
  final gates = _motionGates(epochs);
  final labels = List<String>.filled(epochs.length, 'unobserved');
  if (baseline.hrMinNight == null || baseline.rmssdMeanNight == null)
    return labels;
  bool observed(HmmEpoch e) =>
      !e.contactLost &&
      _validHr(e.hr) &&
      _validRmssd(e.rmssd) &&
      !hmm628IsArtifact(e);
  var start = 0;
  while (start < epochs.length) {
    if (!observed(epochs[start])) {
      start++;
      continue;
    }
    var end = start + 1;
    while (end < epochs.length &&
        observed(epochs[end]) &&
        epochs[end].startSec - epochs[end - 1].startSec == 30) {
      end++;
    }
    final back = List.generate(end - start, (_) => List<int>.filled(4, 0));
    var score = [
      for (var s = 0; s < 4; s++)
        (s < 2 ? math.log(.5) : double.negativeInfinity) +
            _emission(s, epochs[start], baseline, gates[start]),
    ];
    for (var t = start + 1; t < end; t++) {
      final next = List<double>.filled(4, double.negativeInfinity);
      for (var s = 0; s < 4; s++) {
        for (var prev = 0; prev < 4; prev++) {
          final v =
              score[prev] +
              math.log(_transitions[prev][s]) +
              _emission(s, epochs[t], baseline, gates[t]);
          if (v > next[s]) {
            next[s] = v;
            back[t - start][s] = prev;
          }
        }
      }
      score = next;
    }
    var state = 0;
    for (var s = 1; s < 4; s++) {
      if (score[s] > score[state]) state = s;
    }
    for (var t = end - 1; t >= start; t--) {
      labels[t] = _labels[state];
      state = back[t - start][state];
    }
    start = end;
  }
  return labels;
}

/// Degenerate-output guard (hmm-fix-spec.md section 3). True iff at least 120
/// CLASSIFIED labels (wake, light, deep, rem; 'unobserved' counts as neither
/// numerator nor denominator) and one stage holds at least 90% of them.
/// Integer arithmetic: exactly 90% triggers, 89.9% does not. 120 epochs is 60
/// minutes; both numbers are policy choices, not physiology. CLAIM: unvalidated.
bool hmm628IsDegenerate(List<String> labels) {
  final count = <String, int>{};
  var classified = 0;
  for (final l in labels) {
    if (!_labels.contains(l)) continue;
    classified++;
    count[l] = (count[l] ?? 0) + 1;
  }
  if (classified < 120) return false;
  final top = count.values.fold<int>(0, (m, c) => c > m ? c : m);
  return top * 10 >= classified * 9;
}
