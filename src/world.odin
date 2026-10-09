package main

// Мир из кубических секций 16×16×16 — без потолка и дна (0.012).
//
// Секция принадлежит грани куба-планеты и лежит в её собственной сетке (ключ —
// грань + координаты на ней, y — номер секции по высоте). Игра идёт в
// "кадре" текущей грани: координаты x, z — её сетка, продолженная через
// рёбра на соседние грани (их сетка повёрнута на 90°·k). За двумя рёбрами
// сразу (у вершины куба) — пустота, её закрывает столп-аномалия.
//
// Над каждым столбом секций — колонка 16×16: высоты рельефа, свет неба,
// деревья, слои пород. Грузятся только секции «полосы поверхности» (от низа
// земли до верха крон и поверхность моря) рядом с игроком. Всё остальное —
// сплошной воздух, толща воды или камень — отвечается по колонке, ничего не
// храня. Вдали поверхность рисует дальний рельеф.

import "core:math"
import "core:slice"
import eng "engine"

CHUNK_SIZE :: 16
CHUNK_AREA :: CHUNK_SIZE * CHUNK_SIZE
CHUNK_VOLUME :: CHUNK_AREA * CHUNK_SIZE
SEA_LEVEL :: 62
VIEW_ABOVE :: 192 // поверхность выше игрока грузится до стольких блоков
VIEW_BELOW :: 400 // ниже — до стольких (из капсулы на 360 м земля уже из блоков)
MAX_COL_TREES :: 96

Chunk_Key :: struct {
	face:    Cube_Face,
	x, y, z: i32, // координаты секции в сетке своей грани; y — по высоте
}

Column_Key :: struct {
	face: Cube_Face,
	x, z: i32,
}

Chunk :: struct {
	key:         Chunk_Key,
	blocks:      ^[CHUNK_VOLUME]Block, // nil — вся секция из fill
	fill:        Block,
	meshed:      bool,
	stale:       bool, // меш есть, но свет изменился (облетели кроны) — перестроить, когда будет время
	opaque_mesh: Chunk_Mesh,
	water_mesh:  Chunk_Mesh,
}

// Дерево (trees.odin): форма строится из этих чисел и зерна.
Tree :: struct {
	x, z:       i32, // клетка ствола (сетка грани); у толстого — младший угол 2×2
	base:       i32, // первый блок ствола (над землёй)
	height:     f32, // высота, м
	crown:      f32, // радиус кроны, м
	crown_base: f32, // низ кроны над землёй, м
	kind:       Tree_Kind,
	girth:      u8, // толщина ствола, блоков (1 или 2)
	thin:       bool, // ствол тоньше 45 см — тонкий столбик (Post)
	under:      bool, // подрост в тени крон соседей
	dbh:        f32, // поперечник ствола, м
	fins:       u8, // досковидные корни (тропические великаны)
	seed:       u32,
}

Tree_Kind :: enum u8 {
	Oak,
	Birch,
	Spruce,
	Acacia,
	Jungle,
	Cactus,
}

Column :: struct {
	key:      Column_Key,
	height:   [CHUNK_AREA]i32, // последний блок земли
	surface:  [CHUNK_AREA]Block,
	filler:   [CHUNK_AREA]Block,
	monolith: [CHUNK_AREA]bool, // столп аномалии
	points:   [CHUNK_AREA][3]f64, // точки шара (шум трав и цветов)
	sky:      [CHUNK_AREA]i32, // первый y, куда достаёт небесный свет
	sky_bare: [CHUNK_AREA]i32, // то же, когда лиственные кроны голые (зима)
	trees:    [MAX_COL_TREES]Tree, // деревья, чья листва задевает колонку
	tree_n:   int,
	lo, hi:   i32, // полоса поверхности, блоки
	water:    bool, // в колонке есть вода (поверхность моря)
	// недра: слои пород по колонкам блоков
	sed:      [CHUNK_AREA]f32, // толщина осадочных слоёв, м
	warp:     [CHUNK_AREA]f32, // сдвиг слоёв (наклон пластов), м
	moho:     i32, // ниже — мантия
	oceanic:  bool, // кора океанов (базальт), иначе материков (гранит)
	covered:  bool, // поверхность здесь нарисована блоками (для дальнего рельефа)
	// климат (0.015): природная зона и оттенок травы по блокам, условия в центре колонки
	biome:    [CHUNK_AREA]Biome,
	tint:     [CHUNK_AREA]u8, // сухость (младшие 4 бита) и холод (старшие) — для травы и листвы
	clim:     Climate_Point,
}

