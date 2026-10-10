package main

// Персонаж (игрок или спутник): физика как в Minecraft (20 тиков/с, те же
// константы ускорения, трения и гравитации), коллизии AABB с блоками и
// состояние анимаций.

import "core:math"
import eng "engine"

CHAR_HALF_WIDTH :: 0.3
CHAR_HEIGHT :: 1.8
EYE_HEIGHT :: 1.62
SNEAK_EYE_HEIGHT :: 1.27
SWIM_HEIGHT :: 0.6 // в позе плавания хитбокс 0.6 x 0.6, как в Minecraft
SWIM_EYE_HEIGHT :: 0.4
TICK_RATE :: 20.0
TICK_DT :: 1.0 / TICK_RATE
JUMP_SPEED :: 0.42 // блоков за тик — сила ног, на любой планете одна
GRAVITY_PER_TICK :: 0.08 // ускорение падения при 1 g (как в Minecraft)
CLIMB_TICKS :: 24 // дольше этого на уступ не лезет

@(private = "file")
EPS :: 1e-7

Move_Input :: struct {
	forward, strafe:     f32, // -1..1 (strafe > 0 — влево, как в Minecraft)
	jump, sneak, sprint: bool,
}

Character :: struct {
	pos, prev_pos:              [3]f64,
	vel:                        [3]f64,
	yaw, pitch:                 f32, // радианы; yaw 0 = смотрит на +Z, растёт вправо
	on_ground, in_water:        bool,
	h_collision:                bool,
	sprinting, sneaking:        bool,
	swimming:                   bool, // плывёт лёжа (бег в воде)
	prev_yaw, prev_pitch:       f32, // для плавного поворота головы у NPC
	interp_look:                bool,

	// анимация (обновляется каждый тик, интерполируется при отрисовке)
	limb_pos:                   f32,
	limb_speed, prev_limb_speed: f32,
	body_yaw, prev_body_yaw:    f32,
	age:                        f32,
	air, prev_air:              f32, // 0..1 — в прыжке/падении
	crouch, prev_crouch:        f32, // 0..1 — присед
	land, prev_land:            f32, // 0..1 — "приземление", затухает
	walk_dist, prev_walk_dist:  f32, // для покачивания камеры
	bob, prev_bob:              f32,
	eye_h, prev_eye_h:          f32,
	fov_mod, prev_fov_mod:      f32,
	wave, prev_wave:            f32, // 0..1 — машет рукой (ответ на приказ)
	wave_ticks:                 i32,
	swim, prev_swim:            f32, // 0..1 — поза плавания
	tread, prev_tread:          f32, // 0..1 — "бултыхание" на месте в воде
	climb:                      i32, // > 0 — залезает на уступ (тиков осталось)
	climb_top:                  f64, // высота верха уступа
}

AABB :: struct {
	min, max: [3]f64,
}

character_box :: proc(pos: [3]f64, height: f64 = CHAR_HEIGHT) -> AABB {
	return {
		{pos.x - CHAR_HALF_WIDTH, pos.y, pos.z - CHAR_HALF_WIDTH},
		{pos.x + CHAR_HALF_WIDTH, pos.y + height, pos.z + CHAR_HALF_WIDTH},
	}
}

character_height :: proc(p: ^Character) -> f64 {
	return p.swimming ? SWIM_HEIGHT : CHAR_HEIGHT
}

@(private = "file")
water_at :: proc(w: ^World, pos: [3]f64) -> bool {
	b, _ := world_get_block(w, i32(math.floor(pos.x)), i32(math.floor(pos.y)), i32(math.floor(pos.z)))
	return b == .Water
}

box_offset :: proc(b: AABB, d: [3]f64) -> AABB {
	return {b.min + d, b.max + d}
}

@(private = "file")
cell_range :: proc(lo, hi: f64) -> (i32, i32) {
	return i32(math.floor(lo + EPS)), i32(math.floor(hi - EPS))
}

