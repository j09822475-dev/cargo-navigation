import 'dart:math' as math;

import 'geo.dart';

/// Погода в точке (текущая).
class WeatherPoint {
  final int code; // код погоды WMO
  final double precipitation; // мм/ч
  final double snowfall; // см/ч
  final double gust; // порывы ветра, км/ч
  final double temperature; // °C
  const WeatherPoint({this.code = 0, this.precipitation = 0, this.snowfall = 0, this.gust = 0, this.temperature = 15});
}

/// Источник погоды (в приложении — Open-Meteo, в тестах — подставной).
abstract class WeatherSource {
  /// Погода в точках; null — данных нет (расчёт идёт без поправки).
  Future<List<WeatherPoint>?> current(List<LatLon> points);
}

class WeatherEffect {
  final double factor; // множитель скорости 0..1
  final String? label; // что за явление, для предупреждения
  const WeatherEffect(this.factor, this.label);
}

/// Насколько погода снижает скорость. Коэффициенты — инженерная оценка, не измерения.
WeatherEffect weatherEffect(WeatherPoint w) {
  var f = 1.0;
  String? label;
  void apply(double v, String l) {
    if (v < f) {
      f = v;
      label = l;
    }
  }

  final c = w.code;
  if (w.snowfall >= 1.0 || c == 75 || c == 86) {
    apply(0.55, 'сильный снег');
  } else if (w.snowfall > 0 || (c >= 71 && c <= 77) || c == 85) {
    apply(0.7, 'снег');
  }
  if (c == 56 || c == 57 || c == 66 || c == 67) apply(0.6, 'ледяной дождь');
  if (w.precipitation >= 7.5 || c == 65 || c == 82 || c >= 95) {
    apply(0.8, c >= 95 ? 'гроза' : 'сильный дождь');
  } else if (w.precipitation >= 1.0 || c == 63 || c == 81) {
    apply(0.9, 'дождь');
  }
  if (c == 45 || c == 48) apply(0.8, 'туман');
  if (w.gust >= 90) {
    apply(0.8, 'штормовой ветер');
  } else if (w.gust >= 70) {
    apply(0.9, 'сильный ветер');
  }
  if (w.temperature <= 0 && w.precipitation > 0 && f > 0.75) apply(0.75, 'гололёд');
  return WeatherEffect(f, label);
}

/// Точки вдоль ломаной (lat, lon, …) примерно через [stepMeters], не более [maxPoints].
List<(LatLon, double)> samplePolyline(List<double> pts, double stepMeters, int maxPoints) {
  final n = pts.length ~/ 2;
  if (n == 0) return const [];
  var total = 0.0;
  for (var i = 1; i < n; i++) {
    total += haversine(pts[2 * i - 2], pts[2 * i - 1], pts[2 * i], pts[2 * i + 1]);
  }
  final count = math.max(1, math.min(maxPoints, (total / stepMeters).ceil()));
  final step = total / count;
  final out = <(LatLon, double)>[];
  var acc = 0.0, next = step / 2;
  for (var i = 1; i < n && out.length < count; i++) {
    final seg = haversine(pts[2 * i - 2], pts[2 * i - 1], pts[2 * i], pts[2 * i + 1]);
    while (acc + seg >= next && out.length < count) {
      // точка внутри отрезка, а не ближайшая вершина
      final t = seg <= 0 ? 0.0 : (next - acc) / seg;
      out.add((
        LatLon(pts[2 * i - 2] + (pts[2 * i] - pts[2 * i - 2]) * t, pts[2 * i - 1] + (pts[2 * i + 1] - pts[2 * i - 1]) * t),
        next
      ));
      next += step;
    }
    acc += seg;
  }
  if (out.isEmpty) out.add((LatLon(pts[0], pts[1]), 0));
  return out;
}
