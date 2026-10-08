package main

// Чёрная дыра (схлопывание капсулы), как это обычно делают в играх:
//  1) гравитационная линза — картинка вокруг дыры искажается (берём копию
//     кадра и читаем её со смещением, как точечная линза: β = θ - θE²/θ);
//  2) горизонт событий — чёрное ядро;
//  3) фотонное кольцо — светящийся ободок;
//  4) вещество закручивается и втягивается (частицы + сжатие модели в шейдере).
// Линза рисуется билбордом с проверкой глубины, поэтому то, что стоит
// перед дырой (персонаж), не искажается.

import "core:math/linalg"
import eng "engine"
import gl "vendor:OpenGL"

Black_Hole :: struct {
	center:   [3]f64,
	radius:   f32, // радиус линзы в блоках
	horizon:  f32, // радиус горизонта, доля от radius
	strength: f32, // 0..1
}

@(private = "file")
LENS_VS :: `#version 330 core
layout(location = 0) in vec2 a_local;
uniform mat4 u_view_proj;
uniform vec3 u_center;
uniform vec3 u_right;
uniform vec3 u_up;
out vec2 v_local;
void main() {
	v_local = a_local;
	gl_Position = u_view_proj * vec4(u_center + u_right * a_local.x + u_up * a_local.y, 1.0);
}
`

@(private = "file")
LENS_FS :: `#version 330 core
in vec2 v_local;
uniform sampler2D u_scene;
uniform vec2 u_center_uv;
uniform vec2 u_axis_u;
uniform vec2 u_axis_v;
uniform float u_horizon;
uniform float u_strength;
out vec4 o_color;
void main() {
	float r = length(v_local);
	if (r > 1.0) discard;
	float rh = u_horizon;
	float te = rh * 1.7; // радиус кольца Эйнштейна
	vec2 lensed = v_local * (1.0 - te * te / max(r * r, 1e-4));
	float edge = 1.0 - smoothstep(0.45, 1.0, r);
	vec2 src = mix(v_local, lensed, edge * u_strength);
	vec3 col = texture(u_scene, u_center_uv + u_axis_u * src.x + u_axis_v * src.y).rgb;
	float ring = exp(-pow((r - te * 0.92) / (0.16 * te + 0.004), 2.0));
	col += vec3(1.0, 0.82, 0.55) * ring * 1.2 * u_strength;
	col = mix(col, vec3(0.0), 1.0 - smoothstep(rh * 0.9, rh, r));
	o_color = vec4(col, 1.0);
}
`

Lens_Renderer :: struct {
	prog:                                        u32,
	u_view_proj, u_center, u_right, u_up:        i32,
	u_scene, u_center_uv, u_axis_u, u_axis_v:    i32,
	u_horizon, u_strength:                       i32,
	vao, vbo:                                    u32,
	scene_tex:                                   u32,
	tex_w, tex_h:                                i32,
}

lens_init :: proc(l: ^Lens_Renderer) -> bool {
	p := eng.shader_create("black_hole", LENS_VS, LENS_FS) or_return
	loc :: eng.uniform_loc
	l.prog = p
	l.u_view_proj = loc(p, "u_view_proj")
	l.u_center = loc(p, "u_center")
	l.u_right = loc(p, "u_right")
	l.u_up = loc(p, "u_up")
	l.u_scene = loc(p, "u_scene")
	l.u_center_uv = loc(p, "u_center_uv")
	l.u_axis_u = loc(p, "u_axis_u")
	l.u_axis_v = loc(p, "u_axis_v")
	l.u_horizon = loc(p, "u_horizon")
	l.u_strength = loc(p, "u_strength")

	quad := [6][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, -1}, {1, 1}, {-1, 1}}
	gl.GenVertexArrays(1, &l.vao)
	gl.GenBuffers(1, &l.vbo)
	gl.BindVertexArray(l.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, l.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(quad), &quad, gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, size_of([2]f32), 0)
	gl.BindVertexArray(0)
	gl.GenTextures(1, &l.scene_tex)
	return true
}

@(private = "file")
to_uv :: proc(view_proj: eng.Mat4, p: [3]f32) -> [2]f32 {
	c := view_proj * [4]f32{p.x, p.y, p.z, 1}
	return {c.x / c.w * 0.5 + 0.5, c.y / c.w * 0.5 + 0.5}
}

// Рисует чёрные дыры поверх уже отрисованной сцены.
lens_draw :: proc(l: ^Lens_Renderer, holes: []Black_Hole, cam: ^Camera, width, height: i32) {
	if len(holes) == 0 do return

	// копия кадра, из которой линза берёт искажённую картинку
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, l.scene_tex)
	if l.tex_w != width || l.tex_h != height {
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGB8, width, height, 0, gl.RGB, gl.UNSIGNED_BYTE, nil)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		l.tex_w, l.tex_h = width, height
	}
	gl.CopyTexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 0, 0, width, height)

	right := [3]f32{cam.view[0, 0], cam.view[0, 1], cam.view[0, 2]}
	up := [3]f32{cam.view[1, 0], cam.view[1, 1], cam.view[1, 2]}
	back := [3]f32{cam.view[2, 0], cam.view[2, 1], cam.view[2, 2]} // к камере

	gl.UseProgram(l.prog)
	eng.set_mat4(l.u_view_proj, cam.view_proj)
	eng.set_i32(l.u_scene, 0)
	gl.BindVertexArray(l.vao)
	gl.Enable(gl.DEPTH_TEST)
	gl.DepthMask(false)
	gl.Disable(gl.BLEND)
	gl.Disable(gl.CULL_FACE)
	for h in holes {
		if h.strength <= 0.001 do continue
		c := [3]f32{f32(h.center.x - cam.pos.x), f32(h.center.y - cam.pos.y), f32(h.center.z - cam.pos.z)}
		// билборд чуть ближе к камере, чтобы исказилась и сама капсула
		dist := linalg.length(c)
		c += back * min(1.2, dist * 0.5)
		r := right * h.radius
		u := up * h.radius
		cuv := to_uv(cam.view_proj, c)
		eng.set_vec3(l.u_center, c)
		eng.set_vec3(l.u_right, r)
		eng.set_vec3(l.u_up, u)
		eng.set_vec2(l.u_center_uv, cuv)
		eng.set_vec2(l.u_axis_u, to_uv(cam.view_proj, c + r) - cuv)
		eng.set_vec2(l.u_axis_v, to_uv(cam.view_proj, c + u) - cuv)
		eng.set_f32(l.u_horizon, h.horizon)
		eng.set_f32(l.u_strength, h.strength)
		gl.DrawArrays(gl.TRIANGLES, 0, 6)
	}
	gl.DepthMask(true)
	gl.Enable(gl.CULL_FACE)
}
