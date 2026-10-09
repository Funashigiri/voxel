package main

// Проверка погоды (-weather): десять лет погоды по часам на климате Земли
// (climate_check.odin) в типичных местах. Суммы осадков должны сойтись с
// климатом; число дней с дождём, доля ливней, снег зимой, ветер (пассаты и
// западный перенос) и разброс давления — с настоящими метеостанциями.

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

	Place :: struct {
		name:           string,
		c:              Climate_Point,
		lon:            f64,
		wet_lo, wet_hi: f64, // дней с осадками ≥ 1 мм в год — как у настоящих станций
		cl_lo, cl_hi:   f64, // средняя облачность, % — по спутникам и станциям
	}
	places := []Place {
		{"экваториальный лес у моря (3°)", {lat = 3, cont = 0.4, wet = 1.0, land = true}, 100, 120, 230, 55, 85},
		{"тропики в глубине материка (13°)", {lat = 13, cont = 0.8, wet = 0.75, land = true}, 10, 30, 110, 30, 60},
		{"Сахара (25°)", {lat = 25, cont = 0.95, wet = 0.4, land = true}, 15, 0, 15, 5, 30},
		{"Средиземноморье (38°)", {lat = 38, cont = 0.45, wet = 0.9, land = true}, 350, 50, 110, 30, 60},
		{"Западная Европа у моря (50°)", {lat = 50, cont = 0.2, wet = 1.0, land = true}, 0, 90, 190, 60, 85},
		{"Подмосковье (55°)", {lat = 55, cont = 0.9, wet = 0.75, land = true}, 37, 80, 170, 55, 80},
		{"тундра (70°)", {lat = 70, cont = 0.6, wet = 0.6, land = true}, 60, 15, 60, 55, 85},
	}
	YEARS :: 10
	hours := int(EARTH_YEAR_HOURS * YEARS)
	fmt.println("место                              осадки: погода / климат   дней ≥1 мм (на деле)   дождь, % часов  ливни  снег зимой  ветер, м/с (с запада)  давление ±σ, гПа  облачность, % (на деле)")
	for &pl in places {
		dry := 0.6 * pl.c.cont // как сухость травы: глубь материка — больше суточный ход
		clim_year := 0.0
		_, pm := climate_months(&cm, &pl.c)
		for m in 0 ..< 12 do clim_year += pm[m]
		total, conv_sum, rain_h, wet_days, winter_p, winter_snow, cover_sum := 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
		wind_u, wind_s, p_sum, p_sum2, p_lo, p_hi := 0.0, 0.0, 0.0, 0.0, 1.0e9, -1.0e9
		samples := 0
		day_sum := 0.0
		LONS :: 4 // четыре точки на широте — редкие ливни пустынь набираются вчетверо быстрее
		for li in 0 ..< LONS do for h in 0 ..< hours {
			lon := pl.lon + f64(li) * 90
			d := geo_from_latlon(pl.c.lat, lon)
			t := f64(h)
			s := math.mod(t / EARTH_YEAR_HOURS, 1)
			tc, pc := climate_at(&cm, &pl.c, s)
			loc := Wx_Local{lat = pl.c.lat, t = tc, p = pc, dry = dry, land = pl.c.land, sea_t = climate_sea_t(&cm, pl.c.lat, s)}
			hour := math.mod(t + lon / 15, 24)
			full := h % 6 == 0
			w := weather_at(&wm, d, loc, t, hour, full)
			total += w.rain
			conv_sum += w.conv
			cover_sum += w.cover
			if w.rain >= 0.1 do rain_h += 1
			day_sum += w.rain
			if h % 24 == 23 {
				if day_sum >= 1 do wet_days += 1
				day_sum = 0
			}
			// зима этого полушария: три самых холодных «месяца» — по климату
			if tc < climate_coldest(&cm, &pl.c) + 3 {
				winter_p += w.rain
				winter_snow += w.rain * w.snow
			}
			if full {
				wind_u += w.wind.x
				wind_s += math.sqrt(w.wind.x * w.wind.x + w.wind.y * w.wind.y)
				p_sum += w.press
				p_sum2 += w.press * w.press
				p_lo = min(p_lo, w.press)
				p_hi = max(p_hi, w.press)
				samples += 1
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
			pad(fmt.tprintf("%.0f (%.0f–%.0f)", wet, pl.wet_lo, pl.wet_hi), 22),
			pad(fmt.tprintf("%.1f", rain_h / f64(hours * LONS) * 100), 15),
			pad(fmt.tprintf("%.0f%%", conv_sum / max(total, 1e-6) * 100), 6),
			pad(fmt.tprintf("%.0f%%", snow_share * 100), 11),
			pad(fmt.tprintf("%+.1f (%.1f)", wind_u / ns, wind_s / ns), 22),
			pad(fmt.tprintf("%.0f ±%.1f (%.0f…%.0f)", p_mean, p_sd, p_lo, p_hi), 24),
			fmt.tprintf("%.0f (%.0f–%.0f)", cloud, pl.cl_lo, pl.cl_hi))
		if cloud < pl.cl_lo - 8 || cloud > pl.cl_hi + 8 do fail(&errors, fmt.tprintf("%s: средняя облачность", pl.name))
		if clim_year > 20 && abs(ratio - 1) > 0.08 do fail(&errors, fmt.tprintf("%s: осадки погоды расходятся с климатом", pl.name))
		if wet < pl.wet_lo * 0.8 || wet > pl.wet_hi * 1.2 do fail(&errors, fmt.tprintf("%s: дней с осадками", pl.name))
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
			if snow_share > 0.4 do fail(&errors, "у моря в Западной Европе зимой чаще дождь, чем снег")
		case 55:
			if snow_share < 0.6 do fail(&errors, "в Подмосковье зимой осадки — в основном снег")
		}
	}
	fmt.printfln("ошибок: %d", errors)
	return
}

// Средняя температура самого холодного «месяца» места.
@(private = "file")
climate_coldest :: proc(cm: ^Climate, c: ^Climate_Point) -> f64 {
	@(static) cache_lat := -999.0
	@(static) cache_t := 0.0
	if c.lat == cache_lat do return cache_t
	t, _ := climate_months(cm, c)
	m := 1.0e9
	for x in t do m = min(m, x)
	cache_lat, cache_t = c.lat, m
	return m
}
