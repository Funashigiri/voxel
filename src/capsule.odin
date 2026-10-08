package main

// Одноместная спускаемая капсула и её парашют — "кубические" модели в стиле
// Minecraft из коробок, разбитых на клетки 1x1 блок (16 пикселей на блок).

import "core:math"
import "core:math/linalg"
import eng "engine"
import gl "vendor:OpenGL"

@(private = "file")
Tile :: enum {
	Hull,
	Hull_Scorched,
	Shield,
	Window,
	Hatch,
	Interior,
	Chute,
	Line,
}

@(private = "file")
TILE_COUNT :: len(Tile)

POD_HATCH_HINGE :: [3]f32{-0.45, 0, 0.79} // вертикальная петля люка
POD_HATCH_OPEN :: 1.9 // радиан
POD_TOP :: f32(2.8) // сюда крепятся стропы парашюта
POD_CENTER :: [3]f32{0, 1.3, 0}
CHUTE_HEIGHT :: f32(5.5) // от точки крепления до купола

Capsule_Model :: struct {
	vao, vbo: u32,
	body:     [2]i32, // first, count
	hatch:    [2]i32,
	cap:      [2]i32, // крышка отсека парашюта
	chute:    [2]i32, // купол и стропы (начало координат — точка крепления)
	tex:      u32,
}

// Прямоугольник origin + du*[0..u_len] + dv*[0..v_len], разбитый на клетки 1x1.
// cross(du, dv) должен смотреть наружу (в сторону нормали).
@(private = "file")
add_rect :: proc(out: ^[dynamic]Entity_Vertex, origin, du, dv: [3]f32, u_len, v_len: f32, n: [3]f32, tile: Tile, scorch: f32 = 0, window_cell: int = -1) {
	cells_u := int(math.ceil(u_len - 0.001))
	cells_v := int(math.ceil(v_len - 0.001))
	for j in 0 ..< cells_v do for i in 0 ..< cells_u {
		u0, v0 := f32(i), f32(j)
		u1, v1 := min(u_len, u0 + 1), min(v_len, v0 + 1)
		t := tile
		if tile == .Hull && scorch > 0 {
			hp := origin + du * (u0 + 0.5) + dv * (v0 + 0.5)
			chance := scorch * (1.3 - hp.y / 2.5) // ниже — сильнее обгорел
			if eng.hash3f(i32(hp.x * 7), i32(hp.y * 7), i32(hp.z * 7), 77) < chance do t = .Hull_Scorched
		}
		if i == window_cell && j == cells_v - 1 do t = .Window
		p := [4][3]f32{origin + du * u0 + dv * v0, origin + du * u1 + dv * v0, origin + du * u1 + dv * v1, origin + du * u0 + dv * v1}
		tu := f32(int(t))
		uv := [4][2]f32 {
			{(tu + 0) / TILE_COUNT, 1},
			{(tu + (u1 - u0)) / TILE_COUNT, 1},
			{(tu + (u1 - u0)) / TILE_COUNT, 1 - (v1 - v0)},
			{(tu + 0) / TILE_COUNT, 1 - (v1 - v0)},
		}
		for k in ([6]int{0, 1, 2, 0, 2, 3}) do append(out, Entity_Vertex{pos = p[k], uv = uv[k], normal = n})
	}
}

