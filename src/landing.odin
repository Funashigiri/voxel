package main

// Высадка на планету. Никакой отдельной сцены — обычная игра:
//  * игрок и двое спутников падают в одноместных капсулах с ~360 м;
//    спутники летят слева и справа, их видно;
//  * камера — от третьего лица вокруг своей капсулы, мышью можно оглядываться,
//    WASD немного уводят капсулу в сторону;
//  * парашют пытается раскрыться сам, но его срывает, и он улетает;
//  * после удара управления нет: люк открывается, персонаж выскакивает,
//    отбегает, разворачивается — а капсула схлопывается в точку, как в чёрную
//    дыру, не оставляя ничего, кроме выжженной воронки;
//  * когда своя капсула исчезла, игрок получает управление.

import "core:math"
import eng "engine"

DROP_ALTITUDE :: 360.0 // блоков над землёй
DROP_START_SPEED :: 18.0
DROP_TERMINAL :: 24.0
DROP_GRAVITY :: 9.8
DRIFT_SPEED :: 5.0 // боковой увод капсулы, блоков в секунду
SQUAD_SIDE :: 8.0 // спутники летят слева и справа (в кадре)
CHUTE_GROW :: 0.35
CHUTE_HOLD :: 1.25 // столько держится раскрытый парашют, потом его срывает
CHUTE_SPEED :: 11.0
HATCH_DELAY :: 0.3
HATCH_TIME :: 0.22
EXIT_DIST :: 4.6
EXIT_TIMEOUT :: 3.5 // если не выбрался за это время — дальше без этого
COLLAPSE_AFTER :: 1.6 // капсула схлопывается не позже, чем через столько после выхода
COLLAPSE_START_DIST :: 2.0
COLLAPSE_TIME :: 1.5
HOLE_FADE :: 0.35
ORBIT_DIST :: 7.5

Pod_State :: enum u8 {
	Falling,
	Landed,
	Open,
	Collapsing,
	Gone,
}

Chute_State :: enum u8 {
	Packed,
	Open,
	Torn,
	Gone,
}

Pod :: struct {
	rider:      ^Character,
	companion:  ^Companion, // nil — капсула игрока
	state:      Pod_State,
	t:          f32, // время в текущем состоянии
	pos, vel:   [3]f64, // pos — низ капсулы
	yaw:        f32, // куда смотрит люк
	tilt:       [2]f32,
	hatch:      f32,
	formation:  [3]f64, // смещение от капсулы игрока
	deploy_alt: f64,
	chute:      Chute_State,
	chute_t:    f32,
	chute_pos:  [3]f64,
	chute_vel:  [3]f64,
	chute_rot:  [3]f32,
	chute_spin: [3]f32,
	splashed:   bool,
	floating:   bool, // качается на глубокой воде
	float_y:    f64,
	ground_y:   f64, // уровень земли под капсулой
	tilt_base:  [2]f32, // наклон по склону
	path:       [24]Cell, // путь выхода (найден поиском пути)
	path_n:     int,
	wp:         int,
	exit_goal:  [3]f64,
	rider_out:  bool,
	exit_t:     f32, // сколько персонаж уже выбирается (страховка от застревания)
	arrived:    bool,
	turn_t:     f32,
	released:   bool,
	hole:       Black_Hole,
	collapse:   f32,
	acc:        [4]f32, // накопители для частиц
}

Landing :: struct {
	active:    bool, // игрок ещё без управления
	pods:      [1 + SQUAD_SIZE]Pod,
	cam_yaw:   f32,
	cam_pitch: f32,
	cam_from:  [3]f64, // откуда камера переходит к обычной
	cam_from_yaw, cam_from_pitch: f32,
	cam_blend: f32,
	shake:     f32,
	particles: Particles,
	rng:       eng.Rng,
}

@(private = "file")
rand :: proc(l: ^Landing, lo, hi: f32) -> f32 {
	return f32(eng.rng_range(&l.rng, f64(lo), f64(hi)))
}

@(private = "file")
rand_dir :: proc(l: ^Landing) -> [3]f32 {
	for {
		v := [3]f32{rand(l, -1, 1), rand(l, -1, 1), rand(l, -1, 1)}
		d := v.x * v.x + v.y * v.y + v.z * v.z
		if d > 0.01 && d <= 1 do return v / math.sqrt(d)
	}
}

