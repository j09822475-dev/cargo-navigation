import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/geo.dart';
import 'core/prefs.dart';
import 'core/tariffs.dart';
import 'engine/demo_source.dart';
import 'engine/engine.dart';
import 'engine/overpass_source.dart';
import 'engine/routing_service.dart';
import 'engine/tariff_assets.dart';
import 'ui/app_state.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final tariffFiles = await loadTariffFiles();
  PlanFn plan;
  VoidCallback? cancel;
  if (kIsWeb) {
    // Изоляты недоступны в вебе (используется только для предпросмотра) — считаем в основном потоке.
    final book = TariffBook.parse(tariffFiles);
    final real = RoutingEngine(OverpassSource(), tariffs: book), demo = RoutingEngine(DemoSource(), tariffs: book);
    plan = (LatLon s, LatLon e, RoutePrefs p, bool d, Progress? pr) => (d ? demo : real).plan(s, e, p, onProgress: pr);
  } else {
    final service = await RoutingService.start(tariffFiles: tariffFiles);
    plan = service.plan;
    cancel = service.cancelAll;
  }
  final state = AppState(plan, cancel: cancel);
  await state.load();
  runApp(CargoApp(state: state));
}

class CargoApp extends StatelessWidget {
  const CargoApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cargo Navigation',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF1A73E8), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF1A73E8), brightness: Brightness.dark, useMaterial3: true),
      home: HomePage(state: state),
    );
  }
}
