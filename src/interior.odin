package main

// Строение тел — планет и лун (0.013).
//
// Тело собирается из четырёх веществ: железо (ядро), камень (мантия), лёд и
// вода, водород с гелием. Сколько чего — решает генератор системы (зависит от
// того, где тело родилось). Радиус не задаётся, а получается: от центра
// наружу считаются масса и давление (равновесие dP/dr = −G·m·ρ/r²), плотность
// каждого вещества — по его уравнению состояния при этом давлении (сжатие
// измерено в опытах; при тысячах ГПа — по теории), давление в центре
// подбирается, пока масса не сойдётся.
//
// Потом — температура: у поверхности — от атмосферы; ниже — твёрдая
// остывшая оболочка (литосфера), где тепло идёт теплопроводностью; мантия
// перемешивается и греется только от сжатия (адиабата); на границе ядра —
// скачок; ядро — снова по адиабате. Где железо холоднее точки плавления при
// своём давлении — твёрдое внутреннее ядро. Тепло недр — распад урана,
// тория и калия (с возрастом слабеет) и приливы (у лун гигантов). Слои
// (переходная зона, нижняя мантия, океан под льдом, металлический водород)
// — там, где давление и температура переводят вещество в другую форму.

import "core:math"

G_SI :: 6.674e-11
M_EARTH_KG :: 5.9722e24
R_GAS :: 8.314
GAS_MU :: 2.3e-3 // водород с гелием, кг/моль
EARTH_DENSITY :: 5.514 // г/см³

Material :: enum u8 {
	Iron,
	Rock,
	Ice,
	Gas,
}

// Доли массы, в сумме 1.
Composition :: struct {
	iron, rock, ice, gas: f64,
}

// Что кроме состава влияет на сжатие: водородная оболочка горячее у звезды.
Structure_Params :: struct {
	gas_t_irr: f64, // К: верх оболочки, прогретый звездой
	gas_t_int: f64, // К: адиабата недр на уровне 1 бар (собственное тепло)
	gas_k:     f64, // жёсткость водорода в глубине (P = K·ρ²), м⁵/(кг·с²)
}

Profile_Point :: struct {
	r, m, p, rho: f64,
	mat:          Material,
}

Structure :: struct {
	radius_km:  f64,
	gravity_g:  f64,
	center_p:   f64, // Па
	center_rho: f64, // кг/м³
	ok:         bool,
}

// Примеси лёгких элементов (сера, кислород, кремний) и жар: ядро легче чистого железа.
CORE_LIGHT :: 0.905
GAS_K :: 2.3e5 // у Юпитера: радиус ~70 тыс. км почти не зависит от массы

// Мурнаган: ρ = ρ0·(1 + K'·P/K0)^(1/K').
@(private = "file")
murnaghan :: #force_inline proc "contextless" (rho0, k0, kp, p: f64) -> f64 {
	return rho0 * math.pow(1 + kp * max(p, 0) / k0, 1 / kp)
}

// Сигер и др. (2007): ρ = ρ0 + c·P^n — для огромных давлений (тысячи ГПа).
@(private = "file")
seager :: #force_inline proc "contextless" (rho0, c, n, p: f64) -> f64 {
	return rho0 + c * math.pow(max(p, 0), n)
}

// Температура водородной оболочки (К) при давлении p, Па: сверху — свет
// звезды, глубже — адиабата собственного тепла.
gas_temperature :: proc "contextless" (p: f64, sp: ^Structure_Params) -> f64 {
	return max(sp.gas_t_irr, sp.gas_t_int * math.pow(max(p, 1e5) / 1e5, 0.286))
}

