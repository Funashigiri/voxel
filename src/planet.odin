package main

// Планета-шар реального размера: "раздутый куб" (кубосфера).
// Шесть граней, на каждой — сетка N x N колонок блоков; колонки смотрят от
// центра планеты. Отображение равноугольное: клетка в центре грани — ровно
// 1 блок (1 метр). Вблизи грань почти плоская (на 160 блоках поверхность
// опускается на миллиметры), поэтому игра на грани идёт в обычных плоских
// координатах (x — вдоль u, z — вдоль v, y — высота).
// Ландшафт генерируется по точке на шаре, поэтому с орбиты будет виден тот же
// рельеф, по которому ходишь.

import "core:math"
import "core:math/linalg"
import eng "engine"

Cube_Face :: enum u8 {
	PX,
	NX,
	PY, // северный полюс в центре
	NY, // южный полюс в центре
	PZ,
	NZ,
}

FACE_NAMES := [Cube_Face]string {
	.PX = "экваториальная +X",
	.NX = "экваториальная -X",
	.PY = "северная полярная",
	.NY = "южная полярная",
	.PZ = "экваториальная +Z",
	.NZ = "экваториальная -Z",
}

// n — нормаль грани (центр), u — локальная ось x, v — локальная ось z (v = u × n).
// На экваториальных гранях x смотрит на восток, z — на юг.
Face_Basis :: struct {
	n, u, v: [3]f64,
}

FACE_BASES := [Cube_Face]Face_Basis {
	.PX = {{1, 0, 0}, {0, 0, -1}, {0, -1, 0}},
	.NX = {{-1, 0, 0}, {0, 0, 1}, {0, -1, 0}},
	.PY = {{0, 1, 0}, {1, 0, 0}, {0, 0, 1}},
	.NY = {{0, -1, 0}, {1, 0, 0}, {0, 0, -1}},
	.PZ = {{0, 0, 1}, {1, 0, 0}, {0, -1, 0}},
	.NZ = {{0, 0, -1}, {-1, 0, 0}, {0, -1, 0}},
}

MIN_ANOMALY_DIST :: 20_000.0 // высаживаемся не ближе 20 км к аномалии (вершине куба)

Planet_Geo :: struct {
	radius: f64, // в блоках (метрах)
	n:      i32, // колонок вдоль ребра грани (кратно размеру чанка)
	face:   Cube_Face, // грань, на которой сейчас идёт игра ("кадр")
	edges:  [Cube_Face][Edge]Edge_Link, // кто за каким ребром и как повёрнута его сетка
}

// Рёбра грани: за -x, +x, -z, +z.
Edge :: enum u8 {
	NX,
	PX,
	NZ,
	PZ,
}

// Поворот на 90°·k и сдвиг клеточной сетки: g = r·f + t.
Xform :: struct {
	r: [2][2]i32, // r[строка][столбец]
	t: [2]i32,
}

Edge_Link :: struct {
	face: Cube_Face, // соседняя грань
	m:    Xform, // клетки за ребром (в координатах этой грани) -> клетки соседней
}

geo_make :: proc(radius_km: f64) -> (g: Planet_Geo) {
	g.radius = radius_km * 1000
	// кратно чанку, чтобы чанки соседних граней стыковались целиком
	g.n = i32(math.round(g.radius * math.PI / 2 / CHUNK_SIZE)) * CHUNK_SIZE
	geo_build_edges(&g)
	return
}

xform_cell :: proc(m: Xform, x, z: i32) -> (i32, i32) {
	return m.r[0][0] * x + m.r[0][1] * z + m.t[0], m.r[1][0] * x + m.r[1][1] * z + m.t[1]
}

// Непрерывная точка: центр клетки переходит в центр клетки.
xform_pos :: proc(m: Xform, x, z: f64) -> (f64, f64) {
	qx, qz := x - 0.5, z - 0.5
	return f64(m.r[0][0]) * qx + f64(m.r[0][1]) * qz + f64(m.t[0]) + 0.5, f64(m.r[1][0]) * qx + f64(m.r[1][1]) * qz + f64(m.t[1]) + 0.5
}

xform_vec :: proc(m: Xform, x, z: f64) -> (f64, f64) {
	return f64(m.r[0][0]) * x + f64(m.r[0][1]) * z, f64(m.r[1][0]) * x + f64(m.r[1][1]) * z
}

// Поворот направления взгляда (yaw: вперёд = (-sin, cos) в осях x, z).
xform_yaw :: proc(m: Xform, yaw: f32) -> f32 {
	fx, fz := xform_vec(m, f64(-math.sin(yaw)), f64(math.cos(yaw)))
	return f32(math.atan2(-fx, fz))
}

