package main

// Проверка погоды (-weather): десять лет погоды по часам на климате Земли
// (climate_check.odin) в типичных местах. Суммы осадков должны сойтись с
// климатом; число дней с дождём, доля ливней, снег зимой, ветер (пассаты и
// западный перенос) и разброс давления — с настоящими метеостанциями.
// 0.018: разброс температуры день ко дню, влажность, дни с туманом и грозой,
// плотность молний, снежный покров (дни со снегом, наибольшая высота).
// Станции — с тем же климатом, что даёт модель: «Подмосковье» модели (январь
// −17, июль +15 °C) — как Сыктывкар, «тайга» (−23…+12, 260 мм) — как
// сухая якутская тайга, «тундра» — как Барроу, «Западная Европа» (0…+12) —
// как побережье Норвегии. Гроз у экватора бывает от ~100 дней (Конго) до
// ~300 (Богор, Кампала); в саванне с ~1300 мм (Банги, Киншаса) — 110–150;
// на краю Сахары, где выпадает ~100 мм (Агадес, Тимбукту), — 10–25.
// Туманы у экватора на берегу редки (Сингапур — единицы дней в году), в
// глубине леса — десятки (Манаус); на атлантическом берегу Иберии — от
// ~15 (Лиссабон) до ~90 (Коимбра в долине). В нашей сухой тундре осадки
// выпадают редкими порциями (дней с ≥1 мм — 13 в году; частых слабых
// снегопадов модель 0.017 почти не даёт), и снег ложится на месяц позже, чем в
// Барроу (~250 дней) — нижняя граница 185.

import "core:fmt"
import "core:math"

