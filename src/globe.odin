package main

// Маленький глобус планеты для панели F3 — первый шаг к виду из космоса.
// Строится по тому же генератору, что и мир: океаны, материки, горные пояса,
// полярные шапки. Повёрнут так, чтобы точка, где стоит игрок, была спереди.

import "core:math"
import "core:math/linalg"
import eng "engine"
import gl "vendor:OpenGL"

@(private = "file")
GLOBE_GRID :: 32 // клеток на ребро грани куба

@(private = "file")
GLOBE_VS :: `#version 330 core
layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec3 a_color;
uniform mat4 u_mvp;
uniform mat4 u_model;
out vec3 v_color;
out vec3 v_n;
void main() {
	v_color = a_color;
	v_n = mat3(u_model) * a_pos;
	gl_Position = u_mvp * vec4(a_pos, 1.0);
}
`

@(private = "file")
GLOBE_FS :: `#version 330 core
in vec3 v_color;
in vec3 v_n;
uniform vec3 u_light;
out vec4 o_color;
void main() {
	vec3 n = normalize(v_n);
	float d = smoothstep(-0.08, 0.3, dot(n, u_light)); // мягкая граница дня и ночи
	vec3 col = v_color * (0.04 + 0.96 * d);
	float rim = pow(1.0 - max(n.z, 0.0), 3.0); // атмосфера по краю диска
	col += vec3(0.35, 0.55, 1.0) * rim * (0.05 + 0.7 * d);
	o_color = vec4(col, 1.0);
}
`

@(private = "file")
Globe_Vertex :: struct {
	pos:   [3]f32,
	color: [3]f32,
}

Globe :: struct {
	prog:                    u32,
	u_mvp, u_model, u_light: i32,
	vao, vbo:                u32,
	count:                   i32,
}

@(private = "file")
mix3 :: proc(a, b: [3]f32, t: f32) -> [3]f32 {return a + (b - a) * clamp(t, 0, 1)}

// Цвет точки планеты по крупному рельефу (мелкий рельеф с орбиты не виден).
@(private = "file")
globe_color :: proc(seed: i64, g: ^Planet_Geo, dir: [3]f64) -> [3]f32 {
	alt := f32(elevation(seed, dir * g.radius, 150_000))
	lat := abs(math.to_degrees(math.asin(clamp(dir.y, -1, 1))))
	wobble := f32(math.sin(dir.x * 9 + dir.z * 5) * 3)
	if f32(lat) > 68 + wobble do return {0.9, 0.94, 1.0} // полярная шапка
	if alt < 0 {
		// мелководье светлее, глубины — тёмно-синие
		return mix3({0.22, 0.5, 0.8}, {0.04, 0.12, 0.36}, -alt / 4000)
	}
	if alt < 40 do return {0.72, 0.7, 0.5}
	green := mix3({0.36, 0.58, 0.24}, {0.2, 0.4, 0.15}, f32(lat) / 60)
	c := mix3(green, {0.5, 0.46, 0.42}, (alt - 800) / 1800) // горы — серо-коричневые
	return mix3(c, {0.66, 0.64, 0.62}, (alt - 3000) / 2000) // высокие — светлее
}

