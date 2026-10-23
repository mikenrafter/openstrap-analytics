// Wall-clock 30 s epoch feature rows, accumulated. RED-phase stub: signatures
// only, bodies throw. test/onehz/epoch_rows_test.dart pins the contract.
//
//   * Epoch starts are multiples of [kEpochMs] since the Unix epoch (UTC),
//     whatever time the data starts at. An epoch is clipped only by a data gap
//     (the seconds the data does not have), never by where a session starts.
//   * A row's features are `cardioEpochFeatures`' for that epoch: motion, hr,
//     hrSd from the epoch's own seconds (motion against the local 1 g median
//     of the +-150 s of accel magnitudes around it), rmssd / sdnn from the
//     +-150 s RR window centred on the epoch, lfhf / rk from the +-90 s one.
//     Lookback therefore reaches 165 s (accel, HR) and 150 s (RR) past an
//     epoch's edges.
//   * A row is FINAL once every sample it can read has arrived (newest sample
//     is at least ~3 min past the epoch); the last few rows are PROVISIONAL and
//     are recomputed with the data clipped at the newest sample.
//   * Chunk invariance is exact: any chunking, with a save/restore through JSON
//     text between chunks, gives the same rows as one fold.

import 'dart:math' as math;
import 'dart:typed_data';

import '../../aggregate/json_support.dart';
import 'advanced_stager.dart' show StageSegment;
import 'accounting.dart' show SleepStage;
import 'cardio_stager.dart';
import 'cardio_row_cache.dart';
import '../types.dart';
import '../foundations/rr_correction_kernel.dart' show SortedMultiset;
import '../util.dart';

/// Epoch length of the UTC wall-clock grid, ms.
const int kEpochMs = 30000;

/// Raw features of one wall-clock epoch; NaN means not measurable.
class EpochFeatureRow {
  final int startMs;
  final double motion, hr, hrSd, rmssd, lfhf, rk, sdnn;
  final int _hrSeconds;
  const EpochFeatureRow(this.startMs, this.motion, this.hr, this.hrSd,
      this.rmssd, this.lfhf, this.rk, this.sdnn,
      {int hrSeconds = 0})
      : _hrSeconds = hrSeconds;

  List<Object> _encode() => [
        startMs,
        for (final v in [motion, hr, hrSd, rmssd, lfhf, rk, sdnn])
          encodeDouble(v),
        _hrSeconds
      ];

  static EpochFeatureRow _decode(Object? value) {
    final l = decodeList(value);
    if (l.length != 9 ||
        l[0] is! int ||
        (l[0] as int) % kEpochMs != 0 ||
        l[8] is! int ||
        (l[8] as int) < 0) {
      throw const FormatException('Invalid epoch row');
    }
    return EpochFeatureRow(
        l[0] as int,
        decodeDouble(l[1]),
        decodeDouble(l[2]),
        decodeDouble(l[3]),
        decodeDouble(l[4]),
        decodeDouble(l[5]),
        decodeDouble(l[6]),
        decodeDouble(l[7]),
        hrSeconds: l[8] as int);
  }
}

/// Final feature rows and the raw time lookback needed by pending rows.
/// Each fold advances all input channels through the same watermark. A channel
/// omitted from a fold has no samples there, rather than arriving late later.
class EpochRows {
  EpochRows({CardioRowCache? rowCache}) : _cache = rowCache;
  final CardioRowCache? _cache;
  final _hr = <HrSample>[];
  final _accel = <AccelSample>[];
  final _rr = <double>[], _rt = <double>[];
  final _final = <EpochFeatureRow>[];
  final _pending = <int>{};
  // Accel coverage with the same bounded 60-second carry as the stager. These
  // intervals cost one pair per actual outage, not one entry per second.
  final _runs = <(int, int)>[];
  int? _newest;

  static int epochStartMs(int tsMs) => tsMs - tsMs % kEpochMs;
  int? get newestMs => _newest;
  List<EpochFeatureRow> get finalRows => List.unmodifiable(_final);

