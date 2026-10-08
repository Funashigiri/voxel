package main

// Спутники игрока и приказы им.
//   «За мной»  — идут следом, держатся в 2–4 блоках, догоняют бегом.
//   «Стой»     — ждут на месте.
//   «Иди туда» — идут в указанную точку и ждут там.
// Пока ждут — оглядываются, смотрят на игрока, иногда переступают с места на место.

import "core:math"
import "core:slice"
import eng "engine"

SQUAD_SIZE :: 2

FOLLOW_START :: 4.0 // дальше этого — начинают идти за игроком
FOLLOW_STOP :: 2.5 // ближе этого — останавливаются
FOLLOW_SPRINT :: 8.0 // дальше этого — бегут
FOLLOW_TELEPORT :: 24.0 // дальше этого — "догоняют" телепортом
LOOK_AT_PLAYER :: 8.0
WANDER_RADIUS :: 2

Order :: enum u8 {
	Follow,
	Hold,
	Go_To,
}

Companion :: struct {
	body:         Character,
	skin_tex:     u32,
	color:        [3]u8,
	order:        Order,
	home:         [3]f64, // где ждать (Hold / Go_To после прибытия)
	goal:         Cell, // цель приказа Go_To
	arrived:      bool,
	path:         [dynamic]Cell,
	path_i:       int,
	path_goal:    Cell,
	walking:      bool,
	stroll:       bool, // неспешный шаг (переминаются, пока ждут)
	repath_ticks: i32,
	stuck_ticks:  i32,
	progress_pos: [3]f64,
	look_yaw:     f32,
	look_pitch:   f32,
	look_timer:   i32,
	wander_timer: i32,
	rng:          u32,
	light:        f32, // для отрисовки
	marker:       f32, // видимость метки цели 0..1
	held:         bool, // управляется сценой посадки, а не ИИ
}

Squad :: struct {
	members:  [SQUAD_SIZE]Companion,
	selected: [SQUAD_SIZE]bool,
}

SQUAD_PALETTES := [SQUAD_SIZE]Skin_Palette {
	{hair = {205, 160, 82, 255}, skin = {226, 182, 142, 255}, eyes = {58, 112, 62, 255}, shirt = {52, 96, 178, 255}, pants = {60, 62, 76, 255}, boots = {44, 36, 30, 255}},
	{hair = {36, 30, 28, 255}, skin = {178, 126, 90, 255}, eyes = {74, 52, 32, 255}, shirt = {64, 134, 58, 255}, pants = {98, 80, 56, 255}, boots = {50, 38, 30, 255}},
}

@(private = "file")
rand01 :: proc(c: ^Companion) -> f32 {
	c.rng ~= c.rng << 13
	c.rng ~= c.rng >> 17
	c.rng ~= c.rng << 5
	return f32(c.rng >> 8) / f32(1 << 24)
}

@(private = "file")
turn_towards :: proc(from, to, max_step: f32) -> f32 {
	d := eng.wrap_angle(to - from)
	return from + clamp(d, -max_step, max_step)
}

@(private = "file")
horizontal_dist :: proc(a, b: [3]f64) -> f64 {
	dx, dz := a.x - b.x, a.z - b.z
	return math.sqrt(dx * dx + dz * dz)
}

// Клетка под ногами (если персонаж в прыжке — ближайшая опора под ним).
@(private = "file")
ground_cell :: proc(w: ^World, pos: [3]f64) -> Cell {
	c := cell_of(pos)
	for _ in 0 ..< 4 {
		if standable(w, c) do return c
		c.y -= 1
	}
	return cell_of(pos)
}

@(private = "file")
place_at :: proc(c: ^Companion, cell: Cell) {
	b := &c.body
	b.pos = cell_center(cell)
	b.prev_pos = b.pos
	b.vel = {}
	clear(&c.path)
	c.walking = false
	c.stuck_ticks = 0
	c.progress_pos = b.pos
}

