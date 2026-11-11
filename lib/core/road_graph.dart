import 'dart:typed_data';

import 'countries.dart';
import 'geo.dart';
import 'prefs.dart';

// ---------- Растущие типизированные буферы ----------
class F64Buf {
  Float64List _a = Float64List(1024);
  int length = 0;
  void add(double v) {
    if (length == _a.length) _a = Float64List(_a.length * 2)..setRange(0, length, _a);
    _a[length++] = v;
  }

  Float64List take() => Float64List.sublistView(_a, 0, length);
}

class I32Buf {
  Int32List _a = Int32List(1024);
  int length = 0;
  void add(int v) {
    if (length == _a.length) _a = Int32List(_a.length * 2)..setRange(0, length, _a);
    _a[length++] = v;
  }

  Int32List take() => Int32List.sublistView(_a, 0, length);
}

// ---------- Данные OSM ----------
class WayInfo {
  final int cls; // индекс в roadClasses
  final bool link;
  final int dir; // 0 — в обе стороны, 1 — только вперёд, 2 — только назад
  final String name, ref, operator;
  final bool toll;
  final int fwd, bwd; // лимиты, км/ч
  final bool hasMaxspeed; // false — лимит взят по умолчанию
  const WayInfo(this.cls, this.link, this.dir, this.name, this.ref, this.operator, this.toll, this.fwd, this.bwd,
      {this.hasMaxspeed = true});
}

/// Компактный набор путей (результат одного запроса к OSM).
class WayData {
  final List<int> ids;
  final List<WayInfo> infos;
  final Int32List offsets; // длина ids.length + 1
  final List<int> nodeIds;
  final Float64List lats, lons;
  const WayData(this.ids, this.infos, this.offsets, this.nodeIds, this.lats, this.lons);
  static final empty = WayData(const [], const [], Int32List(1), const <int>[], Float64List(0), Float64List(0));
  int get wayCount => ids.length;
}

int? parseMaxspeed(Object? raw) {
  if (raw == null) return null;
  final v = raw.toString().trim().toLowerCase();
  if (v.isEmpty) return null;
  if (v == 'none' || v == 'unlimited') return 130;
  if (v == 'walk') return 7;
  var m = RegExp(r'^(\d+(?:\.\d+)?)\s*mph$').firstMatch(v);
  if (m != null) return (double.parse(m.group(1)!) * 1.609).round();
  m = RegExp(r'^(\d+(?:\.\d+)?)(\s*km/h)?$').firstMatch(v);
  if (m != null) return double.parse(m.group(1)!).round();
  if (v.contains('living_street')) return 20;
  if (v.contains('urban')) return 60;
  if (v.contains('motorway')) return 110;
  if (RegExp(r'rural|national|trunk').hasMatch(v)) return 90;
  m = RegExp(r'\d+').firstMatch(v);
  return m == null ? null : int.parse(m.group(0)!);
}

/// Разбор тегов пути; null — путь не подходит для авто.
WayInfo? wayInfoFromTags(Map<String, dynamic> t) {
  final hw = t['highway'];
  if (hw is! String) return null;
  final link = hw.endsWith('_link');
  final cls = roadClasses.indexOf(hw.replaceAll('_link', ''));
  if (cls < 0) return null;
  bool bad(Object? v) => v == 'no' || v == 'private';
  if (bad(t['access']) || bad(t['motor_vehicle']) || t['motorcar'] == 'no') return null;
  var dir = 0;
  final ow = t['oneway'];
  if (ow == '-1' || ow == 'reverse') {
    dir = 2;
  } else if (ow == 'yes' || ow == 'true' || ow == '1') {
    dir = 1;
  } else if (ow != 'no' && (t['junction'] == 'roundabout' || t['junction'] == 'circular' || cls == 0)) {
    dir = 1;
  }
  final def = link ? (defaultSpeed[cls] < 50 ? defaultSpeed[cls] : 50) : defaultSpeed[cls];
  final tagged = parseMaxspeed(t['maxspeed']);
  final base = tagged ?? def;
  return WayInfo(
    cls,
    link,
    dir,
    (t['name'] as String?) ?? '',
    (t['ref'] as String?) ?? '',
    (t['operator'] as String?) ?? '',
    t['toll'] == 'yes' || t['toll:motor_vehicle'] == 'yes',
    parseMaxspeed(t['maxspeed:forward']) ?? base,
    parseMaxspeed(t['maxspeed:backward']) ?? base,
    hasMaxspeed: tagged != null || t['maxspeed:forward'] != null,
  );
}

