package main

// Построение мешей чанков.
// Каждая вершина — 12 байт: позиция в 1/16 блока, освещение (AO + тень неба),
// номер грани, UV в текселях и слой массива текстур.

import "core:math"
import "core:math/linalg"
import eng "engine"
import gl "vendor:OpenGL"

SHADOW_LIGHT :: 0.62 // яркость в тени (под деревьями, под водой)
AO_CASTER_LIGHT :: 0.22 // вклад непрозрачного соседа в сглаженное освещение

FLAG_ANIMATED :: 1 // слой текстуры анимируется (вода)
FACE_ID_CROSS :: 6 // растения: без направленного затенения

Chunk_Vertex :: struct {
	x, y, z:    u16, // (локальная позиция + 1 блок) * 16
	light_face: u16, // свет [0..255] | грань << 8 | флаги << 11
	u, v:       u8, // тексели 0..16
	layer:      u8,
	tint:       u8, // климат: сухость (младшие 4 бита), холод (старшие)
}

Chunk_Mesh :: struct {
	vao, vbo: u32,
	quads:    i32,
}

@(private = "file")
P :: CHUNK_SIZE + 2

// Блоки секции с бортиком в 1 блок из соседних секций (сверху и снизу тоже).
@(private = "file")
Padded :: struct {
	blocks:  [P * P * P]Block,
	light_h: [P * P]i32, // свет неба: первый y (от низа секции), куда он достаёт
	tint:    [P * P]u8, // оттенок травы и листвы по климату (сухость, холод)
}

@(private = "file")
scratch: Padded
@(private = "file")
opaque_verts: [dynamic]Chunk_Vertex
@(private = "file")
water_verts: [dynamic]Chunk_Vertex

quad_ebo: u32
@(private = "file")
quad_ebo_capacity: i32

// Углы граней (BL, BR, TR, TL при взгляде снаружи), против часовой стрелки.
@(private = "file")
FACE_CORNERS := [Face][4][3]i32 {
	.East  = {{1, 0, 1}, {1, 0, 0}, {1, 1, 0}, {1, 1, 1}},
	.West  = {{0, 0, 0}, {0, 0, 1}, {0, 1, 1}, {0, 1, 0}},
	.Up    = {{0, 1, 1}, {1, 1, 1}, {1, 1, 0}, {0, 1, 0}},
	.Down  = {{0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {0, 0, 1}},
	.South = {{0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}},
	.North = {{1, 0, 0}, {0, 0, 0}, {0, 1, 0}, {1, 1, 0}},
}

@(private = "file")
FACE_TANGENTS := [Face][2]int {
	.East  = {1, 2},
	.West  = {1, 2},
	.Up    = {0, 2},
	.Down  = {0, 2},
	.South = {0, 1},
	.North = {0, 1},
}

@(private = "file")
QUAD_UV := [4][2]u8{{0, 16}, {16, 16}, {16, 0}, {0, 0}}

@(private = "file")
pidx :: #force_inline proc "contextless" (x, y, z: i32) -> i32 {
	return ((y + 1) * P + (z + 1)) * P + (x + 1)
}

@(private = "file")
pb :: #force_inline proc "contextless" (p: ^Padded, x, y, z: i32) -> Block {
	return p.blocks[pidx(x, y, z)]
}

// Значение света клетки для сглаживания + признак "отбрасывает AO".
@(private = "file")
cell :: proc "contextless" (p: ^Padded, x, y, z: i32) -> (v: f32, caster: bool) {
	b := pb(p, x, y, z)
	info := &BLOCK_INFO[b]
	if info.opaque || info.render == .Leaves do return AO_CASTER_LIGHT, true
	if y >= p.light_h[(z + 1) * P + (x + 1)] do return 1, false
	return SHADOW_LIGHT, false
}

