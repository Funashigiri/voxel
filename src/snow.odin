package main

// Снег (0.018): копится и тает по погоде.
//
// Снежный покров — как в моделях суши (CLASS, Noah), попроще: запас воды в
// снеге, плотность, белизна (альбедо), талая вода внутри, почва под снегом.
// Свежий снег пушистый (60–150 кг/м³, в оттепель и на ветру плотнее), потом
// оседает. Тает от тепла воздуха и от солнца — тем быстрее, чем снег старее и
// серее; дождь на снегу приносит тепло; ночью талая вода замерзает; первые
// снегопады тают снизу на тёплой земле. Хвоя задерживает часть снегопада
// (Хедстром и Померой), в оттепель и ветер этот снег падает.
//
// Покров считается на сетке вокруг игрока (±160 км, клетки ~7 км) по восьми
// высотам — в горах снег свой на каждой. Начало — честная погода за весь
// прошлый год (шаг 3 ч, в фоне на всех ядрах), дальше — вперёд вместе со
// временем. В шейдеры — текстурный массив: глубина, белизна, снег на кронах,
// доля покрытой земли.

import "core:fmt"
import "core:math"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import gl "vendor:OpenGL"

SNOW_N :: 48 // клеток по стороне
SNOW_LEVELS :: 8 // высот
SNOW_EXTENT :: WX_EXTENT // м: от середины до края
SNOW_STEP_H :: 3.0 // шаг расчёта прошлого, ч
SNOW_RECENTRE :: 60_000.0 // м: ушли дальше — пересчитать заново
SNOW_CANOPY_REF :: 15.0 // мм: столько снега на хвое — крона белая
SNOW_BELOW :: 3 // блоков: насколько ниже искать снег, на котором можно стоять
SNOW_LIFT_MAX :: 1.0 // м: глубже блока снег рисуется и держит как метровый (как в шейдере)

Snow_Cell :: struct {
	swe:    f32, // запас воды в снеге, мм (= кг/м²)
	rho:    f32, // плотность, кг/м³
	albedo: f32, // белизна (доля отражённого света)
	liquid: f32, // талая вода в снегу, мм
	canopy: f32, // снег на хвое, мм
	t_soil: f32, // верх почвы, °C
	last:   f32, // часов с последнего снегопада
}

Snow_Grid :: struct {
	centre, east, north: [3]f64, // середина сетки и её оси (оси планеты)
	lo, step:            f64, // высоты уровней: lo + k·step, м над морем
	t_h:                 f64, // время погоды, до которого досчитано, ч
	cells:               [SNOW_N * SNOW_N * SNOW_LEVELS]Snow_Cell,
	clim:                [SNOW_N * SNOW_N]Climate_Point, // климат клеток (на уровне моря)
	ok:                  bool,
}

Snow_Request :: struct {
	centre: [3]f64,
	t_h:    f64, // время погоды сейчас, ч
	season: f64,
	hour:   f64, // местное время, ч
	full:   bool, // пересчитать заново (новое место или скачок времени)
}

Snow_State :: struct {
	model:   ^Weather_Model, // только читается
	seed:    i64,
	day_h:   f64,
	work:    ^Snow_Grid, // считает фоновый поток
	back:    ^Snow_Grid, // готовая копия для главного
	front:   ^Snow_Grid, // у главного потока (текстура, физика, F3)
	tex_buf: []f32, // RGBA по уровням для текстуры (готовит фоновый поток)
	tex:     u32,
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	worker:  ^thread.Thread,
	req:     Snow_Request,
	pending: bool,
	busy:    bool,
	ready:   bool,
	quit:    bool,
	spin:    bool, // идёт расчёт прошлого года
}

// Снег здесь (для F3 и физики).
Snow_Here :: struct {
	depth:  f64, // м
	swe:    f64, // мм воды
	rho:    f64, // кг/м³
	albedo: f64,
	canopy: f64, // мм на хвое
	cover:  f64, // доля покрытой земли
	last:   f64, // часов с последнего снегопада
	ok:     bool,
}

