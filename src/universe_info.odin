package main

// Сведения о вселенной вокруг нас (страница F3 и отчёт -universe) и
// самопроверки генерации: длинные числа, повторяемость, независимость от
// того, откуда спрашивают, и работа в сколь угодно далёком космосе.

import "core:fmt"
import "core:math"
import "core:slice"
import "core:time"
import "core:unicode/utf8"
import eng "engine"

@(private = "file")
TAG_GALNAME :: 0x6A1A_4A3E

NEAR_COUNT :: 6

Near_Star :: struct {
	name:    string,
	class:   Star_Class,
	dist:    f64, // св. лет
	planets: int,
}

Near_Galaxy :: struct {
	name:  string,
	kind:  Galaxy_Kind,
	stars: f64,
	dist:  f64, // св. лет
	bound: bool, // связана с нами гравитацией (расширение её не уносит)
}

Universe_Info :: struct {
	u:                   ^Universe,
	home:                Home,
	galaxy_name:         string,
	host_name:           string, // если наша галактика — спутник: чей
	from_center:         f64, // св. лет
	above_disk:          f64, // над плоскостью диска (минус — под), св. лет
	arm:                 int, // -1 — рукавов нет, 0 — между рукавами, 1 — в рукаве, 2 — внутри, где рукавов нет
	density:             f64, // звёзд на кубический св. год вокруг нас
	stars:               [dynamic]Near_Star,
	galaxies:            [dynamic]Near_Galaxy,
	galaxies_10mly:      int,
	observable_galaxies: f64,
}

galaxy_name :: proc(seed: u64, allocator := context.allocator) -> string {
	r := eng.rng_make(seed ~ TAG_GALNAME)
	return make_name(&r, 2, 4, allocator)
}

// Связаны ли две галактики гравитацией (грубо: ближе "поверхности нулевой скорости").
@(private = "file")
galaxies_bound :: proc(a_stars, b_stars, dist_ly: f64) -> bool {
	return dist_ly < 0.6 * MPC_LY * math.cbrt((a_stars + b_stars) / 1e11)
}

// Ближайшие звёзды (без нашей), по возрастанию расстояния.
@(private = "file")
nearest_stars :: proc(u: ^Universe, home: ^Home, density: f64, want: int) -> []Star {
	list := make([dynamic]Star, context.temp_allocator)
	radius := clamp(math.cbrt(f64(want + 2) / (max(density, 1e-9) * 4.19)) * 1.3, 8, 300)
	for _ in 0 ..< 4 {
		clear(&list)
		stars_near(u, home.star.pos, radius, ALL_STARS, &list)
		if len(list) > want do break
		radius *= 1.6
	}
	Item :: struct {
		s: Star,
		d: f64,
	}
	items := make([dynamic]Item, context.temp_allocator)
	for s in list {
		if s.seed == home.star.seed do continue
		append(&items, Item{s, len3(upos_delta_ly(s.pos, home.star.pos))})
	}
	slice.sort_by(items[:], proc(a, b: Item) -> bool {return a.d < b.d})
	out := make([]Star, min(len(items), want), context.temp_allocator)
	for i in 0 ..< len(out) do out[i] = items[i].s
	return out
}

universe_info_build :: proc(u: ^Universe, home: Home) -> (info: Universe_Info) {
	info.u = u
	info.home = home
	g := home.galaxy
	info.galaxy_name = galaxy_name(g.seed)
	rel := home.rel
	info.from_center = len3(rel)
	info.above_disk = dot3d(rel, g.n)
	info.arm = -1
	if g.arms > 0 {
		x, y := dot3d(rel, g.e1), dot3d(rel, g.e2)
		_, s := galaxy_arm(&g, x, y, math.sqrt(x * x + y * y))
		info.arm = s < -1.5 ? 2 : s > 0.55 ? 1 : 0
	}
	info.density = galaxy_density(&g, rel)

	for s in nearest_stars(u, &info.home, info.density, NEAR_COUNT) {
		sys := star_system_generate(0, s, false)
		append(&info.stars, Near_Star{star_name(s.seed), s.class, len3(upos_delta_ly(s.pos, home.star.pos)), sys.planet_count})
		star_system_destroy(&sys)
	}

	// соседние галактики в 13 млн св. лет
	gals := make([dynamic]Galaxy, context.temp_allocator)
	galaxies_around(u, home.star.pos, 13e6, &gals)
	Item :: struct {
		g: Galaxy,
		d: f64,
	}
	items := make([dynamic]Item, context.temp_allocator)
	for o in gals {
		if o.seed == g.seed do continue
		d := len3(upos_delta_ly(o.center, home.star.pos))
		if d > 13e6 do continue
		append(&items, Item{o, d})
		if d <= 10e6 do info.galaxies_10mly += 1
	}
	slice.sort_by(items[:], proc(a, b: Item) -> bool {return a.d < b.d})
	for it, i in items {
		if i >= NEAR_COUNT do break
		append(&info.galaxies, Near_Galaxy{galaxy_name(it.g.seed), it.g.kind, it.g.stars, it.d, galaxies_bound(g.stars, it.g.stars, it.d)})
	}
	if g.satellite {
		// хозяин — ближайшая крупная галактика
		for it in items {
			if it.g.stars > g.stars * 10 && it.d < 1e6 {
				info.host_name = galaxy_name(it.g.seed)
				break
			}
		}
	}
	R := u.observable_ly / MPC_LY
	info.observable_galaxies = u.gal_density * 4 / 3 * math.PI * R * R * R
	return
}

