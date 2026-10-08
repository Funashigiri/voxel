package main

// Модель персонажа из 6 коробок (голова, тело, руки, ноги) + слои одежды.
// Анимация ходьбы повторяет формулы Minecraft (ModelBiped): руки и ноги
// качаются по cos(limbSwing * 0.6662) с амплитудой limbSwingAmount.
// Плавание — тоже по формулам Minecraft. Сверху добавлены позы прыжка,
// приземления, приседа и "бултыхание" в воде.

import "core:math"
import "core:math/linalg"
import eng "engine"
import gl "vendor:OpenGL"

Model_Part :: enum {
	Head,
	Body,
	Right_Arm,
	Left_Arm,
	Right_Leg,
	Left_Leg,
}

Entity_Vertex :: struct {
	pos:    [3]f32,
	uv:     [2]f32,
	normal: [3]f32,
}

// Координаты модели — в "пикселях" скина, ступни на y = 0, лицо смотрит в +Z.
Part_Def :: struct {
	pivot:            [3]f32,
	box_min, box_max: [3]f32, // относительно pivot
	uv, overlay_uv:   [2]int,
	size:             [3]int, // w, h, d для развёртки
	inflate:          f32, // толщина слоя одежды
}

PART_DEFS := [Model_Part]Part_Def {
	.Head = {pivot = {0, 24, 0}, box_min = {-4, 0, -4}, box_max = {4, 8, 4}, uv = {0, 0}, overlay_uv = {32, 0}, size = {8, 8, 8}, inflate = 0.5},
	.Body = {pivot = {0, 24, 0}, box_min = {-4, -12, -2}, box_max = {4, 0, 2}, uv = {16, 16}, overlay_uv = {16, 32}, size = {8, 12, 4}, inflate = 0.25},
	.Right_Arm = {pivot = {-5, 22, 0}, box_min = {-3, -10, -2}, box_max = {1, 2, 2}, uv = {40, 16}, overlay_uv = {40, 32}, size = {4, 12, 4}, inflate = 0.25},
	.Left_Arm = {pivot = {5, 22, 0}, box_min = {-1, -10, -2}, box_max = {3, 2, 2}, uv = {32, 48}, overlay_uv = {48, 48}, size = {4, 12, 4}, inflate = 0.25},
	.Right_Leg = {pivot = {-1.9, 12, 0}, box_min = {-2, -12, -2}, box_max = {2, 0, 2}, uv = {0, 16}, overlay_uv = {0, 32}, size = {4, 12, 4}, inflate = 0.25},
	.Left_Leg = {pivot = {1.9, 12, 0}, box_min = {-2, -12, -2}, box_max = {2, 0, 2}, uv = {16, 48}, overlay_uv = {0, 48}, size = {4, 12, 4}, inflate = 0.25},
}

MODEL_SCALE :: 0.9375 / 16.0 // пиксель скина -> блоки

// Общая геометрия для всех персонажей; скин (текстура) у каждого свой.
Humanoid_Model :: struct {
	vao, vbo: u32,
	ranges:   [Model_Part][2]i32, // first, count
}

// Поза: углы в соглашении Minecraft (x — вперёд/назад, y — поворот, z — в сторону).
Pose :: struct {
	rot:    [Model_Part][3]f32,
	offset: [Model_Part][3]f32, // сдвиг pivot (пиксели)
	root_y:      f32, // сдвиг всей модели (пиксели)
	swim_angle:  f32, // наклон всего тела при плавании (вокруг X)
	swim_offset: [3]f32, // сдвиг тела при плавании (блоки, до масштаба)
}

@(private = "file")
add_face :: proc(out: ^[dynamic]Entity_Vertex, c: [4][3]f32, u0, v0, u1, v1: f32, n: [3]f32) {
	S :: 1.0 / SKIN_SIZE
	uv := [4][2]f32{{u0 * S, v1 * S}, {u1 * S, v1 * S}, {u1 * S, v0 * S}, {u0 * S, v0 * S}}
	for k in ([6]int{0, 1, 2, 0, 2, 3}) {
		append(out, Entity_Vertex{pos = c[k], uv = uv[k], normal = n})
	}
}

