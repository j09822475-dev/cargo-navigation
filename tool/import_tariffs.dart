// Импорт тарифов оператора из CSV в assets/tariffs/*.json.
//
//   dart run tool/import_tariffs.dart --operator "APRR" --alias "APRR" --country FR \
//        --updated 2026-08-02 --source "https://…" [--note "пояснение"] sections.csv > assets/tariffs/aprr.json
//
// После импорта добавьте имя файла в assets/tariffs/index.json.
import 'dart:io';

import 'package:cargo_navigation/core/tariff_import.dart';

void main(List<String> args) {
  final opts = <String, List<String>>{};
  String? file;
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      if (i + 1 >= args.length) _fail('у ${args[i]} нет значения');
      opts.putIfAbsent(args[i].substring(2), () => []).add(args[++i]);
    } else {
      file = args[i];
    }
  }
  String one(String k) => opts[k]?.first ?? _fail('не задан --$k');
  if (file == null) _fail('укажите CSV-файл');
  try {
    final r = buildTariffJson(
      File(file).readAsStringSync(),
      operator: one('operator'),
      aliases: opts['alias'] ?? const [],
      country: one('country'),
      updated: one('updated'),
      source: one('source'),
      note: opts['note']?.first ?? '',
    );
    for (final w in r.warnings) {
      stderr.writeln('Предупреждение: $w');
    }
    stderr.writeln('Участков: ${r.sections}');
    stdout.writeln(r.json);
  } on FormatException catch (e) {
    _fail(e.message);
  }
}

Never _fail(String m) {
  stderr.writeln('Ошибка: $m');
  exit(64);
}
