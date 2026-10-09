package main

// Строение звёзд (0.014). Масса, радиус, светимость и температура звезды —
// прежние (stars.odin), отсюда — что у неё внутри.
//
// Звезда — шар горячего газа в равновесии: давление держит тяжесть. Его
// разрез близок к политропе (давление ∝ плотность^(1+1/n)): у звёзд, где
// тепло выносит конвекция (красные карлики), n = 1,5; где излучение — n = 3
// (стандартная модель Эддингтона). Политропа даёт плотность, давление и
// температуру по радиусу; центр — с поправкой на выгоревшее ядро (там уже
// гелий: тяжелее и плотнее), сверенной с моделью Солнца. Горит водород
// двумя путями: протон-протонная цепочка (∝ T⁴, у Солнца ~99%) и CNO-цикл
// (∝ T¹⁷ — у звёзд массивнее ~1,3 Солнца он главный). Где горит 99% энергии —
// ядро. Где тепло выносит конвекция — по известным расчётам звёзд: красные
// карлики перемешаны целиком, у Солнца конвективна внешняя треть, у
// массивных — конвективное ядро. Над поверхностью — хромосфера и корона
// (у звёзд с конвекцией — магнитная активность: пятна, вспышки, ветер;
// с возрастом звезда медленнее вращается и успокаивается).
//
// Гиганты — сжавшееся вырожденное гелиевое ядро и огромная разреженная
// оболочка; белые карлики держит давление вырожденных электронов,
// нейтронные звёзды — нейтронов; чёрная дыра — горизонт событий.

import "core:math"
import eng "engine"

C_LIGHT :: 2.998e8
K_BOLTZ :: 1.380649e-23
M_HYDROGEN :: 1.6735e-27
M_UNIT :: 1.66054e-27
SUN_MASS_KG :: 1.989e30
SUN_RADIUS_M :: 6.957e8
SUN_LUM_W :: 3.828e26
CHANDRASEKHAR :: 1.44 // предел массы белого карлика, масс Солнца
NUCLEAR_DENSITY :: 2.7e17 // кг/м³ — как в ядре атома
CNO_AT_SUN :: 0.045 // CNO-цикл против протон-протонной цепочки в центре Солнца (в сумме по Солнцу ~1,6%)

@(private = "file")
TAG_STAR_ACT :: 0x5AC7_0014

// ---------------------------------------------------------------- политропы

LE_MAX :: 6000

// Решение уравнения Лейна — Эмдена: θ'' + 2θ'/ξ + θⁿ = 0, θ(0) = 1.
Lane_Emden :: struct {
	n:      f64,
	h:      f64, // шаг по ξ
	count:  int,
	theta:  [LE_MAX]f64,
	dtheta: [LE_MAX]f64,
	xi1:    f64, // поверхность (θ = 0)
	mass1:  f64, // −ξ1²·θ'(ξ1) — безразмерная масса
}

lane_emden :: proc(n: f64) -> ^Lane_Emden {
	le := new(Lane_Emden)
	le.n = n
	le.h = 12.0 / f64(LE_MAX - 10)
	f :: proc(n, xi, th, dth: f64) -> (a, b: f64) {
		return dth, -math.pow(max(th, 0), n) - 2 / xi * dth
	}
	h := le.h
	xi := h
	th := 1 - xi * xi / 6 + n * xi * xi * xi * xi / 120
	dth := -xi / 3 + n * xi * xi * xi / 30
	le.theta[0], le.dtheta[0] = 1, 0
	le.theta[1], le.dtheta[1] = th, dth
	k := 1
	for k < LE_MAX - 2 {
		a1, b1 := f(n, xi, th, dth)
		a2, b2 := f(n, xi + h / 2, th + a1 * h / 2, dth + b1 * h / 2)
		a3, b3 := f(n, xi + h / 2, th + a2 * h / 2, dth + b2 * h / 2)
		a4, b4 := f(n, xi + h, th + a3 * h, dth + b3 * h)
		nth := th + h / 6 * (a1 + 2 * a2 + 2 * a3 + a4)
		ndth := dth + h / 6 * (b1 + 2 * b2 + 2 * b3 + b4)
		if nth <= 0 {
			fr := th / (th - nth)
			le.xi1 = xi + h * fr
			d1 := dth + (ndth - dth) * fr
			le.mass1 = le.xi1 * le.xi1 * -d1
			k += 1
			le.theta[k], le.dtheta[k] = 0, d1
			break
		}
		xi += h
		th, dth = nth, ndth
		k += 1
		le.theta[k], le.dtheta[k] = th, dth
	}
	le.count = k + 1
	return le
}

// Политропа массой M (кг) и радиусом R (м).
Polytrope :: struct {
	le:          ^Lane_Emden,
	mass, radius: f64,
	alpha:       f64, // масштаб: r = α·ξ
	rhoc, pc:    f64, // кг/м³, Па
}

