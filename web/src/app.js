import { ROAD_CLASSES, CLASS_LABELS, DEFAULT_SPEED, DEFAULT_PREFS, mergePrefs, planRoutes, buildSteps, haversine } from './router.js';
import { loadGraph } from './osm.js';
import { demoGraph, DEMO_START, DEMO_END } from './demo.js';

const $ = id => document.getElementById(id);
const L = window.L;

// ---------- Настройки ----------
const STORE = 'cargo-nav-settings-v1';
const ui = {
  vot: 300, tollMode: 'any', classes: [...ROAD_CLASSES], minSpeed: 0, maxSpeed: 200, vehicleMax: 110,
  currency: '₽', tollHigh: 4, tollLow: 3, tollEntry: 0, fuelCons: 8, fuelPrice: 60,
};
try { Object.assign(ui, JSON.parse(localStorage.getItem(STORE) || '{}')); } catch { /* ignore */ }
const save = () => { try { localStorage.setItem(STORE, JSON.stringify(ui)); } catch { /* ignore */ } };

function prefs() {
  const high = ['motorway', 'trunk'];
  const tollPerKm = {};
  for (const c of ROAD_CLASSES) tollPerKm[c] = high.includes(c) ? ui.tollHigh : ui.tollLow;
  return mergePrefs({
    classes: ui.classes, minSpeed: ui.minSpeed, maxSpeed: ui.maxSpeed, vehicleMaxSpeed: ui.vehicleMax,
    tollMode: ui.tollMode, valueOfTime: ui.vot, tollPerKm, tollEntryFee: ui.tollEntry,
    fuelPer100: ui.fuelCons, fuelPrice: ui.fuelPrice,
  });
}

const numInputs = { vot: 'vot', minSpeed: 'minSpeed', maxSpeed: 'maxSpeed', vehicleMax: 'vehicleMax', tollHigh: 'tollHigh', tollLow: 'tollLow', tollEntry: 'tollEntry', fuelCons: 'fuelCons', fuelPrice: 'fuelPrice' };
for (const [key, id] of Object.entries(numInputs)) {
  const el = $(id); el.value = ui[key];
  el.addEventListener('input', () => { const v = parseFloat(el.value); if (!Number.isNaN(v)) { ui[key] = v; save(); if (key === 'vot') syncPresets(); changed(); } });
}
$('currency').value = ui.currency;
$('currency').addEventListener('input', e => { ui.currency = e.target.value || '₽'; save(); syncCur(); renderResults(); });
function syncCur() { document.querySelectorAll('.cur').forEach(e => { e.textContent = ui.currency; }); }
syncCur();

function seg(id, key, attr) {
  const box = $(id);
  const sync = () => box.querySelectorAll('button').forEach(b => b.classList.toggle('on', String(b.dataset[attr]) === String(ui[key])));
  box.addEventListener('click', e => { const b = e.target.closest('button'); if (!b) return; ui[key] = attr === 'vot' ? Number(b.dataset.vot) : b.dataset[attr]; $('vot').value = ui.vot; save(); sync(); changed(); });
  sync(); return sync;
}
const syncPresets = (() => {
  const box = $('presets');
  return () => box.querySelectorAll('button').forEach(b => b.classList.toggle('on', Number(b.dataset.vot) === ui.vot));
})();
seg('presets', 'vot', 'vot'); seg('tollMode', 'tollMode', 'v');
syncPresets();

for (const c of ROAD_CLASSES) {
  const d = document.createElement('label'); d.className = 'cls';
  d.innerHTML = `<input type="checkbox" ${ui.classes.includes(c) ? 'checked' : ''}> ${CLASS_LABELS[c]} <small>~${DEFAULT_SPEED[c]} км/ч</small>`;
  d.querySelector('input').addEventListener('change', e => {
    ui.classes = e.target.checked ? [...new Set([...ui.classes, c])] : ui.classes.filter(x => x !== c);
    save(); changed();
  });
  $('classes').appendChild(d);
}

// ---------- Карта ----------
const map = L.map('map', { zoomControl: false }).setView([55.75, 37.62], 10);
L.control.zoom({ position: 'bottomright' }).addTo(map);
L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map);

