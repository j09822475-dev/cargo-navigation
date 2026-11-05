import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/geo.dart';
import '../core/road_graph.dart';
import 'road_source.dart';

const overpassEndpoints = <String>[
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
];

/// Запрос на пути в прямоугольнике.
String boxQuery(Bbox b, Set<int> classes) =>
    '[out:json][timeout:180];way["highway"~"${classRegex(classes)}"](${b.south},${b.west},${b.north},${b.east});out body geom qt;';

/// Запрос на пути в полосе вокруг ломаной (оператор around).
String corridorQuery(List<LatLon> line, double radiusM, Set<int> classes) {
  final pts = line.map((p) => '${p.lat.toStringAsFixed(5)},${p.lon.toStringAsFixed(5)}').join(',');
  return '[out:json][timeout:180];way["highway"~"${classRegex(classes)}"](around:${radiusM.round()},$pts);out body geom qt;';
}

/// Разбор ответа Overpass (формат `out body geom`) в компактный WayData.
WayData parseOverpass(String body) {
  final json = jsonDecode(body) as Map<String, dynamic>;
  final remark = json['remark'];
  if (remark is String && remark.contains('error')) throw OverpassException(remark);
  final elements = (json['elements'] as List?) ?? const [];
  final ids = <int>[];
  final infos = <WayInfo>[];
  final offsets = I32Buf()..add(0);
  final nodeIds = <int>[];
  final lats = F64Buf(), lons = F64Buf();
  for (final el in elements) {
    if (el is! Map || el['type'] != 'way') continue;
    final tags = el['tags'];
    final nodes = el['nodes'], geom = el['geometry'];
    if (tags is! Map || nodes is! List || geom is! List || nodes.length != geom.length) continue;
    final info = wayInfoFromTags(Map<String, dynamic>.from(tags));
    if (info == null || nodes.length < 2) continue;
    var ok = true;
    for (final g in geom) {
      if (g == null) {
        ok = false; // клипнутый узел без координат
        break;
      }
    }
    if (!ok) continue;
    ids.add((el['id'] as num).toInt());
    infos.add(info);
    for (var i = 0; i < nodes.length; i++) {
      nodeIds.add((nodes[i] as num).toInt());
      lats.add((geom[i]['lat'] as num).toDouble());
      lons.add((geom[i]['lon'] as num).toDouble());
    }
    offsets.add(nodeIds.length);
  }
  return WayData(ids, infos, offsets.take(), nodeIds, lats.take(), lons.take());
}

class OverpassException implements Exception {
  final String message;
  OverpassException(this.message);
  @override
  String toString() => message;
}

class OverpassSource implements RoadSource {
  final http.Client _client;
  final List<String> endpoints;
  final Duration retryDelay;
  OverpassSource({http.Client? client, this.endpoints = overpassEndpoints, this.retryDelay = const Duration(seconds: 3)})
      : _client = client ?? http.Client();

  @override
  Future<WayData> fetchBox(Bbox box, Set<int> classes, CancelToken cancel) =>
      _run(boxQuery(box, classes), cancel);

  @override
  Future<WayData> fetchCorridor(List<LatLon> line, double radiusM, Set<int> classes, CancelToken cancel) async {
    // Если запрос не выполнился (таймаут, перегрузка) — делим ломаную пополам и пробуем частями.
    try {
      return await _run(corridorQuery(line, radiusM, classes), cancel);
    } on CancelledException {
      rethrow;
    } catch (e) {
      if (line.length <= 2) rethrow;
      final mid = line.length ~/ 2;
      final a = await fetchCorridor(line.sublist(0, mid + 1), radiusM, classes, cancel);
      final b = await fetchCorridor(line.sublist(mid), radiusM, classes, cancel);
      return mergeWayData([a, b]);
    }
  }

  Future<WayData> _run(String query, CancelToken cancel) async {
    Object? last;
    for (var round = 0; round < 2; round++) {
      for (final url in endpoints) {
        cancel.check();
        try {
          final res = await _client
              .post(Uri.parse(url), body: {'data': query})
              .timeout(const Duration(seconds: 200));
          if (res.statusCode == 429 || res.statusCode == 504 || res.statusCode == 502) {
            last = OverpassException('Overpass ${res.statusCode}');
            await Future<void>.delayed(retryDelay);
            continue;
          }
          if (res.statusCode != 200) {
            last = OverpassException('Overpass ${res.statusCode}');
            continue;
          }
          return parseOverpass(utf8.decode(res.bodyBytes));
        } on CancelledException {
          rethrow;
        } catch (e) {
          last = e;
        }
      }
    }
    throw OverpassException('Не удалось загрузить данные OpenStreetMap: ${last ?? 'ошибка сети'}');
  }
}

/// Объединение нескольких WayData в один.
WayData mergeWayData(List<WayData> parts) {
  final ids = <int>[];
  final infos = <WayInfo>[];
  final offsets = I32Buf()..add(0);
  final nodeIds = <int>[];
  final lats = F64Buf(), lons = F64Buf();
  for (final p in parts) {
    for (var w = 0; w < p.wayCount; w++) {
      ids.add(p.ids[w]);
      infos.add(p.infos[w]);
      for (var i = p.offsets[w]; i < p.offsets[w + 1]; i++) {
        nodeIds.add(p.nodeIds[i]);
        lats.add(p.lats[i]);
        lons.add(p.lons[i]);
      }
      offsets.add(nodeIds.length);
    }
  }
  return WayData(ids, infos, offsets.take(), nodeIds, lats.take(), lons.take());
}
