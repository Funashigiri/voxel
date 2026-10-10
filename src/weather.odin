package main

// Погода (0.017): колебания вокруг климата места (climate.odin).
//
// Над планетой ходят погодные системы — циклоны с фронтами и антициклоны в
// тысячи километров. Их несёт ветер на высоте: в средних широтах — с запада, в
// тропиках — с востока; узор живёт несколько суток и плавно сменяется новым.
// Летом и в тропиках днём от нагрева растут кучевые облака, и после полудня
// идут ливни. Узор — шум на шаре; где он выше порога — пасмурно или идут
// осадки. Пороги подобраны по распределению самого узора так, что за месяц в
// каждом месте выпадает ровно столько, сколько даёт климат; сила дождя — как у
// настоящих дождей при такой температуре. Давление — по узору, ветер у земли —
// из перепада давления (геострофический, у земли слабее и повёрнут к
// циклону) и общей циркуляции. Всё — от зерна мира и времени: в тот же момент
// та же погода.

import "core:math"
import "core:slice"
import eng "engine"

WX_PRESS_SCALE :: 4.0e6 // м: узор давления — циклоны и антициклоны в 1000–2000 км
WX_SYN_SCALE :: 2.0e6 // м: узор осадков систем и фронтов (мельче)
WX_SYN_LIFE :: 77.3 // ч: сколько живёт узор погодных систем (не кратно суткам)
WX_CONV_SCALE :: 12_000.0 // м: размер ливневых ячеек
WX_CONV_LIFE :: 2.71 // ч: ливневая ячейка (не кратно суткам)
WX_HOURS_PER_MONTH :: EARTH_YEAR_HOURS / 12 // климат даёт осадки в мм за 1/12 земного года — это темп
WX_Q :: 2048 // ступеней в таблице распределения узора (хвост — до 1/2000)

Weather_Model :: struct {
	seed:      i64,
	radius:    f64, // м
	omega:     f64, // вращение планеты, рад/с
	rho:       f64, // плотность воздуха у поверхности, кг/м³
	press0:    f64, // давление у моря, гПа
	day_h:     f64, // солнечные сутки, ст. ч
	hadley:    f64, // край тропиков, °
	storm:     f64, // пояс циклонов, °
	q_syn:     [WX_Q + 1]f64, // узор систем: значение, ниже которого доля k/WX_Q
	tail_syn:  [WX_Q + 1]f64, // средний перебор над этим значением
	q_conv:    [WX_Q + 1]f64,
	tail_conv: [WX_Q + 1]f64,
	sd_p:      f64, // разброс узора давления
	mid_p:     f64,
	sd_f:      f64, // разброс узора фронтов
	mid_f:     f64,
	wave:      f64, // среднее exp(1,2·S) — чтобы «волны» ливней не меняли сумм
}

WX_FLASH_K :: 0.016 // молний на км² на (мм ливня × кДж/кг неустойчивости) — по числу гроз на станциях

// Климат места на этот момент года.
Wx_Local :: struct {
	lat:     f64, // °
	t:       f64, // средняя температура (месяца) здесь, °C
	p:       f64, // осадки, мм за 1/12 земного года
	dry:     f64, // сухость 0..1 (суточный ход температуры)
	sea_t:   f64, // море на этой широте, °C (слоистые облака над холодным морем)
	land:    bool,
	alt:     f64, // высота над морем, м
	cont:    f64, // материковость 0..1: в глубине материка морозы и жара сильнее
	dtdlat:  f64, // ход температуры к северу, К на градус широты (ветер несёт тепло и холод)
	rh:      f64, // влажность воздуха по климату (при средней температуре), 0..1
	sun:     f64, // среднесуточный свет у верха атмосферы, Вт/м²
	pool:    f64, // насколько холоднее ясной тихой ночью в низине (холодный воздух стекает вниз), К
	onshore: [2]f64, // направление с моря на это место (восток, север); длина — близость берега (1 — у воды)
	snow:    f64, // доля земли под снегом (оттепельные туманы над снегом)
}

Fog_Kind :: enum u8 {
	None,
	Radiation, // радиационный: ясная тихая ночь, остывший воздух у земли
	Sea, // морской (адвективный): тёплый влажный воздух над холодным морем
	Steam, // парение: мороз над открытой водой
	Thaw, // оттепельный: тёплый влажный воздух над снегом
	Cloud, // низкие облака лежат на земле
}