snow_state_init :: proc(ss: ^Snow_State, wm: ^Weather_Model, seed: u32, day_h: f64) {
	ss.model = wm
	ss.seed = i64(seed)
	ss.day_h = day_h
	ss.work = new(Snow_Grid)
	ss.back = new(Snow_Grid)
	ss.front = new(Snow_Grid)
	ss.tex_buf = make([]f32, SNOW_N * SNOW_N * SNOW_LEVELS * 4)
	gl.GenTextures(1, &ss.tex)
	// 3D-текстура: по высотам видеокарта сама смешивает соседние уровни (одна выборка)
	gl.BindTexture(gl.TEXTURE_3D, ss.tex)
	gl.TexImage3D(gl.TEXTURE_3D, 0, gl.RGBA16F, SNOW_N, SNOW_N, SNOW_LEVELS, 0, gl.RGBA, gl.FLOAT, nil)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)
	gl.BindTexture(gl.TEXTURE_3D, 0)
	ss.worker = thread.create_and_start_with_data(ss, snow_worker)
}

snow_state_destroy :: proc(ss: ^Snow_State) {
	sync.mutex_lock(&ss.mutex)
	ss.quit = true
	sync.cond_broadcast(&ss.cond)
	sync.mutex_unlock(&ss.mutex)
	thread.join(ss.worker)
	thread.destroy(ss.worker)
	gl.DeleteTextures(1, &ss.tex)
	free(ss.work)
	free(ss.back)
	free(ss.front)
	delete(ss.tex_buf)
}

// ---------------------------------------------------------------- модель

@(private = "file")
ssmooth :: proc "contextless" (e0, e1, x: f64) -> f64 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}

// Погода для снега на одном уровне высоты на шаг dt (ч).
Snow_Forcing :: struct {
	rain:  f64, // осадки, мм/ч воды
	t:     f64, // воздух на этой высоте, °C
	cover: f64,
	wind:  f64, // м/с
	sun:   f64, // свет на землю в ясную погоду, Вт/м²
	rh:    f64,
}

