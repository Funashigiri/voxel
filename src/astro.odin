package main

// Небесная механика нашей системы — «рельсы»: положение каждого тела —
// формула от времени (эллиптические орбиты по Кеплеру), поэтому его можно
// узнать на любой момент. Отсюда: солнце и луны на небе, местное время,
// времена года, восход и закат, фазы лун, затмения и освещённость — честная:
// днём светит звезда, ночью — только луны (и чуть-чуть звёзды).
//
// Оси:
//  * инерциальные (эклиптика), с центром в нашей планете: плоскость орбиты —
//    XZ, её нормаль — +Y; планета обходит звезду против часовой стрелки, если
//    смотреть с +Y;
//  * оси планеты («тело»): ось вращения — +Y, долгота 0 — +Z, восток — +X
//    (те же, что у geo_* в planet.odin). Планета вращается против часовой
//    вокруг своей оси, наклонённой к нормали орбиты, — солнце встаёт на востоке.
// Время T — стандартные часы с момента высадки.

import "core:math"
import eng "engine"

AU_KM :: 149_597_870.7
SUN_LUX :: 120_000.0 // солнце в зените на Земле (с рассеянным светом неба)
FULL_MOON_LUX :: 0.25 // полная Луна на Земле
NIGHT_LUX :: 0.002 // безлунная ночь: звёзды и свечение неба
EARTH_MOON_ANG :: 1737.4 / 384_400.0 // угловой радиус нашей Луны, рад
@(private = "file")
TAG_SEASON :: 0x5EA5_0E

Orbit :: struct {
	a:      f64, // большая полуось: а.е. у планет, км у лун
	e:      f64, // эксцентриситет (0 — круг)
	incl:   f64, // наклон к плоскости нашей орбиты, рад
	node:   f64, // долгота восходящего узла, рад
	peri:   f64, // аргумент перицентра, рад
	mean0:  f64, // средняя аномалия в T = 0, рад
	period: f64, // стандартных часов
}

// Направление в плоскости эклиптики по долготе phi и обратно.
ecl_dir :: proc "contextless" (phi: f64) -> [3]f64 {
	return {math.cos(phi), 0, -math.sin(phi)}
}

ecl_lon :: proc "contextless" (v: [3]f64) -> f64 {
	return math.atan2(-v.z, v.x)
}

@(private = "file")
cross3 :: proc "contextless" (a, b: [3]f64) -> [3]f64 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

@(private = "file")
norm3 :: proc "contextless" (v: [3]f64) -> [3]f64 {
	return v / len3(v)
}

// Угол в (-PI, PI].
@(private = "file")
wrap_pi :: proc "contextless" (a: f64) -> f64 {
	r := math.mod(a + math.PI, 2 * math.PI)
	if r < 0 do r += 2 * math.PI
	return r - math.PI
}

@(private = "file")
smooth :: proc "contextless" (e0, e1, x: f64) -> f64 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}

// Уравнение Кеплера: M = E - e·sin E (метод Ньютона).
kepler_E :: proc "contextless" (M, e: f64) -> f64 {
	m := wrap_pi(M)
	E := e < 0.8 ? m : math.PI
	for _ in 0 ..< 12 do E -= (E - e * math.sin(E) - m) / (1 - e * math.cos(E))
	return E
}

// Истинная аномалия -> средняя.
@(private = "file")
true_to_mean :: proc "contextless" (nu, e: f64) -> f64 {
	E := 2 * math.atan(math.sqrt((1 - e) / (1 + e)) * math.tan(wrap_pi(nu) / 2))
	return E - e * math.sin(E)
}

// Положение тела на орбите в момент T (в единицах a), в инерциальных осях.
orbit_pos :: proc "contextless" (o: ^Orbit, T: f64) -> [3]f64 {
	E := kepler_E(o.mean0 + 2 * math.PI * T / o.period, o.e)
	px := o.a * (math.cos(E) - o.e)
	py := o.a * math.sqrt(1 - o.e * o.e) * math.sin(E)
	// плоскость орбиты: линия узлов n, нормаль w, перицентр P, Q = w × P
	n := ecl_dir(o.node)
	w := [3]f64{0, math.cos(o.incl), 0} + cross3(n, {0, 1, 0}) * math.sin(o.incl)
	q0 := cross3(w, n)
	P := n * math.cos(o.peri) + q0 * math.sin(o.peri)
	Q := cross3(w, P)
	return P * px + Q * py
}