Weather_Point :: struct {
	cover:      f64, // облачность над точкой, 0..1
	storm:      f64, // облака дождевые и грозовые — толще и темнее, 0..1
	rain:       f64, // осадки, мм/ч (в пересчёте на воду)
	conv:       f64, // из них ливневых, мм/ч
	snow:       f64, // доля снега в осадках (0 — дождь, 1 — снег)
	t_air:      f64, // температура воздуха сейчас, °C
	t_anom:     f64, // отклонение от климата из-за погоды (тепло и холод с ветром), К
	td:         f64, // точка росы, °C
	rh:         f64, // влажность сейчас, 0..1
	press:      f64, // давление у моря, гПа
	syn:        f64, // узор систем в «сигмах»: больше нуля — циклон, меньше — антициклон
	wind:       [2]f64, // ветер у земли: на восток и на север, м/с
	gust:       f64, // порывы, м/с
	fog:        f64, // туман у земли: ослабление света, 1/м (0 — нет)
	fog_depth:  f64, // толщина слоя тумана, м
	fog_kind:   Fog_Kind,
	cloud_base: f64, // нижняя кромка облаков над морем, м (по точке росы)
	flash:      f64, // молний на км² в час
	cape:       f64, // энергия неустойчивости, Дж/кг
}

// Климат места cp на сезон s для погоды (сухость — по осадкам месяца и теплу).
wx_local_of :: proc(cm: ^Climate, cp: ^Climate_Point, s: f64) -> Wx_Local {
	t, p := climate_at(cm, cp, s)
	aridity := p * 12 / max(20 * max(t, 0) + 280, 100)
	n, sth := cp^, cp^
	n.lat = min(cp.lat + 1, 89)
	sth.lat = max(cp.lat - 1, -89)
	tn, _ := climate_at(cm, &n, s)
	ts, _ := climate_at(cm, &sth, s)
	return {
		lat = cp.lat, t = t, p = p, dry = clamp(1.5 - aridity, 0, 1), land = cp.land, alt = cp.alt, cont = cp.cont,
		sea_t = climate_sea_t(cm, cp.lat, s), dtdlat = (tn - ts) / (n.lat - sth.lat), rh = wx_rh_clim(t, p, cp.cont, climate_sea_t(cm, cp.lat, s), cp.land),
		sun = climate_daily_sun(cm, cp.lat, s),
	}
}

// Насыщенное давление пара над водой, гПа (Магнус).
wx_esat :: proc "contextless" (t: f64) -> f64 {
	return 6.112 * math.exp(17.62 * t / (243.12 + t))
}

// Точка росы по давлению пара e, гПа.
wx_dew :: proc "contextless" (e: f64) -> f64 {
	l := math.ln(max(e, 1e-3) / 6.112)
	return 243.12 * l / (17.62 - l)
}

// Влажность по климату. Над морем — 78–90% (над холодным выше). На суше — по
// тому, хватает ли осадков на испарение (испаряемость ~6 мм в месяц на градус
// тепла): в пустыне ~30%, где осадков вдвое больше испаряемости, — ~80%. В
// мороз воздух насыщен надо льдом и снегом — это 75–90% от насыщения над
// водой (как и меряют станции). У моря воздух морской.
wx_rh_clim :: proc(t, p, cont, sea_t: f64, land: bool) -> f64 {
	sea := 0.9 - 0.12 * wsmooth(0, 25, sea_t)
	if !land do return sea
	ratio := max(p, 0) / max(6 * max(t, 0), 5)
	rh := 0.25 + 0.62 * (1 - math.exp(-1.8 * ratio))
	if t < 0 do rh = max(rh, 0.92 * wx_ice_ratio(t))
	return rh + (sea - rh) * (1 - clamp(cont, 0, 1))
}

// Насыщение надо льдом относительно насыщения над водой (ниже нуля).
wx_ice_ratio :: proc "contextless" (t: f64) -> f64 {
	return math.exp(0.0097 * min(t, 0))
}

@(private = "file")
wsmooth :: proc(e0, e1, x: f64) -> f64 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}

