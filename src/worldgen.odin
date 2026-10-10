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

// Поверхность и подстилка в клетке по климату: ледник — снег на льду, тундра
// — мхи, осыпи и скалы у снеговой линии, пустыни — песок и щебень, сухие
// степи и саванны — с проплешинами земли.
surface_for :: proc(seed: i64, p: [3]f64, h, slope: i32, bc: ^Block_Climate) -> (surface, filler: Block) {
	if h < SEA_LEVEL - 1 {
		n := fbm(seed + 131, p, 24, 2)
		if h >= SEA_LEVEL - 4 || n > 0.25 do return .Sand, .Sand
		if n < -0.2 do return .Gravel, .Gravel
		return .Dirt, .Dirt
	}
	biome := bc.k.biome
	if biome == .Ice_Cap do return .Snow, .Ice // ледник спускается и к самому морю
	if h <= SEA_LEVEL + 1 do return biome == .Tundra ? .Gravel : .Sand, biome == .Tundra ? .Gravel : .Sand
	// круто — почвы нет, наружу выходят пласты (.Stone — метка, см. column_block)
	if slope >= 3 do return .Stone, .Stone
	n := f64(fbm(seed + 135, p, 18, 2))
	#partial switch biome {
	case .Tundra:
		rock := smooth(6, 1, bc.t_max) // ближе к вечным снегам — больше камня
		if n * 0.5 + 0.5 < rock * 0.85 do return .Stone, .Stone
		if n > 0.45 do return .Gravel, .Gravel
	case .Desert_Hot:
		return .Sand, .Sand
	case .Desert_Cold:
		if n > 0.2 do return .Gravel, .Gravel
		if n < -0.35 do return .Dirt, .Dirt
		return .Sand, .Sand
	case .Steppe, .Savanna, .Mediterranean:
		if n > 0.55 do return .Dirt, .Dirt
	}
	return .Grass, .Dirt
}

