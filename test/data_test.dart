import 'dart:io';

import 'package:cargo_navigation/core/tariff_import.dart';
import 'package:cargo_navigation/core/tariffs.dart';
import 'package:cargo_navigation/core/toll_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('границы стран', () {
    test('страны ЕС и не ЕС определяются по точке', () {
      String? iso(double la, double lo) => countries.isoAt(la, lo);
      expect(iso(48.85, 2.35), 'FR');
      expect(iso(52.5, 13.4), 'DE');
      expect(iso(48.2, 16.37), 'AT');
      expect(iso(45.8, 15.97), 'HR');
      expect(iso(28.3, -16.5), 'ES', reason: 'Канары — ЕС');
      expect(iso(46.95, 7.45), 'CH');
      expect(iso(45.0, -20.0), isNull, reason: 'океан');
      expect(countries.eu[countries.indexOf('FR')], isTrue);
      expect(countries.eu[countries.indexOf('CH')], isFalse);
      expect(countries.eu.where((e) => e).length, 27);
    });

    test('«уверенно вне ЕС» имеет запас у границы', () {
      expect(countries.isDeepNonEu(46.95, 7.45), isTrue); // Берн
      expect(countries.isDeepNonEu(51.5, -0.1), isTrue); // Лондон
      expect(countries.isDeepNonEu(44.8, 20.45), isTrue); // Белград
      expect(countries.isDeepNonEu(54.7, 20.5), isTrue); // Калининград
      expect(countries.isDeepNonEu(46.19, 6.24), isFalse); // Анмас (Франция, у Женевы)
      expect(countries.isDeepNonEu(47.59, 7.56), isFalse); // Сен-Луи (Франция, у Базеля)
      expect(countries.isDeepNonEu(59.37, 28.18), isFalse); // Нарва (Эстония)
      expect(countries.isDeepNonEu(43.735, 7.42), isFalse); // Монако не блокирует проезд
    });

    test('поиск страны достаточно быстр для графа', () {
      final sw = Stopwatch()..start();
      var n = 0;
      // 200 тыс. точек вдоль «дороги» Лион → Вена, как при построении графа
      for (var i = 0; i < 200000; i++) {
        final t = i / 200000;
        if (countries.countryAt(45.75 + t * 2.45, 4.85 + t * 11.5) >= 0) n++;
      }
      expect(n, greaterThan(150000));
      expect(sw.elapsedMilliseconds, lessThan(3000));
    });
  });

  group('тарифы стран', () {
    test('файл разбирается без ошибок; схемы и цены в разумных пределах', () {
      final errors = <String>[];
      final m = TollModel.parse(File('assets/tariffs/countries.json').readAsStringSync(), operatorFiles(), errors: errors);
      expect(errors, isEmpty);
      for (final iso in ['AT', 'CZ', 'SK', 'SI', 'HU', 'RO', 'BG']) {
        final c = m.of(iso)!;
        expect(c.scheme, TollScheme.vignette, reason: iso);
        expect(c.priceEur, inInclusiveRange(3, 20), reason: iso);
        expect(c.product, isNotEmpty);
        expect(c.source, startsWith('https://'));
      }
      for (final iso in ['FR', 'IT', 'ES', 'PT', 'HR', 'GR', 'PL']) {
        final c = m.of(iso)!;
        expect(c.scheme, TollScheme.distance, reason: iso);
        expect(c.perKm, inInclusiveRange(0.03, 0.2), reason: iso);
        expect(c.confirmed, isFalse, reason: 'средние ставки — оценка');
      }
      expect(m.of('DE'), isNull, reason: 'Германия — бесплатно');
      expect(m.of('AT')!.priceEur, 9.60);
      expect(m.of('SK')!.priceEur, 8.10);
      expect(m.of('SI')!.priceEur, 16.00);
      expect(m.of('RO')!.confirmed, isFalse);
      expect(m.of('BG')!.confirmed, isFalse);
    });

    test('ошибки в файле не роняют разбор', () {
      final errors = <String>[];
      final m = TollModel.parse('{"schema":1,"countries":{"AT":{"scheme":"vignette","priceEur":-1},"SK":{"scheme":"vignette","priceEur":8.1}}}', const [], errors: errors);
      expect(errors.length, 1);
      expect(m.of('AT'), isNull);
      expect(m.of('SK'), isNotNull);
      expect(TollModel.parse('не json', const [], errors: errors).countries, isEmpty);
    });
  });

  group('тарифы операторов', () {
    final book = TariffBook.parse(operatorFiles());
    test('AREA и APRR: ставки из открытых данных, у каждого своя', () {
      expect(book.match('AREA', 'A41')!.perKm, closeTo(0.132, 0.001));
      expect(book.match('APRR', 'A6')!.perKm, closeTo(0.112, 0.001));
      expect(book.match('Autoroutes Paris-Rhin-Rhône', 'A31'), isNotNull);
      expect(book.match('Vinci', 'A7'), isNull);
      expect(book.match('', 'A6'), isNull);
      for (final r in book.rules) {
        expect(r.perKm, inInclusiveRange(0.03, 0.6));
        expect(r.source, startsWith('https://'));
      }
    });

    test('импорт из CSV', () {
      final r = buildTariffJson('ref,length_km,price_eur\nA1,10,2.0\nA1,30,6.0\n,10,0.5\nA1,abc,3\n',
          operator: 'Оп', country: 'XX', updated: '2000-01-01', source: 's', aliases: ['OpTag']);
      expect(r.sections, 3);
      expect(r.warnings.length, 1);
      final b = TariffBook.parse([r.json]);
      expect(b.match('OpTag', 'A1')!.perKm, closeTo(0.2, 1e-9));
      expect(b.match('Оп', 'A7')!.perKm, closeTo(0.05, 1e-9));
      expect(() => buildTariffJson('', operator: 'Оп', country: 'XX', updated: 'u', source: 's'), throwsFormatException);
    });
  });
}
