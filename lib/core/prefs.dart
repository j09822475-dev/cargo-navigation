/// Типы дорог (индекс = значение в типизированных массивах графа).
const roadClasses = <String>[
  'motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'unclassified', 'residential', 'living_street',
];
const classLabels = <String>[
  'Автомагистрали', 'Скоростные шоссе', 'Главные дороги', 'Второстепенные',
  'Местные соединительные', 'Прочие дороги', 'Улицы жилых кварталов', 'Дворовые проезды',
];

/// Лимит по умолчанию, если в OSM нет maxspeed (км/ч).
const defaultSpeed = <int>[110, 90, 70, 60, 50, 50, 40, 20];

/// Средняя реальная скорость относительно лимита (светофоры, трафик).
const classFactor = <double>[0.95, 0.9, 0.85, 0.8, 0.8, 0.8, 0.7, 0.6];

/// Местные классы: доступны в зоне у старта/финиша независимо от фильтров.
bool isLocalClass(int c) => c >= 4;

enum TollMode {
  any('Комбинировать'),
  free('Только бесплатные'),
  prefer('Предпочитать платные');

  final String label;
  const TollMode(this.label);
}

class RoutePrefs {
  Set<int> classes;
  double minSpeed, maxSpeed, vehicleMax;
  TollMode tollMode;
  double valueOfTime; // стоимость часа времени
  double tollHigh, tollLow, tollEntry; // за км на магистралях/шоссе, на прочих, за въезд
  double fuelPer100, fuelPrice;
  String currency;
  double accessRadius; // м у старта/финиша, где фильтры не действуют
  double preferPenalty; // во сколько раз «дороже» бесплатные дороги в режиме prefer

  RoutePrefs({
    Set<int>? classes,
    this.minSpeed = 0,
    this.maxSpeed = 200,
    this.vehicleMax = 110,
    this.tollMode = TollMode.any,
    this.valueOfTime = 300,
    this.tollHigh = 4,
    this.tollLow = 3,
    this.tollEntry = 0,
    this.fuelPer100 = 8,
    this.fuelPrice = 60,
    this.currency = '₽',
    this.accessRadius = 800,
    this.preferPenalty = 2.5,
  }) : classes = classes ?? {for (var i = 0; i < roadClasses.length; i++) i};

  double tollPerKm(int cls) => cls <= 1 ? tollHigh : tollLow;

  RoutePrefs copy() => RoutePrefs.fromJson(toJson());

  Map<String, Object?> toJson() => {
        'classes': classes.toList()..sort(),
        'minSpeed': minSpeed,
        'maxSpeed': maxSpeed,
        'vehicleMax': vehicleMax,
        'tollMode': tollMode.name,
        'valueOfTime': valueOfTime,
        'tollHigh': tollHigh,
        'tollLow': tollLow,
        'tollEntry': tollEntry,
        'fuelPer100': fuelPer100,
        'fuelPrice': fuelPrice,
        'currency': currency,
        'accessRadius': accessRadius,
        'preferPenalty': preferPenalty,
      };

  factory RoutePrefs.fromJson(Map<String, Object?> j) {
    double d(String k, double def) => (j[k] as num?)?.toDouble() ?? def;
    return RoutePrefs(
      classes: (j['classes'] as List?)?.map((e) => (e as num).toInt()).toSet(),
      minSpeed: d('minSpeed', 0),
      maxSpeed: d('maxSpeed', 200),
      vehicleMax: d('vehicleMax', 110),
      tollMode: TollMode.values.firstWhere((m) => m.name == j['tollMode'], orElse: () => TollMode.any),
      valueOfTime: d('valueOfTime', 300),
      tollHigh: d('tollHigh', 4),
      tollLow: d('tollLow', 3),
      tollEntry: d('tollEntry', 0),
      fuelPer100: d('fuelPer100', 8),
      fuelPrice: d('fuelPrice', 60),
      currency: (j['currency'] as String?) ?? '₽',
      accessRadius: d('accessRadius', 800),
      preferPenalty: d('preferPenalty', 2.5),
    );
  }
}
