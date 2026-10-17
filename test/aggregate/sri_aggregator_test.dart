// Epochs + sriAggregator, and the public phillipsSri rewired onto them, must
// reproduce the ORIGINAL phillipsSri exactly. `_referenceSri` below is a frozen
// copy of that original body. Do not edit it when phillipsSri is rewired.
//
// Contract used here:
//  * Epochs(asleep, {valid, firstIndex = 0}): asleep is 0/1 per epoch, valid
//    (optional, 0/1) the mask. The absolute epoch index of row r is
//    firstIndex + r. valid == null means every epoch is valid. Exported from
//    package:openstrap_analytics/aggregate.dart, with public fields asleep,
//    valid (Uint8List?) and firstIndex.
//  * copyRange(a, b) returns COPIES (the source can change afterwards) with
//    firstIndex shifted by a; a null valid stays null.
//  * join(other) requires other.firstIndex == firstIndex + length (assert; an
//    AssertionError in debug mode). When exactly one side has a mask, the
//    missing side counts as all-valid; the joined batch has a mask then, and
//    none when neither side has one. The joined batch is a new, independent
//    copy and keeps this.firstIndex.
//  * sriAggregator(epochsPerDay, {minPairCases}) is built for epochsPerDay >= 1
//    and run on batches with firstIndex 0 (the whole record, or its chunks cut
//    with copyRange / ranges of that one batch). Its result equals
//    phillipsSri on the same record (sri bit-identical, days, cases, every
//    pair, confidence, tier, inputs_used, note).
//  * phillipsSri(sleepWake, epochsPerDay, valid:, minPairCases:) keeps its
//    signature and behaviour, including epochsPerDay <= 0 (absent) and a
//    trailing partial day (ignored).

import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/property.dart' show Rng;

// ---------------------------------------------------------------------------
// FROZEN COPY of phillipsSri as it was before the rewire.
// ---------------------------------------------------------------------------
Metric<SriResult> _referenceSri(
  List<bool> sleepWake,
  int epochsPerDay, {
  List<bool>? valid,
  int? minPairCases,
}) {
  const inputs = ['sleep_wake_epochs'];
  final n = sleepWake.length;
  if (epochsPerDay <= 0 || n < 2 * epochsPerDay) {
    return const Metric<SriResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'need ≥2 full days of clock-aligned sleep/wake epochs for SRI',
    );
  }
  final days = n ~/ epochsPerDay;
  if (days < 2) {
    return const Metric<SriResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'need ≥2 full days for SRI',
    );
  }

  final pairFloor = minPairCases ?? (epochsPerDay ~/ 2);
  var agreement = 0;
  var cases = 0;
  final pairs = <SriPair>[];
  for (var d = 1; d < days; d++) {
    var pairAgreement = 0;
    var pairCases = 0;
    for (var e = 0; e < epochsPerDay; e++) {
      final iPrev = (d - 1) * epochsPerDay + e;
      final iCur = d * epochsPerDay + e;
      if (iCur >= n) break;
      if (valid != null && (!valid[iPrev] || !valid[iCur])) continue;
      pairCases++;
      if (sleepWake[iPrev] == sleepWake[iCur]) pairAgreement++;
    }
    agreement += pairAgreement;
    cases += pairCases;
    if (pairCases > 0 && pairCases >= pairFloor) {
      pairs.add(SriPair(d, pairAgreement, pairCases));
    }
  }
  if (cases == 0) {
    return const Metric<SriResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no valid epoch pairs for SRI',
    );
  }

  final sri = 200.0 * agreement / cases - 100.0;
  final conf = ((days - 1) / 7.0).clamp(0.3, 0.95);
  return Metric<SriResult>(
    value: SriResult(sri, days, cases, pairs),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'epoch-by-epoch 24-h concordance (Phillips 2017), '
        'SRI=200·agreement/cases−100; NOT SD-of-midsleep',
  );
}
// ---------------------------------------------------------------------------

typedef _Agg = Aggregator<dynamic, Epochs, Metric<SriResult>>;

