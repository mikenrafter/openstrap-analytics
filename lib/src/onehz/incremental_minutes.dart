part of 'incremental.dart';

class MinuteMetrics {
  final Metric<double> trimp;
  final Metric<double> strain;
  final ({double total, double active, double basal, double walking})? energy;
  final MinuteEnergySeries? minutes;
  const MinuteMetrics(
      {required this.trimp, required this.strain, this.energy, this.minutes});
}

// Owned by IncrementalMinuteMetrics. Rows follow the caller's last key order.
// Null cadence has its own presence bit so it remains distinct from NaN.
class _MinuteBillColumns {
  final Float64List hr, cadence, trimp, active, walking;
  final Uint8List hasCadence, source;
  _MinuteBillColumns(int capacity)
      : hr = Float64List(capacity),
        cadence = Float64List(capacity),
        trimp = Float64List(capacity),
        active = Float64List(capacity),
        walking = Float64List(capacity),
        hasCadence = Uint8List(capacity),
        source = Uint8List(capacity);

  double? cadenceAt(int i) => hasCadence[i] == 0 ? null : cadence[i];
  MinuteEnergySource? sourceAt(int i) =>
      source[i] == 0 ? null : MinuteEnergySource.values[source[i] - 1];

  void copyRow(int to, _MinuteBillColumns old, int from) {
    hr[to] = old.hr[from];
    cadence[to] = old.cadence[from];
    hasCadence[to] = old.hasCadence[from];
    trimp[to] = old.trimp[from];
    active[to] = old.active[from];
    walking[to] = old.walking[from];
    source[to] = old.source[from];
  }
}

/// Retains nonlinear TRIMP and energy contributions by caller-supplied key.
/// Keys must be unique. Day duration must be a finite whole number of minutes,
/// matching the batch dailyEnergy API's integer duration.
// Banister 1991 / Morton 1990 TRIMP; Keytel 2005 / Mifflin-St Jeor 1990 / Tudor-
// Locke 2019 energy. Retains identical keyed minute contributions; edits replace
// them and dependency changes rebuild.
// CLAIM(minute-bill-order): cached contributions fold in input order using
// batch's compensated TRIMP sum and separate ordinary HR/walking sums
// [minute_bill_cache_test: exact batch bytes after edits/removal/reorder/insertion].
class IncrementalMinuteMetrics {
  final Map<int, int> _billIndices = {};
  final List<int> _keys = [];
  _MinuteBillColumns _columns = _MinuteBillColumns(0);
  bool _cacheReady = true;
  List<Object?>? _parameters;
  double _trimpTotal = 0;
  double _hrActiveTotal = 0, _walkingTotal = 0;
  double? _basalPerMinute;
  MinuteEnergyPricer? _energyPricer;
  bool _pricerReady = false;
  int _processedMinutes = 0;
  IncrementalMinuteMetrics();

