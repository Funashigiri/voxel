package main

// Деревья настоящего размера (0.016).
//
// У каждого дерева свой вид, возраст и место. Высота растёт с возрастом по
// кривой Чепмена — Ричардса до предела, который ставят вид и климат места: у
// границы леса деревья низкие, в сухом климате — ниже. Возрасты — как при
// постоянной смертности: молодых больше, до старости доживают немногие.
// Крона на просторе широкая и низкая, в сомкнутом лесу — узкая и поднята
// высоко (нижние ветви отмирают в тени). Ствол толстеет с возрастом: самые
// старые — в два блока толщиной, у тропических великанов — досковидные корни.
//
// Форма — скелет: ствол, сучья и ветви (дерево), листва облаками на концах
// ветвей. Всё вычисляется из (зерна, клетки), поэтому части одного дерева в
// разных секциях и колонках совпадают.

import "core:fmt"
import "core:math"
import eng "engine"

TREE_CELL :: 6 // м: в клетке не больше одного дерева (до ~280 стволов на гектар)
CROWN_MAX :: 10.0 // радиус кроны, м
TREE_REACH :: i32(CROWN_MAX) + 4 // дальше этого от ствола от дерева ничего нет, блоков

@(private = "file")
V :: [3]f64

Tree_Species :: struct {
	h_max:        f64, // высота взрослого дерева на хорошем месте, м
	k, c:         f64, // рост: H = h_max·(1 − e^(−k·возраст))^c
	life:         f64, // предельный возраст, лет
	tau:          f64, // 1 / смертность взрослых деревьев за год, лет
	crown_open:   f64, // поперечник кроны / высота — на просторе
	crown_forest: f64, // то же в сомкнутом лесу
	len_open:     f64, // длина кроны / высота — на просторе
	len_forest:   f64, // то же в лесу
	d_rate:       f64, // прирост толщины ствола, м в год
}

// Дуб черешчатый, берёза повислая, ель европейская, акация зонтичная,
// дерево полога тропического леса (великаны — выше на треть).
TREE_SPECIES := [Tree_Kind]Tree_Species {
	.Oak    = {32, 0.022, 1.3, 500, 125, 0.85, 0.45, 0.75, 0.45, 0.004},
	.Birch  = {26, 0.05, 1.2, 120, 40, 0.50, 0.30, 0.70, 0.50, 0.005},
	.Spruce = {38, 0.02, 1.6, 350, 85, 0.38, 0.22, 0.95, 0.60, 0.0035},
	.Acacia = {13, 0.05, 1.2, 200, 50, 1.40, 1.00, 0.35, 0.30, 0.005},
	.Jungle = {42, 0.03, 1.3, 400, 70, 0.55, 0.42, 0.45, 0.32, 0.0045},
	.Cactus = {3, 0.05, 1.0, 100, 30, 0, 0, 0, 0, 0},
}

TREE_NAMES := [Tree_Kind]string {
	.Oak    = "дуб",
	.Birch  = "берёза",
	.Spruce = "ель",
	.Acacia = "акация",
	.Jungle = "тропические деревья",
	.Cactus = "кактусы",
}

@(private = "file")
tsmooth :: proc(e0, e1, x: f64) -> f64 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}

// Высота взрослых деревьев вида здесь, м. Летнее тепло: у самого тёплого
// месяца в 10 °C — граница леса, деревья низкие и кривые; влага: в сухом
// климате деревья ниже.
tree_site_height :: proc(kind: Tree_Kind, t_max, dry: f64) -> f64 {
	warm := 0.12 + 0.88 * tsmooth(10, 17, t_max)
	return TREE_SPECIES[kind].h_max * warm * (1 - 0.55 * clamp(dry, 0, 1))
}

// Главное дерево зоны (для дальнего рельефа и F3).
zone_tree :: proc(bc: ^Block_Climate) -> Tree_Kind {
	#partial switch bc.k.biome {
	case .Taiga:
		return .Spruce
	case .Savanna:
		return .Acacia
	case .Rainforest:
		return .Jungle
	case .Desert_Hot:
		return .Cactus
	}
	return .Oak
}

// Средняя высота верха леса, м: деревья всех возрастов, большинство — взрослые.
canopy_height :: proc(bc: ^Block_Climate) -> f64 {
	kind := zone_tree(bc)
	if kind == .Cactus do return 0
	return 0.8 * tree_site_height(kind, bc.t_max, f64(bc.tint & 15) / 15)
}

// Какое дерево растёт в этой зоне.
tree_kind_for :: proc(bc: ^Block_Climate, roll, birch_noise: f64) -> Tree_Kind {
	#partial switch bc.k.biome {
	case .Taiga:
		return roll < 0.85 ? .Spruce : .Birch
	case .Temperate_Forest:
		if bc.k.code[0] == 'D' && roll < 0.35 do return .Spruce // смешанный лес континентального климата
		return birch_noise > 0.2 || roll > 0.88 ? .Birch : .Oak
	case .Savanna:
		return .Acacia
	case .Rainforest:
		return .Jungle
	case .Desert_Hot:
		return .Cactus
	}
	return roll > 0.85 ? .Birch : .Oak
}

// Блоки вида: ствол (кольца сверху), ветви (кора со всех сторон), листва.
tree_blocks_of :: proc(k: Tree_Kind) -> (log, wood, pole, leaves: Block) {
	switch k {
	case .Oak:
		return .Oak_Log, .Oak_Wood, .Oak_Pole, .Oak_Leaves
	case .Birch:
		return .Birch_Log, .Birch_Wood, .Birch_Pole, .Birch_Leaves
	case .Spruce:
		return .Spruce_Log, .Spruce_Wood, .Spruce_Pole, .Spruce_Leaves
	case .Acacia:
		return .Acacia_Log, .Acacia_Wood, .Acacia_Pole, .Acacia_Leaves
	case .Jungle:
		return .Jungle_Log, .Jungle_Wood, .Jungle_Pole, .Jungle_Leaves
	case .Cactus:
		return .Cactus, .Cactus, .Cactus, .Air
	}
	return .Oak_Log, .Oak_Wood, .Oak_Pole, .Oak_Leaves
}

