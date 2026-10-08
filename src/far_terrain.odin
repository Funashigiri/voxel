package main

// Дальний рельеф — до настоящего горизонта.
//
// Вблизи мир из блоков (чанки), дальше — упрощённая поверхность, тем грубее,
// чем дальше. На каждой грани куба-планеты — дерево тайлов (квадродерево):
// тайл — сетка FAR_K×FAR_K клеток, его четыре потомка — та же сетка вдвое
// мельче. Высоты и цвета — из того же генератора, что и блоки (worldgen.odin),
// только без деталей мельче клетки: вдали — тот же рельеф, по которому потом
// пройдёшь. Лес — цвет и высота крон, вода — гладь с отражением неба.
//
// Тайлы строятся на настоящем шаре (кривизна, горизонт) в фоновых потоках и
// рисуются отдельным проходом со своей логарифмической глубиной — от метров
// до сотен километров. Где уже есть чанки, дальний рельеф не рисуется (маска
// чанков), блоки рисуются поверх после очистки глубины.

import "core:fmt"
import "core:math"
import "core:slice"
import "core:sync"
import "core:thread"
import eng "engine"
import gl "vendor:OpenGL"

FAR_K :: 32 // клеток на ребро тайла
FAR_N :: FAR_K + 1 // вершин на ребро
FAR_G :: FAR_K + 3 // с бортиком в клетку (нормали, уклон)
FAR_VERTS :: FAR_N * FAR_N + 4 * FAR_N // сетка + «юбки» по краям (закрывают щели между уровнями)
FAR_INDICES :: FAR_K * FAR_K * 6 + 4 * FAR_K * 6
FAR_SPLIT :: 2.6 // дальше FAR_SPLIT своих размеров тайл не делится никогда
FAR_NEAR_SPLIT :: 1.0 // ближе — делится всегда (подробности у границы с блоками)
FAR_PIXEL_ERR :: 0.0009 // между ними — если его упрощение заметно: ошибка больше ~1 пикселя (рад)
FAR_MIN_TILE :: 48.0 // самый мелкий тайл, м (клетка 1,5 м)
FAR_MAX_TILES :: 1500 // тайлов в видеопамяти
FAR_WORKERS :: 3
FAR_UPLOAD_BUDGET :: 0.003 // секунд на загрузку тайлов в видеокарту за кадр
FAR_VIEW_LIMIT :: 700_000.0 // предел дальности, м (с вершин видно за сотни км)
FAR_LOG_FAR :: f64(1e7) // дальняя граница логарифмической глубины, м
MASK_R :: VIEW_RADIUS + 4 // маска чанков: столько чанков в каждую сторону от камеры
MASK_N :: 2 * MASK_R + 1

Tile_Key :: struct {
	face:  Cube_Face,
	level: u8,
	x, z:  i32,
}

Far_Vertex :: struct {
	off:    [3]f32, // от начала тайла, оси планеты, м
	normal: [4]i8, // нормаль в осях планеты; w — глубина воды, м (для дна)
	color:  [4]u8, // цвет поверхности; a = 255 — вода
}

FAR_FLOOR_DIST :: 8000.0 // ближе — у воды рисуется и дно (видно сквозь ближнюю воду)

Far_Tile :: struct {
	key:       Tile_Key,
	origin:    [3]f64, // центр тайла на уровне моря, оси планеты
	radius:    f64, // ограничивающая сфера вокруг origin, м
	size:      f64, // сторона тайла, м
	// фоновый поток (под mutex)
	priority:  f64, // меньше — строить раньше
	wanted:    u64, // кадр, когда тайл был нужен в последний раз
	dropped:   bool, // устарел, пока ждал очереди
	verts:     []Far_Vertex,
	bound:     f64, // настоящий радиус с высотами
	top:       f64, // самая высокая точка тайла над уровнем моря, м
	bottom:    f64, // самая низкая (с дном под водой)
	err:       f64, // насколько тайл грубее своих потомков (высоты и цвет), м
	has_water: bool,
	// главный поток
	h_top:     f64, // верх тайла для отсечения за горизонтом (пока не построен — с запасом)
	h_lo:      f64, // низ тайла (дно под водой)
	in_flight: bool, // в очереди, строится или ждёт загрузки в видеокарту
	ready:     bool, // загружен в видеокарту
	used:      u64, // кадр последнего использования
	want:      f64, // срочность этого кадра (в priority — под замком)
	vao, vbo:  u32,
}

