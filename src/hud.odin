package main

// Текстовый интерфейс: часы в правом верхнем углу и панель F3
// (как экран отладки в Minecraft) со сведениями о мире и звёздной системе.

import "core:fmt"
import "core:math"
import "core:math/linalg"
import eng "engine"
import gl "vendor:OpenGL"

@(private = "file")
WHITE :: [4]u8{255, 255, 255, 255}
@(private = "file")
GRAY :: [4]u8{190, 190, 190, 255}
@(private = "file")
GOLD :: [4]u8{255, 214, 92, 255}
@(private = "file")
VIOLET :: [4]u8{196, 160, 255, 255}
@(private = "file")
LINE_BG :: [4]u8{40, 40, 40, 150}

// Строка панели: несколько кусков текста в фиксированных колонках.
@(private = "file")
Panel :: struct {
	x, y, px: f32,
	cols:     []f32, // колонки таблицы (в пикселях шрифта)
}

// колонки таблиц: планеты, ближайшие звёзды, ближайшие галактики
@(private = "file")
PLANET_COLS := [?]f32{0, 16, 106, 170}
@(private = "file")
STAR_COLS := [?]f32{0, 50, 162, 250}
@(private = "file")
GALAXY_COLS := [?]f32{0, 62, 208, 318}
@(private = "file")
SKYSTAR_COLS := [?]f32{0, 62, 182, 274}
@(private = "file")
SKYGAL_COLS := [?]f32{0, 62, 214, 264}

@(private = "file")
panel_line :: proc(p: ^Panel, color: [4]u8, parts: ..string) {
	cols := p.cols != nil ? p.cols : PLANET_COLS[:]
	right: f32 = 0
	for part, i in parts {
		col := len(parts) > 1 ? cols[min(i, len(cols) - 1)] : 0
		right = max(right, col + eng.text_width(part, 1))
	}
	if right > 0 {
		eng.imm_rect(p.x - p.px, p.y - p.px, p.x + (right + 1) * p.px, p.y + (eng.TEXT_LINE_HEIGHT - 1) * p.px, LINE_BG)
	}
	for part, i in parts {
		col := len(parts) > 1 ? cols[min(i, len(cols) - 1)] : 0
		eng.draw_text(part, p.x + col * p.px, p.y, p.px, color)
	}
	p.y += eng.TEXT_LINE_HEIGHT * p.px
}

@(private = "file")
panel_gap :: proc(p: ^Panel) {
	p.y += eng.TEXT_LINE_HEIGHT * p.px / 2
}

hud_draw_clock :: proc(st: ^Sky_State, width, height: i32) {
	g := gui_scale(height)
	text := fmt.tprintf("День %d  %s", st.day, hm_text(st.local_hours))
	w := eng.text_width(text, g)
	x := f32(width) - w - 6 * g
	y := 6 * g
	eng.imm_rect(x - 3 * g, y - 3 * g, x + w + 3 * g, y + 10 * g, {0, 0, 0, 110})
	eng.draw_text(text, x, y, g, WHITE)
}

// Местные часы -> "ЧЧ:ММ".
@(private = "file")
hm_text :: proc(hours: f64) -> string {
	m := int(math.floor(hours * 60)) %% (24 * 60)
	return fmt.tprintf("%02d:%02d", m / 60, m % 60)
}

// Освещённость: в темноте — с десятичными, днём — целыми люксами.
@(private = "file")
lux_text :: proc(lux: f64) -> string {
	switch {
	case lux < 1:
		return fmt.tprintf("%.3f лк", lux)
	case lux < 100:
		return fmt.tprintf("%.1f лк", lux)
	}
	return fmt.tprintf("%.0f лк", lux)
}

@(private = "file")
lat_text :: proc(lat: f64) -> string {
	return fmt.tprintf("%.1f° %s", abs(lat), lat >= 0 ? "с.ш." : "ю.ш.")
}

// Расстояние: до километра — в метрах, дальше — в км.
@(private = "file")
dist_text :: proc(d: f64) -> string {
	return d < 1000 ? fmt.tprintf("%.0f м", d) : fmt.tprintf("%.1f км", d / 1000)
}

@(private = "file")
lon_text :: proc(lon: f64) -> string {
	return lon <= 180 ? fmt.tprintf("%.1f° в.д.", lon) : fmt.tprintf("%.1f° з.д.", 360 - lon)
}

PAGE_TITLES := [F3_PAGES + 1]string{"", "мир и планета", "звёздная система", "галактика и вселенная", "звёздное небо", "строение планеты", "атмосфера"}
F3_PAGES :: 6

// Шапка любой страницы F3.
@(private = "file")
page_header :: proc(p: ^Panel, fp: ^Frame_Params) {
	panel_line(p, WHITE, fmt.tprintf("Voxel %s  —  %d FPS", VERSION, int(fp.fps + 0.5)))
	panel_line(p, GRAY, fmt.tprintf("F3: страница %d/%d — %s", fp.debug_page, F3_PAGES, PAGE_TITLES[fp.debug_page]))
	panel_gap(p)
}

