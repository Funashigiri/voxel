package main

// Небо (градиент + квадратное солнце) и объёмные "кубические" облака,
// медленно плывущие над миром, как в Minecraft (Fancy clouds).
//
// Узор облаков привязан к шару: клетка облачной сетки берёт шум в своей
// точке планеты, поэтому облака одни и те же, с какой грани ни смотри.

import "core:math"
import gl "vendor:OpenGL"

SKY_TOP :: [3]f32{0.47, 0.65, 1.0}
SKY_HORIZON :: [3]f32{0.74, 0.84, 1.0}

CLOUD_CELL :: 12.0 // блоков в клетке
CLOUD_Y :: 140.0
CLOUD_THICK :: 4.0
CLOUD_RADIUS :: 26 // клеток вокруг камеры
CLOUD_SPEED :: 0.6 // блоков в секунду

Cloud_Vertex :: struct {
	pos:   [3]f32,
	shade: f32,
}

Sky :: struct {
	sun_dir:     [3]f32,
	empty_vao:   u32,
	cloud_vao:   u32,
	cloud_vbo:   u32,
	cloud_verts: i32,
	seed:        u32,
	// Облачная сетка в кадре: клетка (i, j) занимает [C·i, C·(i+1)) + phase + drift.
	// phase — фаза сетки (точка), drift — снос ветром (вектор), wind — ветер.
	// При переходе через ребро все три переводятся в новый кадр.
	phase:       [2]f64,
	drift:       [2]f64,
	wind:        [2]f64,
	last_time:   f64,
	built_cell:  [2]i32,
	built:       bool,
}

sky_init :: proc(s: ^Sky, seed: u32) {
	// солнце в утренней части неба (на востоке, +X), путь — в плоскости XY
	elev := math.to_radians(f32(50))
	s.sun_dir = {math.cos(elev), math.sin(elev), 0}

	gl.GenVertexArrays(1, &s.empty_vao)
	s.seed = seed
	s.wind = {CLOUD_SPEED, 0}

	gl.GenVertexArrays(1, &s.cloud_vao)
	gl.GenBuffers(1, &s.cloud_vbo)
	gl.BindVertexArray(s.cloud_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, s.cloud_vbo)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, size_of(Cloud_Vertex), offset_of(Cloud_Vertex, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 1, gl.FLOAT, false, size_of(Cloud_Vertex), offset_of(Cloud_Vertex, shade))
	gl.BindVertexArray(0)
}

// Есть ли облако в клетке (i, j): шум в точке планеты под центром клетки
// (без сноса — снос двигает уже готовый узор).
@(private = "file")
cloud_sample :: proc(s: ^Sky, g: ^Planet_Geo, i, j: i32) -> bool {
	x := (f64(i) + 0.5) * CLOUD_CELL + s.phase.x
	z := (f64(j) + 0.5) * CLOUD_CELL + s.phase.y
	p := geo_point(g, g.face, i32(math.floor(x)), i32(math.floor(z)))
	return fbm(i64(s.seed) + 31, p, 16 * CLOUD_CELL, 3) > CLOUD_THRESHOLD
}

CLOUD_THRESHOLD :: 0.2

@(private = "file")
cloud_face :: proc(out: ^[dynamic]Cloud_Vertex, c: [4][3]f32, shade: f32) {
	for k in ([6]int{0, 1, 2, 0, 2, 3}) do append(out, Cloud_Vertex{c[k], shade})
}