// Плотность вещества (кг/м³) при давлении p (Па). Камень и лёд меняют форму
// с давлением: оливин -> рингвудит (13,5 ГПа) -> бриджманит (23,5 ГПа) ->
// постперовскит (125 ГПа); лёд I -> III/V -> VI -> VII.
eos_density :: proc "contextless" (mat: Material, p: f64, sp: ^Structure_Params) -> f64 {
	switch mat {
	case .Iron:
		return CORE_LIGHT * max(murnaghan(8300, 165e9, 4.97, p), seager(8300, 0.00349, 0.528, p))
	case .Rock:
		switch {
		case p < 13.5e9:
			return murnaghan(3300, 128e9, 4.3, p)
		case p < 23.5e9:
			return murnaghan(3550, 180e9, 4.0, p)
		case p < 125e9:
			return murnaghan(4100, 250e9, 4.0, p)
		}
		return max(murnaghan(4170, 250e9, 4.0, p), seager(4100, 0.00161, 0.541, p))
	case .Ice:
		switch {
		case p < 0.21e9:
			return murnaghan(940, 9e9, 5.5, p)
		case p < 0.63e9:
			return murnaghan(1180, 12e9, 5, p)
		case p < 2.2e9:
			return murnaghan(1310, 18e9, 5, p)
		}
		return max(murnaghan(1460, 23.7e9, 4.15, p), seager(1460, 0.00311, 0.513, p))
	case .Gas:
		// сверху — идеальный газ, в глубине — вырожденный водород (политропа)
		ideal := max(p, 1) * GAS_MU / (R_GAS * gas_temperature(p, sp))
		poly := math.sqrt(max(p, 0) / sp.gas_k)
		return max(min(ideal, poly), 1e-4)
	}
	return 0
}

// ---------------------------------------------------------------- равновесие

@(private = "file")
Integ :: struct {
	mass:  f64, // кг
	bound: [3]f64, // накопленная масса на внешней границе железа, камня, льда
	last:  Material, // внешнее вещество (продолжается, если масса «перелита»)
	sp:    ^Structure_Params,
	h_max: f64, // наибольший шаг, м
}

@(private = "file")
integ_mat :: proc "contextless" (it: ^Integ, m: f64) -> Material {
	if m < it.bound[0] do return .Iron
	if m < it.bound[1] do return .Rock
	if m < it.bound[2] do return .Ice
	return it.last
}

P_SURFACE :: 1e5 // поверхность — где давление 1 бар (у гигантов — условная)

// От центра наружу при давлении в центре pc, пока давление не упадёт до 1 бар.
// Возвращает массу и радиус в этот момент.
@(private = "file")
integrate :: proc(it: ^Integ, pc: f64, out: ^[dynamic]Profile_Point) -> (m_end, r_end: f64) {
	deriv :: proc "contextless" (it: ^Integ, mat: Material, r, m, p: f64) -> (dm, dp: f64) {
		rho := eos_density(mat, p, it.sp)
		dm = 4 * math.PI * r * r * rho
		dp = -G_SI * m * rho / (r * r)
		return
	}
	mat := integ_mat(it, 0)
	rho_c := eos_density(mat, pc, it.sp)
	m := it.mass * 1e-9
	r := math.cbrt(3 * m / (4 * math.PI * rho_c))
	p := pc - 2.0 / 3 * math.PI * G_SI * rho_c * rho_c * r * r
	if out != nil do append(out, Profile_Point{0, 0, pc, rho_c, mat})
	for _ in 0 ..< 30000 {
		mat = integ_mat(it, m)
		dm, dp := deriv(it, mat, r, m, p)
		h := it.h_max
		if dp < 0 do h = min(h, 0.06 * p / -dp)
		// шаг не перескакивает границу веществ
		for b in it.bound {
			if b > m * (1 + 1e-12) {
				if dm > 0 && m + dm * h > b do h = max((b - m) / dm * 1.0002, 1e-3)
				break
			}
		}
		k1m, k1p := dm, dp
		k2m, k2p := deriv(it, mat, r + h / 2, m + k1m * h / 2, p + k1p * h / 2)
		k3m, k3p := deriv(it, mat, r + h / 2, m + k2m * h / 2, p + k2p * h / 2)
		k4m, k4p := deriv(it, mat, r + h, m + k3m * h, p + k3p * h)
		nm := m + h / 6 * (k1m + 2 * k2m + 2 * k3m + k4m)
		np := p + h / 6 * (k1p + 2 * k2p + 2 * k3p + k4p)
		nr := r + h
		if np <= P_SURFACE {
			f := (p - P_SURFACE) / max(p - np, 1e-30)
			r, m, p = r + h * f, m + (nm - m) * f, P_SURFACE
			if out != nil do append(out, Profile_Point{r, m, p, eos_density(mat, p, it.sp), mat})
			break
		}
		r, m, p = nr, nm, np
		if out != nil do append(out, Profile_Point{r, m, p, eos_density(integ_mat(it, m), p, it.sp), integ_mat(it, m)})
	}
	return m, r
}

