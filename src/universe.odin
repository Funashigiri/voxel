package main

// Вселенная — бесконечная, с настоящими расстояниями. Ничего не хранится:
// всё вычисляется из зерна мира и координат, когда понадобится:
//   космическая паутина (плотность) -> галактики в клетках по 1 Мпк ->
//   звёзды в клетках по несколько световых лет (stars.odin) -> планеты.
// Координаты — длинные целые световые годы (bignum.odin) плюс метры, поэтому
// края нет нигде, а точность везде — до метра.
//
// Вселенная расширяется (плоская модель с тёмной энергией, параметры Planck).
// Координаты сопутствующие: галактики стоят на растягивающейся сетке, а сами
// галактики, группы и скопления держит гравитация — внутри них ничего не
// растягивается. За время игры расширение ничтожно (~7·10⁻¹¹ в год).

import "core:math"
import "core:slice"
import eng "engine"

LY :: 9.4607304725808e15 // метров в световом году
MPC_LY :: 3_261_564 // световых лет в мегапарсеке
GAL_CELL :: i64(MPC_LY) // клетка сетки галактик — 1 Мпк

// космология (Planck 2018)
H0 :: 67.7 // км/с на мегапарсек
OMEGA_M :: 0.31
OMEGA_L :: 0.69
HUBBLE_TIME_YEARS :: 977.8e9 / H0 // 1/H0 в годах; c/H0 в св. годах — то же число

// галактики
GAL_PER_MPC3 :: 0.12 // в среднем на кубический мегапарсек (без спутников)
SCHECHTER_STARS :: 1e11 // характерное число звёзд (как у Млечного Пути)
SCHECHTER_ALPHA :: -1.25 // карликов много, гигантов мало
GAL_MIN_STARS :: 1e7
GAL_MAX_STARS :: 3e13
@(private = "file")
SCH_LO :: 7.0 // таблица по десятичному логарифму числа звёзд
@(private = "file")
SCH_HI :: 13.5
@(private = "file")
SCH_STEPS :: 400

// метки хешей, чтобы разные слои генерации не повторяли друг друга
@(private = "file")
TAG_WEB :: [4]u64{0x57EB_0001, 0x57EB_0002, 0x57EB_0003, 0x57EB_0004}
@(private = "file")
TAG_GALCELL :: 0x6A1C_E11
@(private = "file")
TAG_NORM :: 0x4E0F_3A11
@(private = "file")
TAG_HOME :: 0x40AE_5EED

// Точка во вселенной: целый световой год + метры от его центра.
U_Pos :: struct {
	cell: [3]Big,
	off:  [3]f64, // |off| <= LY/2
}

// Вектор a - b в световых годах (для близких точек — точно).
upos_delta_ly :: proc(a, b: U_Pos) -> (d: [3]f64) {
	for k in 0 ..< 3 do d[k] = big_to_f64(big_sub(a.cell[k], b.cell[k])) + (a.off[k] - b.off[k]) / LY
	return
}

upos_add_ly :: proc(p: U_Pos, d: [3]f64, allocator := context.temp_allocator) -> (q: U_Pos) {
	for k in 0 ..< 3 {
		t := p.off[k] / LY + d[k]
		whole := math.floor(t + 0.5)
		q.cell[k] = big_add_i(p.cell[k], i64(whole), allocator)
		q.off[k] = (t - whole) * LY
	}
	return
}

// Точка origin + p (origin — целые св. годы, p — св. годы от него).
upos_at :: proc(origin: [3]Big, p: [3]f64, allocator := context.temp_allocator) -> (q: U_Pos) {
	for k in 0 ..< 3 {
		whole := math.floor(p[k])
		q.cell[k] = big_add_i(origin[k], i64(whole), allocator)
		q.off[k] = (p[k] - whole - 0.5) * LY
	}
	return
}

upos_clone :: proc(p: U_Pos, allocator := context.allocator) -> (q: U_Pos) {
	q.off = p.off
	for k in 0 ..< 3 do q.cell[k] = big_clone(p.cell[k], allocator)
	return
}

len3 :: proc "contextless" (v: [3]f64) -> f64 {
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
}

dot3d :: proc "contextless" (a, b: [3]f64) -> f64 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

hash3big :: proc "contextless" (h: u64, c: [3]Big) -> u64 {
	return big_hash(big_hash(big_hash(h, c[0]), c[1]), c[2])
}

// ---------------------------------------------------------------- случайности

gauss :: proc "contextless" (r: ^eng.Rng) -> f64 {
	u1 := 1 - eng.rng_f64(r)
	u2 := eng.rng_f64(r)
	return math.sqrt(-2 * math.ln(u1)) * math.cos(2 * math.PI * u2)
}