/// Everything observable, flattened. Compared EXACTLY (no tolerance).
List<Object?> _fields(Metric<SriResult> m) {
  final v = m.value;
  return [
    m.present,
    m.confidence,
    m.tier,
    m.inputs_used.join(','),
    m.note,
    v?.sri,
    v?.days,
    v?.cases,
    v?.pairs.length,
    if (v != null)
      for (final p in v.pairs) ...[p.dayIndex, p.agreement, p.cases],
  ];
}

final _eq = fieldsEqual<Metric<SriResult>>(_fields);

void _same(Metric<SriResult> got, Metric<SriResult> want, String tag) {
  // Bit-identical sri, not just ==.
  if (want.value != null && got.value != null) {
    expect(got.value!.sri.toString(), want.value!.sri.toString(),
        reason: '$tag sri');
  }
  expect(_fields(got), _fields(want), reason: tag);
}

Epochs _epochs(List<bool> sw, [List<bool>? valid]) => Epochs(
      Uint8List.fromList([for (final b in sw) b ? 1 : 0]),
      valid: valid == null
          ? null
          : Uint8List.fromList([for (final b in valid) b ? 1 : 0]),
    );

class _Rec {
  _Rec(this.sw, this.valid);
  final List<bool> sw;
  final List<bool>? valid;
  Epochs get epochs => _epochs(sw, valid);
  int get n => sw.length;
  @override
  String toString() =>
      'n=$n sw=${sw.map((b) => b ? 1 : 0).join()} '
      'valid=${valid?.map((b) => b ? 1 : 0).join()}';
}

/// A record of [n] epochs: day-periodic sleep with [flipP] noise, optionally a
/// validity mask with holes (whole stretches and single epochs).
_Rec _record(Rng r, int n, int epd, {bool masked = false, double flipP = .1}) {
  final base = [for (var e = 0; e < epd; e++) r.nextBool()];
  final sw = [
    for (var i = 0; i < n; i++)
      r.nextBool(flipP) ? !base[i % epd] : base[i % epd]
  ];
  List<bool>? valid;
  if (masked) {
    valid = [for (var i = 0; i < n; i++) !r.nextBool(.15)];
    if (n > 0 && r.nextBool(.4)) {
      // A stretch of invalid epochs (a thin day).
      final a = r.intIn(0, n - 1), len = r.intIn(1, epd + 2);
      for (var i = a; i < a + len && i < n; i++) {
        valid[i] = false;
      }
    }
  }
  return _Rec(sw, valid);
}

void _allPaths(
    _Agg a, Epochs e, List<int> b, Metric<SriResult> want, String tag) {
  _same(runChunked(a, e, b), want, '$tag chunks $b');
  _same(runChunked(a, e, b, copy: true), want, '$tag copies $b');
  _same(runChunkedRight(a, e, b), want, '$tag right $b');
  _same(runSliced(a, e, b), want, '$tag sliced $b');
}

void _checkRecord(Rng r, _Rec rec, int epd, int? floor, String tag,
    {int slicings = 2}) {
  final want = _referenceSri(rec.sw, epd, valid: rec.valid, minPairCases: floor);
  // The public function (rewired) must still be the original.
  _same(phillipsSri(rec.sw, epd, valid: rec.valid, minPairCases: floor), want,
      '$tag phillipsSri');
  final a = sriAggregator(epd, minPairCases: floor);
  final e = rec.epochs;
  _same(a.run(e), want, '$tag run');
  for (var k = 0; k < slicings; k++) {
    _allPaths(a, e, randomBounds(r, rec.n), want, tag);
  }
  // Day-aligned and one-off-day-aligned cuts exercise the day boundary.
  final days = rec.n ~/ epd;
  if (days >= 1) {
    final aligned = [
      0,
      for (var d = 1; d <= days; d++) d * epd,
      if (rec.n % epd != 0) rec.n,
    ];
    _allPaths(a, e, aligned, want, '$tag aligned');
    final off = [
      0,
      for (var d = 1; d <= days; d++)
        if (d * epd - 1 > 0) d * epd - 1,
      rec.n,
    ];
    _allPaths(a, e, off, want, '$tag off-by-one');
  }
}

