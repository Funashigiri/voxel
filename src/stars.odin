package main

// Звёзды галактик. Плотность — из модели галактики (universe.odin), доли
// типов — как у реальных звёзд: три четверти — красные карлики, горячие
// голубые — редкость. Есть красные гиганты, белые карлики, нейтронные звёзды
// и чёрные дыры.
//
// Звёзды каждого типа лежат в своей сетке клеток: частые тусклые — в мелкой,
// редкие яркие — в крупной. Тогда яркие звёзды на тысячи световых лет вокруг
// (для будущего ночного неба) находятся быстро, без перебора миллиардов
// карликов. Содержимое клетки зависит только от зерна и номера клетки.

import "core:math"
import eng "engine"

Star_Class :: enum u8 {
	M, // красный карлик
	K, // оранжевый карлик
	G, // жёлтый карлик (как Солнце)
	F, // жёлто-белая звезда
	A, // белая звезда
	B, // бело-голубая звезда
	O, // голубая звезда
	Red_Giant,
	White_Dwarf,
	Neutron,
	Black_Hole,
}

STAR_CLASS_NAMES := [Star_Class]string {
	.M           = "красный карлик",
	.K           = "оранжевый карлик",
	.G           = "жёлтый карлик",
	.F           = "жёлто-белая звезда",
	.A           = "белая звезда",
	.B           = "бело-голубая звезда",
	.O           = "голубая звезда",
	.Red_Giant   = "красный гигант",
	.White_Dwarf = "белый карлик",
	.Neutron     = "нейтронная звезда",
	.Black_Hole  = "чёрная дыра",
}

Star :: struct {
	name:        string,
	class:       Star_Class,
	mass:        f64, // масс Солнца
	luminosity:  f64, // светимостей Солнца
	radius:      f64, // радиусов Солнца (у чёрной дыры — горизонт)
	temperature: f64, // К
	color:       [3]f32,
	pos:         U_Pos,
	seed:        u64,
}

// frac — доля среди звёзд в плоскости диска, cell — размер клетки сетки, св. лет,
// z — толщина их слоя относительно диска (молодые горячие — тонким слоем у
// плоскости, как в нашей галактике: голубые ~60 пк, белые ~120 пк).
Star_Tier :: struct {
	frac: f64,
	cell: i64,
	z:    f64,
}

STAR_TIERS := [Star_Class]Star_Tier {
	.M           = {0.7082, 8, 1},
	.K           = {0.12, 16, 1},
	.G           = {0.075, 16, 1},
	.F           = {0.03, 32, 1},
	.A           = {0.006, 64, 0.5},
	.B           = {0.0013, 128, 0.2},
	.O           = {3e-7, 1024, 0.15},
	.Red_Giant   = {0.003, 64, 1},
	.White_Dwarf = {0.05, 16, 1},
	.Neutron     = {0.004, 64, 1},
	.Black_Hole  = {0.0005, 128, 1},
}

ALL_STARS :: bit_set[Star_Class]{.M, .K, .G, .F, .A, .B, .O, .Red_Giant, .White_Dwarf, .Neutron, .Black_Hole}

@(private = "file")
TAG_STAR :: 0x57A2_CE11
@(private = "file")
TAG_NAME :: 0x4A3E

SUN_RADIUS_KM :: 695_700.0

// Поправка на возраст звёздного населения галактики: в старых (эллиптических)
// горячие звёзды давно погасли, зато больше гигантов и белых карликов.
star_pop_mult :: proc "contextless" (g: ^Galaxy, class: Star_Class) -> f64 {
	y := min(g.young, 1)
	#partial switch class {
	case .O, .B:
		return g.young
	case .A:
		return math.sqrt(g.young)
	case .F:
		return 0.5 + 0.5 * y
	case .White_Dwarf:
		return 2 - y
	}
	return 1
}

// Горячие молодые звёзды сильнее собраны в рукава.
@(private = "file")
arm_power_of :: proc "contextless" (class: Star_Class) -> f64 {
	return class == .O || class == .B ? 2 : 1
}