weather_report :: proc() -> (errors: int) {
	fail :: proc(errors: ^int, what: string) {
		errors^ += 1
		fmt.printfln("  ОШИБКА: %s", what)
	}
	cm, atmo := climate_earth()
	wm: Weather_Model
	weather_init(&wm, 1, 6371, 23.934, 24, atmo.density, 1.0, &cm)
	fmt.println("=== Погода на Земле по модели: 10 лет по часам ===")
	fmt.printfln("ветер на высоте: на 15° %.0f м/с, на 45° %.0f м/с, на 75° %.0f м/с (+ — с запада); плотность воздуха %.2f кг/м³",
		wx_steer(&wm, 15), wx_steer(&wm, 45), wx_steer(&wm, 75), wm.rho)

	Range :: [2]f64
	Place :: struct {
		name:    string,
		c:       Climate_Point,
		lon:     f64,
		wet:     Range, // дней с осадками ≥ 1 мм в год — как у настоящих станций
		cloud:   Range, // средняя облачность, % — по спутникам и станциям
		sea:     [2]f64, // с моря сюда (восток, север) — для морского тумана; 0 — моря рядом нет
		sd_cold: Range, // разброс среднесуточной температуры в самый холодный месяц, К
		rh:      Range, // средняя влажность за год, %
		fog:     Range, // дней с туманом в год
		thunder: Range, // дней с грозой (гром слышен — молния ближе 15 км)
		snow:    Range, // дней со снегом (≥ 1 см)
		depth:   Range, // наибольшая высота снега за зиму (в среднем по годам), см
	}
	places := []Place {
		{"экваториальный лес у моря (3°)", {lat = 3, cont = 0.4, wet = 1.0, land = true}, 100, {120, 230}, {55, 85}, {1, 0}, {0.3, 1.5}, {75, 90}, {0, 40}, {80, 280}, {0, 0}, {0, 0}},
		{"тропики в глубине материка (13°)", {lat = 13, cont = 0.8, wet = 0.75, land = true}, 10, {30, 110}, {30, 60}, {}, {0.7, 2.5}, {45, 75}, {1, 40}, {40, 150}, {0, 0}, {0, 0}},
		{"Сахара (25°)", {lat = 25, cont = 0.95, wet = 0.4, land = true}, 15, {0, 15}, {5, 30}, {}, {1.2, 3.5}, {18, 40}, {0, 8}, {2, 25}, {0, 0}, {0, 0}},
		{"Средиземноморье (38°)", {lat = 38, cont = 0.45, wet = 0.9, land = true}, 350, {50, 110}, {30, 60}, {1, 0}, {1.5, 3.5}, {55, 75}, {5, 70}, {5, 35}, {0, 10}, {0, 10}},
		{"Западная Европа у моря (50°)", {lat = 50, cont = 0.2, wet = 1.0, land = true}, 0, {90, 190}, {60, 85}, {1, 0}, {2.5, 4.5}, {74, 88}, {15, 80}, {2, 20}, {0, 60}, {0, 35}},
		{"Подмосковье (55°)", {lat = 55, cont = 0.9, wet = 0.75, land = true}, 37, {80, 170}, {55, 80}, {}, {5, 9}, {70, 85}, {8, 45}, {8, 30}, {150, 210}, {30, 85}},
		{"тайга (62°)", {lat = 62, cont = 0.95, wet = 0.7, land = true}, 120, {40, 110}, {50, 80}, {}, {3.5, 8}, {65, 82}, {5, 50}, {3, 20}, {185, 235}, {20, 60}},
		{"тундра (70°)", {lat = 70, cont = 0.6, wet = 0.6, land = true}, 60, {15, 60}, {55, 85}, {0, -1}, {4.5, 9.5}, {75, 92}, {20, 120}, {0, 5}, {185, 290}, {15, 60}},
	}
	YEARS :: 10
	year_h := EARTH_YEAR_HOURS
	hours := int(year_h * YEARS)
	fmt.println("место                              осадки: погода / климат   дней ≥1 мм (на деле)   дождь, % часов  ливни  снег зимой  ветер, м/с (с запада)  давление ±σ, гПа  облачность, % (на деле)")
	extra := make([dynamic]string, context.temp_allocator)
	for &pl in places {
		dry := 0.6 * pl.c.cont // как сухость травы: глубь материка — больше суточный ход
		clim_year := 0.0
		_, pm := climate_months(&cm, &pl.c)
		for m in 0 ..< 12 do clim_year += pm[m]
		coldest := climate_coldest(&cm, &pl.c)
		total, conv_sum, rain_h, wet_days, winter_p, winter_snow, cover_sum := 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
		wind_u, wind_s, p_sum, p_sum2, p_lo, p_hi := 0.0, 0.0, 0.0, 0.0, 1.0e9, -1.0e9
		samples := 0
		day_sum := 0.0
		// 0.018
		an_day, an_n, an_sum2 := 0.0, 0, 0.0 // отклонение температуры: сутки в холодный месяц
		rh_sum := 0.0
		fog_days, thunder_days, flashes := 0.0, 0.0, 0.0
		fog_today := false
		storm_e := 0.0 // ожидаемых молний ближе 15 км за сутки
		snow_days, depth_max_sum, depth_years := 0.0, 0.0, 0
		any_snow_days := 0.0 // с любым снегом (тоньше сантиметра тоже)
		t_min_sum := 0.0
		bias_sum := 0.0 // средняя температура погоды минус климат
		month_depth: [12]f64
		month_fog: [12]f64
		LONS :: 4 // четыре точки на широте — редкие ливни пустынь набираются вчетверо быстрее
		for li in 0 ..< LONS {
			lon := pl.lon + f64(li) * 90
			d := geo_from_latlon(pl.c.lat, lon)
			east, north := wx_axes(d)
			sc := Snow_Cell{rho = 100, albedo = 0.85}
			depth_max := 0.0
			t_min := 1.0e9
			for h in 0 ..< hours {
				t := f64(h)
				s := math.mod(t / year_h, 1)
				hour := math.mod(t + lon / 15, 24)
				loc := wx_local_of(&cm, &pl.c, s)
				loc.dry = dry
				loc.pool = 0.5 // станции стоят чаще в неглубоких низинах
				loc.onshore = pl.sea
				loc.snow = sc.swe > 0 ? snow_coverage(f64(sc.swe) / f64(sc.rho), f64(sc.rho), f64(sc.albedo)) : 0
				w := weather_at(&wm, d, loc, t, hour)
				tc := loc.t
				bias_sum += w.t_air - tc
				total += w.rain
				conv_sum += w.conv
				cover_sum += w.cover
				rh_sum += w.rh
				if w.rain >= 0.1 do rain_h += 1
				day_sum += w.rain
				an_day += w.t_anom
				if w.fog > 0 do fog_today = true
				// молнии вокруг: в центре и в шести точках в 9 км — сколько их ближе 15 км
				flashes += w.flash
				if w.cape > 500 {
					lam := w.flash
					if loc.p > 0 {
						for k in 0 ..< 6 {
							a := f64(k) / 6 * math.TAU
							q := d + (east * math.cos(a) + north * math.sin(a)) * (9000 / wm.radius)
							q /= math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
							lam += wx_flash_rate(wx_conv_rain(&wm, q, &loc, t, hour), w.cape, true)
						}
					}
					storm_e += lam / 7 * math.PI * 15 * 15
				}
				// снег
				cosz, flux := climate_sun(&cm, pl.c.lat, s, hour)
				wind := math.sqrt(w.wind.x * w.wind.x + w.wind.y * w.wind.y)
				snow_step(&sc, {rain = w.rain, t = w.t_air, cover = w.cover, wind = wind, sun = flux * max(cosz, 0) * cm.clear_sky, rh = w.rh}, 1)
				depth := sc.swe > 0 ? f64(sc.swe) / f64(sc.rho) : 0
				if t >= year_h do month_depth[int(math.mod(s - cm.season_eq + 1, 1) * 12) % 12] += depth
				first := t < year_h // первый год — снег только копится
				if !first {
					depth_max = max(depth_max, depth)
					t_min = min(t_min, w.t_air)
				}
				if h % 24 == 12 && !first && depth >= 0.01 do snow_days += 1
				if h % 24 == 12 && !first && depth >= 0.001 do any_snow_days += 1
				if h % 24 == 23 {
					if day_sum >= 1 do wet_days += 1
					day_sum = 0
					if tc < coldest + 1.5 {
						a := an_day / 24
						an_sum2 += a * a
						an_n += 1
					}
					an_day = 0
					if fog_today {
						fog_days += 1
						month_fog[int(math.mod(s - cm.season_eq + 1, 1) * 12) % 12] += 1
					}
					fog_today = false
					thunder_days += 1 - math.exp(-storm_e)
					storm_e = 0
				}
				// год кончился: наибольшая высота снега и самый сильный мороз
				if h > 0 && int(t / year_h) != int((t - 1) / year_h) && !first && t > 1.5 * year_h {
					depth_max_sum += depth_max
					t_min_sum += t_min
					depth_years += 1
					depth_max = 0
					t_min = 1.0e9
				}
				// зима этого полушария: три самых холодных «месяца» — по климату
				if tc < coldest + 3 {
					winter_p += w.rain
					winter_snow += w.rain * w.snow
				}
				if h % 6 == 0 {
					wind_u += w.wind.x
					wind_s += wind
					p_sum += w.press
					p_sum2 += w.press * w.press
					p_lo = min(p_lo, w.press)
					p_hi = max(p_hi, w.press)
					samples += 1
				}
			}
		}
		year := total / (YEARS * LONS)
		ratio := year / max(clim_year, 1e-6)
		wet := wet_days / (YEARS * LONS)
		ns := f64(samples)
		p_mean := p_sum / ns
		p_sd := math.sqrt(max(p_sum2 / ns - p_mean * p_mean, 0))
		snow_share := winter_p > 0 ? winter_snow / winter_p : 0
		cloud := cover_sum / f64(hours * LONS) * 100
		fmt.printfln("%s %s %s %s %s %s %s %s %s",
			pad(pl.name, 34),
			pad(fmt.tprintf("%.0f / %.0f мм (%+.0f%%)", year, clim_year, (ratio - 1) * 100), 25),
			pad(fmt.tprintf("%.0f (%.0f–%.0f)", wet, pl.wet[0], pl.wet[1]), 22),
			pad(fmt.tprintf("%.1f", rain_h / f64(hours * LONS) * 100), 15),
			pad(fmt.tprintf("%.0f%%", conv_sum / max(total, 1e-6) * 100), 6),
			pad(fmt.tprintf("%.0f%%", snow_share * 100), 11),
			pad(fmt.tprintf("%+.1f (%.1f)", wind_u / ns, wind_s / ns), 22),
			pad(fmt.tprintf("%.0f ±%.1f (%.0f…%.0f)", p_mean, p_sd, p_lo, p_hi), 24),
			fmt.tprintf("%.0f (%.0f–%.0f)", cloud, pl.cloud[0], pl.cloud[1]))
		if cloud < pl.cloud[0] - 8 || cloud > pl.cloud[1] + 8 do fail(&errors, fmt.tprintf("%s: средняя облачность", pl.name))
		if clim_year > 20 && abs(ratio - 1) > 0.08 do fail(&errors, fmt.tprintf("%s: осадки погоды расходятся с климатом", pl.name))
		if wet < pl.wet[0] * 0.8 || wet > pl.wet[1] * 1.2 do fail(&errors, fmt.tprintf("%s: дней с осадками", pl.name))
		switch pl.c.lat {
		case 3:
			if conv_sum / max(total, 1e-6) < 0.6 do fail(&errors, "у экватора дожди должны быть почти все ливневые")
		case 13:
			if wind_u / ns >= 0 do fail(&errors, "пассаты дуют с востока")
			if wind_s / ns < 3 || wind_s / ns > 9 do fail(&errors, "пассаты: на деле ~4–7 м/с")
		case 50:
			if wind_u / ns <= 0 do fail(&errors, "в средних широтах ветер чаще с запада")
			if p_sd < 5 || p_sd > 16 do fail(&errors, "разброс давления в средних широтах (на деле ~8–12 гПа)")
			if wind_s / ns < 4 || wind_s / ns > 10 do fail(&errors, "средний ветер у западного берега в средних широтах (на деле ~5–8 м/с)")
			if snow_share > 0.5 do fail(&errors, "у моря в Западной Европе (январь модели ~0 °C) зимой дождь бывает не реже снега")
		case 55:
			if snow_share < 0.6 do fail(&errors, "в Подмосковье зимой осадки — в основном снег")
		}
		// 0.018: температура день ко дню, влажность, туманы, грозы, снег
		n := f64(YEARS * LONS)
		sd := an_n > 0 ? math.sqrt(an_sum2 / f64(an_n)) : 0
		rh := rh_sum / f64(hours * LONS) * 100
		fog := fog_days / n
		thunder := thunder_days / n
		dens := flashes / n
		sn := snow_days / f64((YEARS - 1) * LONS)
		dmax := depth_years > 0 ? depth_max_sum / f64(depth_years) * 100 : 0
		tmin := depth_years > 0 ? t_min_sum / f64(depth_years) : 0
		append(&extra, fmt.tprintf("%s %s %s %s %s %s %s %s %s %s",
			pad(pl.name, 34),
			pad(fmt.tprintf("%.1f (%.1f–%.1f)", sd, pl.sd_cold[0], pl.sd_cold[1]), 16),
			pad(fmt.tprintf("%+.1f", bias_sum / f64(hours * LONS)), 7),
			pad(fmt.tprintf("%.0f", tmin), 8),
			pad(fmt.tprintf("%.0f (%.0f–%.0f)", rh, pl.rh[0], pl.rh[1]), 15),
			pad(fmt.tprintf("%.0f (%.0f–%.0f)", fog, pl.fog[0], pl.fog[1]), 15),
			pad(fmt.tprintf("%.0f (%.0f–%.0f)", thunder, pl.thunder[0], pl.thunder[1]), 15),
			pad(fmt.tprintf("%.2g", dens), 9),
			pad(fmt.tprintf("%.0f (%.0f–%.0f) [%.0f]", sn, pl.snow[0], pl.snow[1], any_snow_days / f64((YEARS - 1) * LONS)), 21),
			fmt.tprintf("%.0f (%.0f–%.0f)", dmax, pl.depth[0], pl.depth[1])))
		out :: proc(v: f64, r: [2]f64, slack: f64) -> bool {return v < r[0] - slack || v > r[1] + slack}
		if out(sd, pl.sd_cold, 0.5) do fail(&errors, fmt.tprintf("%s: разброс температуры день ко дню зимой", pl.name))
		if out(rh, pl.rh, 3) do fail(&errors, fmt.tprintf("%s: влажность", pl.name))
		if out(fog, pl.fog, 2) do fail(&errors, fmt.tprintf("%s: дней с туманом", pl.name))
		if out(thunder, pl.thunder, 2) do fail(&errors, fmt.tprintf("%s: дней с грозой", pl.name))
		if out(sn, pl.snow, 3) do fail(&errors, fmt.tprintf("%s: дней со снегом", pl.name))
		if out(dmax, pl.depth, 3) do fail(&errors, fmt.tprintf("%s: высота снега", pl.name))
		if pl.c.lat == 3 && (dens < 8 || dens > 90) do fail(&errors, "плотность молний у экватора (на деле ~20–80 на км² в год)")
		bias := bias_sum / f64(hours * LONS)
		{
			tm, ptm := climate_months(&cm, &pl.c)
			ms := fmt.tprintf("%s климат по месяцам, °C / мм:", pad("", 34))
			for m in 0 ..< 12 do ms = fmt.tprintf("%s %.0f/%.0f", ms, tm[m], ptm[m])
			append(&extra, ms)
			if fog > 0 {
				fs := fmt.tprintf("%s дней с туманом по месяцам:", pad("", 34))
				for m in 0 ..< 12 do fs = fmt.tprintf("%s %.1f", fs, month_fog[m] / n)
				append(&extra, fs)
			}
		}
		if dmax > 0 {
			ms := fmt.tprintf("%s снег по месяцам (от равноденствия), см:", pad("", 34))
			for m in 0 ..< 12 do ms = fmt.tprintf("%s %.0f", ms, month_depth[m] / f64((YEARS - 1) * LONS) / (year_h / 12) * 100)
			append(&extra, ms)
		}
		if abs(bias) > 0.5 do fail(&errors, fmt.tprintf("%s: средняя температура погоды ушла от климата на %+.1f К", pl.name, bias))
	}
	fmt.println()
	fmt.println("место                              σ зимой, К       сдвиг  мороз   влажность, %   дней с туманом  дней с грозой  молний/км²  дней со снегом [с любым]  снег, см")
	for s in extra do fmt.println(s)
	fmt.printfln("ошибок: %d", errors)
	return
}

// Средняя температура самого холодного «месяца» места.
@(private = "file")
climate_coldest :: proc(cm: ^Climate, c: ^Climate_Point) -> f64 {
	t, _ := climate_months(cm, c)
	m := 1.0e9
	for x in t do m = min(m, x)
	return m
}