@(private = "file")
emit_quad :: proc(out: ^[dynamic]Chunk_Vertex, pos: [4][3]i32, uv: [4][2]u8, light: [4]f32, face_id: u16, layer: u8, flags: u16, tint: u8 = 0) {
	// разворачиваем диагональ квадрата, чтобы AO интерполировался ровно
	order := [4]int{0, 1, 2, 3}
	if light[1] + light[3] > light[0] + light[2] do order = {1, 2, 3, 0}
	for k in order {
		l := u16(clamp(light[k], 0, 1) * 255 + 0.5)
		append(out, Chunk_Vertex{
			x = u16(pos[k].x),
			y = u16(pos[k].y),
			z = u16(pos[k].z),
			light_face = l | face_id << 8 | flags << 11,
			u = uv[k].x,
			v = uv[k].y,
			layer = layer,
			tint = tint,
		})
	}
}

@(private = "file")
emit_cube_face :: proc(out: ^[dynamic]Chunk_Vertex, p: ^Padded, x, y, z: i32, face: Face, layer: u8, flags: u16, top16: i32) {
	n := FACE_DIR[face]
	f := [3]i32{x, y, z} + n
	lf, _ := cell(p, f.x, f.y, f.z)
	t := FACE_TANGENTS[face]
	pos: [4][3]i32
	uv: [4][2]u8
	light: [4]f32
	for k in 0 ..< 4 {
		corner := FACE_CORNERS[face][k]
		o1, o2: [3]i32
		o1[t[0]] = corner[t[0]] * 2 - 1
		o2[t[1]] = corner[t[1]] * 2 - 1
		s1 := f + o1
		s2 := f + o2
		cc := f + o1 + o2
		v1, c1 := cell(p, s1.x, s1.y, s1.z)
		v2, c2 := cell(p, s2.x, s2.y, s2.z)
		vc: f32 = AO_CASTER_LIGHT
		if !(c1 && c2) do vc, _ = cell(p, cc.x, cc.y, cc.z)
		light[k] = (lf + v1 + v2 + vc) * 0.25

		py := y * 16 + (corner.y == 1 ? top16 : 0)
		pos[k] = {(x + corner.x) * 16 + 16, py + 16, (z + corner.z) * 16 + 16}
		uv[k] = QUAD_UV[k]
		if corner.y == 1 && face != .Up && face != .Down do uv[k].y = u8(16 - top16)
	}
	emit_quad(out, pos, uv, light, u16(face), layer, flags, p.tint[(z + 1) * P + (x + 1)])
}

@(private = "file")
emit_cross :: proc(out: ^[dynamic]Chunk_Vertex, p: ^Padded, x, y, z: i32, layer: u8, wx, wz: i32, seed: u32) {
	l, _ := cell(p, x, y, z)
	light := [4]f32{l, l, l, l}
	// случайный сдвиг по XZ, как у травы в Minecraft
	hsh := eng.hash2(wx, wz, seed ~ 0x51A7)
	ox := i32(hsh % 7) - 3
	oz := i32((hsh >> 4) % 7) - 3
	bx := x * 16 + 16 + ox
	by := y * 16 + 16
	bz := z * 16 + 16 + oz
	diag := [2][2][2]i32{{{1, 1}, {15, 15}}, {{1, 15}, {15, 1}}}
	for d in diag {
		a := d[0]
		b := d[1]
		front := [4][3]i32{{bx + a.x, by, bz + a.y}, {bx + b.x, by, bz + b.y}, {bx + b.x, by + 16, bz + b.y}, {bx + a.x, by + 16, bz + a.y}}
		back := [4][3]i32{front[1], front[0], front[3], front[2]}
		tint := p.tint[(z + 1) * P + (x + 1)]
		emit_quad(out, front, QUAD_UV, light, FACE_ID_CROSS, layer, 0, tint)
		emit_quad(out, back, QUAD_UV, light, FACE_ID_CROSS, layer, 0, tint)
	}
}

// ---- тонкие стволы и ветви: брус сечением POST_W вдоль настоящей линии ветви
// (отрезки дерева — trees.odin), по кусочку в каждой клетке, где блок ещё есть
// (сломанный блок — дыра в ветви). Кусочки одного отрезка лежат на одной линии
// и стыкуются без швов.

