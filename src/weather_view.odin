package main

// Погода вокруг игрока (0.017): карта погоды на ±160 км (облачность, тучи,
// осадки, снег) — считается в фоне и уходит в текстуру для облаков и их
// теней; погода там, где стоишь (ветер, давление, температура) — каждый кадр.
// 0.018: на карте и туман (слой: низ, верх, густота) — в низинах, у моря,
// низкие облака на холмах; и частота молний — для гроз вокруг.

import "core:fmt"
import "core:math"
import "core:sync"
import "core:thread"
import gl "vendor:OpenGL"

WX_N :: 128 // клеток карты по стороне
WX_EXTENT :: 160_000.0 // м: от середины карты до края
WX_CORNERS :: 9 // климат на карте — по сетке 9×9 (дальше плавно)
WX_TN :: 160 // рельеф для тумана: клеток по стороне
WX_TEXTENT :: 200_000.0 // м: от середины до края
WX_NO_FOG :: [4]f32{-1000, -1000, 0, 0}

Wx_Grid :: struct {
	centre, east, north: [3]f64, // середина карты и её оси (единичные векторы, оси планеты)
	cells:               [WX_N * WX_N][4]u8, // облачность, тучи, осадки (√(мм/ч / 50)), доля снега
	mean:                [4]f64, // средние по карте (0..1) — облака за её краем
	fog:                 [WX_N * WX_N][4]f32, // туман: низ и верх слоя (м над морем), ослабление (1/м)
	kind:                [WX_N * WX_N]Fog_Kind,
	flash:               [WX_N * WX_N]f32, // молний на км² в час
	fog_top:             f32, // верх самого высокого слоя тумана на карте, м (< −999 — тумана нет)
	ok:                  bool,
}

// Рельеф для тумана (один раз на место): дно низин, средняя высота, доля
// суши, близость и сторона моря.
Wx_Terrain :: struct {
	floor, mean, land: f32,
	on:                [2]f32, // с моря сюда (восток, север); длина — близость берега
}

Wx_Request :: struct {
	centre: [3]f64,
	t_h:    f64, // время погоды, ч
	season: f64,
	hour:   f64, // местное время, ч
}

Weather_State :: struct {
	model:      Weather_Model,
	seed:       i64,
	here:       Weather_Point, // погода там, где стоит игрок
	here_ok:    bool,
	wind_frame: [3]f64, // ветер у игрока в осях кадра, м/с
	press_3h:   f64, // давление здесь три часа назад, гПа (тенденция)
	fog_cam:    [4]f64, // туман у камеры (как в шейдере): низ, верх, ослабление; w — 1: карта есть
	fog_kind:   Fog_Kind, // какой туман в клетке игрока
	precip:     Precip, // капли и хлопья вокруг камеры (precip.odin)
	front:      Wx_Grid, // для главного потока (облака, тени, F3)
	back:       Wx_Grid, // считает фоновый поток
	tex:        u32,
	fog_tex:    u32,
	layer_h:    f64, // высота слоя облаков (низкие облака — ниже его)
	// фоновый поток
	mutex:      sync.Mutex,
	cond:       sync.Cond,
	worker:     ^thread.Thread,
	req:        Wx_Request,
	pending:    bool, // запрос ждёт потока
	busy:       bool,
	ready:      bool, // back готов
	quit:       bool,
	last_post:  f64,
	// климат по углам карты (для фонового потока)
	corners:    [WX_CORNERS * WX_CORNERS]Climate_Point,
	c_centre:   [3]f64,
	c_ok:       bool,
	// рельеф (для фонового потока)
	terrain:    [WX_TN * WX_TN]Wx_Terrain,
	t_centre:   [3]f64,
	t_east:     [3]f64,
	t_north:    [3]f64,
	t_ok:       bool,
	snow:       Snow_Snap, // снег для оттепельных туманов (кладёт главный поток, пока этот спит)
}

