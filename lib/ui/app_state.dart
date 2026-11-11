import 'package:flutter/foundation.dart';

import '../core/geo.dart';
import '../core/route_data.dart';
import '../engine/demo_source.dart';
import '../engine/routing_service.dart';
import 'nav_controller.dart';

/// Определение текущего местоположения (null — недоступно).
typedef LocateFn = Future<LatLon?> Function();

/// Состояние приложения. Настроек нет: пользователь задаёт только точки.
class AppState extends ChangeNotifier {
  AppState(this._plan, {this.cancel, this.locate});

  final PlanFn _plan;
  final VoidCallback? cancel;
  final LocateFn? locate;

  /// Точка отправления; null — «Моё местоположение» (определяется при построении).
  LatLon? start;
  LatLon? end;
  String startLabel = '', endLabel = '';
  LatLon? myLocation;
  List<RouteData> routes = const [];
  int selected = 0;
  bool busy = false;
  bool demo = false;
  String status = '';
  String? error;
  String? note;
  NavController? nav;
  int _gen = 0;

  bool get hasDestination => end != null;
  RouteData? get route => routes.isEmpty ? null : routes[selected.clamp(0, routes.length - 1)];
  String get startTitle => start == null ? 'Моё местоположение' : startLabel;

  static String _coords(LatLon p) => '${p.lat.toStringAsFixed(5)}, ${p.lon.toStringAsFixed(5)}';

  /// Задаёт пункт назначения и сразу строит маршрут.
  Future<void> setDestination(LatLon pos, {String? label}) {
    end = pos;
    endLabel = label ?? _coords(pos);
    _leaveDemoIfFar();
    return plan();
  }

  /// Задаёт точку отправления (null — снова «Моё местоположение») и перестраивает маршрут.
  Future<void> setStart(LatLon? pos, {String? label}) async {
    start = pos;
    startLabel = pos == null ? '' : (label ?? _coords(pos));
    _leaveDemoIfFar();
    if (end != null) await plan();
  }

  Future<void> swap() async {
    final e = end;
    if (e == null) return;
    final s = start ?? myLocation;
    final sl = start == null ? 'Моё местоположение' : startLabel;
    start = e;
    startLabel = endLabel;
    end = s;
    endLabel = s == null ? '' : sl;
    if (end != null) {
      await plan();
    } else {
      notifyListeners();
    }
  }

  /// Сброс к пустой карте.
  void clear() {
    _gen++;
    if (busy) cancel?.call();
    start = null;
    end = null;
    startLabel = endLabel = '';
    routes = const [];
    busy = false;
    demo = false;
    error = note = null;
    status = '';
    notifyListeners();
  }

  void select(int i) {
    selected = i;
    notifyListeners();
  }

  Future<void> startDemo() {
    demo = true;
    start = demoStart;
    startLabel = 'Город А (демо)';
    end = demoEnd;
    endLabel = 'Город Б (демо)';
    return plan();
  }

  void _leaveDemoIfFar() {
    final e = end;
    if (demo && e != null && haversine(e.lat, e.lon, demoEnd.lat, demoEnd.lon) > 50000) demo = false;
  }

  Future<void> plan() async {
    final e = end;
    if (e == null) return;
    final gen = ++_gen;
    busy = true;
    error = null;
    note = null;
    routes = const [];
    status = 'Готовлю маршрут…';
    notifyListeners();
    var s = start;
    if (s == null) {
      status = 'Определяю местоположение…';
      notifyListeners();
      s = await locate?.call();
      if (gen != _gen) return;
      if (s == null) {
        busy = false;
        status = '';
        error = 'Не удалось определить местоположение. Укажите точку отправления: нажмите на верхнюю строку.';
        notifyListeners();
        return;
      }
      myLocation = s;
    }
    final out = await _plan(s, e, demo, (t) {
      if (gen == _gen) {
        status = t;
        notifyListeners();
      }
    });
    if (gen != _gen) return; // устарел — запущен более новый расчёт
    busy = false;
    status = '';
    if (out.routes == null) {
      routes = const [];
      error = out.error;
    } else {
      routes = out.routes!;
      selected = 0;
      note = out.note;
    }
    notifyListeners();
  }

  void cancelPlanning() {
    _gen++;
    cancel?.call();
    busy = false;
    status = '';
    notifyListeners();
  }

  // ---------- навигация ----------
  Future<void> startNavigation({bool simulate = false}) async {
    final r = route;
    if (r == null) return;
    await _disposeNav();
    final n = NavController(r, simulate: simulate || demo, onOffRoute: _reroute);
    n.addListener(notifyListeners); // экран обновляется при каждой новой позиции
    nav = n;
    notifyListeners();
    await n.start();
  }

  Future<void> _disposeNav() async {
    final n = nav;
    nav = null;
    if (n == null) return;
    n.removeListener(notifyListeners);
    await n.stop();
    n.dispose();
  }

  Future<void> stopNavigation() async {
    await _disposeNav();
    notifyListeners();
  }

  Future<void> _reroute(LatLon pos) async {
    final wasSim = nav?.simulate ?? false;
    if (end == null) return;
    start = pos;
    startLabel = 'Моё местоположение';
    await _disposeNav();
    notifyListeners();
    await plan();
    if (routes.isNotEmpty) await startNavigation(simulate: wasSim);
  }
}
