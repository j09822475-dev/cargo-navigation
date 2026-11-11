import 'dart:convert';
import 'dart:math' as math;

import 'package:cargo_navigation/core/geo.dart';
import 'package:cargo_navigation/core/weather.dart';
import 'package:cargo_navigation/engine/demo_source.dart';
import 'package:cargo_navigation/engine/engine.dart';
import 'package:cargo_navigation/engine/open_meteo.dart';
import 'package:cargo_navigation/engine/overpass_source.dart';
import 'package:cargo_navigation/engine/road_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';

/// ~1730 км с запада на восток по 48,5° с. ш.: Бретань → Германия → Австрия → Словакия.
/// Магистраль (во Франции с тегом toll=yes) и параллельная бесплатная главная дорога.
List<WaySpec> longNetwork() {
  const n = 48; // шаг 0,5° ≈ 37 км
  const lat = 48.5;
  final specs = <WaySpec>[];
  final motor = [for (var i = 0; i < n; i++) (1000 + i, lat, -4.0 + 0.5 * i)];
  final prim = [for (var i = 0; i < n; i++) (2000 + i, lat + 0.15, -4.0 + 0.5 * i)];
  // запад (Франция) — платный, дальше без тега
  specs.add(WaySpec(1, {'highway': 'motorway', 'toll': 'yes', 'maxspeed': '130', 'name': 'М запад'}, motor.sublist(0, 23)));
  specs.add(WaySpec(3, {'highway': 'motorway', 'maxspeed': '130', 'name': 'М восток'}, motor.sublist(22)));
  specs.add(WaySpec(2, {'highway': 'primary', 'maxspeed': '80', 'name': 'Главное шоссе'}, prim));
  for (var i = 0; i < n; i += 6) {
    specs.add(WaySpec(100 + i, {'highway': 'secondary', 'maxspeed': '60', 'name': 'Связка $i'}, [motor[i], prim[i]]));
  }
  specs.add(WaySpec(99, {'highway': 'secondary', 'maxspeed': '60', 'name': 'Связка у финиша'}, [motor.last, prim.last]));
  specs.add(WaySpec(5, {'highway': 'residential', 'name': 'ул. Старта'}, [(1, lat + 0.004, -4.004), motor.first]));
  specs.add(WaySpec(6, {'highway': 'residential', 'name': 'ул. Финиша'}, [motor.last, (2, lat + 0.004, 19.504)]));
  return specs;
}

const longStart = LatLon(48.504, -4.004);
const longEnd = LatLon(48.504, 19.504);

RoutingEngine engineOf(RoadSource src, {WeatherSource? weather}) =>
    RoutingEngine(src, countries: countries, tolls: tolls, weather: weather);