// ---------- Граф ----------
class RoadGraph {
  final int nodeCount, edgeCount;
  final Float64List lat, lon; // узлы
  // CSR-списки смежности: исходящие и входящие рёбра
  final Int32List outStart, outEdges, inStart, inEdges;
  final Int32List from, to;
  final Float64List len; // метры
  final Uint8List speed; // лимит км/ч
  final Uint8List cls;
  final Uint8List toll; // 0/1
  final Uint8List country; // индекс страны + 1 (0 — неизвестно/море)
  final List<String> countryIso; // индекс страны → ISO
  final int droppedNonEu; // сколько рёбер отброшено как лежащие вне ЕС
  final Int32List nameIdx, refIdx, opIdx;
  final List<String> strings;
  // геометрия рёбер: точки [ptStart[e], ptStart[e+1]) в ptLat/ptLon
  final Int32List ptStart;
  final Float64List ptLat, ptLon;

  RoadGraph._(this.nodeCount, this.edgeCount, this.lat, this.lon, this.outStart, this.outEdges, this.inStart,
      this.inEdges, this.from, this.to, this.len, this.speed, this.cls, this.toll, this.country, this.countryIso, this.droppedNonEu, this.nameIdx, this.refIdx, this.opIdx,
      this.strings, this.ptStart, this.ptLat, this.ptLon);

  static final empty = RoadGraph.build(const []);

  String edgeName(int e) => strings[nameIdx[e]];
  String edgeRef(int e) => strings[refIdx[e]];
  String edgeOperator(int e) => strings[opIdx[e]];
  String edgeCountry(int e) => country[e] == 0 ? '' : countryIso[country[e] - 1];

