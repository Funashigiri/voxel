package main

// Звёздное небо из настоящей вселенной: на небе ровно те звёзды, что
// сгенерированы вокруг нас (stars.odin), — ничего не нарисовано.
//  * Каталог видимых глазом звёзд (до 6,5 звёздной величины): перебор
//    клеток вокруг нас — для каждого типа до расстояния, дальше которого даже
//    самые яркие его звёзды глазу не видны. Свет слабеет и краснеет в
//    межзвёздной пыли.
//  * Карта свечения неба: миллиарды неразличимых звёзд галактики — полоса
//    вроде Млечного Пути с тёмными прожилками пыли — и соседние галактики
//    туманными пятнами.
//  * Всё это считается один раз в фоновом потоке (на своей копии вселенной),
//    а небо поворачивается вместе с планетой.
// Направления хранятся в осях вселенной; в оси нашей системы их переводит
// поворот из astro.odin.

import "core:fmt"
import "core:math"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"
import eng "engine"
import gl "vendor:OpenGL"

MAG_LIMIT :: 6.5 // предел человеческого глаза на тёмном небе
BAND_W :: 256 // карта свечения неба (широта/долгота в осях вселенной)
BAND_H :: 128
LIGHT_SAMPLES :: 256 // направления для подсчёта ночного света от свечения неба
AIRGLOW_LUX :: 0.0006 // собственное свечение ночного воздуха
VEGA_LUX :: 2.54e-6 // освещённость от звезды нулевой величины
LSUN_LY_LUX :: 3.18e-5 // от светимости Солнца с расстояния в световой год (полоса V)
L_PER_STAR :: 0.5 // средняя светимость звезды населения в полосе V, светимостей Солнца
BAND_CAL :: 25.0 // поправка яркости свечения — откалибрована по Млечному Пути
BAND_REF :: 2e-4 // лк/ср — типичная яркость Млечного Пути
BAND_DISP :: 0.07 // её яркость на экране
GALAXY_VIEW_LY :: 13e6 // соседние галактики ищем в этом радиусе

// До какого расстояния искать звёзды каждого типа (св. лет): дальше даже самые
// яркие из них слабее 6,5 величины. Нейтронные звёзды и чёрные дыры не видны.
SKY_RADIUS := [Star_Class]f64 {
	.M           = 16,
	.K           = 50,
	.G           = 90,
	.F           = 150,
	.A           = 450,
	.B           = 2500,
	.O           = 15000,
	.Red_Giant   = 2500,
	.White_Dwarf = 6,
	.Neutron     = 0,
	.Black_Hole  = 0,
}

Sky_Star :: struct {
	dir:   [3]f32, // от нас, оси вселенной
	mag:   f32, // видимая звёздная величина (с пылью)
	color: [3]f32,
	phase: f32, // фаза мерцания
	seed:  u64,
	class: Star_Class,
	dist:  f32, // св. лет
	dust:  f32, // ослабление пылью, звёздных величин
}

Sky_Galaxy :: struct {
	seed: u64,
	kind: Galaxy_Kind,
	mag:  f32,
	size: f32, // угловой размер, градусы
	dist: f32, // св. лет
}

@(private = "file")
Star_Vertex :: struct {
	dir:   [3]f32,
	col:   [4]f32, // цвет, звёздная величина
	phase: f32, // < 0 — не мерцает (планета)
}

Star_Sky :: struct {
	world_seed: u32,
	home:       Home,
	// результат фонового расчёта
	stars:      [dynamic]Sky_Star, // от ярких к тусклым
	galaxies:   [dynamic]Sky_Galaxy, // соседние галактики, видимые глазом
	band:       []f32, // BAND_W×BAND_H×3, лк/ср
	tau:        []f32, // пыль нашей галактики до края, по направлениям
	light_dir:  [LIGHT_SAMPLES][3]f32,
	light_lum:  [LIGHT_SAMPLES]f32,
	core_dir:   [3]f64, // на центр нашей галактики
	core_dust:  f64, // ослабление пылью в ту сторону, звёздных величин
	core_dist:  f64,
	considered: int, // сколько звёзд перебрано
	build_ms:   f64,
	done:       bool, // расчёт закончен (атомарно)
	cancel:     bool, // выходим из игры — бросить расчёт (атомарно)
	// главный поток
	worker:     ^thread.Thread,
	ready:      bool, // загружено в видеокарту
	prog:       u32,
	u_view_proj, u_u2f, u_mlim, u_time, u_scale, u_moon: i32,
	vao, vbo:   u32,
	pvao, pvbo: u32, // планеты (каждый кадр)
	count:      i32,
	tex:        u32,
}