// Поворот точки d вокруг оси планеты на угол a (рад) к востоку.
@(private = "file")
rot_east :: proc(d: [3]f64, a: f64) -> [3]f64 {
	c, s := math.cos(a), math.sin(a)
	return {d.x * c + d.z * s, d.y, d.z * c - d.x * s}
}

// Ветер на высоте ~5 км, что несёт погодные системы, м/с на восток.
wx_steer :: proc(wm: ^Weather_Model, lat: f64) -> f64 {
	al := abs(lat)
	return -5 + 17 * wsmooth(wm.hadley - 5, wm.hadley + 8, al) - 15 * wsmooth(wm.storm + 10, wm.storm + 30, al)
}

// Средний ветер у земли, м/с (на восток, на север): пассаты с востока к
// экватору, в средних широтах — с запада, у полюсов — снова с востока.
wx_mean_wind :: proc(wm: ^Weather_Model, lat: f64) -> [2]f64 {
	al := abs(lat)
	sg := lat < 0 ? -1.0 : 1.0
	west := wsmooth(wm.hadley - 5, wm.hadley + 8, al)
	polar := wsmooth(wm.storm + 10, wm.storm + 30, al)
	// у экватора — полоса затишья (пассаты сходятся), сильнее всего они на 10–20°
	u := -6 * (0.3 + 0.7 * wsmooth(0, 10, al)) + 12 * west - 9 * polar
	v := -sg * 2.5 * (1 - west) * wsmooth(2, 8, al) + sg * 1.0 * west * (1 - polar)
	return {u, v}
}

// Узор в точке d (единичный вектор) в момент t_h (ч): шум на шаре, сносимый
// ветром steer; каждые life часов узор плавно сменяется новым (два узора со
// сдвигом на полжизни, вес каждого — sin² от его возраста).
@(private = "file")
wx_field :: proc(wm: ^Weather_Model, d: [3]f64, t_h, scale, life: f64, octaves: int, salt: i64, steer: f64) -> f64 {
	cosl := max(math.sqrt(d.x * d.x + d.z * d.z), 0.2)
	sum, w2 := 0.0, 0.0
	for k in 0 ..< 2 {
		phase := t_h / life + 0.5 * f64(k)
		n := math.floor(phase)
		age := phase - n
		w := math.sin(math.PI * age)
		w *= w
		src := rot_east(d, -steer * age * life * 3600 / (wm.radius * cosl))
		// у каждого узора свой сдвиг в шуме: точка не смотрит всё время в один срез решётки
		ps := wm.seed + salt + i64(n) * 15485863 + i64(k) * 7919
		h := eng.hash2(i32(ps & 0x7fffffff), i32(ps >> 31), 77)
		shift := [3]f64{f64(h & 1023), f64((h >> 10) & 1023), f64((h >> 20) & 1023)} * (scale * 0.137)
		v := f64(fbm(ps, src * wm.radius + shift, scale, octaves))
		sum += w * v
		w2 += w * w
	}
	return sum / math.sqrt(max(w2, 1e-9))
}

// Узор давления: крупный и плавный, как у настоящего (больше — ниже давление).
@(private = "file")
wx_press :: proc(wm: ^Weather_Model, d: [3]f64, t_h: f64) -> f64 {
	lat := math.to_degrees(math.asin(clamp(d.y, -1, 1)))
	return wx_field(wm, d, t_h, WX_PRESS_SCALE, WX_SYN_LIFE, 1, 9001, wx_steer(wm, lat))
}

// Узор осадков систем: в циклонах (низкое давление) чаще, плюс полосы фронтов.
@(private = "file")
wx_syn :: proc(wm: ^Weather_Model, d: [3]f64, t_h: f64) -> f64 {
	lat := math.to_degrees(math.asin(clamp(d.y, -1, 1)))
	fr := wx_field(wm, d, t_h, WX_SYN_SCALE, WX_SYN_LIFE, 3, 9201, wx_steer(wm, lat))
	return 0.6 * (wx_press(wm, d, t_h) - wm.mid_p) / wm.sd_p + 0.8 * (fr - wm.mid_f) / wm.sd_f
}

@(private = "file")
wx_conv :: proc(wm: ^Weather_Model, d: [3]f64, t_h: f64) -> f64 {
	lat := math.to_degrees(math.asin(clamp(d.y, -1, 1)))
	return wx_field(wm, d, t_h, WX_CONV_SCALE, WX_CONV_LIFE, 2, 9101, wx_steer(wm, lat) * 0.6)
}

