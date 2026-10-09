package main

// Звёздная система (0.013). Одни правила для любой звезды — и для нашей
// тоже: наша звезда ничем не особенная, просто у неё нашлась планета, где
// можно высадиться (поиск — universe_find_home).
//
// Где что рождается: ближе снеговой линии (там, где в молодом диске
// замерзала вода) — из железа и камня; дальше — ещё и изо льда, а крупные
// зародыши захватывают водород и гелий и становятся гигантами. Массы — как
// у найденных экзопланет: суперземли и мини-нептуны часты, горячие юпитеры
// редки, гиганты чаще у массивных и богатых металлами звёзд. Близко к
// звезде мини-нептуны теряют газ (свет звезды «сдувает» оболочку). Радиус и
// тяжесть — из массы и состава (interior.odin), атмосфера — atmosphere.odin.
// Вращение: при рождении — несколько часов на оборот, потом приливы звезды и
// лун тормозят его; близко к тусклой звезде планета замирает одной стороной
// к ней. Без большой луны наклон оси «гуляет» и бывает большим.

import "core:fmt"
import "core:math"
import "core:strings"
import eng "engine"

EARTH_RADIUS_KM :: 6371.0
EARTH_YEAR_HOURS :: 8766.0 // 365.25 суток
GM_EARTH :: 3.986004418e14 // м³/с²
MAX_PLANETS :: 10
MAX_MOONS :: 3 // луны нашей планеты на небе
MAX_PLANET_MOONS :: 6 // крупные луны любой планеты (у гигантов — больше)
SUN_MASS_EARTHS :: 332_946.0

@(private = "file")
TAG_MASS :: 0x3A55_0013
@(private = "file")
TAG_MOON :: 0x300F_0013
@(private = "file")
TAG_ROT :: 0x2077_0013
@(private = "file")
TAG_AGE :: 0x0A6E_0013
@(private = "file")
TAG_SITE :: 0x517E_0013

Planet_Kind :: enum u8 {
	Rocky, // твёрдая поверхность (камень, лёд, водный мир)
	Ice_Giant, // ледяной гигант или мини-нептун (водородная оболочка поверх льда и камня)
	Gas_Giant,
}

PLANET_KIND_NAMES := [Planet_Kind]string {
	.Rocky     = "каменная",
	.Ice_Giant = "ледяной гигант",
	.Gas_Giant = "газовый гигант",
}

// Физическое тело — планета или луна.
Body :: struct {
	mass_earth:     f64,
	radius_km:      f64,
	comp:           Composition,
	water:          f64, // вода на поверхности, доля массы (у каменных)
	gravity_g:      f64,
	v_esc:          f64, // км/с
	flux:           f64, // свет звезды, Земля = 1 (среднее за орбиту)
	atmo:           Atmosphere,
	// вращение
	period0_hours:  f64, // при рождении
	sidereal_hours: f64, // оборот относительно звёзд
	day_hours:      f64, // солнечные сутки (0 — одной стороной к звезде навсегда)
	locked:         bool,
	resonance:      bool, // 3:2 — три оборота за два года (как Меркурий)
	axial_tilt_deg: f64,
	tilt_dir:       f64,
	// недра (сводка, interior.odin)
	core_km:        f64,
	inner_km:       f64,
	center_p:       f64, // ГПа
	center_t:       f64, // °C
	heat_flux:      f64, // Вт/м²
	tidal_w:        f64, // приливный нагрев, Вт
	magnetic_ut:    f64,
	plates:         bool,
	ocean_under:    bool, // океан под льдом
	ocean_frac:     f64, // доля поверхности под океаном (оценка)
	phys:           bool, // радиус и атмосфера посчитаны
	deep:           bool, // недра посчитаны
	seed:           u64,
}

Moon :: struct {
	using body:   Body,
	orbit_km:     f64,
	period_hours: f64,
	// орбита: эксцентриситет, наклон к плоскости орбиты планеты, узел, перицентр, средняя аномалия
	ecc, incl, node, peri, mean0: f64,
}

