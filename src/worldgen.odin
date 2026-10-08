package main

// Генерация ландшафта: холмы, горы, пляжи, озёра, леса и трава.
// Шум берётся в точке на шаре планеты (3D), а не на плоскости, поэтому рельеф
// один и тот же, смотришь ли ты на него с земли или с орбиты.
// Всё детерминировано от (seed, точки), поэтому деревья на границах
// чанков совпадают без обмена данными между чанками.

import "core:math"
import "core:math/noise"
import eng "engine"

// Фрактальный шум в точке p (блоки) с размером деталей scale.
fbm :: proc(seed: i64, p: [3]f64, scale: f64, octaves: int) -> f32 {
	sum, amp, norm: f32 = 0, 1, 0
	freq := 1 / scale
	for i in 0 ..< octaves {
		sum += noise.noise_3d_improve_xz(seed + i64(i) * 7919, p * freq) * amp
		norm += amp
		amp *= 0.5
		freq *= 2
	}
	return sum / norm
}

// Крупный рельеф планеты: материки и океаны (тысячи км) и горные пояса (сотни км).
// offset — сдвиг средней высоты (океан — сильно ниже уровня моря),
// belt — насколько здесь горный край (0.3..1).
planet_relief :: proc(seed: i64, p: [3]f64) -> (offset, belt: f32) {
	macro := fbm(seed + 201, p, 1_800_000, 5)
	regional := fbm(seed + 202, p, 160_000, 4)
	land := macro + regional * 0.22 + 0.08
	offset = clamp(land * 70, -38, 12)
	belt = 0.3 + 0.7 * eng.smoothstep(0.05, 0.45, fbm(seed + 203, p, 400_000, 3))
	return
}

// Высота поверхности в точке шара p (блоки от центра планеты).
terrain_height :: proc(seed: i64, p: [3]f64) -> i32 {
	offset, belt := planet_relief(seed, p)
	cont := fbm(seed, p, 600, 3)
	base := 66 + offset + cont * 14
	hills := fbm(seed + 11, p, 140, 4) * (5 + 10 * clamp(cont + 0.3, 0, 1))
	detail := fbm(seed + 23, p, 36, 2) * 1.8
	mask := eng.smoothstep(0.2, 0.6, fbm(seed + 37, p, 420, 2)) * belt
	ridge := 1 - abs(fbm(seed + 41, p, 110, 4))
	mountains := mask * ridge * ridge * 46
	return clamp(i32(math.floor(base + hills + detail + mountains)), 4, CHUNK_HEIGHT - 12)
}

surface_for :: proc(seed: i64, p: [3]f64, h, slope: i32) -> (surface, filler: Block) {
	if h < SEA_LEVEL - 1 {
		n := fbm(seed + 131, p, 24, 2)
		if h >= SEA_LEVEL - 4 || n > 0.25 do return .Sand, .Sand
		if n < -0.2 do return .Gravel, .Gravel
		return .Dirt, .Dirt
	}
	if h <= SEA_LEVEL + 1 do return .Sand, .Sand
	peak := 102 + i32(fbm(seed + 151, p, 30, 2) * 8)
	if slope >= 4 || h >= peak do return .Stone, .Stone
	return .Grass, .Dirt
}

forest_density :: proc(seed: i64, p: [3]f64) -> f32 {
	f := fbm(seed + 88, p, 220, 3)
	return 0.03 + 0.9 * eng.smoothstep(0.02, 0.35, f)
}

PAD :: 3
@(private = "file")
N :: CHUNK_SIZE + 2 * PAD

@(private = "file")
chunk_set :: proc(c: ^Chunk, x0, z0, wx, y, wz: i32, b: Block, force: bool) {
	lx := wx - x0
	lz := wz - z0
	if lx < 0 || lz < 0 || lx >= CHUNK_SIZE || lz >= CHUNK_SIZE || y < 0 || y >= CHUNK_HEIGHT do return
	i := block_index(lx, y, lz)
	cur := c.blocks[i]
	if force {
		if cur == .Air || is_plant(cur) || BLOCK_INFO[cur].render == .Leaves do c.blocks[i] = b
	} else if cur == .Air || is_plant(cur) {
		c.blocks[i] = b
	}
}

@(private = "file")
place_tree :: proc(c: ^Chunk, x0, z0, tx, base, tz: i32, log, leaves: Block, height: i32, seed: u32) {
	for dy in height - 3 ..= height {
		y := base + dy
		r: i32 = dy >= height - 1 ? 1 : 2
		for dz in -r ..= r do for dx in -r ..= r {
			if abs(dx) == r && abs(dz) == r {
				if dy == height do continue
				if eng.hash3f(tx + dx, y, tz + dz, seed) < 0.5 do continue
			}
			chunk_set(c, x0, z0, tx + dx, y, tz + dz, leaves, false)
		}
	}
	for dy in 0 ..< height {
		chunk_set(c, x0, z0, tx, base + dy, tz, log, true)
	}
	// под деревом трава превращается в землю
	lx, lz := tx - x0, tz - z0
	if lx >= 0 && lz >= 0 && lx < CHUNK_SIZE && lz < CHUNK_SIZE {
		c.blocks[block_index(lx, base - 1, lz)] = .Dirt
	}
}