World :: struct {
	seed:        u32,
	geo:         Planet_Geo, // планета и грань, на которой идёт игра
	chunks:      map[Chunk_Key]^Chunk,
	columns:     map[Column_Key]^Column,
	view_radius: i32,
	load_order:  [dynamic][2]i32, // смещения колонок, отсортированные по расстоянию
	// Изменения мира поверх генерации — переживают выгрузку секций
	// (пока только до выхода из игры: сохранения ещё нет).
	edits:       map[Chunk_Key][dynamic]Block_Edit,
	gravity:     f64, // сила тяжести планеты, g (1 — земная)
	jump_apex:   f64, // высота прыжка при этой силе тяжести, блоков
	bare:        bool, // лиственные кроны вокруг игрока сейчас голые — свет неба проходит сквозь них
}

// Сила тяжести планеты: падение и прыжки. Высота прыжка считается теми же
// шагами, что и физика персонажа (character_tick).
world_set_gravity :: proc(w: ^World, g: f64) {
	w.gravity = g
	y, v := 0.0, JUMP_SPEED
	w.jump_apex = 0
	for _ in 0 ..< 200 {
		y += v
		v = (v - GRAVITY_PER_TICK * g) * 0.98
		w.jump_apex = max(w.jump_apex, y)
		if v <= 0 do break
	}
}

Block_Edit :: struct {
	index: i32,
	block: Block,
}

block_index :: #force_inline proc "contextless" (x, y, z: i32) -> i32 {
	return (y * CHUNK_SIZE + z) * CHUNK_SIZE + x
}

column_index :: #force_inline proc "contextless" (gx, gz: i32) -> int {
	return int(eng.floor_mod(gz, CHUNK_SIZE) * CHUNK_SIZE + eng.floor_mod(gx, CHUNK_SIZE))
}

world_init :: proc(w: ^World, seed: u32, view_radius: i32, geo: Planet_Geo) {
	w.seed = seed
	w.geo = geo
	w.view_radius = view_radius
	world_set_gravity(w, 1)
	r := view_radius
	for dz in -r ..= r do for dx in -r ..= r {
		if f32(dx * dx + dz * dz) <= (f32(r) + 0.5) * (f32(r) + 0.5) {
			append(&w.load_order, [2]i32{dx, dz})
		}
	}
	slice.sort_by(w.load_order[:], proc(a, b: [2]i32) -> bool {
		return a.x * a.x + a.y * a.y < b.x * b.x + b.y * b.y
	})
}

@(private = "file")
chunk_free :: proc(c: ^Chunk) {
	chunk_mesh_free(&c.opaque_mesh)
	chunk_mesh_free(&c.water_mesh)
	if c.blocks != nil do free(c.blocks)
	free(c)
}

world_destroy :: proc(w: ^World) {
	for _, c in w.chunks do chunk_free(c)
	delete(w.chunks)
	for _, col in w.columns do free(col)
	delete(w.columns)
	delete(w.load_order)
	for _, list in w.edits do delete(list)
	delete(w.edits)
}

// Клетка кадра -> грань, клетка на ней (ok = false — пустота у вершины куба).
world_resolve :: proc(w: ^World, x, z: i32) -> (face: Cube_Face, gx, gz: i32, ok: bool) {
	return geo_resolve(&w.geo, w.geo.face, x, z)
}

chunk_key_of :: proc(face: Cube_Face, gx, y, gz: i32) -> Chunk_Key {
	return {face, eng.floor_div(gx, CHUNK_SIZE), eng.floor_div(y, CHUNK_SIZE), eng.floor_div(gz, CHUNK_SIZE)}
}

column_key_of :: proc(face: Cube_Face, gx, gz: i32) -> Column_Key {
	return {face, eng.floor_div(gx, CHUNK_SIZE), eng.floor_div(gz, CHUNK_SIZE)}
}

world_chunk :: proc(w: ^World, key: Chunk_Key) -> ^Chunk {
	return w.chunks[key] or_else nil
}

world_column :: proc(w: ^World, key: Column_Key) -> ^Column {
	return w.columns[key] or_else nil
}

