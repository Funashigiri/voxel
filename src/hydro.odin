package main

// Реки и озёра (0.019): сеть стока на всю планету.
//
// На каждой грани куба — сетка M×M клеток (~10 км; равноугольная, как сетка
// блоков). В клетке — средняя высота рельефа и размах деталей мельче клетки
// (relief.odin), климат и сток:
//  * сток за год — осадки минус испарение по кривой Будыко в форме Фу
//    (w = 2,6), возможное испарение — по свету и теплу месяцев (Харгривс);
//    с глади озера испаряется в 1,2 раза больше;
//  * вода течёт к морю: впадины заполняются от берегов океана вглубь суши
//    (Priority-Flood, Barnes и др., 2014), каждая клетка стекает в ту, от
//    которой до неё дошла «вода» — к самой низкой соседке, через впадины к их
//    порогу;
//  * впадина — озеро: если притока хватает покрыть испарение с полной глади,
//    оно переливается через порог и из него вытекает река; если нет — озеро
//    бессточное, его уровень там, где испарение с глади равно притоку; совсем
//    малое в сухом краю — солончак (такие озёра пересыхают);
//  * реки на клетках — расход (м³/с) из сложенного стока; их гладь идёт ниже
//    средней высоты на размах мелкого рельефа (реки текут по низинам и врезаны
//    в долины), вниз по течению не поднимается.
// Впадины ниже уровня моря, не связанные с океаном, — не море: в них вода
// только по своему балансу (как Каспий или Мёртвое море), иначе суша.
// Сеть считается один раз при старте, на всех ядрах; дальше только читается.
// Русла, долины и берега в блоках и дальнем рельефе — hydro_shape.odin.

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"

import "core:thread"
import "core:time"

HYDRO_CELL :: 10_000.0 // м: размер клетки сети стока (на большой планете)
HYDRO_MAX_M :: 1024
HYDRO_OCEAN_MIN :: 1.0e12 // м²: впадина ниже уровня моря меньше этого — не океан (узкие проливы на сетке не видны)
HYDRO_FU_W :: 2.6 // кривая Будыко (Фу): средняя для лесов и лугов
HYDRO_LAKE_E :: 1.2 // испарение с глади озера — больше, чем с травы (Penman E0 против ET0)
HYDRO_EPS :: 0.002 // м: подъём дна заполненной впадины на клетку (чтобы сток шёл к порогу)
HYDRO_PLAYA :: 0.01 // бессточное озеро меньше этой доли своего водосбора — солончак (пересыхает)
HYDRO_BREACH_K :: 20.0 // м на √(м³/с): так глубоко река пропиливает порог впадины за геологическое время
HYDRO_PLUVIAL_P :: 1.5 // влажные эпохи прошлого (плювиалы ледниковий): осадков больше в полтора раза
HYDRO_PLUVIAL_E :: 0.9 // и холоднее — испарялось меньше

Hydro_Kind :: enum u8 {
	Land,
	Ocean,
	Lake,
	Salt, // солончак — дно пересыхающего бессточного озера
}

Hydro_Stats :: struct {
	build_s:         f64,
	land_cells:      int,
	ocean_cells:     int,
	lake_cells:      int,
	salt_cells:      int,
	lakes, closed:   int, // озёр всего и бессточных
	playas:          int,
	endorheic_area:  f64, // м²: суша, что стекает в бессточные озёра
	land_area:       f64,
	lake_area:       f64,
	runoff_land:     f64, // м³/год стока со всей суши
	runoff_in:       f64, // м³/год: сток с суши и баланс глади озёр (бессточные — около нуля)
	to_ocean:        f64, // м³/год рек в океан
	lost_lakes:      f64, // м³/год: столько стекает в бессточные озёра (и испаряется там)
	big:             [8]Hydro_River, // крупнейшие реки (у устья)
	mouths:          [dynamic]Hydro_River, // устья рек с водосбором больше 1000 км²
	mean_runoff_mm:  f64,
	rivers:          int, // клеток с реками
	perched:         [3]int, // из них гладь выше своей отметки на 20, 50, 100 м
	arid_area:       [5]f64, // м² суши по засушливости (крайне сухо, сухо, полусухо, сухо-влажно, влажно)
	arid_endo:       [5]f64, // из неё — бессточной
	arid_to:         [5][5]f64, // бессточная по засушливости у самого озера
	depth_catch:     [6]f64, // водосбор бессточных впадин по их глубине: <25, <50, <100, <200, <400, больше м
}

Hydro_River :: struct {
	q:      f64, // м³/с у устья
	area:   f64, // м² водосбора
	length: f64, // м: от самого дальнего истока
	mouth:  int, // клетка устья
}

Hydro_Map :: struct {
	ok:     bool,
	m:      int, // клеток на ребро грани
	radius: f64,
	cell:   f64, // м: клетка в середине грани
	seed:   i64,
	year_s: f64, // секунд в году планеты
	gen:    u32, // меняется при каждой постройке (кэши потоков)
	kind:   []Hydro_Kind,
	rcv:    []u8, // куда течёт (0…7 — соседи D8), 255 — никуда
	level:  []f32, // м над морем: гладь реки, уровень озера, 0 — море
	q:      []f32, // расход из клетки, м³/с
	wetc:   []u8, // болота (0.020): класс климата (младшие 3 бита: Wet_Class) | 16 — у моря мангры | 32 — у моря марши
	gw:     []u8, // подъём грунтовых вод над местным дном, по 5 см (бугор Дюпюи между ручьями)
	ai:     []u8, // осадки к возможному испарению в низинах клетки, по 0,02 (местные колебания — в hydro_shape)
	border: [][8]i32, // соседи клеток у рёбер граней (через рёбра — на другой грани)
	edge:   []bool, // клетка у ребра грани (соседи — по таблице border)
	doff:   [8]int, // сдвиг номера к соседу у внутренних клеток
	stats:  Hydro_Stats,
}

// Сеть стока мира — строится один раз при старте, до фоновых потоков.
hydro: Hydro_Map

// Соседи D8: (di, dj) по осям грани.
HD := [8][2]i32{{1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}, {0, -1}, {1, -1}}