  factory IncrementalMinuteMetrics.fromJson(Map<String, dynamic> json) {
    _version(json, 'IncrementalMinuteMetrics');
    final state = IncrementalMinuteMetrics();
    state._processedMinutes = _count(json['processedMinutes']);
    state._trimpTotal = _number(json['trimpTotal'], finite: true);
    state._basalPerMinute = json['basalPerMinute'] == null
        ? null
        : _number(json['basalPerMinute'], finite: true);
    // A basal rate is energy per minute at rest: never negative. A negative one
    // would pass through an unchanged-parameter sync and price a walking minute
    // at a negative surplus, which the next restore then refuses.
    if (state._basalPerMinute != null && state._basalPerMinute! < 0) {
      throw const FormatException('Invalid basal rate');
    }
    if (json['parameters'] != null) {
      final parameters = json['parameters'];
      if (parameters is! List ||
          parameters.length != 4 ||
          parameters[2] is! String ||
          !Sex.values.any((s) => s.name == parameters[2])) {
        throw const FormatException('Invalid minute parameters');
      }
      for (final i in [0, 1]) {
        if (parameters[i] != null) _number(parameters[i]);
      }
      final profile = parameters[3];
      if (profile != null) {
        if (profile is! List || profile.length != 4 || profile[3] is! String)
          throw const FormatException('Invalid minute profile');
        for (var i = 0; i < 3; i++) {
          _number(profile[i]);
        }
      }
      state._parameters = [
        parameters[0],
        parameters[1],
        parameters[2],
        profile == null ? null : List<Object?>.of(profile as List),
      ];
    }
    if (json['bills'] is! List)
      throw const FormatException('Invalid minute bills');
    state._columns = _MinuteBillColumns((json['bills'] as List).length);
    var summedTrimp = 0.0;
    for (final raw in json['bills'] as List) {
      final data = _map(raw);
      if (data['key'] is! int)
        throw const FormatException('Invalid minute key');
      final key = data['key'] as int;
      if (state._billIndices.containsKey(key))
        throw const FormatException('Duplicate minute key');
      final hr = _number(data['hr']);
      final cadence = data['cadence'] == null ? null : _number(data['cadence']);
      final trimp = _number(data['trimp'], finite: true);
      final active = _number(data['active'], finite: true);
      final walking = _number(data['walking'], finite: true);
      final sourceName = data['source'];
      MinuteEnergySource? source;
      if (sourceName != null) {
        if (sourceName is! String ||
            !MinuteEnergySource.values.any((s) => s.name == sourceName))
          throw const FormatException('Invalid energy source');
        source = MinuteEnergySource.values.byName(sourceName);
      }
      if (trimp < 0 ||
          active < 0 ||
          walking < 0 ||
          (source != MinuteEnergySource.cadence && walking != 0) ||
          (source != MinuteEnergySource.hr && active != 0) ||
          (state._basalPerMinute == null && source != null))
        throw const FormatException('Invalid minute contribution');
      final i = state._keys.length;
      state._billIndices[key] = i;
      state._keys.add(key);
      state._columns.hr[i] = hr;
      state._columns.cadence[i] = cadence ?? 0;
      state._columns.hasCadence[i] = cadence == null ? 0 : 1;
      state._columns.trimp[i] = trimp;
      state._columns.source[i] = source == null ? 0 : source.index + 1;
      state._columns.active[i] = active;
      state._columns.walking[i] = walking;
      summedTrimp += trimp;
      state._hrActiveTotal += active;
      state._walkingTotal += walking;
    }
    if (state._processedMinutes < state._billIndices.length ||
        (state._parameters == null && state._billIndices.isNotEmpty) ||
        (summedTrimp - state._trimpTotal).abs() >
            1e-9 * math.max(1, summedTrimp))
      throw const FormatException('Inconsistent minute checkpoint');
    // Older version-one checkpoints have all minute contributions and can
    // reconstruct these totals. New checkpoints retain the unrounded sums.
    for (final field in ['hrActiveTotal', 'walkingTotal']) {
      if (!json.containsKey(field)) continue;
      final saved = _number(json[field], finite: true);
      final rebuilt =
          field == 'hrActiveTotal' ? state._hrActiveTotal : state._walkingTotal;
      if (saved < 0 || (saved - rebuilt).abs() > 1e-9 * math.max(1, rebuilt)) {
        throw const FormatException('Inconsistent energy total');
      }
      if (field == 'hrActiveTotal') {
        state._hrActiveTotal = saved;
      } else {
        state._walkingTotal = saved;
      }
    }
    final columns = json['billColumns'];
    // CLAIM(minute-bill-migration): version-one row checkpoints predate the
    // canonical fold. Reprice once on sync, retaining the accepted basal rate
    // [minute_bill_cache_test: legacy checkpoint without bill columns].
    state._cacheReady = columns != null;
    if (columns != null) {
      final saved = _map(columns);
      for (final entry in <String, List<num>>{
        'trimp': state._columns.trimp,
        'active': state._columns.active,
        'walking': state._columns.walking,
        'source': state._columns.source,
      }.entries) {
        final values = saved[entry.key];
        if (values is! List || values.length != state._keys.length) {
          throw const FormatException('Invalid minute bill column');
        }
        for (var i = 0; i < values.length; i++) {
          if (_number(values[i], finite: true) != entry.value[i]) {
            throw const FormatException('Inconsistent minute bill column');
          }
        }
      }
    }
    return state;
  }
  int get processedMinutes => _processedMinutes;

