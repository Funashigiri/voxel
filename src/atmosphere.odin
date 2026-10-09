package main

// Атмосферы (0.013).
//
// Удержит ли тело воздух — решают скорость убегания и излучение звезды
// («космическая береговая линия»: у Луны и Меркурия воздуха нет, у
// холодного Титана — плотный, у Марса — едва-едва). Сколько газа — запас
// летучих веществ: у каменных планет ~70 бар углекислого газа и 1–4 бара
// азота на каждую «земную» тяжесть (у ледяных тел — гораздо больше азота).
// Куда девается углекислый газ — решает вода: где есть океаны и движутся
// плиты, он уходит в известняк, пока не установится умеренная температура
// (карбонатно-силикатный «термостат», он и задаёт зону жизни). Слишком близко
// к звезде океаны выкипают — безудержный парниковый эффект, как на Венере;
// слишком далеко — даже весь углекислый газ не согреет.
// Температура поверхности — баланс света звезды и парникового эффекта
// (серая атмосфера). Где долго есть жидкая вода, появляется жизнь, а через
// миллиарды лет — кислород и растения на суше.
// С высотой: давление падает экспонентой, в нижнем слое холодает по
// влажной адиабате (~6,5 °C на км у Земли), выше — стратосфера (с озоном
// теплее), мезосфера, термосфера.

import "core:math"
import eng "engine"

Gas_Kind :: enum u8 {
	N2,
	O2,
	CO2,
	Ar,
	H2O,
	CH4,
	H2,
	He,
}

GAS_NAMES := [Gas_Kind]string {
	.N2  = "азот",
	.O2  = "кислород",
	.CO2 = "углекислый газ",
	.Ar  = "аргон",
	.H2O = "водяной пар",
	.CH4 = "метан",
	.H2  = "водород",
	.He  = "гелий",
}

// кг/моль
GAS_MOLAR := [Gas_Kind]f64 {
	.N2  = 0.028014,
	.O2  = 0.031998,
	.CO2 = 0.04401,
	.Ar  = 0.039948,
	.H2O = 0.018015,
	.CH4 = 0.016043,
	.H2  = 0.002016,
	.He  = 0.004003,
}

// Рассеяние света одной молекулой (воздух = 1): углекислый газ — в 2,5 раза сильнее.
GAS_SCATTER := [Gas_Kind]f64 {
	.N2  = 1.02,
	.O2  = 0.86,
	.CO2 = 2.45,
	.Ar  = 0.86,
	.H2O = 0.7,
	.CH4 = 2.2,
	.H2  = 0.22,
	.He  = 0.015,
}

// Теплоёмкость, Дж/(кг·К)
GAS_CP := [Gas_Kind]f64 {
	.N2  = 1040,
	.O2  = 918,
	.CO2 = 844,
	.Ar  = 520,
	.H2O = 1864,
	.CH4 = 2220,
	.H2  = 14300,
	.He  = 5193,
}

Atmo_Kind :: enum u8 {
	None, // нет (следы)
	Thin, // разреженная, как у Марса
	Thick,
	Envelope, // водородная оболочка гиганта — поверхности нет
}

Water_State :: enum u8 {
	None,
	Oceans, // жидкие океаны на поверхности
	Frozen, // лёд на поверхности
	Lost, // выкипели и улетели (безудержный парниковый эффект)
	Deep, // океан покрывает всё (водный мир)
	Steam, // водный мир у звезды: пар и горячая вода под огромным давлением
}

ATMO_TABLE :: 64

