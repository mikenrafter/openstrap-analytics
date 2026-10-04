import 'dart:math' as math;

import 'util.dart';

/// Removable, mergeable centered moments, with an origin to retain precision
/// when a series has a large offset and a small spread.
class RunningMoments {
  int _count = 0;
  double _origin = 0, _meanOffset = 0, _m2 = 0;

  RunningMoments();

  factory RunningMoments.fromJson(Map<String, dynamic> json) {
    _checkVersion(json, 'RunningMoments');
    final result = RunningMoments();
    result._count = _readCount(json['count']);
    result._origin = _readFinite(json['origin']);
    result._meanOffset = _readFinite(json['meanOffset']);
    result._m2 = _readFinite(json['m2']);
    if (result._m2 < 0 ||
        (result._count == 0 &&
            (result._origin != 0 ||
                result._meanOffset != 0 ||
                result._m2 != 0)) ||
        (result._count == 1 && result._m2 != 0)) {
      throw const FormatException('Invalid centered moments');
    }
    return result;
  }

  int get count => _count;
  double? get mean => _count == 0 ? null : _origin + _meanOffset;
  double? get sampleSd => _count < 2 ? null : math.sqrt(_m2 / (_count - 1));
  double? get populationSd => _count == 0 ? null : math.sqrt(_m2 / _count);

  void add(double x) {
    if (!x.isFinite) throw ArgumentError.value(x, 'x', 'Must be finite');
    if (_count == 0) {
      _origin = x;
      _count = 1;
      return;
    }
    final centered = x - _origin;
    final delta = centered - _meanOffset;
    _count++;
    _meanOffset += delta / _count;
    _m2 += delta * (centered - _meanOffset);
  }

  /// The caller must remove a value represented by this summary.
  void remove(double x) {
    if (!x.isFinite) throw ArgumentError.value(x, 'x', 'Must be finite');
    if (_count == 0) throw StateError('Cannot remove from empty moments');
    if (_count == 1) {
      _count = 0;
      _origin = _meanOffset = _m2 = 0;
      return;
    }
    final centered = x - _origin;
    final oldMean = _meanOffset;
    _count--;
    _meanOffset += (_meanOffset - centered) / _count;
    _m2 = math.max(0, _m2 - (centered - oldMean) * (centered - _meanOffset));
    if (_count == 1) _m2 = 0;
  }

  void merge(RunningMoments other) {
    if (other._count == 0) return;
    if (_count == 0) {
      _count = other._count;
      _origin = other._origin;
      _meanOffset = other._meanOffset;
      _m2 = other._m2;
      return;
    }
    final otherCount = other._count;
    final combinedCount = _count + otherCount;
    final delta = (other._origin - _origin) + other._meanOffset - _meanOffset;
    _m2 += other._m2 + delta * delta * _count * otherCount / combinedCount;
    _meanOffset += delta * otherCount / combinedCount;
    _count = combinedCount;
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'type': 'RunningMoments',
        'count': _count,
        'origin': _origin,
        'meanOffset': _meanOffset,
        'm2': _m2,
      };
}

/// Fixed-grid spectral sums. Raw snapshots establish that each sync is a
/// genuine prefix; callers may revise or remove any earlier sample.
class IncrementalLombScargle {
  final List<double> _frequencies;
  List<double> _t = [], _y = [];
  List<List<double>> _sums;
  RunningMoments _moments = RunningMoments();
  int _processedPoints = 0;
  bool _incremental = true;
  double _origin = 0, _yOrigin = 0, _tMin = 0, _tMax = 0;

  IncrementalLombScargle(List<double> frequencies)
      : _frequencies = List.of(frequencies),
        _sums = [for (final _ in frequencies) List.filled(7, 0.0)];