// ---------------------------------------------------------------- геометрия сетки

// Направление от центра планеты для точки (x, z) грани в клетках сетки (можно за краем).
hydro_dir_at :: proc "contextless" (m: int, face: Cube_Face, x, z: f64) -> [3]f64 {
	a := (x / f64(m) * 2 - 1) * (math.PI / 4)
	b := (z / f64(m) * 2 - 1) * (math.PI / 4)
	fb := FACE_BASES[face]
	d := fb.n + fb.u * math.tan(a) + fb.v * math.tan(b)
	return d / math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
}

// Грань и место (в клетках, непрерывно) направления dir.
hydro_locate :: proc "contextless" (m: int, dir: [3]f64) -> (face: Cube_Face, x, z: f64) {
	ax, ay, az := abs(dir.x), abs(dir.y), abs(dir.z)
	switch {
	case ax >= ay && ax >= az:
		face = dir.x > 0 ? .PX : .NX
	case ay >= az:
		face = dir.y > 0 ? .PY : .NY
	case:
		face = dir.z > 0 ? .PZ : .NZ
	}
	fb := FACE_BASES[face]
	dn := dir.x * fb.n.x + dir.y * fb.n.y + dir.z * fb.n.z
	t := (dir.x * fb.u.x + dir.y * fb.u.y + dir.z * fb.u.z) / dn
	s := (dir.x * fb.v.x + dir.y * fb.v.y + dir.z * fb.v.z) / dn
	x = (math.atan(t) / (math.PI / 4) + 1) / 2 * f64(m)
	z = (math.atan(s) / (math.PI / 4) + 1) / 2 * f64(m)
	return
}

hydro_index :: #force_inline proc "contextless" (m: int, face: Cube_Face, i, j: int) -> int {
	return (int(face) * m + j) * m + i
}

hydro_cell_dir :: proc "contextless" (h: ^Hydro_Map, idx: int) -> [3]f64 {
	m := h.m
	face := Cube_Face(idx / (m * m))
	r := idx % (m * m)
	return hydro_dir_at(m, face, f64(r % m) + 0.5, f64(r / m) + 0.5)
}

// Площадь клетки, м² (у рёбер граней клетки меньше).
hydro_cell_area :: proc "contextless" (h: ^Hydro_Map, idx: int) -> f64 {
	m := h.m
	r := idx % (m * m)
	da := math.PI / 2 / f64(m)
	ta := math.tan((((f64(r % m) + 0.5) / f64(m)) * 2 - 1) * (math.PI / 4))
	tb := math.tan((((f64(r / m) + 0.5) / f64(m)) * 2 - 1) * (math.PI / 4))
	s := 1 + ta * ta + tb * tb
	return h.radius * h.radius * da * da * (1 + ta * ta) * (1 + tb * tb) / (s * math.sqrt(s))
}

// Номер клетки у ребра в таблице соседей (-1 — внутренняя).
@(private = "file")
border_slot :: #force_inline proc "contextless" (m, idx: int) -> int {
	f := idx / (m * m)
	r := idx % (m * m)
	i, j := r % m, r / m
	switch {
	case j == 0:
		return f * 4 * m + i
	case j == m - 1:
		return f * 4 * m + m + i
	case i == 0:
		return f * 4 * m + 2 * m + j
	case i == m - 1:
		return f * 4 * m + 3 * m + j
	}
	return -1
}

// Сосед k (D8) клетки idx; -1 — нет (у вершины куба сосед может совпасть с другим).
hydro_nb :: #force_inline proc "contextless" (h: ^Hydro_Map, idx, k: int) -> int {
	if !h.edge[idx] do return idx + h.doff[k]
	return int(h.border[border_slot(h.m, idx)][k])
}

@(private = "file")
build_border :: proc(h: ^Hydro_Map) {
	m := h.m
	h.border = make([][8]i32, 6 * 4 * m)
	h.edge = make([]bool, 6 * m * m)
	for k in 0 ..< 8 do h.doff[k] = int(HD[k][1]) * m + int(HD[k][0])
	for face in Cube_Face {
		for j in 0 ..< m do for i in 0 ..< m {
			if i > 0 && j > 0 && i < m - 1 && j < m - 1 do continue
			idx := hydro_index(m, face, i, j)
			slot := border_slot(m, idx)
			h.edge[idx] = true
			for k in 0 ..< 8 {
				i2, j2 := i + int(HD[k][0]), j + int(HD[k][1])
				if i2 >= 0 && j2 >= 0 && i2 < m && j2 < m {
					h.border[slot][k] = i32(hydro_index(m, face, i2, j2))
					continue
				}
				// за ребром: точка продолжения сетки -> её клетка на соседней грани
				d := hydro_dir_at(m, face, f64(i2) + 0.5, f64(j2) + 0.5)
				nf, x, z := hydro_locate(m, d)
				ni := clamp(int(x), 0, m - 1)
				nj := clamp(int(z), 0, m - 1)
				n := hydro_index(m, nf, ni, nj)
				h.border[slot][k] = n == idx ? -1 : i32(n)
			}
		}
	}
}

// ---------------------------------------------------------------- параллельно

@(private = "file")
Par_Job :: struct {
	data: rawptr,
	k, n: int,
	fn:   proc(data: rawptr, k, n: int),
}

