import 'dart:math' as math;

const double _earthR = 6371000;
const double _rad = math.pi / 180;

/// Расстояние между точками по большому кругу, метры.
double haversine(double lat1, double lon1, double lat2, double lon2) {
  final dLat = (lat2 - lat1) * _rad, dLon = (lon2 - lon1) * _rad;
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * _rad) * math.cos(lat2 * _rad) * math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthR * math.asin(math.sqrt(a.toDouble()));
}

/// Начальный азимут 0..360.
double bearing(double lat1, double lon1, double lat2, double lon2) {
  final y = math.sin((lon2 - lon1) * _rad) * math.cos(lat2 * _rad);
  final x = math.cos(lat1 * _rad) * math.sin(lat2 * _rad) -
      math.sin(lat1 * _rad) * math.cos(lat2 * _rad) * math.cos((lon2 - lon1) * _rad);
  return (math.atan2(y, x) / _rad + 360) % 360;
}

/// Точка на большом круге между a и b, f — доля 0..1.
(double, double) interpolateGreatCircle(double lat1, double lon1, double lat2, double lon2, double f) {
  final p1 = lat1 * _rad, l1 = lon1 * _rad, p2 = lat2 * _rad, l2 = lon2 * _rad;
  final d = haversine(lat1, lon1, lat2, lon2) / _earthR;
  if (d < 1e-9) return (lat1, lon1);
  final a = math.sin((1 - f) * d) / math.sin(d), b = math.sin(f * d) / math.sin(d);
  final x = a * math.cos(p1) * math.cos(l1) + b * math.cos(p2) * math.cos(l2);
  final y = a * math.cos(p1) * math.sin(l1) + b * math.cos(p2) * math.sin(l2);
  final z = a * math.sin(p1) + b * math.sin(p2);
  return (math.atan2(z, math.sqrt(x * x + y * y)) / _rad, math.atan2(y, x) / _rad);
}

class LatLon {
  final double lat, lon;
  const LatLon(this.lat, this.lon);
  @override
  bool operator ==(Object other) => other is LatLon && other.lat == lat && other.lon == lon;
  @override
  int get hashCode => Object.hash(lat, lon);
  @override
  String toString() => '$lat,$lon';
}

/// Опорные точки вдоль большого круга с шагом ~stepMeters (включая концы).
List<LatLon> greatCirclePoints(LatLon a, LatLon b, double stepMeters) {
  final d = haversine(a.lat, a.lon, b.lat, b.lon);
  final n = math.max(1, (d / stepMeters).ceil());
  return [
    for (var i = 0; i <= n; i++)
      if (i == 0) a else if (i == n) b else () {
        final p = interpolateGreatCircle(a.lat, a.lon, b.lat, b.lon, i / n);
        return LatLon(p.$1, p.$2);
      }()
  ];
}
