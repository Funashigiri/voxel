package main

// Генерация мира: колонки (высоты, поверхность, деревья, свет неба, слои
// пород) и секции 16×16×16 по ним. Рельеф — relief.odin.
// Шум берётся в точке на шаре планеты (3D), а не на плоскости, поэтому рельеф
// один и тот же, смотришь ли ты на него с земли или с орбиты.
// Всё детерминировано от (seed, точки), поэтому деревья на границах
// секций и колонок совпадают без обмена данными.

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

// Тот же шум, но без октав мельче клетки cell (м): их вклад заменён средним —
// нулём. Для дальнего рельефа: тот же рельеф, только без деталей, которые с
// такого расстояния всё равно не видны (и не мерцают). Нормировка прежняя.
fbm_lod :: proc(seed: i64, p: [3]f64, scale: f64, octaves: int, cell: f64) -> f32 {
	sum, amp, norm: f32 = 0, 1, 0
	freq := 1 / scale
	wave := scale
	for i in 0 ..< octaves {
		// длина волны больше 3 клеток — целиком, меньше 2 — нет
		if w := f32(clamp(wave / cell - 2, 0, 1)); w > 0 {
			sum += noise.noise_3d_improve_xz(seed + i64(i) * 7919, p * freq) * amp * w
		}
		norm += amp
		amp *= 0.5
		freq *= 2
		wave *= 0.5
	}
	return sum / norm
}

// Самопроверка рельефа: среднее (1 − |шум|)² одной октавы, расхождение
// дальнего рельефа (клетка 1,5 м) с верхом блоков, доля океана, крайние высоты.
far_selftest :: proc(seed: u32, g: ^Planet_Geo) -> (ridge_mean, diff_mean, diff_max, ocean, h_lo, h_hi: f64) {
	r := eng.rng_make(u64(seed) + 4242)
	N :: 4000
	s := i64(seed)
	h_lo, h_hi = 1e9, -1e9
	for _ in 0 ..< N {
		d := [3]f64{eng.rng_range(&r, -1, 1), eng.rng_range(&r, -1, 1), eng.rng_range(&r, -1, 1)}
		d /= math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
		p := d * g.radius
		n := 1 - abs(f64(noise.noise_3d_improve_xz(s + 41, p / 110)))
		ridge_mean += n * n
		th := terrain_height(s, p)
		diff := abs(terrain_height_lod(s, p, 1.5) + 0.5 - f64(th + 1))
		diff_mean += diff
		diff_max = max(diff_max, diff)
		e := f64(th) + 1 - Y_SEA
		if th < SEA_LEVEL do ocean += 1
		h_lo = min(h_lo, e)
		h_hi = max(h_hi, e)
	}
	return ridge_mean / N, diff_mean / N, diff_max, ocean / N, h_lo, h_hi
}

surface_for :: proc(seed: i64, p: [3]f64, h, slope: i32) -> (surface, filler: Block) {
	if h < SEA_LEVEL - 1 {
		n := fbm(seed + 131, p, 24, 2)
		if h >= SEA_LEVEL - 4 || n > 0.25 do return .Sand, .Sand
		if n < -0.2 do return .Gravel, .Gravel
		return .Dirt, .Dirt
	}
	if h <= SEA_LEVEL + 1 do return .Sand, .Sand
	// круто или выше границы скал — почвы нет, наружу выходят пласты (.Stone — метка, см. column_block)
	if slope >= 3 || f64(h) + 1 - Y_SEA >= rock_line(seed, p, 0.5) do return .Stone, .Stone
	return .Grass, .Dirt
}

PAD :: 3
@(private = "file")
N :: CHUNK_SIZE + 2 * PAD

MONOLITH_RADIUS :: 7.0 // столп в вершине куба-планеты

// Расстояние от центра колонки до ближайшей вершины куба (угла грани).
corner_dist :: proc(n, x, z: i32) -> f64 {
	cx: f64 = x < n / 2 ? 0 : f64(n)
	cz: f64 = z < n / 2 ? 0 : f64(n)
	dx, dz := f64(x) + 0.5 - cx, f64(z) + 0.5 - cz
	return math.sqrt(dx * dx + dz * dz)
}

@(private = "file")
smooth :: proc(e0, e1, x: f64) -> f64 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}

