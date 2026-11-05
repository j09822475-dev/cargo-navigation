import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/geo.dart';
import '../core/prefs.dart';
import '../core/route_data.dart';
import 'app_state.dart';
import 'format.dart';
import 'geocoder.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.state, Geocoder? geocoder}) : _geocoder = geocoder; // ignore: prefer_initializing_formals
  final AppState state;
  final Geocoder? _geocoder;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final MapController _map = MapController();
  final _fromCtl = TextEditingController(), _toCtl = TextEditingController();
  final _fromFocus = FocusNode(), _toFocus = FocusNode();
  late final Geocoder _geo = widget._geocoder ?? Geocoder();
  List<Place> _suggest = const [];
  bool _suggestForStart = true;
  bool? _pickStart; // режим выбора точки на карте
  String? _fitted; // чтобы не перенацеливать карту на каждую перерисовку
  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    s.addListener(_sync);
  }

  @override
  void dispose() {
    s.removeListener(_sync);
    _fromCtl.dispose();
    _toCtl.dispose();
    _fromFocus.dispose();
    _toFocus.dispose();
    super.dispose();
  }

  void _sync() {
    if (!_fromFocus.hasFocus && _fromCtl.text != s.startLabel) _fromCtl.text = s.startLabel;
    if (!_toFocus.hasFocus && _toCtl.text != s.endLabel) _toCtl.text = s.endLabel;
    final r = s.route;
    if (r != null && s.nav == null) {
      final key = '${s.routes.length}-${r.pts.length}-${r.meters.round()}';
      if (key != _fitted) {
        _fitted = key;
        WidgetsBinding.instance.addPostFrameCallback((_) => _fit(r));
      }
    }
    final nav = s.nav;
    if (nav != null && nav.position != null) {
      _map.move(LatLng(nav.position!.lat, nav.position!.lon), math.max(_map.camera.zoom, 15));
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
      padding: EdgeInsets.fromLTRB(32, 150, 32, h * 0.42),
      maxZoom: 16,
    ));
  }

  Future<void> _search(bool forStart) async {
    final ctl = forStart ? _fromCtl : _toCtl;
    final q = ctl.text.trim();
    if (q.isEmpty) return;
    try {
      final res = await _geo.search(q);
      if (!mounted) return;
      if (res.isEmpty) {
        _snack('Адрес не найден');
        return;
      }
      if (res.length == 1) {
        _pick(forStart, res.first);
      } else {
        setState(() {
          _suggest = res;
          _suggestForStart = forStart;
        });
      }
    } catch (e) {
      _snack('$e');
    }
  }

  void _pick(bool forStart, Place p) {
    setState(() => _suggest = const []);
    FocusScope.of(context).unfocus(); // сначала снимаем фокус, чтобы поле показало найденный адрес
    s.setPoint(isStart: forStart, pos: p.pos, label: p.title);
    _map.move(LatLng(p.pos.lat, p.pos.lon), 13);
  }

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _locate() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        _snack('Нет доступа к геолокации');
        return;
      }
      final p = await Geolocator.getCurrentPosition();
      s.setPoint(isStart: true, pos: LatLon(p.latitude, p.longitude), label: 'Моё местоположение');
      _map.move(LatLng(p.latitude, p.longitude), 14);
    } catch (e) {
      _snack('Не удалось определить местоположение');
    }
  }

  void _onMapTap(LatLng ll) {
    final pos = LatLon(ll.latitude, ll.longitude);
    final forStart = _pickStart ?? (s.start == null ? true : (s.end == null ? false : null));
    if (forStart == null) return;
    s.setPoint(isStart: forStart, pos: pos);
    setState(() => _pickStart = null);
  }

  Future<void> _onMapLongPress(LatLng ll) async {
    final pos = LatLon(ll.latitude, ll.longitude);
    final choice = await showModalBottomSheet<bool>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.trip_origin, color: Colors.green), title: const Text('Отсюда (точка А)'), onTap: () => Navigator.pop(c, true)),
          ListTile(leading: const Icon(Icons.place, color: Colors.red), title: const Text('Сюда (точка Б)'), onTap: () => Navigator.pop(c, false)),
        ]),
      ),
    );
    if (choice != null) s.setPoint(isStart: choice, pos: pos);
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
            if (nav == null) ...[
              _topPanel(),
              _sheet(),
            ] else
              _navOverlay(),
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
        if (i == s.selected) continue;
        layers.add(PolylineLayer(simplificationTolerance: 0.5, polylines: [
          Polyline(points: _points(s.routes[i], 0, s.routes[i].pointCount - 1), strokeWidth: 5, color: Colors.blueGrey.withValues(alpha: 0.6)),
        ]));
      }
      layers.add(PolylineLayer(simplificationTolerance: 0.5, polylines: [
        Polyline(
            points: _points(r, 0, r.pointCount - 1), strokeWidth: 7, color: const Color(0xFF1A73E8), borderStrokeWidth: 3, borderColor: Colors.white),
        ..._tollLines(r),
      ]));
    }
    layers.add(MarkerLayer(markers: [
      if (s.start != null) _pin(s.start!, Colors.green, 'А'),
      if (s.end != null) _pin(s.end!, Colors.red, 'Б'),
      if (nav?.position != null)
        Marker(
          point: LatLng(nav!.position!.lat, nav.position!.lon),
          width: 24,
          height: 24,
          child: Container(decoration: BoxDecoration(color: const Color(0xFF1A73E8), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3), boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black38)])),
        ),
    ]));
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: const LatLng(55.75, 37.62),
        initialZoom: 9,
        onTap: (_, ll) => _onMapTap(ll),
        onLongPress: (_, ll) => _onMapLongPress(ll),
      ),
      children: layers,
    );
  }

  Marker _pin(LatLon p, Color c, String t) => Marker(
        point: LatLng(p.lat, p.lon),
        width: 30,
        height: 30,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3), boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black45)]),
          child: Text(t, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
        ),
      );

  List<LatLng> _points(RouteData r, int from, int to) =>
      [for (var i = from; i <= to; i++) LatLng(r.pts[2 * i], r.pts[2 * i + 1])];

  /// Платные участки — оранжевым поверх маршрута.
  List<Polyline> _tollLines(RouteData r) {
    final out = <Polyline>[];
    int? runStart;
    for (var k = 0; k <= r.edgeCount; k++) {
      final toll = k < r.edgeCount && r.edgeToll[k] == 1;
      if (toll && runStart == null) runStart = r.edgeStartPt[k];
      if (!toll && runStart != null) {
        out.add(Polyline(points: _points(r, runStart, r.edgeStartPt[k]), strokeWidth: 7, color: const Color(0xFFF59E0B)));
        runStart = null;
      }
    }
    return out;
  }

  // ---------- верхняя панель ----------
  Widget _topPanel() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Card(
            elevation: 6,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Column(children: [
                _field(true, _fromCtl, 'Откуда (адрес или координаты)', Icons.my_location, _locate),
                const SizedBox(height: 6),
                _field(false, _toCtl, 'Куда', Icons.swap_vert, s.swap),
              ]),
            ),
          ),
          if (_suggest.isNotEmpty)
            Card(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [
                  for (final p in _suggest)
                    ListTile(dense: true, title: Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis), onTap: () => _pick(_suggestForStart, p)),
                ]),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _field(bool isStart, TextEditingController c, String hint, IconData actionIcon, VoidCallback action) {
    return Row(children: [
      CircleAvatar(radius: 11, backgroundColor: isStart ? Colors.green : Colors.red, child: Text(isStart ? 'А' : 'Б', style: const TextStyle(fontSize: 11, color: Colors.white))),
      const SizedBox(width: 8),
      Expanded(
        child: TextField(
          controller: c,
          focusNode: isStart ? _fromFocus : _toFocus,
          decoration: InputDecoration(hintText: hint, isDense: true, border: InputBorder.none),
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(isStart),
          onChanged: (_) => setState(() => _suggest = const []),
        ),
      ),
      IconButton(
        tooltip: 'Выбрать на карте',
        icon: Icon(Icons.push_pin, color: _pickStart == isStart ? Theme.of(context).colorScheme.primary : null),
        onPressed: () {
          setState(() => _pickStart = _pickStart == isStart ? null : isStart);
          if (_pickStart != null) _snack('Коснитесь карты, чтобы поставить точку ${isStart ? 'А' : 'Б'}');
        },
      ),
      IconButton(icon: Icon(actionIcon), onPressed: action),
    ]);
  }

  // ---------- нижняя панель ----------
  Widget _sheet() {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.38,
      minChildSize: 0.12,
      maxChildSize: 0.92,
      snap: true,
      snapSizes: const [0.12, 0.38, 0.92],
      builder: (context, scroll) => Material(
        elevation: 12,
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 10), decoration: BoxDecoration(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(2)))),
            _quickSettings(),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: s.busy ? null : s.plan,
                  icon: const Icon(Icons.alt_route),
                  label: const Text('Построить маршрут'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Настройки',
                icon: const Icon(Icons.tune),
                onPressed: _openSettings,
              ),
            ]),
            if (!s.demo || s.routes.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () {
                    s.startDemo();
                    s.plan();
                  },
                  child: const Text('Демо без интернета'),
                ),
              ),
            if (s.busy) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: Text(s.status, style: Theme.of(context).textTheme.bodySmall)),
                TextButton(onPressed: s.cancelPlanning, child: const Text('Отмена')),
              ]),
            ],
            if (s.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(s.error!, style: TextStyle(color: scheme.error)),
              ),
            if (s.note != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.info_outline, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text(s.note!, style: Theme.of(context).textTheme.bodySmall)),
                ]),
              ),
            for (var i = 0; i < s.routes.length; i++) _routeCard(i),
            if (s.route != null) ..._steps(s.route!),
          ],
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    final before = s.prefs.toJson().toString();
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsPage(state: s)));
    if (s.prefs.toJson().toString() != before && s.start != null && s.end != null && s.routes.isNotEmpty) s.plan();
  }

  Widget _quickSettings() {
    final p = s.prefs;
    void apply(void Function() f) {
      s.updatePrefs((_) => f());
      if (s.routes.isNotEmpty && !s.busy) s.plan();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<Priority>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: Priority.fastest, label: Text('Быстрее', maxLines: 1), icon: Icon(Icons.bolt, size: 18)),
          ButtonSegment(value: Priority.cheapest, label: Text('Дешевле', maxLines: 1), icon: Icon(Icons.savings, size: 18)),
        ],
        selected: {p.priority},
        onSelectionChanged: (v) => apply(() => p.priority = v.first),
      ),
      const SizedBox(height: 8),
      SegmentedButton<TollMode>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: TollMode.any, label: Text('Любые', maxLines: 1), tooltip: 'Комбинировать платные и бесплатные'),
          ButtonSegment(value: TollMode.free, label: Text('Бесплатные', maxLines: 1), tooltip: 'Только бесплатные дороги'),
          ButtonSegment(value: TollMode.prefer, label: Text('Платные', maxLines: 1), tooltip: 'Предпочитать платные дороги'),
        ],
        selected: {p.tollMode},
        onSelectionChanged: (v) => apply(() => p.tollMode = v.first),
      ),
    ]);
  }

  Widget _routeCard(int i) {
    final r = s.routes[i];
    final fast = s.routes.reduce((a, b) => b.hours < a.hours ? b : a);
    final selected = i == s.selected;
    final scheme = Theme.of(context).colorScheme;
    const tagNames = {'best': 'По вашему приоритету', 'fastest': 'Самый быстрый', 'cheapest': 'Меньше платных дорог'};
    const tagOrder = ['best', 'fastest', 'cheapest'];
    return Card(
      margin: const EdgeInsets.only(top: 10),
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.5) : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 2 : 1)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => s.select(i),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (final t in tagOrder)
                if (r.tags.contains(t))
                  Chip(
                    label: Text(tagNames[t]!, style: const TextStyle(fontSize: 11, color: Colors.white)),
                    backgroundColor: t == 'fastest' ? Colors.red.shade400 : t == 'cheapest' ? Colors.green.shade600 : scheme.primary,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    side: BorderSide.none,
                  ),
            ]),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(fmtTime(r.hours), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              Text(r.tollCost > 0 ? fmtMoney(r.tollCost) : 'Бесплатно', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            ]),
            Text('${fmtDist(r.meters)}${identical(r, fast) ? '' : ' · +${fmtTime(r.hours - fast.hours)} к самому быстрому'}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 2),
            Text.rich(TextSpan(children: [
              if (r.tollMeters > 0)
                TextSpan(text: 'Платные дороги: ${fmtDist(r.tollMeters)} — ${fmtMoney(r.tollCost)}', style: const TextStyle(color: Color(0xFFD97706), fontWeight: FontWeight.w600))
              else
                const TextSpan(text: 'Без платных дорог'),
            ]), style: Theme.of(context).textTheme.bodySmall),
            if (r.tollMeters > 0)
              Text(_tariffNote(r), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
            if (selected)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.green.shade600),
                    onPressed: () => s.startNavigation(),
                    icon: const Icon(Icons.navigation),
                    label: const Text('Поехали'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: () => s.startNavigation(simulate: true), child: const Text('Симуляция')),
                ]),
              ),
          ]),
        ),
      ),
    );
  }

  /// Откуда взята цена платных участков: тарифы операторов или ваша ставка из настроек.
  String _tariffNote(RouteData r) {
    if (r.tollKnownMeters <= 0) return 'Оценка по вашей ставке из настроек (тарифов оператора для этих дорог нет)';
    if (r.tollKnownMeters >= r.tollMeters - 1) return 'Цена по тарифам операторов';
    return 'По тарифам операторов: ${fmtDist(r.tollKnownMeters)} из ${fmtDist(r.tollMeters)}, остальное — по вашей ставке';
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
        const SizedBox(height: 16),
        Text('Маршрут по шагам', style: Theme.of(context).textTheme.titleSmall),
        for (final st in r.steps)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(_icons[st.type]),
            title: Text.rich(TextSpan(children: [
              TextSpan(text: st.text),
              if (st.toll) const TextSpan(text: ' · платная', style: TextStyle(color: Color(0xFFD97706), fontWeight: FontWeight.w600)),
            ])),
            subtitle: st.meters > 0 ? Text('${fmtDist(st.meters)} · лимит ${st.speed} км/ч') : null,
          ),
      ];

  // ---------- навигация ----------
  Widget _navOverlay() {
    final nav = s.nav!;
    final scheme = Theme.of(context).colorScheme;
    final r = s.route!;
    final next = nav.next;
    return Stack(children: [
      SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Material(
              color: const Color(0xFF0B5CD5),
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                child: Row(children: [
                  Icon(_icons[next?.type] ?? Icons.navigation, color: Colors.white, size: 38),
                  const SizedBox(width: 12),
                  Expanded(
                    child: nav.error != null
                        ? Text(nav.error!, style: const TextStyle(color: Colors.white))
                        : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(fmtDist(nav.toNext), style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700)),
                            Text(next?.text ?? '', style: const TextStyle(color: Colors.white), maxLines: 2, overflow: TextOverflow.ellipsis),
                          ]),
                  ),
                  Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white, border: Border.all(color: Colors.red, width: 5)),
                    child: Text('${nav.limit}', style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.black)),
                  ),
                  IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: s.stopNavigation),
                ]),
              ),
            ),
          ),
        ),
      ),
      SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Material(
              color: scheme.surface,
              elevation: 8,
              borderRadius: BorderRadius.circular(40),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                child: Text(
                  nav.arrived
                      ? 'Вы прибыли в пункт назначения'
                      : 'Осталось ${fmtDist(nav.remaining)} · ${fmtTime(r.hours * nav.remainingFraction)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