@(private = "file")
v3 :: proc(v: [3]f32) -> [3]f64 {return {f64(v.x), f64(v.y), f64(v.z)}}

@(private = "file")
is_foliage :: proc(b: Block) -> bool {
	return BLOCK_INFO[b].render == .Leaves || b == .Oak_Log || b == .Birch_Log || is_plant(b)
}

// Верх земли под точкой (без листвы, брёвен, травы и воды), ищем от y вниз.
@(private = "file")
terrain_top :: proc(w: ^World, x, z: i32, from_y: i32) -> i32 {
	for y := min(from_y, CHUNK_HEIGHT - 1); y > 0; y -= 1 {
		b, loaded := world_get_block(w, x, y, z)
		if !loaded do return y // незагруженное — считаем землёй
		if b == .Air || b == .Water || is_foliage(b) do continue
		return y
	}
	return 0
}

// Уровень земли под капсулой (самая высокая точка под её основанием).
@(private = "file")
ground_under :: proc(w: ^World, pos: [3]f64) -> f64 {
	top: i32 = 0
	from := i32(math.floor(pos.y))
	for dz in ([2]f64{-0.8, 0.8}) do for dx in ([2]f64{-0.8, 0.8}) {
		top = max(top, terrain_top(w, i32(math.floor(pos.x + dx)), i32(math.floor(pos.z + dz)), from))
	}
	top = max(top, terrain_top(w, i32(math.floor(pos.x)), i32(math.floor(pos.z)), from))
	return f64(top + 1)
}

landing_create :: proc(w: ^World, player: ^Character, s: ^Squad, site: [3]f64, seed: u32) -> (l: Landing) {
	l.active = true
	l.rng = eng.rng_make(u64(seed) * 131 + 17)
	l.cam_yaw = rand(&l, -math.PI, math.PI)
	l.cam_pitch = 0.45
	f := look_dir(l.cam_yaw, 0)
	fwd := [3]f64{f64(f.x), 0, f64(f.z)}
	right := [3]f64{-fwd.z, 0, fwd.x}
	offsets := [1 + SQUAD_SIZE][3]f64{{0, 0, 0}, -right * SQUAD_SIDE + fwd * 5 + {0, 6, 0}, right * SQUAD_SIDE + fwd * 3 + {0, -4, 0}}
	for &pod, i in l.pods {
		pod.rider = i == 0 ? player : &s.members[i - 1].body
		if i > 0 {
			pod.companion = &s.members[i - 1]
			pod.companion.held = true
		}
		pod.formation = offsets[i]
		pod.pos = site + {0, DROP_ALTITUDE, 0} + offsets[i]
		pod.vel = {0, -DROP_START_SPEED, 0}
		pod.yaw = l.cam_yaw
		pod.deploy_alt = f64(rand(&l, 190, 235))
		pod.rider.interp_look = true
	}
	return
}

// Мгновенно в конечное состояние (флаг -nointro, отладка).
landing_skip :: proc(l: ^Landing, s: ^Squad, player: ^Character) {
	for &pod in l.pods {
		pod.state = .Gone
		pod.rider_out = true
		pod.released = true
	}
	for &c in s.members do c.held = false
	player.interp_look = false
	l.active = false
}

@(private = "file")
emit :: proc(l: ^Landing, p: Particle) {
	particles_emit(&l.particles, p)
}

// Небольшая воронка от одноместной капсулы.
@(private = "file")
apply_crater :: proc(w: ^World, cx, cz: i32, top: i32) {
	for dz in i32(-4) ..= 4 do for dx in i32(-4) ..= 4 {
		x, z := cx + dx, cz + dz
		d := math.sqrt(f32(dx * dx + dz * dz)) + (eng.hash2f(x, z, 4242) - 0.5) * 1.0
		if d > 4 do continue
		t := terrain_top(w, x, z, top + 12)
		if abs(t - top) > 2 do continue // склон: не выгрызаем гору
		for y in t + 1 ..= t + 4 {
			b, _ := world_get_block(w, x, y, z)
			if is_plant(b) || BLOCK_INFO[b].render == .Leaves do world_set_block(w, x, y, z, .Air)
		}
		roll := eng.hash2f(x, z, 4343)
		switch {
		case d < 1.3:
			world_set_block(w, x, t, z, .Air)
			world_set_block(w, x, t - 1, z, .Scorched)
		case d < 2.6:
			world_set_block(w, x, t, z, .Scorched)
		case d < 3.8:
			if roll < 0.4 {
				world_set_block(w, x, t, z, .Scorched)
			} else if roll < 0.8 {
				b, _ := world_get_block(w, x, t, z)
				if b == .Grass do world_set_block(w, x, t, z, .Dirt)
			}
		}
	}
}