  /// Строит граф из наборов путей (дубликаты путей из разных запросов отбрасываются).
  /// С [countries] каждому ребру назначается страна, а рёбра в странах вне ЕС отбрасываются.
  static RoadGraph build(List<WayData> chunks, {CountryIndex? countries}) {
    final ci = (countries == null || countries.isEmpty) ? null : countries;
    var dropped = 0;
    final seen = <int>{};
    final count = <int, int>{};
    // 1) подсчёт использования узлов — перекрёстки там, где узел встречается более одного раза
    for (final c in chunks) {
      for (var w = 0; w < c.wayCount; w++) {
        final s = c.offsets[w], e = c.offsets[w + 1];
        if (e - s < 2 || !seen.add(c.ids[w])) {
          continue;
        }
        for (var i = s; i < e; i++) {
          final id = c.nodeIds[i];
          count[id] = (count[id] ?? 0) + (i == s || i == e - 1 ? 2 : 1);
        }
      }
    }
    seen.clear();
    // 2) нарезка путей на рёбра
    final nodeIndex = <int, int>{};
    final nLat = F64Buf(), nLon = F64Buf();
    int nodeOf(int id, double la, double lo) {
      var i = nodeIndex[id];
      if (i == null) {
        i = nLat.length;
        nodeIndex[id] = i;
        nLat.add(la);
        nLon.add(lo);
      }
      return i;
    }

    final eFrom = I32Buf(), eTo = I32Buf(), eName = I32Buf(), eRef = I32Buf(), eOp = I32Buf(), ePtStart = I32Buf();
    final eLen = F64Buf(), pLat = F64Buf(), pLon = F64Buf();
    final eSpeed = <int>[], eCls = <int>[], eToll = <int>[], eCountry = <int>[];
    final strings = <String>[''];
    final stringIdx = <String, int>{'': 0};
    int str(String s) => stringIdx.putIfAbsent(s, () {
          strings.add(s);
          return strings.length - 1;
        });

    void addEdge(int a, int b, List<double> la, List<double> lo, WayInfo info, int speed, bool reversed) {
      var len = 0.0;
      for (var i = 1; i < la.length; i++) {
        len += haversine(la[i - 1], lo[i - 1], la[i], lo[i]);
      }
      if (len <= 0) return;
      var cIdx = 0;
      if (ci != null) {
        // страна вне ЕС: проверяем концы и точки примерно через километр
        var acc = 1e9;
        for (var i = 0; i < la.length; i++) {
          if (i > 0) acc += haversine(la[i - 1], lo[i - 1], la[i], lo[i]);
          if (acc >= 1000 || i == la.length - 1) {
            acc = 0;
            if (ci.isDeepNonEu(la[i], lo[i])) {
              dropped++;
              return;
            }
          }
        }
        final m = la.length ~/ 2;
        cIdx = ci.countryAt(la[m], lo[m]) + 1;
        if (cIdx > 0 && !info.hasMaxspeed && info.cls == 0 && !info.link) {
          speed = motorwayDefaultByCountry[ci.iso[cIdx - 1]] ?? speed;
        }
      }
      ePtStart.add(pLat.length);
      if (reversed) {
        for (var i = la.length - 1; i >= 0; i--) {
          pLat.add(la[i]);
          pLon.add(lo[i]);
        }
      } else {
        for (var i = 0; i < la.length; i++) {
          pLat.add(la[i]);
          pLon.add(lo[i]);
        }
      }
      eFrom.add(a);
      eTo.add(b);
      eLen.add(len);
      eSpeed.add(speed.clamp(1, 255));
      eCls.add(info.cls);
      eToll.add(info.toll ? 1 : 0);
      eCountry.add(cIdx);
      eName.add(str(info.name));
      eRef.add(str(info.ref));
      eOp.add(str(info.operator));
    }

    for (final c in chunks) {
      for (var w = 0; w < c.wayCount; w++) {
        final s = c.offsets[w], e = c.offsets[w + 1];
        if (e - s < 2 || !seen.add(c.ids[w])) continue;
        final info = c.infos[w];
        var startPos = s;
        var la = <double>[c.lats[s]], lo = <double>[c.lons[s]];
        for (var i = s + 1; i < e; i++) {
          la.add(c.lats[i]);
          lo.add(c.lons[i]);
          if ((count[c.nodeIds[i]] ?? 0) > 1) {
            final a = nodeOf(c.nodeIds[startPos], c.lats[startPos], c.lons[startPos]);
            final b = nodeOf(c.nodeIds[i], c.lats[i], c.lons[i]);
            if (a != b || la.length > 2) {
              if (info.dir != 2) addEdge(a, b, la, lo, info, info.fwd, false);
              if (info.dir != 1) addEdge(b, a, la, lo, info, info.bwd, true);
            }
            startPos = i;
            la = <double>[c.lats[i]];
            lo = <double>[c.lons[i]];
          }
        }
      }
    }
    final n = nLat.length, m = eFrom.length;
    ePtStart.add(pLat.length);
    final from = eFrom.take(), to = eTo.take();
    // 3) CSR
    Int32List csrStart(Int32List key) {
      final st = Int32List(n + 1);
      for (var e = 0; e < m; e++) {
        st[key[e] + 1]++;
      }
      for (var i = 0; i < n; i++) {
        st[i + 1] += st[i];
      }
      return st;
    }

    Int32List csrFill(Int32List st, Int32List key) {
      final pos = Int32List.fromList(st), out = Int32List(m);
      for (var e = 0; e < m; e++) {
        out[pos[key[e]]++] = e;
      }
      return out;
    }

    final os = csrStart(from), isArr = csrStart(to);
    return RoadGraph._(
      n,
      m,
      nLat.take(),
      nLon.take(),
      os,
      csrFill(os, from),
      isArr,
      csrFill(isArr, to),
      from,
      to,
      eLen.take(),
      Uint8List.fromList(eSpeed),
      Uint8List.fromList(eCls),
      Uint8List.fromList(eToll),
      Uint8List.fromList(eCountry),
      ci?.iso ?? const [],
      dropped,
      eName.take(),
      eRef.take(),
      eOp.take(),
      strings,
      ePtStart.take(),
      pLat.take(),
      pLon.take(),
    );
  }

  /// k ближайших узлов (с расстоянием в метрах) в радиусе maxMeters.
  List<({int id, double d})> nearestNodes(double la, double lo, {int count = 5, double maxMeters = 3000}) {
    final best = <({int id, double d})>[];
    // грубый фильтр по широте/долготе перед haversine
    final dLat = maxMeters / 111000 + 1e-6;
    for (var i = 0; i < nodeCount; i++) {
      if ((lat[i] - la).abs() > dLat) continue;
      if (outStart[i + 1] == outStart[i] && inStart[i + 1] == inStart[i]) continue; // узел без рёбер
      final d = haversine(la, lo, lat[i], lon[i]);
      if (d > maxMeters) continue;
      if (best.length < count || d < best.last.d) {
        best.add((id: i, d: d));
        best.sort((a, b) => a.d.compareTo(b.d));
        if (best.length > count) best.removeLast();
      }
    }
    return best;
  }
}
