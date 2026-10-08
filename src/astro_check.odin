package main

// Самопроверка неба (-sky): год в точке высадки — проверки против
// независимого счёта (высота солнца в полдень, восход и закат, ход часов,
// смена дней и времён года) и ближайшие затмения, видимые отсюда.

import "core:fmt"
import "core:math"

@(private = "file")
Eclipse :: struct {
	T:     f64, // момент наибольшей фазы, ст. ч
	depth: f64, // закрытая доля солнца / глубина тени луны
	day:   int,
	hours: f64, // местное время
	moon:  int,
}

astro_report :: proc(a: ^Astro, s: ^Star_System, d: [3]f64) -> (errors: int) {
	// оси кадра для проверок не важны — берём любые касательные
	ex := [3]f64{d.z, 0, -d.x}
	if len3(ex) < 1e-9 do ex = {1, 0, 0}
	ex /= len3(ex)
	ez := [3]f64{d.y * ex.z - d.z * ex.y, d.z * ex.x - d.x * ex.z, d.x * ex.y - d.y * ex.x}
	at :: proc(a: ^Astro, T: f64, d, ex, ez: [3]f64) -> Sky_State {return astro_update(a, T, d, ex, ez)}
	hm :: proc(h: f64) -> string {
		if h < 0 do return "  —  "
		m := int(math.floor(h * 60 + 0.5)) %% (24 * 60)
		return fmt.tprintf("%02d:%02d", m / 60, m % 60)
	}
	fail :: proc(errors: ^int, what: string) {
		errors^ += 1
		fmt.printfln("  ОШИБКА: %s", what)
	}

	home := &s.home
	hp := home_planet(s)
	day := a.day
	st0 := at(a, 0, d, ex, ez)
	fmt.printfln("=== Небо в точке высадки (широта %.2f°) ===", st0.latitude)
	fmt.printfln("сутки %.2f ст. ч, год %.1f местных суток, наклон оси %.1f°, эксцентриситет %.3f, лун %d",
		day, a.year_days, home.axial_tilt_deg, hp.ecc, a.moon_n)
	fmt.println("день года  время года (север)  до звезды  склонение  полдень: высота (формула)  восход  закат  (счёт)        день")

	// --- год по месяцам: полдень и восход/закат — перебором по минутам
	MONTHS :: 12
	for k in 0 ..< MONTHS {
		T0 := f64(k) * a.planet.period / MONTHS
		T0 += (24 - at(a, T0, d, ex, ez).local_hours) * day / 24 // от местной полуночи
		step := day / 1440 // местная минута
		best, best_T := -1000.0, T0
		rise, set := -1.0, -1.0
		prev := at(a, T0, d, ex, ez)
		h0 := -0.57 - math.to_degrees(prev.sun_ang_r)
		for i in 1 ..= 1440 {
			T := T0 + f64(i) * step
			cur := at(a, T, d, ex, ez)
			if cur.sun_elev > best do best, best_T = cur.sun_elev, T
			if prev.sun_elev < h0 && cur.sun_elev >= h0 do rise = cur.local_hours
			if prev.sun_elev >= h0 && cur.sun_elev < h0 do set = cur.local_hours
			prev = cur
		}
		noon := at(a, best_T, d, ex, ez)
		formula := 90 - abs(noon.latitude - noon.decl)
		dl := noon.polar == 0 ? hm(noon.day_length) : noon.polar > 0 ? "полярный день" : "полярная ночь"
		fmt.printfln("%s%s%.4f а.е.  %s%s%s%s  %s  (%s  %s)  %s",
			pad(fmt.tprintf("%d", noon.day_of_year), 11), pad(SEASON_NAMES[noon.season], 20), noon.sun_dist, pad(fmt.tprintf("%.1f°", noon.decl), 11),
			pad(fmt.tprintf("%.1f°", best), 8), pad(fmt.tprintf("(%.1f°)", formula), 21),
			hm(noon.sunrise), hm(noon.sunset), hm(rise), hm(set), dl)
		// полуденная высота (выше горизонта) должна сходиться с формулой
		if formula < 89 && best > 0 && abs(best - formula) > 0.6 do fail(&errors, fmt.tprintf("полдень: %.2f° вместо %.2f°", best, formula))
		// восход и закат по формуле — с точностью до нескольких минут (склонение за день чуть меняется)
		tol := 10.0 / 60 + 24 * 2 / a.year_days * 0.1
		near :: proc(x, y, tol: f64) -> bool {
			dd := abs(x - y)
			return min(dd, 24 - dd) <= tol
		}
		if noon.polar == 0 && rise >= 0 && !near(rise, noon.sunrise, tol) do fail(&errors, fmt.tprintf("восход %s, по формуле %s", hm(rise), hm(noon.sunrise)))
		if noon.polar == 0 && set >= 0 && !near(set, noon.sunset, tol) do fail(&errors, fmt.tprintf("закат %s, по формуле %s", hm(set), hm(noon.sunset)))
		// расстояние до звезды — между перицентром и апоцентром
		if noon.sun_dist < hp.orbit_au * (1 - hp.ecc) * 0.9999 || noon.sun_dist > hp.orbit_au * (1 + hp.ecc) * 1.0001 {
			fail(&errors, "расстояние до звезды вне орбиты")
		}
		// за местные сутки — ровно один новый день, часы проходят 24 местных часа
		n1 := at(a, best_T + day, d, ex, ez)
		if n1.day - noon.day != 1 do fail(&errors, fmt.tprintf("за сутки прошло %d дней", n1.day - noon.day))
		hr := at(a, best_T + day / 24, d, ex, ez)
		dh := math.mod(hr.local_hours - noon.local_hours + 24, 24)
		if abs(dh - 1) > 0.01 do fail(&errors, fmt.tprintf("за местный час часы ушли на %.3f ч", dh))
	}

	// --- времена года идут по порядку
	prev_season := st0.season
	changes := 0
	for i in 1 ..= 400 {
		cur := at(a, f64(i) * a.planet.period / 400, d, ex, ez)
		if cur.season != prev_season {
			if cur.season != (prev_season + 1) % 4 do fail(&errors, "времена года идут не по порядку")
			changes += 1
			prev_season = cur.season
		}
	}
	if changes != 4 do fail(&errors, fmt.tprintf("за год сменилось %d времён года", changes))

	// --- затмения, видимые из точки высадки
	years := 2.0
	step := 0.05 // ст. ч
	if a.planet.period * years / step > 400_000 do years = 400_000 * step / a.planet.period
	solar := make([dynamic]Eclipse, context.temp_allocator)
	lunar := make([dynamic]Eclipse, context.temp_allocator)
	in_solar := false
	in_lunar := [MAX_MOONS]bool{}
	for T := 0.0; T < a.planet.period * years; T += step {
		cur := at(a, T, d, ex, ez)
		covered := 1 - cur.sun_visible
		if cur.sun_elev > 0 && covered > 0.005 {
			if !in_solar do append(&solar, Eclipse{})
			e := &solar[len(solar) - 1]
			if covered > e.depth do e^ = {T, covered, cur.day, cur.local_hours, 0}
			in_solar = true
		} else {
			in_solar = false
		}
		for i in 0 ..< cur.moon_n {
			m := &cur.moons[i]
			dark := 1 - m.shadow
			if m.elevation > 0 && cur.sun_elev < -6 && dark > 0.1 {
				if !in_lunar[i] do append(&lunar, Eclipse{moon = i})
				e := &lunar[len(lunar) - 1]
				if dark > e.depth do e^ = {T, dark, cur.day, cur.local_hours, i}
				in_lunar[i] = true
			} else {
				in_lunar[i] = false
			}
		}
	}
	fmt.printfln("затмения за %.1f года, видимые отсюда: солнечных %d, лунных %d", years, len(solar), len(lunar))
	for e, i in solar {
		if i >= 6 do break
		fmt.printfln("  солнечное: день %d, %s, закрыто %.0f%%  (-hours:%.2f)", e.day, hm(e.hours), e.depth * 100, e.T)
	}
	for e, i in lunar {
		if i >= 6 do break
		fmt.printfln("  лунное (луна %d): день %d, %s, в тени %.0f%%  (-hours:%.2f)", e.moon + 1, e.day, hm(e.hours), e.depth * 100, e.T)
	}
	fmt.printfln("ошибок: %d", errors)
	return
}
