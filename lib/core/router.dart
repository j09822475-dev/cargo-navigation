import 'dart:math' as math;
import 'dart:typed_data';

import 'geo.dart';
import 'prefs.dart';
import 'road_graph.dart';
import 'toll_model.dart';

double effectiveSpeed(int speedLimit, int cls) =>
    math.max(5, math.min(speedLimit.toDouble(), RouteProfile.vehicleMax) * classFactor[cls]);

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

/// Виньетка, нужная на маршруте.
class VignetteCharge {
  final String iso, product;
  final double priceEur;
  final bool confirmed;
  const VignetteCharge(this.iso, this.product, this.priceEur, this.confirmed);
}

/// Платный объект (тоннель, мост), который проезжает маршрут.
class ObjectCharge {
  final String name;
  final double priceEur;
  final bool confirmed;
  const ObjectCharge(this.name, this.priceEur, this.confirmed);
}

class RouteResult {
  final List<int> edges;
  final double hours, meters;

  /// Плата за километры на платных дорогах, €.
  final double distanceToll;

  /// Длина участков с платой за километр, м.
  final double tollMeters;

  /// Из них посчитано по тарифам операторов (остальное — по средней ставке страны), м.
  final double tollOperatorMeters;

  /// Платные участки без известной цены (тоннели, мосты в странах без общей платы), м.
  final double tollUnknownMeters;
  final List<VignetteCharge> vignettes;
  final List<ObjectCharge> objects;
  final Set<String> tags = {}; // best, fastest, free
  RouteResult(this.edges, this.hours, this.meters, this.distanceToll, this.tollMeters, this.tollOperatorMeters,
      this.tollUnknownMeters, this.vignettes, this.objects);

  double get objectCost => objects.fold(0.0, (s, v) => s + v.priceEur);

  double get vignetteCost => vignettes.fold(0.0, (s, v) => s + v.priceEur);

  /// Стоимость дороги — только платные дороги и виньетки.
  double get money => distanceToll + vignetteCost + objectCost;
}

/// Подготовленные для одного поиска данные: допустимость рёбер, время, платежи.
class SearchContext {
  final RoadGraph g;
  final TollModel tolls;
  final int startNode, endNode;
  final Uint8List allowed;
  final Uint8List tollKind; // 0 — бесплатно, 1 — тариф оператора, 2 — ставка страны, 3 — цена неизвестна, 4 — объект с ценой
  final Uint8List obj; // платный объект (индекс + 1) или 0
  final Uint8List vig; // страна виньетки (индекс + 1) или 0
  final Float64List hours, toll;
  final Float64List vigFee; // цена виньетки по индексу страны + 1
  double vmax = 30;
  SearchContext(this.g, this.tolls, this.startNode, this.endNode)
      : allowed = Uint8List(g.edgeCount),
        tollKind = Uint8List(g.edgeCount),
        vig = Uint8List(g.edgeCount),
        obj = Uint8List(g.edgeCount),
        hours = Float64List(g.edgeCount),
        toll = Float64List(g.edgeCount),
        vigFee = Float64List(g.countryIso.length + 1);
  // буферы поиска переиспользуются между запусками
  late final Float64List dist = Float64List(g.nodeCount * 2);
  late final Int32List prevE = Int32List(g.nodeCount * 2);
  late final Int32List prevS = Int32List(g.nodeCount * 2);
  late final Float64List hCache = Float64List(g.nodeCount);
  final MinHeap heap = MinHeap();
}

SearchContext prepare(RoadGraph g, int startNode, int endNode, TollModel tolls) {
  final ctx = SearchContext(g, tolls, startNode, endNode);
  final schemes = <CountryToll?>[null, for (final iso in g.countryIso) tolls.of(iso)];
  for (var c = 1; c < schemes.length; c++) {
    final s = schemes[c];
    if (s != null && s.scheme == TollScheme.vignette) ctx.vigFee[c] = s.priceEur;
  }
  for (var i = 0; i < g.edgeCount; i++) {
    final cls = g.cls[i];
    final v = effectiveSpeed(g.speed[i], cls), km = g.len[i] / 1000;
    ctx.hours[i] = km / v;
    if (v > ctx.vmax) ctx.vmax = v;
    ctx.allowed[i] = 1;
    final s = schemes[g.country[i]];
    if (s != null && s.scheme == TollScheme.vignette) {
      // в странах с виньетками плата — разовая, за страну; тег toll=yes там обычно и означает виньетку
      if (s.classes.contains(cls)) ctx.vig[i] = g.country[i];
    } else if (g.toll[i] == 1) {
      final rule = tolls.operators.matchCached(g.opIdx[i], g.refIdx[i], () => g.edgeOperator(i), () => g.edgeRef(i));
      final byRef = rule == null ? s?.rateForRef(g.edgeRef(i)) : null;
      final iso = g.edgeCountry(i);
      var o = -1;
      for (var k = 0; k < tolls.objects.length && o < 0; k++) {
        if (tolls.objects[k].country == iso && tolls.objects[k].matches(g.edgeName(i), g.edgeRef(i))) o = k;
      }
      if (o >= 0) {
        ctx.obj[i] = o + 1; // фиксированная плата за объект, не за километры
        ctx.tollKind[i] = 4;
      } else if (rule != null || byRef != null) {
        ctx.toll[i] = km * (rule?.perKm ?? byRef!);
        ctx.tollKind[i] = 1;
      } else if (s != null && s.scheme == TollScheme.distance) {
        ctx.toll[i] = km * s.perKm;
        ctx.tollKind[i] = 2;
      } else {
        ctx.tollKind[i] = 3; // платный объект без известной цены
      }
    }
  }
  return ctx;
}