Planet :: struct {
	name:       string,
	kind:       Planet_Kind,
	orbit_au:   f64,
	year_hours: f64, // стандартных часов
	// эллиптическая орбита (astro.odin): эксцентриситет, долгота перицентра,
	// средняя аномалия в момент высадки
	ecc, peri, mean0: f64,
	using body: Body,
	moons:      [MAX_PLANET_MOONS]Moon,
	moon_n:     int,
}

// Наша планета — подробнее (для неба и времени).
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
	age_gyr:      f64, // возраст звезды и планет
	metal:        f64, // металличность [Fe/H], dex
	frost_au:     f64, // снеговая линия
	hz_in_au:     f64, // зона жизни (Коппарапу)
	hz_out_au:    f64,
	planets:      [MAX_PLANETS]Planet,
	planet_count: int,
	has_home:     bool,
	home:         Home_Planet,
	checked:      int, // сколько звёзд проверено, пока искали планету для высадки
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

// Сколько звезда живёт, пока горит водород в ядре, млрд лет (Солнце — 10).
star_lifetime_gyr :: proc(mass: f64) -> f64 {
	return 10 * math.pow(max(mass, 0.08), -2.5)
}

// Возраст звезды (и её планет), млрд лет — из её зерна, не меняя остальных параметров.
star_age_gyr :: proc(s: Star) -> f64 {
	r := eng.rng_make(s.seed ~ TAG_AGE)
	u := eng.rng_f64(&r)
	#partial switch s.class {
	case .Red_Giant:
		return star_lifetime_gyr(s.mass) * eng.rng_range(&r, 1.0, 1.15)
	case .White_Dwarf:
		return star_lifetime_gyr(s.mass * 3) + 0.1 + 9 * u
	case .Neutron, .Black_Hole:
		return 0.02 + 9 * u
	}
	return 0.1 + (min(12.5, 0.95 * star_lifetime_gyr(s.mass)) - 0.1) * u
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

// Грубая оценка радиуса до расчёта (км): для орбит лун и отбора кандидатов.
radius_estimate :: proc(mass_earth: f64, comp: Composition) -> f64 {
	if comp.gas > 0.3 do return 70_000 * clamp(math.pow(mass_earth / 318, 0.1), 0.6, 1.1)
	if comp.gas > 0 do return EARTH_RADIUS_KM * math.pow(mass_earth, 0.27) * (1.6 + 12 * comp.gas)
	return EARTH_RADIUS_KM * math.pow(mass_earth, 0.27) * (1 + 0.9 * comp.ice) * (1 - 0.3 * max(comp.iron - 0.33, 0))
}

@(private = "file")
gauss :: proc(r: ^eng.Rng) -> f64 {
	return (eng.rng_f64(r) + eng.rng_f64(r) + eng.rng_f64(r) + eng.rng_f64(r) - 2) * 1.732
}

// Состав каменной планеты: железо и камень (иногда железа много — как у Меркурия).
@(private = "file")
rocky_comp :: proc(r: ^eng.Rng, iron_rich: bool, ice: f64) -> Composition {
	iron := iron_rich ? eng.rng_range(r, 0.5, 0.7) : eng.rng_range(r, 0.24, 0.38)
	rest := 1 - ice
	return {iron = iron * rest, rock = (1 - iron) * rest, ice = ice}
}

