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
LINE_BG :: [4]u8{40, 40, 40, 150}

// Строка панели: несколько кусков текста в фиксированных колонках.
@(private = "file")
Panel :: struct {
	x, y, px: f32,
}

@(private = "file")
panel_line :: proc(p: ^Panel, color: [4]u8, parts: ..string) {
	// колонки для таблицы планет (в пикселях шрифта)
	COLS := [?]f32{0, 16, 106, 156}
	right: f32 = 0
	for part, i in parts {
		col := len(parts) > 1 ? COLS[min(i, len(COLS) - 1)] : 0
		right = max(right, col + eng.text_width(part, 1))
	}
	if right > 0 {
		eng.imm_rect(p.x - p.px, p.y - p.px, p.x + (right + 1) * p.px, p.y + (eng.TEXT_LINE_HEIGHT - 1) * p.px, LINE_BG)
	}
	for part, i in parts {
		col := len(parts) > 1 ? COLS[min(i, len(COLS) - 1)] : 0
		eng.draw_text(part, p.x + col * p.px, p.y, p.px, color)
	}
	p.y += eng.TEXT_LINE_HEIGHT * p.px
}

@(private = "file")
panel_gap :: proc(p: ^Panel) {
	p.y += eng.TEXT_LINE_HEIGHT * p.px / 2
}

hud_draw_clock :: proc(c: ^Game_Clock, width, height: i32) {
	g := gui_scale(height)
	day, h, m := clock_local(c)
	text := fmt.tprintf("День %d  %02d:%02d", day, h, m)
	w := eng.text_width(text, g)
	x := f32(width) - w - 6 * g
	y := 6 * g
	eng.imm_rect(x - 3 * g, y - 3 * g, x + w + 3 * g, y + 10 * g, {0, 0, 0, 110})
	eng.draw_text(text, x, y, g, WHITE)
}

@(private = "file")
lat_text :: proc(lat: f64) -> string {
	return fmt.tprintf("%.1f° %s", abs(lat), lat >= 0 ? "с.ш." : "ю.ш.")
}

@(private = "file")
lon_text :: proc(lon: f64) -> string {
	return lon <= 180 ? fmt.tprintf("%.1f° в.д.", lon) : fmt.tprintf("%.1f° з.д.", 360 - lon)
}

hud_draw_debug :: proc(s: ^Star_System, w: ^World, c: ^Game_Clock, player: ^Character, fps: f64, chunks_drawn, chunks_loaded: int, width, height: i32) {
	g := gui_scale(height)
	p := Panel{x = 4 * g, y = 4 * g, px = g}
	star := &s.star
	hp := home_planet(s)
	home := &s.home

	panel_line(&p, WHITE, fmt.tprintf("Voxel %s  —  %d FPS", VERSION, int(fps + 0.5)))
	panel_line(&p, WHITE, fmt.tprintf("XYZ: %.2f / %.2f / %.2f", player.pos.x, player.pos.y, player.pos.z))
	panel_line(&p, WHITE, fmt.tprintf("Чанков: %d видно, %d загружено", chunks_drawn, chunks_loaded))
	panel_line(&p, WHITE, fmt.tprintf("Зерно мира: %d", s.seed))
	panel_gap(&p)

	day, h, m := clock_local(c)
	panel_line(&p, GOLD, fmt.tprintf("Время: день %d, %02d:%02d (местное)", day, h, m))
	panel_line(&p, WHITE, fmt.tprintf("Сутки: %.1f ст. ч = %.1f мин; прошло %.2f ст. ч", c.day_hours, clock_day_real_minutes(c), c.std_hours))
	panel_line(&p, GRAY, "1 стандартный час = 100 секунд")
	panel_gap(&p)

	panel_line(&p, GOLD, fmt.tprintf("Звезда: %s — %s, %.0f K", star.name, STAR_CLASS_NAMES[star.class], star.temperature))
	panel_line(&p, WHITE, fmt.tprintf("масса %.2f, светимость %.2f, радиус %.2f (Солнце = 1)", star.mass, star.luminosity, star.radius))
	panel_line(&p, GOLD, fmt.tprintf("Планет: %d", s.planet_count))
	for i in 0 ..< s.planet_count {
		pl := &s.planets[i]
		here := i == home.index
		col := here ? GOLD : WHITE
		mark := here ? "  < мы здесь" : ""
		panel_line(&p, col,
			fmt.tprintf("%d.", i + 1),
			PLANET_KIND_NAMES[pl.kind],
			fmt.tprintf("%.2f а.е.", pl.orbit_au),
			fmt.tprintf("R %.0f км%s", pl.radius_km, mark),
		)
	}
	panel_gap(&p)

	panel_line(&p, GOLD, fmt.tprintf("Наша планета: %s", hp.name))
	panel_line(&p, WHITE, fmt.tprintf("радиус %.0f км (%.2f Земли), гравитация %.2f g", hp.radius_km, hp.radius_km / EARTH_RADIUS_KM, home.gravity_g))
	panel_line(&p, WHITE, fmt.tprintf("сутки %.1f ст. ч, наклон оси %.1f°", home.day_hours, home.axial_tilt_deg))
	panel_line(&p, WHITE, fmt.tprintf("год %.1f местных суток (%.2f земного)", home.year_days, hp.year_hours / EARTH_YEAR_HOURS))
	if home.moon_count == 0 {
		panel_line(&p, WHITE, "лун нет")
	}
	for i in 0 ..< home.moon_count {
		mo := &home.moons[i]
		panel_line(&p, WHITE, fmt.tprintf("луна %d: R %.0f км, орбита %.0f тыс. км, период %.1f сут", i + 1, mo.radius_km, mo.orbit_km / 1000, mo.period_hours / home.day_hours))
	}
	panel_gap(&p)

	// где мы на шаре — считается по текущей позиции
	geo := &w.geo
	dir := geo_dir(geo, geo.face, player.pos.x, player.pos.z)
	lat, lon := geo_latlon(dir)
	panel_line(&p, GOLD, fmt.tprintf("Мы: широта %s, долгота %s", lat_text(lat), lon_text(lon)))
	panel_line(&p, WHITE, fmt.tprintf("грань куба: %s, до ребра %.1f км", FACE_NAMES[geo.face], geo_edge_dist(geo, player.pos.x, player.pos.z) / 1000))
	panel_line(&p, WHITE, fmt.tprintf("над уровнем моря: %.0f м; окружность планеты %.0f км", player.pos.y - (SEA_LEVEL + 1), 2 * 3.14159265 * geo.radius / 1000))
}

// Рисует весь текстовый интерфейс (вызывать с включённым смешиванием).
hud_draw :: proc(fp: ^Frame_Params) {
	ortho := linalg.matrix_ortho3d_f32(0, f32(fp.width), f32(fp.height), 0, -1, 1)
	hud_draw_clock(fp.clock, fp.width, fp.height)
	if fp.show_debug {
		hud_draw_debug(fp.system, fp.world, fp.clock, fp.player, fp.fps, fp.chunks_drawn, len(fp.world.chunks), fp.width, fp.height)
	}
	eng.imm_flush(ortho)
	if fp.show_debug do hud_draw_globe(fp, ortho)
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
	dir := geo_dir(geo, geo.face, fp.player.pos.x, fp.player.pos.z)
	marker, visible := globe_draw(fp.globe, dir, fp.time, x, y, size, fp.height)
	gl.Viewport(0, 0, fp.width, fp.height)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.Disable(gl.CULL_FACE)

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