xform_inverse :: proc(m: Xform) -> (inv: Xform) {
	// поворот обратим транспонированием
	inv.r = {{m.r[0][0], m.r[1][0]}, {m.r[0][1], m.r[1][1]}}
	inv.t = {-(inv.r[0][0] * m.t[0] + inv.r[0][1] * m.t[1]), -(inv.r[1][0] * m.t[0] + inv.r[1][1] * m.t[1])}
	return
}

XFORM_IDENTITY :: Xform{r = {{1, 0}, {0, 1}}}

// Композиция: сначала b, потом a.
xform_compose :: proc(a, b: Xform) -> (c: Xform) {
	for i in 0 ..< 2 {
		for j in 0 ..< 2 do c.r[i][j] = a.r[i][0] * b.r[0][j] + a.r[i][1] * b.r[1][j]
		c.t[i] = a.r[i][0] * b.t[0] + a.r[i][1] * b.t[1] + a.t[i]
	}
	return
}

// Для каждой грани и ребра находим соседа и поворот его сетки: берём клетки
// сразу за серединой ребра, смотрим, в какие клетки соседа они попадают на шаре.
@(private = "file")
geo_build_edges :: proc(g: ^Planet_Geo) {
	n := g.n
	cell_of_dir :: proc(g: ^Planet_Geo, d: [3]f64) -> (Cube_Face, [2]i32) {
		f, x, z := geo_locate(g, d)
		return f, {i32(math.floor(x)), i32(math.floor(z))}
	}
	for face in Cube_Face {
		for e in Edge {
			a: [2]i32
			step: [2]i32 = {1, 1} // шаги, которые остаются за ребром
			switch e {
			case .NX:
				a, step.x = {-1, n / 2}, -1
			case .PX:
				a = {n, n / 2}
			case .NZ:
				a, step.y = {n / 2, -1}, -1
			case .PZ:
				a = {n / 2, n}
			}
			img :: proc(g: ^Planet_Geo, face: Cube_Face, c: [2]i32) -> (Cube_Face, [2]i32) {
				return cell_of_dir(g, geo_dir(g, face, f64(c.x) + 0.5, f64(c.y) + 0.5))
			}
			nf, ia := img(g, face, a)
			_, ib := img(g, face, a + [2]i32{step.x, 0})
			_, ic := img(g, face, a + [2]i32{0, step.y})
			col0 := (ib - ia) * step.x // образ единичного шага по x
			col1 := (ic - ia) * step.y // образ единичного шага по z
			m: Xform
			m.r = {{col0.x, col1.x}, {col0.y, col1.y}}
			m.t = {ia.x - (m.r[0][0] * a.x + m.r[0][1] * a.y), ia.y - (m.r[1][0] * a.x + m.r[1][1] * a.y)}
			g.edges[face][e] = {nf, m}
		}
	}
}

// Клетка (x, z) в координатах грани face -> реальная грань и клетка.
// За одним ребром — соседняя грань; за двумя сразу (у вершины куба) — пустота.
geo_resolve :: proc(g: ^Planet_Geo, face: Cube_Face, x, z: i32) -> (Cube_Face, i32, i32, bool) {
	n := g.n
	ox := x < 0 || x >= n
	oz := z < 0 || z >= n
	if !ox && !oz do return face, x, z, true
	if ox && oz do return face, 0, 0, false
	e: Edge = x < 0 ? .NX : x >= n ? .PX : z < 0 ? .NZ : .PZ
	link := g.edges[face][e]
	gx, gz := xform_cell(link.m, x, z)
	if gx < 0 || gz < 0 || gx >= n || gz >= n do return face, 0, 0, false
	return link.face, gx, gz, true
}

// Как клетки грани other лежат в кадре текущей грани (если она соседняя).
geo_frame_of :: proc(g: ^Planet_Geo, other: Cube_Face) -> (Xform, bool) {
	if other == g.face do return XFORM_IDENTITY, true
	for e in Edge {
		link := g.edges[g.face][e]
		if link.face == other do return xform_inverse(link.m), true
	}
	return {}, false
}