@(private = "file")
cloud_rebuild :: proc(s: ^Sky, g: ^Planet_Geo, base: [2]i32) {
	verts := make([dynamic]Cloud_Vertex, context.temp_allocator)
	R :: CLOUD_RADIUS
	C :: f32(CLOUD_CELL)
	// узор с запасом в клетку по краям (для боковых граней)
	W :: 2 * R + 3
	grid := make([]bool, W * W, context.temp_allocator)
	for dj in i32(0) ..< W do for di in i32(0) ..< W {
		grid[dj * W + di] = cloud_sample(s, g, base.x + di - R - 1, base.y + dj - R - 1)
	}
	cloud_at :: proc(grid: []bool, di, dj: i32) -> bool {
		return grid[(dj + R + 1) * W + di + R + 1]
	}
	for dj in i32(-R) ..= R do for di in i32(-R) ..= R {
		if !cloud_at(grid, di, dj) do continue
		x0, z0 := f32(di) * C, f32(dj) * C
		x1, z1 := x0 + C, z0 + C
		y0, y1 := f32(0), f32(CLOUD_THICK)
		cloud_face(&verts, {{x0, y1, z1}, {x1, y1, z1}, {x1, y1, z0}, {x0, y1, z0}}, 1.0)
		cloud_face(&verts, {{x0, y0, z0}, {x1, y0, z0}, {x1, y0, z1}, {x0, y0, z1}}, 0.72)
		if !cloud_at(grid, di + 1, dj) do cloud_face(&verts, {{x1, y0, z1}, {x1, y0, z0}, {x1, y1, z0}, {x1, y1, z1}}, 0.9)
		if !cloud_at(grid, di - 1, dj) do cloud_face(&verts, {{x0, y0, z0}, {x0, y0, z1}, {x0, y1, z1}, {x0, y1, z0}}, 0.9)
		if !cloud_at(grid, di, dj + 1) do cloud_face(&verts, {{x0, y0, z1}, {x1, y0, z1}, {x1, y1, z1}, {x0, y1, z1}}, 0.8)
		if !cloud_at(grid, di, dj - 1) do cloud_face(&verts, {{x1, y0, z0}, {x0, y0, z0}, {x0, y1, z0}, {x1, y1, z0}}, 0.8)
	}
	gl.BindBuffer(gl.ARRAY_BUFFER, s.cloud_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(verts) * size_of(Cloud_Vertex), raw_data(verts), gl.DYNAMIC_DRAW)
	s.cloud_verts = i32(len(verts))
	s.built_cell = base
	s.built = true
}

// Возвращает смещение облачной сетки относительно камеры.
sky_update_clouds :: proc(s: ^Sky, g: ^Planet_Geo, cam_pos: [3]f64, time: f64) -> [3]f32 {
	s.drift += s.wind * clamp(time - s.last_time, 0, 0.25)
	s.last_time = time
	off := s.phase + s.drift
	base := [2]i32{i32(math.floor((cam_pos.x - off.x) / CLOUD_CELL)), i32(math.floor((cam_pos.z - off.y) / CLOUD_CELL))}
	if !s.built || base != s.built_cell do cloud_rebuild(s, g, base)
	return {
		f32(f64(base.x) * CLOUD_CELL + off.x - cam_pos.x),
		f32(CLOUD_Y - cam_pos.y),
		f32(f64(base.y) * CLOUD_CELL + off.y - cam_pos.z),
	}
}

// Переход кадра через ребро: солнце, ветер и облачная сетка поворачиваются
// вместе с кадром — на небе ничего не меняется.
sky_rebase :: proc(s: ^Sky, m: Xform) {
	sx, sz := xform_vec(m, f64(s.sun_dir.x), f64(s.sun_dir.z))
	s.sun_dir.x, s.sun_dir.z = f32(sx), f32(sz)
	s.phase.x, s.phase.y = xform_pos(m, s.phase.x, s.phase.y)
	// фаза важна только по модулю клетки (номера клеток считаются заново)
	s.phase = {math.mod(s.phase.x, CLOUD_CELL), math.mod(s.phase.y, CLOUD_CELL)}
	s.drift.x, s.drift.y = xform_vec(m, s.drift.x, s.drift.y)
	s.wind.x, s.wind.y = xform_vec(m, s.wind.x, s.wind.y)
	s.built = false
}
