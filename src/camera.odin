package main

// Камера: от первого лица, от третьего лица сзади и спереди (F5).

import "core:math"
import "core:math/linalg"
import eng "engine"

Camera_Mode :: enum {
	First_Person,
	Third_Back,
	Third_Front,
}

BASE_FOV :: 70.0
THIRD_PERSON_DIST :: 4.0
NEAR_PLANE :: 0.05
FAR_PLANE :: 1000.0

Camera :: struct {
	mode:       Camera_Mode,
	pos:        [3]f64, // мировая позиция камеры
	yaw, pitch: f32,
	bob:        eng.Mat4, // покачивание при ходьбе (только от первого лица)
	view:       eng.Mat4, // без переноса: рисуем всё относительно камеры
	proj:       eng.Mat4,
	view_proj:  eng.Mat4,
	fov:        f32,
	hand_yaw:   f32, // сглаженные углы для "запаздывания" руки
	hand_pitch: f32,
	orbit:      f32, // отладка: доп. поворот камеры вокруг игрока (от третьего лица)
}

// Луч по вокселям (Amanatides & Woo). Возвращает расстояние до первого
// твёрдого блока, сам блок и нормаль грани, в которую попал луч.
raycast_solid :: proc(w: ^World, origin, dir: [3]f64, max_dist: f64) -> (hit: bool, dist: f64, cell: [3]i32, normal: [3]i32) {
	cellf := [3]f64{math.floor(origin.x), math.floor(origin.y), math.floor(origin.z)}
	cell = {i32(cellf.x), i32(cellf.y), i32(cellf.z)}
	step: [3]i32
	t_max, t_delta: [3]f64
	for a in 0 ..< 3 {
		if dir[a] > 0 {
			step[a] = 1
			t_delta[a] = 1 / dir[a]
			t_max[a] = (cellf[a] + 1 - origin[a]) / dir[a]
		} else if dir[a] < 0 {
			step[a] = -1
			t_delta[a] = -1 / dir[a]
			t_max[a] = (origin[a] - cellf[a]) / -dir[a]
		} else {
			t_delta[a] = math.F64_MAX
			t_max[a] = math.F64_MAX
		}
	}
	t: f64 = 0
	for t <= max_dist {
		if b, loaded := world_get_block(w, cell.x, cell.y, cell.z); loaded && BLOCK_INFO[b].solid {
			return true, t, cell, normal
		}
		a := 0
		if t_max[1] < t_max[a] do a = 1
		if t_max[2] < t_max[a] do a = 2
		t = t_max[a]
		t_max[a] += t_delta[a]
		cell[a] += step[a]
		normal = {}
		normal[a] = -step[a]
	}
	return false, max_dist, cell, normal
}

// Отодвигает камеру ближе, если между ней и игроком есть блоки.
@(private = "file")
clip_distance :: proc(w: ^World, eye, dir: [3]f64, dist: f64) -> f64 {
	d := dist
	for i in 0 ..< 8 {
		off := [3]f64{f64(i & 1) * 2 - 1, f64((i >> 1) & 1) * 2 - 1, f64((i >> 2) & 1) * 2 - 1} * 0.1
		if hit, t, _, _ := raycast_solid(w, eye + off, dir, d); hit && t < d do d = t
	}
	return d
}

camera_cycle_mode :: proc(cam: ^Camera) {
	cam.mode = Camera_Mode((int(cam.mode) + 1) % len(Camera_Mode))
}

camera_update :: proc(cam: ^Camera, p: ^Character, w: ^World, t: f32, aspect: f32, dt: f32) {
	eye := character_render_pos(p, t)
	eye.y += f64(math.lerp(p.prev_eye_h, p.eye_h, t))
	look := look_dir(p.yaw, p.pitch)
	fwd := [3]f64{f64(look.x), f64(look.y), f64(look.z)}

	switch cam.mode {
	case .First_Person:
		cam.pos = eye
		cam.yaw, cam.pitch = p.yaw, p.pitch
	case .Third_Back:
		ol := look_dir(p.yaw + cam.orbit, p.pitch)
		ofwd := [3]f64{f64(ol.x), f64(ol.y), f64(ol.z)}
		cam.pos = eye - ofwd * clip_distance(w, eye, -ofwd, THIRD_PERSON_DIST)
		cam.yaw, cam.pitch = p.yaw + cam.orbit, p.pitch
	case .Third_Front:
		cam.pos = eye + fwd * clip_distance(w, eye, fwd, THIRD_PERSON_DIST)
		cam.yaw, cam.pitch = p.yaw + math.PI, -p.pitch
	}

	// покачивание камеры при ходьбе (как view bobbing в Minecraft)
	cam.bob = 1
	if cam.mode == .First_Person {
		f1 := -math.lerp(p.prev_walk_dist, p.walk_dist, t) * math.PI
		f2 := math.lerp(p.prev_bob, p.bob, t)
		cam.bob =
			linalg.matrix4_translate_f32({math.sin(f1) * f2 * 0.5, -abs(math.cos(f1) * f2), 0}) *
			linalg.matrix4_rotate_f32(math.to_radians(math.sin(f1) * f2 * 3), {0, 0, 1}) *
			linalg.matrix4_rotate_f32(math.to_radians(abs(math.cos(f1 - 0.2) * f2) * 5), {1, 0, 0})
	}

	dir := look_dir(cam.yaw, cam.pitch)
	cam.view = cam.bob * linalg.matrix4_look_at_f32({0, 0, 0}, dir, {0, 1, 0})
	cam.fov = BASE_FOV * math.lerp(p.prev_fov_mod, p.fov_mod, t)
	cam.proj = linalg.matrix4_perspective_f32(math.to_radians(cam.fov), aspect, NEAR_PLANE, FAR_PLANE)
	cam.view_proj = cam.proj * cam.view

	k := 1 - math.pow(f32(0.5), dt * 20)
	cam.hand_yaw = eng.lerp_angle(cam.hand_yaw, p.yaw, k)
	cam.hand_pitch += (p.pitch - cam.hand_pitch) * k
}
