package main

// Простые частицы-квадраты, повёрнутые к камере (как в Minecraft):
// огонь, дым, пыль, искры, "втягивание" при коллапсе капсулы.

import "core:math"
import eng "engine"

Particle :: struct {
	pos:            [3]f64,
	vel:            [3]f32,
	age, life:      f32,
	size0, size1:   f32,
	color0, color1: [4]u8,
	gravity:        f32,
	drag:           f32,
	additive:       bool, // светящиеся (огонь, искры) — складываются со светом
	attract:        f32, // > 0 — тянутся к точке target
	target:         [3]f64,
}

Particles :: struct {
	list: [dynamic]Particle,
}

particles_emit :: proc(ps: ^Particles, p: Particle) {
	if len(ps.list) < 4000 do append(&ps.list, p)
}

particles_update :: proc(ps: ^Particles, dt: f32) {
	for i := 0; i < len(ps.list); {
		p := &ps.list[i]
		p.age += dt
		if p.age >= p.life {
			unordered_remove(&ps.list, i)
			continue
		}
		if p.attract > 0 {
			to := p.target - p.pos
			d := f32(math.sqrt(to.x * to.x + to.y * to.y + to.z * to.z))
			if d > 0.05 do p.vel += [3]f32{f32(to.x), f32(to.y), f32(to.z)} / d * p.attract * dt
		}
		p.vel.y -= p.gravity * dt
		p.vel *= max(0, 1 - p.drag * dt)
		p.pos += [3]f64{f64(p.vel.x), f64(p.vel.y), f64(p.vel.z)} * f64(dt)
		i += 1
	}
}

particles_clear :: proc(ps: ^Particles) {
	clear(&ps.list)
}

// Рисует частицы одного типа (обычные или светящиеся); смешивание задаёт вызывающий.
particles_draw :: proc(ps: ^Particles, cam: ^Camera, additive: bool) {
	right := [3]f32{cam.view[0, 0], cam.view[0, 1], cam.view[0, 2]}
	up := [3]f32{cam.view[1, 0], cam.view[1, 1], cam.view[1, 2]}
	for &p in ps.list {
		if p.additive != additive do continue
		k := p.age / p.life
		size := math.lerp(p.size0, p.size1, k) * 0.5
		c: [4]u8
		for i in 0 ..< 4 do c[i] = u8(math.lerp(f32(p.color0[i]), f32(p.color1[i]), k))
		centre := [3]f32{f32(p.pos.x - cam.pos.x), f32(p.pos.y - cam.pos.y), f32(p.pos.z - cam.pos.z)}
		r := right * size
		u := up * size
		eng.imm_quad(centre - r - u, centre + r - u, centre + r + u, centre - r + u, c)
	}
	eng.imm_flush(cam.view_proj)
}
