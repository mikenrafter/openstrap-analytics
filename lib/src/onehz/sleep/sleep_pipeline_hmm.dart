// Experimental #628 offline model. These engineering weights have not been
// validated against polysomnography. This is not a medical device or a basis
// for medical decisions. Mutable decoding state is local to each call/session.
import 'dart:math' as math;

/// A measured 30-second epoch. Null/nonfinite channels remain unobserved.
class HmmEpoch {
  final int startSec;
  final double? hr, rmssd;
  final bool contactLost;
  const HmmEpoch(
    this.startSec, {
    this.hr,
    this.rmssd,
    this.contactLost = false,
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

bool _validHr(double? v) => v != null && v.isFinite && v > 30 && v < 200;
bool _validRmssd(double? v) => v != null && v.isFinite && v > 0 && v < 500;

/// Upstream #628: p10 order statistic HR and mean epoch RMSSD, using the
/// first 120 elapsed minutes of this session. Channels are independent; no
/// substitution from RHR, readiness, an earlier session or an absent channel.
NightBaselines computeNightBaselines(
  List<HmmEpoch> epochs, {
  required int sessionStartSec,
}) {
  final hr = <double>[], rmssd = <double>[];
  for (final e in epochs) {
    if (e.startSec < sessionStartSec ||
        e.startSec >= sessionStartSec + 7200 ||
        e.contactLost)
      continue;
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

const _labels = ['wake', 'light', 'deep', 'rem'];
const _transitions = [
  [.90, .09, .005, .005],
  [.05, .80, .10, .05],
  [.02, .15, .80, .03],
  [.05, .10, .00, .85],
];

double _sigmoid(double x, double center, double scale) =>
    1 / (1 + math.exp(-(x - center) / scale));
double _emission(int state, HmmEpoch e, NightBaselines b) {
  final h = e.hr! / b.hrMinNight!, r = e.rmssd! / b.rmssdMeanNight!;
  final p = switch (state) {
    0 => _sigmoid(h, 1.2, .05) * (1 - _sigmoid(r, .8, .05)),
    1 => .4,
    2 => (1 - _sigmoid(h, 1, .05)) * _sigmoid(r, 1.1, .05),
    _ => _sigmoid(h, 1.05, .05) * _sigmoid(r, 1, .05),
  };
  return math.log(math.max(.01, p));
}

/// One label per input epoch. Missing measurements and time gaps terminate the
/// Viterbi chain rather than becoming uniform emissions and invented stages.
List<String> hmm628Stages(
  List<HmmEpoch> epochs, {
  required int sessionStartSec,
}) {
  final baseline = computeNightBaselines(
    epochs,
    sessionStartSec: sessionStartSec,
  );
  final labels = List<String>.filled(epochs.length, 'unobserved');
  if (baseline.hrMinNight == null || baseline.rmssdMeanNight == null)
    return labels;
  bool observed(HmmEpoch e) =>
      !e.contactLost && _validHr(e.hr) && _validRmssd(e.rmssd);
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
            _emission(s, epochs[start], baseline),
    ];
    for (var t = start + 1; t < end; t++) {
      final next = List<double>.filled(4, double.negativeInfinity);
      for (var s = 0; s < 4; s++) {
        for (var prev = 0; prev < 4; prev++) {
          final v =
              score[prev] +
              math.log(_transitions[prev][s]) +
              _emission(s, epochs[t], baseline);
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