// Система звезды star. physics — посчитать радиусы, атмосферы и недра всех тел
// (дорого; без этого — только орбиты, массы и состав, например для списков).
star_system_generate :: proc(world_seed: u32, star: Star, physics: bool) -> (s: Star_System) {
	r := eng.rng_make(star.seed * 0x2545F4914F6CDD1D + 1)
	o := eng.rng_make(star.seed ~ 0x0E11_1F5E) // орбиты — отдельно
	pm := eng.rng_make(star.seed ~ TAG_MASS)
	mr := eng.rng_make(star.seed ~ TAG_MOON)
	rt := eng.rng_make(star.seed ~ TAG_ROT)
	s.seed = world_seed
	s.star = star
	if physics do s.star.name = star_name(star.seed) // имена — только когда систему покажут
	s.age_gyr = star_age_gyr(star)
	s.metal = clamp(0.2 * gauss(&pm) - 0.05, -1, 0.5)

	lum := max(star.luminosity, 1e-5)
	sqrt_l := math.sqrt(lum)
	s.frost_au = 2.7 * sqrt_l
	s_in, s_out := habitable_flux(star.temperature)
	s.hz_in_au, s.hz_out_au = math.sqrt(lum / s_in), math.sqrt(lum / s_out)
	mass := max(star.mass, 0.08)

	// --- орбиты: первая близко к звезде, дальше — каждая в 1,35–2,3 раза дальше
	n := planet_count_for(star.class, &r)
	if n > 0 do s.planets[0].orbit_au = eng.rng_range(&r, 0.03, 0.4) * max(sqrt_l, 0.1)
	for i in 1 ..< n do s.planets[i].orbit_au = s.planets[i - 1].orbit_au * eng.rng_range(&r, 1.35, 2.3)
	s.planet_count = n

	letters := "bcdefghijk"
	giant_k := clamp(mass, 0.2, 2) * math.pow(10, 1.2 * s.metal) // гиганты — у массивных и «металлических» звёзд
	for i in 0 ..< n {
		p := &s.planets[i]
		if physics do p.name = fmt.aprintf("%s %c", s.star.name, rune(letters[i]))
		p.seed = mix64(star.seed ~ u64(i + 1) * 0x9E3779B97F4A7C15)
		a := p.orbit_au
		p.flux = lum / (a * a)
		beyond := a > s.frost_au
		roll := eng.rng_f64(&pm)
		switch {
		case !beyond && (roll < 0.012 * giant_k && a < 0.1 * max(sqrt_l, 0.3) || roll < 0.025 * giant_k):
			// горячий (тёплый) юпитер — ушёл к звезде из внешней системы
			p.kind = .Gas_Giant
		case beyond && roll < 0.3 * giant_k:
			p.kind = .Gas_Giant
		case beyond && roll < 0.3 * giant_k + 0.35:
			p.kind = .Ice_Giant
		case:
			p.kind = .Rocky
		}
		switch p.kind {
		case .Gas_Giant:
			p.mass_earth = math.pow(10, 1.5 + 2 * math.pow(eng.rng_f64(&pm), 1.4)) // 30..3000, чаще — как Сатурн и Юпитер
			z := clamp(12 * eng.rng_range(&pm, 0.6, 1.8) / p.mass_earth + 0.05, 0.05, 0.45) // тяжёлые элементы
			p.comp = {iron = 0.2 * z, rock = 0.4 * z, ice = 0.4 * z, gas = 1 - z}
		case .Ice_Giant:
			p.mass_earth = eng.rng_range(&pm, 8, 30)
			gas := eng.rng_range(&pm, 0.04, 0.15)
			ice := eng.rng_range(&pm, 0.6, 0.72)
			p.comp = {iron = (1 - gas - ice) * 0.3, rock = (1 - gas - ice) * 0.7, ice = ice, gas = gas}
		case .Rocky:
			lm := clamp(0.15 + 0.55 * gauss(&pm), -1.7, 1.2)
			if beyond do lm = clamp(-0.4 + 0.6 * gauss(&pm), -1.7, 1.0)
			p.mass_earth = math.pow(10, lm)
			iron_rich := !beyond && a < 0.6 * sqrt_l && eng.rng_f64(&pm) < 0.08
			if beyond {
				p.comp = rocky_comp(&pm, false, eng.rng_range(&pm, 0.25, 0.5))
			} else {
				// вода: чем ближе к снеговой линии, тем больше; изредка — водный мир, пришедший издалека
				w := logu(&pm, 5e-5, 2.5e-3) * (1 + 30 * smooth(0.5, 1.0, a / s.frost_au))
				if eng.rng_f64(&pm) < 0.06 do w = eng.rng_range(&pm, 0.05, 0.3)
				if w >= 0.02 {
					p.comp = rocky_comp(&pm, iron_rich, w)
					p.water = w
				} else {
					p.comp = rocky_comp(&pm, iron_rich, 0)
					p.water = 0.3 * w // остальная вода — в мантии
				}
				// крупные зародыши захватывают немного водорода — мини-нептуны,
				// но близко к звезде оболочку «сдувает»
				if eng.rng_f64(&pm) < 0.8 * smooth(0.25, 0.85, lm) {
					gas := eng.rng_range(&pm, 0.003, 0.05)
					if p.flux < 60 * math.pow(p.mass_earth / 4, 2) {
						k := 1 - gas
						p.comp = {iron = p.comp.iron * k, rock = p.comp.rock * k, ice = p.comp.ice * k, gas = gas}
						p.kind = .Ice_Giant
					}
				}
			}
		}
		p.year_hours = year_hours(a, mass)
		// вытянутость: у гигантов — меньше
		e_max := p.kind == .Rocky ? 0.25 : 0.12
		p.ecc = e_max * eng.rng_f64(&o) * eng.rng_f64(&o)
		p.peri = eng.rng_range(&o, 0, 2 * math.PI)
		p.mean0 = eng.rng_range(&o, 0, 2 * math.PI)
		p.flux /= math.sqrt(1 - p.ecc * p.ecc) // среднее за орбиту

		// вращение при рождении и наклон оси
		p.period0_hours = p.kind == .Rocky ? logu(&rt, 7, 30) : eng.rng_range(&rt, 9, 18)
		p.tilt_dir = eng.rng_range(&rt, 0, 2 * math.PI)
		tilt_u := eng.rng_f64(&rt)

		// --- луны (в пределах сферы Хилла, иначе звезда их отнимет)
		hill_km := a * AU_KM * math.cbrt(p.mass_earth / SUN_MASS_EARTHS / (3 * mass))
		r_est := radius_estimate(p.mass_earth, p.comp)
		count := 0
		orbit := 0.0
		switch p.kind {
		case .Rocky, .Ice_Giant:
			if p.kind == .Ice_Giant && p.comp.gas > 0.03 {
				count = eng.rng_int(&mr, 0, 4)
				orbit = r_est * eng.rng_range(&mr, 5, 12)
			} else if p.mass_earth > 0.08 {
				roll_m := eng.rng_f64(&mr)
				count = roll_m < 0.25 ? 0 : roll_m < 0.65 ? 1 : roll_m < 0.9 ? 2 : 3
				orbit = r_est * eng.rng_range(&mr, 12, 35)
			}
		case .Gas_Giant:
			count = eng.rng_int(&mr, 2, MAX_PLANET_MOONS)
			orbit = r_est * eng.rng_range(&mr, 4, 8)
		}
		planet_gm := GM_EARTH * p.mass_earth
		big_moon := false
		for k in 0 ..< count {
			if orbit > 0.4 * hill_km do break
			m := &p.moons[p.moon_n]
			m.seed = mix64(p.seed ~ u64(k + 1) * 0xD1B54A32D192ED03)
			m.orbit_km = orbit
			m.flux = p.flux
			switch p.kind {
			case .Gas_Giant:
				m.mass_earth = logu(&mr, 0.002, 0.03)
				ice := clamp(0.55 * f64(k) / f64(max(count - 1, 1)) + eng.rng_range(&mr, -0.12, 0.08), 0, 0.55)
				if beyond == false do ice = 0
				m.comp = rocky_comp(&mr, false, ice)
				m.comp.iron = min(m.comp.iron, (1 - ice) * 0.25)
				m.comp.rock = 1 - ice - m.comp.iron
				m.ecc = logu(&mr, 0.0005, 0.012)
			case .Ice_Giant:
				m.mass_earth = logu(&mr, 1e-4, 0.004)
				m.comp = rocky_comp(&mr, false, beyond ? eng.rng_range(&mr, 0.3, 0.5) : 0)
				m.ecc = logu(&mr, 0.0002, 0.01)
			case .Rocky:
				m.mass_earth = min(logu(&mr, 5e-5, 0.03), 0.05 * p.mass_earth)
				m.comp = rocky_comp(&mr, false, beyond ? eng.rng_range(&mr, 0.3, 0.5) : 0)
				m.comp.iron = min(m.comp.iron, 0.2 * (1 - m.comp.ice))
				m.comp.rock = 1 - m.comp.ice - m.comp.iron
				m.ecc = 0.08 * eng.rng_f64(&o) * eng.rng_f64(&o)
				if m.mass_earth > 0.005 * p.mass_earth do big_moon = true
			}
			a_m := m.orbit_km * 1000
			m.period_hours = 2 * math.PI * math.sqrt(a_m * a_m * a_m / planet_gm) / 3600
			m.incl = math.to_radians(eng.rng_range(&o, 0, 8))
			m.node = eng.rng_range(&o, 0, 2 * math.PI)
			m.peri = eng.rng_range(&o, 0, 2 * math.PI)
			m.mean0 = eng.rng_range(&o, 0, 2 * math.PI)
			p.moon_n += 1
			orbit *= p.kind == .Gas_Giant ? eng.rng_range(&mr, 1.5, 2.5) : eng.rng_range(&mr, 1.6, 2.6)
		}
		// большая луна держит ось; без неё наклон «гуляет» (как у Марса)
		p.axial_tilt_deg = big_moon ? 35 * tilt_u : 70 * tilt_u * tilt_u
	}
	if physics {
		for i in 0 ..< n do planet_physics(&s, i, true)
	}
	return
}