// Поверхность воды над точкой (с учётом того, что вода ниже блока на 2/16).
@(private = "file")
water_surface :: proc(w: ^World, pos: [3]f64) -> f64 {
	x, z := i32(math.floor(pos.x)), i32(math.floor(pos.z))
	y := i32(math.floor(pos.y))
	for {
		b, _ := world_get_block(w, x, y + 1, z)
		if b != .Water do break
		y += 1
	}
	return f64(y) + 0.875
}

@(private = "file")
splash :: proc(l: ^Landing, at: [3]f64, power: f32) {
	for _ in 0 ..< int(90 * power) {
		d := rand_dir(l)
		d.y = abs(d.y) * 1.6 + 0.6
		emit(l, {
			pos = at + v3({d.x, 0, d.z}) * 0.8, vel = d * rand(l, 3, 8) * power, life = rand(l, 0.7, 1.4),
			size0 = 0.32, size1 = 0.22, color0 = {190, 215, 245, 230}, color1 = {220, 235, 255, 0},
			gravity = 14, drag = 0.4,
		})
	}
	// пена по кругу
	for _ in 0 ..< int(40 * power) {
		a := rand(l, 0, 2 * math.PI)
		dir := [3]f32{math.cos(a), 0, math.sin(a)}
		emit(l, {
			pos = at + v3(dir) * 1.0 + {0, 0.05, 0}, vel = dir * rand(l, 1.5, 3.5), life = rand(l, 1.2, 2.2),
			size0 = 0.5, size1 = 1.4, color0 = {235, 242, 250, 200}, color1 = {235, 242, 250, 0}, drag = 2,
		})
	}
}

// Ищем, куда персонаж реально может выбежать: пробуем направления, начиная
// с обращённого к камере, и проверяем поиском пути. Люк откроется туда.
@(private = "file")
plan_exit :: proc(pod: ^Pod, w: ^World) {
	start := cell_of(pod.pos + {0, 0.2, 0})
	if !standable(w, start) {
		if c, ok := find_stand_cell(w, start, 1); ok do start = c
	}
	prefer := pod.yaw
	turns := [8]f32{0, 0.785, -0.785, 1.571, -1.571, 2.356, -2.356, math.PI}
	for o in turns {
		yaw := prefer + o
		f := look_dir(yaw, 0)
		target := pod.pos + [3]f64{f64(f.x), 0, f64(f.z)} * EXIT_DIST
		goal, ok := find_stand_cell(w, cell_of(target + {0, 1, 0}), 2)
		if !ok do continue
		path, reached := find_path(w, start, goal, context.temp_allocator)
		if !reached || len(path) > 16 do continue
		smooth_path(w, start, &path)
		pod.yaw = yaw
		pod.path_n = min(len(path), len(pod.path))
		for i in 0 ..< pod.path_n do pod.path[i] = path[i]
		pod.exit_goal = cell_center(goal)
		return
	}
	// пути нет — побежит как сможет, а страховка по времени не даст застрять
	f := look_dir(prefer, 0)
	pod.path_n = 0
	pod.exit_goal = pod.pos + [3]f64{f64(f.x), 0, f64(f.z)} * EXIT_DIST
}

// Наклон капсулы по склону под ней.
@(private = "file")
slope_tilt :: proc(pod: ^Pod, w: ^World) -> [2]f32 {
	f := look_dir(pod.yaw, 0)
	fwd := [3]f64{f64(f.x), 0, f64(f.z)}
	right := [3]f64{-fwd.z, 0, fwd.x}
	from := i32(math.floor(pod.pos.y)) + 3
	h :: proc(w: ^World, p: [3]f64, from: i32) -> f32 {
		return f32(terrain_top(w, i32(math.floor(p.x)), i32(math.floor(p.z)), from))
	}
	hf, hb := h(w, pod.pos + fwd * 0.8, from), h(w, pod.pos - fwd * 0.8, from)
	hr, hl := h(w, pod.pos + right * 0.8, from), h(w, pod.pos - right * 0.8, from)
	return {clamp(math.atan2(hb - hf, 1.6), -0.35, 0.35), clamp(math.atan2(hl - hr, 1.6), -0.35, 0.35)}
}

