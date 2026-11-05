// Ядро маршрутизации: A* по обобщённой стоимости
//   стоимость = время(ч) * ЦЕНА_ВРЕМЕНИ + платные дороги + топливо
// Перебирая цену времени от 0 до «бесконечности», получаем фронт Парето:
// от самого дешёвого до самого быстрого маршрута.

export const ROAD_CLASSES = ['motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'unclassified', 'residential', 'living_street'];

export const CLASS_LABELS = {
  motorway: 'Автомагистрали', trunk: 'Скоростные шоссе', primary: 'Главные дороги',
  secondary: 'Второстепенные', tertiary: 'Местные соединительные', unclassified: 'Прочие дороги',
  residential: 'Улицы жилых кварталов', living_street: 'Дворовые проезды',
};

// Лимит по умолчанию, если в OSM нет maxspeed (км/ч)
export const DEFAULT_SPEED = { motorway: 110, trunk: 90, primary: 70, secondary: 60, tertiary: 50, unclassified: 50, residential: 40, living_street: 20 };
// Средняя реальная скорость относительно лимита (светофоры, трафик)
export const CLASS_FACTOR = { motorway: 0.95, trunk: 0.9, primary: 0.85, secondary: 0.8, tertiary: 0.8, unclassified: 0.8, residential: 0.7, living_street: 0.6 };
const LOCAL = new Set(['tertiary', 'unclassified', 'residential', 'living_street']);

export const DEFAULT_PREFS = {
  classes: [...ROAD_CLASSES],   // разрешённые типы дорог
  minSpeed: 0,                  // не ездить по дорогам с лимитом ниже (км/ч)
  maxSpeed: 200,                // не ездить по дорогам с лимитом выше (км/ч)
  vehicleMaxSpeed: 110,         // потолок скорости вашего авто (км/ч)
  tollMode: 'any',              // 'any' — комбинировать; 'free' — только бесплатные; 'prefer' — предпочитать платные
  valueOfTime: 300,             // сколько стоит час времени (в валюте/час)
  tollPerKm: { motorway: 4, trunk: 4, primary: 3, secondary: 3, tertiary: 3, unclassified: 3, residential: 3, living_street: 3 },
  tollEntryFee: 0,              // фикс. плата за въезд на платный участок
  fuelPer100: 8,                // л/100 км
  fuelPrice: 60,                // цена литра
  accessRadius: 800,            // м у старта/финиша, где фильтры не действуют
  preferPenalty: 2.5,           // во сколько раз «дороже» бесплатные дороги в режиме 'prefer'
};

export function mergePrefs(p = {}) {
  return { ...DEFAULT_PREFS, ...p, tollPerKm: { ...DEFAULT_PREFS.tollPerKm, ...(p.tollPerKm || {}) } };
}

const R = 6371000;
const rad = Math.PI / 180;
export function haversine(lat1, lon1, lat2, lon2) {
  const dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}
export function bearing(lat1, lon1, lat2, lon2) {
  const y = Math.sin((lon2 - lon1) * rad) * Math.cos(lat2 * rad);
  const x = Math.cos(lat1 * rad) * Math.sin(lat2 * rad) - Math.sin(lat1 * rad) * Math.cos(lat2 * rad) * Math.cos((lon2 - lon1) * rad);
  return (Math.atan2(y, x) / rad + 360) % 360;
}

// Расход топлива относительно среднего: минимум около 70 км/ч, растёт на высоких и очень низких скоростях.
export function fuelFactor(v) { const d = (v - 70) / 60; return 0.8 + 0.5 * d * d; }

export function effectiveSpeed(e, p) {
  return Math.max(5, Math.min(e.speed, p.vehicleMaxSpeed) * (CLASS_FACTOR[e.cls] ?? 0.8));
}

class MinHeap {
  constructor() { this.k = []; this.v = []; }
  get size() { return this.k.length; }
  push(key, val) {
    const k = this.k, v = this.v; let i = k.length; k.push(key); v.push(val);
    while (i > 0) { const p = (i - 1) >> 1; if (k[p] <= key) break; k[i] = k[p]; v[i] = v[p]; i = p; }
    k[i] = key; v[i] = val;
  }
  pop() {
    const k = this.k, v = this.v, top = v[0], lk = k.pop(), lv = v.pop(), n = k.length;
    if (n) {
      let i = 0;
      for (;;) {
        let c = 2 * i + 1; if (c >= n) break;
        if (c + 1 < n && k[c + 1] < k[c]) c++;
        if (k[c] >= lk) break;
        k[i] = k[c]; v[i] = v[c]; i = c;
      }
      k[i] = lk; v[i] = lv;
    }
    return top;
  }
}

export function nearestNodes(g, lat, lon, count = 5, maxMeters = 3000) {
  const best = [];
  for (let i = 0; i < g.lat.length; i++) {
    if (!g.adj[i].length && !g.radj[i].length) continue;
    const d = haversine(lat, lon, g.lat[i], g.lon[i]);
    if (d > maxMeters) continue;
    if (best.length < count || d < best[best.length - 1].d) {
      best.push({ id: i, d }); best.sort((a, b) => a.d - b.d); if (best.length > count) best.pop();
    }
  }
  return best;
}

// Узлы в радиусе по дорожной сети от точки (по исходящим или входящим рёбрам)
function reach(g, node, radius, adj, endOf, out) {
  const dist = new Map([[node, 0]]); const h = new MinHeap(); h.push(0, node);
  while (h.size) {
    const n = h.pop(); const d = dist.get(n);
    out[n] = 1;
    for (const ei of adj[n]) {
      const e = g.edges[ei]; const m = endOf(e); const nd = d + e.len;
      if (nd <= radius && nd < (dist.get(m) ?? Infinity)) { dist.set(m, nd); h.push(nd, m); }
    }
  }
}

// Подготовка: допустимость рёбер, время, топливо, платежи — один раз на все варианты цены времени.
export function prepare(g, startNode, endNode, prefsIn) {
  const p = mergePrefs(prefsIn);
  const E = g.edges.length;
  const access = new Uint8Array(g.lat.length);
  reach(g, startNode, p.accessRadius, g.adj, e => e.b, access);
  reach(g, endNode, p.accessRadius, g.radj, e => e.a, access);
  const classes = new Set(p.classes);
  const ctx = { g, p, startNode, endNode, allowed: new Uint8Array(E), hours: new Float64Array(E),
    fuelL: new Float64Array(E), toll: new Float64Array(E), mult: new Float64Array(E), vmax: 30 };
  for (let i = 0; i < E; i++) {
    const e = g.edges[i];
    const v = effectiveSpeed(e, p), km = e.len / 1000;
    ctx.hours[i] = km / v;
    ctx.fuelL[i] = km * p.fuelPer100 / 100 * fuelFactor(v);
    ctx.toll[i] = e.toll ? km * (p.tollPerKm[e.cls] ?? 3) : 0;
    ctx.mult[i] = p.tollMode === 'prefer' && !e.toll ? p.preferPenalty : 1;
    if (v > ctx.vmax) ctx.vmax = v;
    let ok = true;
    if (p.tollMode === 'free' && e.toll) ok = false;
    else if (!(access[e.a] && access[e.b] && LOCAL.has(e.cls))) {
      if (!classes.has(e.cls) || e.speed < p.minSpeed || e.speed > p.maxSpeed) ok = false;
    }
    ctx.allowed[i] = ok ? 1 : 0;
  }
  return ctx;
}

// A* для заданной цены времени lambda (валюта/час).
export function search(ctx, lambda) {
  const { g, p, allowed, hours, fuelL, toll, mult, startNode, endNode } = ctx;
  const fee = p.tollMode === 'free' ? 0 : p.tollEntryFee;
  const N = g.lat.length, S = N * 2;
  const dist = new Float64Array(S).fill(Infinity);
  const prevE = new Int32Array(S).fill(-1), prevS = new Int32Array(S).fill(-1);
  const hc = new Float64Array(N).fill(-1);
  const h = n => {
    if (hc[n] < 0) hc[n] = haversine(g.lat[n], g.lon[n], g.lat[endNode], g.lon[endNode]) / 1000 / ctx.vmax * lambda;
    return hc[n];
  };
  const heap = new MinHeap();
  const s0 = startNode * 2; dist[s0] = 0; heap.push(h(startNode), s0);
  let goal = -1;
  while (heap.size) {
    const s = heap.pop(); const n = s >> 1, f = s & 1;
    if (n === endNode) { goal = s; break; }
    const d = dist[s];
    for (const ei of g.adj[n]) {
      if (!allowed[ei]) continue;
      const e = g.edges[ei];
      const ns = e.b * 2 + (e.toll ? 1 : 0);
      const c = d + (hours[ei] * lambda + fuelL[ei] * p.fuelPrice + toll[ei]) * mult[ei] + (e.toll && !f ? fee : 0);
      if (c < dist[ns]) { dist[ns] = c; prevE[ns] = ei; prevS[ns] = s; heap.push(c + h(e.b), ns); }
    }
  }
  if (goal < 0) return null;
  const path = [];
  for (let s = goal; prevE[s] >= 0; s = prevS[s]) path.push(prevE[s]);
  path.reverse();
  return summarize(ctx, path);
}

export function summarize(ctx, path) {
  const { g, p } = ctx;
  let hrs = 0, m = 0, tollM = 0, tollLen = 0, lit = 0, inToll = false;
  for (const ei of path) {
    const e = g.edges[ei];
    hrs += ctx.hours[ei]; m += e.len; lit += ctx.fuelL[ei];
    if (e.toll) { tollM += ctx.toll[ei]; tollLen += e.len; if (!inToll && p.tollMode !== 'free') tollM += p.tollEntryFee; }
    inToll = !!e.toll;
  }
  const fuelCost = lit * p.fuelPrice;
  return { edges: path, hours: hrs, meters: m, tollCost: tollM, tollMeters: tollLen,
    fuelLiters: lit, fuelCost, money: tollM + fuelCost };
}

// Строит набор маршрутов на фронте Парето «время ↔ деньги».
// Первый в списке — оптимальный для заданной цены времени.
export function planRoutes(g, start, end, prefsIn) {
  const p = mergePrefs(prefsIn);
  const ss = nearestNodes(g, start.lat, start.lon), es = nearestNodes(g, end.lat, end.lon);
  if (!ss.length) return { error: 'Рядом с точкой старта нет дорог в загруженных данных.' };
  if (!es.length) return { error: 'Рядом с точкой финиша нет дорог в загруженных данных.' };
  const base = p.valueOfTime > 0 ? p.valueOfTime : 100;
  const lambdas = [0, ...[-5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5].map(k => base * 2 ** k), base * 1e4];

  // Пробуем ближайшие узлы, пока не найдём связный маршрут
  const combos = [];
  for (let i = 0; i < ss.length; i++) for (let j = 0; j < es.length; j++) combos.push([i, j]);
  combos.sort((a, b) => a[0] + a[1] - (b[0] + b[1]));
  for (const [i, j] of combos) {
    if (ss[i].id === es[j].id) continue;
    const ctx = prepare(g, ss[i].id, es[j].id, p);
    const main = search(ctx, p.valueOfTime);
    if (!main) continue;
    const seen = new Map([[main.edges.join(','), main]]);
    for (const l of lambdas) {
      const r = search(ctx, l);
      if (r) { const k = r.edges.join(','); if (!seen.has(k)) seen.set(k, r); }
    }
    let list = [...seen.values()];
    // Убираем заведомо проигрышные (и дольше, и дороже другого)
    list = list.filter(a => a === main || !list.some(b => b !== a && b.hours <= a.hours && b.money <= a.money && (b.hours < a.hours || b.money < a.money)));
    const fastest = list.reduce((a, b) => (b.hours < a.hours ? b : a));
    const cheapest = list.reduce((a, b) => (b.money < a.money || (b.money === a.money && b.hours < a.hours) ? b : a));
    main.tags = ['best']; fastest.tags = [...(fastest.tags || []), 'fastest']; cheapest.tags = [...(cheapest.tags || []), 'cheapest'];
    list.forEach(r => { r.tags = r.tags || []; });
    list.sort((a, b) => (a === main ? -1 : b === main ? 1 : a.hours - b.hours));
    return { routes: list, ctx, startNode: ss[i].id, endNode: es[j].id };
  }
  const why = p.tollMode === 'free' ? ' Попробуйте разрешить платные дороги или больше типов дорог.' : ' Ослабьте фильтры типов дорог и ограничений скорости.';
  return { error: 'Маршрут по заданным условиям не найден.' + why };
}

// ---------- Пошаговые инструкции ----------
const norm = a => ((a + 540) % 360) - 180;

function turnOf(delta) {
  const a = Math.abs(delta);
  if (a < 20) return 'straight';
  if (a < 60) return delta > 0 ? 'slight right' : 'slight left';
  if (a < 125) return delta > 0 ? 'right' : 'left';
  if (a < 170) return delta > 0 ? 'sharp right' : 'sharp left';
  return 'uturn';
}
const TURN_RU = { straight: 'Продолжайте движение', 'slight right': 'Плавно поверните направо', 'slight left': 'Плавно поверните налево',
  right: 'Поверните направо', left: 'Поверните налево', 'sharp right': 'Резко поверните направо', 'sharp left': 'Резко поверните налево', uturn: 'Развернитесь' };

function roadName(e) {
  if (e.name) return e.ref ? `${e.name} (${e.ref})` : e.name;
  if (e.ref) return e.ref;
  return (CLASS_LABELS[e.cls] || 'дорога').toLowerCase();
}

export function buildSteps(g, edgeIdxs) {
  const steps = []; let prev = null, cur = null;
  const outB = e => { const n = e.pts.length; return bearing(e.pts[n - 2][0], e.pts[n - 2][1], e.pts[n - 1][0], e.pts[n - 1][1]); };
  const inB = e => bearing(e.pts[0][0], e.pts[0][1], e.pts[1][0], e.pts[1][1]);
  edgeIdxs.forEach((ei, k) => {
    const e = g.edges[ei]; const label = roadName(e);
    if (!cur || cur.label !== label) {
      let type = 'depart', text;
      if (prev) {
        type = turnOf(norm(inB(e) - outB(prev)));
        text = `${TURN_RU[type]} ${type === 'straight' ? 'по' : 'на'} ${label}`;
      } else text = `Начните движение по ${label}`;
      cur = { type, text, label, meters: 0, toll: !!e.toll, speed: e.speed, lat: e.pts[0][0], lon: e.pts[0][1], firstEdge: k };
      steps.push(cur);
    }
    cur.meters += e.len; if (e.toll) cur.toll = true;
    prev = e;
  });
  steps.push({ type: 'arrive', text: 'Вы прибыли в пункт назначения', label: '', meters: 0, toll: false, lat: prev ? prev.pts[prev.pts.length - 1][0] : 0, lon: prev ? prev.pts[prev.pts.length - 1][1] : 0, firstEdge: edgeIdxs.length });
  return steps;
}
