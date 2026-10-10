package main

// Voxel — воксельная игра на Odin с самописным движком (GLFW + OpenGL 3.3).

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import eng "engine"
import "vendor:glfw"

VERSION :: "0.018"
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
	cliff_spawn:   bool, // у самого крутого обрыва (слои пород)
	tree_spawn:    bool, // у большого лиственного дерева, лицом к нему
	wx_want:       string, // -wx: начать в ближайший день с такой погодой (rain, snow, firstsnow, storm, clear, overcast, fog, thunder, nightstorm)
	has_latlon:    bool, // высадка в заданной точке планеты
	lat, lon:      f64,
	debug_page:    int, // сразу открыть страницу F3 (1..3)
	universe_report: bool, // напечатать отчёт о вселенной с проверками и выйти
	planets_report: bool, // сверить модель планет с Солнечной системой, статистика систем — и выйти
	stars_report:  bool, // сверить модель звёзд с настоящими звёздами — и выйти
	climate_report: bool, // сверить климат с Землёй — и выйти
	weather_report: bool, // прогнать погоду на климате Земли — и выйти
	biome:         string, // отладка: высадиться в природной зоне (forest, taiga, tundra, glacier, steppe, desert, savanna, rainforest…)
	timescale:     f64, // ускорение времени (отладка)
	start_day:     int, // день года при высадке (0 — случайный)
	look_at:       string, // sun | moon — сразу смотреть туда (отладка)
	start_hours:   f64, // начать через столько стандартных часов после высадки (отладка)
	sky_report:    bool, // проверить небо за год, найти затмения и выйти
	no_intro:      bool, // без высадки в капсулах (сразу на земле)
	has_look:      bool, // заданы -yaw / -pitch
	has_yaw:       bool,
	edge_dist:     f64, // > 0: высадка в стольких метрах от ребра грани (тест стыка)
	anomaly_dist:  f64, // > 0: высадка в стольких метрах от вершины куба (тест аномалии)
	selftest:      bool, // проверить геометрию стыков граней и выйти
	dump_textures: string,
	no_vsync:      bool, // без вертикальной синхронизации (замер скорости)
	alt:           f64, // отладка: камера выше на столько метров (вид с высоты)
	view_km:       f64, // > 0: предел дальности дальнего рельефа, км
	off:           string, // отладка: выключить части (far,clouds,shadows,haze) — для замеров
}