// Колонка кадра (координаты колонки в кадре текущей грани).
world_frame_column :: proc(w: ^World, fcx, fcz: i32) -> ^Column {
	face, gx, gz, ok := world_resolve(w, fcx * CHUNK_SIZE, fcz * CHUNK_SIZE)
	if !ok do return nil
	return world_column(w, column_key_of(face, gx, gz))
}

// Блок секции (секция может быть «сплошной»).
chunk_block :: #force_inline proc(c: ^Chunk, idx: i32) -> Block {
	return c.blocks == nil ? c.fill : c.blocks[idx]
}

// Секция sy колонки — из полосы поверхности (её нужно строить из блоков)?
column_band_has :: proc(col: ^Column, sy: i32) -> bool {
	if sy >= eng.floor_div(col.lo, CHUNK_SIZE) && sy <= eng.floor_div(col.hi, CHUNK_SIZE) do return true
	return col.water && sy == eng.floor_div(SEA_LEVEL, CHUNK_SIZE)
}

// Блок вне полосы поверхности: воздух, толща воды или камень (порода для
// столкновений и граней неважна — всё равно сплошная).
column_guess :: proc(col: ^Column, i: int, y: i32) -> Block {
	if y <= col.height[i] do return col.monolith[i] ? .Monolith : .Stone
	return y <= SEA_LEVEL ? .Water : .Air
}

// Блок в мировой (глобальной) клетке грани face. loaded = false — секция
// полосы поверхности ещё не построена (физика считает такое твёрдым).
global_get_block :: proc(w: ^World, face: Cube_Face, gx, y, gz: i32) -> (b: Block, loaded: bool) {
	key := chunk_key_of(face, gx, y, gz)
	if c := world_chunk(w, key); c != nil {
		return chunk_block(c, block_index(eng.floor_mod(gx, CHUNK_SIZE), eng.floor_mod(y, CHUNK_SIZE), eng.floor_mod(gz, CHUNK_SIZE))), true
	}
	col := world_column(w, {face, key.x, key.z})
	if col == nil do return .Air, false
	return column_guess(col, column_index(gx, gz), y), !column_band_has(col, key.y)
}

// Блок в координатах кадра. Пустота у вершины куба — непроходимый столп.
world_get_block :: proc(w: ^World, x, y, z: i32) -> (b: Block, loaded: bool) {
	face, gx, gz, ok := world_resolve(w, x, z)
	if !ok do return .Monolith, true
	return global_get_block(w, face, gx, y, gz)
}

// Незагруженное считается твёрдым, чтобы игрок не провалился.
world_is_solid :: proc(w: ^World, x, y, z: i32) -> bool {
	b, loaded := world_get_block(w, x, y, z)
	if !loaded do return true
	return BLOCK_INFO[b].solid
}

// Яркость неба в точке: 1 — открыто небу, SHADOW_LIGHT — в тени.
world_sky_light :: proc(w: ^World, x, y, z: i32) -> f32 {
	face, gx, gz, ok := world_resolve(w, x, z)
	if !ok do return 1
	col := world_column(w, column_key_of(face, gx, gz))
	if col == nil do return 1
	sky := w.bare ? col.sky_bare[column_index(gx, gz)] : col.sky[column_index(gx, gz)]
	return y >= sky ? 1 : SHADOW_LIGHT
}

ensure_column :: proc(w: ^World, key: Column_Key) -> (col: ^Column, created: bool) {
	if existing, ok := w.columns[key]; ok do return existing, false
	col = new(Column)
	col.key = key
	generate_column(w, col)
	w.columns[key] = col
	return col, true
}

ensure_chunk :: proc(w: ^World, key: Chunk_Key) -> (c: ^Chunk, created: bool) {
	if existing, ok := w.chunks[key]; ok do return existing, false
	col, _ := ensure_column(w, {key.face, key.x, key.z})
	c = new(Chunk)
	c.key = key
	generate_section(w, col, c)
	if list, ok := w.edits[key]; ok {
		chunk_expand(c)
		for e in list do c.blocks[e.index] = e.block
	}
	w.chunks[key] = c
	return c, true
}

// Сплошную секцию — в обычный массив (перед правкой).
chunk_expand :: proc(c: ^Chunk) {
	if c.blocks != nil do return
	c.blocks = new([CHUNK_VOLUME]Block)
	for &b in c.blocks do b = c.fill
}

