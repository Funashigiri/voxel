package main

// Климат (0.015).
//
// Температура — модель теплового баланса по широтам (как у Норта и Коакли):
// на каждой широте две «коробки» — суша и океан. Их греет свет звезды
// (суточное среднее по склонению солнца и расстоянию до звезды — из орбиты
// планеты), они остывают излучением в космос (A + B·T, A подбирается так,
// чтобы средняя по планете совпала с температурой из атмосферы), обмениваются
// теплом между собой и с соседними широтами (перенос воздухом: сильнее в
// плотной атмосфере и на медленно вращающейся планете — D ∝ p·cp/μ²/Ω²).
// Лёд и снег отражают свет — полярные шапки поддерживают холод сами. Океан
// прогревается медленно (глубокий перемешанный слой), суша — быстро: у моря
// мягко, в глубине материка лето жаркое, зима морозная.
//
// Осадки — по поясам циркуляции: у экватора дожди (внутритропическая зона
// схождения ветров — ходит за солнцем), у края ячейки Хэдли — сухие пояса
// пустынь, в средних широтах — пояс циклонов, у полюсов сухо. Ширина ячейки
// Хэдли — по Хелду и Хоу: шире на медленно вращающейся и тёплой планете.
// Вглубь материка суше, за горами с подветренной стороны — дождевая тень.
//
// По месячным температурам и осадкам — тип климата по Кёппену, по нему —
// природная зона.

import "core:fmt"
import "core:math"
import eng "engine"

CLIM_LAT :: 90 // полосы по 2°
CLIM_SEASON :: 48 // отсчётов за год

Climate :: struct {
	t_land:   [CLIM_LAT][CLIM_SEASON]f32, // °C на уровне моря
	t_ocean:  [CLIM_LAT][CLIM_SEASON]f32,
	p_zonal:  [CLIM_LAT][CLIM_SEASON]f32, // мм в месяц (1/12 года)
	land:     [CLIM_LAT]f32, // доля суши на широте
	ok:       bool,
	lapse:    f64, // К/м
	global_t: f64, // средняя по планете за год, °C
	global_p: f64, // осадков в среднем, мм в год
	hadley:   f64, // край ячейки Хэдли, градусы широты
	storm:    f64, // пояс циклонов, градусы
	d_ratio:  f64, // перенос тепла относительно Земли
	a_olr:    f64,
	albedo:   f64,
	year_h:   f64, // стандартных часов в году
	season_eq: f64, // сезон (доля года по средней аномалии) в момент весеннего равноденствия на севере
	equator_t, pole_n_t, pole_s_t: f64, // за год, на уровне моря
}

// Климат мира — задаётся один раз при старте, до фоновых потоков.
climate: Climate

Climate_Input :: struct {
	star_lum:       f64, // светимостей Солнца
	orbit_au, ecc:  f64,
	peri:           f64, // долгота перицентра (рад) — как в astro.odin
	tilt, tilt_dir: f64, // рад
	sidereal_hours: f64,
	year_hours:     f64,
	atmo:           ^Atmosphere,
	radius_km:      f64,
	gravity_g:      f64,
	land:           []f32, // доля суши по полосам (CLIM_LAT), если задана; иначе — из рельефа
	seed:           u32, // зерно рельефа
}

@(private = "file")
band_lat :: #force_inline proc "contextless" (i: int) -> f64 {
	return -89 + 2 * f64(i)
}

// Склонение солнца и расстояние до звезды (а.е.) при средней аномалии m.
@(private = "file")
sun_geometry :: proc(in_: ^Climate_Input, m: f64) -> (decl, r: f64) {
	e := in_.ecc
	E := kepler_E(m, e)
	nu := 2 * math.atan2(math.sqrt(1 + e) * math.sin(E / 2), math.sqrt(1 - e) * math.cos(E / 2))
	r = in_.orbit_au * (1 - e * math.cos(E))
	lam := in_.peri + nu + math.PI // солнце — с обратной стороны от планеты
	decl = math.asin(math.sin(in_.tilt) * math.cos(lam - in_.tilt_dir))
	return
}

// Суточное среднее света (Вт/м²) на широте phi при склонении decl.
@(private = "file")
daily_insolation :: proc "contextless" (s0, phi, decl: f64) -> f64 {
	c := -math.tan(phi) * math.tan(decl)
	h0: f64
	switch {
	case c >= 1:
		return 0 // полярная ночь
	case c <= -1:
		h0 = math.PI // полярный день
	case:
		h0 = math.acos(c)
	}
	return s0 / math.PI * (h0 * math.sin(phi) * math.sin(decl) + math.cos(phi) * math.cos(decl) * math.sin(h0))
}