polytrope_make :: proc(n, mass, radius: f64) -> (p: Polytrope) {
	p.le = lane_emden(n)
	p.mass, p.radius = mass, radius
	p.alpha = radius / p.le.xi1
	p.rhoc = mass / (4 * math.PI * p.alpha * p.alpha * p.alpha * p.le.mass1)
	p.pc = 4 * math.PI * G_SI * p.alpha * p.alpha * p.rhoc * p.rhoc / (n + 1)
	return
}

// θ, плотность, давление и масса внутри радиуса x·R.
polytrope_at :: proc(p: ^Polytrope, x: f64) -> (theta, rho, pres, m: f64) {
	xi := clamp(x, 0, 1) * p.le.xi1
	f := xi / p.le.h
	k := min(int(f), p.le.count - 2)
	t := f - f64(k)
	theta = max(math.lerp(p.le.theta[k], p.le.theta[k + 1], t), 0)
	dth := math.lerp(p.le.dtheta[k], p.le.dtheta[k + 1], t)
	rho = p.rhoc * math.pow(theta, p.le.n)
	pres = p.pc * math.pow(theta, p.le.n + 1)
	m = 4 * math.PI * p.alpha * p.alpha * p.alpha * p.rhoc * xi * xi * -dth
	return
}

// Радиус (доля R), внутри которого доля массы q.
polytrope_radius_of_mass :: proc(p: ^Polytrope, q: f64) -> f64 {
	lo, hi := 0.0, 1.0
	for _ in 0 ..< 40 {
		mid := (lo + hi) / 2
		_, _, _, m := polytrope_at(p, mid)
		if m / p.mass < q {
			lo = mid
		} else {
			hi = mid
		}
	}
	return (lo + hi) / 2
}

// ---------------------------------------------------------------- строение

Star_Stage :: enum u8 {
	Main_Sequence,
	Red_Giant, // горит водород в слое вокруг гелиевого ядра
	Clump, // в ядре горит гелий
	Bright_Giant, // асимптотическая ветвь: углеродно-кислородное ядро
	White_Dwarf,
	Neutron,
	Black_Hole,
}

STAR_STAGE_NAMES := [Star_Stage]string {
	.Main_Sequence = "главная последовательность: в ядре горит водород",
	.Red_Giant     = "красный гигант: гелиевое ядро сжимается, водород горит в слое вокруг",
	.Clump         = "красный гигант «сгущения»: в ядре горит гелий",
	.Bright_Giant  = "яркий гигант: углеродное ядро, гелий и водород горят в слоях",
	.White_Dwarf   = "белый карлик: остывающее ядро умершей звезды",
	.Neutron       = "нейтронная звезда: остаток взрыва сверхновой",
	.Black_Hole    = "чёрная дыра: остаток массивной звезды",
}

Star_Zone_Kind :: enum u8 {
	Core, // ядро: горит водород (излучение)
	Conv_Core, // конвективное ядро
	Radiative, // зона лучистого переноса
	Convective, // конвективная зона
	Photosphere,
	Chromosphere,
	Corona,
	Wind, // звёздный ветер горячих звёзд
	He_Core, // вырожденное гелиевое ядро
	He_Burning, // ядро, где горит гелий
	CO_Core, // углеродно-кислородное ядро
	H_Shell, // слой, где горит водород
	He_Shell, // слой, где горит гелий
	Envelope, // огромная конвективная оболочка гиганта
	Degenerate, // вырожденный углерод и кислород (белый карлик)
	Crystal, // кристаллизованное ядро белого карлика
	He_Layer,
	H_Atmosphere,
	NS_Outer_Crust,
	NS_Inner_Crust,
	NS_Outer_Core,
	NS_Inner_Core,
	BH_Singularity,
	BH_Horizon,
	BH_Photon,
	BH_ISCO,
}

STAR_ZONE_NAMES := [Star_Zone_Kind]string {
	.Core           = "ядро: горит водород",
	.Conv_Core      = "конвективное ядро",
	.Radiative      = "зона лучистого переноса",
	.Convective     = "конвективная зона",
	.Photosphere    = "фотосфера",
	.Chromosphere   = "хромосфера",
	.Corona         = "корона",
	.Wind           = "звёздный ветер",
	.He_Core        = "гелиевое ядро",
	.He_Burning     = "ядро: горит гелий",
	.CO_Core        = "углеродно-кислородное ядро",
	.H_Shell        = "слой: горит водород",
	.He_Shell       = "слой: горит гелий",
	.Envelope       = "конвективная оболочка",
	.Degenerate     = "углерод и кислород",
	.Crystal        = "кристаллическое ядро",
	.He_Layer       = "гелиевый слой",
	.H_Atmosphere   = "водородная атмосфера",
	.NS_Outer_Crust = "внешняя кора",
	.NS_Inner_Crust = "внутренняя кора",
	.NS_Outer_Core  = "внешнее ядро",
	.NS_Inner_Core  = "внутреннее ядро",
	.BH_Singularity = "центр (сингулярность)",
	.BH_Horizon     = "горизонт событий",
	.BH_Photon      = "фотонная сфера",
	.BH_ISCO        = "последняя устойчивая орбита",
}

