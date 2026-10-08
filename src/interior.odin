package main

// Строение планеты: кора, мантия, ядро — из массы, радиуса и средней
// плотности. Блоками мир идёт только сквозь кору (на сотни км вглубь —
// практически недостижимо); глубже — эта модель (F3, страница 5; позже —
// разрушение планет в стратегии).
//
// Ядро — железо, мантия — камень: по средней плотности видно, сколько
// железа, отсюда радиус ядра. Давление — интеграл ρ·g от поверхности вниз.
// Температуры — как у Земли (на границе ядра ~3700 °C, в центре ~5400 °C),
// у меньших планет недра холоднее. Жидкое внешнее ядро вокруг твёрдого
// внутреннего — динамо: есть магнитное поле.

import "core:math"

Interior_Layer :: struct {
	name:              string,
	top_km, bottom_km: f64, // глубина от уровня моря
	liquid:            bool,
	t_top, t_bottom:   f64, // °C
	p_top, p_bottom:   f64, // ГПа
	rho:               f64, // г/см³
}

Planet_Interior :: struct {
	layers:         [5]Interior_Layer,
	n:              int,
	density:        f64, // средняя плотность, г/см³
	core_km:        f64, // радиус ядра
	inner_km:       f64, // радиус внутреннего ядра (0 — нет)
	crust_cont_km:  f64, // толщина коры под материками (без гор)
	crust_ocean_km: f64,
	surface_c:      f64, // средняя температура поверхности (оценка по свету звезды)
	gradient:       f64, // прогрев коры, °C на км
	center_t:       f64,
	center_p:       f64,
	magnetic:       bool,
}

EARTH_DENSITY :: 5.514 // г/см³

interior_make :: proc(radius_km, mass_earth, gravity_g, flux: f64) -> (pi: Planet_Interior) {
	re := radius_km / EARTH_RADIUS_KM
	pi.density = EARTH_DENSITY * mass_earth / (re * re * re)
	// плотности камня мантии и железа ядра (сжатые: у большой планеты — плотнее)
	rho_m := 4.0 + 0.4 * re
	rho_c := 10.0 + 1.0 * re
	f := clamp((pi.density - rho_m) / (rho_c - rho_m), 0.03, 0.6) // доля объёма ядра
	pi.core_km = radius_km * math.cbrt(f)
	// модель должна весить как планета: подгоняем плотность мантии
	rho_m = (pi.density - rho_c * f) / (1 - f)

	// давление: от поверхности к центру, dP = ρ·g·dr
	G :: 6.674e-11
	R := radius_km * 1000
	rc := pi.core_km * 1000
	mass_in :: proc(r, rc, rho_m, rho_c: f64) -> f64 {
		if r <= rc do return 4.0 / 3 * math.PI * rho_c * r * r * r
		return 4.0 / 3 * math.PI * (rho_c * rc * rc * rc + rho_m * (r * r * r - rc * rc * rc))
	}
	STEPS :: 4000
	pressure: [STEPS + 1]f64 // давление на глубине i/STEPS·R, Па
	for i in 1 ..= STEPS {
		r := R * (1 - (f64(i) - 0.5) / STEPS)
		rho := (r <= rc ? rho_c : rho_m) * 1000
		g := G * mass_in(r, rc, rho_m * 1000, rho_c * 1000) / (r * r)
		pressure[i] = pressure[i - 1] + rho * g * R / STEPS
	}
	p_at :: proc(pressure: ^[STEPS + 1]f64, depth_km, radius_km: f64) -> f64 {
		i := clamp(int(depth_km / radius_km * STEPS + 0.5), 0, STEPS)
		return pressure[i] / 1e9
	}
	pi.center_p = pressure[STEPS] / 1e9

	// температуры: поверхность — по свету звезды; недра — как у Земли, у малых планет холоднее
	pi.surface_c = 288 * math.pow(flux, 0.25) - 273
	s := math.sqrt(gravity_g * re)
	pi.crust_cont_km = 35 / math.sqrt(gravity_g)
	pi.crust_ocean_km = 7 / math.sqrt(gravity_g)
	pi.gradient = 20 * s
	t_moho := pi.surface_c + pi.gradient * pi.crust_cont_km
	t_cmb := 3700 * s
	pi.center_t = 5400 * s
	liquid_core := t_cmb > 1500
	if liquid_core && pi.center_p > 200 do pi.inner_km = pi.core_km * 0.35
	pi.magnetic = liquid_core && pi.inner_km > 0
	t_icb := pi.inner_km > 0 ? 5000 * s : pi.center_t

	mantle_top := pi.crust_cont_km
	core_top := radius_km - pi.core_km
	add :: proc(pi: ^Planet_Interior, l: Interior_Layer) {
		pi.layers[pi.n] = l
		pi.n += 1
	}
	add(&pi, {"кора материков", 0, pi.crust_cont_km, false, pi.surface_c, t_moho, 0, p_at(&pressure, pi.crust_cont_km, radius_km), 2.8})
	add(&pi, {"кора океанов", 0, pi.crust_ocean_km, false, 4, 4 + pi.gradient * 1.6 * pi.crust_ocean_km, 0, p_at(&pressure, pi.crust_ocean_km, radius_km), 3.0})
	add(&pi, {"мантия", mantle_top, core_top, false, t_moho, t_cmb, p_at(&pressure, mantle_top, radius_km), p_at(&pressure, core_top, radius_km), rho_m})
	if pi.inner_km > 0 {
		icb := radius_km - pi.inner_km
		add(&pi, {"внешнее ядро", core_top, icb, true, t_cmb, t_icb, p_at(&pressure, core_top, radius_km), p_at(&pressure, icb, radius_km), rho_c})
		add(&pi, {"внутреннее ядро", icb, radius_km, false, t_icb, pi.center_t, p_at(&pressure, icb, radius_km), pi.center_p, rho_c * 1.05})
	} else {
		add(&pi, {"ядро", core_top, radius_km, liquid_core, t_cmb, pi.center_t, p_at(&pressure, core_top, radius_km), pi.center_p, rho_c})
	}
	return
}

// Температура породы на глубине depth м под поверхностью на высоте alt м
// (поверхность в горах холоднее — ~6,5 °C на км).
rock_temperature :: proc(pi: ^Planet_Interior, alt, depth: f64) -> f64 {
	return pi.surface_c - 6.5 * max(alt, 0) / 1000 + pi.gradient * depth / 1000
}