// Параметры звезды по классу.
star_params :: proc(s: ^Star, r: ^eng.Rng) {
	ms :: proc(s: ^Star, r: ^eng.Rng, m0, m1, t0, t1, skew: f64) {
		t := math.pow(eng.rng_f64(r), skew) // skew > 1 — чаще лёгкие
		s.mass = math.lerp(m0, m1, t)
		s.temperature = math.lerp(t0, t1, t) * eng.rng_range(r, 0.97, 1.03)
		m := s.mass
		switch {
		case m < 0.43:
			s.luminosity = 0.23 * math.pow(m, 2.3)
		case m < 2:
			s.luminosity = math.pow(m, 4)
		case m < 55:
			s.luminosity = 1.4 * math.pow(m, 3.5)
		case:
			s.luminosity = 32000 * m
		}
		s.radius = m < 1 ? math.pow(m, 0.8) : math.pow(m, 0.57)
	}
	switch s.class {
	case .M:
		ms(s, r, 0.08, 0.6, 2400, 3900, 1.6)
	case .K:
		ms(s, r, 0.6, 0.85, 3900, 5200, 1)
	case .G:
		ms(s, r, 0.85, 1.1, 5200, 6000, 1)
	case .F:
		ms(s, r, 1.1, 1.4, 6000, 7500, 1)
	case .A:
		ms(s, r, 1.4, 2.5, 7500, 10000, 1.3)
	case .B:
		ms(s, r, 2.5, 16, 10000, 30000, 4) // больше всего поздних, неярких
	case .O:
		ms(s, r, 16, 90, 30000, 50000, 2)
	case .Red_Giant:
		s.mass = 0.8 + 2.2 * math.pow(eng.rng_f64(r), 2)
		// ветви гигантов: нижняя (3–9 радиусов Солнца) — 30%, «красное сгущение»
		// (9–12) — 63%, верхняя (12–35) — 6,3%, яркие гиганты (35–90) — 0,7%
		roll := eng.rng_f64(r)
		switch {
		case roll < 0.30:
			s.radius = eng.rng_range(r, 3, 9)
		case roll < 0.93:
			s.radius = eng.rng_range(r, 9, 12)
		case roll < 0.993:
			s.radius = eng.rng_range(r, 12, 35)
		case:
			s.radius = eng.rng_range(r, 35, 90)
		}
		s.temperature = s.radius > 35 ? eng.rng_range(r, 3400, 4300) : eng.rng_range(r, 3800, 5100)
		s.luminosity = s.radius * s.radius * math.pow(s.temperature / 5772, 4)
	case .White_Dwarf:
		s.mass = 0.55 + 0.5 * math.pow(eng.rng_f64(r), 3)
		s.radius = 0.01 * math.cbrt(0.6 / s.mass) // размером с Землю
		s.temperature = 4000 * math.pow(10, math.pow(eng.rng_f64(r), 2))
		s.luminosity = s.radius * s.radius * math.pow(s.temperature / 5772, 4)
	case .Neutron:
		s.mass = eng.rng_range(r, 1.2, 2.1)
		s.radius = eng.rng_range(r, 11, 13) / SUN_RADIUS_KM // ~12 км
		s.temperature = 30000 * math.pow(10, 1.5 * eng.rng_f64(r))
		s.luminosity = s.radius * s.radius * math.pow(s.temperature / 5772, 4)
	case .Black_Hole:
		s.mass = 5 + 35 * math.pow(eng.rng_f64(r), 2)
		s.radius = 2.953 * s.mass / SUN_RADIUS_KM // горизонт событий: 3 км на массу Солнца
	}
	s.color = s.class == .Black_Hole ? {} : star_color(s.temperature)
}

star_name :: proc(seed: u64, allocator := context.allocator) -> string {
	r := eng.rng_make(seed ~ TAG_NAME)
	return make_name(&r, 2, 3, allocator)
}

@(private = "file")
Cell_Galaxy :: struct {
	g:    ^Galaxy,
	rel:  [3]f64, // начало клетки относительно центра галактики, св. лет
	mult: f64,
}

@(private = "file")
cell_density :: proc(act: []Cell_Galaxy, local: [3]f64, arm_power, z_scale: f64) -> f64 {
	rho := 0.0
	for &a in act do rho += galaxy_density(a.g, a.rel + local, arm_power, z_scale) * a.mult
	return rho
}