Astro :: struct {
	planet:     Orbit, // наша планета вокруг звезды
	moons:      [MAX_MOONS]Orbit,
	moon_r:     [MAX_MOONS]f64, // км
	moon_n:     int,
	axis:       [3]f64, // ось вращения планеты (инерциальные оси)
	x0, z0:     [3]f64, // экваториальные оси при нулевом повороте
	tilt:       f64,
	tilt_dir:   f64, // долгота, к которой наклонена ось (там солнце в день летнего солнцестояния)
	sidereal:   f64, // звёздные сутки, ст. ч
	day:        f64, // солнечные сутки, ст. ч
	year_days:  f64,
	theta0:     f64, // поворот планеты в T = 0
	m_eq:       f64, // средняя аномалия в момент весеннего равноденствия (северного)
	day_base:   f64,
	planet_r:   f64, // км
	star_r:     f64, // км
	star_lum:   f64,
	star_color: [3]f32,
	// остальные планеты системы (видны на небе блуждающими точками)
	others:     [MAX_PLANETS]Orbit,
	other_d:    [MAX_PLANETS]f64, // диаметр, км
	other_p:    [MAX_PLANETS]f64, // отражательная способность
	other_kind: [MAX_PLANETS]Planet_Kind,
	other_n:    int,
	other_idx:  [MAX_PLANETS]int, // номер в системе
	// как оси вселенной (галактики, звёзды) лежат относительно осей нашей системы
	uni_to_inert: matrix[3, 3]f64,
}

// Другая планета системы на нашем небе.
Sky_Planet :: struct {
	dir:       [3]f32, // направление от нас (инерциальные оси)
	color:     [3]f32,
	mag:       f64, // видимая звёздная величина
	elevation: f64, // градусы
	index:     int, // номер в системе
}

Sky_Moon :: struct {
	frame:     [3]f32, // направление в осях кадра
	body:      [3]f64, // в осях планеты
	ang_r:     f64, // угловой радиус, рад
	elevation: f64, // градусы
	lit:       f64, // освещённая доля диска
	waxing:    bool,
	shadow:    f64, // 1 — на свету, меньше — в тени планеты (лунное затмение)
	lux:       f64,
}

Sky_State :: struct {
	// солнце
	sun_frame:   [3]f32, // направление в осях кадра
	sun_body:    [3]f64, // в осях планеты
	sun_ang_r:   f64,
	sun_elev:    f64, // градусы
	sun_azim:    f64, // градусы от севера по часовой
	sun_dist:    f64, // а.е.
	sun_visible: f64, // доля диска, не закрытая лунами
	sun_color:   [3]f32,
	moons:       [MAX_MOONS]Sky_Moon,
	moon_n:      int,
	planets:     [MAX_PLANETS]Sky_Planet,
	planet_n:    int,
	// повороты для неба: оси вселенной и инерциальные оси -> оси кадра
	uni_to_frame:   matrix[3, 3]f64,
	inert_to_frame: matrix[3, 3]f64,
	mag_limit:   f64, // самые слабые звёзды, видные сейчас (сумерки и луна мешают)
	band_vis:    f32, // насколько видно свечение неба (0..1)
	night_lux:   f64, // свет неба без луны: звёзды, полоса галактики, свечение воздуха
	pole_uni:    [3]f64, // небесный полюс над горизонтом — в осях вселенной
	// время
	local_hours: f64, // 0..24, среднее местное время
	day:         int, // день с высадки (с 1)
	day_of_year: int, // с 1, от весеннего равноденствия
	season:      int, // 0 весна, 1 лето, 2 осень, 3 зима — в северном полушарии
	sunrise:     f64, // местные часы; -1 — нет (полярный день или ночь)
	sunset:      f64,
	day_length:  f64, // местных часов
	polar:       int, // 1 — полярный день, -1 — полярная ночь
	latitude:    f64, // градусы
	decl:        f64, // склонение солнца (высота над небесным экватором), градусы
	// свет
	lux:         f64,
	light:       [3]f32, // цвет и яркость освещения мира
	desat:       f32, // обесцвечивание (ночное зрение)
	brightness:  f32,
	sky_top:     [3]f32,
	sky_horizon: [3]f32,
	glow:        [4]f32, // зарево заката: цвет и сила
}

