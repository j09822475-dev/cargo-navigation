import 'dart:io';

import 'package:cargo_navigation/core/geo.dart';
import 'package:cargo_navigation/core/route_data.dart';
import 'package:cargo_navigation/engine/online_router.dart';
import 'package:cargo_navigation/engine/osrm.dart';
import 'package:cargo_navigation/engine/road_source.dart';
import 'package:cargo_navigation/engine/route_api.dart';
import 'package:cargo_navigation/engine/valhalla.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Участок подставного маршрута: от точки к точке, с признаками дороги.
class Seg {
  final LatLon to;
  final bool toll, highway, ferry;
  final List<String> names;
  const Seg(this.to, {this.toll = false, this.highway = false, this.ferry = false, this.names = const []});
}

/// Подставной маршрут: точки через ~5 км, один манёвр на участок, скорость 25 м/с.
RouteCandidate line(LatLon from, List<Seg> segs, {String provider = 'Valhalla', bool priced = true, double speed = 25}) {
  final pts = <double>[from.lat, from.lon];
  final ms = <Maneuver>[];
  var cur = from;
  var total = 0.0;
  for (var k = 0; k < segs.length; k++) {
    final s = segs[k];
    final d = haversine(cur.lat, cur.lon, s.to.lat, s.to.lon);
    final n = (d / 5000).ceil().clamp(1, 100000);
    final begin = pts.length ~/ 2 - 1;
    for (var i = 1; i <= n; i++) {
      final p = interpolateGreatCircle(cur.lat, cur.lon, s.to.lat, s.to.lon, i / n);
      pts..add(p.$1)..add(p.$2);
    }
    ms.add(Maneuver(k == 0 ? 1 : 8, k == 0 ? 'Двигайтесь' : 'Продолжайте движение', s.names, d, d / speed, s.toll, s.highway,
        s.ferry, begin, pts.length ~/ 2 - 1));
    total += d;
    cur = s.to;
  }
  final last = pts.length ~/ 2 - 1;
  ms.add(Maneuver(4, 'Вы прибыли', const [], 0, 0, false, false, false, last, last));
  return RouteCandidate(pts, ms, total, total / speed, provider, priced: priced);
}

class Req {
  final LatLon a, b;
  final bool avoidTolls, alternatives, viaA, viaB;
  final List<LatLon> exclude;
  Req(this.a, this.b, this.avoidTolls, this.alternatives, this.viaA, this.viaB, this.exclude);
}

class FakeProvider implements RoutingProvider {
  @override
  final String name;
  @override
  final bool supportsExclude;
  final Future<List<RouteCandidate>> Function(Req r) handler;
  final List<Req> calls = [];
  FakeProvider(this.name, this.handler, {this.supportsExclude = true});

  @override
  Future<List<RouteCandidate>> route(LatLon a, LatLon b,
      {required bool avoidTolls,
      required bool alternatives,
      required CancelToken cancel,
      bool viaA = false,
      bool viaB = false,
      List<LatLon> exclude = const []}) {
    final r = Req(a, b, avoidTolls, alternatives, viaA, viaB, List.of(exclude));
    calls.add(r);
    return handler(r);
  }
}

OnlineRouter routerOf(List<RoutingProvider> p, {RoutingProvider? guide}) =>
    OnlineRouter(p, guide: guide, countries: countries, tolls: tolls);

/// Прямая a→b по магистрали (для тестов, где важна только геометрия).
Future<List<RouteCandidate>> straight(Req r) async => [line(r.a, [Seg(r.b, highway: true)])];

bool inEu(RouteData r) {
  for (var i = 0; i < r.pointCount; i++) {
    if (countries.isDeepNonEu(r.pts[2 * i], r.pts[2 * i + 1])) return false;
  }
  return true;
}