// Цвета поверхностей — средние цвета текстур блоков (так вдали мир того же цвета, что вблизи).
Far_Palette :: struct {
	grass, tall_grass, sand, stone, dirt, gravel, oak, birch, water, sandstone, limestone, granite: [3]f32,
}

// Для фоновых потоков — только чтение.
@(private = "file")
Far_Shared :: struct {
	seed:    u32,
	geo:     Planet_Geo,
	palette: Far_Palette,
}

Far_Terrain :: struct {
	shared:     Far_Shared,
	tiles:      map[Tile_Key]^Far_Tile,
	// очередь фоновым потокам и готовые тайлы — под mutex
	mutex:      sync.Mutex,
	cond:       sync.Cond,
	queue:      [dynamic]^Far_Tile,
	done:       [dynamic]^Far_Tile,
	quit:       bool,
	now:        u64, // номер кадра для фоновых потоков
	frame:      u64, // главный поток
	workers:    [FAR_WORKERS]^thread.Thread,
	uploads:    [dynamic]^Far_Tile, // построены, ждут видеокарты (главный поток)
	// отрисовка
	prog:       u32,
	u:          struct {
		view_proj, jinv, jt, rel_o, logk, mask, mask_org, side_shade, floor: i32,
	},
	ebo:        u32,
	mask_tex:   u32,
	mask:       [MASK_N * MASK_N]u8,
	mask_org:   [3]f32,
	draw:       [dynamic]^Far_Tile,
	reqs:       [dynamic]^Far_Tile,
	max_dist:   f64,
	// для F3 и автоснимков
	drawn:      int,
	pending:    int,
	horizon:    f64, // до горизонта (по уровню моря), м
	view_dist:  f64, // дальше всего нарисованный тайл, м
	ready_all:  bool, // всё нужное построено и загружено
}

// ---------------------------------------------------------------- запуск

far_init :: proc(ft: ^Far_Terrain, geo: Planet_Geo, seed: u32) -> bool {
	ft.shared = {seed = seed, geo = geo, palette = far_palette()}
	ft.max_dist = FAR_VIEW_LIMIT

	p := eng.shader_create("far", FAR_VS, FAR_FS) or_return
	loc :: eng.uniform_loc
	ft.prog = p
	ft.u = {
		view_proj  = loc(p, "u_view_proj"),
		jinv       = loc(p, "u_jinv"),
		jt         = loc(p, "u_jt"),
		rel_o      = loc(p, "u_rel_o"),
		logk       = loc(p, "u_logk"),
		mask       = loc(p, "u_mask"),
		mask_org   = loc(p, "u_mask_org"),
		side_shade = loc(p, "u_side_shade"),
		floor      = loc(p, "u_floor"),
	}

	indices := far_indices()
	gl.BindVertexArray(0)
	gl.GenBuffers(1, &ft.ebo)
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ft.ebo)
	gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, len(indices) * size_of(u16), raw_data(indices[:]), gl.STATIC_DRAW)

	gl.GenTextures(1, &ft.mask_tex)
	gl.BindTexture(gl.TEXTURE_2D, ft.mask_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, MASK_N, MASK_N, 0, gl.RED, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	for &w in ft.workers do w = thread.create_and_start_with_data(ft, far_worker)
	return true
}

far_destroy :: proc(ft: ^Far_Terrain) {
	sync.mutex_lock(&ft.mutex)
	ft.quit = true
	sync.cond_broadcast(&ft.cond)
	sync.mutex_unlock(&ft.mutex)
	for w in ft.workers {
		if w == nil do continue
		thread.join(w)
		thread.destroy(w)
	}
	for _, t in ft.tiles do far_free_tile(t)
	delete(ft.tiles)
	delete(ft.queue)
	delete(ft.done)
	delete(ft.uploads)
	delete(ft.draw)
	delete(ft.reqs)
}

@(private = "file")
far_free_tile :: proc(t: ^Far_Tile) {
	if t.vao != 0 do gl.DeleteVertexArrays(1, &t.vao)
	if t.vbo != 0 do gl.DeleteBuffers(1, &t.vbo)
	delete(t.verts)
	free(t)
}

// Средний цвет текстуры (по непрозрачным пикселям) — так текстура выглядит издалека.
@(private = "file")
tex_average :: proc(t: Tex) -> [3]f32 {
	img := gen_texture(t)
	sum: [3]f32
	n: f32
	for px in img {
		if px.a == 0 do continue
		sum += {f32(px.r), f32(px.g), f32(px.b)}
		n += 1
	}
	return sum / max(n, 1) / 255
}