@(private = "file")
impact :: proc(l: ^Landing, pod: ^Pod, w: ^World, cam_pos: [3]f64) {
	pod.state = .Landed
	pod.t = 0
	cx := i32(math.floor(pod.pos.x))
	cz := i32(math.floor(pod.pos.z))
	if pod.splashed {
		pod.pos.y = pod.ground_y // мель: на дно, без воронки
	} else {
		top := i32(pod.ground_y) - 1
		apply_crater(w, cx, cz, top)
		pod.pos.y = f64(top) - 0.1 // выбит верхний блок
	}
	pod.vel = {}
	plan_exit(pod, w)
	pod.tilt_base = slope_tilt(pod, w)

	base := pod.pos + {0, 0.4, 0}
	if pod.splashed {
		splash(l, {pod.pos.x, pod.float_y + 1.15, pod.pos.z}, 0.5)
	} else {
		// пыль и комья земли
		for _ in 0 ..< 60 {
			d := rand_dir(l)
			d.y = abs(d.y) * 0.6
			emit(l, {
				pos = base + v3(d) * 0.9, vel = d * rand(l, 2.5, 7) + {0, rand(l, 1, 4), 0},
				life = rand(l, 1.2, 2.4), size0 = rand(l, 0.4, 0.8), size1 = rand(l, 1.4, 2.0),
				color0 = {112, 98, 84, 170}, color1 = {150, 142, 134, 0}, gravity = 1.2, drag = 1.8,
			})
		}
		for _ in 0 ..< 25 {
			d := rand_dir(l)
			d.y = abs(d.y)
			emit(l, {
				pos = base, vel = d * rand(l, 3, 6) + {0, rand(l, 4, 8), 0}, life = rand(l, 0.9, 1.5),
				size0 = 0.2, size1 = 0.16, color0 = {84, 60, 42, 255}, color1 = {70, 50, 36, 255},
				gravity = 22, drag = 0.3,
			})
		}
	}
	dist := math.sqrt((pod.pos.x - cam_pos.x) * (pod.pos.x - cam_pos.x) + (pod.pos.z - cam_pos.z) * (pod.pos.z - cam_pos.z))
	l.shake = max(l.shake, f32(1.0 / (1 + dist * 0.08)))
}

@(private = "file")
settle :: proc(tau, a, w, base: f32) -> f32 {
	return base + a * math.exp(-tau * 3) * math.sin(tau * w)
}