// Абсолютная звёздная величина в полосе V: светимость и болометрическая
// поправка по температуре (горячие звёзды светят в ультрафиолете, холодные — в инфракрасном).
star_abs_mag :: proc(s: ^Star) -> f64 {
	if s.luminosity <= 0 || s.temperature <= 0 do return 99
	x := math.log10(s.temperature) - 4
	bc := (((-8.499 * x + 13.421) * x - 8.131) * x - 3.901) * x - 0.438
	return 4.74 - 2.5 * math.log10(s.luminosity) - bc
}

// Ослабление света пылью на отрезке от нас (rels — мы относительно центров галактик).
@(private = "file")
dust_along :: proc(gals: []Galaxy, rels: [][3]f64, dir: [3]f64, d: f64) -> f64 {
	n := clamp(int(d / 25), 6, 48)
	ds := d / f64(n)
	tau := 0.0
	for k in 0 ..< n {
		s := (f64(k) + 0.5) * ds
		for &g, i in gals do tau += galaxy_dust(&g, rels[i] + dir * s) * ds
	}
	return tau
}

// Направление центра клетки карты свечения (оси вселенной).
band_dir :: proc(i, j: int) -> [3]f64 {
	lat := (f64(j) + 0.5) / BAND_H * math.PI - math.PI / 2
	lon := (f64(i) + 0.5) / BAND_W * 2 * math.PI - math.PI
	return {math.cos(lat) * math.sin(lon), math.sin(lat), math.cos(lat) * math.cos(lon)}
}

@(private = "file")
band_index :: proc(dir: [3]f64) -> (i, j: int) {
	lon := math.atan2(dir.x, dir.z)
	lat := math.asin(clamp(dir.y, -1, 1))
	i = clamp(int((lon + math.PI) / (2 * math.PI) * BAND_W), 0, BAND_W - 1)
	j = clamp(int((lat + math.PI / 2) / math.PI * BAND_H), 0, BAND_H - 1)
	return
}

// Звёзды, видимые глазом.
@(private = "file")
build_catalog :: proc(u: ^Universe, sky: ^Star_Sky, gals: []Galaxy, rels: [][3]f64) {
	pos := sky.home.star.pos
	tmp := make([dynamic]Star)
	defer delete(tmp)
	for class in Star_Class {
		R := SKY_RADIUS[class]
		if R <= 0 do continue
		S := STAR_TIERS[class].cell
		ri := i64(math.ceil(R)) + 1
		lo: [3]Big
		n: [3]i64
		for k in 0 ..< 3 {
			lo[k], _ = big_floor_div(big_add_i(pos.cell[k], -ri), S)
			hi, _ := big_floor_div(big_add_i(pos.cell[k], ri), S)
			n[k], _ = big_to_i64(big_sub(hi, lo[k]))
			n[k] += 1
		}
		for z in 0 ..< n.z {
			if sync.atomic_load(&sky.cancel) do return
			for y in 0 ..< n.y do for x in 0 ..< n.x {
				c := [3]Big{big_add_i(lo[0], x), big_add_i(lo[1], y), big_add_i(lo[2], z)}
				corner := U_Pos{cell = {big_mul_i(c[0], S), big_mul_i(c[1], S), big_mul_i(c[2], S)}, off = {-LY / 2, -LY / 2, -LY / 2}}
				rel := upos_delta_ly(corner, pos)
				gap: [3]f64
				for k in 0 ..< 3 do gap[k] = max(0, rel[k], -(rel[k] + f64(S)))
				if len3(gap) > R do continue
				clear(&tmp)
				star_cell(u, class, c, gals, &tmp)
				for &s in tmp {
					sky.considered += 1
					if s.seed == sky.home.star.seed do continue
					v := upos_delta_ly(s.pos, pos)
					d := len3(v)
					if d > R || d <= 0 do continue
					m := star_abs_mag(&s) + 5 * math.log10(d / 3.2616) - 5
					if m > MAG_LIMIT do continue
					dir := v / d
					A := dust_along(gals, rels, dir, d)
					if m + A > MAG_LIMIT do continue
					// пыль краснит свет; глаз ночью различает цвета слабо — оттенки мягкие
					c3 := [3]f64{f64(s.color.r), f64(s.color.g), f64(s.color.b)}
					c3 *= [3]f64{math.pow(10, 0.1 * A), 1, math.pow(10, -0.12 * A)}
					c3 /= max(c3.r, c3.g, c3.b, 1e-6)
					c3 = [3]f64{1, 1, 1} * 0.5 + c3 * 0.5
					append(&sky.stars, Sky_Star {
						dir   = {f32(dir.x), f32(dir.y), f32(dir.z)},
						mag   = f32(m + A),
						color = {f32(c3.r), f32(c3.g), f32(c3.b)},
						phase = f32(s.seed % 10007) / 10007,
						seed  = s.seed,
						class = s.class,
						dist  = f32(d),
						dust  = f32(A),
					})
				}
			}
			free_all(context.temp_allocator)
		}
	}
	slice.sort_by(sky.stars[:], proc(a, b: Sky_Star) -> bool {return a.mag < b.mag})
}

