import 'dart:math' as math;

import '../core/countries.dart';
import '../core/geo.dart';
import '../core/prefs.dart';
import '../core/road_graph.dart';
import '../core/route_data.dart';
import '../core/router.dart';
import '../core/toll_model.dart';
import '../core/weather.dart';
import 'road_source.dart';

class PlanOutcome {
  final List<RouteData>? routes;
  final String? error;
  final String? note; // пояснение (например, что маршрут дальний и строился по коридору)
  final double distanceKm; // расстояние по прямой между точками
  const PlanOutcome({this.routes, this.error, this.note, this.distanceKm = 0});
}

typedef Progress = void Function(String message);

/// Строит маршруты любой длины по странам Евросоюза. Настроек нет: всё автоматически.
///
/// * До [regionalMaxMeters] — одна загрузка прямоугольной области.
/// * Дальше — иерархически: «каркас» (магистрали, шоссе и главные дороги) в коридоре
///   вдоль линии A→B, проложенной в обход стран вне ЕС, кусками по [chunkMeters]; затем узкий
///   коридор вокруг найденного маршрута с дорогами помельче и повторный расчёт.
/// * Дороги в странах вне ЕС отбрасываются при построении графа.
/// * Погода вдоль маршрутов снижает расчётную скорость и может поменять выбор основного маршрута.
class RoutingEngine {
  final RoadSource source;
  final CountryIndex countries;
  TollModel tolls;
  final WeatherSource? weather;
  static const regionalMaxMeters = 120000.0;
  static const maxMeters = 6000000.0;
  static const chunkMeters = 150000.0;
  static const spineStepMeters = 30000.0;
  static const refineMaxMeters = 500000.0;

  RoutingEngine(this.source, {CountryIndex? countries, TollModel? tolls, this.weather})
      : countries = countries ?? CountryIndex.empty,
        tolls = tolls ?? TollModel.empty;

  final List<WayData> _pieces = [];
  final Set<String> _have = {};
  RoadGraph? _graph;
  String _areaKey = '';

  static String _r(LatLon p) => '${p.lat.toStringAsFixed(4)},${p.lon.toStringAsFixed(4)}';
  static final _all = {for (var i = 0; i < roadClasses.length; i++) i};

  Future<PlanOutcome> plan(LatLon start, LatLon end, {Progress? onProgress, CancelToken? cancel}) async {
    final token = cancel ?? CancelToken();
    final d = haversine(start.lat, start.lon, end.lat, end.lon);
    final km = d / 1000;
    final reject = countries.rejectReason(start.lat, start.lon, 'Точка отправления') ??
        countries.rejectReason(end.lat, end.lon, 'Точка назначения');
    if (reject != null) return PlanOutcome(error: reject, distanceKm: km);
    if (d > maxMeters) {
      return PlanOutcome(error: 'Слишком большое расстояние (${km.round()} км).', distanceKm: km);
    }
    final key = '${_r(start)}|${_r(end)}';

    // 1. Перестроение на уже загруженной сети (уход с маршрута) либо повтор того же запроса.
    final g0 = _graph;
    if (g0 != null) {
      final sameArea = key == _areaKey;
      final near = g0.nearestNodes(start.lat, start.lon, count: 1, maxMeters: 300).isNotEmpty &&
          g0.nearestNodes(end.lat, end.lon, count: 1, maxMeters: 300).isNotEmpty;
      if (sameArea || near) {
        onProgress?.call('Считаю маршруты…');
        final res = planRoutes(g0, start, end, tolls);
        if (res.routes != null) {
          if (!sameArea) _areaKey = key;
          return _finish(res, km, null, onProgress, token);
        }
      }
    }

    // 2. Новая область — сбрасываем накопленные данные.
    _pieces.clear();
    _have.clear();
    _graph = null;
    try {
      final out = d <= regionalMaxMeters
          ? await _planRegional(start, end, km, onProgress, token)
          : await _planLong(start, end, km, onProgress, token);
      if (out.routes != null) {
        _areaKey = key;
      } else {
        _graph = null;
      }
      return out;
    } on CancelledException {
      _graph = null;
      rethrow;
    } catch (e) {
      // сбой загрузки — понятное сообщение вместо технической ошибки
      _graph = null;
      return PlanOutcome(error: '$e', distanceKm: km);
    }
  }

