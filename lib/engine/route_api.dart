import 'dart:async';

import '../core/geo.dart';
import 'road_source.dart';

/// Манёвр от сервера маршрутов: участок от одного действия водителя до следующего.
class Maneuver {
  /// Тип манёвра в терминах Valhalla (1 — старт, 4 — финиш, 10 — направо …), см. [turnTypeOfValhalla].
  final int type;
  final String instruction; // готовый текст на русском
  final List<String> streetNames; // названия и номера дорог («A22», «E45», «Pärnu mnt»)
  final double meters, seconds;
  final bool toll; // платный участок по данным OSM
  final bool highway; // автомагистраль
  final bool ferry;
  final int beginIdx, endIdx; // индексы точек линии маршрута
  const Maneuver(this.type, this.instruction, this.streetNames, this.meters, this.seconds, this.toll, this.highway, this.ferry,
      this.beginIdx, this.endIdx);

  Maneuver shifted(int by) =>
      Maneuver(type, instruction, streetNames, meters, seconds, toll, highway, ferry, beginIdx + by, endIdx + by);
}

/// Готовый маршрут от сервера.
class RouteCandidate {
  final List<double> pts; // lat, lon, lat, lon…
  final List<Maneuver> maneuvers;
  final double meters, seconds;
  final String provider;

  /// Есть ли у манёвров отметки платных дорог и магистралей (у OSRM — нет, стоимость не посчитать).
  final bool priced;
  const RouteCandidate(this.pts, this.maneuvers, this.meters, this.seconds, this.provider, {this.priced = true});

  int get pointCount => pts.length ~/ 2;

  /// Склейка участков: финиш одного участка — старт следующего.
  static RouteCandidate join(List<RouteCandidate> legs) {
    if (legs.length == 1) return legs.single;
    final pts = <double>[];
    final ms = <Maneuver>[];
    double m = 0, s = 0;
    for (var i = 0; i < legs.length; i++) {
      final leg = legs[i];
      final offset = pts.isEmpty ? 0 : pts.length ~/ 2 - 1;
      pts.addAll(pts.isEmpty ? leg.pts : leg.pts.sublist(2));
      for (var k = 0; k < leg.maneuvers.length; k++) {
        final man = leg.maneuvers[k];
        // промежуточные «финиш» и «старт» на стыке участков не показываем
        if (i < legs.length - 1 && k == leg.maneuvers.length - 1 && _isArrive(man.type)) continue;
        if (i > 0 && k == 0 && _isDepart(man.type)) {
          ms.add(Maneuver(8, man.instruction.replaceFirst(RegExp(r'^Двигайтесь'), 'Продолжайте движение'), man.streetNames,
              man.meters, man.seconds, man.toll, man.highway, man.ferry, man.beginIdx + offset, man.endIdx + offset));
          continue;
        }
        ms.add(man.shifted(offset));
      }
      m += leg.meters;
      s += leg.seconds;
    }
    return RouteCandidate(pts, ms, m, s, legs.map((l) => l.provider).toSet().join('+'), priced: legs.every((l) => l.priced));
  }

  static bool _isArrive(int t) => t >= 4 && t <= 6;
  static bool _isDepart(int t) => t >= 1 && t <= 3;
}

/// Сбой сервера маршрутов.
class ProviderException implements Exception {
  final String message;
  final bool tooLong; // участок длиннее, чем принимает сервер
  final bool unsupported; // сервер не умеет такой запрос (например, объезд платных дорог)
  const ProviderException(this.message, {this.tooLong = false, this.unsupported = false});
  @override
  String toString() => message;
}

/// Сервер маршрутов (Valhalla, OSRM).
abstract class RoutingProvider {
  String get name;

  /// Маршрут между двумя точками. Первый в списке — основной, дальше альтернативы (если просили и сервер дал).
  /// Умеет ли сервер запрещать отдельные дороги ([route] с exclude).
  bool get supportsExclude;

  /// [viaA]/[viaB] — точка стыка участков (не адрес пользователя): её можно привязать к крупной дороге.
  /// [exclude] — точки, ближайшие дороги к которым использовать нельзя (переходы границ стран вне ЕС).
  Future<List<RouteCandidate>> route(LatLon a, LatLon b,
      {required bool avoidTolls,
      required bool alternatives,
      required CancelToken cancel,
      bool viaA = false,
      bool viaB = false,
      List<LatLon> exclude = const []});
}

/// Декодирование линии (Google encoded polyline) с точностью [precision] знаков.
List<double> decodePolyline(String s, {int precision = 6}) {
  final out = <double>[];
  var i = 0, lat = 0, lon = 0;
  final f = precision == 6 ? 1e6 : 1e5;
  while (i < s.length) {
    for (var k = 0; k < 2; k++) {
      var shift = 0, result = 0, b = 0;
      do {
        b = s.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      // без побитового «~»: в веб-сборке он даёт беззнаковое 32-битное число
      final d = (result & 1) != 0 ? -((result >> 1) + 1) : result >> 1;
      if (k == 0) {
        lat += d;
      } else {
        lon += d;
      }
    }
    out..add(lat / f)..add(lon / f);
  }
  return out;
}

/// Не чаще одного запроса в [gap] к одному серверу (правила публичных серверов OSM).
class Pacer {
  final Duration gap;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  Pacer(this.gap);
  Future<void> wait() async {
    final next = _last.add(gap);
    final now = DateTime.now();
    if (next.isAfter(now)) await Future<void>.delayed(next.difference(now));
    _last = DateTime.now();
  }
}

/// Короткое описание сетевого сбоя для пользователя.
String describeNetworkError(Object e) {
  final t = e.toString();
  if (e is TimeoutException) return 'нет ответа';
  if (t.contains('Failed host lookup')) return 'адрес сервера не найден';
  if (t.contains('SocketException') || t.contains('Connection')) return 'нет соединения';
  if (t.contains('HandshakeException') || t.contains('CERTIFICATE')) return 'ошибка защищённого соединения';
  if (e is ProviderException) return e.message;
  if (e is FormatException) return 'непонятный ответ';
  return t.length > 80 ? '${t.substring(0, 80)}…' : t;
}

const userAgent = 'CargoNavigation/1.0 (Android; +https://github.com/j09822475-dev/cargo-navigation)';
