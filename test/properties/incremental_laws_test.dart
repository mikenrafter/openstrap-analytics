// LAWS of the incremental calculations (design 05, pilot cluster C2A, analytics
// side): the state objects behind `lib/src/onehz/incremental*.dart` --
// `IncrementalHrvTime`, `IncrementalEnmoSeries`, `IncrementalLombScargle`,
// `IncrementalMinuteMetrics` (all four are fed the WHOLE series so far on every
// `sync` and keep sums for the prefix they have already seen), and the two
// mergeable summaries under them, `RunningMoments` and `IntHistogram`, plus the
// `CalculationCache` that guards the results.
//
//   L1   chunk invariance, stated for a sync: syncing growing prefixes of a
//        series in ANY chunking (empty prefixes and a save/restore through real
//        JSON text between syncs included) gives the checkpoint of one sync of
//        the whole series -- and, because a state that cannot continue starts
//        over, the same holds after any DETOUR (an edited series, a dropped
//        prefix, a forced rebuild, another artifact fraction / reference) as
//        long as the last sync is of the same series. The checkpoint is
//        compared as text without the work counters (`processedPoints`,
//        `processedMinutes`: performance contracts, kept as examples). The
//        checkpoint of the minute metrics lists its bills in the order the keys
//        were first seen, so after a detour that REORDERS keys it is compared
//        by key; chunking alone gives the same text.
//   L1b  streamed vs batch: after every checked sync the output is what the
//        independent batch function gives for the same series (`hrvTime`,
//        `enmoSeries`, `lombScargle`, `banisterTrimp` / `strainScoreMetric` /
//        `Calories`), counts and abstentions exact, numbers within
//        max(1e-9, 1e-8 relative) (running sums against a two-pass batch).
//   L2   checkpoint round trip: `toJson` -> real JSON text -> `fromJson` ->
//        `toJson` is the same text, and the restored state goes on exactly as
//        the live one does (same outputs, same text).
//   L3   a checkpoint of another type or version, a missing or mistyped part,
//        parts that disagree (counts against the data they count), hostile
//        sizes: refused whole with a FormatException, never another error type.
//        A change the reader cannot tell from a legal checkpoint (one sum
//        altered) may be accepted, but then the state holds exactly what was
//        written; an unknown key is ignored, nothing else moves.
//   L4   identity: syncing the series it already holds changes nothing (outputs
//        and checkpoint), an empty first sync leaves a state that takes the
//        series as a fresh one would, and the other way round the parameters
//        belong to the CALL: handing other parameters rebuilds the state as a
//        fresh sync of them would (there is nothing to refuse), a refused call
//        (misaligned arguments, duplicate keys) leaves the state unchanged.
//   L5   conservation: every beat / sample / minute is counted exactly once in
//        the sums a state keeps (pairs, bins, trigonometric sums, bills),
//        checked against counts made here from the INPUT, never from the code.
//   M    merge (`RunningMoments`, `IntHistogram`): merging the summaries of two
//        parts is the summary of the concatenation (exact for the histogram,
//        within float tolerance for the moments), associative, commutative,
//        with the empty summary as identity -- the nearest thing to a monoid
//        law the analytics side has.
//
// The laws describe the code at analytics 0fc57682. A failing law is first
// checked against the module's contract; only a violation of the intended
// contract is a bug, and a wrong oracle is fixed here, never in lib/.
//
// Replay a failure with the command in its report, e.g.
//   PROPERTY_SEED=<s> PROPERTY_CASE=<n> TZ=UTC dart test \
//     test/properties/incremental_laws_test.dart --plain-name '<name>'

import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../onehz/support/energy_day.dart';
import '../onehz/support/incremental_compare.dart';
import '../support/fold_law_support.dart';
import '../support/law_registry.dart';
import '../support/property.dart';

final _laws = LawSet();

typedef Json = Map<String, dynamic>;

// ── the shape every sync module shares ──────────────────────────────────────

/// One module under the sync laws. [In] is a whole series PLUS the parameters
/// of the call; everything else is how to drive it and how to look at it.
abstract class Ops<In> {
  String get name;

  /// The series of a recipe (a handful of ints; cached by the caller).
  In expand(List<int> recipe);
  int length(In input);

  /// The first [k] items with the same parameters.
  In prefix(In input, int k);

  /// A different series with the same parameters (a replaced item, a dropped
  /// prefix, a shrunk tail, ...), chosen by [kind].
  In edit(In input, int kind, int salt);

  /// The same series under other parameters ([alt] picks), or null when the
  /// module has none (the Lomb grid belongs to the constructor).
  In? reconfigure(In input, int alt);

  /// A new state for (the parameters of) [input].
  dynamic fresh(In input);
  dynamic fromJson(Json j);
  Json toJson(dynamic state);
  Object? sync(dynamic state, In input, {bool force = false});

  /// The output as exact text.
  String show(Object? out);

  /// Fails unless [out] is what the batch gives for [input].
  void close(Object? out, In input);

  /// Fails unless two outputs of the same series are the same. Exact by
  /// default; a module that rebuilds a running sum on restore (the HRV bins)
  /// says "within the batch tolerance" instead.
  void sameOutput(Object? a, Object? b, String why) =>
      expect(show(a), show(b), reason: why);

  /// Keys of the checkpoint that count work, not state.
  List<String> get counters;

  /// The checkpoint as text, without the counters.
  String norm(Json j) {
    final c = Map<String, dynamic>.of(j);
    for (final k in counters) {
      c.remove(k);
    }
    return jsonEncode(c);
  }

  /// Whether the checkpoint text after a detour equals a fresh one's.
  bool get detourExact => true;

  /// Hand-written invariants of a reachable state that, broken, must be
  /// refused.
  List<void Function(Json)> get refuseMutations;

  /// Changes the reader cannot tell from a legal checkpoint.
  List<void Function(Json)> get faithfulMutations;

  /// Calls that must be refused (ArgumentError) and leave the state unchanged;
  /// `applies` says whether the input has something to get wrong.
  List<({String name, bool Function(In) applies, void Function(dynamic, In) call})>
      get refusals => const [];

  /// Counts made from the INPUT that the checkpoint must agree with.
  void conserved(Json checkpoint, In input, String why);

  /// Positions where the series changes character (window and bin edges).
  List<int> get special;

  Gen<List<int>> recipeGen(int maxN);
  List<List<int>> get forced;
  void observe(List<int> recipe, void Function(String) bump);
  Map<String, double> get shares;
}

String _text(Json j) => jsonEncode(j);

dynamic _restore<In>(Ops<In> ops, dynamic st) =>
    ops.fromJson((jsonDecode(jsonEncode(ops.toJson(st))) as Map).cast<String, dynamic>());

/// (splits, cut seed, restart mask, detour).
typedef Plan = (int, int, int, int);

final Gen<Plan> _planGen = G.quad(G.intIn(0, 6), G.intIn(0, 1 << 20),
    G.intIn(0, 127), G.elements(const [0, 0, 1, 2, 3, 4, 5]));

typedef Case = (List<int>, Plan);

Gen<Case> _caseGen(Ops ops, int maxN) => G.pair(ops.recipeGen(maxN), _planGen);

String _tagOf(Ops ops, Case c) => '${ops.name} ${c.$1} plan=${c.$2}';

final Map<String, Object?> _expandCache = {};

In _expand<In>(Ops<In> ops, List<int> recipe) {
  final key = '${ops.name}|$recipe';
  if (_expandCache.length > 500) _expandCache.clear();
  return _expandCache.putIfAbsent(key, () => ops.expand(recipe)) as In;
}

void _observeCase(Ops ops, Case c, void Function(String) bump) {
  ops.observe(c.$1, bump);
  final n = ops.length(_expand(ops, c.$1));
  final (splits, cutSeed, restart, detour) = c.$2;
  final b = foldBounds(n, splits, cutSeed, special: ops.special);
  if (b.length >= 4) bump('chunks: three or more');
  if (hasEmptyChunk(b)) bump('an empty prefix');
  if (restart != 0 && b.length > 2) bump('a restore between syncs');
  if (detour != 0) bump('detour: $detour');
}

Map<String, double> _lawShares(Ops ops, {Set<String> drop = const {}}) => {
      ...ops.shares,
      'chunks: three or more': .4,
      'an empty prefix': .04,
      'a restore between syncs': .3,
      for (var k = 1; k <= 5; k++) 'detour: $k': .02,
    }..removeWhere((k, _) => drop.contains(k));

// ── the laws, written once for every module ─────────────────────────────────

void _l1<In>(Ops<In> ops, Case c) {
  final x = _expand(ops, c.$1);
  final n = ops.length(x);
  final (splits, cutSeed, restart, detour) = c.$2;
  final tag = _tagOf(ops, c);
  final single = ops.fresh(x);
  final out1 = ops.sync(single, x);
  final want = ops.norm(ops.toJson(single));
  // Growing prefixes (the last one is the whole series), a save/restore after
  // some of them, and a detour before the whole series.
  var st = ops.fresh(x);
  final bounds = foldBounds(n, splits, cutSeed, special: ops.special);
  for (var k = 1; k + 1 < bounds.length; k++) {
    ops.sync(st, ops.prefix(x, bounds[k]));
    if ((restart >> (k % 7)) & 1 == 1) st = _restore(ops, st);
  }
  if (detour != 0 && ops.detourExact) {
    switch (detour) {
      case 1:
        ops.sync(st, ops.edit(x, 0, cutSeed)); // one item replaced
      case 2:
        ops.sync(st, ops.edit(x, 1, cutSeed)); // the first items dropped
      case 3:
        ops.sync(st, x, force: true); // a forced rebuild
      case 4:
        final other = ops.reconfigure(x, cutSeed);
        if (other != null) ops.sync(st, other); // other parameters
      default:
        ops.sync(st, ops.edit(x, 2, cutSeed)); // the tail dropped
    }
    st = _restore(ops, st);
  }
  final out2 = ops.sync(st, x);
  expect(ops.norm(ops.toJson(st)), want,
      reason: '$tag bounds=$bounds: the checkpoint text is the same');
  ops.sameOutput(out2, out1, '$tag: the output is the same');
}

void _l1b<In>(Ops<In> ops, Case c) {
  final x = _expand(ops, c.$1);
  final n = ops.length(x);
  final (splits, cutSeed, restart, detour) = c.$2;
  var st = ops.fresh(x);
  final bounds = foldBounds(n, splits, cutSeed, special: ops.special);
  final picks = pickSeams(bounds.length - 1);
  for (var k = 1; k < bounds.length; k++) {
    final part = ops.prefix(x, bounds[k]);
    final out = ops.sync(st, part);
    if (picks.contains(k - 1) || k == bounds.length - 1) {
      ops.close(out, part);
    }
    if ((restart >> (k % 7)) & 1 == 1) st = _restore(ops, st);
    if (k == bounds.length - 2 && detour != 0) {
      // Whatever the history, the output is the batch's for the series now.
      final other = detour == 4
          ? ops.reconfigure(x, cutSeed) ?? ops.edit(x, 0, cutSeed)
          : ops.edit(x, detour % 3, cutSeed);
      ops.close(ops.sync(st, other), other);
    }
  }
}

void _l2<In>(Ops<In> ops, Case c) {
  final x = _expand(ops, c.$1);
  final n = ops.length(x);
  final (splits, cutSeed, _, _) = c.$2;
  final tag = _tagOf(ops, c);
  final bounds = foldBounds(n, splits, cutSeed, special: ops.special);
  final at = bounds.length > 2 ? bounds[1] : n ~/ 2;
  final live = ops.fresh(x);
  ops.sync(live, ops.prefix(x, at));
  final text = _text(ops.toJson(live));
  final map = (jsonDecode(text) as Map).cast<String, dynamic>();
  final back = ops.fromJson(map);
  expect(_text(ops.toJson(back)), text, reason: '$tag: write(read(b)) == b');
  // Not aliased to the map it came from.
  for (final k in map.keys.toList()) {
    final v = map[k];
    if (v is List) v.clear();
  }
  expect(_text(ops.toJson(back)), text, reason: '$tag: not aliased to the map');
  final restored = ops.fromJson((jsonDecode(text) as Map).cast<String, dynamic>());
  // And it goes on identically: the rest of the series, then a re-sync.
  final a = ops.sync(live, x), b = ops.sync(restored, x);
  ops.sameOutput(b, a, '$tag: same output after the rest');
  expect(_text(ops.toJson(restored)), _text(ops.toJson(live)),
      reason: '$tag: same checkpoint after the rest (counters included)');
  ops.sameOutput(ops.sync(restored, x), a, '$tag: twice');
}

/// The mutated checkpoint, what it may do, and (when that is not simply "the
/// text of the mutated map") the texts a faithful reading may give.
(Json, Must, List<String>?) _mutate<In>(Ops<In> ops, Json src, Mut m) {
  final j = (deepCopy(src) as Map).cast<String, dynamic>();
  final (kind, a, b) = m;
  final keys = j.keys.toList();
  Must refuseUnlessNoop(Json bad) =>
      jsonEncode(bad) == jsonEncode(src) ? Must.faithful : Must.refuse;
  switch (kind % 7) {
    case 0:
      const versions = <Object?>[0, 2, 3, -1, 99, '1', null, true, 1 << 40];
      j['version'] = versions[a % versions.length];
      return (j, Must.refuse, null);
    case 1:
      const types = <Object?>['RunningMoments', 'Other', null, '', 1, 'incrementalhrvtime'];
      j['type'] = types[a % types.length];
      return (j, Must.refuse, null);
    case 2:
      // A key gone: refused, or (the readers take an absent key for null where
      // a part is nullable, and rebuild a total that older checkpoints did not
      // carry) read back as null, or as it was.
      final k = keys[a % keys.length];
      j.remove(k);
      final asNull = (deepCopy(src) as Map).cast<String, dynamic>()..[k] = null;
      return (
        j,
        k == 'version' || k == 'type' ? Must.refuse : Must.faithful,
        [_text(asNull), _text(src)]
      );
    case 3:
      final k = keys[a % keys.length];
      const junk = <Object?>['x', <String, Object?>{}, <Object?>[<Object?>[]]];
      j[k] = junk[b % junk.length];
      return (j, Must.refuse, null);
    case 4:
      if (ops.refuseMutations.isEmpty) return (j, Must.faithful, null);
      ops.refuseMutations[a % ops.refuseMutations.length](j);
      return (j, refuseUnlessNoop(j), null);
    case 5:
      if (ops.faithfulMutations.isEmpty) return (j, Must.faithful, null);
      ops.faithfulMutations[a % ops.faithfulMutations.length](j);
      return (j, Must.faithful, null);
    default:
      j['futureField${a % 3}'] = const [1, 'x', <Object?>[1]][b % 3];
      return (j, Must.ignored, null);
  }
}

