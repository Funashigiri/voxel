package main

// Проверка климата (-climate): модель считает Землю — её орбиту, наклон оси,
// сутки, атмосферу и долю суши по широтам — и сверяется с настоящим климатом:
// температура на экваторе и у полюсов, годовой ход в глубине материка и над
// океаном, ширина тропиков, пояса пустынь и дождей, типы климата по Кёппену
// в типичных местах, граница леса и снеговая линия.

import "core:fmt"
import "core:math"

// Доля суши Земли по полосам в 10° (от 90° ю.ш. к 90° с.ш.).
@(private = "file")
EARTH_LAND_10 := [18]f64{1.0, 0.73, 0.17, 0.01, 0.03, 0.11, 0.24, 0.22, 0.24, 0.23, 0.26, 0.38, 0.43, 0.52, 0.56, 0.71, 0.38, 0.10}

climate_earth :: proc() -> (cm: Climate, atmo: Atmosphere) {
	land: [CLIM_LAT]f32
	for i in 0 ..< CLIM_LAT {
		lat := -89 + 2 * f64(i)
		x := (lat + 90) / 10 - 0.5
		k0 := clamp(int(math.floor(x)), 0, 16)
		f := clamp(x - f64(k0), 0, 1)
		land[i] = f32(math.lerp(EARTH_LAND_10[k0], EARTH_LAND_10[k0 + 1], f))
	}
	atmo = atmosphere_make({
		mass_earth = 1, radius_km = 6371, gravity_g = 1, flux = 1, star_teff = 5772, star_class = .G, age_gyr = 4.55,
		water = 2.3e-4, seed = 1, fixed_co2 = 70, fixed_n2 = 0.78, fixed = true,
	})
	atmo.t_surface = 288.15 // средняя Земли
	cm = climate_make({
		star_lum       = 1,
		orbit_au       = 1,
		ecc            = 0.0167,
		peri           = math.to_radians(283.0 - 180), // перигелий — 3 января (солнце на долготе 283°)
		tilt           = math.to_radians(23.44),
		tilt_dir       = math.to_radians(90.0), // летнее солнцестояние — солнце на долготе 90°
		sidereal_hours = 23.934,
		year_hours     = EARTH_YEAR_HOURS,
		atmo           = &atmo,
		radius_km      = 6371,
		gravity_g      = 1,
		land           = land[:],
	})
	return
}

