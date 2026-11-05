import 'dart:math' as math;

import '../core/geo.dart';
import '../core/prefs.dart';
import '../core/road_graph.dart';
import '../core/route_data.dart';
import '../core/router.dart';
import '../core/tariffs.dart';
import 'road_source.dart';

class PlanOutcome {
  final List<RouteData>? routes;
  final String? error;
  final String? note; // пояснение (например, что маршрут дальний и строился по коридору)
  final double distanceKm; // расстояние по прямой между точками
  const PlanOutcome({this.routes, this.error, this.note, this.distanceKm = 0});
}

typedef Progress = void Function(String message);

/// Строит маршруты любой длины.
///
/// * До [regionalMaxMeters] — одна загрузка прямоугольной области.
/// * Дальше — иерархически: сначала «каркас» (магистрали/шоссе, при необходимости главные дороги)
///   в коридоре вдоль линии A→B кусками по [chunkMeters], затем узкий коридор вокруг найденного
///   маршрута со всеми разрешёнными типами дорог, и повторный расчёт.
class RoutingEngine {
  final RoadSource source;
  static const regionalMaxMeters = 120000.0;
  static const maxMeters = 6000000.0;
  static const chunkMeters = 150000.0;
  static const spineStepMeters = 30000.0;

  RoutingEngine(this.source, {TariffBook? tariffs}) : tariffs = tariffs ?? TariffBook.empty;

  /// Тарифы операторов платных дорог (пустые — везде ставка из настроек).
  TariffBook tariffs;

  final List<WayData> _pieces = [];
  final Set<String> _have = {};
  RoadGraph? _graph;
  String _areaKey = '';
  String _classKey = '';

  static String _r(LatLon p) => '${p.lat.toStringAsFixed(4)},${p.lon.toStringAsFixed(4)}';
  static String _ck(RoutePrefs p) => (p.classes.toList()..sort()).join(',');

  Future<PlanOutcome> plan(LatLon start, LatLon end, RoutePrefs prefs, {Progress? onProgress, CancelToken? cancel}) async {
    final token = cancel ?? CancelToken();
    final d = haversine(start.lat, start.lon, end.lat, end.lon);
    final km = d / 1000;
    if (d > maxMeters) {
      return PlanOutcome(error: 'Слишком большое расстояние (${km.round()} км). Максимум — ${(maxMeters / 1000).round()} км.', distanceKm: km);
    }
    final key = '${_r(start)}|${_r(end)}|${_ck(prefs)}';

    // 1. Те же точки и типы дорог (смена настроек) либо переезд на уже загруженной сети (перестроение).
    if (_graph != null && _classKey == _ck(prefs)) {
      final g = _graph!;
      final sameArea = key == _areaKey;
      final near = g.nearestNodes(start.lat, start.lon, count: 1, maxMeters: 300).isNotEmpty &&
          g.nearestNodes(end.lat, end.lon, count: 1, maxMeters: 300).isNotEmpty;
      if (sameArea || near) {
        onProgress?.call('Считаю маршруты…');
        final res = planRoutes(g, start, end, prefs, tariffs: tariffs);
        if (res.routes != null) {
          if (!sameArea) _areaKey = key;
          return _ok(g, res, km, d > regionalMaxMeters);
        } else if (sameArea) {
          return PlanOutcome(error: res.error, distanceKm: km);
        }
      }
    }

    // 2. Новая область — сбрасываем накопленные данные.
    _pieces.clear();
    _have.clear();
    _graph = null;
    try {
      PlanOutcome out;
      if (d <= regionalMaxMeters) {
        out = await _planRegional(start, end, prefs, km, onProgress, token);
      } else {
        out = await _planLong(start, end, prefs, km, onProgress, token);
      }
      if (out.routes != null) {
        _areaKey = key;
        _classKey = _ck(prefs);
      } else {
        _graph = null;
      }
      return out;
    } on CancelledException {
      _graph = null;
      rethrow;
    }
  }

  PlanOutcome _ok(RoadGraph g, PlanResult res, double km, bool long, {String? note}) {
    final routes = [for (final r in res.routes!) buildRouteData(g, r)];
    return PlanOutcome(routes: routes, distanceKm: km, note: note);
  }

  Future<void> _ensure(String key, Future<WayData> Function() load) async {
    if (_have.contains(key)) return;
    _pieces.add(await load());
    _have.add(key);
  }

  RoadGraph _rebuild() => _graph = RoadGraph.build(_pieces);