@(private = "file")
smooth :: proc(e0, e1, x: f64) -> f64 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}

// Параметры сжатия водородной оболочки: горячее у звезды, теплее у молодых и
// массивных (ещё не остыли); у горячих юпитеров — раздуты.
structure_params_for :: proc(mass_earth, t_eq, age_gyr: f64) -> Structure_Params {
	t_int := 165 * math.pow(mass_earth / 318, 0.25) * math.pow(4.5 / max(age_gyr, 0.2), 0.3)
	return {gas_t_irr = 1.3 * t_eq, gas_t_int = max(t_int, 30), gas_k = GAS_K * (1 + 0.5 * smooth(1000, 2000, t_eq))}
}

// Радиус, тяжесть, атмосфера, вращение тела (и недра, если deep).
@(private = "file")
body_physics :: proc(s: ^Star_System, b: ^Body, kind: Planet_Kind, deep: bool, strip: f64 = 1) {
	albedo := kind == .Rocky ? 0.3 : 0.34
	t_eq := equilibrium_temp(b.flux, albedo)
	sp := structure_params_for(b.mass_earth, t_eq, s.age_gyr)
	st := structure_solve(b.mass_earth, b.comp, &sp)
	b.radius_km = st.radius_km
	b.gravity_g = st.gravity_g
	b.v_esc = math.sqrt(2 * GM_EARTH * b.mass_earth / (st.radius_km * 1000)) / 1000
	b.atmo = atmosphere_make({
		mass_earth = b.mass_earth,
		radius_km  = b.radius_km,
		gravity_g  = b.gravity_g,
		flux       = b.flux,
		star_teff  = s.star.temperature,
		star_class = s.star.class,
		age_gyr    = s.age_gyr,
		water      = b.water,
		icy        = b.comp.ice > 0.1 && kind == .Rocky && b.water < 0.02,
		envelope   = b.comp.gas > 0,
		ice_giant  = kind == .Ice_Giant,
		gas_t1     = max(sp.gas_t_irr, sp.gas_t_int),
		seed       = b.seed,
		strip      = strip,
	})
	b.plates = b.atmo.plates && b.atmo.water == .Oceans
	// океан: доля поверхности (объём воды против средней глубины впадин)
	if b.water > 0 && b.comp.gas == 0 {
		depth := 3700 * clamp(1 / math.sqrt(b.gravity_g), 0.75, 1.6)
		area := 4 * math.PI * (b.radius_km * 1000) * (b.radius_km * 1000)
		b.ocean_frac = b.atmo.water == .Deep ? 1 : b.water * b.mass_earth * M_EARTH_KG / 1000 / (area * depth)
	}
	b.phys = true
	if deep do body_deep(s, b)
}