@(private = "file")
update_pod :: proc(l: ^Landing, pod: ^Pod, i: int, w: ^World, drift: [3]f64, cam_pos: [3]f64, dt: f32) {
	pod.t += dt
	player_pod := &l.pods[0]
	switch pod.state {
	case .Falling:
		// боковой увод: игрок — клавишами, спутники держат строй
		target := drift * DRIFT_SPEED
		if i > 0 {
			want := player_pod.pos + pod.formation
			target = {player_pod.vel.x, 0, player_pod.vel.z} + (want - pod.pos) * 0.6
			target.y = 0
		}
		k := f64(min(1, dt * 1.6))
		pod.vel.x += (target.x - pod.vel.x) * k
		pod.vel.z += (target.z - pod.vel.z) * k
		if pod.chute == .Open {
			pod.vel.y += (-CHUTE_SPEED - pod.vel.y) * f64(min(1, dt * 4))
		} else if pod.splashed {
			pod.vel.y += (-6 - pod.vel.y) * f64(min(1, dt * 5)) // мель: быстро тормозит в воде
			pod.vel.x *= 0.95
			pod.vel.z *= 0.95
		} else {
			pod.vel.y = max(pod.vel.y - DROP_GRAVITY * f64(dt), -DROP_TERMINAL)
		}
		pod.pos += pod.vel * f64(dt)

		// сквозь кроны — ломает листву и брёвна
		for dz in ([3]f64{-0.7, 0, 0.7}) do for dx in ([3]f64{-0.7, 0, 0.7}) {
			x, z := i32(math.floor(pod.pos.x + dx)), i32(math.floor(pod.pos.z + dz))
			for y in i32(math.floor(pod.pos.y)) ..= i32(math.floor(pod.pos.y + 2.8)) {
				b, _ := world_get_block(w, x, y, z)
				if b != .Air && is_foliage(b) {
					world_set_block(w, x, y, z, .Air)
					for _ in 0 ..< 3 {
						emit(l, {
							pos = {f64(x) + 0.5, f64(y) + 0.5, f64(z) + 0.5}, vel = rand_dir(l) * 3 + {0, 2, 0},
							life = rand(l, 0.6, 1.2), size0 = 0.18, size1 = 0.14,
							color0 = {58, 104, 30, 255}, color1 = {50, 90, 26, 255}, gravity = 9, drag = 1,
						})
					}
				}
			}
		}
		// вода: на глубине капсула уходит под воду, всплывает и качается на волнах;
		// на мели — садится на дно (без воронки)
		if !pod.splashed {
			if b, _ := world_get_block(w, i32(math.floor(pod.pos.x)), i32(math.floor(pod.pos.y)), i32(math.floor(pod.pos.z))); b == .Water {
				pod.splashed = true
				surface := water_surface(w, pod.pos)
				pod.float_y = surface - 1.15
				splash(l, {pod.pos.x, surface, pod.pos.z}, 1)
				if ground_under(w, pod.pos) < pod.float_y - 0.5 {
					pod.floating = true
					pod.state = .Landed
					pod.t = 0
					pod.vel.x *= 0.3
					pod.vel.z *= 0.3
					pod.vel.y = max(pod.vel.y * 0.35, -9) // нырнёт и всплывёт
					pod.yaw = l.cam_yaw + math.PI
					plan_exit(pod, w)
					dist := math.sqrt((pod.pos.x - cam_pos.x) * (pod.pos.x - cam_pos.x) + (pod.pos.z - cam_pos.z) * (pod.pos.z - cam_pos.z))
					l.shake = max(l.shake, f32(0.6 / (1 + dist * 0.08)))
					return
				}
			}
		}

		pod.ground_y = ground_under(w, pod.pos)
		alt := pod.pos.y - pod.ground_y

		// парашют: пытается раскрыться, держит пару секунд — и его срывает
		switch pod.chute {
		case .Packed:
			if alt < pod.deploy_alt {
				pod.chute = .Open
				pod.chute_t = 0
				if i == 0 do l.shake = max(l.shake, 0.45)
			}
		case .Open:
			pod.chute_t += dt
			if pod.chute_t >= CHUTE_HOLD {
				pod.chute = .Torn
				pod.chute_t = 0
				pod.chute_pos = pod.pos + {0, f64(POD_TOP), 0}
				pod.chute_vel = pod.vel * 0.6 + {f64(rand(l, -3, 3)), 5, f64(rand(l, -3, 3))}
				pod.chute_spin = {rand(l, -1.5, 1.5), rand(l, -1, 1), rand(l, -1.5, 1.5)}
				if i == 0 do l.shake = max(l.shake, 0.3)
			}
		case .Torn, .Gone:
		}

		// наклон и покачивание повреждённой капсулы
		f := look_dir(pod.yaw, 0)
		fwd := [2]f64{f64(f.x), f64(f.z)}
		along := f32(pod.vel.x * fwd.x + pod.vel.z * fwd.y)
		side := f32(pod.vel.x * -fwd.y + pod.vel.z * fwd.x)
		tt := pod.t + f32(i) * 1.7
		pod.tilt = {-along * 0.035 + math.sin(tt * 5.3) * 0.05, side * 0.035 + math.sin(tt * 4.1) * 0.05}

		if pod.pos.y <= pod.ground_y {
			pod.pos.y = pod.ground_y
			pod.yaw = l.cam_yaw + math.PI // люк — к камере: выскакивают навстречу
			impact(l, pod, w, cam_pos)
		}
	case .Landed:
		pod.tilt = pod.tilt_base + {settle(pod.t, -0.12, 11, 0.04), settle(pod.t, 0.1, 9, -0.05)}
		if pod.t >= (pod.floating ? HATCH_DELAY + 0.5 : HATCH_DELAY) {
			pod.state = .Open
			pod.t = 0
		}
	case .Open:
		pod.hatch = POD_HATCH_OPEN * min(1, (pod.t / HATCH_TIME) * (pod.t / HATCH_TIME))
		if !pod.rider_out && pod.t >= HATCH_TIME * 0.6 do rider_exit(l, pod, w)
		if pod.rider_out {
			dx, dz := pod.rider.pos.x - pod.pos.x, pod.rider.pos.z - pod.pos.z
			// отбежал — или прошло достаточно времени с открытия люка (страховка)
			if math.sqrt(dx * dx + dz * dz) >= COLLAPSE_START_DIST || pod.t >= HATCH_TIME * 0.6 + COLLAPSE_AFTER {
				pod.state = .Collapsing
				pod.t = 0
			}
		}
	case .Collapsing:
		update_collapse(l, pod, dt)
	case .Gone:
	}
	if pod.floating && pod.state != .Falling && pod.state != .Gone {
		// на волнах: всплывает до ватерлинии и покачивается
		pod.vel.y += ((pod.float_y - pod.pos.y) * 30 - pod.vel.y * 3.5) * f64(dt)
		pod.vel.x *= f64(max(0, 1 - dt * 2))
		pod.vel.z *= f64(max(0, 1 - dt * 2))
		pod.pos += pod.vel * f64(dt)
		tt := pod.t + f32(i)
		pod.tilt = {math.sin(tt * 1.3) * 0.08, math.sin(tt * 1.1 + 1) * 0.07}
	}

	// оторванный парашют уносит
	if pod.chute == .Torn {
		pod.chute_t += dt
		pod.chute_vel.y -= 2 * f64(dt)
		pod.chute_vel *= f64(max(0, 1 - 1.1 * dt))
		pod.chute_pos += pod.chute_vel * f64(dt)
		pod.chute_rot += pod.chute_spin * dt
		if pod.chute_t > 7 do pod.chute = .Gone
	}

	// дым и искры от повреждённой капсулы
	if pod.state == .Falling || pod.state == .Landed || pod.state == .Open {
		rate := pod.state == .Falling ? f32(28) : f32(10)
		pod.acc[0] += rate * dt
		for pod.acc[0] >= 1 {
			pod.acc[0] -= 1
			emit_smoke(l, pod)
		}
		pod.acc[1] += 1.2 * dt
		if pod.acc[1] >= 1 {
			pod.acc[1] -= 1
			from := pod.pos + v3(rand_dir(l)) * 0.8 + {0, 1.3, 0}
			for _ in 0 ..< 6 {
				emit(l, {
					pos = from, vel = rand_dir(l) * rand(l, 2, 4) + {0, 2, 0}, life = rand(l, 0.3, 0.6),
					size0 = 0.1, size1 = 0.04, color0 = {255, 230, 140, 255}, color1 = {255, 140, 40, 0},
					gravity = 12, additive = true,
				})
			}
		}
	}
}