astro_init :: proc(a: ^Astro, s: ^Star_System, start_hour: f64, start_day: int, lon: f64, seed: u32) {
	home := &s.home
	hp := home_planet(s)
	a.planet = {
		a      = hp.orbit_au,
		e      = hp.ecc,
		peri   = hp.peri, // при нулевом наклоне — долгота перигелия
		period = hp.year_hours,
	}
	a.tilt = math.to_radians(home.axial_tilt_deg)
	a.tilt_dir = home.tilt_dir
	v := ecl_dir(a.tilt_dir)
	a.axis = [3]f64{0, math.cos(a.tilt), 0} + v * math.sin(a.tilt)
	a.z0 = norm3(v - a.axis * dot3d(v, a.axis))
	a.x0 = cross3(a.axis, a.z0)
	a.sidereal = home.sidereal_hours
	a.day = home.day_hours
	a.year_days = home.year_days
	a.planet_r = hp.radius_km
	a.star_r = s.star.radius * SUN_RADIUS_KM
	a.star_lum = s.star.luminosity
	a.star_color = s.star.color

	// остальные планеты — в той же плоскости, со своими эллипсами
	for i in 0 ..< s.planet_count {
		if i == home.index do continue
		p := &s.planets[i]
		k := a.other_n
		a.others[k] = {a = p.orbit_au, e = p.ecc, peri = p.peri, mean0 = p.mean0, period = p.year_hours}
		a.other_d[k] = 2 * p.radius_km
		a.other_kind[k] = p.kind
		a.other_idx[k] = i
		a.other_p[k] = p.kind == .Rocky ? 0.25 : p.kind == .Gas_Giant ? 0.5 : 0.45
		a.other_n += 1
	}

	// оси вселенной относительно осей системы — случайный поворот (кватернион Шумейка)
	{
		r := eng.rng_make(u64(seed) ~ 0x5C7_A1E5)
		u1, u2, u3 := eng.rng_f64(&r), eng.rng_f64(&r), eng.rng_f64(&r)
		qx := math.sqrt(1 - u1) * math.sin(2 * math.PI * u2)
		qy := math.sqrt(1 - u1) * math.cos(2 * math.PI * u2)
		qz := math.sqrt(u1) * math.sin(2 * math.PI * u3)
		qw := math.sqrt(u1) * math.cos(2 * math.PI * u3)
		a.uni_to_inert = {
			1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw),
			2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw),
			2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy),
		}
	}

	a.moon_n = home.moon_count
	for i in 0 ..< a.moon_n {
		m := &home.moons[i]
		a.moons[i] = {a = m.orbit_km, e = m.ecc, incl = m.incl, node = m.node, peri = m.peri, mean0 = m.mean0, period = m.period_hours}
		a.moon_r[i] = m.radius_km
	}

	// весеннее равноденствие: солнце (на долготе планеты + 180°) за 90° до направления наклона оси
	nu_eq := (a.tilt_dir - math.PI / 2) - math.PI - a.planet.peri
	a.m_eq = true_to_mean(nu_eq, a.planet.e)
	f0: f64
	if start_day > 0 {
		f0 = (f64(start_day) - 1 + start_hour / 24) / a.year_days
	} else {
		r := eng.rng_make(u64(seed) ~ TAG_SEASON)
		f0 = eng.rng_f64(&r) // время года при высадке — случайное
	}
	a.planet.mean0 = a.m_eq + 2 * math.PI * f0

	// поворот планеты: в момент высадки на её долготе — start_hour местного времени
	lam := wrap_pi(math.to_radians(lon))
	a.theta0 = (start_hour - 12) / 24 * 2 * math.PI - lam + mean_sun_ra(a, 0)
	h0 := lam - mean_sun_ra(a, 0) + a.theta0
	a.day_base = math.floor((h0 + math.PI) / (2 * math.PI) + 1e-6) - 1 // +eps: старт ровно в полночь — тоже день 1
}

// Прямое восхождение «среднего солнца» (равномерно идущего по небесному экватору).
@(private = "file")
mean_sun_ra :: proc(a: ^Astro, T: f64) -> f64 {
	return a.planet.peri + a.planet.mean0 + 2 * math.PI * T / a.planet.period + math.PI - a.tilt_dir
}

