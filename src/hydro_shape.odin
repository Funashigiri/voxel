package main

// Реки и озёра в блоках и дальнем рельефе (0.019): русла, долины, берега.
//
// По сети стока (hydro.odin) каждая река — цепочка кривых: в клетке — кривая
// Безье от середины пути из соседа выше по течению через узел клетки (он
// сдвинут от её середины, чтобы реки не шли по сетке) к середине пути в
// клетку ниже. Притоки сливаются у конца кривой. Поверх — извилистость:
// меандры с длиной волны ~11 ширин реки (как у настоящих рек) и большие
// изгибы — из общего для всех рек поля шума (meander_noise).
//
// Ширина — по расходу (W ≈ 4,5·Q^0,5, Леопольд и Маддок), глубина и
// скорость — по уклону реки (формула Маннинга), гладь между узлами — по
// уровням сети. Земля вокруг: в русле — дно; рядом — пойма вровень с берегом
// (тем шире, чем река больше и равнинней); дальше — склоны долины: рельеф
// к реке плавно сжимается к пойме, холмы сохраняют форму; долина тем шире,
// чем выше рельеф над рекой (склоны не круче ~40°). У нескольких рек рядом —
// срез по самой глубокой долине и подсыпка по самой высокой.
//
// Озёро — там, где земля ниже его уровня в пределах его клеток (граница
// клеток изломана шумом); по краю берег не ниже уровня, иначе вода бы
// растеклась. Море — ниже нуля у клеток океана. Солончак — ровная корка на
// уровне высохшего озера.

import "core:math"
import "core:math/noise"
import eng "engine"

Water_Kind :: enum u8 {
	None,
	Sea,
	Lake,
	River,
	Salt, // корка соли (воды нет)
}

Hydro_Sample :: struct {
	ground: f64, // м над морем: земля (с руслами, долинами, берегами)
	water:  f64, // м над морем: гладь (если есть — выше земли)
	kind:   Water_Kind,
	flow:   [3]f64, // течение, м/с (оси планеты)
	q:      f64, // река: расход, м³/с
	width:  f64, // м
	depth:  f64, // м
	dist:   f64, // до середины ближайшей реки, м
	level:  f64, // уровень озера рядом (для F3)
	cover:  f64, // дальний рельеф: доля клетки под рекой, что уже клетки (тонкая линия цветом)
	phi:    f64, // насколько точка в клетках озера (0…1; озеро — от 0,5)
}

HYDRO_Q_MIN :: 0.12 // м³/с: ручьи меньше не видно
HYDRO_W_K :: 4.5 // ширина реки W = k·√Q, м
HYDRO_MANNING :: 0.035 // шероховатость русла
HYDRO_VALLEY :: 2500.0 // м: шире долина не бывает (от края поймы)
HYDRO_SIDE :: 0.6 // склоны долины в среднем не круче этого (в середине — в 1,5 раза)
HYDRO_JITTER :: 0.3 // узлы русел сдвинуты от середин клеток (доля клетки)

@(private = "file")
Curve :: struct {
	a, b, c:    [2]f64, // Безье: начало, узел, конец (плоскость кэша, м)
	l0, l1, l2: f64, // гладь, м над морем
	q0, q2:     f64, // расход в начале и в конце
	slope:      f64,
	length:     f64, // м (примерно)
	lo, hi:     [2]f64, // рамка влияния
	blo, bhi:   [2]f64, // рамка самой кривой
	reach:      f64, // м: дальше рамки самой кривой — пойма, извилистость и пол-русла
	wmax:       f64, // м: ширина у конца
	dev:        f64, // м: кривая отходит от хорды a–c не дальше этого
	seed:       u32,
	tail:       bool, // приток: широк только у слияния
}

@(private = "file")
Shape_Cache :: struct {
	gen:        u32,
	curves_ok:  bool, // кривые рек собраны (для грубого дальнего рельефа не нужны)
	cell:       int,
	c0, e1, e2: [3]f64, // середина клетки и оси касательной плоскости
	near:       [3][3]int, // клетки вокруг (−1 — нет)
	water_near: bool, // рядом озеро или солончак
	all_lake:   bool, // вокруг только озеро (одно): граница далеко
	ocean_near: bool,
	n:          int,
	curves:     [128]Curve,
}