STAR_ZONE_STATES := [Star_Zone_Kind]string {
	.Core           = "тепло уходит излучением",
	.Conv_Core      = "горит водород, кипит",
	.Radiative      = "свет идёт тысячи лет",
	.Convective     = "кипит, как вода",
	.Photosphere    = "отсюда уходит свет",
	.Chromosphere   = "разрежено, теплеет",
	.Corona         = "миллионы градусов",
	.Wind           = "сдувается светом",
	.He_Core        = "вырожденный газ",
	.He_Burning     = "гелий → углерод, кислород",
	.CO_Core        = "вырожденный газ",
	.H_Shell        = "водород → гелий",
	.He_Shell       = "гелий → углерод",
	.Envelope       = "разрежена, кипит",
	.Degenerate     = "вырожденный газ",
	.Crystal        = "кристалл",
	.He_Layer       = "вырожденный газ",
	.H_Atmosphere   = "газ",
	.NS_Outer_Crust = "ядра железа, электроны",
	.NS_Inner_Crust = "ядра + свободные нейтроны",
	.NS_Outer_Core  = "нейтронная жидкость",
	.NS_Inner_Core  = "неизвестно (кварки?)",
	.BH_Singularity = "законы физики молчат",
	.BH_Horizon     = "отсюда не выйти",
	.BH_Photon      = "свет ходит по кругу",
	.BH_ISCO        = "ближе — падение",
}

Star_Zone :: struct {
	kind:       Star_Zone_Kind,
	r0, r1:     f64, // от центра, доли радиуса звезды (у короны — больше 1)
	t0, t1:     f64, // К
	rho0, rho1: f64, // кг/м³
}

Star_Structure :: struct {
	stage:        Star_Stage,
	zones:        [12]Star_Zone,
	n:            int,
	// центр
	tc:           f64, // К
	rhoc:         f64, // кг/м³
	pc:           f64, // Па
	// состав и горение
	x0, y0, z:    f64, // водород, гелий, металлы при рождении
	xc:           f64, // водород в центре сейчас
	burned:       f64, // доля водорода в ядре, ставшего гелием
	mu_c:         f64,
	beta:         f64, // доля давления газа (остальное — давление света)
	pp_share:     f64,
	cno_share:    f64,
	he_share:     f64, // горение гелия
	core_r:       f64, // где вырабатывается 99% энергии, доля радиуса
	fully_conv:   bool,
	// поверхность
	g:            f64, // м/с²
	v_esc:        f64, // км/с
	// жизнь звезды
	t_ms:         f64, // млрд лет на главной последовательности
	remaining:    f64, // млрд лет до конца горения водорода в ядре
	birth_lum:    f64, // светимость при рождении относительно нынешней
	fate_mass:    f64, // масса остатка, масс Солнца
	giant_au:     f64, // до какого радиуса раздуется гигантом, а.е.
	// вращение и активность
	rot_days:     f64,
	rossby:       f64,
	xray:         f64, // доля рентгена в светимости
	corona_k:     f64,
	spots:        f64, // доля поверхности под пятнами
	flare_years:  f64, // как часто сильная вспышка (как событие Кэррингтона), лет
	wind:         f64, // потеря массы, масс Солнца в год
	// гиганты
	core_mass:    f64, // масс Солнца
	shell_t:      f64,
	// белые карлики
	cool_gyr:     f64,
	crystal:      f64, // доля радиуса, ставшая кристаллом
	// нейтронные звёзды
	b_tesla:      f64,
	spin_s:       f64,
	redshift:     f64, // замедление времени у поверхности (√(1 − r_s/R))
	// чёрные дыры
	bh_spin:      f64,
	horizon_km:   f64,
	photon_km:    f64,
	isco_km:      f64,
	hawking_k:    f64,
	evaporate_yr: f64,
	tidal_km:     f64, // ближе — человека разорвёт приливом
	mean_rho:     f64, // кг/м³ (у чёрной дыры — масса / объём под горизонтом)
}

@(private = "file")
mean_mu :: proc(x, y, z: f64) -> f64 {
	return 1 / (2 * x + 0.75 * y + 0.5 * z) // полностью ионизованный газ
}

// Доля давления газа: 1 − β = 0,003·μ⁴·M²·β⁴ (Эддингтон; M в массах Солнца).
@(private = "file")
eddington_beta :: proc(mass, mu: f64) -> f64 {
	b := 1.0
	for _ in 0 ..< 60 {
		nb := 1 - 0.003 * mu * mu * mu * mu * mass * mass * b * b * b * b
		b += (clamp(nb, 0.05, 1) - b) * 0.5
	}
	return b
}

@(private = "file")
add_zone :: proc(st: ^Star_Structure, z: Star_Zone) {
	if st.n < len(st.zones) {
		st.zones[st.n] = z
		st.n += 1
	}
}