String _outcome<In>(Ops<In> ops, Json j) {
  try {
    final s = ops.fromJson((deepCopy(j) as Map).cast<String, dynamic>());
    return 'accepted:${_text(ops.toJson(s))}';
  } on FormatException {
    return 'refused';
  } catch (e) {
    return 'WRONG ERROR TYPE: ${e.runtimeType}: $e';
  }
}

void _l3<In>(Ops<In> ops, (Case, Mut) arg) {
  final (c, m) = arg;
  final tag = '${_tagOf(ops, c)} mutation=${m.$1 % 7}(${m.$2},${m.$3})';
  final x = _expand(ops, c.$1);
  final st = ops.fresh(x);
  ops.sync(st, x);
  final src = (jsonDecode(_text(ops.toJson(st))) as Map).cast<String, dynamic>();
  final (bad, must, expected) = _mutate(ops, src, m);
  final outcome = _outcome(ops, bad);
  if (expected == null) {
    expectMutationOutcome(outcome, must, _text(bad), _text(src), tag);
  } else {
    expect(outcome, isNot(startsWith('WRONG')), reason: '$tag: only FormatException');
    if (must == Must.refuse) {
      expect(outcome, 'refused', reason: '$tag: refused whole');
    } else if (outcome != 'refused') {
      expect(expected.map((t) => 'accepted:$t'), contains(outcome),
          reason: '$tag: accepted means a faithful reading of what was written');
    }
  }
}

void _l4<In>(Ops<In> ops, Case c) {
  final x = _expand(ops, c.$1);
  final tag = _tagOf(ops, c);
  final fresh = ops.fresh(x);
  final out = ops.sync(fresh, x);
  final text = ops.norm(ops.toJson(fresh));
  // Syncing what it already holds: nothing moves.
  expect(ops.show(ops.sync(fresh, x)), ops.show(out), reason: '$tag: same output');
  expect(ops.norm(ops.toJson(fresh)), text, reason: '$tag: sync of the same is the identity');
  // An empty first sync, then the series: as if it were a fresh state.
  final late = ops.fresh(x);
  ops.sync(late, ops.prefix(x, 0));
  ops.sync(late, x);
  expect(ops.norm(ops.toJson(late)), text,
      reason: '$tag: an empty first sync leaves a state that takes the series afresh');
  // The converse: the parameters belong to the call. Other parameters rebuild
  // the state as a fresh sync of them would (nothing is refused, even for a
  // state restored from a checkpoint written under the first), and handing the
  // first ones back rebuilds the first.
  final other = ops.reconfigure(x, c.$2.$2);
  if (other != null) {
    var s = ops.fresh(x);
    ops.sync(s, x);
    s = _restore(ops, s);
    ops.sync(s, other);
    final f = ops.fresh(other);
    ops.sync(f, other);
    expect(ops.norm(ops.toJson(s)), ops.norm(ops.toJson(f)),
        reason: '$tag: other parameters rebuild, as a fresh sync of them');
    ops.sync(s, x);
    expect(ops.norm(ops.toJson(s)), text, reason: '$tag: and back');
  }
  // A refused call leaves the checkpoint as it was.
  final before = _text(ops.toJson(fresh));
  for (final r in ops.refusals) {
    if (!r.applies(x)) continue;
    expect(() => r.call(fresh, x), throwsArgumentError, reason: '$tag: ${r.name}');
    expect(_text(ops.toJson(fresh)), before,
        reason: '$tag: ${r.name} leaves the state unchanged');
  }
}

void _l5<In>(Ops<In> ops, Case c) {
  final x = _expand(ops, c.$1);
  final n = ops.length(x);
  final (splits, cutSeed, restart, _) = c.$2;
  final tag = _tagOf(ops, c);
  var st = ops.fresh(x);
  final bounds = foldBounds(n, splits, cutSeed, special: ops.special);
  for (var k = 1; k < bounds.length; k++) {
    final part = ops.prefix(x, bounds[k]);
    ops.sync(st, part);
    final json = (jsonDecode(_text(ops.toJson(st))) as Map).cast<String, dynamic>();
    ops.conserved(json, part, '$tag at ${bounds[k]}');
    // The reader takes back what the writer wrote.
    st = (restart >> (k % 7)) & 1 == 1 ? _restore(ops, st) : st;
  }
}

/// Registers the five laws of [ops].
void _registerSyncLaws<In>(Ops<In> ops,
    {int maxN = 400,
    int casesL1 = 120,
    int casesL1b = 60,
    Set<String> dropL1b = const {}}) {
  group(ops.name, () {
    final reachFor = (Set<String> drop) => Reach<Case>(
        _lawShares(ops, drop: drop), (c, bump) => _observeCase(ops, c, bump));
    _laws.law<Case>(
      'L1 ${ops.name}: any chunking of the syncs, empty prefixes, restores and '
      'detours included, gives the checkpoint text and output of one sync',
      _caseGen(ops, maxN),
      (c) => _l1(ops, c),
      examples: [for (final r in ops.forced) (r, (3, 5 + r.length, 85, r.length % 6))],
      cases: casesL1,
      reach: reachFor(const {}),
    );
    _laws.law<Case>(
      'L1b ${ops.name}: after every checked sync the output is the batch '
      "function's, history notwithstanding",
      _caseGen(ops, maxN),
      (c) => _l1b(ops, c),
      examples: [for (final r in ops.forced) (r, (4, 9 + r.length, 127, (r.length + 1) % 6))],
      cases: casesL1b,
      reach: reachFor(dropL1b),
    );
    _laws.law<Case>(
      'L2 ${ops.name}: write(read(b)) == b through JSON text, and the restored '
      'state goes on identically',
      _caseGen(ops, maxN),
      (c) => _l2(ops, c),
      examples: [for (final r in ops.forced) (r, (2, 3 + r.length, 0, 0))],
      cases: 100,
      reach: reachFor(const {'detour: 1', 'detour: 2', 'detour: 3', 'detour: 4', 'detour: 5'}),
    );
    _laws.law<(Case, Mut)>(
      'L3 ${ops.name}: a mutated checkpoint is refused whole or holds exactly '
      'what was written',
      G.pair(_caseGen(ops, 200), mutGen(7)),
      (arg) => _l3(ops, arg),
      examples: [
        for (var i = 0; i < ops.forced.length; i++)
          for (var k = 0; k < 7; k++)
            ((ops.forced[i], (3, 5, 0, 0)), (k, 3 * i + k, 5 * i + 2 * k)),
        for (var a = 0; a < ops.refuseMutations.length; a++)
          for (var i = 0; i < ops.forced.length; i++)
            ((ops.forced[i], (3, 5, 0, 0)), (4, a, i)),
        for (var a = 0; a < ops.faithfulMutations.length; a++)
          for (var i = 0; i < ops.forced.length; i++)
            ((ops.forced[i], (3, 5, 0, 0)), (5, a, i)),
        for (var a = 0; a < 9; a++) ((ops.forced.first, (3, 5, 0, 0)), (0, a, 0)),
      ],
      cases: 200,
      reach: Reach<(Case, Mut)>({
        for (var k = 0; k < 7; k++) 'kind: $k': .03,
      }, (arg, bump) => bump('kind: ${arg.$2.$1 % 7}')),
    );
    _laws.law<Case>(
      'L4 ${ops.name}: syncing what it holds is the identity, an empty first '
      'sync records nothing that matters, the parameters belong to the call, a '
      'refused call changes nothing',
      _caseGen(ops, maxN),
      (c) => _l4(ops, c),
      examples: [for (final r in ops.forced) (r, (3, 7 + r.length, 0, 0))],
      cases: 100,
      reach: reachFor(const {'detour: 1', 'detour: 2', 'detour: 3', 'detour: 4', 'detour: 5'}),
    );
    _laws.law<Case>(
      'L5 ${ops.name}: every item is counted exactly once in the sums the state '
      'keeps (counts made from the input)',
      _caseGen(ops, maxN),
      (c) => _l5(ops, c),
      examples: [for (final r in ops.forced) (r, (4, 11 + r.length, 127, 0))],
      cases: 100,
      reach: reachFor(const {'detour: 1', 'detour: 2', 'detour: 3', 'detour: 4', 'detour: 5'}),
    );
  });
}

// ═════════════════════════════════════════════════════════════════════════════
// HRV
// ═════════════════════════════════════════════════════════════════════════════

const _hrvFlavours = [
  'smooth', // two slow sines: a high lag-1 ACF of the differences is not expected
  'white jitter', // differenced white noise: the jitter gate refuses RMSSD / pNN50
  'af', // irregularly irregular
  'constant', // every difference zero: variance zero
  'gaps', // a 21 s dropout every 113 beats
  'big steps', // every 7th beat 90 ms off: pNN50 moves
  'two valued', // alternating 800 / 1000: ACF of the differences is -1
  'seconds grid', // 1 s beats on a whole-second grid: the 5-minute bin edges are hit exactly
];
const _hrvOrigins = [0.0, 299999.5, 1700000010123.125, 1700000000000.0];
const _hrvAf = [0.0, .17, .8, 1.0];

class HrvIn {
  HrvIn(this.nn, this.t, this.af);
  final List<double> nn;
  final List<double>? t;
  final double af;
}

class HrvOps extends Ops<HrvIn> {
  @override
  String get name => 'IncrementalHrvTime';

  @override
  HrvIn expand(List<int> r) {
    final (flavour, n, seed, timed, originIdx, afIdx) = (r[0], r[1], r[2], r[3], r[4], r[5]);
    final g = Rng(seed * 7919 + flavour + 5);
    final nn = <double>[], t = <double>[];
    var clock = _hrvOrigins[originIdx];
    for (var i = 0; i < n; i++) {
      final v = switch (flavour) {
        1 => 800 + 160 * (g.nextDouble() - .5),
        2 => 420 + g.nextInt(700).toDouble(),
        3 => 800.0,
        6 => i.isEven ? 800.0 : 1000.0,
        7 => 900.0 + (i % 11) * 7,
        5 => 800 + 40 * math.sin(i * .13) + (i % 7 == 6 ? 90 : 0),
        _ => 800 + 75 * math.sin(i * .13 + seed * .003) + 21 * math.sin(i * .031 + seed * .007),
      };
      if (flavour == 4 && i % 113 == 112) clock += 21000;
      clock += flavour == 7 ? 1000 : v;
      nn.add(v);
      t.add(clock);
    }
    return HrvIn(nn, timed == 0 ? t : null, _hrvAf[afIdx]);
  }

  @override
  int length(HrvIn i) => i.nn.length;
  @override
  HrvIn prefix(HrvIn i, int k) =>
      HrvIn(i.nn.sublist(0, k), i.t?.sublist(0, k), i.af);
  @override
  HrvIn edit(HrvIn i, int kind, int salt) {
    final n = i.nn.length;
    if (n < 2) return i;
    switch (kind % 3) {
      case 0:
        final nn = [...i.nn];
        nn[salt % n] += 60;
        return HrvIn(nn, i.t, i.af);
      case 1:
        final d = 1 + salt % (n - 1);
        return HrvIn(i.nn.sublist(d), i.t?.sublist(d), i.af);
      default:
        final d = 1 + salt % (n - 1);
        return HrvIn(i.nn.sublist(0, n - d), i.t?.sublist(0, n - d), i.af);
    }
  }

  @override
  HrvIn? reconfigure(HrvIn i, int alt) => HrvIn(i.nn, i.t, _hrvAf[(alt + 1) % 4] == i.af ? .5 : _hrvAf[(alt + 1) % 4]);

  @override
  dynamic fresh(HrvIn input) => IncrementalHrvTime();
  @override
  dynamic fromJson(Json j) => IncrementalHrvTime.fromJson(j);
  @override
  Json toJson(dynamic s) => (s as IncrementalHrvTime).toJson();
  @override
  Object? sync(dynamic s, HrvIn i, {bool force = false}) => (s as IncrementalHrvTime)
      .sync(i.nn, nnTimesMs: i.t, artifactFraction: i.af, force: force);

  @override
  String show(Object? out) {
    final m = out as Metric<HrvTime>;
    final v = m.value;
    return [
      m.present,
      m.confidence,
      m.tier,
      m.note,
      m.inputs_used,
      if (v != null) [v.nBeats, v.rmssd, v.sdnn, v.sdann, v.sdnnIndex, v.pnn50, v.diffAcf1],
    ].join('|');
  }

  @override
  void sameOutput(Object? a, Object? b, String why) {
    // Restoring rebuilds the running sums of the bin means and SDs from the
    // stored bins (they are not in the checkpoint), so a restored state's
    // SDANN / SDNN index agree with one that never stopped to ~1e-14 relative,
    // not bit for bit.
    final x = a as Metric<HrvTime>, y = b as Metric<HrvTime>;
    try {
      hrvClose(x, y);
    } on TestFailure catch (e) {
      fail('$why: ${e.message}');
    }
  }

  @override
  void close(Object? out, HrvIn i) =>
      hrvClose(out as Metric<HrvTime>, hrvTime(i.nn, nnTimesMs: i.t, artifactFraction: i.af));

  @override
  List<String> get counters => const ['processedPoints'];

  @override
  List<int> get special => const [0, 1, 2, 29, 30, 31, 299, 300, 301, 302, 599, 600, 601];