@(private = "file")
path_to :: proc(c: ^Companion, w: ^World, goal: Cell) {
	start := ground_cell(w, c.body.pos)
	p, _ := find_path(w, start, goal, context.temp_allocator)
	smooth_path(w, start, &p)
	clear(&c.path)
	append(&c.path, ..p[:])
	c.path_i = 0
	c.path_goal = goal
	c.walking = len(c.path) > 0
	c.repath_ticks = 20
	c.stuck_ticks = 0
	c.progress_pos = c.body.pos
}

// Телепорт за спину игроку (как прирученные волки в Minecraft).
@(private = "file")
teleport_near :: proc(c: ^Companion, w: ^World, player: ^Character) -> bool {
	back := look_dir(player.yaw, 0)
	near := cell_of(player.pos) - Cell{i32(math.round(back.x * 2)), 0, i32(math.round(back.z * 2))}
	if cell, ok := find_stand_cell(w, near, 2); ok {
		place_at(c, cell)
		return true
	}
	return false
}

squad_init :: proc(s: ^Squad, w: ^World, player: ^Character, seed: u32) {
	fwd := look_dir(player.yaw, 0)
	right := [3]f32{-fwd.z, 0, fwd.x}
	for &c, i in s.members {
		skin := skin_generate(SQUAD_PALETTES[i])
		c.skin_tex = skin_texture_create(&skin)
		c.color = SQUAD_PALETTES[i].shirt.rgb
		c.rng = eng.hash_u32(seed + u32(i) * 7919) | 1
		c.light = 1
		c.order = .Follow

		side: f32 = i == 0 ? -1.5 : 1.5
		spot := fwd * 2.5 + right * side
		near := cell_of(player.pos) + Cell{i32(math.round(spot.x)), 0, i32(math.round(spot.z))}
		cell, ok := find_stand_cell(w, near, 3)
		if !ok do cell = cell_of(player.pos)
		character_spawn(&c.body, w, cell_center(cell))
		c.body.interp_look = true
		// смотрят на игрока
		to := player.pos - c.body.pos
		c.body.yaw = math.atan2(f32(-to.x), f32(to.z))
		c.body.prev_yaw = c.body.yaw
		c.body.body_yaw = c.body.yaw
		c.body.prev_body_yaw = c.body.yaw
		c.look_yaw = c.body.yaw
		c.home = c.body.pos
		c.wander_timer = 100
		s.selected[i] = true
	}
}

squad_destroy :: proc(s: ^Squad) {
	for &c in s.members do delete(c.path)
}

squad_select :: proc(s: ^Squad, index: int) {
	for i in 0 ..< SQUAD_SIZE do s.selected[i] = index < 0 || i == index
}

@(private = "file")
stand_cell_not_taken :: proc(w: ^World, near: Cell, taken: []Cell) -> (Cell, bool) {
	for r in i32(0) ..= 2 {
		for dy in i32(-1) ..= 1 do for dz in -r ..= r do for dx in -r ..= r {
			if max(abs(dx), abs(dz)) != r do continue
			c := near + Cell{dx, dy, dz}
			if standable(w, c) && !slice.contains(taken, c) do return c, true
		}
	}
	return near, false
}

// Отдаёт приказ выбранным спутникам. target нужен только для Go_To.
squad_order :: proc(s: ^Squad, w: ^World, player: ^Character, order: Order, target: Cell = {}) {
	count := 0
	for sel in s.selected do if sel do count += 1
	fwd := look_dir(player.yaw, 0)
	right := [3]f64{f64(-fwd.z), 0, f64(fwd.x)}
	taken: [SQUAD_SIZE]Cell
	k := 0
	for &c, i in s.members {
		if !s.selected[i] do continue
		c.order = order
		c.walking = false
		c.stroll = false
		clear(&c.path)
		c.stuck_ticks = 0
		c.wander_timer = 80 + i32(rand01(&c) * 80)
		c.body.wave_ticks = 16
		switch order {
		case .Follow:
			c.arrived = false
		case .Hold:
			c.home = c.body.pos
			c.arrived = true
		case .Go_To:
			// несколько спутников встают рядом, а не друг в друга
			offset := (f64(k) - f64(count - 1) / 2) * 1.6
			p := cell_center(target) + right * offset
			goal, ok := stand_cell_not_taken(w, cell_of(p), taken[:k])
			if !ok do goal = target
			taken[k] = goal
			c.goal = goal
			c.arrived = false
			c.marker = 1
			path_to(&c, w, goal)
		}
		k += 1
	}
}