// Колонка: высоты с запасом PAD вокруг (уклоны, деревья соседей), поверхность,
// деревья, свет неба, полоса поверхности и слои пород.
generate_column :: proc(w: ^World, col: ^Column) {
	seed := i64(w.seed)
	useed := w.seed
	face := col.key.face
	n := w.geo.n
	x0 := col.key.x * CHUNK_SIZE
	z0 := col.key.z * CHUNK_SIZE

	points: [N * N][3]f64
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

	// столп в вершине куба — над землёй у вершины
	corner, _ := nearest_anomaly(points[(PAD + 8) * N + PAD + 8] / w.geo.radius)
	pillar_top := anomaly_ground(w.seed, w.geo.radius, corner) + MONOLITH_ABOVE

	col.lo, col.hi = max(i32), min(i32)
	for lz in 0 ..< i32(CHUNK_SIZE) do for lx in 0 ..< i32(CHUNK_SIZE) {
		i := int(lz * CHUNK_SIZE + lx)
		pi, pj := int(lx) + PAD, int(lz) + PAD
		h := heights[pj * N + pi]
		col.points[i] = points[pj * N + pi]
		if corner_dist(n, x0 + lx, z0 + lz) < MONOLITH_RADIUS {
			col.monolith[i] = true
			col.height[i] = pillar_top
			col.surface[i], col.filler[i] = .Monolith, .Monolith
		} else {
			col.height[i] = h
			col.surface[i], col.filler[i] = surface_for(seed, col.points[i], h, slope_at(&heights, pi, pj))
		}
		col.sky[i] = col.height[i] + 1
		if col.height[i] < SEA_LEVEL {
			col.water = true
			col.sky[i] = SEA_LEVEL + 1 // вода гасит свет неба
		}
		col.lo = min(col.lo, col.height[i] - 4)
		col.hi = max(col.hi, col.height[i] + 1) // +1 — трава и цветы
	}

	// деревья (в том числе из соседних колонок, чья листва заходит сюда)
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
		h := heights[j * N + i]
		if eng.hash2f(gx, gz, useed + 501) > forest_density(seed, tp, f64(h) + 1 - Y_SEA) do continue
		slope := slope_at(&heights, i, j)
		surface, _ := surface_for(seed, tp, h, slope)
		if surface != .Grass || slope > 2 do continue
		if col.tree_n >= MAX_COL_TREES do break
		birch := fbm(seed + 99, tp, 160, 2) > 0.2 || eng.hash2f(gx, gz, useed + 502) < 0.12
		height := i32(4 + (hsh >> 16) % 3) + (birch ? 1 : 0)
		col.trees[col.tree_n] = {tx, tz, h + 1, height, birch}
		col.tree_n += 1
	}
	// свет неба и полоса поверхности — с листвой и стволами
	for t in col.trees[:col.tree_n] {
		tree_blocks(t, useed, col, proc(col: ^Column, wx, y, wz: i32, b: Block, x0, z0: i32) {
			lx, lz := wx - x0, wz - z0
			if lx < 0 || lz < 0 || lx >= CHUNK_SIZE || lz >= CHUNK_SIZE do return
			i := lz * CHUNK_SIZE + lx
			col.sky[i] = max(col.sky[i], y + 1)
			col.hi = max(col.hi, y)
		}, x0, z0)
	}

	// недра: осадочные слои (толще в низинах и под морем, тоньше в горах),
	// под ними кора — гранит материков или базальт океанов, глубже — мантия
	alt_c := f64(heights[(PAD + 8) * N + PAD + 8]) + 1 - Y_SEA
	col.oceanic = alt_c < -300
	crust := col.oceanic ? 7000 * relief.depth_k : 35000 * relief.depth_k + 5.6 * max(alt_c, 0)
	col.moho = SEA_LEVEL - i32(crust)
	// толщина и сдвиг слоёв — по углам колонки, между ними плавно (без ступенек на стыках)
	corner_sed, corner_warp: [2][2]f64
	for b in 0 ..= 1 do for a in 0 ..= 1 {
		k := (PAD + b * (CHUNK_SIZE - 1)) * N + PAD + a * (CHUNK_SIZE - 1)
		p := points[k]
		alt := f64(heights[k]) + 1 - Y_SEA
		v := 0.5 + 0.5 * f64(fbm(seed + 341, p, 40_000, 2))
		// высокие горы — без осадочных слоёв (смыты): наружу выходит гранит
		corner_sed[b][a] = alt < -300 ? 250 + 150 * v : (30 + 450 * (1 - smooth(200, 1500, alt))) * (0.4 + 0.6 * v) * (1 - smooth(1500, 2500, alt))
		corner_warp[b][a] = f64(fbm(seed + 340, p, 20_000, 2)) * 40
	}
	for lz in 0 ..< CHUNK_SIZE do for lx in 0 ..< CHUNK_SIZE {
		u, v := f64(lx) / (CHUNK_SIZE - 1), f64(lz) / (CHUNK_SIZE - 1)
		bil :: proc(c: [2][2]f64, u, v: f64) -> f64 {
			return (c[0][0] * (1 - u) + c[0][1] * u) * (1 - v) + (c[1][0] * (1 - u) + c[1][1] * u) * v
		}
		col.sed[lz * CHUNK_SIZE + lx] = f32(bil(corner_sed, u, v))
		col.warp[lz * CHUNK_SIZE + lx] = f32(bil(corner_warp, u, v))
	}
}