// Коробка с развёрткой Minecraft: [право | перед | лево | зад], сверху [верх | низ].
@(private = "file")
add_box :: proc(out: ^[dynamic]Entity_Vertex, mn, mx: [3]f32, tex: [2]int, size: [3]int) {
	x0, y0, z0 := mn.x, mn.y, mn.z
	x1, y1, z1 := mx.x, mx.y, mx.z
	u, v := f32(tex.x), f32(tex.y)
	w, h, d := f32(size.x), f32(size.y), f32(size.z)
	add_face(out, {{x0, y0, z1}, {x1, y0, z1}, {x1, y1, z1}, {x0, y1, z1}}, u + d, v + d, u + d + w, v + d + h, {0, 0, 1}) // перед
	add_face(out, {{x1, y0, z0}, {x0, y0, z0}, {x0, y1, z0}, {x1, y1, z0}}, u + 2 * d + w, v + d, u + 2 * d + 2 * w, v + d + h, {0, 0, -1}) // зад
	add_face(out, {{x0, y0, z0}, {x0, y0, z1}, {x0, y1, z1}, {x0, y1, z0}}, u, v + d, u + d, v + d + h, {-1, 0, 0}) // правый бок
	add_face(out, {{x1, y0, z1}, {x1, y0, z0}, {x1, y1, z0}, {x1, y1, z1}}, u + d + w, v + d, u + 2 * d + w, v + d + h, {1, 0, 0}) // левый бок
	add_face(out, {{x0, y1, z1}, {x1, y1, z1}, {x1, y1, z0}, {x0, y1, z0}}, u + d, v, u + d + w, v + d, {0, 1, 0}) // верх
	add_face(out, {{x0, y0, z0}, {x1, y0, z0}, {x1, y0, z1}, {x0, y0, z1}}, u + d + w, v + d, u + d + 2 * w, v, {0, -1, 0}) // низ
}

