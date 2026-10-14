package main

// Проверка рек и озёр (-hydro): сток по кривой Будыко против настоящих
// бассейнов Земли; сеть стока мира — вода сохраняется (сток с суши = реки в
// океан + испарение бессточных озёр), гладь рек вниз по течению не
// поднимается, длина рек растёт с площадью водосбора как у настоящих (закон
// Хака, L ~ A^0,5…0,6), доля бессточной суши и озёр, крупнейшие реки.

import "core:fmt"
import "core:math"
import "core:time"

@(private = "file")
Basin_Ref :: struct {
	name:  string,
	lat:   f64,
	cont:  f64, // материковость (0 — у моря, 1 — глубь материка)
	p:     f64, // осадков за год, мм
	t:     [12]f64, // средние месячные температуры, °C
	r:     f64, // настоящий сток, мм/год (расход / площадь)
}

// Средние по бассейнам (осадки, температура) и сток у устья.
@(private = "file")
BASINS := [?]Basin_Ref {
	{"Амазонка", -3, 0.6, 2200, {26, 26, 26, 26, 26, 26, 26, 27, 27, 27, 27, 26}, 1080},
	{"Конго", -2, 0.7, 1500, {25, 25, 25, 25, 25, 24, 24, 24, 25, 25, 25, 25}, 350},
	{"Рейн", 50, 0.4, 900, {1, 2, 5, 9, 13, 16, 18, 17, 14, 10, 5, 2}, 390},
	{"Миссисипи", 38, 0.7, 850, {0, 2, 8, 14, 19, 24, 26, 25, 21, 15, 8, 2}, 170},
	{"Обь", 60, 0.85, 500, {-20, -18, -10, 0, 8, 15, 18, 15, 9, 0, -10, -17}, 130},
	{"Муррей", -34, 0.5, 480, {24, 24, 21, 17, 13, 10, 9, 11, 14, 17, 20, 22}, 10},
}