@(private = "file")
add_box :: proc(out: ^[dynamic]Entity_Vertex, mn, mx: [3]f32, tile: Tile, scorch: f32 = 0, inward := false, skip_front := false, window_front := -1) {
	size := mx - mn
	Face :: struct {
		origin, du, dv, n: [3]f32,
		ul, vl:            f32,
	}
	faces := [6]Face {
		{{mn.x, mn.y, mx.z}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, size.x, size.y}, // +Z (перед)
		{{mx.x, mn.y, mn.z}, {-1, 0, 0}, {0, 1, 0}, {0, 0, -1}, size.x, size.y}, // -Z
		{{mx.x, mn.y, mx.z}, {0, 0, -1}, {0, 1, 0}, {1, 0, 0}, size.z, size.y}, // +X
		{{mn.x, mn.y, mn.z}, {0, 0, 1}, {0, 1, 0}, {-1, 0, 0}, size.z, size.y}, // -X
		{{mn.x, mx.y, mx.z}, {1, 0, 0}, {0, 0, -1}, {0, 1, 0}, size.x, size.z}, // +Y
		{{mn.x, mn.y, mn.z}, {1, 0, 0}, {0, 0, 1}, {0, -1, 0}, size.x, size.z}, // -Y
	}
	for f, i in faces {
		if i == 0 && skip_front do continue
		if inward {
			add_rect(out, f.origin, f.dv, f.du, f.vl, f.ul, -f.n, tile, scorch)
		} else {
			add_rect(out, f.origin, f.du, f.dv, f.ul, f.vl, f.n, tile, scorch, i == 0 ? window_front : -1)
		}
	}
}

// Тонкая стропа от a до b: две скрещённые полоски.
@(private = "file")
add_line :: proc(out: ^[dynamic]Entity_Vertex, a, b: [3]f32) {
	d := b - a
	side := linalg.normalize(linalg.cross(d, [3]f32{0, 1, 0}) + {0.001, 0, 0}) * 0.03
	side2 := linalg.normalize(linalg.cross(d, side)) * 0.03
	tu := f32(int(Tile.Line))
	for s in ([2][3]f32{side, side2}) {
		p := [4][3]f32{a - s, a + s, b + s, b - s}
		uv := [4][2]f32{{tu / TILE_COUNT, 1}, {(tu + 0.1) / TILE_COUNT, 1}, {(tu + 0.1) / TILE_COUNT, 0}, {tu / TILE_COUNT, 0}}
		n := linalg.normalize(linalg.cross(d, s))
		for k in ([6]int{0, 1, 2, 0, 2, 3}) do append(out, Entity_Vertex{pos = p[k], uv = uv[k], normal = n})
		for k in ([6]int{0, 2, 1, 0, 3, 2}) do append(out, Entity_Vertex{pos = p[k], uv = uv[k], normal = -n})
	}
}

