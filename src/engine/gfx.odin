package engine

// Тонкая обёртка над OpenGL: шейдеры, текстуры, юниформы, скриншоты.

import "core:fmt"
import "core:strings"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

Mat4 :: matrix[4, 4]f32
Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32

@(private)
compile_stage :: proc(name: string, kind: u32, src: string) -> (u32, bool) {
	shader := gl.CreateShader(kind)
	csrc := cstring(raw_data(src))
	length := i32(len(src))
	gl.ShaderSource(shader, 1, &csrc, &length)
	gl.CompileShader(shader)

	status: i32
	gl.GetShaderiv(shader, gl.COMPILE_STATUS, &status)
	if status == 0 {
		log_len: i32
		gl.GetShaderiv(shader, gl.INFO_LOG_LENGTH, &log_len)
		buf := make([]u8, max(log_len, 1), context.temp_allocator)
		gl.GetShaderInfoLog(shader, log_len, nil, raw_data(buf))
		stage := kind == gl.VERTEX_SHADER ? "vertex" : "fragment"
		fmt.eprintfln("[engine] shader '%s' (%s) compile error:\n%s", name, stage, string(buf))
		gl.DeleteShader(shader)
		return 0, false
	}
	return shader, true
}

shader_create :: proc(name: string, vs_src, fs_src: string) -> (program: u32, ok: bool) {
	vs := compile_stage(name, gl.VERTEX_SHADER, vs_src) or_return
	defer gl.DeleteShader(vs)
	fs := compile_stage(name, gl.FRAGMENT_SHADER, fs_src) or_return
	defer gl.DeleteShader(fs)

	program = gl.CreateProgram()
	gl.AttachShader(program, vs)
	gl.AttachShader(program, fs)
	gl.LinkProgram(program)

	status: i32
	gl.GetProgramiv(program, gl.LINK_STATUS, &status)
	if status == 0 {
		log_len: i32
		gl.GetProgramiv(program, gl.INFO_LOG_LENGTH, &log_len)
		buf := make([]u8, max(log_len, 1), context.temp_allocator)
		gl.GetProgramInfoLog(program, log_len, nil, raw_data(buf))
		fmt.eprintfln("[engine] shader '%s' link error:\n%s", name, string(buf))
		gl.DeleteProgram(program)
		return 0, false
	}
	return program, true
}

uniform_loc :: proc(program: u32, name: cstring) -> i32 {
	return gl.GetUniformLocation(program, name)
}

set_mat4 :: proc(loc: i32, m: Mat4) {
	m := m
	gl.UniformMatrix4fv(loc, 1, false, &m[0, 0])
}
set_vec2 :: proc(loc: i32, v: Vec2) {gl.Uniform2f(loc, v.x, v.y)}
set_vec3 :: proc(loc: i32, v: Vec3) {gl.Uniform3f(loc, v.x, v.y, v.z)}
set_vec4 :: proc(loc: i32, v: Vec4) {gl.Uniform4f(loc, v.x, v.y, v.z, v.w)}
set_f32 :: proc(loc: i32, v: f32) {gl.Uniform1f(loc, v)}
set_i32 :: proc(loc: i32, v: i32) {gl.Uniform1i(loc, v)}

// Массив текстур одинакового размера (все блоки 16x16) с мипмапами и
// фильтрацией "nearest" — пиксельный вид как в Minecraft.
texture_array_create :: proc(width, height, layers: i32, pixels: []u8, max_mip: i32 = 4) -> u32 {
	tex: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D_ARRAY, tex)
	gl.TexImage3D(gl.TEXTURE_2D_ARRAY, 0, gl.RGBA8, width, height, layers, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
	gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.NEAREST_MIPMAP_LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAX_LEVEL, max_mip)
	gl.GenerateMipmap(gl.TEXTURE_2D_ARRAY)
	return tex
}

texture_2d_create :: proc(width, height: i32, pixels: []u8) -> u32 {
	tex: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	return tex
}

// Сохраняет текущий кадр (backbuffer) в PNG.
save_screenshot :: proc(path: string, width, height: i32) -> bool {
	pixels := make([]u8, int(width * height * 4), context.temp_allocator)
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
	gl.ReadPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
	// убираем альфу, чтобы PNG не был полупрозрачным
	for i := 3; i < len(pixels); i += 4 do pixels[i] = 255
	stbi.flip_vertically_on_write(true)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	return stbi.write_png(cpath, width, height, 4, raw_data(pixels), width * 4) != 0
}