// Страница 1: мир, время, наша планета и где мы на ней.
@(private = "file")
page_world :: proc(p: ^Panel, fp: ^Frame_Params) {
	s := fp.system
	w := fp.world
	player := fp.player
	c := fp.clock
	hp := home_planet(s)
	home := &s.home

	panel_line(p, WHITE, fmt.tprintf("XYZ: %.2f / %.2f / %.2f", player.pos.x, player.pos.y, player.pos.z))
	panel_line(p, WHITE, fmt.tprintf("Секций 16³: %d видно, %d загружено; колонок %d", fp.chunks_drawn, len(w.chunks), len(w.columns)))
	panel_line(p, WHITE, fmt.tprintf("Зерно мира: %d", s.seed))
	panel_gap(p)

	st := fp.sky_state
	panel_line(p, GOLD, fmt.tprintf("Время: день %d, %s (местное, по долготе)", st.day, hm_text(st.local_hours)))
	panel_line(p, WHITE, fmt.tprintf("Сутки: %.1f ст. ч = %.1f мин; прошло %.2f ст. ч", c.day_hours, clock_day_real_minutes(c), c.std_hours))
	panel_line(p, GRAY, c.timescale != 1 ? fmt.tprintf("1 стандартный час = 100 секунд; время ускорено ×%g", c.timescale) : "1 стандартный час = 100 секунд")
	eclipse := st.sun_visible < 0.999 ? fmt.tprintf("; затмение: закрыто %.0f%%", (1 - st.sun_visible) * 100) : ""
	panel_line(p, WHITE, fmt.tprintf("солнце: высота %.1f°, азимут %.0f°%s", st.sun_elev, st.sun_azim, eclipse))
	switch st.polar {
	case 1:
		panel_line(p, WHITE, "полярный день — солнце не заходит")
	case -1:
		panel_line(p, WHITE, "полярная ночь — солнце не восходит")
	case:
		dl := int(st.day_length * 60 + 0.5)
		panel_line(p, WHITE, fmt.tprintf("восход %s, закат %s, день %d ч %02d мин", hm_text(st.sunrise), hm_text(st.sunset), dl / 60, dl % 60))
	}
	panel_line(p, WHITE, fmt.tprintf("освещённость: %s", lux_text(st.lux * f64(fp.cloud_shade))))
	panel_gap(p)

	// дальность обзора, облака, скорость
	if ft := fp.far; ft != nil {
		panel_line(p, GOLD, fmt.tprintf("Обзор: горизонт (по морю) в %s, рельеф нарисован до %s", dist_text(ft.horizon), dist_text(ft.view_dist)))
		panel_line(p, WHITE, fmt.tprintf("тайлов рельефа: %d на экране, %d в памяти, строится %d", ft.drawn, len(ft.tiles), ft.pending))
	}
	if c := fp.clouds; c != nil {
		panel_line(p, WHITE, fmt.tprintf("облака: нижняя кромка %.0f м, облачность мира %.0f%%, над нами %.0f%%", c.height, c.cover * 100, fp.cloud_over * 100))
	}
	panel_line(p, WHITE, fmt.tprintf("кадр: %.1f мс", fp.frame_ms))
	panel_gap(p)

	panel_line(p, GOLD, fmt.tprintf("Наша планета: %s — %s", hp.name, body_type_name(&hp.body, hp.kind, false)))
	panel_line(p, WHITE, fmt.tprintf("радиус %.0f км (%.2f Земли), масса %.2f Земли, гравитация %.2f g", hp.radius_km, hp.radius_km / EARTH_RADIUS_KM, hp.mass_earth, home.gravity_g))
	panel_line(p, WHITE, fmt.tprintf("сутки %.1f ст. ч, наклон оси %.1f°", home.day_hours, home.axial_tilt_deg))
	panel_line(p, WHITE, fmt.tprintf("год %.1f местных суток (%.2f земного)", home.year_days, hp.year_hours / EARTH_YEAR_HOURS))
	panel_gap(p)

	// где мы на шаре — считается по текущей позиции
	geo := &w.geo
	dir := geo_frame_dir(geo, player.pos.x, player.pos.z)
	lat, lon := geo_latlon(dir)
	panel_line(p, GOLD, fmt.tprintf("Мы: широта %s, долгота %s", lat_text(lat), lon_text(lon)))
	panel_line(p, WHITE, fmt.tprintf("грань куба: %s, до ребра %s", FACE_NAMES[geo.face], dist_text(geo_edge_dist(geo, player.pos.x, player.pos.z))))
	_, _, anomaly := geo_nearest_corner(geo, player.pos.x, player.pos.z)
	panel_line(p, anomaly < ANOMALY_RADIUS ? VIOLET : WHITE, fmt.tprintf("до аномалии (вершины куба): %s", dist_text(anomaly)))
	panel_line(p, WHITE, fmt.tprintf("над уровнем моря: %.0f м; окружность планеты %.0f км", player.pos.y - Y_SEA, 2 * 3.14159265 * geo.radius / 1000))
	around := fp.around.y < 0 ? fmt.tprintf(", самое глубокое место %.0f м", -fp.around.y) : ""
	panel_line(p, WHITE, fmt.tprintf("вокруг (до 40 км): самая высокая точка %.0f м%s; океан мира — %.0f%% поверхности",
		fp.around.x, around, relief.ocean_frac * 100))
}

