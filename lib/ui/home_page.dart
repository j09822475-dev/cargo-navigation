import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/geo.dart';
import '../core/route_data.dart';
import 'app_state.dart';
import 'format.dart';
import 'geocoder.dart';
import 'search_page.dart';

const _blue = Color(0xFF1A73E8);
const _green = Color(0xFF188038);
const _navGreen = Color(0xFF0B6B3A);
const _tollOrange = Color(0xFFF29900);

/// Главный экран в духе Google Карт: карта, строка поиска, карточка маршрута, ведение по маршруту.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.state, this.geocoder});
  final AppState state;
  final Geocoder? geocoder;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final MapController _map = MapController();
  late final Geocoder _geo = widget.geocoder ?? Geocoder();
  String? _fitted; // чтобы не перенацеливать карту на каждую перерисовку
  bool _showSteps = false;
  bool _wasNav = false;
  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    s.addListener(_sync);
  }

  @override
  void dispose() {
    s.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    final r = s.route;
    final nav = s.nav;
    if (nav != null && nav.position != null) {
      _wasNav = true;
      // камера следует за машиной, карта повёрнута по ходу движения
      _map.moveAndRotate(LatLng(nav.position!.lat, nav.position!.lon), math.max(_map.camera.zoom, 15.5), -nav.heading);
      return;
    }
    if (nav == null && _wasNav) {
      _wasNav = false;
      _fitted = null;
      _map.rotate(0);
    }
    if (r != null && nav == null) {
      final key = '${s.routes.length}-${r.pts.length}-${r.meters.round()}';
      if (key != _fitted) {
        _fitted = key;
        WidgetsBinding.instance.addPostFrameCallback((_) => _fit(r));
      }
    }
  }

  void _fit(RouteData r) {
    if (!mounted || r.pointCount < 2) return;
    var s0 = 90.0, n0 = -90.0, w0 = 180.0, e0 = -180.0;
    for (var i = 0; i < r.pointCount; i += math.max(1, r.pointCount ~/ 2000)) {
      final la = r.pts[2 * i], lo = r.pts[2 * i + 1];
      s0 = math.min(s0, la);
      n0 = math.max(n0, la);
      w0 = math.min(w0, lo);
      e0 = math.max(e0, lo);
    }
    final h = MediaQuery.of(context).size.height;
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds(LatLng(s0, w0), LatLng(n0, e0)),
      padding: EdgeInsets.fromLTRB(40, 170, 40, h * 0.42),
      maxZoom: 16,
    ));
  }

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _openSearch({required bool forStart}) async {
    final res = await Navigator.of(context).push(MaterialPageRoute<SearchResult>(
      builder: (_) => SearchPage(
        geocoder: _geo,
        forStart: forStart,
        hint: forStart ? 'Откуда' : 'Куда едем?',
      ),
    ));
    if (res == null || !mounted) return;
    setState(() => _showSteps = false);
    if (res.demo) {
      s.startDemo();
    } else if (res.myLocation) {
      s.setStart(null);
    } else if (forStart) {
      s.setStart(res.place!.pos, label: res.place!.title);
    } else {
      _map.move(LatLng(res.place!.pos.lat, res.place!.pos.lon), 12);
      s.setDestination(res.place!.pos, label: res.place!.title);
    }
  }

  Future<void> _locateMe() async {
    final p = await s.locate?.call();
    if (!mounted) return;
    if (p == null) {
      _snack('Не удалось определить местоположение');
      return;
    }
    s.myLocation = p;
    _map.moveAndRotate(LatLng(p.lat, p.lon), 14, 0);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final nav = s.nav;
        return Scaffold(
          resizeToAvoidBottomInset: false,
          body: Stack(children: [
            _mapView(),
            if (nav != null)
              _navOverlay()
            else if (!s.hasDestination) ...[
              _searchPill(),
              _locateFab(24),
            ] else ...[
              _directionsHeader(),
              _routeSheet(),
            ],
          ]),
        );
      },
    );
  }

  // ---------- карта ----------
  Widget _mapView() {
    final r = s.route;
    final nav = s.nav;
    final layers = <Widget>[
      TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.cargonav.app'),
    ];
    if (r != null) {
      for (var i = 0; i < s.routes.length; i++) {
        if (i == s.selected || nav != null) continue;
        layers.add(PolylineLayer(simplificationTolerance: 0.5, polylines: [
          Polyline(
              points: _points(s.routes[i], 0, s.routes[i].pointCount - 1),
              strokeWidth: 6,
              color: const Color(0xFFBCC8DC),
              borderStrokeWidth: 1.5,
              borderColor: const Color(0xFF8A9BB8)),
        ]));
      }
      layers.add(PolylineLayer(simplificationTolerance: 0.5, polylines: [
        Polyline(points: _points(r, 0, r.pointCount - 1), strokeWidth: 7, color: _blue, borderStrokeWidth: 2, borderColor: const Color(0xFF1558B0)),
        ..._tollLines(r),
      ]));
    }
    final start = s.start ?? s.myLocation;
    layers.add(MarkerLayer(markers: [
      if (nav == null && start != null && s.hasDestination)
        Marker(
          point: LatLng(start.lat, start.lon),
          width: 18,
          height: 18,
          child: Container(decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: Colors.black87, width: 4))),
        ),
      if (nav == null && !s.hasDestination && s.myLocation != null) _blueDot(s.myLocation!),
      if (s.end != null)
        Marker(
          point: LatLng(s.end!.lat, s.end!.lon),
          width: 40,
          height: 40,
          alignment: Alignment.topCenter,
          rotate: true,
          child: const Icon(Icons.location_on, color: Color(0xFFEA4335), size: 40),
        ),
      if (nav?.position != null)
        Marker(
          point: LatLng(nav!.position!.lat, nav.position!.lon),
          width: 44,
          height: 44,
          rotate: true,
          child: Container(
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(blurRadius: 6, color: Colors.black38)]),
            child: const Icon(Icons.navigation, color: _blue, size: 30),
          ),
        ),
    ]));
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: const LatLng(49.5, 10.5),
        initialZoom: 5,
        onLongPress: (_, ll) {
          if (s.nav == null) s.setDestination(LatLon(ll.latitude, ll.longitude), label: 'Точка на карте');
        },
      ),
      children: layers,
    );
  }

  Marker _blueDot(LatLon p) => Marker(
        point: LatLng(p.lat, p.lon),
        width: 22,
        height: 22,
        child: Container(decoration: BoxDecoration(color: _blue, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3), boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black38)])),
      );

  List<LatLng> _points(RouteData r, int from, int to) =>
      [for (var i = from; i <= to; i++) LatLng(r.pts[2 * i], r.pts[2 * i + 1])];

  /// Участки с платой за километр — оранжевым поверх маршрута.
  List<Polyline> _tollLines(RouteData r) {
    final out = <Polyline>[];
    int? runStart;
    for (var k = 0; k <= r.edgeCount; k++) {
      final toll = k < r.edgeCount && r.edgeToll[k] == 1;
      if (toll && runStart == null) runStart = r.edgeStartPt[k];
      if (!toll && runStart != null) {
        out.add(Polyline(points: _points(r, runStart, r.edgeStartPt[k]), strokeWidth: 7, color: _tollOrange));
        runStart = null;
      }
    }
    return out;
  }

  // ---------- пустая карта: строка поиска ----------
  Widget _searchPill() {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
        child: Material(
          elevation: 4,
          color: scheme.surface,
          borderRadius: BorderRadius.circular(28),
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: () => _openSearch(forStart: false),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(children: [
                const Icon(Icons.search, color: _blue),
                const SizedBox(width: 12),
                Expanded(child: Text('Куда едем?', style: TextStyle(fontSize: 17, color: scheme.onSurfaceVariant))),
                Icon(Icons.directions, color: scheme.onSurfaceVariant),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _locateFab(double bottom) => Positioned(
        right: 16,
        bottom: bottom,
        child: SafeArea(
          child: FloatingActionButton(
            heroTag: 'locate',
            backgroundColor: Theme.of(context).colorScheme.surface,
            foregroundColor: _blue,
            shape: const CircleBorder(),
            onPressed: _locateMe,
            child: const Icon(Icons.my_location),
          ),
        ),
      );

  // ---------- маршрут: шапка «откуда → куда» ----------
  Widget _directionsHeader() {
    final scheme = Theme.of(context).colorScheme;
    Widget field(String text, VoidCallback onTap) => Expanded(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
              child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
            ),
          ),
        );
    return Material(
      elevation: 4,
      color: scheme.surface,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'Назад', onPressed: s.clear),
            Padding(
              padding: const EdgeInsets.only(top: 14, right: 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.trip_origin, size: 16, color: _blue),
                for (var i = 0; i < 3; i++) Container(width: 3, height: 3, margin: const EdgeInsets.symmetric(vertical: 3), decoration: BoxDecoration(color: scheme.outline, shape: BoxShape.circle)),
                const Icon(Icons.location_on, size: 18, color: Color(0xFFEA4335)),
              ]),
            ),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [field(s.startTitle, () => _openSearch(forStart: true))]),
                const SizedBox(height: 8),
                Row(children: [field(s.endLabel, () => _openSearch(forStart: false))]),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 26),
              child: IconButton(icon: const Icon(Icons.swap_vert), tooltip: 'Поменять местами', onPressed: s.busy ? null : s.swap),
            ),
          ]),
        ),
      ),
    );
  }

  // ---------- маршрут: нижняя карточка ----------
  String _costLine(RouteData r) {
    if (r.money <= 0) return 'Без платных дорог';
    return 'Платные дороги: ${r.estimated ? '≈ ' : ''}${fmtMoney(r.money)}';
  }

  Widget _routeSheet() {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final r = s.route;
    return DraggableScrollableSheet(
      initialChildSize: 0.36,
      minChildSize: 0.16,
      maxChildSize: 0.9,
      snap: true,
      snapSizes: const [0.16, 0.36, 0.9],
      builder: (context, scroll) => Material(
        elevation: 12,
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
          children: [
            Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(2)))),
            if (s.busy) ...[
              Text('Строю маршрут', style: text.titleMedium),
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: Text(s.status, style: text.bodySmall)),
                TextButton(onPressed: s.cancelPlanning, child: const Text('Отмена')),
              ]),
            ],
            if (s.error != null) ...[
              Text(s.error!, style: TextStyle(color: scheme.error, fontSize: 15)),
              const SizedBox(height: 10),
              Align(alignment: Alignment.centerLeft, child: OutlinedButton(onPressed: s.plan, child: const Text('Повторить'))),
            ],
            if (r != null) ...[
              Text.rich(TextSpan(children: [
                TextSpan(text: fmtTime(r.hours), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: r.weatherDelayHours > 0.02 ? const Color(0xFFD56E0C) : _green)),
                TextSpan(text: '  (${fmtDist(r.meters)})', style: TextStyle(fontSize: 20, color: scheme.onSurfaceVariant)),
              ])),
              const SizedBox(height: 2),
              Text(_headline(r), style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              Row(children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: _blue, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12)),
                  onPressed: () => s.startNavigation(),
                  icon: const Icon(Icons.navigation),
                  label: const Text('В путь'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                  onPressed: () => setState(() => _showSteps = !_showSteps),
                  icon: const Icon(Icons.list),
                  label: const Text('Шаги'),
                ),
                if (s.demo) ...[
                  const SizedBox(width: 10),
                  Chip(label: const Text('Демо'), visualDensity: VisualDensity.compact, side: BorderSide(color: scheme.outlineVariant)),
                ],
              ]),
              const SizedBox(height: 14),
              ..._costDetails(r),
              for (final w in r.warnings) _infoRow(Icons.warning_amber_rounded, w, const Color(0xFFD56E0C)),
              if (s.note != null) _infoRow(Icons.info_outline, s.note!, scheme.onSurfaceVariant),
              if (s.routes.length > 1) ...[
                const Divider(height: 26),
                Text('Варианты маршрута', style: text.titleSmall),
                for (var i = 0; i < s.routes.length; i++) _routeTile(i),
              ],
              if (_showSteps) ..._steps(r),
            ],
          ],
        ),
      ),
    );
  }

  String _headline(RouteData r) {
    final parts = <String>[
      if (r.tags.contains('best') && r.tags.contains('fastest'))
        'Самый быстрый маршрут'
      else if (r.tags.contains('best'))
        'Оптимальный маршрут'
      else if (r.tags.contains('fastest'))
        'Самый быстрый маршрут'
      else if (r.tags.contains('free'))
        'Маршрут без платных дорог'
      else
        'Альтернативный маршрут',
      _costLine(r).toLowerCase(),
    ];
    return parts.join(' · ');
  }

  Widget _infoRow(IconData icon, String t, Color color) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(t, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color))),
        ]),
      );

  /// Из чего складывается стоимость дороги.
  List<Widget> _costDetails(RouteData r) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final out = <Widget>[];
    if (r.tollMeters > 1) {
      final est = r.tollMeters - r.tollOperatorMeters > 1;
      out.add(_infoRow(Icons.toll, 'Плата за проезд: ${est ? '≈ ' : ''}${fmtMoney(r.distanceToll)} за ${fmtDist(r.tollMeters)}'
          '${est ? ' (средняя ставка по стране — оценка)' : ' (тариф оператора)'}', _tollOrange));
    }
    for (final o in r.objects) {
      out.add(_infoRow(Icons.toll, '${o.name}: ${o.confirmed ? '' : '≈ '}${fmtMoney(o.priceEur)}'
          '${o.confirmed ? '' : ' — цена требует проверки'}', _tollOrange));
    }
    for (final v in r.vignettes) {
      out.add(_infoRow(Icons.confirmation_number_outlined,
          'Виньетка, ${countryNamesRu[v.iso] ?? v.iso} (${v.product}): ${v.confirmed ? '' : '≈ '}${fmtMoney(v.priceEur)}'
          '${v.confirmed ? '' : ' — цена требует проверки'}', muted));
    }
    return out;
  }

  Widget _routeTile(int i) {
    final r = s.routes[i];
    final scheme = Theme.of(context).colorScheme;
    final selected = i == s.selected;
    final label = r.tags.contains('best')
        ? 'Оптимальный'
        : r.tags.contains('fastest')
            ? 'Самый быстрый'
            : r.tags.contains('free')
                ? 'Без платных дорог'
                : 'Альтернатива';
    return InkWell(
      onTap: () => s.select(i),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? _blue.withValues(alpha: 0.08) : null,
          border: Border.all(color: selected ? _blue : scheme.outlineVariant, width: selected ? 2 : 1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('${fmtDist(r.meters)} · ${_costLine(r)}', style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          Text(fmtTime(r.hours), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: _green)),
        ]),
      ),
    );
  }

  static const _icons = {
    TurnType.depart: Icons.directions_car,
    TurnType.straight: Icons.straight,
    TurnType.slightRight: Icons.turn_slight_right,
    TurnType.slightLeft: Icons.turn_slight_left,
    TurnType.right: Icons.turn_right,
    TurnType.left: Icons.turn_left,
    TurnType.sharpRight: Icons.turn_sharp_right,
    TurnType.sharpLeft: Icons.turn_sharp_left,
    TurnType.uturn: Icons.u_turn_left,
    TurnType.arrive: Icons.flag,
  };

  List<Widget> _steps(RouteData r) => [
        const Divider(height: 26),
        Text('Шаги', style: Theme.of(context).textTheme.titleSmall),
        for (final st in r.steps)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(_icons[st.type]),
            title: Text.rich(TextSpan(children: [
              TextSpan(text: st.text),
              if (st.toll) const TextSpan(text: ' · платная', style: TextStyle(color: _tollOrange, fontWeight: FontWeight.w600)),
            ])),
            subtitle: st.meters > 0 ? Text('${fmtDist(st.meters)} · лимит ${st.speed} км/ч') : null,
          ),
      ];

  // ---------- ведение по маршруту ----------
  Widget _navOverlay() {
    final nav = s.nav!;
    final scheme = Theme.of(context).colorScheme;
    final r = s.route!;
    final next = nav.next;
    final remainH = r.hours * nav.remainingFraction;
    return Stack(children: [
      SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Material(
              color: _navGreen,
              elevation: 8,
              borderRadius: BorderRadius.circular(18),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Row(children: [
                  Icon(_icons[next?.type] ?? Icons.navigation, color: Colors.white, size: 46),
                  const SizedBox(width: 14),
                  Expanded(
                    child: nav.error != null
                        ? Text(nav.error!, style: const TextStyle(color: Colors.white, fontSize: 16))
                        : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(fmtDist(nav.toNext), style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700)),
                            Text(next?.text ?? '', style: const TextStyle(color: Colors.white, fontSize: 16), maxLines: 2, overflow: TextOverflow.ellipsis),
                          ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
      // знак ограничения скорости
      Positioned(
        left: 14,
        bottom: 110,
        child: SafeArea(
          child: Container(
            width: 54,
            height: 54,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white, border: Border.all(color: const Color(0xFFD93025), width: 6), boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black38)]),
            child: Text('${nav.limit}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: Colors.black)),
          ),
        ),
      ),
      Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          color: scheme.surface,
          elevation: 12,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
              child: Row(children: [
                Material(
                  color: const Color(0xFFD93025),
                  shape: const CircleBorder(),
                  child: IconButton(icon: const Icon(Icons.close, color: Colors.white), tooltip: 'Завершить', onPressed: s.stopNavigation),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: nav.arrived
                      ? const Text('Вы прибыли', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: _green))
                      : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
                          Text(fmtTime(remainH), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: _green)),
                          Text('${fmtDist(nav.remaining)} · ${fmtEta(remainH, DateTime.now())}', style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant)),
                        ]),
                ),
                const SizedBox(width: 56),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}
