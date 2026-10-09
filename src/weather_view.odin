package main

// Погода вокруг игрока (0.017): карта погоды на ±160 км (облачность, тучи,
// осадки, снег) — считается в фоне и уходит в текстуру для облаков и их
// теней; погода там, где стоишь (ветер, давление, температура) — каждый кадр.

import "core:fmt"
import "core:math"
import "core:sync"
import "core:thread"
import gl "vendor:OpenGL"

WX_N :: 128 // клеток карты по стороне
WX_EXTENT :: 160_000.0 // м: от середины карты до края
WX_CORNERS :: 9 // климат на карте — по сетке 9×9 (дальше плавно)

Wx_Grid :: struct {
	centre, east, north: [3]f64, // середина карты и её оси (единичные векторы, оси планеты)
	cells:               [WX_N * WX_N][4]u8, // облачность, тучи, осадки (√(мм/ч / 50)), доля снега
	mean:                [4]f64, // средние по карте (0..1) — облака за её краем
	ok:                  bool,
}

Wx_Request :: struct {
	centre: [3]f64,
	t_h:    f64, // время погоды, ч
	season: f64,
	hour:   f64, // местное время, ч
}

Weather_State :: struct {
	model:     Weather_Model,
	seed:      i64,
	here:      Weather_Point, // погода там, где стоит игрок
	here_ok:   bool,
	wind_frame: [3]f64, // ветер у игрока в осях кадра, м/с
	press_3h:  f64, // давление здесь три часа назад, гПа (тенденция)
	precip:    Precip, // капли и хлопья вокруг камеры (precip.odin)
	front:     Wx_Grid, // для главного потока (облака, тени, F3)
	back:      Wx_Grid, // считает фоновый поток
	tex:       u32,
	// фоновый поток
	mutex:     sync.Mutex,
	cond:      sync.Cond,
	worker:    ^thread.Thread,
	req:       Wx_Request,
	pending:   bool, // запрос ждёт потока
	busy:      bool,
	ready:     bool, // back готов
	quit:      bool,
	last_post: f64,
	// климат по углам карты (для фонового потока)
	corners:   [WX_CORNERS * WX_CORNERS]Climate_Point,
	c_centre:  [3]f64,
	c_ok:      bool,
}

