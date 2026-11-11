import 'package:cargo_navigation/core/geo.dart';
import 'package:cargo_navigation/core/route_data.dart';
import 'package:cargo_navigation/core/router.dart';
import 'package:cargo_navigation/engine/demo_source.dart';
import 'package:cargo_navigation/engine/engine.dart';
import 'package:cargo_navigation/ui/app_state.dart';
import 'package:cargo_navigation/ui/format.dart';
import 'package:cargo_navigation/ui/home_page.dart';
import 'package:cargo_navigation/ui/nav_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

RouteData demoRoute() {
  final res = planRoutes(graphOf(demoSpecs()), demoStart, demoEnd, tolls);
  return buildRouteData(res.ctx!, res.routes!.first);
}

AppState stateOf({LatLon? location}) {
  final engine = RoutingEngine(DemoSource(), countries: countries, tolls: tolls);
  return AppState((s, e, demo, pr) => engine.plan(s, e, onProgress: pr), locate: () async => location);
}

class NavProbe {
  int offRoute = 0;
  final RouteData r;
  late final NavController c = NavController(r, onOffRoute: (_) => offRoute++);
  NavProbe(this.r);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('форматирование', () {
    expect(fmtTime(0.5), '30 мин');
    expect(fmtTime(26.5), '1 д 2 ч 30 мин');
    expect(fmtDist(1530), '1.5 км');
    expect(fmtMoney(12345.5), '12 345,50 €');
    expect(fmtMoney(9.6), '9,60 €');
    expect(fmtEta(1.5, DateTime(2026, 1, 1, 10, 0)), '11:30');
    expect(fmtEta(20, DateTime(2026, 1, 1, 10, 0)), '06:00 (+1 дн.)');
  });

  test('навигация: прогресс по маршруту до прибытия, направление движения', () {
    final r = demoRoute();
    final nav = NavProbe(r);
    var prev = double.infinity;
    for (var i = 0; i < r.pointCount; i++) {
      nav.c.onFix(r.pts[2 * i], r.pts[2 * i + 1]);
      expect(nav.c.remaining, lessThanOrEqualTo(prev + 1));
      prev = nav.c.remaining;
      if (i == r.pointCount ~/ 2) expect(nav.c.heading, closeTo(90, 5), reason: 'магистраль идёт на восток');
    }
    expect(nav.c.arrived, isTrue);
    expect(nav.offRoute, 0);
  });

  test('навигация: уход с маршрута вызывает перестроение после трёх точек', () {
    final r = demoRoute();
    final nav = NavProbe(r);
    nav.c.onFix((r.pts[2] + r.pts[4]) / 2, (r.pts[3] + r.pts[5]) / 2);
    expect(nav.offRoute, 0, reason: 'между вершинами — всё ещё на маршруте');
    for (var i = 0; i < 3; i++) {
      nav.c.onFix(r.pts[0] + 0.5, r.pts[1] + 0.5);
    }
    expect(nav.offRoute, 1);
  });

  test('старт по умолчанию — моё местоположение; без него понятная ошибка', () async {
    final ok = stateOf(location: demoStart);
    await ok.setDestination(demoEnd, label: 'Б');
    expect(ok.startTitle, 'Моё местоположение');
    expect(ok.routes, isNotEmpty, reason: ok.error);
    expect(ok.myLocation, demoStart);

    final none = stateOf();
    await none.setDestination(demoEnd);
    expect(none.routes, isEmpty);
    expect(none.error, contains('местоположение'));
    // после указания точки отправления маршрут строится
    await none.setStart(demoStart, label: 'А');
    expect(none.routes, isNotEmpty);
    none.clear();
    expect(none.hasDestination, isFalse);
  });

  test('точка назначения вне ЕС даёт сообщение, а не маршрут', () async {
    final st = stateOf(location: demoStart);
    await st.setDestination(const LatLon(46.95, 7.45));
    expect(st.routes, isEmpty);
    expect(st.error, contains('Евросоюз'));
  });

  testWidgets('экран: поиск «Куда едем?», затем карточка маршрута без каких-либо настроек', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final state = stateOf(location: demoStart);
    await tester.pumpWidget(MaterialApp(home: HomePage(state: state)));
    await tester.pump();
    expect(find.text('Куда едем?'), findsOneWidget);
    expect(find.byIcon(Icons.tune), findsNothing);
    expect(find.byIcon(Icons.settings), findsNothing);

    await tester.tap(find.text('Куда едем?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Демо-маршрут'));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(state.routes, isNotEmpty, reason: state.error);
    expect(find.text('В путь'), findsOneWidget);
    expect(find.textContaining('Самый быстрый маршрут'), findsOneWidget);
    expect(find.textContaining('Плата за проезд'), findsOneWidget);
    expect(find.text('Город Б (демо)'), findsOneWidget);
  });
}