Atmosphere :: struct {
	kind:       Atmo_Kind,
	pressure:   f64, // бар у поверхности (у гигантов — условный уровень 1 бар)
	frac:       [Gas_Kind]f64, // доли молекул
	mu:         f64, // кг/моль
	cp:         f64,
	albedo:     f64,
	t_eq:       f64, // К — без парникового эффекта
	t_surface:  f64, // К — средняя у поверхности (у моря)
	t_skin:     f64, // К — верх тропосферы
	tau:        f64, // оптическая толщина парникового эффекта
	lapse:      f64, // К/м — как холодает с высотой у поверхности
	scale_h:    f64, // м — высота, на которой давление падает в e раз
	gm:         f64, // ускорение свободного падения, м/с²
	tropopause: f64, // м
	ozone:      bool,
	water:      Water_State,
	plates:     bool, // тектоника плит (нужна термостату)
	life:       bool,
	plants:     bool, // растения на суше
	runaway:    bool,
	margin:     f64, // запас удержания: < 1 — не удержать
	rayleigh:   f64, // рассеяние света у поверхности относительно Земли
	density:    f64, // кг/м³ у поверхности
	o2_kpa:     f64, // кислород, кПа
	co2_store:  f64, // углекислого газа в запасе (в известняке и т. п.), бар
	// давление по высоте: ln p (бар) на высотах k·table_dz
	table_dz:   f64,
	table_lnp:  [ATMO_TABLE]f32,
}

Atmo_Input :: struct {
	mass_earth, radius_km, gravity_g: f64,
	flux:                             f64, // свет звезды, Земля = 1
	star_teff:                        f64,
	star_class:                       Star_Class,
	age_gyr:                          f64,
	water:                            f64, // вода на поверхности, доля массы
	icy:                              bool, // тело из льда (за снеговой линией)
	envelope:                         bool, // водородная оболочка
	ice_giant:                        bool,
	gas_t1:                           f64, // К на уровне 1 бар (у гигантов)
	strip:                            f64, // во сколько раз сильнее сдувает: луны в магнитосфере гиганта (0 — 1)
	seed:                             u64,
	// для проверок (-planets): запас углекислого газа и азота, бар (0 — случайный); средние случайности
	fixed_co2, fixed_n2:              f64,
	fixed:                            bool,
}

// Насколько звезда «сдувает» атмосферы жёстким излучением (на единицу её света):
// красные карлики — вспышками, горячие звёзды — ультрафиолетом.
@(private = "file")
xuv_factor :: proc(c: Star_Class) -> f64 {
	switch c {
	case .M:
		return 25
	case .K:
		return 3
	case .G:
		return 1
	case .F:
		return 0.8
	case .A:
		return 1.5
	case .B:
		return 20
	case .O:
		return 50
	case .Red_Giant:
		return 2
	case .White_Dwarf:
		return 10
	case .Neutron, .Black_Hole:
		return 1000
	}
	return 1
}

// Границы зоны жизни по Коппарапу (2013): поток (Земля = 1), при котором
// океаны выкипают (in) и при котором уже не согреться (out), — для звезды с
// температурой teff.
habitable_flux :: proc(teff: f64) -> (s_in, s_out: f64) {
	t := clamp(teff, 2600, 7200) - 5780
	s_in = 1.0512 + 1.3242e-4 * t + 1.5418e-8 * t * t - 7.9895e-12 * t * t * t - 1.8328e-15 * t * t * t * t
	s_out = 0.3438 + 5.8942e-5 * t + 1.6558e-9 * t * t - 3.0045e-12 * t * t * t - 5.2983e-16 * t * t * t * t
	return
}

// Равновесная температура (К): свет звезды против излучения в космос.
equilibrium_temp :: proc(flux, albedo: f64) -> f64 {
	return 278.6 * math.pow(max(flux, 0), 0.25) * math.pow(1 - albedo, 0.25)
}

// Давление насыщенного пара воды (бар) при температуре t, К.
@(private = "file")
water_vapour :: proc(t: f64) -> f64 {
	return 0.0061 * math.exp(5420 * (1 / 273.16 - 1 / max(t, 150)))
}