// Шаг снежного покрова c на dt часов.
snow_step :: proc "contextless" (c: ^Snow_Cell, f: Snow_Forcing, dt: f64) {
	T := f.t
	snow_frac := ssmooth(2, 0, T)
	P_snow := f.rain * snow_frac * dt
	P_rain := f.rain * (1 - snow_frac) * dt
	swe := f64(c.swe)
	rho := f64(c.rho)
	alb := f64(c.albedo)
	liq := f64(c.liquid)
	can := f64(c.canopy)
	ts := f64(c.t_soil)
	c.last += f32(dt)

	// снегопад: свежий снег тем пушистее, чем холоднее (Хедстром и Померой,
	// 1998), ветер его уплотняет
	if P_snow > 1e-4 {
		rn := T <= 0 ? 67.92 + 51.25 * math.exp(T / 2.59) : 119.17 + 20 * min(T, 3)
		rn = clamp(rn + 25 * max(f.wind - 4, 0), 50, 350)
		rho = swe > 1e-3 ? (swe + P_snow) / (swe / rho + P_snow / rn) : rn
		swe += P_snow
		alb += (0.85 - alb) * min(P_snow / 5, 1) // 5 мм свежего снега — снова белый
		if P_snow > 0.1 * dt do c.last = 0
		// хвоя ловит часть снегопада (LAI ~3; чем пушистее снег, тем больше удержит)
		imax := 6.6 * 3 * (0.27 + 46 / rn)
		can += (imax - can) * (1 - math.exp(-0.7 * P_snow / imax))
	}
	// снег с хвои падает: в мороз и тишь — днями, в ветер и оттепель — за часы;
	// на солнце понемногу испаряется
	u := 0.004 + 0.02 * max(f.wind - 2, 0) + (T > -3 ? 0.06 * (T + 3) : 0)
	can *= math.exp(-u * dt)
	can = max(can - 0.02 * dt * (1 + f.sun / 300), 0)

	if swe <= 1e-3 {
		// без снега почва — по воздуху (за пару суток)
		ts += (T - ts) * (1 - math.exp(-dt / 48))
		c^ = {swe = 0, rho = 100, albedo = 0.85, liquid = 0, canopy = f32(can), t_soil = f32(ts), last = c.last}
		return
	}
	depth := swe / rho
	// таяние: от тепла воздуха и от солнца — свет, что снег не отразил
	// (Pellicciotti и др., 2005); под облаками солнца меньше (Kasten, Czeplak)
	G := f.sun * (1 - 0.75 * math.pow(clamp(f.cover, 0, 1), 3.4))
	melt := 0.0
	if T > 1 do melt = (0.05 * T + 0.0094 * (1 - alb) * G) * dt
	melt += P_rain * 4190 * max(T, 0) / 3.34e5 // тёплый дождь
	// снизу греет почва (1 мм талой воды остужает верх почвы на ~1,3 К)
	if ts > 0 {
		bm := min(0.06 * ts * dt, ts / 1.34)
		melt += bm
		ts -= bm * 1.34
	}
	melt = min(melt, swe)
	swe -= melt
	liq += melt + P_rain
	// ночью талая вода замерзает
	if T < 0 {
		rf := min(liq, 0.05 * -T * dt)
		liq -= rf
		swe += rf
	}
	liq = min(liq, 0.05 * swe) // лишняя вода стекает
	// испарение в сухом ветреном воздухе
	swe = max(swe - 0.004 * (1 + f.wind / 5) * max(1 - f.rh, 0) * wx_esat(T) / 6.112 * dt, 0)
	if swe <= 1e-3 {
		c^ = {swe = 0, rho = 100, albedo = 0.85, canopy = f32(can), t_soil = f32(max(ts, 0)), last = c.last}
		return
	}
	// оседание к пределу плотности: сухой снег ~350 кг/м³ за недели, мокрый
	// ~450–600 за дни (по CLASS, Verseghy 1991)
	depth = swe / rho
	wet := liq > 0.01 || T > 0
	zk := depth > 1e-3 ? (1 - math.exp(-depth / 0.673)) / depth : 1 / 0.673
	rmax := wet ? 600 - 204.7 * zk : 350 - 20.47 * zk
	rate := wet ? 0.01 : 0.0025
	if rho < rmax do rho = rmax + (rho - rmax) * math.exp(-rate * dt)
	// старение: свежий белый снег сереет, тающий — быстрее и сильнее
	amin := wet ? 0.5 : 0.7
	alb = amin + (alb - amin) * math.exp(-0.01 * dt)
	// почва под снегом: снег — шуба; холод доходит до неё слабо
	depth = swe / rho
	target := T > 0 ? 0 : T * math.exp(-depth / 0.15)
	ts += (target - ts) * (1 - math.exp(-dt / (48 * (1 + depth / 0.1))))
	c^ = {swe = f32(swe), rho = f32(rho), albedo = f32(alb), liquid = f32(liq), canopy = f32(can), t_soil = f32(ts), last = c.last}
}

// Доля земли под снегом (Niu и Yang, 2007): тонкий снег лежит пятнами, а
// подтаявший (серый, плотный) — тем более: сначала сходит там, где тоньше.
// Сухой холодный слежавшийся снег лежит ровнее — показатель ниже.
snow_coverage :: proc "contextless" (depth, rho, albedo: f64) -> f64 {
	if depth <= 0 do return 0
	m := 0.5 + 1.1 * clamp((0.75 - albedo) / 0.2, 0, 1)
	return math.tanh(depth / (2.5 * 0.01 * math.pow(max(rho, 50) / 100, m)))
}

// ---------------------------------------------------------------- сетка

// Оси клетки (i, j) сетки и точка на шаре.
@(private = "file")
snow_cell_dir :: proc(g: ^Snow_Grid, i, j: int, R: f64) -> [3]f64 {
	x := ((f64(i) + 0.5) / SNOW_N * 2 - 1) * SNOW_EXTENT
	y := ((f64(j) + 0.5) / SNOW_N * 2 - 1) * SNOW_EXTENT
	p := g.centre * R + g.east * x + g.north * y
	return p / math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
}