// Значение узора, выше которого он бывает в доле f мест и времени, и средний перебор над ним.
@(private = "file")
quantile :: proc(q, tail: ^[WX_Q + 1]f64, f: f64) -> (s, excess: f64) {
	x := clamp(1 - f, 0, 1) * WX_Q
	i := min(int(x), WX_Q - 1)
	g := x - f64(i)
	return math.lerp(q[i], q[i + 1], g), max(math.lerp(tail[i], tail[i + 1], g), 1e-6)
}

weather_init :: proc(wm: ^Weather_Model, seed: u32, radius_km, sidereal_h, day_h, rho, pressure_bar: f64, cm: ^Climate) {
	wm.seed = i64(seed) * 31 + 17
	wm.radius = radius_km * 1000
	wm.omega = math.TAU / (sidereal_h * 3600)
	wm.rho = max(rho, 0.01)
	wm.press0 = pressure_bar * 1013.25
	wm.day_h = day_h
	wm.hadley = cm.hadley
	wm.storm = cm.storm
	// распределение узоров: по случайным местам и временам
	N :: 120_000
	syn := make([]f64, N, context.temp_allocator)
	conv := make([]f64, N, context.temp_allocator)
	pr := make([]f64, N, context.temp_allocator)
	ds := make([][3]f64, N, context.temp_allocator)
	ts := make([]f64, N, context.temp_allocator)
	r := eng.rng_make(u64(seed) * 0x2545F491 + 3)
	p_sum, p_sum2, f_sum, f_sum2 := 0.0, 0.0, 0.0, 0.0
	for i in 0 ..< N {
		z := eng.rng_range(&r, -1, 1)
		a := eng.rng_range(&r, 0, math.TAU)
		s := math.sqrt(1 - z * z)
		ds[i] = {s * math.cos(a), z, s * math.sin(a)}
		ts[i] = eng.rng_range(&r, 0, 50_000)
		lat := math.to_degrees(math.asin(z))
		pr[i] = wx_press(wm, ds[i], ts[i])
		syn[i] = wx_field(wm, ds[i], ts[i], WX_SYN_SCALE, WX_SYN_LIFE, 3, 9201, wx_steer(wm, lat))
		conv[i] = wx_conv(wm, ds[i], ts[i])
		p_sum += pr[i]
		p_sum2 += pr[i] * pr[i]
		f_sum += syn[i]
		f_sum2 += syn[i] * syn[i]
	}
	wm.mid_p = p_sum / N
	wm.sd_p = math.sqrt(max(p_sum2 / N - wm.mid_p * wm.mid_p, 1e-12))
	wm.mid_f = f_sum / N
	wm.sd_f = math.sqrt(max(f_sum2 / N - wm.mid_f * wm.mid_f, 1e-12))
	for i in 0 ..< N do syn[i] = 0.6 * (pr[i] - wm.mid_p) / wm.sd_p + 0.8 * (syn[i] - wm.mid_f) / wm.sd_f
	wm.wave = 0
	for v in syn do wm.wave += math.exp(1.2 * clamp(v, -4, 4)) / N
	table :: proc(v: []f64, q, tail: ^[WX_Q + 1]f64) {
		slice.sort(v)
		n := len(v)
		// суммы сверху: средний перебор над k-й ступенью
		suffix := make([]f64, n + 1, context.temp_allocator)
		for i := n - 1; i >= 0; i -= 1 do suffix[i] = suffix[i + 1] + v[i]
		for k in 0 ..= WX_Q {
			i := min(k * n / WX_Q, n - 1)
			q[k] = v[i]
			cnt := f64(n - i)
			tail[k] = suffix[i] / cnt - v[i]
		}
	}
	table(syn, &wm.q_syn, &wm.tail_syn)
	table(conv, &wm.q_conv, &wm.tail_conv)
}

// Время погоды, ч: от начала года планеты — одно и то же, с какого дня ни начать.
weather_time :: proc(a: ^Astro, T: f64) -> f64 {
	return a.planet.mean0 / math.TAU * a.planet.period + T
}

