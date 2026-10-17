import '../../aggregate/aggregator.dart';
import '../../aggregate/primitives.dart';
import '../types.dart';
import 'load_trimp.dart';

const _trimpInputs = ['hr_per_min', 'resting_hr', 'max_hr'];
const _trimpNote =
    'Banister TRIMP needs finite measured RHR and HRmax (HRmax>RHR)';

/// Builds a mergeable Banister TRIMP summary over per-minute mean HR values.
///
/// The resulting metric has the same missing-input and empty-input behaviour as
/// [banisterTrimp].
Aggregator<dynamic, DoubleColumn, Metric<double>> banisterTrimpAggregator({
  required double? restingHr,
  required double? maxHr,
  required Sex sex,
}) {
  final anchorsValid = restingHr != null &&
      maxHr != null &&
      restingHr.isFinite &&
      maxHr.isFinite &&
      maxHr > restingHr;
  final reserve = anchorsValid ? maxHr - restingHr : 0.0;
  final core = both(
    Count<DoubleColumn>(),
    SumOf<DoubleColumn>((batch) => batch.values, (hr) {
      if (!anchorsValid || !hr.isFinite || hr <= 0) return double.nan;
      var hrr = (hr - restingHr) / reserve;
      if (hrr < 0) hrr = 0.0;
      if (hrr > 1) hrr = 1.0;
      return hrr * StrainScorer.banisterY(hrr, female: sex == Sex.female);
    }),
  );
  return core.map((result) {
    if (!anchorsValid || result.$1 == 0) {
      return const Metric<double>.absent(
        tier: Tier.estimate,
        inputs_used: _trimpInputs,
        note: _trimpNote,
      );
    }
    return Metric<double>(
      value: result.$2,
      confidence: 0.6,
      tier: Tier.estimate,
      inputs_used: _trimpInputs,
      note: 'Banister exponential TRIMP (wrist HR estimate)',
    );
  });
}
