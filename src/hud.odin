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
PLANET_COLS := [?]f32{0, 16, 106, 156}
@(private = "file")
STAR_COLS := [?]f32{0, 50, 162, 250}
@(private = "file")
GALAXY_COLS := [?]f32{0, 62, 208, 318}

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

PAGE_TITLES := [4]string{"", "мир и планета", "звёздная система", "галактика и вселенная"}

// Шапка любой страницы F3.
@(private = "file")
page_header :: proc(p: ^Panel, fp: ^Frame_Params) {
	panel_line(p, WHITE, fmt.tprintf("Voxel %s  —  %d FPS", VERSION, int(fp.fps + 0.5)))
	panel_line(p, GRAY, fmt.tprintf("F3: страница %d/3 — %s", fp.debug_page, PAGE_TITLES[fp.debug_page]))
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
	panel_line(p, WHITE, fmt.tprintf("Чанков: %d видно, %d загружено", fp.chunks_drawn, len(w.chunks)))
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
	panel_line(p, WHITE, fmt.tprintf("освещённость: %s", lux_text(st.lux)))
	panel_gap(p)

	panel_line(p, GOLD, fmt.tprintf("Наша планета: %s", hp.name))
	panel_line(p, WHITE, fmt.tprintf("радиус %.0f км (%.2f Земли), гравитация %.2f g", hp.radius_km, hp.radius_km / EARTH_RADIUS_KM, home.gravity_g))
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
	panel_line(p, WHITE, fmt.tprintf("над уровнем моря: %.0f м; окружность планеты %.0f км", player.pos.y - (SEA_LEVEL + 1), 2 * 3.14159265 * geo.radius / 1000))
}

// Страница 2: звезда, планеты, луны.
@(private = "file")
page_system :: proc(p: ^Panel, fp: ^Frame_Params) {
	s := fp.system
	star := &s.star
	home := &s.home

	panel_line(p, GOLD, fmt.tprintf("Звезда: %s — %s, %.0f K", star.name, STAR_CLASS_NAMES[star.class], star.temperature))
	panel_line(p, WHITE, fmt.tprintf("масса %.2f, светимость %.2f, радиус %.2f (Солнце = 1)", star.mass, star.luminosity, star.radius))
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
	for i in 0 ..< s.planet_count {
		pl := &s.planets[i]
		here := i == home.index
		panel_line(p, here ? GOLD : WHITE,
			fmt.tprintf("%d.", i + 1),
			PLANET_KIND_NAMES[pl.kind],
			fmt.tprintf("%.2f а.е.", pl.orbit_au),
			fmt.tprintf("R %.0f км%s", pl.radius_km, here ? "  < мы здесь" : ""),
		)
	}
	panel_gap(p)

	panel_line(p, GOLD, fmt.tprintf("Луны планеты %s:", home_planet(s).name))
	if home.moon_count == 0 do panel_line(p, WHITE, "лун нет")
	for i in 0 ..< home.moon_count {
		mo := &home.moons[i]
		panel_line(p, WHITE, fmt.tprintf("луна %d: R %.0f км, орбита %.0f тыс. км, период %.1f сут", i + 1, mo.radius_km, mo.orbit_km / 1000, mo.period_hours / home.day_hours))
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
		}
	}
	eng.imm_flush(ortho)
	if fp.debug_page == 1 do hud_draw_globe(fp, ortho)
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
