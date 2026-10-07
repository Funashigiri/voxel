package engine

// Детерминированные хеши/шум и мелкая математика.

import "core:math"

hash_u32 :: proc "contextless" (v: u32) -> u32 {
	x := v
	x ~= x >> 16
	x *= 0x7feb352d
	x ~= x >> 15
	x *= 0x846ca68b
	x ~= x >> 16
	return x
}

hash2 :: proc "contextless" (x, y: i32, seed: u32) -> u32 {
	h := hash_u32(transmute(u32)x ~ seed * 0x9E3779B9)
	h = hash_u32(h ~ transmute(u32)y * 0x85EBCA6B)
	return h
}

hash3 :: proc "contextless" (x, y, z: i32, seed: u32) -> u32 {
	h := hash2(x, y, seed)
	return hash_u32(h ~ transmute(u32)z * 0xC2B2AE35)
}

// [0, 1)
hash2f :: proc "contextless" (x, y: i32, seed: u32) -> f32 {
	return f32(hash2(x, y, seed) >> 8) / f32(1 << 24)
}

hash3f :: proc "contextless" (x, y, z: i32, seed: u32) -> f32 {
	return f32(hash3(x, y, z, seed) >> 8) / f32(1 << 24)
}

// Value-noise, бесшовно повторяющийся с периодом `period` (для текстур).
tile_value_noise :: proc "contextless" (x, y: f32, cell: f32, period: i32, seed: u32) -> f32 {
	fx := x / cell
	fy := y / cell
	ix := i32(math.floor(fx))
	iy := i32(math.floor(fy))
	tx := fx - f32(ix)
	ty := fy - f32(iy)
	tx = tx * tx * (3 - 2 * tx)
	ty = ty * ty * (3 - 2 * ty)
	w :: proc "contextless" (v, p: i32) -> i32 {return ((v % p) + p) % p}
	a := hash2f(w(ix, period), w(iy, period), seed)
	b := hash2f(w(ix + 1, period), w(iy, period), seed)
	c := hash2f(w(ix, period), w(iy + 1, period), seed)
	d := hash2f(w(ix + 1, period), w(iy + 1, period), seed)
	return math.lerp(math.lerp(a, b, tx), math.lerp(c, d, tx), ty)
}

floor_div :: proc "contextless" (a, b: i32) -> i32 {
	q := a / b
	if (a % b != 0) && ((a < 0) != (b < 0)) do q -= 1
	return q
}

floor_mod :: proc "contextless" (a, b: i32) -> i32 {
	return a - floor_div(a, b) * b
}

// Приводит угол к диапазону [-PI, PI).
wrap_angle :: proc "contextless" (a: f32) -> f32 {
	r := math.mod(a + math.PI, 2 * math.PI)
	if r < 0 do r += 2 * math.PI
	return r - math.PI
}

lerp_angle :: proc "contextless" (a, b, t: f32) -> f32 {
	return a + wrap_angle(b - a) * t
}

smoothstep :: proc "contextless" (e0, e1, x: f32) -> f32 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}