// Недра тела: сводка для таблиц (полный разрез — interior_make).
@(private = "file")
body_deep :: proc(s: ^Star_System, b: ^Body) {
	pi := interior_make(body_interior_input(s, b))
	defer free(pi)
	b.core_km, b.inner_km = pi.core_km, pi.inner_km
	b.center_p, b.center_t = pi.center_p, pi.center_t
	b.heat_flux, b.magnetic_ut = pi.heat_flux, pi.magnetic_ut
	b.ocean_under = pi.ocean_km[1] > 0 && pi.ocean_km[0] > 0
	b.deep = true
}

// Вход для расчёта недр тела системы.
body_interior_input :: proc(s: ^Star_System, b: ^Body) -> Interior_Input {
	albedo := b.comp.gas > 0 ? 0.34 : 0.3
	t_eq := equilibrium_temp(b.flux, albedo)
	r := eng.rng_make(b.seed ~ 0x4EA7)
	return {
		mass_earth = b.mass_earth,
		comp       = b.comp,
		t_surface  = b.atmo.t_surface,
		age_gyr    = s.age_gyr,
		heat_k     = math.pow(10, 0.6 * s.metal) * eng.rng_range(&r, 0.7, 1.4),
		tidal_w    = b.tidal_w,
		plates     = b.plates,
		sp         = structure_params_for(b.mass_earth, t_eq, s.age_gyr),
	}
}