// Строение тела массой mass_earth и составом comp: радиус, тяжесть, давление в
// центре. out — если нужен весь разрез (от центра к поверхности).
structure_solve :: proc(mass_earth: f64, comp: Composition, sp_in: ^Structure_Params, out: ^[dynamic]Profile_Point = nil) -> (st: Structure) {
	sp := sp_in
	params: Structure_Params
	if sp == nil {
		params = {gas_t_irr = 150, gas_t_int = 165, gas_k = GAS_K}
		sp = &params
	}
	it := Integ{mass = mass_earth * M_EARTH_KG, sp = sp}
	acc := 0.0
	fr := [3]f64{comp.iron, comp.rock, comp.ice}
	for k in 0 ..< 3 {
		acc += fr[k]
		it.bound[k] = acc * it.mass
	}
	it.last = .Iron
	if comp.rock > 0 do it.last = .Rock
	if comp.ice > 0 do it.last = .Ice
	if comp.gas > 0 do it.last = .Gas
	// первый шаг — по грубой оценке радиуса, дальше — по последнему расчёту
	r_est := 6.371e6 * math.pow(mass_earth, 0.27) * (1 + comp.ice) * (comp.gas > 0 ? 1 + 10 * math.sqrt(comp.gas) : 1)
	it.h_max = r_est / 500
	f :: proc(it: ^Integ, x: f64) -> f64 {
		m, r := integrate(it, math.exp(x), nil)
		it.h_max = max(r / 500, 50)
		return math.ln(max(m, 1) / it.mass)
	}
	// давление в центре: оценка по массе и радиусу, затем «вилка» и метод Иллинойса
	guess := G_SI * it.mass * it.mass / (r_est * r_est * r_est * r_est) * 0.8
	lo, hi := math.ln(guess) - 1.5, math.ln(guess) + 1.5
	flo, fhi := f(&it, lo), f(&it, hi)
	for i := 0; flo > 0 && i < 20; i += 1 {
		hi, fhi = lo, flo
		lo -= 2
		flo = f(&it, lo)
	}
	for i := 0; fhi < 0 && i < 20; i += 1 {
		lo, flo = hi, fhi
		hi += 2
		fhi = f(&it, hi)
	}
	if flo > 0 || fhi < 0 do return
	x := hi
	side := 0
	for _ in 0 ..< 60 {
		x = (lo * fhi - hi * flo) / (fhi - flo)
		fx := f(&it, x)
		if abs(fx) < 1e-6 || hi - lo < 1e-8 do break
		if fx > 0 {
			hi, fhi = x, fx
			if side == 1 do flo /= 2
			side = 1
		} else {
			lo, flo = x, fx
			if side == -1 do fhi /= 2
			side = -1
		}
	}
	m_end, r_end := integrate(&it, math.exp(x), out)
	_ = m_end
	st.radius_km = r_end / 1000
	st.gravity_g = G_SI * it.mass / (r_end * r_end) / 9.80665
	st.center_p = math.exp(x)
	st.center_rho = eos_density(integ_mat(&it, 0), st.center_p, sp)
	st.ok = true
	return
}

// ---------------------------------------------------------------- температура и слои

Layer_Kind :: enum u8 {
	Crust_Cont,
	Crust_Ocean,
	Ice_Shell,
	Ocean,
	HP_Ice,
	Upper_Mantle,
	Transition,
	Lower_Mantle,
	D2,
	Outer_Core,
	Inner_Core,
	Core_Liquid,
	Core_Solid,
	Giant_Mantle, // горячая вода, аммиак, метан (у ледяных гигантов)
	Ice_Core, // лёд в ядре газового гиганта
	Molecular_H,
	Metallic_H,
	Rock_Core, // каменное ядро гиганта
	Iron_Core, // железное ядро гиганта
}

LAYER_NAMES := [Layer_Kind]string {
	.Crust_Cont   = "кора материков",
	.Crust_Ocean  = "кора океанов",
	.Ice_Shell    = "ледяная кора",
	.Ocean        = "океан",
	.HP_Ice       = "лёд высокого давления",
	.Upper_Mantle = "верхняя мантия",
	.Transition   = "переходная зона",
	.Lower_Mantle = "нижняя мантия",
	.D2           = "слой D″",
	.Outer_Core   = "внешнее ядро",
	.Inner_Core   = "внутреннее ядро",
	.Core_Liquid  = "ядро",
	.Core_Solid   = "ядро",
	.Giant_Mantle = "мантия: вода, аммиак",
	.Ice_Core     = "ядро: лёд",
	.Molecular_H  = "водород и гелий",
	.Metallic_H   = "металлический водород",
	.Rock_Core    = "каменное ядро",
	.Iron_Core    = "железное ядро",
}

