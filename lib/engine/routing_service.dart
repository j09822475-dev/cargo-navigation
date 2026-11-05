import 'dart:async';
import 'dart:isolate';

import '../core/geo.dart';
import '../core/prefs.dart';
import '../core/tariffs.dart';
import 'demo_source.dart';
import 'engine.dart';
import 'overpass_source.dart';
import 'road_source.dart';

/// Функция построения маршрута (в приложении — через фоновый изолят, в тестах — напрямую).
typedef PlanFn = Future<PlanOutcome> Function(LatLon start, LatLon end, RoutePrefs prefs, bool demo, Progress? onProgress);

/// Фоновый изолят: загрузка данных, разбор JSON, построение графа и поиск не блокируют интерфейс.
/// Граф остаётся в изоляте между запросами — смена настроек и перестроение не качают данные заново.
class RoutingService {
  final SendPort _toWorker;
  final ReceivePort _fromWorker;
  final Map<int, Completer<PlanOutcome>> _pending = {};
  final Map<int, Progress?> _progress = {};
  int _nextId = 1;

  RoutingService._(this._toWorker, this._fromWorker) {
    _fromWorker.listen((m) {
      final msg = m as List;
      final id = msg[1] as int;
      switch (msg[0]) {
        case 'progress':
          _progress[id]?.call(msg[2] as String);
        case 'result':
          _progress.remove(id);
          _pending.remove(id)?.complete(msg[2] as PlanOutcome);
        case 'error':
          _progress.remove(id);
          _pending.remove(id)?.complete(PlanOutcome(error: msg[2] as String));
      }
    });
  }

  /// [tariffFiles] — тексты JSON с тарифами операторов (assets/tariffs).
  static Future<RoutingService> start({List<String> tariffFiles = const []}) async {
    final recv = ReceivePort();
    await Isolate.spawn(_workerMain, recv.sendPort);
    final events = StreamController<dynamic>();
    final sub = recv.listen(events.add);
    final first = await events.stream.first as SendPort;
    await sub.cancel();
    final back = ReceivePort();
    first.send(back.sendPort);
    first.send(['tariffs', 0, tariffFiles]);
    return RoutingService._(first, back);
  }

  Future<PlanOutcome> plan(LatLon start, LatLon end, RoutePrefs prefs, bool demo, Progress? onProgress) {
    final id = _nextId++;
    final c = Completer<PlanOutcome>();
    _pending[id] = c;
    _progress[id] = onProgress;
    _toWorker.send(['plan', id, start.lat, start.lon, end.lat, end.lon, prefs.toJson(), demo]);
    return c.future;
  }

  void cancelAll() {
    for (final id in _pending.keys.toList()) {
      _toWorker.send(['cancel', id]);
    }
  }
}

void _workerMain(SendPort main) {
  final port = ReceivePort();
  main.send(port.sendPort);
  SendPort? out;
  final real = RoutingEngine(OverpassSource());
  final demo = RoutingEngine(DemoSource());
  final tokens = <int, CancelToken>{};
  port.listen((m) async {
    final msg = m as dynamic;
    if (msg is SendPort) {
      out = msg;
      return;
    }
    final list = msg as List;
    final id = list[1] as int;
    if (list[0] == 'tariffs') {
      final book = TariffBook.parse((list[2] as List).cast<String>());
      real.tariffs = book;
      demo.tariffs = book;
      return;
    }
    if (list[0] == 'cancel') {
      tokens[id]?.cancelled = true;
      return;
    }
    // новый запрос отменяет предыдущие
    for (final t in tokens.values) {
      t.cancelled = true;
    }
    final token = tokens[id] = CancelToken();
    try {
      final engine = (list[7] as bool) ? demo : real;
      final outcome = await engine.plan(
        LatLon(list[2] as double, list[3] as double),
        LatLon(list[4] as double, list[5] as double),
        RoutePrefs.fromJson((list[6] as Map).cast<String, Object?>()),
        onProgress: (t) => out?.send(['progress', id, t]),
        cancel: token,
      );
      out?.send(['result', id, outcome]);
    } on CancelledException {
      out?.send(['error', id, 'Отменено']);
    } catch (e) {
      out?.send(['error', id, 'Ошибка: $e']);
    } finally {
      tokens.remove(id);
    }
  });
}