@(private = "file")
emit_smoke :: proc(l: ^Landing, pod: ^Pod) {
	up: f64 = pod.state == .Falling ? -pod.vel.y * 0.2 + 1 : f64(rand(l, 1, 2))
	emit(l, {
		pos = pod.pos + {0, 2.4, 0} + v3(rand_dir(l)) * 0.4,
		vel = {rand(l, -0.4, 0.4), f32(up), rand(l, -0.4, 0.4)},
		life = rand(l, 1.6, 2.6), size0 = 0.45, size1 = rand(l, 1.5, 2.2),
		color0 = {78, 76, 74, 150}, color1 = {140, 138, 136, 0}, drag = 0.4,
	})
}

// Персонаж выскакивает из люка и бежит прочь.
@(private = "file")
rider_exit :: proc(l: ^Landing, pod: ^Pod, w: ^World) {
	pod.rider_out = true
	ch := pod.rider
	spawn := pod.pos + {0, 0.15, 0}
	if pod.floating do spawn.y = pod.float_y + 0.75 // выбирается прямо в воду
	character_spawn(ch, w, spawn)
	ch.interp_look = true
	ch.yaw, ch.prev_yaw = pod.yaw, pod.yaw
	ch.body_yaw, ch.prev_body_yaw = pod.yaw, pod.yaw
	ch.pitch, ch.prev_pitch = 0.1, 0.1
	pod.wp = 0
	pod.exit_t = 0
}