// Время, за которое приливы тела массой m_pert (кг) на расстоянии a (м)
// затормозят вращение (с): ω·a⁶·I·Q / (3·G·M²·k2·R⁵).
@(private = "file")
despin_time :: proc(omega, a, m_body, r_body, m_pert: f64, giant: bool) -> f64 {
	inertia := (giant ? 0.25 : 0.33) * m_body * r_body * r_body
	q := giant ? 1e5 : 20.0 // у каменных — с океанами (у Земли ~12–20), у гигантов — огромная
	k2 := giant ? 0.38 : 0.3
	return omega * math.pow(a, 6) * inertia * q / (3 * G_SI * m_pert * m_pert * k2 * math.pow(r_body, 5))
}

// Физика планеты i: радиус, атмосфера, вращение, луны (и недра всех, если deep).
planet_physics :: proc(s: ^Star_System, i: int, deep: bool) {
	p := &s.planets[i]
	body_physics(s, &p.body, p.kind, false)
	age_s := s.age_gyr * 3.156e16
	year_s := p.year_hours * 3600
	m_p := p.mass_earth * M_EARTH_KG
	r_p := p.radius_km * 1000
	giant := p.kind != .Rocky

	// вращение: тормозят звезда и луны (линейно — момент сил постоянен)
	omega0 := 2 * math.PI / (p.period0_hours * 3600)
	n := 2 * math.PI / year_s
	slow := age_s / despin_time(omega0, p.orbit_au * AU_KM * 1000, m_p, r_p, s.star.mass * SUN_MASS_EARTHS * M_EARTH_KG, giant)
	for k in 0 ..< p.moon_n {
		m := &p.moons[k]
		slow += age_s / despin_time(omega0, m.orbit_km * 1000, m_p, r_p, m.mass_earth * M_EARTH_KG, giant)
	}
	omega := omega0 * (1 - slow)
	p.locked, p.resonance = false, false
	if omega <= n * 1.0001 {
		p.locked = true
		if p.ecc > 0.15 {
			p.resonance = true // вытянутая орбита: три оборота за два года
			omega = 1.5 * n
		} else {
			omega = n
		}
	}
	p.sidereal_hours = 2 * math.PI / omega / 3600
	p.day_hours = 0
	if !p.locked || p.resonance do p.day_hours = 1 / (1 / p.sidereal_hours - 1 / p.year_hours)

	// луны: повёрнуты к планете одной стороной; приливный нагрев (как у Ио и Европы)
	for k in 0 ..< p.moon_n {
		m := &p.moons[k]
		a_m := m.orbit_km * 1000
		nm := 2 * math.PI / (m.period_hours * 3600)
		// внутри магнитосферы гиганта луну «обдувает» плазма (Ио, Европа, Ганимед)
		strip := 1.0
		if p.kind == .Gas_Giant {
			b := math.pow(p.mass_earth / 318, 0.3)
			strip = 1 + 2.5 * b * b * 15 * r_p / a_m
		}
		body_physics(s, &m.body, .Rocky, false, strip)
		r_m := m.radius_km * 1000
		k2q := m.comp.ice > 0.1 ? 0.01 : 0.015
		m.tidal_w = 10.5 * k2q * G_SI * m_p * m_p * math.pow(r_m, 5) * nm * m.ecc * m.ecc / math.pow(a_m, 6)
		m.locked = true
		m.sidereal_hours = m.period_hours
		m.day_hours = 1 / (1 / m.period_hours - 1 / p.year_hours)
		if deep do body_deep(s, &m.body)
	}
	if deep do body_deep(s, &p.body)
}