// Давление, выше которого газ вымерзает на поверхность (бар): азот у
// Тритона и Плутона, углекислый газ — на полюсах Марса.
@(private = "file")
frost_pressure :: proc(g: Gas_Kind, t: f64) -> f64 {
	#partial switch g {
	case .N2:
		return 0.125 * math.exp(6900 / R_GAS * (1 / 63.15 - 1 / max(t, 20)))
	case .CH4:
		return 1.013 * math.exp(8200 / R_GAS * (1 / 111.7 - 1 / max(t, 20)))
	case .CO2:
		return 1.013 * math.exp(25200 / R_GAS * (1 / 194.7 - 1 / max(t, 50)))
	}
	return 1e9
}

// Оптическая толщина серой атмосферы в тепловом свете: углекислый газ,
// водяной пар (растёт с теплом — усиливает нагрев), метан, столкновения молекул.
@(private = "file")
greenhouse_tau :: proc(p, p_co2, p_ch4, ts: f64, wet: bool) -> f64 {
	tau := 0.02 * (p - p_co2) * (p - p_co2) + 0.0005 * p_co2 * p_co2 // столкновения молекул (у плотных атмосфер)
	if p_co2 > 0 do tau += 0.25 * math.pow(p_co2 / 4e-4, 0.4) * math.pow(max(p, 1e-4), 0.3)
	if wet && ts > 240 do tau += 0.58 * math.exp(0.026 * (min(ts, 420) - 288)) * math.pow(clamp(p, 0.05, 10), 0.3)
	if p_ch4 > 0 do tau += 0.5 * math.sqrt(p_ch4 / 0.07)
	return tau
}

@(private = "file")
surface_temp :: proc(t_eq, p, p_co2, p_ch4: f64, wet: bool) -> (ts, tau: f64) {
	ts = t_eq
	for _ in 0 ..< 80 {
		tau = greenhouse_tau(p, p_co2, p_ch4, ts, wet)
		nt := t_eq * math.pow(1 + 0.75 * tau, 0.25)
		ts += (min(nt, 3000) - ts) * 0.5
	}
	return
}

@(private = "file")
smooth01 :: proc(e0, e1, x: f64) -> f64 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}

// Логарифмически равномерное случайное число в [lo, hi].
logu :: proc(r: ^eng.Rng, lo, hi: f64) -> f64 {
	return math.exp(eng.rng_range(r, math.ln(lo), math.ln(hi)))
}