// Доля суши по полосам широты — по рельефу (relief должен быть задан).
climate_land_from_relief :: proc(seed: u32, radius_m: f64, out: []f32) {
	s := i64(seed)
	LON :: 72
	for i in 0 ..< CLIM_LAT {
		n := 0
		for sub in 0 ..< 2 {
			lat := band_lat(i) - 0.5 + f64(sub)
			for k in 0 ..< LON {
				lon := (f64(k) + 0.5 * f64(sub)) / LON * 360
				if elevation(s, geo_from_latlon(lat, lon) * radius_m, 20_000) > 0 do n += 1
			}
		}
		out[i] = f32(n) / (2 * LON)
	}
}

// Тепловой баланс за годы до установления; возвращает среднюю по планете за год.
@(private = "file")
ebm_run :: proc(cm: ^Climate, in_: ^Climate_Input, D, A, B, alb: f64) -> f64 {
	STEPS :: 360
	YEARS :: 24
	C_LAND :: 2.0e7 // Дж/(м²·К): воздух и верх почвы
	C_OCEAN :: 1.5e8 // перемешанный слой океана (в среднем за год ~35 м)
	NU :: 3.0 // обмен теплом суша — океан на одной широте, Вт/(м²·К)
	ALB_SNOW :: 0.6
	ALB_GLACIER :: 0.72
	dt := in_.year_hours * 3600 / STEPS
	s0 := 1361 * in_.star_lum
	x, w: [CLIM_LAT]f64 // синус широты в центре полосы, ширина полосы по синусу
	xe: [CLIM_LAT + 1]f64 // границы полос
	for i in 0 ..< CLIM_LAT do x[i] = math.sin(math.to_radians(band_lat(i)))
	for i in 0 ..= CLIM_LAT do xe[i] = math.sin(math.to_radians(-90 + 2 * f64(i)))
	for i in 0 ..< CLIM_LAT do w[i] = xe[i + 1] - xe[i]
	tl, to: [CLIM_LAT]f64
	for i in 0 ..< CLIM_LAT {
		tl[i] = 15
		to[i] = 15
	}
	// неявная диффузия: (C/dt)·Tнов − div(D(1−x²)∇Tнов) = (C/dt)·T (метод прогонки)
	diffuse :: proc(t: ^[CLIM_LAT]f64, c: ^[CLIM_LAT]f64, x, w: ^[CLIM_LAT]f64, xe: ^[CLIM_LAT + 1]f64, dk: ^[CLIM_LAT + 1]f64, dt: f64) {
		a, b, cc, d: [CLIM_LAT]f64
		for i in 0 ..< CLIM_LAT {
			kl := i > 0 ? dk[i] * (1 - xe[i] * xe[i]) / (x[i] - x[i - 1]) : 0
			kr := i < CLIM_LAT - 1 ? dk[i + 1] * (1 - xe[i + 1] * xe[i + 1]) / (x[i + 1] - x[i]) : 0
			m := c[i] * w[i] / dt
			a[i] = -kl
			cc[i] = -kr
			b[i] = m + kl + kr
			d[i] = m * t[i]
		}
		for i in 1 ..< CLIM_LAT {
			f := a[i] / b[i - 1]
			b[i] -= f * cc[i - 1]
			d[i] -= f * d[i - 1]
		}
		t[CLIM_LAT - 1] = d[CLIM_LAT - 1] / b[CLIM_LAT - 1]
		for i := CLIM_LAT - 2; i >= 0; i -= 1 do t[i] = (d[i] - cc[i] * t[i + 1]) / b[i]
	}
	smooth :: proc "contextless" (e0, e1, v: f64) -> f64 {
		t := clamp((v - e0) / (e1 - e0), 0, 1)
		return t * t * (3 - 2 * t)
	}
	// перенос: океан добавляет свои течения, над сушей — только воздух
	d_land, d_ocean := 0.85 * D, 1.5 * D
	// снег на суше: копится в морозы, тает в тепло, отбирая тепло (пока лежит —
	// земля не греется выше нуля). Не стаял за год — вечный ледник.
	L_FUSION :: 3.34e5 // Дж/кг
	snow: [CLIM_LAT]f64 // кг/м² (= мм воды)
	snow_min: [CLIM_LAT]f64
	glacier: [CLIM_LAT]bool
	mean := 0.0
	for year in 0 ..< YEARS {
		sum, wsum := 0.0, 0.0
		for i in 0 ..< CLIM_LAT do snow_min[i] = 1.0e9
		for step in 0 ..< STEPS {
			m := 2 * math.PI * (f64(step) + 0.5) / STEPS
			decl, r := sun_geometry(in_, m)
			cl, co: [CLIM_LAT]f64
			for i in 0 ..< CLIM_LAT {
				phi := math.to_radians(band_lat(i))
				q := daily_insolation(s0 / (r * r), phi, decl)
				fl := f64(cm.land[i])
				// низкое солнце отражается сильнее (и облаков у полюсов больше)
				free := clamp(alb - 0.06 + 0.2 * x[i] * x[i], 0.05, 0.9)
				cover := smooth(0, 40, snow[i]) // слой в 4 см воды закрывает землю
				al := free + ((glacier[i] ? ALB_GLACIER : ALB_SNOW) - free) * cover * 0.9
				ice := smooth(-2, -8, to[i])
				ao := free + (ALB_SNOW - free) * ice
				exch := NU * (to[i] - tl[i])
				tl[i] += dt / C_LAND * (q * (1 - al) - (A + B * tl[i]) + exch)
				if tl[i] < 0 {
					snow[i] += 1.0e-5 * math.exp(0.06 * max(tl[i], -40)) * dt // в мороз — снегопады (в холоде суше)
				} else if snow[i] > 0 {
					melt := C_LAND * tl[i] / L_FUSION // тепло уходит на таяние
					if melt < snow[i] {
						snow[i] -= melt
						tl[i] = 0
					} else {
						tl[i] = (melt - snow[i]) * L_FUSION / C_LAND
						snow[i] = 0
					}
				}
				snow[i] = min(snow[i], 3000)
				snow_min[i] = min(snow_min[i], snow[i])
				// океан: зимой перемешивается глубже — остывает медленнее, летом греется тонкий слой
				deep := q * (1 - ao) - (A + B * to[i]) < 0
				// подо льдом океан отрезан от воздуха — над ним морозно, как над сушей
				co[i] = (deep && ice < 0.5 ? 2.0 * C_OCEAN : C_OCEAN) * (1 - 0.9 * ice)
				back := fl < 0.999 ? exch * fl / (1 - fl) : 0
				to[i] += dt / co[i] * (q * (1 - ao) - (A + B * to[i]) - back)
				cl[i] = C_LAND
				if year == YEARS - 1 {
					s := step * CLIM_SEASON / STEPS
					cm.t_land[i][s] += f32(tl[i]) * CLIM_SEASON / STEPS
					cm.t_ocean[i][s] += f32(to[i]) * CLIM_SEASON / STEPS
				}
				zw := w[i]
				sum += (fl * tl[i] + (1 - fl) * to[i]) * zw
				wsum += zw
			}
			// перенос по границам полос; у океана подо льдом течения не греют воздух
			dl, do_: [CLIM_LAT + 1]f64
			for j in 0 ..= CLIM_LAT {
				dl[j] = d_land
				ia, ib := max(j - 1, 0), min(j, CLIM_LAT - 1)
				ice_e := (smooth(-2, -8, to[ia]) + smooth(-2, -8, to[ib])) / 2
				do_[j] = d_ocean * (1 - 0.7 * ice_e)
			}
			diffuse(&tl, &cl, &x, &w, &xe, &dl, dt)
			diffuse(&to, &co, &x, &w, &xe, &do_, dt)
		}
		for i in 0 ..< CLIM_LAT do glacier[i] = snow_min[i] > 0
		mean = sum / wsum
	}
	return mean
}