  // ---------- Погода, метки, итог ----------
  Future<PlanOutcome> _finish(PlanResult res, double km, String? note, Progress? progress, CancelToken cancel) async {
    final ctx = res.ctx!, g = ctx.g, routes = res.routes!;
    final hours = [for (final r in routes) r.hours];
    final warnings = [for (final _ in routes) <String>[]];
    final w = weather;
    if (w != null) {
      try {
        cancel.check();
        progress?.call('Проверяю погоду на маршруте…');
        // точки вдоль каждого маршрута: примерно через 40 км, не более 8 на маршрут
        final samples = <List<(LatLon, double)>>[];
        for (final r in routes) {
          final pts = <double>[];
          for (final e in r.edges) {
            for (var i = g.ptStart[e]; i < g.ptStart[e + 1]; i++) {
              pts..add(g.ptLat[i])..add(g.ptLon[i]);
            }
          }
          samples.add(samplePolyline(pts, 40000, 8));
        }
        final flat = [for (final s in samples) for (final p in s) p.$1];
        final data = await w.current(flat);
        if (data != null && data.length == flat.length) {
          var off = 0;
          for (var i = 0; i < routes.length; i++) {
            final s = samples[i];
            final eff = [for (var k = 0; k < s.length; k++) weatherEffect(data[off + k])];
            off += s.length;
            final step = routes[i].meters / s.length;
            var acc = 0.0, h = 0.0;
            final delay = <String, double>{};
            for (final e in routes[i].edges) {
              final idx = math.min(s.length - 1, ((acc + g.len[e] / 2) / step).floor());
              acc += g.len[e];
              final f = eff[idx];
              final eh = ctx.hours[e] / f.factor;
              h += eh;
              if (f.label != null) delay[f.label!] = (delay[f.label!] ?? 0) + eh - ctx.hours[e];
            }
            hours[i] = h;
            delay.forEach((label, dh) {
              final min = (dh * 60).round();
              warnings[i].add('Погода: $label на маршруте${min > 0 ? ', +$min мин' : ''}');
            });
          }
        }
      } on CancelledException {
        rethrow;
      } catch (_) {
        // погода недоступна — считаем без поправки
      }
    }
    // основной маршрут и метки — с учётом погоды
    final order = [for (var i = 0; i < routes.length; i++) i];
    double score(int i) => hours[i] * RouteProfile.mainLambda + routes[i].money;
    final main = order.reduce((a, b) => score(b) < score(a) ? b : a);
    final fastest = order.reduce((a, b) => hours[b] < hours[a] ? b : a);
    order.sort((a, b) => a == main ? -1 : b == main ? 1 : hours[a].compareTo(hours[b]));
    final out = <RouteData>[];
    for (final i in order) {
      final r = routes[i];
      final w2 = [...warnings[i]];
      if (r.tollUnknownMeters > 1) {
        w2.add('Есть платный участок без известной цены (${(r.tollUnknownMeters / 1000).toStringAsFixed(1)} км): тоннель, мост или перевал');
      }
      out.add(buildRouteData(ctx, r, hours: hours[i], warnings: w2, tags: {
        if (i == main) 'best',
        if (i == fastest) 'fastest',
        if (r.money == 0) 'free',
      }));
    }
    return PlanOutcome(routes: out, distanceKm: km, note: note);
  }

  Future<void> _ensure(String key, Future<WayData> Function() load) async {
    if (_have.contains(key)) return;
    _pieces.add(await load());
    _have.add(key);
  }

  RoadGraph _rebuild() => _graph = RoadGraph.build(_pieces, countries: countries);