@(private = "file")
thin_segs: [dynamic][2][3]f64
@(private = "file")
thin_covered: [CHUNK_VOLUME]bool

@(private = "file")
Thin_Ctx :: struct {
	out:    ^[dynamic]Chunk_Vertex,
	p:      ^Padded,
	o:      [3]i32, // угол секции (сетка грани)
	a, d:   [3]f64, // отрезок: начало и направление (до конца)
	e1, e2: [3]f64, // поперечные оси бруса (половина ширины)
	side:   u8, // слой текстуры коры
	top:    u8, // слой торца
	len16:  f64, // длина отрезка в текселях
}

// Номер грани по нормали — для затенения граней, как у кубов.
@(private = "file")
face_of :: proc(n: [3]f64) -> Face {
	ax := [3]f64{abs(n.x), abs(n.y), abs(n.z)}
	if ax.y >= ax.x && ax.y >= ax.z do return n.y > 0 ? .Up : .Down
	if ax.x >= ax.z do return n.x > 0 ? .East : .West
	return n.z > 0 ? .South : .North
}

@(private = "file")
thin_piece :: proc(ctx: ^Thin_Ctx, at: [3]i32, t0, t1: f64, cap0, cap1: bool) {
	l := at - ctx.o
	lv, _ := cell(ctx.p, l.x, l.y, l.z)
	light := [4]f32{lv, lv, lv, lv}
	tint := ctx.p.tint[(clamp(l.z, -1, CHUNK_SIZE) + 1) * P + (clamp(l.x, -1, CHUNK_SIZE) + 1)]
	o := [3]f64{f64(ctx.o.x), f64(ctx.o.y), f64(ctx.o.z)}
	p0 := ctx.a + ctx.d * t0 - o
	p1 := ctx.a + ctx.d * t1 - o
	vp :: proc(q: [3]f64) -> [3]i32 {
		return {i32(math.round(q.x * 16)) + 16, i32(math.round(q.y * 16)) + 16, i32(math.round(q.z * 16)) + 16}
	}
	ring := [4][3]f64{ctx.e1 + ctx.e2, -ctx.e1 + ctx.e2, -ctx.e1 - ctx.e2, ctx.e1 - ctx.e2}
	v0 := math.mod(t0 * ctx.len16, 16)
	v1 := v0 + (t1 - t0) * ctx.len16
	for k in 0 ..< 4 {
		r0, r1 := ring[k], ring[(k + 1) % 4]
		q := [4][3]f64{p0 + r0, p0 + r1, p1 + r1, p1 + r0}
		n := r0 + r1
		if linalg.dot(linalg.cross(q[1] - q[0], q[2] - q[0]), n) < 0 do q = {q[1], q[0], q[3], q[2]}
		uv := [4][2]u8{{POST_LO, u8(16 - v0)}, {POST_HI, u8(16 - v0)}, {POST_HI, u8(max(16 - v1, 0))}, {POST_LO, u8(max(16 - v1, 0))}}
		emit_quad(ctx.out, {vp(q[0]), vp(q[1]), vp(q[2]), vp(q[3])}, uv, light, u16(face_of(n)), ctx.side, 0, tint)
	}
	caps := [2]bool{cap0, cap1}
	for end in 0 ..< 2 {
		if !caps[end] do continue
		pc := end == 0 ? p0 : p1
		n := end == 0 ? -ctx.d : ctx.d
		q := [4][3]f64{pc + ring[0], pc + ring[1], pc + ring[2], pc + ring[3]}
		if linalg.dot(linalg.cross(q[1] - q[0], q[2] - q[0]), n) < 0 do q = {q[3], q[2], q[1], q[0]}
		uv := [4][2]u8{{POST_LO, POST_HI}, {POST_HI, POST_HI}, {POST_HI, POST_LO}, {POST_LO, POST_LO}}
		emit_quad(ctx.out, {vp(q[0]), vp(q[1]), vp(q[2]), vp(q[3])}, uv, light, u16(face_of(n)), ctx.top, 0, tint)
	}
}