@(private = "file")
@(thread_local)
shape_cache: Shape_Cache

// Узел русла в клетке: середина, сдвинутая на долю клетки (свой сдвиг у каждой).
hydro_node :: proc "contextless" (h: ^Hydro_Map, idx: int) -> [3]f64 {
	m := h.m
	face := Cube_Face(idx / (m * m))
	r := idx % (m * m)
	jx := (f64(eng.hash2f(i32(idx), 17, u32(h.seed))) - 0.5) * 2 * HYDRO_JITTER
	jz := (f64(eng.hash2f(i32(idx), 29, u32(h.seed))) - 0.5) * 2 * HYDRO_JITTER
	return hydro_dir_at(m, face, f64(r % m) + 0.5 + jx, f64(r / m) + 0.5 + jz)
}

// Клетка (i, j) грани face — можно за краем грани (тогда на соседней).
hydro_cell_at :: proc "contextless" (h: ^Hydro_Map, face: Cube_Face, i, j: int) -> int {
	m := h.m
	if i >= 0 && j >= 0 && i < m && j < m do return hydro_index(m, face, i, j)
	d := hydro_dir_at(m, face, f64(i) + 0.5, f64(j) + 0.5)
	nf, x, z := hydro_locate(m, d)
	return hydro_index(m, nf, clamp(int(x), 0, m - 1), clamp(int(z), 0, m - 1))
}

@(private = "file")
project :: #force_inline proc "contextless" (c: ^Shape_Cache, d: [3]f64, R: f64) -> [2]f64 {
	k := R / (d.x * c.c0.x + d.y * c.c0.y + d.z * c.c0.z)
	return {(d.x * c.e1.x + d.y * c.e1.y + d.z * c.e1.z) * k, (d.x * c.e2.x + d.y * c.e2.y + d.z * c.e2.z) * k}
}

@(private = "file")
river_width :: #force_inline proc "contextless" (q: f64) -> f64 {
	return HYDRO_W_K * math.sqrt(max(q, 0))
}

// Пойма в стороны от русла реки шириной w и уклоном s, м: у равнинной реки — широкая.
@(private = "file")
river_flood :: proc "contextless" (w, s: f64) -> f64 {
	g := clamp(1 - s / 0.002, 0, 1)
	return w * (0.5 + 3 * g)
}

