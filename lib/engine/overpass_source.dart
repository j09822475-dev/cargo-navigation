import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/geo.dart';
import '../core/road_graph.dart';
import 'road_source.dart';

/// Публичные серверы Overpass; пробуются по очереди.
const overpassEndpoints = <String>[
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
  'https://overpass.openstreetmap.fr/api/interpreter',
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

  /// Пауза перед повтором, когда сервер перегружен (429/502/503/504); растёт с каждым кругом.
  final Duration retryDelay;
  final Duration requestTimeout;
  OverpassSource(
      {http.Client? client,
      this.endpoints = overpassEndpoints,
      this.retryDelay = const Duration(seconds: 6),
      this.requestTimeout = const Duration(seconds: 200)})
      : _client = client ?? http.Client();

  @override
  Future<WayData> fetchBox(Bbox box, Set<int> classes, CancelToken cancel) async {
    // Если область не отдают целиком (таймаут, перегрузка) — делим её на четыре части.
    try {
      return await _run(boxQuery(box, classes), cancel);
    } on CancelledException {
      rethrow;
    } catch (e) {
      if ((box.north - box.south) < 0.08 && (box.east - box.west) < 0.08) rethrow;
      final mLat = (box.south + box.north) / 2, mLon = (box.west + box.east) / 2;
      final parts = <WayData>[];
      for (final b in [
        Bbox(box.south, box.west, mLat, mLon),
        Bbox(box.south, mLon, mLat, box.east),
        Bbox(mLat, box.west, box.north, mLon),
        Bbox(mLat, mLon, box.north, box.east),
      ]) {
        parts.add(await _run(boxQuery(b, classes), cancel));
      }
      return mergeWayData(parts);
    }
  }

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

  /// Короткое описание сбоя для сообщения пользователю.
  static String describeError(Object e) {
    final t = e.toString();
    if (e is TimeoutException) return 'нет ответа';
    if (t.contains('Failed host lookup')) return 'адрес сервера не найден';
    if (t.contains('SocketException') || t.contains('Connection')) return 'нет соединения';
    if (t.contains('HandshakeException') || t.contains('CERTIFICATE')) return 'ошибка защищённого соединения';
    if (e is OverpassException) return e.message;
    if (e is FormatException) return 'непонятный ответ';
    return t.length > 60 ? '${t.substring(0, 60)}…' : t;
  }

  Future<WayData> _run(String query, CancelToken cancel) async {
    final failures = <String, String>{}; // сервер → причина последнего сбоя
    for (var round = 0; round < 3; round++) {
      var busy = false;
      for (final url in endpoints) {
        cancel.check();
        final host = Uri.parse(url).host;
        try {
          final res = await _client.post(Uri.parse(url), body: {'data': query}).timeout(requestTimeout);
          if (res.statusCode == 429 || res.statusCode == 502 || res.statusCode == 503 || res.statusCode == 504) {
            failures[host] = 'перегружен (${res.statusCode})';
            busy = true;
            continue;
          }
          if (res.statusCode != 200) {
            failures[host] = 'ответ ${res.statusCode}';
            continue;
          }
          return parseOverpass(utf8.decode(res.bodyBytes));
        } on CancelledException {
          rethrow;
        } catch (e) {
          failures[host] = describeError(e);
        }
      }
      // повторяем круг, только если хоть один сервер жив, но занят
      if (!busy) break;
      cancel.check();
      await Future<void>.delayed(retryDelay * (round + 1));
    }
    final noNetwork = failures.values.every((v) => v == 'адрес сервера не найден' || v == 'нет соединения');
    final details = failures.entries.map((e) => '${e.key} — ${e.value}').join('; ');
    throw OverpassException(noNetwork
        ? 'Нет связи с серверами дорожных данных. Проверьте интернет (и VPN, если он включён). ($details)'
        : 'Серверы дорожных данных OpenStreetMap сейчас не отвечают. Попробуйте ещё раз через минуту. ($details)');
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
