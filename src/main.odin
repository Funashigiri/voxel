package main

// Voxel — воксельная игра на Odin с самописным движком (GLFW + OpenGL 3.3).

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import eng "engine"
import "vendor:glfw"

VERSION :: "0.008"
VIEW_RADIUS :: 10 // чанков
MOUSE_SENSITIVITY :: 0.0026 // радиан на пиксель (~0.15°, как в Minecraft)
WORLD_BUDGET :: 0.005 // секунд на генерацию/меши за кадр
ORDER_RANGE :: 128.0 // дальность приказа «Иди туда», блоков

Options :: struct {
	width, height: i32,
	seed:          u32,
	has_seed:      bool, // иначе зерно случайное — каждый запуск новый мир
	start_hour:    f64, // местное время появления
	cam_mode:      Camera_Mode,
	yaw, pitch:    f32, // градусы
	// отладка / автоматические скриншоты
	shot_path:     string,
	shot_delay:    f64,
	walk, sprint:  bool,
	jump, sneak:   bool,
	strafe:        bool,
	burst:         int, // сколько кадров снять подряд
	interval:      f64, // пауза между кадрами серии
	orbit:         f32, // градусы, поворот камеры вокруг игрока
	order:         string, // follow | hold | go — отдать приказ автоматически
	order_at:      f64, // через сколько секунд
	select:        int, // 1, 2 или 3 (оба)
	water_spawn:   bool, // появиться над водой
	mountain_spawn: bool, // появиться над горами
	has_latlon:    bool, // высадка в заданной точке планеты
	lat, lon:      f64,
	debug_page:    int, // сразу открыть страницу F3 (1..3)
	universe_report: bool, // напечатать отчёт о вселенной с проверками и выйти
	no_intro:      bool, // без высадки в капсулах (сразу на земле)
	has_look:      bool, // заданы -yaw / -pitch
	has_yaw:       bool,
	edge_dist:     f64, // > 0: высадка в стольких метрах от ребра грани (тест стыка)
	anomaly_dist:  f64, // > 0: высадка в стольких метрах от вершины куба (тест аномалии)
	selftest:      bool, // проверить геометрию стыков граней и выйти
	dump_textures: string,
}

parse_options :: proc() -> (o: Options) {
	o.width, o.height = 1280, 720
	o.start_hour = 7
	o.cam_mode = .Third_Back
	o.shot_delay = 1.0
	o.burst = 1
	o.order_at = 0.3
	o.interval = 0.1
	for arg in os.args[1:] {
		key, _, val := strings.partition(arg, ":")
		switch key {
		case "-shot":
			o.shot_path = val
		case "-delay":
			o.shot_delay = strconv.parse_f64(val) or_else 1
		case "-cam":
			switch val {
			case "fp":
				o.cam_mode = .First_Person
			case "back":
				o.cam_mode = .Third_Back
			case "front":
				o.cam_mode = .Third_Front
			}
		case "-yaw":
			o.yaw = f32(strconv.parse_f64(val) or_else 0)
			o.has_look, o.has_yaw = true, true
		case "-pitch":
			o.pitch = f32(strconv.parse_f64(val) or_else 0)
			o.has_look = true
		case "-seed":
			if v, ok := strconv.parse_u64(val); ok {
				o.seed = u32(v)
				o.has_seed = true
			}
		case "-time":
			hs, _, ms := strings.partition(val, ":")
			o.start_hour = f64(strconv.parse_int(hs) or_else 7) + f64(strconv.parse_int(ms) or_else 0) / 60
		case "-size":
			ws, _, hs := strings.partition(val, "x")
			o.width = i32(strconv.parse_int(ws) or_else 1280)
			o.height = i32(strconv.parse_int(hs) or_else 720)
		case "-walk":
			o.walk = true
		case "-sprint":
			o.sprint = true
		case "-jump":
			o.jump = true
		case "-sneak":
			o.sneak = true
		case "-strafe":
			o.strafe = true
		case "-burst":
			o.burst = max(1, strconv.parse_int(val) or_else 1)
		case "-order":
			o.order = val
		case "-order_at":
			o.order_at = strconv.parse_f64(val) or_else 0.3
		case "-select":
			o.select = strconv.parse_int(val) or_else 3
		case "-nointro":
			o.no_intro = true
		case "-f3":
			o.debug_page = val == "" ? 1 : clamp(strconv.parse_int(val) or_else 1, 1, 3)
		case "-universe":
			o.universe_report = true
		case "-spawn":
			o.water_spawn = val == "water"
			o.mountain_spawn = val == "mountain"
		case "-latlon":
			las, _, los := strings.partition(val, ",")
			o.lat = strconv.parse_f64(las) or_else 40
			o.lon = strconv.parse_f64(los) or_else 0
			o.has_latlon = true
		case "-selftest":
			o.selftest = true
		case "-edge":
			o.edge_dist = strconv.parse_f64(val) or_else 200
		case "-anomaly":
			o.anomaly_dist = strconv.parse_f64(val) or_else 220
		case "-orbit":
			o.orbit = f32(strconv.parse_f64(val) or_else 0)
		case "-interval":
			o.interval = strconv.parse_f64(val) or_else 0.1
		case "-dump-textures":
			o.dump_textures = val
		}
	}
	return
}