  void fold(
      {List<HrSample> hr = const [],
      List<AccelSample> accel = const [],
      List<double> rrMs = const [],
      List<double> rrTsMs = const []}) {
    if (rrMs.length != rrTsMs.length) {
      throw ArgumentError('RR columns differ in length');
    }
    void check(Iterable<double> times, double? last) {
      for (final t in times) {
        if (!t.isFinite || (last != null && t < last)) {
          throw ArgumentError('samples must have finite, ascending times');
        }
        if (_newest != null &&
            epochStartMs(t.floor()) <= epochStartMs(_newest! - 240000)) {
          throw ArgumentError('sample precedes the settled watermark');
        }
        last = t;
      }
    }

    check(hr.map((v) => v.tsMs), _hr.isEmpty ? null : _hr.last.tsMs);
    check(accel.map((v) => v.tsMs), _accel.isEmpty ? null : _accel.last.tsMs);
    check(rrTsMs, _rt.isEmpty ? null : _rt.last);
    for (final v in rrMs) {
      if (!v.isFinite) throw ArgumentError('non-finite RR');
    }
    void observe(double t) {
      final ms = t.floor();
      _newest = _newest == null ? ms : math.max(_newest!, ms);
      _pending.add(epochStartMs(ms));
    }

    for (final h in hr) {
      _hr.add(h);
      observe(h.tsMs);
    }
    for (final a in accel) {
      _accel.add(a);
      observe(a.tsMs);
      if (!a.valid) continue;
      final second = (a.tsMs / 1000).floor();
      if (_runs.isNotEmpty && second <= _runs.last.$2) {
        final prev = _runs.removeLast();
        _runs.add((prev.$1, math.max(prev.$2, second + 61)));
      } else {
        _runs.add((second, second + 61));
      }
    }
    _rr.addAll(rrMs);
    _rt.addAll(rrTsMs);
    for (final t in rrTsMs) {
      observe(t);
    }
    if (_newest == null) return;
    final starts = _pending.where((s) => s <= _newest! - 240000).toList()
      ..sort();
    _final.addAll(_rows(starts));
    _pending.removeAll(starts);
    // The oldest still-possible row starts after the final watermark; retain
    // its widest left window, even when there are no pending rows in a gap.
    final oldest = epochStartMs(_newest! - 240000) + kEpochMs - 165000;
    _hr.removeWhere((h) => h.tsMs < oldest);
    _accel.removeWhere((a) => a.tsMs < oldest);
    final drop = _lower(_rt, oldest.toDouble());
    if (drop > 0) {
      _rr.removeRange(0, drop);
      _rt.removeRange(0, drop);
    }
  }

  List<EpochFeatureRow> provisionalRows() {
    final starts = _pending.toList()..sort();
    return _rows(starts);
  }

  List<EpochFeatureRow> allRows() => [..._final, ...provisionalRows()];

  static int _lower(List<double> times, double value) {
    var a = 0, b = times.length;
    while (a < b) {
      final m = (a + b) >> 1;
      if (times[m] < value) {
        a = m + 1;
      } else {
        b = m;
      }
    }
    return a;
  }

  static int _sampleLower<T>(
      List<T> samples, double value, double Function(T) time) {
    var a = 0, b = samples.length;
    while (a < b) {
      final m = (a + b) >> 1;
      if (time(samples[m]) < value) {
        a = m + 1;
      } else {
        b = m;
      }
    }
    return a;
  }

