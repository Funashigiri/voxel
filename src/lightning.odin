package main

// Молнии (0.018). Сколько их — по карте погоды (weather.odin, wx_flash_rate:
// ∝ сильный ливень × неустойчивость воздуха), молний на км² в час. Частота —
// по настоящему времени (как снос облаков и падение капель): активная гроза
// сверкает раз в десятки секунд. Время делится на отрезки по 0,25
// настоящей секунды (нарезаны по часам игры), и в каждой клетке карты вспышка
// случается с вероятностью по её частоте (зерно — от места и отрезка: в тот же
// момент мира в том же месте — та же молния).
//
// Доля ударов в землю — по широте (Prentice и Mackerras, 1977: у экватора
// ~1 из 7, в средних широтах ~1 из 3); остальные — в облаке, видны как
// подсветка облаков (зарницы за горизонтом). Ток — логнормальный, медиана
// ~30 кА; молния бьёт в самое высокое место в пределах «радиуса притяжения»
// 10·I^0,65 м (~90 м при 30 кА) — в деревья и вершины. Канал ломаный, с
// ветвями; 2–6 обратных ударов через 40–80 мс; вспышка освещает облака и
// землю (ночью близкий удар — как днём на миг). Звука пока нет — гром в F3:
// через сколько секунд он пришёл бы (звук идёт ~340 м/с).

import "core:math"
import "core:math/linalg"
import eng "engine"
import gl "vendor:OpenGL"

LIGHTNING_SLOT :: 0.25 // с: шаг розыгрыша вспышек
BOLT_MAX :: 8 // одновременно видимых вспышек
BOLT_PTS :: 160 // точек канала с ветвями
BOLT_NEAR :: 300.0 // м: ближе — рисуется вместе с блоками (иначе — в дальнем проходе)

Bolt :: struct {
	t0:       f64, // начало (настоящее время, с)
	ground:   bool, // в землю (иначе — в облаке)
	strokes:  int,
	stroke_t: [6]f32, // начала обратных ударов, с от t0
	current:  f64, // ток, кА
	foot:     [3]f64, // куда ударила (оси планеты, м); у вспышки в облаке — под ней на земле
	top:      [3]f64, // откуда (низ облака)
	pts:      [BOLT_PTS][3]f32, // точки канала: смещения от foot (м, оси планеты)
	seg:      [BOLT_PTS][2]u8, // отрезки: номера точек
	glow:     [BOLT_PTS]f32, // яркость отрезка (ветви тусклее)
	nseg:     int,
	dist:     f64, // от игрока, м
	duration: f32,
}

Lightning :: struct {
	bolts:     [BOLT_MAX]Bolt,
	n:         int,
	slot:      i64, // последний разыгранный отрезок
	seed:      u32,
	prog:      u32,
	vao, vbo:  u32,
	u_vp:      i32,
	u_log:     i32,
	u_logk:    i32,
	verts:     [dynamic]Bolt_Vertex,
	// для F3
	last_dist: f64, // до последнего удара в землю, м
	last_t:    f64, // когда он был (настоящее время, с); < 0 — не было
	recent:    [64]f64, // времена вспышек ближе 20 км
	recent_n:  int,
	flash_k:   f64, // освещение от вспышек сейчас (0 — нет)
}

Bolt_Vertex :: struct {
	pos: [3]f32,
	col: [3]f32,
}

lightning_init :: proc(lt: ^Lightning, seed: u32) -> bool {
	lt.seed = seed
	lt.last_t = -1
	lt.slot = -1
	lt.prog = eng.shader_create("bolt", BOLT_VS, BOLT_FS) or_return
	lt.u_vp = eng.uniform_loc(lt.prog, "u_view_proj")
	lt.u_log = eng.uniform_loc(lt.prog, "u_log")
	lt.u_logk = eng.uniform_loc(lt.prog, "u_logk")
	gl.GenVertexArrays(1, &lt.vao)
	gl.GenBuffers(1, &lt.vbo)
	gl.BindVertexArray(lt.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, lt.vbo)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, size_of(Bolt_Vertex), 0)
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 3, gl.FLOAT, false, size_of(Bolt_Vertex), offset_of(Bolt_Vertex, col))
	gl.BindVertexArray(0)
	return true
}

lightning_destroy :: proc(lt: ^Lightning) {
	gl.DeleteVertexArrays(1, &lt.vao)
	gl.DeleteBuffers(1, &lt.vbo)
	gl.DeleteProgram(lt.prog)
	delete(lt.verts)
}