weather_state_init :: proc(ws: ^Weather_State, seed: u32, hp: ^Planet, day_h, layer_h: f64) {
	ws.seed = i64(seed)
	ws.layer_h = layer_h
	weather_init(&ws.model, seed, hp.radius_km, hp.sidereal_hours, day_h, hp.atmo.density, hp.atmo.pressure, &climate)
	gl.GenTextures(1, &ws.tex)
	gl.BindTexture(gl.TEXTURE_2D, ws.tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, WX_N, WX_N, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.GenTextures(1, &ws.fog_tex)
	gl.BindTexture(gl.TEXTURE_2D, ws.fog_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, WX_N, WX_N, 0, gl.RGBA, gl.FLOAT, nil)
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
	gl.DeleteTextures(1, &ws.fog_tex)
}

// Оси на шаре у точки d: на восток и на север.
wx_axes :: proc(d: [3]f64) -> (east, north: [3]f64) {
	east = {d.z, 0, -d.x}
	el := math.sqrt(east.x * east.x + east.z * east.z)
	east = el > 1e-6 ? east / el : {1, 0, 0}
	north = {d.y * east.z - d.z * east.y, d.z * east.x - d.x * east.z, d.x * east.y - d.y * east.x}
	return
}

// Климат места на этот момент года.
wx_local :: proc(cp: ^Climate_Point, season: f64) -> Wx_Local {
	return wx_local_of(&climate, cp, season)
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

// Рельеф вокруг centre для тумана: в каждой клетке 3×3 точки — дно низин и
// средняя высота (в низинах ясной ночью стоит холодный воздух), доля суши;
// затем — где море и в какую сторону от него берег.
@(private = "file")
wx_terrain_build :: proc(ws: ^Weather_State, centre: [3]f64) {
	R := ws.model.radius
	east, north := wx_axes(centre)
	ws.t_centre, ws.t_east, ws.t_north = centre, east, north
	cell := 2 * WX_TEXTENT / WX_TN
	for j in 0 ..< WX_TN do for i in 0 ..< WX_TN {
		lo, sum, land := 1.0e9, 0.0, 0
		for v in 0 ..< 3 do for u in 0 ..< 3 {
			x := ((f64(i) + (f64(u) + 0.5) / 3) / WX_TN * 2 - 1) * WX_TEXTENT
			y := ((f64(j) + (f64(v) + 0.5) / 3) / WX_TN * 2 - 1) * WX_TEXTENT
			p := centre * R + east * x + north * y
			p = p / math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z) * R
			e := elevation(ws.seed, p, 500)
			lo = min(lo, e)
			sum += e
			if e > 0 do land += 1
		}
		ws.terrain[j * WX_TN + i] = {floor = f32(lo), mean = f32(sum / 9), land = f32(land) / 9}
	}
	// море рядом: направление с моря и близость (затухает за ~5 км)
	RAD :: 6
	for j in 0 ..< WX_TN do for i in 0 ..< WX_TN {
		t := &ws.terrain[j * WX_TN + i]
		if t.land < 0.5 do continue
		dir: [2]f64
		near := 0.0
		for dj in -RAD ..= RAD do for di in -RAD ..= RAD {
			ii, jj := i + di, j + dj
			if ii < 0 || jj < 0 || ii >= WX_TN || jj >= WX_TN || (di == 0 && dj == 0) do continue
			if ws.terrain[jj * WX_TN + ii].land >= 0.5 do continue
			dist := math.sqrt(f64(di * di + dj * dj)) * cell
			k := math.exp(-dist / 5000)
			dir += [2]f64{f64(-di), f64(-dj)} / math.sqrt(f64(di * di + dj * dj)) * k
			near = max(near, k)
		}
		if l := math.sqrt(dir.x * dir.x + dir.y * dir.y); l > 1e-9 do t.on = {f32(dir.x / l * near), f32(dir.y / l * near)}
	}
	ws.t_ok = true
}

// Рельеф в точке p (м, оси планеты): дно, средняя, суша — плавно, берег — по ближайшей клетке.
@(private = "file")
wx_terrain_at :: proc(ws: ^Weather_State, p: [3]f64) -> (t: Wx_Terrain) {
	R := ws.model.radius
	rel := p - ws.t_centre * R
	u := clamp(((rel.x * ws.t_east.x + rel.y * ws.t_east.y + rel.z * ws.t_east.z) / WX_TEXTENT + 1) / 2 * WX_TN - 0.5, 0, WX_TN - 1.001)
	v := clamp(((rel.x * ws.t_north.x + rel.y * ws.t_north.y + rel.z * ws.t_north.z) / WX_TEXTENT + 1) / 2 * WX_TN - 0.5, 0, WX_TN - 1.001)
	i0, j0 := int(u), int(v)
	fu, fv := f32(u - f64(i0)), f32(v - f64(j0))
	a := ws.terrain[j0 * WX_TN + i0]
	b := ws.terrain[j0 * WX_TN + i0 + 1]
	c := ws.terrain[(j0 + 1) * WX_TN + i0]
	d := ws.terrain[(j0 + 1) * WX_TN + i0 + 1]
	bl :: proc(a, b, c, d, fu, fv: f32) -> f32 {return (a * (1 - fu) + b * fu) * (1 - fv) + (c * (1 - fu) + d * fu) * fv}
	t.floor = bl(a.floor, b.floor, c.floor, d.floor, fu, fv)
	t.mean = bl(a.mean, b.mean, c.mean, d.mean, fu, fv)
	t.land = bl(a.land, b.land, c.land, d.land, fu, fv)
	n := ws.terrain[int(v + 0.5) * WX_TN + int(u + 0.5)]
	t.on = n.on
	return
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
	// рельеф — заново, если ушли на 30 км
	dt := req.centre - ws.t_centre
	if !ws.t_ok || math.sqrt(dt.x * dt.x + dt.y * dt.y + dt.z * dt.z) * R > 30_000 do wx_terrain_build(ws, req.centre)
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
		// суша и высота — по рельефу клетки (дно низин: там ложится туман)
		tr := wx_terrain_at(ws, d * R)
		land := tr.land > 0.5
		cp := Climate_Point {
			lat  = math.to_degrees(math.asin(clamp(d.y, -1, 1))),
			alt  = land ? max(f64(tr.floor), 0) : 0,
			cont = bl(c00.cont, c10.cont, c01.cont, c11.cont, fu, fv),
			wet  = bl(c00.wet, c10.wet, c01.wet, c11.wet, fu, fv),
			land = land,
		}
		loc := wx_local(&cp, req.season)
		loc.pool = clamp(f64(tr.mean - tr.floor) / 50, 0, 4)
		loc.onshore = {f64(tr.on.x), f64(tr.on.y)}
		loc.snow = snow_snap_at(&ws.snow, d, cp.alt, R)
		w := weather_at(&ws.model, d, loc, req.t_h, req.hour)
		idx := j * WX_N + i
		g.cells[idx] = {
			u8(clamp(w.cover, 0, 1) * 255 + 0.5),
			u8(clamp(w.storm, 0, 1) * 255 + 0.5),
			u8(clamp(math.sqrt(w.rain / 50), 0, 1) * 255 + 0.5),
			u8(clamp(w.snow, 0, 1) * 255 + 0.5),
		}
		g.fog[idx], g.kind[idx] = wx_fog_slab(ws, &w, &cp)
		g.flash[idx] = f32(w.flash)
	}
	g.mean = {}
	for c in g.cells do for k in 0 ..< 4 do g.mean[k] += f64(c[k]) / 255 / (WX_N * WX_N)
	g.fog_top = -2000
	for f in g.fog do if f.z > 0 do g.fog_top = max(g.fog_top, f.y)
	g.ok = true
}