  // ---------- Региональные маршруты ----------
  Future<PlanOutcome> _planRegional(LatLon start, LatLon end, double km, Progress? progress, CancelToken cancel) async {
    final cosLat = math.cos((start.lat + end.lat) / 2 * math.pi / 180).abs().clamp(0.2, 1.0);
    double pad(double a, double b) => math.max(0.03, (a - b).abs() * 0.25);
    final south = math.min(start.lat, end.lat) - pad(start.lat, end.lat);
    final north = math.max(start.lat, end.lat) + pad(start.lat, end.lat);
    final lonPad = math.max(0.03 / cosLat, (start.lon - end.lon).abs() * 0.25);
    final west = math.min(start.lon, end.lon) - lonPad, east = math.max(start.lon, end.lon) + lonPad;
    final area = (north - south) * 111 * (east - west) * 111 * cosLat;
    // Чем больше область, тем крупнее дороги: все улицы большого города — это десятки мегабайт,
    // публичные серверы такое не отдают. Улицы у старта и финиша догружаются отдельно (_zones).
    var mid = _all;
    if (area > 10000) {
      mid = {0, 1, 2, 3};
    } else if (area > 1500) {
      mid = {0, 1, 2, 3, 4};
    } else if (area > 150) {
      mid = {0, 1, 2, 3, 4, 5};
    }
    cancel.check();
    progress?.call('Загружаю дороги…');
    await _ensure('box', () => source.fetchBox(Bbox(south, west, north, east), mid, cancel));
    if (mid.length != _all.length) await _zones(start, end, cancel);
    cancel.check();
    progress?.call('Строю граф дорог…');
    final g = _rebuild();
    if (g.edgeCount == 0) return PlanOutcome(error: 'В выбранной области нет дорог.', distanceKm: km);
    progress?.call('Считаю маршруты…');
    final res = planRoutes(g, start, end, tolls);
    if (res.routes == null) return PlanOutcome(error: res.error, distanceKm: km);
    return _finish(res, km, null, progress, cancel);
  }

