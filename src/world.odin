package main

// Мир из чанков 16x128x16, подгружаемых вокруг игрока.

import "core:math"
import "core:slice"
import eng "engine"

CHUNK_SIZE :: 16
CHUNK_HEIGHT :: 128
CHUNK_AREA :: CHUNK_SIZE * CHUNK_SIZE
CHUNK_VOLUME :: CHUNK_AREA * CHUNK_HEIGHT
SEA_LEVEL :: 62

Chunk_Key :: [2]i32

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
	load_order:  [dynamic]Chunk_Key, // смещения чанков, отсортированные по расстоянию
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
			append(&w.load_order, Chunk_Key{dx, dz})
		}
	}
	slice.sort_by(w.load_order[:], proc(a, b: Chunk_Key) -> bool {
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

world_get_chunk :: proc(w: ^World, cx, cz: i32) -> ^Chunk {
	return w.chunks[{cx, cz}] or_else nil
}

world_get_block :: proc(w: ^World, x, y, z: i32) -> (b: Block, loaded: bool) {
	if y < 0 do return .Bedrock, true
	if y >= CHUNK_HEIGHT do return .Air, true
	c := world_get_chunk(w, eng.floor_div(x, CHUNK_SIZE), eng.floor_div(z, CHUNK_SIZE))
	if c == nil do return .Air, false
	lx := eng.floor_mod(x, CHUNK_SIZE)
	lz := eng.floor_mod(z, CHUNK_SIZE)
	return c.blocks[block_index(lx, y, lz)], true
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
	c := world_get_chunk(w, eng.floor_div(x, CHUNK_SIZE), eng.floor_div(z, CHUNK_SIZE))
	if c == nil do return 1
	lx := eng.floor_mod(x, CHUNK_SIZE)
	lz := eng.floor_mod(z, CHUNK_SIZE)
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

// Меняет блок, запоминает изменение и помечает чанки на перестройку сетки.
world_set_block :: proc(w: ^World, x, y, z: i32, b: Block) {
	if y < 0 || y >= CHUNK_HEIGHT do return
	key := Chunk_Key{eng.floor_div(x, CHUNK_SIZE), eng.floor_div(z, CHUNK_SIZE)}
	lx := eng.floor_mod(x, CHUNK_SIZE)
	lz := eng.floor_mod(z, CHUNK_SIZE)
	idx := block_index(lx, y, lz)

	list := w.edits[key]
	append(&list, Block_Edit{idx, b})
	w.edits[key] = list

	c := world_get_chunk(w, key.x, key.y)
	if c == nil do return
	c.blocks[idx] = b
	chunk_update_light(c)
	// соседям тоже: их AO и грани на границе зависят от этого блока
	for dz in i32(-1) ..= 1 do for dx in i32(-1) ..= 1 {
		if dx < 0 && lx != 0 || dx > 0 && lx != CHUNK_SIZE - 1 do continue
		if dz < 0 && lz != 0 || dz > 0 && lz != CHUNK_SIZE - 1 do continue
		if n := world_get_chunk(w, key.x + dx, key.y + dz); n != nil do n.meshed = false
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
		key := Chunk_Key{pcx + off.x, pcz + off.y}
		c, _ := ensure_chunk(w, key)
		if c.meshed do continue
		all_ready = false
		// для сетки нужны все 8 соседей (AO и грани на границе)
		for dz in i32(-1) ..= 1 do for dx in i32(-1) ..= 1 {
			if dx == 0 && dz == 0 do continue
			if _, created := ensure_chunk(w, key + Chunk_Key{dx, dz}); created {
				if eng.time_now() - start > budget_sec do break outer
			}
		}
		chunk_build_mesh(w, c)
		if eng.time_now() - start > budget_sec do break
	}

	// выгрузка дальних чанков
	unload_r := w.view_radius + 3
	to_remove := make([dynamic]Chunk_Key, context.temp_allocator)
	for key in w.chunks {
		if abs(key.x - pcx) > unload_r || abs(key.y - pcz) > unload_r {
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