// Яркость вспышки в момент t (с от начала): обратные удары гаснут за ~30 мс,
// между ними тлеет продолжающийся ток.
@(private = "file")
bolt_brightness :: proc(b: ^Bolt, t: f64) -> f64 {
	if t < 0 || t > f64(b.duration) do return 0
	v := 0.0
	for k in 0 ..< b.strokes {
		dt := t - f64(b.stroke_t[k])
		if dt >= 0 do v = max(v, math.exp(-dt / 0.03))
	}
	return max(v, 0.12) * math.sqrt(b.current / 30)
}

// Канал: ломаная от низа облака до земли (середины отрезков смещаются вбок —
// так ветвится настоящий ступенчатый лидер), и несколько ветвей вниз.
@(private = "file")
bolt_shape :: proc(b: ^Bolt, r: ^eng.Rng, up, e1, e2: [3]f64, height: f64) {
	n := 0
	add :: proc(b: ^Bolt, n: ^int, p: [3]f64) -> int {
		if n^ >= BOLT_PTS do return BOLT_PTS - 1
		b.pts[n^] = {f32(p.x), f32(p.y), f32(p.z)}
		n^ += 1
		return n^ - 1
	}
	add_seg :: proc(b: ^Bolt, a, c: int, glow: f32) {
		if b.nseg >= BOLT_PTS || a == c do return
		b.seg[b.nseg] = {u8(a), u8(c)}
		b.glow[b.nseg] = glow
		b.nseg += 1
	}
	// главный канал: 64 отрезка, смещения ~ длине отрезка
	MAIN :: 64
	chan: [MAIN + 1][3]f64
	chan[0] = up * height
	chan[MAIN] = {}
	step := MAIN
	for step > 1 {
		half := step / 2
		for i := 0; i + step <= MAIN; i += step {
			a, c := chan[i], chan[i + step]
			l := linalg.length(c - a)
			off := (e1 * eng.rng_range(r, -1, 1) + e2 * eng.rng_range(r, -1, 1)) * l * 0.22
			chan[i + half] = (a + c) / 2 + off
		}
		step = half
	}
	idx: [MAIN + 1]int
	for i in 0 ..= MAIN do idx[i] = add(b, &n, chan[i])
	for i in 0 ..< MAIN do add_seg(b, idx[i], idx[i + 1], 1)
	// ветви: от верхних двух третей канала вниз и вбок, тусклее и короче
	branches := eng.rng_int(r, 2, 5)
	for _ in 0 ..< branches {
		i0 := eng.rng_int(r, 4, MAIN * 2 / 3)
		start := chan[i0]
		dir := -up * eng.rng_range(r, 0.6, 1) + (e1 * eng.rng_range(r, -1, 1) + e2 * eng.rng_range(r, -1, 1)) * 0.7
		dir = linalg.normalize(dir)
		length := linalg.dot(start, up) * eng.rng_range(r, 0.15, 0.45)
		prev := idx[i0]
		p := start
		parts := 10
		for k in 0 ..< parts {
			p += dir * (length / f64(parts)) + (e1 * eng.rng_range(r, -1, 1) + e2 * eng.rng_range(r, -1, 1)) * (length / f64(parts)) * 0.5
			cur := add(b, &n, p)
			add_seg(b, prev, cur, f32(0.45 * (1 - f64(k) / f64(parts))))
			prev = cur
		}
	}
}

