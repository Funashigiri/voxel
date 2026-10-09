package main

// Рельеф настоящего масштаба (0.012).
//
// Высота поверхности над уровнем моря в метрах — функция точки шара:
//  * поле материков (тысячи км): выше порога — суша, ниже — океан; порог
//    подобран так, чтобы вода планеты (её объём) заполнила впадины (0.013);
//  * океан: шельф 100–200 м у берегов, материковый склон, равнины дна на
//    3–5 км, редкие жёлоба до ~10 км, холмы дна;
//  * суша: низменности и равнины, плато в 1–2 км, горные пояса — длинные
//    хребты из «гребнистого» шума, обычно 2–5 км, редкие вершины до ~8 км;
//    на лёгкой планете горы выше (как Олимп на Марсе);
//  * поверх — местный рельеф прежних версий: холмы и мелкие неровности.
// Всё детерминировано от зерна и точки, без деталей мельче клетки cell
// (для дальнего рельефа): блоки — floor(высота).

import "core:math"
import "core:math/noise"
import "core:slice"
import eng "engine"

Relief :: struct {
	ocean_frac: f64, // доля поверхности под океаном (из запаса воды планеты)
	thr:        f64, // порог поля материков: выше — суша
	mountain_k: f64, // масштаб гор: на лёгкой планете — выше
	depth_k:    f64, // масштаб глубин океана
	h_max:      f64, // пределы высот, м (для дальнего рельефа)
	h_min:      f64,
}

// Параметры рельефа мира — задаются один раз при старте, до фоновых потоков.
relief: Relief

ROCK_LINE :: 2800.0 // выше — голые скалы, м над морем
TREE_LINE :: 2400.0 // выше деревья не растут

// water_m3 — объём воды на поверхности: доля океана выходит такой, чтобы
// вода заполнила впадины рельефа (0 — случайная, как до 0.013).
relief_init :: proc(seed: u32, radius: f64, gravity_g: f64, water_m3: f64 = 0) {
	r := eng.rng_make(u64(seed) ~ 0x0CEA_11F5)
	relief.ocean_frac = eng.rng_range(&r, 0.1, 0.92)
	relief.mountain_k = clamp(1 / gravity_g, 0.55, 2.5)
	relief.depth_k = clamp(1 / math.sqrt(gravity_g), 0.75, 1.6)
	relief.h_max = 2600 + 7200 * relief.mountain_k
	relief.h_min = -12000 * relief.depth_k
	// порог — квантиль поля материков по равномерным точкам шара
	N :: 4096
	pts := make([][3]f64, N, context.temp_allocator)
	vals := make([]f64, N, context.temp_allocator)
	s := i64(seed)
	for i in 0 ..< N {
		// спираль Фибоначчи: точки равномерно по сфере
		y := 1 - (f64(i) + 0.5) / N * 2
		rr := math.sqrt(1 - y * y)
		a := f64(i) * 2.399963229728653
		pts[i] = {math.cos(a) * rr, y, math.sin(a) * rr} * radius
		vals[i] = continent(s, pts[i], 20_000)
	}
	slice.sort(vals)
	relief.thr = vals[clamp(int(relief.ocean_frac * N), 0, N - 1)]
	if water_m3 <= 0 do return
	// объём впадин ниже уровня моря при данной доле океана — растёт с ней
	volume :: proc(s: i64, pts: [][3]f64, radius: f64) -> f64 {
		sum := 0.0
		for i := 0; i < len(pts); i += 2 do sum += max(-elevation(s, pts[i], 20_000), 0)
		return sum / f64(len(pts) / 2) * 4 * math.PI * radius * radius
	}
	lo, hi := N / 50, N - N / 50
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		relief.thr = vals[mid]
		if volume(s, pts, radius) < water_m3 {
			lo = mid
		} else {
			hi = mid
		}
	}
	relief.ocean_frac = f64(hi) / N
	relief.thr = vals[hi]
}

@(private = "file")
smooth :: proc(e0, e1, x: f64) -> f64 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}

@(private = "file")
fl :: #force_inline proc(seed: i64, p: [3]f64, scale: f64, octaves: int, cell: f64) -> f64 {
	return f64(fbm_lod(seed, p, scale, octaves, cell))
}

// Поле материков: крупные массивы суши, их очертания, полуострова.
@(private = "file")
continent :: proc(seed: i64, p: [3]f64, cell: f64) -> f64 {
	return fl(seed + 301, p, 2_600_000, 5, cell) + 0.35 * fl(seed + 302, p, 420_000, 4, cell) + 0.1 * fl(seed + 303, p, 90_000, 3, cell)
}

// Среднее (1 − |шум|)² одной октавы — им заменяются октавы мельче клетки (проверяется в -selftest).
RIDGE1_MEAN :: 0.5