// Климат планеты: температура по широтам и сезонам, пояса осадков.
climate_make :: proc(input: Climate_Input) -> (cm: Climate) {
	in_ := input
	a := in_.atmo
	if in_.land != nil {
		for i in 0 ..< CLIM_LAT do cm.land[i] = in_.land[i]
	} else {
		climate_land_from_relief(in_.seed, in_.radius_km * 1000, cm.land[:])
	}
	cm.lapse = a.lapse
	cm.albedo = a.albedo
	cm.year_h = in_.year_hours
	// весеннее равноденствие на севере: солнце на 90° раньше направления наклона оси
	{
		e := in_.ecc
		nu := (in_.tilt_dir - math.PI / 2) - math.PI - in_.peri
		E := 2 * math.atan(math.sqrt((1 - e) / (1 + e)) * math.tan(nu / 2))
		m := E - e * math.sin(E)
		cm.season_eq = math.mod(m / (2 * math.PI) + 2, 1)
	}
	// перенос тепла: Уильямс и Кастинг (1997) — D ∝ p·cp/μ²/Ω²
	omega_ratio := 23.934 / max(in_.sidereal_hours, 1)
	cm.d_ratio = (a.pressure / 1.013) * (a.cp / 1004) * (0.02896 / a.mu) * (0.02896 / a.mu) / (omega_ratio * omega_ratio)
	cm.d_ratio = cm.d_ratio / (1 + cm.d_ratio / 12) // когда ячейки Хэдли охватывают всю планету, перенос насыщается
	D := 0.65 * cm.d_ratio
	B := 2.0
	A := 203.3
	target := a.t_surface - 273.15
	// A — секущими: средняя по планете должна совпасть с атмосферой
	a_prev, got_prev := 0.0, 0.0
	for it in 0 ..< 10 {
		cm.t_land, cm.t_ocean = {}, {}
		got := ebm_run(&cm, &in_, D, A, B, cm.albedo)
		if abs(got - target) < 0.05 do break
		next := A + B * (got - target)
		if it > 0 && abs(got - got_prev) > 1e-6 do next = A - (got - target) * (A - a_prev) / (got - got_prev)
		a_prev, got_prev = A, got
		A = clamp(next, A - 40, A + 40)
	}
	cm.a_olr = A

	// средние за год
	tz: [CLIM_LAT]f64 // по широте (суша и море вместе)
	gsum, wsum := 0.0, 0.0
	for i in 0 ..< CLIM_LAT {
		s := 0.0
		for k in 0 ..< CLIM_SEASON do s += f64(cm.land[i]) * f64(cm.t_land[i][k]) + (1 - f64(cm.land[i])) * f64(cm.t_ocean[i][k])
		tz[i] = s / CLIM_SEASON
		wz := math.cos(math.to_radians(band_lat(i)))
		gsum += tz[i] * wz
		wsum += wz
	}
	cm.global_t = gsum / wsum
	cm.equator_t = (tz[44] + tz[45]) / 2
	cm.pole_s_t = tz[0]
	cm.pole_n_t = tz[CLIM_LAT - 1]

	// --- осадки
	// ячейка Хэдли (Хелд и Хоу): φ ∝ √(g·H·Δθ)/(Ω·a); у Земли — ~30°
	dtheta := max((tz[44] + tz[45]) / 2 - (tz[0] + tz[CLIM_LAT - 1]) / 2, 2) / 45
	h_ratio := max(a.tropopause, 2000) / 11000
	cm.hadley = clamp(30 * math.sqrt(in_.gravity_g * h_ratio * dtheta) / (omega_ratio * in_.radius_km / EARTH_RADIUS_KM), 8, 70)
	cm.storm = min(cm.hadley + 18, 80)
	// осадков в среднем: испарение растёт с теплом (~2,5% на градус) и с площадью океана
	land_mean := 0.0
	for i in 0 ..< CLIM_LAT do land_mean += f64(cm.land[i]) * math.cos(math.to_radians(band_lat(i)))
	land_mean /= wsum
	cm.global_p = 1000 * math.exp(0.025 * (cm.global_t - 15)) * math.sqrt(max(1 - land_mean, 0.05) / 0.71)
	if a.pressure < 0.05 do cm.global_p *= a.pressure / 0.05 // разреженный воздух — почти без осадков
	gauss :: proc "contextless" (v: f64) -> f64 {return math.exp(-v * v)}
	rel: [CLIM_LAT][CLIM_SEASON]f64
	norm := 0.0
	for k in 0 ..< CLIM_SEASON {
		// солнце над тропиком — с запаздыванием в месяц
		m := 2 * math.PI * ((f64(k) + 0.5) / CLIM_SEASON - 1.0 / 12)
		decl, _ := sun_geometry(&in_, m)
		dd := math.to_degrees(decl)
		itcz := clamp(0.55 * dd, -0.5 * cm.hadley, 0.5 * cm.hadley)
		w_itcz := max(0.3 * cm.hadley, 5)
		for i in 0 ..< CLIM_LAT {
			lat := band_lat(i)
			h := lat >= 0 ? 1.0 : -1.0
			shift := 0.25 * dd * h // летом пояса сдвигаются к полюсу
			v := 0.10 + 2.2 * gauss((lat - itcz) / w_itcz)
			v += 0.9 * gauss((abs(lat) - (cm.storm + shift)) / 13)
			v += 0.12 * gauss((abs(lat) - 88) / 12)
			v *= 1 - 0.6 * gauss((abs(lat) - (cm.hadley + shift)) / 7) // нисходящий воздух — сухо
			t := f64(cm.land[i]) * f64(cm.t_land[i][k]) + (1 - f64(cm.land[i])) * f64(cm.t_ocean[i][k])
			v *= math.exp(0.03 * clamp(t - cm.global_t, -45, 20)) // в холоде воздух держит меньше воды
			rel[i][k] = v
			norm += v * math.cos(math.to_radians(lat))
		}
	}
	norm /= wsum * CLIM_SEASON
	for i in 0 ..< CLIM_LAT do for k in 0 ..< CLIM_SEASON do cm.p_zonal[i][k] = f32(cm.global_p / 12 * rel[i][k] / norm)
	cm.ok = true
	return
}

