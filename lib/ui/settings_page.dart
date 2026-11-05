import 'package:flutter/material.dart';

import '../core/prefs.dart';
import 'app_state.dart';

/// Настройки: что важнее, платные дороги, типы дорог, ограничения скорости, стоимость.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state});
  final AppState state;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  RoutePrefs get p => widget.state.prefs;

  void _changed(VoidCallback f) {
    setState(f);
    widget.state.savePrefs();
  }

  @override
  Widget build(BuildContext context) {
    final cur = p.currency;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки маршрута')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _h('Что важнее'),
          SegmentedButton<double>(
            segments: const [
              ButtonSegment(value: 5000, label: Text('Быстрее'), icon: Icon(Icons.bolt)),
              ButtonSegment(value: 300, label: Text('Баланс'), icon: Icon(Icons.balance)),
              ButtonSegment(value: 0, label: Text('Дешевле'), icon: Icon(Icons.savings)),
            ],
            emptySelectionAllowed: true,
            selected: {if ([5000.0, 300.0, 0.0].contains(p.valueOfTime)) p.valueOfTime},
            onSelectionChanged: (s) => _changed(() => p.valueOfTime = s.first),
          ),
          _num('Цена вашего часа времени, $cur/ч', p.valueOfTime, (v) => p.valueOfTime = v, step: 10),
          _hint('Маршрут минимизирует «время × цена часа + платные дороги + топливо». '
              'Чем дороже ваше время, тем охотнее выбираются платные скоростные дороги.'),
          _h('Платные дороги'),
          SegmentedButton<TollMode>(
            segments: const [
              ButtonSegment(value: TollMode.any, label: Text('Любые', maxLines: 1)),
              ButtonSegment(value: TollMode.free, label: Text('Бесплатные', maxLines: 1)),
              ButtonSegment(value: TollMode.prefer, label: Text('Платные', maxLines: 1)),
            ],
            selected: {p.tollMode},
            showSelectedIcon: false,
            onSelectionChanged: (s) => _changed(() => p.tollMode = s.first),
          ),
          _hint('Любые — платные и бесплатные комбинируются так, чтобы суммарные затраты были минимальными. '
              'Бесплатные — платные дороги исключены. Платные — свободные дороги считаются «дороже» (едем по платным, где возможно).'),
          _h('Типы дорог'),
          for (var i = 0; i < roadClasses.length; i++)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(classLabels[i]),
              subtitle: Text('обычно ~${defaultSpeed[i]} км/ч'),
              value: p.classes.contains(i),
              onChanged: (v) => _changed(() => v == true ? p.classes.add(i) : p.classes.remove(i)),
            ),
          _hint('Для маршрутов длиннее 120 км нужен хотя бы один из типов: магистрали, шоссе, главные или второстепенные дороги.'),
          _h('Ограничения скорости'),
          Text('Не ездить по дорогам с лимитом: ${p.minSpeed.round()}–${p.maxSpeed.round()} км/ч'),
          RangeSlider(
            values: RangeValues(p.minSpeed, p.maxSpeed),
            min: 0,
            max: 200,
            divisions: 20,
            labels: RangeLabels('${p.minSpeed.round()}', '${p.maxSpeed.round()}'),
            onChanged: (v) => _changed(() {
              p.minSpeed = v.start;
              p.maxSpeed = v.end;
            }),
          ),
          Text('Максимальная скорость вашего авто: ${p.vehicleMax.round()} км/ч'),
          Slider(
            value: p.vehicleMax.clamp(30, 200),
            min: 30,
            max: 200,
            divisions: 34,
            label: '${p.vehicleMax.round()}',
            onChanged: (v) => _changed(() => p.vehicleMax = v),
          ),
          _hint('Рядом со стартом и финишем (~800 м) мелкие улицы доступны всегда — иначе нельзя выехать со двора.'),
          _h('Стоимость проезда и топлива'),
          _text('Валюта', p.currency, (v) => p.currency = v.isEmpty ? '₽' : v),
          _num('Платная магистраль / шоссе, $cur/км', p.tollHigh, (v) => p.tollHigh = v, step: 0.5),
          _num('Прочие платные дороги, $cur/км', p.tollLow, (v) => p.tollLow = v, step: 0.5),
          _num('Плата за въезд на платный участок, $cur', p.tollEntry, (v) => p.tollEntry = v, step: 10),
          _num('Расход топлива, л/100 км', p.fuelPer100, (v) => p.fuelPer100 = v, step: 0.5),
          _num('Цена топлива, $cur/л', p.fuelPrice, (v) => p.fuelPrice = v, step: 1),
          _hint('OpenStreetMap знает, какие дороги платные, но не тарифы — поэтому ставки задаёте вы.'),
        ],
      ),
    );
  }

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(t, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      );

  Widget _hint(String t) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(t, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
      );

  Widget _num(String label, double value, void Function(double) set, {double step = 1}) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextFormField(
          key: ValueKey('$label-${value == value.roundToDouble() ? value.round() : value}'),
          initialValue: value == value.roundToDouble() ? '${value.round()}' : '$value',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
          onChanged: (t) {
            final v = double.tryParse(t.replaceAll(',', '.'));
            if (v != null && v >= 0) {
              set(v);
              widget.state.savePrefs();
            }
          },
        ),
      );

  Widget _text(String label, String value, void Function(String) set) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextFormField(
          initialValue: value,
          maxLength: 4,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true, counterText: ''),
          onChanged: (t) {
            set(t.trim());
            widget.state.savePrefs();
          },
        ),
      );
}