// Свечение неба: вдоль каждого направления — свет звёзд галактики минус пыль.
@(private = "file")
build_band :: proc(sky: ^Star_Sky, gals: []Galaxy, rels: [][3]f64) {
	sky.band = make([]f32, BAND_W * BAND_H * 3)
	sky.tau = make([]f32, BAND_W * BAND_H)
	far := 0.0
	for g, i in gals do far = max(far, len3(rels[i]) + g.extent)
	OLD :: [3]f64{1.0, 0.86, 0.68}
	YOUNG :: [3]f64{0.75, 0.85, 1.0}
	K :: L_PER_STAR * LSUN_LY_LUX / (4 * math.PI) * BAND_CAL
	for j in 0 ..< BAND_H do for i in 0 ..< BAND_W {
		if i == 0 && sync.atomic_load(&sky.cancel) do return
		dir := band_dir(i, j)
		acc: [3]f64
		tau, s := 0.0, 0.0
		for s < far && tau < 30 {
			step := max(2.0, s * 0.05)
			mid := s + step / 2
			old, young, dust := 0.0, 0.0, 0.0
			for &g, k in gals {
				p := rels[k] + dir * mid
				o, y := galaxy_light(&g, p)
				old += o
				young += y
				dust += galaxy_dust(&g, p)
			}
			tm := tau + dust * step / 2
			att := [3]f64{math.pow(10, -0.3 * tm), math.pow(10, -0.4 * tm), math.pow(10, -0.52 * tm)}
			acc += (OLD * old + YOUNG * young) * att * step
			tau += dust * step
			s += step
		}
		k := j * BAND_W + i
		for c in 0 ..< 3 do sky.band[k * 3 + c] = f32(acc[c] * K)
		sky.tau[k] = f32(tau)
	}
}

