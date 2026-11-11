import 'package:cargo_navigation/core/geo.dart';
import 'package:cargo_navigation/core/road_graph.dart';
import 'package:cargo_navigation/core/route_data.dart';
import 'package:cargo_navigation/core/router.dart';
import 'package:cargo_navigation/engine/demo_source.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Set<String> names(RoadGraph g, RouteResult r) => {for (final e in r.edges) g.edgeName(e)};

/// Магистраль и параллельная главная дорога длиной [steps]×0,1° на широте 48,2° начиная с [lon0].
List<WaySpec> pair(double lon0, int steps, {Map<String, String> motorTags = const {}, double lat = 48.2}) {
  final motor = [for (var i = 0; i <= steps; i++) (100 + i, lat, lon0 + 0.1 * i)];
  return [
    WaySpec(1, {'highway': 'motorway', 'maxspeed': '130', 'name': 'Магистраль', ...motorTags}, motor),
    WaySpec(2, {'highway': 'primary', 'maxspeed': '80', 'name': 'Главная'},
        [motor.first, (201, lat + 0.03, lon0 + 0.05 * steps), motor.last]),
  ];
}

void main() {
  final g = graphOf(demoSpecs());

  test('parseMaxspeed', () {
    expect(parseMaxspeed('50'), 50);
    expect(parseMaxspeed('60 mph'), 97);
    expect(parseMaxspeed('RU:urban'), 60);
    expect(parseMaxspeed('none'), 130);
    expect(parseMaxspeed(null), isNull);
  });

  test('односторонние дороги и разбиение на рёбра', () {
    final gg = graphOf([
      const WaySpec(1, {'highway': 'residential', 'oneway': 'yes'}, [(1, 47.0, 3.0), (2, 47.0, 3.01), (3, 47.0, 3.02)]),
    ]);
    expect(gg.edgeCount, 1);
    expect(gg.ptStart[1] - gg.ptStart[0], 3);
    expect(gg.edgeCountry(0), 'FR');
  });

  test('Франция: плата за км по тарифу оператора; есть бесплатная альтернатива', () {
    final res = planRoutes(g, demoStart, demoEnd, tolls);
    expect(res.routes, isNotNull, reason: res.error);
    final main = res.routes!.first;
    expect(main.tags, containsAll(['best', 'fastest']));
    expect(names(g, main), contains('Платная магистраль (демо)'));
    // ~60,7 км × 0,112 €/км (тариф APRR)
    expect(main.distanceToll, closeTo(6.8, 0.2));
    expect(main.tollOperatorMeters, closeTo(main.tollMeters, 1));
    expect(main.vignettes, isEmpty);
    expect(main.money, main.distanceToll);
    final free = res.routes!.firstWhere((r) => r.tags.contains('free'));
    expect(free.money, 0);
    expect(free.hours, greaterThan(main.hours));
    expect(names(g, free), contains('Шоссе Северное'));
  });

  test('без оператора в таблице — средняя ставка страны', () {
    final gg = graphOf(pair(3.0, 8, motorTags: {'toll': 'yes'}, lat: 47.0));
    final r = planRoutes(gg, const LatLon(47.0, 3.0), const LatLon(47.0, 3.8), tolls).routes!.first;
    expect(r.distanceToll, greaterThan(0));
    expect(r.tollOperatorMeters, 0);
  });

  test('Австрия: виньетка — разовая плата, длинный путь идёт по магистрали', () {
    final gg = graphOf(pair(14.0, 10));
    final res = planRoutes(gg, const LatLon(48.2, 14.0), const LatLon(48.2, 15.0), tolls);
    final main = res.routes!.first;
    expect(names(gg, main), contains('Магистраль'));
    expect(main.vignettes.map((v) => v.iso), ['AT']);
    expect(main.money, closeTo(9.60, 1e-9));
    expect(main.distanceToll, 0);
    expect(res.routes!.any((r) => r.tags.contains('free') && r.money == 0), isTrue);
  });

  test('Австрия: ради короткого участка виньетка не покупается — приоритет бесплатной дороги', () {
    final gg = graphOf(pair(14.0, 2));
    final main = planRoutes(gg, const LatLon(48.2, 14.0), const LatLon(48.2, 14.2), tolls).routes!.first;
    expect(names(gg, main), isNot(contains('Магистраль')));
    expect(main.money, 0);
  });

  test('виньетка одной страны считается один раз, даже если на магистраль въезжают дважды', () {
    final a = [for (var i = 0; i <= 5; i++) (100 + i, 48.2, 14.0 + 0.1 * i)];
    final b = [for (var i = 0; i <= 5; i++) (200 + i, 48.2, 14.6 + 0.1 * i)];
    final gg = graphOf([
      WaySpec(1, {'highway': 'motorway', 'maxspeed': '130', 'name': 'M1'}, a),
      WaySpec(2, {'highway': 'primary', 'maxspeed': '80', 'name': 'Связка'}, [a.last, b.first]),
      WaySpec(3, {'highway': 'motorway', 'maxspeed': '130', 'name': 'M2'}, b),
    ]);
    final r = planRoutes(gg, const LatLon(48.2, 14.0), const LatLon(48.2, 15.1), tolls).routes!.first;
    expect(names(gg, r), containsAll(['M1', 'M2']));
    expect(r.vignettes.length, 1);
    expect(r.money, closeTo(9.60, 1e-9));
  });

  test('Германия: магистрали бесплатны; платный объект без цены помечается', () {
    final gg = graphOf(pair(10.0, 5, motorTags: {'toll': 'yes'}, lat: 50.0));
    final r = planRoutes(gg, const LatLon(50.0, 10.0), const LatLon(50.0, 10.5), tolls).routes!.first;
    expect(r.money, 0);
    expect(r.tollUnknownMeters, greaterThan(1000));
  });

  test('Италия: официальный тариф Autostrade per l\'Italia по оператору, A22 — по номеру дороги', () {
    final aspi = graphOf(pair(10.9, 4, motorTags: {'toll': 'yes', 'operator': "Autostrade per l'Italia S.p.A.", 'ref': 'A1'}, lat: 44.6));
    final r = planRoutes(aspi, const LatLon(44.6, 10.9), const LatLon(44.6, 11.3), tolls).routes!
        .firstWhere((r) => r.distanceToll > 0);
    expect(r.distanceToll / (r.tollMeters / 1000), closeTo(0.07869, 1e-5));
    expect(r.tollOperatorMeters, closeTo(r.tollMeters, 1));

    // у A22 оператор в данных не указан — ставка находится по номеру дороги
    final a22 = graphOf(pair(11.0, 4, motorTags: {'toll': 'yes', 'ref': 'A22;E45'}, lat: 45.9));
    final b = planRoutes(a22, const LatLon(45.9, 11.0), const LatLon(45.9, 11.4), tolls).routes!
        .firstWhere((r) => r.distanceToll > 0);
    expect(b.distanceToll / (b.tollMeters / 1000), closeTo(0.07002, 1e-5));

    // прочие итальянские автострады — средняя ставка страны (оценка)
    final other = graphOf(pair(10.9, 4, motorTags: {'toll': 'yes', 'ref': 'A99'}, lat: 44.6));
    final c = planRoutes(other, const LatLon(44.6, 10.9), const LatLon(44.6, 11.3), tolls).routes!
        .firstWhere((r) => r.distanceToll > 0);
    expect(c.tollOperatorMeters, 0);
  });

  test('Бельгия и Нидерланды: магистрали бесплатны, платный тоннель — фиксированная цена один раз', () {
    // магистраль — тоннель (два пути подряд) — магистраль; объезд по главной дороге
    List<WaySpec> net(double lat, double lon, Map<String, String> tunnel) {
      final n = [for (var i = 0; i <= 6; i++) (100 + i, lat, lon + 0.05 * i)];
      return [
        WaySpec(1, {'highway': 'motorway', 'maxspeed': '120', 'name': 'Запад'}, n.sublist(0, 3)),
        WaySpec(2, {'highway': 'motorway', 'maxspeed': '100', 'toll': 'yes', ...tunnel}, n.sublist(2, 4)),
        WaySpec(3, {'highway': 'motorway', 'maxspeed': '100', 'toll': 'yes', ...tunnel}, n.sublist(3, 5)),
        WaySpec(4, {'highway': 'motorway', 'maxspeed': '120', 'name': 'Восток'}, n.sublist(4)),
        WaySpec(5, {'highway': 'primary', 'maxspeed': '50', 'name': 'Объезд'}, [n.first, (201, lat + 0.25, lon + 0.15), n.last]),
      ];
    }

    final be = graphOf(net(51.3, 4.2, {'name': 'Liefkenshoektunnel', 'ref': 'R2'}));
    final res = planRoutes(be, const LatLon(51.3, 4.2), const LatLon(51.3, 4.5), tolls);
    final viaTunnel = res.routes!.firstWhere((r) => r.objects.isNotEmpty);
    expect(viaTunnel.objects.single.name, contains('Лифкенсхук'));
    expect(viaTunnel.money, closeTo(6.20, 1e-9), reason: 'одна плата, хотя тоннель состоит из двух путей');
    expect(viaTunnel.distanceToll, 0);
    expect(viaTunnel.tollUnknownMeters, 0);
    expect(res.routes!.any((r) => r.money == 0 && r.tags.contains('free')), isTrue);

    final nl = graphOf(net(51.9, 4.2, {'name': 'Blankenburgverbinding', 'ref': 'A24'}));
    final a24 = planRoutes(nl, const LatLon(51.9, 4.2), const LatLon(51.9, 4.5), tolls).routes!
        .firstWhere((r) => r.objects.isNotEmpty);
    expect(a24.money, closeTo(1.57, 1e-9));

    // обычная магистраль без платных объектов — бесплатно и без предупреждений
    final free = graphOf(pair(4.2, 6, lat: 51.3));
    final f = planRoutes(free, const LatLon(51.3, 4.2), const LatLon(51.3, 4.8), tolls).routes!.first;
    expect(f.money, 0);
    expect(f.tollUnknownMeters, 0);
  });

  test('дороги в странах вне ЕС отбрасываются', () {
    // прямая дорога через Швейцарию и объезд по Германии/Австрии… проверяем только отбрасывание
    final gg = graphOf([
      const WaySpec(1, {'highway': 'motorway', 'name': 'Через Берн'}, [(1, 46.95, 7.3), (2, 46.95, 7.45), (3, 46.95, 7.6)]),
      const WaySpec(2, {'highway': 'motorway', 'name': 'Франция'}, [(4, 47.0, 3.0), (5, 47.0, 3.1)]),
    ]);
    expect(gg.droppedNonEu, greaterThan(0));
    expect({for (var e = 0; e < gg.edgeCount; e++) gg.edgeName(e)}, {'Франция'});
    // узлы отброшенных рёбер не выбираются как ближайшие
    expect(gg.nearestNodes(46.95, 7.45), isEmpty);
  });

  test('лимит на магистрали без maxspeed берётся по стране', () {
    final pl = graphOf([const WaySpec(1, {'highway': 'motorway'}, [(1, 52.0, 19.0), (2, 52.0, 19.1)])]);
    expect(pl.speed[0], 140);
    final es = graphOf([const WaySpec(1, {'highway': 'motorway'}, [(1, 40.0, -3.5), (2, 40.0, -3.4)])]);
    expect(es.speed[0], 120);
    final tagged = graphOf([const WaySpec(1, {'highway': 'motorway', 'maxspeed': '100'}, [(1, 52.0, 19.0), (2, 52.0, 19.1)])]);
    expect(tagged.speed[0], 100);
  });

  test('точка вдали от дорог — понятная ошибка', () {
    expect(planRoutes(g, const LatLon(40, 0), demoEnd, tolls).error, isNotNull);
  });

  test('пошаговые инструкции и данные маршрута', () {
    final res = planRoutes(g, demoStart, demoEnd, tolls);
    final data = buildRouteData(res.ctx!, res.routes!.first);
    expect(data.steps.first.text, startsWith('Начните движение'));
    expect(data.steps.last.type, TurnType.arrive);
    expect(data.steps.any((s) => s.toll), isTrue);
    expect(data.edgeStartPt.length, data.edgeCount + 1);
    expect(data.edgeStartPt.last, data.pointCount - 1);
    expect(data.edgeToll.contains(1), isTrue);
    expect(data.estimated, isFalse, reason: 'тариф оператора — не оценка');
  });
}
