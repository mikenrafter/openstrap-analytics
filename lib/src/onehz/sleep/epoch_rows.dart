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

import 'advanced_stager.dart' show StageSegment;
import '../types.dart';

/// Epoch length of the wall-clock grid, ms.
const int kEpochMs = 30000;

/// One wall-clock epoch's raw staging features (what `CardioEpochFeatures`
/// holds per epoch). NaN = not measurable, as there.
class EpochFeatureRow {
  /// Epoch start, ms since the Unix epoch; a multiple of [kEpochMs].
  final int startMs;
  final double motion, hr, hrSd, rmssd, lfhf, rk, sdnn;
  const EpochFeatureRow(this.startMs, this.motion, this.hr, this.hrSd,
      this.rmssd, this.lfhf, this.rk, this.sdnn);
}

class EpochRows {
  EpochRows();

  /// Restores from [toJson]. Throws [FormatException] on a checkpoint of
  /// another type or version, or one that is malformed.
  factory EpochRows.fromJson(Map<String, dynamic> json) =>
      throw UnimplementedError('EpochRows.fromJson');

  /// Plain JSON (survives `jsonEncode`/`jsonDecode` bit-exactly). Holds the
  /// final rows, the unsettled input tail and the open state; bounded by the
  /// night's row count, not its sample count.
  Map<String, dynamic> toJson() => throw UnimplementedError('EpochRows.toJson');

  /// Start of the wall-clock epoch containing [tsMs]: `tsMs ~/ 30000 * 30000`
  /// (floor, so also right for negative values).
  static int epochStartMs(int tsMs) =>
      throw UnimplementedError('EpochRows.epochStartMs');

  /// Appends samples in time order (chunks follow one another; inside a chunk
  /// every list is ascending in time). Any list may be empty. [rrMs] pairs with
  /// [rrTsMs] (same length; `rr_ts_ms` is whole-second, beats may tie).
  void fold({
    List<HrSample> hr = const [],
    List<AccelSample> accel = const [],
    List<double> rrMs = const [],
    List<double> rrTsMs = const [],
  }) =>
      throw UnimplementedError('EpochRows.fold');

  /// Newest sample time folded so far (ms); null before any sample.
  int? get newestMs => throw UnimplementedError('EpochRows.newestMs');

  /// Rows that can no longer change, ascending by start. Only ever grows.
  List<EpochFeatureRow> get finalRows =>
      throw UnimplementedError('EpochRows.finalRows');

  /// The rows after [finalRows], computed with the data clipped at the newest
  /// sample. Does not change the accumulator.
  List<EpochFeatureRow> provisionalRows() =>
      throw UnimplementedError('EpochRows.provisionalRows');

  /// `finalRows ++ provisionalRows()`.
  List<EpochFeatureRow> allRows() =>
      throw UnimplementedError('EpochRows.allRows');

  /// Stages the window `[startSec, endSec)` (Unix seconds) from the
  /// accumulated rows; equals `AdvancedSleepStager.stageWindow(startSec,
  /// endSec, ...)`'s `stages` on the same samples, exactly. Segment boundaries
  /// fall on the wall-clock grid except at the window edges and next to
  /// 'unobserved' stretches.
  List<StageSegment> stageWindow(int startSec, int endSec) =>
      throw UnimplementedError('EpochRows.stageWindow');
}