box_collides :: proc(w: ^World, b: AABB) -> bool {
	x0, x1 := cell_range(b.min.x, b.max.x)
	y0, y1 := cell_range(b.min.y, b.max.y)
	if w.snow != nil do y0 -= SNOW_BELOW // снег на блоках ниже поднимает их верх
	z0, z1 := cell_range(b.min.z, b.max.z)
	for y in y0 ..= y1 do for z in z0 ..= z1 do for x in x0 ..= x1 {
		if !world_is_solid(w, x, y, z) do continue
		bx, n := block_boxes(w, x, y, z)
		for c in bx[:n] {
			inside := true
			for a in 0 ..< 3 do if b.max[a] <= c[0][a] + EPS || b.min[a] >= c[1][a] - EPS do inside = false
			if inside do return true
		}
	}
	return false
}

// Насколько можно сдвинуть коробку по оси, не войдя в твёрдый блок.
@(private = "file")
clip_axis :: proc(w: ^World, b: AABB, d: f64, axis: int) -> f64 {
	if d == 0 do return 0
	region := b
	if d > 0 {
		region.max[axis] += d
	} else {
		region.min[axis] += d
	}
	x0, x1 := cell_range(region.min.x, region.max.x)
	y0, y1 := cell_range(region.min.y, region.max.y)
	if w.snow != nil do y0 -= SNOW_BELOW
	z0, z1 := cell_range(region.min.z, region.max.z)
	d := d
	for y in y0 ..= y1 do for z in z0 ..= z1 do for x in x0 ..= x1 {
		if !world_is_solid(w, x, y, z) do continue
		bx, n := block_boxes(w, x, y, z) // у тонкого ствола — его настоящая форма
		for c in bx[:n] {
			cmin, cmax := c[0], c[1]
			overlap := true
			for a in 0 ..< 3 {
				if a == axis do continue
				if b.max[a] <= cmin[a] + EPS || b.min[a] >= cmax[a] - EPS do overlap = false
			}
			if !overlap do continue
			if d > 0 && b.max[axis] <= cmin[axis] + EPS {
				d = min(d, cmin[axis] - b.max[axis])
			} else if d < 0 && b.min[axis] >= cmax[axis] - EPS {
				d = max(d, cmax[axis] - b.min[axis])
			}
		}
	}
	return d
}

@(private = "file")
in_water_check :: proc(w: ^World, pos: [3]f64, height: f64) -> bool {
	b := character_box(pos, height)
	shrink := min(0.4, height * 0.3)
	b.min += {0.001, shrink, 0.001}
	b.max -= {0.001, shrink, 0.001}
	x0, x1 := cell_range(b.min.x, b.max.x)
	y0, y1 := cell_range(b.min.y, b.max.y)
	z0, z1 := cell_range(b.min.z, b.max.z)
	for y in y0 ..= y1 do for z in z0 ..= z1 do for x in x0 ..= x1 {
		if blk, _ := world_get_block(w, x, y, z); blk == .Water do return true
	}
	return false
}

@(private = "file")
move_relative :: proc(p: ^Character, strafe, forward: f32, accel: f64) {
	f := strafe * strafe + forward * forward
	if f < 1e-4 do return
	f = math.sqrt(f)
	if f < 1 do f = 1
	k := accel / f64(f)
	s := f64(strafe) * k
	fw := f64(forward) * k
	sy := f64(math.sin(p.yaw))
	cy := f64(math.cos(p.yaw))
	p.vel.x += s * cy - fw * sy
	p.vel.z += fw * cy + s * sy
}

// Уступ высотой в блок прямо по ходу, на который можно залезть: блок впереди
// на уровне ног, над ним два свободных, над головой тоже свободно.
@(private = "file")
ledge_ahead :: proc(p: ^Character, w: ^World) -> (top: f64, ok: bool) {
	fx, fz := f64(-math.sin(p.yaw)), f64(math.cos(p.yaw))
	by := i32(math.floor(p.pos.y + 0.01))
	px, pz := i32(math.floor(p.pos.x)), i32(math.floor(p.pos.z))
	if world_is_solid(w, px, by + 2, pz) do return
	for dist in ([2]f64{0.45, 0.8}) {
		bx, bz := i32(math.floor(p.pos.x + fx * dist)), i32(math.floor(p.pos.z + fz * dist))
		if bx == px && bz == pz do continue
		if world_is_solid(w, bx, by, bz) && !world_is_solid(w, bx, by + 1, bz) && !world_is_solid(w, bx, by + 2, bz) {
			return f64(by + 1), true
		}
		return
	}
	return
}