// Сколько часов прошлого считать при старте: год планеты (не больше двух земных).
@(private = "file")
snow_spin_hours :: proc() -> f64 {
	return math.floor(min(climate.year_h, 2 * EARTH_YEAR_HOURS) / SNOW_STEP_H) * SNOW_STEP_H
}

// Новая сетка вокруг req.centre: климат клеток, высоты уровней, вечные снега.
@(private = "file")
snow_grid_setup :: proc(ss: ^Snow_State, g: ^Snow_Grid, req: Snow_Request) {
	R := ss.model.radius
	g.centre = req.centre
	g.east, g.north = wx_axes(req.centre)
	lo, hi := 1.0e9, -1.0e9
	for j in 0 ..< SNOW_N do for i in 0 ..< SNOW_N {
		d := snow_cell_dir(g, i, j, R)
		// высоты: по нескольким точкам клетки (вершины тоже)
		alt := 0.0
		for v in 0 ..< 3 do for u in 0 ..< 3 {
			x := ((f64(i) + (f64(u) + 0.5) / 3) / SNOW_N * 2 - 1) * SNOW_EXTENT
			y := ((f64(j) + (f64(v) + 0.5) / 3) / SNOW_N * 2 - 1) * SNOW_EXTENT
			p := g.centre * R + g.east * x + g.north * y
			p = p / math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z) * R
			e := elevation(ss.seed, p, 1000)
			if u == 1 && v == 1 do alt = e
			if e > 0 {
				lo = min(lo, e)
				hi = max(hi, e)
			}
		}
		cp := climate_point(&climate, ss.seed, d * R, max(alt, 0))
		cp.alt = 0 // температура — у моря, уровни — свои
		cp.land = alt > 0
		g.clim[j * SNOW_N + i] = cp
	}
	if hi < lo do lo, hi = 0, 100 // одно море
	lo = max(lo - 50, 0)
	hi = max(hi + 200, lo + 700)
	g.lo = lo
	g.step = (hi - lo) / (SNOW_LEVELS - 1)
	// выше снеговой линии — вечный снег (фирн), как у ледников в мире
	for j in 0 ..< SNOW_N do for i in 0 ..< SNOW_N {
		cp := g.clim[j * SNOW_N + i]
		line := climate_height_of(&climate, &cp, 0)
		t, _ := climate_at(&climate, &cp, req.season - snow_spin_hours() / climate.year_h) // где начинается расчёт
		for k in 0 ..< SNOW_LEVELS {
			c := &g.cells[(k * SNOW_N + j) * SNOW_N + i]
			alt := g.lo + f64(k) * g.step
			c^ = {rho = 100, albedo = 0.85, t_soil = f32(t - climate.lapse * alt), last = 1.0e6}
			// фирн: сами вечные снега — блоки снега в мире, сверху — слой, что лежит весь год
			if alt > line do c^ = {swe = 300, rho = 500, albedo = 0.6, t_soil = -1, last = 1.0e6}
		}
	}
}

// Погода на шаг для клетки и шаги всех её уровней.
@(private = "file")
snow_advance_cell :: proc(ss: ^Snow_State, g: ^Snow_Grid, i, j: int, t_h, season, hour, dt: f64, loc: ^Wx_Local) {
	d := snow_cell_dir(g, i, j, ss.model.radius)
	cp := &g.clim[j * SNOW_N + i]
	w := weather_at(ss.model, d, loc^, t_h, hour)
	cosz, flux := climate_sun(&climate, cp.lat, season, hour)
	sun := flux * max(cosz, 0) * climate.clear_sky
	wind := math.sqrt(w.wind.x * w.wind.x + w.wind.y * w.wind.y)
	for k in 0 ..< SNOW_LEVELS {
		alt := g.lo + f64(k) * g.step
		f := Snow_Forcing{rain = w.rain, t = w.t_air - climate.lapse * alt, cover = w.cover, wind = wind, sun = sun, rh = w.rh}
		snow_step(&g.cells[(k * SNOW_N + j) * SNOW_N + i], f, dt)
	}
}