universe_info_destroy :: proc(info: ^Universe_Info) {
	delete(info.galaxy_name)
	delete(info.host_name)
	for s in info.stars do delete(s.name)
	for g in info.galaxies do delete(g.name)
	delete(info.stars)
	delete(info.galaxies)
}

// ---------------------------------------------------------------- текст

// Расстояние в световых годах: св. лет, тыс., млн, млрд.
ly_text :: proc(d: f64) -> string {
	switch {
	case d < 1000:
		return fmt.tprintf("%.2f св. лет", d)
	case d < 1e6:
		return fmt.tprintf("%.1f тыс. св. лет", d / 1e3)
	case d < 1e9:
		return fmt.tprintf("%.2f млн св. лет", d / 1e6)
	}
	return fmt.tprintf("%.2f млрд св. лет", d / 1e9)
}

// Большое количество: 35 млн, 210 млрд, 1.2 трлн.
count_text :: proc(n: f64) -> string {
	switch {
	case n < 1e3:
		return fmt.tprintf("%.0f", n)
	case n < 1e6:
		return fmt.tprintf("%.0f тыс.", n / 1e3)
	case n < 1e9:
		return fmt.tprintf("%.0f млн", n / 1e6)
	case n < 1e12:
		return fmt.tprintf("%.0f млрд", n / 1e9)
	}
	return fmt.tprintf("%.1f трлн", n / 1e12)
}

// Где мы в галактике: от центра, над диском (если он есть), в рукаве или нет.
where_text :: proc(info: ^Universe_Info) -> string {
	disk := ""
	if info.home.galaxy.disk_rho0 > 0 {
		disk = fmt.tprintf(", %.0f св. лет %s диска", abs(info.above_disk), info.above_disk >= 0 ? "над плоскостью" : "под плоскостью")
	}
	ARM_TEXT := [4]string{"", ", между рукавами", ", в рукаве", ", ближе к центру, чем начинаются рукава"}
	arm := ARM_TEXT[info.arm + 1]
	return fmt.tprintf("%s от центра%s%s", ly_text(info.from_center), disk, arm)
}

// Дополняет строку пробелами до n символов (а не байт — для кириллицы).
pad :: proc(s: string, n: int) -> string {
	k := utf8.rune_count_in_string(s)
	if k >= n do return s
	b := make([]u8, len(s) + n - k, context.temp_allocator)
	copy(b, s)
	for i in len(s) ..< len(b) do b[i] = ' '
	return string(b)
}

// Степень десяти надстрочными цифрами: 2.1·10¹¹.
sci_text :: proc(x: f64) -> string {
	if x == 0 do return "0"
	e := int(math.floor(math.log10(abs(x))))
	m := x / math.pow(10, f64(e))
	return fmt.tprintf("%.1f·10%s", m, superscript(e))
}

superscript :: proc(n: int) -> string {
	SUP := [10]rune{'⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹'}
	digits := fmt.tprintf("%d", n)
	out := make([dynamic]u8, context.temp_allocator)
	for c in digits {
		r := c == '-' ? '⁻' : SUP[int(c - '0')]
		buf, w := utf8.encode_rune(r)
		append(&out, ..buf[:w])
	}
	return string(out[:])
}

