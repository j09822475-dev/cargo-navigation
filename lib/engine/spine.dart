import '../core/countries.dart';
import '../core/geo.dart';
import '../core/router.dart';

/// Опорная линия A→B: большой круг, а если он задевает страны вне ЕС или море —
/// путь по сетке 0,25° в обход стран вне ЕС (море проходимо, но «дорого»).
List<LatLon> euSpine(CountryIndex countries, LatLon a, LatLon b, {double stepMeters = 30000}) {
  final gc = greatCirclePoints(a, b, stepMeters);
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

