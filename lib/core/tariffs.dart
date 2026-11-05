import 'dart:convert';

/// Тарифы платных дорог из официальных данных операторов.
///
/// Файл тарифов (assets/tariffs/*.json) описывает одного оператора:
/// ```json
/// {
///   "schema": 1,
///   "operator": "Название оператора",
///   "aliases": ["значения тега operator в OpenStreetMap"],
///   "country": "FR",
///   "updated": "2026-08-02",
///   "source": "https://…",
///   "rules": [
///     {"refs": ["A6", "A7"], "perKm": 0.1012},   // ставка для дорог с этими номерами (тег ref)
///     {"perKm": 0.09}                             // ставка оператора по умолчанию
///   ]
/// }
/// ```
/// Ставка `perKm` — €/км для легкового авто, посчитанная как (цена участка ÷ длина участка).
class TariffRule {
  final String operator, country, updated, source;
  final String? ref; // null — правило оператора по умолчанию
  final double perKm;
  const TariffRule(this.operator, this.country, this.updated, this.source, this.ref, this.perKm);
}

String _norm(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');

/// Значения тега из OSM: «A6;E15» → [a6, e15]; «APRR; Vinci» → [aprr, vinci].
List<String> splitTag(String v) => [
      for (final p in v.split(RegExp(r'[;,]')))
        if (_norm(p).isNotEmpty) _norm(p)
    ];

class TariffBook {
  final List<TariffRule> rules;
  // индекс: «оператор|ref» и «оператор|» (по умолчанию)
  final Map<String, TariffRule> _index = {};
  final Map<int, TariffRule?> _cache = {};

  TariffBook(this.rules) {
    for (final r in rules) {
      _index.putIfAbsent('${_norm(r.operator)}|${r.ref == null ? '' : _norm(r.ref!)}', () => r);
    }
  }

  static final empty = TariffBook(const []);

  bool get isEmpty => rules.isEmpty;

  /// Разбор файлов тарифов (JSON-текстов). Некорректные файлы и правила пропускаются, ошибки — в [errors].
  static TariffBook parse(Iterable<String> files, {List<String>? errors}) {
    final rules = <TariffRule>[];
    for (final text in files) {
      try {
        final j = jsonDecode(text) as Map<String, dynamic>;
        if (j['schema'] != 1) throw const FormatException('неизвестная версия схемы (ожидается schema: 1)');
        final op = (j['operator'] as String).trim();
        final aliases = {op, ...((j['aliases'] as List?)?.cast<String>() ?? const <String>[])};
        final country = (j['country'] as String?) ?? '';
        final updated = (j['updated'] as String?) ?? '';
        final source = (j['source'] as String?) ?? '';
        for (final r in (j['rules'] as List)) {
          final perKm = (r['perKm'] as num).toDouble();
          if (!(perKm > 0 && perKm < 5)) throw FormatException('perKm вне допустимого диапазона: $perKm');
          final refs = (r['refs'] as List?)?.cast<String>();
          for (final alias in aliases) {
            if (refs == null || refs.isEmpty) {
              rules.add(TariffRule(alias, country, updated, source, null, perKm));
            } else {
              for (final ref in refs) {
                rules.add(TariffRule(alias, country, updated, source, ref, perKm));
              }
            }
          }
        }
      } catch (e) {
        errors?.add('$e');
      }
    }
    return TariffBook(rules);
  }

  /// Ставка для дороги с тегами operator/ref или null, если оператора нет в таблице.
  /// Сначала ищется точное совпадение «оператор + ref», затем ставка оператора по умолчанию.
  TariffRule? match(String operatorTag, String refTag) {
    if (rules.isEmpty || operatorTag.isEmpty) return null;
    final ops = splitTag(operatorTag), refs = splitTag(refTag);
    for (final op in ops) {
      for (final ref in refs) {
        final r = _index['$op|$ref'];
        if (r != null) return r;
      }
    }
    for (final op in ops) {
      final r = _index['$op|'];
      if (r != null) return r;
    }
    return null;
  }

  /// То же с кэшем по индексам строк графа (вызывается для каждого платного ребра).
  TariffRule? matchCached(int opIdx, int refIdx, String Function() op, String Function() ref) {
    final key = opIdx * 4194304 + refIdx;
    if (_cache.containsKey(key)) return _cache[key];
    return _cache[key] = match(op(), ref());
  }
}