// ---------------------------------------------------------------- деревья по клеткам

@(private = "file")
Tree_Cell :: struct {
	tree: Tree,
	ok:   bool,
}

// Клетки общие у соседних колонок — дерево считается один раз (генерация — в
// главном потоке). raw — каким выросло бы дерево без соседей, tree — с ними.
@(private = "file")
tree_cache: map[[3]i32]Tree_Cell
@(private = "file")
raw_cache: map[[3]i32]Tree_Cell

trees_reset :: proc() {
	clear(&tree_cache)
	clear(&raw_cache)
}

// Теневыносливость: доля деревьев вида, что выживают подростом под чужой кроной.
TREE_SHADE := [Tree_Kind]f64 {
	.Oak    = 0.35,
	.Birch  = 0.1,
	.Spruce = 0.85,
	.Acacia = 0.05,
	.Jungle = 0.9,
	.Cactus = 1,
}

// Дерево клетки (cx, cz) грани face — одно и то же, из какой колонки ни спроси.
//
// Конкуренция за свет: если ствол накрывает крона соседа, что выше, дерево в
// тени — растёт медленно, остаётся невысоким (ниже полога соседа), с маленькой
// кроной и тонким стволом. Светолюбивые виды в тени гибнут (TREE_SHADE). Так в
// пологе остаётся столько деревьев, сколько помещается крон.
tree_in_cell :: proc(w: ^World, face: Cube_Face, cx, cz: i32) -> (Tree, bool) {
	key := [3]i32{i32(face), cx, cz}
	if c, ok := tree_cache[key]; ok do return c.tree, c.ok
	if len(tree_cache) > 400_000 do clear(&tree_cache)
	t, ok := raw_tree(w, face, cx, cz)
	if ok && t.kind != .Cactus {
		top := 1.0e9 // низ полога над деревом (от его основания), м
		for dz in i32(-2) ..= 2 do for dx in i32(-2) ..= 2 {
			if dx == 0 && dz == 0 do continue
			o, has := raw_tree(w, face, cx + dx, cz + dz)
			if !has || o.kind == .Cactus do continue
			if o.height < t.height || (o.height == t.height && o.seed < t.seed) do continue
			ex, ez := f64(o.x - t.x), f64(o.z - t.z)
			if ex * ex + ez * ez > f64(o.crown * o.crown) * 0.8 do continue
			top = min(top, f64(o.base) + f64(o.crown_base) - f64(t.base))
		}
		if top < 1.0e9 {
			if f64(eng.hash2f(cx, cz, w.seed + 503)) > TREE_SHADE[t.kind] {
				ok = false // не выжило в тени
			} else {
				H := min(f64(t.height), max(1.6, 0.6 * top))
				t.height = f32(H)
				t.crown = f32(min(f64(t.crown), 0.8 + 0.15 * H))
				t.crown_base = f32(0.45 * H)
				t.dbh *= 0.35 // в тени ствол почти не толстеет
				t.under = true
				t.fins = 0
				t.girth = 1
				t.thin = t.dbh < 0.45
			}
		}
	}
	tree_cache[key] = {t, ok}
	return t, ok
}

@(private = "file")
raw_tree :: proc(w: ^World, face: Cube_Face, cx, cz: i32) -> (Tree, bool) {
	key := [3]i32{i32(face), cx, cz}
	if c, ok := raw_cache[key]; ok do return c.tree, c.ok
	if len(raw_cache) > 400_000 do clear(&raw_cache)
	t, ok := make_tree(w, face, cx, cz)
	raw_cache[key] = {t, ok}
	return t, ok
}

@(private = "file")
make_tree :: proc(w: ^World, face: Cube_Face, cx, cz: i32) -> (t: Tree, ok: bool) {
	seed := i64(w.seed)
	useed := w.seed
	n := w.geo.n
	hsh := eng.hash2(cx, cz, useed + 500)
	tx := cx * TREE_CELL + 1 + i32(hsh % 4)
	tz := cz * TREE_CELL + 1 + i32((hsh >> 8) % 4)
	// дерево целиком на своей грани (не режется на стыке) и не у столпа
	if tx < 3 || tz < 3 || tx > n - 5 || tz > n - 5 do return
	if corner_dist(n, tx, tz) < MONOLITH_RADIUS + 4 do return
	p := geo_point(&w.geo, face, tx, tz)
	h := terrain_height(seed, p)
	if h < SEA_LEVEL do return
	bc := block_climate(w, face, tx, tz, f64(h) + 1 - Y_SEA, p)
	cover := f64(forest_cover(seed, p, bc.k.biome, bc.t_max))
	if f64(eng.hash2f(cx, cz, useed + 501)) > cover do return
	slope: i32
	for d in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
		slope = max(slope, abs(h - terrain_height(seed, geo_point(&w.geo, face, tx + d.x, tz + d.y))))
	}
	surface, _ := surface_for(seed, p, h, slope, &bc)
	kind := tree_kind_for(&bc, f64(eng.hash2f(cx, cz, useed + 502)), f64(fbm(seed + 99, p, 160, 2)))
	if kind == .Cactus {
		if surface != .Sand || slope > 1 do return
		return {x = tx, z = tz, base = h + 1, height = f32(1 + (hsh >> 16) % 3), kind = .Cactus, girth = 1, seed = hsh}, true
	}
	if surface != .Grass || slope > 2 do return

	sp := &TREE_SPECIES[kind]
	r := eng.rng_make(u64(hsh) ~ u64(useed) << 32 ~ 0x7EE5)
	// возраст: взрослые гибнут с постоянной вероятностью (смертность 1/τ в год), и
	// в просвет встаёт подрост, которому уже лет десять, — возрасты по экспоненте
	span := sp.life - 10
	age := 10 - sp.tau * math.ln(1 - eng.rng_f64(&r) * (1 - math.exp(-span / sp.tau)))
	h_max := tree_site_height(kind, bc.t_max, f64(bc.tint & 15) / 15)
	giant := kind == .Jungle && eng.rng_f64(&r) < 0.06 // великаны над пологом
	if giant do h_max *= 1.35
	H := h_max * math.pow(1 - math.exp(-sp.k * age), sp.c) * eng.rng_range(&r, 0.9, 1.1)
	if H < 1.6 do return // всходы — не деревья
	// крона: на просторе шире и ниже, в сомкнутом лесу уже и выше
	closure := clamp(cover / 0.85, 0, 1)
	R := 0.5 * H * math.lerp(sp.crown_open, sp.crown_forest, closure) * eng.rng_range(&r, 0.85, 1.15)
	if giant do R *= 1.25
	edge := f64(min(tx, tz, n - 2 - tx, n - 2 - tz))
	R = clamp(R, 0.8, min(CROWN_MAX, edge - 2))
	crown_len := H * math.lerp(sp.len_open, sp.len_forest, closure)
	// поперечник ствола, м: толстеет с возрастом — быстрее на хорошем месте и на просторе
	D := sp.d_rate * age * (h_max / sp.h_max) * (1 + 0.4 * (1 - closure))
	t = {
		x          = tx,
		z          = tz,
		base       = h + 1,
		height     = f32(H),
		crown      = f32(R),
		crown_base = f32(H - crown_len),
		kind       = kind,
		girth      = D >= 1.3 ? 2 : 1,
		thin       = D < 0.45,
		dbh        = f32(D),
		seed       = hsh,
	}
	if kind == .Jungle && D >= 0.6 && H >= 15 do t.fins = u8(3 + eng.rng_int(&r, 0, 2))
	return t, true
}