@(private = "file")
character_move :: proc(p: ^Character, w: ^World) {
	d := p.vel
	box := character_box(p.pos, character_height(p))

	// присед: не даём сойти с края блока
	if p.sneaking && p.on_ground {
		STEP :: 0.05
		shrink :: proc(v: f64) -> f64 {
			if abs(v) < STEP do return 0
			return v - math.sign(v) * STEP
		}
		for d.x != 0 && !box_collides(w, box_offset(box, {d.x, -1, 0})) do d.x = shrink(d.x)
		for d.z != 0 && !box_collides(w, box_offset(box, {0, -1, d.z})) do d.z = shrink(d.z)
		for d.x != 0 && d.z != 0 && !box_collides(w, box_offset(box, {d.x, -1, d.z})) {
			d.x = shrink(d.x)
			d.z = shrink(d.z)
		}
	}

	orig := d
	start := box
	d.y = clip_axis(w, box, d.y, 1)
	box = box_offset(box, {0, d.y, 0})
	d.x = clip_axis(w, box, d.x, 0)
	box = box_offset(box, {d.x, 0, 0})
	d.z = clip_axis(w, box, d.z, 2)
	box = box_offset(box, {0, 0, d.z})
	// невысокий уступ (край снега, разная глубина у соседних блоков) — перешагиваем
	if p.on_ground && (orig.x != d.x || orig.z != d.z) && w.snow != nil {
		STEP_UP :: 0.4
		up := clip_axis(w, start, STEP_UP, 1)
		b2 := box_offset(start, {0, up, 0})
		sx := clip_axis(w, b2, orig.x, 0)
		b2 = box_offset(b2, {sx, 0, 0})
		sz := clip_axis(w, b2, orig.z, 2)
		b2 = box_offset(b2, {0, 0, sz})
		b2 = box_offset(b2, {0, clip_axis(w, b2, -up, 1), 0})
		if sx * sx + sz * sz > d.x * d.x + d.z * d.z + 1e-9 {
			box = b2
			d = {sx, d.y, sz}
		}
	}

	p.pos = {box.min.x + CHAR_HALF_WIDTH, box.min.y, box.min.z + CHAR_HALF_WIDTH}
	p.h_collision = orig.x != d.x || orig.z != d.z
	p.on_ground = orig.y != d.y && orig.y < 0
	if orig.x != d.x do p.vel.x = 0
	if orig.y != d.y do p.vel.y = 0
	if orig.z != d.z do p.vel.z = 0
}

character_spawn :: proc(p: ^Character, w: ^World, pos: [3]f64) {
	p^ = {}
	p.pos = pos
	// если попали в дерево или склон — поднимаемся
	for i := 0; i < 64 && box_collides(w, character_box(p.pos)); i += 1 do p.pos.y += 1
	p.prev_pos = p.pos
	p.eye_h = EYE_HEIGHT
	p.prev_eye_h = EYE_HEIGHT
	p.fov_mod = 1
	p.prev_fov_mod = 1
}

