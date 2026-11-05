import test from 'node:test';
import assert from 'node:assert/strict';
import { demoGraph, DEMO_START, DEMO_END } from '../src/demo.js';
import { planRoutes, buildSteps, ROAD_CLASSES } from '../src/router.js';
import { parseMaxspeed, buildGraph } from '../src/osm.js';

const g = demoGraph();
const plan = (prefs) => planRoutes(g, DEMO_START, DEMO_END, prefs);
const edgeNames = (r, res) => new Set(r.edges.map(i => res.ctx.g.edges[i].name));

test('parseMaxspeed', () => {
  assert.equal(parseMaxspeed('50'), 50);
  assert.equal(parseMaxspeed('60 mph'), 97);
  assert.equal(parseMaxspeed('RU:urban'), 60);
  assert.equal(parseMaxspeed('none'), 130);
  assert.equal(parseMaxspeed(undefined), null);
});

test('одностороннее движение и разбиение на рёбра', () => {
  const gg = buildGraph([
    { type: 'node', id: 1, lat: 0, lon: 0 }, { type: 'node', id: 2, lat: 0, lon: 0.01 }, { type: 'node', id: 3, lat: 0, lon: 0.02 },
    { type: 'way', id: 1, nodes: [1, 2, 3], tags: { highway: 'residential', oneway: 'yes' } },
  ]);
  assert.equal(gg.edges.length, 1);
  assert.equal(gg.edges[0].pts.length, 3);
});

test('при низкой цене времени выбирается бесплатная дорога', () => {
  const res = plan({ valueOfTime: 100 });
  assert.ok(res.routes, res.error);
  assert.equal(res.routes[0].tollCost, 0);
});

test('при высокой цене времени выбирается платная магистраль', () => {
  const res = plan({ valueOfTime: 3000 });
  assert.ok(res.routes[0].tollCost > 0);
  assert.ok(edgeNames(res.routes[0], res).has('Платная магистраль М-Демо'));
});

test('режим «только бесплатные» никогда не использует платные дороги', () => {
  const res = plan({ valueOfTime: 100000, tollMode: 'free' });
  for (const r of res.routes) assert.equal(r.tollCost, 0);
});

test('режим «предпочитать платные» выбирает магистраль даже при дешёвом времени', () => {
  const res = plan({ valueOfTime: 50, tollMode: 'prefer' });
  assert.ok(res.routes[0].tollCost > 0);
});

test('фильтр по типу дорог: без магистралей маршрут идёт по главной', () => {
  const res = plan({ valueOfTime: 100000, classes: ROAD_CLASSES.filter(c => c !== 'motorway') });
  assert.equal(res.routes[0].tollCost, 0);
  assert.ok(edgeNames(res.routes[0], res).has('Шоссе Северное'));
});

test('фильтр по макс. лимиту скорости исключает быстрые дороги', () => {
  const res = plan({ valueOfTime: 100000, maxSpeed: 60 });
  assert.ok(!edgeNames(res.routes[0], res).has('Платная магистраль М-Демо'));
});

test('фильтр по мин. лимиту скорости исключает медленные дороги', () => {
  const res = plan({ valueOfTime: 0.0001, minSpeed: 60 });
  assert.ok(!edgeNames(res.routes[0], res).has('Южная дорога'));
});

test('жилые подъезды у старта/финиша доступны даже если жилые улицы отключены', () => {
  const res = plan({ classes: ['motorway', 'primary'] });
  assert.ok(res.routes);
});

test('выдаются альтернативы: самый быстрый и самый дешёвый', () => {
  const res = plan({ valueOfTime: 300 });
  const fast = res.routes.find(r => r.tags.includes('fastest')), cheap = res.routes.find(r => r.tags.includes('cheapest'));
  assert.ok(fast.hours <= cheap.hours);
  assert.ok(cheap.money <= fast.money);
  assert.ok(fast.hours < cheap.hours, 'быстрый и дешёвый должны различаться');
});

test('нет маршрута — понятная ошибка', () => {
  const res = planRoutes(g, { lat: 10, lon: 10 }, DEMO_END, {});
  assert.ok(res.error);
});

test('пошаговые инструкции', () => {
  const res = plan({ valueOfTime: 3000 });
  const steps = buildSteps(g, res.routes[0].edges);
  assert.match(steps[0].text, /Начните движение/);
  assert.equal(steps.at(-1).type, 'arrive');
  assert.ok(steps.some(s => s.toll));
});