// Местное время и сезон за dh часов до запроса.
@(private = "file")
snow_when :: proc(ss: ^Snow_State, req: Snow_Request, dh: f64) -> (season, hour: f64) {
	season = req.season - dh / climate.year_h
	hour = math.mod(req.hour - dh * 24 / ss.day_h, 24)
	if hour < 0 do hour += 24
	return
}

@(private = "file")
Spin_Job :: struct {
	ss:    ^Snow_State,
	req:   Snow_Request,
	k, n:  int, // строки k, k+n, …
	t0:    f64, // начало расчёта, ч назад
}

// Год погоды для строк сетки (свой поток).
@(private = "file")
snow_spin_rows :: proc(data: rawptr) {
	job := (^Spin_Job)(data)
	ss := job.ss
	g := ss.work
	steps := int(job.t0 / SNOW_STEP_H)
	for j := job.k; j < SNOW_N; j += job.n {
		for i in 0 ..< SNOW_N {
			loc: Wx_Local
			for s in 0 ..< steps {
				dh := job.t0 - f64(s) * SNOW_STEP_H
				season, hour := snow_when(ss, job.req, dh)
				if s % 8 == 0 do loc = wx_local_of(&climate, &g.clim[j * SNOW_N + i], season) // климат — раз в сутки
				snow_advance_cell(ss, g, i, j, job.req.t_h - dh, season, hour, SNOW_STEP_H, &loc)
			}
		}
	}
}

@(private = "file")
snow_worker :: proc(data: rawptr) {
	ss := (^Snow_State)(data)
	for {
		sync.mutex_lock(&ss.mutex)
		for !ss.pending && !ss.quit do sync.cond_wait(&ss.cond, &ss.mutex)
		if ss.quit {
			sync.mutex_unlock(&ss.mutex)
			return
		}
		req := ss.req
		ss.pending = false
		ss.busy = true
		ss.spin = req.full
		sync.mutex_unlock(&ss.mutex)

		g := ss.work
		if req.full {
			// прошлый год (не больше двух земных — у долгих лет хватит и этого)
			t_start := time.now()
			snow_grid_setup(ss, g, req)
			t0 := snow_spin_hours()
			n := clamp(os.get_processor_core_count() - 2, 1, 12)
			jobs := make([]Spin_Job, n)
			threads := make([]^thread.Thread, n)
			for k in 0 ..< n {
				jobs[k] = {ss = ss, req = req, k = k, n = n, t0 = t0}
				threads[k] = thread.create_and_start_with_data(&jobs[k], snow_spin_rows)
			}
			for t in threads {
				thread.join(t)
				thread.destroy(t)
			}
			delete(jobs)
			delete(threads)
			g.t_h = req.t_h
			g.ok = true
			fmt.printfln("снег: прошлый год (%d клеток × %d высот) посчитан за %.1f с на %d потоках", SNOW_N * SNOW_N, SNOW_LEVELS, time.duration_seconds(time.since(t_start)), n)
		} else if g.ok && req.t_h > g.t_h {
			// вперёд — до запрошенного времени шагами не длиннее трёх часов
			for g.t_h < req.t_h - 1e-6 {
				dt := min(req.t_h - g.t_h, SNOW_STEP_H)
				dh := req.t_h - (g.t_h + dt)
				season, hour := snow_when(ss, req, dh)
				for j in 0 ..< SNOW_N do for i in 0 ..< SNOW_N {
					loc := wx_local_of(&climate, &g.clim[j * SNOW_N + i], season)
					snow_advance_cell(ss, g, i, j, g.t_h + dt, season, hour, dt, &loc)
				}
				g.t_h += dt
			}
		}

		sync.mutex_lock(&ss.mutex)
		consumed := !ss.ready
		sync.mutex_unlock(&ss.mutex)
		if consumed && g.ok {
			ss.back^ = g^
			snow_fill_tex(ss.back, ss.tex_buf)
		}
		sync.mutex_lock(&ss.mutex)
		ss.busy = false
		ss.spin = false
		if consumed && g.ok do ss.ready = true
		sync.mutex_unlock(&ss.mutex)
	}
}