globe_create :: proc(g: ^Planet_Geo, seed: u32) -> (gl_: Globe, ok: bool) {
	p := eng.shader_create("globe", GLOBE_VS, GLOBE_FS) or_return
	gl_.prog = p
	gl_.u_mvp = eng.uniform_loc(p, "u_mvp")
	gl_.u_model = eng.uniform_loc(p, "u_model")
	gl_.u_light = eng.uniform_loc(p, "u_light")

	G :: GLOBE_GRID
	s := i64(seed)
	verts := make([dynamic]Globe_Vertex, 0, 6 * G * G * 6, context.temp_allocator)
	grid: [(G + 1) * (G + 1)]Globe_Vertex
	for face in Cube_Face {
		for j in 0 ..= G do for i in 0 ..= G {
			d := geo_dir(g, face, f64(i) / G * f64(g.n), f64(j) / G * f64(g.n))
			grid[j * (G + 1) + i] = {{f32(d.x), f32(d.y), f32(d.z)}, globe_color(s, g, d)}
		}
		for j in 0 ..< G do for i in 0 ..< G {
			a := grid[j * (G + 1) + i]
			b := grid[j * (G + 1) + i + 1]
			c := grid[(j + 1) * (G + 1) + i + 1]
			d := grid[(j + 1) * (G + 1) + i]
			append(&verts, a, d, c, a, c, b) // наружу против часовой
		}
	}
	gl_.count = i32(len(verts))
	gl.GenVertexArrays(1, &gl_.vao)
	gl.GenBuffers(1, &gl_.vbo)
	gl.BindVertexArray(gl_.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, gl_.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(verts) * size_of(Globe_Vertex), raw_data(verts), gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, size_of(Globe_Vertex), offset_of(Globe_Vertex, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 3, gl.FLOAT, false, size_of(Globe_Vertex), offset_of(Globe_Vertex, color))
	gl.BindVertexArray(0)
	return gl_, true
}

// Как глобус лежит на экране — для отметок поверх него.
Globe_View :: struct {
	mvp, model:  matrix[4, 4]f32,
	x, y, size: f32,
}

// Рисует глобус в квадрате (x, y — левый верхний угол в пикселях, size — сторона),
// повёрнутый к игроку; освещён настоящим солнцем (sun — в осях планеты).
globe_draw :: proc(gb: ^Globe, player_dir, sun: [3]f64, time: f64, x, y, size: f32, screen_h: i32) -> Globe_View {
	lat := f32(math.asin(clamp(player_dir.y, -1, 1)))
	lon := f32(math.atan2(player_dir.x, player_dir.z))
	sway := f32(math.sin(time * 0.35)) * 0.35
	model := linalg.matrix4_rotate_f32(0.3, {1, 0, 0}) * linalg.matrix4_rotate_f32(lat, {1, 0, 0}) * linalg.matrix4_rotate_f32(-lon + sway, {0, 1, 0})
	view := linalg.matrix4_translate_f32({0, 0, -3.3})
	proj := linalg.matrix4_perspective_f32(math.to_radians(f32(38)), 1, 0.1, 10)
	mvp := proj * view * model

	vx := i32(x)
	vy := screen_h - i32(y + size)
	vs := i32(size)
	gl.Viewport(vx, vy, vs, vs)
	gl.Enable(gl.SCISSOR_TEST)
	gl.Scissor(vx, vy, vs, vs)
	gl.Clear(gl.DEPTH_BUFFER_BIT)
	gl.Enable(gl.DEPTH_TEST)
	gl.DepthMask(true)
	gl.Disable(gl.BLEND)
	gl.Enable(gl.CULL_FACE)
	gl.UseProgram(gb.prog)
	eng.set_mat4(gb.u_mvp, mvp)
	eng.set_mat4(gb.u_model, model)
	light := model * [4]f32{f32(sun.x), f32(sun.y), f32(sun.z), 0}
	eng.set_vec3(gb.u_light, linalg.normalize(light.xyz))
	gl.BindVertexArray(gb.vao)
	gl.DrawArrays(gl.TRIANGLES, 0, gb.count)
	gl.Disable(gl.SCISSOR_TEST)
	gl.Disable(gl.DEPTH_TEST)

	return {mvp, model, x, y, size}
}

// Экранная позиция точки чуть над поверхностью глобуса и видна ли она (не с обратной стороны).
globe_project :: proc(v: Globe_View, dir: [3]f64) -> (pos: [2]f32, facing: bool) {
	pd := [4]f32{f32(dir.x) * 1.02, f32(dir.y) * 1.02, f32(dir.z) * 1.02, 1}
	c := v.mvp * pd
	ndc := [2]f32{c.x / c.w, c.y / c.w}
	facing = (v.model * [4]f32{pd.x, pd.y, pd.z, 0}).z > 0
	return {v.x + (ndc.x * 0.5 + 0.5) * v.size, v.y + (1 - (ndc.y * 0.5 + 0.5)) * v.size}, facing
}