// Соседние галактики: туманные пятна на карте свечения (их свет гасит и наша пыль).
@(private = "file")
build_neighbors :: proc(u: ^Universe, sky: ^Star_Sky, gals: []Galaxy) {
	pos := sky.home.star.pos
	list := make([dynamic]Galaxy)
	defer delete(list)
	galaxies_around(u, pos, GALAXY_VIEW_LY, &list)
	texel := 2 * math.PI / BAND_W
	outer: for &o in list {
		for g in gals do if g.seed == o.seed do continue outer
		v := upos_delta_ly(o.center, pos)
		d := len3(v)
		if d > GALAXY_VIEW_LY do continue
		dir := v / d
		ci, cj := band_index(dir)
		lux := o.stars * L_PER_STAR * LSUN_LY_LUX / (d * d) * math.pow(10, -0.4 * f64(sky.tau[cj * BAND_W + ci]))
		m := -2.5 * math.log10(lux / VEGA_LUX)
		if m > 9 do continue
		r_ang := galaxy_diameter(&o) / 2 / d
		sigma := max(r_ang / 2, 0.6 * texel)
		// размываем пятно по клеткам карты так, чтобы сумма осталась равна свету галактики
		span_j := int(math.ceil(3 * sigma / (math.PI / BAND_H))) + 1
		weights := make([dynamic]f64, context.temp_allocator)
		cells := make([dynamic][2]int, context.temp_allocator)
		total := 0.0
		for dj in -span_j ..= span_j {
			j := cj + dj
			if j < 0 || j >= BAND_H do continue
			lat := (f64(j) + 0.5) / BAND_H * math.PI - math.PI / 2
			span_i := min(int(math.ceil(3 * sigma / (texel * max(math.cos(lat), 0.05)))) + 1, BAND_W / 2)
			for di in -span_i ..= span_i {
				i := ((ci + di) % BAND_W + BAND_W) % BAND_W
				td := band_dir(i, j)
				ang := 2 * math.asin(clamp(len3(td - dir) / 2, 0, 1))
				w := math.exp(-ang * ang / (2 * sigma * sigma))
				if w < 1e-3 do continue
				omega := texel * (math.PI / BAND_H) * math.cos(lat)
				append(&weights, w)
				append(&cells, [2]int{i, j})
				total += w * omega
			}
		}
		col := [3]f64{0.95, 0.9, 0.85}
		for c, n in cells {
			k := c.y * BAND_W + c.x
			for ch in 0 ..< 3 do sky.band[k * 3 + ch] += f32(lux * weights[n] / total * col[ch])
		}
		if m <= MAG_LIMIT {
			append(&sky.galaxies, Sky_Galaxy{o.seed, o.kind, f32(m), f32(math.to_degrees(2 * r_ang)), f32(d)})
		}
		free_all(context.temp_allocator)
	}
	slice.sort_by(sky.galaxies[:], proc(a, b: Sky_Galaxy) -> bool {return a.mag < b.mag})
}

// Весь расчёт неба (в фоновом потоке или сразу — для отчёта -sky).
starsky_build :: proc(sky: ^Star_Sky) {
	t0 := time.now()
	u: Universe
	universe_init(&u, sky.world_seed)
	defer universe_destroy(&u)
	pos := sky.home.star.pos
	gals := make([dynamic]Galaxy)
	defer delete(gals)
	galaxies_around(&u, pos, SKY_RADIUS[.O], &gals)
	rels := make([][3]f64, len(gals))
	defer delete(rels)
	for g, i in gals {
		rels[i] = upos_delta_ly(pos, g.center)
		if g.seed == sky.home.galaxy.seed {
			sky.core_dist = len3(rels[i])
			sky.core_dir = -rels[i] / sky.core_dist
		}
	}
	build_catalog(&u, sky, gals[:], rels)
	if sync.atomic_load(&sky.cancel) do return
	build_band(sky, gals[:], rels)
	if sync.atomic_load(&sky.cancel) do return
	if sky.core_dist > 0 do sky.core_dust = dust_along(gals[:], rels, sky.core_dir, sky.core_dist)
	build_neighbors(&u, sky, gals[:])
	// направления для ночного света (равномерно по сфере)
	golden := math.PI * (3 - math.sqrt(f64(5)))
	for k in 0 ..< LIGHT_SAMPLES {
		y := 1 - (f64(k) + 0.5) / LIGHT_SAMPLES * 2
		r := math.sqrt(1 - y * y)
		a := golden * f64(k)
		dir := [3]f64{r * math.cos(a), y, r * math.sin(a)}
		i, j := band_index(dir)
		b := sky.band[(j * BAND_W + i) * 3:]
		sky.light_dir[k] = {f32(dir.x), f32(dir.y), f32(dir.z)}
		sky.light_lum[k] = 0.3 * b[0] + 0.59 * b[1] + 0.11 * b[2]
	}
	free_all(context.temp_allocator)
	sky.build_ms = time.duration_milliseconds(time.since(t0))
	sync.atomic_store(&sky.done, true)
}

