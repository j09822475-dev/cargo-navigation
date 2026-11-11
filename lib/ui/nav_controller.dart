import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/geo.dart';
import '../core/route_data.dart';

/// Ведение по маршруту: GPS (или симуляция), ближайшая точка на маршруте, подсказки, голос, уход с маршрута.
class NavController extends ChangeNotifier {
  NavController(this.route, {required this.onOffRoute, this.simulate = false}) {
    _prepare();
  }

  final RouteData route;
  final bool simulate;
  final void Function(LatLon pos) onOffRoute;

  late final Float64List _cum; // накопленное расстояние до каждой точки
  late final Int32List _edgeAt; // ребро для каждой точки
  late final double total;
  StreamSubscription<Position>? _sub;
  Timer? _simTimer;
  final FlutterTts _tts = FlutterTts();
  final Set<String> _spoken = {};
  int _offCount = 0;
  int _lastIdx = 1;
  bool _stopped = false;

  LatLon? position;

  /// Направление движения по маршруту, градусы от севера.
  double heading = 0;
  double remaining = 0;
  double toNext = 0;
  Step? next;
  int limit = 0;
  bool arrived = false;
  String? error;

  double get remainingFraction => total <= 0 ? 0 : remaining / total;

  void _prepare() {
    final n = route.pointCount;
    _cum = Float64List(n);
    for (var i = 1; i < n; i++) {
      _cum[i] = _cum[i - 1] +
          haversine(route.pts[2 * i - 2], route.pts[2 * i - 1], route.pts[2 * i], route.pts[2 * i + 1]);
    }
    total = n > 0 ? _cum[n - 1] : 0;
    _edgeAt = Int32List(n);
    var k = 0;
    for (var i = 0; i < n; i++) {
      while (k < route.edgeCount - 1 && i >= route.edgeStartPt[k + 1]) {
        k++;
      }
      _edgeAt[i] = k;
    }
    remaining = total;
    next = route.steps.length > 1 ? route.steps[1] : route.steps.first;
    limit = route.edgeSpeed.isNotEmpty ? route.edgeSpeed[0] : 0;
  }

  /// Экран не гаснет, голос готов — но навигацию это не блокирует (TTS/вакелок могут отвечать долго или быть недоступны).
  Future<void> _initAudioAndWakelock() async {
    try {
      await WakelockPlus.enable().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      await _tts.setLanguage('ru-RU').timeout(const Duration(seconds: 3));
    } catch (_) {}
    if (!_stopped) _speak(route.steps.first.text);
  }

  Future<void> start() async {
    unawaited(_initAudioAndWakelock());
    if (simulate) {
      _startSimulation();
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      error = 'Нет доступа к геолокации. Разрешите её в настройках или включите симуляцию.';
      notifyListeners();
      return;
    }
    _sub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 5,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Cargo Navigation',
          notificationText: 'Идёт навигация по маршруту',
          enableWakeLock: true,
        ),
      ),
    ).listen((p) => onFix(p.latitude, p.longitude), onError: (Object e) {
      error = 'Нет сигнала GPS';
      notifyListeners();
    });
  }

  void _startSimulation() {
    var d = 0.0;
    final speed = math.max(300.0, total / 180); // м/с: быстро, чтобы проехать маршрут за пару минут
    _simTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      d = math.min(total, d + speed);
      var i = 1;
      while (i < _cum.length - 1 && _cum[i] < d) {
        i++;
      }
      final seg = _cum[i] - _cum[i - 1];
      final t = seg <= 0 ? 0.0 : (d - _cum[i - 1]) / seg;
      final la = route.pts[2 * i - 2] + (route.pts[2 * i] - route.pts[2 * i - 2]) * t;
      final lo = route.pts[2 * i - 1] + (route.pts[2 * i + 1] - route.pts[2 * i - 1]) * t;
      onFix(la, lo);
      if (d >= total) _simTimer?.cancel();
    });
  }

  /// Обработка новой позиции (GPS или симуляции).
  void onFix(double lat, double lon) {
    if (_stopped || arrived) return;
    position = LatLon(lat, lon);
    final n = route.pointCount;
    if (n < 2) return;
    final kx = math.cos(lat * math.pi / 180);

    var bestD = double.infinity, bestI = 1;
    var done = 0.0;
    void scan(int from, int to) {
      for (var i = math.max(1, from); i < math.min(n, to); i++) {
        final ay = route.pts[2 * i - 2], ax = route.pts[2 * i - 1];
        final by = route.pts[2 * i], bx = route.pts[2 * i + 1];
        final dx = (bx - ax) * kx, dy = by - ay, px = (lon - ax) * kx, py = lat - ay;
        final l2 = dx * dx + dy * dy;
        final t = l2 == 0 ? 0.0 : ((px * dx + py * dy) / l2).clamp(0.0, 1.0);
        final d = haversine(lat, lon, ay + dy * t, ax + (bx - ax) * t);
        if (d < bestD) {
          bestD = d;
          bestI = i;
          done = _cum[i - 1] + t * (_cum[i] - _cum[i - 1]);
        }
      }
    }

    // сначала ищем рядом с прошлой позицией (быстро для длинных маршрутов), иначе по всему маршруту
    scan(_lastIdx - 50, _lastIdx + 2000);
    if (bestD > 80) scan(1, n);
    if (bestD > 80) {
      if (++_offCount >= 3) {
        _offCount = 0;
        _speak('Перестраиваю маршрут');
        onOffRoute(position!);
      }
      notifyListeners();
      return;
    }
    _offCount = 0;
    _lastIdx = bestI;
    heading = bearing(route.pts[2 * bestI - 2], route.pts[2 * bestI - 1], route.pts[2 * bestI], route.pts[2 * bestI + 1]);
    final k = _edgeAt[bestI];
    limit = route.edgeSpeed[k];
    remaining = math.max(0, total - done);
    final step = route.steps.firstWhere((s) => s.firstEdge > k, orElse: () => route.steps.last);
    next = step;
    final stepIdx = step.firstEdge >= route.edgeCount ? n - 1 : route.edgeStartPt[step.firstEdge];
    toNext = math.max(0, _cum[stepIdx] - done);
    const marks = [(100.0, 'Через 100 метров'), (400.0, 'Через 400 метров'), (1000.0, 'Через километр')];
    for (var i = 0; i < marks.length; i++) {
      final (th, label) = marks[i];
      if (toNext > th) continue;
      final key = '${step.firstEdge}-$th';
      if (!_spoken.contains(key)) {
        // ближайший рубеж озвучиваем, более дальние считаем пройденными
        for (var j = i; j < marks.length; j++) {
          _spoken.add('${step.firstEdge}-${marks[j].$1}');
        }
        final text = step.type == TurnType.arrive
            ? '$label вы прибудете в пункт назначения'
            : '$label ${step.text[0].toLowerCase()}${step.text.substring(1)}';
        _speak(text);
      }
      break;
    }
    if (step.type == TurnType.arrive && toNext < 25) {
      arrived = true;
      _speak('Вы прибыли');
    }
    notifyListeners();
  }

  void _speak(String t) {
    try {
      _tts.speak(t).catchError((Object _) => null);
    } catch (_) {}
  }

  Future<void> stop() async {
    _stopped = true;
    _simTimer?.cancel();
    await _sub?.cancel();
    try {
      await _tts.stop().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await WakelockPlus.disable().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