// Давление и ветер у земли в точке d.
@(private = "file")
wx_wind :: proc(wm: ^Weather_Model, d: [3]f64, loc: ^Wx_Local, t_h: f64, w: ^Weather_Point) -> (geo: [2]f64) {
	// давление: в циклоне ниже, в антициклоне выше; в тропиках перепады малы
	pc := wx_press(wm, d, t_h)
	w.syn = (pc - wm.mid_p) / wm.sd_p
	trop := 0.15 + 0.85 * wsmooth(10, 50, abs(loc.lat)) // разброс давления растёт к полярному фронту
	w.press = wm.press0 * (1 - 0.012 * w.syn * trop)
	// ветер: средний по широте + из перепада давления (у земли ~0,6 от
	// геострофического и повёрнут на 25° к низкому давлению)
	w.wind = wx_mean_wind(wm, loc.lat)
	east := [3]f64{d.z, 0, -d.x}
	el := math.sqrt(east.x * east.x + east.z * east.z)
	east = el > 1e-6 ? east / el : {1, 0, 0}
	north := [3]f64{d.y * east.z - d.z * east.y, d.z * east.x - d.x * east.z, d.x * east.y - d.y * east.x}
	h := 60_000.0 / wm.radius
	dp := wm.press0 * 0.012 * trop * 100 / wm.sd_p // Па на единицу узора
	sx := wx_press(wm, d + east * h, t_h) - pc
	sy := wx_press(wm, d + north * h, t_h) - pc
	gx := -dp * sx / (h * wm.radius) // ∂p/∂x (на восток), Па/м: высокий узор — низкое давление
	gy := -dp * sy / (h * wm.radius)
	sl := math.sin(math.to_radians(loc.lat))
	f := 2 * wm.omega * (abs(sl) < 0.17 ? (sl < 0 ? -0.17 : 0.17) : sl)
	vg := [2]f64{-gy, gx} / (wm.rho * f)
	ang := math.to_radians(f64(f > 0 ? 25 : -25))
	ca, sa := math.cos(ang), math.sin(ang)
	geo = [2]f64{vg.x * ca - vg.y * sa, vg.x * sa + vg.y * ca} * 0.6 * wsmooth(8, 20, abs(loc.lat))
	if l := math.sqrt(geo.x * geo.x + geo.y * geo.y); l > 25 do geo *= 25 / l
	w.wind += geo
	// у земли ветер тормозит о сушу: над лесами и полями в глубине материка он вдвое слабее, чем над морем
	if loc.land do w.wind *= 1 - 0.45 * loc.cont
	return
}

// Молний на км² в час (Romps и др., 2014: ∝ ливень × неустойчивость). Порог:
// ливень сильнее ~5 мм/ч и CAPE больше ~500 Дж/кг. Молнии
// рождаются в столкновениях крупы и льдинок — нужны сильный ливень (крупные
// капли и лёд, слабые дожди из тёплых облаков без них) и заметная
// неустойчивость (CAPE).
wx_flash_rate :: proc "contextless" (conv, cape: f64, land: bool) -> f64 {
	c := max(conv - 5, 0)
	return WX_FLASH_K * c * max(cape - 500, 0) / 1000 * (land ? 1 : 0.15)
}

// Ливни идут волнами: в погодных системах (у фронтов, в тропических волнах)
// воздух неустойчив и ливней много, между ними — затишье на дни. Множитель
// к доле ливней по узору систем S; в среднем — 1 (за месяц выпадает столько же).
@(private = "file")
wx_conv_wave :: proc(wm: ^Weather_Model, S: f64) -> f64 {
	return math.exp(1.2 * clamp(S, -4, 4)) / wm.wave
}

// Только ливни в точке d, мм/ч — как в weather_at (для подсчёта гроз вокруг станции).
wx_conv_rain :: proc(wm: ^Weather_Model, d: [3]f64, loc: ^Wx_Local, t_h, hour: f64) -> f64 {
	T := loc.t
	P := max(loc.p, 0) / WX_HOURS_PER_MONTH
	conv := clamp(0.1 + 0.75 * wsmooth(4, 24, T), 0, 0.9)
	i_c := clamp(4.5 * math.exp(0.06 * (T - 20)), 1.5, 30)
	day := math.TAU / 24
	diurnal := loc.land ? 1 + 0.9 * math.cos((hour - 16) * day) : 1 + 0.3 * math.cos((hour - 5) * day)
	f_c := P * conv * diurnal * wx_conv_wave(wm, wx_syn(wm, d, t_h)) / i_c
	if f_c > 0.4 {
		i_c *= f_c / 0.4
		f_c = 0.4
	}
	if f_c <= 1e-5 do return 0
	C := wx_conv(wm, d, t_h)
	s0, ex := quantile(&wm.q_conv, &wm.tail_conv, f_c)
	return C > s0 ? i_c * (C - s0) / ex : 0
}