// ---------------------------------------------------------------- место

Climate_Point :: struct {
	lat:   f64, // градусы
	alt:   f64, // м над морем (у моря — 0)
	cont:  f64, // 0 — открытое море, 1 — глубь материка
	wet:   f64, // множитель осадков: глубь материка, дождевая тень, наветренные склоны
	land:  bool,
	wind:  int, // откуда дует: 1 — с востока (пассаты, полярные), -1 — с запада
}

// Климатические условия точки шара p (м) с высотой alt (м над морем).
climate_point :: proc(cm: ^Climate, seed: i64, p: [3]f64, alt: f64) -> (c: Climate_Point) {
	r := math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	d := p / r
	c.lat = math.to_degrees(math.asin(clamp(d.y, -1, 1)))
	c.alt = max(alt, 0)
	c.land = alt > 0
	// доля суши в кольцах 300, 800, 1500 км
	east := [3]f64{d.z, 0, -d.x}
	el := math.sqrt(east.x * east.x + east.z * east.z)
	east = el > 1e-6 ? east / el : {1, 0, 0}
	north := [3]f64{d.y * east.z - d.z * east.y, d.z * east.x - d.x * east.z, d.x * east.y - d.y * east.x}
	ring :: proc(seed: i64, d, east, north: [3]f64, r, dist: f64) -> f64 {
		n := 0
		for k in 0 ..< 16 {
			ang := f64(k) / 16 * math.TAU
			q := d + (east * math.cos(ang) + north * math.sin(ang)) * (dist / r)
			q /= math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
			if elevation(seed, q * r, 30_000) > 0 do n += 1
		}
		return f64(n) / 16
	}
	l300 := ring(seed, d, east, north, r, 300_000)
	l800 := ring(seed, d, east, north, r, 800_000)
	l1500 := ring(seed, d, east, north, r, 1_500_000)
	// ветер: пассаты с востока, в средних широтах — с запада, у полюсов — снова с востока
	al := abs(c.lat)
	c.wind = al < cm.hadley || al > cm.storm + 22 ? 1 : -1
	up, l_up := 0.0, 0.0
	dists := [4]f64{150_000, 400_000, 800_000, 1_500_000}
	for dist in dists {
		q := d + east * (f64(c.wind) * dist / r)
		q /= math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
		e := elevation(seed, q * r, 30_000)
		if dist < 1_000_000 do up = max(up, e)
		if e > 0 do l_up += 0.25
	}
	// откуда дует ветер, оттуда и погода: западные берега средних широт — морские,
	// восточные — почти материковые
	land_near := 0.5 * (0.5 * l300 + 0.3 * l800 + 0.2 * l1500) + 0.5 * l_up
	c.cont = c.land ? clamp(land_near * 1.15, 0, 1) : land_near * 0.3
	inland := 0.35 + 0.65 * math.pow(1 - land_near, 0.6)
	shadow := math.exp(-max(up - c.alt, 0) / 1800)
	oro := 1 + 0.6 * clamp(c.alt / 2500, 0, 1) * (c.alt > up ? 1 : 0.3)
	c.wet = inland * shadow * oro
	return
}

