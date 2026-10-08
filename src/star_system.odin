package main

// Звёздная система у звезды. Сама звезда — из вселенной (stars.odin), а
// планеты генерируются по её зерну, когда понадобятся: систему может получить
// любая звезда. У нашей звезды одна планета гарантированно каменная и в
// пригодной для жизни зоне — на ней мы.
// Физика упрощённая, но честная: зона жизни по светимости, год по закону
// Кеплера, гравитация из массы и радиуса.

import "core:fmt"
import "core:math"
import "core:strings"
import eng "engine"

EARTH_RADIUS_KM :: 6371.0
EARTH_YEAR_HOURS :: 8766.0 // 365.25 суток
GM_EARTH :: 3.986004418e14 // м³/с²
MAX_PLANETS :: 10
MAX_MOONS :: 3

Planet_Kind :: enum u8 {
	Rocky,
	Ice_Giant,
	Gas_Giant,
}

PLANET_KIND_NAMES := [Planet_Kind]string {
	.Rocky     = "каменная",
	.Ice_Giant = "ледяной гигант",
	.Gas_Giant = "газовый гигант",
}

Planet :: struct {
	name:       string,
	kind:       Planet_Kind,
	orbit_au:   f64,
	radius_km:  f64,
	mass_earth: f64,
	year_hours: f64, // стандартных часов
	// эллиптическая орбита (astro.odin): эксцентриситет, долгота перицентра,
	// средняя аномалия в момент высадки
	ecc, peri, mean0: f64,
}

Moon :: struct {
	radius_km:    f64,
	orbit_km:     f64,
	period_hours: f64,
	// орбита: эксцентриситет, наклон к плоскости орбиты планеты, узел, перицентр, средняя аномалия
	ecc, incl, node, peri, mean0: f64,
}

// Наша планета — подробнее.
Home_Planet :: struct {
	index:          int,
	gravity_g:      f64,
	day_hours:      f64, // солнечные сутки, стандартных часов
	sidereal_hours: f64, // оборот вокруг оси относительно звёзд
	axial_tilt_deg: f64,
	tilt_dir:       f64, // долгота, к которой наклонена ось (рад)
	year_days:      f64, // местных суток в году
	moons:          [MAX_MOONS]Moon,
	moon_count:     int,
	latitude_deg:   f64, // точка появления
	longitude_deg:  f64,
}

Star_System :: struct {
	seed:         u32, // зерно мира
	star:         Star,
	planets:      [MAX_PLANETS]Planet,
	planet_count: int,
	has_home:     bool,
	home:         Home_Planet,
}

@(private = "file")
SYLLABLES := [?]string{"ка", "ре", "ла", "ми", "то", "ва", "на", "ри", "со", "де", "лу", "ки", "мо", "та", "ше", "за", "ни", "ра", "ве", "ор", "ан", "ис", "ус", "ел", "ар", "ти", "го", "ди", "ке", "ну"}

// Имя из lo..hi слогов.
make_name :: proc(r: ^eng.Rng, lo, hi: int, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< eng.rng_int(r, lo, hi) do strings.write_string(&b, SYLLABLES[eng.rng_int(r, 0, len(SYLLABLES) - 1)])
	return eng.capitalize(strings.to_string(b), allocator)
}

// Цвет абсолютно чёрного тела по температуре (приближение Таннера Хелланда).
star_color :: proc(kelvin: f64) -> [3]f32 {
	t := kelvin / 100
	r, g, b: f64
	if t <= 66 {
		r = 255
		g = 99.4708025861 * math.ln(t) - 161.1195681661
	} else {
		r = 329.698727446 * math.pow(t - 60, -0.1332047592)
		g = 288.1221695283 * math.pow(t - 60, -0.0755148492)
	}
	if t >= 66 {
		b = 255
	} else if t <= 19 {
		b = 0
	} else {
		b = 138.5177312231 * math.ln(t - 10) - 305.0447927307
	}
	return {f32(clamp(r, 0, 255) / 255), f32(clamp(g, 0, 255) / 255), f32(clamp(b, 0, 255) / 255)}
}

// Год в стандартных часах по третьему закону Кеплера.
@(private = "file")
year_hours :: proc(orbit_au, star_mass: f64) -> f64 {
	return math.sqrt(orbit_au * orbit_au * orbit_au / star_mass) * EARTH_YEAR_HOURS
}

// Сколько планет у звезды (у горячих гигантов и остатков звёзд — реже).
@(private = "file")
planet_count_for :: proc(class: Star_Class, r: ^eng.Rng) -> int {
	none, most: f64
	switch class {
	case .M, .K, .G, .F:
		none, most = 0.15, 10
	case .A:
		none, most = 0.3, 7
	case .B, .O:
		none, most = 0.6, 4
	case .Red_Giant:
		none, most = 0.4, 6
	case .White_Dwarf:
		none, most = 0.6, 4
	case .Neutron:
		none, most = 0.9, 3
	case .Black_Hole:
		none, most = 0.95, 1
	}
	if eng.rng_f64(r) < none do return 0
	return eng.rng_int(r, 1, int(most))
}