void main() {
  test('Overpass: запросы и разбор ответа', () {
    final q = corridorQuery([const LatLon(1, 2), const LatLon(3, 4.5)], 30000, {0, 1});
    expect(q, contains('around:30000,1.00000,2.00000,3.00000,4.50000'));
    expect(q, contains('motorway|motorway_link|trunk|trunk_link'));
    final data = parseOverpass(jsonEncode({
      'elements': [
        {
          'type': 'way', 'id': 10, 'nodes': [1, 2],
          'geometry': [{'lat': 1.0, 'lon': 2.0}, {'lat': 1.0, 'lon': 2.1}],
          'tags': {'highway': 'primary', 'maxspeed': '90', 'toll': 'yes', 'name': 'Т', 'operator': 'APRR'}
        },
        {'type': 'way', 'id': 11, 'nodes': [3, 4], 'geometry': [{'lat': 1.0, 'lon': 2.0}, null], 'tags': {'highway': 'primary'}},
        {'type': 'way', 'id': 12, 'nodes': [5, 6], 'geometry': [{'lat': 1.0, 'lon': 2.0}, {'lat': 1.0, 'lon': 2.1}], 'tags': {'highway': 'footway'}},
      ]
    }));
    expect(data.wayCount, 1);
    expect(data.infos.first.toll, isTrue);
    expect(data.infos.first.operator, 'APRR');
    expect(() => parseOverpass(jsonEncode({'elements': [], 'remark': 'runtime error: Query timed out'})), throwsA(isA<OverpassException>()));
  });

  test('маршрут ~1730 км через четыре страны: коридоры, плата за км и виньетки', () async {
    final src = FakeSource(longNetwork());
    final progress = <String>[];
    final out = await engineOf(src).plan(longStart, longEnd, onProgress: progress.add);
    expect(out.error, isNull);
    final best = out.routes!.first;
    expect(best.meters / 1000, inInclusiveRange(1700, 1800));
    expect(best.distanceToll, greaterThan(50), reason: 'платная магистраль во Франции');
    expect(best.vignettes.map((v) => v.iso).toSet(), {'AT', 'SK'});
    expect(best.money, closeTo(best.distanceToll + 9.60 + 8.10, 1e-6));
    expect(best.estimated, isTrue, reason: 'ставка Франции без оператора — оценка');
    expect(out.note, contains('Дальний маршрут'));

    final corridors = src.calls.where((c) => c.kind == 'corridor').toList();
    expect(corridors.length, greaterThan(10), reason: 'данные грузятся кусками');
    for (final c in corridors) {
      expect(c.lengthMeters, lessThanOrEqualTo(160000));
    }
    expect(corridors.first.classes.difference({0, 1}), isEmpty, reason: 'сначала каркас из магистралей');
    expect(corridors.any((c) => c.radius == 3000), isTrue, reason: 'затем уточнение вдоль трассы');
    expect(progress.any((m) => m.contains('участок')), isTrue);
    // бесплатная альтернатива по главному шоссе
    expect(out.routes!.any((r) => r.tags.contains('free')), isTrue);
  });

  test('повтор того же запроса не перезагружает данные', () async {
    final src = FakeSource(longNetwork());
    final engine = engineOf(src);
    await engine.plan(longStart, longEnd);
    final n = src.calls.length;
    final out = await engine.plan(longStart, longEnd);
    expect(out.routes, isNotNull);
    expect(src.calls.length, n);
  });

  test('маршрут из Германии в Италию идёт в обход Швейцарии', () async {
    // прямая магистраль через Швейцарию и объезд через Австрию (Форарльберг — Решен — Больцано)
    const start = LatLon(47.9, 9.0), end = LatLon(45.6, 9.0);
    final specs = <WaySpec>[
      const WaySpec(1, {'highway': 'motorway', 'maxspeed': '120', 'name': 'Через Швейцарию'},
          [(10, 47.9, 9.0), (11, 47.3, 9.0), (12, 46.8, 9.0), (13, 46.2, 9.0), (20, 45.6, 9.0)]),
    ];
    const detour = [
      (10, 47.9, 9.0), (31, 47.55, 9.75), (32, 47.15, 10.6), (33, 46.85, 10.5), (34, 46.65, 10.65),
      (35, 46.5, 11.35), (36, 45.9, 11.0), (37, 45.6, 10.0), (20, 45.6, 9.0),
    ];
    for (var i = 1; i < detour.length; i++) {
      // отдельные пути, чтобы у каждого участка была своя страна; параллельная мелкая дорога делает узлы перекрёстками
      specs.add(WaySpec(100 + i, {'highway': 'trunk', 'maxspeed': '90', 'name': 'Объезд по ЕС'}, [detour[i - 1], detour[i]]));
    }
    final src = FakeSource(specs);
    final engine = engineOf(src);
    // опорная линия обходит Швейцарию
    final line = engine.spine(start, end);
    expect(line.any((p) => countries.isDeepNonEu(p.lat, p.lon)), isFalse);
    expect(line.length, greaterThan(greatCirclePoints(start, end, 30000).length));

    final out = await engine.plan(start, end);
    expect(out.error, isNull, reason: out.error);
    final r = out.routes!.first;
    for (var i = 0; i < r.pointCount; i++) {
      expect(countries.isDeepNonEu(r.pts[2 * i], r.pts[2 * i + 1]), isFalse);
    }
    expect(r.meters / 1000, greaterThan(400), reason: 'объезд длиннее прямой (255 км)');
    expect(r.steps.any((s) => s.text.contains('Через Швейцарию')), isFalse);
    expect(r.vignettes.map((v) => v.iso), contains('AT'));
  });

  test('точки вне ЕС и вне Европы отклоняются с понятным сообщением', () async {
    final engine = engineOf(FakeSource(longNetwork()));
    final ch = await engine.plan(const LatLon(46.95, 7.45), longEnd); // Берн
    expect(ch.routes, isNull);
    expect(ch.error, allOf(contains('Евросоюз'), contains('CH')));
    final rs = await engine.plan(longStart, const LatLon(44.8, 20.45)); // Белград
    expect(rs.error, contains('Точка назначения'));
    final far = await engine.plan(longStart, const LatLon(40.7, -74.0)); // Нью-Йорк
    expect(far.error, contains('вне Европы'));
  });

  test('погода: снег замедляет маршрут и даёт предупреждение', () async {
    final clear = await engineOf(DemoSource()).plan(demoStart, demoEnd);
    final w = FakeWeather((_) => const WeatherPoint(code: 73, snowfall: 0.5, temperature: -2));
    final snowy = await engineOf(DemoSource(), weather: w).plan(demoStart, demoEnd);
    expect(w.calls, 1);
    final a = clear.routes!.first, b = snowy.routes!.first;
    expect(a.weatherDelayHours, 0);
    expect(b.hours, closeTo(a.hours / 0.7, 0.01));
    expect(b.weatherDelayHours, greaterThan(0));
    expect(b.warnings.single, allOf(contains('снег'), contains('мин')));
  });

  test('погода может поменять основной маршрут', () async {
    // на магистрали (широта 47,0) гроза и ледяной дождь, на северном шоссе (47,05) ясно
    final w = FakeWeather((p) => p.lat < 47.03 ? const WeatherPoint(code: 67, precipitation: 9) : const WeatherPoint());
    final clear = await engineOf(DemoSource()).plan(demoStart, demoEnd);
    final out = await engineOf(DemoSource(), weather: w).plan(demoStart, demoEnd);
    expect(clear.routes!.first.money, greaterThan(0), reason: 'в ясную погоду основной — платная магистраль');
    expect(out.routes!.first.tags, contains('best'));
    expect(out.routes!.first.money, 0, reason: 'в непогоду на магистрали основной — бесплатное шоссе');
  });

  test('погода недоступна — маршрут строится без поправки', () async {
    final out = await engineOf(DemoSource(), weather: _Broken()).plan(demoStart, demoEnd);
    expect(out.routes, isNotNull);
    expect(out.routes!.first.warnings, isEmpty);
  });

  test('Open-Meteo: запрос и разбор ответа (один объект и массив)', () {
    final u = OpenMeteoSource.uriFor([const LatLon(48.5, 2.25), const LatLon(47, 3)]);
    expect(u.host, 'api.open-meteo.com');
    expect(u.queryParameters['latitude'], '48.500,47.000');
    expect(u.queryParameters['current'], contains('weather_code'));
    final one = OpenMeteoSource.parse('{"current":{"temperature_2m":-1.5,"precipitation":0.4,"snowfall":0.3,"weather_code":71,"wind_gusts_10m":35}}')!;
    expect(one.single.code, 71);
    expect(one.single.temperature, -1.5);
    final many = OpenMeteoSource.parse('[{"current":{"weather_code":0}},{"current":{"weather_code":95,"precipitation":12}}]')!;
    expect(many.length, 2);
    expect(weatherEffect(many[1]).label, 'гроза');
    expect(OpenMeteoSource.parse('{"error":true}'), isNull);
  });

  test('влияние погоды на скорость', () {
    expect(weatherEffect(const WeatherPoint()).factor, 1);
    expect(weatherEffect(const WeatherPoint(code: 75, snowfall: 2)).factor, 0.55);
    expect(weatherEffect(const WeatherPoint(code: 45)).label, 'туман');
    expect(weatherEffect(const WeatherPoint(gust: 95)).label, 'штормовой ветер');
    expect(weatherEffect(const WeatherPoint(precipitation: 2)).factor, 0.9);
    final s = samplePolyline([47.0, 3.0, 47.0, 4.0, 47.0, 5.0], 40000, 8);
    expect(s.length, 4);
  });

  group('сбои серверов Overpass', () {
    const ok = '{"elements":[{"type":"way","id":1,"nodes":[1,2],"geometry":[{"lat":45.0,"lon":9.0},{"lat":45.0,"lon":9.1}],"tags":{"highway":"primary"}}]}';
    OverpassSource src(Future<http.Response> Function(http.Request r) h, {List<String>? endpoints}) => OverpassSource(
        client: MockClient(h),
        endpoints: endpoints ?? const ['https://a.example/api', 'https://b.example/api', 'https://c.example/api'],
        retryDelay: Duration.zero);
    const box = Bbox(45.0, 9.0, 45.05, 9.05);

    test('первый сервер недоступен — данные берутся со следующего', () async {
      final hosts = <String>[];
      final s = src((r) async {
        hosts.add(r.url.host);
        if (r.url.host == 'a.example') throw http.ClientException('Failed host lookup: a.example');
        return http.Response(ok, 200);
      });
      expect((await s.fetchBox(box, {2}, CancelToken())).wayCount, 1);
      expect(hosts, ['a.example', 'b.example']);
    });

    test('перегруженный сервер (429) пробуется повторно', () async {
      var n = 0;
      final s = src((r) async => ++n < 3 ? http.Response('', 429) : http.Response(ok, 200), endpoints: const ['https://a.example/api']);
      expect((await s.fetchBox(box, {2}, CancelToken())).wayCount, 1);
      expect(n, 3);
    });

    test('все серверы недоступны — сообщение про интернет со списком причин по каждому серверу', () async {
      final s = src((r) async => throw http.ClientException("SocketException: Failed host lookup: '${r.url.host}'"));
      await expectLater(
          s.fetchBox(box, {2}, CancelToken()),
          throwsA(isA<OverpassException>().having((e) => e.message, 'message',
              allOf(contains('Проверьте интернет'), contains('a.example'), contains('b.example'), contains('c.example'), contains('адрес сервера не найден')))));
    });

    test('серверы отвечают ошибками — сообщение «попробуйте позже» с причинами', () async {
      final s = src((r) async => r.url.host == 'a.example' ? http.Response('', 504) : http.Response('', 400));
      await expectLater(
          s.fetchBox(box, {2}, CancelToken()),
          throwsA(isA<OverpassException>().having((e) => e.message, 'message',
              allOf(contains('не отвечают'), contains('перегружен (504)'), contains('ответ 400')))));
    });

    test('большая область, которую не отдают целиком, делится на четыре части', () async {
      var calls = 0;
      final s = src((r) async {
        calls++;
        final q = Uri.splitQueryString(r.body)['data']!;
        // целая область 1°×1° «слишком велика», четверти отдаются
        return q.contains('(45.0,9.0,46.0,10.0)') ? http.Response('', 400) : http.Response(ok, 200);
      }, endpoints: const ['https://a.example/api']);
      final d = await s.fetchBox(const Bbox(45.0, 9.0, 46.0, 10.0), {2}, CancelToken());
      expect(calls, 5);
      expect(d.wayCount, 4);
    });

    test('движок возвращает понятную ошибку, а не падает', () async {
      final s = src((r) async => throw http.ClientException('SocketException: Connection refused'));
      final out = await engineOf(s).plan(demoStart, demoEnd);
      expect(out.routes, isNull);
      expect(out.error, contains('Проверьте интернет'));
    });
  });

  test('отмена прерывает загрузку', () async {
    final token = CancelToken()..cancelled = true;
    expect(engineOf(FakeSource(longNetwork())).plan(longStart, longEnd, cancel: token), throwsA(isA<CancelledException>()));
  });

  test('короткий маршрут (демо) строится одной рамкой', () async {
    final out = await engineOf(DemoSource()).plan(demoStart, demoEnd);
    expect(out.routes, isNotNull, reason: out.error);
    expect(out.note, isNull);
    expect(math.max(0, out.routes!.length), greaterThanOrEqualTo(2));
  });
}

class _Broken implements WeatherSource {
  @override
  Future<List<WeatherPoint>?> current(List<LatLon> points) async => throw Exception('нет сети');
}