@(private = "file")
SYSTEM_COLS := [?]f32{0, 18, 166, 218, 284, 330, 480}

// Атмосфера тела коротко: давление и главный газ.
@(private = "file")
atmo_short :: proc(a: ^Atmosphere) -> string {
	switch a.kind {
	case .None:
		return "без воздуха"
	case .Envelope:
		return a.frac[.CH4] > 0.01 ? "H₂, He, CH₄" : "H₂, He"
	case .Thin, .Thick:
	}
	main_gas := Gas_Kind.N2
	for g in Gas_Kind do if a.frac[g] > a.frac[main_gas] do main_gas = g
	p := a.pressure < 0.01 ? fmt.tprintf("%.4f", a.pressure) : a.pressure < 10 ? fmt.tprintf("%.2f", a.pressure) : fmt.tprintf("%.0f", a.pressure)
	return fmt.tprintf("%s бар, %s", p, GAS_NAMES[main_gas])
}

// Страница 2: звезда, планеты, луны.
@(private = "file")
page_system :: proc(p: ^Panel, fp: ^Frame_Params) {
	s := fp.system
	star := &s.star
	home := &s.home

	panel_line(p, GOLD, fmt.tprintf("Звезда: %s — %s, %.0f K", star.name, STAR_CLASS_NAMES[star.class], star.temperature))
	panel_line(p, WHITE, fmt.tprintf("масса %.2f, светимость %.2f, радиус %.2f (Солнце = 1); возраст %.1f млрд лет из %.0f отпущенных",
		star.mass, star.luminosity, star.radius, s.age_gyr, star_lifetime_gyr(star.mass)))
	panel_line(p, WHITE, fmt.tprintf("зона жизни %.2f–%.2f а.е., снеговая линия %.1f а.е.; металлов %.0f%% от солнечного",
		s.hz_in_au, s.hz_out_au, s.frost_au, math.pow(10, s.metal) * 100))
	panel_line(p, GRAY, fmt.tprintf("планета для высадки нашлась у %d-й проверенной звезды", s.checked))
	panel_gap(p)
	// где мы на орбите сейчас, время года
	st := fp.sky_state
	hp := home_planet(s)
	panel_line(p, WHITE, fmt.tprintf("до звезды сейчас %.3f а.е. (от %.3f до %.3f, эксцентриситет %.3f)",
		st.sun_dist, hp.orbit_au * (1 - hp.ecc), hp.orbit_au * (1 + hp.ecc), hp.ecc))
	if home.axial_tilt_deg < 2 {
		panel_line(p, WHITE, fmt.tprintf("времён года почти нет (наклон оси %.1f°); день года %d из %.0f", home.axial_tilt_deg, st.day_of_year, home.year_days))
	} else {
		panel_line(p, WHITE, fmt.tprintf("время года: %s на севере, %s на юге; день года %d из %.0f",
			SEASON_NAMES[st.season], SEASON_NAMES[(st.season + 2) % 4], st.day_of_year, home.year_days))
	}
	panel_gap(p)
	panel_line(p, GOLD, fmt.tprintf("Планет: %d", s.planet_count))
	p.cols = SYSTEM_COLS[:]
	panel_line(p, GRAY, "", "вид", "орбита", "радиус", "°C", "атмосфера", "лун")
	for i in 0 ..< s.planet_count {
		pl := &s.planets[i]
		here := i == home.index
		temp := pl.atmo.kind == .Envelope ? fmt.tprintf("%s*", celsius(pl.atmo.t_surface - 273.15)) : celsius(pl.atmo.t_surface - 273.15)
		panel_line(p, here ? GOLD : WHITE,
			fmt.tprintf("%d.", i + 1),
			body_type_name(&pl.body, pl.kind, false),
			fmt.tprintf("%.2f а.е.", pl.orbit_au),
			fmt.tprintf("%.0f км", pl.radius_km),
			temp,
			atmo_short(&pl.atmo),
			here ? fmt.tprintf("%d  < мы", pl.moon_n) : fmt.tprintf("%d", pl.moon_n),
		)
	}
	p.cols = nil
	panel_line(p, GRAY, "* у гигантов — на уровне давления 1 бар (твёрдой поверхности нет)")
	panel_gap(p)

	panel_line(p, GOLD, fmt.tprintf("Луны планеты %s:", hp.name))
	if home.moon_count == 0 do panel_line(p, WHITE, "лун нет")
	for i in 0 ..< home.moon_count {
		mo := &hp.moons[i]
		panel_line(p, WHITE, fmt.tprintf("луна %d: %s, R %.0f км, орбита %.0f тыс. км, период %.1f сут", i + 1, body_type_name(&mo.body, .Rocky, true),
			mo.radius_km, mo.orbit_km / 1000, mo.period_hours / home.day_hours))
		sm := &st.moons[i]
		place := sm.elevation > 0 ? fmt.tprintf("над горизонтом, %.0f°", sm.elevation) : "за горизонтом"
		eclipse := sm.shadow < 0.95 ? "; лунное затмение" : ""
		panel_line(p, GRAY, fmt.tprintf("   %s, освещено %.0f%%, размер %.2f°; %s%s", moon_phase_name(sm), sm.lit * 100,
			math.to_degrees(sm.ang_r * 2), place, eclipse))
	}
}