@(private = "file")
cache_build :: proc(h: ^Hydro_Map, idx: int, with_curves: bool) {
	c := &shape_cache
	c.gen = h.gen
	c.cell = idx
	c.n = 0
	m := h.m
	R := h.radius
	face := Cube_Face(idx / (m * m))
	r := idx % (m * m)
	ci, cj := r % m, r / m
	c.c0 = hydro_cell_dir(h, idx)
	ex := hydro_dir_at(m, face, f64(ci) + 1.5, f64(cj) + 0.5) - hydro_dir_at(m, face, f64(ci) - 0.5, f64(cj) + 0.5)
	ex -= c.c0 * (ex.x * c.c0.x + ex.y * c.c0.y + ex.z * c.c0.z)
	ex /= math.sqrt(ex.x * ex.x + ex.y * ex.y + ex.z * ex.z)
	c.e1 = ex
	c.e2 = {c.c0.y * ex.z - c.c0.z * ex.y, c.c0.z * ex.x - c.c0.x * ex.z, c.c0.x * ex.y - c.c0.y * ex.x}
	c.water_near, c.ocean_near = false, false
	c.all_lake = true
	for dj in -1 ..= 1 do for di in -1 ..= 1 {
		n := hydro_cell_at(h, face, ci + di, cj + dj)
		c.near[dj + 1][di + 1] = n
		if h.kind[n] != .Lake || h.level[n] != h.level[idx] do c.all_lake = false
		#partial switch h.kind[n] {
		case .Ocean:
			c.ocean_near = true
		case .Lake, .Salt:
			c.water_near = true
		}
	}
	c.curves_ok = with_curves
	if !with_curves do return
	// клетка в плоскости кэша — квадрат с половиной стороны half (с запасом)
	half := 0.6 * math.sqrt(hydro_cell_area(h, idx))
	add :: proc(c: ^Shape_Cache, cv: Curve, half: f64) {
		if c.n >= len(c.curves) do return
		w := river_width(max(cv.q0, cv.q2))
		cv := cv
		cv.wmax = w
		cv.reach = w / 2 + river_flood(w, cv.slope) + meander_reach(w) + 20
		cv.blo = {min(cv.a.x, cv.b.x, cv.c.x), min(cv.a.y, cv.b.y, cv.c.y)}
		md := cv.b - (cv.a + cv.c) / 2 // B(t) = хорда(t) + 2t(1−t)·md
		cv.dev = 0.5 * math.sqrt(md.x * md.x + md.y * md.y)
		cv.bhi = {max(cv.a.x, cv.b.x, cv.c.x), max(cv.a.y, cv.b.y, cv.c.y)}
		pad := HYDRO_VALLEY + cv.reach + 30
		cv.lo = {min(cv.a.x, cv.b.x, cv.c.x) - pad, min(cv.a.y, cv.b.y, cv.c.y) - pad}
		cv.hi = {max(cv.a.x, cv.b.x, cv.c.x) + pad, max(cv.a.y, cv.b.y, cv.c.y) + pad}
		if cv.lo.x > half || cv.lo.y > half || cv.hi.x < -half || cv.hi.y < -half do return
		c.curves[c.n] = cv
		c.n += 1
	}
	for dj in -2 ..= 2 do for di in -2 ..= 2 {
		n := hydro_cell_at(h, face, ci + di, cj + dj)
		if h.kind[n] != .Land || h.rcv[n] == 255 do continue
		qn := f64(h.q[n])
		if qn < HYDRO_Q_MIN do continue
		rr := hydro_nb(h, n, int(h.rcv[n]))
		if rr < 0 do continue
		pn := project(c, hydro_node(h, n), R)
		ln := f64(h.level[n])
		end: [2]f64
		l_end: f64
		if h.kind[rr] == .Land {
			end = (pn + project(c, hydro_node(h, rr), R)) / 2
			l_end = (ln + f64(h.level[rr])) / 2
		} else {
			end = project(c, hydro_node(h, rr), R) // в море или озеро — до его узла
			l_end = f64(h.level[rr])
		}
		seg := math.sqrt((end.x - pn.x) * (end.x - pn.x) + (end.y - pn.y) * (end.y - pn.y))
		has := false
		for k in 0 ..< 8 {
			d := hydro_nb(h, n, k)
			if d < 0 || h.rcv[d] == 255 || h.kind[d] == .Ocean do continue
			if hydro_nb(h, d, int(h.rcv[d])) != n do continue
			start: [2]f64
			l0, qd: f64
			if h.kind[d] == .Land {
				qd = f64(h.q[d])
				if qd < HYDRO_Q_MIN do continue // ручей выше не виден — его вода в реке отсюда
				start = (project(c, hydro_node(h, d), R) + pn) / 2
				l0 = (f64(h.level[d]) + ln) / 2
			} else {
				qd = qn // из озера
				start = project(c, hydro_node(h, d), R)
				l0 = f64(h.level[d])
			}
			length := seg + math.sqrt((pn.x - start.x) * (pn.x - start.x) + (pn.y - start.y) * (pn.y - start.y))
			add(c, {a = start, b = pn, c = end, l0 = l0, l1 = ln, l2 = l_end, q0 = qd, q2 = qn,
				slope = max((l0 - l_end) / max(length, 1), 1e-5), length = length, seed = u32(n) * 8 + u32(k), tail = qd < 0.5 * qn}, half)
			has = true
		}
		if !has {
			// исток: от узла клетки
			add(c, {a = pn, b = pn, c = end, l0 = ln, l1 = ln, l2 = l_end, q0 = 0, q2 = qn,
				slope = max((ln - l_end) / max(seg, 1), 1e-5), length = seg, seed = u32(n) * 8 + 7}, half)
		}
	}
}