// Освещённость от солнца (лк) при высоте h (градусы) — у Земли; днём — синус
// высоты, в сумерках — по точкам гражданских, навигационных и астрономических сумерек.
@(private = "file")
sun_curve :: proc(h: f64) -> f64 {
	if h >= 0 do return 400 + (SUN_LUX - 400) * math.pow(math.sin(math.to_radians(h)), 1.2)
	pts := [4][2]f64{{0, 2.6}, {-6, 0.5}, {-12, -2.1}, {-18, -3.4}}
	if h <= -18 do return 0
	for i in 0 ..< 3 {
		if h >= pts[i + 1][0] {
			t := (h - pts[i][0]) / (pts[i + 1][0] - pts[i][0])
			return math.pow(10, math.lerp(pts[i][1], pts[i + 1][1], t))
		}
	}
	return 0
}

// Площадь пересечения двух дисков (радиусы r1, r2, расстояние между центрами d).
@(private = "file")
disc_overlap :: proc(r1, r2, d: f64) -> f64 {
	if d >= r1 + r2 do return 0
	if d <= abs(r1 - r2) {
		r := min(r1, r2)
		return math.PI * r * r
	}
	a1 := math.acos(clamp((d * d + r1 * r1 - r2 * r2) / (2 * d * r1), -1, 1))
	a2 := math.acos(clamp((d * d + r2 * r2 - r1 * r1) / (2 * d * r2), -1, 1))
	return r1 * r1 * (a1 - math.sin(2 * a1) / 2) + r2 * r2 * (a2 - math.sin(2 * a2) / 2)
}

// Угол между единичными векторами (точно и для очень маленьких углов).
@(private = "file")
angle_between :: proc(a, b: [3]f64) -> f64 {
	return 2 * math.asin(clamp(len3(a - b) / 2, 0, 1))
}