atmosphere_make :: proc(in_: Atmo_Input) -> (a: Atmosphere) {
	r := eng.rng_make(in_.seed ~ 0xA7_305F)
	g := in_.gravity_g
	M := in_.mass_earth * M_EARTH_KG
	R := in_.radius_km * 1000
	v_esc := math.sqrt(2 * G_SI * M / R) / 1000
	a.margin = 6.9e-4 * v_esc * v_esc * v_esc * v_esc / max(in_.flux * xuv_factor(in_.star_class) * max(in_.strip, 1), 1e-9)

	if in_.envelope {
		// водородная оболочка: поверхности нет, «уровень моря» — 1 бар
		a.kind = .Envelope
		a.pressure = 1
		if in_.ice_giant {
			a.frac[.H2], a.frac[.He], a.frac[.CH4] = 0.80, 0.18, 0.02
		} else {
			a.frac[.H2], a.frac[.He], a.frac[.CH4] = 0.86, 0.136, 0.004
		}
		a.albedo = in_.ice_giant ? 0.3 : 0.34
		a.t_eq = equilibrium_temp(in_.flux, a.albedo)
		a.t_surface = in_.gas_t1
		a.t_skin = a.t_eq * 0.841
		a.water = .None
		atmo_finish(&a, g)
		return
	}

	// запас летучих (бар, если бы всё было в воздухе): у каменных — как у
	// Земли и Венеры, у ледяных тел азота много больше (Титан)
	inv_co2 := 70 * g * g * logu(&r, 0.3, 3)
	inv_n2 := g * g * logu(&r, 0.25, 4)
	if in_.icy do inv_n2 = 80 * g * g * logu(&r, 0.3, 3)
	u_ox, u_f, u_t := eng.rng_f64(&r), eng.rng_f64(&r), eng.rng_f64(&r)
	if in_.fixed {
		if in_.fixed_co2 > 0 do inv_co2 = in_.fixed_co2
		if in_.fixed_n2 > 0 do inv_n2 = in_.fixed_n2
		u_ox, u_f, u_t = 0.5, 0.5, 0.5
	}
	retain := math.pow(clamp((a.margin - 0.9) / 2, 0, 1), 3)
	s_in, s_out := habitable_flux(in_.star_teff)
	has_water := in_.water > 1e-6 || in_.icy
	a.plates = has_water && !in_.icy && in_.mass_earth >= 0.2 && in_.mass_earth <= 6

	p_n2, p_co2, p_ch4, p_o2, p_steam := 0.0, 0.0, 0.0, 0.0, 0.0
	wet := false
	switch {
	case retain < 1e-7:
		// воздуха нет: всё улетело
		a.kind = .None
		a.albedo = in_.icy ? 0.6 : 0.12
		a.water = in_.icy ? .Frozen : .None
	case in_.icy:
		// ледяное тело: азот и метан, если не вымерзают
		a.albedo = 0.6
		p_n2 = inv_n2 * retain
		p_ch4 = 0.05 * p_n2
		for _ in 0 ..< 6 {
			t := equilibrium_temp(in_.flux, a.albedo)
			p_n2 = min(inv_n2 * retain, frost_pressure(.N2, t))
			p_ch4 = min(0.05 * inv_n2 * retain, frost_pressure(.CH4, t))
			a.albedo = p_n2 > 0.1 ? 0.22 : 0.6 // дымка из метана (как на Титане)
		}
		a.water = .Frozen
	case has_water && in_.flux > s_in && in_.water >= 0.02:
		// водный мир слишком близко к звезде: океан не улетит — он превращается
		// в пар над горячей водой под огромным давлением
		a.runaway = true
		a.water = .Steam
		a.albedo = 0.3
		p_n2 = inv_n2 * retain
		p_co2 = inv_co2 * retain
		p_steam = min(in_.water * M * g * 9.80665 / (4 * math.PI * R * R) / 1e5, 5000)
	case has_water && in_.flux > s_in:
		// океаны выкипели, водород улетел: углекислый газ остался в воздухе (Венера)
		a.runaway = true
		a.water = in_.age_gyr > 0.3 ? .Lost : .None
		p_n2 = inv_n2 * retain
		p_co2 = inv_co2 * retain
		a.albedo = p_n2 + p_co2 > 10 ? 0.75 : 0.3 // облака серной кислоты — у плотной атмосферы
	case has_water && a.plates && in_.flux < s_out:
		// дальше зоны жизни: даже весь углекислый газ не согреет — он сам
		// вымерзает и отражает свет; океаны подо льдом
		a.water = .Frozen
		a.albedo = 0.6
		p_n2 = inv_n2 * retain
		p_co2 = min(inv_co2 * retain, frost_pressure(.CO2, equilibrium_temp(in_.flux, a.albedo)))
	case has_water && a.plates:
		// термостат: углекислого газа ровно столько, чтобы было умеренно
		a.albedo = 0.3
		p_n2 = inv_n2 * retain
		wet = true
		x := clamp((in_.flux - s_out) / (s_in - s_out), 0, 1)
		target := 270 + 22 * math.sqrt(x) + (u_t - 0.5) * 12
		t_eq := equilibrium_temp(in_.flux, a.albedo)
		// ниже ~0,01 мбар не уйдёт: растения перестают брать углекислый газ, выветривание затихает
		lo, hi := math.ln(1e-5), math.ln(max(inv_co2 * retain, 2e-5))
		for _ in 0 ..< 40 {
			mid := (lo + hi) / 2
			pc := math.exp(mid)
			ts, _ := surface_temp(t_eq, p_n2 + pc, pc, 0, true)
			if ts > target {
				hi = mid
			} else {
				lo = mid
			}
		}
		p_co2 = math.exp((lo + hi) / 2)
		a.co2_store = max(inv_co2 * retain - p_co2, 0)
		a.water = .Oceans
	case has_water:
		// вода без плит: углекислый газ в воздухе, лёд или океаны — как выйдет
		a.albedo = 0.3
		p_n2 = inv_n2 * retain
		p_co2 = 0.3 * inv_co2 * retain
		wet = true
		a.water = .Oceans
	case:
		// сухая планета
		a.albedo = 0.25
		p_n2 = inv_n2 * retain
		p_co2 = inv_co2 * retain
		a.water = .None
	}
	// водный мир: океан сплошной
	if a.water == .Oceans && in_.water > 0.02 do a.water = .Deep

	// жизнь и кислород: где долго есть жидкая вода
	a.t_eq = equilibrium_temp(in_.flux, a.albedo)
	ts, tau := surface_temp(a.t_eq, p_n2 + p_co2 + p_ch4, p_co2, p_ch4, wet)
	if (a.water == .Oceans || a.water == .Deep) && ts < 263 {
		// всё замёрзло. С плотным воздухом — «снежный ком»: лёд отражает свет,
		// ещё холоднее, а углекислый газ копится (не уходит в камень); в
		// разреженном — холодная пустыня с ледяными шапками (Марс)
		a.water = .Frozen
		wet = false
		if p_n2 + p_co2 > 0.1 {
			a.albedo = 0.6
			a.t_eq = equilibrium_temp(in_.flux, a.albedo)
			p_co2 = max(p_co2, min(inv_co2 * retain, frost_pressure(.CO2, a.t_eq)))
		} else {
			a.albedo = 0.25
			a.t_eq = equilibrium_temp(in_.flux, a.albedo)
		}
		ts, tau = surface_temp(a.t_eq, p_n2 + p_co2, p_co2, 0, false)
	}
	if (a.water == .Oceans || a.water == .Deep) && ts < 340 && in_.age_gyr > 0.8 {
		a.life = true
		t_ox := 1.4 + 2.6 * u_ox // кислород копится, когда его производят миллиарды лет
		if in_.age_gyr > t_ox {
			f := (0.12 + 0.22 * u_f) * smooth01(t_ox, t_ox + 0.6, in_.age_gyr)
			p_o2 = f / (1 - f) * p_n2
			a.ozone = f > 0.01
			a.plants = in_.age_gyr > t_ox + 0.35 && a.water == .Oceans
		}
	}
	p_ar := 0.012 * p_n2
	p_h2o := wet ? 0.5 * min(water_vapour(ts), 0.2) : 0
	if a.water == .Steam {
		// пар держит тепло: под сотнями бар — сотни градусов и выше
		p_h2o = p_steam
		ts = clamp(600 + 0.3 * p_steam, 650, 2000)
	}
	p := p_n2 + p_co2 + p_ch4 + p_o2 + p_ar + p_h2o
	a.pressure = p
	if p > 1e-9 {
		a.frac[.N2], a.frac[.CO2], a.frac[.CH4] = p_n2 / p, p_co2 / p, p_ch4 / p
		a.frac[.O2], a.frac[.Ar], a.frac[.H2O] = p_o2 / p, p_ar / p, p_h2o / p
	}
	a.kind = p < 1e-4 ? .None : p < 0.05 ? .Thin : .Thick
	a.t_surface = ts
	a.tau = tau
	a.t_skin = a.t_eq * 0.841
	a.o2_kpa = p_o2 * 100
	atmo_finish(&a, g)
	return
}