// Извилистость рек: сдвиг середины русла вбок — гладкое поле шума (октавы от
// 25 м до 3,2 км), одно на все реки и посчитанное в самой точке. Река шириной
// w берёт из него меандры с длиной волны ~11 ширин (как у настоящих рек) и
// большие плавные изгибы. Сдвиг зависит только от места и ширины, а ширина у
// стыка кривых и у слияния притоков одна — изгибы на стыках сходятся сами.
MEANDER_OCT :: 8

@(private = "file")
meander_noise :: proc(seed: i64, p: [3]f64) -> (n: [MEANDER_OCT]f64) {
	lam := 25.0
	for k in 0 ..< MEANDER_OCT {
		n[k] = f64(noise.noise_3d_improve_xz(seed + 950 + i64(k), p / lam))
		lam *= 2
	}
	return
}

// Вес октавы с длиной волны lam у реки шириной w (м сдвига на единицу шума).
@(private = "file")
meander_amp :: #force_inline proc "contextless" (lam, w: f64) -> f64 {
	x := math.log2(lam / (11 * max(w, 1.5)))
	a := 0.3 * lam * math.exp(-x * x / 0.7) // меандры
	if lam >= 1400 do a += 0.15 * lam // большие изгибы
	return a
}

@(private = "file")
meander_off :: proc "contextless" (n: ^[MEANDER_OCT]f64, w: f64) -> f64 {
	off, lam := 0.0, 25.0
	for k in 0 ..< MEANDER_OCT {
		off += meander_amp(lam, w) * n[k]
		lam *= 2
	}
	return off
}

// Сколько извилистость уводит реку шириной w вбок, м (не больше).
@(private = "file")
meander_reach :: proc "contextless" (w: f64) -> f64 {
	r, lam := 0.0, 25.0
	for _ in 0 ..< MEANDER_OCT {
		r += meander_amp(lam, w)
		lam *= 2
	}
	return r
}

// Ближайшая точка кривой Безье a-b-c к p: расстояние (со знаком: слева
// плюс) и параметр t (Иниго Килес: корни кубического уравнения).
@(private = "file")
bezier_closest :: proc "contextless" (p, a, b, c: [2]f64) -> (dist, t: f64) {
	A := b - a
	B := a - 2 * b + c
	bb := B.x * B.x + B.y * B.y
	if bb < 1e-9 {
		// почти прямая: отрезок a–c
		ac := c - a
		t = clamp(((p.x - a.x) * ac.x + (p.y - a.y) * ac.y) / max(ac.x * ac.x + ac.y * ac.y, 1e-12), 0, 1)
	} else {
		C := A * 2
		D := a - p
		kk := 1 / bb
		kx := kk * (A.x * B.x + A.y * B.y)
		ky := kk * (2 * (A.x * A.x + A.y * A.y) + (D.x * B.x + D.y * B.y)) / 3
		kz := kk * (D.x * A.x + D.y * A.y)
		pp := ky - kx * kx
		p3 := pp * pp * pp
		q := kx * (2 * kx * kx - 3 * ky) + kz
		hh := q * q + 4 * p3
		_ = C
		if hh >= 0 {
			hh = math.sqrt(hh)
			x0 := (hh - q) / 2
			x1 := (-hh - q) / 2
			u := math.sign(x0) * math.pow(abs(x0), 1.0 / 3)
			v := math.sign(x1) * math.pow(abs(x1), 1.0 / 3)
			t = clamp(u + v - kx, 0, 1)
		} else {
			z := math.sqrt(-pp)
			ang := math.acos(clamp(q / (pp * z * 2), -1, 1)) / 3
			mm := math.cos(ang)
			nn := math.sin(ang) * 1.732050808
			t0 := clamp((mm + mm) * z - kx, 0, 1)
			t1 := clamp((-nn - mm) * z - kx, 0, 1)
			q0 := a + (C + B * t0) * t0 - p
			q1 := a + (C + B * t1) * t1 - p
			t = q0.x * q0.x + q0.y * q0.y < q1.x * q1.x + q1.y * q1.y ? t0 : t1
		}
	}
	pt := a + (2 * A + B * t) * t
	tan := 2 * A + 2 * B * t // производная
	dv := p - pt
	dist = math.sqrt(dv.x * dv.x + dv.y * dv.y)
	if tan.x * dv.y - tan.y * dv.x < 0 do dist = -dist
	return
}