@(private = "file")
par_for :: proc(data: rawptr, fn: proc(data: rawptr, k, n: int)) {
	n := clamp(os.get_processor_core_count(), 1, 16)
	jobs := make([]Par_Job, n, context.temp_allocator)
	threads := make([]^thread.Thread, n, context.temp_allocator)
	for k in 0 ..< n {
		jobs[k] = {data, k, n, fn}
		threads[k] = thread.create_and_start_with_data(&jobs[k], proc(p: rawptr) {
			j := (^Par_Job)(p)
			j.fn(j.data, j.k, j.n)
		})
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
}

// ---------------------------------------------------------------- постройка

@(private = "file")
Build :: struct {
	h:       ^Hydro_Map,
	elev:    []f32, // средняя высота клетки, м
	amp:     []f32, // размах деталей мельче клетки, м
	runoff:  []f32, // сток с суши, мм/год
	pe:      []f32, // осадки минус испарение с глади, мм/год
	runoff_w, pe_w: []f32, // то же во влажную эпоху прошлого
	arid:    []u8, // засушливость: 0 — крайне сухо … 4 — влажно (осадки к возможному испарению)
	floor:   []f32, // дно пути реки в клетке (самое низкое место рельефа на пути к узлу ниже), м
	cg:      int, // узлов климата на ребро грани (сетка cg×cg клеток)
	cpts:    []Climate_Point,
	tab:     ^Climate_Month_Table,
	month_days: f64, // земных суток в месяце планеты
}

// Высоты клеток (на всех ядрах).
@(private = "file")
build_elev :: proc(data: rawptr, k, n: int) {
	b := (^Build)(data)
	h := b.h
	total := 6 * h.m * h.m
	for idx := k; idx < total; idx += n {
		p := hydro_cell_dir(h, idx) * h.radius
		e, amp := elevation_amp(h.seed, p, h.cell)
		b.elev[idx] = f32(e)
		b.amp[idx] = f32(amp)
	}
}

// Условия места (материковость, влажность) в узлах грубой сетки.
@(private = "file")
build_climate_nodes :: proc(data: rawptr, k, n: int) {
	b := (^Build)(data)
	h := b.h
	g := b.cg + 1
	for idx := k; idx < 6 * g * g; idx += n {
		face := Cube_Face(idx / (g * g))
		r := idx % (g * g)
		x := f64(r % g) / f64(b.cg) * f64(h.m)
		z := f64(r / g) / f64(b.cg) * f64(h.m)
		p := hydro_dir_at(h.m, face, x, z) * h.radius
		b.cpts[idx] = climate_point(&climate, h.seed, p, elevation(h.seed, p, h.cell))
	}
}

// Сток и испарение с глади в клетках.
@(private = "file")
build_runoff :: proc(data: rawptr, k, n: int) {
	b := (^Build)(data)
	h := b.h
	m := h.m
	g := b.cg + 1
	total := 6 * m * m
	for idx := k; idx < total; idx += n {
		face := idx / (m * m)
		r := idx % (m * m)
		u := (f64(r % m) + 0.5) / f64(m) * f64(b.cg)
		v := (f64(r / m) + 0.5) / f64(m) * f64(b.cg)
		a0 := min(int(u), b.cg - 1)
		b0 := min(int(v), b.cg - 1)
		fu, fv := u - f64(a0), v - f64(b0)
		base := face * g * g
		c00 := &b.cpts[base + b0 * g + a0]
		c10 := &b.cpts[base + b0 * g + a0 + 1]
		c01 := &b.cpts[base + (b0 + 1) * g + a0]
		c11 := &b.cpts[base + (b0 + 1) * g + a0 + 1]
		bil :: proc "contextless" (a, b, c, d, fu, fv: f64) -> f64 {
			return (a * (1 - fu) + b * fu) * (1 - fv) + (c * (1 - fu) + d * fu) * fv
		}
		cont := bil(c00.cont, c10.cont, c01.cont, c11.cont, fu, fv)
		wet := bil(c00.wet, c10.wet, c01.wet, c11.wet, fu, fv)
		d := hydro_cell_dir(h, idx)
		lat := math.to_degrees(math.asin(clamp(d.y, -1, 1)))
		alt := max(f64(b.elev[idx]), 0)
		t, p, ra := climate_months_tab(&climate, b.tab, lat, cont, wet, alt)
		P := 0.0
		for mo in 0 ..< 12 do P += p[mo]
		PET := hydro_pet(ra, t, P, cont, b.month_days)
		b.runoff[idx] = f32(hydro_fu_runoff(P, PET))
		ai := P / max(PET, 1)
		b.arid[idx] = ai < 0.05 ? 0 : ai < 0.2 ? 1 : ai < 0.5 ? 2 : ai < 0.65 ? 3 : 4
		b.pe[idx] = f32(P - HYDRO_LAKE_E * PET)
		// болота: грунтовые воды и климат болот — в низинах клетки (там и болота;
		// там теплее, чем на средней её высоте, и испарение больше)
		to, _, _ := climate_months_tab(&climate, b.tab, lat, 0, 1, 0) // море у этой широты
		tw := t
		for &tm in tw do tm += climate.lapse * (alt - max(f64(b.elev[idx] - b.amp[idx]), 0))
		pet_w := hydro_pet(ra, tw, P, cont, b.month_days)
		h.wetc[idx] = hydro_wet_class(tw, to, P, pet_w)
		h.ai[idx] = u8(clamp(P / max(pet_w, 1) * 50, 0, 255))
		h.gw[idx] = u8(clamp(hydro_mound(f64(b.runoff[idx]), Wet_Class(h.wetc[idx] & 7)) / 0.05, 0, 255))
		// влажная эпоха прошлого (плювиал): ею прорезаны пороги впадин
		b.runoff_w[idx] = f32(hydro_fu_runoff(P * HYDRO_PLUVIAL_P, PET * HYDRO_PLUVIAL_E))
		b.pe_w[idx] = f32(P * HYDRO_PLUVIAL_P - HYDRO_LAKE_E * PET * HYDRO_PLUVIAL_E)
	}
}

// Сток за год (мм) по осадкам и возможному испарению — кривая Будыко (Фу, 1981).
hydro_fu_runoff :: proc "contextless" (P, PET: f64) -> f64 {
	if P <= 0 do return 0
	if PET <= 0 do return P
	phi := PET / P
	return P * (math.pow(1 + math.pow(phi, HYDRO_FU_W), 1 / HYDRO_FU_W) - phi)
}

// Очередь с приоритетом (меньше высота — раньше).
@(private = "file")
Heap_Item :: struct {
	key: f32,
	idx: i32,
}

@(private = "file")
heap_push :: proc(hp: ^[dynamic]Heap_Item, it: Heap_Item) {
	append(hp, it)
	i := len(hp) - 1
	for i > 0 {
		p := (i - 1) / 2
		if hp[p].key <= it.key do break
		hp[i] = hp[p]
		i = p
	}
	hp[i] = it
}

@(private = "file")
heap_pop :: proc(hp: ^[dynamic]Heap_Item) -> Heap_Item {
	top := hp[0]
	last := pop(hp)
	n := len(hp)
	if n == 0 do return top
	i := 0
	for {
		c := 2 * i + 1
		if c >= n do break
		if c + 1 < n && hp[c + 1].key < hp[c].key do c += 1
		if hp[c].key >= last.key do break
		hp[i] = hp[c]
		i = c
	}
	hp[i] = last
	return top
}

@(private = "file")
Lake :: struct {
	sill:     i32, // клетка порога (через неё переливается)
	level:    f32, // уровень при полной глади (порог)
	cells:    i32, // клеток во впадине
	area:     f64, // м²
	pe:       f64, // м³/год: осадки минус испарение со всей глади
	inflow:   f64, // м³/год притока с суши
	inflow_w: f64, // то же во влажную эпоху прошлого
	pe_w:     f64,
	catch:    f64, // м² водосбора (без самой впадины)
	runoff:   f64, // м³/год стока с самих клеток впадины, будь они сушей
	closed:   bool,
	playa:    bool,
	final:    f32, // уровень бессточного озера
	first:    i32, // клетки впадины — в общем списке
}

// Строит сеть стока для мира (relief и climate уже заданы).
hydro_build :: proc(seed: u32, radius: f64, full_stats := false) {
	t_start := time.now()
	hydro_free()
	h := &hydro
	h.seed = i64(seed)
	h.radius = radius
	face_len := radius * math.PI / 2
	h.m = clamp(int(math.round(face_len / HYDRO_CELL)), 64, HYDRO_MAX_M)
	h.cell = face_len / f64(h.m)
	h.year_s = climate.year_h * 3600
	h.gen += 1
	m := h.m
	N := 6 * m * m
	build_border(h)

	b: Build
	b.h = h
	b.elev = make([]f32, N)
	b.amp = make([]f32, N)
	b.runoff = make([]f32, N)
	b.pe = make([]f32, N)
	b.arid = make([]u8, N)
	b.runoff_w = make([]f32, N)
	b.pe_w = make([]f32, N)
	defer {
		delete(b.elev)
		delete(b.amp)
		delete(b.runoff)
		delete(b.pe)
		delete(b.arid)
		delete(b.runoff_w)
		delete(b.pe_w)
		delete(b.floor)
	}
	par_for(&b, build_elev)
	t_elev := time.now()
	b.cg = max(m / 16, 4)
	b.cpts = make([]Climate_Point, 6 * (b.cg + 1) * (b.cg + 1))
	defer delete(b.cpts)
	tab := new(Climate_Month_Table)
	defer free(tab)
	climate_month_table(&climate, tab)
	b.tab = tab
	b.month_days = climate.year_h / 24 / 12 // месяц планеты длиннее — испаряется больше
	h.wetc = make([]u8, N)
	h.gw = make([]u8, N)
	h.ai = make([]u8, N)
	par_for(&b, build_climate_nodes)
	par_for(&b, build_runoff)
	t_clim := time.now()

	h.kind = make([]Hydro_Kind, N)
	h.rcv = make([]u8, N)
	h.level = make([]f32, N)
	h.q = make([]f32, N)
	area := make([]f32, N)
	defer delete(area)
	for idx in 0 ..< N do area[idx] = f32(hydro_cell_area(h, idx))

	// океан: связные места ниже уровня моря, большие (меньшие — впадины на суше)
	{
		comp := make([]i32, N)
		defer delete(comp)
		for &c in comp do c = -1
		stack := make([dynamic]i32)
		defer delete(stack)
		members := make([dynamic]i32)
		defer delete(members)
		for s in 0 ..< N {
			if b.elev[s] >= 0 || comp[s] >= 0 do continue
			clear(&members)
			comp[s] = i32(s)
			append(&stack, i32(s))
			sum := 0.0
			for len(stack) > 0 {
				c := int(pop(&stack))
				append(&members, i32(c))
				sum += f64(area[c])
				for k in 0 ..< 8 {
					nb := hydro_nb(h, c, k)
					if nb < 0 || comp[nb] >= 0 || b.elev[nb] >= 0 do continue
					comp[nb] = i32(s)
					append(&stack, i32(nb))
				}
			}
			if sum >= HYDRO_OCEAN_MIN {
				for c in members do h.kind[c] = .Ocean
			}
		}
	}

	t_ocean := time.now()
	// заполнение впадин от берегов океана (Priority-Flood + ε)
	F := make([]f32, N) // уровень заполненной поверхности
	rcv := make([]i32, N) // -2 — не дошли, -1 — исток (море)
	order := make([dynamic]i32, 0, N) // порядок прихода: куда течёт — всегда раньше
	flooded := make([]bool, N)
	rk := make([]u8, N) // направление стока (0…7) — к клетке, от которой пришла вода
	defer {
		delete(F)
		delete(rcv)
		delete(order)
		delete(flooded)
		delete(rk)
	}
	heap := make([dynamic]Heap_Item, 0, 1 << 20)
	defer delete(heap)
	pit := make([dynamic]i32, 0, 1 << 16)
	defer delete(pit)
	for idx in 0 ..< N do rcv[idx] = -2
	seeds := 0
	for idx in 0 ..< N {
		if h.kind[idx] != .Ocean do continue
		rcv[idx] = -1
		F[idx] = 0
		seeds += 1
		for k in 0 ..< 8 {
			nb := hydro_nb(h, idx, k)
			if nb >= 0 && h.kind[nb] != .Ocean {
				heap_push(&heap, {0, i32(idx)})
				break
			}
		}
	}
	if seeds == 0 {
		// океана нет: сток — в самую низкую точку планеты
		low := 0
		for idx in 0 ..< N do if b.elev[idx] < b.elev[low] do low = idx
		rcv[low] = -1
		F[low] = b.elev[low]
		append(&order, i32(low))
		heap_push(&heap, {F[low], i32(low)})
	}
	pit_head := 0
	for {
		c: int
		if pit_head < len(pit) {
			c = int(pit[pit_head])
			pit_head += 1
		} else if len(heap) > 0 {
			clear(&pit)
			pit_head = 0
			c = int(heap_pop(&heap).idx)
		} else {
			break
		}
		fc := F[c]
		for k in 0 ..< 8 {
			nb := hydro_nb(h, c, k)
			if nb < 0 || rcv[nb] != -2 do continue
			rcv[nb] = i32(c)
			// куда течёт nb — обратное направление (через ребро грани сетка повёрнута)
			rk[nb] = u8((k + 4) & 7)
			if h.edge[nb] {
				for kk in 0 ..< 8 do if hydro_nb(h, nb, kk) == c do rk[nb] = u8(kk)
			}
			append(&order, i32(nb))
			// у самого моря впадин нет: низкий берег стекает прямо в него
			if b.elev[nb] <= fc + HYDRO_EPS && h.kind[c] != .Ocean {
				F[nb] = fc + HYDRO_EPS
				flooded[nb] = true
				append(&pit, i32(nb))
			} else {
				F[nb] = b.elev[nb]
				heap_push(&heap, {F[nb], i32(nb)})
			}
		}
	}
	t_flood := time.now()

	// впадины: каждая заполненная клетка относится к порогу, через который стекает
	lake_of := make([]i32, N)
	defer delete(lake_of)
	for &l in lake_of do l = -1
	lakes := make([dynamic]Lake)
	defer delete(lakes)
	sill_lake := make([]i32, N) // у порога — номер его озера, иначе −1
	defer delete(sill_lake)
	for &s in sill_lake do s = -1
	for c in order {
		if !flooded[c] do continue
		r := rcv[c]
		if flooded[r] {
			lake_of[c] = lake_of[r]
		} else {
			id := sill_lake[r]
			if id < 0 {
				id = i32(len(lakes))
				append(&lakes, Lake{sill = r, level = F[r]})
				sill_lake[r] = id
			}
			lake_of[c] = id
		}
		lakes[lake_of[c]].cells += 1
	}
	// клетки впадин — подряд по озёрам
	{
		pos := i32(0)
		for &l in lakes {
			l.first = pos
			pos += l.cells
			l.cells = 0
		}
	}
	lake_cells := make([]i32, max(len(order), 1))
	defer delete(lake_cells)
	for c in order {
		if lake_of[c] < 0 do continue
		l := &lakes[lake_of[c]]
		lake_cells[l.first + l.cells] = c
		l.cells += 1
	}

	t_groups := time.now()
	// сток вниз по течению (против порядка прихода); на пороге — баланс озера.
	// Пороги впадин прорезаны во влажные эпохи прошлого (если тогда озеро
	// переливалось), уровни озёр — по нынешнему климату.
	acc := make([]f64, N) // м³/год, что вытекает из клетки
	acc_w := make([]f64, N) // то же во влажную эпоху
	acc_a := make([]f64, N) // м² водосбора
	defer {
		delete(acc)
		delete(acc_w)
		delete(acc_a)
	}
	for i := len(order) - 1; i >= 0; i -= 1 {
		c := int(order[i])
		if flooded[c] {
			l := &lakes[lake_of[c]]
			a := f64(area[c])
			l.area += a
			l.pe += f64(b.pe[c]) * a / 1000
			l.runoff += f64(b.runoff[c]) * a / 1000
			l.inflow += acc[c]
			l.inflow_w += acc_w[c]
			l.pe_w += f64(b.pe_w[c]) * a / 1000
			l.catch += acc_a[c]
			continue
		}
		a := f64(area[c])
		acc[c] += f64(b.runoff[c]) * a / 1000
		acc_w[c] += f64(b.runoff_w[c]) * a / 1000
		acc_a[c] += a
		if id := sill_lake[c]; id >= 0 {
			l := &lakes[id]
			cells := lake_cells[l.first:l.first + l.cells]
			l.final = l.level
			if net_w := l.inflow_w + l.pe_w; net_w >= 0 {
				// переливалось: вытекавшая река пропилила порог — тем глубже, чем
				// была полноводнее (но не ниже воды, куда она течёт)
				base := f32(-1.0e9)
				for r := rcv[c]; r >= 0; r = rcv[r] {
					if h.kind[r] == .Ocean {
						base = 0
						break
					}
					if flooded[r] {
						base = lakes[lake_of[r]].level
						break
					}
				}
				l.final = max(l.level - f32(HYDRO_BREACH_K * math.sqrt(net_w / h.year_s)), base)
				nw := l.inflow_w
				for cc in cells {
					aa := f64(area[cc]) / 1000
					nw += b.elev[cc] < l.final ? f64(b.pe_w[cc]) * aa : f64(b.runoff_w[cc]) * aa
				}
				acc_w[c] += max(nw, 0)
			}
			// сейчас: озеро ниже пропиленного порога — испаряется меньше
			net := l.inflow
			for cc in cells {
				aa := f64(area[cc]) / 1000
				net += b.elev[cc] < l.final ? f64(b.pe[cc]) * aa : f64(b.runoff[cc]) * aa
			}
			if net >= 0 {
				acc[c] += net
				acc_a[c] += l.catch + l.area
			} else {
				l.closed = true
			}
		}
		if r := rcv[c]; r >= 0 && h.kind[r] != .Ocean {
			acc[r] += acc[c]
			acc_w[r] += acc_w[c]
			acc_a[r] += acc_a[c]
		}
	}
	t_acc := time.now()

	// бессточные озёра: уровень, где испарение с глади равно притоку
	st := &h.stats
	delete(st.mouths)
	st^ = {}
	for &l in lakes {
		cells := lake_cells[l.first:l.first + l.cells]
		if !l.closed {
			// проточное: под водой то, что ниже пропиленного порога; остальное —
			// осушенное дно, по нему течёт река (сток — по цепочке к порогу)
			#reverse for c in cells {
				a := f64(area[c]) / 1000
				wet := b.elev[c] < l.final
				if wet do h.kind[c] = .Lake
				acc[c] = max(acc[c] + (wet ? f64(b.pe[c]) : f64(b.runoff[c])) * a, 0)
				if r := rcv[c]; flooded[r] do acc[r] += acc[c]
				if !wet do h.q[c] = f32(acc[c] / h.year_s)
			}
			continue
		}
		hydro_sort_elev = b.elev
		slice.sort_by(cells, proc(a, b: i32) -> bool {return hydro_sort_elev[a] < hydro_sort_elev[b]})
		// f(k) = приток + Σ(k ниже уровня)(P − E)·a + Σ(остальные) сток·a
		f := l.inflow + l.runoff
		k := 0
		f_prev := f
		for k < len(cells) {
			c := cells[k]
			a := f64(area[c])
			nf := f - f64(b.runoff[c]) * a / 1000 + f64(b.pe[c]) * a / 1000
			if nf < 0 do break
			f_prev = nf
			f = nf
			k += 1
		}
		// доля следующей клетки под водой
		frac := 0.0
		if k < len(cells) {
			c := cells[k]
			a := f64(area[c])
			nf := f - f64(b.runoff[c]) * a / 1000 + f64(b.pe[c]) * a / 1000
			frac = clamp(f_prev / max(f_prev - nf, 1e-9), 0, 1)
		}
		// не выше порога (пропиленного или нет)
		if k == 0 {
			c := cells[0]
			l.final = min(b.elev[c] - b.amp[c] * f32(1 - 2 * frac), l.final)
		} else if k < len(cells) {
			lo, hi := b.elev[cells[k - 1]], b.elev[cells[k]]
			l.final = min(lo + (hi - lo) * f32(frac), l.final)
		}
		wet := frac * f64(area[cells[k]])
		for c in cells[:k] do wet += f64(area[c])
		l.playa = wet < HYDRO_PLAYA * (l.catch + l.area)
		// солончак — ровное дно котловины, засыпанное осадками: не ниже средней
		// высоты самой низкой клетки (ниже — корка соли, выше — острова)
		if l.playa do l.final = max(l.final, b.elev[cells[0]])
		for c in cells {
			if b.elev[c] < l.final || c == cells[0] {
				h.kind[c] = l.playa ? .Salt : .Lake
			}
		}
	}

	t_closed := time.now()
	// уровни: море 0, озёра — свой уровень; реки — ниже средней высоты на
	// размах мелкого рельефа, вниз по течению не поднимаются
	for idx in 0 ..< N {
		if h.kind[idx] == .Ocean {
			h.level[idx] = 0
			h.rcv[idx] = 255
		}
	}
	for &l in lakes {
		for c in lake_cells[l.first:l.first + l.cells] {
			if h.kind[c] == .Lake || h.kind[c] == .Salt do h.level[c] = l.final
		}
	}
	dir_code :: proc(h: ^Hydro_Map, c, r: int) -> u8 {
		for k in 0 ..< 8 do if hydro_nb(h, c, k) == r do return u8(k)
		return 255
	}
	// осушенные края бессточных озёр: вниз по склону к воде (от низких к высоким)
	for &l in lakes {
		if !l.closed do continue
		cells := lake_cells[l.first:l.first + l.cells]
		// клетки уже по возрастанию высоты
		for c in cells {
			if h.kind[c] != .Land do continue
			best, best_e := -1, b.elev[c]
			for k in 0 ..< 8 {
				nb := hydro_nb(h, int(c), k)
				if nb < 0 || lake_of[nb] != lake_of[c] do continue
				if b.elev[nb] < best_e {
					best, best_e = nb, b.elev[nb]
				}
			}
			if best < 0 {
				h.rcv[c] = 255 // ямка: вода в ней и остаётся (мала для сетки)
				continue
			}
			h.rcv[c] = dir_code(h, int(c), best)
		}
		// расход — сверху вниз
		#reverse for c in cells {
			if h.kind[c] != .Land do continue
			a := f64(area[c])
			acc[c] += f64(b.runoff[c]) * a / 1000
			h.q[c] = f32(acc[c] / h.year_s)
			if h.rcv[c] == 255 do continue
			r := hydro_nb(h, int(c), int(h.rcv[c]))
			if h.kind[r] == .Land do acc[r] += acc[c]
		}
	}
	// куда течёт каждая клетка (уровни рек — потом, hydro_river_levels)
	for c32 in order {
		c := int(c32)
		r := int(rcv[c])
		if flooded[c] {
			l := &lakes[lake_of[c]]
			if l.closed {
				if h.kind[c] != .Land do h.rcv[c] = 255 // вода бессточного озера никуда не течёт
				continue // осушенный край — выше, по склону к воде
			}
			h.rcv[c] = rk[c] // проточное озеро и его осушенное дно — к порогу
		} else {
			h.rcv[c] = r >= 0 ? rk[c] : 255
			h.q[c] = f32(acc[c] / h.year_s)
		}
	}
	hydro_river_levels(h, &b)

	t_levels := time.now()
	// статистика; вода на входе: сток с суши, осадки минус испарение с глади озёр
	for idx in 0 ..< N {
		a := f64(area[idx])
		switch h.kind[idx] {
		case .Ocean:
			st.ocean_cells += 1
			continue
		case .Land:
			st.land_cells += 1
			st.land_area += a
			st.runoff_land += f64(b.runoff[idx]) * a / 1000
		case .Lake:
			st.lake_cells += 1
			st.lake_area += a
			st.land_area += a
		case .Salt:
			st.salt_cells += 1
			st.land_area += a
		}
		// у бессточных озёр приход и испарение равны — они не в счёт (в них стекает lost_lakes)
		if flooded[idx] && lakes[lake_of[idx]].closed do continue
		wet := flooded[idx] && h.kind[idx] != .Land
		st.runoff_in += (wet ? f64(b.pe[idx]) : f64(b.runoff[idx])) * a / 1000
	}
	// бессточная суша по засушливости: клетка стекает в бессточное озеро
	if full_stats {
		endo := make([]i8, N) // засушливость у бессточного озера, куда стекает клетка (-1 — в океан)
		defer delete(endo)
		for &e in endo do e = -1
		for c32 in order {
			c := int(c32)
			endo[c] = -1
			if flooded[c] && lakes[lake_of[c]].closed {
				endo[c] = i8(b.arid[lake_cells[lakes[lake_of[c]].first]])
			} else if r := rcv[c]; r >= 0 {
				endo[c] = endo[r]
			}
			if h.kind[c] == .Ocean do continue
			a := f64(area[c])
			st.arid_area[b.arid[c]] += a
			if endo[c] >= 0 {
				st.arid_endo[b.arid[c]] += a
				st.arid_to[b.arid[c]][endo[c]] += a
			}
		}
	}
	for &l in lakes {
		st.lakes += 1
		if l.closed {
			// глубина впадины (порог − дно) — по водосбору
			lo := l.level
			for c in lake_cells[l.first:l.first + l.cells] do lo = min(lo, b.elev[c])
			d := l.level - lo
			k := d < 25 ? 0 : d < 50 ? 1 : d < 100 ? 2 : d < 200 ? 3 : d < 400 ? 4 : 5
			st.depth_catch[k] += l.catch + l.area
			st.closed += 1
			st.endorheic_area += l.catch + l.area
			st.lost_lakes += l.inflow
			if l.playa do st.playas += 1
		}
	}
	// реки в океан: устья — клетки суши, что стекают в море
	if full_stats {
		// длина от самого дальнего истока: по порядку прихода сверху вниз
		dist := make([]f32, N)
		defer delete(dist)
		for i := len(order) - 1; i >= 0; i -= 1 {
			c := int(order[i])
			r := int(rcv[c])
			if r < 0 do continue
			step := f32(math.sqrt(f64(area[c])))
			if h.rcv[c] % 2 == 1 do step *= math.SQRT_TWO
			if d := dist[c] + step; d > dist[r] do dist[r] = d
		}
		for c32 in order {
			c := int(c32)
			r := int(rcv[c])
			if r < 0 || h.kind[r] != .Ocean || h.kind[c] != .Land do continue
			st.to_ocean += acc[c]
			rv := Hydro_River{q = acc[c] / h.year_s, area = acc_a[c], length = f64(dist[c]), mouth = c}
			if rv.area >= 1.0e9 do append(&st.mouths, rv)
			for k in 0 ..< len(st.big) {
				if rv.q > st.big[k].q {
					for j := len(st.big) - 1; j > k; j -= 1 do st.big[j] = st.big[j - 1]
					st.big[k] = rv
					break
				}
			}
		}
	}
	st.mean_runoff_mm = st.runoff_land / max(st.land_area, 1) * 1000
	// насколько гладь рек выше дна своего пути (у впадения в озёра — их уровень)
	if full_stats {
		for c in 0 ..< N {
			if h.kind[c] != .Land || h.q[c] < 0.12 do continue
			ex := f64(h.level[c]) - f64(b.floor[c])
			st.rivers += 1
			if ex > 20 do st.perched[0] += 1
			if ex > 50 do st.perched[1] += 1
			if ex > 100 do st.perched[2] += 1
		}
	}
	h.ok = true
	st.build_s = time.duration_seconds(time.since(t_start))
	sec :: proc(a, b: time.Time) -> f64 {return time.duration_seconds(time.diff(a, b))}
	fmt.printfln("сеть стока: %d×%d×6 клеток по %.1f км за %.1f с (высоты %.1f, климат %.1f, океан %.1f, заполнение %.1f, впадины %.1f, сток %.1f, озёра %.1f, уровни %.1f, сводка %.1f); озёр %d, бессточных %d, солончаков %d",
		m, m, h.cell / 1000, st.build_s, sec(t_start, t_elev), sec(t_elev, t_clim), sec(t_clim, t_ocean), sec(t_ocean, t_flood),
		sec(t_flood, t_groups), sec(t_groups, t_acc), sec(t_acc, t_closed), sec(t_closed, t_levels), sec(t_levels, time.now()),
		st.lakes, st.closed, st.playas)
}