  factory IncrementalLombScargle.fromJson(Map<String, dynamic> json) {
    _checkVersion(json, 'IncrementalLombScargle');
    final result = IncrementalLombScargle(_readDoubles(json['frequencies']));
    result._t = _readDoubles(json['t']);
    result._y = _readDoubles(json['y']);
    result._processedPoints = _readCount(json['processedPoints']);
    final incremental = json['incremental'];
    if (incremental is! bool || result._t.length != result._y.length) {
      throw const FormatException('Invalid spectral input state');
    }
    result._incremental = incremental;
    result._origin = _readFinite(json['origin']);
    result._yOrigin = _readFinite(json['yOrigin']);
    result._tMin = _readFinite(json['tMin']);
    result._tMax = _readFinite(json['tMax']);
    final moments = json['moments'];
    if (moments is! Map<String, dynamic>) {
      throw const FormatException('Missing spectral moments');
    }
    result._moments = RunningMoments.fromJson(moments);
    final sums = json['sums'];
    if (sums is! List || sums.length != result._frequencies.length) {
      throw const FormatException('Invalid spectral sum dimensions');
    }
    result._sums = [
      for (final row in sums) _readDoubles(row, finite: true),
    ];
    if (result._sums.any((row) => row.length != 7) ||
        (incremental &&
            (!result._allFinite(result._t, result._y) ||
                result._moments.count != result._t.length ||
                result._processedPoints < result._t.length)) ||
        (!incremental && result._moments.count != 0)) {
      throw const FormatException('Invalid spectral accumulator');
    }
    if (result._t.isEmpty || !incremental) {
      if (result._origin != 0 ||
          result._yOrigin != 0 ||
          result._tMin != 0 ||
          result._tMax != 0 ||
          result._sums.any((row) => row.any((value) => value != 0))) {
        throw const FormatException('Invalid empty spectral state');
      }
    }
    if (incremental && result._t.isNotEmpty) {
      if (result._origin != result._t.first ||
          result._yOrigin != result._y.first ||
          result._tMin != result._t.reduce(math.min) ||
          result._tMax != result._t.reduce(math.max)) {
        throw const FormatException('Invalid spectral origin or extrema');
      }
      for (final row in result._sums) {
        if (row[2] < 0 ||
            row[3] < 0 ||
            ((row[2] + row[3]) - result._t.length).abs() >
                1e-8 * result._t.length) {
          throw const FormatException('Invalid trigonometric sums');
        }
      }
    }
    return result;
  }

  int get processedPoints => _processedPoints;

  bool _allFinite(List<double> t, List<double> y) =>
      _frequencies.every((x) => x.isFinite) &&
      t.every((x) => x.isFinite) &&
      y.every((x) => x.isFinite);

  LombScargle? sync(List<double> t, List<double> y, {bool force = false}) {
    if (t.length != y.length) {
      _reset();
      return lombScargle(t, y, _frequencies);
    }
    if (!_allFinite(t, y)) {
      // The batch function defines the NaN/infinity behavior. Never fold these
      // values into summaries that could contaminate later finite prefixes.
      final result = lombScargle(t, y, _frequencies);
      _reset();
      _incremental = false;
      _t = List.of(t);
      _y = List.of(y);
      if (t.length >= 4 && _frequencies.isNotEmpty)
        _processedPoints += t.length;
      return result;
    }
    var prefix = !force && _incremental && t.length >= _t.length;
    if (prefix) {
      for (var i = 0; i < _t.length; i++) {
        if (_t[i] != t[i] || _y[i] != y[i]) {
          prefix = false;
          break;
        }
      }
    }
    if (!prefix) _reset();
    final start = _t.length;
    if (start == 0 && t.isNotEmpty) {
      _origin = _tMin = _tMax = t.first;
      _yOrigin = y.first;
    }
    for (var i = start; i < t.length; i++) {
      _moments.add(y[i]);
      _tMin = math.min(_tMin, t[i]);
      _tMax = math.max(_tMax, t[i]);
      for (var j = 0; j < _frequencies.length; j++) {
        final w = 2 * math.pi * _frequencies[j];
        final c = math.cos(w * (t[i] - _origin));
        final s = math.sin(w * (t[i] - _origin));
        final centeredY = y[i] - _yOrigin;
        final sums = _sums[j];
        sums[0] += c;
        sums[1] += s;
        sums[2] += c * c;
        sums[3] += s * s;
        sums[4] += c * s;
        sums[5] += centeredY * c;
        sums[6] += centeredY * s;
      }
      _processedPoints++;
    }
    _t = List.of(t);
    _y = List.of(y);
    return _render();
  }

