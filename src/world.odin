package main

// Мир из чанков 16x128x16, подгружаемых вокруг игрока.
//
// Чанк принадлежит грани куба-планеты и лежит в её собственной сетке
// (ключ — грань + координаты чанка на ней). Игра идёт в "кадре" текущей
// грани: координаты x, z — её сетка, продолженная через рёбра на соседние
// грани (их сетка повёрнута на 90°·k). За двумя рёбрами сразу (у вершины
// куба) — пустота, её закрывает столп-аномалия.

import "core:math"
import "core:slice"
import eng "engine"

CHUNK_SIZE :: 16
CHUNK_HEIGHT :: 128
CHUNK_AREA :: CHUNK_SIZE * CHUNK_SIZE
CHUNK_VOLUME :: CHUNK_AREA * CHUNK_HEIGHT
SEA_LEVEL :: 62

Chunk_Key :: struct {
	face: Cube_Face,
	x, z: i32, // координаты чанка в сетке своей грани
}

Chunk :: struct {
	key:          Chunk_Key,
	blocks:       [CHUNK_VOLUME]Block,
	// Для каждой колонки — первая высота, куда достаёт небесный свет.
	light_height: [CHUNK_AREA]u8,
	max_y:        i32, // самый высокий непустой блок
	meshed:       bool,
	opaque_mesh:  Chunk_Mesh,
	water_mesh:   Chunk_Mesh,
}

World :: struct {
	seed:        u32,
	geo:         Planet_Geo, // планета и грань, на которой идёт игра
	chunks:      map[Chunk_Key]^Chunk,
	view_radius: i32,
	load_order:  [dynamic][2]i32, // смещения чанков, отсортированные по расстоянию
	// Изменения мира поверх генерации — переживают выгрузку чанков
	// (пока только до выхода из игры: сохранения ещё нет).
	edits:       map[Chunk_Key][dynamic]Block_Edit,
}

Block_Edit :: struct {
	index: i32,
	block: Block,
}

block_index :: #force_inline proc "contextless" (x, y, z: i32) -> i32 {
	return (y * CHUNK_SIZE + z) * CHUNK_SIZE + x
}