// Деревья, чьи ветви и листва задевают колонку.
column_trees :: proc(w: ^World, col: ^Column) {
	x0 := col.key.x * CHUNK_SIZE
	z0 := col.key.z * CHUNK_SIZE
	col.tree_n = 0
	gx0 := eng.floor_div(x0 - TREE_REACH, TREE_CELL)
	gx1 := eng.floor_div(x0 + CHUNK_SIZE + TREE_REACH, TREE_CELL)
	gz0 := eng.floor_div(z0 - TREE_REACH, TREE_CELL)
	gz1 := eng.floor_div(z0 + CHUNK_SIZE + TREE_REACH, TREE_CELL)
	for cz in gz0 ..= gz1 do for cx in gx0 ..= gx1 {
		t, ok := tree_in_cell(w, col.key.face, cx, cz)
		if !ok || !tree_touches(t, {x0, min(i32) / 2, z0}, {x0 + CHUNK_SIZE, max(i32) / 2, z0 + CHUNK_SIZE}) do continue
		if col.tree_n >= MAX_COL_TREES do return
		col.trees[col.tree_n] = t
		col.tree_n += 1
	}
}

// Занято ли деревом место человека (ноги и голова) в клетке (gx, y, gz) грани face.
tree_in_the_way :: proc(w: ^World, face: Cube_Face, gx, y, gz: i32) -> bool {
	hit := false
	for cz in eng.floor_div(gz - TREE_REACH, TREE_CELL) ..= eng.floor_div(gz + TREE_REACH, TREE_CELL) {
		for cx in eng.floor_div(gx - TREE_REACH, TREE_CELL) ..= eng.floor_div(gx + TREE_REACH, TREE_CELL) {
			t, ok := tree_in_cell(w, face, cx, cz)
			if !ok do continue
			tree_blocks(t, {gx, y, gz}, {gx + 1, y + 2, gz + 1}, &hit, proc(data: rawptr, x, y, z: i32, b: Block) {
				(^bool)(data)^ = true
			})
		}
	}
	return hit
}

// ---------------------------------------------------------------- форма дерева

Tree_Put :: proc(data: rawptr, x, y, z: i32, b: Block)

@(private = "file")
Raster :: struct {
	lo, hi: [3]i32, // куда рисуем (hi — не включая)
	data:   rawptr,
	put:    Tree_Put,
	blk:    Block, // блок отрезка, что рисуется сейчас (seg_walk)
}

@(private = "file")
Seg :: struct {
	a, b: [3]f64,
	blk:  Block,
}

@(private = "file")
Blob :: struct {
	c:      [3]f64,
	rx, ry: f64,
	fill:   f64,
}

@(private = "file")
Shape :: struct {
	segs:  [64]Seg,
	nseg:  int,
	blobs: [40]Blob,
	nblob: int,
}

@(private = "file")
add_seg :: proc(s: ^Shape, a, b: [3]f64, blk: Block) {
	if s.nseg == len(s.segs) do return
	s.segs[s.nseg] = {a, b, blk}
	s.nseg += 1
}

@(private = "file")
add_blob :: proc(s: ^Shape, c: [3]f64, rx, ry, fill: f64) {
	if s.nblob == len(s.blobs) do return
	s.blobs[s.nblob] = {c, rx, ry, fill}
	s.nblob += 1
}

@(private = "file")
rr :: proc(r: ^eng.Rng, lo, hi: f64) -> f64 {return eng.rng_range(r, lo, hi)}

// Направление: азимут и наклон от вертикали.
@(private = "file")
dir_at :: proc(az, incl: f64) -> [3]f64 {
	return {math.sin(incl) * math.cos(az), math.cos(incl), math.sin(incl) * math.sin(az)}
}

@(private = "file")
fl :: #force_inline proc(p: [3]f64) -> [3]i32 {
	return {i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
}

@(private = "file")
put_cell :: #force_inline proc(r: ^Raster, c: [3]i32, b: Block) {
	if c.x < r.lo.x || c.y < r.lo.y || c.z < r.lo.z || c.x >= r.hi.x || c.y >= r.hi.y || c.z >= r.hi.z do return
	r.put(r.data, c.x, c.y, c.z, b)
}

// Задевает ли дерево область [lo, hi).
tree_touches :: proc(t: Tree, lo, hi: [3]i32) -> bool {
	reach := i32(t.crown) + 3 + i32(t.girth)
	if t.x + reach < lo.x || t.x - reach >= hi.x || t.z + reach < lo.z || t.z - reach >= hi.z do return false
	return t.base - 4 < hi.y && t.base + i32(t.height) + 3 >= lo.y
}