  MinuteMetrics sync(
    List<int> minuteKeys,
    List<double> hr, {
    List<double?>? cadenceSpm,
    double? restingHr,
    double? maxHr,
    Sex sex = Sex.male,
    WorkoutUserProfile? profile,
    int dayMinutes = 1440,
    double? quietHrr,
    // As in [strainScoreMetric]. Defaults to calibrating: leaving it out can
    // only understate confidence, never claim a settled level.
    bool quietSettled = false,
    bool force = false,
    bool includeMinuteSeries = true,
  }) {
    if (minuteKeys.length != hr.length ||
        (cadenceSpm != null && cadenceSpm.length != hr.length))
      throw ArgumentError('Minute keys, HR and cadence must align');
    var keyPrefix = minuteKeys.length >= _keys.length;
    if (keyPrefix) {
      for (var i = 0; i < _keys.length; i++) {
        if (minuteKeys[i] != _keys[i]) {
          keyPrefix = false;
          break;
        }
      }
    }
    // Validate before changing owned state. Retained prefix keys are already
    // unique, so an ordinary interior value edit needs no set allocation.
    if (keyPrefix) {
      final added = minuteKeys.length - _keys.length > 1 ? <int>{} : null;
      for (var i = _keys.length; i < minuteKeys.length; i++) {
        if (_billIndices.containsKey(minuteKeys[i]) ||
            (added != null && !added.add(minuteKeys[i]))) {
          throw ArgumentError('Minute keys must be unique');
        }
      }
    } else if (minuteKeys.toSet().length != minuteKeys.length) {
      throw ArgumentError('Minute keys must be unique');
    }
    final parameters = <Object?>[
      restingHr == null ? null : _encode(restingHr),
      maxHr == null ? null : _encode(maxHr),
      sex.name,
      profile == null
          ? null
          : [
              _encode(profile.weightKg),
              _encode(profile.heightCm),
              _encode(profile.age),
              profile.sex
            ],
    ];
    final reprice = force || !_equalState(_parameters, parameters);
    final trimpValid = restingHr != null &&
        maxHr != null &&
        restingHr.isFinite &&
        maxHr.isFinite &&
        maxHr > restingHr;
    if (reprice || !_pricerReady) {
      _energyPricer = profile == null || restingHr == null || maxHr == null
          ? null
          : Calories.minuteEnergyPricer(
              profile: profile,
              hrmax: maxHr,
              restingHr: restingHr,
              basalKcalPerMin: reprice ? null : _basalPerMinute);
      // Restoring the callable must not change an accepted checkpoint's rate.
      // CLAIM(restored-minute-pricing): retained and new bills use that rate
      // [minute_metrics_test: restored basal prices appended surplus].
      // Parameter changes or force select the current profile's rate instead.
      if (reprice) _basalPerMinute = _energyPricer?.basalKcalPerMin;
      _pricerReady = true;
    }
    final priceAll = reprice || !_cacheReady;
    final oldColumns = _columns;
    final oldLength = _keys.length;
    final rebuildOrder = !keyPrefix;
    if (rebuildOrder || hr.length > _columns.hr.length) {
      _columns = _MinuteBillColumns(math.max(hr.length, oldLength * 2));
      if (!rebuildOrder) {
        for (var i = 0; i < oldLength; i++) {
          _columns.copyRow(i, oldColumns, i);
        }
      }
    }
    for (var i = 0; i < hr.length; i++) {
      final oldIndex = keyPrefix
          ? (i < oldLength ? i : null)
          : _billIndices[minuteKeys[i]];
      final value = hr[i], cadence = cadenceSpm?[i];
      if (!priceAll &&
          oldIndex != null &&
          _same(oldColumns.hr[oldIndex], value) &&
          _same(oldColumns.cadenceAt(oldIndex), cadence)) {
        if (rebuildOrder) _columns.copyRow(i, oldColumns, oldIndex);
        continue;
      }
      var trimp = 0.0;
      if (trimpValid && value.isFinite && value > 0) {
        final hrr = ((value - restingHr) / (maxHr - restingHr)).clamp(0.0, 1.0);
        trimp = hrr * StrainScorer.banisterY(hrr, female: sex == Sex.female);
      }
      MinuteEnergySource? source;
      var active = 0.0, walking = 0.0;
      if (_energyPricer != null) {
        final bill = _energyPricer!.price(value, cadence);
        source = bill.source;
        active = bill.active;
        walking = bill.walking;
      }
      _columns.hr[i] = value;
      _columns.cadence[i] = cadence ?? 0;
      _columns.hasCadence[i] = cadence == null ? 0 : 1;
      _columns.trimp[i] = trimp;
      _columns.active[i] = active;
      _columns.walking[i] = walking;
      _columns.source[i] = source == null ? 0 : source.index + 1;
      _processedMinutes++;
    }
    if (rebuildOrder) {
      _keys.clear();
      _billIndices.clear();
    }
    for (var i = _keys.length; i < minuteKeys.length; i++) {
      _keys.add(minuteKeys[i]);
      _billIndices[minuteKeys[i]] = i;
    }
    _parameters = parameters;
    _cacheReady = true;
    // Reuse the batch sum implementation. A view avoids copying or repricing
    // the cached TRIMP column; ordinary energy sums match dailyEnergy's order.
    // ↳ CLAIM(minute-bill-order)
    final sum = Sum<DoubleColumn>((batch) => batch.values);
    _trimpTotal = sum.finish(sum.addSlice(
        sum.empty(),
        DoubleColumn(Float64List.sublistView(_columns.trimp, 0, hr.length)),
        0,
        hr.length));
    _hrActiveTotal = _walkingTotal = 0;
    for (var i = 0; i < hr.length; i++) {
      _hrActiveTotal += _columns.active[i];
      _walkingTotal += _columns.walking[i];
    }
    final trimp = !trimpValid || hr.isEmpty
        ? banisterTrimp(const [], restingHr: restingHr, maxHr: maxHr, sex: sex)
        : Metric<double>(
            value: _trimpTotal,
            confidence: .6,
            tier: Tier.estimate,
            inputs_used: const ['hr_per_min', 'resting_hr', 'max_hr'],
            note: 'Banister exponential TRIMP (wrist HR estimate)');
    final strain = strainScoreMetric(trimp.value,
        wakeMinutes: hr.length.toDouble(),
        quietHrr: quietHrr,
        quietSettled: quietSettled,
        female: sex == Sex.female);
    final minutes = !includeMinuteSeries || _basalPerMinute == null
        ? null
        : Calories.assembleMinuteEnergySeries([
            for (var i = 0; i < minuteKeys.length; i++)
              (
                minute: minuteKeys[i],
                source: _columns.sourceAt(i),
                active: _columns.active[i],
                walking: _columns.walking[i]
              ),
          ], basalKcalPerMin: _basalPerMinute!);
    final basal = (_basalPerMinute ?? 0) * dayMinutes;
    final active = minutes?.active ?? (_hrActiveTotal + _walkingTotal);
    final walking = minutes?.walking ?? _walkingTotal;
    return MinuteMetrics(
        trimp: trimp,
        strain: strain,
        minutes: minutes,
        energy: _basalPerMinute == null
            ? null
            : (
                total: basal + active,
                active: active,
                basal: basal,
                walking: walking
              ));
  }