// Ведёт персонажа по пути. Возвращает true, когда путь пройден.
@(private = "file")
follow_path :: proc(c: ^Companion, w: ^World, input: ^Move_Input, sprint: bool) -> bool {
	b := &c.body
	for c.path_i < len(c.path) {
		wp := c.path[c.path_i]
		tgt := cell_center(wp)
		dx, dz := tgt.x - b.pos.x, tgt.z - b.pos.z
		hd := math.sqrt(dx * dx + dz * dz)
		last := c.path_i == len(c.path) - 1
		reach := last ? 0.3 : 0.5
		if hd < reach && abs(b.pos.y - tgt.y) < 1.2 {
			c.path_i += 1
			continue
		}

		desired := math.atan2(f32(-dx), f32(dz))
		b.yaw = turn_towards(b.yaw, desired, math.to_radians(f32(35)))
		b.pitch = turn_towards(b.pitch, 0.15, math.to_radians(f32(8)))
		off := abs(eng.wrap_angle(desired - b.yaw))
		input.forward = off < 1.2 ? 1 : 0.2
		if last && hd < 1 do input.forward = clamp(f32(hd) * 1.5, 0.3, 1)
		if c.stroll do input.forward *= 0.45
		input.sprint = sprint && !c.stroll && hd > 2
		// на длинном прямом участке — бег с прыжками, как делают игроки
		if input.sprint && hd > 4 && b.on_ground && off < 0.3 do input.jump = true

		// глубокая вода — плывут (бег в воде), держась у поверхности
		deep := b.in_water && (is_water_at(w, b.pos - {0, 0.8, 0}) || is_water_at(w, b.pos + {0, EYE_HEIGHT, 0}))
		if (deep || b.swimming) && hd > 1.5 && !c.stroll do input.sprint = true
		if b.swimming {
			want_y := tgt.y + (is_water_at(w, tgt + {0, 0.2, 0}) ? 0.45 : 0)
			aim := -math.atan2(f32(want_y - b.pos.y), f32(max(hd, 1)))
			b.pitch = turn_towards(b.pitch, clamp(aim, -0.4, 0.4), math.to_radians(f32(8)))
			input.jump = b.h_collision && tgt.y > b.pos.y // выбраться на берег
			return false
		}

		if tgt.y > b.pos.y + 0.5 && hd < 1.8 do input.jump = true
		if b.h_collision && b.on_ground do input.jump = true
		if b.in_water && tgt.y >= b.pos.y - 0.6 do input.jump = true
		return false
	}
	return true
}

// Взгляд и мелкие движения, пока спутник никуда не идёт.
@(private = "file")
idle :: proc(c: ^Companion, w: ^World, player: ^Character) {
	b := &c.body
	eye := b.pos + [3]f64{0, EYE_HEIGHT, 0}
	peye := player.pos + [3]f64{0, f64(player.eye_h), 0}
	to := peye - eye
	dist := math.sqrt(to.x * to.x + to.y * to.y + to.z * to.z)
	if dist < LOOK_AT_PLAYER {
		hd := math.sqrt(to.x * to.x + to.z * to.z)
		c.look_yaw = math.atan2(f32(-to.x), f32(to.z))
		c.look_pitch = -math.atan2(f32(to.y), f32(hd))
		if dist < 4 do b.body_yaw = eng.lerp_angle(b.body_yaw, c.look_yaw, 0.12) // разворачиваются к игроку
		c.look_timer = 0
	} else {
		c.look_timer -= 1
		if c.look_timer <= 0 {
			c.look_yaw = b.body_yaw + (rand01(c) * 2 - 1) * 1.1
			c.look_pitch = rand01(c) * 0.55 - 0.2
			c.look_timer = 40 + i32(rand01(c) * 80)
		}
	}
	b.yaw = turn_towards(b.yaw, c.look_yaw, math.to_radians(f32(12)))
	b.pitch = turn_towards(b.pitch, c.look_pitch, math.to_radians(f32(8)))

	// переступить на шаг-другой рядом с точкой ожидания
	if c.order == .Follow do return
	c.wander_timer -= 1
	if c.wander_timer > 0 do return
	c.wander_timer = 100 + i32(rand01(c) * 160)
	if rand01(c) > 0.55 do return
	home := cell_of(c.home)
	dx := i32(rand01(c) * (2 * WANDER_RADIUS + 1)) - WANDER_RADIUS
	dz := i32(rand01(c) * (2 * WANDER_RADIUS + 1)) - WANDER_RADIUS
	if cell, ok := find_stand_cell(w, home + Cell{dx, 0, dz}, 0); ok && cell != ground_cell(w, b.pos) {
		path_to(c, w, cell)
		c.stroll = true
	}
}