// Запускает расчёт неба в фоне: пока он идёт, игра уже работает.
starsky_start :: proc(sky: ^Star_Sky, world_seed: u32, home: Home) {
	sky.world_seed = world_seed
	sky.home = home
	sky.worker = thread.create_and_start_with_data(sky, proc(data: rawptr) {
		starsky_build((^Star_Sky)(data))
	})
}

starsky_destroy :: proc(sky: ^Star_Sky) {
	if sky.worker != nil {
		sync.atomic_store(&sky.cancel, true)
		thread.join(sky.worker)
		thread.destroy(sky.worker)
	}
	delete(sky.stars)
	delete(sky.galaxies)
	delete(sky.band)
	delete(sky.tau)
}

// Ночной свет от неба (лк) при заданном повороте «вселенная -> кадр»:
// свечение воздуха, полоса галактики и звёзды над горизонтом.
starsky_night_lux :: proc(sky: ^Star_Sky, u2f: matrix[3, 3]f64) -> f64 {
	up := [3]f64{u2f[1, 0], u2f[1, 1], u2f[1, 2]} // зенит в осях вселенной
	e := AIRGLOW_LUX
	for k in 0 ..< LIGHT_SAMPLES {
		d := sky.light_dir[k]
		y := up.x * f64(d.x) + up.y * f64(d.y) + up.z * f64(d.z)
		if y > 0 do e += f64(sky.light_lum[k]) * y * (4 * math.PI / LIGHT_SAMPLES)
	}
	for &s in sky.stars {
		y := up.x * f64(s.dir.x) + up.y * f64(s.dir.y) + up.z * f64(s.dir.z)
		if y > 0 do e += VEGA_LUX * math.pow(10, -0.4 * f64(s.mag)) * y
	}
	return e
}

// Звезда у небесного полюса (pole — в осях вселенной): ярче 4-й величины, не дальше 4°.
starsky_pole_star :: proc(sky: ^Star_Sky, pole: [3]f64) -> (star: ^Sky_Star, angle: f64) {
	angle = 1e9
	for &s in sky.stars {
		if s.mag > 4 do break
		d := [3]f64{f64(s.dir.x), f64(s.dir.y), f64(s.dir.z)}
		a := math.to_degrees(2 * math.asin(clamp(len3(d - pole) / 2, 0, 1)))
		if a < 4 && a < angle do star, angle = &s, a
	}
	return
}

// ---------------------------------------------------------------- видеокарта

starsky_gl_init :: proc(sky: ^Star_Sky) -> bool {
	p := eng.shader_create("stars", STAR_VS, STAR_FS) or_return
	sky.prog = p
	sky.u_view_proj = eng.uniform_loc(p, "u_view_proj")
	sky.u_u2f = eng.uniform_loc(p, "u_u2f")
	sky.u_mlim = eng.uniform_loc(p, "u_mlim")
	sky.u_time = eng.uniform_loc(p, "u_time")
	sky.u_scale = eng.uniform_loc(p, "u_scale")
	sky.u_moon = eng.uniform_loc(p, "u_moon")
	make_vao :: proc(vao, vbo: ^u32) {
		gl.GenVertexArrays(1, vao)
		gl.GenBuffers(1, vbo)
		gl.BindVertexArray(vao^)
		gl.BindBuffer(gl.ARRAY_BUFFER, vbo^)
		gl.EnableVertexAttribArray(0)
		gl.VertexAttribPointer(0, 3, gl.FLOAT, false, size_of(Star_Vertex), offset_of(Star_Vertex, dir))
		gl.EnableVertexAttribArray(1)
		gl.VertexAttribPointer(1, 4, gl.FLOAT, false, size_of(Star_Vertex), offset_of(Star_Vertex, col))
		gl.EnableVertexAttribArray(2)
		gl.VertexAttribPointer(2, 1, gl.FLOAT, false, size_of(Star_Vertex), offset_of(Star_Vertex, phase))
		gl.BindVertexArray(0)
	}
	make_vao(&sky.vao, &sky.vbo)
	make_vao(&sky.pvao, &sky.pvbo)
	return true
}

