# Строит assets/geo/countries.json из world-atlas (Natural Earth 1:10m): страны в рамке Европы.
import json, sys, math
src, out = sys.argv[1], sys.argv[2]
EU = {'040':'AT','056':'BE','100':'BG','191':'HR','196':'CY','203':'CZ','208':'DK','233':'EE','246':'FI','250':'FR','276':'DE','300':'GR','348':'HU','372':'IE','380':'IT','428':'LV','440':'LT','442':'LU','470':'MT','528':'NL','616':'PL','620':'PT','642':'RO','703':'SK','705':'SI','724':'ES','752':'SE'}
NON = {'756':'CH','438':'LI','578':'NO','826':'GB','352':'IS','688':'RS','070':'BA','499':'ME','807':'MK','008':'AL','498':'MD','804':'UA','112':'BY','643':'RU','792':'TR','020':'AD','833':'IM','234':'FO','268':'GE','051':'AM','031':'AZ','504':'MA','012':'DZ','788':'TN','434':'LY','818':'EG','760':'SY','422':'LB','376':'IL','400':'JO','368':'IQ','364':'IR','398':'KZ','275':'PS','832':'JE','831':'GG','292':'GI'}
SKIP = {'492','674','336'}  # Монако, Сан-Марино, Ватикан: проезд не блокируем
BB = (-32.0, 27.0, 45.0, 72.0)  # lon0, lat0, lon1, lat1
t = json.load(open(src))
sx, sy = t['transform']['scale']; tx, ty = t['transform']['translate']
arcs = []
for a in t['arcs']:
    x = y = 0; pts = []
    for dx, dy in a:
        x += dx; y += dy; pts.append((x * sx + tx, y * sy + ty))
    arcs.append(pts)
def ring(idx):
    pts = []
    for i in idx:
        a = arcs[i] if i >= 0 else arcs[~i][::-1]
        pts.extend(a if not pts else a[1:])
    return pts
def dp(pts, tol):
    if len(pts) < 3: return pts
    keep = [False] * len(pts); keep[0] = keep[-1] = True; st = [(0, len(pts) - 1)]
    while st:
        a, b = st.pop(); ax, ay = pts[a]; bx, by = pts[b]; dx, dy = bx - ax, by - ay; l2 = dx * dx + dy * dy
        md = -1; mi = -1
        for i in range(a + 1, b):
            px, py = pts[i]
            if l2 == 0: d = math.hypot(px - ax, py - ay)
            else:
                u = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / l2)); d = math.hypot(px - ax - u * dx, py - ay - u * dy)
            if d > md: md, mi = d, i
        if md > tol: keep[mi] = True; st.append((a, mi)); st.append((mi, b))
    return [p for p, k in zip(pts, keep) if k]
def area(pts):
    return abs(sum(pts[i][0] * pts[i + 1][1] - pts[i + 1][0] * pts[i][1] for i in range(len(pts) - 1))) / 2
res = {}; unknown = []
for g in t['objects']['countries']['geometries']:
    cid = g.get('id'); name = g['properties']['name']
    if cid in SKIP: continue
    if cid in EU: iso, eu = EU[cid], True
    elif cid in NON: iso, eu = NON[cid], False
    elif name == 'Kosovo': iso, eu = 'XK', False
    elif name == 'N. Cyprus': iso, eu = 'XN', False
    elif name == 'Åland': iso, eu = 'FI', True
    elif name in ('Akrotiri', 'Dhekelia', 'Cyprus U.N. Buffer Zone'): continue  # дороги Кипра проходят насквозь
    else: iso, eu = None, False
    polys = [g['arcs']] if g['type'] == 'Polygon' else g['arcs']
    for poly in polys:
        r = ring(poly[0])  # только внешний контур
        xs = [p[0] for p in r]; ys = [p[1] for p in r]
        if max(xs) < BB[0] or min(xs) > BB[2] or max(ys) < BB[1] or min(ys) > BB[3]: continue
        if iso is None: unknown.append(name); iso = 'ZZ'
        if area(r) < 2e-5: continue  # < ~0.15 км²
        r = dp(r, 0.0015)
        if len(r) < 4: continue
        res.setdefault((iso, eu), []).append([v for p in r for v in (round(p[0] * 1e4), round(p[1] * 1e4))])
print('в рамке, но без кода (как не-ЕС ZZ):', sorted(set(unknown)), file=sys.stderr)
outj = {'source': 'Natural Earth 1:10m (world-atlas 2.0.2, npm), упрощено до ~150 м', 'scale': 10000,
        'countries': [{'iso': k[0], 'eu': k[1], 'rings': v} for k, v in sorted(res.items())]}
json.dump(outj, open(out, 'w'), separators=(',', ':'))
print(len(outj['countries']), 'стран', sum(len(c['rings']) for c in outj['countries']), 'контуров', sum(len(r) // 2 for c in outj['countries'] for r in c['rings']), 'вершин', file=sys.stderr)
print('ЕС:', sorted(c['iso'] for c in outj['countries'] if c['eu']), file=sys.stderr)
