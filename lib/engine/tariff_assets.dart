import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Читает тексты файлов тарифов, перечисленных в assets/tariffs/index.json.
/// Отсутствующие или нечитаемые файлы пропускаются: приложение работает и без них (ставки из настроек).
Future<List<String>> loadTariffFiles() async {
  try {
    final index = jsonDecode(await rootBundle.loadString('assets/tariffs/index.json')) as Map<String, dynamic>;
    final out = <String>[];
    for (final name in (index['files'] as List).cast<String>()) {
      try {
        out.add(await rootBundle.loadString('assets/tariffs/$name'));
      } catch (e) {
        debugPrint('Файл тарифов $name не загружен: $e');
      }
    }
    return out;
  } catch (e) {
    debugPrint('Тарифы не загружены: $e');
    return const [];
  }
}