  @override
  List<void Function(Json)> get refuseMutations => [
        (j) {
          final n = (j['nn'] as List).length;
          if (n > 0) j['processedPoints'] = n - 1;
        },
        (j) => j['over50'] = (j['pairs'] as int) + 1,
        (j) => j['lagPairs'] = (j['pairs'] as int) + 1,
        (j) => j['pairs'] = math.max(0, (j['nn'] as List).length - 1) + 1,
        (j) => (j['levels'] as Map)['count'] = ((j['levels'] as Map)['count'] as int) + 1,
        (j) {
          final bins = j['bins'] as List;
          if (bins.isNotEmpty) (bins.first as Map)['count'] = ((bins.first as Map)['count'] as int) + 1;
        },
        (j) => (j['nn'] as List).add(800.0),
        (j) {
          final t = j['times'] as List?;
          if (t != null && t.isNotEmpty) t.removeLast();
        },
        (j) {
          if (((j['levels'] as Map)['count'] as int) > 0) j['finite'] = false;
        },
        (j) {
          final nn = j['nn'] as List;
          if (nn.isNotEmpty && j['finite'] == true) nn[0] = 'NaN';
        },
        (j) => (j['bins'] as List).add({
              'version': 1,
              'type': 'RunningMoments',
              'count': 0,
              'origin': 0.0,
              'meanOffset': 0.0,
              'm2': 0.0
            }),
        (j) => j['diffSquares'] = -1.0,
      ];

  @override
  List<void Function(Json)> get faithfulMutations => [
        (j) {
          final nn = j['nn'] as List;
          if (nn.isNotEmpty) nn[0] = (nn[0] as num) + 1.0;
        },
        (j) => j['diffSum'] = (j['diffSum'] as num) + 1.0,
        (j) => j['products'] = (j['products'] as num) + 1.0,
        (j) => j['endpoints'] = (j['endpoints'] as num) + 1.0,
        (j) => j['lastDiff'] = ((j['lastDiff'] as num?) ?? 0) + 1.0,
        (j) => j['binIdx'] = (j['binIdx'] as int) + 1,
        (j) => j['processedPoints'] = (j['processedPoints'] as int) + 5,
        (j) {
          final t = j['times'] as List?;
          if (t != null && t.isNotEmpty) t[0] = (t[0] as num) + 1.0;
        },
      ];

  @override
  void conserved(Json cp, HrvIn i, String why) {
    final n = i.nn.length;
    expect((cp['nn'] as List).length, n, reason: 'the series is kept $why');
    expect((cp['levels'] as Map)['count'], n, reason: 'every beat is a level, once $why');
    final timed = i.t != null;
    // Pairs made here: neighbours, except across a dropout (a time step longer
    // than the beat itself, plus half a millisecond).
    var pairs = 0, over = 0, lag = 0;
    double? last;
    for (var k = 1; k < n; k++) {
      if (timed && i.t![k] - i.t![k - 1] > i.nn[k] + .5) {
        last = null;
        continue;
      }
      final d = i.nn[k] - i.nn[k - 1];
      pairs++;
      if (d.abs() > 50) over++;
      if (last != null) lag++;
      last = d;
    }
    expect(cp['pairs'], pairs, reason: 'successive differences $why');
    expect(cp['over50'], over, reason: 'differences over 50 ms $why');
    expect(cp['lagPairs'], lag, reason: 'lag-1 pairs $why');
    final bins = cp['bins'] as List;
    if (!timed) {
      expect(bins, isEmpty, reason: 'no times, no bins $why');
    } else {
      // Every beat is in exactly one five-minute bin; bins are runs of beats
      // with the same index since the first beat.
      var total = 0;
      for (final b in bins) {
        total += (b as Map)['count'] as int;
      }
      expect(total, n, reason: 'every beat is in one bin $why');
      var runs = 0;
      int? prev;
      for (var k = 0; k < n; k++) {
        final idx = ((i.t![k] - i.t!.first) / 300000).floor();
        if (prev == null || idx != prev) runs++;
        prev = idx;
      }
      expect(bins.length, runs, reason: 'bins are runs of the same five minutes $why');
    }
  }

  @override
  Gen<List<int>> recipeGen(int maxN) => IntsGen([
        G.intIn(0, _hrvFlavours.length - 1),
        SizeGen(maxN, pool: const [0, 1, 2, 3, 29, 30, 31, 32, 299, 300, 301, 302, 599, 600, 601, 610]),
        G.intIn(0, 1 << 12),
        G.elements(const [0, 0, 0, 1]),
        G.intIn(0, _hrvOrigins.length - 1),
        G.intIn(0, _hrvAf.length - 1),
      ]);

  @override
  List<List<int>> get forced => [
        [0, 0, 1, 0, 0, 0], // empty
        [0, 1, 1, 0, 0, 0], // one beat
        [0, 2, 1, 0, 0, 0], // two
        [3, 31, 1, 0, 0, 0], // constant, 30 pairs
        [3, 29, 1, 1, 0, 0], // constant, no times
        [1, 300, 2, 0, 0, 1], // jitter: RMSSD refused
        [6, 120, 1, 0, 0, 0], // ACF of the differences exactly -1
        [7, 610, 1, 0, 0, 0], // whole-second grid across 5-minute edges
        [7, 610, 1, 0, 1, 2], // shifted origin
        [7, 610, 1, 0, 2, 3],
        [4, 400, 3, 0, 0, 0], // dropouts
        [5, 200, 1, 0, 3, 0], // big steps
        [2, 250, 5, 1, 0, 1], // AF, no times
        [0, 500, 7, 0, 3, 2],
      ];

  @override
  void observe(List<int> r, void Function(String) bump) {
    bump('flavour: ${_hrvFlavours[r[0]]}');
    final n = r[1];
    if (n == 0) bump('series: empty');
    if (n >= 1 && n < 30) bump('series: under 30 pairs');
    if (n >= 300) bump('series: past one 5-minute bin');
    if (r[3] == 1) bump('no times');
    if (r[5] != 0) bump('artifact fraction set');
  }

  @override
  Map<String, double> get shares => {
        for (var f = 0; f < _hrvFlavours.length; f++) 'flavour: ${_hrvFlavours[f]}': .03,
        'series: empty': .01,
        'series: under 30 pairs': .05,
        'series: past one 5-minute bin': .15,
        'no times': .08,
        'artifact fraction set': .3,
      };
}

// ═════════════════════════════════════════════════════════════════════════════
// ENMO
// ═════════════════════════════════════════════════════════════════════════════

const _enmoFlavours = [
  'regular', // a sample every 1/hz s, a still vector with noise
  'gaps + invalid', // a hole of 69 samples, every 47th sample invalid
  'duplicate times', // two samples per timestamp
  'unsorted', // the stream arrives newest first
  'constant vector',
];
const _hz = [.5, 1.0, 2.0];
const _enmoOrigins = [0.0, 1700000010000.0, 59000.0, 1700000040000.5];

/// (gRef, gravityWindowS, minSamplesPerMinute, expectedMinutes). A null gRef is
/// the auto-calibrated path (the batch every time); a NaN gRef the fallback.
const List<(double?, double, int, int?)> _enmoCfgs = [
  (1.013456789, defaultGravityWindowS, 30, 12),
  (1.0, defaultGravityWindowS, 30, null),
  (null, defaultGravityWindowS, 30, null),
  (1.05, 31, 60, 100),
  (1.0, 0.0, 1, null),
  (1.0, 1.0, 60, null),
  (1.0, 61.5, 30, 12),
  (double.nan, defaultGravityWindowS, 30, null),
  (double.infinity, defaultGravityWindowS, 30, null),
];

class EnmoIn {
  EnmoIn(this.samples, this.cfg);
  final List<AccelSample> samples;
  final int cfg;
  (double?, double, int, int?) get c => _enmoCfgs[cfg];
}

class EnmoOps extends Ops<EnmoIn> {
  @override
  String get name => 'IncrementalEnmoSeries';

  @override
  EnmoIn expand(List<int> r) {
    final (n, hzIdx, seed, flavour, cfg, originIdx) = (r[0], r[1], r[2], r[3], r[4], r[5]);
    final g = Rng(seed * 104729 + flavour + 7);
    final hz = _hz[hzIdx];
    final out = <AccelSample>[];
    for (var i = 0; i < n; i++) {
      if (flavour == 1 && i >= 70 && i < 139) continue;
      final idx = flavour == 2 ? i ~/ 2 : i;
      final ts = _enmoOrigins[originIdx] + idx * 1000 / hz;
      if (flavour == 4) {
        out.add(AccelSample(ts, .3, -.4, 1.0));
      } else {
        out.add(AccelSample(
            ts,
            .22 * math.sin(i * .29) + g.nextDouble() * .007,
            .11 * math.cos(i * .07),
            1.02 + .065 * math.sin(i * .23),
            valid: !(flavour == 1 && i % 47 == 46)));
      }
    }
    return EnmoIn(flavour == 3 ? out.reversed.toList() : out, cfg);
  }

  @override
  int length(EnmoIn i) => i.samples.length;
  @override
  EnmoIn prefix(EnmoIn i, int k) => EnmoIn(i.samples.sublist(0, k), i.cfg);
  @override
  EnmoIn edit(EnmoIn i, int kind, int salt) {
    final n = i.samples.length;
    if (n < 2) return i;
    switch (kind % 3) {
      case 0:
        final a = [...i.samples];
        final o = a[salt % n];
        a[salt % n] = AccelSample(o.tsMs, o.x + .07, o.y, o.z, valid: o.valid);
        return EnmoIn(a, i.cfg);
      case 1:
        return EnmoIn(i.samples.sublist(1 + salt % (n - 1)), i.cfg);
      default:
        return EnmoIn(i.samples.sublist(0, n - 1 - salt % (n - 1)), i.cfg);
    }
  }

  @override
  EnmoIn? reconfigure(EnmoIn i, int alt) =>
      EnmoIn(i.samples, (i.cfg + 1 + alt % (_enmoCfgs.length - 1)) % _enmoCfgs.length);

  @override
  dynamic fresh(EnmoIn input) => IncrementalEnmoSeries();
  @override
  dynamic fromJson(Json j) => IncrementalEnmoSeries.fromJson(j);
  @override
  Json toJson(dynamic s) => (s as IncrementalEnmoSeries).toJson();
  @override
  Object? sync(dynamic s, EnmoIn i, {bool force = false}) =>
      (s as IncrementalEnmoSeries).sync(i.samples,
          gRef: i.c.$1,
          gravityWindowS: i.c.$2,
          minSamplesPerMinute: i.c.$3,
          expectedMinutes: i.c.$4,
          force: force);

  @override
  String show(Object? out) {
    final r = out as EnmoResult;
    return [
      r.gRef,
      r.coverage,
      for (final m in r.minutes)
        [m.tsMinStartMs, m.nSamples, m.enmo, m.mad, m.meanMag, m.dynAmp],
    ].join('|');
  }

  @override
  void close(Object? out, EnmoIn i) => enmoClose(
      out as EnmoResult,
      enmoSeries(i.samples,
          gRef: i.c.$1,
          gravityWindowS: i.c.$2,
          minSamplesPerMinute: i.c.$3,
          expectedMinutes: i.c.$4));

  @override
  List<String> get counters => const ['processedPoints'];

  @override
  List<int> get special => const [0, 1, 2, 29, 30, 31, 59, 60, 61, 69, 70, 120, 121];

  @override
  List<void Function(Json)> get refuseMutations => [
        (j) {
          final n = (j['valid'] as List).length;
          if (n > 0) j['processedPoints'] = n - 1;
        },
        (j) => j['lo'] = (j['valid'] as List).length + 1,
        (j) {
          final bins = j['bins'] as List;
          if (bins.isNotEmpty && ((bins.first as Map)['mags'] as List).isNotEmpty) {
            ((bins.first as Map)['mags'] as List).removeLast();
          }
        },
        (j) => (j['valid'] as List).add([1.0, 0.0, 0.0, 1.0]),
        (j) {
          if ((j['valid'] as List).isNotEmpty) j['gRef'] = null;
        },
        (j) {
          final v = j['valid'] as List;
          if (v.length >= 2) (v[0] as List)[0] = ((v[1] as List)[0] as num) + 1.0;
        },
        (j) {
          final v = j['valid'] as List;
          if (v.isNotEmpty) (v[0] as List).removeLast();
        },
        (j) => (j['bins'] as List).add({
              'key': -1,
              'mags': <double>[],
              'magSum': 0.0,
              'enmoSum': 0.0,
              'dynSum': 0.0
            }),
        (j) {
          final bins = j['bins'] as List;
          if (bins.isNotEmpty) bins.add(deepCopy(bins.first));
        },
        (j) {
          final bins = j['bins'] as List;
          if (bins.isNotEmpty) (bins.first as Map)['enmoSum'] = -1.0;
        },
        (j) => j['windowS'] = 'x',
      ];

  @override
  List<void Function(Json)> get faithfulMutations => [
        (j) => j['sx'] = (j['sx'] as num) + 1.0,
        (j) => j['sy'] = (j['sy'] as num) + 1.0,
        (j) => j['sz'] = (j['sz'] as num) + 1.0,
        (j) => j['windowS'] = (j['windowS'] as num) + 1.0,
        (j) => j['processedPoints'] = (j['processedPoints'] as int) + 5,
        (j) {
          final bins = j['bins'] as List;
          if (bins.isNotEmpty) (bins.first as Map)['magSum'] = ((bins.first as Map)['magSum'] as num) + 1.0;
        },
        (j) {
          final bins = j['bins'] as List;
          if (bins.isNotEmpty) (bins.first as Map)['dynSum'] = ((bins.first as Map)['dynSum'] as num) + 1.0;
        },
        (j) {
          final v = j['valid'] as List;
          if (v.isNotEmpty) (v[0] as List)[1] = ((v[0] as List)[1] as num) + .01;
        },
      ];

  @override
  void conserved(Json cp, EnmoIn i, String why) {
    // Every valid sample is in exactly one minute bin (the minute its time falls
    // in); a state with a non-finite reference or parameter keeps nothing.
    final c = i.c;
    final usable = c.$1 != null && c.$1!.isFinite && c.$2.isFinite;
    final valid = i.samples.where((s) => s.valid).toList();
    if (!usable) {
      expect((cp['valid'] as List), isEmpty, reason: 'nothing is kept $why');
      expect((cp['bins'] as List), isEmpty, reason: 'no bins $why');
      return;
    }
    expect((cp['valid'] as List).length, valid.length, reason: 'valid samples kept $why');
    final want = <int, int>{};
    for (final s in valid) {
      want.update((s.tsMs / 60000).floor(), (v) => v + 1, ifAbsent: () => 1);
    }
    final got = <int, int>{
      for (final b in cp['bins'] as List)
        (b as Map)['key'] as int: (b['mags'] as List).length
    };
    expect(got, want, reason: 'every valid sample is in the bin of its minute, once $why');
  }