// Страница 3: вселенная, наша галактика, ближайшие звёзды и галактики.
@(private = "file")
page_universe :: proc(p: ^Panel, fp: ^Frame_Params) {
	info := fp.universe
	u := info.u
	g := &info.home.galaxy
	pos := &info.home.star.pos

	panel_line(p, GOLD, fmt.tprintf("Вселенная: бесконечная, возраст %.1f млрд лет", u.age_years / 1e9))
	panel_line(p, WHITE, fmt.tprintf("расширение %.1f км/с на Мпк; горизонт событий %s", H0, ly_text(u.horizon_ly)))
	panel_line(p, WHITE, fmt.tprintf("видимая часть: радиус %s, галактик ~%s", ly_text(u.observable_ly), sci_text(info.observable_galaxies)))
	panel_line(p, GRAY, fmt.tprintf("мы, св. лет: X %s  Y %s  Z %s", big_grouped(pos.cell[0]), big_grouped(pos.cell[1]), big_grouped(pos.cell[2])))
	panel_gap(p)

	panel_line(p, GOLD, fmt.tprintf("Галактика: %s — %s", info.galaxy_name, GALAXY_KIND_NAMES[g.kind]))
	host := info.host_name != "" ? fmt.tprintf(", спутник галактики %s", info.host_name) : ""
	panel_line(p, WHITE, fmt.tprintf("звёзд %s, диаметр %s%s", count_text(g.stars), ly_text(galaxy_diameter(g)), host))
	panel_line(p, WHITE, fmt.tprintf("в центре чёрная дыра: %s масс Солнца", count_text(g.bh_mass)))
	panel_line(p, WHITE, fmt.tprintf("мы: %s", where_text(info)))
	panel_line(p, WHITE, fmt.tprintf("плотность звёзд: %.4f на кубический св. год", info.density))
	panel_gap(p)

	panel_line(p, GOLD, "Ближайшие звёзды:")
	p.cols = STAR_COLS[:]
	for s in info.stars {
		panel_line(p, WHITE, s.name, STAR_CLASS_NAMES[s.class], ly_text(s.dist), fmt.tprintf("планет: %d", s.planets))
	}
	p.cols = nil
	panel_gap(p)

	panel_line(p, GOLD, fmt.tprintf("Ближайшие галактики (в 10 млн св. лет — %d):", info.galaxies_10mly))
	p.cols = GALAXY_COLS[:]
	for ng in info.galaxies {
		motion := ng.bound ? "связана гравитацией" : fmt.tprintf("удаляется %.0f км/с", recession_kms(ng.dist))
		panel_line(p, WHITE, ng.name, GALAXY_KIND_NAMES[ng.kind], ly_text(ng.dist), motion)
	}
	if len(info.galaxies) == 0 do panel_line(p, WHITE, "в 13 млн св. лет — ни одной")
	p.cols = nil
}