LAYER_STATES := [Layer_Kind]string {
	.Crust_Cont   = "твёрдая",
	.Crust_Ocean  = "твёрдая",
	.Ice_Shell    = "твёрдый лёд",
	.Ocean        = "жидкая вода",
	.HP_Ice       = "твёрдый",
	.Upper_Mantle = "твёрдая, текучая",
	.Transition   = "твёрдая, текучая",
	.Lower_Mantle = "твёрдая, текучая",
	.D2           = "твёрдый",
	.Outer_Core   = "жидкое",
	.Inner_Core   = "твёрдое",
	.Core_Liquid  = "жидкое",
	.Core_Solid   = "твёрдое",
	.Giant_Mantle = "горячая жидкость",
	.Ice_Core     = "горячая жидкость",
	.Molecular_H  = "газ → жидкость",
	.Metallic_H   = "жидкий металл",
	.Rock_Core    = "раскалённое",
	.Iron_Core    = "раскалённое",
}

Interior_Layer :: struct {
	kind:              Layer_Kind,
	top_km, bottom_km: f64, // глубина от поверхности
	t_top, t_bottom:   f64, // °C
	p_top, p_bottom:   f64, // ГПа
	rho_top, rho_bot:  f64, // г/см³
	liquid:            bool,
}

PROF_N :: 1024

// Что нужно знать о теле, кроме состава, чтобы посчитать его недра.
Interior_Input :: struct {
	mass_earth:  f64,
	comp:        Composition,
	t_surface:   f64, // К (у гигантов — на уровне 1 бар)
	age_gyr:     f64,
	heat_k:      f64, // содержание урана, тория и калия относительно Земли
	tidal_w:     f64, // приливный нагрев, Вт
	plates:      bool, // тектоника плит
	sp:          Structure_Params,
}

Planet_Interior :: struct {
	layers:         [16]Interior_Layer,
	n:              int,
	radius_km:      f64,
	gravity_g:      f64,
	density:        f64, // средняя, г/см³
	core_km:        f64, // радиус железного ядра (0 — нет)
	inner_km:       f64, // радиус твёрдого внутреннего ядра (0 — нет)
	crust_cont_km:  f64,
	crust_ocean_km: f64,
	litho_km:       f64, // литосфера: до неё тепло идёт теплопроводностью
	surface_c:      f64,
	gradient:       f64, // прогрев у поверхности, °C на км
	mantle_c:       f64, // температура мантии (без сжатия), °C
	center_t:       f64, // °C
	center_p:       f64, // ГПа
	center_rho:     f64, // г/см³
	heat_tw:        f64, // тепло недр, ТВт
	radio_tw:       f64, // из них распад урана, тория, калия
	tidal_tw:       f64, // приливы
	heat_flux:      f64, // Вт/м²
	plates:         bool,
	magnetic_ut:    f64, // поле у поверхности (0 — нет)
	dynamo_km:      f64, // где рождается поле (верх жидкого слоя), радиус
	ocean_km:       [2]f64, // подлёдный океан: глубина верха и низа (0 — нет)
	has_gas:        bool,
	// разрез по глубине (равномерно, шаг prof_step м): для запросов «что здесь»
	prof_step:      f64,
	prof_t:         [PROF_N]f32, // °C
	prof_p:         [PROF_N]f32, // ГПа
	prof_rho:       [PROF_N]f32, // г/см³
	prof_kind:      [PROF_N]Layer_Kind,
}

// Тепло распада на килограмм камня (Вт/кг) в возрасте age: у Земли сейчас
// ~5·10⁻¹² (уран-238 — 39%, уран-235 — 2%, торий-232 — 40%, калий-40 — 19%);
// в молодости — в разы больше (калий и уран-235 распадаются быстро).
radiogenic_w_per_kg :: proc(age_gyr: f64) -> f64 {
	EARTH_AGE :: 4.55
	share := [4]f64{0.39, 0.02, 0.40, 0.19}
	half := [4]f64{4.468, 0.704, 14.05, 1.248}
	sum := 0.0
	for k in 0 ..< 4 do sum += share[k] * math.pow(2, (EARTH_AGE - age_gyr) / half[k])
	return 5.0e-12 * sum
}

