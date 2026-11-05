import 'dart:convert';
import 'dart:math' as math;

import 'package:cargo_navigation/core/geo.dart';
import 'package:cargo_navigation/core/prefs.dart';
import 'package:cargo_navigation/core/road_graph.dart';
import 'package:cargo_navigation/engine/demo_source.dart';
import 'package:cargo_navigation/engine/engine.dart';
import 'package:cargo_navigation/engine/overpass_source.dart';
import 'package:cargo_navigation/engine/road_source.dart';
import 'package:flutter_test/flutter_test.dart';

class Call {
  final String kind;
  final Set<int> classes;
  final double radius, lengthMeters;
  Call(this.kind, this.classes, this.radius, this.lengthMeters);
}

/// Имитация Overpass на синтетической сети: фильтрует пути по классу и по области/коридору.
class FakeSource implements RoadSource {
  final List<WaySpec> specs;
  final List<Call> calls = [];
  FakeSource(this.specs);

  bool _cls(WaySpec s, Set<int> classes) {
    final hw = s.tags['highway']!.replaceAll('_link', '');
    return classes.contains(roadClasses.indexOf(hw));
  }

  @override
  Future<WayData> fetchBox(Bbox b, Set<int> classes, CancelToken cancel) async {
    calls.add(Call('box', classes, 0, 0));
    return waysFromSpecs([
      for (final s in specs)
        if (_cls(s, classes) && s.nodes.any((n) => n.$2 >= b.south && n.$2 <= b.north && n.$3 >= b.west && n.$3 <= b.east)) s
    ]);
  }

  static double _distToSegment(LatLon p, LatLon a, LatLon b) {
    final kx = math.cos(p.lat * math.pi / 180);
    final dx = (b.lon - a.lon) * kx, dy = b.lat - a.lat;
    final px = (p.lon - a.lon) * kx, py = p.lat - a.lat;
    final l2 = dx * dx + dy * dy;
    final t = l2 == 0 ? 0.0 : ((px * dx + py * dy) / l2).clamp(0.0, 1.0);
    return haversine(p.lat, p.lon, a.lat + dy * t, a.lon + (b.lon - a.lon) * t);
  }

  @override
  Future<WayData> fetchCorridor(List<LatLon> line, double r, Set<int> classes, CancelToken cancel) async {
    var len = 0.0;
    for (var i = 1; i < line.length; i++) {
      len += haversine(line[i - 1].lat, line[i - 1].lon, line[i].lat, line[i].lon);
    }
    calls.add(Call('corridor', classes, r, len));
    bool near(double la, double lo) {
      for (var i = 1; i < line.length; i++) {
        if (_distToSegment(LatLon(la, lo), line[i - 1], line[i]) <= r) return true;
      }
      return false;
    }

    return waysFromSpecs([
      for (final s in specs)
        if (_cls(s, classes) && s.nodes.any((n) => near(n.$2, n.$3))) s
    ]);
  }
}

/// ~1470 км с запада на восток: платная магистраль и параллельная бесплатная главная дорога.
List<WaySpec> longNetwork({double motorwayLat = 55.75, double primaryLat = 55.95}) {
  const n = 48; // шаг 0.5° ≈ 31 км
  final specs = <WaySpec>[];
  final motor = [for (var i = 0; i < n; i++) (1000 + i, motorwayLat, 37.6 + 0.5 * i)];
  final prim = [for (var i = 0; i < n; i++) (2000 + i, primaryLat, 37.6 + 0.5 * i)];
  specs.add(WaySpec(1, {'highway': 'motorway', 'toll': 'yes', 'maxspeed': '110', 'name': 'Платная М'}, motor));
  specs.add(WaySpec(2, {'highway': 'primary', 'maxspeed': '70', 'name': 'Главное шоссе'}, prim));
  for (var i = 0; i < n; i += 6) {
    specs.add(WaySpec(100 + i, {'highway': 'secondary', 'maxspeed': '60', 'name': 'Связка $i'}, [motor[i], prim[i]]));
  }
  // подъезды у концов
  specs.add(WaySpec(5, {'highway': 'residential', 'name': 'ул. Старта'}, [(1, motorwayLat + 0.004, 37.6 - 0.004), motor.first]));
  specs.add(WaySpec(6, {'highway': 'residential', 'name': 'ул. Финиша'}, [motor.last, (2, motorwayLat + 0.004, 37.6 + 0.5 * (n - 1) + 0.004)]));
  // мелкая дорога вдоль трассы — должна подтянуться только при уточнении
  specs.add(WaySpec(7, {'highway': 'tertiary', 'maxspeed': '60', 'name': 'Местная'}, [for (var i = 0; i < n; i++) (3000 + i, motorwayLat - 0.02, 37.6 + 0.5 * i)]));
  return specs;
}