// Самая высокая точка рядом с ударом: блоки (если рядом с игроком) или рельеф.
@(private = "file")
strike_point :: proc(w: ^World, pv: ^Planet_View, seed: i64, d: [3]f64, R, reach: f64, player: [3]f64) -> [3]f64 {
	rel := planet_rel(pv, d * R)
	horiz := math.sqrt(rel.x * rel.x + rel.z * rel.z)
	if horiz < 160 {
		// в мире блоков: выше всех — то, до чего достаёт свет неба (деревья, скалы)
		cx := player.x + rel.x
		cz := player.z + rel.z
		best := [3]f64{cx, -1.0e9, cz}
		rr := i32(min(reach, 120))
		for dz := -rr; dz <= rr; dz += 2 do for dx := -rr; dx <= rr; dx += 2 {
			if dx * dx + dz * dz > rr * rr do continue
			x, z := i32(math.floor(cx)) + dx, i32(math.floor(cz)) + dz
			face, gx, gz, ok := world_resolve(w, x, z)
			if !ok do continue
			col := world_column(w, column_key_of(face, gx, gz))
			if col == nil do continue
			top := f64(col.sky[column_index(gx, gz)])
			if top > best.y do best = {f64(x) + 0.5, top, f64(z) + 0.5}
		}
		if best.y > -1.0e8 {
			up := geo_frame_dir(&w.geo, best.x, best.z)
			return up * (R + best.y - Y_SEA)
		}
	}
	// вдали — по рельефу: вершина в радиусе притяжения
	e1, e2 := wx_axes(d)
	best_d := d
	best_h := elevation(seed, d * R, 200)
	for k in 0 ..< 8 {
		a := f64(k) / 8 * math.TAU
		q := d + (e1 * math.cos(a) + e2 * math.sin(a)) * (reach * 0.7 / R)
		q /= linalg.length(q)
		h := elevation(seed, q * R, 200)
		if h > best_h do best_d, best_h = q, h
	}
	return best_d * (R + max(best_h, 0))
}

// Розыгрыш вспышек на новые отрезки времени и старение старых.
// now — настоящее время (с), им живут вспышки; game_s — часы игры (с) и
// game_rate — сколько игровых секунд в настоящей: по ним нарезаны отрезки
// розыгрыша (0,25 настоящей секунды), чтобы в тот же момент мира была та же молния.
lightning_update :: proc(lt: ^Lightning, ws: ^Weather_State, w: ^World, clouds: ^Clouds, player: [3]f64, now, game_s, game_rate: f64) {
	// старые — прочь
	k := 0
	for i in 0 ..< lt.n {
		if now - lt.bolts[i].t0 < f64(lt.bolts[i].duration) + 0.1 {
			lt.bolts[k] = lt.bolts[i]
			k += 1
		}
	}
	lt.n = k
	slot := i64(math.floor(game_s / (LIGHTNING_SLOT * max(game_rate, 1e-6))))
	if lt.slot < 0 || slot - lt.slot > 8 do lt.slot = slot - 1 // после паузы — без лавины
	g := &ws.front
	if ws == nil || !g.ok || clouds == nil {
		lt.slot = slot
		return
	}
	R := ws.model.radius
	pv := planet_view_make(&w.geo, player)
	cell_km2 := (2 * WX_EXTENT / WX_N / 1000) * (2 * WX_EXTENT / WX_N / 1000)
	for s := lt.slot + 1; s <= slot; s += 1 {
		for j in 0 ..< WX_N do for i in 0 ..< WX_N {
			lam := f64(g.flash[j * WX_N + i])
			if lam <= 0 do continue
			expect := lam * cell_km2 * LIGHTNING_SLOT / 3600
			x := ((f64(i) + 0.5) / WX_N * 2 - 1) * WX_EXTENT
			y := ((f64(j) + 0.5) / WX_N * 2 - 1) * WX_EXTENT
			p := g.centre * R + g.east * x + g.north * y
			key := [3]i32{i32(math.floor(p.x / 2500)), i32(math.floor(p.y / 2500)), i32(math.floor(p.z / 2500))}
			h := eng.hash3(key.x, key.y, key.z, lt.seed ~ u32(s & 0xffffffff) ~ u32(s >> 32) * 0x9E37)
			if f64(h & 0xffffff) / f64(0x1000000) >= expect do continue
			r := eng.rng_make(u64(h) * 0x2545F491 + u64(s))
			// место в клетке
			p += g.east * eng.rng_range(&r, -1250, 1250) + g.north * eng.rng_range(&r, -1250, 1250)
			d := p / linalg.length(p)
			lat := math.asin(clamp(d.y, -1, 1))
			z := 4.16 + 2.16 * math.cos(3 * lat) // облачных на одну в землю
			b: Bolt
			b.t0 = now
			b.ground = eng.rng_f64(&r) < 1 / (1 + z)
			b.current = 30 * math.exp(0.7 * math.sqrt(-2 * math.ln(max(eng.rng_f64(&r), 1e-9))) * math.cos(math.TAU * eng.rng_f64(&r)))
			b.strokes = b.ground ? eng.rng_int(&r, 2, 6) : eng.rng_int(&r, 3, 8)
			tt: f32 = 0
			for k2 in 0 ..< min(b.strokes, 6) {
				b.stroke_t[k2] = tt
				tt += f32(eng.rng_range(&r, 0.04, 0.08))
			}
			b.strokes = min(b.strokes, 6)
			b.duration = tt + 0.08
			base := clouds.height
			reach := 10 * math.pow(b.current, 0.65)
			if b.ground {
				b.foot = strike_point(w, &pv, ws.seed, d, R, reach, player)
			} else {
				b.foot = d * (R + max(elevation(ws.seed, d * R, 2000), 0))
			}
			fu := b.foot / linalg.length(b.foot)
			// низ грозовой тучи — в ~1,5 км над землёй (слой облаков лежит над морем на
			// одной высоте — над высокой сушей канал от него был бы короче настоящего)
			b.top = fu * (max(R + base + 300, linalg.length(b.foot) + 1500))
			b.dist = linalg.length(b.foot - pv.pc)
			if b.ground {
				e1, e2 := wx_axes(fu)
				bolt_shape(&b, &r, fu, e1, e2, linalg.length(b.top) - linalg.length(b.foot))
				if lt.last_t < 0 || b.dist < 20_000 || now - lt.last_t > 30 {
					lt.last_dist = b.dist
					lt.last_t = now
				}
			}
			if b.dist < 20_000 {
				lt.recent[lt.recent_n % len(lt.recent)] = now
				lt.recent_n += 1
			}
			// место — самым ярким: ближние вытесняют дальние
			if lt.n < BOLT_MAX {
				lt.bolts[lt.n] = b
				lt.n += 1
			} else {
				far := 0
				for q in 1 ..< lt.n do if lt.bolts[q].dist > lt.bolts[far].dist do far = q
				if lt.bolts[far].dist > b.dist do lt.bolts[far] = b
			}
		}
	}
	lt.slot = slot
}