// Слой тумана в клетке: туман у земли (низины, море) или низкие облака,
// что лежат на холмах (нижняя кромка — по точке росы).
@(private = "file")
wx_fog_slab :: proc(ws: ^Weather_State, w: ^Weather_Point, cp: ^Climate_Point) -> ([4]f32, Fog_Kind) {
	if w.fog > 0 {
		base := w.fog_kind == .Radiation || w.fog_kind == .Thaw ? cp.alt : 0 // морской — от уровня моря
		return {-1000, f32(base + w.fog_depth), f32(w.fog), 0}, w.fog_kind
	}
	if w.cover > 0.88 && w.cloud_base < ws.layer_h {
		// в облаке видно на 40–150 м: дождевые гуще
		bottom := w.cloud_base
		top := min(bottom + 300 + 900 * w.storm, ws.layer_h + 300)
		k := clamp((w.cover - 0.88) / 0.07, 0, 1)
		return {f32(bottom), f32(top), f32(k * 3.912 / (40 + 110 * (1 - w.storm))), 0}, .Cloud
	}
	return WX_NO_FOG, .None
}

// Каждый кадр: погода у игрока (dir — вертикаль в точке игрока, оси планеты),
// новая карта — раз в полсекунды, готовая — в текстуру.
weather_update :: proc(ws: ^Weather_State, ss: ^Snow_State, dir: [3]f64, cp: Climate_Point, t_h, season, hour, now: f64) {
	c := cp
	loc := wx_local(&c, season)
	ws.here = weather_at(&ws.model, dir, loc, t_h, hour)
	ws.press_3h = weather_at(&ws.model, dir, loc, t_h - 3, hour - 3).press
	ws.here_ok = true
	sync.mutex_lock(&ws.mutex)
	if ws.ready {
		ws.front = ws.back
		ws.ready = false
		gl.BindTexture(gl.TEXTURE_2D, ws.tex)
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, WX_N, WX_N, gl.RGBA, gl.UNSIGNED_BYTE, &ws.front.cells[0])
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
		gl.BindTexture(gl.TEXTURE_2D, ws.fog_tex)
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, WX_N, WX_N, gl.RGBA, gl.FLOAT, &ws.front.fog[0])
		gl.BindTexture(gl.TEXTURE_2D, 0)
	}
	if !ws.busy && !ws.pending && (now - ws.last_post > 0.5 || !ws.front.ok) {
		ws.req = {centre = dir, t_h = t_h, season = season, hour = hour}
		if ss != nil do snow_snapshot(ss, &ws.snow)
		ws.pending = true
		ws.last_post = now
		sync.cond_signal(&ws.cond)
	}
	sync.mutex_unlock(&ws.mutex)
	// туман у игрока — по карте, как его видит шейдер
	ws.fog_cam = {}
	ws.fog_kind = .None
	if g := &ws.front; g.ok {
		uv := wx_uv(g, dir, ws.model.radius)
		f := wx_fog_sample(g, uv)
		ws.fog_cam = {f64(f.x), f64(f.y), f64(f.z), 1}
		i := clamp(int(uv.x * WX_N), 0, WX_N - 1)
		j := clamp(int(uv.y * WX_N), 0, WX_N - 1)
		ws.fog_kind = g.kind[j * WX_N + i]
	}
}