humanoid_model_create :: proc() -> (m: Humanoid_Model) {
	verts := make([dynamic]Entity_Vertex, context.temp_allocator)
	for part in Model_Part {
		def := PART_DEFS[part]
		first := i32(len(verts))
		add_box(&verts, def.box_min, def.box_max, def.uv, def.size)
		inf := [3]f32{def.inflate, def.inflate, def.inflate}
		add_box(&verts, def.box_min - inf, def.box_max + inf, def.overlay_uv, def.size)
		m.ranges[part] = {first, i32(len(verts)) - first}
	}

	gl.GenVertexArrays(1, &m.vao)
	gl.GenBuffers(1, &m.vbo)
	gl.BindVertexArray(m.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, m.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(verts) * size_of(Entity_Vertex), raw_data(verts), gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, size_of(Entity_Vertex), offset_of(Entity_Vertex, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, size_of(Entity_Vertex), offset_of(Entity_Vertex, uv))
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribPointer(2, 3, gl.FLOAT, false, size_of(Entity_Vertex), offset_of(Entity_Vertex, normal))
	gl.BindVertexArray(0)
	return
}

// Вычисляет позу персонажа для момента t (0..1) между тиками.
character_pose :: proc(p: ^Character, t: f32) -> (pose: Pose, body_yaw: f32) {
	lerp :: math.lerp
	speed := min(lerp(p.prev_limb_speed, p.limb_speed, t), 1)
	swing := p.limb_pos - p.limb_speed * (1 - t)
	age := p.age + t
	air := lerp(p.prev_air, p.air, t)
	land := lerp(p.prev_land, p.land, t)
	crouch := max(lerp(p.prev_crouch, p.crouch, t), land * 0.55)
	body_yaw = eng.lerp_angle(p.prev_body_yaw, p.body_yaw, t)

	// голова смотрит туда же, куда камера
	look_yaw, look_pitch := p.yaw, p.pitch
	if p.interp_look {
		look_yaw = eng.lerp_angle(p.prev_yaw, p.yaw, t)
		look_pitch = lerp(p.prev_pitch, p.pitch, t)
	}
	head_yaw := clamp(eng.wrap_angle(look_yaw - body_yaw), -math.to_radians(f32(75)), math.to_radians(f32(75)))
	pose.rot[.Head] = {look_pitch, head_yaw, 0}

	// ходьба / бег (формулы Minecraft)
	phase := swing * 0.6662
	stride := speed * (1 - air * 0.4)
	pose.rot[.Right_Arm].x = math.cos(phase + math.PI) * stride
	pose.rot[.Left_Arm].x = math.cos(phase) * stride
	pose.rot[.Right_Leg].x = math.cos(phase) * 1.4 * stride
	pose.rot[.Left_Leg].x = math.cos(phase + math.PI) * 1.4 * stride

	// дыхание: руки слегка покачиваются
	breath := math.cos(age * 0.09) * 0.05 + 0.05
	pose.rot[.Right_Arm].z += breath
	pose.rot[.Left_Arm].z -= breath
	pose.rot[.Right_Arm].x += math.sin(age * 0.067) * 0.05
	pose.rot[.Left_Arm].x -= math.sin(age * 0.067) * 0.05

	// в воздухе: руки в стороны, ноги "шагом"
	pose.rot[.Right_Arm].x -= 0.35 * air
	pose.rot[.Left_Arm].x -= 0.35 * air
	pose.rot[.Right_Arm].z += 0.35 * air
	pose.rot[.Left_Arm].z -= 0.35 * air
	pose.rot[.Right_Leg].x -= 0.45 * air
	pose.rot[.Left_Leg].x += 0.25 * air
	pose.rot[.Right_Leg].z += 0.06 * air
	pose.rot[.Left_Leg].z -= 0.06 * air

	// в воде на месте — лёгкое "бултыхание": руки в стороны и мелкие гребки
	// попеременно, ноги медленно крутят "велосипед", тело покачивается
	tread := lerp(p.prev_tread, p.tread, t)
	if tread > 0.001 {
		ph := age * 0.32
		k := tread * (1 - speed * 0.6)
		pose.rot[.Right_Arm].z += (0.55 + 0.15 * math.cos(ph * 2)) * k
		pose.rot[.Left_Arm].z -= (0.55 + 0.15 * math.cos(ph * 2 + 1)) * k
		pose.rot[.Right_Arm].x += (math.sin(ph) * 0.45 - 0.2) * k
		pose.rot[.Left_Arm].x += (math.sin(ph + math.PI) * 0.45 - 0.2) * k
		pose.rot[.Right_Leg].x += math.sin(ph * 1.3) * 0.35 * k
		pose.rot[.Left_Leg].x += math.sin(ph * 1.3 + math.PI) * 0.35 * k
		pose.rot[.Right_Leg].z += 0.05 * k
		pose.rot[.Left_Leg].z -= 0.05 * k
		pose.root_y += math.sin(ph * 2) * 0.5 * tread
	}

	// присед (и короткое "проседание" при приземлении)
	pose.rot[.Body].x += 0.5 * crouch
	pose.rot[.Right_Arm].x += 0.4 * crouch
	pose.rot[.Left_Arm].x += 0.4 * crouch
	pose.offset[.Head].y = -4.2 * crouch
	pose.offset[.Body].y = -3.2 * crouch
	pose.offset[.Right_Arm].y = -3.2 * crouch
	pose.offset[.Left_Arm].y = -3.2 * crouch
	pose.offset[.Right_Leg] = {0, -0.2 * crouch, -4 * crouch}
	pose.offset[.Left_Leg] = {0, -0.2 * crouch, -4 * crouch}
	pose.root_y = -0.125 / MODEL_SCALE * crouch

	// плавание (формулы HumanoidModel из Minecraft): руки гребут над головой,
	// ноги делают частые махи, голова поднята, всё тело наклонено по взгляду
	swim := lerp(p.prev_swim, p.swim, t)
	if swim > 0.001 {
		q :: proc(f: f32) -> f32 {return -65 * f + f * f}
		PI :: math.PI
		f5 := math.mod(swing, 26)
		tr, tl: [3]f32
		if f5 < 14 {
			k := q(f5) / q(14)
			tr = {0, PI, PI - 1.8707964 * k}
			tl = {0, PI, PI + 1.8707964 * k}
		} else if f5 < 22 {
			f6 := (f5 - 14) / 8
			tr = {PI / 2 * f6, PI, 1.2707963 + 1.8707964 * f6}
			tl = {PI / 2 * f6, PI, 5.012389 - 1.8707964 * f6}
		} else {
			f3 := (f5 - 22) / 4
			tr = {PI / 2 - PI / 2 * f3, PI, PI}
			tl = {PI / 2 - PI / 2 * f3, PI, PI}
		}
		ra := &pose.rot[.Right_Arm]
		la := &pose.rot[.Left_Arm]
		for i in 0 ..< 3 {
			ra[i] = lerp(ra[i], tr[i], swim)
			la[i] = eng.lerp_angle(la[i], tl[i], swim)
		}
		pose.rot[.Right_Leg].x = lerp(pose.rot[.Right_Leg].x, 0.3 * math.cos(swing * 0.33333334), swim)
		pose.rot[.Left_Leg].x = lerp(pose.rot[.Left_Leg].x, 0.3 * math.cos(swing * 0.33333334 + PI), swim)
		pose.rot[.Head].x = eng.lerp_angle(pose.rot[.Head].x, -PI / 4, swim)
		tilt := p.in_water ? look_pitch : 0 // ползком на суше — просто лёжа
		pose.swim_angle = (PI / 2 + tilt) * swim
		pose.swim_offset = [3]f32{0, -0.9, -0.3} * swim
	}

	// взмах рукой — ответ на приказ
	wave := lerp(p.prev_wave, p.wave, t)
	if wave > 0.001 {
		arm := &pose.rot[.Right_Arm]
		arm.x = lerp(arm.x, -2.75, wave)
		arm.z = lerp(arm.z, 0.25 + math.sin(age * 0.9) * 0.4, wave)
	}
	return
}

@(private = "file")
part_matrix :: proc(part: Model_Part, pose: ^Pose) -> eng.Mat4 {
	r := pose.rot[part]
	return linalg.matrix4_translate_f32(PART_DEFS[part].pivot + pose.offset[part]) *
		linalg.matrix4_rotate_f32(-r.z, {0, 0, 1}) *
		linalg.matrix4_rotate_f32(-r.y, {0, 1, 0}) *
		linalg.matrix4_rotate_f32(r.x, {1, 0, 0})
}

// Рисует персонажа. rel_pos — позиция ног относительно камеры.
humanoid_model_draw :: proc(m: ^Humanoid_Model, sh: ^Entity_Shader, view_proj: eng.Mat4, rel_pos: [3]f32, body_yaw: f32, pose: ^Pose) {
	root :=
		linalg.matrix4_translate_f32(rel_pos) *
		linalg.matrix4_rotate_f32(-body_yaw, {0, 1, 0}) *
		linalg.matrix4_rotate_f32(pose.swim_angle, {1, 0, 0}) *
		linalg.matrix4_translate_f32(pose.swim_offset) *
		linalg.matrix4_scale_f32({MODEL_SCALE, MODEL_SCALE, MODEL_SCALE}) *
		linalg.matrix4_translate_f32({0, pose.root_y, 0})
	gl.BindVertexArray(m.vao)
	for part in Model_Part {
		model := root * part_matrix(part, pose)
		eng.set_mat4(sh.u_model, model)
		eng.set_mat4(sh.u_mvp, view_proj * model)
		gl.DrawArrays(gl.TRIANGLES, m.ranges[part][0], m.ranges[part][1])
	}
}

// Правая рука в режиме от первого лица. hand — матрица в пространстве камеры.
humanoid_model_draw_hand :: proc(m: ^Humanoid_Model, sh: ^Entity_Shader, proj: eng.Mat4, view_to_world: eng.Mat4, hand: eng.Mat4) {
	model := hand * linalg.matrix4_scale_f32({1.0 / 16, 1.0 / 16, 1.0 / 16})
	eng.set_mat4(sh.u_model, view_to_world * model)
	eng.set_mat4(sh.u_mvp, proj * model)
	gl.BindVertexArray(m.vao)
	gl.DrawArrays(gl.TRIANGLES, m.ranges[.Right_Arm][0], m.ranges[.Right_Arm][1])
}