void main() {
  group('Epochs batch', () {
    Epochs mk(int n, {bool mask = false, int first = 0}) => Epochs(
          Uint8List.fromList([for (var i = 0; i < n; i++) i % 3 == 0 ? 1 : 0]),
          valid: mask
              ? Uint8List.fromList([for (var i = 0; i < n; i++) i % 4 == 0 ? 0 : 1])
              : null,
          firstIndex: first,
        );

    test('defaults and length', () {
      final e = mk(5);
      expect(e.length, 5);
      expect(e.firstIndex, 0);
      expect(e.valid, isNull);
      expect(mk(0).length, 0);
    });

    test('copyRange cuts rows and shifts firstIndex', () {
      final e = mk(10, mask: true);
      final c = e.copyRange(3, 8);
      expect(c.length, 5);
      expect(c.firstIndex, 3);
      expect(c.asleep, e.asleep.sublist(3, 8));
      expect(c.valid, e.valid!.sublist(3, 8));
      final cc = c.copyRange(2, 4);
      expect(cc.firstIndex, 5);
      expect(cc.asleep, e.asleep.sublist(5, 7));
      final shifted = mk(10, first: 100).copyRange(4, 10);
      expect(shifted.firstIndex, 104);
    });

    test('copyRange of nothing, and of a batch without a mask', () {
      final e = mk(6);
      final empty = e.copyRange(4, 4);
      expect(empty.length, 0);
      expect(empty.firstIndex, 4);
      expect(e.copyRange(0, 6).valid, isNull);
      expect(e.copyRange(0, 6).length, 6);
    });

    test('copies are independent of the source, both ways', () {
      final e = mk(8, mask: true);
      final snapshot = Uint8List.fromList(e.asleep);
      final snapshotValid = Uint8List.fromList(e.valid!);
      final c = e.copyRange(2, 6);
      e.asleep[3] ^= 1;
      e.valid![4] ^= 1;
      expect(c.asleep, snapshot.sublist(2, 6));
      expect(c.valid, snapshotValid.sublist(2, 6));
      final before = Uint8List.fromList(e.asleep);
      c.asleep[0] ^= 1;
      expect(e.asleep, before);
    });

    test('join of adjacent batches', () {
      final e = mk(10, mask: true);
      final j = e.copyRange(0, 4).join(e.copyRange(4, 10));
      expect(j.length, 10);
      expect(j.firstIndex, 0);
      expect(j.asleep, e.asleep);
      expect(j.valid, e.valid);
      final j2 = e.copyRange(2, 5).join(e.copyRange(5, 5)).join(e.copyRange(5, 9));
      expect(j2.firstIndex, 2);
      expect(j2.asleep, e.asleep.sublist(2, 9));
    });

    test('join result is independent of both inputs', () {
      final e = mk(6, mask: true);
      final left = e.copyRange(0, 3), right = e.copyRange(3, 6);
      final j = left.join(right);
      final want = Uint8List.fromList(j.asleep);
      left.asleep[0] ^= 1;
      right.asleep[0] ^= 1;
      expect(j.asleep, want);
    });

    test('join with one side unmasked treats it as all valid', () {
      final withMask = Epochs(Uint8List.fromList([1, 0]),
          valid: Uint8List.fromList([0, 1]));
      final plain = Epochs(Uint8List.fromList([1, 1]), firstIndex: 2);
      expect(withMask.join(plain).valid, [0, 1, 1, 1]);
      final plain0 = Epochs(Uint8List.fromList([1, 1]));
      final maskedAfter = Epochs(Uint8List.fromList([0, 0]),
          valid: Uint8List.fromList([1, 0]), firstIndex: 2);
      expect(plain0.join(maskedAfter).valid, [1, 1, 1, 0]);
      expect(plain0.join(Epochs(Uint8List(1), firstIndex: 2)).valid, isNull);
    });

    test('join of a non-adjacent batch asserts', () {
      final e = mk(10);
      expect(() => e.copyRange(0, 3).join(e.copyRange(4, 10)),
          throwsA(isA<AssertionError>()));
      expect(() => e.copyRange(3, 6).join(e.copyRange(0, 3)),
          throwsA(isA<AssertionError>()));
    });
  });

  group('known results', () {
    test('perfectly regular 3 days: sri 100, 2 pairs', () {
      final sw = [for (var i = 0; i < 12; i++) (i % 4) < 2];
      final m = sriAggregator(4).run(_epochs(sw));
      _same(m, _referenceSri(sw, 4), 'regular');
      expect(m.value!.sri, 100.0);
      expect(m.value!.days, 3);
      expect(m.value!.cases, 8);
      expect([for (final p in m.value!.pairs) p.dayIndex], [1, 2]);
    });
    test('anti-phase 2 days: sri -100', () {
      final sw = [true, true, false, false, false, false, true, true];
      final m = sriAggregator(4).run(_epochs(sw));
      expect(m.value!.sri, -100.0);
      expect(m.value!.days, 2);
      expect(m.confidence, 0.3); // (days-1)/7 clamped to 0.3..0.95
    });
    test('a trailing partial day is dropped at finish', () {
      // 2 full days + 3 stray epochs that would disagree if they were used.
      final sw = [true, false, true, false, true, false, true, false,
          false, false, false];
      final m = sriAggregator(4).run(_epochs(sw));
      _same(m, _referenceSri(sw, 4), 'partial');
      expect(m.value!.days, 2);
      expect(m.value!.cases, 4);
      expect(m.value!.sri, 100.0);
    });
  });

  group('absent cases (notes included)', () {
    final records = <String, (List<bool>, List<bool>?, int, int?)>{
      'empty': ([], null, 4, null),
      'one epoch': ([true], null, 4, null),
      'less than 2 days': ([for (var i = 0; i < 7; i++) i.isEven], null, 4, null),
      'exactly one day': ([true, false, true, false], null, 4, null),
      '2 days minus one': ([for (var i = 0; i < 7; i++) true], null, 4, null),
      'no valid pair': (
        [for (var i = 0; i < 8; i++) true],
        [true, true, false, false, false, false, true, true],
        4,
        null
      ),
      'mask all false': (
        [for (var i = 0; i < 12; i++) i.isEven],
        List.filled(12, false),
        4,
        0
      ),
    };
    records.forEach((name, rec) {
      test(name, () {
        final want = _referenceSri(rec.$1,
            rec.$3, valid: rec.$2, minPairCases: rec.$4);
        expect(want.present, isFalse);
        final a = sriAggregator(rec.$3, minPairCases: rec.$4);
        final e = _epochs(rec.$1, rec.$2);
        _same(a.run(e), want, name);
        _same(phillipsSri(rec.$1, rec.$3, valid: rec.$2, minPairCases: rec.$4),
            want, name);
        final r = Rng(name.hashCode & 0xffff);
        for (var k = 0; k < 3; k++) {
          _allPaths(a, e, randomBounds(r, e.length), want, name);
        }
      });
    });

    test('the two notes are the two different absent reasons', () {
      final short = sriAggregator(4).run(_epochs([true, false, true]));
      expect(short.note, contains('≥2 full days of clock-aligned'));
      final empty = sriAggregator(4).run(_epochs(List.filled(8, true),
          List.filled(8, false)));
      expect(empty.note, 'no valid epoch pairs for SRI');
      expect(short.confidence, 0);
      expect(empty.confidence, 0);
    });

    test('phillipsSri with epochsPerDay <= 0 stays absent', () {
      for (final epd in [0, -1, -1440]) {
        final want = _referenceSri([true, false, true, false], epd);
        _same(phillipsSri([true, false, true, false], epd), want, 'epd $epd');
        expect(want.present, isFalse);
      }
    });

    test('empty batch finishes absent, also from an empty state', () {
      final a = sriAggregator(4);
      final want = _referenceSri([], 4);
      _same(a.finish(a.empty()), want, 'empty state');
      _same(a.run(_epochs([])), want, 'empty batch');
    });
  });

  group('minPairCases', () {
    final r = Rng(0x5A1);
    final rec = _record(r, 5 * 6 + 2, 6, masked: true, flipP: .3);
    for (final floor in <int?>[null, 0, 1, 2, 3, 4, 6, 7, 100]) {
      test('floor $floor', () {
        _checkRecord(Rng(floor ?? -1), rec, 6, floor, 'floor $floor');
      });
    }
    test('floor hides thin pairs but not their cases', () {
      // Day 1 has 1 valid pair-case, day 2 has 4.
      final sw = [for (var i = 0; i < 12; i++) i.isEven];
      final valid = [
        true, false, false, false, // day 0
        true, true, true, true, // day 1: only epoch 0 pairs with day 0
        true, true, true, true, // day 2
      ];
      final a = sriAggregator(4, minPairCases: 2).run(_epochs(sw, valid));
      _same(a, _referenceSri(sw, 4, valid: valid, minPairCases: 2), 'thin');
      expect(a.value!.cases, 5);
      expect([for (final p in a.value!.pairs) p.dayIndex], [2]);
      final z = sriAggregator(4, minPairCases: 0).run(_epochs(sw, valid));
      expect([for (final p in z.value!.pairs) p.dayIndex], [1, 2]);
    });
    test('default floor is half the day (integer division)', () {
      // epd 5 -> floor 2; a pair with 2 cases is kept, with 1 is not.
      final sw = List.filled(15, true);
      final valid = [
        true, true, true, true, true,
        true, true, false, false, false, // 3 cases
        true, false, false, false, false, // 0 cases with prev day mask... prev has 3
      ];
      final want = _referenceSri(sw, 5, valid: valid);
      _same(sriAggregator(5).run(_epochs(sw, valid)), want, 'floor 2');
    });
  });

  group('random parity (seeded)', () {
    test('small epochsPerDay 4..12, lengths 0..7 days, masks, floors', () {
      final r = Rng(0x5121);
      for (var t = 0; t < 120; t++) {
        final epd = r.intIn(4, 12);
        final n = switch (r.intIn(0, 5)) {
          0 => r.intIn(0, 2 * epd + 1), // around the 2-day threshold
          1 => 2 * epd + r.intIn(0, epd - 1), // 2 days + partial
          2 => r.intIn(1, 7) * epd, // whole days
          _ => r.intIn(0, 7 * epd + epd - 1), // anything, partial trailing day
        };
        final rec = _record(r, n, epd,
            masked: r.nextBool(.5), flipP: r.nextBool() ? .05 : .45);
        final floor = switch (r.intIn(0, 3)) {
          0 => null,
          1 => 0,
          2 => r.intIn(1, epd),
          _ => r.intIn(1, epd + 2),
        };
        _checkRecord(r, rec, epd, floor, 't$t epd=$epd floor=$floor $rec');
      }
    });

    test('one 1440-epoch record of 3 days plus a partial fourth', () {
      final r = Rng(0x1440);
      for (final (n, masked) in [(3 * 1440, true), (3 * 1440 + 700, false)]) {
        final rec = _record(r, n, 1440, masked: masked, flipP: .08);
        _checkRecord(r, rec, 1440, null, 'n=$n', slicings: 2);
        _checkRecord(r, rec, 1440, 100, 'n=$n floor 100', slicings: 1);
      }
    });

    test('singleton chunks (state per epoch)', () {
      final r = Rng(0x5106);
      final rec = _record(r, 3 * 5 + 2, 5, masked: true);
      final want = _referenceSri(rec.sw, 5, valid: rec.valid);
      final a = sriAggregator(5);
      _allPaths(a, rec.epochs, singletonBounds(rec.n), want, 'singletons');
    });
  });

  group('lawful (exact equality)', () {
    final r = Rng(0x1A25);
    List<Epochs> cases(int epd, {int count = 14}) => [
          _epochs([]),
          _epochs([true]),
          _epochs([true, false]),
          for (var i = 0; i < count; i++)
            _record(r, r.intIn(0, 4 * epd + epd ~/ 2), epd,
                    masked: r.nextBool(), flipP: .3)
                .epochs,
        ];
    for (final floor in <int?>[null, 0, 2]) {
      test('epochsPerDay 4, floor $floor',
          () => expectLawful(sriAggregator(4, minPairCases: floor), cases(4),
              equals: _eq));
    }
    test('epochsPerDay 7',
        () => expectLawful(sriAggregator(7), cases(7, count: 10), equals: _eq));
    test('epochsPerDay 1', () {
      // Degenerate day length: every epoch is its own day.
      expectLawful(sriAggregator(1), cases(1, count: 10), equals: _eq);
    });
  });
}