// Высоты для сортировки клеток озера (sort_by не берёт данные).
@(private = "file")
hydro_sort_elev: []f32

hydro_free :: proc() {
	h := &hydro
	delete(h.kind)
	delete(h.rcv)
	delete(h.level)
	delete(h.q)
	delete(h.wetc)
	delete(h.gw)
	delete(h.ai)
	delete(h.border)
	delete(h.edge)
	delete(h.stats.mouths)
	gen := h.gen
	h^ = {}
	h.gen = gen
}


// Возможное испарение за год (мм) — по Харгривсу и Самани (1985): свет у
// верха атмосферы ra (Вт/м², среднесуточный) и тепло месяцев t (°C);
// суточный размах температуры больше в сухом воздухе и в глуби материка.
// month_days — земных суток в месяце.
hydro_pet :: proc "contextless" (ra, t: [12]f64, P, cont, month_days: f64) -> f64 {
	pet0 := 0.0
	for m in 0 ..< 12 {
		ra_mm := ra[m] * 0.0864 / 2.45 // МДж/м² в сутки -> мм испарённой воды
		pet0 += 0.0023 * ra_mm * max(t[m] + 17.8, 0) * math.sqrt(10.0) * month_days
	}
	dry := clamp((pet0 - P) / max(pet0, 1), 0, 1)
	dtr := 7 + 3 * cont + 9 * dry // суточный размах, К
	return pet0 * math.sqrt(dtr / 10)
}