// Земля и вода в точке шара p (м) при рельефе e (м над морем, без деталей мельче cell).
hydro_sample :: proc(p: [3]f64, e: f64, cell: f64) -> (s: Hydro_Sample) {
	s.ground = e
	s.dist = 1.0e9
	h := &hydro
	if !h.ok do return
	m := h.m
	r := math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	d := p / r
	face, fx, fz := hydro_locate(m, d)
	ci := clamp(int(fx), 0, m - 1)
	cj := clamp(int(fz), 0, m - 1)
	idx := hydro_index(m, face, ci, cj)
	c := &shape_cache
	// реки уже четверти клетки сети в дальнем рельефе не видны (и долины мельче клетки)
	curves := cell < 0.25 * h.cell
	if shape_force > 0 do idx = shape_force - 1 // отладка: кэш соседней клетки
	if c.gen != h.gen || c.cell != idx || (curves && !c.curves_ok) do cache_build(h, idx, curves)
	q := project(c, d, h.radius)

	lo, hi := -1.0e12, 1.0e12 // русла: дно (и не выше, и не ниже)
	cut, fill := e, e // долины: срез до самой глубокой, подсыпка до самой высокой
	river := -1.0e12 // гладь реки здесь
	mn: [MEANDER_OCT]f64 // поле извилистости в этой точке (считается, если рядом река)
	have_mn := false
	for &cv in c.curves[:curves ? c.n : 0] {
		if q.x < cv.lo.x || q.y < cv.lo.y || q.x > cv.hi.x || q.y > cv.hi.y do continue
		// долина тем уже, чем ниже рельеф над рекой: дальше её края — кривая не нужна
		dzm := max(abs(e - cv.l0), abs(e - cv.l1), abs(e - cv.l2)) + 0.25 * cv.wmax + 3
		ext := min(30 + 2 * cv.wmax + dzm / HYDRO_SIDE, HYDRO_VALLEY) + cv.reach + (cell > 1.5 ? 0.5 * cell : 0)
		if q.x < cv.blo.x - ext || q.y < cv.blo.y - ext || q.x > cv.bhi.x + ext || q.y > cv.bhi.y + ext do continue
		// до хорды минус отход кривой от неё — не дальше, чем до самой кривой
		{
			ac := cv.c - cv.a
			aq := q - cv.a
			k := clamp((aq.x * ac.x + aq.y * ac.y) / max(ac.x * ac.x + ac.y * ac.y, 1e-9), 0, 1)
			dd := aq - ac * k
				if math.sqrt(dd.x * dd.x + dd.y * dd.y) - cv.dev > ext do continue
		}
		sd, t := bezier_closest(q, cv.a, cv.b, cv.c)
		if abs(sd) > ext do continue // дальше края долины (с запасом на изгибы)
		qq := cv.tail ? math.lerp(cv.q0, cv.q2, t * t) : math.lerp(cv.q0, cv.q2, t)
		if qq < HYDRO_Q_MIN * 0.5 do continue
		fq := smooth01((qq - 0.5 * HYDRO_Q_MIN) / HYDRO_Q_MIN) // у истока долина проявляется плавно
		w := river_width(qq)
		// извилистость: расстояние до сдвинутой середины
		if !have_mn {
			mn = meander_noise(h.seed, p)
			have_mn = true
		}
		dist := abs(sd - meander_off(&mn, w))
		s.dist = min(s.dist, dist)
		flood := river_flood(w, cv.slope)
		// дальний рельеф: реки уже клетки не видно, долина — хотя бы в клетку
		visible := w >= 0.7 * cell
		if !visible do s.cover = max(s.cover, clamp(w / cell, 0, 1) * max(0, 1 - dist / (0.5 * cell + 0.5 * w)))
		dv := dist
		if cell > 1.5 do dv = max(dist - 0.5 * cell, 0)
		hw := w / 2
		x := max((visible ? dv - hw : dv) - flood, 0) // от края поймы
		if x >= HYDRO_VALLEY do continue
		L := (1 - t) * (1 - t) * cv.l0 + 2 * t * (1 - t) * cv.l1 + t * t * cv.l2
		depth := clamp(math.pow(qq * HYDRO_MANNING / (w * math.sqrt(cv.slope)), 0.6), 0.2, 80)
		fp := L + max(0.25 * depth, 0.6) // пойма — вровень с берегами
		if visible && dv < hw {
				// русло: ровное дно, пологие края; не мельче блока
			dvis := max(depth, 1.3)
			bed := L - dvis * min(1, 1.6 * (1 - (dv / hw) * (dv / hw)))
			lo = max(lo, bed)
			hi = min(hi, bed)
			if L > river {
				river = L
				s.q, s.width, s.depth = qq, w, depth
				// течение вдоль кривой, у берегов медленнее
				tan := 2 * (cv.b - cv.a) * (1 - t) + 2 * (cv.c - cv.b) * t
				tl := math.sqrt(tan.x * tan.x + tan.y * tan.y)
				if tl > 1e-9 {
					v := qq / (w * depth) * math.sqrt(max(1 - (dv / hw) * (dv / hw), 0.05))
					t3 := c.e1 * (tan.x / tl) + c.e2 * (tan.y / tl)
					s.flow = t3 * v
				}
			}
			continue
		}
		// долина: к реке рельеф сжимается к пойме (холмы сохраняют форму);
		// чем выше он над поймой, тем шире долина — склоны не круче ~40°
		dz := e - fp
		V := min(30 + 2 * w + abs(dz) / HYDRO_SIDE, HYDRO_VALLEY)
		if x >= V do continue
		g := smooth01(x / V)
		target := e + (dz * g - dz) * fq
		cut = min(cut, target)
		fill = max(fill, target)
	}

	// озёра и солончаки: клетки вокруг (граница изломана шумом)
	lake_l, salt_l := 0.0, 0.0
	phi_lake, phi_salt, phi_ocean := 0.0, 0.0, 0.0
	if shape_force > 0 {
		// отладка: кэш чужой клетки — озёра по её соседям не годятся
	} else if c.all_lake {
		phi_lake, lake_l = 1, f64(h.level[idx])
		s.level, s.phi = lake_l, 1
	} else if c.water_near || c.ocean_near {
		wx := f64(noise.noise_3d_improve_xz(h.seed + 901, p / 6000)) * 0.22 + f64(noise.noise_3d_improve_xz(h.seed + 903, p / 1300)) * 0.07
		wz := f64(noise.noise_3d_improve_xz(h.seed + 902, p / 6000)) * 0.22 + f64(noise.noise_3d_improve_xz(h.seed + 904, p / 1300)) * 0.07
		gx := clamp(fx + wx - 0.5 - f64(ci), -1, 0.999)
		gz := clamp(fz + wz - 0.5 - f64(cj), -1, 0.999)
		i0 := int(math.floor(gx))
		j0 := int(math.floor(gz))
		u, v := gx - f64(i0), gz - f64(j0)
		best_l, best_s := 0.0, 0.0
		for b in 0 ..= 1 do for a in 0 ..= 1 {
			n := c.near[j0 + b + 1][i0 + a + 1]
			wgt := (a == 0 ? 1 - u : u) * (b == 0 ? 1 - v : v)
			#partial switch h.kind[n] {
			case .Lake:
				phi_lake += wgt
				if wgt > best_l do best_l, lake_l = wgt, f64(h.level[n])
			case .Salt:
				phi_salt += wgt
				if wgt > best_s do best_s, salt_l = wgt, f64(h.level[n])
			case .Ocean:
				phi_ocean += wgt
			}
		}
		// у края — берег не ниже уровня (иначе вода растеклась бы за клетки озера)
		if phi_lake > 0.05 && phi_lake < 0.5 && e < lake_l + 0.5 {
			k := smooth01((phi_lake - 0.05) / 0.4)
			lo = max(lo, e + (lake_l + 0.5 - e) * k)
		}
		// у моря — так же: ниже нуля у самой воды — подсыпка до +0,5 (иначе стена воды)
		if phi_ocean > 0.02 && phi_ocean < 0.25 && e < 0.5 {
			k := smooth01((phi_ocean - 0.02) / 0.23)
			lo = max(lo, e + (0.5 - e) * k)
		}
		if phi_lake > 0 do s.level = lake_l
		s.phi = phi_lake
	}
	ground := cut + fill - e // срез и подсыпка (у разных рек) — вместе, без скачков
	s.ground = min(max(ground, lo), hi)

	s.water = -1.0e9
	if river > s.ground {
		s.water = river
		s.kind = .River
	}
	// в озере и в море — их гладь (река входит в них ступенькой у берега)
	if phi_lake >= 0.5 && s.ground < lake_l {
		s.water = lake_l
		s.kind = .Lake
		s.flow = {}
	}
	if phi_ocean >= 0.25 && s.ground < 0 && (s.kind != .Lake || lake_l < 0) {
		s.water = 0
		s.kind = .Sea
		s.flow = {}
	}
	if s.kind == .None && phi_salt >= 0.5 && s.ground < salt_l + 0.3 {
		s.ground = salt_l // ровная корка соли
		s.kind = .Salt
	}
	return
}

