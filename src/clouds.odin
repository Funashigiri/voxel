package main

// Облака на настоящей высоте: мягкие кучевые в слое на 1–2 км (у планет со
// слабой тяжестью атмосфера «выше» — и облака тоже), до своего горизонта
// (~140 км на планете размером с Землю). Слой изогнут вместе с планетой.
//
// Узор — шум в точке шара (оси планеты), один и тот же на видеокарте
// (CLOUD_GLSL) и здесь, на процессоре: облака отбрасывают тени на землю, и
// освещённость там, где стоишь, учитывает тень облака. Облака плывут по ветру,
// где-то ясно, где-то сплошная облачность, и картина медленно меняется.

import "core:math"
import eng "engine"
import gl "vendor:OpenGL"

CLOUD_SCALE :: 1800.0 // м на клетку основной октавы шума (размер облачных скоплений)
CLOUD_OCTAVES :: 5
CLOUD_RINGS :: 72 // купол: кольца от зенита к горизонту
CLOUD_SEGMENTS :: 128
CLOUD_WIND :: 8.0 // м/с — снос облаков ветром
CLOUD_SHADOW :: 0.55 // насколько темнее в тени плотного облака (прямой свет солнца закрыт)

Clouds :: struct {
	prog:        u32,
	u:           struct {
		view_proj, jinv, logk, e, geom, pcs: i32,
	},
	vao, vbo:    u32,
	ebo:         u32,
	index_count: i32,
	noise_tex:   u32, // 3D-текстура шума (NOISE_N³)
	height:      f64, // нижняя кромка над уровнем моря, м
	cover:       f64, // средняя облачность мира (0..1)
	offset:      [3]f64, // сдвиг узора этого мира (единицы шума)
	wind:        [3]f64, // ветер (оси планеты), м/с
	drift:       [3]f64, // накопленный снос узора, единицы шума
	last_time:   f64,
	time:        f64,
}

clouds_init :: proc(c: ^Clouds, seed: u32, gravity_g: f64) -> bool {
	p := eng.shader_create("clouds", CLOUD_VS, CLOUD_FS) or_return
	loc :: eng.uniform_loc
	c.prog = p
	c.u = {
		view_proj = loc(p, "u_view_proj"),
		jinv      = loc(p, "u_jinv"),
		logk      = loc(p, "u_logk"),
		e         = loc(p, "u_e"),
		geom      = loc(p, "u_geom"),
		pcs       = loc(p, "u_pcs"),
	}
	r := eng.rng_make(u64(seed) * 0x5DEECE66D + 77)
	c.height = clamp(1600 / max(gravity_g, 0.1), 800, 4000) * eng.rng_range(&r, 0.85, 1.15)
	c.cover = eng.rng_range(&r, 0.25, 0.7)
	c.offset = {eng.rng_range(&r, 0, 997), eng.rng_range(&r, 0, 997), eng.rng_range(&r, 0, 997)}
	w := [3]f64{eng.rng_range(&r, -1, 1), eng.rng_range(&r, -1, 1), eng.rng_range(&r, -1, 1)}
	c.wind = w / max(len3(w), 1e-6) * CLOUD_WIND * eng.rng_range(&r, 0.6, 1.4)

	noise_build()
	gl.GenTextures(1, &c.noise_tex)
	gl.BindTexture(gl.TEXTURE_3D, c.noise_tex)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage3D(gl.TEXTURE_3D, 0, gl.R8, NOISE_N, NOISE_N, NOISE_N, 0, gl.RED, gl.UNSIGNED_BYTE, raw_data(noise_table))
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_3D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	for wrap in ([3]u32{gl.TEXTURE_WRAP_S, gl.TEXTURE_WRAP_T, gl.TEXTURE_WRAP_R}) do gl.TexParameteri(gl.TEXTURE_3D, wrap, gl.REPEAT)
	gl.BindTexture(gl.TEXTURE_3D, 0)

	// купол: (доля пути к краю, азимут) — форму считает шейдер
	verts := make([dynamic][2]f32, context.temp_allocator)
	for i in 0 ..= CLOUD_RINGS do for s in 0 ..= CLOUD_SEGMENTS {
		append(&verts, [2]f32{f32(i) / CLOUD_RINGS, f32(s) / CLOUD_SEGMENTS * math.TAU})
	}
	indices := make([dynamic]u32, context.temp_allocator)
	W :: CLOUD_SEGMENTS + 1
	for i in 0 ..< CLOUD_RINGS do for s in 0 ..< CLOUD_SEGMENTS {
		a := u32(i * W + s)
		append(&indices, a, a + W, a + W + 1, a, a + W + 1, a + 1)
	}
	c.index_count = i32(len(indices))
	gl.GenVertexArrays(1, &c.vao)
	gl.GenBuffers(1, &c.vbo)
	gl.GenBuffers(1, &c.ebo)
	gl.BindVertexArray(c.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, c.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(verts) * size_of([2]f32), raw_data(verts), gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, size_of([2]f32), 0)
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, c.ebo)
	gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, len(indices) * size_of(u32), raw_data(indices), gl.STATIC_DRAW)
	gl.BindVertexArray(0)
	return true
}