PAD :: 1 // для уклонов; деревья соседей — по своим клеткам (trees.odin)
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
			bc := block_climate(w, face, x0 + lx, z0 + lz, h < SEA_LEVEL ? -1 : f64(h) + 1 - Y_SEA, col.points[i])
			col.biome[i] = bc.k.biome
			col.tint[i] = bc.tint
			col.surface[i], col.filler[i] = surface_for(seed, col.points[i], h, slope_at(&heights, pi, pj), &bc)
		}
		col.sky[i] = col.height[i] + 1
		if col.height[i] < SEA_LEVEL {
			col.water = true
			col.sky[i] = SEA_LEVEL + 1 // вода гасит свет неба
		}
		col.sky_bare[i] = col.sky[i]
		col.sky_snow[i] = col.sky[i]
		col.lo = min(col.lo, col.height[i] - 4)
		col.hi = max(col.hi, col.height[i] + 1) // +1 — трава и цветы
	}

	// климат в центре колонки — для смены времён года на экране
	{
		cx, cz := col.key.x, col.key.z
		cs := [4]Corner_Climate{corner_climate(w, face, cx, cz), corner_climate(w, face, cx + 1, cz), corner_climate(w, face, cx, cz + 1), corner_climate(w, face, cx + 1, cz + 1)}
		col.clim = cs[0].cp
		col.clim.cont, col.clim.wet = 0, 0
		for c in cs {
			col.clim.cont += c.cp.cont / 4
			col.clim.wet += c.cp.wet / 4
		}
		c := points[(PAD + 8) * N + PAD + 8]
		col.clim.lat = math.to_degrees(math.asin(clamp(c.y / w.geo.radius, -1, 1)))
		col.clim.alt = 0
		col.clim.land = true
	}

	// деревья (в том числе из соседних колонок, чьи ветви заходят сюда), trees.odin
	column_trees(w, col)
	// свет неба и полоса поверхности — с листвой и стволами
	for t in col.trees[:col.tree_n] {
		tree_blocks(t, {x0, min(i32) / 2, z0}, {x0 + CHUNK_SIZE, max(i32) / 2, z0 + CHUNK_SIZE}, col, proc(data: rawptr, x, y, z: i32, b: Block) {
			col := (^Column)(data)
			i := (z - col.key.z * CHUNK_SIZE) * CHUNK_SIZE + (x - col.key.x * CHUNK_SIZE)
			if BLOCK_INFO[b].blocks_light { // тонкий ствол почти не затеняет
				col.sky[i] = max(col.sky[i], y + 1)
				if !deciduous_leaves(b) do col.sky_bare[i] = max(col.sky_bare[i], y + 1)
				if snow_blocker(b) do col.sky_snow[i] = max(col.sky_snow[i], y + 1)
			}
			col.hi = max(col.hi, y)
		})
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

// Порода на глубине: осадочные слои полосами, под ними кора, глубже мантия.
@(private = "file")
strata :: proc(col: ^Column, i: int, y: i32, seed: u32) -> Block {
	depth := f32(col.height[i] - y)
	if depth < col.sed[i] {
		// пласты горизонтальны (слегка наклонены): полосы песчаника и известняка
		band := i32(math.floor((f32(y) + col.warp[i]) / 7))
		return eng.hash2(band, 0, seed + 77) % 3 == 0 ? .Limestone : .Sandstone
	}
	if y < col.moho do return deep_block(y)
	return col.oceanic ? .Basalt : .Granite
}

// Блок колонки на высоте y (без деревьев и растений).
column_block :: proc(col: ^Column, i: int, y: i32, seed: u32) -> Block {
	h := col.height[i]
	if y > h {
		if y == SEA_LEVEL && col.biome[i] == .Sea_Ice do return .Ice // многолетний лёд на море
		return y <= SEA_LEVEL ? .Water : .Air
	}
	if col.monolith[i] do return .Monolith
	if col.surface[i] == .Stone do return strata(col, i, y, seed) // голая скала: сразу пласты
	if y == h do return col.surface[i]
	if y >= h - (col.surface[i] == .Snow ? 12 : 3) do return col.filler[i] // ледник — толща льда
	return strata(col, i, y, seed)
}

@(private = "file")
Section_Gen :: struct {
	c: ^Chunk,
	o: [3]i32, // угол секции в сетке грани
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
		// подлесок тропического леса: кусты и молодые деревца
		h := col.height[i]
		wx, wz := x0 + lx, z0 + lz
		if col.surface[i] == .Grass {
			if tall, bush := undergrowth(useed, wx, wz, col.biome[i]); tall > 0 {
				for dy in 1 ..= tall {
					if h + dy >= y0 && h + dy < y0 + CHUNK_SIZE do c.blocks[block_index(lx, h + dy - y0, lz)] = bush
				}
				continue
			}
		}
		// трава, цветы, сухие кусты — по природной зоне
		if h + 1 < y0 || h + 1 >= y0 + CHUNK_SIZE do continue
		p := col.points[i]
		r := eng.hash2f(wx, wz, useed + 101)
		biome := col.biome[i]
		plant := Block.Air
		if col.surface[i] == .Sand && h > SEA_LEVEL + 1 && (biome == .Desert_Hot || biome == .Desert_Cold || biome == .Steppe) {
			if r < 0.012 do plant = .Dead_Bush
		} else if col.surface[i] == .Grass {
			grassy := f32(0.5 + 0.5 * fbm(seed + 55, p, 48, 2))
			dense: f32
			flowers := false
			#partial switch biome {
			case .Rainforest, .Savanna, .Steppe:
				dense = 0.25 + 0.4 * grassy
			case .Taiga, .Tundra:
				dense = 0.02 + 0.12 * grassy
			case .Mediterranean:
				dense = 0.05 + 0.2 * grassy
				flowers = true
			case:
				dense = 0.03 + 0.32 * grassy
				flowers = true
			}
			if r < dense {
				plant = .Tall_Grass
			} else if flowers {
				patch := fbm(seed + 66, p, 20, 1)
				f := eng.hash2f(wx, wz, useed + 102)
				if (patch > 0.55 && f < 0.12) || f < 0.003 {
					plant = fbm(seed + 77, p, 60, 1) > 0 ? .Dandelion : .Poppy
				}
			}
		}
		if plant != .Air do c.blocks[block_index(lx, h + 1 - y0, lz)] = plant
	}

	// деревья (обрезаны по секции)
	gen := Section_Gen{c, {x0, y0, z0}}
	for t in col.trees[:col.tree_n] {
		tree_blocks(t, {x0, y0, z0}, {x0 + CHUNK_SIZE, y0 + CHUNK_SIZE, z0 + CHUNK_SIZE}, &gen, proc(data: rawptr, x, y, z: i32, b: Block) {
			g := (^Section_Gen)(data)
			i := block_index(x - g.o.x, y - g.o.y, z - g.o.z)
			cur := g.c.blocks[i]
			if cur == .Air || is_plant(cur) || (is_log(b) && BLOCK_INFO[cur].render == .Leaves) do g.c.blocks[i] = b
		})
		// под стволом трава превращается в землю
		if t.kind == .Cactus do continue
		for dz in i32(0) ..< i32(t.girth) do for dx in i32(0) ..< i32(t.girth) {
			lx, ly, lz := t.x + dx - x0, t.base - 1 - y0, t.z + dz - z0
			if lx < 0 || lz < 0 || ly < 0 || lx >= CHUNK_SIZE || lz >= CHUNK_SIZE || ly >= CHUNK_SIZE do continue
			if c.blocks[block_index(lx, ly, lz)] == .Grass do c.blocks[block_index(lx, ly, lz)] = .Dirt
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
// zone — только в умеренном лесу или степи (иначе — любая суша без воды).
find_spawn :: proc(w: ^World, cx, cz: i32, zone := true) -> [3]f64 {
	for r := i32(0); r < 400; r += 4 {
		for dz := -r; dz <= r; dz += 4 {
			for dx := -r; dx <= r; dx += 4 {
				if max(abs(dx), abs(dz)) != r do continue
				x, z := cx + dx, cz + dz
				face, gx, gz, ok := world_resolve(w, x, z)
				if !ok do continue // пустота у вершины
				if corner_dist(w.geo.n, x, z) < MONOLITH_RADIUS + 2 do continue
				h, slope, p := column_at(w, x, z)
				if h <= SEA_LEVEL + 2 do continue
				bc := block_climate(w, face, gx, gz, f64(h) + 1 - Y_SEA, p)
				surface, _ := surface_for(i64(w.seed), p, h, slope, &bc)
				if zone && !(surface == .Grass && climate_start_zone(bc.k)) do continue
				if tree_in_the_way(w, face, gx, h + 1, gz) do continue // не в стволе и не в кроне
				if tall, _ := undergrowth(w.seed, gx, gz, bc.k.biome); tall > 0 && surface == .Grass do continue
				return {f64(x) + 0.5, f64(h) + 1, f64(z) + 0.5}
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

// Глубже коры — по строению планеты (interior.odin): глубины границ под
// уровнем моря, м. Задаются один раз при старте, до фоновых потоков.
Deep_Rock :: struct {
	transition, lower, core, inner: f64,
}

deep_rock := Deep_Rock{1e18, 1e18, 1e18, 1e18}

deep_rock_init :: proc(pi: ^Planet_Interior) {
	deep_rock = {1e18, 1e18, 1e18, 1e18}
	for l in pi.layers[:pi.n] {
		d := l.top_km * 1000
		#partial switch l.kind {
		case .Transition:
			deep_rock.transition = min(deep_rock.transition, d)
		case .Lower_Mantle, .D2:
			deep_rock.lower = min(deep_rock.lower, d)
		case .Outer_Core, .Core_Liquid:
			deep_rock.core = min(deep_rock.core, d)
		case .Inner_Core, .Core_Solid:
			deep_rock.core = min(deep_rock.core, d)
			deep_rock.inner = min(deep_rock.inner, d)
		}
	}
}

// Порода мантии и ядра на высоте y (ниже коры).
deep_block :: proc(y: i32) -> Block {
	d := Y_SEA - f64(y)
	switch {
	case d >= deep_rock.inner:
		return .Iron_Core
	case d >= deep_rock.core:
		return .Molten_Iron
	case d >= deep_rock.lower:
		return .Bridgmanite
	case d >= deep_rock.transition:
		return .Ringwoodite
	}
	return .Peridotite
}

// ---------------------------------------------------------------- климат в блоках

// Климат в углу колонки: по месяцам температура у моря и осадки.
Corner_Climate :: struct {
	t, p: [12]f32,
	cp:   Climate_Point,
}

// Углы общие у четырёх колонок — считаются один раз (генерация — в главном потоке).
@(private = "file")
corner_cache: map[[3]i32]Corner_Climate

world_climate_reset :: proc() {
	clear(&corner_cache)
}

@(private = "file")
corner_climate :: proc(w: ^World, face: Cube_Face, cx, cz: i32) -> Corner_Climate {
	key := [3]i32{i32(face), cx, cz}
	if c, ok := corner_cache[key]; ok do return c
	cc := make_corner_climate(i64(w.seed), geo_dir(&w.geo, face, f64(cx * CHUNK_SIZE), f64(cz * CHUNK_SIZE)) * w.geo.radius)
	corner_cache[key] = cc
	return cc
}

// Климат в точке шара p (м): условия места и месяцы на уровне моря.
make_corner_climate :: proc(seed: i64, p: [3]f64) -> (cc: Corner_Climate) {
	cc.cp = climate_point(&climate, seed, p, elevation(seed, p, 2000))
	sea := cc.cp
	sea.alt = 0
	t, pr := climate_months(&climate, &sea)
	for m in 0 ..< 12 do cc.t[m], cc.p[m] = f32(t[m]), f32(pr[m])
	return
}

Block_Climate :: struct {
	k:                    Koppen,
	t_max, t_min, t_ann:  f64,
	p_sum:                f64,
	tint:                 u8,
	cont, wet:            f64, // условия места (для смены сезонов на дальнем рельефе)
	month_t, month_p:     [12]f32, // по месяцам: температура (°C) и осадки (мм) здесь
}

// Климат клетки (gx, gz) грани face на высоте alt (м над морем; < 0 — под водой):
// плавно между углами колонки, граница зон чуть извилиста (температура и
// осадки колеблются от места к месту).
block_climate :: proc(w: ^World, face: Cube_Face, gx, gz: i32, alt: f64, p: [3]f64) -> (b: Block_Climate) {
	cx, cz := eng.floor_div(gx, CHUNK_SIZE), eng.floor_div(gz, CHUNK_SIZE)
	fx := (f64(gx - cx * CHUNK_SIZE) + 0.5) / CHUNK_SIZE
	fz := (f64(gz - cz * CHUNK_SIZE) + 0.5) / CHUNK_SIZE
	c00 := corner_climate(w, face, cx, cz)
	c10 := corner_climate(w, face, cx + 1, cz)
	c01 := corner_climate(w, face, cx, cz + 1)
	c11 := corner_climate(w, face, cx + 1, cz + 1)
	dither := f64(fbm(i64(w.seed) + 700, p, 600, 2)) * 1.2
	wet := 1 + 0.25 * f64(fbm(i64(w.seed) + 701, p, 900, 2))
	return climate_blend({&c00, &c10, &c01, &c11}, fx, fz, alt, dither, wet)
}

// Климат между четырьмя углами (00, 10, 01, 11) на высоте alt (м; < 0 — под водой).
climate_blend :: proc(cs: [4]^Corner_Climate, fx, fz, alt, dither, wet: f64) -> (b: Block_Climate) {
	c00, c10, c01, c11 := cs[0], cs[1], cs[2], cs[3]
	b.cont = (c00.cp.cont * (1 - fx) + c10.cp.cont * fx) * (1 - fz) + (c01.cp.cont * (1 - fx) + c11.cp.cont * fx) * fz
	b.wet = ((c00.cp.wet * (1 - fx) + c10.cp.wet * fx) * (1 - fz) + (c01.cp.wet * (1 - fx) + c11.cp.wet * fx) * fz) * wet
	t, pr: [12]f64
	b.t_max, b.t_min = -1.0e9, 1.0e9
	for m in 0 ..< 12 {
		bt := (f64(c00.t[m]) * (1 - fx) + f64(c10.t[m]) * fx) * (1 - fz) + (f64(c01.t[m]) * (1 - fx) + f64(c11.t[m]) * fx) * fz
		bp := (f64(c00.p[m]) * (1 - fx) + f64(c10.p[m]) * fx) * (1 - fz) + (f64(c01.p[m]) * (1 - fx) + f64(c11.p[m]) * fx) * fz
		t[m] = bt - climate.lapse * max(alt, 0) + dither
		pr[m] = bp * wet
		b.t_max = max(b.t_max, t[m])
		b.t_min = min(b.t_min, t[m])
		b.t_ann += t[m] / 12
		b.p_sum += pr[m]
		b.month_t[m], b.month_p[m] = f32(t[m]), f32(pr[m])
	}
	if alt < 0 {
		b.k.biome = b.t_max < -1.8 ? .Sea_Ice : .Ocean // летом не тает — многолетний лёд
	} else {
		b.k = koppen_classify(t, pr)
	}
	// оттенок травы и листвы: сухость и холод
	aridity := b.p_sum / max(20 * max(b.t_ann, 0) + 280, 100)
	dry := clamp(1.5 - aridity, 0, 1)
	cold := clamp((18 - b.t_max) / 14, 0, 1)
	b.tint = u8(dry * 15 + 0.5) | u8(cold * 15 + 0.5) << 4
	return
}

// Подлесок в клетке (wx, wz) на траве: высота куста (0 — нет) и его листва.
// В тропическом лесу кусты и молодые деревца стоят густо, до двух метров.
undergrowth :: proc(seed: u32, wx, wz: i32, biome: Biome) -> (tall: i32, leaves: Block) {
	b := eng.hash2f(wx, wz, seed + 103)
	#partial switch biome {
	case .Rainforest:
		if b < 0.09 do return b < 0.045 ? 2 : 1, .Jungle_Leaves
	}
	return 0, .Air
}
