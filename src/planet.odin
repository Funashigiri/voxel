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

MIN_EDGE_DIST :: 100_000.0 // высаживаемся не ближе 100 км к ребру грани

Planet_Geo :: struct {
	radius: f64, // в блоках (метрах)
	n:      i32, // колонок вдоль ребра грани
	face:   Cube_Face, // грань, на которой идёт игра
}

geo_make :: proc(radius_km: f64) -> (g: Planet_Geo) {
	g.radius = radius_km * 1000
	g.n = i32(math.round(g.radius * math.PI / 2))
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

// Точка на поверхности (в блоках) для центра колонки (x, z) текущей грани.
geo_point :: proc(g: ^Planet_Geo, x, z: i32) -> [3]f64 {
	return geo_dir(g, g.face, f64(x) + 0.5, f64(z) + 0.5) * g.radius
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

// Расстояние до ближайшего ребра грани, в блоках.
geo_edge_dist :: proc(g: ^Planet_Geo, x, z: f64) -> f64 {
	n := f64(g.n)
	return min(x, n - x, z, n - z)
}

geo_inside :: proc(g: ^Planet_Geo, x, z: i32) -> bool {
	return x >= 0 && z >= 0 && x < g.n && z < g.n
}

// Выбирает точку высадки: начиная с (lat, lon), а если она ближе 100 км к ребру
// или в океане — ищет другую в умеренных широтах. Задаёт грань и возвращает
// локальные x, z.
geo_choose_site :: proc(g: ^Planet_Geo, lat, lon: f64, seed: u32, keep_exact: bool) -> (x, z, out_lat, out_lon: f64) {
	r := eng.rng_make(u64(seed) * 977 + 3)
	la, lo := lat, lon
	for attempt in 0 ..< 3000 {
		dir := geo_from_latlon(la, lo)
		face, fx, fz := geo_locate(g, dir)
		offset, _ := planet_relief(i64(seed), dir * g.radius)
		good := geo_edge_dist(g, fx, fz) >= MIN_EDGE_DIST && offset > 3 // на суше
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