  List<EpochFeatureRow> _rows(List<int> starts) {
    if (starts.isEmpty) return [];
    if (_cache != null) return [for (final s in starts) _row(s)];
    // Slide the same sorted 330-second gravity window used by the batch
    // extractor, computing each sample's magnitude once per fold.
    final mag = [
      for (final a in _accel) math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
    ];
    final sorted = SortedMultiset();
    var lo = 0, hi = 0;
    final out = <EpochFeatureRow>[];
    for (final start in starts) {
      final nextLo = _sampleLower(_accel, start - 150000.0, (a) => a.tsMs);
      final nextHi = _sampleLower(_accel, start + 180000.0, (a) => a.tsMs);
      while (lo < nextLo && lo < hi) {
        if (_accel[lo].valid) sorted.remove(mag[lo]);
        lo++;
      }
      lo = nextLo;
      hi = math.max(hi, nextLo);
      while (hi < nextHi) {
        if (_accel[hi].valid) sorted.add(mag[hi]);
        hi++;
      }
      out.add(_row(start, reference: percentileSorted(sorted.a, 50) ?? 1.0));
    }
    return out;
  }

  EpochFeatureRow _row(int start, {double? reference}) {
    final end = start + kEpochMs;
    final ab = _sampleLower(
        _accel, start - (reference == null ? 150000.0 : 0.0), (a) => a.tsMs);
    final ae = _sampleLower(
        _accel, end + (reference == null ? 150000.0 : 0.0), (a) => a.tsMs);
    final hb = _sampleLower(_hr, start.toDouble(), (h) => h.tsMs);
    final he = _sampleLower(_hr, end.toDouble(), (h) => h.tsMs);
    final av = [
      for (var i = ab; i < ae; i++)
        if (_accel[i].valid) _accel[i]
    ];
    final hv = [
      for (var i = hb; i < he; i++)
        if (_hr[i].valid) _hr[i].hr
    ];
    final low = start - 135000.0, high = start + 165000.0;
    final rb = _lower(_rt, low), re = _lower(_rt, high + 0.001);
    CardioRowKey? key;
    if (_cache != null) {
      var hash = 0xcbf29ce484222325;
      final bits = ByteData(8);
      void number(double v) {
        bits.setFloat64(0, v, Endian.little);
        hash = (hash ^ bits.getUint64(0, Endian.little)) * 0x100000001b3;
      }

      number(0x45504f434832.toDouble()); // EPOCH2, separate from old grid keys.
      for (final a in av) {
        number(a.tsMs);
        number(a.x);
        number(a.y);
        number(a.z);
      }
      number(-1);
      for (var i = hb; i < he; i++) {
        number(_hr[i].tsMs);
        number(_hr[i].hr);
      }
      number(-2);
      for (var i = rb; i < re; i++) {
        number(_rt[i]);
        number(_rr[i]);
      }
      key = CardioRowKey(start ~/ 1000, 30, hash);
      final hit = _cache.lookup(key);
      if (hit != null)
        return EpochFeatureRow(start, hit.motion, hit.hr, hit.hrSd, hit.rmssd,
            hit.lfhf, hit.rk, hit.sdnn,
            hrSeconds: hv.length);
    }
    final mag = [
      for (final a in av) math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
    ];
    final ref = reference ?? median(mag) ?? 1.0;
    var motion = 0.0, count = 0;
    for (var i = 0; i < av.length; i++) {
      if (av[i].tsMs >= start && av[i].tsMs < end) {
        final d = mag[i] - ref;
        motion += d > 0 ? d : 0.0;
        count++;
      }
    }
    final beats = cleanRrBeatsBetween(_rr, _rt, low, high);
    var ss = 0.0, pairs = 0;
    for (var i = 1; i < beats.beats.length; i++) {
      if (beats.seam[i]) continue;
      final d = beats.beats[i] - beats.beats[i - 1];
      ss += d * d;
      pairs++;
    }
    final remBeats =
        cleanRrBeatsBetween(_rr, _rt, start - 75000.0, start + 105000.0);
    final rem =
        remFeaturesFromBeats(remBeats.beats, remBeats.tsSec, remBeats.seam);
    final row = EpochFeatureRow(
        start,
        count == 0 ? double.nan : motion / count,
        mean(hv) ?? double.nan,
        hv.length >= 2 ? stddev(hv) ?? 0 : 0,
        beats.beats.length >= 5 && pairs >= 4
            ? math.sqrt(ss / pairs)
            : double.nan,
        rem.lfhf ?? double.nan,
        rem.rk ?? double.nan,
        beats.beats.length >= 5
            ? stddev(beats.beats) ?? double.nan
            : double.nan,
        hrSeconds: hv.length);
    if (key != null)
      _cache!.insert(
          key,
          CardioEpochRow(row.motion, row.hr, row.hrSd, row.rmssd, row.lfhf,
              row.rk, row.sdnn));
    return row;
  }

