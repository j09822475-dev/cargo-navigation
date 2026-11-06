import 'dart:convert';

/// Преобразует таблицу участков оператора (CSV) в файл тарифов.
///
/// CSV: заголовок `ref,length_km,price_eur`, по строке на участок (цена для легкового авто).
/// Строки с одинаковым `ref` объединяются: ставка = сумма цен ÷ сумма длин (взвешенная по длине).
/// Пустой `ref` — участки без номера: идут в ставку оператора по умолчанию.
class TariffImportResult {
  final String json;
  final List<String> warnings;
  final int sections;
  const TariffImportResult(this.json, this.warnings, this.sections);
}

TariffImportResult buildTariffJson(
  String csv, {
  required String operator,
  List<String> aliases = const [],
  required String country,
  required String updated,
  required String source,
  String note = '',
}) {
  final warnings = <String>[];
  final lines = const LineSplitter().convert(csv).where((l) => l.trim().isNotEmpty).toList();
  if (lines.isEmpty) throw const FormatException('пустой CSV');
  final header = lines.first.split(',').map((e) => e.trim().toLowerCase()).toList();
  final iRef = header.indexOf('ref'), iLen = header.indexOf('length_km'), iPrice = header.indexOf('price_eur');
  if (iRef < 0 || iLen < 0 || iPrice < 0) {
    throw const FormatException('в заголовке должны быть колонки: ref, length_km, price_eur');
  }
  final sumLen = <String, double>{}, sumPrice = <String, double>{};
  var sections = 0;
  for (var n = 1; n < lines.length; n++) {
    final cols = lines[n].split(',').map((e) => e.trim()).toList();
    final len = double.tryParse(cols.length > iLen ? cols[iLen].replaceAll(',', '.') : '');
    final price = double.tryParse(cols.length > iPrice ? cols[iPrice].replaceAll(',', '.') : '');
    if (len == null || price == null || len <= 0 || price < 0) {
      warnings.add('строка ${n + 1}: пропущена (некорректные длина или цена): ${lines[n]}');
      continue;
    }
    final ref = cols.length > iRef ? cols[iRef] : '';
    sumLen[ref] = (sumLen[ref] ?? 0) + len;
    sumPrice[ref] = (sumPrice[ref] ?? 0) + price;
    sections++;
  }
  if (sections == 0) throw const FormatException('нет ни одной корректной строки');
  final rules = <Map<String, Object>>[];
  for (final ref in sumLen.keys.where((r) => r.isNotEmpty).toList()..sort()) {
    rules.add({'refs': [ref], 'perKm': double.parse((sumPrice[ref]! / sumLen[ref]!).toStringAsFixed(5))});
  }
  final noRef = sumLen[''];
  if (noRef != null) rules.add({'perKm': double.parse((sumPrice['']! / noRef).toStringAsFixed(5))});
  final out = {
    'schema': 1,
    'operator': operator,
    if (aliases.isNotEmpty) 'aliases': aliases,
    'country': country,
    'updated': updated,
    'source': source,
    if (note.isNotEmpty) 'note': note,
    'rules': rules,
  };
  return TariffImportResult(const JsonEncoder.withIndent('  ').convert(out), warnings, sections);
}