@(private = "file")
smooth01 :: #force_inline proc "contextless" (x: f64) -> f64 {
	t := clamp(x, 0, 1)
	return t * t * (3 - 2 * t)
}

// Течение для блоков воды (байт вершины): направление по сетке грани face
// (16 румбов), скорость по 0,25 м/с (до 1,75), 128 — пресная (зимой замерзает).
water_flow_code :: proc "contextless" (face: Cube_Face, p: [3]f64, flow: [3]f64, fresh: bool) -> u8 {
	code: u8 = fresh ? 128 : 0
	v := math.sqrt(flow.x * flow.x + flow.y * flow.y + flow.z * flow.z)
	if v < 0.06 do return code
	fb := FACE_BASES[face]
	fx := flow.x * fb.u.x + flow.y * fb.u.y + flow.z * fb.u.z
	fz := flow.x * fb.v.x + flow.y * fb.v.y + flow.z * fb.v.z
	k := int(math.round(math.atan2(fz, fx) / math.TAU * 16)) & 15
	sp := clamp(int(math.round(v / 0.25)), 1, 7)
	return code | u8(k) | u8(sp) << 4
}

// Отладка (-hydro): считать точку по кэшу другой клетки.
@(thread_local)
shape_force: int // номер клетки + 1 (0 — своей)