// Приказ «Иди туда»: точка — блок под прицелом (луч из глаз игрока).
order_go_to_aim :: proc(s: ^Squad, w: ^World, player: ^Character) -> bool {
	eye := player.pos + [3]f64{0, f64(player.eye_h), 0}
	d := look_dir(player.yaw, player.pitch)
	hit, _, cell, normal := raycast_solid(w, eye, {f64(d.x), f64(d.y), f64(d.z)}, ORDER_RANGE)
	if !hit do return false
	target, ok := find_stand_cell(w, cell + normal, 1)
	if !ok do return false
	squad_order(s, w, player, .Go_To, target)
	return true
}

handle_squad_keys :: proc(s: ^Squad, w: ^World, player: ^Character) {
	if eng.key_pressed(glfw.KEY_1) do squad_select(s, 0)
	if eng.key_pressed(glfw.KEY_2) do squad_select(s, 1)
	if eng.key_pressed(glfw.KEY_3) do squad_select(s, -1)
	if eng.key_pressed(glfw.KEY_F) do squad_order(s, w, player, .Follow)
	if eng.key_pressed(glfw.KEY_H) do squad_order(s, w, player, .Hold)
	if eng.key_pressed(glfw.KEY_G) do order_go_to_aim(s, w, player)
}

spawn_area_ready :: proc(w: ^World, pos: [3]f64, radius: i32) -> bool {
	cx := eng.floor_div(i32(math.floor(pos.x)), CHUNK_SIZE)
	cz := eng.floor_div(i32(math.floor(pos.z)), CHUNK_SIZE)
	for dz in -radius ..= radius do for dx in -radius ..= radius {
		if _, _, _, ok := world_resolve(w, (cx + dx) * CHUNK_SIZE, (cz + dz) * CHUNK_SIZE); !ok do continue // пустота у вершины
		c := world_frame_chunk(w, cx + dx, cz + dz)
		if c == nil || !c.meshed do return false
	}
	return true
}