// Доля карты (0..1 от края до края) для точки d (оси планеты).
wx_uv :: proc(g: ^Wx_Grid, d: [3]f64, R: f64) -> [2]f64 {
	rel := (d - g.centre) * R
	return {
		((rel.x * g.east.x + rel.y * g.east.y + rel.z * g.east.z) / WX_EXTENT + 1) / 2,
		((rel.x * g.north.x + rel.y * g.north.y + rel.z * g.north.z) / WX_EXTENT + 1) / 2,
	}
}

// Туман на карте по координатам uv — как его читает видеокарта (за краем — нет).
wx_fog_sample :: proc(g: ^Wx_Grid, uv: [2]f64) -> [4]f32 {
	u := clamp(uv.x * WX_N - 0.5, 0, WX_N - 1.001)
	v := clamp(uv.y * WX_N - 0.5, 0, WX_N - 1.001)
	i0, j0 := int(u), int(v)
	fu, fv := f32(u - f64(i0)), f32(v - f64(j0))
	a := g.fog[j0 * WX_N + i0]
	b := g.fog[j0 * WX_N + i0 + 1]
	c := g.fog[(j0 + 1) * WX_N + i0]
	e := g.fog[(j0 + 1) * WX_N + i0 + 1]
	f := (a * (1 - fu) + b * fu) * (1 - fv) + (c * (1 - fu) + e * fu) * fv
	ex := max(abs(uv.x - 0.5), abs(uv.y - 0.5))
	f.z *= f32(1 - clamp((ex - 0.42) / 0.08, 0, 1))
	return f
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
	val := wx_sample(g, wx_uv(g, d, R))
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
// ищется в честной погоде, ничего не подгоняя. Туман и грозу ищем и по часам
// (туман — к утру, грозы — после полудня; nightstorm — ночью сухо, а вокруг
// грозы). Возвращает сдвиг, ст. ч.
weather_find :: proc(ws: ^Weather_State, dir: [3]f64, cp: Climate_Point, a: ^Astro, T0, hour: f64, want: string) -> (shift: f64, ok: bool) {
	c := cp
	by_hour := want == "fog" || want == "thunder" || want == "nightstorm"
	steps := by_hour ? 2000 * 24 : 2000
	for k in 0 ..< steps {
		dt := by_hour ? f64(k) * a.day / 24 : f64(k) * a.day
		T := T0 + dt
		h := math.mod(hour + dt / a.day * 24, 24)
		loc := wx_local(&c, climate_season(a, T))
		loc.pool = 2 // в низине
		w := weather_at(&ws.model, dir, loc, weather_time(a, T), h)
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
		case "fog":
			hit = w.fog > 0.01 && h > 4 && h < 9
		case "thunder":
			// грозы рядом, а здесь почти сухо — молнии видно (сквозь ливень их не видно)
			hit = w.rain < 0.5 && wx_ring_flash(ws, dir, loc, weather_time(a, T), h) > 0.3
		case "nightstorm":
			// ночь, здесь сухо, а вокруг грозы — молнии видно издалека
			hit = (h < 4 || h > 20) && w.rain < 0.2 && wx_ring_flash(ws, dir, loc, weather_time(a, T), h) > 0.3
		case "firstsnow":
			// первый снег: идёт снег, а неделю до этого было тепло (земля голая)
			if w.rain > 0.2 && w.snow > 0.9 {
				warm := 0.0
				for k2 in 1 ..= 7 {
					Tp := T - f64(k2) * a.day
					wp := weather_at(&ws.model, dir, wx_local(&c, climate_season(a, Tp)), weather_time(a, Tp), h)
					warm += wp.t_air / 7
				}
				hit = warm > 2
			}
		}
		if hit do return dt, true
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

// Дымка во влажном воздухе: капельки на пылинках растут — видимость 10 км
// при 90% и ~2 км у 98%; ослабление (1/м) сверх сухой дымки.
wx_mist :: proc(rh: f64) -> f64 {
	if rh <= 0.9 do return 0
	v := 10_000 * math.pow(max(1 - rh, 0.005) / 0.1, 0.8)
	return 3.912 / v - 3.912 / 10_000
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
	if w.flash > 0.05 && w.snow < 0.5 do what = "ливень с грозой"
	return sky, fmt.tprintf("%s %s (%.1f мм/ч)", how, what, w.rain)
}

FOG_NAMES := [Fog_Kind]string {
	.None      = "",
	.Radiation = "радиационный туман (ясной тихой ночью остыл воздух у земли)",
	.Sea       = "морской туман (тёплый влажный воздух над холодным морем)",
	.Steam     = "парение (мороз над открытой водой)",
	.Thaw      = "оттепельный туман (тёплый влажный воздух над снегом)",
	.Cloud     = "низкие облака лежат на холмах",
}

// Молний в среднем в восьми точках в 20 км вокруг dir (для поиска гроз -wx:).
@(private = "file")
wx_ring_flash :: proc(ws: ^Weather_State, dir: [3]f64, loc: Wx_Local, t_h, hour: f64) -> (ring: f64) {
	e1, e2 := wx_axes(dir)
	for k in 0 ..< 8 {
		an := f64(k) / 8 * math.TAU
		q := dir + (e1 * math.cos(an) + e2 * math.sin(an)) * (20_000 / ws.model.radius)
		q /= math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
		ring += weather_at(&ws.model, q, loc, t_h, hour).flash / 8
	}
	return
}
