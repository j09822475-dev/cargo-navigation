import 'package:cargo_navigation/core/geo.dart';
import 'package:cargo_navigation/core/prefs.dart';
import 'package:cargo_navigation/core/road_graph.dart';
import 'package:cargo_navigation/core/route_data.dart';
import 'package:cargo_navigation/core/router.dart';
import 'package:cargo_navigation/engine/demo_source.dart';
import 'package:flutter_test/flutter_test.dart';

RoadGraph demoGraph() => RoadGraph.build([waysFromSpecs(demoSpecs())]);

PlanResult plan(RoadGraph g, RoutePrefs p) => planRoutes(g, demoStart, demoEnd, p);

Set<String> names(RoadGraph g, RouteResult r) => {for (final e in r.edges) g.edgeName(e)};

void main() {
  final g = demoGraph();

  test('parseMaxspeed', () {
    expect(parseMaxspeed('50'), 50);
    expect(parseMaxspeed('60 mph'), 97);
    expect(parseMaxspeed('RU:urban'), 60);
    expect(parseMaxspeed('none'), 130);
    expect(parseMaxspeed(null), isNull);
  });

  test('односторонние дороги и разбиение на рёбра', () {
    final gg = RoadGraph.build([
      waysFromSpecs([
        const WaySpec(1, {'highway': 'residential', 'oneway': 'yes'}, [(1, 0, 0), (2, 0, 0.01), (3, 0, 0.02)]),
      ])
    ]);
    expect(gg.edgeCount, 1);
    expect(gg.ptStart[1] - gg.ptStart[0], 3);
  });

  test('приоритет «дешевле» — бесплатная дорога', () {
    final res = plan(g, RoutePrefs(priority: Priority.cheapest));
    expect(res.routes, isNotNull, reason: res.error);
    expect(res.routes!.first.tollCost, 0);
  });

  test('приоритет «быстрее» — платная магистраль', () {
    final res = plan(g, RoutePrefs(priority: Priority.fastest));
    expect(res.routes!.first.tollCost, greaterThan(0));
    expect(names(g, res.routes!.first), contains('Платная магистраль М-Демо'));
  });

  test('режим «только бесплатные» не использует платные дороги', () {
    final res = plan(g, RoutePrefs(priority: Priority.fastest, tollMode: TollMode.free));
    for (final r in res.routes!) {
      expect(r.tollCost, 0);
    }
  });

  test('режим «предпочитать платные» выбирает магистраль даже при приоритете «дешевле»', () {
    final res = plan(g, RoutePrefs(priority: Priority.cheapest, tollMode: TollMode.prefer));
    expect(res.routes!.first.tollCost, greaterThan(0));
  });

  test('фильтр по типу дорог', () {
    final res = plan(g, RoutePrefs(priority: Priority.fastest, classes: {1, 2, 3, 4, 5, 6, 7}));
    expect(res.routes!.first.tollCost, 0);
    expect(names(g, res.routes!.first), contains('Шоссе Северное'));
  });

  test('фильтр по максимальному лимиту скорости', () {
    final res = plan(g, RoutePrefs(priority: Priority.fastest, maxSpeed: 60));
    expect(names(g, res.routes!.first), isNot(contains('Платная магистраль М-Демо')));
  });

  test('фильтр по минимальному лимиту скорости', () {
    final res = plan(g, RoutePrefs(priority: Priority.cheapest, minSpeed: 60));
    expect(names(g, res.routes!.first), isNot(contains('Южная дорога')));
  });

  test('жилые подъезды у старта/финиша доступны при отключённых жилых улицах', () {
    final res = plan(g, RoutePrefs(classes: {0, 2}));
    expect(res.routes, isNotNull, reason: res.error);
  });

  test('топливо и цена времени не влияют на стоимость: затраты = только платные участки', () {
    final res = plan(g, RoutePrefs(priority: Priority.fastest));
    for (final r in res.routes!) {
      expect(r.money, r.tollCost);
    }
    // тариф 0.10 €/км на ~50 км магистрали ≈ 5 €
    final toll = res.routes!.firstWhere((r) => r.tollCost > 0);
    expect(toll.tollCost, inInclusiveRange(4.5, 5.5));
  });

  test('приоритет «дешевле»: из равных по стоимости — самый быстрый', () {
    final res = plan(g, RoutePrefs(priority: Priority.cheapest, tollMode: TollMode.free));
    final free = res.routes!;
    expect(free.every((r) => r.tollCost == 0), isTrue);
    expect(free.first.hours, lessThanOrEqualTo(free.last.hours + 1e-9));
  });

  test('есть альтернативы: самый быстрый и самый дешёвый', () {
    final res = plan(g, RoutePrefs(priority: Priority.fastest));
    final fast = res.routes!.firstWhere((r) => r.tags.contains('fastest'));
    final cheap = res.routes!.firstWhere((r) => r.tags.contains('cheapest'));
    expect(fast.hours, lessThan(cheap.hours));
    expect(cheap.money, lessThanOrEqualTo(fast.money));
  });

  test('точка вдали от дорог — понятная ошибка', () {
    final res = planRoutes(g, const LatLon(10, 10), demoEnd, RoutePrefs());
    expect(res.error, isNotNull);
  });

  test('пошаговые инструкции', () {
    final res = plan(g, RoutePrefs(priority: Priority.fastest));
    final data = buildRouteData(g, res.routes!.first);
    expect(data.steps.first.text, startsWith('Начните движение'));
    expect(data.steps.last.type, TurnType.arrive);
    expect(data.steps.any((s) => s.toll), isTrue);
    expect(data.edgeStartPt.length, data.edgeCount + 1);
    expect(data.edgeStartPt.last, data.pointCount - 1);
  });

  test('настройки сериализуются', () {
    final p = RoutePrefs(priority: Priority.cheapest, tollMode: TollMode.free, classes: {0, 2});
    final q = RoutePrefs.fromJson(p.toJson());
    expect(q.priority, Priority.cheapest);
    expect(q.tollMode, TollMode.free);
    expect(q.classes, {0, 2});
  });
}