// Вспышек ближе 20 км за последнюю минуту.
lightning_per_minute :: proc(lt: ^Lightning, now: f64) -> int {
	c := 0
	for i in 0 ..< min(lt.recent_n, len(lt.recent)) do if now - lt.recent[i] < 60 do c += 1
	return c
}

// Свет вспышек на этот кадр: сцена и небо светлее, облака подсвечены изнутри.
lightning_light :: proc(lt: ^Lightning, now: f64, pv: ^Planet_View, light: ^[4]f32, sky_top, sky_horizon: ^[3]f32, flash: ^[4][4]f32, haze_beta: f64) {
	flash^ = {}
	lt.flash_k = 0
	// днём при свете солнца подсветка облаков почти незаметна, ночью — во всё облако
	dark := 1 - clamp(f64(light.r * 0.3 + light.g * 0.59 + light.b * 0.11), 0, 1)
	glow := 0.05 + 0.95 * dark * dark
	FLASH_COLOR :: [3]f32{0.78, 0.82, 1.0}
	slot := 0
	for i in 0 ..< lt.n {
		b := &lt.bolts[i]
		br := bolt_brightness(b, now - b.t0)
		if br <= 0 do continue
		// освещённость от канала падает с расстоянием (и в мгле — сильнее)
		// вспышка светит рассеянно (тучи, мгла) — дождь гасит её слабее прямого луча
		k := br * (b.ground ? 1 : 0.4) / (1 + (b.dist / 3000) * (b.dist / 3000)) * math.exp(-haze_beta * b.dist * 0.1)
		lt.flash_k = max(lt.flash_k, k)
		if slot < 4 {
			c := planet_rel(pv, b.top * 0.8 + b.foot * 0.2)
			flash[slot] = {f32(c.x), f32(c.y), f32(c.z), f32(br * (b.ground ? 1.5 : 1) * glow)}
			slot += 1
		}
	}
	k := f32(min(lt.flash_k, 1.5))
	if k > 0 {
		light.rgb += FLASH_COLOR * k * 0.8
		sky_top^ += FLASH_COLOR * k * 0.35
		sky_horizon^ += FLASH_COLOR * k * 0.45
	}
}