@(private = "file")
lat_index :: proc(lat: f64) -> (i0, i1: int, f: f64) {
	x := (clamp(lat, -89, 89) + 89) / 2
	i0 = min(int(x), CLIM_LAT - 2)
	return i0, i0 + 1, x - f64(i0)
}

// Температура (°C, среднесуточная) и осадки (мм в месяц) в сезон s (0..1 года
// по средней аномалии).
climate_at :: proc(cm: ^Climate, c: ^Climate_Point, s: f64) -> (t, p: f64) {
	i0, i1, f := lat_index(c.lat)
	x := math.mod(s, 1)
	if x < 0 do x += 1
	x *= CLIM_SEASON
	k0 := int(x) % CLIM_SEASON
	k1 := (k0 + 1) % CLIM_SEASON
	g := x - math.floor(x)
	at :: proc(arr: ^[CLIM_LAT][CLIM_SEASON]f32, i0, i1, k0, k1: int, f, g: f64) -> f64 {
		a := math.lerp(f64(arr[i0][k0]), f64(arr[i1][k0]), f)
		b := math.lerp(f64(arr[i0][k1]), f64(arr[i1][k1]), f)
		return math.lerp(a, b, g)
	}
	to := at(&cm.t_ocean, i0, i1, k0, k1, f, g)
	tl := at(&cm.t_land, i0, i1, k0, k1, f, g)
	t = to + c.cont * (tl - to) - cm.lapse * c.alt
	p = at(&cm.p_zonal, i0, i1, k0, k1, f, g) * c.wet
	return
}

// 12 «месяцев» года планеты.
climate_months :: proc(cm: ^Climate, c: ^Climate_Point) -> (t, p: [12]f64) {
	for m in 0 ..< 12 {
		for q in 0 ..< 4 {
			tt, pp := climate_at(cm, c, cm.season_eq + (f64(m) + (f64(q) + 0.5) / 4) / 12)
			t[m] += tt / 4
			p[m] += pp / 4
		}
	}
	return
}

// ---------------------------------------------------------------- Кёппен и зоны

Biome :: enum u8 {
	Ocean,
	Sea_Ice,
	Ice_Cap,
	Tundra,
	Taiga,
	Temperate_Forest,
	Mediterranean,
	Steppe,
	Desert_Cold,
	Desert_Hot,
	Savanna,
	Rainforest,
}