const state = { start: null, end: null, pick: null, result: null, sel: 0, graph: null, demo: false };
const markers = {};
const routeLayer = L.layerGroup().addTo(map);

function setPoint(which, ll, label) {
  state[which] = { lat: ll.lat, lon: ll.lng ?? ll.lon, label };
  $(which === 'start' ? 'from' : 'to').value = label || `${state[which].lat.toFixed(5)}, ${state[which].lon.toFixed(5)}`;
  markers[which]?.remove();
  const color = which === 'start' ? '#12b76a' : '#e5484d';
  markers[which] = L.marker([state[which].lat, state[which].lon], { draggable: true, icon: L.divIcon({ className: '', html: `<div style="width:22px;height:22px;border-radius:50%;background:${color};border:3px solid #fff;box-shadow:0 1px 6px rgba(0,0,0,.5)"></div>`, iconSize: [22, 22], iconAnchor: [11, 11] }) }).addTo(map);
  markers[which].on('dragend', () => { const p = markers[which].getLatLng(); setPoint(which, p); });
  clearResult();
}
function setPick(which) {
  state.pick = state.pick === which ? null : which;
  $('pickFrom').classList.toggle('on', state.pick === 'start'); $('pickTo').classList.toggle('on', state.pick === 'end');
  map.getContainer().style.cursor = state.pick ? 'crosshair' : '';
}
$('pickFrom').onclick = () => setPick('start'); $('pickTo').onclick = () => setPick('end');
map.on('click', e => {
  const which = state.pick || (!state.start ? 'start' : !state.end ? 'end' : null);
  if (!which) return;
  setPoint(which, e.latlng); if (state.pick) setPick(state.pick);
});
$('swap').onclick = () => {
  const a = state.start, b = state.end; state.start = state.end = null;
  if (b) setPoint('start', b, b.label); else { markers.start?.remove(); $('from').value = ''; }
  if (a) setPoint('end', a, a.label); else { markers.end?.remove(); $('to').value = ''; }
};
$('locate').onclick = () => {
  if (!navigator.geolocation) return status('Геолокация недоступна в этом браузере.', true);
  navigator.geolocation.getCurrentPosition(p => { const ll = { lat: p.coords.latitude, lng: p.coords.longitude }; setPoint('start', ll, 'Моё местоположение'); map.setView(ll, 14); },
    () => status('Не удалось определить местоположение.', true));
};
$('collapse').onclick = () => $('panel').classList.toggle('min');

// ---------- Поиск адресов (Nominatim) ----------
async function geocode(q) {
  const r = await fetch('https://nominatim.openstreetmap.org/search?format=json&limit=5&accept-language=ru&q=' + encodeURIComponent(q));
  if (!r.ok) throw new Error('Поиск адреса недоступен');
  return r.json();
}
for (const [id, which] of [['from', 'start'], ['to', 'end']]) {
  $(id).addEventListener('keydown', async e => {
    if (e.key !== 'Enter') return;
    const q = $(id).value.trim(); if (!q) return;
    const m = q.match(/^\s*(-?\d+(?:\.\d+)?)\s*[,; ]\s*(-?\d+(?:\.\d+)?)\s*$/);
    if (m) { setPoint(which, { lat: +m[1], lng: +m[2] }); map.setView([+m[1], +m[2]], 13); return; }
    try {
      status('Ищу адрес…');
      const res = await geocode(q); const box = $('suggest');
      if (!res.length) { box.hidden = true; return status('Адрес не найден.', true); }
      status(''); box.innerHTML = ''; box.hidden = false;
      for (const r of res) {
        const d = document.createElement('div'); d.textContent = r.display_name;
        d.onclick = () => { box.hidden = true; setPoint(which, { lat: +r.lat, lng: +r.lon }, r.display_name.split(',').slice(0, 3).join(',')); map.setView([+r.lat, +r.lon], 13); };
        box.appendChild(d);
      }
    } catch (err) { status(err.message, true); }
  });
}

// ---------- Построение ----------
function status(t, err) { const s = $('status'); s.textContent = t; s.classList.toggle('err', !!err); }
function clearResult() { state.result = null; routeLayer.clearLayers(); $('results').innerHTML = ''; $('steps').innerHTML = ''; }
let busy = false, pending = false;
function changed() { if (state.result && !busy) build(); else if (busy) pending = true; }