// Блоки дерева (ствол и листва) — для света неба (колонка) и для секций.
tree_blocks :: proc(t: Tree, seed: u32, data: ^$T, put: proc(data: ^T, wx, y, wz: i32, b: Block, x0, z0: i32), x0, z0: i32) {
	log: Block = t.birch ? .Birch_Log : .Oak_Log
	leaves: Block = t.birch ? .Birch_Leaves : .Oak_Leaves
	for dy in t.height - 3 ..= t.height {
		y := t.base + dy
		r: i32 = dy >= t.height - 1 ? 1 : 2
		for dz in -r ..= r do for dx in -r ..= r {
			if abs(dx) == r && abs(dz) == r {
				if dy == t.height do continue
				if eng.hash3f(t.x + dx, y, t.z + dz, seed + 503) < 0.5 do continue
			}
			put(data, t.x + dx, y, t.z + dz, leaves, x0, z0)
		}
	}
	for dy in 0 ..< t.height do put(data, t.x, t.base + dy, t.z, log, x0, z0)
}

// Порода на глубине: осадочные слои полосами, под ними кора, глубже мантия.
@(private = "file")
strata :: proc(col: ^Column, i: int, y: i32, seed: u32) -> Block {
	depth := f32(col.height[i] - y)
	if depth < col.sed[i] {
		// пласты горизонтальны (слегка наклонены): полосы песчаника и известняка
		band := i32(math.floor((f32(y) + col.warp[i]) / 7))
		return eng.hash2(band, 0, seed + 77) % 3 == 0 ? .Limestone : .Sandstone
	}
	if y < col.moho do return .Peridotite
	return col.oceanic ? .Basalt : .Granite
}

// Блок колонки на высоте y (без деревьев и растений).
column_block :: proc(col: ^Column, i: int, y: i32, seed: u32) -> Block {
	h := col.height[i]
	if y > h do return y <= SEA_LEVEL ? .Water : .Air
	if col.monolith[i] do return .Monolith
	if col.surface[i] == .Stone do return strata(col, i, y, seed) // голая скала: сразу пласты
	if y == h do return col.surface[i]
	if y >= h - 3 do return col.filler[i]
	return strata(col, i, y, seed)
}

@(private = "file")
Section_Gen :: struct {
	c:      ^Chunk,
	y0:     i32,
}