// Состав -> молярная масса, теплоёмкость, высота однородной атмосферы,
// холодание с высотой, тропопауза, рассеяние света, таблица давления по высоте.
@(private = "file")
atmo_finish :: proc(a: ^Atmosphere, g: f64) {
	a.mu, a.cp = 0, 0
	scatter := 0.0
	for gk in Gas_Kind {
		a.mu += a.frac[gk] * GAS_MOLAR[gk]
		scatter += a.frac[gk] * GAS_SCATTER[gk]
	}
	if a.mu <= 0 do a.mu = 0.029
	for gk in Gas_Kind do a.cp += a.frac[gk] * GAS_MOLAR[gk] / a.mu * GAS_CP[gk]
	if a.cp <= 0 do a.cp = 1004
	gm := g * 9.80665
	a.gm = gm
	a.scale_h = R_GAS * a.t_surface / (a.mu * gm)
	wet := a.frac[.H2O] > 0.001
	a.lapse = gm / a.cp * (wet ? 0.66 : 0.8)
	a.tropopause = a.t_surface > a.t_skin ? (a.t_surface - a.t_skin) / a.lapse : 0
	a.density = a.pressure * 1e5 * a.mu / (R_GAS * a.t_surface)
	// столб молекул над поверхностью относительно Земли (1,013 бар, 1 g, воздух)
	a.rayleigh = a.pressure / 1.013 / max(g, 0.01) * (0.02896 / a.mu) * scatter
	a.table_dz = a.scale_h / 3
	lnp := math.ln(max(a.pressure, 1e-12))
	for k in 0 ..< ATMO_TABLE {
		a.table_lnp[k] = f32(lnp)
		// шаг: dp/p = −μ·g/(R·T)·dz, по средней температуре на шаге
		z := (f64(k) + 0.5) * a.table_dz
		lnp -= a.mu * gm / (R_GAS * atmo_temperature(a, z)) * a.table_dz
	}
}