// Вид тела словами.
body_type_name :: proc(b: ^Body, kind: Planet_Kind, moon: bool) -> string {
	switch kind {
	case .Gas_Giant:
		return b.flux > 50 ? "горячий юпитер" : "газовый гигант"
	case .Ice_Giant:
		return b.mass_earth < 10 && b.comp.gas < 0.06 ? "мини-нептун" : "ледяной гигант"
	case .Rocky:
	}
	if moon {
		switch {
		case b.tidal_w > 2e13:
			return "вулканическая луна"
		case b.ocean_under:
			return "луна с океаном подо льдом"
		case b.comp.ice > 0.1 && b.atmo.kind == .Thick:
			return "ледяная луна с плотным воздухом"
		case b.comp.ice > 0.1:
			return "ледяная луна"
		}
		return "каменная луна"
	}
	switch {
	case b.atmo.water == .Steam:
		return "паровой мир: кипящий океан"
	case b.atmo.water == .Deep:
		return "водный мир"
	case b.comp.ice > 0.1:
		return b.ocean_under ? "ледяной мир с океаном подо льдом" : "ледяной мир"
	case b.comp.iron > 0.5:
		return "железная планета"
	case b.atmo.runaway:
		return b.atmo.t_surface > 400 ? "раскалённая, как Венера" : "сухая: океаны выкипели"
	case b.atmo.water == .Oceans && b.atmo.plants:
		return "живая: океаны, суша, леса"
	case b.atmo.water == .Oceans && b.atmo.life:
		return "океаны и суша, жизнь в воде"
	case b.atmo.water == .Oceans:
		return "океаны и суша"
	case b.atmo.water == .Frozen:
		return "скованная льдом"
	case b.atmo.kind == .None:
		return b.mass_earth > 2 ? "безвоздушная суперземля" : "безвоздушная"
	case b.mass_earth > 2:
		return "суперземля"
	case b.atmo.kind == .Thin:
		return "холодная пустыня"
	}
	return "пустыня"
}

// ---------------------------------------------------------------- высадка

// Можно ли высадиться на планету i: твёрдая поверхность, океаны и суша,
// умеренная температура, воздух для дыхания, растения, сносная тяжесть,
// день и ночь. why — чего не хватило.
start_check :: proc(s: ^Star_System, i: int) -> (ok: bool, why: string) {
	p := &s.planets[i]
	a := &p.atmo
	switch {
	case p.kind != .Rocky:
		return false, "нет твёрдой поверхности"
	case p.comp.ice > 0:
		return false, "вода покрывает всё"
	case a.water != .Oceans:
		return false, "нет океанов"
	case p.ocean_frac < 0.15 || p.ocean_frac > 0.85:
		return false, p.ocean_frac > 0.85 ? "почти нет суши" : "почти нет океанов"
	case a.t_surface < 273 || a.t_surface > 303:
		return false, a.t_surface < 273 ? "холодно" : "жарко"
	case !a.plants:
		return false, a.life ? "жизнь ещё не вышла на сушу" : "нет жизни"
	case a.o2_kpa < 16 || a.o2_kpa > 50:
		return false, a.o2_kpa < 16 ? "мало кислорода" : "слишком много кислорода"
	case a.pressure > 3.04:
		return false, "давление выше 3 атмосфер"
	case a.frac[.CO2] * a.pressure > 0.01:
		return false, "углекислого газа больше 1 кПа — ядовито"
	case p.gravity_g < 0.4 || p.gravity_g > 1.8:
		return false, "тяжесть вне 0,4–1,8 g"
	case p.locked && !p.resonance:
		return false, "повёрнута к звезде одной стороной"
	case p.day_hours < 10 || p.day_hours > 60:
		return false, "сутки вне 10–60 ч"
	}
	return true, ""
}

