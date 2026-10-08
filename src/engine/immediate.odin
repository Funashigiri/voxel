package engine

// Immediate-режим: набираем цветные треугольники за кадр и рисуем одним
// вызовом. Для интерфейса, меток и значков.

import gl "vendor:OpenGL"

Imm_Vertex :: struct {
	pos:   [3]f32,
	color: [4]u8,
}

@(private = "file")
IMM_VS :: `#version 330 core
layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec4 a_color;
uniform mat4 u_mvp;
out vec4 v_color;
void main() {
	v_color = a_color;
	gl_Position = u_mvp * vec4(a_pos, 1.0);
}
`

@(private = "file")
IMM_FS :: `#version 330 core
in vec4 v_color;
out vec4 o_color;
void main() {
	o_color = v_color;
}
`

@(private = "file")
Imm :: struct {
	prog:     u32,
	u_mvp:    i32,
	vao, vbo: u32,
	verts:    [dynamic]Imm_Vertex,
}

@(private = "file")
imm: Imm

imm_init :: proc() -> bool {
	imm.prog = shader_create("immediate", IMM_VS, IMM_FS) or_return
	imm.u_mvp = uniform_loc(imm.prog, "u_mvp")
	gl.GenVertexArrays(1, &imm.vao)
	gl.GenBuffers(1, &imm.vbo)
	gl.BindVertexArray(imm.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, imm.vbo)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, size_of(Imm_Vertex), offset_of(Imm_Vertex, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 4, gl.UNSIGNED_BYTE, true, size_of(Imm_Vertex), offset_of(Imm_Vertex, color))
	gl.BindVertexArray(0)
	return true
}

// Четырёхугольник a-b-c-d.
imm_quad :: proc(a, b, c, d: Vec3, color: [4]u8) {
	append(&imm.verts,
		Imm_Vertex{a, color}, Imm_Vertex{b, color}, Imm_Vertex{c, color},
		Imm_Vertex{a, color}, Imm_Vertex{c, color}, Imm_Vertex{d, color},
	)
}

// Прямоугольник на плоскости z = 0 (для интерфейса в пикселях).
imm_rect :: proc(x0, y0, x1, y1: f32, color: [4]u8) {
	imm_quad({x0, y0, 0}, {x1, y0, 0}, {x1, y1, 0}, {x0, y1, 0}, color)
}

// Рисует всё набранное с матрицей mvp и очищает буфер.
imm_flush :: proc(mvp: Mat4) {
	if len(imm.verts) == 0 do return
	gl.UseProgram(imm.prog)
	set_mat4(imm.u_mvp, mvp)
	gl.BindVertexArray(imm.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, imm.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(imm.verts) * size_of(Imm_Vertex), raw_data(imm.verts), gl.STREAM_DRAW)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(len(imm.verts)))
	clear(&imm.verts)
}
