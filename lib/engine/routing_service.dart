import 'dart:async';
import 'dart:isolate';

import '../core/countries.dart';
import '../core/geo.dart';
import '../core/toll_model.dart';
import 'demo_source.dart';
import 'engine.dart';
import 'open_meteo.dart';
import 'overpass_source.dart';
import 'road_source.dart';
import 'tariff_assets.dart';

/// Функция построения маршрута (в приложении — через фоновый изолят, в тестах — напрямую).
typedef PlanFn = Future<PlanOutcome> Function(LatLon start, LatLon end, bool demo, Progress? onProgress);

/// Движки для настоящих и демо-данных на общих встроенных данных.
(RoutingEngine real, RoutingEngine demo) buildEngines(EngineAssets a) {
  final countries = CountryIndex.parse(a.countriesGeo);
  final tolls = TollModel.parse(a.countryTolls, a.operatorFiles);
  return (
    RoutingEngine(OverpassSource(), countries: countries, tolls: tolls, weather: OpenMeteoSource()),
    RoutingEngine(DemoSource(), countries: countries, tolls: tolls),
  );
}

/// Фоновый изолят: загрузка данных, разбор JSON, построение графа и поиск не блокируют интерфейс.
/// Граф остаётся в изоляте между запросами — перестроение маршрута не качает данные заново.
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

  static Future<RoutingService> start(EngineAssets assets) async {
    final recv = ReceivePort();
    await Isolate.spawn(_workerMain, recv.sendPort);
    final events = StreamController<dynamic>();
    final sub = recv.listen(events.add);
    final first = await events.stream.first as SendPort;
    await sub.cancel();
    final back = ReceivePort();
    first.send(back.sendPort);
    first.send(['assets', 0, assets.countriesGeo, assets.countryTolls, assets.operatorFiles]);
    return RoutingService._(first, back);
  }

  Future<PlanOutcome> plan(LatLon start, LatLon end, bool demo, Progress? onProgress) {
    final id = _nextId++;
    final c = Completer<PlanOutcome>();
    _pending[id] = c;
    _progress[id] = onProgress;
    _toWorker.send(['plan', id, start.lat, start.lon, end.lat, end.lon, demo]);
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
  RoutingEngine? real, demo;
  final tokens = <int, CancelToken>{};
  port.listen((m) async {
    final msg = m as dynamic;
    if (msg is SendPort) {
      out = msg;
      return;
    }
    final list = msg as List;
    final id = list[1] as int;
    if (list[0] == 'assets') {
      (real, demo) = buildEngines(
          EngineAssets(list[2] as String, list[3] as String, (list[4] as List).cast<String>()));
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
      final engine = (list[6] as bool) ? demo : real;
      if (engine == null) throw StateError('движок ещё не готов');
      final outcome = await engine.plan(
        LatLon(list[2] as double, list[3] as double),
        LatLon(list[4] as double, list[5] as double),
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