// Соседняя секция (dx, dy, dz) в сетке грани секции; через ребро — на другой грани.
chunk_neighbor_key :: proc(w: ^World, key: Chunk_Key, dx, dy, dz: i32) -> (Chunk_Key, bool) {
	x := (key.x + dx) * CHUNK_SIZE + CHUNK_SIZE / 2
	z := (key.z + dz) * CHUNK_SIZE + CHUNK_SIZE / 2
	face, gx, gz, ok := geo_resolve(&w.geo, key.face, x, z)
	if !ok do return {}, false
	return chunk_key_of(face, gx, (key.y + dy) * CHUNK_SIZE, gz), true
}

// Меняет блок (координаты кадра), запоминает изменение и помечает секции на
// перестройку сетки.
world_set_block :: proc(w: ^World, x, y, z: i32, b: Block) {
	face, gx, gz, ok := world_resolve(w, x, z)
	if !ok do return
	key := chunk_key_of(face, gx, y, gz)
	lx := eng.floor_mod(gx, CHUNK_SIZE)
	ly := eng.floor_mod(y, CHUNK_SIZE)
	lz := eng.floor_mod(gz, CHUNK_SIZE)
	idx := block_index(lx, ly, lz)
	c, _ := ensure_chunk(w, key)
	if chunk_block(c, idx) == .Monolith do return // столп неразрушим
	chunk_expand(c)

	list := w.edits[key]
	append(&list, Block_Edit{idx, b})
	w.edits[key] = list
	c.blocks[idx] = b
	c.meshed = false

	// полоса поверхности растёт до правки; свет неба в этой колонке блоков
	col, _ := ensure_column(w, {face, key.x, key.z})
	col.lo = min(col.lo, y)
	col.hi = max(col.hi, y)
	i := column_index(gx, gz)
	for bare in ([2]bool{false, true}) {
		sky := bare ? &col.sky_bare[i] : &col.sky[i]
		if BLOCK_INFO[b].blocks_light && !(bare && deciduous_leaves(b)) {
			sky^ = max(sky^, y + 1)
		} else if y == sky^ - 1 {
			yy := y - 1
			for ; yy > y - 512; yy -= 1 {
				bb, _ := global_get_block(w, face, gx, yy, gz)
				if BLOCK_INFO[bb].blocks_light && !(bare && deciduous_leaves(bb)) do break
			}
			sky^ = yy + 1
		}
	}
	// соседи тоже: их AO и грани на границе зависят от этого блока
	for dy in i32(-1) ..= 1 do for dz in i32(-1) ..= 1 do for dx in i32(-1) ..= 1 {
		if dx < 0 && lx != 0 || dx > 0 && lx != CHUNK_SIZE - 1 do continue
		if dy < 0 && ly != 0 || dy > 0 && ly != CHUNK_SIZE - 1 do continue
		if dz < 0 && lz != 0 || dz > 0 && lz != CHUNK_SIZE - 1 do continue
		if nk, nok := chunk_neighbor_key(w, key, dx, dy, dz); nok {
			if n := world_chunk(w, nk); n != nil do n.meshed = false
		}
	}
}

// Секции колонки, нужные рядом с игроком на высоте py: полоса поверхности
// в пределах VIEW_BELOW ниже и VIEW_ABOVE выше.
@(private = "file")
column_needed :: proc(col: ^Column, sy, py: i32) -> bool {
	if !column_band_has(col, sy) do return false
	y0 := sy * CHUNK_SIZE
	return y0 + CHUNK_SIZE > py - VIEW_BELOW && y0 <= py + VIEW_ABOVE
}