@(private = "file")
emit_thin_wood :: proc(w: ^World, c: ^Chunk, p: ^Padded, out: ^[dynamic]Chunk_Vertex) {
	o := [3]i32{c.key.x * CHUNK_SIZE, c.key.y * CHUNK_SIZE, c.key.z * CHUNK_SIZE}
	thin_covered = {}
	clear(&thin_segs)
	if col := world_column(w, {c.key.face, c.key.x, c.key.z}); col != nil {
		for t in col.trees[:col.tree_n] {
			if tree_touches(t, o, o + CHUNK_SIZE) do tree_thin_segments(t, &thin_segs)
		}
	}
	hw := f64(POST_W) / 32 // половина ширины, блоков
	for sg in thin_segs {
		lo := [3]f64{min(sg[0].x, sg[1].x), min(sg[0].y, sg[1].y), min(sg[0].z, sg[1].z)}
		hi := [3]f64{max(sg[0].x, sg[1].x), max(sg[0].y, sg[1].y), max(sg[0].z, sg[1].z)}
		if hi.x < f64(o.x) || hi.y < f64(o.y) || hi.z < f64(o.z) || lo.x >= f64(o.x + CHUNK_SIZE) || lo.y >= f64(o.y + CHUNK_SIZE) || lo.z >= f64(o.z + CHUNK_SIZE) do continue
		d := sg[1] - sg[0]
		L := linalg.length(d)
		if L < 1e-6 do continue
		u := d / L
		h := abs(u.y) < 0.95 ? [3]f64{0, 1, 0} : [3]f64{1, 0, 0}
		ctx := Thin_Ctx{out = out, p = p, o = o, a = sg[0], d = d, len16 = L * 16}
		ctx.e1 = linalg.normalize(linalg.cross(u, h)) * hw
		ctx.e2 = linalg.normalize(linalg.cross(u, ctx.e1)) * hw
		seg_walk(sg[0], sg[1], &ctx, proc(data: rawptr, cell: [3]i32, t0, t1: f64) {
			ctx := (^Thin_Ctx)(data)
			l := cell - ctx.o
			if l.x < 0 || l.y < 0 || l.z < 0 || l.x >= CHUNK_SIZE || l.y >= CHUNK_SIZE || l.z >= CHUNK_SIZE do return
			b := pb(ctx.p, l.x, l.y, l.z)
			info := &BLOCK_INFO[b]
			if info.render != .Post do return // блок сломан — кусочка нет
			thin_covered[block_index(l.x, l.y, l.z)] = true
			ctx.side, ctx.top = u8(info.tex[.East]), u8(info.tex[.Up])
			thin_piece(ctx, cell, t0, t1, t0 <= 0, t1 >= 1)
		})
	}
	// тонкая древесина без своей ветви (поставлена вручную) — столбик
	for y in i32(0) ..< CHUNK_SIZE do for z in i32(0) ..< CHUNK_SIZE do for x in i32(0) ..< CHUNK_SIZE {
		b := pb(p, x, y, z)
		if BLOCK_INFO[b].render != .Post || thin_covered[block_index(x, y, z)] do continue
		info := &BLOCK_INFO[b]
		cell := o + {x, y, z}
		a := [3]f64{f64(cell.x) + 0.5, f64(cell.y), f64(cell.z) + 0.5}
		ctx := Thin_Ctx{out = out, p = p, o = o, a = a, d = {0, 1, 0}, len16 = 16, side = u8(info.tex[.East]), top = u8(info.tex[.Up])}
		ctx.e1 = {hw, 0, 0}
		ctx.e2 = {0, 0, hw}
		thin_piece(&ctx, cell, 0, 1, !is_woody(pb(p, x, y - 1, z)), !is_woody(pb(p, x, y + 1, z)))
	}
}

