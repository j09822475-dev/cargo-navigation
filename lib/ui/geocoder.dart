import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/geo.dart';

class Place {
  final String title;
  final LatLon pos;
  const Place(this.title, this.pos);
}

/// Поиск адресов через Nominatim (OpenStreetMap). Запросы — только по действию пользователя.
class Geocoder {
  final http.Client _client;
  Geocoder([http.Client? client]) : _client = client ?? http.Client();

  /// Принимает и координаты вида «55.75, 37.62».
  Future<List<Place>> search(String query) async {
    final m = RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*[,; ]\s*(-?\d+(?:\.\d+)?)\s*$').firstMatch(query);
    if (m != null) {
      final p = LatLon(double.parse(m.group(1)!), double.parse(m.group(2)!));
      return [Place('${p.lat.toStringAsFixed(5)}, ${p.lon.toStringAsFixed(5)}', p)];
    }
    final uri = Uri.https('nominatim.openstreetmap.org', '/search',
        {'format': 'json', 'limit': '5', 'accept-language': 'ru', 'q': query});
    final res = await _client.get(uri, headers: {'User-Agent': 'CargoNavigation/1.0 (Android)'});
    if (res.statusCode != 200) throw Exception('Поиск адреса недоступен (${res.statusCode})');
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    return [
      for (final r in list)
        Place((r['display_name'] as String).split(',').take(3).join(','),
            LatLon(double.parse(r['lat'] as String), double.parse(r['lon'] as String)))
    ];
  }
}