// Страница 4: звёздное небо — звёзды, полярная звезда, пыль, планеты, галактики.
@(private = "file")
page_sky :: proc(p: ^Panel, fp: ^Frame_Params) {
	ss := fp.star_sky
	st := fp.sky_state
	if ss == nil || !ss.ready {
		panel_line(p, GOLD, "Звёздное небо ещё считается...")
		return
	}
	up := [3]f64{st.uni_to_frame[1, 0], st.uni_to_frame[1, 1], st.uni_to_frame[1, 2]}
	above, seen := 0, 0
	for &s in ss.stars {
		y := up.x * f64(s.dir.x) + up.y * f64(s.dir.y) + up.z * f64(s.dir.z)
		if y <= 0 do continue
		above += 1
		if f64(s.mag) + 0.2 * (1 / max(y + 0.03, 0.03) - 1) <= st.mag_limit do seen += 1
	}
	panel_line(p, GOLD, fmt.tprintf("Звёздное небо: глазом видно %d звёзд (всё небо, до %.1f величины)", len(ss.stars), MAG_LIMIT))
	if st.mag_limit < -1 {
		panel_line(p, WHITE, fmt.tprintf("сейчас светло — звёзд не видно (над горизонтом %d)", above))
	} else {
		panel_line(p, WHITE, fmt.tprintf("сейчас видно до %.1f величины: %d звёзд из %d над горизонтом", st.mag_limit, seen, above))
	}
	if star, ang := starsky_pole_star(ss, st.pole_uni); star != nil {
		panel_line(p, WHITE, fmt.tprintf("полярная звезда: %s, %.1f° от полюса мира, %.1f величины", star_name(star.seed, context.temp_allocator), ang, star.mag))
	} else {
		panel_line(p, WHITE, "полярной звезды нет — у полюса мира нет яркой звезды")
	}
	core := st.uni_to_frame * ss.core_dir
	panel_line(p, WHITE, fmt.tprintf("центр галактики: %s, высота %.0f°; пыль ослабляет его свет на %.1f величины",
		ly_text(ss.core_dist), math.to_degrees(math.asin(clamp(core.y, -1, 1))), ss.core_dust))
	panel_line(p, WHITE, fmt.tprintf("свет безлунной ночи: %s (звёзды, полоса галактики, свечение воздуха)", lux_text(st.night_lux)))
	panel_gap(p)

	panel_line(p, GOLD, "Самые яркие звёзды:")
	p.cols = SKYSTAR_COLS[:]
	for s, i in ss.stars {
		if i >= 7 do break
		panel_line(p, WHITE, star_name(s.seed, context.temp_allocator), STAR_CLASS_NAMES[s.class], ly_text(f64(s.dist)), fmt.tprintf("%.1f вел.", s.mag))
	}
	p.cols = nil
	panel_gap(p)

	panel_line(p, GOLD, "Планеты на небе:")
	p.cols = SKYSTAR_COLS[:]
	for i in 0 ..< st.planet_n {
		pl := &st.planets[i]
		where_ := pl.elevation < 0 ? "за горизонтом" : pl.mag + 0.2 * (1 / max(math.sin(math.to_radians(pl.elevation)) + 0.03, 0.03) - 1) <= st.mag_limit ? fmt.tprintf("видна, высота %.0f°", pl.elevation) : "не видна — светло"
		panel_line(p, WHITE, fp.system.planets[pl.index].name, PLANET_KIND_NAMES[fp.system.planets[pl.index].kind], fmt.tprintf("%.1f вел.", pl.mag), where_)
	}
	p.cols = nil
	panel_gap(p)

	panel_line(p, GOLD, fmt.tprintf("Галактики, видимые глазом: %d", len(ss.galaxies)))
	p.cols = SKYGAL_COLS[:]
	for g, i in ss.galaxies {
		if i >= 3 do break
		panel_line(p, WHITE, galaxy_name(g.seed, context.temp_allocator), GALAXY_KIND_NAMES[g.kind], fmt.tprintf("%.1f вел.", g.mag), fmt.tprintf("%.1f°, %s", g.size, ly_text(f64(g.dist))))
	}
	p.cols = nil
}

@(private = "file")
INTERIOR_COLS := [?]f32{0, 112, 184, 278, 360}
@(private = "file")
ATMO_COLS := [?]f32{0, 56, 140, 236, 326}

// Температура целыми градусами, без «−0».
@(private = "file")
celsius :: proc(t: f64) -> string {
	r := math.round(t)
	return fmt.tprintf("%.0f", r == 0 ? 0 : r)
}

@(private = "file")
gpa :: proc(p: f64) -> string {
	switch {
	case p < 0.1:
		return fmt.tprintf("%.3f", p)
	case p < 10:
		return fmt.tprintf("%.1f", p)
	}
	return fmt.tprintf("%.0f", p)
}

// Цвет слоя на разрезе планеты.
@(private = "file")
LAYER_COLORS := [Layer_Kind][4]u8 {
	.Crust_Cont   = {150, 120, 90, 255},
	.Crust_Ocean  = {90, 90, 96, 255},
	.Ice_Shell    = {214, 230, 240, 255},
	.Ocean        = {50, 90, 180, 255},
	.HP_Ice       = {150, 180, 210, 255},
	.Upper_Mantle = {120, 132, 80, 255},
	.Transition   = {82, 94, 140, 255},
	.Lower_Mantle = {120, 84, 60, 255},
	.D2           = {150, 80, 50, 255},
	.Outer_Core   = {240, 150, 50, 255},
	.Inner_Core   = {250, 236, 190, 255},
	.Core_Liquid  = {240, 150, 50, 255},
	.Core_Solid   = {200, 196, 186, 255},
	.Giant_Mantle = {80, 150, 190, 255},
	.Ice_Core     = {120, 170, 200, 255},
	.Molecular_H  = {214, 190, 150, 255},
	.Metallic_H   = {170, 150, 170, 255},
	.Rock_Core    = {150, 110, 80, 255},
	.Iron_Core    = {220, 140, 60, 255},
}