// Когда фоновый расчёт закончен — загружает звёзды и карту свечения в видеокарту.
starsky_upload :: proc(sky: ^Star_Sky) {
	verts := make([]Star_Vertex, len(sky.stars), context.temp_allocator)
	for s, i in sky.stars do verts[i] = {s.dir, {s.color.r, s.color.g, s.color.b, s.mag}, s.phase}
	gl.BindBuffer(gl.ARRAY_BUFFER, sky.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(verts) * size_of(Star_Vertex), raw_data(verts), gl.STATIC_DRAW)
	sky.count = i32(len(verts))

	// свечение -> яркость на экране: Млечный Путь — BAND_DISP, ярче — с насыщением
	disp := make([]f32, len(sky.band), context.temp_allocator)
	for k in 0 ..< BAND_W * BAND_H {
		b := sky.band[k * 3:]
		lum := 0.3 * b[0] + 0.59 * b[1] + 0.11 * b[2]
		if lum <= 0 do continue
		v := min(BAND_DISP * math.pow(lum / BAND_REF, 0.6), 0.6)
		// ночью глаз почти не различает цвета: полоса видится серо-белой с лёгким оттенком
		for c in 0 ..< 3 do disp[k * 3 + c] = (0.7 + 0.3 * b[c] / lum) * v
	}
	gl.GenTextures(1, &sky.tex)
	gl.BindTexture(gl.TEXTURE_2D, sky.tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGB16F, BAND_W, BAND_H, 0, gl.RGB, gl.FLOAT, raw_data(disp))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	sky.ready = true
}

@(private = "file")
mat3_f32 :: proc(m: matrix[3, 3]f64) -> (r: matrix[3, 3]f32) {
	for i in 0 ..< 3 do for j in 0 ..< 3 do r[i, j] = f32(m[i, j])
	return
}

// Звёзды и планеты — точки поверх неба (рисовать сразу после неба, до земли).
starsky_draw :: proc(sky: ^Star_Sky, st: ^Sky_State, view_proj: eng.Mat4, time: f64, height: i32, anomaly: [4]f32) {
	if !sky.ready do return
	gl.UseProgram(sky.prog)
	eng.set_mat4(sky.u_view_proj, view_proj)
	eng.set_f32(sky.u_mlim, f32(st.mag_limit))
	eng.set_f32(sky.u_time, f32(time))
	eng.set_f32(sky.u_scale, max(1, f32(height) / 720))
	eng.set_vec4(eng.uniform_loc(sky.prog, "u_anomaly"), anomaly) // в тумане аномалии звёзд не видно
	moon: [MAX_MOONS][4]f32
	for i in 0 ..< st.moon_n do moon[i] = {st.moons[i].frame.x, st.moons[i].frame.y, st.moons[i].frame.z, f32(st.moons[i].ang_r)}
	gl.Uniform4fv(sky.u_moon, MAX_MOONS, &moon[0][0])
	gl.Enable(gl.PROGRAM_POINT_SIZE)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.ONE, gl.ONE)

	u2f := mat3_f32(st.uni_to_frame)
	gl.UniformMatrix3fv(sky.u_u2f, 1, false, &u2f[0, 0])
	gl.BindVertexArray(sky.vao)
	gl.DrawArrays(gl.POINTS, 0, sky.count)

	// планеты нашей системы: в инерциальных осях, не мерцают
	pv: [MAX_PLANETS]Star_Vertex
	for i in 0 ..< st.planet_n {
		p := &st.planets[i]
		pv[i] = {p.dir, {p.color.r, p.color.g, p.color.b, f32(p.mag)}, -1}
	}
	if st.planet_n > 0 {
		i2f := mat3_f32(st.inert_to_frame)
		gl.UniformMatrix3fv(sky.u_u2f, 1, false, &i2f[0, 0])
		gl.BindBuffer(gl.ARRAY_BUFFER, sky.pvbo)
		gl.BufferData(gl.ARRAY_BUFFER, st.planet_n * size_of(Star_Vertex), &pv[0], gl.DYNAMIC_DRAW)
		gl.BindVertexArray(sky.pvao)
		gl.DrawArrays(gl.POINTS, 0, i32(st.planet_n))
	}
	gl.BindVertexArray(0)
	gl.Disable(gl.BLEND)
	gl.Disable(gl.PROGRAM_POINT_SIZE)
}