const fmtT = h => { const m = Math.round(h * 60); return m >= 60 ? `${Math.floor(m / 60)} ч ${m % 60} мин` : `${m} мин`; };
const fmtD = m => m >= 1000 ? `${(m / 1000).toFixed(m >= 10000 ? 0 : 1)} км` : `${Math.round(m / 10) * 10} м`;
const fmtM = v => `${Math.round(v).toLocaleString('ru-RU')} ${ui.currency}`;

$('go').onclick = () => build(true);
$('demo').onclick = () => {
  state.demo = true; state.graph = demoGraph();
  setPoint('start', { lat: DEMO_START.lat, lng: DEMO_START.lon }, DEMO_START.label);
  setPoint('end', { lat: DEMO_END.lat, lng: DEMO_END.lon }, DEMO_END.label);
  map.fitBounds([[55.68, 36.98], [55.82, 37.82]], { animate: false });
  build(true);
};

async function build(reload) {
  if (!state.start || !state.end) return status('Укажите точки А и Б (поиск адреса по Enter или клик по карте).', true);
  busy = true; $('go').disabled = true;
  try {
    let graph = state.graph;
    const demoNow = state.demo && haversine(state.start.lat, state.start.lon, DEMO_START.lat, DEMO_START.lon) < 5000;
    if (!demoNow) {
      state.demo = false;
      const r = await loadGraph(state.start, state.end, { onStatus: t => status(t) });
      graph = state.graph = r.graph;
    }
    status('Считаю маршруты…');
    await new Promise(r => setTimeout(r, 20));
    const res = planRoutes(graph, state.start, state.end, prefs());
    if (res.error) { clearResult(); status(res.error, true); return; }
    state.result = { ...res, graph }; state.sel = 0;
    status('');
    renderResults(); draw(true);
    $('results').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  } catch (e) { clearResult(); status(e.message || String(e), true); }
  finally { busy = false; $('go').disabled = false; if (pending) { pending = false; build(); } }
}

const TAGS = { best: 'Оптимальный для ваших настроек', fastest: 'Самый быстрый', cheapest: 'Самый дешёвый' };
function renderResults() {
  const box = $('results'); box.innerHTML = '';
  if (!state.result) return;
  const rs = state.result.routes; const fast = rs.reduce((a, b) => (b.hours < a.hours ? b : a));
  rs.forEach((r, i) => {
    const d = document.createElement('div'); d.className = 'card' + (i === state.sel ? ' sel' : '');
    const diff = r === fast ? '' : ` · +${fmtT(r.hours - fast.hours)} к самому быстрому`;
    d.innerHTML = `<div>${r.tags.map(t => `<span class="tag ${t}">${TAGS[t]}</span>`).join('')}</div>
      <div class="top"><span class="time">${fmtT(r.hours)}</span><span class="total">${fmtM(r.money)}</span></div>
      <div class="meta">${fmtD(r.meters)}${diff}</div>
      <div class="meta">${r.tollMeters ? `<span class="tollchip">Платные: ${fmtD(r.tollMeters)} — ${fmtM(r.tollCost)}</span>` : 'Без платных дорог'} · топливо ${r.fuelLiters.toFixed(1)} л — ${fmtM(r.fuelCost)}</div>`;
    d.onclick = () => { state.sel = i; renderResults(); draw(false); };
    if (i === state.sel) { const b = document.createElement('button'); b.textContent = '▶ Поехали'; b.onclick = ev => { ev.stopPropagation(); startNav(); }; d.appendChild(b); }
    box.appendChild(d);
  });
  renderSteps();
}
function renderSteps() {
  const r = state.result.routes[state.sel]; const steps = buildSteps(state.result.graph, r.edges);
  r.steps = steps;
  const ic = { depart: '🚗', straight: '⬆', 'slight right': '↗', 'slight left': '↖', right: '➡', left: '⬅', 'sharp right': '↘', 'sharp left': '↙', uturn: '↩', arrive: '🏁' };
  $('steps').innerHTML = '<h2 style="margin-top:14px">Маршрут по шагам</h2>' + steps.map(s =>
    `<div class="step"><div class="ic">${ic[s.type] || '•'}</div><div><div>${s.text}${s.toll ? ' <span class="tollchip">· платная</span>' : ''}</div>${s.meters ? `<div class="d">${fmtD(s.meters)} · лимит ${s.speed} км/ч</div>` : ''}</div></div>`).join('');
}

