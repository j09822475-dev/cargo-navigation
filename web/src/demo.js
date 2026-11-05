// Демо-сеть (без интернета): платная автомагистраль, бесплатная главная дорога
// и медленная местная дорога между двумя городами, плюс жилые подъезды.
import { buildGraph } from './osm.js';

export const DEMO_START = { lat: 55.752, lon: 36.995, label: 'Город А (демо)' };
export const DEMO_END = { lat: 55.752, lon: 37.805, label: 'Город Б (демо)' };

export function demoElements() {
  const el = [];
  const node = (id, lat, lon) => el.push({ type: 'node', id, lat, lon });
  const way = (id, nodes, tags) => el.push({ type: 'way', id, nodes, tags });
  // Платная автомагистраль по прямой: узлы 100..108
  for (let i = 0; i <= 8; i++) node(100 + i, 55.75, 37.0 + 0.1 * i);
  way(1, [100, 101, 102, 103, 104, 105, 106, 107, 108], { highway: 'motorway', toll: 'yes', maxspeed: '110', name: 'Платная магистраль М-Демо' });
  // Бесплатная главная дорога с объездом севернее
  node(201, 55.80, 37.2); node(202, 55.80, 37.4); node(203, 55.80, 37.6);
  way(2, [100, 201, 202, 203, 108], { highway: 'primary', maxspeed: '70', name: 'Шоссе Северное' });
  // Соединение главной дороги с магистралью в середине (съезд)
  way(3, [202, 104], { highway: 'secondary', maxspeed: '60', name: 'Съезд к магистрали' });
  // Медленная местная дорога южнее
  node(301, 55.70, 37.4);
  way(4, [100, 301, 108], { highway: 'tertiary', maxspeed: '50', name: 'Южная дорога' });
  // Подъезды в городах
  node(1, 55.752, 36.995); node(2, 55.752, 37.805);
  way(5, [1, 100], { highway: 'residential', maxspeed: '30', name: 'ул. Центральная' });
  way(6, [108, 2], { highway: 'residential', maxspeed: '30', name: 'ул. Вокзальная' });
  return el;
}

export function demoGraph() { return buildGraph(demoElements()); }
