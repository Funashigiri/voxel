package main

// Текстовый интерфейс: часы в правом верхнем углу и панель F3
// (как экран отладки в Minecraft) со сведениями о мире и звёздной системе.

import "core:fmt"
import "core:math/linalg"
import eng "engine"

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

hud_draw_debug :: proc(s: ^Star_System, c: ^Game_Clock, player: ^Character, fps: f64, chunks_drawn, chunks_loaded: int, width, height: i32) {
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
	panel_line(&p, WHITE, fmt.tprintf("мы на широте %s, долготе %s", lat_text(home.latitude_deg), lon_text(home.longitude_deg)))
}

// Рисует весь текстовый интерфейс (вызывать с включённым смешиванием).
hud_draw :: proc(fp: ^Frame_Params) {
	hud_draw_clock(fp.clock, fp.width, fp.height)
	if fp.show_debug {
		hud_draw_debug(fp.system, fp.clock, fp.player, fp.fps, fp.chunks_drawn, len(fp.world.chunks), fp.width, fp.height)
	}
	eng.imm_flush(linalg.matrix_ortho3d_f32(0, f32(fp.width), f32(fp.height), 0, -1, 1))
}