// Проверка: перейти через ребро и вернуться обратно — тождество (иначе
// сетки соседних граней собраны неверно). Возвращает число ошибок.
geo_check_links :: proc(g: ^Planet_Geo) -> (errors: int) {
	for face in Cube_Face {
		for e in Edge {
			link := g.edges[face][e]
			if r := link.m.r; r[0][0] * r[1][1] - r[0][1] * r[1][0] != 1 do errors += 1 // только повороты
			back, ok := Xform{}, false
			for e2 in Edge {
				if g.edges[link.face][e2].face == face {
					back, ok = g.edges[link.face][e2].m, true
				}
			}
			if !ok {
				errors += 1
				continue
			}
			for t in ([3]i32{0, g.n / 3, g.n - 1}) {
				// клетка сразу за ребром -> на соседней грани -> обратно
				c: [2]i32
				switch e {
				case .NX:
					c = {-1, t}
				case .PX:
					c = {g.n, t}
				case .NZ:
					c = {t, -1}
				case .PZ:
					c = {t, g.n}
				}
				gx, gz := xform_cell(link.m, c.x, c.y)
				bx, bz := xform_cell(back, gx, gz)
				if bx != c.x || bz != c.y do errors += 1
			}
		}
	}
	return
}

// Направление от центра планеты для точки кадра (за ребром — на соседней грани).
geo_frame_dir :: proc(g: ^Planet_Geo, x, z: f64) -> [3]f64 {
	n := f64(g.n)
	ox := x < 0 || x >= n
	oz := z < 0 || z >= n
	if ox == oz do return geo_dir(g, g.face, x, z)
	e: Edge = ox ? (x < 0 ? .NX : .PX) : (z < 0 ? .NZ : .PZ)
	link := g.edges[g.face][e]
	gx, gz := xform_pos(link.m, x, z)
	return geo_dir(g, link.face, gx, gz)
}

// Аномалии — в восьми вершинах куба: серый туман и столп из гладкого камня.
ANOMALY_RADIUS :: 150.0 // радиус тумана, блоков
ANOMALY_Y :: 64.0 // высота центра тумана
ANOMALY_DIRS := [8][3]f64 {
	{-1, -1, -1}, {-1, -1, 1}, {-1, 1, -1}, {-1, 1, 1},
	{1, -1, -1}, {1, -1, 1}, {1, 1, -1}, {1, 1, 1},
}

// Ближайшая вершина куба (угол текущей грани) в координатах кадра.
geo_nearest_corner :: proc(g: ^Planet_Geo, x, z: f64) -> (cx, cz, dist: f64) {
	n := f64(g.n)
	cx = x < n / 2 ? 0 : n
	cz = z < n / 2 ? 0 : n
	dist = math.sqrt((x - cx) * (x - cx) + (z - cz) * (z - cz))
	return
}

@(private = "file")
dot3 :: proc(a, b: [3]f64) -> f64 {return a.x * b.x + a.y * b.y + a.z * b.z}

@(private = "file")
normalize3 :: proc(a: [3]f64) -> [3]f64 {return a / math.sqrt(dot3(a, a))}

// Единичное направление от центра планеты для точки (x, z) грани.
geo_dir :: proc(g: ^Planet_Geo, face: Cube_Face, x, z: f64) -> [3]f64 {
	a := (x / f64(g.n) * 2 - 1) * (math.PI / 4)
	b := (z / f64(g.n) * 2 - 1) * (math.PI / 4)
	fb := FACE_BASES[face]
	return normalize3(fb.n + fb.u * math.tan(a) + fb.v * math.tan(b))
}

// Точка на поверхности (в блоках) для центра колонки (x, z) грани face.
// Колонки за ребром берутся у соседней грани (так рельеф на стыке совпадает).
geo_point :: proc(g: ^Planet_Geo, face: Cube_Face, x, z: i32) -> [3]f64 {
	f, gx, gz, ok := geo_resolve(g, face, x, z)
	if !ok do return geo_dir(g, face, f64(x) + 0.5, f64(z) + 0.5) * g.radius
	return geo_dir(g, f, f64(gx) + 0.5, f64(gz) + 0.5) * g.radius
}

// На какой грани и в какой клетке лежит направление.
geo_locate :: proc(g: ^Planet_Geo, dir: [3]f64) -> (face: Cube_Face, x, z: f64) {
	ax, ay, az := abs(dir.x), abs(dir.y), abs(dir.z)
	switch {
	case ax >= ay && ax >= az:
		face = dir.x > 0 ? .PX : .NX
	case ay >= az:
		face = dir.y > 0 ? .PY : .NY
	case:
		face = dir.z > 0 ? .PZ : .NZ
	}
	fb := FACE_BASES[face]
	dn := dot3(dir, fb.n)
	t := dot3(dir, fb.u) / dn
	s := dot3(dir, fb.v) / dn
	x = (math.atan(t) / (math.PI / 4) + 1) / 2 * f64(g.n)
	z = (math.atan(s) / (math.PI / 4) + 1) / 2 * f64(g.n)
	return
}