character_tick :: proc(p: ^Character, w: ^World, input: Move_Input) {
	p.prev_pos = p.pos
	p.prev_limb_speed = p.limb_speed
	p.prev_body_yaw = p.body_yaw
	p.prev_air = p.air
	p.prev_crouch = p.crouch
	p.prev_land = p.land
	p.prev_walk_dist = p.walk_dist
	p.prev_bob = p.bob
	p.prev_eye_h = p.eye_h
	p.prev_fov_mod = p.fov_mod
	p.prev_wave = p.wave
	p.prev_swim = p.swim
	p.prev_tread = p.tread

	forward := input.forward * 0.98
	strafe := input.strafe * 0.98
	p.sneaking = input.sneak
	crawling := p.swimming && !p.in_water // вылез лёжа туда, где не встать
	if p.sneaking || crawling {
		forward *= 0.3
		strafe *= 0.3
	}

	if input.sprint && input.forward > 0 && !p.sneaking && !crawling do p.sprinting = true
	if input.forward <= 0 || p.sneaking || (p.h_collision && !p.swimming) do p.sprinting = false

	// плавание: бег в воде укладывает персонажа горизонтально
	if p.swimming {
		if !(p.sprinting && p.in_water) && !box_collides(w, character_box(p.pos)) do p.swimming = false
	} else if p.sprinting && p.in_water && water_at(w, p.pos + {0, 0.2, 0}) {
		eyes_wet := water_at(w, p.pos + {0, EYE_HEIGHT, 0})
		deep := water_at(w, p.pos - {0, 0.8, 0})
		if eyes_wet || deep do p.swimming = true
	}

	was_on_ground := p.on_ground
	vy_before := p.vel.y

	if p.in_water && p.swimming {
		// вертикальная скорость тянется к направлению взгляда, гравитации нет
		look := f64(look_dir(p.yaw, p.pitch).y)
		k: f64 = look < -0.2 ? 0.085 : 0.06
		if look <= 0 || input.jump || water_at(w, p.pos + {0, 0.9, 0}) do p.vel.y += (look - p.vel.y) * k
		move_relative(p, strafe, forward, 0.02)
		character_move(p, w)
		p.vel.x *= 0.9
		p.vel.z *= 0.9
		p.vel.y *= 0.8
		if p.h_collision && input.jump do p.vel.y = 0.3
	} else if p.in_water {
		if input.jump do p.vel.y += 0.04
		if p.sneaking do p.vel.y -= 0.04 // нырнуть
		move_relative(p, strafe, forward, 0.02)
		character_move(p, w)
		p.vel *= 0.8
		p.vel.y -= 0.02
		if p.h_collision && input.jump do p.vel.y = 0.3 // выбраться на берег
	} else if p.climb > 0 {
		// залезает на уступ: подтягивается вверх (на тяжёлой планете — медленнее), потом шаг вперёд
		p.climb -= 1
		p.vel.y = 0.1 / math.sqrt(max(w.gravity, 0.1))
		move_relative(p, 0, 1, 0.04)
		character_move(p, w)
		p.vel.x *= 0.546
		p.vel.z *= 0.546
		if p.pos.y >= p.climb_top + 0.01 {
			p.climb = 0
			p.vel.y = 0
			p.vel.x -= f64(math.sin(p.yaw)) * 0.15
			p.vel.z += f64(math.cos(p.yaw)) * 0.15
		}
	} else {
		if input.jump && p.on_ground {
			// прыжка не хватает на блок (тяжёлая планета) — лезем на уступ руками
			top, ledge := 0.0, false
			if w.jump_apex < 1.05 && input.forward > 0 do top, ledge = ledge_ahead(p, w)
			if ledge {
				p.climb, p.climb_top = CLIMB_TICKS, top
			} else {
				p.vel.y = JUMP_SPEED
				if p.sprinting {
					p.vel.x -= f64(math.sin(p.yaw)) * 0.2
					p.vel.z += f64(math.cos(p.yaw)) * 0.2
				}
			}
		}
		accel: f64
		if p.on_ground {
			friction: f64 = 0.546
			speed: f64 = p.sprinting ? 0.13 : 0.1
			accel = speed * (0.16277136 / (friction * friction * friction))
			// по глубокому снегу идти тяжело: ноги вязнут на (глубина − на сколько держит)
			if _, depth, support, ok := snow_underfoot(p, w); ok do accel /= 1 + 2.5 * max(depth - support, 0)
		} else {
			accel = p.sprinting ? 0.026 : 0.02
		}
		move_relative(p, strafe, forward, accel)
		character_move(p, w)
		friction: f64 = p.on_ground ? 0.546 : 0.91
		p.vel.y -= GRAVITY_PER_TICK * w.gravity
		p.vel.y *= 0.98
		p.vel.x *= friction
		p.vel.z *= friction
	}
	for &v in p.vel do if abs(v) < 0.003 do v = 0

	// снега прибыло под ногами — поднимаемся на его верх
	if top, _, support, ok := snow_underfoot(p, w); ok && p.on_ground && p.pos.y > top - 0.05 && p.pos.y < top + support - 0.005 {
		p.pos.y = min(top + support, p.pos.y + 0.05)
	}
	p.in_water = in_water_check(w, p.pos, character_height(p))

	// --- анимация ---
	dx := f32(p.pos.x - p.prev_pos.x)
	dy := f32(p.pos.y - p.prev_pos.y)
	dz := f32(p.pos.z - p.prev_pos.z)
	dist := math.sqrt(dx * dx + dz * dz)
	stroke := p.swimming ? math.sqrt(dx * dx + dy * dy + dz * dz) : dist // при плавании считается и вертикаль

	p.limb_speed += (min(stroke * 4, 1) - p.limb_speed) * 0.4
	p.limb_pos += p.limb_speed

	// корпус поворачивается в сторону движения, голова — куда смотрит камера
	target := p.body_yaw
	if dist * dist > 0.0025 {
		move_yaw := math.atan2(dz, dx) - math.PI / 2
		if abs(eng.wrap_angle(p.yaw - move_yaw)) > math.to_radians(f32(95)) do move_yaw += math.PI
		target = move_yaw
	}
	p.body_yaw += eng.wrap_angle(target - p.body_yaw) * 0.3
	rel := clamp(eng.wrap_angle(p.yaw - p.body_yaw), -math.to_radians(f32(75)), math.to_radians(f32(75)))
	p.body_yaw = p.yaw - rel
	if abs(rel) > math.to_radians(f32(50)) do p.body_yaw += rel * 0.2

	p.walk_dist += dist * 0.6
	p.bob += ((p.on_ground ? min(0.1, dist) : 0) - p.bob) * 0.4
	p.air += ((!p.on_ground && !p.in_water ? f32(1) : 0) - p.air) * 0.5
	p.crouch += ((p.sneaking && !p.in_water && !p.swimming ? f32(1) : 0) - p.crouch) * 0.5
	p.land *= 0.55
	if p.on_ground && !was_on_ground && vy_before < -0.25 {
		p.land = min(1, f32(-vy_before) / 0.7)
	}
	eye_target: f32 = EYE_HEIGHT
	if p.sneaking do eye_target = SNEAK_EYE_HEIGHT
	if p.swimming do eye_target = SWIM_EYE_HEIGHT
	p.eye_h += (eye_target - p.eye_h) * 0.5
	p.swim = p.swimming ? min(1, p.swim + 0.09) : max(0, p.swim - 0.09)
	p.tread += ((p.in_water && !p.swimming ? f32(1) : 0) - p.tread) * 0.25
	p.fov_mod += ((p.sprinting ? f32(1.15) : 1) - p.fov_mod) * 0.5
	p.wave += ((p.wave_ticks > 0 ? f32(1) : 0) - p.wave) * 0.35
	if p.wave_ticks > 0 do p.wave_ticks -= 1
	p.age += 1
}

