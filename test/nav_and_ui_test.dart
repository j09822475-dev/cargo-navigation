import 'package:cargo_navigation/core/prefs.dart';
import 'package:cargo_navigation/core/road_graph.dart';
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

RouteData demoRoute() {
  final g = RoadGraph.build([waysFromSpecs(demoSpecs())]);
  final res = planRoutes(g, demoStart, demoEnd, RoutePrefs(valueOfTime: 3000));
  return buildRouteData(g, res.routes!.first);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('форматирование', () {
    expect(fmtTime(0.5), '30 мин');
    expect(fmtTime(26.5), '1 д 2 ч 30 мин');
    expect(fmtDist(1530), '1.5 км');
    expect(fmtDist(250), '250 м');
    expect(fmtMoney(12345, '₽'), '12 345 ₽');
  });

  test('навигация: прогресс по маршруту до прибытия', () {
    final r = demoRoute();
    final nav = NavProbe(r);
    final n = r.pointCount;
    var prevRemaining = double.infinity;
    for (var i = 0; i < n; i++) {
      nav.c.onFix(r.pts[2 * i], r.pts[2 * i + 1]);
      expect(nav.c.remaining, lessThanOrEqualTo(prevRemaining + 1));
      prevRemaining = nav.c.remaining;
    }
    expect(nav.c.arrived, isTrue);
    expect(nav.c.remaining, lessThan(30));
    expect(nav.offRoute, 0);
  });

  test('навигация: на прямом участке между вершинами позиция остаётся на маршруте', () {
    final r = demoRoute();
    final nav = NavProbe(r);
    // середина между двумя первыми разными точками
    final la = (r.pts[2] + r.pts[4]) / 2, lo = (r.pts[3] + r.pts[5]) / 2;
    nav.c.onFix(la, lo);
    expect(nav.offRoute, 0);
    expect(nav.c.remaining, lessThan(nav.c.total));
  });

  test('навигация: уход с маршрута вызывает перестроение после трёх точек', () {
    final r = demoRoute();
    final nav = NavProbe(r);
    for (var i = 0; i < 3; i++) {
      nav.c.onFix(r.pts[0] + 0.5, r.pts[1] + 0.5);
    }
    expect(nav.offRoute, 1);
  });

  testWidgets('демо: кнопка строит маршруты и показывает карточки', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final engine = RoutingEngine(DemoSource());
    final state = AppState((s, e, p, demo, pr) => engine.plan(s, e, p, onProgress: pr));
    await tester.pumpWidget(MaterialApp(home: HomePage(state: state)));
    await tester.pump();
    expect(find.text('Построить маршрут'), findsOneWidget);

    await tester.tap(find.text('Демо без интернета'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.routes, isNotEmpty, reason: state.error);
    // раскрываем шторку, чтобы карточки попали в видимую область
    await tester.drag(find.text('Построить маршрут'), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.textContaining('Самый быстрый'), findsWidgets);
    expect(find.textContaining('Оптимальный для ваших настроек'), findsOneWidget);
    expect(find.text('Поехали'), findsOneWidget);
  });
}

class NavProbe {
  int offRoute = 0;
  late final NavController c = NavController(r, onOffRoute: (_) => offRoute++);
  final RouteData r;
  NavProbe(this.r);
}