main :: proc() {
	opts := parse_options()
	blocks_init()

	if opts.dump_textures != "" {
		ok := dump_textures_png(opts.dump_textures)
		fmt.println(ok ? "textures saved to" : "failed to save", opts.dump_textures)
		return
	}

	if !opts.has_seed {
		opts.seed = eng.hash_u32(u32(time.time_to_unix_nano(time.now())) ~ u32(time.time_to_unix_nano(time.now()) >> 32))
	}

	// вселенная -> наша галактика и звезда -> её система планет
	t0 := time.now()
	universe: Universe
	universe_init(&universe, opts.seed)
	defer universe_destroy(&universe)
	t1 := time.now()
	home := universe_find_home(&universe)
	t2 := time.now()
	system := star_system_generate(opts.seed, home.star, true)
	defer star_system_destroy(&system)
	uinfo := universe_info_build(&universe, home)
	defer universe_info_destroy(&uinfo)
	t3 := time.now()
	fmt.printfln("Мир %d: галактика %s (%s), звезда %s (%s), планета %s, сутки %.1f ч, гравитация %.2f g",
		opts.seed, uinfo.galaxy_name, GALAXY_KIND_NAMES[home.galaxy.kind], system.star.name, STAR_CLASS_NAMES[system.star.class],
		home_planet(&system).name, system.home.day_hours, system.home.gravity_g)
	if opts.universe_report {
		ms :: proc(a, b: time.Time) -> f64 {return time.duration_milliseconds(time.diff(a, b))}
		if universe_report(&universe, &uinfo, opts.seed, ms(t0, t1), ms(t1, t2), ms(t2, t3)) > 0 do os.exit(1)
		return
	}

	if !eng.window_create(fmt.tprintf("Voxel %s", VERSION), opts.width, opts.height) do os.exit(1)
	defer eng.window_destroy()

	clock := clock_init(system.home.day_hours, opts.start_hour)

	r: Renderer
	if !renderer_init(&r, VIEW_RADIUS) do os.exit(1)

	player_skin := skin_load_or_generate("assets/skin.png", PALETTE_PLAYER)
	player_skin_tex := skin_texture_create(&player_skin)
	model := humanoid_model_create()
	capsule := capsule_model_create()

	sky: Sky
	sky_init(&sky, opts.seed)

	// планета-шар реального размера: выбираем грань и точку высадки
	geo := geo_make(home_planet(&system).radius_km)
	lat, lon := system.home.latitude_deg, system.home.longitude_deg
	if opts.has_latlon do lat, lon = opts.lat, opts.lon
	site_x, site_z: f64
	site_x, site_z, lat, lon = geo_choose_site(&geo, lat, lon, opts.seed, opts.has_latlon)
	if errors := geo_check_links(&geo); errors > 0 do fmt.eprintln("ОШИБКА: рёбра граней не стыкуются:", errors)
	if opts.selftest {
		checked, errors := frame_selftest(geo)
		fmt.printfln("selftest: рёбра %d ошибок; смена кадра: %d точек, %d ошибок", geo_check_links(&geo), checked, errors)
		return
	}
	// тесты: высадка у ребра или у вершины; взгляд — в их сторону
	test_yaw, has_test_yaw := f32(0), false
	if opts.edge_dist > 0 || opts.anomaly_dist > 0 {
		n := f64(geo.n)
		if opts.anomaly_dist > 0 {
			cx, cz, _ := geo_nearest_corner(&geo, site_x, site_z)
			d := opts.anomaly_dist / math.SQRT_TWO
			site_x = cx == 0 ? d : n - d
			site_z = cz == 0 ? d : n - d
			test_yaw = f32(math.atan2(-(cx - site_x), cz - site_z))
		} else {
			d := opts.edge_dist
			ds := [4]f64{site_x, n - site_x, site_z, n - site_z}
			k := 0
			for i in 1 ..< 4 do if ds[i] < ds[k] do k = i
			switch k {
			case 0:
				site_x, test_yaw = d, math.PI / 2
			case 1:
				site_x, test_yaw = n - d, -math.PI / 2
			case 2:
				site_z, test_yaw = d, math.PI
			case 3:
				site_z, test_yaw = n - d, 0
			}
		}
		has_test_yaw = true
		lat, lon = geo_latlon(geo_dir(&geo, geo.face, site_x, site_z))
	}
	system.home.latitude_deg, system.home.longitude_deg = lat, lon
	fmt.printfln("Высадка: широта %.2f, долгота %.2f, грань %s, до ребра %.1f км",
		lat, lon, FACE_NAMES[geo.face], geo_edge_dist(&geo, site_x, site_z) / 1000)

	world: World
	world_init(&world, opts.seed, VIEW_RADIUS, geo)
	defer world_destroy(&world)

	globe, globe_ok := globe_create(&world.geo, opts.seed)
	if !globe_ok do os.exit(1)

	sx, sz := i32(site_x), i32(site_z)
	spawn := find_spawn(&world, sx, sz)
	if opts.water_spawn do spawn = find_water_spawn(&world, sx, sz)
	if opts.mountain_spawn do spawn = find_mountain_spawn(&world, sx, sz)
	if opts.anomaly_dist > 0 || opts.edge_dist > 0 do spawn = spawn_at(&world, sx, sz)
	for !spawn_area_ready(&world, spawn, 2) {
		world_update(&world, spawn, 0.1)
		free_all(context.temp_allocator)
	}
	for !spawn_area_ready(&world, spawn, 4) {
		world_update(&world, spawn, 0.1)
		free_all(context.temp_allocator)
	}

	player: Character
	character_spawn(&player, &world, spawn)
	if opts.anomaly_dist > 0 {
		// место высадки могло сдвинуться (вода) — смотрим на вершину от него
		cx, cz, _ := geo_nearest_corner(&world.geo, spawn.x, spawn.z)
		test_yaw = f32(math.atan2(-(cx - spawn.x), cz - spawn.z))
	}
	if has_test_yaw && !opts.has_yaw do opts.yaw, opts.has_look = math.to_degrees(test_yaw), true
	player.yaw = math.to_radians(opts.yaw)
	player.pitch = math.to_radians(opts.pitch)
	player.body_yaw = player.yaw
	player.prev_body_yaw = player.yaw

	squad: Squad
	squad_init(&squad, &world, &player, opts.seed)
	defer squad_destroy(&squad)
	if opts.select > 0 do squad_select(&squad, opts.select == 3 ? -1 : opts.select - 1)
	auto_order_done := opts.order == ""

	// высадка: игрок и спутники падают в капсулах над точкой появления
	landing := landing_create(&world, &player, &squad, spawn, opts.seed)
	if opts.no_intro {
		landing_skip(&landing, &squad, &player)
		if opts.has_look {
			player.yaw = math.to_radians(opts.yaw)
			player.pitch = math.to_radians(opts.pitch)
			player.body_yaw, player.prev_body_yaw = player.yaw, player.yaw
		}
	}

	cam := Camera {
		mode       = opts.cam_mode,
		hand_yaw   = player.yaw,
		hand_pitch = player.pitch,
		orbit      = math.to_radians(opts.orbit),
	}

	auto_mode := opts.shot_path != ""
	if !auto_mode do eng.set_cursor_locked(true)

	start := eng.time_now()
	last := start
	accumulator: f64
	sprint_latch := false
	last_w_press: f64 = -10
	screenshot_requested := false
	debug_page := opts.debug_page
	fps_timer: f64
	fps_frames: int
	shots_taken := 0
	last_fps: f64

	for !eng.window_should_close() {
		eng.window_begin_frame()
		now := eng.time_now()
		dt := min(now - last, 0.25)
		last = now

		// --- системные клавиши
		playing := !landing.active // во время высадки — только увод капсулы и взгляд
		if eng.key_pressed(glfw.KEY_ESCAPE) {
			if eng.win.cursor_locked {
				eng.set_cursor_locked(false)
			} else {
				eng.window_request_close()
			}
		}
		if playing && !eng.win.cursor_locked && !auto_mode && eng.mouse_pressed(glfw.MOUSE_BUTTON_LEFT) {
			eng.set_cursor_locked(true)
		}
		if playing && eng.key_pressed(glfw.KEY_F5) do camera_cycle_mode(&cam)
		if eng.key_pressed(glfw.KEY_F2) do screenshot_requested = true
		if eng.key_pressed(glfw.KEY_F3) do debug_page = (debug_page + 1) % 4 // страницы F3 по кругу, 0 — выкл
		if playing && eng.win.focused do handle_squad_keys(&squad, &world, &player)
		if playing && !auto_order_done && now - start > opts.order_at {
			auto_order_done = true
			switch opts.order {
			case "follow":
				squad_order(&squad, &world, &player, .Follow)
			case "hold":
				squad_order(&squad, &world, &player, .Hold)
			case "go":
				if !order_go_to_aim(&squad, &world, &player) do fmt.println("go: no target under crosshair")
			}
		}

		// --- обзор мышью
		if playing && eng.win.cursor_locked {
			player.yaw += eng.win.mouse_dx * MOUSE_SENSITIVITY
			player.pitch += eng.win.mouse_dy * MOUSE_SENSITIVITY
			limit := math.to_radians(f32(89.9))
			player.pitch = clamp(player.pitch, -limit, limit)
		}

		// --- управление
		input: Move_Input
		if playing && eng.win.focused {
			if eng.key_pressed(glfw.KEY_W) {
				if now - last_w_press < 0.3 do sprint_latch = true
				last_w_press = now
			}
			if !eng.key_down(glfw.KEY_W) do sprint_latch = false
			if eng.key_down(glfw.KEY_W) do input.forward += 1
			if eng.key_down(glfw.KEY_S) do input.forward -= 1
			if eng.key_down(glfw.KEY_A) do input.strafe += 1
			if eng.key_down(glfw.KEY_D) do input.strafe -= 1
			input.jump = eng.key_down(glfw.KEY_SPACE)
			input.sneak = eng.key_down(glfw.KEY_LEFT_SHIFT)
			input.sprint = eng.key_down(glfw.KEY_LEFT_CONTROL) || sprint_latch
		}
		if opts.walk do input.forward = 1
		if opts.sprint do input.sprint = true
		if opts.jump do input.jump = true
		if opts.sneak do input.sneak = true
		if opts.strafe do input.strafe = 1

		// --- фиксированные тики физики (20 в секунду, как в Minecraft)
		accumulator += dt
		ticks := 0
		for accumulator >= TICK_DT && ticks < 10 {
			landing_tick(&landing, &world)
			if !landing.active do character_tick(&player, &world, input)
			squad_tick(&squad, &world, &player)
			clock_tick(&clock)
			accumulator -= TICK_DT
			ticks += 1
		}
		t := f32(accumulator / TICK_DT)
		{
			// увод капсулы WASD относительно камеры
			drift: [3]f64
			mdx, mdy: f32
			if landing.active && eng.win.focused {
				f := look_dir(landing.cam_yaw, 0)
				fwd := [3]f64{f64(f.x), 0, f64(f.z)}
				right := [3]f64{-fwd.z, 0, fwd.x}
				if eng.key_down(glfw.KEY_W) do drift += fwd
				if eng.key_down(glfw.KEY_S) do drift -= fwd
				if eng.key_down(glfw.KEY_D) do drift += right
				if eng.key_down(glfw.KEY_A) do drift -= right
				if opts.walk do drift += fwd // отладка: "держать W"
				if l := math.sqrt(drift.x * drift.x + drift.z * drift.z); l > 1 do drift /= l
			}
			if eng.win.cursor_locked do mdx, mdy = eng.win.mouse_dx, eng.win.mouse_dy
			landing_update(&landing, &world, drift, mdx, mdy, cam.pos, f32(dt))
		}

		// ушли за ребро грани — кадром становится соседняя грань
		frame_follow({&world, &player, &squad, &landing, &cam, &sky, &r})

		world_update(&world, player.pos, WORLD_BUDGET)

		fbw, fbh := eng.win.fb_width, eng.win.fb_height
		if fbw > 0 && fbh > 0 {
			if landing.active {
				landing_camera(&landing, &cam, &player, &world, t, f32(fbw) / f32(fbh), f32(dt))
			} else {
				camera_update(&cam, &player, &world, t, f32(fbw) / f32(fbh), f32(dt))
			}
			render_frame(&r, {
				world = &world,
				player = &player,
				cam = &cam,
				sky = &sky,
				model = &model,
				player_skin = player_skin_tex,
				capsule = &capsule,
				landing = &landing,
				globe = &globe,
				squad = &squad,
				clock = &clock,
				system = &system,
				debug_page = debug_page,
				universe = &uinfo,
				fps = last_fps,
				t = t,
				time = now - start,
				dt = f32(dt),
				width = fbw,
				height = fbh,
			})

			if screenshot_requested {
				screenshot_requested = false
				os.make_directory("screenshots")
				path := fmt.tprintf("screenshots/%d.png", time.time_to_unix(time.now()))
				if eng.save_screenshot(path, fbw, fbh) do fmt.println("Скриншот:", path)
			}
			if auto_mode && now - start > opts.shot_delay + f64(shots_taken) * opts.interval {
				path := opts.shot_path
				if opts.burst > 1 {
					base := strings.trim_suffix(path, ".png")
					path = fmt.tprintf("%s_%d.png", base, shots_taken)
				}
				ok := eng.save_screenshot(path, fbw, fbh)
				fmt.println(ok ? "saved" : "FAILED", path)
				shots_taken += 1
				if shots_taken >= opts.burst {
					fmt.printfln("fps: %.1f, chunks: %d, drawn: %d", last_fps, len(world.chunks), r.chunks_drawn)
					eng.window_request_close()
				}
			}
		}

		eng.window_end_frame()

		fps_frames += 1
		fps_timer += dt
		if fps_timer >= 0.5 {
			last_fps = f64(fps_frames) / fps_timer
			eng.window_set_title(fmt.tprintf(
				"Voxel %s  |  %d FPS  |  XYZ %.1f %.1f %.1f  |  чанков: %d/%d  |  F5 камера  |  1/2/3 выбор, F за мной, H стой, G иди туда",
				VERSION, int(f64(fps_frames) / fps_timer + 0.5),
				player.pos.x, player.pos.y, player.pos.z,
				r.chunks_drawn, len(world.chunks),
			))
			fps_frames = 0
			fps_timer = 0
		}
		free_all(context.temp_allocator)
	}
}
