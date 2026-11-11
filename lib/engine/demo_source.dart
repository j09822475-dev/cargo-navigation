
import '../core/geo.dart';
import '../core/road_graph.dart';
import 'overpass_source.dart';
import 'road_source.dart';

const demoStart = LatLon(47.002, 2.995);
const demoEnd = LatLon(47.002, 3.805);

/// Построение WayData из простого описания путей (для демо и тестов).
class WaySpec {
  final int id;
  final Map<String, String> tags;
  final List<(int, double, double)> nodes; // (id, lat, lon)
  const WaySpec(this.id, this.tags, this.nodes);
}

WayData waysFromSpecs(List<WaySpec> specs) {
  final ids = <int>[];
  final infos = <WayInfo>[];
  final offsets = I32Buf()..add(0);
  final nodeIds = <int>[];
  final lats = F64Buf(), lons = F64Buf();
  for (final s in specs) {
    final info = wayInfoFromTags(Map<String, dynamic>.from(s.tags));
    if (info == null) continue;
    ids.add(s.id);
    infos.add(info);
    for (final n in s.nodes) {
      nodeIds.add(n.$1);
      lats.add(n.$2);
      lons.add(n.$3);
    }
    offsets.add(nodeIds.length);
  }
  return mergeWayData([WayData(ids, infos, offsets.take(), nodeIds, lats.take(), lons.take())]);
}

/// Демо-сеть (в Бургундии, Франция): платная магистраль оператора APRR, бесплатное шоссе
/// и медленная местная дорога между двумя городами. Дороги выдуманы, тариф APRR — настоящий.
List<WaySpec> demoSpecs() {
  final motor = [for (var i = 0; i <= 8; i++) (100 + i, 47.0, 3.0 + 0.1 * i)];
  return [
    WaySpec(1, {'highway': 'motorway', 'toll': 'yes', 'maxspeed': '130', 'operator': 'APRR', 'ref': 'A 0', 'name': 'Платная магистраль (демо)'}, motor),
    WaySpec(2, {'highway': 'primary', 'maxspeed': '80', 'name': 'Шоссе Северное'},
        [motor.first, (201, 47.05, 3.2), (202, 47.05, 3.4), (203, 47.05, 3.6), motor.last]),
    WaySpec(3, {'highway': 'secondary', 'maxspeed': '70', 'name': 'Съезд к магистрали'}, [(202, 47.05, 3.4), motor[4]]),
    WaySpec(4, {'highway': 'tertiary', 'maxspeed': '50', 'name': 'Южная дорога'},
        [motor.first, (301, 46.95, 3.4), motor.last]),
    WaySpec(5, {'highway': 'residential', 'maxspeed': '30', 'name': 'ул. Центральная'}, [(1, 47.002, 2.995), motor.first]),
    WaySpec(6, {'highway': 'residential', 'maxspeed': '30', 'name': 'ул. Вокзальная'}, [motor.last, (2, 47.002, 3.805)]),
  ];
}

/// Источник для демо-режима: всегда отдаёт демо-сеть, независимо от области запроса.
class DemoSource implements RoadSource {
  final WayData _data = waysFromSpecs(demoSpecs());
  @override
  Future<WayData> fetchBox(Bbox box, Set<int> classes, CancelToken cancel) async => _data;
  @override
  Future<WayData> fetchCorridor(List<LatLon> line, double radiusM, Set<int> classes, CancelToken cancel) async => _data;
}