@(private = "file")
lerp_table :: proc(xs, ys: []f64, x: f64) -> f64 {
	if x <= xs[0] do return ys[0]
	for i in 1 ..< len(xs) {
		if x <= xs[i] do return math.lerp(ys[i - 1], ys[i], (x - xs[i - 1]) / (xs[i] - xs[i - 1]))
	}
	return ys[len(ys) - 1]
}

// Показатель цвета B−V по температуре (обращение формулы Бальестероса).
@(private = "file")
b_v :: proc(teff: f64) -> f64 {
	lo, hi := -0.4, 2.5
	for _ in 0 ..< 50 {
		mid := (lo + hi) / 2
		t := 4600 * (1 / (0.92 * mid + 1.7) + 1 / (0.92 * mid + 0.62))
		if t > teff {
			lo = mid
		} else {
			hi = mid
		}
	}
	return (lo + hi) / 2
}

// Строение звезды s в возрасте age (млрд лет); metal — металличность [Fe/H].
star_structure_make :: proc(s: Star, age, metal: f64) -> (st: Star_Structure) {
	st.z = 0.014 * math.pow(10, metal)
	st.x0 = 0.7392 - 2 * st.z
	st.y0 = 1 - st.x0 - st.z
	M := max(s.mass, 0.08) * SUN_MASS_KG
	R := max(s.radius, 1e-9) * SUN_RADIUS_M
	st.g = G_SI * M / (R * R)
	st.v_esc = math.sqrt(2 * G_SI * M / R) / 1000
	st.mean_rho = M / (4.0 / 3 * math.PI * R * R * R)
	st.t_ms = star_lifetime_gyr(s.mass)
	switch s.class {
	case .M, .K, .G, .F, .A, .B, .O:
		main_sequence(&st, s, age)
	case .Red_Giant:
		giant(&st, s, age)
	case .White_Dwarf:
		white_dwarf(&st, s, age)
	case .Neutron:
		neutron_star(&st, s)
	case .Black_Hole:
		black_hole(&st, s)
	}
	if s.class != .Black_Hole && s.class != .Neutron && s.class != .White_Dwarf do activity(&st, s, age)
	return
}