weather_state_init :: proc(ws: ^Weather_State, seed: u32, hp: ^Planet, day_h: f64) {
	ws.seed = i64(seed)
	weather_init(&ws.model, seed, hp.radius_km, hp.sidereal_hours, day_h, hp.atmo.density, hp.atmo.pressure, &climate)
	gl.GenTextures(1, &ws.tex)
	gl.BindTexture(gl.TEXTURE_2D, ws.tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, WX_N, WX_N, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	precip_init(&ws.precip, seed, hp.atmo.density)
	ws.worker = thread.create_and_start_with_data(ws, wx_worker)
}

weather_state_destroy :: proc(ws: ^Weather_State) {
	sync.mutex_lock(&ws.mutex)
	ws.quit = true
	sync.cond_broadcast(&ws.cond)
	sync.mutex_unlock(&ws.mutex)
	thread.join(ws.worker)
	thread.destroy(ws.worker)
	gl.DeleteTextures(1, &ws.tex)
}

// Оси на шаре у точки d: на восток и на север.
wx_axes :: proc(d: [3]f64) -> (east, north: [3]f64) {
	east = {d.z, 0, -d.x}
	el := math.sqrt(east.x * east.x + east.z * east.z)
	east = el > 1e-6 ? east / el : {1, 0, 0}
	north = {d.y * east.z - d.z * east.y, d.z * east.x - d.x * east.z, d.x * east.y - d.y * east.x}
	return
}

// Климат места на этот момент года (сухость — по осадкам месяца и теплу).
wx_local :: proc(cp: ^Climate_Point, season: f64) -> Wx_Local {
	t, p := climate_at(&climate, cp, season)
	aridity := p * 12 / max(20 * max(t, 0) + 280, 100)
	return {lat = cp.lat, t = t, p = p, dry = clamp(1.5 - aridity, 0, 1), land = cp.land, sea_t = climate_sea_t(&climate, cp.lat, season)}
}

@(private = "file")
wx_worker :: proc(data: rawptr) {
	ws := (^Weather_State)(data)
	for {
		sync.mutex_lock(&ws.mutex)
		for !ws.pending && !ws.quit do sync.cond_wait(&ws.cond, &ws.mutex)
		if ws.quit {
			sync.mutex_unlock(&ws.mutex)
			return
		}
		req := ws.req
		ws.pending = false
		ws.busy = true
		sync.mutex_unlock(&ws.mutex)

		wx_build(ws, req)

		sync.mutex_lock(&ws.mutex)
		ws.busy = false
		ws.ready = true
		sync.mutex_unlock(&ws.mutex)
	}
}

// Карта погоды вокруг req.centre (фоновый поток).
@(private = "file")
wx_build :: proc(ws: ^Weather_State, req: Wx_Request) {
	R := ws.model.radius
	east, north := wx_axes(req.centre)
	// климат по углам — заново, если ушли далеко
	dc := req.centre - ws.c_centre
	if !ws.c_ok || math.sqrt(dc.x * dc.x + dc.y * dc.y + dc.z * dc.z) * R > 20_000 {
		for j in 0 ..< WX_CORNERS do for i in 0 ..< WX_CORNERS {
			x := (f64(i) / (WX_CORNERS - 1) * 2 - 1) * WX_EXTENT
			y := (f64(j) / (WX_CORNERS - 1) * 2 - 1) * WX_EXTENT
			p := req.centre * R + east * x + north * y
			p = p / math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z) * R
			ws.corners[j * WX_CORNERS + i] = climate_point(&climate, ws.seed, p, elevation(ws.seed, p, 2000))
		}
		ws.c_centre = req.centre
		ws.c_ok = true
	}
	ce, cn := wx_axes(ws.c_centre)
	g := &ws.back
	g.centre, g.east, g.north = req.centre, east, north
	for j in 0 ..< WX_N do for i in 0 ..< WX_N {
		x := ((f64(i) + 0.5) / WX_N * 2 - 1) * WX_EXTENT
		y := ((f64(j) + 0.5) / WX_N * 2 - 1) * WX_EXTENT
		p := req.centre * R + east * x + north * y
		d := p / math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
		// климат: между углами сетки климата
		rel := d * R - ws.c_centre * R
		u := clamp(((rel.x * ce.x + rel.y * ce.y + rel.z * ce.z) / WX_EXTENT + 1) / 2 * (WX_CORNERS - 1), 0, WX_CORNERS - 1.001)
		v := clamp(((rel.x * cn.x + rel.y * cn.y + rel.z * cn.z) / WX_EXTENT + 1) / 2 * (WX_CORNERS - 1), 0, WX_CORNERS - 1.001)
		i0, j0 := int(u), int(v)
		fu, fv := u - f64(i0), v - f64(j0)
		c00 := &ws.corners[j0 * WX_CORNERS + i0]
		c10 := &ws.corners[j0 * WX_CORNERS + i0 + 1]
		c01 := &ws.corners[(j0 + 1) * WX_CORNERS + i0]
		c11 := &ws.corners[(j0 + 1) * WX_CORNERS + i0 + 1]
		bl :: proc(a, b, c, d, fu, fv: f64) -> f64 {return (a * (1 - fu) + b * fu) * (1 - fv) + (c * (1 - fu) + d * fu) * fv}
		alt := bl(c00.alt, c10.alt, c01.alt, c11.alt, fu, fv)
		land := bl(f64(int(c00.land)), f64(int(c10.land)), f64(int(c01.land)), f64(int(c11.land)), fu, fv) > 0.5
		cp := Climate_Point {
			lat  = math.to_degrees(math.asin(clamp(d.y, -1, 1))),
			alt  = land ? alt : 0,
			cont = bl(c00.cont, c10.cont, c01.cont, c11.cont, fu, fv),
			wet  = bl(c00.wet, c10.wet, c01.wet, c11.wet, fu, fv),
			land = land,
		}
		w := weather_at(&ws.model, d, wx_local(&cp, req.season), req.t_h, req.hour, false)
		g.cells[j * WX_N + i] = {
			u8(clamp(w.cover, 0, 1) * 255 + 0.5),
			u8(clamp(w.storm, 0, 1) * 255 + 0.5),
			u8(clamp(math.sqrt(w.rain / 50), 0, 1) * 255 + 0.5),
			u8(clamp(w.snow, 0, 1) * 255 + 0.5),
		}
	}
	g.mean = {}
	for c in g.cells do for k in 0 ..< 4 do g.mean[k] += f64(c[k]) / 255 / (WX_N * WX_N)
	g.ok = true
}

