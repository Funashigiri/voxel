package main

// Генерация ландшафта: холмы, горы, пляжи, озёра, леса и трава.
// Всё детерминировано от (seed, x, z), поэтому деревья на границах
// чанков совпадают без обмена данными между чанками.

import "core:math"
import "core:math/noise"
import eng "engine"

@(private = "file")
fbm :: proc(seed: i64, x, z: f64, octaves: int) -> f32 {
	sum, amp, norm: f32 = 0, 1, 0
	freq: f64 = 1
	for i in 0 ..< octaves {
		sum += noise.noise_2d(seed + i64(i) * 7919, {x * freq, z * freq}) * amp
		norm += amp
		amp *= 0.5
		freq *= 2
	}
	return sum / norm
}

terrain_height :: proc(seed: i64, x, z: f64) -> i32 {
	cont := fbm(seed, x / 600, z / 600, 3)
	base := 66 + cont * 14
	hills := fbm(seed + 11, x / 140, z / 140, 4) * (5 + 10 * clamp(cont + 0.3, 0, 1))
	detail := fbm(seed + 23, x / 36, z / 36, 2) * 1.8
	mask := eng.smoothstep(0.2, 0.6, fbm(seed + 37, x / 420, z / 420, 2))
	ridge := 1 - abs(fbm(seed + 41, x / 110, z / 110, 4))
	mountains := mask * ridge * ridge * 50
	return clamp(i32(math.floor(base + hills + detail + mountains)), 4, CHUNK_HEIGHT - 12)
}

@(private = "file")
surface_for :: proc(seed: i64, wx, wz, h, slope: i32) -> (surface, filler: Block) {
	if h < SEA_LEVEL - 1 {
		n := fbm(seed + 131, f64(wx) / 24, f64(wz) / 24, 2)
		if h >= SEA_LEVEL - 4 || n > 0.25 do return .Sand, .Sand
		if n < -0.2 do return .Gravel, .Gravel
		return .Dirt, .Dirt
	}
	if h <= SEA_LEVEL + 1 do return .Sand, .Sand
	peak := 102 + i32(fbm(seed + 151, f64(wx) / 30, f64(wz) / 30, 2) * 8)
	if slope >= 4 || h >= peak do return .Stone, .Stone
	return .Grass, .Dirt
}

@(private = "file")
forest_density :: proc(seed: i64, wx, wz: i32) -> f32 {
	f := fbm(seed + 88, f64(wx) / 220, f64(wz) / 220, 3)
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

generate_chunk :: proc(w: ^World, c: ^Chunk) {
	seed := i64(w.seed)
	useed := w.seed
	x0 := c.key.x * CHUNK_SIZE
	z0 := c.key.y * CHUNK_SIZE

	heights: [N * N]i32
	for j in 0 ..< N do for i in 0 ..< N {
		heights[j * N + i] = terrain_height(seed, f64(x0 + i32(i) - PAD), f64(z0 + i32(j) - PAD))
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
		h := heights[j * N + i]
		surface, filler := surface_for(seed, wx, wz, h, slope_at(&heights, i, j))
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
			grassy := 0.5 + 0.5 * fbm(seed + 55, f64(wx) / 48, f64(wz) / 48, 2)
			plant := Block.Air
			if r < 0.03 + 0.32 * grassy {
				plant = .Tall_Grass
			} else {
				patch := fbm(seed + 66, f64(wx) / 20, f64(wz) / 20, 1)
				f := eng.hash2f(wx, wz, useed + 102)
				if (patch > 0.55 && f < 0.12) || f < 0.003 {
					plant = fbm(seed + 77, f64(wx) / 60, f64(wz) / 60, 1) > 0 ? .Dandelion : .Poppy
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
		if eng.hash2f(gx, gz, useed + 501) > forest_density(seed, tx, tz) do continue
		h := heights[j * N + i]
		slope := slope_at(&heights, i, j)
		surface, _ := surface_for(seed, tx, tz, h, slope)
		if surface != .Grass || slope > 2 do continue

		birch := fbm(seed + 99, f64(tx) / 160, f64(tz) / 160, 2) > 0.2 || eng.hash2f(gx, gz, useed + 502) < 0.12
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

// Ищет точку появления на траве недалеко от (0, 0).
find_spawn :: proc(seed: u32) -> [3]f64 {
	s := i64(seed)
	for r := i32(0); r < 400; r += 4 {
		for dz := -r; dz <= r; dz += 4 {
			for dx := -r; dx <= r; dx += 4 {
				if max(abs(dx), abs(dz)) != r do continue
				h := terrain_height(s, f64(dx), f64(dz))
				if h <= SEA_LEVEL + 2 do continue
				slope: i32 = 0
				slope = max(slope, abs(h - terrain_height(s, f64(dx + 1), f64(dz))))
				slope = max(slope, abs(h - terrain_height(s, f64(dx - 1), f64(dz))))
				slope = max(slope, abs(h - terrain_height(s, f64(dx), f64(dz + 1))))
				slope = max(slope, abs(h - terrain_height(s, f64(dx), f64(dz - 1))))
				surface, _ := surface_for(s, dx, dz, h, slope)
				if surface == .Grass do return {f64(dx) + 0.5, f64(h) + 1, f64(dz) + 0.5}
			}
		}
	}
	return {0.5, f64(terrain_height(s, 0, 0)) + 1, 0.5}
}

// Отладка: точка на поверхности глубокой воды недалеко от (0, 0).
find_water_spawn :: proc(seed: u32) -> [3]f64 {
	s := i64(seed)
	for r := i32(0); r < 600; r += 4 {
		for dz := -r; dz <= r; dz += 4 {
			for dx := -r; dx <= r; dx += 4 {
				if max(abs(dx), abs(dz)) != r do continue
				if terrain_height(s, f64(dx), f64(dz)) < SEA_LEVEL - 5 {
					return {f64(dx) + 0.5, SEA_LEVEL - 0.4, f64(dz) + 0.5}
				}
			}
		}
	}
	return find_spawn(seed)
}