// Звезда главной последовательности.
@(private = "file")
main_sequence :: proc(st: ^Star_Structure, s: Star, age: f64) {
	st.stage = .Main_Sequence
	mass := s.mass
	M := mass * SUN_MASS_KG
	R := s.radius * SUN_RADIUS_M
	frac := age / st.t_ms
	st.fully_conv = mass < 0.35
	// выгорание: красный карлик перемешан — горит весь водород звезды, медленно
	burn := st.fully_conv ? clamp(0.9 * frac, 0, 0.95) : clamp(1.13 * frac, 0, 0.98)
	st.xc = st.x0 * (1 - burn)
	st.burned = burn
	st.remaining = max(st.t_ms - age, 0)
	mu0 := mean_mu(st.x0, st.y0, st.z)
	st.mu_c = mean_mu(st.xc, 1 - st.xc - st.z, st.z)
	st.beta = eddington_beta(mass, mu0)
	n := st.fully_conv ? 1.5 : 3.0
	poly := polytrope_make(n, M, R)
	defer free(poly.le)
	// центр: выгоревшее ядро плотнее; поправки сверены с моделью Солнца
	// (сейчас 15,7 млн К и 150 г/см³, при рождении ~13,5 млн К), у самых
	// маленьких карликов часть давления — вырожденные электроны
	// у звёзд массивнее Солнца (конвективное ядро) политропа n = 3 занижает центр — поправка по их моделям
	t_factor := (1.12 - 0.36 * burn) * (1 + 0.4 * smooth01(1.0, 2.5, mass))
	if st.fully_conv do t_factor = 1 / (1 + 0.5 * (0.15 / mass) * (0.15 / mass))
	st.tc = poly.pc * st.mu_c * M_HYDROGEN * st.beta / (poly.rhoc * K_BOLTZ) * t_factor
	concentrate := 1 + 1.85 * burn
	st.rhoc = poly.rhoc * concentrate
	st.pc = st.rhoc * K_BOLTZ * st.tc / (st.mu_c * M_HYDROGEN * st.beta)
	t_at :: proc(p: ^Polytrope, st: ^Star_Structure, x: f64) -> (t, rho: f64) {
		th, r, _, _ := polytrope_at(p, x)
		return st.tc * th, r * (1 + 1.85 * st.burned * math.exp(-(x / 0.1) * (x / 0.1)))
	}

	// горение по радиусу: протон-протонная цепочка ∝ ρ·X²·T⁴, CNO ∝ ρ·X·Z·T¹⁷
	// (у центра Солнца CNO даёт ~7% — отсюда нормировка)
	N :: 400
	l_pp, l_cno := 0.0, 0.0
	lum: [N + 1]f64
	for i in 1 ..= N {
		x := (f64(i) - 0.5) / N
		t, rho := t_at(&poly, st, x)
		if t < 2e6 {
			lum[i] = lum[i - 1]
			continue
		}
		tt := t / 1.57e7
		// чувствительность к теплу: у цепочки ~4 (в холодных ядрах больше, в горячих меньше), у CNO ~19
		nu := 4.0 + 2.0 * clamp((1.5e7 - t) / 1e7, 0, 1) - 0.5 * clamp((t - 1.5e7) / 1e7, 0, 1)
		// выделение на единицу объёма: ρ·ε, а ε ∝ ρ·X²·T^ν
		pp := rho * rho * st.xc * st.xc * math.pow(tt, nu)
		cno := rho * rho * st.xc * 0.34 * CNO_AT_SUN * (st.z / 0.014) * math.pow(tt, 19)
		dv := x * x
		l_pp += pp * dv
		l_cno += cno * dv
		lum[i] = lum[i - 1] + (pp + cno) * dv
	}
	total := max(l_pp + l_cno, 1e-300)
	st.pp_share, st.cno_share = l_pp / total, l_cno / total
	st.core_r = 1
	for i in 1 ..= N {
		if lum[i] >= 0.99 * lum[N] {
			st.core_r = f64(i) / N
			break
		}
	}

	// конвекция — по расчётам моделей звёзд: дно конвективной зоны (доля
	// радиуса) и масса конвективного ядра (доля массы)
	bcz_m := []f64{0.35, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.45}
	bcz_r := []f64{0.0, 0.40, 0.55, 0.60, 0.63, 0.66, 0.69, 0.713, 0.75, 0.80, 0.88, 1.0}
	cc_m := []f64{1.1, 1.2, 1.5, 2, 3, 5, 10, 20, 40, 60, 100}
	cc_q := []f64{0.0, 0.03, 0.08, 0.15, 0.20, 0.24, 0.33, 0.45, 0.60, 0.70, 0.78}
	bcz := st.fully_conv ? 0 : lerp_table(bcz_m, bcz_r, mass)
	qcc := lerp_table(cc_m, cc_q, mass) * (1 - 0.4 * burn) // ядро сжимается по мере выгорания
	rcc := qcc > 0.005 ? polytrope_radius_of_mass(&poly, qcc) : 0
	t_of :: proc(p: ^Polytrope, st: ^Star_Structure, x: f64) -> f64 {t, _ := t_at(p, st, x); return t}
	rho_of :: proc(p: ^Polytrope, st: ^Star_Structure, x: f64) -> f64 {_, r := t_at(p, st, x); return r}
	zone :: proc(st: ^Star_Structure, p: ^Polytrope, kind: Star_Zone_Kind, r0, r1: f64) {
		add_zone(st, {kind, r0, r1, t_of(p, st, r0), t_of(p, st, min(r1, 0.999)), rho_of(p, st, r0), rho_of(p, st, min(r1, 0.999))})
	}
	switch {
	case st.fully_conv:
		zone(st, &poly, .Core, 0, st.core_r)
		zone(st, &poly, .Convective, st.core_r, 1)
	case rcc > 0:
		zone(st, &poly, .Conv_Core, 0, rcc)
		zone(st, &poly, .Radiative, rcc, bcz < 1 ? bcz : 1)
		if bcz < 1 do zone(st, &poly, .Convective, bcz, 1)
	case:
		zone(st, &poly, .Core, 0, st.core_r)
		zone(st, &poly, .Radiative, st.core_r, bcz)
		zone(st, &poly, .Convective, bcz, 1)
	}
	// поверхность: фотосфера ~4 высоты однородной атмосферы
	surface_layers(st, s)
	// будущее
	st.birth_lum = 1 / (1 + 0.87 * min(frac, 1))
	switch {
	case mass < 8:
		st.fate_mass = mass < 0.5 ? 0.9 * mass : 0.109 * mass + 0.394
		st.giant_au = mass < 0.25 ? 0 : 0.9 * math.pow(mass, 0.4)
	case mass < 25:
		st.fate_mass = 1.4
	case:
		st.fate_mass = 0.3 * mass
	}
}

// Фотосфера, хромосфера и корона (или ветер у горячих звёзд).
@(private = "file")
surface_layers :: proc(st: ^Star_Structure, s: Star) {
	teff := s.temperature
	R := s.radius * SUN_RADIUS_M
	h := K_BOLTZ * teff / (1.3 * M_HYDROGEN * st.g) // высота однородной атмосферы
	rho_ph := 2e-4 * math.pow(st.g / 274, 0.6)
	ph := 4 * h / R
	add_zone(st, {.Photosphere, 1, 1 + ph, teff * 1.15, teff * 0.75, rho_ph, rho_ph * 0.05})
	if teff < 7500 {
		chrom := 2.0e6 * (h / 1.4e5) / R // у Солнца ~2000 км
		top := 1 + ph + chrom
		add_zone(st, {.Chromosphere, 1 + ph, top, 4500, 2e4, 1e-8, 1e-10})
		if s.class == .Red_Giant {
			// у гигантов горячей короны нет — медленный холодный ветер
			add_zone(st, {.Wind, top, 3, 8000, 3000, 1e-11, 1e-15})
		} else {
			add_zone(st, {.Corona, top, 3, 1e6, 1.5e6, 1e-12, 1e-14}) // температура — из активности
		}
	} else {
		add_zone(st, {.Wind, 1 + ph, 3, teff * 0.8, teff * 0.5, rho_ph * 1e-4, rho_ph * 1e-8})
	}
}