// Ветер сносит узор (время — настоящее: облака — часть местной погоды).
clouds_tick :: proc(c: ^Clouds, time: f64) {
	dt := clamp(time - c.last_time, 0, 0.25)
	c.last_time = time
	c.time += dt
	c.drift += c.wind * dt / CLOUD_SCALE
}

// Точка шара (оси планеты, м) -> координаты шума облаков.
cloud_q :: proc(c: ^Clouds, p: [3]f64) -> [3]f64 {
	return p / CLOUD_SCALE + c.offset + c.drift
}

// ---- шум облаков: value noise по решётке с периодом NOISE_N. Значения в узлах —
// одна и та же таблица байтов здесь и в 3D-текстуре видеокарты (там
// интерполяцию делает сама текстура — дёшево), поэтому тени и освещённость
// на процессоре совпадают с картинкой.

NOISE_N :: 128

@(private = "file")
noise_table: []u8

@(private = "file")
noise_build :: proc() {
	noise_table = make([]u8, NOISE_N * NOISE_N * NOISE_N)
	for z in 0 ..< NOISE_N do for y in 0 ..< NOISE_N do for x in 0 ..< NOISE_N {
		h := (u32(x) * 0x8da6b343) ~ (u32(y) * 0xd8163841) ~ (u32(z) * 0xcb1ab31f)
		h ~= h >> 16
		h *= 0x7feb352d
		h ~= h >> 15
		h *= 0x846ca68b
		h ~= h >> 16
		noise_table[(z * NOISE_N + y) * NOISE_N + x] = u8(h >> 24)
	}
}

@(private = "file")
cloud_value :: #force_inline proc "contextless" (x, y, z: i32) -> f64 {
	M :: NOISE_N - 1
	return f64(noise_table[((z & M) * NOISE_N + (y & M)) * NOISE_N + (x & M)]) / 255
}

@(private = "file")
cloud_vnoise :: proc "contextless" (p: [3]f64) -> f64 {
	fl := [3]f64{math.floor(p.x), math.floor(p.y), math.floor(p.z)}
	x, y, z := i32(fl.x), i32(fl.y), i32(fl.z)
	f := p - fl
	u := f * f * (3 - 2 * f)
	lerp :: proc "contextless" (a, b, t: f64) -> f64 {return a + (b - a) * t}
	a := lerp(cloud_value(x, y, z), cloud_value(x + 1, y, z), u.x)
	b := lerp(cloud_value(x, y + 1, z), cloud_value(x + 1, y + 1, z), u.x)
	cc := lerp(cloud_value(x, y, z + 1), cloud_value(x + 1, y, z + 1), u.x)
	d := lerp(cloud_value(x, y + 1, z + 1), cloud_value(x + 1, y + 1, z + 1), u.x)
	return lerp(lerp(a, b, u.y), lerp(cc, d, u.y), u.z)
}

// Плотность облака 0..1 в точке шума q (как cloud_density в CLOUD_GLSL);
// октавы дальше octaves — средним значением.
cloud_density :: proc(c: ^Clouds, q: [3]f64, octaves := CLOUD_OCTAVES) -> f64 {
	sum, amp, f := 0.0, 0.5, 1.0
	for i in 0 ..< CLOUD_OCTAVES {
		sum += amp * (i < octaves ? cloud_vnoise(q * f + f64(i) * 17.31) : 0.5)
		amp *= 0.5
		f *= 2
	}
	n := sum / 0.96875
	// облачность меняется от места к месту (скопления ~70 км) и медленно во времени
	cov := c.cover + 0.45 * (cloud_vnoise(q / 40 + {0, c.time / 1800, 0}) - 0.5) * 2
	thr := 0.5 + 0.2 * (0.5 - cov) * 2
	t := clamp((n - thr) / 0.14, 0, 1)
	return t * t * (3 - 2 * t)
}

