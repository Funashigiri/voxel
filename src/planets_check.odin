package main

// Проверка модели планет (-planets): тела Солнечной системы — по их массе,
// составу (как его оценивают учёные) и свету Солнца модель считает радиус,
// недра и атмосферу, это сверяется с настоящими значениями. Затем —
// статистика по тысячам случайных систем: какие планеты выходят и как часто
// находится планета для высадки.

import "core:fmt"
import "core:time"
import eng "engine"

@(private = "file")
Sol_Body :: struct {
	name:      string,
	mass:      f64, // масс Земли
	comp:      Composition,
	water:     f64,
	flux:      f64, // свет Солнца, Земля = 1
	radius:    f64, // настоящий, км
	tol:       f64, // допуск по радиусу
	t_real:    f64, // настоящая средняя температура поверхности, К (0 — не проверять)
	t_tol:     f64,
	co2, n2:   f64, // запас газов, бар (0 — случайный)
	kind:      Planet_Kind,
	icy:       bool,
	plates:    bool,
	tidal:     f64, // Вт
	atmo_real: string, // как на самом деле
	strip:     f64, // магнитосфера гиганта сдувает (Ио, Европа, Ганимед, Каллисто, Титан)
}

planets_report :: proc() -> (errors: int) {
	fail :: proc(errors: ^int, what: string) {
		errors^ += 1
		fmt.printfln("  ОШИБКА: %s", what)
	}
	bodies := []Sol_Body {
		{"Меркурий", 0.0553, {0.68, 0.32, 0, 0}, 0, 6.67, 2440, 0.03, 0, 0, 0, 0, .Rocky, false, false, 0, "нет", 0},
		{"Венера", 0.815, {0.30, 0.70, 0, 0}, 1e-4, 1.91, 6052, 0.03, 737, 50, 92, 3.3, .Rocky, false, false, 0, "92 бара CO₂, 737 К", 0},
		{"Земля", 1.0, {0.325, 0.675, 0, 0}, 2.3e-4, 1.0, 6371, 0.03, 288, 6, 70, 0.78, .Rocky, false, true, 0, "1 бар, N₂ и O₂, 288 К", 0},
		{"Луна", 0.0123, {0.02, 0.98, 0, 0}, 0, 1.0, 1737, 0.03, 0, 0, 0, 0, .Rocky, false, false, 0, "нет", 0},
		{"Марс", 0.1074, {0.24, 0.76, 0, 0}, 1e-4, 0.431, 3390, 0.03, 210, 15, 25, 0.5, .Rocky, false, false, 0, "0,006 бара CO₂, 210 К", 0},
		{"Ио", 0.01496, {0.20, 0.80, 0, 0}, 0, 0.037, 1822, 0.04, 0, 0, 0, 0, .Rocky, false, false, 1e14, "следы SO₂", 7.4},
		{"Европа", 0.008, {0.15, 0.77, 0.08, 0}, 0, 0.037, 1561, 0.04, 0, 0, 0, 0, .Rocky, true, false, 3e12, "следы O₂", 5.0},
		{"Ганимед", 0.0248, {0.12, 0.42, 0.46, 0}, 0, 0.037, 2634, 0.04, 0, 0, 0, 0, .Rocky, true, false, 0, "следы O₂", 3.5},
		{"Каллисто", 0.018, {0.05, 0.50, 0.45, 0}, 0, 0.037, 2410, 0.04, 0, 0, 0, 0, .Rocky, true, false, 0, "следы CO₂", 2.4},
		{"Титан", 0.0225, {0.05, 0.52, 0.43, 0}, 0, 0.011, 2575, 0.04, 94, 8, 0, 2.2, .Rocky, true, false, 0, "1,5 бара N₂ и CH₄, 94 К", 1.15},
		{"Тритон", 0.00359, {0.05, 0.65, 0.30, 0}, 0, 0.0011, 1353, 0.05, 0, 0, 0, 0, .Rocky, true, false, 0, "0,00001 бара N₂", 0},
		{"Юпитер", 317.8, {0.016, 0.032, 0.032, 0.92}, 0, 0.037, 69911, 0.08, 0, 0, 0, 0, .Gas_Giant, false, false, 0, "H₂ и He", 0},
		{"Сатурн", 95.16, {0.065, 0.13, 0.13, 0.675}, 0, 0.011, 58232, 0.08, 0, 0, 0, 0, .Gas_Giant, false, false, 0, "H₂ и He", 0},
		{"Уран", 14.54, {0.06, 0.14, 0.75, 0.05}, 0, 0.0027, 25362, 0.08, 0, 0, 0, 0, .Ice_Giant, false, false, 0, "H₂, He, CH₄", 0},
		{"Нептун", 17.15, {0.06, 0.14, 0.76, 0.04}, 0, 0.0011, 24622, 0.08, 0, 0, 0, 0, .Ice_Giant, false, false, 0, "H₂, He, CH₄", 0},
	}
	fmt.println("=== Модель планет на Солнечной системе (возраст 4,55 млрд лет) ===")
	fmt.println("тело      радиус: модель / на деле     тяжесть  в центре          ядро (твёрдое)   поле     атмосфера: модель — на деле")
	t0 := time.now()
	for &b in bodies {
		albedo := b.kind == .Rocky ? 0.3 : 0.34
		t_eq := equilibrium_temp(b.flux, albedo)
		sp := structure_params_for(b.mass, t_eq, 4.55)
		st := structure_solve(b.mass, b.comp, &sp)
		atmo := atmosphere_make({
			mass_earth = b.mass,
			radius_km  = st.radius_km,
			gravity_g  = st.gravity_g,
			flux       = b.flux,
			star_teff  = 5772,
			star_class = .G,
			age_gyr    = 4.55,
			water      = b.water,
			icy        = b.icy,
			envelope   = b.comp.gas > 0,
			ice_giant  = b.kind == .Ice_Giant,
			gas_t1     = max(sp.gas_t_irr, sp.gas_t_int),
			seed       = 1,
			fixed_co2  = b.co2,
			fixed_n2   = b.n2,
			fixed      = true,
			strip      = b.strip,
		})
		pi := interior_make({
			mass_earth = b.mass,
			comp       = b.comp,
			t_surface  = atmo.t_surface,
			age_gyr    = 4.55,
			heat_k     = 1,
			tidal_w    = b.tidal,
			plates     = b.plates,
			sp         = sp,
		})
		defer free(pi)
		dr := st.radius_km / b.radius - 1
		atmo_text := "нет"
		switch atmo.kind {
		case .Envelope:
			atmo_text = fmt.tprintf("оболочка, %.0f К на уровне 1 бар", atmo.t_surface)
		case .Thin, .Thick:
			main_gas := Gas_Kind.N2
			for gk in Gas_Kind do if atmo.frac[gk] > atmo.frac[main_gas] do main_gas = gk
			atmo_text = fmt.tprintf("%.3g бар, больше всего — %s, %.0f К", atmo.pressure, GAS_NAMES[main_gas], atmo.t_surface)
		case .None:
			atmo_text = fmt.tprintf("нет, %.0f К", atmo.t_surface)
		}
		inner := pi.inner_km > 0 ? fmt.tprintf("%.0f", pi.inner_km) : "—"
		field := pi.magnetic_ut > 0 ? fmt.tprintf("%.1f мкТл", pi.magnetic_ut) : "нет"
		fmt.printfln("%s %s %s %s %s %s %s — %s", pad(b.name, 9),
			pad(fmt.tprintf("%.0f / %.0f км (%+.1f%%)", st.radius_km, b.radius, dr * 100), 28),
			pad(fmt.tprintf("%.2f g", st.gravity_g), 8),
			pad(fmt.tprintf("%.0f ГПа, %.0f °C", pi.center_p, pi.center_t), 18),
			pad(fmt.tprintf("%.0f (%s) км", pi.core_km, inner), 16), pad(field, 9), atmo_text, b.atmo_real)
		if abs(dr) > b.tol do fail(&errors, fmt.tprintf("%s: радиус ошибается на %.1f%%", b.name, dr * 100))
		if b.t_real > 0 && abs(atmo.t_surface - b.t_real) > b.t_tol {
			fail(&errors, fmt.tprintf("%s: температура %.0f К вместо %.0f", b.name, atmo.t_surface, b.t_real))
		}
		switch b.name {
		case "Земля":
			if pi.inner_km < 1000 || pi.inner_km > 1450 do fail(&errors, fmt.tprintf("твёрдое ядро Земли %.0f км (на деле 1221)", pi.inner_km))
			if pi.magnetic_ut < 25 || pi.magnetic_ut > 70 do fail(&errors, "магнитное поле Земли")
			if atmo.o2_kpa <= 0 || !atmo.plants do fail(&errors, "на Земле нет кислорода и растений")
			if abs(pi.center_t - 5400) > 600 do fail(&errors, "температура в центре Земли")
			if abs(pi.center_p - 364) > 30 do fail(&errors, "давление в центре Земли")
		case "Венера":
			if !atmo.runaway do fail(&errors, "Венера не перегрелась")
			if pi.magnetic_ut > 0 do fail(&errors, "у Венеры нет поля, а модель его дала")
		case "Луна", "Меркурий", "Ио", "Европа", "Каллисто", "Ганимед":
			if atmo.kind != .None do fail(&errors, fmt.tprintf("у тела %s не должно быть атмосферы", b.name))
		case "Марс":
			if atmo.kind != .Thin do fail(&errors, "у Марса атмосфера должна быть разреженной")
		case "Титан":
			if atmo.kind != .Thick do fail(&errors, "у Титана атмосфера должна быть плотной")
		case "Тритон":
			if atmo.pressure > 1e-3 || atmo.pressure <= 0 do fail(&errors, "у Тритона атмосфера должна быть едва заметной (азот вымерзает)")
		}
		if b.name == "Европа" || b.name == "Ганимед" {
			if pi.ocean_km[1] <= 0 do fail(&errors, fmt.tprintf("у тела %s должен быть океан подо льдом", b.name))
			fmt.printfln("          океан подо льдом: %.0f–%.0f км", pi.ocean_km[0], pi.ocean_km[1])
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("(расчёт %.0f мс)", time.duration_milliseconds(time.since(t0)))

	// --- зависимость радиуса от массы (для сравнения с известными кривыми)
	fmt.println()
	fmt.println("Радиус по массе, R Земли (модель):")
	fmt.println("масса     как Земля  железная  30% воды  +1% газа  +3% газа")
	for m in ([?]f64{0.1, 0.5, 1, 2, 5, 10}) {
		rr: [5]f64
		comps := [5]Composition{{0.325, 0.675, 0, 0}, {0.7, 0.3, 0, 0}, {0.23, 0.47, 0.3, 0}, {0.32, 0.67, 0, 0.01}, {0.315, 0.655, 0, 0.03}}
		for c, k in comps {
			sp := structure_params_for(m, 400, 5)
			rr[k] = structure_solve(m, c, &sp).radius_km / EARTH_RADIUS_KM
		}
		fmt.printfln("%s %s %s %s %s %s", pad(fmt.tprintf("%g", m), 9), pad(fmt.tprintf("%.2f", rr[0]), 10), pad(fmt.tprintf("%.2f", rr[1]), 9),
			pad(fmt.tprintf("%.2f", rr[2]), 9), pad(fmt.tprintf("%.2f", rr[3]), 9), fmt.tprintf("%.2f", rr[4]))
	}

	// --- случайные системы: звёзды в долях, как в галактике
	fmt.println()
	N :: 30000
	r := eng.rng_make(0x57A7)
	classes := [7]Star_Class{.M, .K, .G, .F, .A, .B, .O}
	weights: [7]f64
	for c, k in classes do weights[k] = STAR_TIERS[c].frac
	found, stars_n: [7]int
	reasons := make(map[string]int)
	defer delete(reasons)
	kinds: [Planet_Kind]int
	planets, moons := 0, 0
	t1 := time.now()
	for i in 0 ..< N {
		k := pick_weighted(&r, weights[:])
		s := Star{class = classes[k], seed = mix64(u64(i) * 0x9E3779B97F4A7C15 + 17)}
		sr := eng.rng_make(s.seed)
		star_params(&s, &sr)
		sys := star_system_generate(0, s, false)
		stars_n[k] += 1
		planets += sys.planet_count
		for p in sys.planets[:sys.planet_count] {
			kinds[p.kind] += 1
			moons += p.moon_n
		}
		if system_find_start(&sys, &reasons) >= 0 do found[k] += 1
		star_system_destroy(&sys)
		free_all(context.temp_allocator)
	}
	ms := time.duration_milliseconds(time.since(t1))
	{
		// отдельно: только лёгкая генерация (без расчёта кандидатов)
		t2 := time.now()
		for i in 0 ..< 10000 {
			s := Star{class = .G, seed = mix64(u64(i) * 31 + 5)}
			sr := eng.rng_make(s.seed)
			star_params(&s, &sr)
			sys := star_system_generate(0, s, false)
			star_system_destroy(&sys)
		}
		fmt.printfln("лёгкая генерация системы: %.3f мс", time.duration_milliseconds(time.since(t2)) / 10000)
	}
	total := 0
	for f in found do total += f
	fmt.printfln("Случайные звёзды: %d (%.1f мс на звезду)", N, ms / N)
	fmt.printfln("планет %d (в среднем %.1f), каменных %d, ледяных гигантов и мини-нептунов %d, газовых гигантов %d; лун %d",
		planets, f64(planets) / N, kinds[.Rocky], kinds[.Ice_Giant], kinds[.Gas_Giant], moons)
	fmt.printfln("планета для высадки есть у %d звёзд из %d (%.2f%%):", total, N, f64(total) / N * 100)
	for c, k in classes {
		if stars_n[k] == 0 do continue
		fmt.printfln("  %s %s из %d — %d (%.1f%%)", pad(STAR_CLASS_NAMES[c], 20), pad("", 0), stars_n[k], found[k], f64(found[k]) / f64(stars_n[k]) * 100)
	}
	fmt.println("почему не подошли кандидаты (каменные с водой у зоны жизни):")
	for why, c in reasons do fmt.printfln("  %s %d", pad(why, 36), c)
	if total == 0 do fail(&errors, "ни одной планеты для высадки")

	// --- виды планет и лун (с полным расчётом) у части систем
	fmt.println()
	SAMPLE :: 120
	type_count := make(map[string]int, context.allocator)
	defer delete(type_count)
	moon_count := make(map[string]int, context.allocator)
	defer delete(moon_count)
	for i in 0 ..< SAMPLE {
		k := pick_weighted(&r, weights[:])
		s := Star{class = classes[k], seed = mix64(u64(i + 1_000_000) * 0x9E3779B97F4A7C15)}
		sr := eng.rng_make(s.seed)
		star_params(&s, &sr)
		sys := star_system_generate(0, s, true)
		for &p in sys.planets[:sys.planet_count] {
			type_count[body_type_name(&p.body, p.kind, false)] += 1
			for &m in p.moons[:p.moon_n] do moon_count[body_type_name(&m.body, .Rocky, true)] += 1
		}
		star_system_destroy(&sys)
		free_all(context.temp_allocator)
	}
	fmt.printfln("Виды планет у %d случайных систем:", SAMPLE)
	for name, c in type_count do fmt.printfln("  %s %d", pad(name, 34), c)
	fmt.println("Виды лун:")
	for name, c in moon_count do fmt.printfln("  %s %d", pad(name, 34), c)
	fmt.printfln("ошибок: %d", errors)
	return
}