// Плавление сплава железа с серой и кислородом (К) при давлении p (Па): при
// 1 бар ~1260 К (как у смеси железа с сульфидом), на границе внутреннего ядра
// Земли (330 ГПа) ~5500 К.
core_melting :: proc "contextless" (p: f64) -> f64 {
	return 1125 * math.pow(1 + p / 23e9, 0.581)
}

// Плавление льда (К) при давлении p (Па): лёд I плавится ниже 0 °C при
// сжатии, льды высокого давления (III, V, VI, VII) — всё выше.
ice_melting :: proc "contextless" (p: f64) -> f64 {
	g := p / 1e9
	switch {
	case g < 0.21:
		return 273.15 - 104.7 * g
	case g < 0.632:
		return 251.2 + 52.4 * (g - 0.21)
	case g < 2.216:
		return 273.3 + 51.6 * (g - 0.632)
	}
	return 355 * math.pow(g / 2.216, 0.42)
}

// Толщина коры (км): на тяжёлой планете тоньше.
crust_thickness :: proc(gravity_g: f64, oceanic: bool) -> f64 {
	k := clamp(1 / math.sqrt(gravity_g), 0.75, 1.6)
	return (oceanic ? 7 : 35) * k
}

// Недра тела: разрез давления и плотности, температура, слои, тепло, поле.
interior_make :: proc(in_: Interior_Input) -> (pi: ^Planet_Interior) {
	pi = new(Planet_Interior)
	sp := in_.sp
	prof := make([dynamic]Profile_Point, 0, 2048, context.temp_allocator)
	st := structure_solve(in_.mass_earth, in_.comp, &sp, &prof)
	n := len(prof)
	if !st.ok || n < 4 do return
	R := prof[n - 1].r
	pi.radius_km = R / 1000
	pi.gravity_g = st.gravity_g
	pi.density = in_.mass_earth * M_EARTH_KG / (4.0 / 3 * math.PI * R * R * R) / 1000
	pi.center_p = st.center_p / 1e9
	pi.center_rho = st.center_rho / 1000
	pi.has_gas = in_.comp.gas > 0
	M := in_.mass_earth * M_EARTH_KG

	// внешние радиусы веществ
	top: [Material]f64
	for q in prof do top[q.mat] = max(top[q.mat], q.r)
	pi.core_km = top[.Iron] / 1000

	// --- тепло недр: распад в камне (и в камне ледяных тел) + приливы
	h := radiogenic_w_per_kg(in_.age_gyr) * in_.heat_k
	rock_mass := M * in_.comp.rock
	solid_surface := in_.comp.gas == 0
	urey := in_.plates ? 0.45 : in_.mass_earth < 0.05 ? 0.95 : 0.7
	pi.radio_tw = h * rock_mass / 1e12
	pi.tidal_tw = in_.tidal_w / 1e12
	pi.heat_tw = pi.radio_tw / urey + pi.tidal_tw
	if solid_surface {
		pi.heat_flux = pi.heat_tw * 1e12 / (4 * math.PI * R * R)
	} else {
		// гигант светится собственным теплом: остывает и сжимается со времён рождения
		t_eff := 0.6 * sp.gas_t_int
		pi.heat_tw = 5.67e-8 * t_eff * t_eff * t_eff * t_eff * 4 * math.PI * R * R / 1e12
	}
	pi.plates = in_.plates

	// --- температура по слоям, от поверхности вглубь
	t := make([]f64, n, context.temp_allocator)
	ts := in_.t_surface
	pi.surface_c = ts - 273.15
	h_rel := h / 5.0e-12
	tp := 1450 + 150 * math.log2(1 + h_rel) + (in_.plates ? 0 : 80) // мантия «держит» температуру у точки плавления
	t_gas_bottom := ts
	t_ice_bottom := ts
	k_rock :: 3.0
	// водородная оболочка: сверху идеальный газ, глубже — вырожденный водород
	x_t, x_rho := 0.0, 0.0
	i := n - 1
	for ; i >= 0 && prof[i].mat == .Gas; i -= 1 {
		p := prof[i].p
		ideal := max(p, 1) * GAS_MU / (R_GAS * gas_temperature(p, &sp))
		if ideal <= math.sqrt(max(p, 0) / sp.gas_k) {
			t[i] = gas_temperature(p, &sp)
			x_t, x_rho = t[i], prof[i].rho
		} else {
			if x_rho == 0 do x_t, x_rho = gas_temperature(p, &sp), prof[i].rho
			t[i] = x_t * math.pow(prof[i].rho / x_rho, 0.5)
		}
		t_gas_bottom = t[i]
	}
	// лёд и вода
	if i >= 0 && prof[i].mat == .Ice {
		i_top := i
		if !solid_surface {
			// мантия ледяного гиганта — горячая жидкость, по адиабате
			rho_top := prof[i_top].rho
			for ; i >= 0 && prof[i].mat == .Ice; i -= 1 {
				t[i] = t_gas_bottom * math.exp(0.8 * (1 - rho_top / prof[i].rho))
				t_ice_bottom = t[i]
			}
		} else {
			// ледяная кора: теплопроводность льда растёт с холодом (k ≈ 651/T)
			q := pi.heat_flux
			ocean_t := -1.0
			for ; i >= 0 && prof[i].mat == .Ice; i -= 1 {
				z := R - prof[i].r
				tm := ice_melting(prof[i].p)
				switch {
				case ocean_t < 0 && ts >= tm:
					ocean_t = ts // тёплый водный мир: океан с поверхности
					t[i] = ts
				case ocean_t < 0:
					t[i] = ts * math.exp(q * z / 651)
					if t[i] >= tm {
						ocean_t = tm + 8 // океан греется снизу: теплее точки замерзания у потолка
						t[i] = tm
					}
				case:
					t[i] = max(ocean_t, tm - 15) // ниже океана — лёд высокого давления у точки плавления
				}
				t_ice_bottom = t[i]
			}
		}
	}
	// камень: литосфера (теплопроводность) -> мантия (адиабата)
	if i >= 0 && prof[i].mat == .Rock {
		i_top := i
		t0 := i_top == n - 1 ? ts : (prof[i_top + 1].mat == .Ice ? t_ice_bottom : t_gas_bottom)
		r_top := prof[i_top].r
		r_bot := top[.Iron]
		if solid_surface {
			q_top := pi.heat_tw * 1e12 / (4 * math.PI * r_top * r_top)
			// маленькое тело остывает насквозь: прогрев ограничен теплопроводностью
			dt_cond := h * 3300 * (r_top * r_top - r_bot * r_bot) / (6 * k_rock)
			tp_eff := max(min(tp, t0 + dt_cond), t0)
			litho := clamp(k_rock * (tp_eff - t0) / max(0.5 * q_top, 1e-4), 8000, r_top - r_bot)
			pi.litho_km = litho / 1000
			pi.mantle_c = tp_eff - 273.15
			pi.gradient = 2 * (tp_eff - t0) / litho * 1000
			p_l := prof[i_top].p
			for ; i >= 0 && prof[i].mat == .Rock; i -= 1 {
				z := r_top - prof[i].r
				if z < litho {
					x := z / litho
					t[i] = t0 + (tp_eff - t0) * (2 * x - x * x)
					p_l = prof[i].p
				} else {
					t[i] = tp_eff * math.pow(1 + (prof[i].p - p_l) / 30e9, 0.3) // адиабата: греется только от сжатия
				}
			}
		} else {
			p_top := prof[i_top].p
			for ; i >= 0 && prof[i].mat == .Rock; i -= 1 do t[i] = t0 * math.pow((1 + prof[i].p / 300e9) / (1 + p_top / 300e9), 0.3)
		}
	}
	// железо: скачок на границе ядра (горячий пограничный слой), дальше адиабата
	if i >= 0 && prof[i].mat == .Iron {
		above := i == n - 1 ? ts : t[i + 1]
		jump := solid_surface ? 0.48 * above * clamp(math.pow(in_.mass_earth, 0.25), 0.3, 1.6) : 0
		t_cmb := above + jump
		p_cmb := prof[i].p
		for ; i >= 0; i -= 1 do t[i] = t_cmb * math.pow((1 + prof[i].p / 100e9) / (1 + p_cmb / 100e9), 0.565)
	}
	pi.center_t = t[0] - 273.15

	// --- вид вещества в каждой точке
	kinds := make([]Layer_Kind, n, context.temp_allocator)
	liquid := make([]bool, n, context.temp_allocator)
	has_liquid_iron, has_solid_iron := false, false
	for q, k in prof {
		if q.mat == .Iron {
			if t[k] >= core_melting(q.p) {
				has_liquid_iron = true
			} else {
				has_solid_iron = true
			}
		}
	}
	for q, k in prof {
		p := q.p
		switch q.mat {
		case .Gas:
			kinds[k] = p < 150e9 ? .Molecular_H : .Metallic_H
			liquid[k] = true
		case .Ice:
			if !solid_surface {
				kinds[k], liquid[k] = in_.comp.gas > 0.5 ? .Ice_Core : .Giant_Mantle, true
			} else if t[k] >= ice_melting(p) - 0.01 {
				kinds[k], liquid[k] = .Ocean, true
			} else {
				kinds[k] = p < 0.21e9 ? .Ice_Shell : .HP_Ice
			}
		case .Rock:
			switch {
			case !solid_surface:
				kinds[k] = .Rock_Core
			case p < 13.5e9:
				kinds[k] = .Upper_Mantle
			case p < 23.5e9:
				kinds[k] = .Transition
			case p < 125e9:
				kinds[k] = .Lower_Mantle
			case:
				kinds[k] = .D2
			}
		case .Iron:
			molten := t[k] >= core_melting(p)
			liquid[k] = molten
			switch {
			case !solid_surface:
				kinds[k] = .Iron_Core
			case has_liquid_iron && has_solid_iron:
				kinds[k] = molten ? .Outer_Core : .Inner_Core
			case:
				kinds[k] = molten ? .Core_Liquid : .Core_Solid
			}
		}
	}
	for q, k in prof {
		if kinds[k] == .Inner_Core do pi.inner_km = max(pi.inner_km, q.r / 1000)
	}

	// --- слои: сверху вниз, соседние точки одного вида — один слой
	add :: proc(pi: ^Planet_Interior, l: Interior_Layer) {
		if pi.n < len(pi.layers) {
			pi.layers[pi.n] = l
			pi.n += 1
		}
	}
	celsius_k :: proc(k: f64) -> f64 {return k - 273.15}
	// разрез по глубине (равномерно): интерполяция между точками расчёта
	pi.prof_step = R / (PROF_N - 1)
	{
		j := n - 1
		for s in 0 ..< PROF_N {
			r := R - f64(s) * pi.prof_step
			for j > 0 && prof[j - 1].r > r do j -= 1
			lo := max(j - 1, 0)
			a, b := prof[lo], prof[j]
			f := b.r > a.r ? clamp((r - a.r) / (b.r - a.r), 0, 1) : 0
			pi.prof_t[s] = f32(celsius_k(math.lerp(t[lo], t[j], f)))
			pi.prof_p[s] = f32(math.lerp(a.p, b.p, f) / 1e9)
			pi.prof_rho[s] = f32(math.lerp(a.rho, b.rho, f) / 1000)
			pi.prof_kind[s] = f > 0.5 ? kinds[j] : kinds[lo]
		}
	}
	at_depth :: proc(pi: ^Planet_Interior, d_km: f64) -> (tc, p, rho: f64) {
		x := clamp(d_km * 1000 / pi.prof_step, 0, PROF_N - 1)
		k := min(int(x), PROF_N - 2)
		f := x - f64(k)
		tc = math.lerp(f64(pi.prof_t[k]), f64(pi.prof_t[k + 1]), f)
		p = math.lerp(f64(pi.prof_p[k]), f64(pi.prof_p[k + 1]), f)
		rho = math.lerp(f64(pi.prof_rho[k]), f64(pi.prof_rho[k + 1]), f)
		return
	}
	crust_top := 0.0
	if solid_surface && in_.comp.ice == 0 {
		// кора — тонкая плёнка из камня полегче (в уравнении сжатия — часть мантии)
		pi.crust_cont_km = crust_thickness(st.gravity_g, false)
		pi.crust_ocean_km = crust_thickness(st.gravity_g, true)
		for c in 0 ..< 2 {
			d := c == 0 ? pi.crust_cont_km : pi.crust_ocean_km
			t1, p1, _ := at_depth(pi, d)
			t0 := pi.surface_c
			if c == 1 do t0 = 4 // дно океана
			add(pi, {c == 0 ? .Crust_Cont : .Crust_Ocean, 0, d, t0, t1, 0, p1, c == 0 ? 2.7 : 2.9, c == 0 ? 2.9 : 3.0, false})
		}
		crust_top = pi.crust_cont_km
	}
	k := n - 1
	prev_bot := 0.0 // границы слоёв — посередине между точками расчёта, без щелей
	for k >= 0 {
		kind := kinds[k]
		j := k
		for j > 0 && kinds[j - 1] == kind do j -= 1
		top_d := prev_bot
		bot_d := j == 0 ? R / 1000 : (R - (prof[j].r + prof[j - 1].r) / 2) / 1000
		prev_bot = bot_d
		if bot_d > crust_top {
			l := Interior_Layer{kind, max(top_d, crust_top), bot_d, 0, celsius_k(t[j]), 0, prof[j].p / 1e9, 0, prof[j].rho / 1000, liquid[k]}
			l.t_top, l.p_top, l.rho_top = at_depth(pi, l.top_km)
			if top_d >= crust_top {
				l.t_top, l.p_top, l.rho_top = celsius_k(t[k]), prof[k].p / 1e9, prof[k].rho / 1000
			}
			if kind == .Ocean do pi.ocean_km = {top_d, bot_d}
			add(pi, l)
		}
		k = j - 1
	}

	// --- магнитное поле: динамо в жидком проводящем слое, если он перемешивается
	switch {
	case in_.comp.gas > 0.05:
		// металлический водород (у газовых гигантов) или горячая вода (у ледяных)
		for q, kk in prof {
			if kinds[kk] == .Metallic_H do pi.dynamo_km = max(pi.dynamo_km, q.r / 1000)
			if kinds[kk] == .Giant_Mantle do pi.dynamo_km = max(pi.dynamo_km, q.r / 1000)
		}
		if pi.dynamo_km > 0 {
			x := pi.dynamo_km / pi.radius_km
			metal := false
			for kk in kinds do if kk == .Metallic_H do metal = true
			pi.magnetic_ut = metal ? 420 * math.pow(x / 0.83, 3) * math.pow(in_.mass_earth / 318, 0.3) : 22 * math.pow(x / 0.8, 3)
		}
	case has_liquid_iron:
		// жидкий слой железа должен перемешиваться: растёт твёрдое ядро, кора
		// «сбрасывает» тепло плитами или греют приливы
		shell := pi.core_km - pi.inner_km
		stirred := pi.inner_km > 0 || in_.plates
		if shell > 0.1 * pi.core_km && stirred {
			pi.dynamo_km = pi.core_km
			q_rel := max(pi.heat_flux, 1e-4) / 0.092
			x := pi.core_km / pi.radius_km
			pi.magnetic_ut = 45 * math.pow(x / 0.546, 3) * math.cbrt(q_rel * shell / 2260)
		}
	}
	return
}

