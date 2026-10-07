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

VERSION :: "0.001"
VIEW_RADIUS :: 10 // чанков
DEFAULT_SEED :: 20261007
MOUSE_SENSITIVITY :: 0.0026 // радиан на пиксель (~0.15°, как в Minecraft)
WORLD_BUDGET :: 0.005 // секунд на генерацию/меши за кадр

Options :: struct {
	width, height: i32,
	seed:          u32,
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
	dump_textures: string,
}

parse_options :: proc() -> (o: Options) {
	o.width, o.height = 1280, 720
	o.seed = DEFAULT_SEED
	o.cam_mode = .Third_Back
	o.shot_delay = 1.0
	o.burst = 1
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
		case "-pitch":
			o.pitch = f32(strconv.parse_f64(val) or_else 0)
		case "-seed":
			o.seed = u32(strconv.parse_u64(val) or_else DEFAULT_SEED)
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

spawn_area_ready :: proc(w: ^World, pos: [3]f64, radius: i32) -> bool {
	cx := eng.floor_div(i32(math.floor(pos.x)), CHUNK_SIZE)
	cz := eng.floor_div(i32(math.floor(pos.z)), CHUNK_SIZE)
	for dz in -radius ..= radius do for dx in -radius ..= radius {
		c := world_get_chunk(w, cx + dx, cz + dz)
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

	if !eng.window_create(fmt.tprintf("Voxel %s", VERSION), opts.width, opts.height) do os.exit(1)
	defer eng.window_destroy()

	r: Renderer
	if !renderer_init(&r, VIEW_RADIUS) do os.exit(1)

	skin := skin_load_or_generate("assets/skin.png")
	model := player_model_create(&skin)

	sky: Sky
	sky_init(&sky, opts.seed)

	world: World
	world_init(&world, opts.seed, VIEW_RADIUS)
	defer world_destroy(&world)

	spawn := find_spawn(opts.seed)
	for !spawn_area_ready(&world, spawn, 2) {
		world_update(&world, spawn, 0.1)
		free_all(context.temp_allocator)
	}

	player: Player
	player_spawn(&player, &world, spawn)
	player.yaw = math.to_radians(opts.yaw)
	player.pitch = math.to_radians(opts.pitch)
	player.body_yaw = player.yaw
	player.prev_body_yaw = player.yaw

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
		if eng.key_pressed(glfw.KEY_ESCAPE) {
			if eng.win.cursor_locked {
				eng.set_cursor_locked(false)
			} else {
				eng.window_request_close()
			}
		}
		if !eng.win.cursor_locked && !auto_mode && eng.mouse_pressed(glfw.MOUSE_BUTTON_LEFT) {
			eng.set_cursor_locked(true)
		}
		if eng.key_pressed(glfw.KEY_F5) do camera_cycle_mode(&cam)
		if eng.key_pressed(glfw.KEY_F2) do screenshot_requested = true

		// --- обзор мышью
		if eng.win.cursor_locked {
			player.yaw += eng.win.mouse_dx * MOUSE_SENSITIVITY
			player.pitch += eng.win.mouse_dy * MOUSE_SENSITIVITY
			limit := math.to_radians(f32(89.9))
			player.pitch = clamp(player.pitch, -limit, limit)
		}

		// --- управление
		input: Player_Input
		if eng.win.focused {
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
			player_tick(&player, &world, input)
			accumulator -= TICK_DT
			ticks += 1
		}
		t := f32(accumulator / TICK_DT)

		world_update(&world, player.pos, WORLD_BUDGET)

		fbw, fbh := eng.win.fb_width, eng.win.fb_height
		if fbw > 0 && fbh > 0 {
			camera_update(&cam, &player, &world, t, f32(fbw) / f32(fbh), f32(dt))
			render_frame(&r, {
				world = &world,
				player = &player,
				cam = &cam,
				sky = &sky,
				model = &model,
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
				"Voxel %s  |  %d FPS  |  XYZ %.1f %.1f %.1f  |  чанков: %d/%d  |  F5 — камера",
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