poisson :: proc "contextless" (r: ^eng.Rng, lambda: f64) -> int {
	if lambda <= 0 do return 0
	if lambda < 30 {
		l := math.exp(-lambda)
		k := 0
		p := 1.0
		for {
			p *= eng.rng_f64(r)
			if p <= l do break
			k += 1
		}
		return k
	}
	return max(0, int(math.round(lambda + math.sqrt(lambda) * gauss(r))))
}

random_unit :: proc "contextless" (r: ^eng.Rng) -> [3]f64 {
	z := 2 * eng.rng_f64(r) - 1
	a := 2 * math.PI * eng.rng_f64(r)
	s := math.sqrt(max(0, 1 - z * z))
	return {s * math.cos(a), s * math.sin(a), z}
}

// Множитель с разбросом sigma в десятичных порядках.
@(private = "file")
lognorm :: proc "contextless" (r: ^eng.Rng, sigma_dex: f64) -> f64 {
	return math.pow(10, gauss(r) * sigma_dex)
}

@(private = "file")
smooth01 :: proc "contextless" (e0, e1, x: f64) -> f64 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}

// ---------------------------------------------------------------- вселенная

Galaxy_Cell :: struct {
	key:      [3]Big,
	galaxies: [dynamic]Galaxy,
}

Universe :: struct {
	seed:          u64,
	world_seed:    u32, // зерно мира (им же — рельеф планет)
	web_norm:      f64, // делитель плотности паутины (средняя плотность = 1)
	gal_density:   f64, // измеренная средняя плотность галактик со спутниками, на Мпк³
	sch_cdf:       [SCH_STEPS + 1]f64,
	cells:         map[u64]Galaxy_Cell, // уже сгенерированные клетки галактик
	age_years:     f64,
	horizon_ly:    f64, // горизонт событий: дальше не долететь даже со скоростью света
	observable_ly: f64, // радиус видимой части
}

universe_init :: proc(u: ^Universe, world_seed: u32) {
	u.seed = mix64(u64(world_seed) ~ 0x0123_4567_89AB_CDEF)
	u.world_seed = world_seed

	// распределение галактик по числу звёзд (функция Шехтера), в логарифмах
	acc := 0.0
	prev := 0.0
	for i in 0 ..= SCH_STEPS {
		x := math.pow(10, SCH_LO + (SCH_HI - SCH_LO) * f64(i) / SCH_STEPS) / SCHECHTER_STARS
		pdf := math.pow(x, SCHECHTER_ALPHA + 1) * math.exp(-x)
		if i > 0 do acc += (pdf + prev) / 2
		prev = pdf
		u.sch_cdf[i] = acc
	}
	for &v in u.sch_cdf do v /= acc

	// нормировка паутины и средняя плотность галактик — по случайным клеткам
	r := eng.rng_make(u.seed ~ TAG_NORM)
	SAMPLES :: 4000
	sum := 0.0
	for _ in 0 ..< SAMPLES do sum += web_raw(u, random_key(&r, 1 << 40))
	u.web_norm = sum / SAMPLES
	count := 0
	tmp := make([dynamic]Galaxy, context.temp_allocator)
	for _ in 0 ..< SAMPLES {
		clear(&tmp)
		galaxy_cell_generate(u, random_key(&r, 1 << 40), &tmp)
		count += len(tmp)
	}
	u.gal_density = f64(count) / SAMPLES

	// возраст, горизонт событий, радиус видимой части (без учёта излучения)
	u.age_years = HUBBLE_TIME_YEARS * 2 / (3 * math.sqrt(OMEGA_L)) * math.asinh(math.sqrt(OMEGA_L / OMEGA_M))
	u.horizon_ly = HUBBLE_TIME_YEARS * simpson(proc(x: f64) -> f64 {return 1 / math.sqrt(OMEGA_M * x * x * x + OMEGA_L)})
	u.observable_ly = HUBBLE_TIME_YEARS * simpson(proc(s: f64) -> f64 {return 2 / math.sqrt(OMEGA_M + OMEGA_L * math.pow(s, 6))})
}

universe_destroy :: proc(u: ^Universe) {
	for _, &c in u.cells {
		for &g in c.galaxies do for k in 0 ..< 3 do big_delete(g.center.cell[k])
		for k in 0 ..< 3 do big_delete(c.key[k])
		delete(c.galaxies)
	}
	delete(u.cells)
}

// Интеграл функции на [0, 1] по Симпсону.
@(private = "file")
simpson :: proc(f: proc(x: f64) -> f64) -> f64 {
	N :: 2000
	h := 1.0 / N
	s := f(0) + f(1)
	for i in 1 ..< N do s += f(f64(i) * h) * (i % 2 == 1 ? 4 : 2)
	return s * h / 3
}

@(private = "file")
random_key :: proc(r: ^eng.Rng, span: i64) -> (k: [3]Big) {
	for a in 0 ..< 3 do k[a] = big(i64(eng.rng_u64(r) % u64(2 * span)) - span)
	return
}

// Удаление галактики от нас из-за расширения, км/с (d — в св. годах).
recession_kms :: proc(d_ly: f64) -> f64 {
	return H0 * d_ly / MPC_LY
}