  @override
  Gen<List<int>> recipeGen(int maxN) => IntsGen([
        SizeGen(maxN, pool: const [0, 1, 2, 3, 29, 30, 31, 59, 60, 61, 69, 70, 120, 121]),
        G.intIn(0, _hz.length - 1),
        G.intIn(0, 1 << 12),
        G.intIn(0, _enmoFlavours.length - 1),
        G.intIn(0, _enmoCfgs.length - 1),
        G.intIn(0, _enmoOrigins.length - 1),
      ]);

  @override
  List<List<int>> get forced => [
        [0, 1, 1, 0, 0, 0], // empty
        [1, 1, 1, 0, 0, 0], // one sample
        [31, 1, 1, 0, 1, 0],
        [200, 1, 1, 1, 0, 1], // gaps + invalid
        [300, 2, 1, 2, 3, 1], // duplicate timestamps
        [150, 1, 1, 3, 1, 0], // newest first
        [130, 1, 1, 4, 1, 1], // constant vector
        [200, 0, 2, 0, 2, 1], // auto-calibrated
        [200, 1, 2, 0, 7, 0], // NaN reference: the fallback
        [200, 1, 2, 0, 8, 2], // infinite reference
        [200, 1, 3, 0, 4, 2], // window of zero seconds
        [240, 2, 4, 0, 6, 3], // wide window
        [180, 1, 5, 0, 5, 2],
      ];

  @override
  void observe(List<int> r, void Function(String) bump) {
    bump('flavour: ${_enmoFlavours[r[3]]}');
    final n = r[0];
    if (n == 0) bump('series: empty');
    if (n >= 1 && n < 30) bump('series: under a minute of samples');
    if (n >= 120) bump('series: two minutes or more');
    final c = _enmoCfgs[r[4]];
    if (c.$1 == null) bump('reference: auto');
    if (c.$1 != null && !c.$1!.isFinite) bump('reference: not finite');
    if (c.$1 != null && c.$1!.isFinite) bump('reference: given');
    if (c.$2 != defaultGravityWindowS) bump('window: not the default');
  }

  @override
  Map<String, double> get shares => {
        for (final f in _enmoFlavours) 'flavour: $f': .03,
        'series: empty': .01,
        'series: under a minute of samples': .05,
        'series: two minutes or more': .2,
        'reference: auto': .05,
        'reference: not finite': .05,
        'reference: given': .4,
        'window: not the default': .2,
      };
}

// ═════════════════════════════════════════════════════════════════════════════
// Lomb-Scargle
// ═════════════════════════════════════════════════════════════════════════════

const _lombFlavours = [
  'regular', // beats at ~0.8 s with slow modulation
  'irregular', // uneven gaps, dropouts
  'constant y', // nothing to analyse: abstains
  'collapsed t', // every time the same: abstains
  'duplicate t', // pairs of equal times
  'NaN y', // a non-finite value halfway: the batch decides
  'infinite t', // a non-finite time halfway
  'length mismatch', // one value fewer than times
];
final _lombGrids = <List<double>>[
  [0.0, .0033, .01, .04, .07, .1, .15, .25, .4],
  [],
  [0.0],
  [.04, .04, .13],
  [.1, .07, .4],
  [for (var k = 0; k <= 40; k++) .0033 + k * .01],
];
const _lombOrigins = [0.0, 12345.125, 1791028730.0];

class LombIn {
  LombIn(this.t, this.y, this.grid);
  final List<double> t, y;
  final int grid;
  List<double> get freqs => _lombGrids[grid];
}

class LombOps extends Ops<LombIn> {
  @override
  String get name => 'IncrementalLombScargle';

  @override
  LombIn expand(List<int> r) {
    final (n, seed, flavour, grid, originIdx) = (r[0], r[1], r[2], r[3], r[4]);
    final g = Rng(seed * 6007 + flavour + 13);
    var clock = _lombOrigins[originIdx];
    final t = <double>[], y = <double>[];
    for (var i = 0; i < n; i++) {
      final rr = 800 + 75 * math.sin(i * .13 + seed * .003) + 21 * math.sin(i * .031) + (flavour == 1 ? g.nextDouble() * 400 : 0);
      if (flavour == 4) {
        if (i.isEven) clock += rr / 1000;
      } else if (flavour == 3) {
        // time does not move
      } else {
        clock += rr / 1000;
      }
      if (flavour == 1 && i % 61 == 60) clock += 21;
      t.add(clock);
      y.add(flavour == 2 ? 800.0 : rr);
    }
    if (flavour == 5 && n > 4) y[n ~/ 2] = double.nan;
    if (flavour == 6 && n > 4) t[n ~/ 2] = double.infinity;
    if (flavour == 7 && n > 0) y.removeLast();
    return LombIn(t, y, grid);
  }

  @override
  int length(LombIn i) => i.t.length;
  @override
  LombIn prefix(LombIn i, int k) =>
      LombIn(i.t.sublist(0, k), i.y.sublist(0, math.min(k, i.y.length)), i.grid);
  @override
  LombIn edit(LombIn i, int kind, int salt) {
    final n = i.t.length;
    if (n < 2 || i.y.length != n) return i;
    switch (kind % 3) {
      case 0:
        final y = [...i.y];
        y[salt % n] += 79;
        return LombIn(i.t, y, i.grid);
      case 1:
        final d = 1 + salt % (n - 1);
        return LombIn(i.t.sublist(d), i.y.sublist(d), i.grid);
      default:
        final d = 1 + salt % (n - 1);
        return LombIn(i.t.sublist(0, n - d), i.y.sublist(0, n - d), i.grid);
    }
  }

  // The grid belongs to the constructor (and travels in the checkpoint).
  @override
  LombIn? reconfigure(LombIn i, int alt) => null;

  @override
  dynamic fresh(LombIn input) => IncrementalLombScargle(_lombGrids[input.grid]);
  @override
  dynamic fromJson(Json j) => IncrementalLombScargle.fromJson(j);
  @override
  Json toJson(dynamic s) => (s as IncrementalLombScargle).toJson();
  @override
  Object? sync(dynamic s, LombIn i, {bool force = false}) =>
      (s as IncrementalLombScargle).sync(i.t, i.y, force: force);

  @override
  String show(Object? out) {
    final r = out as LombScargle?;
    if (r == null) return 'null';
    return [for (final p in r.spectrum) '${p.freqHz}:${p.psd}'].join('|');
  }

  /// The batch function on times shifted by the first one: the periodogram is
  /// shift-invariant, the shift is exact, and on raw epoch seconds the batch's
  /// own trigonometric arguments lose ~1e-6 relative (drift_test.dart).
  LombScargle? _oracle(LombIn i) {
    final ok = i.t.length == i.y.length &&
        i.t.isNotEmpty &&
        i.t.every((x) => x.isFinite) &&
        i.y.every((x) => x.isFinite);
    if (!ok) return lombScargle(i.t, i.y, i.freqs);
    final first = i.t.first;
    return lombScargle([for (final x in i.t) x - first], i.y, i.freqs);
  }

  @override
  void close(Object? out, LombIn i) => spectrumClose(out as LombScargle?, _oracle(i));

  @override
  void sameOutput(Object? a, Object? b, String why) {
    try {
      spectrumClose(a as LombScargle?, b as LombScargle?);
    } on TestFailure catch (e) {
      fail('$why: ${e.message}');
    }
  }

  @override
  List<String> get counters => const ['processedPoints'];

  @override
  List<int> get special => const [0, 1, 2, 3, 4, 5, 30, 31, 60, 61, 62];

  @override
  List<void Function(Json)> get refuseMutations => [
        (j) => (j['t'] as List).add(1.0),
        (j) {
          final y = j['y'] as List;
          if (y.isNotEmpty) y.removeLast();
        },
        (j) {
          final sums = j['sums'] as List;
          if (sums.isNotEmpty) (sums.first as List).removeLast();
        },
        (j) {
          final sums = j['sums'] as List;
          if (sums.isNotEmpty) sums.removeLast();
        },
        (j) => (j['moments'] as Map)['count'] = ((j['moments'] as Map)['count'] as int) + 1,
        (j) {
          // (Only an incremental state ties its work counter to its data.)
          final n = (j['t'] as List).length;
          if (n > 0 && j['incremental'] == true) j['processedPoints'] = n - 1;
        },
        (j) {
          if (j['incremental'] == true && (j['t'] as List).isNotEmpty) {
            j['origin'] = (j['origin'] as num) + 1.0;
          }
        },
        (j) {
          if (j['incremental'] == true && (j['t'] as List).isNotEmpty) {
            j['tMax'] = (j['tMax'] as num) + 1.0;
          }
        },
        (j) {
          if (j['incremental'] == true && (j['t'] as List).isNotEmpty) {
            final sums = j['sums'] as List;
            if (sums.isNotEmpty) (sums.first as List)[2] = ((sums.first as List)[2] as num) + 5.0;
          }
        },
        (j) {
          if (((j['moments'] as Map)['count'] as int) > 0) j['incremental'] = false;
        },
        (j) => (j['frequencies'] as List).add(.5),
        (j) {
          if (j['incremental'] == true && (j['y'] as List).isNotEmpty) {
            j['yOrigin'] = (j['yOrigin'] as num) + 1.0;
          }
        },
      ];

  @override
  List<void Function(Json)> get faithfulMutations => [
        (j) {
          final sums = j['sums'] as List;
          if (sums.isNotEmpty) (sums.first as List)[0] = ((sums.first as List)[0] as num) + 1.0;
        },
        (j) {
          final sums = j['sums'] as List;
          if (sums.isNotEmpty) (sums.first as List)[4] = ((sums.first as List)[4] as num) + 1.0;
        },
        (j) {
          final sums = j['sums'] as List;
          if (sums.isNotEmpty) (sums.last as List)[5] = ((sums.last as List)[5] as num) + 1.0;
        },
        (j) => j['processedPoints'] = (j['processedPoints'] as int) + 3,
        (j) {
          final m = j['moments'] as Map;
          m['m2'] = ((m['m2'] as num) + 1.0);
        },
      ];

  @override
  void conserved(Json cp, LombIn i, String why) {
    final finite = i.t.length == i.y.length &&
        i.t.every((x) => x.isFinite) &&
        i.y.every((x) => x.isFinite);
    if (!finite) {
      // The batch decides; nothing is folded into the sums.
      expect((cp['moments'] as Map)['count'], 0, reason: 'no moments $why');
      return;
    }
    final n = i.t.length;
    expect((cp['moments'] as Map)['count'], n, reason: 'every value is a moment, once $why');
    expect((cp['t'] as List).length, n, reason: why);
    // cos^2 + sin^2 = 1 at every point: the two squares sum to n per frequency.
    if (n > 0) {
      for (final row in cp['sums'] as List) {
        final r = (row as List).cast<num>();
        expect((r[2] + r[3] - n).abs() <= 1e-8 * n, isTrue,
            reason: 'sum of cos^2 and sin^2 is the count ${r[2] + r[3]} vs $n $why');
      }
    }
  }

  @override
  Gen<List<int>> recipeGen(int maxN) => IntsGen([
        SizeGen(maxN, pool: const [0, 1, 2, 3, 4, 5, 30, 31, 60, 61, 62]),
        G.intIn(0, 1 << 12),
        G.intIn(0, _lombFlavours.length - 1),
        G.intIn(0, _lombGrids.length - 1),
        G.intIn(0, _lombOrigins.length - 1),
      ]);

  @override
  List<List<int>> get forced => [
        [0, 1, 0, 0, 0],
        [3, 1, 0, 0, 0], // under 4 points: abstains
        [4, 1, 0, 0, 1], // exactly 4
        [60, 1, 0, 0, 0],
        [60, 2, 0, 0, 2], // epoch-sized times
        [100, 3, 1, 5, 0], // irregular, dense grid
        [40, 1, 2, 0, 0], // constant y
        [40, 1, 3, 0, 0], // collapsed time
        [40, 1, 4, 0, 1], // duplicate times
        [40, 1, 5, 0, 0], // NaN value
        [40, 1, 6, 0, 0], // infinite time
        [40, 1, 7, 0, 0], // lengths differ
        [50, 1, 0, 1, 0], // empty grid
        [50, 1, 0, 2, 0], // grid of zero only
        [50, 1, 0, 3, 1], // repeated frequency
        [50, 1, 0, 4, 0], // unsorted grid
      ];

  @override
  void observe(List<int> r, void Function(String) bump) {
    bump('flavour: ${_lombFlavours[r[2]]}');
    final n = r[0];
    if (n == 0) bump('series: empty');
    if (n >= 1 && n < 4) bump('series: under 4 points');
    if (n >= 60) bump('series: 60 or more');
    bump('grid: ${r[3]}');
    if (r[4] == 2) bump('epoch-sized times');
  }

  @override
  Map<String, double> get shares => {
        for (final f in _lombFlavours) 'flavour: $f': .02,
        'series: under 4 points': .03,
        'series: 60 or more': .3,
        for (var g = 0; g < _lombGrids.length; g++) 'grid: $g': .03,
        'epoch-sized times': .15,
      };
}

// ═════════════════════════════════════════════════════════════════════════════
// Minute metrics
// ═════════════════════════════════════════════════════════════════════════════

const _hrBranches = [54.0, 95.0, 106.799999, 106.8, 130.0, 190.0, 0.0, double.nan, 40.0];
const _cadBranches = <double?>[null, 99.999, 100, 110, 120, 130, 160, 0, double.nan];

/// (resting HR, max HR, sex, profile name, day minutes, quiet HRR). Anchors
/// that gate the TRIMP off (null, equal, inverted, NaN), no profile (no
/// energy), a short, a DST and a long day, and quiet-HRR gates.
final List<(double?, double?, Sex, String?, int, double?)> _minCfgs = [
  (54, 186, Sex.male, 'male', 1440, .12),
  (65, 197, Sex.female, 'female', 900, .12),
  (null, 186, Sex.male, 'male', 1440, .12),
  (54, null, Sex.male, 'nonbinary', 1440, null),
  (70, 60, Sex.male, 'male', 1440, .18),
  (double.nan, 186, Sex.male, 'male', 0, .12),
  (54, 186, Sex.female, null, 1440, .12),
  (54, 186, Sex.male, 'nonbinary', 1380, 0.0),
  (54, 186, Sex.male, 'female', 1441, -0.1),
  (54, 186, Sex.male, 'male', 1500, double.nan),
  (54, 54, Sex.male, 'male', 1440, .12),
];