// Постройка сети стока в фоне (пока готовится остальное); hydro_wait — дождаться.
@(private = "file")
Build_Args :: struct {
	seed:   u32,
	radius: f64,
}

hydro_build_async :: proc(seed: u32, radius: f64) -> ^thread.Thread {
	args := new(Build_Args)
	args^ = {seed, radius}
	return thread.create_and_start_with_data(args, proc(p: rawptr) {
		a := (^Build_Args)(p)
		hydro_build(a.seed, a.radius)
		free(a)
	})
}

hydro_wait :: proc(t: ^^thread.Thread) {
	if t^ == nil do return
	thread.join(t^)
	thread.destroy(t^)
	t^ = nil
}

// Дно пути реки в клетках суши: самое низкое место рельефа (без деталей
// мельче 600 м, за вычетом их размаха) на пути от узла клетки к узлу ниже по
// течению (на всех ядрах).
@(private = "file")
build_floor :: proc(data: rawptr, k, n: int) {
	b := (^Build)(data)
	h := b.h
	for idx := k; idx < len(b.floor); idx += n {
		if h.kind[idx] != .Land do continue
		nc := hydro_node(h, idx)
		nr := nc
		if h.rcv[idx] != 255 {
			if r := hydro_nb(h, idx, int(h.rcv[idx])); r >= 0 do nr = hydro_node(h, r)
		}
		lo := 1.0e9
		for s in 0 ..< 2 {
			t := f64(s) / 2
			d := nc + (nr - nc) * t
			p := d / math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z) * h.radius
			e, amp := elevation_amp(h.seed, p, 600)
			lo = min(lo, e - amp)
		}
		b.floor[idx] = f32(lo)
	}
}