// Состояние неба в момент T для игрока в точке d (единичный вектор в осях
// планеты). ex, ez — куда смотрят оси x и z кадра в этой точке (в осях планеты).
// sky — звёздное небо (свет безлунной ночи); nil — пока не готово.
astro_update :: proc(a: ^Astro, T: f64, d, ex, ez: [3]f64, sky: ^Star_Sky = nil) -> (st: Sky_State) {
	theta := a.theta0 + 2 * math.PI * T / a.sidereal
	xb := a.x0 * math.cos(theta) - a.z0 * math.sin(theta)
	zb := a.z0 * math.cos(theta) + a.x0 * math.sin(theta)
	to_body :: proc(v, xb, axis, zb: [3]f64) -> [3]f64 {return {dot3d(v, xb), dot3d(v, axis), dot3d(v, zb)}}
	to_frame :: proc(b, d, ex, ez: [3]f64) -> [3]f32 {
		f := [3]f64{dot3d(b, ex), dot3d(b, d), dot3d(b, ez)}
		f /= len3(f)
		return {f32(f.x), f32(f.y), f32(f.z)}
	}
	// оси кадра в инерциальных осях -> поворот «инерциальные -> кадр» (строки)
	axes := [3][3]f64{ex, d, ez}
	for k in 0 ..< 3 {
		e := axes[k]
		F := xb * e.x + a.axis * e.y + zb * e.z
		F /= len3(F)
		for c in 0 ..< 3 do st.inert_to_frame[k, c] = F[c]
	}
	st.uni_to_frame = st.inert_to_frame * a.uni_to_inert
	st.pole_uni = mat_t_mul(a.uni_to_inert, d.y >= 0 ? a.axis : -a.axis)

	// местный горизонт: восток, север, зенит
	east := cross3({0, 1, 0}, d)
	if len3(east) < 1e-9 do east = {1, 0, 0}
	east = norm3(east)
	north := cross3(d, east)
	st.latitude = math.to_degrees(math.asin(clamp(d.y, -1, 1)))

	// --- солнце
	p := orbit_pos(&a.planet, T)
	st.sun_dist = len3(p)
	sun_in := -p / st.sun_dist
	st.sun_body = to_body(sun_in, xb, a.axis, zb)
	st.sun_frame = to_frame(st.sun_body, d, ex, ez)
	st.sun_elev = math.to_degrees(math.asin(clamp(dot3d(st.sun_body, d), -1, 1)))
	st.sun_azim = math.to_degrees(math.atan2(dot3d(st.sun_body, east), dot3d(st.sun_body, north)))
	if st.sun_azim < 0 do st.sun_azim += 360
	st.sun_ang_r = a.star_r / (st.sun_dist * AU_KM)
	flux := a.star_lum / (st.sun_dist * st.sun_dist) // относительно Земли

	// --- луны
	observer := (xb * d.x + a.axis * d.y + zb * d.z) * a.planet_r // мы в инерциальных осях, км
	st.sun_visible = 1
	st.moon_n = a.moon_n
	moon_lux := 0.0
	for i in 0 ..< a.moon_n {
		m := &st.moons[i]
		mp := orbit_pos(&a.moons[i], T)
		rel := mp - observer
		dist := len3(rel)
		mh := rel / dist
		m.body = to_body(mh, xb, a.axis, zb)
		m.frame = to_frame(m.body, d, ex, ez)
		m.ang_r = a.moon_r[i] / dist
		m.elevation = math.to_degrees(math.asin(clamp(dot3d(m.body, d), -1, 1)))
		cos_phase := clamp(dot3d(sun_in, -mh), -1, 1) // угол «солнце — луна — мы»
		m.lit = (1 + cos_phase) / 2
		m.waxing = wrap_pi(ecl_lon(mh) - ecl_lon(sun_in)) > 0
		// тень планеты: конус тени и полутени вдоль направления от солнца
		m.shadow = 1
		if x := dot3d(mp, -sun_in); x > 0 {
			rho := len3(mp + sun_in * x)
			D := st.sun_dist * AU_KM
			umbra := a.planet_r - x * (a.star_r - a.planet_r) / D
			pen := a.planet_r + x * (a.star_r + a.planet_r) / D
			m.shadow = max(0.03, smooth(umbra - a.moon_r[i], pen + a.moon_r[i], rho))
		}
		// свет луны: как у полной Луны, с поправкой на размер, фазу, тень и высоту
		alpha := math.acos(cos_phase)
		phase_f := ((math.PI - alpha) * math.cos(alpha) + math.sin(alpha)) / math.PI
		size := (m.ang_r / EARTH_MOON_ANG) * (m.ang_r / EARTH_MOON_ANG)
		up := clamp(math.sin(math.to_radians(m.elevation)) * 2.5, 0, 1)
		m.lux = FULL_MOON_LUX * size * flux * phase_f * m.shadow * up
		moon_lux += m.lux
		// солнечное затмение: какая доля диска солнца закрыта
		if m.elevation > -5 {
			sep := angle_between(st.sun_body, m.body)
			st.sun_visible *= 1 - disc_overlap(st.sun_ang_r, m.ang_r, sep) / (math.PI * st.sun_ang_r * st.sun_ang_r)
		}
	}

	// --- другие планеты системы: блуждающие яркие точки (свет звезды, отражённый их диском)
	for i in 0 ..< a.other_n {
		q := orbit_pos(&a.others[i], T)
		rel := q - p
		dl := len3(rel)
		r := len3(q)
		alpha := math.acos(clamp(dot3d(q, rel) / (r * dl), -1, 1)) // звезда — планета — мы
		phase := max(((math.PI - alpha) * math.cos(alpha) + math.sin(alpha)) / math.PI, 1e-4)
		H := 5 * math.log10(1329 / (a.other_d[i] * math.sqrt(a.other_p[i]))) // как у планет Солнечной системы
		pl := &st.planets[i]
		pl.mag = H + 5 * math.log10(r * dl) - 2.5 * math.log10(phase) - 2.5 * math.log10(max(a.star_lum, 1e-6))
		dir := rel / dl
		pl.dir = {f32(dir.x), f32(dir.y), f32(dir.z)}
		pl.elevation = math.to_degrees(math.asin(clamp(dot3d(to_body(dir, xb, a.axis, zb), d), -1, 1)))
		pl.index = a.other_idx[i]
		switch a.other_kind[i] {
		case .Rocky:
			pl.color = {1.0, 0.86, 0.72}
		case .Gas_Giant:
			pl.color = {1.0, 0.95, 0.82}
		case .Ice_Giant:
			pl.color = {0.82, 0.95, 1.0}
		}
	}
	st.planet_n = a.other_n

	// --- свет: днём солнце, в сумерках рассеянный свет, ночью луны и звёзды
	// при полном затмении светят корона и небо за краем тени — как в глубоких сумерках
	sun_lux := sun_curve(st.sun_elev) * flux * max(st.sun_visible, 1e-5)
	// безлунная ночь: настоящие звёзды и полоса галактики (пока небо считается — средняя оценка)
	st.night_lux = sky != nil && sky.ready ? starsky_night_lux(sky, st.uni_to_frame) : NIGHT_LUX
	st.lux = sun_lux + moon_lux + st.night_lux
	// предел видимости звёзд: сумерки и лунный свет засвечивают небо
	scatter := sun_lux + 0.6 * moon_lux
	st.mag_limit = MAG_LIMIT - 1.1 * math.log10(1 + scatter / NIGHT_LUX)
	st.band_vis = f32(NIGHT_LUX / (NIGHT_LUX + scatter))
	level := clamp((math.log10(st.lux) + 3.2) / 8.2, 0, 1)
	bright := math.pow(level, 1.6)
	st.brightness = f32(bright)
	// цвет: звезда (глаз наполовину привыкает к её цвету), у горизонта — краснее;
	// в сумерках — синеватый рассеянный свет; луна — голубоватая
	star_c := [3]f64{f64(a.star_color.r), f64(a.star_color.g), f64(a.star_color.b)}
	star_c = [3]f64{1, 1, 1} * 0.65 + star_c / max(star_c.r, star_c.g, star_c.b) * 0.35
	redden := 1 - smooth(0, 12, st.sun_elev)
	sun_c := star_c * ([3]f64{1, 1, 1} * (1 - redden * 0.6) + [3]f64{1, 0.55, 0.3} * redden * 0.6)
	twilight_c := [3]f64{0.62, 0.7, 1.0}
	sun_w := st.sun_elev > 0 ? sun_lux : 0
	tw_w := st.sun_elev > 0 ? 0 : sun_lux
	col := sun_c * sun_w + twilight_c * tw_w + [3]f64{0.65, 0.75, 1.0} * moon_lux + [3]f64{0.55, 0.6, 0.85} * st.night_lux
	col /= max(col.r * 0.3 + col.g * 0.59 + col.b * 0.11, 1e-9)
	for k in 0 ..< 3 do st.light[k] = f32(min(col[k] * bright, 1))
	st.desat = f32(1 - smooth(0.03, 0.3, bright))
	st.sun_color = {f32(sun_c.r), f32(sun_c.g), f32(sun_c.b)}

	// --- цвета неба
	h := st.sun_elev
	day_k := smooth(-4, 10, h) * st.sun_visible
	tw_k := smooth(-18, -4, h) * (0.3 + 0.7 * st.sun_visible)
	moon_k := min(moon_lux / FULL_MOON_LUX, 2) * 0.5
	tint := [3]f64{1, 1, 1} * 0.75 + star_c * 0.25
	night_top := [3]f64{0.004, 0.006, 0.012} + [3]f64{0.03, 0.045, 0.09} * moon_k
	night_hor := [3]f64{0.008, 0.01, 0.02} + [3]f64{0.05, 0.065, 0.11} * moon_k
	tw_top := [3]f64{0.07, 0.1, 0.22}
	tw_hor := [3]f64{0.4, 0.33, 0.4}
	day_top := [3]f64{f64(SKY_TOP.r), f64(SKY_TOP.g), f64(SKY_TOP.b)} * tint
	day_hor := [3]f64{f64(SKY_HORIZON.r), f64(SKY_HORIZON.g), f64(SKY_HORIZON.b)} * tint
	top := math.lerp(math.lerp(night_top, tw_top, tw_k), day_top, day_k)
	hor := math.lerp(math.lerp(night_hor, tw_hor, tw_k), day_hor, day_k)
	st.sky_top = {f32(top.r), f32(top.g), f32(top.b)}
	st.sky_horizon = {f32(hor.r), f32(hor.g), f32(hor.b)}
	g := math.exp(-((h - 0.5) / 4.5) * ((h - 0.5) / 4.5)) * st.sun_visible
	if h > 0 do g += (1 - st.sun_visible) * 0.6 // затмение: горизонт светится по кругу
	gc := [3]f64{1.0, 0.42, 0.12} * 0.7 + star_c * [3]f64{1.0, 0.42, 0.12} * 0.3
	st.glow = {f32(gc.r), f32(gc.g), f32(gc.b), f32(g * 0.85)}

	// --- время: среднее местное время по долготе игрока
	lam := math.atan2(d.x, d.z) // долгота, (-PI, PI]: на 180° — линия перемены дат
	ra_mean := mean_sun_ra(a, T)
	H := lam - ra_mean + theta
	st.local_hours = math.mod(12 + H / (2 * math.PI) * 24, 24)
	if st.local_hours < 0 do st.local_hours += 24
	st.day = int(math.floor((H + math.PI) / (2 * math.PI)) - a.day_base)
	M := a.planet.mean0 + 2 * math.PI * T / a.planet.period
	fy := math.mod((M - a.m_eq) / (2 * math.PI), 1)
	if fy < 0 do fy += 1
	st.day_of_year = int(fy * a.year_days) + 1
	ls := math.mod(ecl_lon(sun_in) - (a.tilt_dir - math.PI / 2), 2 * math.PI)
	if ls < 0 do ls += 2 * math.PI
	st.season = min(int(ls / (math.PI / 2)), 3)

	// восход и закат сегодня. Склонение солнца берётся на момент самого
	// события: на планетах с коротким годом оно заметно меняется за день.
	decl := math.asin(clamp(dot3d(sun_in, a.axis), -1, 1))
	st.decl = math.to_degrees(decl)
	phi := math.to_radians(st.latitude)
	h0 := -math.to_radians(0.57) - st.sun_ang_r // край диска с рефракцией
	ra_sun := math.atan2(dot3d(sun_in, a.x0), dot3d(sun_in, a.z0))
	noon := 12 - wrap_pi(ra_mean - ra_sun) / (2 * math.PI) * 24 // уравнение времени
	half, polar := half_day(phi, decl, h0)
	st.polar, st.day_length = polar, 2 * half
	st.sunrise, st.sunset = -1, -1
	if polar == 0 {
		// местные часы -> стандартные часы от «сейчас» (ближайшее событие)
		offset :: proc(a: ^Astro, local_dt: f64) -> f64 {
			return (math.mod(local_dt + 36, 24) - 12) * a.day / 24
		}
		rise_d, set_d := decl, decl
		for _ in 0 ..< 3 {
			hr, _ := half_day(phi, rise_d, h0)
			hs, _ := half_day(phi, set_d, h0)
			rise_d = sun_decl_at(a, T + offset(a, noon - hr - st.local_hours))
			set_d = sun_decl_at(a, T + offset(a, noon + hs - st.local_hours))
		}
		hr, pr := half_day(phi, rise_d, h0)
		hs, ps := half_day(phi, set_d, h0)
		if pr == 0 do st.sunrise = math.mod(noon - hr + 24, 24)
		if ps == 0 do st.sunset = math.mod(noon + hs + 24, 24)
		st.day_length = hr + hs
	}
	return
}