// Широта и долгота в градусах (ось планеты — Y, долгота 0 смотрит на +Z).
geo_latlon :: proc(dir: [3]f64) -> (lat, lon: f64) {
	lat = math.to_degrees(math.asin(clamp(dir.y, -1, 1)))
	lon = math.to_degrees(math.atan2(dir.x, dir.z))
	if lon < 0 do lon += 360
	return
}

geo_from_latlon :: proc(lat, lon: f64) -> [3]f64 {
	la, lo := math.to_radians(lat), math.to_radians(lon)
	return {math.cos(la) * math.sin(lo), math.sin(la), math.cos(la) * math.cos(lo)}
}

// Поверхность воды — верх водяного блока на уровне моря (блоки по y).
Y_SEA :: f64(SEA_LEVEL) + 0.875

// Как кадр (сетка текущей грани у камеры) лежит на настоящем шаре.
// Блоки вблизи рисуются в плоской сетке кадра, всё дальнее (рельеф до
// горизонта, облака) — на шаре: rel = J⁻¹·(P − pc), где J — якобиан сетки у
// камеры (столбцы: куда ведут шаги по x, y, z кадра в осях планеты). У камеры
// оба способа совпадают до миллиметров, вдали работает кривизна.
Planet_View :: struct {
	pc:     [3]f64, // камера в осях планеты, м
	up:     [3]f64, // вертикаль у камеры
	j:      matrix[3, 3]f64, // кадр -> оси планеты
	jinv:   matrix[3, 3]f64, // оси планеты -> кадр
	t1, t2: [3]f64, // ортонормированный базис касательной плоскости
	cam_h:  f64, // высота камеры над уровнем моря, м
	radius: f64,
}

planet_view_make :: proc(g: ^Planet_Geo, pos: [3]f64) -> (v: Planet_View) {
	R := g.radius
	v.radius = R
	v.up = geo_frame_dir(g, pos.x, pos.z)
	v.cam_h = pos.y - Y_SEA
	v.pc = v.up * (R + v.cam_h)
	ex := (geo_frame_dir(g, pos.x + 1, pos.z) - geo_frame_dir(g, pos.x - 1, pos.z)) * (R / 2)
	ez := (geo_frame_dir(g, pos.x, pos.z + 1) - geo_frame_dir(g, pos.x, pos.z - 1)) * (R / 2)
	cols := [3][3]f64{ex, v.up, ez}
	for c in 0 ..< 3 do for r in 0 ..< 3 do v.j[r, c] = cols[c][r]
	v.jinv = linalg.inverse(v.j)
	v.t1 = normalize3(ex - v.up * dot3(ex, v.up))
	v.t2 = cross3(v.up, v.t1)
	return
}

// Точка планеты (оси планеты, м) -> относительно камеры в осях кадра.
planet_rel :: proc(v: ^Planet_View, p: [3]f64) -> [3]f64 {
	return v.jinv * (p - v.pc)
}

@(private = "file")
cross3 :: proc(a, b: [3]f64) -> [3]f64 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

// Расстояние до ближайшего ребра грани, в блоках.
geo_edge_dist :: proc(g: ^Planet_Geo, x, z: f64) -> f64 {
	n := f64(g.n)
	return min(x, n - x, z, n - z)
}

// Выбирает точку высадки: начиная с (lat, lon), а если она ближе 20 км к
// аномалии или в океане — ищет другую в умеренных широтах. Задаёт грань и возвращает
// локальные x, z.
geo_choose_site :: proc(g: ^Planet_Geo, lat, lon: f64, seed: u32, keep_exact: bool) -> (x, z, out_lat, out_lon: f64) {
	r := eng.rng_make(u64(seed) * 977 + 3)
	la, lo := lat, lon
	for attempt in 0 ..< 3000 {
		dir := geo_from_latlon(la, lo)
		face, fx, fz := geo_locate(g, dir)
		offset, _ := planet_relief(i64(seed), dir * g.radius)
		_, _, anomaly := geo_nearest_corner(g, fx, fz)
		good := anomaly >= MIN_ANOMALY_DIST && offset > 3 // на суше
		if keep_exact || good || attempt == 2999 {
			g.face = face
			return fx, fz, la, lo
		}
		sign: f64 = eng.rng_f64(&r) < 0.5 ? -1 : 1
		la = sign * eng.rng_range(&r, 25, 55)
		lo = eng.rng_range(&r, 0, 360)
	}
	return
}