// ---------------------------------------------------------------- паутина

@(private = "file")
GRAD12 := [12][3]f64 {
	{1, 1, 0}, {-1, 1, 0}, {1, -1, 0}, {-1, -1, 0},
	{1, 0, 1}, {-1, 0, 1}, {1, 0, -1}, {-1, 0, -1},
	{0, 1, 1}, {0, -1, 1}, {0, 1, -1}, {0, -1, -1},
}

// Градиентный шум по решётке с шагом step клеток галактик. Узлы решётки
// хешируются длинными числами, поэтому шум одинаково работает в любой дали.
@(private = "file")
big_noise :: proc(seed: u64, c: [3]Big, step: i64) -> f64 {
	f: [3]f64
	hs: [3][2]u64
	for k in 0 ..< 3 {
		q, rem := big_floor_div(c[k], step)
		f[k] = (f64(rem) + 0.5) / f64(step)
		ks := seed ~ u64(k + 1) * 0x9E3779B97F4A7C15
		hs[k] = {big_hash(ks, q), big_hash(ks, big_add_i(q, 1))}
	}
	fade :: proc "contextless" (t: f64) -> f64 {return t * t * t * (t * (t * 6 - 15) + 10)}
	w := [3]f64{fade(f.x), fade(f.y), fade(f.z)}
	sum := 0.0
	for corner in 0 ..< 8 {
		i, j, l := corner & 1, (corner >> 1) & 1, (corner >> 2) & 1
		h := mix64(mix64(hs[0][i] ~ hs[1][j] * 0xC2B2AE3D27D4EB4F) ~ hs[2][l] * 0x165667B19E3779F9)
		g := GRAD12[h % 12]
		d := [3]f64{f.x - f64(i), f.y - f64(j), f.z - f64(l)}
		wx := i == 1 ? w.x : 1 - w.x
		wy := j == 1 ? w.y : 1 - w.y
		wz := l == 1 ? w.z : 1 - w.z
		sum += (g.x * d.x + g.y * d.y + g.z * d.z) * wx * wy * wz
	}
	return sum
}

// Плотность паутины до нормировки. Две независимые "стенки" (где шум около
// нуля); их пересечения — нити, где густо; вдали от стенок — пустоты.
@(private = "file")
web_raw :: proc(u: ^Universe, c: [3]Big) -> f64 {
	tw := TAG_WEB
	a := big_noise(u.seed ~ tw[0], c, 20) + 0.4 * big_noise(u.seed ~ tw[1], c, 7)
	b := big_noise(u.seed ~ tw[2], c, 20) + 0.4 * big_noise(u.seed ~ tw[3], c, 7)
	fa := max(0, 1 - abs(a) * 1.6)
	fb := max(0, 1 - abs(b) * 1.6)
	f := fa * fb
	return 0.1 + 30 * f * f * f * f
}

// Плотность галактик в клетке относительно средней по вселенной.
web_density :: proc(u: ^Universe, c: [3]Big) -> f64 {
	return web_raw(u, c) / u.web_norm
}

// ---------------------------------------------------------------- галактики

Galaxy_Kind :: enum u8 {
	Spiral,
	Barred_Spiral,
	Lenticular,
	Elliptical,
	Irregular,
	Dwarf_Elliptical,
	Dwarf_Irregular,
}

GALAXY_KIND_NAMES := [Galaxy_Kind]string {
	.Spiral           = "спиральная",
	.Barred_Spiral    = "спиральная с перемычкой",
	.Lenticular       = "линзовидная",
	.Elliptical       = "эллиптическая",
	.Irregular        = "неправильная",
	.Dwarf_Elliptical = "карликовая эллиптическая",
	.Dwarf_Irregular  = "карликовая неправильная",
}

MAX_CLUMPS :: 6

// Сгусток звёзд неправильной галактики (в осях галактики).
Clump :: struct {
	pos:  [3]f64,
	a:    f64,
	rho0: f64,
}

// Галактика: несколько составляющих с плотностью звёзд (на кубический св. год):
// экспоненциальный диск с рукавами, балдж или эллипсоид (модель Пламмера),
// перемычка, гало, сгустки. Оси: n — ось диска, e1 и e2 — в его плоскости.
Galaxy :: struct {
	seed:      u64,
	center:    U_Pos,
	kind:      Galaxy_Kind,
	stars:     f64,
	satellite: bool,
	n, e1, e2: [3]f64,
	extent:    f64, // дальше звёзд нет, св. лет
	young:     f64, // молодых горячих звёзд относительно нашей галактики
	dust:      f64, // сколько пыли (1 — как в нашей)
	disk_r, disk_h, disk_rho0: f64,
	arms:      int,
	arm_pitch, arm_phase, arm_amp: f64,
	sph_a, sph_q, sph_rho0: f64,
	bar_a, bar_b, bar_rho0: f64,
	halo_a, halo_rho0: f64,
	clumps:    [MAX_CLUMPS]Clump,
	clump_n:   int,
	bh_mass:   f64, // центральная чёрная дыра, масс Солнца
}