// Страница 5: строение планеты — слои, температуры, давление; тепло, поле; что под ногами.
@(private = "file")
page_interior :: proc(p: ^Panel, fp: ^Frame_Params) {
	pi := fp.interior
	if pi == nil do return
	hp := home_planet(fp.system)
	c := &hp.comp
	panel_line(p, GOLD, fmt.tprintf("Строение планеты %s", hp.name))
	panel_line(p, WHITE, fmt.tprintf("состав: железо %.0f%%, камень %.0f%%; средняя плотность %.2f г/см³ (Земля — %.2f)",
		c.iron * 100, c.rock * 100, pi.density, EARTH_DENSITY))
	solid_core := false
	for l in pi.layers[:pi.n] do if l.kind == .Core_Solid do solid_core = true
	inner := pi.inner_km > 0 ? fmt.tprintf(", твёрдое внутреннее — %.0f км", pi.inner_km) : solid_core ? ", застыло целиком" : ", жидкое целиком"
	panel_line(p, WHITE, fmt.tprintf("ядро из железа радиусом %.0f км (%.0f%% радиуса)%s", pi.core_km, pi.core_km / pi.radius_km * 100, inner))
	panel_gap(p)
	p.cols = INTERIOR_COLS[:]
	panel_line(p, GRAY, "слой", "глубина, км", "температура, °C", "давление, ГПа", "состояние")
	for l in pi.layers[:pi.n] {
		panel_line(p, l.liquid ? GOLD : WHITE, LAYER_NAMES[l.kind], fmt.tprintf("%.0f–%.0f", l.top_km, l.bottom_km),
			fmt.tprintf("%s → %s", celsius(l.t_top), celsius(l.t_bottom)), fmt.tprintf("%s → %s", gpa(l.p_top), gpa(l.p_bottom)), LAYER_STATES[l.kind])
	}
	p.cols = nil
	panel_line(p, GRAY, fmt.tprintf("в центре %s °C, %.0f ГПа (%.1f млн атмосфер), плотность %.1f г/см³",
		celsius(pi.center_t), pi.center_p, pi.center_p / 0.101325 / 1000, pi.center_rho))
	panel_gap(p)
	panel_line(p, WHITE, fmt.tprintf("тепло недр %.0f ТВт (распад урана, тория, калия — %.0f), поток %.0f мВт/м² (у Земли ~90)",
		pi.heat_tw, pi.radio_tw, pi.heat_flux * 1000))
	panel_line(p, WHITE, pi.plates ? "кора разбита на плиты — они движутся, растут горы, остывают недра" : "плит нет — кора сплошная «крышка»")
	if pi.magnetic_ut > 0 {
		panel_line(p, WHITE, fmt.tprintf("магнитное поле ~%.0f мкТл (у Земли ~45): жидкое железо перемешивается — динамо", pi.magnetic_ut))
	} else {
		panel_line(p, WHITE, solid_core ? "магнитного поля нет: ядро застыло — динамо не работает" : "магнитного поля нет: жидкий слой ядра не перемешивается")
	}
	panel_gap(p)

	// здесь: высота, порода, прогрев вглубь
	player := fp.player
	alt := player.pos.y - Y_SEA
	px, pz := i32(math.floor(player.pos.x)), i32(math.floor(player.pos.z))
	under: Block = .Air
	for y := i32(math.floor(player.pos.y)) - 1; y > i32(math.floor(player.pos.y)) - 8; y -= 1 {
		b, _ := world_get_block(fp.world, px, y, pz)
		if BLOCK_INFO[b].solid || b == .Water {
			under = b
			break
		}
	}
	panel_line(p, GOLD, fmt.tprintf("Здесь: %s над уровнем моря %.0f м, под ногами — %s", alt >= 0 ? "высота" : "глубина", abs(alt), BLOCK_NAMES[under]))
	a := &hp.atmo
	t_air := atmo_temperature(a, alt) - 273.15
	rock :: proc(pi: ^Planet_Interior, alt, t_air, d: f64) -> string {
		// под горой поверхность холоднее: разница гаснет с глубиной
		tc, _, _, _ := interior_at(pi, max(d - alt, 0))
		return celsius(tc + (t_air - pi.surface_c) * max(0, 1 - d / 30000))
	}
	panel_line(p, WHITE, fmt.tprintf("порода вглубь: 100 м — %s °C, 1 км — %s °C, 10 км — %s °C, 100 км — %s °C",
		rock(pi, alt, t_air, 100), rock(pi, alt, t_air, 1000), rock(pi, alt, t_air, 10000), rock(pi, alt, t_air, 100000)))
	if alt < -100 && under != .Water {
		tc, pg, _, kind := interior_at(pi, -alt)
		panel_line(p, VIOLET, fmt.tprintf("мы в недрах: %s, %s °C, %s ГПа", LAYER_NAMES[kind], celsius(tc), gpa(pg)))
	}
	panel_line(p, GRAY, "блоки идут вглубь по этому разрезу — до ядра (на практике недостижимо)")
}

