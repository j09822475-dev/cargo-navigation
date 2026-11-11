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
    if (i > 0 && (s.length - i) % 3 == 0) b.write('\u00A0');
    b.write(s[i]);
  }
  return b.toString();
}

/// Сумма в евро: «12,50 €».
String fmtMoney(double v) {
  final cents = (v * 100).round();
  final whole = cents ~/ 100, frac = cents % 100;
  return '${_group(whole)},${frac.toString().padLeft(2, '0')}\u00A0€';
}

/// Время прибытия «14:32» через [hours] часов от [now].
String fmtEta(double hours, DateTime now) {
  final t = now.add(Duration(minutes: (hours * 60).round()));
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final days = DateTime(t.year, t.month, t.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  return days == 0 ? hm : '$hm (+$days дн.)';
}

const countryNamesRu = <String, String>{
  'AT': 'Австрия', 'CZ': 'Чехия', 'SK': 'Словакия', 'SI': 'Словения', 'HU': 'Венгрия', 'RO': 'Румыния', 'BG': 'Болгария',
};