// Половина дня (местных часов) при склонении солнца decl на широте phi;
// polar: 1 — солнце не заходит, -1 — не восходит.
@(private = "file")
half_day :: proc(phi, decl, h0: f64) -> (half: f64, polar: int) {
	c := (math.sin(h0) - math.sin(phi) * math.sin(decl)) / (math.cos(phi) * math.cos(decl))
	if c < -1 do return 12, 1
	if c > 1 do return 0, -1
	return math.acos(c) / (2 * math.PI) * 24, 0
}

// Склонение солнца (рад) в момент T.
@(private = "file")
sun_decl_at :: proc(a: ^Astro, T: f64) -> f64 {
	p := orbit_pos(&a.planet, T)
	return math.asin(clamp(-dot3d(p, a.axis) / len3(p), -1, 1))
}

// Небо для точки pos кадра: направление от центра планеты и куда смотрят оси x, z кадра.
astro_sky_at :: proc(a: ^Astro, g: ^Planet_Geo, pos: [3]f64, T: f64, sky: ^Star_Sky = nil) -> Sky_State {
	d := geo_frame_dir(g, pos.x, pos.z)
	ex := norm3(geo_frame_dir(g, pos.x + 8, pos.z) - d)
	ez := norm3(geo_frame_dir(g, pos.x, pos.z + 8) - d)
	return astro_update(a, T, d, ex, ez, sky)
}

SEASON_NAMES := [4]string{"весна", "лето", "осень", "зима"}

// Фаза луны словами.
moon_phase_name :: proc(m: ^Sky_Moon) -> string {
	switch {
	case m.lit < 0.03:
		return "новолуние"
	case m.lit > 0.97:
		return "полнолуние"
	case abs(m.lit - 0.5) < 0.07:
		return m.waxing ? "первая четверть" : "последняя четверть"
	case m.lit < 0.5:
		return m.waxing ? "растущий серп" : "убывающий серп"
	}
	return m.waxing ? "растущая" : "убывающая"
}