climate_report :: proc() -> (errors: int) {
	fail :: proc(errors: ^int, what: string) {
		errors^ += 1
		fmt.printfln("  ОШИБКА: %s", what)
	}
	cm, _ := climate_earth()
	fmt.println("=== Климат Земли по модели ===")
	fmt.printfln("средняя за год %.1f °C (задано 15), осадков %.0f мм в год; перенос тепла ×%.2f от земного; излучение A = %.1f Вт/м²",
		cm.global_t, cm.global_p, cm.d_ratio, cm.a_olr)
	fmt.printfln("ячейка Хэдли до %.0f°, пояс циклонов ~%.0f°", cm.hadley, cm.storm)
	// летнее и зимнее солнцестояние на севере: сезоны с наибольшим и наименьшим склонением
	jul, jan := 0, 0
	{
		best, worst := -1.0e9, 1.0e9
		for k in 0 ..< CLIM_SEASON {
			c := Climate_Point{lat = 45, cont = 0.5, wet = 1, land = true}
			t, _ := climate_at(&cm, &c, (f64(k) + 0.5) / CLIM_SEASON)
			if t > best do best, jul = t, k
			if t < worst do worst, jan = t, k
		}
	}
	fmt.println("широта   за год   суша зимой/летом   море зимой/летом   осадки, мм/год   (зима/лето — северные)")
	for lat := 80; lat >= -80; lat -= 10 {
		i := (lat + 89) / 2
		ann, p := 0.0, 0.0
		for k in 0 ..< CLIM_SEASON {
			fl := f64(cm.land[i])
			ann += (fl * f64(cm.t_land[i][k]) + (1 - fl) * f64(cm.t_ocean[i][k])) / CLIM_SEASON
			p += f64(cm.p_zonal[i][k]) * 12 / CLIM_SEASON
		}
		fmt.printfln("%s %s %s %s %s", pad(fmt.tprintf("%d°", lat), 8), pad(fmt.tprintf("%.1f", ann), 8),
			pad(fmt.tprintf("%.0f / %.0f", cm.t_land[i][jan], cm.t_land[i][jul]), 18),
			pad(fmt.tprintf("%.0f / %.0f", cm.t_ocean[i][jan], cm.t_ocean[i][jul]), 18), fmt.tprintf("%.0f", p))
	}
	fmt.printfln("экватор %.1f °C, северный полюс %.1f, южный %.1f (на уровне моря)", cm.equator_t, cm.pole_n_t, cm.pole_s_t)
	if abs(cm.global_t - 15) > 0.5 do fail(&errors, "средняя температура не сошлась")
	if cm.equator_t < 23 || cm.equator_t > 30 do fail(&errors, "температура на экваторе (на деле ~27 °C)")
	if cm.pole_n_t < -32 || cm.pole_n_t > -8 do fail(&errors, "Арктика (на деле ~ −18 °C)")
	if cm.pole_s_t > -15 do fail(&errors, "Антарктида у моря должна быть морозной")
	i60 := (61 + 89) / 2
	amp_land := f64(cm.t_land[i60][jul] - cm.t_land[i60][jan])
	amp_ocean := f64(cm.t_ocean[i60][jul] - cm.t_ocean[i60][jan])
	fmt.printfln("годовой ход на 61° с.ш.: в глубине материка %.0f К, над океаном %.0f К (на деле ~40–60 и ~5–10)", amp_land, amp_ocean)
	if amp_land < 25 || amp_land > 65 do fail(&errors, "годовой ход в глубине материка")
	if amp_ocean > 16 do fail(&errors, "годовой ход над океаном слишком велик")
	if cm.hadley < 24 || cm.hadley > 36 do fail(&errors, "ширина ячейки Хэдли (на деле ~30°)")
	// пояса осадков за год
	p_ann: [CLIM_LAT]f64
	for i in 0 ..< CLIM_LAT do for k in 0 ..< CLIM_SEASON do p_ann[i] += f64(cm.p_zonal[i][k]) * 12 / CLIM_SEASON
	wet_i, dry_n, dry_s := 0, 0, 0
	for i in 0 ..< CLIM_LAT {
		lat := -89 + 2 * i
		if p_ann[i] > p_ann[wet_i] do wet_i = i
		if lat >= 5 && lat <= 45 && (dry_n == 0 || p_ann[i] < p_ann[dry_n]) do dry_n = i
		if lat <= -5 && lat >= -45 && (dry_s == 0 || p_ann[i] < p_ann[dry_s]) do dry_s = i
	}
	fmt.printfln("больше всего дождей на %d°, сухие пояса на %d° и %d°", -89 + 2 * wet_i, -89 + 2 * dry_n, -89 + 2 * dry_s)
	if abs(-89 + 2 * wet_i) > 12 do fail(&errors, "дождевой пояс должен быть у экватора")
	if abs(-89 + 2 * dry_n) < 15 || abs(-89 + 2 * dry_n) > 35 do fail(&errors, "северный пояс пустынь (на деле 20–30°)")
	if abs(-89 + 2 * dry_s) < 15 || abs(-89 + 2 * dry_s) > 35 do fail(&errors, "южный пояс пустынь")

	// типичные места
	Place :: struct {
		name:       string,
		c:          Climate_Point,
		want:       string, // ожидаемые буквы (префикс)
		must:       bool,
	}
	places := []Place {
		{"экваториальный лес у моря (3°)", {lat = 3, cont = 0.4, wet = 1.0, land = true}, "A", true},
		{"тропики в глубине материка (13°)", {lat = 13, cont = 0.8, wet = 0.75, land = true}, "Aw", false},
		{"Сахара: глубь материка (25°)", {lat = 25, cont = 0.95, wet = 0.4, land = true}, "BW", true},
		{"Средиземноморье: запад материка (38°)", {lat = 38, cont = 0.45, wet = 0.9, land = true}, "Cs", false},
		{"Западная Европа у моря (50°)", {lat = 50, cont = 0.2, wet = 1.0, land = true}, "C", true},
		{"Подмосковье (55°, глубь материка)", {lat = 55, cont = 0.9, wet = 0.75, land = true}, "D", true},
		{"степь Казахстана (48°, далеко от моря)", {lat = 48, cont = 1.0, wet = 0.45, land = true}, "BS", false},
		{"тайга Сибири (62°)", {lat = 62, cont = 0.95, wet = 0.7, land = true}, "Dfc", true},
		{"тундра (70°)", {lat = 70, cont = 0.6, wet = 0.6, land = true}, "ET", true},
		{"ледник Гренландии (75°, 2500 м)", {lat = 75, alt = 2500, cont = 0.8, wet = 0.4, land = true}, "EF", true},
		{"Альпы (46°, 3500 м)", {lat = 46, alt = 3500, cont = 0.75, wet = 1.2, land = true}, "E", true},
	}
	fmt.println("Типичные места (тип климата по Кёппену):")
	for &pl in places {
		k, t, p := climate_classify(&cm, &pl.c)
		code := koppen_text(k)
		t_min, t_max, p_sum := 1.0e9, -1.0e9, 0.0
		for m in 0 ..< 12 {
			t_min = min(t_min, t[m])
			t_max = max(t_max, t[m])
			p_sum += p[m]
		}
		ok := len(code) >= len(pl.want) && code[:len(pl.want)] == pl.want
		fmt.printfln("  %s %s %s %s ожидалось %s%s", pad(pl.name, 40), pad(code, 4), pad(BIOME_NAMES[k.biome], 18),
			pad(fmt.tprintf("%.0f…%.0f °C, %.0f мм", t_min, t_max, p_sum), 22), pl.want, ok ? "" : pl.must ? "  — НЕ СОВПАЛО" : "  — не совпало (допустимо)")
		if !ok && pl.must do fail(&errors, fmt.tprintf("климат: %s", pl.name))
	}
	alps := Climate_Point{lat = 46, cont = 0.75, wet = 1.2, land = true}
	tree := climate_height_of(&cm, &alps, 10)
	snow := climate_height_of(&cm, &alps, 0)
	fmt.printfln("Альпы (46°): граница леса %.0f м (на деле ~2000), снеговая линия %.0f м (на деле ~2800–3200)", tree, snow)
	if tree < 1100 || tree > 2700 do fail(&errors, "граница леса в Альпах (модель грубая: лето в средних широтах на 2–3° прохладнее)")
	if snow < 2300 || snow > 4200 do fail(&errors, "снеговая линия в Альпах")

	// миры, где высаживаемся: доля суши под каждой природной зоной
	fmt.println()
	fmt.println("Миры высадки (зерна 1–8): доля суши под зонами, %")
	for seed in u32(1) ..= 8 {
		u: Universe
		universe_init(&u, seed)
		home := universe_find_home(&u)
		sys := star_system_generate(seed, home.star, false)
		planet_physics(&sys, home.planet, false)
		p := &sys.planets[home.planet]
		share: [Biome]int
		land := 0
		N :: 3000
		for i in 0 ..< N {
			y := 1 - (f64(i) + 0.5) / N * 2
			dir := geo_from_latlon(math.to_degrees(math.asin(y)), math.mod(f64(i) * 137.50776405, 360))
			pm := dir * p.radius_km * 1000
			alt := elevation(i64(seed), pm, 2000)
			if alt <= 0 do continue
			cp := climate_point(&climate, i64(seed), pm, alt)
			k, _, _ := climate_classify(&climate, &cp)
			share[k.biome] += 1
			land += 1
		}
		line := ""
		for b in Biome {
			if share[b] == 0 do continue
			part := fmt.tprintf("%s %.0f", BIOME_NAMES[b], f64(share[b]) / f64(max(land, 1)) * 100)
			line = line == "" ? part : fmt.tprintf("%s, %s", line, part)
		}
		fmt.printfln("  %d: %.1f °C, наклон %.0f°, сутки %.0f ч, Хэдли %.0f° — %s", seed, climate.global_t, p.axial_tilt_deg, p.day_hours, climate.hadley, line)
		star_system_destroy(&sys)
		universe_destroy(&u)
		free_all(context.temp_allocator)
	}
	fmt.printfln("ошибок: %d", errors)
	return
}