// Ветвь от a до b (м, сетка грани): блоки подряд, каждый касается предыдущего гранью.
@(private = "file")
draw_seg :: proc(r: ^Raster, s: Seg) {
	lo := fl({min(s.a.x, s.b.x), min(s.a.y, s.b.y), min(s.a.z, s.b.z)})
	hi := fl({max(s.a.x, s.b.x), max(s.a.y, s.b.y), max(s.a.z, s.b.z)})
	if hi.x < r.lo.x || hi.y < r.lo.y || hi.z < r.lo.z || lo.x >= r.hi.x || lo.y >= r.hi.y || lo.z >= r.hi.z do return
	d := s.b - s.a
	steps := int(math.ceil(max(abs(d.x), abs(d.y), abs(d.z)) * 2)) + 1
	cur := fl(s.a)
	put_cell(r, cur, s.blk)
	// тонкая ветвь — во всех клетках, через которые проходит её линия (сетку
	// рисует сама линия); толстая — лесенкой через грани
	if BLOCK_INFO[s.blk].render == .Post {
		r.blk = s.blk
		seg_walk(s.a, s.b, r, proc(data: rawptr, cell: [3]i32, t0, t1: f64) {
			rr := (^Raster)(data)
			put_cell(rr, cell, rr.blk)
		})
		return
	}
	for i in 1 ..= steps {
		c := fl(s.a + d * (f64(i) / f64(steps)))
		for axis in 0 ..< 3 {
			if c[axis] == cur[axis] do continue
			cur[axis] = c[axis]
			put_cell(r, cur, s.blk)
		}
	}
}

// Облако листвы: эллипсоид, к краю реже (рваный край).
@(private = "file")
draw_blob :: proc(r: ^Raster, b: Blob, leaves: Block, seed: u32) {
	x0, x1 := max(i32(math.floor(b.c.x - b.rx)), r.lo.x), min(i32(math.floor(b.c.x + b.rx)), r.hi.x - 1)
	y0, y1 := max(i32(math.floor(b.c.y - b.ry)), r.lo.y), min(i32(math.floor(b.c.y + b.ry)), r.hi.y - 1)
	z0, z1 := max(i32(math.floor(b.c.z - b.rx)), r.lo.z), min(i32(math.floor(b.c.z + b.rx)), r.hi.z - 1)
	for y in y0 ..= y1 do for z in z0 ..= z1 do for x in x0 ..= x1 {
		dx := (f64(x) + 0.5 - b.c.x) / b.rx
		dy := (f64(y) + 0.5 - b.c.y) / b.ry
		dz := (f64(z) + 0.5 - b.c.z) / b.rx
		d := dx * dx + dy * dy + dz * dz
		if d > 1 do continue
		keep := b.fill * (d < 0.4 ? 1 : 1 - (d - 0.4) * 0.9)
		if f64(eng.hash3f(x, y, z, seed)) < keep do r.put(r.data, x, y, z, leaves)
	}
}

// Ель: хвоя ярусами-мутовками, конусом от низа кроны к макушке; концы ветвей
// мутовки свисают — ярусом ниже лежит их край (сухие сучья ниже кроны — в tree_shape).
@(private = "file")
draw_spruce :: proc(r: ^Raster, t: Tree, c: [3]f64, leaves: Block) {
	top := t.base + i32(f64(t.height))
	ylo := t.base + i32(f64(t.crown_base))
	span := f64(top - ylo) + 1
	cx, cz := i32(math.floor(c.x)), i32(math.floor(c.z))
	whorl_r :: proc(t: Tree, y, top: i32, span: f64) -> f64 {
		return f64(t.crown) * math.pow((f64(top - y) + 0.5) / span, 0.9)
	}
	for y in max(ylo - 1, r.lo.y) ..= min(top, r.hi.y - 1) {
		whorl := (y + i32(t.seed >> 3 & 1)) % 2 == 0
		// мутовка: плотный диск; между мутовками — свисающий край верхней и редкая хвоя внутри
		rad := whorl ? whorl_r(t, y, top, span) : whorl_r(t, y + 1, top, span) + 0.4
		rad = max(rad, t.girth == 2 ? 1.8 : 1.1) // у макушки хвоя всё равно закрывает ствол
		inner := whorl ? rad - 0.8 : rad - 1.6
		if y == top do rad, inner = t.girth == 2 ? 1.0 : 0.4, 2
		if y < ylo && whorl do continue
		ri := i32(math.ceil(rad))
		for dz in -ri ..= ri do for dx in -ri ..= ri {
			x, z := cx + dx, cz + dz
			if x < r.lo.x || z < r.lo.z || x >= r.hi.x || z >= r.hi.z do continue
			ex, ez := f64(x) + 0.5 - c.x, f64(z) + 0.5 - c.z
			dist := math.sqrt(ex * ex + ez * ez)
			if dist > rad + 0.3 do continue
			keep := dist < inner ? (whorl ? 0.97 : 0.3) : 0.65
			if rad < 2 do keep = 0.95 // молодые побеги у верхушки — густые
			if f64(eng.hash3f(x, y, z, t.seed)) < keep do r.put(r.data, x, y, z, leaves)
		}
	}
}

