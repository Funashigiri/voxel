package main

// Небо (градиент + квадратное солнце) и объёмные "кубические" облака,
// медленно плывущие над миром, как в Minecraft (Fancy clouds).

import "core:math"
import eng "engine"
import gl "vendor:OpenGL"

SKY_TOP :: [3]f32{0.47, 0.65, 1.0}
SKY_HORIZON :: [3]f32{0.74, 0.84, 1.0}

CLOUD_N :: 256 // размер узора облаков (клеток), повторяется
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
	pattern:     [CLOUD_N * CLOUD_N]bool,
	built_cell:  [2]i32,
	built:       bool,
}

sky_init :: proc(s: ^Sky, seed: u32) {
	// солнце в утренней части неба (на востоке, +X), путь — в плоскости XY
	elev := math.to_radians(f32(50))
	s.sun_dir = {math.cos(elev), math.sin(elev), 0}

	gl.GenVertexArrays(1, &s.empty_vao)

	for j in 0 ..< CLOUD_N do for i in 0 ..< CLOUD_N {
		x, y := f32(i), f32(j)
		v := 0.5 * eng.tile_value_noise(x, y, 16, CLOUD_N / 16, seed + 1) +
			0.3 * eng.tile_value_noise(x, y, 8, CLOUD_N / 8, seed + 2) +
			0.2 * eng.tile_value_noise(x, y, 4, CLOUD_N / 4, seed + 3)
		s.pattern[j * CLOUD_N + i] = v > 0.57
	}

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

@(private = "file")
cloud_at :: proc(s: ^Sky, i, j: i32) -> bool {
	return s.pattern[eng.floor_mod(j, CLOUD_N) * CLOUD_N + eng.floor_mod(i, CLOUD_N)]
}

@(private = "file")
cloud_face :: proc(out: ^[dynamic]Cloud_Vertex, c: [4][3]f32, shade: f32) {
	for k in ([6]int{0, 1, 2, 0, 2, 3}) do append(out, Cloud_Vertex{c[k], shade})
}

@(private = "file")
cloud_rebuild :: proc(s: ^Sky, base: [2]i32) {
	verts := make([dynamic]Cloud_Vertex, context.temp_allocator)
	R :: CLOUD_RADIUS
	C :: f32(CLOUD_CELL)
	for dj in i32(-R) ..= R do for di in i32(-R) ..= R {
		i := base.x + di
		j := base.y + dj
		if !cloud_at(s, i, j) do continue
		x0, z0 := f32(di) * C, f32(dj) * C
		x1, z1 := x0 + C, z0 + C
		y0, y1 := f32(0), f32(CLOUD_THICK)
		cloud_face(&verts, {{x0, y1, z1}, {x1, y1, z1}, {x1, y1, z0}, {x0, y1, z0}}, 1.0)
		cloud_face(&verts, {{x0, y0, z0}, {x1, y0, z0}, {x1, y0, z1}, {x0, y0, z1}}, 0.72)
		if !cloud_at(s, i + 1, j) do cloud_face(&verts, {{x1, y0, z1}, {x1, y0, z0}, {x1, y1, z0}, {x1, y1, z1}}, 0.9)
		if !cloud_at(s, i - 1, j) do cloud_face(&verts, {{x0, y0, z0}, {x0, y0, z1}, {x0, y1, z1}, {x0, y1, z0}}, 0.9)
		if !cloud_at(s, i, j + 1) do cloud_face(&verts, {{x0, y0, z1}, {x1, y0, z1}, {x1, y1, z1}, {x0, y1, z1}}, 0.8)
		if !cloud_at(s, i, j - 1) do cloud_face(&verts, {{x1, y0, z0}, {x0, y0, z0}, {x0, y1, z0}, {x1, y1, z0}}, 0.8)
	}
	gl.BindBuffer(gl.ARRAY_BUFFER, s.cloud_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(verts) * size_of(Cloud_Vertex), raw_data(verts), gl.DYNAMIC_DRAW)
	s.cloud_verts = i32(len(verts))
	s.built_cell = base
	s.built = true
}

// Возвращает смещение облачной сетки относительно камеры.
sky_update_clouds :: proc(s: ^Sky, cam_pos: [3]f64, time: f64) -> [3]f32 {
	drift := time * CLOUD_SPEED
	base := [2]i32{i32(math.floor((cam_pos.x - drift) / CLOUD_CELL)), i32(math.floor(cam_pos.z / CLOUD_CELL))}
	if !s.built || base != s.built_cell do cloud_rebuild(s, base)
	return {
		f32(f64(base.x) * CLOUD_CELL + drift - cam_pos.x),
		f32(CLOUD_Y - cam_pos.y),
		f32(f64(base.y) * CLOUD_CELL - cam_pos.z),
	}
}