@(private = "file")
plummer_shape :: proc "contextless" (s2: f64) -> f64 {
	t := 1 + s2
	return 1 / (t * t * math.sqrt(t))
}

@(private = "file")
plummer_rho0 :: proc "contextless" (n, a, b, c: f64) -> f64 {
	return 3 * n / (4 * math.PI * a * b * c)
}

// Усиление плотности в рукавах (среднее по кругу — 1). s — "насколько в рукаве", -1..1.
galaxy_arm :: proc "contextless" (g: ^Galaxy, x, y, R: f64) -> (factor, s: f64) {
	if g.arms == 0 || R <= 0 do return 1, -1
	start := max(g.bar_a, 0.6 * g.disk_r)
	amp := g.arm_amp * smooth01(start, start * 1.6, R)
	theta := math.atan2(y, x)
	psi := f64(g.arms) * (theta - g.arm_phase - math.ln(R / g.disk_r) / math.tan(g.arm_pitch))
	s = math.cos(psi)
	if amp <= 0 do return 1, -2 // так близко к центру рукавов нет
	c := max(s, 0)
	return (1 - amp) + amp * (16.0 / 3.0) * c * c * c * c, s
}

// Плотность звёзд галактики в точке rel (св. годы от центра), звёзд на св. год³.
// arm_power — насколько звёзды собраны в рукава (молодым горячим — сильнее).
// z_scale < 1 — молодое население: живёт только в диске (и сгустках), слоем
// тоньше обычного; доля звёзд задана в плоскости диска, поэтому всего их меньше.
galaxy_density :: proc "contextless" (g: ^Galaxy, rel: [3]f64, arm_power: f64 = 1, z_scale: f64 = 1) -> f64 {
	r2 := dot3d(rel, rel)
	if r2 > g.extent * g.extent do return 0
	x, y, z := dot3d(rel, g.e1), dot3d(rel, g.e2), dot3d(rel, g.n)
	rho := 0.0
	if g.disk_rho0 > 0 {
		R := math.sqrt(x * x + y * y)
		d := g.disk_rho0 * math.exp(-R / g.disk_r - abs(z) / (g.disk_h * z_scale))
		if g.arms > 0 && arm_power > 0 {
			f, _ := galaxy_arm(g, x, y, R)
			d *= arm_power == 1 ? f : math.pow(f, arm_power)
		}
		rho += d
	}
	young := z_scale < 1
	if g.sph_rho0 > 0 && !young {
		zq := z / g.sph_q
		rho += g.sph_rho0 * plummer_shape((x * x + y * y + zq * zq) / (g.sph_a * g.sph_a))
	}
	if g.bar_rho0 > 0 && !young {
		bx, by, bz := x / g.bar_a, y / g.bar_b, z / g.disk_h
		rho += g.bar_rho0 * plummer_shape(bx * bx + by * by + bz * bz)
	}
	if g.halo_rho0 > 0 && !young do rho += g.halo_rho0 * plummer_shape(r2 / (g.halo_a * g.halo_a))
	for i in 0 ..< g.clump_n {
		c := &g.clumps[i]
		d := [3]f64{x, y, z} - c.pos
		rho += c.rho0 * plummer_shape(dot3d(d, d) / (c.a * c.a))
	}
	return rho
}

// Свет галактики для свечения неба: старые звёзды (балдж, гало, перемычка,
// основа диска) и молодые голубоватые (часть диска и сгустков), звёзд на св. год³.
galaxy_light :: proc "contextless" (g: ^Galaxy, rel: [3]f64) -> (old, young: f64) {
	total := galaxy_density(g, rel)
	if total <= 0 do return
	part := 0.0
	if g.disk_rho0 > 0 || g.clump_n > 0 do part = galaxy_density(g, rel, 1, 0.999) * 0.3 * min(g.young, 1.5)
	young = min(part, total)
	return total - young, young
}

DUST_KAPPA :: 0.035 // поглощение пылью на звезду диска (у нас — ~0,55 звёздной величины на 1000 св. лет)

// Пыль: насколько слабеет свет (звёздных величин в полосе V на световой год).
// Слой пыли тоньше звёздного диска, шире его и гуще в рукавах.
galaxy_dust :: proc "contextless" (g: ^Galaxy, rel: [3]f64) -> f64 {
	if g.dust <= 0 do return 0
	if dot3d(rel, rel) > g.extent * g.extent do return 0
	x, y, z := dot3d(rel, g.e1), dot3d(rel, g.e2), dot3d(rel, g.n)
	d := 0.0
	if g.disk_rho0 > 0 {
		R := math.sqrt(x * x + y * y)
		d = g.disk_rho0 * math.exp(-R / (1.2 * g.disk_r) - abs(z) / (0.35 * g.disk_h))
		if g.arms > 0 {
			f, _ := galaxy_arm(g, x, y, R)
			d *= f * math.sqrt(f)
		}
	}
	for i in 0 ..< g.clump_n {
		c := &g.clumps[i]
		dd := [3]f64{x, y, z} - c.pos
		d += c.rho0 * plummer_shape(dot3d(dd, dd) / (c.a * c.a))
	}
	return DUST_KAPPA * g.dust * d
}


