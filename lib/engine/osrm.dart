import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/geo.dart';
import 'road_source.dart';
import 'route_api.dart';

/// OSRM (FOSSGIS https://routing.openstreetmap.de) — запасной сервер: маршрут любой длины одним запросом,
/// отмечает платные участки, но объезжать их не умеет.
class OsrmProvider implements RoutingProvider {
  final http.Client _client;
  final String endpoint;
  final Pacer _pacer;
  final Duration timeout;
  OsrmProvider(
      {http.Client? client,
      this.endpoint = 'https://routing.openstreetmap.de/routed-car/route/v1/driving',
      Duration gap = const Duration(milliseconds: 1100),
      this.timeout = const Duration(seconds: 60)})
      : _client = client ?? http.Client(),
        _pacer = Pacer(gap);

  @override
  String get name => 'OSRM';

  @override
  bool get supportsExclude => false;

  static Uri uriFor(String endpoint, LatLon a, LatLon b, {required bool alternatives}) => Uri.parse(
      '$endpoint/${a.lon.toStringAsFixed(6)},${a.lat.toStringAsFixed(6)};${b.lon.toStringAsFixed(6)},${b.lat.toStringAsFixed(6)}'
      '?overview=full&geometries=polyline6&steps=true${alternatives ? '&alternatives=2' : ''}');

  @override
  Future<List<RouteCandidate>> route(LatLon a, LatLon b,
      {required bool avoidTolls,
      required bool alternatives,
      required CancelToken cancel,
      bool viaA = false,
      bool viaB = false,
      List<LatLon> exclude = const []}) async {
    if (avoidTolls) throw const ProviderException('объезд платных дорог не поддерживается', unsupported: true);
    cancel.check();
    await _pacer.wait();
    cancel.check();
    final res = await _client.get(uriFor(endpoint, a, b, alternatives: alternatives), headers: const {'User-Agent': userAgent}).timeout(timeout);
    return parse(utf8.decode(res.bodyBytes), res.statusCode);
  }

  static const _mod = {
    'uturn': 12, 'sharp right': 11, 'right': 10, 'slight right': 9, 'straight': 8,
    'slight left': 16, 'left': 15, 'sharp left': 14,
  };
  static const _textByType = {
    8: 'Продолжайте движение', 9: 'Плавно поверните направо', 10: 'Поверните направо', 11: 'Резко поверните направо',
    12: 'Развернитесь', 14: 'Резко поверните налево', 15: 'Поверните налево', 16: 'Плавно поверните налево',
  };

  static List<RouteCandidate> parse(String body, int status) {
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw ProviderException(status == 429 ? 'перегружен (429)' : 'ответ $status');
    }
    if (j['code'] != 'Ok') throw ProviderException('${j['message'] ?? j['code'] ?? 'ответ $status'}');
    return [for (final r in (j['routes'] as List)) _route(r as Map<String, dynamic>)];
  }

  static RouteCandidate _route(Map<String, dynamic> r) {
    final pts = decodePolyline(r['geometry'] as String);
    // индексы точек шагов: геометрия шага — кусок общей линии
    final ms = <Maneuver>[];
    var idx = 0;
    for (final leg in (r['legs'] as List)) {
      for (final st in (leg['steps'] as List)) {
        final g = decodePolyline(st['geometry'] as String);
        final n = g.length ~/ 2;
        final m = st['maneuver'] as Map<String, dynamic>;
        final kind = m['type'] as String;
        final mod = m['modifier'] as String?;
        final name = (st['name'] as String?) ?? '', ref = (st['ref'] as String?) ?? '';
        final label = [if (name.isNotEmpty) name, if (ref.isNotEmpty) ref].join(' / ');
        var type = _mod[mod] ?? 8;
        String text;
        if (kind == 'depart') {
          type = 1;
          text = label.isEmpty ? 'Начните движение' : 'Начните движение по $label';
        } else if (kind == 'arrive') {
          type = 4;
          text = 'Вы прибыли в пункт назначения';
        } else if (kind == 'roundabout' || kind == 'rotary' || kind == 'exit roundabout' || kind == 'exit rotary' || kind == 'roundabout turn') {
          type = 26;
          final exit = m['exit'];
          text = 'На кольце${exit != null ? ' выезжайте на $exit-й съезд' : ' продолжайте движение'}${label.isEmpty ? '' : ' на $label'}';
        } else {
          final base = _textByType[type] ?? 'Продолжайте движение';
          text = label.isEmpty ? base : '$base ${type == 8 ? 'по' : 'на'} $label';
        }
        var toll = false, motorway = false;
        for (final it in (st['intersections'] as List?) ?? const []) {
          final cls = ((it as Map)['classes'] as List?) ?? const [];
          if (cls.contains('toll')) toll = true;
          if (cls.contains('motorway')) motorway = true;
        }
        final begin = idx, end = idx + (n > 0 ? n - 1 : 0);
        ms.add(Maneuver(type, text, [if (name.isNotEmpty) name, ...ref.split(RegExp(r';\s*')).where((x) => x.isNotEmpty)],
            (st['distance'] as num).toDouble(), (st['duration'] as num).toDouble(), toll, motorway, st['mode'] == 'ferry', begin, end));
        idx = end;
      }
    }
    // публичные серверы OSRM не отдают отметок платных дорог и магистралей — стоимость не посчитать
    return RouteCandidate(pts, ms, (r['distance'] as num).toDouble(), (r['duration'] as num).toDouble(), 'OSRM',
        priced: false);
  }
}