// Погода в точке d (единичный вектор) в момент t_h (ч) при местном времени hour (ч).
weather_at :: proc(wm: ^Weather_Model, d: [3]f64, loc_in: Wx_Local, t_h, hour: f64) -> (w: Weather_Point) {
	loc := loc_in
	T := loc.t
	P := max(loc.p, 0) / WX_HOURS_PER_MONTH // мм/ч в среднем
	day := math.TAU / 24
	geo := wx_wind(wm, d, &loc, t_h, &w)
	// над сушей ночью выхоложенный слой у земли отрывается от ветра выше —
	// ночи тише, днём солнце перемешивает воздух и ветер крепчает
	if loc.land do w.wind *= 0.7 + 0.5 * max(0, math.cos((hour - 14) * day))
	speed := math.sqrt(w.wind.x * w.wind.x + w.wind.y * w.wind.y)
	// доля ливней: в тропиках и летом почти все осадки ливневые, зимой — обложные
	conv := clamp(0.1 + 0.75 * wsmooth(4, 24, T), 0, 0.9)
	// средняя сила, пока идёт: обложной слабее, ливень сильнее; в тёплом воздухе больше влаги
	i_s := clamp(1.0 * math.exp(0.06 * (T - 10)), 0.08, 4)
	i_c := clamp(4.5 * math.exp(0.06 * (T - 20)), 1.5, 30)
	// ливни над сушей — после полудня, над морем — под утро
	diurnal := loc.land ? 1 + 0.9 * math.cos((hour - 16) * day) : 1 + 0.3 * math.cos((hour - 5) * day)
	f_s := P * (1 - conv) / i_s
	if f_s > 0.3 {
		i_s *= f_s / 0.3
		f_s = 0.3
	}
	S := wx_syn(wm, d, t_h)
	f_c := P * conv * diurnal * wx_conv_wave(wm, S) / i_c
	if f_c > 0.4 {
		i_c *= f_c / 0.4
		f_c = 0.4
	}
	C := wx_conv(wm, d, t_h)
	if f_s > 1e-5 {
		s0, ex := quantile(&wm.q_syn, &wm.tail_syn, f_s)
		if S > s0 do w.rain += i_s * (S - s0) / ex
	}
	if f_c > 1e-5 {
		s0, ex := quantile(&wm.q_conv, &wm.tail_conv, f_c)
		if C > s0 do w.conv = i_c * (C - s0) / ex
		w.rain += w.conv
	}
	// облачность: пасмурно в системах; в ясную погоду — кучевые (днём над сушей больше).
	// Сколько пасмурно — по влажности воздуха: осадки относительно влаги, что
	// воздух держит при этой температуре (Клаузиус — Клапейрон, ~7% на градус).
	// В холоде воздух насыщен уже при малых осадках — в тундре пасмурно.
	rh := loc.p / (30 * math.exp(0.07 * (T - 10)))
	f_cloud := clamp(0.08 + 0.72 * wsmooth(0.1, 1.6, rh), 0.05, 0.8)
	// тёплый воздух над морем у точки замерзания остывает до насыщения — слоистые
	// облака и туманы (лето в Арктике — самое пасмурное время года)
	stratus := 0.85 * clamp((T - loc.sea_t) / 4, 0, 1) * wsmooth(6, 0, loc.sea_t)
	f_cloud = 1 - (1 - f_cloud) * (1 - stratus)
	humid := wsmooth(10, 120, loc.p)
	heat := max(0, math.cos((hour - 14) * day))
	fair := clamp(0.05 + 0.3 * humid * (loc.land ? 0.3 + 0.7 * heat : 0.6), 0.03, 0.45)
	f_ov := clamp((f_cloud - fair) / (0.95 - fair), min(1.5 * f_s + 0.02, 0.9), 0.9)
	s_ov, _ := quantile(&wm.q_syn, &wm.tail_syn, f_ov)
	band := 0.3 * (wm.q_syn[WX_Q * 84 / 100] - wm.q_syn[WX_Q * 16 / 100]) // край облачного поля — размытый
	// в антициклоне нисходящий воздух гасит кучевку — там бывает совсем ясно
	s_hi, _ := quantile(&wm.q_syn, &wm.tail_syn, 0.7)
	fair *= 0.1 + 0.9 * wsmooth(s_hi - band, s_hi + band, S)
	w.cover = fair + (0.95 - fair) * wsmooth(s_ov - band, s_ov + band, S)
	s_r, ex_r := quantile(&wm.q_syn, &wm.tail_syn, max(f_s, 1e-4))
	w.storm = 0.75 * wsmooth(s_ov, s_r + 0.5 * ex_r, S)
	// кучевые башни вокруг ливневых ячеек
	if f_c > 1e-5 {
		s_t, _ := quantile(&wm.q_conv, &wm.tail_conv, min(3 * f_c, 0.9))
		s_c, ex_c := quantile(&wm.q_conv, &wm.tail_conv, f_c)
		cell := wsmooth(s_t, s_c, C)
		w.cover += (0.95 - w.cover) * cell
		w.storm = max(w.storm, wsmooth(s_c - 0.3 * ex_c, s_c + ex_c, C))
	}
	w.gust = speed * 1.5 + 10 * wsmooth(0.5, 8, w.conv)
	// тепло и холод приносит ветер: южный (в северном полушарии) — воздух
	// оттуда, где теплее, на столько, сколько он прошёл, пока «помнит», откуда
	// пришёл: под сильным солнцем — сутки, в полярную ночь — трое (Солнце
	// быстро переделывает воздух под место). Над морем вода гасит перепады, в
	// тропиках воздух однороден. Зимой в антициклоне над материком ясные ночи
	// выхолаживают воздух неделями (сибирские морозы).
	grad := loc.dtdlat / (wm.radius * math.PI / 180) // К/м к северу
	tau := 86400 * (1 + 2 * math.exp(-loc.sun / 150))
	adv := wsmooth(wm.hadley - 12, wm.hadley + 5, abs(loc.lat))
	w.t_anom = -tau * geo.y * grad * (0.4 + 0.6 * loc.cont) * adv
	winter := wsmooth(5, -15, T) * (loc.land ? loc.cont : 0)
	w.t_anom -= 4 * winter * (max(-w.syn, 0) - 0.4)
	// облака: днём заслоняют солнце — пасмурный день прохладнее; без солнца
	// (зимой у полюса) укрывают землю — в пасмурную погоду теплее на градусы
	sunk := 1 - math.exp(-loc.sun / 150)
	w.t_anom -= (3 * sunk - 10 * (1 - sunk) * (loc.land ? 1 : 0.3)) * (w.cover - f_cloud)
	// без солнца в тишь у земли застаивается выхоложенный воздух (инверсия), ветер
	// его перемешивает с тёплым сверху
	if loc.land do w.t_anom += 8 * (1 - sunk) * wsmooth(5, -15, T) * (wsmooth(1, 8, speed) - 0.5)
	w.t_anom = clamp(w.t_anom, -25, 25)
	// температура: суточный ход, под облаками он меньше
	// суточный ход греет солнце: в полярную ночь остаётся меньше половины
	amp := (4 + 9 * loc.dry) * (1 - 0.6 * w.cover) * clamp(math.sqrt(wm.day_h / 24), 0.6, 2.5) * (0.45 + 0.55 * wsmooth(0, 300, loc.sun))
	t_day := T + w.t_anom // среднесуточная сегодня
	w.t_air = t_day + amp / 2 * math.cos((hour - 15) * day)
	w.snow = wsmooth(2, 0, w.t_air)

	// влажность: пара в воздухе за сутки почти столько же — ночью, когда
	// холодает, влажность растёт. В циклоне и под облаками воздух влажнее, в
	// антициклоне — суше, в дожде — насыщен.
	hum := loc.rh
	moist := wsmooth(s_ov - band, max(s_r, s_ov) + band, S)
	hum += (0.95 - hum) * (0.6 * moist + 0.4 * wsmooth(0.05, 2, w.rain))
	hum *= 1 - 0.3 * wsmooth(10, 40, abs(loc.lat)) * wsmooth(0.3, 1.5, -w.syn) * (1 - moist)
	if t_day < 0 do hum = min(hum, 0.98 * wx_ice_ratio(t_day)) // лишний пар оседает инеем
	w.td = wx_dew(clamp(hum, 0.05, 1) * wx_esat(t_day))
	w.td = min(w.td, w.t_air)
	w.rh = wx_esat(w.td) / wx_esat(w.t_air)
	// нижняя кромка облаков: на столько выше, насколько воздух теплее точки
	// росы (~125 м на градус), и не ниже ~150 м — под облаками воздух
	// перемешан и подсушен (капли дождя испаряются); высота — над морем
	w.cloud_base = loc.alt + 150 + 125 * max(w.t_air - w.td, 0)

	// туман
	calm := wsmooth(3.5, 1, speed)
	// радиационный: к утру в ясную тихую ночь воздух у земли остывает сильнее
	// среднего (в низинах — ещё сильнее) до точки росы; после восхода, пока
	// воздух не прогреется, туман держится (температура — с запаздыванием)
	lag := (hour - 2.5 - 15) * day
	t_lag := t_day + amp / 2 * math.cos(lag)
	night := max(-math.cos(lag), 0)
	cool := (0.3 + loc.pool) * (1 - w.cover) * calm * night
	if loc.land {
		// сначала пар оседает росой (на траве), туман — когда воздух остыл на
		// градус ниже точки росы; в мороз пар оседает инеем на снег и лёд —
		// воздух сохнет, туманов мало
		x := wsmooth(-0.8, -2.8, t_lag - cool - w.td) * wsmooth(-10, -1, t_lag)
		if x > 0.03 && w.rain < 0.3 {
			w.fog = x
			w.fog_kind = .Radiation
			w.fog_depth = 30 + 220 * x
		}
	}
	// морской: влажный воздух теплее моря остывает над водой до насыщения;
	// парение: мороз над открытой (незамёрзшей) водой. На берег туман заносит
	// ветер с моря (днём суша прогревает его и рассеивает).
	if loc.sea_t > -1.0 {
		x := wsmooth(0.2, 2.5, w.td - loc.sea_t) * wsmooth(16, 9, speed) * wsmooth(0.5, 2, speed)
		xs := wsmooth(8, 18, loc.sea_t - w.t_air)
		if loc.land {
			on := clamp((loc.onshore.x * w.wind.x + loc.onshore.y * w.wind.y) / 3, 0, 1)
			x *= on * (1 - 0.7 * heat)
			xs *= on * 0.5
		}
		if x > 0.03 && x > w.fog {
			w.fog = x
			w.fog_kind = .Sea
			w.fog_depth = 100 + 300 * x
		}
		if xs > 0.03 && xs > w.fog {
			w.fog = xs
			w.fog_kind = .Steam
			w.fog_depth = 20 + 100 * xs
		}
	}
	// оттепельный: тёплый влажный воздух остывает над снегом (поверхность не
	// теплее нуля) — как над холодным морем; зимой и весной в оттепели
	if loc.land && loc.snow > 0.05 {
		x := wsmooth(1, 4, w.td) * wsmooth(12, 6, speed) * clamp(loc.snow, 0, 1) * (1 - 0.7 * heat)
		if x > 0.03 && x > w.fog {
			w.fog = x
			w.fog_kind = .Thaw
			w.fog_depth = 50 + 200 * x
		}
	}
	// в тумане видно от ~1 км (только лёг) до ~100 м (густой): ослабление 3,9/видимость
	if w.fog > 0 do w.fog = 3.912 / (1000 * math.exp(-2.3 * w.fog))

	// молнии (Romps и др., 2014): частота ∝ ливень × энергия неустойчивости
	// (CAPE); она растёт с влагой у земли. Над морем восходящие потоки слабее —
	// молний на тот же дождь в разы меньше.
	w.cape = 3000 * wsmooth(5, 22, w.td) * (loc.land ? 1 : 0.6)
	w.flash = wx_flash_rate(w.conv, w.cape, loc.land)
	return
}