  // ---------- Региональные маршруты ----------
  Future<PlanOutcome> _planRegional(
      LatLon start, LatLon end, RoutePrefs prefs, double km, Progress? progress, CancelToken cancel) async {
    final all = {for (var i = 0; i < roadClasses.length; i++) i};
    final cosLat = math.cos((start.lat + end.lat) / 2 * math.pi / 180).abs().clamp(0.2, 1.0);
    double pad(double a, double b) => math.max(0.03, (a - b).abs() * 0.25);
    final south = math.min(start.lat, end.lat) - pad(start.lat, end.lat);
    final north = math.max(start.lat, end.lat) + pad(start.lat, end.lat);
    final lonPad = math.max(0.03 / cosLat, (start.lon - end.lon).abs() * 0.25);
    final west = math.min(start.lon, end.lon) - lonPad, east = math.max(start.lon, end.lon) + lonPad;
    final area = (north - south) * 111 * (east - west) * 111 * cosLat;
    var mid = all;
    if (area > 10000) {
      mid = {0, 1, 2, 3};
    } else if (area > 1500) {
      mid = {0, 1, 2, 3, 4};
    }
    cancel.check();
    progress?.call('Загружаю дороги OpenStreetMap…');
    await _ensure('box', () => source.fetchBox(Bbox(south, west, north, east), mid, cancel));
    if (mid.length != all.length) {
      await _zones(start, end, all, cancel, small: true);
    }
    cancel.check();
    progress?.call('Строю граф дорог…');
    final g = _rebuild();
    if (g.edgeCount == 0) return PlanOutcome(error: 'В выбранной области нет дорог.', distanceKm: km);
    progress?.call('Считаю маршруты…');
    final res = planRoutes(g, start, end, prefs, tariffs: tariffs);
    if (res.routes == null) return PlanOutcome(error: res.error, distanceKm: km);
    return _ok(g, res, km, false);
  }

  /// Локальные зоны у старта и финиша: [small] — только мелкие дороги вблизи; иначе ещё и дороги средней величины шире.
  Future<void> _zones(LatLon start, LatLon end, Set<int> all, CancelToken cancel,
      {bool small = false, Set<int>? wide}) async {
    for (final (name, p) in [('start', start), ('end', end)]) {
      const near = 0.025;
      final cos = math.cos(p.lat * math.pi / 180).abs().clamp(0.2, 1.0);
      await _ensure('zone-near-$name', () => source.fetchBox(
          Bbox(p.lat - near, p.lon - near / cos, p.lat + near, p.lon + near / cos), all, cancel));
      if (wide != null && wide.isNotEmpty) {
        const far = 0.12;
        await _ensure('zone-far-$name', () => source.fetchBox(
            Bbox(p.lat - far, p.lon - far / cos, p.lat + far, p.lon + far / cos), wide, cancel));
      }
    }
  }

  // ---------- Дальние маршруты ----------
  static const _tiers = <Set<int>>[
    {0, 1},
    {0, 1, 2},
    {0, 1, 2, 3},
  ];

  /// Разбивает ломаную на куски длиной не более [maxMeters] (концы соседних кусков совпадают).
  static List<List<LatLon>> chunkLine(List<LatLon> line, double maxMeters) {
    final chunks = <List<LatLon>>[];
    var cur = <LatLon>[line.first];
    var acc = 0.0;
    for (var i = 1; i < line.length; i++) {
      final seg = haversine(line[i - 1].lat, line[i - 1].lon, line[i].lat, line[i].lon);
      if (acc + seg > maxMeters && cur.length > 1) {
        chunks.add(cur);
        cur = [line[i - 1]];
        acc = 0;
      }
      cur.add(line[i]);
      acc += seg;
    }
    if (cur.length > 1) chunks.add(cur);
    return chunks;
  }

  Future<void> _fetchCorridor(String key, List<LatLon> line, double radius, Set<int> classes, double chunk,
      String what, Progress? progress, CancelToken cancel) async {
    final chunks = chunkLine(line, chunk);
    for (var i = 0; i < chunks.length; i++) {
      cancel.check();
      progress?.call('Загружаю $what: участок ${i + 1} из ${chunks.length}…');
      await _ensure('$key#$i', () => source.fetchCorridor(chunks[i], radius, classes, cancel));
    }
  }

