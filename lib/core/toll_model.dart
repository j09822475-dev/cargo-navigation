import 'dart:convert';

import 'tariffs.dart';

enum TollScheme { free, vignette, distance }

/// Как страна берёт плату с легковых авто.
class CountryToll {
  final String iso;
  final TollScheme scheme;
  final double priceEur; // виньетка: цена самого короткого срока
  final String product; // «1 день», «7 дней»
  final Set<int> classes; // классы дорог, где нужна виньетка
  final double perKm; // плата за км (distance)
  final bool confirmed; // false — источники расходятся или это оценка
  final String source;

  /// Ставки €/км для отдельных дорог по номеру (тег ref), когда оператор в OSM не указан.
  final Map<String, double> refRates;
  const CountryToll(this.iso, this.scheme, this.priceEur, this.product, this.classes, this.perKm, this.confirmed, this.source,
      {this.refRates = const {}});

  /// Ставка по номеру дороги («A22;E45» → ставка A22) или null.
  double? rateForRef(String refTag) {
    if (refRates.isEmpty || refTag.isEmpty) return null;
    for (final r in splitTag(refTag)) {
      final v = refRates[r];
      if (v != null) return v;
    }
    return null;
  }
}

/// Платный объект с фиксированной ценой за проезд (тоннель, мост).
class TollObject {
  final String country, name, source;
  final List<String> match; // подстроки названия дороги в OSM (в нижнем регистре)
  final Set<String> refs; // либо номер дороги
  final double priceEur;
  final bool confirmed;
  const TollObject(this.country, this.name, this.match, this.refs, this.priceEur, this.confirmed, this.source);

  bool matches(String nameTag, String refTag) {
    final n = nameTag.toLowerCase();
    if (match.any(n.contains)) return true;
    return refs.isNotEmpty && splitTag(refTag).any(refs.contains);
  }
}

/// Все цены платных дорог: схемы по странам (assets/tariffs/countries.json) и тарифы операторов.
class TollModel {
  final Map<String, CountryToll> countries;
  final TariffBook operators;
  final List<TollObject> objects;
  const TollModel(this.countries, this.operators, {this.objects = const []});

  static final empty = TollModel(const {}, TariffBook.empty);

  CountryToll? of(String iso) => countries[iso];

  static TollModel parse(String countriesJson, Iterable<String> operatorFiles, {List<String>? errors}) {
    final map = <String, CountryToll>{};
    final objects = <TollObject>[];
    try {
      final j = jsonDecode(countriesJson) as Map<String, dynamic>;
      if (j['schema'] != 1) throw const FormatException('countries.json: неизвестная версия схемы');
      (j['countries'] as Map<String, dynamic>).forEach((iso, v) {
        try {
          final scheme = TollScheme.values.firstWhere((s) => s.name == v['scheme']);
          final price = (v['priceEur'] as num?)?.toDouble() ?? 0;
          final perKm = (v['perKm'] as num?)?.toDouble() ?? 0;
          if (scheme == TollScheme.vignette && !(price > 0 && price < 200)) throw FormatException('цена виньетки $price');
          if (scheme == TollScheme.distance && !(perKm > 0 && perKm < 5)) throw FormatException('ставка $perKm');
          map[iso] = CountryToll(
            iso,
            scheme,
            price,
            (v['product'] as String?) ?? '',
            ((v['classes'] as List?)?.cast<int>() ?? const <int>[0]).toSet(),
            perKm,
            v['confirmed'] == true,
            (v['source'] as String?) ?? '',
            refRates: {
              for (final e in ((v['refRates'] as Map?) ?? const {}).entries)
                splitTag(e.key as String).first: (e.value as num).toDouble(),
            },
          );
        } catch (e) {
          errors?.add('$iso: $e');
        }
      });
      for (final o in (j['objects'] as List?) ?? const []) {
        try {
          final price = (o['priceEur'] as num).toDouble();
          if (!(price > 0 && price < 200)) throw FormatException('цена объекта $price');
          objects.add(TollObject(
            o['country'] as String,
            o['name'] as String,
            [for (final m in (o['match'] as List?) ?? const []) (m as String).toLowerCase()],
            {for (final r in (o['refs'] as List?) ?? const []) splitTag(r as String).first},
            price,
            o['confirmed'] == true,
            (o['source'] as String?) ?? '',
          ));
        } catch (e) {
          errors?.add('объект: $e');
        }
      }
    } catch (e) {
      errors?.add('$e');
    }
    return TollModel(map, TariffBook.parse(operatorFiles, errors: errors), objects: objects);
  }
}