BIOME_NAMES := [Biome]string {
	.Ocean            = "океан",
	.Sea_Ice          = "многолетний морской лёд",
	.Ice_Cap          = "ледник",
	.Tundra           = "тундра",
	.Taiga            = "тайга",
	.Temperate_Forest = "умеренный лес",
	.Mediterranean    = "средиземноморье",
	.Steppe           = "степь",
	.Desert_Cold      = "холодная пустыня",
	.Desert_Hot       = "жаркая пустыня",
	.Savanna          = "саванна",
	.Rainforest       = "тропический лес",
}

Koppen :: struct {
	code:  [3]u8, // например «Cfb»
	biome: Biome,
}

koppen_text :: proc(k: Koppen) -> string {
	c := k.code
	n := 3
	for n > 0 && c[n - 1] == 0 do n -= 1
	return fmt.tprintf("%s", string(c[:n]))
}

// Тип климата по Кёппену по 12 месячным температурам (°C) и осадкам (мм);
// north — полушарие (какие месяцы летние — по самым тёплым).
koppen_classify :: proc(t, p: [12]f64) -> (k: Koppen) {
	t_max, t_min, t_sum, p_sum := -1.0e9, 1.0e9, 0.0, 0.0
	warm_months := 0
	for m in 0 ..< 12 {
		t_max = max(t_max, t[m])
		t_min = min(t_min, t[m])
		t_sum += t[m]
		p_sum += p[m]
		if t[m] >= 10 do warm_months += 1
	}
	t_ann := t_sum / 12
	// летнее полугодие — 6 самых тёплых месяцев
	order: [12]int
	for m in 0 ..< 12 do order[m] = m
	for i in 1 ..< 12 do for j := i; j > 0 && t[order[j]] > t[order[j - 1]]; j -= 1 do order[j], order[j - 1] = order[j - 1], order[j]
	p_summer, p_dry_summer, p_wet_summer := 0.0, 1.0e9, 0.0
	p_dry_winter, p_wet_winter := 1.0e9, 0.0
	for i in 0 ..< 12 {
		v := p[order[i]]
		if i < 6 {
			p_summer += v
			p_dry_summer = min(p_dry_summer, v)
			p_wet_summer = max(p_wet_summer, v)
		} else {
			p_dry_winter = min(p_dry_winter, v)
			p_wet_winter = max(p_wet_winter, v)
		}
	}
	p_dry := min(p_dry_summer, p_dry_winter)
	// E — полярный: самый тёплый месяц холоднее 10 °C
	if t_max < 10 {
		if t_max < 0 {
			k.code = {'E', 'F', 0}
			k.biome = .Ice_Cap
		} else {
			k.code = {'E', 'T', 0}
			k.biome = .Tundra
		}
		return
	}
	// B — сухой: осадков меньше порога испарения
	summer_share := p_summer / max(p_sum, 1e-9)
	add := summer_share >= 0.7 ? 280.0 : summer_share >= 0.3 ? 140.0 : 0.0
	thr := 20 * t_ann + add
	if p_sum < thr {
		hot := t_ann >= 18
		if p_sum < thr / 2 {
			k.code = {'B', 'W', hot ? 'h' : 'k'}
			k.biome = hot ? .Desert_Hot : .Desert_Cold
		} else {
			k.code = {'B', 'S', hot ? 'h' : 'k'}
			k.biome = .Steppe
		}
		return
	}
	// A — тропический: самый холодный месяц не ниже 18 °C
	if t_min >= 18 {
		switch {
		case p_dry >= 60:
			k.code = {'A', 'f', 0}
			k.biome = .Rainforest
		case p_dry >= 100 - p_sum / 25:
			k.code = {'A', 'm', 0}
			k.biome = .Rainforest
		case:
			k.code = {'A', p_dry_summer < p_dry_winter ? 's' : 'w', 0}
			k.biome = .Savanna
		}
		return
	}
	// C (умеренный) или D (континентальный)
	k.code[0] = t_min > -3 ? 'C' : 'D'
	switch {
	case p_dry_summer < 40 && p_dry_summer < p_wet_winter / 3:
		k.code[1] = 's'
	case p_dry_winter < p_wet_summer / 10:
		k.code[1] = 'w'
	case:
		k.code[1] = 'f'
	}
	switch {
	case t_max >= 22:
		k.code[2] = 'a'
	case warm_months >= 4:
		k.code[2] = 'b'
	case k.code[0] == 'D' && t_min < -38:
		k.code[2] = 'd'
	case:
		k.code[2] = 'c'
	}
	switch {
	case k.code[2] == 'c' || k.code[2] == 'd':
		k.biome = .Taiga
	case k.code[1] == 's' && k.code[0] == 'C':
		k.biome = .Mediterranean
	case:
		k.biome = .Temperate_Forest
	}
	return
}