// «Гребнистый» мультифрактал (0..1): острые хребты, детали гуще там, где уже высоко.
ridged_lod :: proc(seed: i64, p: [3]f64, scale: f64, octaves: int, cell: f64) -> f64 {
	sum, amp, norm, weight := 0.0, 1.0, 0.0, 1.0
	freq := 1 / scale
	wave := scale
	for i in 0 ..< octaves {
		r := RIDGE1_MEAN
		if w := clamp(wave / cell - 2, 0, 1); w > 0 {
			n := f64(noise.noise_3d_improve_xz(seed + i64(i) * 7919, p * freq))
			rr := (1 - abs(n)) * (1 - abs(n))
			r = math.lerp(RIDGE1_MEAN, rr, w)
		}
		r *= weight
		weight = clamp(r * 2, 0, 1)
		sum += r * amp
		norm += amp
		amp *= 0.5
		freq *= 2
		wave *= 0.5
	}
	return sum / norm
}

// Высота поверхности над уровнем моря, м (дно океана — со знаком минус),
// без деталей мельче клетки cell, м.
elevation :: proc(seed: i64, p: [3]f64, cell: f64) -> f64 {
	d := continent(seed, p, cell) - relief.thr
	e: f64
	if d < 0 {
		x := -d
		shelf := 160 * smooth(0, 0.012, x) // шельф у берегов
		slope := 3600 * smooth(0.012, 0.045, x) // материковый склон
		abyss := 1600 * smooth(0.045, 0.16, x) // к середине океанов — глубже
		hills := 0.0
		if x > 0.03 do hills = 350 * fl(seed + 310, p, 25_000, 3, cell) * smooth(0.03, 0.06, x) // холмы дна
		trench := 0.0
		if x > 0.06 {
			t := 1 - abs(fl(seed + 311, p, 900_000, 2, cell)) // глубоководные жёлоба — редкие длинные борозды
			trench = 5000 * smooth(0.965, 1, t) * smooth(0.06, 0.1, x)
		}
		e = -(shelf + slope + abyss + hills + trench) * relief.depth_k
	} else {
		inland := smooth(0, 0.1, d)
		e = 380 * inland * (0.55 + 0.45 * fl(seed + 320, p, 300_000, 3, cell)) // низменности и равнины
		e += 1600 * smooth(0.12, 0.38, fl(seed + 321, p, 900_000, 3, cell)) * smooth(0.04, 0.14, d) // плато
		// горные пояса — длинные хребты
		belt := smooth(0.62, 0.86, 1 - abs(fl(seed + 322, p, 1_400_000, 3, cell))) * smooth(0.01, 0.06, d)
		if belt > 0 {
			rm := ridged_lod(seed + 323, p, 70_000, 9, cell)
			e += 7000 * relief.mountain_k * belt * math.pow(rm, 1.6)
		}
	}
	// местный рельеф прежних версий: холмы и мелкие неровности
	cont := fl(seed, p, 600, 3, cell)
	e += cont * 14 + fl(seed + 11, p, 140, 4, cell) * (5 + 10 * clamp(cont + 0.3, 0, 1)) + fl(seed + 23, p, 36, 2, cell) * 1.8
	return e
}

// Высота поверхности (последний блок земли) в точке шара p.
terrain_height :: proc(seed: i64, p: [3]f64) -> i32 {
	return i32(math.floor(elevation(seed, p, 0.5) + Y_SEA - 0.5))
}

// То же для дальнего рельефа: непрерывно и без деталей мельче клетки cell, м.
// Блоки — floor(v), их верх в среднем на v + 0,5.
terrain_height_lod :: proc(seed: i64, p: [3]f64, cell: f64) -> f64 {
	return elevation(seed, p, cell) + Y_SEA - 0.5
}

// Высота над морем, выше которой — голые скалы (с волнистой границей).
rock_line :: proc(seed: i64, p: [3]f64, cell: f64) -> f64 {
	return ROCK_LINE + 250 * fl(seed + 151, p, 300, 2, cell)
}

// Густота леса: 0.03..0.93, к границе леса в горах редеет.
forest_density :: proc(seed: i64, p: [3]f64, alt: f64, cell: f64 = 0.5) -> f32 {
	f := fbm_lod(seed + 88, p, 220, 3, cell)
	return (0.03 + 0.9 * eng.smoothstep(0.02, 0.35, f)) * f32(1 - smooth(TREE_LINE - 600, TREE_LINE, alt))
}

// Высота земли в вершине куба (у аномалии): столп поднимается над ней.
anomaly_ground :: proc(seed: u32, radius: f64, corner: int) -> i32 {
	@(static) cache: [8]i32
	@(static) known: [8]bool
	@(static) cached_seed: u32
	if cached_seed != seed {
		known = {}
		cached_seed = seed
	}
	if !known[corner] {
		d := ANOMALY_DIRS[corner] / math.sqrt(f64(3))
		cache[corner] = max(terrain_height(i64(seed), d * radius), SEA_LEVEL)
		known[corner] = true
	}
	return cache[corner]
}

MONOLITH_ABOVE :: 64 // столп выше земли в вершине куба, блоков