@(private = "file")
capsule_texture :: proc() -> u32 {
	W :: TILE_COUNT * 16
	pixels := make([]u8, W * 16 * 4, context.temp_allocator)
	put :: proc(px: []u8, tile: Tile, x, y: int, c: [3]u8) {
		o := (y * W + int(tile) * 16 + x) * 4
		px[o], px[o + 1], px[o + 2], px[o + 3] = c.r, c.g, c.b, 255
	}
	n :: proc(x, y: int, s: u32) -> f32 {return eng.hash2f(i32(x), i32(y), s)}
	shade :: proc(c: [3]u8, f: f32) -> [3]u8 {
		return {u8(clamp(f32(c.r) * f, 0, 255)), u8(clamp(f32(c.g) * f, 0, 255)), u8(clamp(f32(c.b) * f, 0, 255))}
	}
	hull := [3]u8{196, 200, 204}
	for y in 0 ..< 16 do for x in 0 ..< 16 {
		// корпус: панели со швами и заклёпками, полосы копоти
		c := shade(hull, 0.93 + n(x, y, 1) * 0.12)
		if x == 0 || y == 0 || x == 8 do c = shade(hull, 0.72)
		if (x == 2 || x == 13) && (y == 2 || y == 13) do c = shade(hull, 0.55)
		if n(x, 0, 2) < 0.18 do c = shade(c, 0.8)
		put(pixels, .Hull, x, y, c)

		// обгоревший корпус
		sc := shade(c, 0.45 + n(x, y, 3) * 0.2)
		sc = {u8(f32(sc.r) * 1.05), sc.g, u8(f32(sc.b) * 0.85)}
		put(pixels, .Hull_Scorched, x, y, sc)

		// теплозащитный экран: обугленные плитки
		s := shade([3]u8{58, 44, 34}, 0.8 + n(x, y, 4) * 0.4)
		if x % 4 == 0 || (y + (x / 4) * 2) % 4 == 0 do s = {28, 22, 18}
		put(pixels, .Shield, x, y, s)

		// иллюминатор: рамка и тёмное стекло с бликом
		wc := [3]u8{24, 38, 66}
		if x + y == 9 || x + y == 10 do wc = {86, 116, 156}
		if x < 2 || y < 2 || x > 13 || y > 13 do wc = shade(hull, 0.6)
		put(pixels, .Window, x, y, wc)

		// люк: окантовка, ручка, предупреждающие полосы
		hc := shade(hull, 0.9 + n(x, y, 5) * 0.1)
		if x == 0 || x == 15 || y == 0 || y == 15 do hc = {84, 86, 90}
		if x >= 11 && x <= 12 && y >= 6 && y <= 9 do hc = {54, 54, 58}
		if y >= 12 && y <= 14 && x > 0 && x < 15 do hc = ((x + y) / 2) % 2 == 0 ? [3]u8{222, 182, 36} : [3]u8{30, 30, 30}
		put(pixels, .Hatch, x, y, hc)

		// салон: тёмные панели и огоньки приборов
		ic := shade([3]u8{56, 60, 66}, 0.85 + n(x, y, 6) * 0.2)
		if y % 5 == 0 do ic = {40, 42, 46}
		if n(x, y, 7) < 0.03 do ic = n(x, y, 8) < 0.5 ? [3]u8{90, 230, 120} : [3]u8{240, 70, 60}
		put(pixels, .Interior, x, y, ic)

		// купол: оранжево-белые сектора
		ch := (x / 4) % 2 == 0 ? [3]u8{232, 108, 34} : [3]u8{236, 232, 224}
		put(pixels, .Chute, x, y, shade(ch, 0.92 + n(x, y, 9) * 0.1))

		put(pixels, .Line, x, y, {214, 212, 206})
	}
	return eng.texture_2d_create(W, 16, pixels)
}