// Вращение и магнитная активность (у звёзд с конвекцией под поверхностью).
@(private = "file")
activity :: proc(st: ^Star_Structure, s: Star, age: f64) {
	r := eng.rng_make(s.seed ~ TAG_STAR_ACT)
	teff := s.temperature
	bv := b_v(teff)
	if teff < 6300 || s.class == .Red_Giant {
		// с возрастом ветер уносит вращение: P ∝ t^0,52 (Барнс; Солнце — ~26 дней)
		p := 0.7725 * math.pow(max(bv - 0.4, 0.05), 0.601) * math.pow(max(age, 0.01) * 1000, 0.5189)
		if s.class == .Red_Giant do p *= s.radius // раздулся — закрутился медленнее
		st.rot_days = p * eng.rng_range(&r, 0.85, 1.15)
	} else {
		st.rot_days = eng.rng_range(&r, 0.5, 3) // горячие звёзды не тормозятся ветром
	}
	// число Россби: вращение против времени оборота конвекции (Крэнмер и Саар)
	// (у карликов — по массе, Райт и др. 2018: у маленьких конвекция медленная, τ до ~200 сут)
	tau := 314.24 * math.exp(-(teff / 1952.5) - math.pow(teff / 6250, 18)) + 0.002
	if s.mass < 1.2 && s.class != .Red_Giant do tau = math.pow(10, 2.33 - 1.5 * s.mass + 0.31 * s.mass * s.mass)
	if s.class == .Red_Giant do tau = 150
	st.rossby = st.rot_days / tau
	if teff < 7500 {
		st.xray = st.rossby < 0.13 ? 1e-3 : 1e-3 * math.pow(st.rossby / 0.13, -2.7)
	} else {
		st.xray = 1e-7 // горячие звёзды светятся рентгеном от ветра, а не от короны
	}
	R := s.radius * SUN_RADIUS_M
	fx := st.xray * s.luminosity * SUN_LUM_W / (4 * math.PI * R * R)
	fx_sun := 5.7e-7 * SUN_LUM_W / (4 * math.PI * SUN_RADIUS_M * SUN_RADIUS_M)
	act := fx / fx_sun
	st.corona_k = 1.5e6 * math.pow(max(act, 1e-3), 0.26)
	st.spots = teff < 7500 ? clamp(0.003 * math.sqrt(st.xray / 5.7e-7), 0, 0.4) : 0
	st.flare_years = teff < 7500 ? clamp(200 * math.pow(5.7e-7 / st.xray, 1.5), 0.002, 1e7) : 0
	st.wind = teff < 7500 ? 2e-14 * clamp(math.pow(max(act, 1e-3), 1.34), 0.01, 100) : 1e-7 * math.pow(s.luminosity / 1e5, 1.5)
	if s.class == .Red_Giant do st.wind = 1e-8 * s.luminosity * s.radius / max(s.mass, 0.1) * 4e-5 // ветер Реймерса
	for i in 0 ..< st.n {
		if st.zones[i].kind == .Corona do st.zones[i].t0, st.zones[i].t1 = st.corona_k * 0.7, st.corona_k
	}
}