// Температура (°C), давление (ГПа), плотность и слой на глубине depth_m под поверхностью.
interior_at :: proc(pi: ^Planet_Interior, depth_m: f64) -> (tc, p_gpa, rho: f64, kind: Layer_Kind) {
	x := clamp(depth_m / pi.prof_step, 0, PROF_N - 1)
	k := min(int(x), PROF_N - 2)
	f := x - f64(k)
	tc = math.lerp(f64(pi.prof_t[k]), f64(pi.prof_t[k + 1]), f)
	p_gpa = math.lerp(f64(pi.prof_p[k]), f64(pi.prof_p[k + 1]), f)
	rho = math.lerp(f64(pi.prof_rho[k]), f64(pi.prof_rho[k + 1]), f)
	kind = pi.prof_kind[f < 0.5 ? k : k + 1]
	return
}

// Слой (из таблицы), в котором лежит глубина depth_km; -1 — нет.
interior_layer_at :: proc(pi: ^Planet_Interior, depth_km: f64) -> int {
	best := -1
	for l, i in pi.layers[:pi.n] {
		if depth_km >= l.top_km && depth_km <= l.bottom_km {
			if best < 0 || l.kind != .Crust_Ocean do best = i
			if l.kind == .Crust_Cont do return i
		}
	}
	return best
}