pick_weighted :: proc(r: ^eng.Rng, weights: []f64) -> int {
	total := 0.0
	for w in weights do total += w
	x := eng.rng_f64(r) * total
	for w, i in weights {
		x -= w
		if x < 0 do return i
	}
	return len(weights) - 1
}

// Строит галактику с n звёздами. dense — в скоплении (там больше эллиптических).
galaxy_make :: proc(r: ^eng.Rng, seed: u64, center: U_Pos, n: f64, dense, satellite: bool) -> (g: Galaxy) {
	g.seed, g.center, g.stars, g.satellite = seed, center, n, satellite
	K :: Galaxy_Kind
	switch {
	case n < 1e9:
		g.kind = eng.rng_f64(r) < (dense || satellite ? 0.7 : 0.45) ? .Dwarf_Elliptical : .Dwarf_Irregular
	case n > 1.5e12:
		g.kind = .Elliptical
	case n < 1e10:
		kinds := [5]K{.Irregular, .Spiral, .Barred_Spiral, .Lenticular, .Elliptical}
		w := dense ? [5]f64{0.15, 0.15, 0.15, 0.3, 0.25} : [5]f64{0.3, 0.3, 0.22, 0.1, 0.08}
		g.kind = kinds[pick_weighted(r, w[:])]
	case:
		kinds := [5]K{.Spiral, .Barred_Spiral, .Lenticular, .Elliptical, .Irregular}
		w := dense ? [5]f64{0.1, 0.12, 0.33, 0.43, 0.02} : [5]f64{0.22, 0.4, 0.18, 0.15, 0.05}
		g.kind = kinds[pick_weighted(r, w[:])]
	}

	g.n = random_unit(r)
	helper := abs(g.n.y) < 0.9 ? [3]f64{0, 1, 0} : [3]f64{1, 0, 0}
	e1 := [3]f64{g.n.y * helper.z - g.n.z * helper.y, g.n.z * helper.x - g.n.x * helper.z, g.n.x * helper.y - g.n.y * helper.x}
	g.e1 = e1 / len3(e1)
	g.e2 = {g.n.y * g.e1.z - g.n.z * g.e1.y, g.n.z * g.e1.x - g.n.x * g.e1.z, g.n.x * g.e1.y - g.n.y * g.e1.x}

	sph_stars := 0.0 // звёзд в сфероиде — по ним масса центральной чёрной дыры
	switch g.kind {
	case .Spiral, .Barred_Spiral, .Lenticular:
		g.disk_r = 8500 * math.pow(n / 1e11, 0.35) * lognorm(r, 0.08)
		g.disk_h = g.disk_r * eng.rng_range(r, 0.08, 0.14)
		bulge := g.kind == .Lenticular ? eng.rng_range(r, 0.35, 0.6) : eng.rng_range(r, 0.08, 0.25)
		bar := g.kind == .Barred_Spiral ? eng.rng_range(r, 0.06, 0.12) : 0
		halo := 0.01
		disk := 1 - bulge - bar - halo
		g.disk_rho0 = n * disk / (4 * math.PI * g.disk_r * g.disk_r * g.disk_h)
		g.sph_a = g.disk_r * eng.rng_range(r, 0.15, 0.3)
		g.sph_q = eng.rng_range(r, 0.6, 0.9)
		g.sph_rho0 = plummer_rho0(n * bulge, g.sph_a, g.sph_a, g.sph_a * g.sph_q)
		if bar > 0 {
			g.bar_a = g.disk_r * eng.rng_range(r, 1.0, 1.8)
			g.bar_b = g.bar_a * eng.rng_range(r, 0.25, 0.4)
			g.bar_rho0 = plummer_rho0(n * bar, g.bar_a, g.bar_b, g.disk_h)
		}
		g.halo_a = g.disk_r * 4
		g.halo_rho0 = plummer_rho0(n * halo, g.halo_a, g.halo_a, g.halo_a)
		if g.kind != .Lenticular {
			arm_counts := [3]int{2, 3, 4}
			arm_weights := [3]f64{0.6, 0.15, 0.25}
			g.arms = arm_counts[pick_weighted(r, arm_weights[:])]
			g.arm_pitch = math.to_radians(eng.rng_range(r, 10, 25))
			g.arm_phase = eng.rng_range(r, 0, 2 * math.PI)
			g.arm_amp = eng.rng_range(r, 0.3, 0.5)
		}
		g.extent = 10 * g.disk_r
		g.young = g.kind == .Lenticular ? 0.08 : 1
		sph_stars = n * (bulge + bar)
	case .Elliptical, .Dwarf_Elliptical:
		a := g.kind == .Elliptical ? 12000 * math.pow(n / 1e11, 0.55) : 1500 * math.pow(n / 1e8, 0.4)
		g.sph_a = a * lognorm(r, 0.1)
		g.sph_q = eng.rng_range(r, 0.45, 1.0)
		g.sph_rho0 = plummer_rho0(n, g.sph_a, g.sph_a, g.sph_a * g.sph_q)
		g.extent = 10 * g.sph_a
		g.young = g.kind == .Elliptical ? 0.02 : 0.03
		sph_stars = n
	case .Irregular, .Dwarf_Irregular:
		size := g.kind == .Irregular ? 4000 * math.pow(n / 1e9, 0.4) : 1200 * math.pow(n / 1e8, 0.4)
		size *= lognorm(r, 0.1)
		g.clump_n = eng.rng_int(r, 3, MAX_CLUMPS)
		w: [MAX_CLUMPS]f64
		total := 0.0
		for i in 0 ..< g.clump_n {
			w[i] = eng.rng_range(r, 0.3, 1.0)
			total += w[i]
		}
		for i in 0 ..< g.clump_n {
			c := &g.clumps[i]
			c.pos = {gauss(r) * 0.6 * size, gauss(r) * 0.6 * size, gauss(r) * 0.25 * size}
			c.a = size * eng.rng_range(r, 0.2, 0.45)
			c.rho0 = plummer_rho0(n * w[i] / total, c.a, c.a, c.a)
		}
		g.extent = 4 * size
		g.young = g.kind == .Irregular ? 1.6 : 1.3
		sph_stars = n * 0.1
	}
	g.bh_mass = max(1e4, sph_stars * 0.6 * 1e-3 * lognorm(r, 0.4))
	DUST := [Galaxy_Kind]f64 {
		.Spiral = 1, .Barred_Spiral = 1, .Lenticular = 0.15, .Elliptical = 0.02,
		.Irregular = 0.6, .Dwarf_Elliptical = 0.01, .Dwarf_Irregular = 0.3,
	}
	g.dust = DUST[g.kind]
	return
}

