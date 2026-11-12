import 'dart:math' as math;
import 'dart:typed_data';

import '../core/countries.dart';
import '../core/geo.dart';
import '../core/prefs.dart';
import '../core/route_data.dart';
import '../core/router.dart';
import '../core/toll_model.dart';
import '../core/weather.dart';
import 'engine.dart';
import 'road_source.dart';
import 'route_api.dart';
import 'spine.dart';

/// Маршруты любой длины по ЕС через серверы маршрутов (Valhalla, запасной — OSRM).
///
/// * Длинный путь делится на участки не длиннее [legStraightMax] по прямой; точки стыка берутся на опорной
///   линии, проложенной по странам ЕС ([euSpine]). Если сервер всё равно отказывается («слишком длинный»),
///   участок делится пополам.
/// * Если участок маршрута заходит в страну вне ЕС, он перестраивается через точку опорной линии рядом
///   с этим местом (до [maxDepth] раз).
/// * Варианты: обычный (с альтернативами) и без платных дорог; стоимость (плата за км, виньетки, тоннели)
///   считается по странам вдоль линии маршрута; основной — оптимальный по времени с приоритетом бесплатных дорог.
class OnlineRouter implements RoutePlanner {
  final List<RoutingProvider> providers; // по приоритету

  /// Сервер без ограничения длины (OSRM): даёт опорный маршрут для расстановки точек стыка.
  final RoutingProvider? guide;
  final CountryIndex countries;
  TollModel tolls;
  final WeatherSource? weather;

  /// Длиннее этого по прямой маршрут строится по участкам (ограничение Valhalla — 1500 км пути).
  static const singleStraightMax = 1000000.0;
  static const legStraightMax = 900000.0;

  /// Длина участка по дороге, когда точки стыка ставятся на опорном маршруте.
  static const legRoadMax = 1200000.0;
  static const maxMeters = 6000000.0;
  static const maxDepth = 3;

  OnlineRouter(this.providers, {this.guide, required this.countries, required this.tolls, this.weather});

