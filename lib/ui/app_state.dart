import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/geo.dart';
import '../core/prefs.dart';
import '../core/route_data.dart';
import '../engine/demo_source.dart';
import '../engine/routing_service.dart';
import 'nav_controller.dart';

class AppState extends ChangeNotifier {
  AppState(this._plan, {this.cancel});

  final PlanFn _plan;
  final VoidCallback? cancel;
  static const _prefsKey = 'route_prefs_v3';

  RoutePrefs prefs = RoutePrefs();
  LatLon? start, end;
  String startLabel = '', endLabel = '';
  List<RouteData> routes = const [];
  int selected = 0;
  bool busy = false;
  bool demo = false;
  String status = '';
  String? error;
  String? note;
  double distanceKm = 0;
  NavController? nav;
  int _gen = 0;

  RouteData? get route => routes.isEmpty ? null : routes[selected.clamp(0, routes.length - 1)];

  Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_prefsKey);
      if (raw != null) prefs = RoutePrefs.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } catch (_) {}
    notifyListeners();
  }

  Future<void> savePrefs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_prefsKey, jsonEncode(prefs.toJson()));
    } catch (_) {}
  }

  /// Применяет изменение настроек, сохраняет и уведомляет слушателей.
  void updatePrefs(void Function(RoutePrefs p) change) {
    change(prefs);
    savePrefs();
    notifyListeners();
  }

  void setPoint({required bool isStart, required LatLon pos, String? label}) {
    final text = label ?? '${pos.lat.toStringAsFixed(5)}, ${pos.lon.toStringAsFixed(5)}';
    if (isStart) {
      start = pos;
      startLabel = text;
    } else {
      end = pos;
      endLabel = text;
    }
    clearRoutes();
  }

  void swap() {
    final s = start, sl = startLabel;
    start = end;
    startLabel = endLabel;
    end = s;
    endLabel = sl;
    clearRoutes();
  }

  void clearRoutes() {
    routes = const [];
    error = null;
    note = null;
    status = '';
    notifyListeners();
  }

  void select(int i) {
    selected = i;
    notifyListeners();
  }

  void startDemo() {
    demo = true;
    start = demoStart;
    end = demoEnd;
    startLabel = 'Город А (демо)';
    endLabel = 'Город Б (демо)';
    notifyListeners();
  }

  void leaveDemoIfFar() {
    if (demo && start != null && haversine(start!.lat, start!.lon, demoStart.lat, demoStart.lon) > 5000) demo = false;
  }

  Future<void> plan() async {
    final s = start, e = end;
    if (s == null || e == null) {
      error = 'Укажите точки А и Б: найдите адрес или коснитесь карты.';
      notifyListeners();
      return;
    }
    leaveDemoIfFar();
    final gen = ++_gen;
    busy = true;
    error = null;
    note = null;
    status = 'Готовлю маршрут…';
    notifyListeners();
    final out = await _plan(s, e, prefs, demo, (t) {
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
      distanceKm = out.distanceKm;
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
    final e = end;
    if (e == null) return;
    start = pos;
    startLabel = 'Моё местоположение';
    await _disposeNav();
    notifyListeners();
    await plan();
    if (routes.isNotEmpty) await startNavigation(simulate: wasSim);
  }
}
