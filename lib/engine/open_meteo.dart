import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/geo.dart';
import '../core/weather.dart';

/// Текущая погода из Open-Meteo (бесплатно, без ключа): https://open-meteo.com
class OpenMeteoSource implements WeatherSource {
  final http.Client _client;
  OpenMeteoSource([http.Client? client]) : _client = client ?? http.Client();

  static Uri uriFor(List<LatLon> points) => Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': points.map((p) => p.lat.toStringAsFixed(3)).join(','),
        'longitude': points.map((p) => p.lon.toStringAsFixed(3)).join(','),
        'current': 'temperature_2m,precipitation,snowfall,weather_code,wind_gusts_10m',
        'wind_speed_unit': 'kmh',
      });

  /// Разбор ответа: один объект для одной точки или массив объектов для нескольких.
  static List<WeatherPoint>? parse(String body) {
    final j = jsonDecode(body);
    final list = j is List ? j : [j];
    final out = <WeatherPoint>[];
    for (final item in list) {
      final c = (item as Map)['current'];
      if (c is! Map) return null;
      double n(String k) => (c[k] as num?)?.toDouble() ?? 0;
      out.add(WeatherPoint(
        code: (c['weather_code'] as num?)?.toInt() ?? 0,
        precipitation: n('precipitation'),
        snowfall: n('snowfall'),
        gust: n('wind_gusts_10m'),
        temperature: (c['temperature_2m'] as num?)?.toDouble() ?? 15,
      ));
    }
    return out;
  }

  @override
  Future<List<WeatherPoint>?> current(List<LatLon> points) async {
    if (points.isEmpty) return const [];
    final res = await _client.get(uriFor(points)).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return null;
    return parse(utf8.decode(res.bodyBytes));
  }
}