// Длинное целое с пробелами между тысячами: 12 345 678.
big_grouped :: proc(a: Big) -> string {
	s := big_string(a)
	neg := len(s) > 0 && s[0] == '-'
	digits := neg ? s[1:] : s
	out := make([dynamic]u8, context.temp_allocator)
	if neg do append(&out, '-')
	for i in 0 ..< len(digits) {
		if i > 0 && (len(digits) - i) % 3 == 0 do append(&out, ' ')
		append(&out, digits[i])
	}
	return string(out[:])
}

// ---------------------------------------------------------------- отчёт и проверки

@(private = "file")
star_same :: proc(a, b: Star) -> bool {
	if a.seed != b.seed || a.class != b.class || a.mass != b.mass do return false
	for k in 0 ..< 3 do if !big_eq(a.pos.cell[k], b.pos.cell[k]) || a.pos.off[k] != b.pos.off[k] do return false
	return true
}

@(private = "file")
big_to_i128 :: proc(a: Big) -> (v: i128, ok: bool) {
	if a.mag == nil do return i128(a.small), true
	if len(a.mag) > 2 do return 0, false
	m := u128(a.mag[0])
	if len(a.mag) == 2 do m |= u128(a.mag[1]) << 64
	if m > u128(max(i128)) do return 0, false
	return a.neg ? -i128(m) : i128(m), true
}

@(private = "file")
pow10 :: proc(e: int) -> Big {
	x := big(1)
	for _ in 0 ..< e do x = big_mul_i(x, 10)
	return x
}

// Проверка длинных чисел: сверка с 128-битной арифметикой и тождества на огромных числах.
@(private = "file")
test_bignum :: proc() -> (checks, errors: int) {
	r := eng.rng_make(0xB16)
	rand_big :: proc(r: ^eng.Rng) -> Big {
		// числа вокруг границы i64 и за ней
		a := big(i64(eng.rng_u64(r)))
		switch eng.rng_int(r, 0, 2) {
		case 0:
			return a
		case 1:
			return big_add(a, big(i64(eng.rng_u64(r))))
		}
		return big_mul_i(a, i64(eng.rng_u64(r) >> 40) + 1)
	}
	check :: proc(checks, errors: ^int, ok: bool) {
		checks^ += 1
		if !ok do errors^ += 1
	}
	for _ in 0 ..< 20000 {
		a, b := rand_big(&r), rand_big(&r)
		ia, oka := big_to_i128(a)
		ib, okb := big_to_i128(b)
		if !oka || !okb do continue
		if s, ok := big_to_i128(big_add(a, b)); ok do check(&checks, &errors, s == ia + ib)
		if s, ok := big_to_i128(big_sub(a, b)); ok do check(&checks, &errors, s == ia - ib)
		m := i64(eng.rng_u64(&r) >> 33) - (1 << 30)
		if p, ok := big_to_i128(big_mul_i(a, m)); ok && abs(ia) < 1 << 90 do check(&checks, &errors, p == ia * i128(m))
		d := i64(eng.rng_u64(&r) >> 24) + 1
		q, rem := big_floor_div(a, d)
		if iq, ok := big_to_i128(q); ok do check(&checks, &errors, iq * i128(d) + i128(rem) == ia && rem >= 0 && rem < d)
		check(&checks, &errors, big_cmp(a, b) == (ia < ib ? -1 : ia > ib ? 1 : 0))
		// однозначность: всё, что помещается в i64, хранится в small
		check(&checks, &errors, (ia >= i128(min(i64)) && ia <= i128(max(i64))) == big_is_small(a))
	}
	for e in ([3]int{30, 100, 1000}) {
		x := pow10(e)
		y := big_add(pow10(e / 2), big(12345))
		check(&checks, &errors, big_eq(big_sub(big_add(x, y), y), x))
		check(&checks, &errors, big_is_small(big_sub(big_add(x, big(1)), x)))
		q, rem := big_floor_div(big_add_i(big_mul_i(x, 1000), 7), 1000)
		check(&checks, &errors, big_eq(q, x) && rem == 7)
		q2, rem2 := big_floor_div(big_neg(big_add_i(big_mul_i(x, 1000), 7)), 1000)
		check(&checks, &errors, big_eq(q2, big_neg(big_add_i(x, 1))) && rem2 == 993)
		check(&checks, &errors, big_hash(1, x) != big_hash(1, big_add_i(x, 1)))
		check(&checks, &errors, big_cmp(big_neg(x), x) < 0 && big_cmp(x, big(max(i64))) > 0)
		s := big_string(x)
		check(&checks, &errors, len(s) == e + 1 && s[0] == '1')
		check(&checks, &errors, abs(big_log10(x) - f64(e)) < 1e-9)
	}
	return
}