// Природная зона и тип климата точки (для моря — океан или многолетний лёд).
climate_classify :: proc(cm: ^Climate, c: ^Climate_Point) -> (k: Koppen, t, p: [12]f64) {
	t, p = climate_months(cm, c)
	if !c.land {
		t_max := -1.0e9
		for m in 0 ..< 12 do t_max = max(t_max, t[m])
		k.biome = t_max < -1.8 ? .Sea_Ice : .Ocean // летом не тает — многолетний лёд
		return
	}
	k = koppen_classify(t, p)
	return
}

// Можно ли высаживаться: умеренный лес или степь (BSk).
climate_start_zone :: proc(k: Koppen) -> bool {
	switch k.biome {
	case .Temperate_Forest:
		return true
	case .Steppe:
		return k.code[2] == 'k'
	case .Ocean, .Sea_Ice, .Ice_Cap, .Tundra, .Taiga, .Mediterranean, .Desert_Cold, .Desert_Hot, .Savanna, .Rainforest:
	}
	return false
}

// Высота над морем, где самый тёплый месяц остывает до t °C (граница леса — 10, снеговая линия — 0).
climate_height_of :: proc(cm: ^Climate, c: ^Climate_Point, t_target: f64) -> f64 {
	sea := c^
	sea.alt = 0
	t, _ := climate_months(cm, &sea)
	t_max := -1.0e9
	for m in 0 ..< 12 do t_max = max(t_max, t[m])
	return (t_max - t_target) / max(cm.lapse, 1e-4)
}

// Сезон сейчас (0..1 года по средней аномалии — как в таблицах климата).
climate_season :: proc(a: ^Astro, T: f64) -> f64 {
	m := a.planet.mean0 + 2 * math.PI * T / a.planet.period
	s := math.mod(m / (2 * math.PI), 1)
	return s < 0 ? s + 1 : s
}

// ---------------------------------------------------------------- место высадки

// Вход для климата планеты p системы s.
climate_input_for :: proc(s: ^Star_System, p: ^Planet, seed: u32) -> Climate_Input {
	return {
		star_lum       = s.star.luminosity,
		orbit_au       = p.orbit_au,
		ecc            = p.ecc,
		peri           = p.peri,
		tilt           = math.to_radians(p.axial_tilt_deg),
		tilt_dir       = p.tilt_dir,
		sidereal_hours = p.sidereal_hours,
		year_hours     = p.year_hours,
		atmo           = &p.atmo,
		radius_km      = p.radius_km,
		gravity_g      = p.gravity_g,
		seed           = seed,
	}
}

// Для какой планеты сейчас посчитаны рельеф и климат (чтобы не считать дважды).
climate_key: [2]u64

// Место высадки на планете i: суша в низине, не у вершины куба, вне полярного
// круга (там полярные день и ночь), в умеренном лесу или степи. Рельеф и климат планеты считаются честно, место — ищется
// (точки по всей планете в случайном порядке). ok = false — такого места нет.
start_site_search :: proc(s: ^Star_System, i: int, seed: u32) -> (lat, lon: f64, ok: bool) {
	p := &s.planets[i]
	geo := geo_make(p.radius_km)
	relief_init(seed, geo.radius, p.gravity_g, p.water * p.mass_earth * M_EARTH_KG / 1000)
	climate = climate_make(climate_input_for(s, p, seed))
	climate_key = {s.star.seed, u64(i)}
	N :: 3000
	r := eng.rng_make(u64(seed) ~ 0x517E_0015)
	first := eng.rng_int(&r, 0, N - 1)
	turn := eng.rng_range(&r, 0, 360)
	for k in 0 ..< N {
		idx := (first + k * 1103) % N // обход точек вразнобой
		y := 1 - (f64(idx) + 0.5) / N * 2
		la := math.to_degrees(math.asin(y))
		lo := math.mod(f64(idx) * 137.50776405 + turn, 360) // спираль Фибоначчи
		if abs(la) > 88 - p.axial_tilt_deg do continue // за полярным кругом
		dir := geo_from_latlon(la, lo)
		pm := dir * geo.radius
		alt := elevation(i64(seed), pm, 2000)
		if alt < 10 || alt > 900 do continue
		_, fx, fz := geo_locate(&geo, dir)
		if _, _, anomaly := geo_nearest_corner(&geo, fx, fz); anomaly < MIN_ANOMALY_DIST do continue
		cp := climate_point(&climate, i64(seed), pm, alt)
		kp, _, _ := climate_classify(&climate, &cp)
		if climate_start_zone(kp) do return la, lo, true
	}
	return
}