// Число звёзд случайной галактики по функции Шехтера (в пределах lo..hi).
@(private = "file")
schechter_sample :: proc(u: ^Universe, r: ^eng.Rng, lo, hi: f64) -> f64 {
	cdf_at :: proc(u: ^Universe, logn: f64) -> f64 {
		t := clamp((logn - SCH_LO) / (SCH_HI - SCH_LO), 0, 1) * SCH_STEPS
		i := min(int(t), SCH_STEPS - 1)
		return math.lerp(u.sch_cdf[i], u.sch_cdf[i + 1], t - f64(i))
	}
	c0 := cdf_at(u, math.log10(lo))
	c1 := cdf_at(u, math.log10(hi))
	x := math.lerp(c0, c1, eng.rng_f64(r))
	// двоичный поиск по таблице
	a, b := 0, SCH_STEPS
	for b - a > 1 {
		m := (a + b) / 2
		if u.sch_cdf[m] <= x {
			a = m
		} else {
			b = m
		}
	}
	span := u.sch_cdf[b] - u.sch_cdf[a]
	t := span > 0 ? (x - u.sch_cdf[a]) / span : 0
	logn := SCH_LO + (SCH_HI - SCH_LO) * (f64(a) + t) / SCH_STEPS
	return clamp(math.pow(10, logn), lo, hi)
}

// Галактики клетки key (1 Мпк). Число — по плотности паутины; часть галактик
// собрана в группу вокруг общего центра; у больших — карлики-спутники.
// Галактики могут выходить за свою клетку (примерно на 0,7 клетки).
galaxy_cell_generate :: proc(u: ^Universe, key: [3]Big, out: ^[dynamic]Galaxy) {
	h := hash3big(u.seed ~ TAG_GALCELL, key)
	r := eng.rng_make(h)
	web := web_density(u, key)
	dense := web > 4
	count := poisson(&r, GAL_PER_MPC3 * web)
	if count == 0 do return
	G := f64(GAL_CELL)
	group := [3]f64{eng.rng_f64(&r) * G, eng.rng_f64(&r) * G, eng.rng_f64(&r) * G}
	origin := [3]Big{big_mul_i(key[0], GAL_CELL), big_mul_i(key[1], GAL_CELL), big_mul_i(key[2], GAL_CELL)}
	for i in 0 ..< count {
		gs := mix64(h ~ u64(i + 1) * 0xD1B54A32D192ED03)
		gr := eng.rng_make(gs)
		p: [3]f64
		if eng.rng_f64(&gr) < 0.6 {
			for a in 0 ..< 3 do p[a] = clamp(group[a] + gauss(&gr) * 0.25 * G, -0.45 * G, 1.45 * G)
		} else {
			for a in 0 ..< 3 do p[a] = eng.rng_f64(&gr) * G
		}
		n := schechter_sample(u, &gr, GAL_MIN_STARS, GAL_MAX_STARS)
		center := upos_at(origin, p)
		append(out, galaxy_make(&gr, gs, center, n, dense, false))
		if n > 2e10 {
			sats := min(poisson(&gr, 1.5 * math.sqrt(n / 1e11)), 12)
			for j in 0 ..< sats {
				ss := mix64(gs ~ u64(j + 1) * 0x9E6C63D0676A9A99)
				sr := eng.rng_make(ss)
				sn := schechter_sample(u, &sr, GAL_MIN_STARS, min(n / 30, 3e9))
				dist := 60_000 * math.pow(800_000.0 / 60_000.0, eng.rng_f64(&sr)) // 60–800 тыс. св. лет
				sp := upos_add_ly(center, random_unit(&sr) * dist)
				append(out, galaxy_make(&sr, ss, sp, sn, dense, true))
			}
		}
	}
}