  @override
  Future<PlanOutcome> plan(LatLon start, LatLon end, {Progress? onProgress, CancelToken? cancel}) async {
    final token = cancel ?? CancelToken();
    final km = haversine(start.lat, start.lon, end.lat, end.lon) / 1000;
    final reject = countries.rejectReason(start.lat, start.lon, 'Точка отправления') ??
        countries.rejectReason(end.lat, end.lon, 'Точка назначения');
    if (reject != null) return PlanOutcome(error: reject, distanceKm: km);
    if (km * 1000 > maxMeters) return PlanOutcome(error: 'Слишком большое расстояние (${km.round()} км).', distanceKm: km);

    final spine = euSpine(countries, start, end);
    final spineLen = _length(spine);
    final failures = <String, String>{};
    final candidates = <RouteCandidate>[];

    // Опорная линия и точки стыка. Короткий путь по ЕС без обходов — один запрос с альтернативами.
    var ref = spine;
    var points = <LatLon>[start, end];
    final detour = spineLen > km * 1000 * 1.05;
    if (km * 1000 > singleStraightMax || detour) {
      points = _legPoints(spine, legStraightMax);
      final g = guide;
      if (g != null) {
        try {
          onProgress?.call('Прокладываю общий маршрут…');
          final res = await g.route(start, end, avoidTolls: false, alternatives: true, cancel: token);
          final inEu = res.where((r) => _firstNonEu(r) < 0).toList();
          if (inEu.isNotEmpty && identical(inEu.first, res.first)) {
            // лучший маршрут целиком в ЕС — точки стыка ставим на нём: так участки идут по тем же магистралям
            ref = _asLine(res.first.pts, 2000);
            points = _legPoints(ref, legRoadMax);
          }
        } on CancelledException {
          rethrow;
        } on ProviderException catch (e) {
          failures[g.name] = e.message;
        } catch (e) {
          failures[g.name] = describeNetworkError(e);
        }
      }
    }
    var legsUsed = points.length - 1;

    onProgress?.call(points.length > 2 ? 'Строю маршрут по участкам (${points.length - 1})…' : 'Строю маршрут…');
    final normal = await _variant(points, ref, avoidTolls: false, failures: failures, cancel: token, progress: onProgress);
    if (normal == null) return PlanOutcome(error: _failureText(failures), distanceKm: km);
    final provider = normal.provider;
    candidates.addAll(normal.routes);
    legsUsed = math.max(legsUsed, normal.legs);
    // вариант без платных дорог — только если в обычных вариантах есть платное
    final priced = [for (final c in candidates) _price(c)];
    if (provider == 'Valhalla' && priced.any((p) => p.money > 0)) {
      token.check();
      onProgress?.call('Ищу вариант без платных дорог…');
      final free = await _variant(points, ref, avoidTolls: true, failures: <String, String>{}, cancel: token, progress: onProgress);
      if (free != null) {
        for (final r in free.routes) {
          candidates.add(r);
          priced.add(_price(r));
        }
      }
    }

    // погода
    token.check();
    final hours = [for (final c in candidates) c.seconds / 3600];
    final warnings = [for (final _ in candidates) <String>[]];
    final w = weather;
    if (w != null) {
      try {
        onProgress?.call('Проверяю погоду на маршруте…');
        final samples = [for (final c in candidates) samplePolyline(c.pts, 40000, 8)];
        final flat = [for (final s in samples) for (final p in s) p.$1];
        final data = await w.current(flat);
        if (data != null && data.length == flat.length) {
          var off = 0;
          for (var i = 0; i < candidates.length; i++) {
            final s = samples[i];
            final eff = [for (var k = 0; k < s.length; k++) weatherEffect(data[off + k])];
            off += s.length;
            final step = candidates[i].meters / s.length;
            var acc = 0.0, h = 0.0;
            final delay = <String, double>{};
            for (final m in candidates[i].maneuvers) {
              final idx = math.min(s.length - 1, ((acc + m.meters / 2) / step).floor());
              acc += m.meters;
              final f = eff[idx];
              final mh = m.seconds / 3600;
              h += mh / f.factor;
              if (f.label != null) delay[f.label!] = (delay[f.label!] ?? 0) + mh / f.factor - mh;
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
        // погода недоступна — без поправки
      }
    }

    // одинаковые варианты (разница < 0,5 % по длине и < 1 % по времени) показываем один раз
    final keep = <int>[];
    for (var i = 0; i < candidates.length; i++) {
      final dup = keep.any((j) =>
          (candidates[i].meters - candidates[j].meters).abs() < candidates[j].meters * 0.005 &&
          (hours[i] - hours[j]).abs() < hours[j] * 0.01 &&
          (priced[i].money - priced[j].money).abs() < 0.5);
      if (!dup) keep.add(i);
    }
    double score(int i) => hours[i] * RouteProfile.mainLambda + priced[i].money;
    final main = keep.reduce((a, b) => score(b) < score(a) ? b : a);
    final shown = keep
        .where((a) =>
            a == main ||
            !keep.any((b) =>
                b != a &&
                hours[b] <= hours[a] &&
                priced[b].money <= priced[a].money &&
                (hours[b] < hours[a] || priced[b].money < priced[a].money)))
        .toList();
    final fastest = shown.reduce((a, b) => hours[b] < hours[a] ? b : a);
    shown.sort((a, b) => a == main ? -1 : b == main ? 1 : hours[a].compareTo(hours[b]));

    final out = <RouteData>[];
    for (final i in shown) {
      final p = priced[i];
      out.add(_routeData(candidates[i], p, hours[i], [...warnings[i], ...p.warnings], {
        if (i == main) 'best',
        if (i == fastest) 'fastest',
        if (p.known && p.money == 0 && p.unknownMeters <= 1) 'free',
      }));
    }
    final notes = <String>[
      if (legsUsed > 1) 'Дальний маршрут (${km.round()} км по прямой) построен по участкам: $legsUsed.',
      if (provider != 'Valhalla')
        'Основной сервер маршрутов недоступен — маршрут построен через запасной (OSRM): у него нет данных о платных дорогах, поэтому стоимость не рассчитана.',
    ];
    return PlanOutcome(routes: out, distanceKm: km, note: notes.isEmpty ? null : notes.join(' '));
  }

  // ---------- участки ----------
  static double _length(List<LatLon> line) {
    var d = 0.0;
    for (var i = 1; i < line.length; i++) {
      d += haversine(line[i - 1].lat, line[i - 1].lon, line[i].lat, line[i].lon);
    }
    return d;
  }

  /// Линия маршрута как точки примерно через [step] метров.
  static List<LatLon> _asLine(List<double> pts, double step) {
    final out = <LatLon>[LatLon(pts[0], pts[1])];
    var acc = 0.0;
    final n = pts.length ~/ 2;
    for (var i = 1; i < n; i++) {
      acc += haversine(pts[2 * i - 2], pts[2 * i - 1], pts[2 * i], pts[2 * i + 1]);
      if (acc >= step || i == n - 1) {
        out.add(LatLon(pts[2 * i], pts[2 * i + 1]));
        acc = 0;
      }
    }
    return out;
  }

  /// Точки стыка на линии [line] примерно через [maxLen] метров.
  static List<LatLon> _legPoints(List<LatLon> line, double maxLen) => _pick(line, 0, line.length - 1, maxLen);

  /// Начало, конец и промежуточные точки линии между индексами [i0] и [i1] через ~[maxLen] метров.
  static List<LatLon> _pick(List<LatLon> line, int i0, int i1, double maxLen) {
    final cum = <double>[0];
    for (var i = i0 + 1; i <= i1; i++) {
      cum.add(cum.last + haversine(line[i - 1].lat, line[i - 1].lon, line[i].lat, line[i].lon));
    }
    final n = (cum.last / maxLen).ceil();
    final out = <LatLon>[line[i0]];
    var j = 1;
    for (var k = 1; k < n; k++) {
      final target = cum.last * k / n;
      while (j < cum.length - 1 && cum[j] < target) {
        j++;
      }
      if (!identical(out.last, line[i0 + j])) out.add(line[i0 + j]);
    }
    out.add(line[i1]);
    return out;
  }

  static int _nearestIdx(List<LatLon> line, LatLon p) {
    var bi = 0;
    var bd = double.infinity;
    for (var i = 0; i < line.length; i++) {
      final d = haversine(line[i].lat, line[i].lon, p.lat, p.lon);
      if (d < bd) {
        bd = d;
        bi = i;
      }
    }
    return bi;
  }

  Future<({List<RouteCandidate> routes, String provider, int legs})?> _variant(List<LatLon> points, List<LatLon> ref,
      {required bool avoidTolls,
      required Map<String, String> failures,
      required CancelToken cancel,
      Progress? progress}) async {
    for (final p in providers) {
      try {
        final legs = <RouteCandidate>[];
        List<RouteCandidate>? single;
        var count = 0;
        for (var i = 0; i + 1 < points.length; i++) {
          if (points.length > 2) progress?.call('Строю маршрут: участок ${i + 1} из ${points.length - 1}…');
          final r = await _leg(p, points[i], points[i + 1], ref, 0,
              avoidTolls: avoidTolls,
              alternatives: points.length == 2,
              viaA: i > 0,
              viaB: i + 2 < points.length,
              cancel: cancel);
          count += r.legs;
          if (points.length == 2) {
            single = r.routes;
          } else {
            legs.add(r.routes.first);
          }
        }
        return (routes: single ?? [RouteCandidate.join(legs)], provider: p.name, legs: count);
      } on CancelledException {
        rethrow;
      } on ProviderException catch (e) {
        if (!e.unsupported) failures[p.name] = e.message;
      } catch (e) {
        failures[p.name] = describeNetworkError(e);
      }
    }
    return null;
  }

  /// Маршрут участка a→b. Если сервер отказал по длине — участок делится пополам по опорной линии;
  /// если маршрут заходит в страну вне ЕС — участок перестраивается через частые точки опорной линии
  /// (каждые ~150 км, затем ~50 км).
  Future<({List<RouteCandidate> routes, int legs})> _leg(RoutingProvider p, LatLon a, LatLon b, List<LatLon> ref, int depth,
      {required bool avoidTolls,
      required bool alternatives,
      required bool viaA,
      required bool viaB,
      required CancelToken cancel}) async {
    List<RouteCandidate> res;
    final exclude = <LatLon>[];
    for (var attempt = 0;; attempt++) {
      try {
        res = await p.route(a, b,
            avoidTolls: avoidTolls, alternatives: alternatives, cancel: cancel, viaA: viaA, viaB: viaB, exclude: exclude);
      } on ProviderException catch (e) {
        if (!e.tooLong || depth >= maxDepth) rethrow;
        return _through(p, a, b, ref, depth, 0, avoidTolls: avoidTolls, viaA: viaA, viaB: viaB, cancel: cancel);
      }
      final ok = res.where((r) => _firstNonEu(r) < 0).toList();
      if (ok.isNotEmpty) return (routes: ok, legs: 1);
      // Маршрут заходит в страну вне ЕС: запрещаем дороги сразу за каждым таким переходом границы и перестраиваем.
      if (!p.supportsExclude || attempt >= 8 || exclude.length >= 40) break;
      final crossings = _crossings(res.first);
      if (crossings.isEmpty) break;
      exclude.addAll(crossings.take(40 - exclude.length));
    }
    if (depth >= maxDepth) throw const ProviderException('не удалось проложить путь только по странам ЕС');
    return _through(p, a, b, ref, depth, depth == 0 ? 150000 : 50000, avoidTolls: avoidTolls, viaA: viaA, viaB: viaB, cancel: cancel);
  }

  /// Для каждого заезда маршрута в страну вне ЕС — точка в ~300 м за границей (дорога, которую надо запретить).
  List<LatLon> _crossings(RouteCandidate r) {
    final out = <LatLon>[];
    final pts = r.pts;
    bool nonEu(int i) {
      final c = countries.countryAt(pts[2 * i], pts[2 * i + 1]);
      return c >= 0 && !countries.eu[c];
    }

    var i = 0;
    while (true) {
      final bad = _firstNonEu(r, from: i);
      if (bad < 0) break;
      // назад до последней точки в ЕС — там граница
      var j = bad;
      while (j > 0 && nonEu(j - 1)) {
        j--;
      }
      // чуть вперёд от границы, ~300 м
      var k = j, acc = 0.0;
      while (k + 1 < r.pointCount && acc < 300) {
        acc += haversine(pts[2 * k], pts[2 * k + 1], pts[2 * k + 2], pts[2 * k + 3]);
        k++;
      }
      out.add(LatLon(pts[2 * k], pts[2 * k + 1]));
      // дальше — после выхода из страны вне ЕС
      i = bad;
      while (i < r.pointCount && nonEu(i)) {
        i++;
      }
      if (i >= r.pointCount) break;
    }
    return out;
  }

  /// Участок через промежуточные точки опорной линии: через ~[step] метров (0 — одна точка посередине).
  Future<({List<RouteCandidate> routes, int legs})> _through(
      RoutingProvider p, LatLon a, LatLon b, List<LatLon> ref, int depth, double step,
      {required bool avoidTolls, required bool viaA, required bool viaB, required CancelToken cancel}) async {
    var i0 = _nearestIdx(ref, a), i1 = _nearestIdx(ref, b);
    if (i0 > i1) {
      final t = i0;
      i0 = i1;
      i1 = t;
    }
    List<LatLon> mids;
    if (i1 - i0 < 2) {
      throw const ProviderException('не удалось проложить путь только по странам ЕС');
    } else if (step <= 0) {
      mids = [ref[(i0 + i1) ~/ 2]];
    } else {
      final picked = _pick(ref, i0, i1, step);
      mids = picked.sublist(1, picked.length - 1);
      if (mids.isEmpty) mids = [ref[(i0 + i1) ~/ 2]];
    }
    final chain = [a, ...mids, b];
    final parts = <RouteCandidate>[];
    var legs = 0;
    for (var i = 0; i + 1 < chain.length; i++) {
      final r = await _leg(p, chain[i], chain[i + 1], ref, depth + 1,
          avoidTolls: avoidTolls,
          alternatives: false,
          viaA: i == 0 ? viaA : true,
          viaB: i + 2 == chain.length ? viaB : true,
          cancel: cancel);
      parts.add(r.routes.first);
      legs += r.legs;
    }
    return (routes: [RouteCandidate.join(parts)], legs: legs);
  }

  /// Индекс первой точки маршрута (начиная с [from]), уверенно лежащей в стране вне ЕС, или -1.
  int _firstNonEu(RouteCandidate r, {int from = 0}) {
    if (countries.isEmpty) return -1;
    final pts = r.pts;
    var acc = 1e9;
    for (var i = from; i < r.pointCount; i++) {
      if (i > from) acc += haversine(pts[2 * i - 2], pts[2 * i - 1], pts[2 * i], pts[2 * i + 1]);
      if (acc < 1000 && i != r.pointCount - 1) continue;
      acc = 0;
      if (countries.isDeepNonEu(pts[2 * i], pts[2 * i + 1])) return i;
    }
    return -1;
  }

  String _failureText(Map<String, String> failures) {
    final details = failures.entries.map((e) => '${e.key} — ${e.value}').join('; ');
    final net = failures.values.isNotEmpty &&
        failures.values.every((v) => v == 'адрес сервера не найден' || v == 'нет соединения' || v == 'нет ответа');
    if (net) return 'Нет связи с сервером маршрутов. Проверьте интернет (и VPN, если он включён). ($details)';
    if (failures.values.any((v) => v.contains('только по странам ЕС'))) {
      return 'Не удалось проложить маршрут только по странам Евросоюза. ($details)';
    }
    return 'Сервер маршрутов сейчас не ответил. Попробуйте ещё раз через минуту. ($details)';
  }

  // ---------- стоимость ----------
  _Priced _price(RouteCandidate r) {
    if (!r.priced) return _Priced(0, 0, 0, 0, const [], const [], Uint8List(r.maneuvers.length), const [], known: false);
    final pts = r.pts;
    double dist = 0, tollM = 0, official = 0, unknown = 0;
    final vig = <String>{};
    final objs = <int>{};
    final kinds = Uint8List(r.maneuvers.length);
    var ferry = false;
    String? lastIso; // над водой (тоннель под рекой, мост через пролив) страна — как у предыдущего участка
    for (var k = 0; k < r.maneuvers.length; k++) {
      final m = r.maneuvers[k];
      if (m.ferry) ferry = true;
      final names = m.streetNames.join(';');
      for (var i = math.max(1, m.beginIdx + 1); i <= m.endIdx && i < r.pointCount; i++) {
        final la = (pts[2 * i - 2] + pts[2 * i]) / 2, lo = (pts[2 * i - 1] + pts[2 * i + 1]) / 2;
        final seg = haversine(pts[2 * i - 2], pts[2 * i - 1], pts[2 * i], pts[2 * i + 1]);
        if (seg <= 0) continue;
        final iso = countries.isoAt(la, lo) ?? lastIso;
        if (iso == null) continue;
        lastIso = iso;
        final scheme = tolls.of(iso);
        // платный объект с фиксированной ценой (тоннель, мост) — один раз за проезд
        // (только на участках, отмеченных как платные: по номеру дороги платна лишь часть её, например R2 в Антверпене)
        var o = -1;
        for (var q = 0; m.toll && q < tolls.objects.length && o < 0; q++) {
          final obj = tolls.objects[q];
          if (obj.country == iso && obj.matches(names, names)) o = q;
        }
        if (o >= 0) {
          objs.add(o);
          kinds[k] = math.max(kinds[k], 1);
          continue;
        }
        if (scheme != null && scheme.scheme == TollScheme.vignette) {
          // виньетка: на магистралях; в Румынии и Болгарии — на всех национальных дорогах
          if (m.highway || scheme.classes.contains(2)) {
            vig.add(iso);
            if (kinds[k] == 0) kinds[k] = 2;
          } else if (m.toll) {
            unknown += seg;
            kinds[k] = 3;
          }
        } else if (m.toll) {
          if (scheme != null && scheme.scheme == TollScheme.distance) {
            final byRef = scheme.rateForRef(names);
            dist += seg / 1000 * (byRef ?? scheme.perKm);
            tollM += seg;
            if (byRef != null) official += seg;
            kinds[k] = 1;
          } else {
            unknown += seg;
            if (kinds[k] == 0) kinds[k] = 3;
          }
        }
      }
    }
    final vignettes = [
      for (final iso in vig)
        VignetteCharge(iso, tolls.of(iso)!.product, tolls.of(iso)!.priceEur, tolls.of(iso)!.confirmed),
    ];
    final objects = [
      for (final q in objs) ObjectCharge(tolls.objects[q].name, tolls.objects[q].priceEur, tolls.objects[q].confirmed),
    ];
    return _Priced(dist, tollM, official, unknown, vignettes, objects, kinds, [
      if (unknown > 1)
        'Есть платный участок без известной цены (${(unknown / 1000).toStringAsFixed(1)} км): тоннель, мост или перевал',
      if (ferry) 'На маршруте паром — его стоимость не учтена',
    ]);
  }

  RouteData _routeData(RouteCandidate r, _Priced p, double hours, List<String> warnings, Set<String> tags) {
    final ms = r.maneuvers;
    // рёбра навигации = манёвры (кроме последнего «прибытия»)
    final edgeMs = [for (final m in ms) if (!(m.type >= 4 && m.type <= 6)) m];
    final n = edgeMs.length;
    final start = Int32List(n + 1), speed = Int32List(n), toll = Uint8List(n);
    final steps = <Step>[];
    for (var k = 0; k < n; k++) {
      final m = edgeMs[k];
      start[k] = m.beginIdx.clamp(0, r.pointCount - 1);
      final mk = ms.indexOf(m);
      toll[k] = p.kinds[mk];
      final label = m.streetNames.isEmpty ? '' : m.streetNames.first;
      steps.add(Step(turnTypeOfValhalla(m.type), m.instruction, label, m.meters, p.kinds[mk] == 1, 0,
          r.pts[2 * start[k]], r.pts[2 * start[k] + 1], k));
    }
    start[n] = r.pointCount - 1;
    final last = r.pointCount - 1;
    steps.add(Step(TurnType.arrive, 'Вы прибыли в пункт назначения', '', 0, false, 0, r.pts[2 * last], r.pts[2 * last + 1], n));
    return RouteData(tags, hours, hours - r.seconds / 3600, r.meters, p.distanceToll, p.tollMeters, p.officialMeters,
        p.unknownMeters, p.vignettes, p.objects, warnings, Float64List.fromList(r.pts), start, speed, toll, steps,
        costKnown: p.known);
  }
}

class _Priced {
  final double distanceToll, tollMeters, officialMeters, unknownMeters;
  final List<VignetteCharge> vignettes;
  final List<ObjectCharge> objects;
  final Uint8List kinds; // по манёврам: 0 — бесплатно, 1 — плата, 2 — виньетка, 3 — цена неизвестна
  final List<String> warnings;
  final bool known;
  _Priced(this.distanceToll, this.tollMeters, this.officialMeters, this.unknownMeters, this.vignettes, this.objects, this.kinds,
      this.warnings,
      {this.known = true});
  double get money =>
      distanceToll + vignettes.fold(0.0, (s, v) => s + v.priceEur) + objects.fold(0.0, (s, v) => s + v.priceEur);
}