// Отладка: одна и та же точка по кэшу своей клетки и соседних — расхождение
// земли (м); у правильного кэша соседние клетки дают то же самое.
hydro_cache_mismatch :: proc(p: [3]f64, e: f64) -> (worst: f64) {
	h := &hydro
	d := p / math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	face, fx, fz := hydro_locate(h.m, d)
	ci, cj := int(fx), int(fz)
	shape_force = hydro_index(h.m, face, ci, cj) + 1 // и своя — без озёр, как у соседей
	ref := hydro_sample(p, e, 0.5)
	// кэш соседа отвечает и за кромку в 0,1 клетки за своей границей
	for dj in -1 ..= 1 do for di in -1 ..= 1 {
		if di == 0 && dj == 0 do continue
		ux := fx - f64(ci)
		uz := fz - f64(cj)
		if (di < 0 && ux > 0.08) || (di > 0 && ux < 0.92) || (dj < 0 && uz > 0.08) || (dj > 0 && uz < 0.92) do continue
		shape_force = hydro_cell_at(h, face, ci + di, cj + dj) + 1
		s := hydro_sample(p, e, 0.5)
		shape_force = 0
		worst = max(worst, abs(s.ground - ref.ground))
	}
	shape_cache.gen = 0 // кэш собран не для своей клетки — сбросить
	return
}
