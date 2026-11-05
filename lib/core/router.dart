import 'dart:math' as math;
import 'dart:typed_data';

import 'geo.dart';
import 'prefs.dart';
import 'road_graph.dart';
import 'tariffs.dart';

double effectiveSpeed(int speedLimit, int cls, RoutePrefs p) =>
    math.max(5, math.min(speedLimit.toDouble(), p.vehicleMax) * classFactor[cls]);

class MinHeap {
  Float64List _k = Float64List(256);
  Int32List _v = Int32List(256);
  int size = 0;

  void clear() => size = 0;

  void push(double key, int val) {
    if (size == _k.length) {
      _k = Float64List(size * 2)..setRange(0, size, _k);
      _v = Int32List(size * 2)..setRange(0, size, _v);
    }
    var i = size++;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_k[p] <= key) break;
      _k[i] = _k[p];
      _v[i] = _v[p];
      i = p;
    }
    _k[i] = key;
    _v[i] = val;
  }

  int pop() {
    final top = _v[0];
    final lk = _k[--size], lv = _v[size];
    if (size > 0) {
      var i = 0;
      for (;;) {
        var c = 2 * i + 1;
        if (c >= size) break;
        if (c + 1 < size && _k[c + 1] < _k[c]) c++;
        if (_k[c] >= lk) break;
        _k[i] = _k[c];
        _v[i] = _v[c];
        i = c;
      }
      _k[i] = lk;
      _v[i] = lv;
    }
    return top;
  }
}

class RouteResult {
  final List<int> edges;
  final double hours, meters, tollCost, tollMeters;

  /// Сколько метров платных участков посчитано по тарифам операторов (остальное — по ставке из настроек).
  final double tollKnownMeters;
  final Set<String> tags = {}; // best, fastest, cheapest
  RouteResult(this.edges, this.hours, this.meters, this.tollCost, this.tollMeters, this.tollKnownMeters);

  /// Затраты на дорогу — только платные участки (топливо и цена времени не учитываются).
  double get money => tollCost;
}

/// Подготовленные для одного поиска данные: допустимость рёбер, время, платежи.
class SearchContext {
  final RoadGraph g;
  final RoutePrefs p;
  final int startNode, endNode;
  final Uint8List allowed;
  final Uint8List tollKnown; // 1 — ставка взята из тарифов оператора
  final Float64List hours, toll, mult;
  double vmax = 30;
  SearchContext(this.g, this.p, this.startNode, this.endNode)
      : allowed = Uint8List(g.edgeCount),
        tollKnown = Uint8List(g.edgeCount),
        hours = Float64List(g.edgeCount),
        toll = Float64List(g.edgeCount),
        mult = Float64List(g.edgeCount);
  // буферы поиска переиспользуются между запусками
  late final Float64List dist = Float64List(g.nodeCount * 2);
  late final Int32List prevE = Int32List(g.nodeCount * 2);
  late final Int32List prevS = Int32List(g.nodeCount * 2);
  late final Float64List hCache = Float64List(g.nodeCount);
  final MinHeap heap = MinHeap();
}

void _reach(RoadGraph g, int node, double radius, bool outgoing, Uint8List out) {
  final dist = <int, double>{node: 0};
  final heap = MinHeap()..push(0, node);
  while (heap.size > 0) {
    final n = heap.pop();
    final d = dist[n]!;
    out[n] = 1;
    final st = outgoing ? g.outStart : g.inStart, list = outgoing ? g.outEdges : g.inEdges;
    for (var k = st[n]; k < st[n + 1]; k++) {
      final e = list[k];
      final m = outgoing ? g.to[e] : g.from[e];
      final nd = d + g.len[e];
      if (nd <= radius && nd < (dist[m] ?? double.infinity)) {
        dist[m] = nd;
        heap.push(nd, m);
      }
    }
  }
}