// ---------------------------------------------------------------- отчёт -sky

starsky_report :: proc(sky: ^Star_Sky, a: ^Astro) {
	fmt.printfln("=== Звёздное небо (рассчитано за %.0f мс, перебрано звёзд: %d) ===", sky.build_ms, sky.considered)
	counts: [Star_Class]int
	brighter: [8]int // ярче 1, 2, ... 6 величины
	for s in sky.stars {
		counts[s.class] += 1
		for m in 0 ..< 8 {
			if f64(s.mag) <= f64(m) - 1 do brighter[m] += 1 // brighter[m] — ярче (m - 1)-й величины
		}
	}
	fmt.printfln("видно глазом (до %.1f величины, всё небо): %d звёзд", MAG_LIMIT, len(sky.stars))
	line := ""
	for c in Star_Class do if counts[c] > 0 do line = fmt.tprintf("%s%s %d; ", line, STAR_CLASS_NAMES[c], counts[c])
	fmt.printfln("  по типам: %s", line)
	fmt.printfln("  ярче 0 величины: %d, ярче 1: %d, ярче 2: %d, ярче 3: %d, ярче 4: %d, ярче 5: %d",
		brighter[1], brighter[2], brighter[3], brighter[4], brighter[5], brighter[6])
	fmt.printfln("пыль: в сторону центра галактики (%s) свет слабеет на %.1f звёздной величины", ly_text(sky.core_dist), sky.core_dust)
	fmt.println("самые яркие звёзды:")
	for s, i in sky.stars {
		if i >= 12 do break
		fmt.printfln("  %s %s %s %+.2f (пыль %.2f)", pad(star_name(s.seed, context.temp_allocator), 10), pad(STAR_CLASS_NAMES[s.class], 20),
			pad(ly_text(f64(s.dist)), 18), s.mag, s.dust)
	}
	for sign in ([2]f64{1, -1}) {
		pole := mat_t_mul(a.uni_to_inert, a.axis * sign)
		star, ang := starsky_pole_star(sky, pole)
		name := sign > 0 ? "северная" : "южная"
		if star != nil {
			fmt.printfln("%s полярная звезда: %s, %.1f° от полюса, %.2f величины", name, star_name(star.seed, context.temp_allocator), ang, star.mag)
		} else {
			fmt.printfln("%s полярной звезды нет", name)
		}
	}
	fmt.printfln("соседние галактики, видимые глазом: %d", len(sky.galaxies))
	for g in sky.galaxies {
		fmt.printfln("  %s %s %s %.1f величины, %.1f°", pad(galaxy_name(g.seed, context.temp_allocator), 12), pad(GALAXY_KIND_NAMES[g.kind], 25),
			pad(ly_text(f64(g.dist)), 18), g.mag, g.size)
	}
	peak, total := f32(0), 0.0
	for k in 0 ..< BAND_W * BAND_H {
		lum := 0.3 * sky.band[k * 3] + 0.59 * sky.band[k * 3 + 1] + 0.11 * sky.band[k * 3 + 2]
		peak = max(peak, lum)
		total += f64(lum)
	}
	fmt.printfln("свечение неба: в среднем %.2g лк/ср, ярчайшее место %.2g лк/ср (Млечный Путь ~%.0g)", total / (BAND_W * BAND_H), peak, BAND_REF)
}

// Транспонированная матрица на вектор (обратный поворот).
mat_t_mul :: proc(m: matrix[3, 3]f64, v: [3]f64) -> [3]f64 {
	return {m[0, 0] * v.x + m[1, 0] * v.y + m[2, 0] * v.z, m[0, 1] * v.x + m[1, 1] * v.y + m[2, 1] * v.z, m[0, 2] * v.x + m[1, 2] * v.y + m[2, 2] * v.z}
}