parse_options :: proc() -> (o: Options) {
	o.width, o.height = 1280, 720
	o.start_hour = 7
	o.timescale = 1
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
			o.debug_page = val == "" ? 1 : clamp(strconv.parse_int(val) or_else 1, 1, F3_PAGES)
		case "-hours":
			o.start_hours = max(0, strconv.parse_f64(val) or_else 0)
		case "-sky":
			o.sky_report = true
		case "-look":
			o.look_at = val
		case "-timescale":
			o.timescale = max(0, strconv.parse_f64(val) or_else 1)
		case "-day":
			o.start_day = max(1, strconv.parse_int(val) or_else 1)
		case "-biome":
			o.biome = val
		case "-climate":
			o.climate_report = true
		case "-wx":
			o.wx_want = val
		case "-weather":
			o.weather_report = true
		case "-stars":
			o.stars_report = true
		case "-planets":
			o.planets_report = true
		case "-universe":
			o.universe_report = true
		case "-spawn":
			o.water_spawn = val == "water"
			o.mountain_spawn = val == "mountain"
			o.cliff_spawn = val == "cliff"
			o.tree_spawn = val == "tree"
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
		case "-novsync":
			o.no_vsync = true
		case "-alt":
			o.alt = max(0, strconv.parse_f64(val) or_else 0)
		case "-view":
			o.view_km = max(0, strconv.parse_f64(val) or_else 0)
		case "-off":
			o.off = val
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
		col := world_frame_column(w, cx + dx, cz + dz)
		if col == nil || !col.covered do return false
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

	if opts.weather_report {
		if weather_report() > 0 do os.exit(1)
		return
	}
	if opts.climate_report {
		if climate_report() > 0 do os.exit(1)
		return
	}
	if opts.stars_report {
		if stars_report() > 0 do os.exit(1)
		return
	}
	if opts.planets_report {
		if planets_report() > 0 do os.exit(1)
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
	star_system_set_home(&system, home.planet, opts.seed)
	system.checked = home.checked
	defer star_system_destroy(&system)
	uinfo := universe_info_build(&universe, home)
	defer universe_info_destroy(&uinfo)
	// звёздное небо считается в фоне, пока грузится мир (для -sky — сразу, в отчёте)
	star_sky: Star_Sky
	defer starsky_destroy(&star_sky)
	if !opts.sky_report && !opts.universe_report do starsky_start(&star_sky, opts.seed, home)
	t3 := time.now()
	fmt.printfln("Мир %d: галактика %s (%s), звезда %s (%s, проверено звёзд: %d), планета %s, сутки %.1f ч, гравитация %.2f g",
		opts.seed, uinfo.galaxy_name, GALAXY_KIND_NAMES[home.galaxy.kind], system.star.name, STAR_CLASS_NAMES[system.star.class], home.checked,
		home_planet(&system).name, system.home.day_hours, system.home.gravity_g)
	if opts.universe_report {
		ms :: proc(a, b: time.Time) -> f64 {return time.duration_milliseconds(time.diff(a, b))}
		if universe_report(&universe, &uinfo, opts.seed, ms(t0, t1), ms(t1, t2), ms(t2, t3)) > 0 do os.exit(1)
		return
	}

	if !eng.window_create(fmt.tprintf("Voxel %s", VERSION), opts.width, opts.height) do os.exit(1)
	defer eng.window_destroy()
	if opts.no_vsync do eng.window_set_vsync(false)

	clock := clock_init(system.home.day_hours, opts.timescale)
	clock.std_hours = opts.start_hours

	r: Renderer
	if !renderer_init(&r) do os.exit(1)
	if !starsky_gl_init(&star_sky) do os.exit(1)

	player_skin := skin_load_or_generate("assets/skin.png", PALETTE_PLAYER)
	player_skin_tex := skin_texture_create(&player_skin)
	model := humanoid_model_create()
	capsule := capsule_model_create()

	sky: Sky
	sky_init(&sky)

	// планета-шар реального размера: выбираем грань и точку высадки
	hp := home_planet(&system)
	geo := geo_make(hp.radius_km)
	// рельеф настоящего масштаба (океан — столько, сколько у планеты воды; высота
	// гор — по силе тяжести) и климат — обычно уже посчитаны поиском места высадки
	if climate_key != {home.star.seed, u64(home.planet)} {
		relief_init(opts.seed, geo.radius, system.home.gravity_g, hp.water * hp.mass_earth * M_EARTH_KG / 1000)
		climate = climate_make(climate_input_for(&system, hp, opts.seed))
		climate_key = {home.star.seed, u64(home.planet)}
	}
	world_climate_reset()
	trees_reset()
	// строение планеты (кора, мантия, ядро) — из массы, состава, возраста; глубже коры блоки идут по нему
	interior := interior_make(body_interior_input(&system, &hp.body))
	defer free(interior)
	deep_rock_init(interior)
	// строение нашей звезды (её блеск, цвет и размер — прежние)
	star_st := star_structure_make(system.star, system.age_gyr, system.metal)
	// место высадки — найдено поиском: умеренный лес или степь
	lat, lon := home.lat, home.lon
	if opts.has_latlon do lat, lon = opts.lat, opts.lon
	if b, ok := biome_from_name(opts.biome); ok {
		if la, lo, found := climate_find_biome(opts.seed, hp.radius_km, b); found {
			lat, lon = la, lo
		} else {
			fmt.printfln("зоны «%s» на этой планете нет", opts.biome)
		}
	}
	site_x, site_z: f64
	site_x, site_z, lat, lon = geo_choose_site(&geo, lat, lon, opts.seed, true)
	if errors := geo_check_links(&geo); errors > 0 do fmt.eprintln("ОШИБКА: рёбра граней не стыкуются:", errors)
	if opts.selftest {
		checked, errors := frame_selftest(geo)
		fmt.printfln("selftest: рёбра %d ошибок; смена кадра: %d точек, %d ошибок", geo_check_links(&geo), checked, errors)
		ridge, diff, diff_max, ocean, h_lo, h_hi := far_selftest(opts.seed, &geo)
		fmt.printfln("дальний рельеф: гребень одной октавы (1−|шум|)² в среднем %.3f (заложено %.2f); от верха блоков в среднем %.2f м, наибольшее %.2f м",
			ridge, RIDGE1_MEAN, diff, diff_max)
		fmt.printfln("рельеф: океан %.0f%% (задано %.0f%%), высоты от %.0f до %.0f м, горы ×%.2f (тяжесть %.2f g)",
			ocean * 100, relief.ocean_frac * 100, h_lo, h_hi, relief.mountain_k, system.home.gravity_g)
		fmt.printfln("недра: плотность %.2f г/см³, ядро %.0f км (твёрдое %.0f км), в центре %.0f °C и %.0f ГПа, поле %.0f мкТл",
			interior.density, interior.core_km, interior.inner_km, interior.center_t, interior.center_p, interior.magnetic_ut)
		fmt.printfln("атмосфера: %.2f бар, %.1f °C, кислород %.0f кПа; суша и море: океан %.0f%% поверхности (оценка по воде %.0f%%)",
			hp.atmo.pressure, hp.atmo.t_surface - 273.15, hp.atmo.o2_kpa, relief.ocean_frac * 100, hp.ocean_frac * 100)
		site := geo_from_latlon(lat, lon) * geo.radius
		scp := climate_point(&climate, i64(opts.seed), site, elevation(i64(opts.seed), site, 2000))
		sk, _, _ := climate_classify(&climate, &scp)
		fmt.printfln("климат: в среднем %.1f °C, экватор %.1f, полюса %.1f и %.1f; ячейка Хэдли до %.0f°, осадков %.0f мм в год; место высадки (%.1f°, %.1f°) — %s, %s",
			climate.global_t, climate.equator_t, climate.pole_n_t, climate.pole_s_t, climate.hadley, climate.global_p, lat, lon, koppen_text(sk), BIOME_NAMES[sk.biome])
		tw: World
		world_init(&tw, opts.seed, 1, geo)
		defer world_destroy(&tw)
		if trees_selftest(&tw, site_x, site_z) > 0 do os.exit(1)
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
	world_set_gravity(&world, system.home.gravity_g)

	// небесная механика: в момент высадки на её долготе — start_hour местного времени
	astro: Astro
	astro_init(&astro, &system, opts.start_hour, opts.start_day, lon, opts.seed)
	if opts.sky_report {
		star_sky.world_seed, star_sky.home = opts.seed, home
		starsky_build(&star_sky)
		starsky_report(&star_sky, &astro)
		if astro_report(&astro, &system, geo_dir(&world.geo, world.geo.face, site_x, site_z)) > 0 do os.exit(1)
		return
	}
	defer world_destroy(&world)

	globe, globe_ok := globe_create(&world.geo, opts.seed)
	if !globe_ok do os.exit(1)

	// рельеф до горизонта (тайлы строятся в фоне) и облака на настоящей высоте;
	// у планет со слабой тяжестью атмосфера «выше» — дымка тоже
	far: Far_Terrain
	if !far_init(&far, world.geo, opts.seed) do os.exit(1)
	defer far_destroy(&far)
	if opts.view_km > 0 do far.max_dist = opts.view_km * 1000
	// воздух: выше атмосфера — выше облака и дымка; плотнее — гуще дымка
	clouds: Clouds
	air_scale := hp.atmo.scale_h / EARTH_SCALE_H
	if !clouds_init(&clouds, opts.seed, air_scale) do os.exit(1)
	// погода (weather.odin): колебания вокруг климата; карта вокруг игрока считается в фоне
	wx := new(Weather_State) // ~400 КБ — не на стеке
	defer free(wx)
	weather_state_init(wx, opts.seed, hp, system.home.day_hours, clouds.height)
	defer weather_state_destroy(wx)
	// снег копится и тает по погоде (snow.odin): сетка вокруг игрока, считается в фоне
	snow := new(Snow_State)
	defer free(snow)
	snow_state_init(snow, &wx.model, opts.seed, system.home.day_hours)
	defer snow_state_destroy(snow)
	world.snow = snow
	// молнии в грозах вокруг (lightning.odin)
	lightning := new(Lightning)
	defer free(lightning)
	if !lightning_init(lightning, opts.seed) do os.exit(1)
	defer lightning_destroy(lightning)
	r.haze_height = f32(clamp(HAZE_HEIGHT * air_scale, 400, 6000))
	r.haze_beta = f32(HAZE_BETA * clamp(hp.atmo.density / EARTH_AIR_DENSITY, 0.1, 5))
	r.seed = opts.seed
	r.off_far = strings.contains(opts.off, "far")
	r.off_clouds = strings.contains(opts.off, "clouds")
	r.off_shadows = strings.contains(opts.off, "shadows")
	r.off_fog = strings.contains(opts.off, "fog")
	r.off_snow = strings.contains(opts.off, "snow")
	if strings.contains(opts.off, "haze") do r.haze_beta = 0

	sx, sz := i32(site_x), i32(site_z)
	spawn := find_spawn(&world, sx, sz, opts.biome == "")
	if opts.water_spawn do spawn = find_water_spawn(&world, sx, sz)
	if opts.mountain_spawn do spawn = find_mountain_spawn(&world, sx, sz)
	if opts.cliff_spawn {
		spawn, test_yaw = find_cliff_spawn(&world, sx, sz)
		has_test_yaw = true
	}
	if opts.tree_spawn {
		if p, yaw, ok := find_tree_spawn(&world, sx, sz); ok {
			spawn, test_yaw = p, yaw
			has_test_yaw = true
		}
	}
	if opts.anomaly_dist > 0 || opts.edge_dist > 0 do spawn = spawn_at(&world, sx, sz)
	// отладка: начать в ближайший день, когда здесь такая погода (её не подгоняем — ищем)
	if opts.wx_want != "" && climate.ok {
		face, gx, gz, ok := world_resolve(&world, i32(spawn.x), i32(spawn.z))
		if ok {
			col, _ := ensure_column(&world, column_key_of(face, gx, gz))
			cp := col.clim
			cp.alt = max(spawn.y - Y_SEA, 0)
			up := geo_frame_dir(&world.geo, spawn.x, spawn.z)
			st := astro_sky_at(&astro, &world.geo, spawn, clock.std_hours, nil)
			if shift, found := weather_find(wx, up, cp, &astro, clock.std_hours, st.local_hours, opts.wx_want); found {
				clock.std_hours += shift
				fmt.printfln("погода «%s»: через %.0f суток", opts.wx_want, shift / astro.day)
			} else {
				fmt.printfln("погоды «%s» здесь за 2000 суток не нашлось", opts.wx_want)
			}
		}
	}
	// зимой лиственные кроны голые — свет неба под ними не гаснет
	world.bare = leaves_bare_at(&world, spawn, climate_season(&astro, clock.std_hours))
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
		// отладка: сразу смотреть на солнце или на первую луну
		if opts.look_at != "" {
			st := astro_sky_at(&astro, &world.geo, player.pos, clock.std_hours)
			d := opts.look_at == "moon" && st.moon_n > 0 ? st.moons[0].frame : st.sun_frame
			if opts.look_at == "pole" {
				// небесный полюс над горизонтом (северный — в северном полушарии)
				pole := st.latitude >= 0 ? astro.axis : -astro.axis
				f := st.inert_to_frame * pole
				d = {f32(f.x), f32(f.y), f32(f.z)}
			}
			player.yaw = math.atan2(-d.x, d.z)
			player.pitch = -math.asin(clamp(d.y, -1, 1)) + math.to_radians(f32(4)) // цель — чуть выше прицела
			player.body_yaw, player.prev_body_yaw = player.yaw, player.yaw
		}
	}

	cam := Camera {
		mode       = opts.cam_mode,
		hand_yaw   = player.yaw,
		hand_pitch = player.pitch,
		orbit      = math.to_radians(opts.orbit),
	}

	// дальний рельеф вокруг точки появления — ещё до первого кадра (при высадке — с высоты капсул)
	{
		eye := player.pos + {0, opts.no_intro ? 1.6 + opts.alt : DROP_ALTITUDE, 0}
		pv := planet_view_make(&world.geo, eye)
		deadline := eng.time_now() + 5
		for eng.time_now() < deadline {
			far_update(&far, &pv, 1)
			if far.ready_all do break
			time.sleep(5 * time.Millisecond)
		}
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
	bench_frames, bench_time: f64 // замер для отчёта: кадры после 3-й секунды и расчёта снега
	frame_ms: f64 = 16
	around_time: f64 = -10
	around: [2]f64

	cover_set := false // ветер облаков: в первом кадре — сразу
	bolt_shot_at := -1.0 // отладка (-look:bolt): когда снять удар молнии
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
		if eng.key_pressed(glfw.KEY_F3) do debug_page = (debug_page + 1) % (F3_PAGES + 1) // страницы F3 по кругу, 0 — выкл
		if !star_sky.ready && sync.atomic_load(&star_sky.done) {
			starsky_upload(&star_sky) // небо досчиталось
			if opts.look_at == "core" {
				// отладка: взгляд на центр галактики
				st := astro_sky_at(&astro, &world.geo, player.pos, clock.std_hours)
				f := st.uni_to_frame * star_sky.core_dir
				player.yaw = math.atan2(f32(-f.x), f32(f.z))
				player.pitch = -math.asin(clamp(f32(f.y), -1, 1)) + math.to_radians(f32(4))
				player.body_yaw, player.prev_body_yaw = player.yaw, player.yaw
			}
		}
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

		// небо этого кадра: солнце, луны, свет — по положению планеты и игрока на ней
		season := climate_season(&astro, clock.std_hours + f64(t) * clock_tick_hours(&clock))
		sky_state := astro_sky_at(&astro, &world.geo, player.pos + {0, opts.alt, 0}, clock.std_hours + f64(t) * clock_tick_hours(&clock), &star_sky)
		// облетели или распустились кроны — свет неба под ними другой: секции перестроятся
		if b := leaves_bare_at(&world, player.pos, season); b != world.bare {
			world.bare = b
			for _, c in world.chunks do if c.meshed do c.stale = true
		}

		// погода: там, где стоим, — каждый кадр, карта вокруг — в фоне; облака плывут по местному ветру
		if climate.ok {
			up := geo_frame_dir(&world.geo, player.pos.x, player.pos.z)
			if face, gx, gz, ok := world_resolve(&world, i32(math.floor(player.pos.x)), i32(math.floor(player.pos.z))); ok {
				if col := world_column(&world, column_key_of(face, gx, gz)); col != nil {
					cp := col.clim
					cp.alt = max(player.pos.y - Y_SEA, 0)
					T := clock.std_hours + f64(t) * clock_tick_hours(&clock)
					weather_update(wx, snow, up, cp, weather_time(&astro, T), season, sky_state.local_hours, now - start)
					snow_update(snow, up, weather_time(&astro, T), season, sky_state.local_hours)
					east, north := wx_axes(up)
					want := east * wx.here.wind.x + north * wx.here.wind.y
					pv := planet_view_make(&world.geo, player.pos)
					wx.wind_frame = pv.jinv * want
					precip_tick(&wx.precip, wx.wind_frame, wx.here.rain, wx.here.snow, f64(dt))
					clouds.wind += (want - clouds.wind) * (cover_set ? min(dt * 0.3, 1) : 1)
					clouds.cover = wx.here.cover
					cover_set = true
				}
			}
		}
		// облака плывут; тень облака там, где стоит игрок (для персонажей и освещённости)
		clouds_tick(&clouds, now - start)
		weather_link_clouds(wx, &clouds)
		lightning_update(lightning, wx, &world, &clouds, player.pos, now - start, clock.std_hours * 3600, 3600 / REAL_SECONDS_PER_STD_HOUR * clock.timescale)
		// отладка (-look:bolt): повернуться к удару молнии ближе 30 км — и снять его
		if opts.look_at == "bolt" && bolt_shot_at < 0 {
			pv := planet_view_make(&world.geo, player.pos + {0, 1.6 + opts.alt, 0}) // от камеры (с -alt — выше)
			vis := wx_visibility(wx.here.rain, wx.here.snow)
			if d, ok := lightning_fresh_strike(lightning, &pv, i64(opts.seed), now - start, 30_000, vis > 0 ? 3.912 / vis : 0); ok {
				player.yaw = math.atan2(-d.x, d.z)
				player.pitch = -math.asin(clamp(d.y, -1, 1))
				player.body_yaw, player.prev_body_yaw = player.yaw, player.yaw
				bolt_shot_at = now - start + 0.005
			}
		}
		cloud_shade, cloud_over: f64
		{
			up := geo_frame_dir(&world.geo, player.pos.x, player.pos.z)
			h := player.pos.y + 1.6 - Y_SEA
			cloud_shade = cloud_shadow_at(&clouds, up * (world.geo.radius + h), up, sky_state.sun_body, h)
			cloud_over = cloud_alpha(cloud_density(&clouds, cloud_q(&clouds, up * (world.geo.radius + clouds.height))))
		}
		frame_ms += (dt * 1000 - frame_ms) * 0.05
		// окрестности для F3: самая высокая и самая низкая точка в 40 км (раз в пару секунд)
		if now - around_time > 2 {
			around_time = now
			around = {-1e9, 1e9}
			up := geo_frame_dir(&world.geo, player.pos.x, player.pos.z)
			t1 := [3]f64{-up.z, 0, up.x}
			if t1.x * t1.x + t1.z * t1.z < 1e-6 do t1 = {1, 0, 0}
			t1 /= math.sqrt(t1.x * t1.x + t1.y * t1.y + t1.z * t1.z)
			t2 := [3]f64{up.y * t1.z - up.z * t1.y, up.z * t1.x - up.x * t1.z, up.x * t1.y - up.y * t1.x}
			for ring in 0 ..< 8 do for k in 0 ..< 16 {
				a := f64(k) / 16 * math.TAU
				dist := f64(ring + 1) * 5000
				d := up + (t1 * math.cos(a) + t2 * math.sin(a)) * (dist / world.geo.radius)
				d /= math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
				e := elevation(i64(opts.seed), d * world.geo.radius, 300)
				around = {max(around.x, e), min(around.y, e)}
			}
		}

		fbw, fbh := eng.win.fb_width, eng.win.fb_height
		if fbw > 0 && fbh > 0 {
			if landing.active {
				landing_camera(&landing, &cam, &player, &world, t, f32(fbw) / f32(fbh), f32(dt))
			} else {
				camera_update(&cam, &player, &world, t, f32(fbw) / f32(fbh), f32(dt))
				if opts.alt > 0 do cam.pos.y += opts.alt // отладка: вид с высоты
			}
			{
				pv := planet_view_make(&world.geo, cam.pos)
				far_update(&far, &pv)
			}
			render_frame(&r, {
				world = &world,
				player = &player,
				cam = &cam,
				sky = &sky,
				sky_state = &sky_state,
				star_sky = &star_sky,
				model = &model,
				player_skin = player_skin_tex,
				capsule = &capsule,
				landing = &landing,
				globe = &globe,
				far = &far,
				interior = interior,
				star_st = &star_st,
				around = around,
				clouds = &clouds,
				weather = wx,
				snow = snow,
				lightning = lightning,
				cloud_shade = f32(cloud_shade),
				cloud_over = cloud_over,
				frame_ms = frame_ms,
				squad = &squad,
				clock = &clock,
				system = &system,
				debug_page = debug_page,
				season = season,
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
			// автоснимок ждёт, пока досчитаются звёздное небо и дальний рельеф
			bolt_ok := opts.look_at != "bolt" || (bolt_shot_at >= 0 && now - start >= bolt_shot_at)
			if auto_mode && bolt_ok && (star_sky.ready || star_sky.worker == nil) && far.ready_all && wx.front.ok && snow.front.ok && now - start > opts.shot_delay + f64(shots_taken) * opts.interval {
				bolt_shot_at = -1
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
					if bench_frames > 0 do fmt.printfln("кадр: %.2f мс в среднем (%.0f кадров)", bench_time / bench_frames * 1000, bench_frames)
					fmt.printfln("дальний рельеф: %d тайлов на экране, выбрано %d (%s), в памяти %d, до %.1f км",
						far.drawn, len(far.draw), far_stats(&far), len(far.tiles), far.view_dist / 1000)
					eng.window_request_close()
				}
			}
		}

		eng.window_end_frame()

		fps_frames += 1
		fps_timer += dt
		if now - start > 3 && snow.front.ok && !snow.spin { // после расчёта прошлого года снега (он грузит все ядра)
			bench_frames += 1
			bench_time += dt
		}
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