// Страница 6: атмосфера — состав, давление и температура, слои; воздух здесь.
@(private = "file")
page_atmosphere :: proc(p: ^Panel, fp: ^Frame_Params) {
	hp := home_planet(fp.system)
	a := &hp.atmo
	panel_line(p, GOLD, fmt.tprintf("Атмосфера планеты %s: %.2f бар у моря (у Земли 1,01)", hp.name, a.pressure))
	// состав по убыванию
	order: [len(Gas_Kind)]Gas_Kind
	for g, i in Gas_Kind do order[i] = g
	for i in 1 ..< len(order) {
		for j := i; j > 0 && a.frac[order[j]] > a.frac[order[j - 1]]; j -= 1 do order[j], order[j - 1] = order[j - 1], order[j]
	}
	line := ""
	for g in order {
		f := a.frac[g]
		if f < 1e-5 do continue
		part := f >= 0.01 ? fmt.tprintf("%s %.0f%%", GAS_NAMES[g], f * 100) : f >= 1e-4 ? fmt.tprintf("%s %.2f%%", GAS_NAMES[g], f * 100) : fmt.tprintf("%s %.3f%%", GAS_NAMES[g], f * 100)
		line = line == "" ? part : fmt.tprintf("%s, %s", line, part)
	}
	panel_line(p, WHITE, fmt.tprintf("состав: %s", line))
	panel_line(p, WHITE, fmt.tprintf("у моря в среднем %s °C; без парникового эффекта было бы %s °C (отражает %.0f%% света)",
		celsius(a.t_surface - 273.15), celsius(a.t_eq - 273.15), a.albedo * 100))
	if a.co2_store > 0 {
		panel_line(p, WHITE, fmt.tprintf("углекислый газ: в воздухе %.3f мбар, в известняке ~%.0f бар — океаны и плиты держат климат",
			a.frac[.CO2] * a.pressure * 1000, a.co2_store))
	}
	panel_line(p, WHITE, fmt.tprintf("высота однородной атмосферы %.1f км: давление вдвое меньше на %.1f км", a.scale_h / 1000, a.scale_h * math.LN2 / 1000))
	strat := a.ozone ? "стратосфера с озоном" : "холодно, озона нет"
	panel_line(p, WHITE, fmt.tprintf("тропосфера до %.1f км (холодает на %.1f °C на км), выше — %s", a.tropopause / 1000, a.lapse * 1000, strat))
	sky := a.rayleigh > 1.3 ? "бледнее, белее у горизонта" : a.rayleigh < 0.75 ? "темнее и глубже" : "как у Земли"
	panel_line(p, WHITE, fmt.tprintf("рассеяние света ×%.2f от земного — небо %s; дымка ×%.1f", a.rayleigh, sky, a.density / EARTH_AIR_DENSITY))
	life := "жизни нет"
	switch {
	case a.plants:
		life = "жизнь в океанах и на суше; кислород — от растений"
	case a.life:
		life = "жизнь — только в воде"
	}
	panel_line(p, WHITE, life)
	panel_line(p, GRAY, fmt.tprintf("воздух держится: скорость убегания %.1f км/с, запас ×%.0f против излучения звезды", hp.v_esc, a.margin))
	panel_gap(p)

	// по высоте
	p.cols = ATMO_COLS[:]
	panel_line(p, GRAY, "высота", "давление, бар", "температура, °C", "кислород, кПа", "как на Земле на")
	for km in ([?]f64{0, 2, 5, 8, 12, 20, 50}) {
		z := km * 1000
		pr := atmo_pressure(a, z)
		panel_line(p, WHITE, fmt.tprintf("%.0f км", km), pr < 0.01 ? fmt.tprintf("%.4f", pr) : fmt.tprintf("%.3f", pr),
			celsius(atmo_temperature(a, z) - 273.15), fmt.tprintf("%.1f", pr * a.frac[.O2] * 100), pr > 1.013 ? "— (плотнее)" : dist_text(earth_equivalent_height(pr)))
	}
	p.cols = nil
	panel_gap(p)

	alt := fp.player.pos.y - Y_SEA
	pr := atmo_pressure(a, alt)
	o2 := pr * a.frac[.O2] * 100
	panel_line(p, GOLD, fmt.tprintf("Здесь (%.0f м): %.3f бар, %s °C, воздух %.2f кг/м³, кислород %.1f кПа",
		alt, pr, celsius(atmo_temperature(a, alt) - 273.15), pr * 1e5 * a.mu / (R_GAS * atmo_temperature(a, alt)), o2))
	breath := "дышится как у моря на Земле"
	switch {
	case o2 < 7:
		breath = "кислорода почти нет — без баллона смерть за минуты"
	case o2 < 11:
		breath = "мало кислорода — как выше 6 км на Земле: долго не протянуть"
	case o2 < 16:
		breath = fmt.tprintf("кислорода мало — как в горах на %.1f км: одышка, слабость", earth_equivalent_height(o2 / 21.2 * 1.013) / 1000)
	case o2 > 50:
		breath = "кислорода слишком много — со временем отравляет"
	}
	if co2 := pr * a.frac[.CO2] * 100; co2 > 1 {
		breath = fmt.tprintf("%s; углекислого газа %.1f кПа — %s", breath, co2, co2 > 5 ? "смертельно" : co2 > 3 ? "опасно" : "голова тяжелеет")
	}
	panel_line(p, WHITE, breath)
}