// Форма дерева: отрезки древесины и облака листвы (ель — свою хвою рисует сама).
// Тонкий ствол — тоже отрезок; у толстого ствол — колонна блоков до trunk_top.
@(private = "file")
tree_shape :: proc(t: Tree) -> (s: Shape, trunk_top: f64, c: [3]f64) {
	log, wood, pole, _ := tree_blocks_of(t.kind)
	_ = log
	// главные сучья толщиной в блок — только у толстых деревьев, мелкие ветви,
	// сухие сучки и корни — тонкие
	limb := t.dbh >= 0.9 ? wood : pole
	g := f64(t.girth)
	c = {f64(t.x) + g / 2, f64(t.base), f64(t.z) + g / 2}
	rng := eng.rng_make(u64(t.seed) * 0x9E37_79B9_7F4A_7C15 + 1)
	switch t.kind {
	case .Oak:
		trunk_top = shape_oak(&s, t, c, &rng, limb, pole)
	case .Birch:
		trunk_top = shape_birch(&s, t, c, &rng, limb, pole)
	case .Spruce:
		trunk_top = f64(t.height) - 1
		// сухие сучья под кроной: в тени ветви отмирают, но долго не опадают
		ylo := t.base + i32(f64(t.crown_base))
		for y in t.base + 2 ..< ylo - 1 {
			h := eng.hash3(t.x, y, t.z, t.seed)
			if h % 100 >= 16 do continue
			az := f64(h >> 8 & 1023) / 1024 * math.TAU
			p := c + V{0, f64(y - t.base) + 0.5, 0}
			add_seg(&s, p, p + V{math.cos(az), -0.15, math.sin(az)} * (g / 2 + 0.9), pole)
		}
	case .Acacia:
		trunk_top = shape_acacia(&s, t, c, &rng, limb, pole)
	case .Jungle:
		trunk_top = shape_jungle(&s, t, c, &rng, limb, pole)
	case .Cactus:
	}
	// тонкий ствол — отрезок от земли (с запасом вниз — на склоне не висит) до развилки
	if t.thin do add_seg(&s, c + V{0, -3, 0}, c + V{0, trunk_top, 0}, pole)
	return
}

// Тонкие отрезки дерева (стволы, ветви, сучья, корни) — для их сетки (mesher.odin).
tree_thin_segments :: proc(t: Tree, out: ^[dynamic][2][3]f64) {
	if t.kind == .Cactus do return
	s, _, _ := tree_shape(t)
	for sg in s.segs[:s.nseg] do if BLOCK_INFO[sg.blk].render == .Post do append(out, [2][3]f64{sg.a, sg.b})
}

// Блоки дерева в области [lo, hi): сначала листва, потом дерево (брёвна вытесняют листву).
tree_blocks :: proc(t: Tree, lo, hi: [3]i32, data: rawptr, put: Tree_Put) {
	if !tree_touches(t, lo, hi) do return
	r := Raster{lo = lo, hi = hi, data = data, put = put}
	if t.kind == .Cactus {
		for dy in 0 ..< i32(t.height) do put_cell(&r, {t.x, t.base + dy, t.z}, .Cactus)
		return
	}
	log, _, _, leaves := tree_blocks_of(t.kind)
	s, trunk_top, c := tree_shape(t)
	if t.kind == .Spruce do draw_spruce(&r, t, c, leaves)
	for b in s.blobs[:s.nblob] do draw_blob(&r, b, leaves, t.seed)
	// толстый ствол: колонна блоков от земли (с запасом вниз) до развилки
	if !t.thin {
		for dz in i32(0) ..< i32(t.girth) do for dx in i32(0) ..< i32(t.girth) {
			x, z := t.x + dx, t.z + dz
			if x < lo.x || z < lo.z || x >= hi.x || z >= hi.z do continue
			for y in max(t.base - 3, lo.y) ..< min(t.base + i32(math.ceil(trunk_top)), hi.y) do put(data, x, y, z, log)
		}
	}
	for sg in s.segs[:s.nseg] do draw_seg(&r, sg)
}

// Дуб: ствол делится на несколько толстых кривых сучьев, крона широкая, округлая.
@(private = "file")
shape_oak :: proc(s: ^Shape, t: Tree, c: [3]f64, rng: ^eng.Rng, wood, twig: Block) -> (trunk: f64) {
	H, R, cb := f64(t.height), f64(t.crown), f64(t.crown_base)
	if H < 6 {
		add_blob(s, c + V{0, H - max(R * 0.7, 1), 0}, max(R, 1.2), max(R * 0.8, 1.2), 0.9)
		return H - 1
	}
	bole := clamp(cb, 1.5, H * 0.6)
	lead := c + V{rr(rng, -0.6, 0.6), H - 2, rr(rng, -0.6, 0.6)}
	add_seg(s, c + V{0, bole, 0}, lead, wood)
	rl := clamp(R * 0.5, 1.6, 4.2) // облака листвы
	n := 3 + eng.rng_int(rng, 0, 2)
	az0 := rr(rng, 0, math.TAU)
	for i in 0 ..< n {
		az := az0 + math.TAU * f64(i) / f64(n) + rr(rng, -0.4, 0.4)
		start := c + V{0, bole + rr(rng, 0, (H - bole) * 0.3), 0}
		// сук сначала отходит от ствола полого (иначе в блоках он шёл бы вплотную к
		// стволу), у локтя заворачивает вверх; в лесу — круче, на просторе — шире
		open := clamp((R / H - 0.22) / 0.2, 0, 1)
		reach := max(R - rl * 0.6, 0.8) * rr(rng, 0.75, 1.0)
		incl1 := rr(rng, 0.9, 1.2)
		mid := start + dir_at(az, incl1) * (reach * 0.5 / math.sin(incl1))
		incl2 := rr(rng, 0.35, 0.65) + 0.4 * open
		end := mid + dir_at(az + rr(rng, -0.3, 0.3), incl2) * (reach * 0.5 / math.sin(incl2))
		end.y = min(end.y, c.y + H - rl * 0.7)
		add_seg(s, start, mid, wood)
		add_seg(s, mid, end, wood)
		add_blob(s, end + V{0, rl * 0.25, 0}, rl, rl * 0.75, 0.92)
		// боковая ветвь от середины сука
		az2 := az + (eng.rng_f64(rng) < 0.5 ? -1.0 : 1.0) * rr(rng, 0.6, 1.1)
		e2 := mid + dir_at(az2, rr(rng, 0.7, 1.1)) * (reach * 0.55)
		e2.y = min(e2.y, c.y + H - rl * 0.6)
		if H >= 12 do add_seg(s, mid, e2, twig)
		add_blob(s, e2 + V{0, rl * 0.2, 0}, rl * 0.8, rl * 0.65, 0.9)
	}
	add_blob(s, lead + V{0, 0.3, 0}, rl * 1.05, rl * 0.8, 0.92)
	return bole
}