// Галактики клетки — из кеша или сгенерированные.
universe_galaxy_cell :: proc(u: ^Universe, key: [3]Big) -> []Galaxy {
	h := hash3big(0xCAC4E, key)
	if c, ok := &u.cells[h]; ok {
		if big_eq(c.key[0], key[0]) && big_eq(c.key[1], key[1]) && big_eq(c.key[2], key[2]) do return c.galaxies[:]
	}
	list := make([dynamic]Galaxy)
	galaxy_cell_generate(u, key, &list)
	for &g in list do g.center = upos_clone(g.center)
	if old, ok := u.cells[h]; ok {
		// совпадение хешей у разных клеток — старую выбрасываем
		for &g in old.galaxies do for k in 0 ..< 3 do big_delete(g.center.cell[k])
		for k in 0 ..< 3 do big_delete(old.key[k])
		delete(old.galaxies)
	}
	u.cells[h] = {{big_clone(key[0]), big_clone(key[1]), big_clone(key[2])}, list}
	return list[:]
}

// Клетка сетки галактик, в которой лежит точка.
galaxy_cell_of :: proc(p: U_Pos) -> (key: [3]Big) {
	for k in 0 ..< 3 do key[k], _ = big_floor_div(p.cell[k], GAL_CELL)
	return
}

// Галактики, которые могут задевать шар (p, radius): звёзды галактики не дальше extent от её центра.
galaxies_around :: proc(u: ^Universe, p: U_Pos, radius_ly: f64, out: ^[dynamic]Galaxy) {
	R := 2 + i64(math.ceil(radius_ly / f64(GAL_CELL)))
	base := galaxy_cell_of(p)
	for dz in -R ..= R do for dy in -R ..= R do for dx in -R ..= R {
		key := [3]Big{big_add_i(base[0], dx), big_add_i(base[1], dy), big_add_i(base[2], dz)}
		for g in universe_galaxy_cell(u, key) {
			if len3(upos_delta_ly(g.center, p)) <= radius_ly + g.extent do append(out, g)
		}
	}
}

// Случайная точка галактики (св. годы от центра) — по распределению её звёзд.
galaxy_sample :: proc(g: ^Galaxy, r: ^eng.Rng) -> [3]f64 {
	frame :: proc(g: ^Galaxy, x, y, z: f64) -> [3]f64 {return g.e1 * x + g.e2 * y + g.n * z}
	plummer :: proc(r: ^eng.Rng, extent: f64) -> f64 {
		for _ in 0 ..< 32 {
			u := max(eng.rng_f64(r), 1e-12)
			rr := 1 / math.sqrt(math.pow(u, -2.0 / 3) - 1)
			if rr < extent do return rr
		}
		return 0
	}
	disk_n := g.disk_rho0 * 4 * math.PI * g.disk_r * g.disk_r * g.disk_h
	sph_n := g.sph_rho0 * 4 * math.PI * g.sph_a * g.sph_a * g.sph_a * g.sph_q / 3
	bar_n := g.bar_rho0 * 4 * math.PI * g.bar_a * g.bar_b * g.disk_h / 3
	halo_n := g.halo_rho0 * 4 * math.PI * g.halo_a * g.halo_a * g.halo_a / 3
	w: [4 + MAX_CLUMPS]f64
	w[0], w[1], w[2], w[3] = disk_n, sph_n, bar_n, halo_n
	for i in 0 ..< g.clump_n do w[4 + i] = g.clumps[i].rho0 * 4 * math.PI * g.clumps[i].a * g.clumps[i].a * g.clumps[i].a / 3
	switch k := pick_weighted(r, w[:]); k {
	case 0:
		max_f := 1 + g.arm_amp * (16.0 / 3.0 - 1)
		x, y, z: f64
		for _ in 0 ..< 32 {
			R := -g.disk_r * math.ln(max(eng.rng_f64(r) * eng.rng_f64(r), 1e-300))
			a := eng.rng_f64(r) * 2 * math.PI
			x, y = R * math.cos(a), R * math.sin(a)
			z = -g.disk_h * math.ln(max(eng.rng_f64(r), 1e-300)) * (eng.rng_f64(r) < 0.5 ? -1 : 1)
			f, _ := galaxy_arm(g, x, y, R)
			if eng.rng_f64(r) * max_f <= f do break
		}
		return frame(g, x, y, z)
	case 1:
		d := random_unit(r) * plummer(r, g.extent / g.sph_a)
		return frame(g, d.x * g.sph_a, d.y * g.sph_a, d.z * g.sph_a * g.sph_q)
	case 2:
		d := random_unit(r) * plummer(r, 10)
		return frame(g, d.x * g.bar_a, d.y * g.bar_b, d.z * g.disk_h)
	case 3:
		d := random_unit(r) * plummer(r, g.extent / g.halo_a)
		return frame(g, d.x * g.halo_a, d.y * g.halo_a, d.z * g.halo_a)
	case:
		c := &g.clumps[k - 4]
		d := random_unit(r) * plummer(r, 3)
		return frame(g, c.pos.x + d.x * c.a, c.pos.y + d.y * c.a, c.pos.z + d.z * c.a)
	}
}