  /// Локальные зоны у старта и финиша: все дороги вблизи; с [wide] — ещё и дороги средней величины шире.
  Future<void> _zones(LatLon start, LatLon end, CancelToken cancel, {Set<int>? wide}) async {
    for (final (name, p) in [('start', start), ('end', end)]) {
      const near = 0.025;
      final cos = math.cos(p.lat * math.pi / 180).abs().clamp(0.2, 1.0);
      await _ensure('zone-near-$name',
          () => source.fetchBox(Bbox(p.lat - near, p.lon - near / cos, p.lat + near, p.lon + near / cos), _all, cancel));
      if (wide != null && wide.isNotEmpty) {
        const far = 0.12;
        await _ensure('zone-far-$name',
            () => source.fetchBox(Bbox(p.lat - far, p.lon - far / cos, p.lat + far, p.lon + far / cos), wide, cancel));
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

  /// Опорная линия A→B: большой круг, а если он задевает страны вне ЕС или море —
  /// путь по сетке 0,25° в обход стран вне ЕС (море проходимо, но «дорого»).
  List<LatLon> spine(LatLon a, LatLon b) {
    final gc = greatCirclePoints(a, b, spineStepMeters);
    if (countries.isEmpty) return gc;
    bool offEu(LatLon p) {
      final c = countries.countryAt(p.lat, p.lon);
      return c < 0 || !countries.eu[c];
    }

    if (!gc.sublist(1, gc.length - 1).any(offEu)) return gc;
    const cell = 0.25;
    const w = 308, hgt = 180; // рамка Европы в ячейках
    int ix(double lon) => ((lon - CountryIndex.minLon) / cell).floor().clamp(0, w - 1);
    int iy(double lat) => ((lat - CountryIndex.minLat) / cell).floor().clamp(0, hgt - 1);
    double clat(int y) => CountryIndex.minLat + (y + 0.5) * cell;
    double clon(int x) => CountryIndex.minLon + (x + 0.5) * cell;
    final s = iy(a.lat) * w + ix(a.lon), t = iy(b.lat) * w + ix(b.lon);
    final kind = <int, int>{}; // 0 — ЕС, 1 — море, 2 — вне ЕС
    int kindOf(int id) => kind.putIfAbsent(id, () {
          if (id == s || id == t) return 0;
          final c = countries.countryAt(clat(id ~/ w), clon(id % w));
          return c < 0 ? 1 : (countries.eu[c] ? 0 : 2);
        });
    final dist = <int, double>{s: 0};
    final prev = <int, int>{};
    final heap = MinHeap()..push(0, s);
    final done = <int>{};
    while (heap.size > 0) {
      final u = heap.pop();
      if (!done.add(u)) continue;
      if (u == t) break;
      final ux = u % w, uy = u ~/ w;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final vx = ux + dx, vy = uy + dy;
          if (vx < 0 || vy < 0 || vx >= w || vy >= hgt) continue;
          final v = vy * w + vx;
          final k = kindOf(v);
          if (k == 2) continue;
          final step = haversine(clat(uy), clon(ux), clat(vy), clon(vx)) * (k == 1 ? 4 : 1);
          final nd = dist[u]! + step;
          if (nd < (dist[v] ?? double.infinity)) {
            dist[v] = nd;
            prev[v] = u;
            heap.push(nd + haversine(clat(vy), clon(vx), b.lat, b.lon), v);
          }
        }
      }
    }
    if (!prev.containsKey(t) && s != t) return gc;
    final cells = <int>[];
    for (int? c = t; c != null && c != s; c = prev[c]) {
      cells.add(c);
    }
    return [a, for (final c in cells.reversed) if (c != t) LatLon(clat(c ~/ w), clon(c % w)), b];
  }

  Future<void> _fetchCorridor(String key, List<LatLon> line, double radius, Set<int> classes, double chunk, String what,
      Progress? progress, CancelToken cancel) async {
    final chunks = chunkLine(line, chunk);
    for (var i = 0; i < chunks.length; i++) {
      cancel.check();
      progress?.call('Загружаю $what: участок ${i + 1} из ${chunks.length}…');
      await _ensure('$key#$i', () => source.fetchCorridor(chunks[i], radius, classes, cancel));
    }
  }

  Future<PlanOutcome> _planLong(LatLon start, LatLon end, double km, Progress? progress, CancelToken cancel) async {
    final line = spine(start, end);
    final d = km * 1000;
    final radius0 = (d * 0.08).clamp(20000.0, 70000.0).toDouble();

    // Каркас: ступенчато расширяем набор классов и ширину коридора, пока не появится связность.
    // Главные дороги грузятся сразу: без них не найти бесплатную альтернативу платным магистралям.
    final attempts = <(Set<int>, double)>[
      (_tiers[1], radius0),
      (_tiers[1], radius0 * 2),
      (_tiers[2], radius0 * 2),
      (_tiers[2], math.min(150000, radius0 * 3)),
    ];
    PlanResult? last, coarse;
    Set<int> usedTier = {};
    for (final (tier, radius) in attempts) {
      cancel.check();
      await _zones(start, end, cancel, wide: {0, 1, 2, 3, 4});
      // один запрос на участок сразу для всех типов дорог: публичные серверы не терпят длинных серий запросов
      await _fetchCorridor('spine|${radius.round()}|${tier.join(',')}', line, radius, tier, chunkMeters,
          'магистрали и главные дороги (коридор ${(radius * 2 / 1000).round()} км)', progress, cancel);
      progress?.call('Строю граф дорог…');
      final g = _rebuild();
      progress?.call('Ищу маршрут по каркасу дорог…');
      last = planRoutes(g, start, end, tolls);
      if (last.routes != null) {
        coarse = last;
        usedTier = tier;
        break;
      }
    }
    if (coarse == null) {
      return PlanOutcome(
          error: 'Не удалось построить маршрут: ${last?.error ?? 'нет связной сети дорог'} '
              'Возможно, между точками нет дорог по странам ЕС (море, граница).',
          distanceKm: km);
    }

    // Уточнение: узкий коридор вокруг найденного маршрута с дорогами помельче. Только для маршрутов
    // до [refineMaxMeters]: на дальних оно почти не меняет результат, а запросов требует десятки.
    final note = 'Дальний маршрут (${km.round()} км по прямой).';
    final extra = {0, 1, 2, 3, 4, 5}.difference(usedTier);
    if (d <= refineMaxMeters) {
      try {
        final g = coarse.ctx!.g;
        final best = coarse.routes!.first;
        final rl = _routeLine(g, best, 10000);
        await _fetchCorridor('refine|${Object.hashAll(best.edges)}', rl, 3000, extra, 100000,
            'местные дороги вдоль трассы', progress, cancel);
        progress?.call('Строю граф дорог…');
        final g2 = _rebuild();
        progress?.call('Пересчитываю маршруты…');
        final refined = planRoutes(g2, start, end, tolls);
        if (refined.routes != null) return await _finish(refined, km, note, progress, cancel);
      } on CancelledException {
        rethrow;
      } catch (_) {
        // уточнение не удалось — показываем маршрут по каркасу
      }
      _graph = coarse.ctx!.g;
    }
    return _finish(coarse, km, note, progress, cancel);
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
