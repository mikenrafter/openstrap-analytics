/// Solve a 3×3 linear system by Gaussian elimination with partial pivoting.
/// Returns null if singular.
List<double>? solveCosinor3(List<List<double>> a, List<double> b) {
  final m = [
    [a[0][0], a[0][1], a[0][2], b[0]],
    [a[1][0], a[1][1], a[1][2], b[1]],
    [a[2][0], a[2][1], a[2][2], b[2]],
  ];
  for (var col = 0; col < 3; col++) {
    var piv = col;
    for (var r = col + 1; r < 3; r++) {
      if (m[r][col].abs() > m[piv][col].abs()) piv = r;
    }
    if (m[piv][col].abs() < 1e-12) return null;
    final tmp = m[col];
    m[col] = m[piv];
    m[piv] = tmp;
    final d = m[col][col];
    for (var j = col; j < 4; j++) {
      m[col][j] /= d;
    }
    for (var r = 0; r < 3; r++) {
      if (r == col) continue;
      final f = m[r][col];
      for (var j = col; j < 4; j++) {
        m[r][j] -= f * m[col][j];
      }
    }
  }
  return [m[0][3], m[1][3], m[2][3]];
}
