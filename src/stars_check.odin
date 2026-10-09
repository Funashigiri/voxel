package main

// Проверка модели звёзд (-stars): настоящие звёзды — по их массе, радиусу,
// светимости, температуре и возрасту модель считает строение; что известно
// из наблюдений и подробных расчётов, сверяется.

import "core:fmt"

@(private = "file")
Known_Star :: struct {
	name:                string,
	class:               Star_Class,
	mass, radius, lum:   f64,
	teff, age, metal:    f64,
	note:                string, // что известно
}

// Температура в удобных единицах: тысячи или миллионы градусов.
star_temp_text :: proc(k: f64) -> string {
	switch {
	case k >= 1e6:
		return fmt.tprintf("%.1f млн К", k / 1e6)
	case k >= 1e4:
		return fmt.tprintf("%.0f тыс. К", k / 1e3)
	}
	return fmt.tprintf("%.0f К", k)
}

// Плотность, г/см³ (с порядком, если велика или мала).
star_rho_text :: proc(rho: f64) -> string {
	g := rho / 1000
	switch {
	case g >= 1e5 || (g > 0 && g < 1e-3):
		return fmt.tprintf("%s г/см³", sci_text(g))
	case g >= 10:
		return fmt.tprintf("%.0f г/см³", g)
	}
	return fmt.tprintf("%.3g г/см³", g)
}