// Быстрый отбор до дорогого расчёта (только отбрасывает заведомо неподходящие).
@(private = "file")
start_candidate :: proc(s: ^Star_System, i: int) -> bool {
	p := &s.planets[i]
	if p.kind != .Rocky || p.comp.ice > 0 || p.water < 1e-6 do return false
	// океаны бывают только в зоне жизни (ближе — выкипают, дальше — замерзают)
	s_in, s_out := habitable_flux(s.star.temperature)
	if p.flux < s_out || p.flux > s_in || p.mass_earth < 0.06 || p.mass_earth > 8 do return false
	r_est := radius_estimate(p.mass_earth, p.comp) * 1000
	ocean := p.water * p.mass_earth * M_EARTH_KG / 1000 / (4 * math.PI * r_est * r_est * 3700)
	if ocean > 2.5 || ocean < 0.05 do return false // с большим запасом: оценка грубая
	// приливная остановка с запасом: оценка радиуса грубая
	omega0 := 2 * math.PI / (p.period0_hours * 3600)
	t := despin_time(omega0, p.orbit_au * AU_KM * 1000, p.mass_earth * M_EARTH_KG, r_est * 1.3, s.star.mass * SUN_MASS_EARTHS * M_EARTH_KG, false)
	return t * 4 > s.age_gyr * 3.156e16
}

// Планета для высадки в системе (лёгкой — без физики): -1 — нет.
// reasons — если задано, сюда считаются причины отказа (для -planets).
system_find_start :: proc(s: ^Star_System, reasons: ^map[string]int = nil) -> int {
	#partial switch s.star.class {
	case .Red_Giant, .White_Dwarf, .Neutron, .Black_Hole:
		return -1 // звезда уже сошла с главной последовательности: прежние планеты выжжены или заморожены
	}
	if s.age_gyr < 1.75 do return -1 // растения выходят на сушу через миллиарды лет
	for i in 0 ..< s.planet_count {
		if !start_candidate(s, i) do continue
		planet_physics(s, i, false)
		ok, why := start_check(s, i)
		if ok do return i
		if reasons != nil do reasons[why] += 1
	}
	return -1
}

// Делает планету i нашей: сутки, наклон, луны, место высадки.
star_system_set_home :: proc(s: ^Star_System, i: int, world_seed: u32) {
	p := &s.planets[i]
	if !p.phys do planet_physics(s, i, true)
	s.has_home = true
	h := &s.home
	h.index = i
	h.gravity_g = p.gravity_g
	h.day_hours = p.day_hours
	h.sidereal_hours = p.sidereal_hours
	h.axial_tilt_deg = p.axial_tilt_deg
	h.tilt_dir = p.tilt_dir
	h.year_days = p.year_hours / p.day_hours
	h.moon_count = min(p.moon_n, MAX_MOONS)
	for k in 0 ..< h.moon_count do h.moons[k] = p.moons[k]
	r := eng.rng_make(u64(world_seed) ~ TAG_SITE)
	sign: f64 = eng.rng_f64(&r) < 0.5 ? -1 : 1
	h.latitude_deg = sign * eng.rng_range(&r, 25, 55)
	h.longitude_deg = eng.rng_range(&r, 0, 360)
}

star_system_destroy :: proc(s: ^Star_System) {
	if len(s.star.name) > 0 do delete(s.star.name)
	for i in 0 ..< s.planet_count do if len(s.planets[i].name) > 0 do delete(s.planets[i].name)
}

home_planet :: proc(s: ^Star_System) -> ^Planet {
	return &s.planets[s.home.index]
}