@(private = "file")
fill_padded :: proc(w: ^World, c: ^Chunk, p: ^Padded) {
	// колонки бортика берём через рёбра граней (сетка соседа может быть повёрнута)
	x0 := c.key.x * CHUNK_SIZE
	y0 := c.key.y * CHUNK_SIZE
	z0 := c.key.z * CHUNK_SIZE
	for pz in i32(-1) ..= CHUNK_SIZE do for px in i32(-1) ..= CHUNK_SIZE {
		face := c.key.face
		gx, gz := x0 + px, z0 + pz
		ok := true
		if px < 0 || pz < 0 || px >= CHUNK_SIZE || pz >= CHUNK_SIZE {
			face, gx, gz, ok = geo_resolve(&w.geo, c.key.face, gx, gz)
		}
		col: ^Column
		if ok do col = world_column(w, column_key_of(face, gx, gz))
		if col == nil {
			// пустота у вершины куба: со стороны столпа — как камень
			fill: Block = ok ? .Air : .Monolith
			for y in i32(-1) ..= CHUNK_SIZE do p.blocks[pidx(px, y, pz)] = fill
			p.light_h[(pz + 1) * P + (px + 1)] = min(i32)
			p.tint[(pz + 1) * P + (px + 1)] = 0
			continue
		}
		ci := column_index(gx, gz)
		lx, lz := eng.floor_mod(gx, CHUNK_SIZE), eng.floor_mod(gz, CHUNK_SIZE)
		// по секциям: та же, ниже, выше; непостроенные — ответ по колонке
		same := px >= 0 && pz >= 0 && px < CHUNK_SIZE && pz < CHUNK_SIZE
		mid := same ? c : world_chunk(w, chunk_key_of(face, gx, y0, gz))
		below := world_chunk(w, chunk_key_of(face, gx, y0 - 1, gz))
		above := world_chunk(w, chunk_key_of(face, gx, y0 + CHUNK_SIZE, gz))
		for y in i32(-1) ..= CHUNK_SIZE {
			wy := y0 + y
			n := y < 0 ? below : y >= CHUNK_SIZE ? above : mid
			if n != nil {
				p.blocks[pidx(px, y, pz)] = chunk_block(n, block_index(lx, eng.floor_mod(wy, CHUNK_SIZE), lz))
			} else {
				p.blocks[pidx(px, y, pz)] = column_guess(col, ci, wy)
			}
		}
		p.light_h[(pz + 1) * P + (px + 1)] = (w.bare ? col.sky_bare[ci] : col.sky[ci]) - y0
		p.tint[(pz + 1) * P + (px + 1)] = col.tint[ci]
	}
}

chunk_build_mesh :: proc(w: ^World, c: ^Chunk) {
	clear(&opaque_verts)
	clear(&water_verts)
	if c.blocks == nil && c.fill == .Air {
		// пустой воздух — сетки нет
		chunk_mesh_upload(&c.opaque_mesh, opaque_verts[:])
		chunk_mesh_upload(&c.water_mesh, water_verts[:])
		c.meshed = true
		c.stale = false
		return
	}
	p := &scratch
	fill_padded(w, c, p)

	x0 := c.key.x * CHUNK_SIZE
	y0 := c.key.y * CHUNK_SIZE
	z0 := c.key.z * CHUNK_SIZE
	has_thin := false
	for y in i32(0) ..< CHUNK_SIZE do for z in i32(0) ..< CHUNK_SIZE do for x in i32(0) ..< CHUNK_SIZE {
		b := p.blocks[pidx(x, y, z)]
		if b == .Air do continue
		info := &BLOCK_INFO[b]
		switch info.render {
		case .None:
		case .Cube, .Leaves:
			// у листвы — свой номер блока (0…15): листопад идёт блоками
			flags: u16 = info.render == .Leaves ? u16(eng.hash3(x0 + x, y0 + y, z0 + z, w.seed ~ 0x1EAF) & 15) << 1 : 0
			for face in Face {
				d := FACE_DIR[face]
				nb := pb(p, x + d.x, y + d.y, z + d.z)
				if BLOCK_INFO[nb].opaque do continue
				// внутри вечнозелёной кроны грани между листьями не видны (голых веток зимой нет)
				if nb == b && evergreen_leaves(b) do continue
				emit_cube_face(&opaque_verts, p, x, y, z, face, u8(info.tex[face]), flags, 16)
			}
		case .Cross:
			emit_cross(&opaque_verts, p, x, y, z, u8(info.tex[.Up]), x0 + x, z0 + z, w.seed)
		case .Post:
			has_thin = true // рисуется по линиям ветвей, ниже
		case .Liquid:
			top16: i32 = pb(p, x, y + 1, z) == .Water ? 16 : 14
			for face in Face {
				d := FACE_DIR[face]
				nb := pb(p, x + d.x, y + d.y, z + d.z)
				if nb == .Water || BLOCK_INFO[nb].opaque do continue
				emit_cube_face(&water_verts, p, x, y, z, face, u8(info.tex[face]), FLAG_ANIMATED, top16)
			}
		}
	}
	if has_thin do emit_thin_wood(w, c, p, &opaque_verts)

	chunk_mesh_upload(&c.opaque_mesh, opaque_verts[:])
	chunk_mesh_upload(&c.water_mesh, water_verts[:])
	c.meshed = true
	c.stale = false
}