// Чёрная дыра: модель закручивается и стягивается в точку, вокруг — линза,
// чёрное ядро, фотонное кольцо и затягиваемое вещество.
@(private = "file")
update_collapse :: proc(l: ^Landing, pod: ^Pod, dt: f32) {
	t := pod.t
	k := min(1, t / COLLAPSE_TIME)
	pod.collapse = math.pow(k, 1.25)
	centre := pod.pos + [3]f64{f64(POD_CENTER.x), f64(POD_CENTER.y), f64(POD_CENTER.z)}
	grow := eng.smoothstep(0, 0.25, k)
	fade := 1 - eng.smoothstep(COLLAPSE_TIME, COLLAPSE_TIME + HOLE_FADE, t)
	pod.hole = {
		center   = centre,
		radius   = 3.4,
		horizon  = (0.09 + 0.06 * eng.smoothstep(0.2, 0.9, k)) * grow * fade,
		strength = grow * fade,
	}
	if k < 1 {
		// аккреционный вихрь: вещество по спирали падает внутрь
		pod.acc[2] += 140 * dt
		for pod.acc[2] >= 1 {
			pod.acc[2] -= 1
			a := rand(l, 0, 2 * math.PI)
			rad := rand(l, 1.8, 3.2)
			off := [3]f32{math.cos(a) * rad, rand(l, -0.25, 0.25), math.sin(a) * rad}
			tangent := [3]f32{-math.sin(a), 0, math.cos(a)} * rand(l, 5, 7)
			hot := rand(l, 0, 1) < 0.5
			emit(l, {
				pos = centre + v3(off), vel = tangent, life = 0.55, size0 = 0.22, size1 = 0.06,
				color0 = hot ? [4]u8{255, 196, 120, 255} : [4]u8{200, 220, 255, 255}, color1 = {255, 255, 255, 0},
				attract = 34, target = centre, additive = true,
			})
		}
		// обломки обшивки затягивает внутрь
		pod.acc[3] += 30 * dt
		for pod.acc[3] >= 1 {
			pod.acc[3] -= 1
			d := rand_dir(l)
			emit(l, {
				pos = centre + v3(d) * f64(rand(l, 0.6, 1.3)) * f64(1 - pod.collapse), vel = {d.z, 0, -d.x} * 3,
				life = 0.5, size0 = 0.16, size1 = 0.04, color0 = {170, 172, 176, 255}, color1 = {40, 40, 44, 255},
				attract = 45, target = centre,
			})
		}
	}
	if t >= COLLAPSE_TIME + HOLE_FADE {
		pod.state = .Gone
		pod.hole.strength = 0
		l.shake = max(l.shake, 0.2)
	}
}

// Кадровое обновление: капсулы, парашюты, эффекты, взгляд мышью.
// drift — направление увода от WASD (в мировых осях, длина до 1).
landing_update :: proc(l: ^Landing, w: ^World, drift: [3]f64, mouse_dx, mouse_dy: f32, cam_pos: [3]f64, dt: f32) {
	if l.active && !l.pods[0].rider_out {
		l.cam_yaw += mouse_dx * MOUSE_SENSITIVITY
		l.cam_pitch = clamp(l.cam_pitch + mouse_dy * MOUSE_SENSITIVITY, -0.4, 1.45)
	}
	for &pod, i in l.pods {
		if pod.state == .Gone && pod.chute != .Torn do continue
		update_pod(l, &pod, i, w, i == 0 ? drift : {}, cam_pos, dt)
	}
	l.shake = max(0, l.shake - dt * 1.6)
	particles_update(&l.particles, dt)
}