SearchContext prepare(RoadGraph g, int startNode, int endNode, RoutePrefs p, {TariffBook? tariffs}) {
  final access = Uint8List(g.nodeCount);
  _reach(g, startNode, p.accessRadius, true, access);
  _reach(g, endNode, p.accessRadius, false, access);
  final ctx = SearchContext(g, p, startNode, endNode);
  for (var i = 0; i < g.edgeCount; i++) {
    final cls = g.cls[i];
    final v = effectiveSpeed(g.speed[i], cls, p), km = g.len[i] / 1000;
    ctx.hours[i] = km / v;
    if (g.toll[i] == 1) {
      // тариф оператора (по тегам operator/ref), иначе ставка из настроек
      final rule = tariffs?.matchCached(g.opIdx[i], g.refIdx[i], () => g.edgeOperator(i), () => g.edgeRef(i));
      ctx.toll[i] = km * (rule?.perKm ?? p.tollPerKm(cls));
      ctx.tollKnown[i] = rule == null ? 0 : 1;
    }
    ctx.mult[i] = p.tollMode == TollMode.prefer && g.toll[i] == 0 ? p.preferPenalty : 1;
    if (v > ctx.vmax) ctx.vmax = v;
    var ok = true;
    if (p.tollMode == TollMode.free && g.toll[i] == 1) {
      ok = false;
    } else if (!(access[g.from[i]] == 1 && access[g.to[i]] == 1 && isLocalClass(cls))) {
      if (!p.classes.contains(cls) || g.speed[i] < p.minSpeed || g.speed[i] > p.maxSpeed) ok = false;
    }
    ctx.allowed[i] = ok ? 1 : 0;
  }
  return ctx;
}

/// A* для заданного веса времени lambda (€ за час — внутренний параметр компромисса «время ↔ платные дороги»,
/// не настройка пользователя). null — маршрута нет.
RouteResult? search(SearchContext ctx, double lambda) {
  final g = ctx.g, p = ctx.p;
  // В режиме «предпочитать платные» платежи в целевую функцию не входят: выбор делает штраф времени на бесплатных дорогах.
  final prefer = p.tollMode == TollMode.prefer;
  final fee = (p.tollMode == TollMode.free || prefer) ? 0.0 : p.tollEntry;
  final n = g.nodeCount;
  final dist = ctx.dist..fillRange(0, n * 2, double.infinity);
  final prevE = ctx.prevE..fillRange(0, n * 2, -1);
  final prevS = ctx.prevS..fillRange(0, n * 2, -1);
  final hc = ctx.hCache..fillRange(0, n, -1);
  final endLat = g.lat[ctx.endNode], endLon = g.lon[ctx.endNode];
  double h(int node) {
    if (hc[node] < 0) hc[node] = haversine(g.lat[node], g.lon[node], endLat, endLon) / 1000 / ctx.vmax * lambda;
    return hc[node];
  }

  final heap = ctx.heap..clear();
  final s0 = ctx.startNode * 2;
  dist[s0] = 0;
  heap.push(h(ctx.startNode), s0);
  var goal = -1;
  while (heap.size > 0) {
    final s = heap.pop();
    final node = s >> 1, f = s & 1;
    if (node == ctx.endNode) {
      goal = s;
      break;
    }
    final d = dist[s];
    for (var k = g.outStart[node]; k < g.outStart[node + 1]; k++) {
      final ei = g.outEdges[k];
      if (ctx.allowed[ei] == 0) continue;
      final isToll = g.toll[ei];
      final ns = g.to[ei] * 2 + isToll;
      final c = d +
          (ctx.hours[ei] * lambda + (prefer ? 0.0 : ctx.toll[ei])) * ctx.mult[ei] +
          (isToll == 1 && f == 0 ? fee : 0);
      if (c < dist[ns]) {
        dist[ns] = c;
        prevE[ns] = ei;
        prevS[ns] = s;
        heap.push(c + h(g.to[ei]), ns);
      }
    }
  }
  if (goal < 0) return null;
  final path = <int>[];
  for (var s = goal; prevE[s] >= 0; s = prevS[s]) {
    path.add(prevE[s]);
  }
  return summarize(ctx, path.reversed.toList());
}

