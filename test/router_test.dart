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

  test('при низкой цене времени — бесплатная дорога', () {
    final res = plan(g, RoutePrefs(valueOfTime: 100));
    expect(res.routes, isNotNull, reason: res.error);
    expect(res.routes!.first.tollCost, 0);
  });

  test('при высокой цене времени — платная магистраль', () {
    final res = plan(g, RoutePrefs(valueOfTime: 3000));
    expect(res.routes!.first.tollCost, greaterThan(0));
    expect(names(g, res.routes!.first), contains('Платная магистраль М-Демо'));
  });

  test('режим «только бесплатные» не использует платные дороги', () {
    final res = plan(g, RoutePrefs(valueOfTime: 100000, tollMode: TollMode.free));
    for (final r in res.routes!) {
      expect(r.tollCost, 0);
    }
  });

  test('режим «предпочитать платные» выбирает магистраль даже при дешёвом времени', () {
    final res = plan(g, RoutePrefs(valueOfTime: 50, tollMode: TollMode.prefer));
    expect(res.routes!.first.tollCost, greaterThan(0));
  });

  test('фильтр по типу дорог', () {
    final res = plan(g, RoutePrefs(valueOfTime: 100000, classes: {1, 2, 3, 4, 5, 6, 7}));
    expect(res.routes!.first.tollCost, 0);
    expect(names(g, res.routes!.first), contains('Шоссе Северное'));
  });

  test('фильтр по максимальному лимиту скорости', () {
    final res = plan(g, RoutePrefs(valueOfTime: 100000, maxSpeed: 60));
    expect(names(g, res.routes!.first), isNot(contains('Платная магистраль М-Демо')));
  });

  test('фильтр по минимальному лимиту скорости', () {
    final res = plan(g, RoutePrefs(valueOfTime: 0.0001, minSpeed: 60));
    expect(names(g, res.routes!.first), isNot(contains('Южная дорога')));
  });

  test('жилые подъезды у старта/финиша доступны при отключённых жилых улицах', () {
    final res = plan(g, RoutePrefs(classes: {0, 2}));
    expect(res.routes, isNotNull, reason: res.error);
  });

  test('есть альтернативы: самый быстрый и самый дешёвый', () {
    final res = plan(g, RoutePrefs(valueOfTime: 300));
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
    final res = plan(g, RoutePrefs(valueOfTime: 3000));
    final data = buildRouteData(g, res.routes!.first);
    expect(data.steps.first.text, startsWith('Начните движение'));
    expect(data.steps.last.type, TurnType.arrive);
    expect(data.steps.any((s) => s.toll), isTrue);
    expect(data.edgeStartPt.length, data.edgeCount + 1);
    expect(data.edgeStartPt.last, data.pointCount - 1);
  });

  test('настройки сериализуются', () {
    final p = RoutePrefs(valueOfTime: 123, tollMode: TollMode.free, classes: {0, 2});
    final q = RoutePrefs.fromJson(p.toJson());
    expect(q.valueOfTime, 123);
    expect(q.tollMode, TollMode.free);
    expect(q.classes, {0, 2});
  });
}