MONOLITH_RADIUS :: 7.0 // столп в вершине куба-планеты

// Расстояние от центра колонки до ближайшей вершины куба (угла грани).
corner_dist :: proc(n, x, z: i32) -> f64 {
	cx: f64 = x < n / 2 ? 0 : f64(n)
	cz: f64 = z < n / 2 ? 0 : f64(n)
	dx, dz := f64(x) + 0.5 - cx, f64(z) + 0.5 - cz
	return math.sqrt(dx * dx + dz * dz)
}

generate_chunk :: proc(w: ^World, c: ^Chunk) {
	seed := i64(w.seed)
	useed := w.seed
	face := c.key.face
	n := w.geo.n
	x0 := c.key.x * CHUNK_SIZE
	z0 := c.key.z * CHUNK_SIZE

	points: [N * N][3]f64 // точки шара для колонок (с запасом PAD вокруг чанка)
	heights: [N * N]i32
	for j in 0 ..< N do for i in 0 ..< N {
		points[j * N + i] = geo_point(&w.geo, face, x0 + i32(i) - PAD, z0 + i32(j) - PAD)
		heights[j * N + i] = terrain_height(seed, points[j * N + i])
	}
	slope_at :: proc(heights: ^[N * N]i32, i, j: int) -> i32 {
		h := heights[j * N + i]
		s := abs(h - heights[j * N + i + 1])
		s = max(s, abs(h - heights[j * N + i - 1]))
		s = max(s, abs(h - heights[(j + 1) * N + i]))
		s = max(s, abs(h - heights[(j - 1) * N + i]))
		return s
	}

	// колонки
	for lz in 0 ..< i32(CHUNK_SIZE) do for lx in 0 ..< i32(CHUNK_SIZE) {
		i := int(lx) + PAD
		j := int(lz) + PAD
		wx, wz := x0 + lx, z0 + lz
		if corner_dist(n, wx, wz) < MONOLITH_RADIUS {
			// вершина куба: столп сквозь всю планету
			for y in i32(0) ..< CHUNK_HEIGHT do c.blocks[block_index(lx, y, lz)] = .Monolith
			continue
		}
		p := points[j * N + i]
		h := heights[j * N + i]
		surface, filler := surface_for(seed, p, h, slope_at(&heights, i, j))
		for y in 0 ..= h {
			b := Block.Stone
			if y == 0 {
				b = .Bedrock
			} else if y < 4 && eng.hash3f(wx, y, wz, useed ~ 0xBED) < 0.55 - f32(y) * 0.15 {
				b = .Bedrock
			} else if y == h {
				b = surface
			} else if y >= h - 3 {
				b = filler
			}
			c.blocks[block_index(lx, y, lz)] = b
		}
		for y in h + 1 ..= SEA_LEVEL {
			c.blocks[block_index(lx, y, lz)] = .Water
		}

		// трава и цветы
		if surface == .Grass {
			r := eng.hash2f(wx, wz, useed + 101)
			grassy := 0.5 + 0.5 * fbm(seed + 55, p, 48, 2)
			plant := Block.Air
			if r < 0.03 + 0.32 * grassy {
				plant = .Tall_Grass
			} else {
				patch := fbm(seed + 66, p, 20, 1)
				f := eng.hash2f(wx, wz, useed + 102)
				if (patch > 0.55 && f < 0.12) || f < 0.003 {
					plant = fbm(seed + 77, p, 60, 1) > 0 ? .Dandelion : .Poppy
				}
			}
			if plant != .Air do c.blocks[block_index(lx, h + 1, lz)] = plant
		}
	}

	// деревья (в том числе из соседних чанков, чья листва заходит сюда)
	TREE_CELL :: 5
	gx0 := eng.floor_div(x0 - PAD, TREE_CELL)
	gx1 := eng.floor_div(x0 + CHUNK_SIZE + PAD - 1, TREE_CELL)
	gz0 := eng.floor_div(z0 - PAD, TREE_CELL)
	gz1 := eng.floor_div(z0 + CHUNK_SIZE + PAD - 1, TREE_CELL)
	for gz in gz0 ..= gz1 do for gx in gx0 ..= gx1 {
		hsh := eng.hash2(gx, gz, useed + 500)
		tx := gx * TREE_CELL + 1 + i32(hsh % 3)
		tz := gz * TREE_CELL + 1 + i32((hsh >> 8) % 3)
		i := int(tx - (x0 - PAD))
		j := int(tz - (z0 - PAD))
		if i < 1 || j < 1 || i >= N - 1 || j >= N - 1 do continue
		// деревья целиком внутри грани (не режутся на стыке) и не у столпа
		if tx < 3 || tz < 3 || tx > n - 4 || tz > n - 4 do continue
		if corner_dist(n, tx, tz) < MONOLITH_RADIUS + 4 do continue
		tp := points[j * N + i]
		if eng.hash2f(gx, gz, useed + 501) > forest_density(seed, tp) do continue
		h := heights[j * N + i]
		slope := slope_at(&heights, i, j)
		surface, _ := surface_for(seed, tp, h, slope)
		if surface != .Grass || slope > 2 do continue

		birch := fbm(seed + 99, tp, 160, 2) > 0.2 || eng.hash2f(gx, gz, useed + 502) < 0.12
		height := i32(4 + (hsh >> 16) % 3)
		if birch {
			place_tree(c, x0, z0, tx, h + 1, tz, .Birch_Log, .Birch_Leaves, height + 1, useed + 503)
		} else {
			place_tree(c, x0, z0, tx, h + 1, tz, .Oak_Log, .Oak_Leaves, height, useed + 503)
		}
	}

	chunk_update_light(c)
}

