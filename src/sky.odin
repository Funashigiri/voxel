package main

// Небо: градиент, солнце и луны рисует шейдер неба (цвета и положения —
// astro.odin), звёзды — starsky.odin, облака — clouds.odin.

import gl "vendor:OpenGL"

// Цвета ясного дневного неба (дальше astro.odin меняет их по высоте солнца).
SKY_TOP :: [3]f32{0.47, 0.65, 1.0}
SKY_HORIZON :: [3]f32{0.74, 0.84, 1.0}

Sky :: struct {
	empty_vao: u32, // полноэкранный треугольник без вершин
}

sky_init :: proc(s: ^Sky) {
	gl.GenVertexArrays(1, &s.empty_vao)
}
