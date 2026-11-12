import '../core/geo.dart';
import '../core/prefs.dart';
import '../core/road_graph.dart';

class CancelledException implements Exception {
  @override
  String toString() => 'Отменено';
}

class CancelToken {
  bool cancelled = false;
  void check() {
    if (cancelled) throw CancelledException();
  }
}

class Bbox {
  final double south, west, north, east;
  const Bbox(this.south, this.west, this.north, this.east);
  @override
  String toString() => '$south,$west,$north,$east';
}

/// Источник данных о дорогах для локального графа (демо-сеть, в тестах — синтетическая сеть).
abstract class RoadSource {
  Future<WayData> fetchBox(Bbox box, Set<int> classes, CancelToken cancel);

  /// Дороги в полосе радиусом [radiusM] метров вокруг ломаной [line].
  Future<WayData> fetchCorridor(List<LatLon> line, double radiusM, Set<int> classes, CancelToken cancel);
}

String classRegex(Set<int> classes) {
  final names = <String>[];
  for (final c in (classes.toList()..sort())) {
    names..add(roadClasses[c])..add('${roadClasses[c]}_link');
  }
  return '^(${names.join('|')})\$';
}