// Гладь рек. Сверху вниз по течению — самое низкое дно на всём пути от
// истока: так река не идёт по насыпи над рельефом, а пропиливает каньоном
// хребет на пути (как реки, что старше гор). Но не ниже воды, куда впадает
// (озера или моря): у озера её гладь — уровень озера.
@(private = "file")
hydro_river_levels :: proc(h: ^Hydro_Map, b: ^Build) {
	N := len(h.kind)
	b.floor = make([]f32, N)
	par_for(b, build_floor)
	down :: proc(h: ^Hydro_Map, c: int) -> int {
		if h.rcv[c] == 255 do return -1
		return hydro_nb(h, c, int(h.rcv[c]))
	}
	M := make([]f32, N) // самое низкое дно выше по течению (с этой клеткой)
	indeg := make([]i32, N)
	defer {
		delete(M)
		delete(indeg)
	}
	for &v in M do v = 1.0e9
	for c in 0 ..< N {
		r := down(h, c)
		if r < 0 || h.kind[r] != .Land do continue
		if h.kind[c] == .Land {
			indeg[r] += 1
		} else if h.kind[c] == .Lake {
			M[r] = min(M[r], h.level[c]) // вытекает из озера — не выше его глади
		}
	}
	// от истоков вниз (Кан): клетка — после всех, кто в неё течёт
	topo := make([dynamic]i32, 0, N / 2)
	defer delete(topo)
	for c in 0 ..< N do if h.kind[c] == .Land && indeg[c] == 0 do append(&topo, i32(c))
	for head := 0; head < len(topo); head += 1 {
		c := int(topo[head])
		M[c] = min(M[c], b.floor[c])
		r := down(h, c)
		if r < 0 || h.kind[r] != .Land do continue
		M[r] = min(M[r], M[c])
		indeg[r] -= 1
		if indeg[r] == 0 do append(&topo, i32(r))
	}
	// снизу вверх: не ниже воды, куда впадает река (озеро, солончак, море)
	B := make([]f32, N)
	defer delete(B)
	#reverse for c32 in topo {
		c := int(c32)
		r := down(h, c)
		switch {
		case r < 0:
			B[c] = M[c] // ямка
		case h.kind[r] == .Land:
			B[c] = B[r]
		case:
			B[c] = h.level[r]
		}
		h.level[c] = max(B[c], M[c])
	}
}

