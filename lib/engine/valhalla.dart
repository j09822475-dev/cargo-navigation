import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/geo.dart';
import 'road_source.dart';
import 'route_api.dart';

/// Valhalla (FOSSGIS, https://valhalla1.openstreetmap.de): русские инструкции, отметки платных участков,
/// объезд платных дорог. Ограничение публичного сервера — 1500 км на запрос.
class ValhallaProvider implements RoutingProvider {
  final http.Client _client;
  final String endpoint;
  final Pacer _pacer;
  final Duration timeout;
  ValhallaProvider(
      {http.Client? client,
      this.endpoint = 'https://valhalla1.openstreetmap.de/route',
      Duration gap = const Duration(milliseconds: 1100),
      this.timeout = const Duration(seconds: 60)})
      : _client = client ?? http.Client(),
        _pacer = Pacer(gap);

  @override
  String get name => 'Valhalla';

  @override
  bool get supportsExclude => true;

  static Map<String, Object> _loc(LatLon p, bool via, bool avoidTolls) => {
        'lat': p.lat,
        'lon': p.lon,
        // точка стыка — на главной дороге или крупнее, чтобы маршрут не сворачивал в лес к случайной точке
        if (via) 'search_filter': {'min_road_class': 'primary', if (avoidTolls) 'exclude_toll': true},
      };

  static Map<String, Object> requestBody(LatLon a, LatLon b,
          {required bool avoidTolls,
          required bool alternatives,
          bool viaA = false,
          bool viaB = false,
          List<LatLon> exclude = const []}) =>
      {
        'locations': [_loc(a, viaA, avoidTolls), _loc(b, viaB, avoidTolls)],
        if (exclude.isNotEmpty) 'exclude_locations': [for (final p in exclude) {'lat': p.lat, 'lon': p.lon}],
        'costing': 'auto',
        'costing_options': {
          'auto': {'use_tolls': avoidTolls ? 0.0 : 0.5}
        },
        'units': 'kilometers',
        'language': 'ru-RU',
        if (alternatives) 'alternates': 2,
      };

  @override
  Future<List<RouteCandidate>> route(LatLon a, LatLon b,
      {required bool avoidTolls,
      required bool alternatives,
      required CancelToken cancel,
      bool viaA = false,
      bool viaB = false,
      List<LatLon> exclude = const []}) async {
    cancel.check();
    await _pacer.wait();
    cancel.check();
    final res = await _client
        .post(Uri.parse(endpoint),
            headers: const {'Content-Type': 'application/json', 'User-Agent': userAgent},
            body: jsonEncode(
                requestBody(a, b, avoidTolls: avoidTolls, alternatives: alternatives, viaA: viaA, viaB: viaB, exclude: exclude)))
        .timeout(timeout);
    return parse(utf8.decode(res.bodyBytes), res.statusCode);
  }

  /// Разбор ответа /route (основной маршрут и альтернативы).
  static List<RouteCandidate> parse(String body, int status) {
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw ProviderException('ответ $status');
    }
    if (j['trip'] == null) {
      final code = j['error_code'];
      // 154 — слишком длинный путь; 442/171/170 — точки не связаны дорогами или вне данных
      if (code == 154) throw const ProviderException('слишком длинный участок', tooLong: true);
      if (status == 429) throw const ProviderException('перегружен (429)');
      throw ProviderException('${j['error'] ?? 'ответ $status'}${code != null ? ' [$code]' : ''}');
    }
    return [
      _trip(j['trip'] as Map<String, dynamic>),
      for (final alt in (j['alternates'] as List?) ?? const []) _trip((alt as Map)['trip'] as Map<String, dynamic>),
    ];
  }

  static RouteCandidate _trip(Map<String, dynamic> trip) {
    final pts = <double>[];
    final ms = <Maneuver>[];
    for (final leg in (trip['legs'] as List)) {
      final shape = decodePolyline(leg['shape'] as String);
      final offset = pts.isEmpty ? 0 : pts.length ~/ 2 - 1;
      pts.addAll(pts.isEmpty ? shape : shape.sublist(2));
      for (final m in (leg['maneuvers'] as List)) {
        final names = <String>[
          for (final n in (m['street_names'] as List?) ?? const []) n as String,
          for (final n in (m['begin_street_names'] as List?) ?? const []) n as String,
        ];
        ms.add(Maneuver(
          (m['type'] as num).toInt(),
          (m['instruction'] as String?) ?? '',
          names,
          ((m['length'] as num?) ?? 0) * 1000,
          ((m['time'] as num?) ?? 0).toDouble(),
          m['toll'] == true,
          m['highway'] == true,
          m['travel_type'] == 'ferry' || m['type'] == 28,
          (m['begin_shape_index'] as num).toInt() + offset,
          (m['end_shape_index'] as num).toInt() + offset,
        ));
      }
    }
    final s = trip['summary'] as Map<String, dynamic>;
    return RouteCandidate(pts, ms, ((s['length'] as num) * 1000).toDouble(), (s['time'] as num).toDouble(), 'Valhalla');
  }
}