/// A* для заданного веса времени lambda (€ за час — внутренний параметр компромисса «время ↔ платные дороги»).
///
/// Виньетка — разовая плата за страну. В поиске она начисляется при въезде на дороги с виньеткой
/// (с дороги без виньетки или из другой страны); повторный въезд в той же стране в поиске стоит
/// столько же, поэтому маршрут не «скачет» между платными и бесплатными дорогами. В итоговой
/// стоимости ([summarize]) виньетка каждой страны считается один раз.
RouteResult? search(SearchContext ctx, double lambda) {
  final g = ctx.g;
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
    final node = s >> 1;
    if (node == ctx.endNode) {
      goal = s;
      break;
    }
    final d = dist[s];
    final pe = prevE[s];
    final prevVig = pe < 0 ? 0 : ctx.vig[pe];
    final prevObj = pe < 0 ? 0 : ctx.obj[pe];
    for (var k = g.outStart[node]; k < g.outStart[node + 1]; k++) {
      final ei = g.outEdges[k];
      if (ctx.allowed[ei] == 0) continue;
      final vg = ctx.vig[ei];
      final ns = g.to[ei] * 2 + (vg != 0 ? 1 : 0);
      final ob = ctx.obj[ei];
      final c = d +
          ctx.hours[ei] * lambda +
          ctx.toll[ei] +
          (vg != 0 && vg != prevVig ? ctx.vigFee[vg] : 0) +
          (ob != 0 && ob != prevObj ? ctx.tolls.objects[ob - 1].priceEur : 0);
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
  final g = ctx.g;
  double hrs = 0, m = 0, tollM = 0, tollLen = 0, opLen = 0, unknown = 0;
  final vigs = <int>{};
  final objs = <int>{};
  for (final e in path) {
    hrs += ctx.hours[e];
    m += g.len[e];
    final k = ctx.tollKind[e];
    if (k == 1 || k == 2) {
      tollM += ctx.toll[e];
      tollLen += g.len[e];
      if (k == 1) opLen += g.len[e];
    } else if (k == 3) {
      unknown += g.len[e];
    }
    if (ctx.vig[e] != 0) vigs.add(ctx.vig[e]);
    if (ctx.obj[e] != 0) objs.add(ctx.obj[e]);
  }
  final charges = [
    for (final c in vigs)
      () {
        final s = ctx.tolls.of(g.countryIso[c - 1])!;
        return VignetteCharge(s.iso, s.product, s.priceEur, s.confirmed);
      }()
  ];
  final objCharges = [
    for (final o in objs)
      ObjectCharge(ctx.tolls.objects[o - 1].name, ctx.tolls.objects[o - 1].priceEur, ctx.tolls.objects[o - 1].confirmed)
  ];
  return RouteResult(path, hrs, m, tollM, tollLen, opLen, unknown, charges, objCharges);
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

/// Строит маршруты на фронте Парето «время ↔ платные дороги».
///
/// Первый — основной: оптимальный по скоростному режиму с приоритетом бесплатных дорог
/// ([RouteProfile.mainLambda]). Остальные — альтернативы: самый быстрый и без платных дорог.
PlanResult planRoutes(RoadGraph g, LatLon start, LatLon end, TollModel tolls) {
  final ss = g.nearestNodes(start.lat, start.lon), es = g.nearestNodes(end.lat, end.lon);
  if (ss.isEmpty) return PlanResult.fail('Рядом с точкой старта нет дорог.');
  if (es.isEmpty) return PlanResult.fail('Рядом с точкой назначения нет дорог.');
  const lambdas = <double>[0.01, 2, 8, 20, RouteProfile.mainLambda, 120, 1e6];

  final combos = [for (var i = 0; i < ss.length; i++) for (var j = 0; j < es.length; j++) (i, j)]
    ..sort((a, b) => (a.$1 + a.$2).compareTo(b.$1 + b.$2));
  for (final (i, j) in combos) {
    if (ss[i].id == es[j].id) continue;
    final ctx = prepare(g, ss[i].id, es[j].id, tolls);
    final main = search(ctx, RouteProfile.mainLambda);
    if (main == null) continue;
    final seen = <String, RouteResult>{main.edges.join(','): main};
    for (final l in lambdas) {
      final r = search(ctx, l);
      if (r != null) seen.putIfAbsent(r.edges.join(','), () => r);
    }
    final all = seen.values.toList();
    final list = all
        .where((a) =>
            identical(a, main) ||
            !all.any((b) =>
                !identical(b, a) && b.hours <= a.hours && b.money <= a.money && (b.hours < a.hours || b.money < a.money)))
        .toList();
    tagRoutes(list, main);
    return PlanResult.ok(list, ctx);
  }
  return PlanResult.fail('Маршрут не найден: между точками нет связной сети дорог в странах Евросоюза.');
}

/// Расставляет метки и порядок: основной первым, дальше по времени.
void tagRoutes(List<RouteResult> list, RouteResult main) {
  for (final r in list) {
    r.tags.clear();
  }
  final fastest = list.reduce((a, b) => b.hours < a.hours ? b : a);
  main.tags.add('best');
  fastest.tags.add('fastest');
  for (final r in list) {
    if (r.money == 0) r.tags.add('free');
  }
  list.sort((a, b) => identical(a, main) ? -1 : identical(b, main) ? 1 : a.hours.compareTo(b.hours));
}