// Данные текстуры: глубина (м), белизна, снег на кронах (доля), плотность (т/м³);
// долю покрытой земли шейдер считает из смешанных глубины, плотности и белизны.
@(private = "file")
snow_fill_tex :: proc(g: ^Snow_Grid, buf: []f32) {
	for c, idx in g.cells {
		depth := c.swe > 0 ? f64(c.swe) / f64(c.rho) : 0
		buf[idx * 4 + 0] = f32(depth)
		buf[idx * 4 + 1] = c.albedo
		buf[idx * 4 + 2] = f32(clamp(f64(c.canopy) / SNOW_CANOPY_REF, 0, 1))
		buf[idx * 4 + 3] = c.rho / 1000
	}
}

// Каждый кадр: готовую сетку — в текстуру; новый шаг — когда время ушло
// вперёд; заново — если ушли далеко или время скакнуло.
snow_update :: proc(ss: ^Snow_State, dir: [3]f64, t_h, season, hour: f64) {
	sync.mutex_lock(&ss.mutex)
	defer sync.mutex_unlock(&ss.mutex)
	if ss.ready {
		ss.front, ss.back = ss.back, ss.front
		ss.ready = false
		gl.BindTexture(gl.TEXTURE_3D, ss.tex)
		gl.TexSubImage3D(gl.TEXTURE_3D, 0, 0, 0, 0, SNOW_N, SNOW_N, SNOW_LEVELS, gl.RGBA, gl.FLOAT, raw_data(ss.tex_buf))
		gl.BindTexture(gl.TEXTURE_3D, 0)
	}
	if ss.busy || ss.pending do return
	g := ss.work // поток спит — читать можно
	full := !g.ok
	if g.ok {
		dc := (dir - g.centre) * ss.model.radius
		if math.sqrt(dc.x * dc.x + dc.y * dc.y + dc.z * dc.z) > SNOW_RECENTRE do full = true
		if t_h < g.t_h - 0.5 || t_h - g.t_h > 24 * 60 do full = true // время назад или скачок на месяцы
	}
	if !full && t_h - g.t_h < 0.05 do return
	ss.req = {centre = dir, t_h = t_h, season = season, hour = hour, full = full}
	ss.pending = true
	sync.cond_signal(&ss.cond)
}

// Снег в точке d (оси планеты) на высоте alt (м над морем) — как в шейдере.
snow_here :: proc(ss: ^Snow_State, d: [3]f64, alt: f64) -> (h: Snow_Here) {
	g := ss.front
	if !g.ok do return
	rel := (d - g.centre) * ss.model.radius
	u := ((rel.x * g.east.x + rel.y * g.east.y + rel.z * g.east.z) / SNOW_EXTENT + 1) / 2
	v := ((rel.x * g.north.x + rel.y * g.north.y + rel.z * g.north.z) / SNOW_EXTENT + 1) / 2
	if u < 0 || v < 0 || u > 1 || v > 1 do return
	fx := clamp(u * SNOW_N - 0.5, 0, SNOW_N - 1.001)
	fy := clamp(v * SNOW_N - 0.5, 0, SNOW_N - 1.001)
	fl := clamp((alt - g.lo) / g.step, 0, SNOW_LEVELS - 1.001)
	i0, j0, k0 := int(fx), int(fy), int(fl)
	gx, gy, gk := fx - f64(i0), fy - f64(j0), fl - f64(k0)
	h.last = 1.0e9
	for dk in 0 ..< 2 do for dj in 0 ..< 2 do for di in 0 ..< 2 {
		w := (di == 0 ? 1 - gx : gx) * (dj == 0 ? 1 - gy : gy) * (dk == 0 ? 1 - gk : gk)
		c := &g.cells[((k0 + dk) * SNOW_N + j0 + dj) * SNOW_N + i0 + di]
		depth := c.swe > 0 ? f64(c.swe) / f64(c.rho) : 0
		h.depth += w * depth
		h.swe += w * f64(c.swe)
		h.albedo += w * f64(c.albedo)
		h.canopy += w * f64(c.canopy)
		if c.swe > 0 do h.last = min(h.last, f64(c.last))
	}
	h.rho = h.depth > 1e-4 ? h.swe / h.depth : 100
	h.cover = snow_coverage(h.depth, h.rho, h.albedo) // как в шейдере — из смешанных величин
	h.ok = true
	return
}