// Берёза: тонкий ствол почти до макушки, ветви круто вверх, концы свисают.
@(private = "file")
shape_birch :: proc(s: ^Shape, t: Tree, c: [3]f64, rng: ^eng.Rng, wood, twig: Block) -> (trunk: f64) {
	H, R, cb := f64(t.height), f64(t.crown), f64(t.crown_base)
	if H < 6 {
		add_blob(s, c + V{0, H - max(R * 1.2, 1), 0}, max(R, 1), max(R * 1.4, 1.3), 0.9)
		return H - 1
	}
	rl := clamp(R * 0.42, 1.2, 2.6)
	n := 5 + eng.rng_int(rng, 0, 3)
	az := rr(rng, 0, math.TAU)
	for i in 0 ..< n {
		az += 2.39996 + rr(rng, -0.3, 0.3) // золотой угол — ветви не друг над другом
		f := (f64(i) + rr(rng, 0.2, 0.8)) / f64(n) // 0 — низ кроны, 1 — верх
		start := c + V{0, cb + (H * 0.88 - cb) * f, 0}
		incl := rr(rng, 0.8, 1.05) // в блоках круче 45° ветвь шла бы вплотную к стволу
		reach := max(R - rl * 0.5, 0.6) * (1.05 - 0.6 * f) * rr(rng, 0.8, 1.0)
		end := start + dir_at(az, incl) * (reach / math.sin(incl))
		end.y = min(end.y, c.y + H - 1)
		if H >= 10 do add_seg(s, start, start + (end - start) * 0.7, twig)
		add_blob(s, end + V{0, -rl * 0.35, 0}, rl, rl * 1.35, 0.85) // концы ветвей свисают
	}
	add_blob(s, c + V{0, H - 1.7, 0}, rl * 0.9, rl * 1.4, 0.9)
	return H * 0.9
}

// Акация: короткий ствол расходится на несколько наклонных ветвей, сверху — плоский зонтик.
@(private = "file")
shape_acacia :: proc(s: ^Shape, t: Tree, c: [3]f64, rng: ^eng.Rng, wood, twig: Block) -> (trunk: f64) {
	H, R := f64(t.height), f64(t.crown)
	if H < 3.5 {
		add_blob(s, c + V{0, H - 0.8, 0}, max(R, 1.2), 0.9, 0.85)
		return H - 1
	}
	fork := max(H * rr(rng, 0.25, 0.4), 1.5)
	top := c + V{rr(rng, -0.7, 0.7), fork, rr(rng, -0.7, 0.7)}
	add_seg(s, c + V{0, 1, 0}, top, wood)
	under := c.y + H - rr(rng, 1.2, 1.8) // низ зонтика
	n := H < 8 ? 2 : 2 + eng.rng_int(rng, 0, 2) // у молодых — развилка надвое
	az0 := rr(rng, 0, math.TAU)
	for i in 0 ..< n {
		az := az0 + math.TAU * f64(i) / f64(n) + rr(rng, -0.5, 0.5)
		d := R * rr(rng, 0.45, 0.7)
		end := [3]f64{c.x + math.cos(az) * d, under + rr(rng, -0.3, 0.3), c.z + math.sin(az) * d}
		mid := top + (end - top) * rr(rng, 0.45, 0.6) + V{rr(rng, -0.5, 0.5), rr(rng, -0.3, 0.3), rr(rng, -0.5, 0.5)}
		add_seg(s, top, mid, wood)
		add_seg(s, mid, end, wood)
		// тонкие ветви веером под зонтиком
		for k in 0 ..< 2 {
			az2 := az + (k == 0 ? -1.0 : 1.0) * rr(rng, 0.4, 0.9)
			e2 := end + V{math.cos(az2) * R * 0.3, 0.6, math.sin(az2) * R * 0.3}
			if H >= 9 do add_seg(s, end, e2, twig)
		}
		add_blob(s, end + V{0, 1.0, 0}, R * rr(rng, 0.45, 0.6), rr(rng, 0.9, 1.2), 0.9)
	}
	add_blob(s, {top.x, under + 1.3, top.z}, R, rr(rng, 0.8, 1.0), 0.75) // плоский верх
	return 1
}

// Дерево тропического леса: прямой гладкий ствол на две трети высоты, у
// великанов — досковидные корни; наверху раскидистые сучья и широкая крона.
@(private = "file")
shape_jungle :: proc(s: ^Shape, t: Tree, c: [3]f64, rng: ^eng.Rng, wood, twig: Block) -> (trunk: f64) {
	H, R, cb := f64(t.height), f64(t.crown), f64(t.crown_base)
	if H < 8 {
		add_blob(s, c + V{0, H - max(R * 0.6, 1), 0}, max(R, 1.3), max(R * 0.7, 1.2), 0.9)
		return H - 1
	}
	// досковидные корни и корни-подпорки: тонкие тяжи от ствола наискось к земле
	az := rr(rng, 0, math.TAU)
	g := f64(t.girth)
	for _ in 0 ..< int(t.fins) {
		az += math.TAU / f64(t.fins) + rr(rng, -0.3, 0.3)
		dir := V{math.cos(az), 0, math.sin(az)}
		fh := rr(rng, 2.5, 4.5)
		reach := g / 2 + rr(rng, 1.5, 3.2)
		add_seg(s, c + dir * (g / 2) + V{0, fh, 0}, c + dir * reach + V{0, -1, 0}, twig)
	}
	bole := max(cb, H * 0.6)
	lead := c + V{rr(rng, -0.5, 0.5), H - 2.5, rr(rng, -0.5, 0.5)}
	add_seg(s, c + V{0, bole, 0}, lead, wood)
	rl := clamp(R * 0.5, 2.0, 5.0)
	n := 3 + eng.rng_int(rng, 0, 2)
	az0 := rr(rng, 0, math.TAU)
	for i in 0 ..< n {
		a := az0 + math.TAU * f64(i) / f64(n) + rr(rng, -0.4, 0.4)
		start := c + V{0, bole + rr(rng, 0, (H - bole) * 0.25), 0}
		reach := max(R - rl * 0.6, 1) * rr(rng, 0.75, 1.0)
		incl1 := rr(rng, 0.95, 1.25) // от ствола полого, потом вверх
		mid := start + dir_at(a, incl1) * (reach * 0.55 / math.sin(incl1))
		incl2 := rr(rng, 0.55, 0.9)
		end := mid + dir_at(a + rr(rng, -0.3, 0.3), incl2) * (reach * 0.45 / math.sin(incl2))
		end.y = min(end.y, c.y + H - rl * 0.45 - 0.5)
		add_seg(s, start, mid, wood)
		add_seg(s, mid, end, wood)
		add_blob(s, end + V{0, rl * 0.2, 0}, rl, rl * 0.5, 0.92)
		a2 := a + (eng.rng_f64(rng) < 0.5 ? -1.0 : 1.0) * rr(rng, 0.6, 1.0)
		e2 := mid + dir_at(a2, rr(rng, 0.9, 1.3)) * (reach * 0.5)
		e2.y = min(e2.y, c.y + H - rl * 0.4)
		if H >= 15 do add_seg(s, mid, e2, twig)
		add_blob(s, e2 + V{0, rl * 0.15, 0}, rl * 0.75, rl * 0.45, 0.9)
	}
	add_blob(s, lead + V{0, 0.5, 0}, rl, rl * 0.55, 0.92)
	return bole
}