  /// Classifies cached features with session-wide baselines. Features retain
  /// their observed context when a session's start or end moves.
  List<StageSegment> stageWindow(int startSec, int endSec) {
    if (endSec <= startSec) return const [];
    final rows = allRows();
    final pieces = <StageSegment>[];
    var cursor = startSec;
    for (final run in _runs) {
      final lo = math.max(startSec, run.$1), hi = math.min(endSec, run.$2);
      if (hi <= lo) continue;
      if (lo > cursor) pieces.add(StageSegment(cursor, lo, 'unobserved'));
      final byStart = {for (final r in rows) r.startMs: r};
      // A carry-only epoch still consumes wall-clock time in the classifier.
      // Keep its absent HR in the coverage denominator; omitting it can turn
      // an otherwise abstained run into apparently sufficient cardiac data.
      final chosen = <EpochFeatureRow>[
        for (var s = epochStartMs(lo * 1000); s < hi * 1000; s += kEpochMs)
          byStart[s] ??
              EpochFeatureRow(s, 0, double.nan, 0, double.nan, double.nan,
                  double.nan, double.nan)
      ];
      final features = CardioEpochFeatures(
          motion: [for (final r in chosen) r.motion],
          hr: [for (final r in chosen) r.hr],
          hrSd: [for (final r in chosen) r.hrSd],
          rmssd: [for (final r in chosen) r.rmssd],
          lfhf: [for (final r in chosen) r.lfhf],
          rk: [for (final r in chosen) r.rk],
          sdnn: [for (final r in chosen) r.sdnn]);
      final result = classifyCardioEpochs(features);
      final labels = result.base.stages;
      final hrSeconds = chosen.fold<int>(0, (sum, row) => sum + row._hrSeconds);
      // Partial epochs must not inflate coverage: one observed second in
      // each epoch is still sparse HR, even if every epoch has a mean.
      if (hi - lo < 90 ||
          labels.isEmpty ||
          hrSeconds / (hi - lo) < minHrCoverage) {
        pieces.add(StageSegment(lo, hi, 'unobserved'));
      } else {
        var at = lo;
        for (var i = 0; i < labels.length; i++) {
          final label = switch (labels[i]) {
            SleepStage.wake => 'wake',
            SleepStage.rem => 'rem',
            SleepStage.nrem => result.deepFlag[i] ? 'deep' : 'light',
          };
          final until = i + 1 == labels.length
              ? hi
              : math.min(hi, chosen[i + 1].startMs ~/ 1000);
          if (until > at) pieces.add(StageSegment(at, until, label));
          at = until;
        }
      }
      cursor = hi;
    }
    if (cursor < endSec) pieces.add(StageSegment(cursor, endSec, 'unobserved'));
    final out = <StageSegment>[];
    for (final p in pieces) {
      if (out.isNotEmpty &&
          out.last.end == p.start &&
          out.last.stage == p.stage) {
        final prev = out.removeLast();
        out.add(StageSegment(prev.start, p.end, p.stage));
      } else {
        out.add(p);
      }
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        'type': 'EpochRows',
        'version': 1,
        'newest': _newest,
        'rows': [for (final r in _final) r._encode()],
        'pending': _pending.toList()..sort(),
        'hr': [
          for (final h in _hr) [h.tsMs, encodeDouble(h.hr)]
        ],
        'accel': [
          for (final a in _accel)
            [
              a.tsMs,
              encodeDouble(a.x),
              encodeDouble(a.y),
              encodeDouble(a.z),
              a.valid
            ]
        ],
        'rr': _rr,
        'rt': _rt,
        'runs': [
          for (final r in _runs) [r.$1, r.$2]
        ],
      };

  factory EpochRows.fromJson(Map<String, dynamic> json) {
    try {
      if (json['type'] != 'EpochRows' || json['version'] != 1) {
        throw const FormatException('Unsupported EpochRows checkpoint');
      }
      final er = EpochRows();
      er._newest = field(json, 'newest') as int?;
      er._final.addAll([
        for (final v in decodeList(field(json, 'rows')))
          EpochFeatureRow._decode(v)
      ]);
      final pending = decodeList(field(json, 'pending')).cast<int>();
      er._pending.addAll(pending);
      if (er._pending.length != pending.length) {
        throw const FormatException('Duplicate pending epoch');
      }
      for (final v in decodeList(field(json, 'hr'))) {
        final l = decodeList(v);
        if (l.length != 2) throw const FormatException('Invalid HR row');
        er._hr.add(HrSample(decodeDouble(l[0]), decodeDouble(l[1])));
      }
      for (final v in decodeList(field(json, 'accel'))) {
        final l = decodeList(v);
        if (l.length != 5 || l[4] is! bool)
          throw const FormatException('Invalid accel row');
        er._accel.add(AccelSample(decodeDouble(l[0]), decodeDouble(l[1]),
            decodeDouble(l[2]), decodeDouble(l[3]),
            valid: l[4] as bool));
      }
      er._rr.addAll(decodeDoubles(field(json, 'rr')));
      er._rt.addAll(decodeDoubles(field(json, 'rt')));
      for (final v in decodeList(field(json, 'runs'))) {
        final l = decodeList(v);
        if (l.length != 2 ||
            l[0] is! int ||
            l[1] is! int ||
            (l[0] as int) >= (l[1] as int) ||
            (er._runs.isNotEmpty && (l[0] as int) <= er._runs.last.$2)) {
          throw const FormatException('Invalid coverage run');
        }
        er._runs.add((l[0] as int, l[1] as int));
      }
      bool ascending(Iterable<double> values) {
        double? prev;
        for (final v in values) {
          if (!v.isFinite || (prev != null && v < prev)) return false;
          prev = v;
        }
        return true;
      }

      if (er._rr.length != er._rt.length ||
          !ascending(er._hr.map((h) => h.tsMs)) ||
          !ascending(er._accel.map((a) => a.tsMs)) ||
          !ascending(er._rt) ||
          !er._rr.every((v) => v.isFinite) ||
          !ascending(er._final.map((r) => r.startMs.toDouble())) ||
          er._final.map((r) => r.startMs).toSet().length != er._final.length ||
          er._pending.any((s) =>
              s % kEpochMs != 0 ||
              (er._final.isNotEmpty && s <= er._final.last.startMs)) ||
          (er._newest != null &&
              (er._final.any((r) => r.startMs > er._newest! - 240000) ||
                  er._pending.any((s) =>
                      s <= er._newest! - 240000 ||
                      s > epochStartMs(er._newest!)) ||
                  er._pending.length > 14 ||
                  er._hr.any((h) => h.tsMs >= er._newest! + 1) ||
                  er._accel.any((a) => a.tsMs >= er._newest! + 1) ||
                  er._rt.any((t) => t >= er._newest! + 1) ||
                  er._runs.any((r) => r.$2 > er._newest! ~/ 1000 + 61))) ||
          (er._newest == null &&
              (er._final.isNotEmpty ||
                  er._pending.isNotEmpty ||
                  er._hr.isNotEmpty ||
                  er._accel.isNotEmpty ||
                  er._rt.isNotEmpty))) {
        throw const FormatException('Inconsistent EpochRows checkpoint');
      }
      return er;
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('Malformed EpochRows checkpoint: $e');
    }
  }
}