// ---------------------------------------------------------------- болота (0.020)

Wet_Class :: enum u8 {
	None, // сухо: болота только у рек и озёр
	Marsh, // низинные болота и топи (минеральные, без торфа)
	Peat, // верховые торфяные болота: прохладно и влажно — торф копится
	Swamp, // тропические заболоченные леса
}

WET_MANGROVE :: 16 // у тёплого моря — мангры
WET_SALT_MARSH :: 32 // у моря умеренного пояса — солёные марши
WET_COLD :: 64 // прохладно для торфа (в среднем за год не выше 7 °C); копится ли он — по местной влажности
HYDRO_STREAM_L :: 400.0 // м: полурасстояние между ручьями (густота речной сети ~1–2 км на км²)
// Водопроводимость грунта, м²/с (~10 м мощностью): в сухих краях — пески
// (~10⁻³), под низинными болотами — суглинки, в тропиках — латеритные глины,
// в холодном влажном климате — морена и торф (~10⁻⁴): вода стоит выше.
HYDRO_TRANSMISSIVITY := [Wet_Class]f64{.None = 1.0e-3, .Marsh = 5.0e-4, .Peat = 1.0e-4, .Swamp = 3.0e-4}
HYDRO_PEAT :: 4.0 // м: торф за голоцен (~0,4 мм в год за 10 тыс. лет)