// Отладка (-spawn:tree): у ближайшего большого лиственного дерева, лицом к нему.
find_tree_spawn :: proc(w: ^World, cx, cz: i32) -> (pos: [3]f64, yaw: f32, ok: bool) {
	face := w.geo.face
	best: Tree
	best_d := max(f64)
	for gz in eng.floor_div(cz - 300, TREE_CELL) ..= eng.floor_div(cz + 300, TREE_CELL) {
		for gx in eng.floor_div(cx - 300, TREE_CELL) ..= eng.floor_div(cx + 300, TREE_CELL) {
			t, has := tree_in_cell(w, face, gx, gz)
			if !has || (t.kind != .Oak && t.kind != .Birch) || t.height < 14 do continue
			d := math.hypot(f64(t.x - cx), f64(t.z - cz))
			if d < best_d do best, best_d = t, d
		}
	}
	if best_d == max(f64) do return
	for k in 0 ..< 24 {
		a := f64(k) / 24 * math.TAU
		dist := f64(best.crown) + 6
		x := best.x + i32(math.round(math.cos(a) * dist))
		z := best.z + i32(math.round(math.sin(a) * dist))
		h := terrain_height(i64(w.seed), geo_point(&w.geo, face, x, z))
		if h <= SEA_LEVEL + 1 || tree_in_the_way(w, face, x, h + 1, z) do continue
		pos = {f64(x) + 0.5, f64(h) + 1, f64(z) + 0.5}
		yaw = f32(math.atan2(-(f64(best.x) - f64(x)), f64(best.z) - f64(z)))
		return pos, yaw, true
	}
	return
}

// Что растёт здесь и до какой высоты (F3, страница климата).
zone_trees_text :: proc(bc: ^Block_Climate) -> string {
	dry := f64(bc.tint & 15) / 15
	h :: proc(k: Tree_Kind, bc: ^Block_Climate, dry: f64) -> f64 {return tree_site_height(k, bc.t_max, dry)}
	#partial switch bc.k.biome {
	case .Temperate_Forest:
		if bc.k.code[0] == 'D' do return fmt.tprintf("лес: дуб (до ~%.0f м), берёза (до ~%.0f м), ель (до ~%.0f м)", h(.Oak, bc, dry), h(.Birch, bc, dry), h(.Spruce, bc, dry))
		return fmt.tprintf("лес: дуб (до ~%.0f м) и берёза (до ~%.0f м)", h(.Oak, bc, dry), h(.Birch, bc, dry))
	case .Taiga:
		return fmt.tprintf("тайга: ель (до ~%.0f м) и берёза (до ~%.0f м)", h(.Spruce, bc, dry), h(.Birch, bc, dry))
	case .Mediterranean, .Steppe:
		return fmt.tprintf("редкие деревья: дуб (до ~%.0f м), берёза", h(.Oak, bc, dry))
	case .Savanna:
		return fmt.tprintf("редкие акации до ~%.0f м с плоской кроной", h(.Acacia, bc, dry))
	case .Rainforest:
		hh := h(.Jungle, bc, dry)
		return fmt.tprintf("тропический лес: полог до ~%.0f м, великаны до ~%.0f м", hh, hh * 1.35)
	case .Desert_Hot:
		return "деревьев нет — слишком сухо; редкие кактусы"
	case .Desert_Cold:
		return "деревьев нет — слишком сухо"
	case .Tundra, .Ice_Cap:
		return "деревьев нет — лето холоднее 10 °C"
	}
	return ""
}

// Голые ли сейчас лиственные кроны там, где стоит игрок: при похолодании
// листья опадают ниже ~6 °C, весной распускаются выше ~8 °C (как в шейдере, в
// среднем по деревьям). С запасом в полградуса — чтобы не переключаться туда-сюда.
leaves_bare_at :: proc(w: ^World, pos: [3]f64, season: f64) -> bool {
	if !climate.ok do return false
	face, gx, gz, ok := world_resolve(w, i32(math.floor(pos.x)), i32(math.floor(pos.z)))
	if !ok do return w.bare
	col, _ := ensure_column(w, column_key_of(face, gx, gz))
	t, _ := climate_at(&climate, &col.clim, season)
	t1, _ := climate_at(&climate, &col.clim, season + 1.0 / 24)
	t0, _ := climate_at(&climate, &col.clim, season - 1.0 / 24)
	t -= climate.lapse * max(pos.y - Y_SEA, 0)
	limit := t1 - t0 < 0 ? 6.0 : 8.0
	return t < limit + (w.bare ? 0.5 : -0.5)
}