  void _reset() {
    _t = [];
    _y = [];
    _sums = [for (final _ in _frequencies) List.filled(7, 0.0)];
    _moments = RunningMoments();
    _origin = _yOrigin = _tMin = _tMax = 0;
    _incremental = true;
  }

  LombScargle? _render() {
    final n = _moments.count;
    final span = _tMax - _tMin;
    if (n < 4 || _frequencies.isEmpty || _moments._m2 <= 0 || span <= 0) {
      return null;
    }
    final centeredMean = (_moments._origin - _yOrigin) + _moments._meanOffset;
    final spectrum = <LsPoint>[];
    for (var j = 0; j < _frequencies.length; j++) {
      final frequency = _frequencies[j];
      if (frequency == 0) {
        spectrum.add(const LsPoint(0, 0));
        continue;
      }
      final sums = _sums[j];
      final phi = 0.5 * math.atan2(2 * sums[4], sums[2] - sums[3]);
      final a = math.cos(phi), b = math.sin(phi);
      final uc = sums[5] - centeredMean * sums[0];
      final us = sums[6] - centeredMean * sums[1];
      final cNum = a * uc + b * us, sNum = a * us - b * uc;
      final cDen = a * a * sums[2] + b * b * sums[3] + 2 * a * b * sums[4];
      final sDen = a * a * sums[3] + b * b * sums[2] - 2 * a * b * sums[4];
      final term1 = cDen == 0 ? 0.0 : cNum * cNum / cDen;
      final term2 = sDen == 0 ? 0.0 : sNum * sNum / sDen;
      spectrum.add(LsPoint(frequency, span / (n - 1) * (term1 + term2)));
    }
    return LombScargle(spectrum);
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'type': 'IncrementalLombScargle',
        'frequencies': _writeDoubles(_frequencies),
        't': _writeDoubles(_t),
        'y': _writeDoubles(_y),
        'processedPoints': _processedPoints,
        'incremental': _incremental,
        'origin': _origin,
        'yOrigin': _yOrigin,
        'tMin': _tMin,
        'tMax': _tMax,
        'moments': _moments.toJson(),
        'sums': [for (final row in _sums) List<double>.of(row)],
      };
}

void _checkVersion(Map<String, dynamic> json, String type) {
  if (json['version'] is! int || json['version'] != 1 || json['type'] != type) {
    throw FormatException('Unsupported $type checkpoint');
  }
}

int _readCount(Object? value) {
  if (value is! int || value < 0) throw const FormatException('Invalid count');
  return value;
}

double _readFinite(Object? value) {
  if (value is! num || !value.isFinite)
    throw const FormatException('Invalid number');
  return value.toDouble();
}

List<double> _readDoubles(Object? value, {bool finite = false}) {
  if (value is! List) throw const FormatException('Expected a numeric list');
  return [for (final item in value) _readDouble(item, finite: finite)];
}

double _readDouble(Object? value, {bool finite = false}) {
  if (value is num && (!finite || value.isFinite)) return value.toDouble();
  if (!finite) {
    if (value == 'NaN') return double.nan;
    if (value == 'Infinity') return double.infinity;
    if (value == '-Infinity') return double.negativeInfinity;
  }
  throw const FormatException('Invalid number');
}

List<Object> _writeDoubles(List<double> values) => [
      for (final value in values)
        if (value.isFinite)
          value
        else if (value.isNaN)
          'NaN'
        else if (value > 0)
          'Infinity'
        else
          '-Infinity',
    ];

class _CalculationEntry {
  final Object? dependencies;
  final Object? value;
  const _CalculationEntry(this.dependencies, this.value);
}

/// Bounded least-recently-used results with owned dependency snapshots.
class CalculationCache {
  final int maxEntries;
  final Map<String, _CalculationEntry> _entries = {};
  int _computations = 0, _hits = 0;

