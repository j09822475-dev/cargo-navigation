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

/// Что важнее. Денежной цены времени нет: «быстрее» — минимум времени (платные только при выигрыше во времени),
/// «дешевле» — минимум платных дорог (из равных по стоимости — самый быстрый).
enum Priority {
  fastest('Быстрее'),
  cheapest('Дешевле');

  final String label;
  const Priority(this.label);
}

class RoutePrefs {
  Set<int> classes;
  double minSpeed, maxSpeed, vehicleMax;
  TollMode tollMode;
  Priority priority;
  double tollHigh, tollLow, tollEntry; // € за км на магистралях/шоссе, на прочих, за въезд
  double accessRadius; // м у старта/финиша, где фильтры не действуют
  double preferPenalty; // во сколько раз «дороже» бесплатные дороги в режиме prefer

  RoutePrefs({
    Set<int>? classes,
    this.minSpeed = 0,
    this.maxSpeed = 200,
    this.vehicleMax = 110,
    this.tollMode = TollMode.any,
    this.priority = Priority.fastest,
    this.tollHigh = 0.10,
    this.tollLow = 0.07,
    this.tollEntry = 0,
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
        'priority': priority.name,
        'tollHigh': tollHigh,
        'tollLow': tollLow,
        'tollEntry': tollEntry,
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
      priority: Priority.values.firstWhere((m) => m.name == j['priority'], orElse: () => Priority.fastest),
      tollHigh: d('tollHigh', 0.10),
      tollLow: d('tollLow', 0.07),
      tollEntry: d('tollEntry', 0),
      accessRadius: d('accessRadius', 800),
      preferPenalty: d('preferPenalty', 2.5),
    );
  }
}