  Future<PlanOutcome> _planLong(
      LatLon start, LatLon end, RoutePrefs prefs, double km, Progress? progress, CancelToken cancel) async {
    final all = {for (var i = 0; i < roadClasses.length; i++) i};
    final spine = greatCirclePoints(start, end, spineStepMeters);
    final d = km * 1000;
    final radius0 = (d * 0.08).clamp(15000.0, 70000.0).toDouble();

    // Каркас: ступенчато расширяем набор классов и ширину коридора, пока не появится связность.
    final attempts = <(Set<int>, double)>[
      (_tiers[0], radius0),
      (_tiers[1], radius0),
      (_tiers[1], radius0 * 2),
      (_tiers[2], radius0 * 2),
      (_tiers[2], math.min(150000, radius0 * 3)),
    ];
    final wide = prefs.classes.intersection({0, 1, 2, 3, 4});
    PlanResult? last;
    RoadGraph? g;
    PlanResult? coarse;
    Set<int> usedTier = {};
    var anyTier = false;
    for (final (tier, radius) in attempts) {
      final classes = tier.intersection(prefs.classes);
      if (classes.isEmpty) continue;
      anyTier = true;
      cancel.check();
      await _zones(start, end, all, cancel, wide: wide);
      for (final c in classes) {
        await _fetchCorridor('spine|${radius.round()}|$c', spine, radius, {c}, chunkMeters,
            'дороги «${classLabels[c].toLowerCase()}» (коридор ${(radius * 2 / 1000).round()} км)', progress, cancel);
      }
      progress?.call('Строю граф дорог…');
      g = _rebuild();
      progress?.call('Ищу маршрут по каркасу дорог…');
      last = planRoutes(g, start, end, prefs, tariffs: tariffs);
      if (last.routes != null) {
        coarse = last;
        usedTier = tier;
        break;
      }
    }
    if (!anyTier) {
      return PlanOutcome(
          error: 'Для маршрутов длиннее ${(regionalMaxMeters / 1000).round()} км включите хотя бы один из типов: '
              'автомагистрали, скоростные шоссе, главные или второстепенные дороги.',
          distanceKm: km);
    }
    if (coarse == null || g == null) {
      return PlanOutcome(
          error: 'Не удалось построить дальний маршрут: ${last?.error ?? 'нет связной сети дорог'} '
              'Возможно, между точками нет дорог (море, граница) или в OpenStreetMap нет данных.',
          distanceKm: km);
    }

    // Уточнение: узкий коридор вокруг найденного маршрута со всеми разрешёнными типами дорог.
    var note = 'Дальний маршрут (${km.round()} км по прямой): построен по каркасу дорог и уточнён вдоль трассы.';
    final extra = prefs.classes.intersection({0, 1, 2, 3, 4, 5}).difference(usedTier);
    final refineOnly = extra;
    if (refineOnly.isNotEmpty) {
      try {
        final best = coarse.routes!.first;
        final line = _routeLine(g, best, 10000);
        final hash = Object.hashAll(best.edges);
        for (final c in refineOnly) {
          await _fetchCorridor('refine|$hash|$c', line, 3000, {c}, 100000,
              'уточнение вдоль трассы («${classLabels[c].toLowerCase()}»)', progress, cancel);
        }
        progress?.call('Строю граф дорог…');
        final g2 = _rebuild();
        progress?.call('Пересчитываю маршруты…');
        final refined = planRoutes(g2, start, end, prefs, tariffs: tariffs);
        if (refined.routes != null) return _ok(g2, refined, km, true, note: note);
        note = '$note (уточнение не удалось, показан маршрут по каркасу)';
      } on CancelledException {
        rethrow;
      } catch (e) {
        note = 'Маршрут построен по каркасу дорог; уточнить вдоль трассы не удалось ($e).';
      }
      _rebuild();
    }
    return _ok(g, coarse, km, true, note: note);
  }

  /// Точки вдоль маршрута с шагом ~step метров (для запроса коридора).
  static List<LatLon> _routeLine(RoadGraph g, RouteResult r, double step) {
    final out = <LatLon>[];
    double acc = 0;
    LatLon? prev;
    for (final e in r.edges) {
      for (var i = g.ptStart[e]; i < g.ptStart[e + 1]; i++) {
        final p = LatLon(g.ptLat[i], g.ptLon[i]);
        if (prev == null) {
          out.add(p);
        } else {
          acc += haversine(prev.lat, prev.lon, p.lat, p.lon);
          if (acc >= step) {
            out.add(p);
            acc = 0;
          }
        }
        prev = p;
      }
    }
    if (prev != null && (out.isEmpty || out.last != prev)) out.add(prev);
    return out;
  }
}