// Красный гигант: вырожденное ядро, слой горения, огромная оболочка.
@(private = "file")
giant :: proc(st: ^Star_Structure, s: Star, age: f64) {
	_ = age
	R := s.radius
	switch {
	case R >= 35:
		st.stage = .Bright_Giant
		st.core_mass = clamp(0.5 + 0.1 * (s.mass - 0.8), 0.52, 0.9)
	case R >= 9 && R < 12:
		st.stage = .Clump
		st.core_mass = 0.47
	case:
		st.stage = .Red_Giant
		// масса ядра по светимости (Пачинский): L ≈ 2,3·10⁵·Mc⁶
		st.core_mass = clamp(math.pow(s.luminosity / 2.3e5, 1.0 / 6), 0.12, 0.47)
	}
	mc := st.core_mass
	// ядро — почти белый карлик (давление вырожденных электронов), чуть горячее и больше
	x := mc / CHANDRASEKHAR
	rc := 1.3 * 0.0126 * math.pow(x, -1.0 / 3) * math.sqrt(max(1 - math.pow(x, 4.0 / 3), 0.01))
	core := polytrope_make(1.5, mc * SUN_MASS_KG, rc * SUN_RADIUS_M)
	defer free(core.le)
	st.rhoc = core.rhoc
	st.pc = core.pc
	#partial switch st.stage {
	case .Clump:
		st.tc = 1.1e8
		st.he_share = 0.35
	case .Bright_Giant:
		st.tc = 2e8
		st.he_share = 0.2
	case:
		st.tc = 1e8 * math.pow(mc / 0.47, 1.4) // у вершины ветви — 100 млн К: вспыхнет гелий
	}
	st.shell_t = 2.5e7 * math.pow(mc / 0.2, 0.8)
	st.cno_share = 1 - st.he_share
	st.burned = 1
	f := rc / R
	env_rho := (s.mass - mc) * SUN_MASS_KG / (4.0 / 3 * math.PI * math.pow(R * SUN_RADIUS_M, 3))
	#partial switch st.stage {
	case .Clump:
		add_zone(st, {.He_Burning, 0, f, st.tc, st.tc * 0.8, st.rhoc, st.rhoc * 0.1})
	case .Bright_Giant:
		add_zone(st, {.CO_Core, 0, f, st.tc, st.tc * 0.9, st.rhoc, st.rhoc * 0.1})
		add_zone(st, {.He_Shell, f, 2 * f, 2e8, 1.5e8, st.rhoc * 0.01, st.rhoc * 1e-3})
	case:
		add_zone(st, {.He_Core, 0, f, st.tc, st.tc, st.rhoc, st.rhoc * 0.1})
	}
	shell_top := st.stage == .Bright_Giant ? 4 * f : 3 * f
	add_zone(st, {.H_Shell, st.zones[st.n - 1].r1, shell_top, st.shell_t, st.shell_t * 0.5, st.rhoc * 1e-3, 10})
	add_zone(st, {.Radiative, shell_top, 0.15, st.shell_t * 0.5, 2e6, 10, env_rho * 50})
	add_zone(st, {.Envelope, 0.15, 1, 2e6, s.temperature * 1.5, env_rho * 50, env_rho * 0.01})
	surface_layers(st, s)
	st.birth_lum = 0
	st.fate_mass = clamp(0.109 * s.mass + 0.394, 0.52, 1.3)
	st.giant_au = s.radius * SUN_RADIUS_M / (AU_KM * 1000)
}

// Белый карлик: вырожденный углерод и кислород, тонкие слои гелия и водорода.
@(private = "file")
white_dwarf :: proc(st: ^Star_Structure, s: Star, age: f64) {
	_ = age
	st.stage = .White_Dwarf
	M := s.mass * SUN_MASS_KG
	R := s.radius * SUN_RADIUS_M
	poly := polytrope_make(1.5, M, R)
	defer free(poly.le)
	st.rhoc, st.pc = poly.rhoc, poly.pc
	// ядро почти одной температуры: L ≈ 6,6·10⁻³·M·(Tc/10⁷ К)^3,5 (Местел)
	st.tc = 1e7 * math.pow(max(s.luminosity, 1e-7) / (6.6e-3 * s.mass), 1 / 3.5)
	st.cool_gyr = 8.8e6 * math.pow(s.mass, 5.0 / 7) * math.pow(max(s.luminosity, 1e-7), -5.0 / 7) / 1e9
	// кристаллизация: где плотность так велика, что ионы «замерзают» в решётку (Γ > 175)
	t_cryst :: proc(rho: f64) -> f64 {
		Z, A :: 7.0, 14.0
		e2 := 2.307e-28 // e²/(4πε₀), Дж·м
		a := math.cbrt(3 / (4 * math.PI * (rho / (A * M_UNIT))))
		return Z * Z * e2 / (a * K_BOLTZ * 175)
	}
	if st.tc < t_cryst(st.rhoc) {
		lo, hi := 0.0, 1.0
		for _ in 0 ..< 40 {
			mid := (lo + hi) / 2
			_, rho, _, _ := polytrope_at(&poly, mid)
			if st.tc < t_cryst(rho) {
				lo = mid
			} else {
				hi = mid
			}
		}
		st.crystal = lo
	}
	_, rho99, _, _ := polytrope_at(&poly, 0.99)
	_, rho_cr, _, _ := polytrope_at(&poly, st.crystal)
	if st.crystal > 0 do add_zone(st, {.Crystal, 0, st.crystal, st.tc, st.tc, st.rhoc, rho_cr})
	add_zone(st, {.Degenerate, st.crystal, 0.99, st.tc, st.tc * 0.95, rho_cr, rho99})
	add_zone(st, {.He_Layer, 0.99, 0.998, st.tc * 0.9, st.tc * 0.1, rho99, rho99 * 1e-3})
	add_zone(st, {.H_Atmosphere, 0.998, 1, st.tc * 0.1, s.temperature, rho99 * 1e-3, 1})
	st.fate_mass = s.mass
}