@(private = "file")
far_palette :: proc() -> (p: Far_Palette) {
	p.grass = tex_average(.Grass_Top)
	p.tall_grass = tex_average(.Tall_Grass)
	p.sand = tex_average(.Sand)
	p.stone = tex_average(.Stone)
	p.dirt = tex_average(.Dirt)
	p.gravel = tex_average(.Gravel)
	p.oak = tex_average(.Oak_Leaves)
	p.birch = tex_average(.Birch_Leaves)
	p.water = tex_average(.Water)
	p.sandstone = tex_average(.Sandstone)
	p.limestone = tex_average(.Limestone)
	p.granite = tex_average(.Granite)
	return
}

// Индексы одинаковы для всех тайлов: сетка и четыре юбки.
@(private = "file")
far_indices :: proc() -> (idx: [FAR_INDICES]u16) {
	k := 0
	put :: proc(idx: ^[FAR_INDICES]u16, k: ^int, v: ..int) {
		for x in v {
			idx[k^] = u16(x)
			k^ += 1
		}
	}
	for j in 0 ..< FAR_K do for i in 0 ..< FAR_K {
		a := j * FAR_N + i
		put(&idx, &k, a, a + FAR_N, a + FAR_N + 1, a, a + FAR_N + 1, a + 1)
	}
	for e in 0 ..< 4 do for s in 0 ..< FAR_K {
		g0, g1 := edge_vertex(e, s), edge_vertex(e, s + 1)
		s0 := FAR_N * FAR_N + e * FAR_N + s
		put(&idx, &k, g0, s0, s0 + 1, g0, s0 + 1, g1)
	}
	return
}

// Вершина сетки на краю e (0: z = 0, 1: z = K, 2: x = 0, 3: x = K), шаг s.
@(private = "file")
edge_vertex :: proc(e, s: int) -> int {
	switch e {
	case 0:
		return s
	case 1:
		return FAR_K * FAR_N + s
	case 2:
		return s * FAR_N
	}
	return s * FAR_N + FAR_K
}

// ---------------------------------------------------------------- фоновые потоки

@(private = "file")
far_worker :: proc(data: rawptr) {
	ft := (^Far_Terrain)(data)
	for {
		sync.mutex_lock(&ft.mutex)
		for len(ft.queue) == 0 && !ft.quit do sync.cond_wait(&ft.cond, &ft.mutex)
		if ft.quit {
			sync.mutex_unlock(&ft.mutex)
			return
		}
		best := 0
		for t, i in ft.queue do if t.priority < ft.queue[best].priority do best = i
		t := ft.queue[best]
		unordered_remove(&ft.queue, best)
		t.dropped = t.wanted + 30 < ft.now // ушли — не нужен
		sync.mutex_unlock(&ft.mutex)

		if !t.dropped do far_build_tile(&ft.shared, t)

		sync.mutex_lock(&ft.mutex)
		append(&ft.done, t)
		sync.mutex_unlock(&ft.mutex)
	}
}

@(private = "file")
smooth :: proc(e0, e1, x: f64) -> f64 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}

@(private = "file")
mix3 :: proc(a, b: [3]f32, t: f64) -> [3]f32 {return a + (b - a) * f32(clamp(t, 0, 1))}

// Цвет поверхности и её высота над уровнем моря (м) в точке шара p — по тем
// же правилам, что блоки в generate_chunk, только плавно (доли вместо выбора).
@(private = "file")
far_surface :: proc(fs: ^Far_Shared, p: [3]f64, v, slope, cell: f64) -> (col: [3]f32, h: f64, water: bool) {
	pal := &fs.palette
	seed := i64(fs.seed)
	if v < SEA_LEVEL {
		// вода: полупрозрачная гладь поверх дна, глубже — дно темнее
		depth := Y_SEA - (v + 0.5)
		n := f64(fbm_lod(seed + 131, p, 24, 2, cell))
		bottom := v >= SEA_LEVEL - 4 || n > 0.25 ? pal.sand : n < -0.2 ? pal.gravel : pal.dirt
		// дно под водой в тени (как у блоков: SHADOW_LIGHT), глубже — темнее
		t := f32(math.exp(-depth / 8))
		col = pal.water * 0.67 + (bottom * SHADOW_LIGHT * t + pal.water * 0.25 * (1 - t)) * 0.33
		return col, 0, true
	}
	h = max(v + 0.5 - Y_SEA, 0.1)
	rock := rock_line(seed, p, cell)
	stone := max(smooth(2.2, 3.5, slope), smooth(rock - 150, rock + 150, h))
	sand := 1 - smooth(63.5, 64.5, v)
	grassy := 0.5 + 0.5 * f64(fbm_lod(seed + 55, p, 48, 2, cell))
	col = mix3(pal.grass, pal.tall_grass, (0.03 + 0.32 * grassy) * 0.6)
	// голая скала — пласты: в низких горах осадочные, в высоких — гранит
	bare := mix3(pal.sandstone * 0.67 + pal.limestone * 0.33, pal.granite, smooth(1500, 2500, h))
	col = mix3(col, bare, stone)
	col = mix3(col, pal.sand, sand)
	// лес: кроны закрывают землю и поднимают поверхность
	cover := f64(forest_density(seed, p, h, cell)) * (1 - stone) * (1 - sand) * (1 - smooth(1.5, 2.5, slope))
	crowns := smooth(0, 0.45, cover)
	birch := clamp(smooth(0.1, 0.3, f64(fbm_lod(seed + 99, p, 160, 2, cell))) + 0.12, 0, 1)
	col = mix3(col, mix3(pal.oak, pal.birch, birch) * 0.85, crowns * 0.9)
	h += 5.5 * crowns
	return col, h, false
}