  // Preserve the row format for older readers. A null billColumns marks a
  // pending legacy rebuild; exported columns are copies of the typed buffers.
  Map<String, dynamic> toJson() => {
        'version': 1,
        'type': 'IncrementalMinuteMetrics',
        'processedMinutes': _processedMinutes,
        'parameters': _parameters == null
            ? null
            : [
                _parameters![0],
                _parameters![1],
                _parameters![2],
                _parameters![3] == null
                    ? null
                    : List.of(_parameters![3] as List),
              ],
        'trimpTotal': _trimpTotal,
        'hrActiveTotal': _hrActiveTotal,
        'walkingTotal': _walkingTotal,
        'basalPerMinute': _basalPerMinute,
        'bills': [
          for (var i = 0; i < _keys.length; i++)
            {
              'key': _keys[i],
              'hr': _encode(_columns.hr[i]),
              'cadence': _columns.cadenceAt(i) == null
                  ? null
                  : _encode(_columns.cadence[i]),
              'trimp': _columns.trimp[i],
              'source': _columns.sourceAt(i)?.name,
              'active': _columns.active[i],
              'walking': _columns.walking[i],
            }
        ],
        'billColumns': !_cacheReady
            ? null
            : {
            'trimp': _columns.trimp.take(_keys.length).toList(),
            'active': _columns.active.take(_keys.length).toList(),
            'walking': _columns.walking.take(_keys.length).toList(),
            'source': _columns.source.take(_keys.length).toList(),
          },
      };
}

bool _equalState(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_equalState(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