class MinIn {
  MinIn(this.keys, this.hr, this.cad, this.cfg, this.series);
  final List<int> keys;
  final List<double> hr;
  final List<double?>? cad;
  final int cfg;
  final bool series;
  WorkoutUserProfile? get profile {
    final name = _minCfgs[cfg].$4;
    return name == null ? null : energyProfiles[name];
  }
}

String _metric(Metric<double> m) =>
    '${m.present}/${m.value}/${m.confidence}/${m.tier}/${m.note}/${m.inputs_used}';

class MinOps extends Ops<MinIn> {
  @override
  String get name => 'IncrementalMinuteMetrics';

  @override
  MinIn expand(List<int> r) {
    final (n, seed, cfg, cadMode, series) = (r[0], r[1], r[2], r[3], r[4]);
    return MinIn(
      List.generate(n, (i) => 28000000 + i + i ~/ 17),
      List.generate(n, (i) => _hrBranches[(i + seed) % _hrBranches.length]),
      cadMode == 0 ? null : List.generate(n, (i) => _cadBranches[(i + seed) % _cadBranches.length]),
      cfg,
      series == 1,
    );
  }

  @override
  int length(MinIn i) => i.keys.length;
  @override
  MinIn prefix(MinIn i, int k) => MinIn(i.keys.sublist(0, k), i.hr.sublist(0, k),
      i.cad?.sublist(0, k), i.cfg, i.series);
  @override
  MinIn edit(MinIn i, int kind, int salt) {
    final n = i.keys.length;
    if (n < 2) return i;
    switch (kind % 3) {
      case 0:
        final hr = [...i.hr];
        hr[salt % n] += 29;
        return MinIn(i.keys, hr, i.cad, i.cfg, i.series);
      case 1:
        final d = 1 + salt % (n - 1);
        return MinIn(i.keys.sublist(d), i.hr.sublist(d), i.cad?.sublist(d), i.cfg, i.series);
      default:
        final d = 1 + salt % (n - 1);
        return MinIn(i.keys.sublist(0, n - d), i.hr.sublist(0, n - d),
            i.cad?.sublist(0, n - d), i.cfg, i.series);
    }
  }

  @override
  MinIn? reconfigure(MinIn i, int alt) =>
      MinIn(i.keys, i.hr, i.cad, (i.cfg + 1 + alt % (_minCfgs.length - 1)) % _minCfgs.length, i.series);

  @override
  dynamic fresh(MinIn input) => IncrementalMinuteMetrics();
  @override
  dynamic fromJson(Json j) => IncrementalMinuteMetrics.fromJson(j);
  @override
  Json toJson(dynamic s) => (s as IncrementalMinuteMetrics).toJson();
  @override
  Object? sync(dynamic s, MinIn i, {bool force = false}) {
    final c = _minCfgs[i.cfg];
    return (s as IncrementalMinuteMetrics).sync(i.keys, i.hr,
        cadenceSpm: i.cad,
        restingHr: c.$1,
        maxHr: c.$2,
        sex: c.$3,
        profile: i.profile,
        dayMinutes: c.$5,
        quietHrr: c.$6,
        force: force,
        includeMinuteSeries: i.series);
  }

  @override
  String show(Object? out) {
    final m = out as MinuteMetrics;
    final e = m.energy, s = m.minutes;
    return [
      _metric(m.trimp),
      _metric(m.strain),
      if (e != null) [e.total, e.active, e.basal, e.walking],
      if (s != null) ...[
        s.coveredMinutes,
        s.abstainedMinutes,
        s.basalKcalPerMin,
        s.active,
        s.walking,
        for (final x in s.minutes)
          [x.minute, x.source, x.abstained, x.basal, x.active, x.total, x.walking],
      ],
    ].join('|');
  }

  @override
  void close(Object? out, MinIn i) {
    final m = out as MinuteMetrics;
    final c = _minCfgs[i.cfg];
    if (i.series) {
      minuteClose(m, i.keys, i.hr,
          cadence: i.cad,
          rhr: c.$1,
          maxHr: c.$2,
          sex: c.$3,
          profile: i.profile,
          dayMinutes: c.$5,
          quietHrr: c.$6);
      return;
    }
    // A summary request omits the minute artifacts and equals the batch's
    // trimp, strain and daily energy.
    expect(m.minutes, isNull, reason: 'summary requests omit minute artifacts');
    final trimp = banisterTrimp(i.hr, restingHr: c.$1, maxHr: c.$2, sex: c.$3);
    final strain = strainScoreMetric(trimp.value,
        wakeMinutes: i.hr.length.toDouble(),
        quietHrr: c.$6,
        female: c.$3 == Sex.female);
    metricEnvelope(m.trimp, trimp);
    numberClose(m.trimp.value, trimp.value);
    metricEnvelope(m.strain, strain);
    numberClose(m.strain.value, strain.value);
    final p = i.profile;
    final energy = p == null || c.$1 == null || c.$2 == null
        ? null
        : Calories.dailyEnergy(i.hr,
            profile: p,
            hrmax: c.$2!,
            restingHr: c.$1!,
            dayMinutes: c.$5,
            cadenceSpmPerMin: i.cad);
    if (energy == null) {
      expect(m.energy, isNull);
    } else {
      expect(m.energy, isNotNull);
      numberClose(m.energy!.total, energy.total);
      numberClose(m.energy!.active, energy.active);
      numberClose(m.energy!.basal, energy.basal);
      numberClose(m.energy!.walking, energy.walking);
    }
  }

  @override
  List<String> get counters => const ['processedMinutes'];

  // After a detour the bills list may be in another order and the totals carry
  // add/remove float residue: the checkpoint is equal in meaning, not in text.
  @override
  bool get detourExact => false;

  @override
  List<int> get special => const [0, 1, 2, 3, 29, 30, 31, 60, 61];

  @override
  List<({String name, bool Function(MinIn) applies, void Function(dynamic, MinIn) call})>
      get refusals => [
            (
              name: 'one more HR than keys',
              applies: (i) => true,
              call: (s, i) => (s as IncrementalMinuteMetrics)
                  .sync(i.keys, [...i.hr, 70], cadenceSpm: i.cad)
            ),
            (
              name: 'one more cadence than keys',
              applies: (i) => true,
              call: (s, i) => (s as IncrementalMinuteMetrics).sync(i.keys, i.hr,
                  cadenceSpm: [...(i.cad ?? List<double?>.filled(i.hr.length, null)), 100])
            ),
            (
              name: 'a key appended twice',
              applies: (i) => i.keys.isNotEmpty,
              call: (s, i) => (s as IncrementalMinuteMetrics)
                  .sync([...i.keys, i.keys.first], [...i.hr, 70])
            ),
            (
              name: 'a duplicate inside a reordering',
              applies: (i) => i.keys.length >= 2,
              call: (s, i) => (s as IncrementalMinuteMetrics).sync(
                  [i.keys[1], i.keys[0], i.keys[1]], [70, 71, 72])
            ),
          ];

  Map _bill(Json j, int i) => ((j['bills'] as List)[i] as Map);

  @override
  List<void Function(Json)> get refuseMutations => [
        (j) {
          final n = (j['bills'] as List).length;
          if (n > 0) j['processedMinutes'] = n - 1;
        },
        (j) => j['trimpTotal'] = (j['trimpTotal'] as num) + 5.0,
        (j) {
          final b = j['bills'] as List;
          if (b.isNotEmpty) b.add(deepCopy(b.first));
        },
        (j) {
          if ((j['bills'] as List).isNotEmpty) _bill(j, 0)['trimp'] = -1.0;
        },
        (j) {
          if ((j['bills'] as List).isNotEmpty) {
            _bill(j, 0)['source'] = 'hr';
            _bill(j, 0)['walking'] = 5.0;
          }
        },
        (j) {
          if ((j['bills'] as List).isNotEmpty) j['parameters'] = null;
        },
        (j) {
          if ((j['bills'] as List).any((b) => (b as Map)['source'] != null)) {
            j['basalPerMinute'] = null;
          }
        },
        (j) => j['hrActiveTotal'] = (j['hrActiveTotal'] as num) + 5.0,
        (j) {
          final p = j['parameters'] as List?;
          if (p != null) p[2] = 'bogus';
        },
        (j) {
          final p = j['parameters'] as List?;
          if (p != null) p.removeLast();
        },
        (j) {
          if ((j['bills'] as List).isNotEmpty) _bill(j, 0)['source'] = 'nonsense';
        },
        (j) {
          if ((j['bills'] as List).isNotEmpty) _bill(j, 0)['key'] = 'x';
        },
        (j) => j['bills'] = 'x',
        (j) => j['walkingTotal'] = (j['walkingTotal'] as num) + 5.0,
      ];

  @override
  List<void Function(Json)> get faithfulMutations => [
        (j) {
          if ((j['bills'] as List).isNotEmpty) _bill(j, 0)['hr'] = 111.0;
        },
        (j) {
          if ((j['bills'] as List).isNotEmpty) _bill(j, 0)['cadence'] = 111.0;
        },
        (j) {
          final p = j['parameters'] as List?;
          if (p != null && p[0] != null && p[0] is num) p[0] = (p[0] as num) + 1.0;
        },
        (j) => j['basalPerMinute'] = ((j['basalPerMinute'] as num?) ?? 0) + 1.0,
        (j) => j['processedMinutes'] = (j['processedMinutes'] as int) + 5,
      ];

  @override
  void conserved(Json cp, MinIn i, String why) {
    final bills = cp['bills'] as List;
    expect(bills.length, i.keys.length, reason: 'a bill for every minute, once $why');
    expect({for (final b in bills) (b as Map)['key']}, i.keys.toSet(),
        reason: 'the bills are the minutes handed in $why');
    var trimp = 0.0, active = 0.0, walking = 0.0;
    for (final b in bills) {
      final m = b as Map;
      trimp += m['trimp'] as num;
      active += m['active'] as num;
      walking += m['walking'] as num;
    }
    double tol(double v) => 1e-9 * math.max(1, v.abs());
    expect((cp['trimpTotal'] as num) - trimp, inInclusiveRange(-tol(trimp), tol(trimp)),
        reason: 'the total is the sum of the bills (trimp) $why');
    expect((cp['hrActiveTotal'] as num) - active, inInclusiveRange(-tol(active), tol(active)),
        reason: 'the total is the sum of the bills (active) $why');
    expect((cp['walkingTotal'] as num) - walking, inInclusiveRange(-tol(walking), tol(walking)),
        reason: 'the total is the sum of the bills (walking) $why');
    // Each bill echoes the minute it prices.
    final byKey = {for (final b in bills) (b as Map)['key']: b};
    for (var k = 0; k < i.keys.length; k++) {
      final b = byKey[i.keys[k]]!;
      final h = i.hr[k];
      expect(b['hr'], h.isNaN ? 'NaN' : h, reason: 'hr of ${i.keys[k]} $why');
      final c = i.cad?[k];
      expect(b['cadence'], c == null ? isNull : (c.isNaN ? 'NaN' : c),
          reason: 'cadence of ${i.keys[k]} $why');
    }
  }

  @override
  Gen<List<int>> recipeGen(int maxN) => IntsGen([
        SizeGen(maxN, pool: const [0, 1, 2, 3, 29, 30, 31, 60, 61]),
        G.intIn(0, 1 << 12),
        G.intIn(0, _minCfgs.length - 1),
        G.elements(const [0, 1, 1]),
        G.elements(const [0, 1]),
      ]);

  @override
  List<List<int>> get forced => [
        [0, 1, 0, 0, 1], // no minutes
        [0, 1, 6, 1, 0],
        [1, 1, 0, 1, 1], // one minute
        [31, 1, 0, 1, 1],
        [61, 3, 1, 1, 0],
        [47, 5, 2, 1, 1], // resting HR unknown
        [47, 5, 3, 0, 0], // max HR unknown, quiet gate absent
        [47, 5, 4, 1, 1], // anchors inverted
        [47, 5, 5, 1, 0], // NaN anchor, day of zero minutes
        [47, 5, 6, 1, 1], // no profile
        [47, 5, 7, 1, 0], // DST-short day, quiet gate 0
        [47, 5, 8, 1, 1], // long day, negative quiet gate
        [47, 5, 9, 1, 0], // NaN quiet gate
        [47, 5, 10, 1, 1], // anchors equal
        [90, 914, 0, 1, 0],
      ];

  @override
  void observe(List<int> r, void Function(String) bump) {
    final n = r[0];
    if (n == 0) bump('series: empty');
    if (n >= 1 && n < 30) bump('series: under 30 minutes');
    if (n >= 60) bump('series: an hour or more');
    final c = _minCfgs[r[2]];
    if (c.$1 == null || c.$2 == null || c.$1!.isNaN) bump('anchors: missing');
    if (c.$1 != null && c.$2 != null && c.$1!.isFinite && c.$1! >= c.$2!) bump('anchors: not ordered');
    if (c.$4 == null) bump('no profile');
    if (c.$3 == Sex.female) bump('sex: female');
    if (r[3] == 1) bump('cadence given');
    bump(r[4] == 1 ? 'minute series requested' : 'summary only');
  }

  @override
  Map<String, double> get shares => {
        'series: empty': .01,
        'series: under 30 minutes': .05,
        'series: an hour or more': .1,
        'anchors: missing': .1,
        'anchors: not ordered': .03,
        'no profile': .05,
        'sex: female': .05,
        'cadence given': .4,
        'minute series requested': .3,
        'summary only': .3,
      };
}

// ═════════════════════════════════════════════════════════════════════════════
// RunningMoments
// ═════════════════════════════════════════════════════════════════════════════

const _momFlavours = [
  'heart rate', // whole bpm, a spread of 40
  'large offset', // 1e9 plus a spread under 1: where sum-of-squares loses every digit
  'constant', // all equal: variance exactly zero
  'wide', // magnitudes from 1e-3 to 1e6, both signs
  'two valued',
  'small spread near zero',
];