// Самопроверка деревьев (-selftest) в квадрате 600×600 м вокруг (cx, cz):
// форма дерева одна и та же, как его ни режь на секции; ни один блок дерева не
// выходит за его заявленный размах (иначе соседняя колонка его не увидит);
// у колонок не переполняется список деревьев; статистика леса.
trees_selftest :: proc(w: ^World, cx, cz: f64) -> (errors: int) {
	face := w.geo.face
	HALF :: 300
	x0, z0 := i32(cx) - HALF, i32(cz) - HALF
	count, thick, fins, checked, canopy, under, thin: int
	canopy_h: f64
	h_sum, h_max: f64
	kinds: [Tree_Kind]int
	Collect :: struct {
		blocks: map[[3]i32]Block,
	}
	add :: proc(data: rawptr, x, y, z: i32, b: Block) {
		c := (^Collect)(data)
		if _, has := c.blocks[{x, y, z}]; !has do c.blocks[{x, y, z}] = b
	}
	for gz in eng.floor_div(z0, TREE_CELL) ..= eng.floor_div(z0 + 2 * HALF, TREE_CELL) {
		for gx in eng.floor_div(x0, TREE_CELL) ..= eng.floor_div(x0 + 2 * HALF, TREE_CELL) {
			t, ok := tree_in_cell(w, face, gx, gz)
			if !ok do continue
			count += 1
			kinds[t.kind] += 1
			h_sum += f64(t.height)
			h_max = max(h_max, f64(t.height))
			if t.girth == 2 do thick += 1
			if t.under do under += 1
			if t.thin do thin += 1
			if !t.under && t.kind != .Cactus {
				canopy += 1
				canopy_h += f64(t.height)
			}
			if t.fins > 0 do fins += 1
			if checked >= 60 || t.height < 6 do continue
			checked += 1
			// целиком
			whole := Collect{make(map[[3]i32]Block, 1024, context.temp_allocator)}
			big := i32(CROWN_MAX) + 20
			tree_blocks(t, {t.x - big, t.base - 20, t.z - big}, {t.x + big, t.base + i32(t.height) + 20, t.z + big}, &whole, add)
			// по секциям 16³
			parts := Collect{make(map[[3]i32]Block, 1024, context.temp_allocator)}
			for sy in eng.floor_div(t.base - 20, CHUNK_SIZE) ..= eng.floor_div(t.base + i32(t.height) + 20, CHUNK_SIZE) {
				for sz in eng.floor_div(t.z - big, CHUNK_SIZE) ..= eng.floor_div(t.z + big, CHUNK_SIZE) {
					for sx in eng.floor_div(t.x - big, CHUNK_SIZE) ..= eng.floor_div(t.x + big, CHUNK_SIZE) {
						lo := [3]i32{sx, sy, sz} * CHUNK_SIZE
						tree_blocks(t, lo, lo + CHUNK_SIZE, &parts, add)
					}
				}
			}
			if len(whole.blocks) != len(parts.blocks) do errors += 1
			reach := i32(t.crown) + 3 + i32(t.girth)
			for p, b in whole.blocks {
				if parts.blocks[p] != b do errors += 1
				if abs(p.x - t.x) > reach || abs(p.z - t.z) > reach || p.y < t.base - 4 || p.y > t.base + i32(t.height) + 3 {
					errors += 1
				}
			}
		}
	}
	// колонки вокруг: список деревьев не переполнен
	most := 0
	col := new(Column)
	defer free(col)
	ccx, ccz := eng.floor_div(i32(cx), CHUNK_SIZE), eng.floor_div(i32(cz), CHUNK_SIZE)
	for dz in i32(-6) ..= 6 do for dx in i32(-6) ..= 6 {
		col.key = {face, ccx + dx, ccz + dz}
		column_trees(w, col)
		most = max(most, col.tree_n)
		if col.tree_n >= MAX_COL_TREES do errors += 1
	}
	ha := f64(2 * HALF) * f64(2 * HALF) / 10_000
	sb := make([dynamic]u8, context.temp_allocator)
	for k in Tree_Kind do if kinds[k] > 0 do append(&sb, ..transmute([]u8)fmt.tprintf(" %s %d,", TREE_NAMES[k], kinds[k]))
	fmt.printfln("деревья (%.0f га вокруг): %.0f стволов на гектар — в пологе %.0f (высота в среднем %.1f м), подрост в тени %.0f; высота до %.1f м; тонких стволов (<45 см) %.0f%%, толстых (2×2) %.1f%%, с досковидными корнями %.1f%%;%s формы %d деревьев по секциям, в колонке до %d деревьев (предел %d), ошибок %d",
		ha, f64(count) / ha, f64(canopy) / ha, canopy_h / max(f64(canopy), 1), f64(under) / ha, h_max, f64(thin) * 100 / max(f64(count), 1), f64(thick) * 100 / max(f64(count), 1), f64(fins) * 100 / max(f64(count), 1),
		string(sb[:]), checked, most, MAX_COL_TREES, errors)
	return
}

// Клетки, через которые проходит отрезок a–b (все, по порядку; 3D DDA), и доля
// отрезка [t0, t1] внутри каждой — для тонких ветвей: блоки и их сетка
// совпадают с настоящей линией ветви.
seg_walk :: proc(a, b: [3]f64, data: rawptr, visit: proc(data: rawptr, cell: [3]i32, t0, t1: f64)) {
	d := b - a
	cell := [3]i32{i32(math.floor(a.x)), i32(math.floor(a.y)), i32(math.floor(a.z))}
	last := [3]i32{i32(math.floor(b.x)), i32(math.floor(b.y)), i32(math.floor(b.z))}
	step: [3]i32
	t_max, t_delta: [3]f64
	for k in 0 ..< 3 {
		if d[k] > 1e-12 {
			step[k] = 1
			t_max[k] = (f64(cell[k]) + 1 - a[k]) / d[k]
			t_delta[k] = 1 / d[k]
		} else if d[k] < -1e-12 {
			step[k] = -1
			t_max[k] = (f64(cell[k]) - a[k]) / d[k]
			t_delta[k] = -1 / d[k]
		} else {
			t_max[k] = 1.0e30
			t_delta[k] = 1.0e30
		}
	}
	t := 0.0
	for _ in 0 ..< 512 {
		k := 0
		if t_max[1] < t_max[k] do k = 1
		if t_max[2] < t_max[k] do k = 2
		t1 := min(t_max[k], 1)
		if t1 > t do visit(data, cell, t, t1)
		if cell == last || t_max[k] >= 1 do return
		t = t_max[k]
		cell[k] += step[k]
		t_max[k] += t_delta[k]
	}
}
