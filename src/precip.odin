package main

// Дождь и снег вокруг камеры (0.017). Капли и хлопья — в «бесконечном ящике»:
// у каждой своё место в ящике 32×24×32 м, ящик повторяется во все стороны, и
// весь узор сдвигается на путь, что прошли осадки (скорость падения + ветер).
// Поэтому капли привязаны к миру, а не к камере, и падают бесконечно. Сколько
// их видно — по силе осадков (показаны крупные, заметные глазу; мелкая морось
// видна мглой — дымкой в шейдерах). Под кронами и крышами не капает: капля
// ниже карты света неба (World.sky) не рисуется.
//
// Скорость падения — установившаяся: капли 1–2 мм — 4–6,5 м/с (Ганн и
// Кинцер), сильный ливень — крупнее и быстрее; снег ~1 м/с, мокрый — ~2 м/с.
// В плотном воздухе медленнее, в разреженном — быстрее (∝ 1/√ρ).

import "core:math"
import eng "engine"

PRECIP_MAX :: 12000
PRECIP_BOX := [3]f64{32, 24, 32}

Precip :: struct {
	base:  [PRECIP_MAX][3]f32, // место в ящике, 0..1
	seed:  [PRECIP_MAX]f32, // своя фаза (кружение хлопьев, длина капли)
	shift: [3]f64, // путь, что прошли осадки, м (кадр)
	rho_k: f64, // поправка скорости падения на плотность воздуха
}

precip_init :: proc(pr: ^Precip, seed: u32, rho: f64) {
	r := eng.rng_make(u64(seed) ~ 0x5EED_0017)
	for i in 0 ..< PRECIP_MAX {
		pr.base[i] = {f32(eng.rng_f64(&r)), f32(eng.rng_f64(&r)), f32(eng.rng_f64(&r))}
		pr.seed[i] = f32(eng.rng_f64(&r))
	}
	pr.rho_k = clamp(math.sqrt(1.2 / max(rho, 0.05)), 0.4, 3)
}

// Скорость падения, м/с: дождь — по силе (крупнее капли), снег, мокрый снег.
precip_fall_speed :: proc(rain, snow, rho_k: f64) -> f64 {
	v_rain := clamp(4.5 + 1.2 * math.log10(max(rain, 0.1)) * 1.5, 3, 9)
	return math.lerp(v_rain, 1.0, snow) * rho_k
}

// Сдвиг узора за кадр: падение и снос ветром (wind — ветер в осях кадра, м/с).
precip_tick :: proc(pr: ^Precip, wind: [3]f64, rain, snow, dt: f64) {
	v := precip_fall_speed(rain, snow, pr.rho_k)
	pr.shift += ([3]f64{wind.x, -v, wind.z}) * dt
	for k in 0 ..< 3 do pr.shift[k] = math.mod(pr.shift[k], PRECIP_BOX[k] * 64)
}

// Рисует осадки (вызывать с включённым смешиванием, без записи глубины).
// light — освещение мира; rain — мм/ч; snow — доля снега.
precip_draw :: proc(pr: ^Precip, w: ^World, cam: ^Camera, wind: [3]f64, rain, snow: f64, light: [3]f32, time: f64) {
	if rain < 0.02 do return
	// частиц в воздухе ∝ сила / скорость падения: хлопья падают медленнее — их больше
	n := int(clamp(2600 * math.sqrt(rain) * (1 + 2 * snow) / math.sqrt(precip_fall_speed(rain, snow, pr.rho_k) / pr.rho_k), 0, PRECIP_MAX))
	v := precip_fall_speed(rain, snow, pr.rho_k)
	vel := [3]f64{wind.x, -v, wind.z}
	speed := math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
	dir := vel / speed
	right := [3]f32{cam.view[0, 0], cam.view[0, 1], cam.view[0, 2]}
	up := [3]f32{cam.view[1, 0], cam.view[1, 1], cam.view[1, 2]}
	fwd := -[3]f32{cam.view[2, 0], cam.view[2, 1], cam.view[2, 2]}
	// цвет: капли — светлые на тёмном, хлопья — белые; ночью темнее
	lc := [3]f32{min(light.r, 1), min(light.g, 1), min(light.b, 1)}
	rain_c := [4]u8{u8(200 * lc.r), u8(208 * lc.g), u8(222 * lc.b), 105}
	snow_c := [4]u8{u8(245 * lc.r), u8(248 * lc.g), u8(255 * lc.b), 220}
	B := PRECIP_BOX
	o := cam.pos - B / 2 // угол ящика вокруг камеры
	sky_col: ^Column
	sky_key: Column_Key
	for i in 0 ..< n {
		b := pr.base[i]
		p: [3]f64
		for k in 0 ..< 3 {
			x := f64(b[k]) * B[k] + pr.shift[k] - o[k]
			p[k] = o[k] + x - math.floor(x / B[k]) * B[k]
		}
		is_snow := f64(pr.seed[i]) < snow
		if is_snow {
			// хлопья кружатся
			ph := f64(pr.seed[i]) * 40 + time * (1.3 + f64(pr.seed[i]))
			p.x += 0.35 * math.sin(ph)
			p.z += 0.35 * math.cos(ph * 0.8)
		}
		// под крышей и кроной не видно
		face, gx, gz, ok := world_resolve(w, i32(math.floor(p.x)), i32(math.floor(p.z)))
		if !ok do continue
		key := column_key_of(face, gx, gz)
		if sky_col == nil || key != sky_key {
			sky_col = world_column(w, key)
			sky_key = key
		}
		if sky_col == nil || p.y < f64(sky_col.sky[column_index(gx, gz)]) do continue
		c := [3]f32{f32(p.x - cam.pos.x), f32(p.y - cam.pos.y), f32(p.z - cam.pos.z)}
		if c.x * fwd.x + c.y * fwd.y + c.z * fwd.z < 0.3 do continue // за спиной
		if is_snow {
			s := f32(0.018 + 0.016 * f64(pr.seed[i]))
			eng.imm_quad(c - right * s - up * s, c + right * s - up * s, c + right * s + up * s, c - right * s + up * s, snow_c)
		} else {
			// капля — черта вдоль пути за ~1/20 с (так глаз видит падающую каплю)
			l := f32(speed * (0.05 + 0.04 * f64(pr.seed[i])))
			a := [3]f32{f32(dir.x), f32(dir.y), f32(dir.z)} * l
			// ширина — поперёк черты и луча зрения
			side := [3]f32{a.y * c.z - a.z * c.y, a.z * c.x - a.x * c.z, a.x * c.y - a.y * c.x}
			sl := math.sqrt(side.x * side.x + side.y * side.y + side.z * side.z)
			if sl < 1e-5 do continue
			side *= 0.011 / sl
			eng.imm_quad(c - side, c + side, c + side + a, c - side + a, rain_c)
		}
	}
	eng.imm_flush(cam.view_proj)
}