RouteResult summarize(SearchContext ctx, List<int> path) {
  final g = ctx.g, p = ctx.p;
  double hrs = 0, m = 0, tollM = 0, tollLen = 0, known = 0;
  var inToll = false;
  for (final e in path) {
    hrs += ctx.hours[e];
    m += g.len[e];
    if (g.toll[e] == 1) {
      tollM += ctx.toll[e];
      tollLen += g.len[e];
      if (ctx.tollKnown[e] == 1) known += g.len[e];
      if (!inToll && p.tollMode != TollMode.free) tollM += p.tollEntry;
    }
    inToll = g.toll[e] == 1;
  }
  return RouteResult(path, hrs, m, tollM, tollLen, known);
}

class PlanResult {
  final List<RouteResult>? routes;
  final SearchContext? ctx;
  final String? error;
  PlanResult.ok(this.routes, this.ctx) : error = null;
  PlanResult.fail(this.error)
      : routes = null,
        ctx = null;
}

/// Вес времени для выбранного приоритета: «быстрее» — время важнее любых платежей; «дешевле» — только
/// платные участки, а время лишь разрешает ничьи.
double lambdaFor(Priority p) => p == Priority.fastest ? 1e6 : 0.01;

/// Строит набор маршрутов на фронте Парето «время ↔ платные дороги»; первый — для выбранного приоритета.
PlanResult planRoutes(RoadGraph g, LatLon start, LatLon end, RoutePrefs p, {TariffBook? tariffs}) {
  final ss = g.nearestNodes(start.lat, start.lon), es = g.nearestNodes(end.lat, end.lon);
  if (ss.isEmpty) return PlanResult.fail('Рядом с точкой старта нет дорог в загруженных данных.');
  if (es.isEmpty) return PlanResult.fail('Рядом с точкой финиша нет дорог в загруженных данных.');
  // промежуточные точки фронта Парето: веса от «почти только платежи» до «почти только время»
  final lambdas = <double>[0.01, for (var k = 0; k <= 5; k++) 0.5 * math.pow(4, k), 1e6];

  final combos = [for (var i = 0; i < ss.length; i++) for (var j = 0; j < es.length; j++) (i, j)]
    ..sort((a, b) => (a.$1 + a.$2).compareTo(b.$1 + b.$2));
  for (final (i, j) in combos) {
    if (ss[i].id == es[j].id) continue;
    final ctx = prepare(g, ss[i].id, es[j].id, p, tariffs: tariffs);
    final main = search(ctx, lambdaFor(p.priority));
    if (main == null) continue;
    final seen = <String, RouteResult>{main.edges.join(','): main};
    for (final l in lambdas) {
      final r = search(ctx, l);
      if (r != null) seen.putIfAbsent(r.edges.join(','), () => r);
    }
    var list = seen.values.toList();
    final all = list;
    list = all
        .where((a) =>
            identical(a, main) ||
            !all.any((b) =>
                !identical(b, a) && b.hours <= a.hours && b.money <= a.money && (b.hours < a.hours || b.money < a.money)))
        .toList();
    final fastest = list.reduce((a, b) => b.hours < a.hours ? b : a);
    final cheapest = list.reduce((a, b) => (b.money < a.money || (b.money == a.money && b.hours < a.hours)) ? b : a);
    main.tags.add('best');
    fastest.tags.add('fastest');
    cheapest.tags.add('cheapest');
    list.sort((a, b) => identical(a, main) ? -1 : identical(b, main) ? 1 : a.hours.compareTo(b.hours));
    return PlanResult.ok(list, ctx);
  }
  final why = p.tollMode == TollMode.free
      ? ' Попробуйте разрешить платные дороги или больше типов дорог.'
      : ' Ослабьте фильтры типов дорог и ограничений скорости.';
  return PlanResult.fail('Маршрут по заданным условиям не найден.$why');
}
