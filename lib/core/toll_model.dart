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
  const CountryToll(this.iso, this.scheme, this.priceEur, this.product, this.classes, this.perKm, this.confirmed, this.source);
}

/// Все цены платных дорог: схемы по странам (assets/tariffs/countries.json) и тарифы операторов.
class TollModel {
  final Map<String, CountryToll> countries;
  final TariffBook operators;
  const TollModel(this.countries, this.operators);

  static final empty = TollModel(const {}, TariffBook.empty);

  CountryToll? of(String iso) => countries[iso];

  static TollModel parse(String countriesJson, Iterable<String> operatorFiles, {List<String>? errors}) {
    final map = <String, CountryToll>{};
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
          );
        } catch (e) {
          errors?.add('$iso: $e');
        }
      });
    } catch (e) {
      errors?.add('$e');
    }
    return TollModel(map, TariffBook.parse(operatorFiles, errors: errors));
  }
}
