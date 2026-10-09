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
}

// Климат места на этот момент года.
Wx_Local :: struct {
	lat:  f64, // °
	t:    f64, // средняя температура (месяца) здесь, °C
	p:    f64, // осадки, мм за 1/12 земного года
	dry:  f64, // сухость 0..1 (суточный ход температуры)
	sea_t: f64, // море на этой широте, °C (слоистые облака над холодным морем)
	land: bool,
}

Weather_Point :: struct {
	cover:  f64, // облачность над точкой, 0..1
	storm:  f64, // облака дождевые и грозовые — толще и темнее, 0..1
	rain:   f64, // осадки, мм/ч (в пересчёте на воду)
	conv:   f64, // из них ливневых, мм/ч
	snow:   f64, // доля снега в осадках (0 — дождь, 1 — снег)
	t_air:  f64, // температура воздуха сейчас, °C
	press:  f64, // давление у моря, гПа
	syn:    f64, // узор систем в «сигмах»: больше нуля — циклон, меньше — антициклон
	wind:   [2]f64, // ветер у земли: на восток и на север, м/с
	gust:   f64, // порывы, м/с
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
	u := -6 + 12 * west - 9 * polar
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

// Погода в точке d (единичный вектор) в момент t_h (ч) при местном времени hour (ч).
// wind = false — без ветра и давления (для карты облаков вокруг — дешевле).
weather_at :: proc(wm: ^Weather_Model, d: [3]f64, loc: Wx_Local, t_h, hour: f64, wind := true) -> (w: Weather_Point) {
	T := loc.t
	P := max(loc.p, 0) / WX_HOURS_PER_MONTH // мм/ч в среднем
	day := math.TAU / 24
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
	f_c := P * conv * diurnal / i_c
	if f_c > 0.4 {
		i_c *= f_c / 0.4
		f_c = 0.4
	}
	S := wx_syn(wm, d, t_h)
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
	// температура: суточный ход, под облаками он меньше
	amp := (4 + 9 * loc.dry) * (1 - 0.6 * w.cover) * clamp(math.sqrt(wm.day_h / 24), 0.6, 2.5)
	w.t_air = T + amp / 2 * math.cos((hour - 15) * day)
	w.snow = wsmooth(2, 0, w.t_air)
	if !wind do return
	// давление: в циклоне ниже, в антициклоне выше; в тропиках перепады малы
	w.syn = (wx_press(wm, d, t_h) - wm.mid_p) / wm.sd_p
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
	sx := wx_press(wm, d + east * h, t_h) - wx_press(wm, d - east * h, t_h)
	sy := wx_press(wm, d + north * h, t_h) - wx_press(wm, d - north * h, t_h)
	gx := -dp * sx / (2 * h * wm.radius) // ∂p/∂x (на восток), Па/м: высокий узор — низкое давление
	gy := -dp * sy / (2 * h * wm.radius)
	sl := math.sin(math.to_radians(loc.lat))
	f := 2 * wm.omega * (abs(sl) < 0.17 ? (sl < 0 ? -0.17 : 0.17) : sl)
	vg := [2]f64{-gy, gx} / (wm.rho * f)
	ang := math.to_radians(f64(f > 0 ? 25 : -25))
	ca, sa := math.cos(ang), math.sin(ang)
	vs := [2]f64{vg.x * ca - vg.y * sa, vg.x * sa + vg.y * ca} * 0.6 * wsmooth(8, 20, abs(loc.lat))
	if l := math.sqrt(vs.x * vs.x + vs.y * vs.y); l > 25 do vs *= 25 / l
	w.wind += vs
	speed := math.sqrt(w.wind.x * w.wind.x + w.wind.y * w.wind.y)
	w.gust = speed * 1.5 + 10 * wsmooth(0.5, 8, w.conv)
	return
}