hydro_report :: proc(seed: u32) -> (errors: int) {
	fail :: proc(errors: ^int, what: string) {
		errors^ += 1
		fmt.printfln("  ОШИБКА: %s", what)
	}
	fmt.println("=== Сток по кривой Будыко (Фу, w = 2,6; испарение по Харгривсу) против настоящих бассейнов ===")
	fmt.println("бассейн      осадки  возм. исп.  сток модели  настоящий")
	earth, _ := climate_earth()
	for b in BASINS {
		// свет у верха атмосферы по календарным месяцам (равноденствие — 20 марта)
		ra: [12]f64
		for m in 0 ..< 12 do ra[m] = climate_daily_sun(&earth, b.lat, earth.season_eq + (15 + 30.44 * f64(m) - 79) / 365.25)
		pet := hydro_pet(ra, b.t, b.p, b.cont, 30.44)
		r := hydro_fu_runoff(b.p, pet)
		fmt.printfln("%s %s %s %s %.0f", pad(b.name, 12), pad(fmt.tprintf("%.0f", b.p), 7), pad(fmt.tprintf("%.0f", pet), 11), pad(fmt.tprintf("%.0f", r), 12), b.r)
		// Будыко держит средние бассейны с разбросом ~30%; у сухих — в разы (там сток мал)
		lo, hi := b.r * 0.65, b.r * 1.45
		if b.r < 50 do lo, hi = 0, 60
		if r < lo || r > hi do fail(&errors, fmt.tprintf("%s: сток %.0f мм, у настоящего %.0f", b.name, r, b.r))
	}

	h := &hydro
	st := &h.stats
	fmt.printfln("=== Сеть стока мира %d ===", seed)
	fmt.printfln("клеток: суша %d, океан %d, озёра %d, солончаки %d; клетка %.1f км, постройка %.1f с",
		st.land_cells, st.ocean_cells, st.lake_cells, st.salt_cells, h.cell / 1000, st.build_s)
	land := st.land_area
	fmt.printfln("сток с суши в среднем %.0f мм/год (на Земле ~300); озёра — %.1f%% суши (на Земле ~2–4%%); бессточная суша %.0f%% (на Земле ~18%%)",
		st.mean_runoff_mm, st.lake_area / land * 100, st.endorheic_area / land * 100)
	fmt.printfln("озёр %d, из них бессточных %d, солончаков %d", st.lakes, st.closed, st.playas)
	fmt.printfln("клеток с реками %d; гладь выше дна своего пути (подпор озёр): на 20 м — %.1f%%, на 50 м — %.1f%%, на 100 м — %.2f%%", st.rivers,
		f64(st.perched[0]) / f64(max(st.rivers, 1)) * 100, f64(st.perched[1]) / f64(max(st.rivers, 1)) * 100, f64(st.perched[2]) / f64(max(st.rivers, 1)) * 100)
	// на Земле (ЮНЕП): крайне сухо 7,5%, сухо 12%, полусухо 18%, сухо-влажно 10%, влажно 53%
	ARID_NAMES := [5]string{"крайне сухо", "сухо", "полусухо", "сухо-влажно", "влажно"}
	EARTH_ARID := [5]f64{7.5, 12.1, 17.7, 9.9, 52.8}
	fmt.println("засушливость (осадки / возм. испарение): доля суши (на Земле), из неё бессточной")
	for k in 0 ..< 5 {
		a := st.arid_area[k]
		fmt.printfln("  %s %s %.0f%%", pad(ARID_NAMES[k], 13), pad(fmt.tprintf("%.0f%% (%.0f%%)", a / land * 100, EARTH_ARID[k]), 14), st.arid_endo[k] / max(a, 1) * 100)
		fmt.printfln("      в озёра: %.0f %.0f %.0f %.0f %.0f", st.arid_to[k][0] / max(a, 1) * 100, st.arid_to[k][1] / max(a, 1) * 100, st.arid_to[k][2] / max(a, 1) * 100, st.arid_to[k][3] / max(a, 1) * 100, st.arid_to[k][4] / max(a, 1) * 100)
	}

	// крупнейшие реки
	fmt.printfln("бессточные впадины по глубине (доля их водосборов): <25 м %.0f%%, <50 %.0f%%, <100 %.0f%%, <200 %.0f%%, <400 %.0f%%, глубже %.0f%%",
		st.depth_catch[0] / st.endorheic_area * 100, st.depth_catch[1] / st.endorheic_area * 100, st.depth_catch[2] / st.endorheic_area * 100,
		st.depth_catch[3] / st.endorheic_area * 100, st.depth_catch[4] / st.endorheic_area * 100, st.depth_catch[5] / st.endorheic_area * 100)
	fmt.println("крупнейшие реки у устья: расход, водосбор, длина")
	for rv in st.big {
		if rv.q <= 0 do continue
		fmt.printfln("  %s %s %.0f км", pad(fmt.tprintf("%.0f м³/с", rv.q), 13), pad(fmt.tprintf("%.0f км²", rv.area / 1e6), 14), rv.length / 1000)
	}

	// гладь рек вниз по течению не поднимается; у озёр — не выше берегов
	up := 0
	N := 6 * h.m * h.m
	for c in 0 ..< N {
		if h.kind[c] != .Land || h.rcv[c] == 255 do continue
		r := hydro_nb(h, c, int(h.rcv[c]))
		if r < 0 do continue
		if h.level[r] > h.level[c] + 0.01 {
			up += 1
			if up <= 5 do fmt.printfln("  клетка %d (%v, %.2f м, расход %.1f) -> %d (%v, %.2f м)", c, h.kind[c], h.level[c], h.q[c], r, h.kind[r], h.level[r])
		}
	}
	fmt.printfln("клеток, где река поднимается вниз по течению: %d", up)
	if up > 0 do fail(&errors, "гладь реки поднимается вниз по течению")

	// закон Хака: длина ~ площадь^h по всем рекам с водосбором больше 10 тыс. км²
	{
		sx, sy, sxx, sxy, n := 0.0, 0.0, 0.0, 0.0, 0.0
		for rv in st.mouths {
			if rv.area < 1.0e10 || rv.length <= 0 do continue
			x, y := math.ln(rv.area / 1e6), math.ln(rv.length / 1000)
			sx += x
			sy += y
			sxx += x * x
			sxy += x * y
			n += 1
		}
		if n > 10 {
			k := (n * sxy - sx * sy) / (n * sxx - sx * sx)
			c := math.exp((sy - k * sx) / n)
			fmt.printfln("закон Хака по %.0f рекам: L ≈ %.2f·A^%.2f км (у настоящих рек показатель 0,5–0,6)", n, c, k)
			if k < 0.45 || k > 0.7 do fail(&errors, fmt.tprintf("показатель Хака %.2f", k))
		}
	}

	// вода сохраняется: всё, что стекло с суши (и осталось от озёр), уходит в океан;
	// у бессточных озёр приход и испарение с глади равны
	{
		fmt.printfln("сток с суши и баланс глади озёр %.0f км³/год, реки в океан %.0f; в бессточные озёра стекает %.0f (испаряется там)",
			st.runoff_in / 1e9, st.to_ocean / 1e9, st.lost_lakes / 1e9)
		if abs(st.to_ocean + st.lost_lakes - st.runoff_in) > 0.01 * st.runoff_in do fail(&errors, fmt.tprintf("вода не сходится: в океан и бессточные озёра %.0f, а стекло %.0f км³", (st.to_ocean + st.lost_lakes) / 1e9, st.runoff_in / 1e9))
	}
	if st.mean_runoff_mm < 20 || st.mean_runoff_mm > 1500 do fail(&errors, fmt.tprintf("средний сток %.0f мм", st.mean_runoff_mm))

	// насыпи: на сколько гладь реки выше естественного рельефа прямо на русле
	// (середина пути между узлами — точно на реке)
	{
		s := i64(seed)
		n, over5, over20, over50 := 0, 0, 0, 0
		for k := 0; k < N && n < 1500; k += 997 {
			c := (k * 7919) % N
			if h.kind[c] != .Land || h.q[c] < 0.5 || h.rcv[c] == 255 do continue
			r := hydro_nb(h, c, int(h.rcv[c]))
			if r < 0 || h.kind[r] != .Land do continue
			// русло извилисто: от середины пути между узлами — поперёк реки до её воды
			nc, nr := hydro_node(h, c), hydro_node(h, r)
			d := nc + nr
			d /= math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
			along := nr - nc
			across := [3]f64{d.y * along.z - d.z * along.y, d.z * along.x - d.x * along.z, d.x * along.y - d.y * along.x}
			across /= math.sqrt(across.x * across.x + across.y * across.y + across.z * across.z)
			p: [3]f64
			sm: Hydro_Sample
			found := false
			for j in 0 ..< 400 {
				off := f64((j + 1) / 2) * 4 * (j % 2 == 0 ? 1 : -1)
				q := d * h.radius + across * off
				p = q / math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z) * h.radius
				sm = terrain_surface(s, p, 0.5)
				if sm.kind == .River {
					found = true
					break
				}
			}
			if !found do continue
			n += 1
			above := sm.water - elevation(s, p, 0.5)
			if above > 5 do over5 += 1
			if above > 20 do over20 += 1
			if above > 50 do over50 += 1
		}
		fmt.printfln("насыпи: гладь реки выше естественного рельефа на русле (%d точек): на 5 м — %.1f%%, на 20 м — %.1f%%, на 50 м — %.1f%%",
			n, f64(over5) / f64(max(n, 1)) * 100, f64(over20) / f64(max(n, 1)) * 100, f64(over50) / f64(max(n, 1)) * 100)
		if f64(over20) > 0.03 * f64(n) do fail(&errors, "реки на насыпях")
	}

	// кэш кривых: точка по кэшу своей клетки и соседних — одно и то же
	{
		s := i64(seed)
		bad, n := 0, 0
		worst := 0.0
		for k := 0; k < N && n < 3000; k += 4999 {
			c := (k * 7919) % N
			if h.kind[c] != .Land || h.q[c] < 0.5 do continue
			n += 1
			// у самой границы клетки (с соседом справа), рядом с её рекой
			face := Cube_Face(c / (h.m * h.m))
			rr := c % (h.m * h.m)
			fz := f64(rr / h.m) + 0.5 + 0.4 * math.sin(f64(k))
			p := hydro_dir_at(h.m, face, f64(rr % h.m) + 0.97, fz) * h.radius
			m := hydro_cache_mismatch(p, elevation(s, p, 0.5))
			if m > 0.01 do bad += 1
			worst = max(worst, m)
		}
		fmt.printfln("кэш кривых: %d точек, расходятся с кэшем соседних клеток %d (до %.1f м)", n, bad, worst)
		if bad > 0 do fail(&errors, "кэш кривых зависит от клетки")
	}
	// земля и вода непрерывны через границы клеток сети (по обе стороны — свой кэш)
	{
		s := i64(seed)
		n, bad := 0, 0
		worst := 0.0
		for k := 0; k < N && n < 20000; k += 211 {
			c := (k * 7919) % N
			if h.kind[c] == .Ocean do continue
			n += 1
			face := Cube_Face(c / (h.m * h.m))
			rr := c % (h.m * h.m)
			if rr % h.m == h.m - 1 do continue
			fz := f64(rr / h.m) + 0.5 + 0.45 * math.sin(f64(k))
			pa := hydro_dir_at(h.m, face, f64(rr % h.m + 1) - 1e-8, fz) * h.radius
			pb := hydro_dir_at(h.m, face, f64(rr % h.m + 1) + 1e-8, fz) * h.radius
			sa := terrain_surface(s, pa, 0.5)
			sb := terrain_surface(s, pb, 0.5)
			// разница земли сверх разницы самого рельефа (склон может быть крутым)
			dg := abs((sa.ground - sb.ground) - (elevation(s, pa, 0.5) - elevation(s, pb, 0.5)))
			wa := sa.kind != .None && sa.kind != .Salt
			wb := sb.kind != .None && sb.kind != .Salt
			if dg > 0.05 || wa != wb {
				bad += 1
				if bad <= 5 do fmt.printfln("  разрыв у клетки %d: земля %.2f | %.2f, вода %v %.2f | %v %.2f", c, sa.ground, sb.ground, sa.kind, sa.water, sb.kind, sb.water)
			}
			worst = max(worst, dg)
		}
		fmt.printfln("границы клеток: %d точек, разрывов %d (земля до %.2f м)", n, bad, worst)
		if bad > 0 do fail(&errors, "разрыв на границе клеток сети")
	}

	// болота (0.020): доля суши под ними по климату болот клетки (на Земле: в
	// среднем ~6%; в тайге и тундре с торфом 15–25%, во влажных тропиках ~10%,
	// в умеренном поясе ~5%, в сухих краях ~1%)
	{
		s := i64(seed)
		CLS := [4]string{"сухо", "низинные", "торф", "тропики"}
		n, wet: [4]int
		kinds: [Wetland]int
		example: [Wetland][2]f64 // широта и долгота первой точки вида (для -latlon)
		mangrove_lat := 0.0
		total, total_wet := 0, 0
		for k := 0; k < N && total < 40000; k += 157 {
			c := (k * 7919) % N
			if h.kind[c] != .Land do continue
			face := Cube_Face(c / (h.m * h.m))
			rr := c % (h.m * h.m)
			p := hydro_dir_at(h.m, face, f64(rr % h.m) + 0.5 + 0.45 * math.sin(f64(k) * 1.3), f64(rr / h.m) + 0.5 + 0.45 * math.cos(f64(k) * 0.7)) * h.radius
			sm := terrain_surface(s, p, 0.5)
			if sm.kind == .River || sm.kind == .Sea do continue
			cl := int(h.wetc[c] & 7)
			n[cl] += 1
			total += 1
			if sm.wet != .None {
				wet[cl] += 1
				total_wet += 1
				kinds[sm.wet] += 1
				la, lo := geo_latlon(p / h.radius)
				if kinds[sm.wet] == 1 do example[sm.wet] = {la, lo}
				if sm.wet == .Mangrove do mangrove_lat = max(mangrove_lat, abs(la))
			}
		}
		fmt.printfln("болота: %.1f%% суши (%d точек); по климату:", f64(total_wet) / f64(max(total, 1)) * 100, total)
		for i in 0 ..< 4 do fmt.printfln("  %s: %.1f%% (%d точек)", pad(CLS[i], 10), f64(wet[i]) / f64(max(n[i], 1)) * 100, n[i])
		ml := kinds[.Mangrove] > 0 ? fmt.tprintf(" (не дальше %.0f° от экватора)", mangrove_lat) : ""
		fmt.printfln("  из болот: низинные %d, торфяные %d, тропические %d, мангры %d%s, марши %d", kinds[.Marsh], kinds[.Bog], kinds[.Swamp], kinds[.Mangrove], ml, kinds[.Salt_Marsh])
		for wk in Wetland do if wk != .None && kinds[wk] > 0 do fmt.printfln("  пример: %s — -latlon:%.2f,%.2f", WETLAND_NAMES[wk], example[wk].x, example[wk].y)
	}

	// цена точки: рельеф и рельеф с реками и озёрами (подряд по 256 м — как колонки мира)
	{
		s := i64(seed)
		d0 := hydro_node(h, st.big[0].mouth) // у устья крупнейшей реки: там рек много
		e1 := [3]f64{d0.z, 0, -d0.x}
		e1 /= math.sqrt(e1.x * e1.x + e1.z * e1.z)
		e2 := [3]f64{d0.y * e1.z - d0.z * e1.y, d0.z * e1.x - d0.x * e1.z, d0.x * e1.y - d0.y * e1.x}
		pt :: proc(d0, e1, e2: [3]f64, R: f64, k: int) -> [3]f64 {
			x, y := f64(k % 400) * 25 - 5000, f64(k / 400) * 20 - 5000 // 10×10 км
			p := d0 * R + e1 * x + e2 * y
			return p / math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z) * R
		}
		M :: 200_000
		t0 := time.now()
		acc := 0.0
		for k in 0 ..< M do acc += elevation(s, pt(d0, e1, e2, h.radius, k), 0.5)
		t1 := time.now()
		wet := 0
		for k in 0 ..< M {
			sm := terrain_surface(s, pt(d0, e1, e2, h.radius, k), 0.5)
			acc += sm.ground
			if sm.kind != .None do wet += 1
		}
		t2 := time.now()
		us :: proc(a, b: time.Time) -> f64 {return time.duration_microseconds(time.diff(a, b)) / M}
		fmt.printfln("точка: рельеф %.2f мкс, с реками и озёрами %.2f мкс (у устья крупнейшей реки; вода в %.0f%% точек)", us(t0, t1), us(t1, t2), f64(wet) / M * 100)
		_ = acc
	}
	fmt.printfln("ошибок: %d", errors)
	return
}