const longStart = LatLon(55.754, 37.596);
const longEnd = LatLon(55.754, 61.104);

void main() {
  test('Overpass: запросы и разбор ответа', () {
    final q = corridorQuery([const LatLon(1, 2), const LatLon(3, 4.5)], 30000, {0, 1});
    expect(q, contains('around:30000,1.00000,2.00000,3.00000,4.50000'));
    expect(q, contains('motorway|motorway_link|trunk|trunk_link'));
    expect(q, contains('out body geom'));
    final b = boxQuery(const Bbox(1, 2, 3, 4), {2});
    expect(b, contains('(1.0,2.0,3.0,4.0)'));

    final data = parseOverpass(jsonEncode({
      'elements': [
        {
          'type': 'way', 'id': 10, 'nodes': [1, 2],
          'geometry': [{'lat': 1.0, 'lon': 2.0}, {'lat': 1.0, 'lon': 2.1}],
          'tags': {'highway': 'primary', 'maxspeed': '90', 'toll': 'yes', 'name': 'Т'}
        },
        {'type': 'way', 'id': 11, 'nodes': [3, 4], 'geometry': [{'lat': 1.0, 'lon': 2.0}, null], 'tags': {'highway': 'primary'}},
        {'type': 'way', 'id': 12, 'nodes': [5, 6], 'geometry': [{'lat': 1.0, 'lon': 2.0}, {'lat': 1.0, 'lon': 2.1}], 'tags': {'highway': 'footway'}},
        {'type': 'node', 'id': 1, 'lat': 1.0, 'lon': 2.0},
      ]
    }));
    expect(data.wayCount, 1);
    expect(data.infos.first.toll, isTrue);
    expect(data.infos.first.fwd, 90);
    expect(() => parseOverpass(jsonEncode({'elements': [], 'remark': 'runtime error: Query timed out'})), throwsA(isA<OverpassException>()));
  });

  test('chunkLine делит ломаную на куски не длиннее лимита', () {
    final line = greatCirclePoints(longStart, longEnd, 30000);
    final chunks = RoutingEngine.chunkLine(line, 150000);
    expect(chunks.length, greaterThan(8));
    for (final c in chunks) {
      var len = 0.0;
      for (var i = 1; i < c.length; i++) {
        len += haversine(c[i - 1].lat, c[i - 1].lon, c[i].lat, c[i].lon);
      }
      expect(len, lessThanOrEqualTo(150000 + 1));
    }
    expect(chunks.first.first, line.first);
    expect(chunks.last.last, line.last);
  });

  test('маршрут ~1470 км (> 600 км) строится через коридоры', () async {
    final src = FakeSource(longNetwork());
    final engine = RoutingEngine(src);
    final progress = <String>[];
    final out = await engine.plan(longStart, longEnd, RoutePrefs(valueOfTime: 3000), onProgress: progress.add);
    expect(out.error, isNull);
    expect(out.distanceKm, greaterThan(1400));
    final best = out.routes!.first;
    expect(best.meters / 1000, inInclusiveRange(1450, 1560));
    expect(best.tollCost, greaterThan(0)); // дорогое время — платная магистраль
    expect(out.note, contains('Дальний маршрут'));

    final corridors = src.calls.where((c) => c.kind == 'corridor').toList();
    expect(corridors.length, greaterThan(10), reason: 'данные грузятся кусками, а не одной рамкой');
    expect(src.calls.where((c) => c.kind == 'box').every((c) => c.lengthMeters == 0), isTrue);
    for (final c in corridors) {
      expect(c.lengthMeters, lessThanOrEqualTo(160000));
    }
    // сначала каркас: только магистрали/шоссе
    expect(corridors.first.classes.difference({0, 1}), isEmpty);
    // потом уточнение вдоль трассы узким коридором
    expect(corridors.any((c) => c.radius == 3000), isTrue);
    expect(progress.any((m) => m.contains('участок')), isTrue);
  });

  test('дальний маршрут: «только бесплатные» расширяет каркас до главных дорог', () async {
    final src = FakeSource(longNetwork());
    final engine = RoutingEngine(src);
    final out = await engine.plan(longStart, longEnd, RoutePrefs(valueOfTime: 3000, tollMode: TollMode.free));
    expect(out.error, isNull, reason: out.error);
    expect(out.routes!.first.tollCost, 0);
    expect(src.calls.any((c) => c.kind == 'corridor' && c.classes.contains(2)), isTrue);
  });

  test('дальний маршрут: смена настроек не перезагружает данные', () async {
    final src = FakeSource(longNetwork());
    final engine = RoutingEngine(src);
    await engine.plan(longStart, longEnd, RoutePrefs(valueOfTime: 3000));
    final n = src.calls.length;
    final out = await engine.plan(longStart, longEnd, RoutePrefs(valueOfTime: 10));
    expect(out.routes, isNotNull);
    expect(src.calls.length, n);
  });

  test('каркас расширяется, если дороги далеко от прямой линии', () async {
    // Дорога прогибается к югу на ~128 км от большого круга и состоит из коротких путей:
    // коридор начального радиуса (70 км) её не захватывает, нужно расширение до 140 км.
    const n = 48;
    final nodes = [
      for (var i = 0; i < n; i++) (1000 + i, 55.75 - 0.7 * math.sin(math.pi * i / (n - 1)), 37.6 + 0.5 * i)
    ];
    final specs = <WaySpec>[
      for (var i = 0; i < n - 1; i += 2)
        WaySpec(10 + i, {'highway': 'trunk', 'maxspeed': '90', 'name': 'Трасса'}, nodes.sublist(i, math.min(i + 3, n))),
      WaySpec(5, {'highway': 'residential', 'name': 'ул. Старта'}, [(1, 55.754, 37.596), nodes.first]),
      WaySpec(6, {'highway': 'residential', 'name': 'ул. Финиша'}, [nodes.last, (2, 55.754, 61.104)]),
    ];
    final src = FakeSource(specs);
    final out = await RoutingEngine(src).plan(longStart, longEnd, RoutePrefs());
    expect(out.error, isNull, reason: out.error);
    final radii = src.calls.where((c) => c.kind == 'corridor').map((c) => c.radius).toSet();
    expect(radii, contains(140000.0), reason: 'должен был потребоваться коридор шире начального');
    expect(radii.first, lessThan(100000));
    expect(out.routes!.first.meters / 1000, inInclusiveRange(1450, 1700));
  });

  test('нет дорог нужных типов — понятное сообщение', () async {
    final engine = RoutingEngine(FakeSource(longNetwork()));
    final out = await engine.plan(longStart, longEnd, RoutePrefs(classes: {6, 7}));
    expect(out.routes, isNull);
    expect(out.error, contains('включите'));
  });

  test('слишком большое расстояние отклоняется', () async {
    final engine = RoutingEngine(FakeSource(longNetwork()));
    final out = await engine.plan(const LatLon(0, 0), const LatLon(0, 80), RoutePrefs());
    expect(out.error, contains('Максимум'));
  });

  test('отмена прерывает загрузку', () async {
    final engine = RoutingEngine(FakeSource(longNetwork()));
    final token = CancelToken()..cancelled = true;
    expect(engine.plan(longStart, longEnd, RoutePrefs(), cancel: token), throwsA(isA<CancelledException>()));
  });

  test('короткий маршрут (демо) строится одной рамкой', () async {
    final engine = RoutingEngine(DemoSource());
    final out = await engine.plan(demoStart, demoEnd, RoutePrefs());
    expect(out.routes, isNotNull, reason: out.error);
    expect(out.note, isNull);
  });
}