// Средняя температура воздуха (К) на высоте z над уровнем моря.
atmo_temperature :: proc(a: ^Atmosphere, height: f64) -> f64 {
	if a.kind == .None do return a.t_surface
	z := max(height, -11000)
	if z <= a.tropopause do return a.t_surface - a.lapse * z
	h := R_GAS * a.t_skin / (a.mu * a.gm) // высота однородной атмосферы у верха тропосферы
	dz := (z - a.tropopause) / h
	if a.ozone {
		// стратосфера (озон греет) -> мезосфера -> термосфера
		switch {
		case dz < 6:
			return a.t_skin + 55 * smooth01(0, 6, dz)
		case dz < 11.5:
			return a.t_skin + 55 - 80 * smooth01(6, 11.5, dz)
		}
		return a.t_skin - 25 + 900 * smooth01(11.5, 19, dz)
	}
	if dz < 12 do return a.t_skin
	return a.t_skin + 700 * smooth01(12, 20, dz)
}

// Давление (бар) на высоте z над уровнем моря.
atmo_pressure :: proc(a: ^Atmosphere, z: f64) -> f64 {
	if a.pressure <= 0 do return 0
	if z <= 0 {
		// ниже уровня моря (впадины): по температуре у поверхности
		return a.pressure * math.exp(-z * a.mu * a.gm / (R_GAS * atmo_temperature(a, z / 2)))
	}
	x := z / a.table_dz
	k := int(x)
	if k >= ATMO_TABLE - 1 do return math.exp(f64(a.table_lnp[ATMO_TABLE - 1]) - (x - f64(ATMO_TABLE - 1)) * 3)
	f := x - f64(k)
	return math.exp(math.lerp(f64(a.table_lnp[k]), f64(a.table_lnp[k + 1]), f))
}

// Высота на Земле с тем же давлением воздуха, м (для сравнения).
earth_equivalent_height :: proc(p_bar: f64) -> f64 {
	return -8400 * math.ln(max(p_bar, 1e-9) / 1.013)
}

EARTH_SCALE_H :: 8430.0 // м
EARTH_AIR_DENSITY :: 1.225 // кг/м³ у моря