// Каждый кадр: погода у игрока (dir — вертикаль в точке игрока, оси планеты),
// новая карта — раз в полсекунды, готовая — в текстуру.
weather_update :: proc(ws: ^Weather_State, dir: [3]f64, cp: Climate_Point, t_h, season, hour, now: f64) {
	c := cp
	ws.here = weather_at(&ws.model, dir, wx_local(&c, season), t_h, hour)
	ws.press_3h = weather_at(&ws.model, dir, wx_local(&c, season), t_h - 3, hour - 3).press
	ws.here_ok = true
	sync.mutex_lock(&ws.mutex)
	if ws.ready {
		ws.front = ws.back
		ws.ready = false
		gl.BindTexture(gl.TEXTURE_2D, ws.tex)
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, WX_N, WX_N, gl.RGBA, gl.UNSIGNED_BYTE, &ws.front.cells[0])
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
		gl.BindTexture(gl.TEXTURE_2D, 0)
	}
	if !ws.busy && !ws.pending && (now - ws.last_post > 0.5 || !ws.front.ok) {
		ws.req = {centre = dir, t_h = t_h, season = season, hour = hour}
		ws.pending = true
		ws.last_post = now
		sync.cond_signal(&ws.cond)
	}
	sync.mutex_unlock(&ws.mutex)
}

// Карта по координатам uv (0..1 — от края до края), как её читает видеокарта
// (сглаживание между центрами клеток, за краем — край): облачность, тучи, осадки, снег (0..1).
wx_sample :: proc(g: ^Wx_Grid, uv: [2]f64) -> (val: [4]f64) {
	u := clamp(uv.x * WX_N - 0.5, 0, WX_N - 1.001)
	v := clamp(uv.y * WX_N - 0.5, 0, WX_N - 1.001)
	i0, j0 := int(u), int(v)
	fu, fv := u - f64(i0), v - f64(j0)
	for k in 0 ..< 4 {
		a := f64(g.cells[j0 * WX_N + i0][k])
		b := f64(g.cells[j0 * WX_N + i0 + 1][k])
		c := f64(g.cells[(j0 + 1) * WX_N + i0][k])
		e := f64(g.cells[(j0 + 1) * WX_N + i0 + 1][k])
		val[k] = ((a * (1 - fu) + b * fu) * (1 - fv) + (c * (1 - fu) + e * fu) * fv) / 255
	}
	return
}

// Карта в точке d (оси планеты, единичный вектор): облачность, тучи, осадки (мм/ч), снег.
wx_grid_at :: proc(g: ^Wx_Grid, d: [3]f64, R: f64) -> (cover, storm, rain, snow: f64) {
	if !g.ok do return 0.4, 0, 0, 0
	rel := (d - g.centre) * R
	val := wx_sample(g, {
		((rel.x * g.east.x + rel.y * g.east.y + rel.z * g.east.z) / WX_EXTENT + 1) / 2,
		((rel.x * g.north.x + rel.y * g.north.y + rel.z * g.north.z) / WX_EXTENT + 1) / 2,
	})
	return val[0], val[1], val[2] * val[2] * 50, val[3]
}