@(private = "file")
pack_normal :: proc(n: [3]f64) -> [4]i8 {
	return {i8(math.round(n.x * 127)), i8(math.round(n.y * 127)), i8(math.round(n.z * 127)), 0}
}

@(private = "file")
far_build_tile :: proc(fs: ^Far_Shared, t: ^Far_Tile) {
	g := &fs.geo
	R := g.radius
	S := f64(g.n) / f64(u64(1) << t.key.level) // сторона тайла, клеток грани
	c := S / FAR_K
	x0 := f64(t.key.x) * S
	z0 := f64(t.key.z) * S
	cell := t.size / FAR_K // клетка, м

	G :: FAR_G
	dirs: [G * G][3]f64
	v: [G * G]f64
	for j in 0 ..< G do for i in 0 ..< G {
		d := geo_dir(g, t.key.face, x0 + f64(i - 1) * c, z0 + f64(j - 1) * c)
		dirs[j * G + i] = d
		v[j * G + i] = terrain_height_lod(i64(fs.seed), d * R, cell)
	}
	h: [G * G]f64
	col: [G * G][3]f32
	water: [G * G]bool
	depth: [G * G]f64
	for j in 0 ..< G do for i in 0 ..< G {
		k := j * G + i
		il, ir := max(i - 1, 0), min(i + 1, G - 1)
		jl, jr := max(j - 1, 0), min(j + 1, G - 1)
		gx := abs(v[j * G + ir] - v[j * G + il]) / (f64(ir - il) * cell)
		gz := abs(v[jr * G + i] - v[jl * G + i]) / (f64(jr - jl) * cell)
		col[k], h[k], water[k] = far_surface(fs, dirs[k] * R, v[k], max(gx, gz), cell)
		if water[k] do depth[k] = Y_SEA - (v[k] + 0.5)
	}
	P: [G * G][3]f64
	for k in 0 ..< G * G do P[k] = dirs[k] * (R + h[k])

	// ошибка упрощения: насколько вершины отличаются от сетки вдвое грубее
	// (нечётные — от среднего соседних чётных). Потомки на шаг мельче — примерно вдвое меньше.
	err_h, err_c: f64
	for j in 0 ..< FAR_N do for i in 0 ..< FAR_N {
		if i % 2 == 0 && j % 2 == 0 do continue
		k := (j + 1) * G + (i + 1)
		ks: [4]int
		n := 0
		if i % 2 == 1 && j % 2 == 1 {
			ks = {k - G - 1, k - G + 1, k + G - 1, k + G + 1}
			n = 4
		} else if i % 2 == 1 {
			ks[0], ks[1], n = k - 1, k + 1, 2
		} else {
			ks[0], ks[1], n = k - G, k + G, 2
		}
		hm: f64
		cm: [3]f32
		for q in 0 ..< n {
			hm += h[ks[q]]
			cm += col[ks[q]]
		}
		err_h = max(err_h, abs(h[k] - hm / f64(n)))
		dc := col[k] - cm / f32(n)
		err_c = max(err_c, f64(max(abs(dc.r), abs(dc.g), abs(dc.b))))
	}
	t.err = 0.5 * err_h + 12 * err_c // цвет: перепад 0,1 — как 1,2 м высоты

	verts := make([]Far_Vertex, FAR_VERTS)
	bound := 0.0
	top, bottom: f64 = -1e9, 1e9
	for j in 0 ..< FAR_N do for i in 0 ..< FAR_N {
		k := (j + 1) * G + (i + 1)
		top = max(top, h[k])
		bottom = min(bottom, h[k] - min(depth[k], 127))
		n := dirs[k]
		if !water[k] {
			a := P[k + 1] - P[k - 1]
			b := P[k + G] - P[k - G]
			n = {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
			n /= math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
			if n.x * dirs[k].x + n.y * dirs[k].y + n.z * dirs[k].z < 0 do n = -n
		}
		off := P[k] - t.origin
		cc := col[k]
		nrm := pack_normal(n)
		nrm.w = i8(clamp(math.round(depth[k]), 0, 127))
		if water[k] do t.has_water = true
		verts[j * FAR_N + i] = {
			off    = {f32(off.x), f32(off.y), f32(off.z)},
			normal = nrm,
			color  = {u8(clamp(cc.r, 0, 1) * 255), u8(clamp(cc.g, 0, 1) * 255), u8(clamp(cc.b, 0, 1) * 255), water[k] ? 255 : 0},
		}
		bound = max(bound, len3(off))
		if water[k] do bound = max(bound, len3(off - dirs[k] * min(depth[k], 127))) // дно
	}
	// юбки: края тайла, опущенные вниз, — закрывают щели с соседями другого уровня
	skirt := 3 + 2 * cell
	for e in 0 ..< 4 do for s in 0 ..< FAR_N {
		gv := edge_vertex(e, s)
		i, j := gv % FAR_N, gv / FAR_N
		d := dirs[(j + 1) * G + (i + 1)]
		src := verts[gv]
		down := [3]f32{f32(d.x * skirt), f32(d.y * skirt), f32(d.z * skirt)}
		verts[FAR_N * FAR_N + e * FAR_N + s] = {off = src.off - down, normal = src.normal, color = src.color}
	}
	t.verts = verts
	t.bound = bound + skirt
	t.top = top
	t.bottom = bottom
}

// ---------------------------------------------------------------- выбор тайлов

// Геометрия тайла: центр, ограничивающая сфера, сторона. Пока тайл не
// построен, его высоты неизвестны — берутся у родителя с запасом (детали
// добавляют вершины и впадины), у корней — пределы рельефа мира.
@(private = "file")
far_tile_new :: proc(ft: ^Far_Terrain, key: Tile_Key) -> ^Far_Tile {
	g := &ft.shared.geo
	S := f64(g.n) / f64(u64(1) << key.level)
	x0, z0 := f64(key.x) * S, f64(key.z) * S
	t := new(Far_Tile)
	t.key = key
	t.h_lo, t.h_top = relief.h_min, relief.h_max
	if key.level > 0 {
		if parent, ok := ft.tiles[{key.face, key.level - 1, key.x >> 1, key.z >> 1}]; ok && parent.ready {
			m := 60 + 4 * parent.err
			t.h_lo = max(parent.h_lo - m, relief.h_min)
			t.h_top = min(parent.h_top + m, relief.h_max)
		}
	}
	R := g.radius
	cd := geo_dir(g, key.face, x0 + S / 2, z0 + S / 2)
	t.origin = cd * (R + (t.h_lo + t.h_top) / 2)
	r, side := 0.0, 0.0
	for a in 0 ..= 2 do for b in 0 ..= 2 {
		d := geo_dir(g, key.face, x0 + f64(a) * S / 2, z0 + f64(b) * S / 2)
		side = max(side, len3((d - cd) * R))
		r = max(r, len3(d * (R + t.h_lo) - t.origin), len3(d * (R + t.h_top) - t.origin))
	}
	t.size = side * math.SQRT_TWO
	t.radius = r
	ft.tiles[key] = t
	return t
}

@(private = "file")
far_tile :: proc(ft: ^Far_Terrain, key: Tile_Key) -> ^Far_Tile {
	if t, ok := ft.tiles[key]; ok do return t
	return far_tile_new(ft, key)
}

// Может ли что-то из тайла быть видно: не за горизонтом и не дальше предела.
// Горизонт — по уровню моря (ниже него поверхность не видна: там вода), с
// высоты камеры, плюс высота самого тайла — его вершины выглядывают из-за горизонта.
@(private = "file")
far_visible :: proc(ft: ^Far_Terrain, pv: ^Planet_View, t: ^Far_Tile) -> (ok: bool, dist: f64) {
	R := pv.radius
	d := len3(pv.pc - t.origin)
	dist = max(d - t.radius, 0)
	if dist > ft.max_dist do return false, dist
	dir := t.origin / len3(t.origin) // центр тайла — на средней высоте, не на уровне моря
	cosv := clamp(dir.x * pv.up.x + dir.y * pv.up.y + dir.z * pv.up.z, -1, 1)
	ang := math.acos(cosv)
	ang_r := 2 * math.asin(min(t.radius / (2 * R), 1))
	horizon := math.acos(R / max(R + pv.cam_h, R + 1)) + math.acos(R / (R + max(t.h_top, 1)))
	return ang - ang_r <= horizon, dist
}

@(private = "file")
far_request :: proc(ft: ^Far_Terrain, t: ^Far_Tile, dist: f64) {
	t.want = dist / max(t.size, 1) + f64(t.key.level) * 0.01
	append(&ft.reqs, t)
}

@(private = "file")
far_visit :: proc(ft: ^Far_Terrain, pv: ^Planet_View, key: Tile_Key) {
	t := far_tile(ft, key)
	vis, dist := far_visible(ft, pv, t)
	if !vis do return
	t.used = ft.frame
	split := false
	if dist < FAR_SPLIT * t.size && t.size > 2 * FAR_MIN_TILE && key.level < 30 {
		split = !t.ready || dist < FAR_NEAR_SPLIT * t.size || t.err / max(dist, 1) > FAR_PIXEL_ERR
	}
	if split {
		kids: [4]Tile_Key
		all := true
		for k in 0 ..< 4 {
			kids[k] = {key.face, key.level + 1, key.x * 2 + i32(k & 1), key.z * 2 + i32(k >> 1)}
			c := far_tile(ft, kids[k])
			cvis, cdist := far_visible(ft, pv, c)
			if !cvis do continue
			c.used = ft.frame
			if !c.ready {
				all = false
				far_request(ft, c, cdist)
			}
		}
		if all {
			for k in kids do far_visit(ft, pv, k)
			return
		}
	}
	if t.ready {
		append(&ft.draw, t)
		ft.view_dist = max(ft.view_dist, dist + t.size)
	} else {
		far_request(ft, t, dist)
	}
}

// Каждый кадр: что рисовать, что достроить, что выгрузить.
far_update :: proc(ft: ^Far_Terrain, pv: ^Planet_View, upload_budget: f64 = FAR_UPLOAD_BUDGET) {
	ft.frame += 1

	// готовые тайлы из фоновых потоков
	sync.mutex_lock(&ft.mutex)
	for t in ft.done {
		if t.dropped {
			t.dropped = false
			t.in_flight = false
		} else {
			append(&ft.uploads, t) // in_flight — до загрузки в видеокарту
		}
	}
	clear(&ft.done)
	sync.mutex_unlock(&ft.mutex)

	start := eng.time_now()
	n_up := 0
	for t in ft.uploads {
		if eng.time_now() - start > upload_budget && n_up > 0 do break
		far_upload(ft, t)
		n_up += 1
	}
	remove_range(&ft.uploads, 0, n_up)

	// выбор тайлов: от граней куба вниз по дереву
	R := pv.radius
	ft.horizon = math.sqrt(max(pv.cam_h, 0) * (2 * R + max(pv.cam_h, 0)))
	clear(&ft.draw)
	clear(&ft.reqs)
	ft.view_dist = 0
	for face in Cube_Face do far_visit(ft, pv, {face, 0, 0, 0})
	// ближние сначала: дальние пиксели за ними отбрасывает тест глубины
	slice.sort_by(ft.draw[:], proc(a, b: ^Far_Tile) -> bool {return a.size < b.size})

	// заявки фоновым потокам (одним заходом под замком)
	sync.mutex_lock(&ft.mutex)
	ft.now = ft.frame
	for t in ft.reqs {
		t.wanted = ft.frame
		t.priority = t.want
		if !t.in_flight && !t.ready {
			t.in_flight = true
			append(&ft.queue, t)
		}
	}
	ft.pending = len(ft.queue) + len(ft.uploads)
	if len(ft.reqs) > 0 do sync.cond_broadcast(&ft.cond)
	sync.mutex_unlock(&ft.mutex)
	ft.ready_all = len(ft.reqs) == 0 && len(ft.uploads) == 0

	if ft.frame % 30 == 0 do far_evict(ft)
}

@(private = "file")
far_upload :: proc(ft: ^Far_Terrain, t: ^Far_Tile) {
	if t.vao == 0 {
		gl.GenVertexArrays(1, &t.vao)
		gl.GenBuffers(1, &t.vbo)
		gl.BindVertexArray(t.vao)
		gl.BindBuffer(gl.ARRAY_BUFFER, t.vbo)
		gl.EnableVertexAttribArray(0)
		gl.VertexAttribPointer(0, 3, gl.FLOAT, false, size_of(Far_Vertex), offset_of(Far_Vertex, off))
		gl.EnableVertexAttribArray(1)
		gl.VertexAttribPointer(1, 4, gl.BYTE, true, size_of(Far_Vertex), offset_of(Far_Vertex, normal))
		gl.EnableVertexAttribArray(2)
		gl.VertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, true, size_of(Far_Vertex), offset_of(Far_Vertex, color))
		gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ft.ebo)
		gl.BindVertexArray(0)
	}
	gl.BindBuffer(gl.ARRAY_BUFFER, t.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(t.verts) * size_of(Far_Vertex), raw_data(t.verts), gl.STATIC_DRAW)
	delete(t.verts)
	t.verts = nil
	t.radius = t.bound
	t.h_top = t.top
	t.h_lo = t.bottom
	t.ready = true
	t.in_flight = false
}