// Карта высот для небесного света + верхняя граница непустых блоков.
chunk_update_light :: proc(c: ^Chunk) {
	c.max_y = 0
	for lz in 0 ..< i32(CHUNK_SIZE) do for lx in 0 ..< i32(CHUNK_SIZE) {
		lh: i32 = 0
		top: i32 = 0
		for y := i32(CHUNK_HEIGHT - 1); y >= 0; y -= 1 {
			b := c.blocks[block_index(lx, y, lz)]
			if b == .Air do continue
			if top == 0 do top = y
			if BLOCK_INFO[b].blocks_light {
				lh = y + 1
				break
			}
		}
		c.light_height[lz * CHUNK_SIZE + lx] = u8(lh)
		c.max_y = max(c.max_y, top)
	}
}

// Высота и уклон колонки (для поиска места появления).
@(private = "file")
column_at :: proc(w: ^World, x, z: i32) -> (h, slope: i32, p: [3]f64) {
	s := i64(w.seed)
	p = geo_point(&w.geo, w.geo.face, x, z)
	h = terrain_height(s, p)
	for d in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
		slope = max(slope, abs(h - terrain_height(s, geo_point(&w.geo, w.geo.face, x + d.x, z + d.y))))
	}
	return
}

// Ищет точку на траве недалеко от (cx, cz) текущей грани.
find_spawn :: proc(w: ^World, cx, cz: i32) -> [3]f64 {
	for r := i32(0); r < 400; r += 4 {
		for dz := -r; dz <= r; dz += 4 {
			for dx := -r; dx <= r; dx += 4 {
				if max(abs(dx), abs(dz)) != r do continue
				x, z := cx + dx, cz + dz
				if _, _, _, ok := world_resolve(w, x, z); !ok do continue // пустота у вершины
				if corner_dist(w.geo.n, x, z) < MONOLITH_RADIUS + 2 do continue
				h, slope, p := column_at(w, x, z)
				if h <= SEA_LEVEL + 2 do continue
				surface, _ := surface_for(i64(w.seed), p, h, slope)
				if surface == .Grass do return {f64(x) + 0.5, f64(h) + 1, f64(z) + 0.5}
			}
		}
	}
	h, _, _ := column_at(w, cx, cz)
	return {f64(cx) + 0.5, f64(h) + 1, f64(cz) + 0.5}
}

// Отладка: ровно в колонке (x, z) — на суше или на воде.
spawn_at :: proc(w: ^World, x, z: i32) -> [3]f64 {
	h, _, _ := column_at(w, x, z)
	if h < SEA_LEVEL do return {f64(x) + 0.5, SEA_LEVEL - 0.4, f64(z) + 0.5}
	return {f64(x) + 0.5, f64(h) + 1, f64(z) + 0.5}
}

// Отладка: точка над глубокой водой недалеко от (cx, cz).
find_water_spawn :: proc(w: ^World, cx, cz: i32) -> [3]f64 {
	for r := i32(0); r < 1200; r += 4 {
		for dz := -r; dz <= r; dz += 4 {
			for dx := -r; dx <= r; dx += 4 {
				if max(abs(dx), abs(dz)) != r do continue
				if terrain_height(i64(w.seed), geo_point(&w.geo, w.geo.face, cx + dx, cz + dz)) < SEA_LEVEL - 5 {
					return {f64(cx + dx) + 0.5, SEA_LEVEL - 0.4, f64(cz + dz) + 0.5}
				}
			}
		}
	}
	return find_spawn(w, cx, cz)
}

// Отладка: точка в горах недалеко от (cx, cz) — для проверки посадки на склоны.
find_mountain_spawn :: proc(w: ^World, cx, cz: i32) -> [3]f64 {
	for r := i32(0); r < 2000; r += 6 {
		for dz := -r; dz <= r; dz += 6 {
			for dx := -r; dx <= r; dx += 6 {
				if max(abs(dx), abs(dz)) != r do continue
				h := terrain_height(i64(w.seed), geo_point(&w.geo, w.geo.face, cx + dx, cz + dz))
				if h >= 92 do return {f64(cx + dx) + 0.5, f64(h) + 1, f64(cz + dz) + 0.5}
			}
		}
	}
	return find_spawn(w, cx, cz)
}