/// The values of a recipe (flavour, n, seed).
List<double> _momValues(int flavour, int n, int seed) {
  final g = Rng(seed * 8191 + flavour + 3);
  return [
    for (var i = 0; i < n; i++)
      switch (flavour) {
        0 => 40.0 + g.nextInt(120),
        1 => 1e9 + (g.nextDouble() * .5 + (i % 7) * .25),
        2 => 42.0,
        3 => (g.nextBool() ? 1 : -1) * math.pow(10, g.nextDouble() * 9 - 3).toDouble(),
        4 => i.isEven ? 800.0 : 1000.0,
        _ => (g.nextDouble() - .5) * 1e-3,
      }
  ];
}

/// Mean and sample / population SD of [x] the stable way: about the first value,
/// two passes. The oracle: independent of the Welford state under test, and
/// accurate where a plain sum is not (a 1e9 offset).
({double? mean, double? sd, double? pop}) _twoPass(List<double> x) {
  final n = x.length;
  if (n == 0) return (mean: null, sd: null, pop: null);
  final x0 = x.first;
  var s = 0.0;
  for (final v in x) {
    s += v - x0;
  }
  final md = s / n;
  var ss = 0.0;
  for (final v in x) {
    final d = v - x0 - md;
    ss += d * d;
  }
  return (
    mean: x0 + md,
    sd: n < 2 ? null : math.sqrt(ss / (n - 1)),
    pop: math.sqrt(ss / n),
  );
}

const double _eps = 2.220446049250313e-16;

/// The moments hold what two passes say: the count exact, the mean to a few
/// ulps of its own size, the SDs to 1e-9 relative (plus the same ulps).
void _momentsMatch(RunningMoments m, List<double> x, String why) {
  final o = _twoPass(x);
  expect(m.count, x.length, reason: 'count $why');
  if (x.isEmpty) {
    expect(m.mean, isNull, reason: 'no values, no mean $why');
    expect(m.sampleSd, isNull, reason: why);
    expect(m.populationSd, isNull, reason: why);
    return;
  }
  final scale = x.fold<double>(1, (a, v) => math.max(a, v.abs()));
  final tol = 64 * _eps * scale;
  expect((m.mean! - o.mean!).abs() <= tol + 1e-12 * (o.sd ?? 0), isTrue,
      reason: 'mean ${m.mean} vs ${o.mean} (tol $tol) $why');
  void sdClose(double? got, double? want, String what) {
    if (want == null) {
      expect(got, isNull, reason: '$what is absent below two values $why');
      return;
    }
    expect(got, isNotNull, reason: '$what $why');
    final t = 1e-9 * want + tol;
    expect((got! - want).abs() <= t, isTrue,
        reason: '$what $got vs $want (tol $t) $why');
  }

  sdClose(m.sampleSd, o.sd, 'sample sd');
  sdClose(m.populationSd, o.pop, 'population sd');
}

RunningMoments _momOf(List<double> x) {
  final m = RunningMoments();
  for (final v in x) {
    m.add(v);
  }
  return m;
}

String _momText(RunningMoments m) => jsonEncode(m.toJson());

/// (flavour, n, seed, splits, cut seed).
typedef MomCase = List<int>;

final Gen<MomCase> _momGen = IntsGen([
  G.intIn(0, _momFlavours.length - 1),
  SizeGen(400, pool: const [0, 1, 2, 3, 4, 5, 10]),
  G.intIn(0, 1 << 12),
  G.intIn(0, 6),
  G.intIn(0, 1 << 20),
]);

List<List<double>> _parts(MomCase c, List<double> x) {
  final b = foldBounds(x.length, c[3], c[4]);
  return [for (var k = 0; k + 1 < b.length; k++) x.sublist(b[k], b[k + 1])];
}

void _observeMom(MomCase c, void Function(String) bump) {
  bump('flavour: ${_momFlavours[c[0]]}');
  if (c[1] == 0) bump('empty');
  if (c[1] == 1) bump('one value');
  if (c[1] >= 100) bump('100 values or more');
  final b = foldBounds(c[1], c[3], c[4]);
  if (b.length >= 4) bump('three parts or more');
  if (hasEmptyChunk(b)) bump('an empty part');
}

final Map<String, double> _momShares = {
  for (final f in _momFlavours) 'flavour: $f': .03,
  'empty': .01,
  'one value': .01,
  '100 values or more': .2,
  'three parts or more': .4,
  'an empty part': .05,
};

final List<MomCase> _momForced = [
  [0, 0, 1, 2, 3], // nothing
  [0, 1, 1, 2, 3], // one value
  [0, 2, 1, 2, 3],
  [1, 300, 1, 3, 5], // large offset
  [2, 80, 1, 3, 7], // constant
  [3, 200, 2, 4, 11], // wide
  [4, 51, 1, 6, 13], // two valued, odd
  [5, 120, 4, 5, 17],
  [0, 100, 3, 6, 19], // heart rate
];

void _momMerge(MomCase c) {
  final x = _momValues(c[0], c[1], c[2]);
  final parts = _parts(c, x);
  final tag = 'moments $c parts=${[for (final p in parts) p.length]}';
  final ms = [for (final p in parts) _momOf(p)];
  final before = [for (final m in ms) _momText(m)];
  // Left to right: merging the summaries of the parts is the summary of the
  // concatenation.
  final left = RunningMoments();
  for (final m in ms) {
    left.merge(m);
  }
  _momentsMatch(left, x, '$tag: left fold');
  for (var k = 0; k < ms.length; k++) {
    expect(_momText(ms[k]), before[k], reason: '$tag: the argument is left unchanged');
  }
  // Associativity: (a+b)+c and a+(b+c) read the same as the concatenation; the
  // state differs only in rounding.
  if (parts.length >= 3) {
    final ab = _momOf(parts[0])..merge(_momOf(parts[1]));
    final abc = ab..merge(_momOf([for (final p in parts.skip(2)) ...p]));
    final bc = _momOf(parts[1])..merge(_momOf([for (final p in parts.skip(2)) ...p]));
    final a_bc = _momOf(parts[0])..merge(bc);
    _momentsMatch(abc, x, '$tag: (a+b)+c');
    _momentsMatch(a_bc, x, '$tag: a+(b+c)');
  }
  // Commutativity: the order of two parts does not matter to what is read.
  if (parts.length >= 2) {
    final ab = _momOf(parts[0])..merge(_momOf(parts[1]));
    final ba = _momOf(parts[1])..merge(_momOf(parts[0]));
    final both = [...parts[0], ...parts[1]];
    _momentsMatch(ab, both, '$tag: a+b');
    _momentsMatch(ba, both, '$tag: b+a');
  }
  // Identity, exactly: merging the empty summary changes nothing, and merging
  // into the empty summary copies.
  final whole = _momOf(x);
  final text = _momText(whole);
  whole.merge(RunningMoments());
  expect(_momText(whole), text, reason: '$tag: x + empty == x');
  expect(_momText(RunningMoments()..merge(whole)), text, reason: '$tag: empty + x == x');
  // A summary merged with itself is the multiset twice.
  final twice = _momOf(x)..merge(whole);
  _momentsMatch(twice, [...x, ...x], '$tag: x + x');
  final selfMerged = _momOf(x);
  selfMerged.merge(selfMerged);
  _momentsMatch(selfMerged, [...x, ...x], '$tag: merge with itself');
}

void _momAddRemove(MomCase c) {
  final x = _momValues(c[0], c[1], c[2]);
  final tag = 'moments $c';
  final g = Rng(c[4] + 5);
  final m = RunningMoments();
  final held = <double>[];
  // A walk of adds and removes (of values that are held), checked against two
  // passes along the way.
  for (var i = 0; i < x.length; i++) {
    m.add(x[i]);
    held.add(x[i]);
    if (held.length > 2 && g.nextBool(.4)) {
      final v = held.removeAt(g.nextInt(held.length));
      m.remove(v);
    }
    if (i % 7 == 0 || i == x.length - 1) _momentsMatch(m, held, '$tag step $i');
  }
  // add then remove the same value: back where it was. (A value inside the
  // data's range: removing a downdate of a wild outlier is a numerical limit of
  // every running variance, not a contract.)
  final probe = _momOf(held);
  final text = _momText(probe);
  final extra = held.isEmpty ? 123.5 : held.last;
  probe.add(extra);
  probe.remove(extra);
  _momentsMatch(probe, held, '$tag: add then remove');
  if (held.isEmpty) expect(_momText(probe), text, reason: '$tag: back to the empty state exactly');
  // Emptied again: exactly the fresh state.
  while (held.isNotEmpty) {
    m.remove(held.removeLast());
  }
  expect(_momText(m), _momText(RunningMoments()), reason: '$tag: emptied is fresh');
}

void _momJson(MomCase c) {
  final x = _momValues(c[0], c[1], c[2]);
  final tag = 'moments $c';
  final m = _momOf(x);
  final text = _momText(m);
  final back = RunningMoments.fromJson((jsonDecode(text) as Map).cast<String, dynamic>());
  expect(_momText(back), text, reason: '$tag: write(read(b)) == b');
  _momentsMatch(back, x, '$tag: restored reads the same');
  // And goes on identically.
  m.add(77);
  back.add(77);
  expect(_momText(back), _momText(m), reason: '$tag: same after one more');
  _momentsMatch(back, [...x, 77], tag);
  // Identity and refusals leave the state unchanged.
  final before = _momText(m);
  expect(() => m.add(double.nan), throwsArgumentError);
  expect(() => m.add(double.infinity), throwsArgumentError);
  expect(() => m.remove(double.negativeInfinity), throwsArgumentError);
  expect(() => RunningMoments().remove(1), throwsStateError);
  expect(_momText(m), before, reason: '$tag: refused calls change nothing');
  expect(m.count, x.length + 1);
  // Conservation: (n - 1) sample variance and n population variance are the
  // same sum of squares.
  if (m.count >= 2) {
    final a = m.sampleSd! * m.sampleSd! * (m.count - 1);
    final b = m.populationSd! * m.populationSd! * m.count;
    expect((a - b).abs() <= 1e-9 * math.max(1, a.abs()), isTrue,
        reason: '$tag: one sum of squares: $a vs $b');
  }
}

(Json, Must) _momMutate(Json src, Mut m) {
  final j = (deepCopy(src) as Map).cast<String, dynamic>();
  final (kind, a, b) = m;
  switch (kind % 8) {
    case 0:
      const versions = <Object?>[0, 2, -1, 99, '1', null, true, 1 << 40];
      j['version'] = versions[a % versions.length];
      return (j, Must.refuse);
    case 1:
      const types = <Object?>['IntHistogram', 'Other', null, '', 1];
      j['type'] = types[a % types.length];
      return (j, Must.refuse);
    case 2:
      j.remove(const ['count', 'origin', 'meanOffset', 'm2', 'version', 'type'][a % 6]);
      return (j, Must.refuse);
    case 3:
      const junk = <Object?>['x', <String, Object?>{}, <Object?>[], null, 1.5];
      final k = const ['count', 'origin', 'meanOffset', 'm2'][a % 4];
      j[k] = k == 'count' ? junk[b % junk.length] : junk[b % 4];
      return (j, Must.refuse);
    case 4:
      // Contradictions a reachable state never shows.
      switch (a % 5) {
        case 0:
          j['count'] = -1 - b % 5;
        case 1:
          j['m2'] = -1.0 - b % 5;
        case 2:
          j
            ..['count'] = 0
            ..['origin'] = 1.0 + b % 7; // nothing counted, yet an origin
        case 3:
          j
            ..['count'] = 1
            ..['m2'] = 1.0 + b % 7; // one value with a spread
        default:
          j
            ..['count'] = 0
            ..['m2'] = 1.0;
      }
      return (j, jsonEncode(j) == jsonEncode(src) ? Must.faithful : Must.refuse);
    case 5:
      // Changes the reader cannot tell from a legal state.
      switch (a % 4) {
        case 0:
          if ((j['count'] as int) >= 2) j['m2'] = (j['m2'] as num) + 1.0;
        case 1:
          if ((j['count'] as int) >= 1) j['meanOffset'] = (j['meanOffset'] as num) + 1.0;
        case 2:
          if ((j['count'] as int) >= 1) j['origin'] = (j['origin'] as num) + 1.0;
        default:
          if ((j['count'] as int) >= 2) j['count'] = (j['count'] as int) + 1 + b % 3;
      }
      return (j, Must.faithful);
    case 6:
      // Hostile size: the count claims far more than the sums can hold.
      if ((j['count'] as int) >= 2) j['count'] = const [1 << 40, 1 << 62, 0x7fffffffffffffff][b % 3];
      return (j, Must.faithful);
    default:
      j['futureField${a % 3}'] = const [1, 'x', <Object?>[1]][b % 3];
      return (j, Must.ignored);
  }
}

void _momL3((MomCase, Mut) arg) {
  final (c, m) = arg;
  final tag = 'moments $c mutation=${m.$1 % 8}(${m.$2},${m.$3})';
  final src = (jsonDecode(_momText(_momOf(_momValues(c[0], c[1], c[2])))) as Map).cast<String, dynamic>();
  final (bad, must) = _momMutate(src, m);
  String outcome;
  try {
    outcome = 'accepted:${_momText(RunningMoments.fromJson((deepCopy(bad) as Map).cast<String, dynamic>()))}';
  } on FormatException {
    outcome = 'refused';
  } catch (e) {
    outcome = 'WRONG ERROR TYPE: ${e.runtimeType}: $e';
  }
  expectMutationOutcome(outcome, must, _text(bad), _text(src), tag);
}

// ═════════════════════════════════════════════════════════════════════════════
// IntHistogram
// ═════════════════════════════════════════════════════════════════════════════

const _histFlavours = [
  'heart rate', // 40..180 bpm
  'few values', // 3 distinct
  'one value',
  'negatives', // -100..299
  'wide', // up to +-1e9
];