// Лишние тайлы (давно не нужные) — из видеопамяти.
@(private = "file")
far_evict :: proc(ft: ^Far_Terrain) {
	if len(ft.tiles) <= FAR_MAX_TILES do return
	old := make([dynamic]^Far_Tile, context.temp_allocator)
	for _, t in ft.tiles {
		if !t.in_flight && t.used + 2 < ft.frame && t.key.level > 0 do append(&old, t)
	}
	slice.sort_by(old[:], proc(a, b: ^Far_Tile) -> bool {return a.used < b.used})
	extra := len(ft.tiles) - FAR_MAX_TILES * 9 / 10
	for t in old[:min(extra, len(old))] {
		delete_key(&ft.tiles, t.key)
		far_free_tile(t)
	}
}

// Маска чанков вокруг камеры: 255 — чанк нарисован блоками и все соседи тоже
// (дальний рельеф здесь не нужен), 128 — нарисованный чанк у края блоков (здесь
// дальний рельеф рисуется опущенным: закрывает щели на стыке), 0 — блоков нет.
far_update_mask :: proc(ft: ^Far_Terrain, w: ^World, cam_pos: [3]f64) {
	ccx := eng.floor_div(i32(math.floor(cam_pos.x)), CHUNK_SIZE)
	ccz := eng.floor_div(i32(math.floor(cam_pos.z)), CHUNK_SIZE)
	meshed: [MASK_N * MASK_N]bool
	for j in 0 ..< MASK_N do for i in 0 ..< MASK_N {
		col := world_frame_column(w, ccx + i32(i) - MASK_R, ccz + i32(j) - MASK_R)
		meshed[j * MASK_N + i] = col != nil && col.covered
	}
	for j in 0 ..< MASK_N do for i in 0 ..< MASK_N {
		v: u8 = 0
		if meshed[j * MASK_N + i] {
			v = 255
			for dj in -1 ..= 1 do for di in -1 ..= 1 {
				ni, nj := i + di, j + dj
				if ni < 0 || nj < 0 || ni >= MASK_N || nj >= MASK_N || !meshed[nj * MASK_N + ni] do v = 128
			}
		}
		ft.mask[j * MASK_N + i] = v
	}
	gl.BindTexture(gl.TEXTURE_2D, ft.mask_tex)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, MASK_N, MASK_N, gl.RED, gl.UNSIGNED_BYTE, &ft.mask[0])
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
	ft.mask_org = {
		f32(cam_pos.x - f64((ccx - MASK_R) * CHUNK_SIZE)),
		f32(cam_pos.z - f64((ccz - MASK_R) * CHUNK_SIZE)),
		MASK_N,
	}
}

