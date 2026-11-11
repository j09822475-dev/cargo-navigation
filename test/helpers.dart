import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cargo_navigation/core/countries.dart';
import 'package:cargo_navigation/core/geo.dart';
import 'package:cargo_navigation/core/prefs.dart';
import 'package:cargo_navigation/core/road_graph.dart';
import 'package:cargo_navigation/core/toll_model.dart';
import 'package:cargo_navigation/core/weather.dart';
import 'package:cargo_navigation/engine/demo_source.dart';
import 'package:cargo_navigation/engine/road_source.dart';

final countries = CountryIndex.parse(File('assets/geo/countries.json').readAsStringSync());

List<String> operatorFiles() {
  final index = jsonDecode(File('assets/tariffs/index.json').readAsStringSync()) as Map<String, dynamic>;
  return [for (final n in (index['files'] as List).cast<String>()) File('assets/tariffs/$n').readAsStringSync()];
}

final tolls = TollModel.parse(File('assets/tariffs/countries.json').readAsStringSync(), operatorFiles());

RoadGraph graphOf(List<WaySpec> specs) => RoadGraph.build([waysFromSpecs(specs)], countries: countries);

class Call {
  final String kind;
  final Set<int> classes;
  final double radius, lengthMeters;
  Call(this.kind, this.classes, this.radius, this.lengthMeters);
}

/// Имитация Overpass на синтетической сети: фильтрует пути по классу и по области/коридору.
class FakeSource implements RoadSource {
  final List<WaySpec> specs;
  final List<Call> calls = [];
  FakeSource(this.specs);

  bool _cls(WaySpec s, Set<int> classes) =>
      classes.contains(roadClasses.indexOf(s.tags['highway']!.replaceAll('_link', '')));

  @override
  Future<WayData> fetchBox(Bbox b, Set<int> classes, CancelToken cancel) async {
    calls.add(Call('box', classes, 0, 0));
    return waysFromSpecs([
      for (final s in specs)
        if (_cls(s, classes) && s.nodes.any((n) => n.$2 >= b.south && n.$2 <= b.north && n.$3 >= b.west && n.$3 <= b.east)) s
    ]);
  }

  static double distToSegment(LatLon p, LatLon a, LatLon b) {
    final kx = math.cos(p.lat * math.pi / 180);
    final dx = (b.lon - a.lon) * kx, dy = b.lat - a.lat;
    final px = (p.lon - a.lon) * kx, py = p.lat - a.lat;
    final l2 = dx * dx + dy * dy;
    final t = l2 == 0 ? 0.0 : ((px * dx + py * dy) / l2).clamp(0.0, 1.0);
    return haversine(p.lat, p.lon, a.lat + dy * t, a.lon + (b.lon - a.lon) * t);
  }

  @override
  Future<WayData> fetchCorridor(List<LatLon> line, double r, Set<int> classes, CancelToken cancel) async {
    var len = 0.0;
    for (var i = 1; i < line.length; i++) {
      len += haversine(line[i - 1].lat, line[i - 1].lon, line[i].lat, line[i].lon);
    }
    calls.add(Call('corridor', classes, r, len));
    bool near(double la, double lo) {
      for (var i = 1; i < line.length; i++) {
        if (distToSegment(LatLon(la, lo), line[i - 1], line[i]) <= r) return true;
      }
      return false;
    }

    return waysFromSpecs([
      for (final s in specs)
        if (_cls(s, classes) && s.nodes.any((n) => near(n.$2, n.$3))) s
    ]);
  }
}

class FakeWeather implements WeatherSource {
  final WeatherPoint Function(LatLon p) at;
  int calls = 0;
  FakeWeather(this.at);
  @override
  Future<List<WeatherPoint>?> current(List<LatLon> points) async {
    calls++;
    return [for (final p in points) at(p)];
  }
}