// Как wx_at в шейдере: за краем карты — средняя по карте.
wx_sample_far :: proc(g: ^Wx_Grid, uv: [2]f64) -> [4]f64 {
	v := wx_sample(g, uv)
	ex := max(abs(uv.x - 0.5), abs(uv.y - 0.5))
	t := clamp((ex - 0.42) / 0.08, 0, 1)
	t = t * t * (3 - 2 * t)
	return v + (g.mean - v) * t
}

// Связь карты с облаками на этот кадр: координаты шума облаков -> доля карты.
weather_link_clouds :: proc(ws: ^Weather_State, c: ^Clouds) {
	c.wx = &ws.front
	if !ws.front.ok do return
	g := &ws.front
	c.wx_q0 = cloud_q(c, g.centre * ws.model.radius)
	k := CLOUD_SCALE / (2 * WX_EXTENT)
	c.wx_e = g.east * k
	c.wx_n = g.north * k
}

// Отладка (-wx:…): ближайший день (в тот же час), когда здесь такая погода —
// ищется в честной погоде, ничего не подгоняя. Возвращает сдвиг, ст. ч.
weather_find :: proc(ws: ^Weather_State, dir: [3]f64, cp: Climate_Point, a: ^Astro, T0, hour: f64, want: string) -> (shift: f64, ok: bool) {
	c := cp
	for k in 0 ..< 2000 {
		T := T0 + f64(k) * a.day
		w := weather_at(&ws.model, dir, wx_local(&c, climate_season(a, T)), weather_time(a, T), hour)
		hit := false
		switch want {
		case "rain":
			hit = w.rain > 2 && w.snow < 0.1
		case "snow":
			hit = w.rain > 0.5 && w.snow > 0.9
		case "storm":
			hit = w.conv > 8 && w.snow < 0.1
		case "clear":
			hit = w.cover < 0.1
		case "overcast":
			hit = w.cover > 0.9 && w.rain < 0.05
		}
		if hit do return T - T0, true
	}
	return
}

// Видимость в осадках, м (как мгла в шейдерах): 0 — осадков нет.
wx_visibility :: proc(rain, snow: f64) -> f64 {
	if rain <= 0.02 do return 0
	vr := 11_200 * math.pow(max(rain, 0.05), -0.6)
	vs := 1_600 * math.pow(max(rain, 0.02), -0.7)
	return 1 / ((1 - snow) / vr + snow / vs)
}

// Откуда дует ветер (восток, север — куда, м/с) — словами.
wx_wind_from :: proc(u, v: f64) -> string {
	if math.sqrt(u * u + v * v) < 0.5 do return "штиль"
	names := [8]string{"с запада", "с юго-запада", "с юга", "с юго-востока", "с востока", "с северо-востока", "с севера", "с северо-запада"}
	a := math.atan2(v, u) // направление, куда дует (0 — на восток)
	k := int(math.round(a / (math.PI / 4)))
	return names[(k % 8 + 8) % 8]
}

// Погода словами для F3.
wx_describe :: proc(w: ^Weather_Point) -> (sky, precip: string) {
	switch {
	case w.cover < 0.15:
		sky = "ясно"
	case w.cover < 0.45:
		sky = "малооблачно"
	case w.cover < 0.8:
		sky = "переменная облачность"
	case w.storm > 0.5:
		sky = "тучи"
	case:
		sky = "пасмурно"
	}
	if w.rain < 0.05 do return sky, "без осадков"
	what := w.snow > 0.9 ? "снег" : w.snow > 0.1 ? "мокрый снег" : w.conv > 0.5 * w.rain ? "ливень" : "дождь"
	how := w.rain < 0.5 ? "слабый" : w.rain < 4 ? "умеренный" : w.rain < 15 ? "сильный" : "очень сильный"
	if w.conv > 8 && w.snow < 0.1 do what = "ливень с грозой"
	return sky, fmt.tprintf("%s %s (%.1f мм/ч)", how, what, w.rain)
}