// Ближайшая к точке (единичное направление) вершина куба.
nearest_anomaly :: proc(up: [3]f64) -> (corner: int, dir: [3]f64) {
	best := -2.0
	for d, i in ANOMALY_DIRS {
		k := (d.x * up.x + d.y * up.y + d.z * up.z) / math.sqrt(f64(3))
		if k > best {
			best = k
			corner = i
		}
	}
	return corner, ANOMALY_DIRS[corner] / math.sqrt(f64(3))
}

// ---------------------------------------------------------------- отрисовка

// Рисует дальний рельеф (uniform-ы неба, света, дымки уже выставлены вызывающим).
far_draw :: proc(ft: ^Far_Terrain, pv: ^Planet_View, view_proj: eng.Mat4, frustum: ^[6][4]f32, side_shade: [2]f32) {
	gl.UseProgram(ft.prog)
	eng.set_mat4(ft.u.view_proj, view_proj)
	jinv, jt: matrix[3, 3]f32
	for r in 0 ..< 3 do for c in 0 ..< 3 {
		jinv[r, c] = f32(pv.jinv[r, c])
		jt[r, c] = f32(pv.j[c, r])
	}
	gl.UniformMatrix3fv(ft.u.jinv, 1, false, &jinv[0, 0])
	gl.UniformMatrix3fv(ft.u.jt, 1, false, &jt[0, 0])
	eng.set_f32(ft.u.logk, f32(2 / math.log2(FAR_LOG_FAR + 1)))
	eng.set_vec2(ft.u.side_shade, side_shade)
	eng.set_i32(ft.u.mask, 2)
	eng.set_vec3(ft.u.mask_org, ft.mask_org)
	gl.ActiveTexture(gl.TEXTURE2)
	gl.BindTexture(gl.TEXTURE_2D, ft.mask_tex)
	gl.ActiveTexture(gl.TEXTURE0)

	// J⁻¹ растягивает не больше чем в ~1,5 раза — с запасом для отсечения
	stretch :: 1.6
	ft.drawn = 0
	eng.set_f32(ft.u.floor, 0)
	floors := make([dynamic]^Far_Tile, context.temp_allocator)
	for t in ft.draw {
		rel := planet_rel(pv, t.origin)
		c := [3]f32{f32(rel.x), f32(rel.y), f32(rel.z)}
		if !sphere_visible(frustum, c, f32(t.radius * stretch)) do continue
		if far_under_blocks(ft, c, f32(t.radius * stretch)) do continue
		eng.set_vec3(ft.u.rel_o, c)
		gl.BindVertexArray(t.vao)
		gl.DrawElements(gl.TRIANGLES, FAR_INDICES, gl.UNSIGNED_SHORT, nil)
		ft.drawn += 1
		if t.has_water && len3(t.origin - pv.pc) - t.radius < FAR_FLOOR_DIST do append(&floors, t)
	}
	// дно под водой: те же тайлы, вершины воды опущены на глубину. Сверху его
	// закрывает гладь, а лучи, ушедшие под воду у края ближних блоков, упираются в него
	eng.set_f32(ft.u.floor, 1)
	for t in floors {
		rel := planet_rel(pv, t.origin)
		eng.set_vec3(ft.u.rel_o, {f32(rel.x), f32(rel.y), f32(rel.z)})
		gl.BindVertexArray(t.vao)
		gl.DrawElements(gl.TRIANGLES, FAR_INDICES, gl.UNSIGNED_SHORT, nil)
	}
	eng.set_f32(ft.u.floor, 0)
	gl.BindVertexArray(0)
}

