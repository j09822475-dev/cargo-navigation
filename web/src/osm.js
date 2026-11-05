// Загрузка дорожной сети из OpenStreetMap (Overpass API) и построение графа.
import { ROAD_CLASSES, DEFAULT_SPEED, haversine } from './router.js';

export const ENDPOINTS = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
];

export function parseMaxspeed(raw) {
  if (raw == null) return null;
  const v = String(raw).trim().toLowerCase();
  if (!v) return null;
  if (v === 'none' || v === 'unlimited') return 130;
  if (v === 'walk') return 7;
  let m = v.match(/^(\d+(?:\.\d+)?)\s*mph$/);
  if (m) return Math.round(parseFloat(m[1]) * 1.609);
  m = v.match(/^(\d+(?:\.\d+)?)(\s*km\/h)?$/);
  if (m) return Math.round(parseFloat(m[1]));
  if (/living_street/.test(v)) return 20;
  if (/urban/.test(v)) return 60;
  if (/motorway/.test(v)) return 110;
  if (/rural|national|trunk/.test(v)) return 90;
  m = v.match(/\d+/);
  return m ? parseInt(m[0], 10) : null;
}

function wayInfo(t) {
  const hw = t.highway; if (!hw) return null;
  const link = hw.endsWith('_link');
  const cls = hw.replace('_link', '');
  if (!ROAD_CLASSES.includes(cls)) return null;
  if (['no', 'private'].includes(t.access) || ['no', 'private'].includes(t.motor_vehicle) || t.motorcar === 'no') return null;
  let dir = 'both'; const ow = t.oneway;
  if (ow === '-1' || ow === 'reverse') dir = 'bwd';
  else if (['yes', 'true', '1'].includes(ow)) dir = 'fwd';
  else if (ow !== 'no' && (t.junction === 'roundabout' || t.junction === 'circular' || cls === 'motorway')) dir = 'fwd';
  const def = link ? Math.min(50, DEFAULT_SPEED[cls]) : DEFAULT_SPEED[cls];
  const base = parseMaxspeed(t.maxspeed) ?? def;
  return {
    cls, link, dir, name: t.name || '', ref: t.ref || '',
    toll: t.toll === 'yes' || t['toll:motor_vehicle'] === 'yes',
    fwd: parseMaxspeed(t['maxspeed:forward']) ?? base,
    bwd: parseMaxspeed(t['maxspeed:backward']) ?? base,
  };
}

// elements — массив в формате Overpass JSON (node + way)
export function buildGraph(elements) {
  const coords = new Map(); const ways = [];
  for (const el of elements) {
    if (el.type === 'node') coords.set(el.id, [el.lat, el.lon]);
    else if (el.type === 'way' && el.tags && el.tags.highway && el.nodes) ways.push(el);
  }
  const usable = []; const count = new Map();
  for (const w of ways) {
    const info = wayInfo(w.tags); if (!info) continue;
    const nodes = w.nodes.filter(id => coords.has(id));
    if (nodes.length < 2) continue;
    usable.push({ info, nodes });
    nodes.forEach((id, i) => count.set(id, (count.get(id) || 0) + (i === 0 || i === nodes.length - 1 ? 2 : 1)));
  }
  const lat = [], lon = [], adj = [], radj = [], edges = [], idx = new Map();
  const nodeOf = id => {
    let i = idx.get(id);
    if (i === undefined) { i = lat.length; idx.set(id, i); const c = coords.get(id); lat.push(c[0]); lon.push(c[1]); adj.push([]); radj.push([]); }
    return i;
  };
  const add = (a, b, pts, info, speed) => {
    let len = 0; for (let i = 1; i < pts.length; i++) len += haversine(pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1]);
    if (len <= 0) return;
    const e = { a, b, len, speed, toll: info.toll, cls: info.cls, link: info.link, name: info.name, ref: info.ref, pts };
    const ei = edges.push(e) - 1; adj[a].push(ei); radj[b].push(ei);
  };
  for (const { info, nodes } of usable) {
    let startId = nodes[0], pts = [coords.get(startId)];
    for (let i = 1; i < nodes.length; i++) {
      const id = nodes[i]; pts.push(coords.get(id));
      if (count.get(id) > 1) {
        const a = nodeOf(startId), b = nodeOf(id);
        if (a !== b || pts.length > 2) {
          if (info.dir !== 'bwd') add(a, b, pts, info, info.fwd);
          if (info.dir !== 'fwd') add(b, a, [...pts].reverse(), info, info.bwd);
        }
        startId = id; pts = [coords.get(id)];
      }
    }
  }
  return { lat, lon, adj, radj, edges };
}