// Подъём грунтовых вод между ручьями (м) при годовом стоке runoff (мм):
// бугор Дюпюи h = R·L²/(2T), питание R — половина стока (остальное стекает
// поверху).
hydro_mound :: proc "contextless" (runoff: f64, class: Wet_Class) -> f64 {
	R := 0.5 * runoff / 1000 / (365.25 * 86400) // м/с
	return R * HYDRO_STREAM_L * HYDRO_STREAM_L / (2 * HYDRO_TRANSMISSIVITY[class])
}

// Климат болот по месяцам t (°C, суша), морю to (°C), осадкам P и испарению PET (мм/год).
hydro_wet_class :: proc "contextless" (t, to: [12]f64, P, PET: f64) -> u8 {
	t_ann, t_min, t_max, to_min := 0.0, 1.0e9, -1.0e9, 1.0e9
	for m in 0 ..< 12 {
		t_ann += t[m] / 12
		t_min = min(t_min, t[m])
		t_max = max(t_max, t[m])
		to_min = min(to_min, to[m])
	}
	ai := P / max(PET, 1)
	c := Wet_Class.Marsh
	switch {
	case ai < 0.5 || t_max < 3:
		c = .None // сухо или вечный лёд
	case t_min >= 18:
		c = .Swamp
	case t_ann <= 7 && ai >= 0.9:
		c = .Peat // торф копится, где холодно и осадков больше испарения
	}
	flags: u8 = t_ann <= 7 && t_max >= 3 && t_min < 18 ? WET_COLD : 0
	if to_min >= 20 {
		flags |= WET_MANGROVE
	} else if to_min > -1 {
		flags |= WET_SALT_MARSH
	}
	return u8(c) | flags
}