function routeLine(g, edges) { const pts = []; for (const ei of edges) { const e = g.edges[ei]; for (let i = pts.length ? 1 : 0; i < e.pts.length; i++) pts.push(e.pts[i]); } return pts; }
function draw(fit) {
  routeLayer.clearLayers();
  const { routes, graph } = state.result;
  routes.forEach((r, i) => {
    if (i === state.sel) return;
    L.polyline(routeLine(graph, r.edges), { color: '#8a94a6', weight: 6, opacity: 0.7 }).on('click', () => { state.sel = i; renderResults(); draw(false); }).addTo(routeLayer);
  });
  const r = routes[state.sel]; const all = routeLine(graph, r.edges);
  L.polyline(all, { color: '#fff', weight: 11, opacity: 0.95 }).addTo(routeLayer);
  L.polyline(all, { color: '#1a73e8', weight: 7 }).addTo(routeLayer);
  // платные участки — оранжевым
  let run = [];
  const flush = () => { if (run.length > 1) L.polyline(run, { color: '#f59e0b', weight: 7 }).addTo(routeLayer); run = []; };
  for (const ei of r.edges) { const e = graph.edges[ei]; if (e.toll) { if (!run.length) run.push(e.pts[0]); run.push(...e.pts.slice(1)); } else flush(); }
  flush();
  if (fit) {
    const wide = window.innerWidth > 700;
    map.fitBounds(L.latLngBounds(all), { paddingTopLeft: wide ? [420, 40] : [30, 40], paddingBottomRight: [40, wide ? 40 : Math.round(window.innerHeight * 0.65)], animate: false });
  }
}

// ---------- Навигация в пути ----------
const nav = { on: false, watch: null, sim: null, marker: null, pts: [], cum: [], edgeAt: [], stepAt: [], off: 0, spoken: new Set(), rerouting: false };
const ICONS = { depart: '🚗', straight: '⬆', 'slight right': '↗', 'slight left': '↖', right: '➡', left: '⬅', 'sharp right': '↘', 'sharp left': '↙', uturn: '↩', arrive: '🏁' };
function speak(t) {
  try {
    if (window.AndroidTTS) { window.AndroidTTS.speak(t); return; } // нативный голос в Android-приложении
    if ('speechSynthesis' in window) { const u = new SpeechSynthesisUtterance(t); u.lang = 'ru-RU'; speechSynthesis.cancel(); speechSynthesis.speak(u); }
  } catch { /* ignore */ }
}

function prepNav() {
  const { graph } = state.result; const r = state.result.routes[state.sel];
  r.steps = r.steps || buildSteps(graph, r.edges);
  nav.pts = []; nav.edgeAt = []; nav.cum = [];
  let acc = 0;
  r.edges.forEach((ei, k) => { const e = graph.edges[ei]; e.pts.forEach((p, i) => { if (nav.pts.length && i === 0) return; if (nav.pts.length) acc += haversine(nav.pts.at(-1)[0], nav.pts.at(-1)[1], p[0], p[1]); nav.pts.push(p); nav.cum.push(acc); nav.edgeAt.push(k); }); });
  nav.total = acc; nav.route = r; nav.spoken = new Set();
}
function startNav() {
  prepNav(); nav.on = true; nav.off = 0;
  document.body.classList.add('navigating'); $('navbanner').hidden = false; $('navfooter').hidden = false;
  nav.marker?.remove(); nav.marker = L.marker(nav.pts[0], { icon: L.divIcon({ className: '', html: '<div class="me"></div>', iconSize: [18, 18], iconAnchor: [9, 9] }), zIndexOffset: 1000 }).addTo(map);
  speak(nav.route.steps[0].text);
  if (navigator.geolocation && !state.demo) {
    nav.watch = navigator.geolocation.watchPosition(p => onFix(p.coords.latitude, p.coords.longitude), () => status('Нет сигнала GPS.', true), { enableHighAccuracy: true, maximumAge: 1000 });
  } else simulate();
}
function stopNav() {
  nav.on = false; if (nav.watch != null) navigator.geolocation.clearWatch(nav.watch); nav.watch = null;
  clearInterval(nav.sim); nav.sim = null; nav.marker?.remove();
  document.body.classList.remove('navigating'); $('navbanner').hidden = true; $('navfooter').hidden = true;
  try { if (window.AndroidTTS) window.AndroidTTS.stop(); else speechSynthesis.cancel(); } catch { /* ignore */ }
}
$('navstop').onclick = stopNav;