  CalculationCache({this.maxEntries = 128}) {
    if (maxEntries < 1) throw ArgumentError.value(maxEntries, 'maxEntries');
  }

  int get computations => _computations;
  int get hits => _hits;

  T evaluate<T>(String key, Object? dependencies, T Function() calculate,
      {bool full = false}) {
    final old = _entries[key];
    if (!full && old != null && _deepEqual(old.dependencies, dependencies)) {
      final result = _copyValue(old.value) as T;
      _entries.remove(key);
      _entries[key] = old;
      _hits++;
      return result;
    }
    // Snapshot before calling user code, which may itself mutate dependencies.
    // Prepare both copies before committing, so exceptions preserve the old entry.
    final snapshot = _snapshotDependency(dependencies);
    final value = _copyValue(calculate());
    final result = _copyValue(value) as T;
    _entries.remove(key);
    _entries[key] = _CalculationEntry(snapshot, value);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _computations++;
    return result;
  }

  void clear() => _entries.clear();
}

Object? _snapshotDependency(Object? value) {
  if (value is List)
    return [for (final item in value) _snapshotDependency(item)];
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key: _snapshotDependency(entry.value)
    };
  }
  return value;
}

bool _deepEqual(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is num && b is num && a.isNaN && b.isNaN) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEqual(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_deepEqual(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}

Object? _copyValue(Object? value) {
  if (value is List) {
    // toList dispatches on the original List<E> and keeps its reified E.
    final copy = value.toList();
    for (var i = 0; i < copy.length; i++) {
      copy[i] = _copyValue(value[i]);
    }
    return copy;
  }
  if (value is Map) {
    // Preserve the usual JSON map types, including typed scalar/list values.
    // Unlike List.toList, Map.map creates new key/value types from its callback.
    if (value is Map<String, double>) return _copyMap(value);
    if (value is Map<String, int>) return _copyMap(value);
    if (value is Map<String, num>) return _copyMap(value);
    if (value is Map<String, bool>) return _copyMap(value);
    if (value is Map<String, String>) return _copyMap(value);
    if (value is Map<String, double?>) return _copyMap(value);
    if (value is Map<String, int?>) return _copyMap(value);
    if (value is Map<String, num?>) return _copyMap(value);
    if (value is Map<String, bool?>) return _copyMap(value);
    if (value is Map<String, String?>) return _copyMap(value);
    if (value is Map<String, List<double>>) return _copyMap(value);
    if (value is Map<String, List<int>>) return _copyMap(value);
    if (value is Map<String, List<String>>) return _copyMap(value);
    if (value is Map<String, List<double?>>) return _copyMap(value);
    if (value is Map<String, List<int?>>) return _copyMap(value);
    if (value is Map<String, List<String?>>) return _copyMap(value);
    if (value is Map<String, Map<String, double>>) return _copyMap(value);
    if (value is Map<String, Map<String, int>>) return _copyMap(value);
    if (value is Map<String, Map<String, String>>) return _copyMap(value);
    if (value is Map<String, Map<String, dynamic>>) return _copyMap(value);
    if (value is Map<String, List<Map<String, dynamic>>>)
      return _copyMap(value);
    if (value is Map<String, List<dynamic>>) return _copyMap(value);
    if (value is Map<String, dynamic>) return _copyMap(value);
    if (value is Map<int, double>) return _copyMap(value);
    if (value is Map<int, int>) return _copyMap(value);
    if (value is Map<int, String>) return _copyMap(value);
    if (value is Map<int, List<double>>) return _copyMap(value);
    if (value is Map<int, List<int>>) return _copyMap(value);
    if (value is Map<int, dynamic>) return _copyMap(value);
    return _copyMap(value);
  }
  // Metric and other immutable domain values retain their identity and type.
  return value;
}

Map<K, V> _copyMap<K, V>(Map<K, V> value) => {
      for (final entry in value.entries)
        entry.key: _copyValue(entry.value) as V,
    };