// Разрез планеты (слои — кольцами) в правом верхнем углу.
@(private = "file")
hud_draw_cutaway :: proc(fp: ^Frame_Params, ortho: matrix[4, 4]f32) {
	pi := fp.interior
	if pi == nil do return
	g := gui_scale(fp.height)
	size := 116 * g
	cx := f32(fp.width) - size / 2 - 6 * g
	cy := f32(fp.height) - size / 2 - 18 * g // в правом нижнем углу: справа сверху — текст
	eng.imm_rect(cx - size / 2, cy - size / 2, cx + size / 2, cy + size / 2 + 12 * g, {0, 0, 0, 90})
	disc :: proc(cx, cy, r: f32, color: [4]u8, half: bool) {
		SEG :: 64
		for k in 0 ..< SEG {
			a0 := f32(k) / SEG * math.TAU
			a1 := f32(k + 1) / SEG * math.TAU
			if half && math.cos((a0 + a1) / 2) < 0 do continue // половина — разрез, половина — поверхность
			p0 := eng.Vec3{cx + r * math.cos(a0), cy + r * math.sin(a0), 0}
			p1 := eng.Vec3{cx + r * math.cos(a1), cy + r * math.sin(a1), 0}
			eng.imm_quad({cx, cy, 0}, p0, p1, p1, color)
		}
	}
	R := size / 2 - 4 * g
	disc(cx, cy, R, {60, 90, 130, 255}, false) // поверхность — океаны и суша
	for l in pi.layers[:pi.n] {
		if l.kind == .Crust_Ocean do continue
		rr := R * f32(1 - l.top_km / pi.radius_km)
		disc(cx, cy, max(rr, 1), LAYER_COLORS[l.kind], true)
	}
	name := "разрез"
	nw := eng.text_width(name, g)
	eng.draw_text(name, cx - nw / 2, cy + size / 2 + 2 * g, g, GOLD)
	eng.imm_flush(ortho)
}

// Рисует весь текстовый интерфейс (вызывать с включённым смешиванием).
hud_draw :: proc(fp: ^Frame_Params) {
	ortho := linalg.matrix_ortho3d_f32(0, f32(fp.width), f32(fp.height), 0, -1, 1)
	hud_draw_clock(fp.sky_state, fp.width, fp.height)
	if fp.debug_page > 0 {
		g := gui_scale(fp.height)
		p := Panel{x = 4 * g, y = 4 * g, px = g}
		page_header(&p, fp)
		switch fp.debug_page {
		case 1:
			page_world(&p, fp)
		case 2:
			page_system(&p, fp)
		case 3:
			page_universe(&p, fp)
		case 4:
			page_sky(&p, fp)
		case 5:
			page_interior(&p, fp)
		case 6:
			page_atmosphere(&p, fp)
		}
	}
	eng.imm_flush(ortho)
	if fp.debug_page == 1 do hud_draw_globe(fp, ortho)
	if fp.debug_page == 5 do hud_draw_cutaway(fp, ortho)
}

// Глобус планеты в правом верхнем углу (под часами) с отметкой "мы здесь".
@(private = "file")
hud_draw_globe :: proc(fp: ^Frame_Params, ortho: matrix[4, 4]f32) {
	g := gui_scale(fp.height)
	size := 116 * g
	x := f32(fp.width) - size - 6 * g
	y := 20 * g
	eng.imm_rect(x, y, x + size, y + size + 12 * g, {0, 0, 0, 90})
	eng.imm_flush(ortho)

	geo := &fp.world.geo
	dir := geo_frame_dir(geo, fp.player.pos.x, fp.player.pos.z)
	view := globe_draw(fp.globe, dir, fp.sky_state.sun_body, fp.time, x, y, size, fp.height)
	gl.Viewport(0, 0, fp.width, fp.height)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.Disable(gl.CULL_FACE)

	// аномалии в вершинах куба
	for a in ANOMALY_DIRS {
		pos, facing := globe_project(view, a / math.sqrt(f64(3)))
		if !facing do continue
		r := 1.5 * g
		eng.imm_rect(pos.x - r - g, pos.y - r - g, pos.x + r + g, pos.y + r + g, {40, 20, 60, 200})
		eng.imm_rect(pos.x - r, pos.y - r, pos.x + r, pos.y + r, {176, 140, 230, 255})
	}
	marker, visible := globe_project(view, dir)
	if visible {
		blink := u8(170 + 85 * math.sin(fp.time * 6))
		r := 2 * g
		eng.imm_rect(marker.x - r - g, marker.y - r - g, marker.x + r + g, marker.y + r + g, {255, 255, 255, blink})
		eng.imm_rect(marker.x - r, marker.y - r, marker.x + r, marker.y + r, {230, 40, 30, 255})
	}
	name := home_planet(fp.system).name
	nw := eng.text_width(name, g)
	eng.draw_text(name, x + (size - nw) / 2, y + size + 2 * g, g, GOLD)
	eng.imm_flush(ortho)
}