// Генерирует и строит меши ближайших секций, укладываясь в бюджет времени.
// Возвращает true, если всё в радиусе видимости уже готово.
world_update :: proc(w: ^World, center: [3]f64, budget_sec: f64) -> (all_ready: bool) {
	start := eng.time_now()
	pcx := eng.floor_div(i32(math.floor(center.x)), CHUNK_SIZE)
	pcz := eng.floor_div(i32(math.floor(center.z)), CHUNK_SIZE)
	py := i32(math.floor(center.y))

	all_ready = true
	outer: for off in w.load_order {
		face, gx, gz, ok := world_resolve(w, (pcx + off.x) * CHUNK_SIZE, (pcz + off.y) * CHUNK_SIZE)
		if !ok do continue // пустота у вершины куба
		col, created := ensure_column(w, column_key_of(face, gx, gz))
		if created && eng.time_now() - start > budget_sec {
			all_ready = false
			break
		}
		lo_sy := eng.floor_div(min(col.lo, SEA_LEVEL), CHUNK_SIZE)
		hi_sy := eng.floor_div(max(col.hi, SEA_LEVEL), CHUNK_SIZE)
		covered := false
		done := true
		for sy in lo_sy ..= hi_sy {
			if !column_needed(col, sy, py) do continue
			covered = true
			key := Chunk_Key{col.key.face, col.key.x, sy, col.key.z}
			c, _ := ensure_chunk(w, key)
			if c.meshed && !c.stale do continue
			if !c.meshed do done = false // устаревший меш пока рисуется — дальний рельеф здесь не нужен
			all_ready = false
			// для сетки нужны соседи (AO и грани на границе), в т.ч. через рёбра;
			// вне полосы поверхности сосед сплошной — его строить не нужно
			for dy in i32(-1) ..= 1 do for dz in i32(-1) ..= 1 do for dx in i32(-1) ..= 1 {
				if dx == 0 && dy == 0 && dz == 0 do continue
				nk, nok := chunk_neighbor_key(w, key, dx, dy, dz)
				if !nok do continue
				ncol, ncreated := ensure_column(w, {nk.face, nk.x, nk.z})
				if column_band_has(ncol, nk.y) do ensure_chunk(w, nk)
				if ncreated && eng.time_now() - start > budget_sec do break outer
			}
			chunk_build_mesh(w, c)
			if eng.time_now() - start > budget_sec do break outer
		}
		col.covered = covered && done
	}

	// выгрузка дальних секций и колонок (и тех, чьих граней нет в кадре)
	unload_r := w.view_radius + 3
	to_remove := make([dynamic]Chunk_Key, context.temp_allocator)
	for key in w.chunks {
		fx, fz, placed := frame_pos(w, key.face, key.x, key.z)
		far := !placed || abs(eng.floor_div(fx, CHUNK_SIZE) - pcx) > unload_r || abs(eng.floor_div(fz, CHUNK_SIZE) - pcz) > unload_r
		y0 := key.y * CHUNK_SIZE
		if far || y0 + CHUNK_SIZE < py - VIEW_BELOW - 48 || y0 > py + VIEW_ABOVE + 48 do append(&to_remove, key)
	}
	for key in to_remove {
		chunk_free(w.chunks[key])
		delete_key(&w.chunks, key)
	}
	cols := make([dynamic]Column_Key, context.temp_allocator)
	for key, col in w.columns {
		fx, fz, placed := frame_pos(w, key.face, key.x, key.z)
		if !placed || abs(eng.floor_div(fx, CHUNK_SIZE) - pcx) > unload_r + 1 || abs(eng.floor_div(fz, CHUNK_SIZE) - pcz) > unload_r + 1 {
			append(&cols, key)
		} else if abs(eng.floor_div(fx, CHUNK_SIZE) - pcx) > w.view_radius || abs(eng.floor_div(fz, CHUNK_SIZE) - pcz) > w.view_radius {
			col.covered = false
		}
	}
	for key in cols {
		free(w.columns[key])
		delete_key(&w.columns, key)
	}
	return
}

// Где в кадре лежит середина колонки (для выгрузки).
@(private = "file")
frame_pos :: proc(w: ^World, face: Cube_Face, cx, cz: i32) -> (x, z: i32, ok: bool) {
	m, placed := geo_frame_of(&w.geo, face)
	if !placed do return 0, 0, false
	x, z = xform_cell(m, cx * CHUNK_SIZE + CHUNK_SIZE / 2, cz * CHUNK_SIZE + CHUNK_SIZE / 2)
	return x, z, true
}

// Коробки столкновений блока (мировые координаты кадра): целый куб или, у
// тонкого ствола и ветви, столбик 25 см посередине. Незагруженное — целый куб.
block_boxes :: proc(w: ^World, x, y, z: i32) -> (boxes: [5][2][3]f64, n: int) {
	b, loaded := world_get_block(w, x, y, z)
	o := [3]f64{f64(x), f64(y), f64(z)}
	if loaded && BLOCK_INFO[b].render == .Post {
		boxes[0] = {o + {POST_LO, 0, POST_LO} / 16.0, o + {POST_HI, 16, POST_HI} / 16.0}
		return boxes, 1
	}
	if loaded && !BLOCK_INFO[b].solid do return
	boxes[0] = {o, o + 1}
	return boxes, 1
}
