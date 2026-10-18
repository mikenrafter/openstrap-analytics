// A non-finite beat time used to make rsaRespRate and hrvFreq walk their
// sub-windows forever (an infinite last time is never reached), which ran a
// test isolate out of memory on the dev box. They abstain now, and the
// streams refuse such a fold and answer a snapshot with the batch.
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  final nn = [for (var i = 0; i < 1500; i++) 900.0 + 40 * (i % 7)];
  final ts = <double>[];
  var t = 0.0;
  for (final v in nn) {
    t += v;
    ts.add(t);
  }
  List<double> withLast(double bad) => [...ts]..[ts.length - 1] = bad;

  for (final bad in [double.infinity, double.nan, double.negativeInfinity]) {
    test('batch abstains on a last beat time of $bad', () {
      final r = rsaRespRate(nn, withLast(bad), artifactFraction: 0);
      expect(r.present, isFalse);
      expect(r.note, 'non-finite beat time');
      final h = hrvFreq(nn, withLast(bad), artifactFraction: 0);
      expect(h.present, isFalse);
      expect(h.note, 'non-finite beat time');
    });

    test('streams refuse the fold, unchanged, on $bad', () {
      final r = RsaRespStream()..fold(nn.sublist(0, 700), ts.sublist(0, 700));
      final h = HrvFreqStream()..fold(nn.sublist(0, 700), ts.sublist(0, 700));
      final rBefore = r.toJson(), hBefore = h.toJson();
      final badTs = [...ts.sublist(700, 800)]..[50] = bad;
      expect(() => r.fold(nn.sublist(700, 800), badTs), throwsArgumentError);
      expect(() => h.fold(nn.sublist(700, 800), badTs), throwsArgumentError);
      expect(r.toJson(), rBefore);
      expect(h.toJson(), hBefore);
    });
  }

  test('a snapshot with an infinite tail time is the batch answer', () {
    final r = RsaRespStream()..fold(nn.sublist(0, 1400), ts.sublist(0, 1400));
    final h = HrvFreqStream()..fold(nn.sublist(0, 1400), ts.sublist(0, 1400));
    final tailTs = withLast(double.infinity).sublist(1400);
    final tailNn = nn.sublist(1400);
    expect(
        r.snapshot(tailNnMs: tailNn, tailNnTimesMs: tailTs, artifactFraction: 0)
            .note,
        'non-finite beat time');
    expect(
        h.snapshot(tailNnMs: tailNn, tailNnTimesMs: tailTs, artifactFraction: 0)
            .note,
        'non-finite beat time');
  });
}