// Полоса широты i в сезон s: температура над океаном и над сушей у моря,
// осадки (мм в месяц), ход температуры суши за месяц — для шейдера дальнего рельефа.
climate_band_now :: proc(cm: ^Climate, i: int, s: f64) -> (to, tl, p, trend: f64) {
	at :: proc(arr: ^[CLIM_LAT][CLIM_SEASON]f32, i: int, s: f64) -> f64 {
		x := math.mod(s, 1)
		if x < 0 do x += 1
		x *= CLIM_SEASON
		k0 := int(x) % CLIM_SEASON
		k1 := (k0 + 1) % CLIM_SEASON
		return math.lerp(f64(arr[i][k0]), f64(arr[i][k1]), x - math.floor(x))
	}
	to = at(&cm.t_ocean, i, s)
	tl = at(&cm.t_land, i, s)
	p = at(&cm.p_zonal, i, s)
	trend = at(&cm.t_land, i, s + 1.0 / 24) - at(&cm.t_land, i, s - 1.0 / 24)
	return
}

// Тип климата по Кёппену словами.
koppen_desc :: proc(k: Koppen) -> string {
	c := k.code
	switch c[0] {
	case 'A':
		switch c[1] {
		case 'f':
			return "влажный экваториальный"
		case 'm':
			return "муссонный тропический"
		}
		return "тропический с сухим сезоном"
	case 'B':
		hot := c[2] == 'h'
		if c[1] == 'W' do return hot ? "жаркая пустыня" : "холодная пустыня"
		return hot ? "жаркая полупустыня" : "степь"
	case 'C':
		switch c[1] {
		case 's':
			return "средиземноморский: сухое жаркое лето"
		case 'w':
			return "умеренный с сухой зимой"
		}
		switch c[2] {
		case 'a':
			return "влажный субтропический"
		case 'b':
			return "морской умеренный"
		}
		return "морской субполярный"
	case 'D':
		dry := c[1] == 'w' ? ", сухая зима" : c[1] == 's' ? ", сухое лето" : ""
		switch c[2] {
		case 'a':
			return fmt.tprintf("континентальный с жарким летом%s", dry)
		case 'b':
			return fmt.tprintf("континентальный с тёплым летом%s", dry)
		case 'd':
			return fmt.tprintf("резко континентальный, лютые морозы%s", dry)
		}
		return fmt.tprintf("субарктический%s", dry)
	case 'E':
		return c[1] == 'F' ? "вечный мороз" : "тундра: лето холоднее 10 °C"
	}
	return "океан"
}

// Отладка (-biome:…): место на планете с нужной природной зоной (рельеф и климат уже заданы).
climate_find_biome :: proc(seed: u32, radius_km: f64, want: Biome) -> (lat, lon: f64, ok: bool) {
	geo := geo_make(radius_km)
	N :: 6000
	for idx in 0 ..< N {
		y := 1 - (f64(idx) + 0.5) / N * 2
		la := math.to_degrees(math.asin(y))
		lo := math.mod(f64(idx) * 137.50776405 + 11, 360)
		dir := geo_from_latlon(la, lo)
		pm := dir * geo.radius
		alt := elevation(i64(seed), pm, 2000)
		if want == .Ocean || want == .Sea_Ice {
			if alt > -50 do continue
		} else if alt < 10 || (want != .Ice_Cap && want != .Tundra && alt > 1500) {
			continue
		}
		_, fx, fz := geo_locate(&geo, dir)
		if _, _, anomaly := geo_nearest_corner(&geo, fx, fz); anomaly < MIN_ANOMALY_DIST do continue
		cp := climate_point(&climate, i64(seed), pm, alt)
		k, _, _ := climate_classify(&climate, &cp)
		if k.biome != want do continue
		// не на краю зоны: та же зона и в 20 км вокруг
		d := math.to_degrees(20 / radius_km)
		inside := true
		for o in ([4][2]f64{{d, 0}, {-d, 0}, {0, d}, {0, -d}}) {
			pn := geo_from_latlon(clamp(la + o.x, -89.9, 89.9), lo + o.y / max(math.cos(math.to_radians(la)), 0.1)) * geo.radius
			an := elevation(i64(seed), pn, 2000)
			if an < 10 && want != .Ocean && want != .Sea_Ice do continue
			cn := climate_point(&climate, i64(seed), pn, an)
			kn, _, _ := climate_classify(&climate, &cn)
			if kn.biome != want {inside = false; break}
		}
		if inside do return la, lo, true
	}
	return
}

// Имя зоны для флага -biome.
biome_from_name :: proc(s: string) -> (b: Biome, ok: bool) {
	switch s {
	case "forest":
		return .Temperate_Forest, true
	case "taiga":
		return .Taiga, true
	case "tundra":
		return .Tundra, true
	case "glacier":
		return .Ice_Cap, true
	case "seaice":
		return .Sea_Ice, true
	case "steppe":
		return .Steppe, true
	case "desert":
		return .Desert_Hot, true
	case "colddesert":
		return .Desert_Cold, true
	case "savanna":
		return .Savanna, true
	case "rainforest":
		return .Rainforest, true
	case "med":
		return .Mediterranean, true
	}
	return
}