List<int> _histValues(int flavour, int n, int seed) {
  final g = Rng(seed * 4099 + flavour + 1);
  return [
    for (var i = 0; i < n; i++)
      switch (flavour) {
        0 => 40 + g.nextInt(141),
        1 => 60 + g.nextInt(3),
        2 => 61,
        3 => g.nextInt(400) - 100,
        _ => g.nextInt(2000000000) - 1000000000,
      }
  ];
}

IntHistogram _histOf(List<int> x) {
  final h = IntHistogram();
  for (final v in x) {
    h.add(v);
  }
  return h;
}

String _histText(IntHistogram h) => jsonEncode(h.toJson());

const _ps = <double>[0, 1, 5, 25, 30, 33.3, 50, 66.6, 75, 90, 95, 99, 100];

/// The histogram reads exactly what the sorted expanded list reads: the very
/// double `percentileSorted` gives, count and distinct count exact, and a
/// canonical checkpoint (sorted bins, no zero counts).
void _histMatches(IntHistogram h, List<int> x, String why) {
  final sorted = [for (final v in x) v.toDouble()]..sort();
  expect(h.count, x.length, reason: 'count $why');
  expect(h.distinct, x.toSet().length, reason: 'distinct $why');
  if (x.isEmpty) {
    expect(h.median, isNull, reason: 'no values, no median $why');
    for (final p in _ps) {
      expect(h.percentile(p), isNull, reason: 'p$p $why');
    }
  } else {
    for (final p in _ps) {
      expect(h.percentile(p), percentileSorted(sorted, p), reason: 'p$p $why');
    }
    expect(h.median, percentileSorted(sorted, 50), reason: 'median $why');
  }
  final j = h.toJson();
  expect(j['values'], ([...x.toSet()]..sort()), reason: 'sorted distinct bins $why');
  final counts = <int, int>{};
  for (final v in x) {
    counts.update(v, (c) => c + 1, ifAbsent: () => 1);
  }
  expect(j['counts'], [for (final v in j['values'] as List) counts[v]], reason: 'counts $why');
}

void _observeHist(MomCase c, void Function(String) bump) {
  bump('flavour: ${_histFlavours[c[0]]}');
  if (c[1] == 0) bump('empty');
  if (c[1] == 1) bump('one value');
  if (c[1] >= 100) bump('100 values or more');
  final b = foldBounds(c[1], c[3], c[4]);
  if (b.length >= 4) bump('three parts or more');
  if (hasEmptyChunk(b)) bump('an empty part');
}

final Map<String, double> _histShares = {
  for (final f in _histFlavours) 'flavour: $f': .03,
  'empty': .01,
  'one value': .01,
  '100 values or more': .2,
  'three parts or more': .4,
  'an empty part': .05,
};

final Gen<MomCase> _histGen = IntsGen([
  G.intIn(0, _histFlavours.length - 1),
  SizeGen(400, pool: const [0, 1, 2, 3, 4, 5, 10]),
  G.intIn(0, 1 << 12),
  G.intIn(0, 6),
  G.intIn(0, 1 << 20),
]);

final List<MomCase> _histForced = [
  [0, 0, 1, 2, 3],
  [0, 1, 1, 2, 3],
  [2, 2, 1, 2, 3], // two equal values
  [1, 7, 1, 3, 5],
  [0, 300, 1, 4, 7],
  [3, 150, 2, 5, 9],
  [4, 90, 3, 6, 11],
  [0, 5, 4, 6, 13],
];

void _histMerge(MomCase c) {
  final x = _histValues(c[0], c[1], c[2]);
  final b = foldBounds(x.length, c[3], c[4]);
  final parts = [for (var k = 0; k + 1 < b.length; k++) x.sublist(b[k], b[k + 1])];
  final tag = 'histogram $c parts=${[for (final p in parts) p.length]}';
  final hs = [for (final p in parts) _histOf(p)];
  final before = [for (final h in hs) _histText(h)];
  // The summary of the concatenation, exactly (bins and checkpoint included).
  final left = IntHistogram();
  for (final h in hs) {
    left.merge(h);
  }
  _histMatches(left, x, '$tag: left fold');
  expect(_histText(left), _histText(_histOf(x)), reason: '$tag: same checkpoint as one fold');
  for (var k = 0; k < hs.length; k++) {
    expect(_histText(hs[k]), before[k], reason: '$tag: the argument is left unchanged');
  }
  // Associative and commutative, exactly: the checkpoint is canonical.
  if (parts.length >= 3) {
    final rest = [for (final p in parts.skip(2)) ...p];
    final ab_c = _histOf(parts[0])..merge(_histOf(parts[1]))..merge(_histOf(rest));
    final a_bc = _histOf(parts[0])..merge(_histOf(parts[1])..merge(_histOf(rest)));
    expect(_histText(ab_c), _histText(a_bc), reason: '$tag: associative');
    expect(_histText(ab_c), _histText(_histOf(x)), reason: '$tag: and the concatenation');
  }
  if (parts.length >= 2) {
    final ab = _histOf(parts[0])..merge(_histOf(parts[1]));
    final ba = _histOf(parts[1])..merge(_histOf(parts[0]));
    expect(_histText(ab), _histText(ba), reason: '$tag: commutative');
  }
  // Identity.
  final whole = _histOf(x);
  final text = _histText(whole);
  whole.merge(IntHistogram());
  expect(_histText(whole), text, reason: '$tag: x + empty == x');
  expect(_histText(IntHistogram()..merge(whole)), text, reason: '$tag: empty + x == x');
  // Itself, doubled.
  final self = _histOf(x);
  self.merge(self);
  _histMatches(self, [...x, ...x], '$tag: merge with itself');
}

void _histAddRemove(MomCase c) {
  final x = _histValues(c[0], c[1], c[2]);
  final tag = 'histogram $c';
  final g = Rng(c[4] + 9);
  final h = IntHistogram();
  final held = <int>[];
  for (var i = 0; i < x.length; i++) {
    if (held.isNotEmpty && g.nextBool(.4)) {
      final v = held.removeAt(g.nextInt(held.length));
      h.remove(v);
    } else {
      held.add(x[i]);
      h.add(x[i]);
    }
    if (i % 5 == 0 || i == x.length - 1) _histMatches(h, held, '$tag step $i');
  }
  // Refusals leave the histogram exactly as it was.
  final before = _histText(h);
  final absent = held.fold<int>(0, (a, v) => math.max(a, v.abs())) + 1;
  expect(() => h.remove(absent), throwsStateError, reason: tag);
  expect(() => h.remove(double.nan), throwsStateError, reason: tag);
  expect(() => h.remove(1.5), throwsStateError, reason: tag);
  expect(() => h.add(double.nan), throwsArgumentError, reason: tag);
  expect(() => h.add(double.infinity), throwsArgumentError, reason: tag);
  expect(() => h.add(70.5), throwsArgumentError, reason: tag);
  expect(() => h.add(70, 0), throwsArgumentError, reason: tag);
  expect(() => h.add(70, -2), throwsArgumentError, reason: tag);
  if (h.count > 0) {
    // (An empty histogram answers null for any p; the range is checked once
    // there is something to read.)
    expect(() => h.percentile(-1), throwsArgumentError, reason: tag);
    expect(() => h.percentile(100.5), throwsArgumentError, reason: tag);
    expect(() => h.percentile(double.nan), throwsArgumentError, reason: tag);
  }
  expect(_histText(h), before, reason: '$tag: refused calls change nothing');
  // Repeat counts: add(v, k) is k adds of v; removing is one at a time.
  final r = IntHistogram()..add(60, 3)..add(70, 2);
  _histMatches(r, [60, 60, 60, 70, 70], '$tag: repeat count');
  r.remove(60);
  _histMatches(r, [60, 60, 70, 70], '$tag: removing one of several');
  expect(_histText(IntHistogram()..add(5, 4)), _histText(_histOf([5, 5, 5, 5])), reason: tag);
  // A whole-number double is a whole number.
  final w = IntHistogram()..add(70.0);
  _histMatches(w, [70], tag);
  // Add then remove: where it was, no zero-count bin left behind.
  final t = _histOf(held);
  final text = _histText(t);
  t.add(1234567);
  t.remove(1234567);
  expect(_histText(t), text, reason: '$tag: add then remove');
}

void _histJson(MomCase c) {
  final x = _histValues(c[0], c[1], c[2]);
  final tag = 'histogram $c';
  final h = _histOf(x);
  final text = _histText(h);
  final back = IntHistogram.fromJson((jsonDecode(text) as Map).cast<String, dynamic>());
  expect(_histText(back), text, reason: '$tag: write(read(b)) == b');
  _histMatches(back, x, '$tag: restored');
  back.add(55);
  h.add(55);
  expect(_histText(back), _histText(h), reason: '$tag: same after one more');
  _histMatches(back, [...x, 55], tag);
  // Conservation: the counts add up to the count, every bin is held once.
  final j = back.toJson();
  expect((j['counts'] as List).fold<int>(0, (a, v) => a + (v as int)), back.count, reason: tag);
}

(Json, Must) _histMutate(Json src, Mut m) {
  final j = (deepCopy(src) as Map).cast<String, dynamic>();
  final (kind, a, b) = m;
  List l(String k) => j[k] as List;
  switch (kind % 8) {
    case 0:
      const versions = <Object?>[0, 2, -1, 99, '1', null, true, 1 << 40];
      j['version'] = versions[a % versions.length];
      return (j, Must.refuse);
    case 1:
      const types = <Object?>['RunningMoments', 'Other', null, '', 1];
      j['type'] = types[a % types.length];
      return (j, Must.refuse);
    case 2:
      j.remove(const ['values', 'counts', 'version', 'type'][a % 4]);
      return (j, Must.refuse);
    case 3:
      const junk = <Object?>['x', <String, Object?>{}, null, 1.5, 3];
      j[const ['values', 'counts'][a % 2]] = junk[b % junk.length];
      return (j, Must.refuse);
    case 4:
      // The bins contradict themselves.
      switch (a % 8) {
        case 0:
          l('values').add(1 << 40);
        case 1:
          if (l('counts').isNotEmpty) l('counts').removeLast();
        case 2:
          if (l('counts').isNotEmpty) l('counts')[b % l('counts').length] = 0;
        case 3:
          if (l('counts').isNotEmpty) l('counts')[b % l('counts').length] = -1 - b % 4;
        case 4:
          if (l('values').length >= 2) {
            final t = l('values')[0];
            l('values')[0] = l('values')[1];
            l('values')[1] = t; // out of order
          }
        case 5:
          if (l('values').isNotEmpty) {
            l('values').insert(0, l('values')[0]); // a repeated value
            l('counts').insert(0, 1);
          }
        case 6:
          if (l('values').isNotEmpty) l('values')[0] = 1.5;
        default:
          if (l('values').isNotEmpty) l('counts')[0] = 1.5;
      }
      return (j, jsonEncode(j) == jsonEncode(src) ? Must.faithful : Must.refuse);
    case 5:
      // A bin count changed: legal.
      if (l('counts').isNotEmpty) l('counts')[b % l('counts').length] = (l('counts')[b % l('counts').length] as int) + 1 + a % 5;
      return (j, Must.faithful);
    case 6:
      // Hostile counts: each bin plausible, the total past what an int can
      // hold (the skipped FINDING below).
      if (l('counts').isNotEmpty) l('counts')[0] = const [1 << 40, 1 << 61, 0x7fffffffffffffff][b % 3];
      return (j, Must.faithful);
    default:
      j['futureField${a % 3}'] = const [1, 'x', <Object?>[1]][b % 3];
      return (j, Must.ignored);
  }
}

void _histL3((MomCase, Mut) arg) {
  final (c, m) = arg;
  final tag = 'histogram $c mutation=${m.$1 % 8}(${m.$2},${m.$3})';
  final src = (jsonDecode(_histText(_histOf(_histValues(c[0], c[1], c[2])))) as Map).cast<String, dynamic>();
  final (bad, must) = _histMutate(src, m);
  String outcome;
  try {
    outcome = 'accepted:${_histText(IntHistogram.fromJson((deepCopy(bad) as Map).cast<String, dynamic>()))}';
  } on FormatException {
    outcome = 'refused';
  } catch (e) {
    outcome = 'WRONG ERROR TYPE: ${e.runtimeType}: $e';
  }
  expectMutationOutcome(outcome, must, _text(bad), _text(src), tag);
}

// ═════════════════════════════════════════════════════════════════════════════
// CalculationCache
// ═════════════════════════════════════════════════════════════════════════════

/// The cache against a model written from its documented behaviour: bounded
/// least-recently-used results, each with an owned snapshot of the dependencies
/// it was computed from; a hit needs the same key and DEEP-equal dependencies
/// (NaN equals NaN) and no `full` request; a hit and a computation are counted;
/// a calculation that throws changes nothing; results are copies.
class _CacheModel {
  _CacheModel(this.cap);
  final int cap;
  final List<(String, Object?, Object?)> entries = []; // oldest first
  int computations = 0, hits = 0;

  static bool eq(Object? a, Object? b) {
    if (a is num && b is num) return a == b || (a.isNaN && b.isNaN);
    if (a is List && b is List) {
      return a.length == b.length && [for (var i = 0; i < a.length; i++) eq(a[i], b[i])].every((x) => x);
    }
    if (a is Map && b is Map) {
      return a.length == b.length && a.keys.every((k) => b.containsKey(k) && eq(a[k], b[k]));
    }
    return a == b;
  }

  static Object? copy(Object? v) => v is List
      ? [for (final e in v) copy(e)]
      : v is Map
          ? {for (final e in v.entries) e.key: copy(e.value)}
          : v;

  Object? evaluate(String key, Object? deps, Object? Function() calc, bool full) {
    final at = entries.indexWhere((e) => e.$1 == key);
    if (!full && at >= 0 && eq(entries[at].$2, deps)) {
      final e = entries.removeAt(at);
      entries.add(e);
      hits++;
      return copy(e.$3);
    }
    final v = calc(); // may throw: nothing changes
    if (at >= 0) entries.removeAt(at);
    entries.add((key, copy(deps), copy(v)));
    while (entries.length > cap) {
      entries.removeAt(0);
    }
    computations++;
    return copy(v);
  }
}