// Система звезды star. home — наша звезда: одна планета каменная и в зоне жизни.
star_system_generate :: proc(world_seed: u32, star: Star, home: bool) -> (s: Star_System) {
	r := eng.rng_make(star.seed * 0x2545F4914F6CDD1D + 1)
	o := eng.rng_make(star.seed ~ 0x0E11_1F5E) // орбиты — отдельно, чтобы не менять остальное
	s.seed = world_seed
	s.star = star
	s.star.name = star_name(star.seed)
	s.has_home = home

	// --- орбиты (у нашей звезды — наша планета в пригодной для жизни зоне)
	sqrt_l := math.sqrt(max(star.luminosity, 1e-4))
	frost_line := 2.7 * sqrt_l
	mass := max(star.mass, 0.08)
	n, home_i := 0, -1
	if home {
		n = eng.rng_int(&r, 2, MAX_PLANETS)
		home_i = eng.rng_int(&r, 0, min(n - 1, 3))
		s.planets[home_i].orbit_au = eng.rng_range(&r, 0.95, 1.35) * sqrt_l
		for i := home_i - 1; i >= 0; i -= 1 {
			s.planets[i].orbit_au = s.planets[i + 1].orbit_au / eng.rng_range(&r, 1.4, 2.0)
		}
	} else {
		n = planet_count_for(star.class, &r)
		if n > 0 do s.planets[0].orbit_au = eng.rng_range(&r, 0.04, 0.5) * max(sqrt_l, 0.1)
	}
	for i in max(home_i + 1, 1) ..< n {
		s.planets[i].orbit_au = s.planets[i - 1].orbit_au * eng.rng_range(&r, 1.4, 2.2)
	}
	s.planet_count = n

	letters := "bcdefghijk"
	for i in 0 ..< n {
		p := &s.planets[i]
		p.name = fmt.aprintf("%s %c", s.star.name, rune(letters[i]))
		if i == home_i || p.orbit_au < frost_line {
			p.kind = .Rocky
		} else {
			p.kind = eng.rng_f64(&r) < 0.6 ? .Gas_Giant : .Ice_Giant
		}
		switch p.kind {
		case .Rocky:
			re := eng.rng_range(&r, 0.3, 1.8)
			p.radius_km = re * EARTH_RADIUS_KM
			p.mass_earth = eng.rng_range(&r, 0.8, 1.15) * re * re * re
		case .Ice_Giant:
			p.radius_km = eng.rng_range(&r, 3.4, 4.6) * EARTH_RADIUS_KM
			p.mass_earth = eng.rng_range(&r, 10, 22)
		case .Gas_Giant:
			p.radius_km = eng.rng_range(&r, 8, 12.5) * EARTH_RADIUS_KM
			p.mass_earth = eng.rng_range(&r, 30, 700)
		}
		p.year_hours = year_hours(p.orbit_au, mass)
		// вытянутость: у нашей — умеренная (иначе сезоны слишком резкие), у гигантов — меньше
		e_max := i == home_i ? 0.15 : p.kind == .Rocky ? 0.25 : 0.12
		p.ecc = e_max * eng.rng_f64(&o) * eng.rng_f64(&o)
		p.peri = eng.rng_range(&o, 0, 2 * math.PI)
		p.mean0 = eng.rng_range(&o, 0, 2 * math.PI)
	}
	if !home do return

	// --- наша планета: размер, гравитация, сутки, наклон оси, луны
	h := &s.home
	h.index = home_i
	hp := &s.planets[home_i]
	re := eng.rng_range(&r, 0.5, 1.6)
	density := eng.rng_range(&r, 0.85, 1.15) // относительно Земли
	h.gravity_g = clamp(density * re, 0.4, 1.8)
	hp.radius_km = re * EARTH_RADIUS_KM
	hp.mass_earth = h.gravity_g * re * re // g = M / R²
	h.day_hours = eng.rng_range(&r, 16, 40)
	// звёздные сутки: 1/звёздные = 1/солнечные + 1/год
	h.sidereal_hours = 1 / (1 / h.day_hours + 1 / hp.year_hours)
	h.axial_tilt_deg = eng.rng_range(&r, 0, 45)
	h.year_days = hp.year_hours / h.day_hours

	moon_roll := eng.rng_f64(&r)
	h.moon_count = moon_roll < 0.25 ? 0 : moon_roll < 0.65 ? 1 : moon_roll < 0.9 ? 2 : 3
	planet_gm := GM_EARTH * hp.mass_earth
	orbit := hp.radius_km * eng.rng_range(&r, 12, 35)
	for i in 0 ..< h.moon_count {
		m := &h.moons[i]
		m.radius_km = eng.rng_range(&r, 250, 1900)
		m.orbit_km = orbit
		orbit *= eng.rng_range(&r, 1.6, 2.6) // луны по порядку удаления
		a := m.orbit_km * 1000
		m.period_hours = 2 * math.PI * math.sqrt(a * a * a / planet_gm) / 3600
	}

	sign: f64 = eng.rng_f64(&r) < 0.5 ? -1 : 1
	h.latitude_deg = sign * eng.rng_range(&r, 25, 55)
	h.longitude_deg = eng.rng_range(&r, 0, 360)
	h.tilt_dir = eng.rng_range(&o, 0, 2 * math.PI)
	for i in 0 ..< h.moon_count {
		m := &h.moons[i]
		m.ecc = 0.08 * eng.rng_f64(&o) * eng.rng_f64(&o)
		m.incl = math.to_radians(eng.rng_range(&o, 0, 8))
		m.node = eng.rng_range(&o, 0, 2 * math.PI)
		m.peri = eng.rng_range(&o, 0, 2 * math.PI)
		m.mean0 = eng.rng_range(&o, 0, 2 * math.PI)
	}
	return
}

star_system_destroy :: proc(s: ^Star_System) {
	delete(s.star.name)
	for i in 0 ..< s.planet_count do delete(s.planets[i].name)
}

home_planet :: proc(s: ^Star_System) -> ^Planet {
	return &s.planets[s.home.index]
}
