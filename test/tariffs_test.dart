import 'dart:convert';
import 'dart:io';

import 'package:cargo_navigation/core/geo.dart';
import 'package:cargo_navigation/core/prefs.dart';
import 'package:cargo_navigation/core/road_graph.dart';
import 'package:cargo_navigation/core/router.dart';
import 'package:cargo_navigation/core/tariff_import.dart';
import 'package:cargo_navigation/core/tariffs.dart';
import 'package:cargo_navigation/engine/demo_source.dart';
import 'package:cargo_navigation/engine/engine.dart';
import 'package:flutter_test/flutter_test.dart';

// Всё ниже — СИНТЕТИЧЕСКИЕ тестовые данные («TestOp»), не реальные тарифы.
String fixture({double a1 = 0.20, double fallback = 0.05, int schema = 1}) => jsonEncode({
      'schema': schema,
      'operator': 'Test Operator',
      'aliases': ['TestOp', 'TO'],
      'country': 'XX',
      'updated': '2000-01-01',
      'source': 'test://fixture',
      'rules': [
        {'refs': ['A1', 'E15'], 'perKm': a1},
        {'perKm': fallback},
      ],
    });

void main() {
  group('TariffBook', () {
    test('ставка по оператору и ref, затем по умолчанию оператора', () {
      final b = TariffBook.parse([fixture()]);
      expect(b.match('TestOp', 'A1')!.perKm, 0.20);
      expect(b.match('testop', ' a 1 ')!.perKm, 0.20, reason: 'регистр и пробелы не важны');
      expect(b.match('TestOp', 'A9')!.perKm, 0.05, reason: 'ставка оператора по умолчанию');
      expect(b.match('TestOp', '')!.perKm, 0.05);
      expect(b.match('Other', 'A1'), isNull, reason: 'чужой оператор');
      expect(b.match('', 'A1'), isNull, reason: 'без оператора тариф не применяется');
    });

    test('значения тегов через «;» и псевдонимы оператора', () {
      final b = TariffBook.parse([fixture()]);
      expect(b.match('Foo;TO', 'X1;E15')!.perKm, 0.20);
      expect(splitTag('A6;E15, A7'), ['a6', 'e15', 'a7']);
    });

    test('некорректные файлы и ставки пропускаются с сообщением об ошибке', () {
      final errors = <String>[];
      final b = TariffBook.parse([fixture(schema: 2), '{не json', fixture(a1: 99), fixture()], errors: errors);
      expect(errors.length, 3);
      expect(b.match('TestOp', 'A1')!.perKm, 0.20, reason: 'корректный файл загружен');
      expect(TariffBook.parse(const []).isEmpty, isTrue);
    });
  });

  group('расчёт с тарифами', () {
    RoadGraph graph({String op = 'TestOp'}) => RoadGraph.build([
          waysFromSpecs([
            WaySpec(1, {'highway': 'motorway', 'toll': 'yes', 'maxspeed': '110', 'operator': op, 'ref': 'A1', 'name': 'Т'},
                [(1, 50.0, 10.0), (2, 50.0, 10.5)]),
          ])
        ]);
    const a = LatLon(50.0, 10.0), b = LatLon(50.0, 10.5);

    test('тариф оператора заменяет ставку из настроек и помечает участок как «по тарифу»', () {
      final g = graph();
      final withTariff = planRoutes(g, a, b, RoutePrefs(), tariffs: TariffBook.parse([fixture()]));
      final r = withTariff.routes!.first;
      expect(r.tollCost, closeTo(r.tollMeters / 1000 * 0.20, 1e-6));
      expect(r.tollKnownMeters, closeTo(r.tollMeters, 1e-6));

      final noTariff = planRoutes(g, a, b, RoutePrefs()).routes!.first;
      expect(noTariff.tollCost, closeTo(noTariff.tollMeters / 1000 * 0.10, 1e-6), reason: 'ставка из настроек');
      expect(noTariff.tollKnownMeters, 0);
    });

    test('оператор без тарифа — ставка из настроек', () {
      final r = planRoutes(graph(op: 'Unknown'), a, b, RoutePrefs(), tariffs: TariffBook.parse([fixture()])).routes!.first;
      expect(r.tollKnownMeters, 0);
      expect(r.tollCost, closeTo(r.tollMeters / 1000 * 0.10, 1e-6));
    });

    test('движок передаёт тарифы в расчёт', () async {
      final engine = RoutingEngine(DemoSource(), tariffs: TariffBook.parse([
        jsonEncode({
          'schema': 1,
          'operator': 'Демо',
          'aliases': ['Демо-оператор'],
          'country': 'XX',
          'rules': [{'perKm': 0.5}],
        })
      ]));
      // в демо-сети у платной магистрали нет тега operator → тариф не применяется, остаётся ставка из настроек
      final out = await engine.plan(demoStart, demoEnd, RoutePrefs());
      final toll = out.routes!.firstWhere((r) => r.tollCost > 0);
      expect(toll.tollKnownMeters, 0);
      expect(toll.tollCost, closeTo(toll.tollMeters / 1000 * 0.10, 0.05));
    });
  });

  group('импорт из CSV', () {
    const csv = 'ref,length_km,price_eur\nA1,10,2.0\nA1,30,6.0\nA2,20,1.0\n,10,0.5\n';

    test('ставка = сумма цен ÷ сумма длин по ref, участки без ref — ставка по умолчанию', () {
      final r = buildTariffJson(csv, operator: 'Оп', country: 'XX', updated: '2000-01-01', source: 's', aliases: ['OpTag']);
      expect(r.sections, 4);
      final book = TariffBook.parse([r.json]);
      expect(book.match('OpTag', 'A1')!.perKm, closeTo(0.2, 1e-9));
      expect(book.match('OpTag', 'A2')!.perKm, closeTo(0.05, 1e-9));
      expect(book.match('Оп', 'A7')!.perKm, closeTo(0.05, 1e-9));
    });

    test('некорректные строки пропускаются с предупреждением, а пустой/неверный CSV — ошибка', () {
      final r = buildTariffJson('ref,length_km,price_eur\nA1,10,2\nA1,abc,3\nA1,-5,1\n', operator: 'Оп', country: 'XX', updated: 'u', source: 's');
      expect(r.sections, 1);
      expect(r.warnings.length, 2);
      expect(() => buildTariffJson('', operator: 'Оп', country: 'XX', updated: 'u', source: 's'), throwsFormatException);
      expect(() => buildTariffJson('a,b\n1,2', operator: 'Оп', country: 'XX', updated: 'u', source: 's'), throwsFormatException);
      expect(() => buildTariffJson('ref,length_km,price_eur\nA1,x,y', operator: 'Оп', country: 'XX', updated: 'u', source: 's'), throwsFormatException);
    });
  });

  group('реальные файлы тарифов в assets/tariffs', () {
    final index = jsonDecode(File('assets/tariffs/index.json').readAsStringSync()) as Map<String, dynamic>;
    final names = (index['files'] as List).cast<String>();

    test('все файлы из index.json существуют и корректно разбираются', () {
      expect(names, isNotEmpty);
      final errors = <String>[];
      final book = TariffBook.parse([for (final n in names) File('assets/tariffs/$n').readAsStringSync()], errors: errors);
      expect(errors, isEmpty);
      expect(book.isEmpty, isFalse);
      for (final r in book.rules) {
        expect(r.perKm, inInclusiveRange(0.03, 0.6), reason: '${r.operator}: ставка вне разумного диапазона');
        expect(r.source, startsWith('https://'), reason: 'у каждого тарифа должен быть источник');
        expect(r.updated, isNotEmpty);
      }
    });

    test('AREA (Франция): ставка из данных APRR, чужие операторы не затронуты', () {
      final book = TariffBook.parse([for (final n in names) File('assets/tariffs/$n').readAsStringSync()]);
      final area = book.match('AREA', 'A41');
      expect(area, isNotNull);
      expect(area!.country, 'FR');
      expect(area.perKm, closeTo(0.132, 0.001), reason: 'взвешенная средняя ставка класса 1 по файлу AREA за 2026-02');
      expect(book.match('Autoroutes Rhône-Alpes', ''), isNotNull);
      expect(book.match('APRR', 'A6'), isNull, reason: 'ставка AREA не распространяется на остальную сеть APRR');
      expect(book.match('Vinci', 'A7'), isNull);
    });
  });
}