// Звёзды в шаре — отсортированные по зерну (для сравнения списков).
@(private = "file")
stars_sorted :: proc(u: ^Universe, center: U_Pos, radius: f64) -> []Star {
	list := make([dynamic]Star, context.temp_allocator)
	stars_near(u, center, radius, ALL_STARS, &list)
	slice.sort_by(list[:], proc(a, b: Star) -> bool {return a.seed < b.seed})
	return list[:]
}

@(private = "file")
lists_same :: proc(a, b: []Star) -> bool {
	if len(a) != len(b) do return false
	for i in 0 ..< len(a) do if !star_same(a[i], b[i]) do return false
	return true
}

// Дальний космос: галактика и звёзды возле точки 10^e св. лет — дважды, в двух
// независимых экземплярах вселенной, результат должен совпасть.
@(private = "file")
test_far :: proc(u, u2: ^Universe, e: int) -> (ok: bool, line: string) {
	x := pow10(e)
	p := U_Pos{cell = {x, big_neg(x), big_add_i(x, 777)}}
	probe :: proc(u: ^Universe, p: U_Pos) -> (g: Galaxy, found: bool, stars: []Star) {
		base := galaxy_cell_of(p)
		best := 0.0
		for R in i64(0) ..< 8 {
			for dz in -R ..= R do for dy in -R ..= R do for dx in -R ..= R {
				if max(abs(dx), abs(dy), abs(dz)) != R do continue
				key := [3]Big{big_add_i(base[0], dx), big_add_i(base[1], dy), big_add_i(base[2], dz)}
				for cg in universe_galaxy_cell(u, key) {
					if cg.stars > best do g, best, found = cg, cg.stars, true
				}
			}
			if found && best > 1e9 do break
		}
		if !found do return
		r := eng.rng_make(g.seed)
		rel := galaxy_sample(&g, &r)
		rho := galaxy_density(&g, rel)
		radius := clamp(math.cbrt(30 / (max(rho, 1e-9) * 4.19)), 10, 200)
		stars = stars_sorted(u, upos_add_ly(g.center, rel), radius)
		return
	}
	g1, f1, s1 := probe(u, p)
	g2, f2, s2 := probe(u2, p)
	if !f1 || !f2 do return false, fmt.tprintf("10%s св. лет: галактик не нашлось", superscript(e))
	same := g1.seed == g2.seed && lists_same(s1, s2)
	for k in 0 ..< 3 do same = same && big_eq(g1.center.cell[k], g2.center.cell[k])
	return same && len(s1) > 0, fmt.tprintf("10%s св. лет: галактика %s (%s), звёзд %s; рядом с точкой в ней %d звёзд — %s",
		superscript(e), galaxy_name(g1.seed, context.temp_allocator), GALAXY_KIND_NAMES[g1.kind], count_text(g1.stars), len(s1),
		same ? "совпадает" : "НЕ СОВПАДАЕТ")
}