generate_section :: proc(w: ^World, col: ^Column, c: ^Chunk) {
	useed := w.seed
	seed := i64(w.seed)
	y0 := c.key.y * CHUNK_SIZE
	x0 := c.key.x * CHUNK_SIZE
	z0 := c.key.z * CHUNK_SIZE
	c.blocks = new([CHUNK_VOLUME]Block)
	for lz in i32(0) ..< CHUNK_SIZE do for lx in i32(0) ..< CHUNK_SIZE {
		i := int(lz * CHUNK_SIZE + lx)
		for ly in i32(0) ..< CHUNK_SIZE {
			c.blocks[block_index(lx, ly, lz)] = column_block(col, i, y0 + ly, useed)
		}
		// трава и цветы
		h := col.height[i]
		if col.surface[i] != .Grass || h + 1 < y0 || h + 1 >= y0 + CHUNK_SIZE do continue
		wx, wz := x0 + lx, z0 + lz
		p := col.points[i]
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
		if plant != .Air do c.blocks[block_index(lx, h + 1 - y0, lz)] = plant
	}

	// деревья (обрезаны по высоте секции и границам колонки)
	gen := Section_Gen{c, y0}
	for t in col.trees[:col.tree_n] {
		if t.base + t.height < y0 || t.base > y0 + CHUNK_SIZE do continue
		tree_blocks(t, useed, &gen, proc(g: ^Section_Gen, wx, y, wz: i32, b: Block, x0, z0: i32) {
			lx, ly, lz := wx - x0, y - g.y0, wz - z0
			if lx < 0 || lz < 0 || ly < 0 || lx >= CHUNK_SIZE || lz >= CHUNK_SIZE || ly >= CHUNK_SIZE do return
			i := block_index(lx, ly, lz)
			cur := g.c.blocks[i]
			is_log := b == .Oak_Log || b == .Birch_Log
			if cur == .Air || is_plant(cur) || (is_log && BLOCK_INFO[cur].render == .Leaves) do g.c.blocks[i] = b
		}, x0, z0)
		// под деревом трава превращается в землю
		lx, lz := t.x - x0, t.z - z0
		ly := t.base - 1 - y0
		if lx >= 0 && lz >= 0 && lx < CHUNK_SIZE && lz < CHUNK_SIZE && ly >= 0 && ly < CHUNK_SIZE {
			c.blocks[block_index(lx, ly, lz)] = .Dirt
		}
	}

	// однородная секция (воздух, вода, сплошная порода) — без массива
	first := c.blocks[0]
	for b in c.blocks do if b != first do return
	free(c.blocks)
	c.blocks = nil
	c.fill = first
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

// Отладка: самый крутой обрыв в радиусе 3 км от (cx, cz) — встаём у подножия
// в 14 блоках от него и смотрим на него (слои пород в стене).
find_cliff_spawn :: proc(w: ^World, cx, cz: i32) -> (pos: [3]f64, yaw: f32) {
	s := i64(w.seed)
	h_at :: proc(w: ^World, s: i64, x, z: i32) -> i32 {
		return terrain_height(s, geo_point(&w.geo, w.geo.face, x, z))
	}
	best := i32(-1)
	at: [2]i32
	dir: [2]i32
	for dz := i32(-3000); dz <= 3000; dz += 12 do for dx := i32(-3000); dx <= 3000; dx += 12 {
		x, z := cx + dx, cz + dz
		if _, _, _, ok := world_resolve(w, x, z); !ok do continue
		h := h_at(w, s, x, z)
		if h < SEA_LEVEL + 2 || h > SEA_LEVEL + 1500 do continue // до 1,5 км — там пласты осадочных пород
		for d in ([4][2]i32{{8, 0}, {-8, 0}, {0, 8}, {0, -8}}) {
			if diff := h_at(w, s, x + d.x, z + d.y) - h; diff > best {
				best, at, dir = diff, {x, z}, d / 8
			}
		}
	}
	if best < 0 do return find_spawn(w, cx, cz), 0 // обрывов нет — обычная точка
	foot := at - dir * 14
	pos = {f64(foot.x) + 0.5, f64(h_at(w, s, foot.x, foot.y)) + 1, f64(foot.y) + 0.5}
	return pos, f32(math.atan2(-f64(dir.x), f64(dir.y)))
}

// Отладка: самая высокая точка в радиусе 30 км от (cx, cz) — вид с горы.
find_mountain_spawn :: proc(w: ^World, cx, cz: i32) -> [3]f64 {
	best_h := min(i32)
	best: [2]i32 = {cx, cz}
	search :: proc(w: ^World, best: ^[2]i32, best_h: ^i32, cx, cz, r, step: i32) {
		for dz := -r; dz <= r; dz += step do for dx := -r; dx <= r; dx += step {
			if dx * dx + dz * dz > r * r do continue
			if _, _, _, ok := world_resolve(w, cx + dx, cz + dz); !ok do continue
			h := terrain_height(i64(w.seed), geo_point(&w.geo, w.geo.face, cx + dx, cz + dz))
			if h > best_h^ {
				best_h^ = h
				best^ = {cx + dx, cz + dz}
			}
		}
	}
	search(w, &best, &best_h, cx, cz, 30_000, 200)
	// уточняем вершину вокруг лучшей точки
	search(w, &best, &best_h, best.x, best.y, 300, 10)
	search(w, &best, &best_h, best.x, best.y, 16, 1)
	return {f64(best.x) + 0.5, f64(best_h) + 1, f64(best.y) + 0.5}
}
