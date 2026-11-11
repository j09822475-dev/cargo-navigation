import 'dart:convert';
import 'dart:typed_data';

/// Границы стран Европы (assets/geo/countries.json, Natural Earth 1:10m) и быстрый поиск страны по точке.
///
/// Точность границ — порядка километра, поэтому «вне ЕС» считается только точка, которая лежит
/// в стране вне ЕС с запасом [_deepDeg] (см. [isDeepNonEu]): дороги ЕС вдоль границы не теряются.
class CountryIndex {
  final List<String> iso; // индекс страны → код ISO
  final List<bool> eu;
  final List<List<Int32List>> _rings; // страна → контуры (lon, lat в 1e-4°)
  final List<List<Int32List>> _bbox; // страна → рамки контуров [minLon, minLat, maxLon, maxLat]
  final Map<int, int> _cells = {}; // кэш сетки 0.1°: индекс страны, -1 — нет, -2 — смешанная ячейка
  final Map<int, int> _fine = {}; // кэш сетки 0.01° для смешанных ячеек

  static const _deepDeg = 0.015; // ~1,5 км
  static const minLat = 27.0, maxLat = 72.0, minLon = -32.0, maxLon = 45.0;

  CountryIndex._(this.iso, this.eu, this._rings, this._bbox);

  static final empty = CountryIndex._(const [], const [], const [], const []);
  bool get isEmpty => iso.isEmpty;

  factory CountryIndex.parse(String text) {
    final j = jsonDecode(text) as Map<String, dynamic>;
    final iso = <String>[];
    final eu = <bool>[];
    final rings = <List<Int32List>>[], boxes = <List<Int32List>>[];
    for (final c in (j['countries'] as List)) {
      iso.add(c['iso'] as String);
      eu.add(c['eu'] as bool);
      final rs = <Int32List>[], bs = <Int32List>[];
      for (final r in (c['rings'] as List)) {
        final a = Int32List.fromList((r as List).cast<int>());
        var x0 = a[0], x1 = a[0], y0 = a[1], y1 = a[1];
        for (var i = 0; i < a.length; i += 2) {
          if (a[i] < x0) x0 = a[i];
          if (a[i] > x1) x1 = a[i];
          if (a[i + 1] < y0) y0 = a[i + 1];
          if (a[i + 1] > y1) y1 = a[i + 1];
        }
        rs.add(a);
        bs.add(Int32List.fromList([x0, y0, x1, y1]));
      }
      rings.add(rs);
      boxes.add(bs);
    }
    return CountryIndex._(iso, eu, rings, boxes);
  }

  int indexOf(String code) => iso.indexOf(code);

  static bool _inRing(Int32List r, double x, double y) {
    var inside = false;
    final n = r.length;
    var xj = r[n - 2], yj = r[n - 1];
    for (var i = 0; i < n; i += 2) {
      final xi = r[i], yi = r[i + 1];
      if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside;
      xj = xi;
      yj = yi;
    }
    return inside;
  }

  int _exact(double lat, double lon) {
    final x = lon * 1e4, y = lat * 1e4;
    for (var c = 0; c < _rings.length; c++) {
      final bs = _bbox[c], rs = _rings[c];
      for (var k = 0; k < rs.length; k++) {
        final b = bs[k];
        if (x < b[0] || x > b[2] || y < b[1] || y > b[3]) continue;
        if (_inRing(rs[k], x, y)) return c;
      }
    }
    return -1;
  }

  int _cell(Map<int, int> cache, double lat, double lon, int perDeg) {
    final cx = (lon * perDeg).floor(), cy = (lat * perDeg).floor();
    final key = (cx + 400000) * 1048576 + (cy + 400000);
    var v = cache[key];
    if (v == null) {
      // ячейка однородна, если углы и центр в одной стране
      final a = _exact(cy / perDeg, cx / perDeg);
      v = (a == _exact(cy / perDeg, (cx + 1) / perDeg) &&
              a == _exact((cy + 1) / perDeg, cx / perDeg) &&
              a == _exact((cy + 1) / perDeg, (cx + 1) / perDeg) &&
              a == _exact((cy + 0.5) / perDeg, (cx + 0.5) / perDeg))
          ? a
          : -2;
      cache[key] = v;
    }
    return v;
  }

  /// Индекс страны в точке или -1 (море, вне рамки Европы).
  /// Двухуровневый кэш: ячейки 0.1°, в приграничных — 0.01°, и только в них точная проверка.
  int countryAt(double lat, double lon) {
    if (isEmpty) return -1;
    var v = _cell(_cells, lat, lon, 10);
    if (v != -2) return v;
    v = _cell(_fine, lat, lon, 100);
    return v == -2 ? _exact(lat, lon) : v;
  }

  String? isoAt(double lat, double lon) {
    final c = countryAt(lat, lon);
    return c < 0 ? null : iso[c];
  }

  bool inEuropeFrame(double lat, double lon) => lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon;

  bool _nonEu(double lat, double lon) {
    final c = countryAt(lat, lon);
    return c >= 0 && !eu[c];
  }

  /// Точка уверенно лежит в стране вне ЕС (с запасом на неточность границы).
  bool isDeepNonEu(double lat, double lon) {
    if (isEmpty || !_nonEu(lat, lon)) return false;
    const d = _deepDeg;
    return _nonEu(lat + d, lon) && _nonEu(lat - d, lon) && _nonEu(lat, lon + d * 1.5) && _nonEu(lat, lon - d * 1.5);
  }

  /// Можно ли строить маршрут до точки: в рамке Европы и не в стране вне ЕС.
  /// Возвращает null, если можно, иначе текст причины.
  String? rejectReason(double lat, double lon, String what) {
    if (isEmpty) return null;
    if (!inEuropeFrame(lat, lon)) return '$what вне Европы. Навигация работает только по странам Евросоюза.';
    if (isDeepNonEu(lat, lon)) {
      return '$what находится в стране, не входящей в Евросоюз (${iso[countryAt(lat, lon)]}). '
          'Маршруты строятся только по странам ЕС.';
    }
    return null;
  }
}
