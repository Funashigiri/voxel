package main

// Звёздная система, случайная для каждого мира (по зерну).
// Физика упрощённая, но честная: светимость ~ масса^4, пригодная для жизни зона
// по светимости, год по закону Кеплера, гравитация из массы и радиуса.

import "core:fmt"
import "core:math"
import "core:strings"
import eng "engine"

EARTH_RADIUS_KM :: 6371.0
EARTH_YEAR_HOURS :: 8766.0 // 365.25 суток
GM_EARTH :: 3.986004418e14 // м³/с²
MAX_PLANETS :: 10
MAX_MOONS :: 3

Star_Class :: enum u8 {
	M, // красный карлик
	K, // оранжевый карлик
	G, // жёлтый карлик (как Солнце)
	F, // жёлто-белая звезда
}

STAR_CLASS_NAMES := [Star_Class]string {
	.M = "красный карлик",
	.K = "оранжевый карлик",
	.G = "жёлтый карлик",
	.F = "жёлто-белая звезда",
}

Star :: struct {
	name:        string,
	class:       Star_Class,
	mass:        f64, // масс Солнца
	luminosity:  f64, // светимостей Солнца
	radius:      f64, // радиусов Солнца
	temperature: f64, // К
	color:       [3]f32,
}

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
}

Moon :: struct {
	radius_km:    f64,
	orbit_km:     f64,
	period_hours: f64,
}

// Наша планета — подробнее.
Home_Planet :: struct {
	index:          int,
	gravity_g:      f64,
	day_hours:      f64, // солнечные сутки, стандартных часов
	sidereal_hours: f64, // оборот вокруг оси относительно звёзд
	axial_tilt_deg: f64,
	year_days:      f64, // местных суток в году
	moons:          [MAX_MOONS]Moon,
	moon_count:     int,
	latitude_deg:   f64, // точка появления
	longitude_deg:  f64,
}

Star_System :: struct {
	seed:         u32,
	star:         Star,
	planets:      [MAX_PLANETS]Planet,
	planet_count: int,
	home:         Home_Planet,
}

@(private = "file")
SYLLABLES := [?]string{"ка", "ре", "ла", "ми", "то", "ва", "на", "ри", "со", "де", "лу", "ки", "мо", "та", "ше", "за", "ни", "ра", "ве", "ор", "ан", "ис", "ус", "ел", "ар", "ти", "го", "ди", "ке", "ну"}

@(private = "file")
make_name :: proc(r: ^eng.Rng) -> string {
	b := strings.builder_make()
	for _ in 0 ..< eng.rng_int(r, 2, 3) do strings.write_string(&b, SYLLABLES[eng.rng_int(r, 0, len(SYLLABLES) - 1)])
	name := eng.capitalize(strings.to_string(b), context.allocator)
	strings.builder_destroy(&b)
	return name
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

star_system_generate :: proc(seed: u32) -> (s: Star_System) {
	r := eng.rng_make(u64(seed) * 0x2545F4914F6CDD1D + 1)
	s.seed = seed

	// --- звезда (чаще — похожие на Солнце, чтобы планеты были разнообразнее)
	roll := eng.rng_f64(&r)
	star := &s.star
	switch {
	case roll < 0.30:
		star.class = .M
		star.mass = eng.rng_range(&r, 0.35, 0.6)
		star.temperature = eng.rng_range(&r, 3100, 3900)
	case roll < 0.60:
		star.class = .K
		star.mass = eng.rng_range(&r, 0.6, 0.85)
		star.temperature = eng.rng_range(&r, 3900, 5200)
	case roll < 0.88:
		star.class = .G
		star.mass = eng.rng_range(&r, 0.85, 1.1)
		star.temperature = eng.rng_range(&r, 5200, 6000)
	case:
		star.class = .F
		star.mass = eng.rng_range(&r, 1.1, 1.4)
		star.temperature = eng.rng_range(&r, 6000, 7200)
	}
	star.luminosity = star.mass < 0.43 ? 0.23 * math.pow(star.mass, 2.3) : math.pow(star.mass, 4)
	star.radius = math.pow(star.mass, 0.8)
	star.color = star_color(star.temperature)
	star.name = make_name(&r)

	// --- орбиты: наша планета в пригодной для жизни зоне, остальные — вокруг
	sqrt_l := math.sqrt(star.luminosity)
	home_orbit := eng.rng_range(&r, 0.95, 1.35) * sqrt_l
	frost_line := 2.7 * sqrt_l
	n := eng.rng_int(&r, 2, MAX_PLANETS)
	home_i := eng.rng_int(&r, 0, min(n - 1, 3))
	s.planet_count = n
	s.planets[home_i].orbit_au = home_orbit
	for i := home_i - 1; i >= 0; i -= 1 {
		s.planets[i].orbit_au = s.planets[i + 1].orbit_au / eng.rng_range(&r, 1.4, 2.0)
	}
	for i in home_i + 1 ..< n {
		s.planets[i].orbit_au = s.planets[i - 1].orbit_au * eng.rng_range(&r, 1.4, 2.2)
	}

	letters := "bcdefghijk"
	for i in 0 ..< n {
		p := &s.planets[i]
		p.name = fmt.aprintf("%s %c", star.name, rune(letters[i]))
		if i == home_i {
			p.kind = .Rocky
		} else if p.orbit_au < frost_line {
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
		p.year_hours = year_hours(p.orbit_au, star.mass)
	}

	// --- наша планета: размер, гравитация, сутки, наклон оси, луны
	home := &s.home
	home.index = home_i
	hp := &s.planets[home_i]
	re := eng.rng_range(&r, 0.5, 1.6)
	density := eng.rng_range(&r, 0.85, 1.15) // относительно Земли
	home.gravity_g = clamp(density * re, 0.4, 1.8)
	hp.radius_km = re * EARTH_RADIUS_KM
	hp.mass_earth = home.gravity_g * re * re // g = M / R²
	home.day_hours = eng.rng_range(&r, 16, 40)
	// звёздные сутки: 1/звёздные = 1/солнечные + 1/год
	home.sidereal_hours = 1 / (1 / home.day_hours + 1 / hp.year_hours)
	home.axial_tilt_deg = eng.rng_range(&r, 0, 45)
	home.year_days = hp.year_hours / home.day_hours

	moon_roll := eng.rng_f64(&r)
	home.moon_count = moon_roll < 0.25 ? 0 : moon_roll < 0.65 ? 1 : moon_roll < 0.9 ? 2 : 3
	planet_gm := GM_EARTH * hp.mass_earth
	orbit := hp.radius_km * eng.rng_range(&r, 12, 35)
	for i in 0 ..< home.moon_count {
		m := &home.moons[i]
		m.radius_km = eng.rng_range(&r, 250, 1900)
		m.orbit_km = orbit
		orbit *= eng.rng_range(&r, 1.6, 2.6) // луны по порядку удаления
		a := m.orbit_km * 1000
		m.period_hours = 2 * math.PI * math.sqrt(a * a * a / planet_gm) / 3600
	}

	sign: f64 = eng.rng_f64(&r) < 0.5 ? -1 : 1
	home.latitude_deg = sign * eng.rng_range(&r, 25, 55)
	home.longitude_deg = eng.rng_range(&r, 0, 360)
	return
}

star_system_destroy :: proc(s: ^Star_System) {
	delete(s.star.name)
	for i in 0 ..< s.planet_count do delete(s.planets[i].name)
}

home_planet :: proc(s: ^Star_System) -> ^Planet {
	return &s.planets[s.home.index]
}
