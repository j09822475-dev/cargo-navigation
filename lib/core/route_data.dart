import 'dart:typed_data';

import 'geo.dart';
import 'prefs.dart';
import 'road_graph.dart';
import 'router.dart';

enum TurnType { depart, straight, slightRight, slightLeft, right, left, sharpRight, sharpLeft, uturn, arrive }

class Step {
  final TurnType type;
  final String text, label;
  final double meters;
  final bool toll;
  final int speed; // лимит на дороге после манёвра, км/ч
  final double lat, lon;
  final int firstEdge; // индекс ребра маршрута, с которого начинается шаг
  const Step(this.type, this.text, this.label, this.meters, this.toll, this.speed, this.lat, this.lon, this.firstEdge);
}

/// Готовый к отображению и навигации маршрут: не зависит от графа (можно передавать между изолятами).
class RouteData {
  final Set<String> tags; // best, fastest, free
  /// Время в пути с учётом погоды, часы.
  final double hours;

  /// Сколько из этого добавила погода, часы.
  final double weatherDelayHours;
  final double meters;
  final double distanceToll, tollMeters, tollOperatorMeters, tollUnknownMeters;
  final List<VignetteCharge> vignettes;
  final List<ObjectCharge> objects;

  /// Предупреждения по маршруту (погода и т. п.).
  final List<String> warnings;
  final Float64List pts; // lat, lon, lat, lon…
  final Int32List edgeStartPt; // для ребра k — индекс точки начала; длина = рёбер + 1
  final Int32List edgeSpeed; // лимит по рёбрам
  final Uint8List edgeToll; // 1 — плата за км, 2 — дорога с виньеткой, 3 — платный объект без цены
  final List<Step> steps;
  const RouteData(this.tags, this.hours, this.weatherDelayHours, this.meters, this.distanceToll, this.tollMeters,
      this.tollOperatorMeters, this.tollUnknownMeters, this.vignettes, this.objects, this.warnings, this.pts, this.edgeStartPt,
      this.edgeSpeed, this.edgeToll, this.steps);

  double get vignetteCost => vignettes.fold(0.0, (s, v) => s + v.priceEur);

  /// Стоимость дороги: платные участки и виньетки, €.
  double get objectCost => objects.fold(0.0, (s, v) => s + v.priceEur);
  double get money => distanceToll + vignetteCost + objectCost;

  /// Есть ли в цене оценочные (неподтверждённые) составляющие.
  bool get estimated => tollMeters - tollOperatorMeters > 1 || vignettes.any((v) => !v.confirmed) ||
      objects.any((o) => !o.confirmed) ||
      tollUnknownMeters > 1;
  int get pointCount => pts.length ~/ 2;
  int get edgeCount => edgeSpeed.length;
}

double _norm(double a) => ((a + 540) % 360) - 180;

TurnType _turnOf(double delta) {
  final a = delta.abs();
  if (a < 20) return TurnType.straight;
  if (a < 60) return delta > 0 ? TurnType.slightRight : TurnType.slightLeft;
  if (a < 125) return delta > 0 ? TurnType.right : TurnType.left;
  if (a < 170) return delta > 0 ? TurnType.sharpRight : TurnType.sharpLeft;
  return TurnType.uturn;
}

const _turnRu = {
  TurnType.straight: 'Продолжайте движение',
  TurnType.slightRight: 'Плавно поверните направо',
  TurnType.slightLeft: 'Плавно поверните налево',
  TurnType.right: 'Поверните направо',
  TurnType.left: 'Поверните налево',
  TurnType.sharpRight: 'Резко поверните направо',
  TurnType.sharpLeft: 'Резко поверните налево',
  TurnType.uturn: 'Развернитесь',
};

String _roadName(RoadGraph g, int e) {
  final name = g.edgeName(e), ref = g.edgeRef(e);
  if (name.isNotEmpty) return ref.isNotEmpty ? '$name ($ref)' : name;
  if (ref.isNotEmpty) return ref;
  return classLabels[g.cls[e]].toLowerCase();
}

RouteData buildRouteData(SearchContext ctx, RouteResult r,
    {double? hours, List<String> warnings = const [], Set<String>? tags}) {
  final g = ctx.g;
  final edges = r.edges;
  final pts = <double>[];
  final edgeStart = Int32List(edges.length + 1);
  final speeds = Int32List(edges.length);
  final tolls = Uint8List(edges.length);
  for (var k = 0; k < edges.length; k++) {
    final e = edges[k];
    edgeStart[k] = pts.length ~/ 2 - (k == 0 ? 0 : 1);
    for (var i = g.ptStart[e] + (k == 0 ? 0 : 1); i < g.ptStart[e + 1]; i++) {
      pts..add(g.ptLat[i])..add(g.ptLon[i]);
    }
    speeds[k] = g.speed[e];
    final kind = ctx.tollKind[e];
    tolls[k] = kind == 3 ? 3 : (kind != 0 ? 1 : (ctx.vig[e] != 0 ? 2 : 0)); // объект с ценой рисуем как платный участок
  }
  edgeStart[edges.length] = pts.length ~/ 2 - 1;

  // пошаговые инструкции
  final steps = <Step>[];
  int? prev;
  String? curLabel;
  Step? cur;
  double curMeters = 0;
  bool curToll = false;
  void flush() {
    final c = cur;
    if (c != null) {
      steps.add(Step(c.type, c.text, c.label, curMeters, curToll || c.toll, c.speed, c.lat, c.lon, c.firstEdge));
    }
  }

  for (var k = 0; k < edges.length; k++) {
    final e = edges[k];
    final label = _roadName(g, e);
    if (cur == null || curLabel != label) {
      flush();
      var type = TurnType.depart;
      String text;
      if (prev != null) {
        double out(int pe) {
          final b = g.ptStart[pe + 1];
          return bearing(g.ptLat[b - 2], g.ptLon[b - 2], g.ptLat[b - 1], g.ptLon[b - 1]);
        }

        double inn(int ne) {
          final a = g.ptStart[ne];
          return bearing(g.ptLat[a], g.ptLon[a], g.ptLat[a + 1], g.ptLon[a + 1]);
        }

        type = _turnOf(_norm(inn(e) - out(prev)));
        text = '${_turnRu[type]} ${type == TurnType.straight ? 'по' : 'на'} $label';
      } else {
        text = 'Начните движение по $label';
      }
      final a = g.ptStart[e];
      cur = Step(type, text, label, 0, tolls[k] == 1, g.speed[e], g.ptLat[a], g.ptLon[a], k);
      curLabel = label;
      curMeters = 0;
      curToll = tolls[k] == 1;
    }
    curMeters += g.len[e];
    if (tolls[k] == 1) curToll = true;
    prev = e;
  }
  flush();
  final lastLat = pts.isEmpty ? 0.0 : pts[pts.length - 2], lastLon = pts.isEmpty ? 0.0 : pts[pts.length - 1];
  steps.add(Step(TurnType.arrive, 'Вы прибыли в пункт назначения', '', 0, false, 0, lastLat, lastLon, edges.length));

  return RouteData(Set.of(tags ?? r.tags), hours ?? r.hours, (hours ?? r.hours) - r.hours, r.meters, r.distanceToll,
      r.tollMeters, r.tollOperatorMeters, r.tollUnknownMeters, r.vignettes, r.objects, warnings, Float64List.fromList(pts),
      edgeStart, speeds, tolls, steps);
}