// Нейтронная звезда: плотность атомного ядра, поле в триллионы раз сильнее земного.
@(private = "file")
neutron_star :: proc(st: ^Star_Structure, s: Star) {
	st.stage = .Neutron
	M := s.mass * SUN_MASS_KG
	R := s.radius * SUN_RADIUS_M
	poly := polytrope_make(1, M, R)
	defer free(poly.le)
	st.rhoc, st.pc = poly.rhoc, poly.pc
	rs := 2 * G_SI * M / (C_LIGHT * C_LIGHT)
	st.redshift = math.sqrt(max(1 - rs / R, 0.01))
	st.g = G_SI * M / (R * R) / st.redshift
	// недра — почти одной температуры (связь с поверхностью по Гудмундссону)
	g14 := st.g / 1e14
	st.tc = 1e9 * math.pow(s.temperature / (3.1e6 * math.pow(g14, 0.25)), 1 / 0.55)
	r := eng.rng_make(s.seed ~ TAG_STAR_ACT)
	roll := eng.rng_f64(&r)
	switch {
	case roll < 0.1: // магнитар
		st.b_tesla = math.pow(10, eng.rng_range(&r, 10, 11))
		st.spin_s = eng.rng_range(&r, 2, 12)
	case roll < 0.2: // миллисекундный пульсар — раскручен соседкой
		st.b_tesla = math.pow(10, eng.rng_range(&r, 3.5, 5))
		st.spin_s = eng.rng_range(&r, 0.0016, 0.01)
	case:
		st.b_tesla = math.pow(10, eng.rng_range(&r, 7.5, 9))
		st.spin_s = math.pow(10, eng.rng_range(&r, -1, 0.6))
	}
	// слои по плотности: кора тонкая (~1 км), дальше — нейтронная жидкость
	outer := 0.4 * (1.4 / s.mass) * math.pow(s.radius * SUN_RADIUS_KM / 12, 2) * 1000 / R
	inner := 2.5 * outer
	core_edge := 1 - outer - inner
	q_outer_core := 0.0
	lo, hi := 0.0, core_edge
	for _ in 0 ..< 40 { // где плотность падает ниже двух ядерных
		mid := (lo + hi) / 2
		_, rho, _, _ := polytrope_at(&poly, mid)
		if rho > 2 * NUCLEAR_DENSITY {
			lo = mid
		} else {
			hi = mid
		}
	}
	q_outer_core = lo
	_, rho_ce, _, _ := polytrope_at(&poly, core_edge)
	if q_outer_core > 0.01 {
		_, rho_q, _, _ := polytrope_at(&poly, q_outer_core)
		add_zone(st, {.NS_Inner_Core, 0, q_outer_core, st.tc, st.tc, st.rhoc, rho_q})
		add_zone(st, {.NS_Outer_Core, q_outer_core, core_edge, st.tc, st.tc, rho_q, max(rho_ce, 1.4e17)})
	} else {
		add_zone(st, {.NS_Outer_Core, 0, core_edge, st.tc, st.tc, st.rhoc, max(rho_ce, 1.4e17)})
	}
	add_zone(st, {.NS_Inner_Crust, core_edge, 1 - outer, st.tc, st.tc * 0.5, 1.4e17, 4.3e14})
	add_zone(st, {.NS_Outer_Crust, 1 - outer, 1, st.tc * 0.5, s.temperature, 4.3e14, 1e5})
	st.v_esc = math.sqrt(2 * G_SI * M / R) / 1000
	st.fate_mass = s.mass
}

// Чёрная дыра: горизонт, фотонная сфера, последняя устойчивая орбита.
@(private = "file")
black_hole :: proc(st: ^Star_Structure, s: Star) {
	st.stage = .Black_Hole
	M := s.mass * SUN_MASS_KG
	r := eng.rng_make(s.seed ~ TAG_STAR_ACT)
	a := eng.rng_range(&r, 0, 0.98) // вращение (0 — не вращается, 1 — предел)
	st.bh_spin = a
	gm := G_SI * M / (C_LIGHT * C_LIGHT) // м
	st.horizon_km = gm * (1 + math.sqrt(1 - a * a)) / 1000
	st.photon_km = 2 * gm * (1 + math.cos(2.0 / 3 * math.acos(-a))) / 1000
	z1 := 1 + math.cbrt(1 - a * a) * (math.cbrt(1 + a) + math.cbrt(1 - a))
	z2 := math.sqrt(3 * a * a + z1 * z1)
	st.isco_km = gm * (3 + z2 - math.sqrt((3 - z1) * (3 + z1 + 2 * z2))) / 1000
	st.hawking_k = 6.17e-8 / s.mass
	st.evaporate_yr = 2.1e67 * s.mass * s.mass * s.mass
	st.tidal_km = math.cbrt(2 * G_SI * M * 2 / (10 * 9.81)) / 1000 // человек 2 м, разница 10 g
	rs := 2 * gm
	st.mean_rho = M / (4.0 / 3 * math.PI * rs * rs * rs)
	h := st.horizon_km * 1000 / rs
	add_zone(st, {.BH_Singularity, 0, 0, 0, 0, 0, 0})
	add_zone(st, {.BH_Horizon, h, h, 0, 0, 0, 0})
	add_zone(st, {.BH_Photon, st.photon_km * 1000 / rs, st.photon_km * 1000 / rs, 0, 0, 0, 0})
	add_zone(st, {.BH_ISCO, st.isco_km * 1000 / rs, st.isco_km * 1000 / rs, 0, 0, 0, 0})
	st.v_esc = C_LIGHT / 1000
	st.fate_mass = s.mass
}