capsule_model_create :: proc() -> (m: Capsule_Model) {
	verts := make([dynamic]Entity_Vertex, context.temp_allocator)
	// корпус
	add_box(&verts, {-0.85, 0, -0.85}, {0.85, 0.3, 0.85}, .Shield)
	add_box(&verts, {-0.75, 0.3, -0.75}, {0.75, 2.25, 0.75}, .Hull, scorch = 0.6, skip_front = true)
	// перед — с проёмом под люк
	FZ :: f32(0.75)
	add_rect(&verts, {-0.75, 0.3, FZ}, {1, 0, 0}, {0, 1, 0}, 0.3, 1.95, {0, 0, 1}, .Hull, 0.6)
	add_rect(&verts, {0.45, 0.3, FZ}, {1, 0, 0}, {0, 1, 0}, 0.3, 1.95, {0, 0, 1}, .Hull, 0.6)
	add_rect(&verts, {-0.45, 0.3, FZ}, {1, 0, 0}, {0, 1, 0}, 0.9, 0.05, {0, 0, 1}, .Hull)
	add_rect(&verts, {-0.45, 2.15, FZ}, {1, 0, 0}, {0, 1, 0}, 0.9, 0.1, {0, 0, 1}, .Hull)
	add_box(&verts, {-0.5, 2.25, -0.5}, {0.5, 2.65, 0.5}, .Hull, scorch = 0.3, window_front = 0)
	// салон (видно через открытый люк)
	add_box(&verts, {-0.7, 0.3, -0.7}, {0.7, 2.2, 0.74}, .Interior, inward = true)
	m.body = {0, i32(len(verts))}

	first := i32(len(verts))
	add_box(&verts, {-0.45, 0.35, 0.73}, {0.45, 2.15, 0.79}, .Hatch)
	m.hatch = {first, i32(len(verts)) - first}

	first = i32(len(verts))
	add_box(&verts, {-0.32, 2.65, -0.32}, {0.32, POD_TOP, 0.32}, .Hull)
	m.cap = {first, i32(len(verts)) - first}

	// парашют: купол из трёх ярусов и четыре стропы к точке крепления (0,0,0)
	first = i32(len(verts))
	H :: CHUTE_HEIGHT
	add_box(&verts, {-2.4, H, -2.4}, {2.4, H + 0.5, 2.4}, .Chute)
	add_box(&verts, {-1.8, H + 0.5, -1.8}, {1.8, H + 0.9, 1.8}, .Chute)
	add_box(&verts, {-1.0, H + 0.9, -1.0}, {1.0, H + 1.15, 1.0}, .Chute)
	for c in ([4][2]f32{{-2.2, -2.2}, {2.2, -2.2}, {2.2, 2.2}, {-2.2, 2.2}}) {
		add_line(&verts, {0, 0, 0}, {c.x, H, c.y})
	}
	m.chute = {first, i32(len(verts)) - first}

	gl.GenVertexArrays(1, &m.vao)
	gl.GenBuffers(1, &m.vbo)
	gl.BindVertexArray(m.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, m.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(verts) * size_of(Entity_Vertex), raw_data(verts), gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, size_of(Entity_Vertex), offset_of(Entity_Vertex, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, size_of(Entity_Vertex), offset_of(Entity_Vertex, uv))
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribPointer(2, 3, gl.FLOAT, false, size_of(Entity_Vertex), offset_of(Entity_Vertex, normal))
	gl.BindVertexArray(0)
	m.tex = capsule_texture()
	return
}

@(private = "file")
draw_range :: proc(sh: ^Entity_Shader, cam: ^Camera, model: eng.Mat4, r: [2]i32) {
	eng.set_mat4(sh.u_model, model)
	eng.set_mat4(sh.u_mvp, cam.view_proj * model)
	gl.DrawArrays(gl.TRIANGLES, r[0], r[1])
}

// Матрица капсулы: позиция низа, поворот люка, наклон.
capsule_matrix :: proc(cam: ^Camera, pos: [3]f64, yaw, tilt_x, tilt_z: f32) -> eng.Mat4 {
	rel := [3]f32{f32(pos.x - cam.pos.x), f32(pos.y - cam.pos.y), f32(pos.z - cam.pos.z)}
	return linalg.matrix4_translate_f32(rel) *
		linalg.matrix4_rotate_f32(-yaw, {0, 1, 0}) *
		linalg.matrix4_rotate_f32(tilt_x, {1, 0, 0}) *
		linalg.matrix4_rotate_f32(tilt_z, {0, 0, 1})
}

capsule_draw :: proc(m: ^Capsule_Model, sh: ^Entity_Shader, cam: ^Camera, root: eng.Mat4, hatch_angle: f32, with_cap: bool) {
	gl.BindVertexArray(m.vao)
	gl.BindTexture(gl.TEXTURE_2D, m.tex)
	draw_range(sh, cam, root, m.body)
	hatch :=
		root *
		linalg.matrix4_translate_f32(POD_HATCH_HINGE) *
		linalg.matrix4_rotate_f32(-hatch_angle, {0, 1, 0}) *
		linalg.matrix4_translate_f32(-POD_HATCH_HINGE)
	draw_range(sh, cam, hatch, m.hatch)
	if with_cap do draw_range(sh, cam, root, m.cap)
}

// Парашют: model — матрица точки крепления строп.
capsule_draw_chute :: proc(m: ^Capsule_Model, sh: ^Entity_Shader, cam: ^Camera, model: eng.Mat4) {
	gl.BindVertexArray(m.vao)
	gl.BindTexture(gl.TEXTURE_2D, m.tex)
	draw_range(sh, cam, model, m.chute)
}