// Тик физики: персонажи выбегают по сценарию и отдают управление.
landing_tick :: proc(l: ^Landing, w: ^World) {
	for &pod in l.pods {
		ch := pod.rider
		if pod.released do continue
		if !pod.rider_out {
			// сидит в капсуле: летит вместе с ней (для подгрузки мира и камеры)
			ch.pos = pod.pos + {0, 0.15, 0}
			ch.prev_pos = ch.pos
			continue
		}
		ch.prev_yaw = ch.yaw
		ch.prev_pitch = ch.pitch
		input: Move_Input
		if !pod.arrived {
			pod.exit_t += TICK_DT
			tgt := pod.wp < pod.path_n ? cell_center(pod.path[pod.wp]) : pod.exit_goal
			dx, dz := tgt.x - ch.pos.x, tgt.z - ch.pos.z
			hd := math.sqrt(dx * dx + dz * dz)
			if hd < 0.45 {
				if pod.wp < pod.path_n {
					pod.wp += 1
				} else {
					pod.arrived = true
				}
			} else {
				desired := math.atan2(f32(-dx), f32(dz))
				ch.yaw += clamp(eng.wrap_angle(desired - ch.yaw), -0.5, 0.5)
				input.forward = 1
				input.sprint = !ch.in_water
				input.jump = (ch.h_collision && ch.on_ground) || (tgt.y > ch.pos.y + 0.5 && hd < 1.8)
			}
			if pod.exit_t >= EXIT_TIMEOUT do pod.arrived = true // не выбрался — дальше без этого
		}
		if ch.in_water do input.jump = true // держится на плаву
		turned := false
		if pod.arrived {
			// разворачивается к капсуле
			pod.turn_t += TICK_DT
			look := pod.pos + {0, 1.3, 0} - (ch.pos + {0, EYE_HEIGHT, 0})
			yaw, pitch := yaw_pitch_of(look)
			d := eng.wrap_angle(yaw - ch.yaw)
			ch.yaw += clamp(d, -0.6, 0.6)
			ch.pitch += (pitch - ch.pitch) * 0.35
			turned = abs(d) < 0.15 || pod.turn_t > 1.2
		}
		character_tick(ch, w, input)

		if pod.state == .Gone && turned {
			pod.released = true
			if pod.companion != nil {
				c := pod.companion
				c.held = false
				c.order = .Follow
				c.walking = false
				clear(&c.path)
				c.home = ch.pos
				c.look_yaw = ch.yaw
				c.look_pitch = ch.pitch
			} else {
				ch.interp_look = false
				l.active = false
			}
		}
	}
}

// Камера: пока игрок в капсуле — от третьего лица вокруг неё (мышью можно
// оглядываться), после выхода — плавно переходит в обычную камеру.
landing_camera :: proc(l: ^Landing, cam: ^Camera, player: ^Character, w: ^World, frame_t, aspect, dt: f32) {
	pod := &l.pods[0]
	pos: [3]f64
	yaw, pitch := l.cam_yaw, l.cam_pitch
	if !pod.arrived {
		// пока игрок не отбежал и не развернулся — камера у капсулы
		centre := pod.pos + {0, 1.3, 0}
		d := look_dir(yaw, pitch)
		dir := [3]f64{f64(d.x), f64(d.y), f64(d.z)}
		pos = centre - dir * clip_distance(w, centre, -dir, ORBIT_DIST)
		l.cam_from, l.cam_from_yaw, l.cam_from_pitch = pos, yaw, pitch
		l.cam_blend = 0
	} else {
		game := cam^
		game.mode = .Third_Back
		camera_update(&game, player, w, frame_t, aspect, dt)
		l.cam_blend = min(1, l.cam_blend + dt / 0.5)
		u := eng.smoothstep(0, 1, l.cam_blend)
		pos = l.cam_from + (game.pos - l.cam_from) * f64(u)
		yaw = eng.lerp_angle(l.cam_from_yaw, game.yaw, u)
		pitch = l.cam_from_pitch + (game.pitch - l.cam_from_pitch) * u
		cam.hand_yaw, cam.hand_pitch = game.hand_yaw, game.hand_pitch
		// по пути к обычной камере не проходим сквозь холмы
		eye := character_render_pos(player, frame_t) + {0, f64(player.eye_h), 0}
		to := pos - eye
		dist := math.sqrt(to.x * to.x + to.y * to.y + to.z * to.z)
		if dist > 0.01 do pos = eye + to / dist * clip_distance(w, eye, to / dist, dist)
	}
	if l.shake > 0 {
		s := f64(l.shake * l.shake)
		pos += v3(rand_dir(l)) * s * 0.3
		yaw += rand(l, -1, 1) * l.shake * l.shake * 0.02
		pitch += rand(l, -1, 1) * l.shake * l.shake * 0.02
	}
	cam.pos = pos
	cam.yaw = yaw
	cam.pitch = pitch
	cam.bob = 1
	cam.fov = BASE_FOV
	camera_build_matrices(cam, aspect)
}

// Активные чёрные дыры (для отрисовки линз).
landing_holes :: proc(l: ^Landing) -> []Black_Hole {
	out := make([dynamic]Black_Hole, context.temp_allocator)
	for &pod in l.pods {
		if pod.state == .Collapsing && pod.hole.strength > 0.001 do append(&out, pod.hole)
	}
	return out[:]
}