/// A dependency: a small structure with ties, NaN, nesting and null.
Object? _dep(Rng g, int depth) {
  switch (g.nextInt(depth > 0 ? 7 : 5)) {
    case 0:
      return g.nextInt(3);
    case 1:
      return null;
    case 2:
      return g.nextBool() ? double.nan : 1.5;
    case 3:
      return 'k${g.nextInt(2)}';
    case 4:
      return g.nextBool();
    case 5:
      return [for (var i = g.nextInt(3); i > 0; i--) _dep(g, depth - 1)];
    default:
      return {for (var i = g.nextInt(3); i > 0; i--) 'a${g.nextInt(3)}': _dep(g, depth - 1)};
  }
}

void _cacheModelLaw(List<int> c) {
  // (steps, capacity, seed)
  final steps = c[0], cap = c[1] + 1, seed = c[2];
  final g = Rng(seed * 31 + 7);
  final cache = CalculationCache(maxEntries: cap);
  final model = _CacheModel(cap);
  final tag = 'cache steps=$steps cap=$cap seed=$seed';
  var made = 0;
  // A small pool of dependency values, so equal dependencies recur.
  final pool = [for (var i = 0; i < 4; i++) _dep(Rng(seed + i * 17), 2)];
  for (var i = 0; i < steps; i++) {
    final key = 'key${g.nextInt(cap + 2)}';
    final deps = _CacheModel.copy(pool[g.nextInt(pool.length)]);
    final full = g.nextBool(.15);
    final throws = g.nextBool(.1);
    final value = [made++, made % 3];
    Object? calc() {
      if (throws) throw StateError('calculation failed');
      return [...value];
    }

    Object? got, want;
    Object? gotErr, wantErr;
    try {
      got = cache.evaluate<Object?>(key, deps, calc, full: full);
    } catch (e) {
      gotErr = e;
    }
    try {
      want = model.evaluate(key, deps, calc, full);
    } catch (e) {
      wantErr = e;
    }
    expect(gotErr.runtimeType, wantErr.runtimeType, reason: '$tag step $i: failures propagate');
    expect(got, want, reason: '$tag step $i: result');
    expect(cache.computations, model.computations, reason: '$tag step $i: computations');
    expect(cache.hits, model.hits, reason: '$tag step $i: hits');
    // The result is the caller's: changing it changes no later hit.
    if (got is List && got.isNotEmpty) got[0] = -99;
    // The dependencies handed in are snapshotted: changing them afterwards
    // does not turn a later hit into a miss (or the reverse).
    if (deps is List && deps.isNotEmpty) deps.add('mutated');
  }
  // Size: never more than the capacity, each key held once.
  var held = 0;
  for (var k = 0; k < cap + 2; k++) {
    var probeCalls = 0;
    final before = cache.computations;
    cache.evaluate<Object?>('key$k', _CacheModel.copy(null), () {
      probeCalls++;
      return [0];
    });
    if (cache.computations == before) held++;
    expect(probeCalls <= 1, isTrue);
  }
  expect(held <= cap, isTrue, reason: '$tag: at most $cap entries held, held $held');
  cache.clear();
  var recomputed = false;
  cache.evaluate<Object?>('key0', null, () => recomputed = true);
  expect(recomputed, isTrue, reason: '$tag: clear discards');
}

void main() {
  _registerSyncLaws(HrvOps(), maxN: 800);
  _registerSyncLaws(EnmoOps(), maxN: 900);
  _registerSyncLaws(LombOps(), maxN: 300);
  _registerSyncLaws(MinOps(), maxN: 300);
  group('RunningMoments', () {
    _laws.law<MomCase>(
      'M RunningMoments.merge: the summary of the parts merged is the summary of '
      'the concatenation; associative, commutative, the empty summary is the '
      'identity, a summary merged with itself is the multiset twice',
      _momGen,
      _momMerge,
      examples: _momForced,
      cases: 200,
      reach: Reach<MomCase>(_momShares, _observeMom),
    );
    _laws.law<MomCase>(
      'L1b RunningMoments: a walk of adds and removes reads what two passes read',
      _momGen,
      _momAddRemove,
      examples: _momForced,
      cases: 120,
      reach: Reach<MomCase>(_momShares, _observeMom),
    );
    _laws.law<MomCase>(
      'L2 RunningMoments: write(read(b)) == b, goes on identically, refused calls '
      'change nothing, one sum of squares',
      _momGen,
      _momJson,
      examples: _momForced,
      cases: 120,
      reach: Reach<MomCase>(_momShares, _observeMom),
    );
    _laws.law<(MomCase, Mut)>(
      'L3 RunningMoments: a mutated checkpoint is refused whole or holds exactly '
      'what was written',
      G.pair(_momGen, mutGen(8)),
      _momL3,
      examples: [
        for (var k = 0; k < 8; k++)
          for (var i = 0; i < 4; i++) (_momForced[3 + i], (k, 2 * k + i, 3 * k + i)),
        for (var a = 0; a < 5; a++) (_momForced[3], (4, a, 1)),
        for (var a = 0; a < 5; a++) (_momForced[1], (4, a, 1)),
      ],
      cases: 200,
      reach: Reach<(MomCase, Mut)>({
        for (var k = 0; k < 8; k++) 'kind: $k': .03,
      }, (arg, bump) => bump('kind: ${arg.$2.$1 % 8}')),
    );
  });

  group('IntHistogram', () {
    _laws.law<MomCase>(
      'M IntHistogram.merge: the histogram of the parts merged is exactly the '
      'histogram of the concatenation; associative, commutative, the empty '
      'histogram is the identity',
      _histGen,
      _histMerge,
      examples: _histForced,
      cases: 200,
      reach: Reach<MomCase>(_histShares, _observeHist),
    );
    _laws.law<MomCase>(
      'L1b IntHistogram: a walk of adds and removes reads exactly what the '
      'sorted list reads; refused calls change nothing',
      _histGen,
      _histAddRemove,
      examples: _histForced,
      cases: 150,
      reach: Reach<MomCase>(_histShares, _observeHist),
    );
    _laws.law<MomCase>(
      'L2 IntHistogram: write(read(b)) == b, goes on identically, the counts add '
      'up',
      _histGen,
      _histJson,
      examples: _histForced,
      cases: 150,
      reach: Reach<MomCase>(_histShares, _observeHist),
    );
    _laws.law<(MomCase, Mut)>(
      'L3 IntHistogram: a mutated checkpoint is refused whole or holds exactly '
      'what was written',
      G.pair(_histGen, mutGen(8)),
      _histL3,
      examples: [
        for (var k = 0; k < 8; k++)
          for (var i = 0; i < 4; i++) (_histForced[3 + i], (k, 2 * k + i, 3 * k + i)),
        for (var a = 0; a < 8; a++) (_histForced[4], (4, a, 1)),
      ],
      cases: 200,
      reach: Reach<(MomCase, Mut)>({
        for (var k = 0; k < 8; k++) 'kind: $k': .03,
      }, (arg, bump) => bump('kind: ${arg.$2.$1 % 8}')),
    );
  });

  group('CalculationCache', () {
    _laws.law<List<int>>(
      'CalculationCache equals a model of bounded LRU results with deep-compared '
      'dependency snapshots: results, hits, computations, failures, capacity',
      IntsGen([G.intIn(0, 80), G.intIn(0, 6), G.intIn(0, 1 << 12)]),
      _cacheModelLaw,
      examples: [
        [0, 0, 1],
        [1, 0, 2],
        [40, 0, 3], // capacity 1
        [60, 2, 4], // capacity 3
        [80, 6, 5], // capacity 7
        [80, 1, 6],
      ],
      cases: 200,
      reach: Reach<List<int>>({
        'capacity 1': .05,
        'capacity 3 or more': .3,
        'many steps': .4,
      }, (c, bump) {
        if (c[1] == 0) bump('capacity 1');
        if (c[1] >= 2) bump('capacity 3 or more');
        if (c[0] >= 40) bump('many steps');
      }),
    );
  });

  group('FINDINGS (skipped: suspected gaps against the documented contract)', () {
    test('IntHistogram.fromJson refuses bin counts whose total does not fit an '
        'int', () {
      final bad = <Map<String, dynamic>>[
        {'version': 1, 'type': 'IntHistogram', 'values': [1, 2, 3], 'counts': [1 << 62, 1 << 62, 1 << 62]},
        {'version': 1, 'type': 'IntHistogram', 'values': [1, 2], 'counts': [0x7fffffffffffffff, 1]},
      ];
      for (final j in bad) {
        // Today: accepted, `count` wraps negative, and a later `percentile`
        // throws StateError('Order statistic out of range'), not the
        // FormatException a malformed checkpoint is documented to raise.
        expect(() => IntHistogram.fromJson(j), throwsFormatException, reason: '$j');
      }
    }, skip: 'FINDING (hostile counts, no output change for any real '
        'checkpoint): fromJson accepts bin counts that overflow int64 when '
        'summed; the histogram then reports a negative count and percentile() '
        'throws StateError. Reported, not fixed.');
  });

  group('the forced scenarios say what they claim', () {
    test('HRV: empty, jitter gate, constant, dropouts, several 5-minute bins, no '
        'times, an artifact fraction', () {
      final ops = HrvOps();
      var absent = false, gated = false, multiBin = false, noTimes = false;
      var constant = false, gaps = false, af = false;
      for (final r in ops.forced) {
        final x = ops.expand(r);
        final st = ops.fresh(x);
        final out = ops.sync(st, x) as Metric<HrvTime>;
        final j = ops.toJson(st);
        if (!out.present) absent = true;
        if (out.present && out.value!.rmssd == null && out.note!.startsWith('rmssd_refused')) {
          gated = true;
        }
        if ((j['bins'] as List).length >= 2) multiBin = true;
        if (x.t == null && x.nn.length >= 2) noTimes = true;
        if (r[0] == 3 && x.nn.length >= 31) constant = true;
        if (x.t != null) {
          for (var i = 1; i < x.nn.length; i++) {
            if (x.t![i] - x.t![i - 1] > x.nn[i] + .5) gaps = true;
          }
        }
        if (x.af > 0) af = true;
      }
      expect([absent, gated, multiBin, noTimes, constant, gaps, af],
          everyElement(isTrue));
    });

    test('ENMO: empty, gaps, invalid samples, duplicate and unsorted times, a '
        'given, an auto and a non-finite reference', () {
      final ops = EnmoOps();
      var empty = false, invalid = false, dup = false, unsorted = false;
      var given = false, auto = false, nonFinite = false, multiMinute = false;
      for (final r in ops.forced) {
        final x = ops.expand(r);
        final out = ops.sync(ops.fresh(x), x) as EnmoResult;
        if (x.samples.isEmpty) empty = true;
        if (x.samples.any((s) => !s.valid)) invalid = true;
        for (var i = 1; i < x.samples.length; i++) {
          if (x.samples[i].tsMs == x.samples[i - 1].tsMs) dup = true;
          if (x.samples[i].tsMs < x.samples[i - 1].tsMs) unsorted = true;
        }
        final g = x.c.$1;
        if (g == null) auto = true;
        if (g != null && !g.isFinite) nonFinite = true;
        if (g != null && g.isFinite) given = true;
        if (out.minutes.length >= 2) multiMinute = true;
      }
      expect([empty, invalid, dup, unsorted, given, auto, nonFinite, multiMinute],
          everyElement(isTrue));
    });

    test('Lomb: abstentions, a spectrum, a non-finite value, a mismatch, '
        'epoch-sized times, an empty and a repeated grid', () {
      final ops = LombOps();
      var abstains = false, spectrum = false, nonFinite = false;
      var mismatch = false, epoch = false, emptyGrid = false, repeated = false;
      for (final r in ops.forced) {
        final x = ops.expand(r);
        final out = ops.sync(ops.fresh(x), x) as LombScargle?;
        if (out == null) abstains = true;
        if (out != null && out.spectrum.isNotEmpty) spectrum = true;
        if (x.t.any((v) => !v.isFinite) || x.y.any((v) => !v.isFinite)) nonFinite = true;
        if (x.t.length != x.y.length) mismatch = true;
        if (x.t.isNotEmpty && x.t.first > 1e9) epoch = true;
        if (x.freqs.isEmpty) emptyGrid = true;
        if (x.freqs.toSet().length < x.freqs.length) repeated = true;
      }
      expect([abstains, spectrum, nonFinite, mismatch, epoch, emptyGrid, repeated],
          everyElement(isTrue));
    });

    test('minute metrics: no minutes, missing / inverted / NaN anchors, no '
        'profile, a short, a DST and a long day, both artifact modes', () {
      final ops = MinOps();
      var empty = false, missing = false, inverted = false, nan = false;
      var noProfile = false, shortDay = false, dst = false, longDay = false;
      var series = false, summary = false, energy = false;
      for (final r in ops.forced) {
        final x = ops.expand(r);
        final out = ops.sync(ops.fresh(x), x) as MinuteMetrics;
        final c = _minCfgs[x.cfg];
        if (x.keys.isEmpty) empty = true;
        if (c.$1 == null || c.$2 == null) missing = true;
        if (c.$1 != null && c.$2 != null && c.$1! >= c.$2!) inverted = true;
        if (c.$1 != null && c.$1!.isNaN) nan = true;
        if (c.$4 == null) noProfile = true;
        if (c.$5 < 1440) shortDay = true;
        if (c.$5 == 1380) dst = true;
        if (c.$5 > 1440) longDay = true;
        if (x.series) series = true;
        if (!x.series) summary = true;
        if (out.energy != null) energy = true;
      }
      expect([empty, missing, inverted, nan, noProfile, shortDay, dst, longDay, series, summary, energy],
          everyElement(isTrue));
    });

    test('merge: empty, one value, two, constant, large offset, wide range, '
        'odd and even counts', () {
      var empty = false, one = false, two = false, constant = false;
      var offset = false, wide = false, odd = false, even = false;
      for (final c in _momForced) {
        if (c[1] == 0) empty = true;
        if (c[1] == 1) one = true;
        if (c[1] == 2) two = true;
        if (c[0] == 2 && c[1] > 2) constant = true;
        if (c[0] == 1) offset = true;
        if (c[0] == 3) wide = true;
        if (c[1] > 2 && c[1].isOdd) odd = true;
        if (c[1] > 2 && c[1].isEven) even = true;
      }
      expect([empty, one, two, constant, offset, wide, odd, even], everyElement(isTrue));
    });
  });

  _laws.registerReachTest();
}
