// Ручная проверка маршрутов на настоящих серверах (не входит в flutter test):
//   dart run tool/live_check.dart [Откуда_lat,lon Куда_lat,lon]
import 'dart:convert';
import 'dart:io';

import 'package:cargo_navigation/core/countries.dart';
import 'package:cargo_navigation/core/geo.dart';
import 'package:cargo_navigation/core/toll_model.dart';
import 'package:cargo_navigation/engine/online_router.dart';
import 'package:cargo_navigation/engine/osrm.dart';
import 'package:cargo_navigation/engine/valhalla.dart';

Future<void> main(List<String> args) async {
  final countries = CountryIndex.parse(File('assets/geo/countries.json').readAsStringSync());
  final index = jsonDecode(File('assets/tariffs/index.json').readAsStringSync()) as Map<String, dynamic>;
  final tolls = TollModel.parse(File('assets/tariffs/countries.json').readAsStringSync(),
      [for (final n in (index['files'] as List).cast<String>()) File('assets/tariffs/$n').readAsStringSync()]);
  final osrm = OsrmProvider();
  final router = OnlineRouter([ValhallaProvider(), osrm], guide: osrm, countries: countries, tolls: tolls);
  LatLon p(String s) {
    final v = s.split(',').map(double.parse).toList();
    return LatLon(v[0], v[1]);
  }

  final trips = args.length >= 2
      ? [('аргументы', p(args[0]), p(args[1]))]
      : [
          ('Таллин → Тарту', const LatLon(59.437, 24.754), const LatLon(58.378, 26.729)),
          ('Таллин → Милан', const LatLon(59.437, 24.754), const LatLon(45.464, 9.19)),
          ('Мюнхен → Милан', const LatLon(48.137, 11.575), const LatLon(45.464, 9.19)),
          ('Вена → Будапешт', const LatLon(48.208, 16.373), const LatLon(47.498, 19.04)),
          ('Салоники → Загреб', const LatLon(40.64, 22.94), const LatLon(45.815, 15.982)),
          ('Лиссабон → Хельсинки', const LatLon(38.722, -9.139), const LatLon(60.17, 24.94)),
          ('Гент → Антверпен-север', const LatLon(51.054, 3.717), const LatLon(51.30, 4.30)),
        ];
  for (final (name, a, b) in trips) {
    final sw = Stopwatch()..start();
    final out = await router.plan(a, b);
    stdout.writeln('== $name (${sw.elapsed.inSeconds} с)');
    if (out.error != null) {
      stdout.writeln('   ОШИБКА: ${out.error}');
      continue;
    }
    if (out.note != null) stdout.writeln('   ${out.note}');
    for (final r in out.routes!) {
      final seq = <String>[];
      var nonEu = 0;
      for (var i = 0; i < r.pointCount; i += 20) {
        final c = countries.isoAt(r.pts[2 * i], r.pts[2 * i + 1]);
        if (countries.isDeepNonEu(r.pts[2 * i], r.pts[2 * i + 1])) nonEu++;
        if (c != null && (seq.isEmpty || seq.last != c)) seq.add(c);
      }
      stdout.writeln('   ${r.tags.join(',').padRight(18)} ${(r.meters / 1000).round()} км, ${(r.hours).toStringAsFixed(1)} ч, '
          '${r.money.toStringAsFixed(2)} € (км ${r.distanceToll.toStringAsFixed(2)}, виньетки ${r.vignettes.map((v) => '${v.iso} ${v.priceEur}').join(' ')}'
          '${r.objects.isEmpty ? '' : ', объекты ${r.objects.map((o) => o.name).join(', ')}'}) '
          'шагов ${r.steps.length}; вне ЕС точек: $nonEu; страны: ${seq.join('→')}');
      for (final w in r.warnings) {
        stdout.writeln('      ! $w');
      }
    }
    stdout.writeln('   шаги: ${out.routes!.first.steps.take(3).map((s) => s.text).join(' | ')}');
  }
  exit(0);
}