// ---------- Запрос Overpass ----------
const withLinks = list => list.flatMap(c => [c, c + '_link']);
const rx = list => `^(${withLinks(list).join('|')})$`;

export function planFetch(start, end) {
  const pad = (a, b) => Math.max(0.03, Math.abs(a - b) * 0.25);
  const south = Math.min(start.lat, end.lat) - pad(start.lat, end.lat), north = Math.max(start.lat, end.lat) + pad(start.lat, end.lat);
  const cosLat = Math.cos(((south + north) / 2) * Math.PI / 180);
  const lonPad = Math.max(0.03 / Math.max(cosLat, 0.2), Math.abs(start.lon - end.lon) * 0.25);
  const west = Math.min(start.lon, end.lon) - lonPad, east = Math.max(start.lon, end.lon) + lonPad;
  const areaKm2 = (north - south) * 111 * (east - west) * 111 * cosLat;
  if (areaKm2 > 400000) throw new Error('Слишком большое расстояние для загрузки данных (> ~600 км). Выберите точки ближе.');
  let mid = ROAD_CLASSES;
  let tier = 'все дороги';
  if (areaKm2 > 60000) { mid = ['motorway', 'trunk', 'primary']; tier = 'только магистрали и главные дороги'; }
  else if (areaKm2 > 10000) { mid = ['motorway', 'trunk', 'primary', 'secondary']; tier = 'без мелких дорог'; }
  else if (areaKm2 > 1500) { mid = ['motorway', 'trunk', 'primary', 'secondary', 'tertiary']; tier = 'без жилых улиц'; }
  const local = 0.025;
  const box = (p, d) => `${p.lat - d},${p.lon - d / Math.max(cosLat, 0.2)},${p.lat + d},${p.lon + d / Math.max(cosLat, 0.2)}`;
  const q = `[out:json][timeout:90];(`
    + `way["highway"~"${rx(mid)}"](${south},${west},${north},${east});`
    + (mid === ROAD_CLASSES ? '' : `way["highway"~"${rx(ROAD_CLASSES)}"](${box(start, local)});way["highway"~"${rx(ROAD_CLASSES)}"](${box(end, local)});`)
    + `);out body;>;out skel qt;`;
  return { query: q, areaKm2, tier };
}

const cache = [];
export async function loadGraph(start, end, { signal, onStatus } = {}) {
  const plan = planFetch(start, end);
  const hit = cache.find(c => c.query === plan.query);
  if (hit) return { graph: hit.graph, tier: plan.tier, cached: true };
  let lastErr;
  for (const url of ENDPOINTS) {
    try {
      onStatus?.(`Загружаю дороги OpenStreetMap (${plan.tier})…`);
      const res = await fetch(url, { method: 'POST', body: 'data=' + encodeURIComponent(plan.query),
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, signal });
      if (!res.ok) throw new Error(`Overpass ${res.status}`);
      const json = await res.json();
      onStatus?.('Строю граф дорог…');
      const graph = buildGraph(json.elements);
      if (!graph.edges.length) throw new Error('В выбранной области нет дорог.');
      cache.unshift({ query: plan.query, graph }); cache.length = Math.min(cache.length, 3);
      return { graph, tier: plan.tier, cached: false };
    } catch (e) {
      if (e.name === 'AbortError') throw e;
      lastErr = e;
    }
  }
  throw new Error('Не удалось загрузить данные OpenStreetMap: ' + (lastErr?.message || 'ошибка сети'));
}