// Тайл целиком под блоками (все чанки под ним нарисованы, не у края) — не нужен.
@(private = "file")
far_under_blocks :: proc(ft: ^Far_Terrain, c: [3]f32, r: f32) -> bool {
	x0 := int(math.floor((ft.mask_org.x + c.x - r) / CHUNK_SIZE))
	x1 := int(math.floor((ft.mask_org.x + c.x + r) / CHUNK_SIZE))
	z0 := int(math.floor((ft.mask_org.y + c.z - r) / CHUNK_SIZE))
	z1 := int(math.floor((ft.mask_org.y + c.z + r) / CHUNK_SIZE))
	if x0 < 0 || z0 < 0 || x1 >= MASK_N || z1 >= MASK_N do return false
	for j in z0 ..= z1 do for i in x0 ..= x1 {
		if ft.mask[j * MASK_N + i] != 255 do return false
	}
	return true
}

// Для отчёта: сколько выбрано тайлов каждого размера.
far_stats :: proc(ft: ^Far_Terrain) -> string {
	counts: [32]int
	sizes: [32]f64
	for t in ft.draw {
		counts[t.key.level] += 1
		sizes[t.key.level] = t.size
	}
	b: [dynamic]u8
	b.allocator = context.temp_allocator
	for c, l in counts {
		if c > 0 do append(&b, ..transmute([]u8)fmt.tprintf("%.0fм:%d ", sizes[l], c))
	}
	return string(b[:])
}

sphere_visible :: proc(f: ^[6][4]f32, c: [3]f32, r: f32) -> bool {
	for pl in f^ {
		l := math.sqrt(pl.x * pl.x + pl.y * pl.y + pl.z * pl.z)
		if (pl.x * c.x + pl.y * c.y + pl.z * c.z + pl.w) / l < -r do return false
	}
	return true
}