world_init :: proc(w: ^World, seed: u32, view_radius: i32, geo: Planet_Geo) {
	w.seed = seed
	w.geo = geo
	w.view_radius = view_radius
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

world_destroy :: proc(w: ^World) {
	for _, c in w.chunks {
		chunk_mesh_free(&c.opaque_mesh)
		chunk_mesh_free(&c.water_mesh)
		free(c)
	}
	delete(w.chunks)
	delete(w.load_order)
	for _, list in w.edits do delete(list)
	delete(w.edits)
}

// Клетка кадра -> грань, клетка на ней (ok = false — пустота у вершины куба).
world_resolve :: proc(w: ^World, x, z: i32) -> (face: Cube_Face, gx, gz: i32, ok: bool) {
	return geo_resolve(&w.geo, w.geo.face, x, z)
}

chunk_key_of :: proc(face: Cube_Face, gx, gz: i32) -> Chunk_Key {
	return {face, eng.floor_div(gx, CHUNK_SIZE), eng.floor_div(gz, CHUNK_SIZE)}
}

world_chunk :: proc(w: ^World, key: Chunk_Key) -> ^Chunk {
	return w.chunks[key] or_else nil
}

// Чанк кадра (координаты чанка в кадре текущей грани).
world_frame_chunk :: proc(w: ^World, fcx, fcz: i32) -> ^Chunk {
	face, gx, gz, ok := world_resolve(w, fcx * CHUNK_SIZE, fcz * CHUNK_SIZE)
	if !ok do return nil
	return world_chunk(w, chunk_key_of(face, gx, gz))
}

// Блок в мировой (глобальной) клетке грани face.
global_get_block :: proc(w: ^World, face: Cube_Face, gx, y, gz: i32) -> (b: Block, loaded: bool) {
	c := world_chunk(w, chunk_key_of(face, gx, gz))
	if c == nil do return .Air, false
	return c.blocks[block_index(eng.floor_mod(gx, CHUNK_SIZE), y, eng.floor_mod(gz, CHUNK_SIZE))], true
}

// Блок в координатах кадра. Пустота у вершины куба — непроходимый столп.
world_get_block :: proc(w: ^World, x, y, z: i32) -> (b: Block, loaded: bool) {
	if y < 0 do return .Bedrock, true
	if y >= CHUNK_HEIGHT do return .Air, true
	face, gx, gz, ok := world_resolve(w, x, z)
	if !ok do return .Monolith, true
	return global_get_block(w, face, gx, y, gz)
}

// Незагруженные чанки считаются твёрдыми, чтобы игрок не провалился.
world_is_solid :: proc(w: ^World, x, y, z: i32) -> bool {
	b, loaded := world_get_block(w, x, y, z)
	if !loaded do return true
	return BLOCK_INFO[b].solid
}

// Яркость неба в точке: 1 — открыто небу, SHADOW_LIGHT — в тени.
world_sky_light :: proc(w: ^World, x, y, z: i32) -> f32 {
	if y >= CHUNK_HEIGHT do return 1
	face, gx, gz, ok := world_resolve(w, x, z)
	if !ok do return 1
	c := world_chunk(w, chunk_key_of(face, gx, gz))
	if c == nil do return 1
	lx := eng.floor_mod(gx, CHUNK_SIZE)
	lz := eng.floor_mod(gz, CHUNK_SIZE)
	return y >= i32(c.light_height[lz * CHUNK_SIZE + lx]) ? 1 : SHADOW_LIGHT
}

@(private = "file")
ensure_chunk :: proc(w: ^World, key: Chunk_Key) -> (c: ^Chunk, created: bool) {
	if existing, ok := w.chunks[key]; ok do return existing, false
	c = new(Chunk)
	c.key = key
	generate_chunk(w, c)
	if list, ok := w.edits[key]; ok {
		for e in list do c.blocks[e.index] = e.block
		chunk_update_light(c)
	}
	w.chunks[key] = c
	return c, true
}

// Соседний чанк (dx, dz) в сетке грани чанка; через ребро — на другой грани.
chunk_neighbor_key :: proc(w: ^World, key: Chunk_Key, dx, dz: i32) -> (Chunk_Key, bool) {
	x := (key.x + dx) * CHUNK_SIZE + CHUNK_SIZE / 2
	z := (key.z + dz) * CHUNK_SIZE + CHUNK_SIZE / 2
	face, gx, gz, ok := geo_resolve(&w.geo, key.face, x, z)
	if !ok do return {}, false
	return chunk_key_of(face, gx, gz), true
}

// Меняет блок (координаты кадра), запоминает изменение и помечает чанки на
// перестройку сетки.
world_set_block :: proc(w: ^World, x, y, z: i32, b: Block) {
	if y < 0 || y >= CHUNK_HEIGHT do return
	face, gx, gz, ok := world_resolve(w, x, z)
	if !ok do return
	key := chunk_key_of(face, gx, gz)
	lx := eng.floor_mod(gx, CHUNK_SIZE)
	lz := eng.floor_mod(gz, CHUNK_SIZE)
	idx := block_index(lx, y, lz)
	if c := world_chunk(w, key); c != nil && c.blocks[idx] == .Monolith do return // столп неразрушим

	list := w.edits[key]
	append(&list, Block_Edit{idx, b})
	w.edits[key] = list

	c := world_chunk(w, key)
	if c == nil do return
	c.blocks[idx] = b
	chunk_update_light(c)
	// соседям тоже: их AO и грани на границе зависят от этого блока
	for dz in i32(-1) ..= 1 do for dx in i32(-1) ..= 1 {
		if dx < 0 && lx != 0 || dx > 0 && lx != CHUNK_SIZE - 1 do continue
		if dz < 0 && lz != 0 || dz > 0 && lz != CHUNK_SIZE - 1 do continue
		if nk, nok := chunk_neighbor_key(w, key, dx, dz); nok {
			if n := world_chunk(w, nk); n != nil do n.meshed = false
		}
	}
}

// Генерирует и строит меши ближайших чанков, укладываясь в бюджет времени.
// Возвращает true, если всё в радиусе видимости уже готово.
world_update :: proc(w: ^World, center: [3]f64, budget_sec: f64) -> (all_ready: bool) {
	start := eng.time_now()
	pcx := eng.floor_div(i32(math.floor(center.x)), CHUNK_SIZE)
	pcz := eng.floor_div(i32(math.floor(center.z)), CHUNK_SIZE)

	all_ready = true
	outer: for off in w.load_order {
		face, gx, gz, ok := world_resolve(w, (pcx + off.x) * CHUNK_SIZE, (pcz + off.y) * CHUNK_SIZE)
		if !ok do continue // пустота у вершины куба
		key := chunk_key_of(face, gx, gz)
		c, _ := ensure_chunk(w, key)
		if c.meshed do continue
		all_ready = false
		// для сетки нужны все 8 соседей (AO и грани на границе), в т.ч. через рёбра
		for dz in i32(-1) ..= 1 do for dx in i32(-1) ..= 1 {
			if dx == 0 && dz == 0 do continue
			nk, nok := chunk_neighbor_key(w, key, dx, dz)
			if !nok do continue
			if _, created := ensure_chunk(w, nk); created {
				if eng.time_now() - start > budget_sec do break outer
			}
		}
		chunk_build_mesh(w, c)
		if eng.time_now() - start > budget_sec do break
	}

	// выгрузка дальних чанков (и чанков граней, которых нет в кадре)
	unload_r := w.view_radius + 3
	to_remove := make([dynamic]Chunk_Key, context.temp_allocator)
	for key in w.chunks {
		fx, fz, placed := chunk_frame_pos(w, key)
		if !placed || abs(eng.floor_div(fx, CHUNK_SIZE) - pcx) > unload_r || abs(eng.floor_div(fz, CHUNK_SIZE) - pcz) > unload_r {
			append(&to_remove, key)
		}
	}
	for key in to_remove {
		c := w.chunks[key]
		chunk_mesh_free(&c.opaque_mesh)
		chunk_mesh_free(&c.water_mesh)
		free(c)
		delete_key(&w.chunks, key)
	}
	return
}

// Где в кадре лежит первая клетка чанка (для выгрузки).
@(private = "file")
chunk_frame_pos :: proc(w: ^World, key: Chunk_Key) -> (x, z: i32, ok: bool) {
	m, placed := geo_frame_of(&w.geo, key.face)
	if !placed do return 0, 0, false
	x, z = xform_cell(m, key.x * CHUNK_SIZE + CHUNK_SIZE / 2, key.z * CHUNK_SIZE + CHUNK_SIZE / 2)
	return x, z, true
}