void main() {
  group('разбор ответов серверов (настоящие ответы)', () {
    test('Valhalla: основной маршрут и альтернатива, манёвры по-русски, отметки магистралей', () {
      final c = ValhallaProvider.parse(File('test/fixtures/valhalla_lt.json').readAsStringSync(), 200);
      expect(c.length, 2);
      final r = c.first;
      expect(r.meters, closeTo(69989, 1));
      expect(r.maneuvers.length, 13);
      expect(r.maneuvers.first.instruction, startsWith('Двигайтесь'));
      expect(r.maneuvers.first.streetNames, contains('A5'));
      expect(r.maneuvers.any((m) => m.highway), isTrue);
      expect(r.maneuvers.last.endIdx, r.pointCount - 1);
      expect(turnTypeOfValhalla(r.maneuvers.last.type), TurnType.arrive);
      expect(r.maneuvers.map((m) => turnTypeOfValhalla(m.type)), contains(TurnType.roundabout));
      expect(r.priced, isTrue);
    });

    test('Valhalla: ошибки', () {
      expect(() => ValhallaProvider.parse('{"error_code":154,"error":"Path distance exceeds"}', 400),
          throwsA(isA<ProviderException>().having((e) => e.tooLong, 'tooLong', isTrue)));
      expect(() => ValhallaProvider.parse('<html>busy</html>', 503), throwsA(isA<ProviderException>()));
      final body = ValhallaProvider.requestBody(const LatLon(1, 2), const LatLon(3, 4),
          avoidTolls: true, alternatives: true, viaB: true, exclude: [const LatLon(5, 6)]);
      expect((body['costing_options'] as Map)['auto'], {'use_tolls': 0.0});
      expect((body['locations'] as List)[1], containsPair('search_filter', {'min_road_class': 'primary', 'exclude_toll': true}));
      expect((body['locations'] as List)[0], isNot(contains('search_filter')));
      expect(body['exclude_locations'], [
        {'lat': 5.0, 'lon': 6.0}
      ]);
      expect(body['language'], 'ru-RU');
    });

    test('OSRM: шаги, русские подсказки, стоимость помечена как неизвестная', () {
      final c = OsrmProvider.parse(File('test/fixtures/osrm_ee.json').readAsStringSync(), 200);
      final r = c.first;
      expect(r.priced, isFalse);
      expect(r.maneuvers.first.type, 1);
      expect(r.maneuvers.last.type, 4);
      expect(r.maneuvers.last.endIdx, r.pointCount - 1);
      for (var i = 1; i < r.maneuvers.length; i++) {
        expect(r.maneuvers[i].beginIdx, r.maneuvers[i - 1].endIdx, reason: 'шаги идут подряд по линии');
      }
      expect(r.maneuvers.any((m) => m.instruction.startsWith('Поверните')), isTrue);
      expect(() => OsrmProvider.parse('{"code":"NoRoute","message":"Impossible route"}', 400), throwsA(isA<ProviderException>()));
    });

    test('декодирование линии', () {
      expect(decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@', precision: 5), [38.5, -120.2, 40.7, -120.95, 43.252, -126.453]);
    });
  });

  group('стоимость', () {
    test('Австрия: виньетка один раз, хотя магистраль в двух манёврах', () async {
      final v = FakeProvider('Valhalla', (r) async => [
            line(r.a, [Seg(const LatLon(48.2, 15.0), highway: true), Seg(r.b, highway: true)])
          ]);
      final out = await routerOf([v]).plan(const LatLon(48.2, 14.3), const LatLon(48.2, 15.6));
      final best = out.routes!.first;
      expect(best.vignettes.map((x) => x.iso), ['AT']);
      expect(best.money, closeTo(9.60, 1e-9));
      expect(v.calls.where((c) => c.avoidTolls).length, 1, reason: 'есть плата — ищем и вариант без платных дорог');
    });

    test('Франция: плата за км; Италия A22 — официальная ставка по номеру; тоннель Бельгии — фиксированно', () async {
      final fr = await routerOf([FakeProvider('Valhalla', (r) async => [line(r.a, [Seg(r.b, toll: true, highway: true, names: ['A6'])])])])
          .plan(const LatLon(47.0, 4.0), const LatLon(47.0, 4.5));
      final r1 = fr.routes!.first;
      expect(r1.distanceToll / (r1.tollMeters / 1000), closeTo(0.112, 1e-6));
      expect(r1.estimated, isTrue);

      final it = await routerOf([FakeProvider('Valhalla', (r) async => [line(r.a, [Seg(r.b, toll: true, highway: true, names: ['A22', 'E45'])])])])
          .plan(const LatLon(45.9, 11.0), const LatLon(46.2, 11.1));
      final r2 = it.routes!.first;
      expect(r2.distanceToll / (r2.tollMeters / 1000), closeTo(0.07002, 1e-6));
      expect(r2.tollOperatorMeters, closeTo(r2.tollMeters, 1));

      final be = await routerOf([
        FakeProvider('Valhalla', (r) async => [
              line(r.a, [
                Seg(const LatLon(51.28, 4.30), highway: true),
                Seg(const LatLon(51.29, 4.33), toll: true, highway: true, names: ['Liefkenshoektunnel', 'R2']),
                Seg(r.b, highway: true),
              ])
            ])
      ]).plan(const LatLon(51.25, 4.20), const LatLon(51.30, 4.45));
      final r3 = be.routes!.first;
      expect(r3.objects.single.priceEur, 6.20);
      expect(r3.tags, isNot(contains('free')));
      expect(r3.money, closeTo(6.20, 1e-9));
      expect(r3.tollUnknownMeters, 0);
    });

    test('тоннель по номеру дороги: только на платном участке', () async {
      // R2 в Антверпене: платно только звено с тоннелем Лифкенсхук, остальное кольцо бесплатно
      final out = await routerOf([
        FakeProvider('Valhalla', (r) async => [
              line(r.a, [
                Seg(const LatLon(51.24, 4.24), highway: true, names: ['R2']),
                Seg(const LatLon(51.30, 4.30), toll: true, highway: true, names: ['R2']),
                Seg(r.b, highway: true, names: ['R2']),
              ])
            ])
      ]).plan(const LatLon(51.20, 4.20), const LatLon(51.32, 4.40));
      final r = out.routes!.first;
      expect(r.objects.single.name, contains('Лифкенсхук'));
      expect(r.money, closeTo(6.20, 1e-9));

      final free = await routerOf([
        FakeProvider('Valhalla', (r) async => [line(r.a, [Seg(r.b, highway: true, names: ['R2'])])])
      ]).plan(const LatLon(51.20, 4.40), const LatLon(51.25, 4.45));
      expect(free.routes!.first.money, 0, reason: 'бесплатный участок R2 не облагается');
    });

    test('Германия: платный объект без цены и паром — предупреждения', () async {
      final out = await routerOf([
        FakeProvider('Valhalla', (r) async => [
              line(r.a, [Seg(const LatLon(54.1, 12.1), toll: true, names: ['Warnowtunnel']), Seg(r.b, ferry: true)])
            ])
      ]).plan(const LatLon(54.0, 12.0), const LatLon(54.2, 12.2));
      final w = out.routes!.first.warnings.join(' ');
      expect(w, contains('без известной цены'));
      expect(out.routes!.first.tags, isNot(contains('free')), reason: 'платный участок с неизвестной ценой — не «бесплатно»');
      expect(w, contains('паром'));
    });

    test('основной — с приоритетом бесплатных дорог; самый быстрый и бесплатный тоже показаны', () async {
      // платный вариант быстрее на 20 мин за 20 € → основной бесплатный (20 €/ч дешевле, чем 40 €/ч)
      final v = FakeProvider('Valhalla', (r) async => r.avoidTolls
          ? [line(r.a, [Seg(r.b)], speed: 20)]
          : [line(r.a, [Seg(r.b, toll: true, highway: true)], speed: 25)]);
      final out = await routerOf([v]).plan(const LatLon(47.0, 2.0), const LatLon(47.0, 3.4));
      final best = out.routes!.first, other = out.routes![1];
      expect(best.tags, containsAll(['best', 'free']));
      expect(other.tags, contains('fastest'));
      expect(other.money, greaterThan(0));
    });
  });

  group('участки и страны', () {
    test('длинный маршрут — по участкам до ~900 км, стыки помечены, шаги склеены', () async {
      final v = FakeProvider('Valhalla', straight);
      final out = await routerOf([v]).plan(const LatLon(59.437, 24.754), const LatLon(45.464, 9.19));
      expect(out.error, isNull, reason: out.error);
      final normal = v.calls.where((c) => !c.avoidTolls).toList();
      expect(normal.length, greaterThanOrEqualTo(3));
      expect(normal.first.viaA, isFalse);
      expect(normal.first.viaB, isTrue);
      expect(normal.last.viaB, isFalse);
      expect(normal.every((c) => !c.alternatives), isTrue);
      for (final c in normal) {
        expect(haversine(c.a.lat, c.a.lon, c.b.lat, c.b.lon), lessThan(1000000));
      }
      final r = out.routes!.first;
      expect(inEu(r), isTrue);
      expect(r.steps.where((s) => s.type == TurnType.depart).length, 1, reason: 'один старт');
      expect(r.steps.where((s) => s.type == TurnType.arrive).length, 1, reason: 'одно прибытие');
      expect(out.note, contains('по участкам'));
    });

    test('участок через страну вне ЕС: переход границы запрещается, маршрут перестраивается', () async {
      const konstanz = LatLon(47.66, 9.17), milan = LatLon(45.464, 9.19);
      final v = FakeProvider('Valhalla', (r) async {
        if (r.exclude.isEmpty) return straight(r); // напрямую — через Швейцарию
        return [
          line(r.a, [
            const Seg(LatLon(47.50, 9.75), highway: true),
            const Seg(LatLon(47.26, 11.40), highway: true),
            const Seg(LatLon(47.00, 11.51), highway: true),
            const Seg(LatLon(46.50, 11.35), highway: true),
            const Seg(LatLon(45.44, 10.99), highway: true),
            Seg(r.b, highway: true),
          ])
        ];
      });
      final out = await routerOf([v]).plan(konstanz, milan);
      expect(out.error, isNull, reason: out.error);
      final second = v.calls[1];
      expect(second.exclude, isNotEmpty);
      // запрещённая дорога — сразу за границей Швейцарии
      expect(countries.isoAt(second.exclude.first.lat, second.exclude.first.lon), 'CH');
      expect(inEu(out.routes!.first), isTrue);
      expect(out.routes!.first.vignettes.map((x) => x.iso), contains('AT'));
    });

    test('сервер не умеет запрещать дороги — участок перестраивается через точки опорной линии', () async {
      const konstanz = LatLon(47.66, 9.17), milan = LatLon(45.464, 9.19);
      final o = FakeProvider('OSRM', (r) async {
        final x = await straight(r);
        return [RouteCandidate(x.first.pts, x.first.maneuvers, x.first.meters, x.first.seconds, 'OSRM', priced: false)];
      }, supportsExclude: false);
      final out = await routerOf([o]).plan(konstanz, milan);
      expect(out.error, isNull, reason: out.error);
      expect(o.calls.length, greaterThan(2));
      expect(inEu(out.routes!.first), isTrue);
    });

    test('«слишком длинный участок» — делится пополам', () async {
      final v = FakeProvider('Valhalla', (r) async {
        if (haversine(r.a.lat, r.a.lon, r.b.lat, r.b.lon) > 400000) {
          throw const ProviderException('слишком длинный участок', tooLong: true);
        }
        return straight(r);
      });
      final out = await routerOf([v]).plan(const LatLon(48.85, 2.35), const LatLon(43.6, 1.44)); // Париж → Тулуза
      expect(out.error, isNull, reason: out.error);
      expect(v.calls.where((c) => !c.avoidTolls).length, greaterThanOrEqualTo(3));
    });

    test('точки стыка ставятся на опорном маршруте, если он целиком в ЕС', () async {
      final guidePts = [const LatLon(52.0, 21.0), const LatLon(50.0, 14.4), const LatLon(48.2, 16.37), const LatLon(45.46, 9.19)];
      final guide = FakeProvider('OSRM', (r) async {
        final x = line(r.a, [for (final p in guidePts.skip(1)) Seg(p, highway: true)]);
        return [RouteCandidate(x.pts, x.maneuvers, x.meters, x.seconds, 'OSRM', priced: false)];
      }, supportsExclude: false);
      final v = FakeProvider('Valhalla', straight);
      final out = await routerOf([v], guide: guide).plan(guidePts.first, guidePts.last);
      expect(out.error, isNull, reason: out.error);
      expect(guide.calls.length, 1);
      // каждая точка стыка лежит на опорной линии (не дальше пары километров)
      final g = guide.calls.isEmpty ? null : line(guidePts.first, [for (final p in guidePts.skip(1)) Seg(p)]);
      for (final c in v.calls.where((c) => !c.avoidTolls && c.viaB)) {
        var near = double.infinity;
        for (var i = 0; i < g!.pointCount; i++) {
          near = [near, haversine(c.b.lat, c.b.lon, g.pts[2 * i], g.pts[2 * i + 1])].reduce((a, b) => a < b ? a : b);
        }
        expect(near, lessThan(3000));
      }
      expect(out.routes!.every((r) => r.costKnown), isTrue, reason: 'варианты опорного сервера не показываются');
    });
  });

  group('сбои серверов', () {
    test('основной сервер недоступен — запасной; стоимость помечена как неизвестная', () async {
      final v = FakeProvider('Valhalla', (r) async => throw Exception("SocketException: Failed host lookup: 'valhalla1'"));
      final o = FakeProvider('OSRM', (r) async {
        final x = await straight(r);
        return [RouteCandidate(x.first.pts, x.first.maneuvers, x.first.meters, x.first.seconds, 'OSRM', priced: false)];
      }, supportsExclude: false);
      final out = await routerOf([v, o]).plan(const LatLon(59.437, 24.754), const LatLon(58.378, 26.729));
      expect(out.error, isNull);
      final r = out.routes!.single;
      expect(r.costKnown, isFalse);
      expect(r.tags, isNot(contains('free')));
      expect(out.note, contains('запасной'));
      expect(o.calls.every((c) => !c.avoidTolls), isTrue);
    });

    test('все серверы недоступны — понятная ошибка с причиной по каждому', () async {
      final v = FakeProvider('Valhalla', (r) async => throw Exception("SocketException: Failed host lookup: 'a'"));
      final o = FakeProvider('OSRM', (r) async => throw Exception('SocketException: Connection refused'), supportsExclude: false);
      final out = await routerOf([v, o]).plan(const LatLon(59.437, 24.754), const LatLon(58.378, 26.729));
      expect(out.routes, isNull);
      expect(out.error, allOf(contains('Проверьте интернет'), contains('Valhalla'), contains('OSRM')));
    });

    test('точки вне ЕС отклоняются без запросов к серверу', () async {
      final v = FakeProvider('Valhalla', straight);
      final out = await routerOf([v]).plan(const LatLon(46.95, 7.45), const LatLon(45.464, 9.19));
      expect(out.error, contains('Евросоюз'));
      expect(v.calls, isEmpty);
    });
  });
}