// Персонажи мягко расталкивают друг друга, если их коробки пересеклись
// (та же формула, что у сущностей в Minecraft).
character_push_apart :: proc(a, b: ^Character) {
	ba, bb := character_box(a.pos, character_height(a)), character_box(b.pos, character_height(b))
	for i in 0 ..< 3 {
		if ba.max[i] <= bb.min[i] || ba.min[i] >= bb.max[i] do return
	}
	dx := b.pos.x - a.pos.x
	dz := b.pos.z - a.pos.z
	d := max(abs(dx), abs(dz))
	if d < 0.01 do return
	d = math.sqrt(d)
	k := min(1 / d, 1) * 0.05 / d
	a.vel.x -= dx * k
	a.vel.z -= dz * k
	b.vel.x += dx * k
	b.vel.z += dz * k
}

look_dir :: proc(yaw, pitch: f32) -> [3]f32 {
	cp := math.cos(pitch)
	return {-math.sin(yaw) * cp, -math.sin(pitch), math.cos(yaw) * cp}
}

character_render_pos :: proc(p: ^Character, t: f32) -> [3]f64 {
	return p.prev_pos + (p.pos - p.prev_pos) * f64(t)
}

// Снег под ногами: верх блока, на котором стоим, глубина снега на нём и на
// сколько он держит (snow.odin).
snow_underfoot :: proc(p: ^Character, w: ^World) -> (top, depth, support: f64, ok: bool) {
	return snow_at_feet(w, p.pos)
}

snow_at_feet :: proc(w: ^World, pos: [3]f64) -> (top, depth, support: f64, ok: bool) {
	if w.snow == nil do return
	x, z := i32(math.floor(pos.x)), i32(math.floor(pos.z))
	y := i32(math.floor(pos.y - 0.01))
	for _ in 0 ..< SNOW_BELOW {
		if world_is_solid(w, x, y, z) {
			depth, support = snow_on_block(w, x, y, z)
			return f64(y + 1), depth, support, true
		}
		y -= 1
	}
	return
}