stars_report :: proc() -> (errors: int) {
	fail :: proc(errors: ^int, what: string) {
		errors^ += 1
		fmt.printfln("  ОШИБКА: %s", what)
	}
	known := []Known_Star {
		{"Солнце", .G, 1.0, 1.0, 1.0, 5772, 4.57, 0, "в центре 15,7 млн К, 150 г/см³, 2,5·10¹⁶ Па; конвекция с 0,713 R; 99% энергии — протон-протонная цепочка; оборот ~26 сут; корона 1–2 млн К"},
		{"Проксима Центавра", .M, 0.122, 0.154, 0.0017, 3042, 4.85, 0.2, "конвективна целиком; вспыхивающая звезда; оборот ~83 сут"},
		{"Альфа Центавра A", .G, 1.1, 1.22, 1.52, 5790, 5.3, 0.2, "чуть старше и массивнее Солнца; оборот ~22 сут"},
		{"Сириус A", .A, 2.06, 1.71, 25.4, 9940, 0.24, 0.5, "конвективное ядро, горит в основном CNO-циклом; короны нет"},
		{"Вега", .A, 2.14, 1.9, 40.1, 9600, 0.45, 0, "конвективное ядро, CNO-цикл (радиус — без раздувания от вращения; металлы обеднены только на поверхности)"},
		{"Спика A", .B, 11.4, 7.5, 20500, 25300, 0.0125, 0, "горячая, давление света заметно; мощный ветер"},
		{"Арктур", .Red_Giant, 1.08, 25.4, 170, 4286, 7.1, -0.5, "красный гигант: вырожденное гелиевое ядро ~0,3 Солнца"},
		{"Сириус B", .White_Dwarf, 1.02, 0.0084, 0.056, 25200, 0.24, 0, "белый карлик: ~3·10⁷ г/см³ в центре; остывает ~0,1 млрд лет"},
		{"нейтронная звезда", .Neutron, 1.4, 12 / SUN_RADIUS_KM, 1e-5, 1e6, 1, 0, "плотнее атомного ядра; убегание ~0,6 скорости света"},
		{"Лебедь X-1", .Black_Hole, 21.2, 2.953 * 21.2 / SUN_RADIUS_KM, 0, 0, 5, 0, "горизонт ~60 км (без вращения 62,6 км)"},
	}
	fmt.println("=== Модель звёзд на настоящих звёздах ===")
	for k in known {
		s := Star{class = k.class, mass = k.mass, radius = k.radius, luminosity = k.lum, temperature = k.teff, seed = 7}
		st := star_structure_make(s, k.age, k.metal)
		fmt.printfln("%s — %s", k.name, STAR_STAGE_NAMES[st.stage])
		fmt.printfln("  на деле: %s", k.note)
		switch st.stage {
		case .Black_Hole:
			fmt.printfln("  модель: горизонт %.1f км (вращение %.2f), фотонная сфера %.0f км, последняя орбита %.0f км, температура Хокинга %s К, разорвёт человека ближе %.0f км",
				st.horizon_km, st.bh_spin, st.photon_km, st.isco_km, sci_text(st.hawking_k), st.tidal_km)
			if st.horizon_km > 2.953 * k.mass + 0.1 || st.horizon_km < 1.476 * k.mass do fail(&errors, "горизонт чёрной дыры")
		case .Neutron:
			fmt.printfln("  модель: в центре %s (%.1f ядерных), %s; убегание %.2f c, время у поверхности течёт ×%.2f, поле %s Тл, оборот %.3f с",
				star_rho_text(st.rhoc), st.rhoc / NUCLEAR_DENSITY, star_temp_text(st.tc), st.v_esc * 1000 / C_LIGHT, st.redshift, sci_text(st.b_tesla), st.spin_s)
			if st.rhoc < 2 * NUCLEAR_DENSITY do fail(&errors, "нейтронная звезда должна быть плотнее двух ядерных плотностей")
			if st.v_esc * 1000 / C_LIGHT < 0.45 do fail(&errors, "скорость убегания нейтронной звезды")
		case .White_Dwarf:
			fmt.printfln("  модель: в центре %s, %s; остывает %.2f млрд лет; кристалл %.0f%% радиуса; тяжесть %s м/с²",
				star_rho_text(st.rhoc), star_temp_text(st.tc), st.cool_gyr, st.crystal * 100, sci_text(st.g))
			if st.rhoc < 1e9 || st.rhoc > 2e11 do fail(&errors, "плотность в центре белого карлика")
			if st.cool_gyr < 0.03 || st.cool_gyr > 0.5 do fail(&errors, "возраст остывания Сириуса B")
		case .Red_Giant, .Clump, .Bright_Giant:
			fmt.printfln("  модель: ядро %.2f Солнца, в нём %s, %s; слой горения %s; ветер %s Солнца в год",
				st.core_mass, star_rho_text(st.rhoc), star_temp_text(st.tc), star_temp_text(st.shell_t), sci_text(st.wind))
			if st.core_mass < 0.2 || st.core_mass > 0.47 do fail(&errors, "масса гелиевого ядра Арктура")
		case .Main_Sequence:
			fmt.printfln("  модель: в центре %s, %s, %s Па; водорода в ядре сгорело %.0f%%; давление света %.1f%%",
				star_temp_text(st.tc), star_rho_text(st.rhoc), sci_text(st.pc), st.burned * 100, (1 - st.beta) * 100)
			surface := k.teff < 7500 ? fmt.tprintf("корона %s; пятна %.1f%%; вспышка силы Кэррингтона раз в %s лет", star_temp_text(st.corona_k), st.spots * 100, sci_text(st.flare_years)) : "короны и пятен нет (горячая звезда), есть ветер"
			fmt.printfln("          протон-протонная цепочка %.1f%%, CNO %.1f%%; 99%% энергии — внутри %.2f R; оборот %.1f сут; %s",
				st.pp_share * 100, st.cno_share * 100, st.core_r, st.rot_days, surface)
			left := st.remaining < 0.1 ? fmt.tprintf("%.0f млн лет", st.remaining * 1000) : fmt.tprintf("%.1f млрд лет", st.remaining)
			fmt.printfln("          при рождении светила на %.0f%% слабее; осталось %s; остаток — %.2f Солнца", (1 - st.birth_lum) * 100, left, st.fate_mass)
		}
		for z in st.zones[:st.n] {
			fmt.printfln("    %s %s %s %s", pad(STAR_ZONE_NAMES[z.kind], 32), pad(fmt.tprintf("%.3f–%.3f R", z.r0, z.r1), 16),
				pad(fmt.tprintf("%s → %s", star_temp_text(z.t0), star_temp_text(z.t1)), 26), fmt.tprintf("%s → %s", star_rho_text(z.rho0), star_rho_text(z.rho1)))
		}
		bcz := 0.0
		has_cc := false
		for z in st.zones[:st.n] {
			if z.kind == .Convective do bcz = z.r0
			if z.kind == .Conv_Core do has_cc = true
		}
		switch k.name {
		case "Солнце":
			if abs(st.tc - 1.57e7) > 1.5e6 do fail(&errors, "температура в центре Солнца")
			if abs(st.rhoc - 1.5e5) > 4e4 do fail(&errors, "плотность в центре Солнца")
			if abs(st.pc / 2.5e16 - 1) > 0.3 do fail(&errors, "давление в центре Солнца")
			if abs(bcz - 0.713) > 0.03 do fail(&errors, "дно конвективной зоны Солнца")
			if st.core_r < 0.18 || st.core_r > 0.32 do fail(&errors, fmt.tprintf("ядро Солнца %.2f R (на деле ~0,25)", st.core_r))
			if st.pp_share < 0.95 do fail(&errors, "у Солнца горит в основном протон-протонная цепочка")
			if st.rot_days < 20 || st.rot_days > 33 do fail(&errors, "оборот Солнца")
			if st.corona_k < 0.8e6 || st.corona_k > 3e6 do fail(&errors, "температура короны Солнца")
			if st.birth_lum < 0.65 || st.birth_lum > 0.77 do fail(&errors, "Солнце в молодости светило на ~30% слабее")
			if st.fate_mass < 0.45 || st.fate_mass > 0.62 do fail(&errors, "белый карлик из Солнца — ~0,54 Солнца")
		case "Проксима Центавра":
			if !st.fully_conv do fail(&errors, "Проксима должна быть конвективна целиком")
			if st.tc < 2.5e6 || st.tc > 7e6 do fail(&errors, "температура в центре Проксимы")
			if st.flare_years > 1 do fail(&errors, "Проксима — вспыхивающая звезда")
			if st.rot_days < 50 || st.rot_days > 130 do fail(&errors, "оборот Проксимы")
		case "Сириус A", "Вега":
			if !has_cc do fail(&errors, fmt.tprintf("у звезды %s должно быть конвективное ядро", k.name))
			if st.cno_share < 0.5 do fail(&errors, fmt.tprintf("у звезды %s главный — CNO-цикл", k.name))
		case "Спика A":
			if st.cno_share < 0.95 do fail(&errors, "у Спики горит CNO-цикл")
			if st.beta > 0.995 do fail(&errors, "у Спики давление света заметно")
		}
	}
	fmt.printfln("ошибок: %d", errors)
	return
}