// ---------------------------------------------------------------- наш дом

Home :: struct {
	galaxy:  Galaxy,
	star:    Star, // наша звезда
	rel:     [3]f64, // её положение относительно центра галактики, св. лет
	planet:  int, // номер планеты для высадки в её системе
	lat, lon: f64, // место высадки: умеренный лес или степь (climate.odin)
	checked: int, // сколько звёзд проверено, пока она нашлась
}

// Сначала — вселенная, потом поиск: случайное место в случайной галактике
// (галактика — с вероятностью, пропорциональной числу её звёзд; место — по
// распределению её звёзд, но не в пустоте и не в тесном ядре), и звёзды
// вокруг — от ближних к дальним, пока у какой-нибудь не найдётся планета,
// где можно высадиться (star_system.odin: start_check). Звезду никто не
// подбирает: её система — по тем же правилам, что у любой другой.
universe_find_home :: proc(u: ^Universe) -> (home: Home) {
	r := eng.rng_make(u.seed ~ TAG_HOME)
	list := make([dynamic]Galaxy, context.temp_allocator)
	for _ in 0 ..< 1_000_000 {
		clear(&list)
		galaxy_cell_generate(u, random_key(&r, 1 << 31), &list)
		chosen := -1
		for cg, i in list {
			if eng.rng_f64(&r) < cg.stars / 3e11 {
				chosen = i
				break
			}
		}
		if chosen < 0 do continue
		g := list[chosen]
		g.center = upos_clone(g.center)
		for _ in 0 ..< 64 {
			rel := galaxy_sample(&g, &r)
			rho := galaxy_density(&g, rel)
			if rho < 1e-5 || rho > 0.03 do continue // не в пустоте и не в тесном опасном ядре
			if star, planet, lat, lon, ok := search_near(u, &g, rel, rho, &home.checked); ok {
				home.lat, home.lon = lat, lon
				home.galaxy = g
				home.star = star
				home.star.pos = upos_clone(star.pos)
				home.rel = upos_delta_ly(star.pos, g.center)
				home.planet = planet
				return
			}
		}
	}
	panic("не нашлось планеты для высадки")
}

// Звёзды вокруг точки (около двухсот ближайших), от ближних к дальним: у
// какой первой найдётся планета для высадки.
@(private = "file")
search_near :: proc(u: ^Universe, g: ^Galaxy, rel: [3]f64, rho: f64, checked: ^int) -> (best: Star, planet: int, lat, lon: f64, ok: bool) {
	point := upos_add_ly(g.center, rel)
	radius := clamp(math.cbrt(200 / (rho * 4.19)), 5, 300)
	found := make([dynamic]Star, context.temp_allocator)
	stars_near(u, point, radius, {.M, .K, .G, .F, .A, .B, .O}, &found)
	Item :: struct {
		i: int,
		d: f64,
	}
	order := make([]Item, len(found), context.temp_allocator)
	for s, i in found do order[i] = {i, len3(upos_delta_ly(s.pos, point))}
	slice.sort_by(order, proc(a, b: Item) -> bool {return a.d < b.d})
	for it in order {
		checked^ += 1
		sys := star_system_generate(0, found[it.i], false)
		idx := system_find_start(&sys)
		// планета подходит — ищем на ней умеренный лес или степь (по честному климату)
		if idx >= 0 {
			if la, lo, site := start_site_search(&sys, idx, u.world_seed); site {
				star_system_destroy(&sys)
				return found[it.i], idx, la, lo, true
			}
		}
		star_system_destroy(&sys)
	}
	return
}