// Печатает отчёт о вселенной и проверки. Возвращает число ошибок.
universe_report :: proc(u: ^Universe, info: ^Universe_Info, world_seed: u32, init_ms, home_ms, info_ms: f64) -> (errors: int) {
	home := &info.home
	g := &home.galaxy
	fmt.printfln("=== Вселенная (зерно мира %d) ===", world_seed)
	fmt.printfln("бесконечная; возраст %.2f млрд лет; расширение %.1f км/с на Мпк", u.age_years / 1e9, H0)
	fmt.printfln("горизонт событий %s; видимая часть — радиус %s", ly_text(u.horizon_ly), ly_text(u.observable_ly))
	fmt.printfln("галактик в среднем %.3f на кубический Мпк -> в видимой части ~%s", u.gal_density, sci_text(info.observable_galaxies))
	fmt.println()
	st := &home.star
	fmt.printfln("Наша звезда: %s — %s, масса %.2f, %.0f K, светимость %.3f", star_name(st.seed, context.temp_allocator), STAR_CLASS_NAMES[st.class], st.mass, st.temperature, st.luminosity)
	fmt.printfln("координаты, св. лет: X %s", big_grouped(st.pos.cell[0]))
	fmt.printfln("                     Y %s", big_grouped(st.pos.cell[1]))
	fmt.printfln("                     Z %s", big_grouped(st.pos.cell[2]))
	fmt.printfln("Галактика: %s — %s%s, звёзд %s (%s), диаметр %s", info.galaxy_name, GALAXY_KIND_NAMES[g.kind], g.satellite ? " (спутник)" : "",
		count_text(g.stars), sci_text(g.stars), ly_text(galaxy_diameter(g)))
	if info.host_name != "" do fmt.printfln("спутник галактики %s", info.host_name)
	fmt.printfln("в центре чёрная дыра %s масс Солнца", count_text(g.bh_mass))
	fmt.printfln("мы: %s; плотность звёзд %.5f на св. год³", where_text(info), info.density)
	fmt.println()

	fmt.println("Ближайшие звёзды:")
	for s in nearest_stars(u, home, info.density, 20) {
		sys := star_system_generate(0, s, false)
		fmt.printfln("  %s %s %s масса %.2f, радиус %.5f, планет %d",
			pad(star_name(s.seed, context.temp_allocator), 10), pad(STAR_CLASS_NAMES[s.class], 20),
			pad(ly_text(len3(upos_delta_ly(s.pos, st.pos))), 16), s.mass, s.radius, sys.planet_count)
		star_system_destroy(&sys)
	}
	fmt.printfln("Ближайшие галактики (в 10 млн св. лет — %d):", info.galaxies_10mly)
	for ng in info.galaxies {
		fmt.printfln("  %s %s %s звёзд %s %s", pad(ng.name, 12), pad(GALAXY_KIND_NAMES[ng.kind], 25), pad(ly_text(ng.dist), 17),
			pad(count_text(ng.stars), 9), ng.bound ? "связана с нами гравитацией" : fmt.tprintf("удаляется %.0f км/с", recession_kms(ng.dist)))
	}
	fmt.println()

	fmt.println("Проверки:")
	checks, berr := test_bignum()
	fmt.printfln("  длинные числа: %d проверок, ошибок %d", checks, berr)
	errors += berr

	t0 := time.now()
	u2: Universe
	universe_init(&u2, world_seed)
	defer universe_destroy(&u2)
	home2 := universe_find_home(&u2)
	rep := home2.star.seed == st.seed && star_same(home2.star, st^)
	a := stars_sorted(u, st.pos, 15)
	b := stars_sorted(&u2, st.pos, 15)
	rep = rep && lists_same(a, b)
	fmt.printfln("  повторяемость (вторая вселенная с тем же зерном): %s, звёзд в 15 св. годах: %d", rep ? "совпадает" : "НЕ СОВПАДАЕТ", len(a))
	if !rep do errors += 1

	// звёзды, попавшие в оба шара, должны быть одними и теми же
	other := upos_add_ly(st.pos, {9, -4, 6})
	c := stars_sorted(u, other, 15)
	both, mismatch := 0, 0
	for s in a {
		if len3(upos_delta_ly(s.pos, other)) > 15 do continue
		both += 1
		found := false
		for s2 in c {
			if s2.seed == s.seed {
				found = star_same(s, s2)
				break
			}
		}
		if !found do mismatch += 1
	}
	fmt.printfln("  независимость от точки запроса: общих звёзд %d, расхождений %d", both, mismatch)
	errors += mismatch

	for e in ([3]int{30, 100, 1000}) {
		ok, line := test_far(u, &u2, e)
		fmt.printfln("  %s", line)
		if !ok do errors += 1
	}
	fmt.printfln("  (проверки заняли %.0f мс)", time.duration_milliseconds(time.since(t0)))
	fmt.printfln("время: вселенная %.0f мс, поиск дома %.0f мс, сведения %.0f мс", init_ms, home_ms, info_ms)
	fmt.printfln("ошибок: %d", errors)
	return
}

// Видимый диаметр галактики, св. лет.
galaxy_diameter :: proc(g: ^Galaxy) -> f64 {
	switch g.kind {
	case .Spiral, .Barred_Spiral, .Lenticular:
		return 11 * g.disk_r
	case .Elliptical, .Dwarf_Elliptical:
		return 5 * g.sph_a
	case .Irregular, .Dwarf_Irregular:
		return g.extent * 0.6
	}
	return g.extent
}
