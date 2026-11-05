String fmtTime(double hours) {
  final m = (hours * 60).round();
  if (m >= 60) {
    final h = m ~/ 60;
    return h >= 24 ? '${h ~/ 24} д ${h % 24} ч ${m % 60} мин' : '$h ч ${m % 60} мин';
  }
  return '$m мин';
}

String fmtDist(double meters) {
  if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(meters >= 10000 ? 0 : 1)} км';
  return '${(meters / 10).round() * 10} м';
}

String _group(int v) {
  final s = v.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return (v < 0 ? '-' : '') + b.toString();
}

String fmtMoney(double v, String currency) => '${_group(v.round())} $currency';