// Каналы молний: near — ближние (вместе с блоками), иначе — дальние (логарифмическая глубина).
lightning_draw :: proc(lt: ^Lightning, now: f64, pv: ^Planet_View, view_proj: matrix[4, 4]f32, near: bool, px: f32) {
	clear(&lt.verts)
	for i in 0 ..< lt.n {
		b := &lt.bolts[i]
		if !b.ground || (b.dist < BOLT_NEAR) != near do continue
		br := f32(bolt_brightness(b, now - b.t0))
		if br <= 0 do continue
		foot := planet_rel(pv, b.foot)
		jinv := pv.jinv
		for s in 0 ..< b.nseg {
			pa := b.pts[b.seg[s][0]]
			pb_ := b.pts[b.seg[s][1]]
			a := foot + jinv * [3]f64{f64(pa.x), f64(pa.y), f64(pa.z)}
			c := foot + jinv * [3]f64{f64(pb_.x), f64(pb_.y), f64(pb_.z)}
			af := [3]f32{f32(a.x), f32(a.y), f32(a.z)}
			cf := [3]f32{f32(c.x), f32(c.y), f32(c.z)}
			g := b.glow[s] * br
			// ширина: канал ~ метр, но не тоньше полутора пикселей; свечение — шире
			dist := linalg.length(af)
			core := max(0.6, 1.5 * px * dist)
			side := linalg.cross(cf - af, af)
			sl := linalg.length(side)
			if sl < 1e-6 do continue
			side /= sl
			bright := [3]f32{0.9, 0.92, 1.0} * g * 2.5
			glowc := [3]f32{0.45, 0.5, 1.0} * g * 0.5
			quad :: proc(v: ^[dynamic]Bolt_Vertex, a, c, s: [3]f32, ca, cb: [3]f32) {
				append(v, Bolt_Vertex{a - s, cb}, Bolt_Vertex{a + s, ca}, Bolt_Vertex{c + s, ca})
				append(v, Bolt_Vertex{a - s, cb}, Bolt_Vertex{c + s, ca}, Bolt_Vertex{c - s, cb})
			}
			quad(&lt.verts, af, cf, side * core, bright, bright)
			// свечение: от оси (ярко) к краю (тьма) — две полосы
			gw := side * core * 8
			append(&lt.verts, Bolt_Vertex{af, glowc}, Bolt_Vertex{af + gw, {}}, Bolt_Vertex{cf + gw, {}})
			append(&lt.verts, Bolt_Vertex{af, glowc}, Bolt_Vertex{cf + gw, {}}, Bolt_Vertex{cf, glowc})
			append(&lt.verts, Bolt_Vertex{af, glowc}, Bolt_Vertex{cf - gw, {}}, Bolt_Vertex{af - gw, {}})
			append(&lt.verts, Bolt_Vertex{af, glowc}, Bolt_Vertex{cf, glowc}, Bolt_Vertex{cf - gw, {}})
		}
	}
	if len(lt.verts) == 0 do return
	gl.UseProgram(lt.prog)
	m := view_proj
	gl.UniformMatrix4fv(lt.u_vp, 1, false, &m[0, 0])
	gl.Uniform1f(lt.u_log, near ? 0 : 1)
	gl.Uniform1f(lt.u_logk, f32(2 / math.log2(FAR_LOG_FAR + 1)))
	gl.BindVertexArray(lt.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, lt.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(lt.verts) * size_of(Bolt_Vertex), raw_data(lt.verts), gl.STREAM_DRAW)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.ONE, gl.ONE)
	gl.DepthMask(false)
	gl.Disable(gl.CULL_FACE)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(len(lt.verts)))
	gl.DepthMask(true)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.Disable(gl.BLEND)
	gl.BindVertexArray(0)
}

// Отладка (-look:bolt): только что ударившая в землю молния ближе max_dist,
// которую не заслоняет рельеф, — направление на середину её канала (оси кадра у камеры).
lightning_fresh_strike :: proc(lt: ^Lightning, pv: ^Planet_View, seed: i64, now, max_dist, rain_beta: f64) -> (dir: [3]f32, ok: bool) {
	R := pv.radius
	for i in 0 ..< lt.n {
		b := &lt.bolts[i]
		if !b.ground || now - b.t0 > 0.03 || b.dist > max_dist do continue
		if math.exp(-rain_beta * b.dist) < 0.15 do continue // за стеной дождя не видно
		// видна ли нижняя треть канала: рельеф вдоль луча ниже луча
		target := b.foot + (b.top - b.foot) * 0.3
		seen := true
		for k in 1 ..< 24 {
			p := pv.pc + (target - pv.pc) * (f64(k) / 24)
			pl := linalg.length(p)
			if elevation(seed, p / pl * R, 300) > pl - R {
				seen = false
				break
			}
		}
		if !seen do continue
		c := planet_rel(pv, (b.foot + b.top) / 2)
		l := linalg.length(c)
		if l < 1 do continue
		return {f32(c.x / l), f32(c.y / l), f32(c.z / l)}, true
	}
	return
}