function simulate() { // демо: движение по маршруту с реальной скоростью ×20
  let d = 0; const speed = 90 / 3.6 * 20;
  nav.sim = setInterval(() => {
    d += speed; if (d >= nav.total) { d = nav.total; clearInterval(nav.sim); }
    let i = nav.cum.findIndex(c => c >= d); if (i < 1) i = 1;
    const a = nav.pts[i - 1], b = nav.pts[i], t = (d - nav.cum[i - 1]) / ((nav.cum[i] - nav.cum[i - 1]) || 1);
    onFix(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t);
  }, 1000);
}

function onFix(lat, lon) {
  if (!nav.on) return;
  nav.marker.setLatLng([lat, lon]); map.panTo([lat, lon], { animate: true });
  // ближайшая точка маршрута — проекция на отрезок полилинии
  const kx = Math.cos(lat * Math.PI / 180);
  let bi = 1, bd = Infinity, done = 0;
  for (let i = 1; i < nav.pts.length; i++) {
    const [ay, ax] = nav.pts[i - 1], [by, bx] = nav.pts[i];
    const dx = (bx - ax) * kx, dy = by - ay, px = (lon - ax) * kx, py = lat - ay;
    const l2 = dx * dx + dy * dy; const t = l2 ? Math.max(0, Math.min(1, (px * dx + py * dy) / l2)) : 0;
    const d = haversine(lat, lon, ay + dy * t, ax + (bx - ax) * t);
    if (d < bd) { bd = d; bi = i; done = nav.cum[i - 1] + t * (nav.cum[i] - nav.cum[i - 1]); }
  }
  if (bd > 80) { if (++nav.off >= 3 && !nav.rerouting) reroute(lat, lon); return; }
  nav.off = 0;
  const k = nav.edgeAt[bi]; const r = nav.route, g = state.result.graph;
  const edge = g.edges[r.edges[k]];
  $('navlimit').textContent = edge.speed;
  const next = r.steps.find(s => s.firstEdge > k) || r.steps.at(-1);
  const nextCum = next.firstEdge >= r.edges.length ? nav.total : nav.cum[nav.edgeAt.indexOf(next.firstEdge)];
  const toNext = Math.max(0, nextCum - done);
  $('navdist').textContent = fmtD(toNext); $('navtext').textContent = next.text; $('navicon').textContent = ICONS[next.type] || '➡';
  const remain = nav.total - done; const frac = remain / (nav.total || 1);
  $('navfooter').textContent = `Осталось ${fmtD(remain)} · ${fmtT(r.hours * frac)} · ${fmtM(r.money * frac)}`;
  for (const [th, label] of [[400, 'Через 400 метров'], [100, 'Через 100 метров']]) {
    const key = `${next.firstEdge}-${th}`;
    if (toNext <= th && !nav.spoken.has(key)) { nav.spoken.add(key); speak(next.type === 'arrive' ? `${label} вы прибудете в пункт назначения` : `${label} ${next.text.charAt(0).toLowerCase()}${next.text.slice(1)}`); }
  }
  if (next.type === 'arrive' && toNext < 25) { speak('Вы прибыли'); stopNav(); status('Вы прибыли в пункт назначения.'); }
}
async function reroute(lat, lon) {
  nav.rerouting = true; speak('Перестраиваю маршрут');
  try {
    const res = planRoutes(state.result.graph, { lat, lon }, state.end, prefs());
    if (res.routes) { state.start = { lat, lon, label: 'Моё местоположение' }; state.result = { ...res, graph: state.result.graph }; state.sel = 0; draw(false); renderResults(); prepNav(); nav.off = 0; }
  } finally { nav.rerouting = false; }
}

if (new URLSearchParams(location.search).has('demo')) $('demo').click();