// Непрозрачность облака (как в шейдере облаков).
cloud_alpha :: proc(d: f64) -> f64 {
	return 1 - math.exp(-d * 3.5)
}

// Во сколько раз темнее от тени облака в точке p (оси планеты, м; h — её высота
// над уровнем моря) при солнце в направлении sun (как cloud_shadow в шейдерах).
cloud_shadow_at :: proc(c: ^Clouds, p, up, sun: [3]f64, h: f64) -> f64 {
	sy := sun.x * up.x + sun.y * up.y + sun.z * up.z
	if sy <= 0 || h > c.height do return 1 // выше облаков — тени нет
	t := (c.height - h) / max(sy, 0.05) // до слоя облаков по лучу к солнцу
	a := cloud_alpha(cloud_density(c, cloud_q(c, p + sun * t), 3)) * smooth01(sy / 0.1)
	return 1 - CLOUD_SHADOW * a
}

@(private = "file")
smooth01 :: proc(x: f64) -> f64 {
	t := clamp(x, 0, 1)
	return t * t * (3 - 2 * t)
}

// ---- отрисовка

// Купол облаков вокруг камеры (в дальнем проходе, после рельефа). Камера
// под облаками — купол над ней до горизонта облаков; над облаками (высокая
// гора) — море облаков внизу, до их горизонта.
clouds_draw :: proc(c: ^Clouds, pv: ^Planet_View, view_proj: eng.Mat4) {
	R := pv.radius
	rc := R + pv.cam_h
	Rc := R + c.height
	above := Rc - rc // облака над камерой, м (меньше нуля — под ней)
	if abs(above) < 20 do return // внутри слоя
	s_max := above > 0 ? math.sqrt(max(rc * rc - R * R, 0)) + math.sqrt(Rc * Rc - R * R) : math.sqrt(rc * rc - Rc * Rc)
	gl.UseProgram(c.prog)
	eng.set_mat4(c.u.view_proj, view_proj)
	jinv: matrix[3, 3]f32
	for r in 0 ..< 3 do for k in 0 ..< 3 do jinv[r, k] = f32(pv.jinv[r, k])
	gl.UniformMatrix3fv(c.u.jinv, 1, false, &jinv[0, 0])
	e: matrix[3, 3]f32 // местные оси камеры (касательные t1, t2 и вертикаль) -> оси планеты
	for r in 0 ..< 3 {
		e[r, 0] = f32(pv.t1[r])
		e[r, 1] = f32(pv.up[r])
		e[r, 2] = f32(pv.t2[r])
	}
	gl.UniformMatrix3fv(c.u.e, 1, false, &e[0, 0])
	eng.set_f32(c.u.logk, f32(2 / math.log2(FAR_LOG_FAR + 1)))
	theta_max := math.atan2(s_max, abs(above))
	eng.set_vec4(c.u.geom, {f32(above), f32(Rc), f32(theta_max), above > 0 ? 0 : 1})
	q := cloud_q(c, pv.pc)
	eng.set_vec3(c.u.pcs, {f32(q.x), f32(q.y), f32(q.z)})
	gl.BindVertexArray(c.vao)
	gl.DrawElements(gl.TRIANGLES, c.index_count, gl.UNSIGNED_INT, nil)
	gl.BindVertexArray(0)
}

// Uniform-ы облаков для любого шейдера с CLOUD_GLSL (тени на земле, сами облака).
clouds_uniforms :: proc(c: ^Clouds, prog: u32, pv: ^Planet_View) {
	q := cloud_q(c, pv.pc)
	eng.set_vec3(eng.uniform_loc(prog, "u_cloud_q0"), {f32(q.x), f32(q.y), f32(q.z)})
	jq: matrix[3, 3]f32 // кадр -> единицы шума
	for r in 0 ..< 3 do for k in 0 ..< 3 do jq[r, k] = f32(pv.j[r, k] / CLOUD_SCALE)
	gl.UniformMatrix3fv(eng.uniform_loc(prog, "u_cloud_jq"), 1, false, &jq[0, 0])
	eng.set_vec4(eng.uniform_loc(prog, "u_cloud"), {f32(c.cover), f32(c.time / 1800), f32(c.height), 1})
}
