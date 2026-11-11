import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Тексты встроенных данных: границы стран, тарифы стран и операторов.
class EngineAssets {
  final String countriesGeo, countryTolls;
  final List<String> operatorFiles;
  const EngineAssets(this.countriesGeo, this.countryTolls, this.operatorFiles);
}

Future<String> _text(String path, String fallback) async {
  try {
    return await rootBundle.loadString(path);
  } catch (e) {
    debugPrint('Не загружен $path: $e');
    return fallback;
  }
}

Future<EngineAssets> loadEngineAssets() async {
  final geo = await _text('assets/geo/countries.json', '{"countries":[]}');
  final tolls = await _text('assets/tariffs/countries.json', '{"schema":1,"countries":{}}');
  final ops = <String>[];
  try {
    final index = jsonDecode(await rootBundle.loadString('assets/tariffs/index.json')) as Map<String, dynamic>;
    for (final name in (index['files'] as List).cast<String>()) {
      final t = await _text('assets/tariffs/$name', '');
      if (t.isNotEmpty) ops.add(t);
    }
  } catch (e) {
    debugPrint('Тарифы операторов не загружены: $e');
  }
  return EngineAssets(geo, tolls, ops);
}