// Звёзды одного класса в клетке c его сетки. gals — галактики, которые могут
// её задевать (лишние не мешают: дальше extent плотность галактики — ноль).
star_cell :: proc(u: ^Universe, class: Star_Class, c: [3]Big, gals: []Galaxy, out: ^[dynamic]Star) {
	tier := STAR_TIERS[class]
	S := f64(tier.cell)
	origin := [3]Big{big_mul_i(c[0], tier.cell), big_mul_i(c[1], tier.cell), big_mul_i(c[2], tier.cell)}
	at_origin := U_Pos{cell = origin, off = {-LY / 2, -LY / 2, -LY / 2}} // угол клетки

	act := make([dynamic]Cell_Galaxy, 0, 4, context.temp_allocator)
	for &g in gals {
		rel := upos_delta_ly(at_origin, g.center)
		if len3(rel + S / 2) > g.extent + S * 0.87 do continue
		append(&act, Cell_Galaxy{&g, rel, star_pop_mult(&g, class)})
	}
	if len(act) == 0 do return

	// средняя и наибольшая плотность по центру и углам клетки
	power := arm_power_of(class)
	zs := tier.z
	mean := cell_density(act[:], {S / 2, S / 2, S / 2}, power, zs)
	peak := mean
	for corner in 0 ..< 8 {
		rho := cell_density(act[:], {f64(corner & 1) * S, f64((corner >> 1) & 1) * S, f64((corner >> 2) & 1) * S}, power, zs)
		mean += rho
		peak = max(peak, rho)
	}
	mean /= 9
	lambda := mean * tier.frac * S * S * S
	if lambda < 1e-12 do return

	h := hash3big(u.seed ~ TAG_STAR ~ u64(class) * 0x9E3779B97F4A7C15, c)
	r := eng.rng_make(h)
	count := min(poisson(&r, lambda), 50_000)
	for i in 0 ..< count {
		s := Star{class = class, seed = mix64(h ~ u64(i + 1) * 0xA0761D6478BD642F)}
		sr := eng.rng_make(s.seed)
		// место — чаще там, где плотнее (выбор с отбраковкой)
		local: [3]f64
		for _ in 0 ..< 12 {
			local = {eng.rng_f64(&sr) * S, eng.rng_f64(&sr) * S, eng.rng_f64(&sr) * S}
			if eng.rng_f64(&sr) * peak * 1.3 <= cell_density(act[:], local, power, zs) do break
		}
		s.pos = upos_at(origin, local)
		star_params(&s, &sr)
		append(out, s)
	}
}

// Все звёзды выбранных классов в шаре (center, radius) — без повторов и
// независимо от того, откуда спрашивают.
stars_near :: proc(u: ^Universe, center: U_Pos, radius: f64, classes: bit_set[Star_Class], out: ^[dynamic]Star) {
	gals := make([dynamic]Galaxy, context.temp_allocator)
	galaxies_around(u, center, radius, &gals)
	if len(gals) == 0 do return
	tmp := make([dynamic]Star, context.temp_allocator)
	ri := i64(math.ceil(radius)) + 1
	for class in classes {
		S := STAR_TIERS[class].cell
		lo: [3]Big
		n: [3]i64
		for k in 0 ..< 3 {
			lo[k], _ = big_floor_div(big_add_i(center.cell[k], -ri), S)
			hi, _ := big_floor_div(big_add_i(center.cell[k], ri), S)
			n[k], _ = big_to_i64(big_sub(hi, lo[k]))
			n[k] += 1
		}
		for z in 0 ..< n.z do for y in 0 ..< n.y do for x in 0 ..< n.x {
			c := [3]Big{big_add_i(lo[0], x), big_add_i(lo[1], y), big_add_i(lo[2], z)}
			// клетка целиком дальше радиуса — пропускаем
			corner := U_Pos{cell = {big_mul_i(c[0], S), big_mul_i(c[1], S), big_mul_i(c[2], S)}, off = {-LY / 2, -LY / 2, -LY / 2}}
			rel := upos_delta_ly(corner, center)
			gap: [3]f64
			for k in 0 ..< 3 do gap[k] = max(0, rel[k], -(rel[k] + f64(S)))
			if len3(gap) > radius do continue
			clear(&tmp)
			star_cell(u, class, c, gals[:], &tmp)
			for s in tmp {
				if len3(upos_delta_ly(s.pos, center)) <= radius do append(out, s)
			}
		}
	}
}