@(private = "file")
is_water_at :: proc(w: ^World, pos: [3]f64) -> bool {
	b, _ := world_get_block(w, i32(math.floor(pos.x)), i32(math.floor(pos.y)), i32(math.floor(pos.z)))
	return b == .Water
}

@(private = "file")
companion_tick :: proc(c: ^Companion, w: ^World, player: ^Character) {
	b := &c.body
	b.prev_yaw = b.yaw
	b.prev_pitch = b.pitch
	// чанк выгружен — спутник "замирает", как сущности в Minecraft
	if world_frame_chunk(w, eng.floor_div(i32(math.floor(b.pos.x)), CHUNK_SIZE), eng.floor_div(i32(math.floor(b.pos.z)), CHUNK_SIZE)) == nil {
		b.prev_pos = b.pos
		return
	}

	input: Move_Input
	pdist := horizontal_dist(b.pos, player.pos)

	switch c.order {
	case .Follow:
		if pdist > FOLLOW_TELEPORT || (c.stuck_ticks > 60 && pdist > 6) {
			teleport_near(c, w, player)
		}
		if c.walking {
			if pdist < FOLLOW_STOP {
				c.walking = false
			} else {
				c.repath_ticks -= 1
				player_cell := ground_cell(w, player.pos)
				moved := player_cell - c.path_goal
				if c.repath_ticks <= 0 && (abs(moved.x) + abs(moved.y) + abs(moved.z) > 1 || c.stuck_ticks > 30) {
					path_to(c, w, player_cell)
				}
			}
		} else if pdist > FOLLOW_START {
			c.stroll = false
			path_to(c, w, ground_cell(w, player.pos))
		}
	case .Go_To:
		if !c.arrived && !c.walking {
			c.arrived = true
			c.home = b.pos
		}
	case .Hold:
	}

	if c.walking {
		if c.order == .Go_To && !c.arrived && c.stuck_ticks == 40 do path_to(c, w, c.goal)
		if c.order != .Follow && c.stuck_ticks > 120 do c.walking = false // не выходит — ждём тут
		if c.walking && follow_path(c, w, &input, c.order == .Follow && pdist > FOLLOW_SPRINT) {
			c.walking = false
			c.stroll = false
		}
	}
	if !c.walking do idle(c, w, player)
	if c.order == .Go_To && !c.arrived {
		c.marker = 1
	} else {
		c.marker = max(0, c.marker - 0.05)
	}

	character_tick(b, w, input)

	// застрял?
	if c.walking {
		if horizontal_dist(b.pos, c.progress_pos) > 0.5 || abs(b.pos.y - c.progress_pos.y) > 0.9 {
			c.progress_pos = b.pos
			c.stuck_ticks = 0
		} else {
			c.stuck_ticks += 1
		}
	} else {
		c.stuck_ticks = 0
		c.progress_pos = b.pos
	}
}

squad_tick :: proc(s: ^Squad, w: ^World, player: ^Character) {
	for &c in s.members do if !c.held do companion_tick(&c, w, player)
	for i in 0 ..< SQUAD_SIZE {
		if s.members[i].held do continue
		character_push_apart(player, &s.members[i].body)
		for j in i + 1 ..< SQUAD_SIZE do if !s.members[j].held do character_push_apart(&s.members[i].body, &s.members[j].body)
	}
}