// Связь сетки с шейдерами: середина в координатах шума облаков, оси, уровни.
snow_shader_params :: proc(ss: ^Snow_State, c: ^Clouds) -> (q0, e, n: [3]f64, lv: [4]f64) {
	g := ss.front
	if !g.ok || c == nil do return
	q0 = cloud_q(c, g.centre * ss.model.radius)
	k := CLOUD_SCALE / (2 * SNOW_EXTENT)
	e = g.east * k
	n = g.north * k
	lv = {g.lo, g.step, SNOW_LEVELS, 1}
	return
}

// Снимок покрытия снегом для карты погоды (оттепельные туманы): главный поток
// кладёт его, пока фоновый поток карты спит.
Snow_Snap :: struct {
	cov:                 [SNOW_N * SNOW_N * SNOW_LEVELS]f32,
	centre, east, north: [3]f64,
	lo, step:            f64,
	ok:                  bool,
}

snow_snapshot :: proc(ss: ^Snow_State, s: ^Snow_Snap) {
	g := ss.front
	s.ok = g.ok
	if !g.ok do return
	s.centre, s.east, s.north, s.lo, s.step = g.centre, g.east, g.north, g.lo, g.step
	for c, i in g.cells {
		depth := c.swe > 0 ? f64(c.swe) / f64(c.rho) : 0
		s.cov[i] = f32(snow_coverage(depth, f64(c.rho), f64(c.albedo)))
	}
}

// Покрытие снегом в точке d на высоте alt по снимку (0 — снега нет или сетки нет).
snow_snap_at :: proc(s: ^Snow_Snap, d: [3]f64, alt, R: f64) -> f64 {
	if !s.ok do return 0
	rel := (d - s.centre) * R
	u := ((rel.x * s.east.x + rel.y * s.east.y + rel.z * s.east.z) / SNOW_EXTENT + 1) / 2
	v := ((rel.x * s.north.x + rel.y * s.north.y + rel.z * s.north.z) / SNOW_EXTENT + 1) / 2
	if u < 0 || v < 0 || u > 1 || v > 1 do return 0
	i := clamp(int(u * SNOW_N), 0, SNOW_N - 1)
	j := clamp(int(v * SNOW_N), 0, SNOW_N - 1)
	k := clamp(int((alt - s.lo) / s.step + 0.5), 0, SNOW_LEVELS - 1)
	return f64(s.cov[(k * SNOW_N + j) * SNOW_N + i])
}

// Снег на блоке (x, y, z) кадра: сколько его лежит сверху (м) и на сколько он
// держит (м). Под ногой снег сжимается, пока не выдержит вес человека, —
// примерно до 450 кг/м³: пушистый свежий проминается почти до земли,
// слежавшийся держит больше, мокрый и наст — почти весь.
snow_on_block :: proc(w: ^World, x, y, z: i32) -> (depth, support: f64) {
	ss := w.snow
	if ss == nil || !ss.front.ok do return
	face, gx, gz, ok := world_resolve(w, x, z)
	if !ok do return
	col := world_column(w, column_key_of(face, gx, gz))
	if col == nil do return
	i := column_index(gx, gz)
	if y + 1 < col.sky_snow[i] do return
	above, loaded := world_get_block(w, x, y + 1, z)
	if !loaded || BLOCK_INFO[above].solid || above == .Water do return
	h := snow_here(ss, geo_frame_dir(&w.geo, f64(x) + 0.5, f64(z) + 0.5), f64(y + 1) - Y_SEA)
	if !h.ok || h.depth < 0.005 do return
	// под хвоей снега меньше; глубже блока снег не рисуется (ступени остались бы
	// стенами) — и держит как метровый
	depth = min(h.depth, SNOW_LIFT_MAX) * (y + 1 < col.sky_bare[i] ? 0.6 : 1)
	support = depth * min(h.rho / 450, 1)
	return
}