// Общий индексный буфер для квадов: 0,1,2, 0,2,3 со сдвигом 4.
@(private = "file")
ensure_quad_indices :: proc(quads: i32) {
	if quads <= quad_ebo_capacity do return
	cap := max(quads, quad_ebo_capacity * 2, 16384)
	indices := make([]u32, cap * 6, context.temp_allocator)
	for q in 0 ..< cap {
		b := u32(q) * 4
		i := q * 6
		indices[i + 0] = b
		indices[i + 1] = b + 1
		indices[i + 2] = b + 2
		indices[i + 3] = b
		indices[i + 4] = b + 2
		indices[i + 5] = b + 3
	}
	gl.BindVertexArray(0)
	if quad_ebo == 0 do gl.GenBuffers(1, &quad_ebo)
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, quad_ebo)
	gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, len(indices) * size_of(u32), raw_data(indices), gl.STATIC_DRAW)
	quad_ebo_capacity = cap
}

chunk_mesh_upload :: proc(m: ^Chunk_Mesh, verts: []Chunk_Vertex) {
	m.quads = i32(len(verts) / 4)
	if m.quads == 0 do return
	ensure_quad_indices(m.quads)
	if m.vao == 0 {
		gl.GenVertexArrays(1, &m.vao)
		gl.GenBuffers(1, &m.vbo)
		gl.BindVertexArray(m.vao)
		gl.BindBuffer(gl.ARRAY_BUFFER, m.vbo)
		gl.EnableVertexAttribArray(0)
		gl.VertexAttribIPointer(0, 4, gl.UNSIGNED_SHORT, size_of(Chunk_Vertex), 0)
		gl.EnableVertexAttribArray(1)
		gl.VertexAttribIPointer(1, 4, gl.UNSIGNED_BYTE, size_of(Chunk_Vertex), 8)
		gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, quad_ebo)
		gl.BindVertexArray(0)
	}
	gl.BindBuffer(gl.ARRAY_BUFFER, m.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(verts) * size_of(Chunk_Vertex), raw_data(verts), gl.STATIC_DRAW)
}

chunk_mesh_draw :: proc(m: ^Chunk_Mesh) {
	if m.quads == 0 do return
	gl.BindVertexArray(m.vao)
	gl.DrawElements(gl.TRIANGLES, m.quads * 6, gl.UNSIGNED_INT, nil)
}

chunk_mesh_free :: proc(m: ^Chunk_Mesh) {
	if m.vao != 0 do gl.DeleteVertexArrays(1, &m.vao)
	if m.vbo != 0 do gl.DeleteBuffers(1, &m.vbo)
	m^ = {}
}
