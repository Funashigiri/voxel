package main

// Процедурные пиксельные текстуры 16x16 в стиле Minecraft.
// Все текстуры рисуются кодом (никаких чужих ассетов), бесшовно тайлятся.

import "core:math"
import "core:strings"
import eng "engine"
import stbi "vendor:stb/image"

TEX_SIZE :: 16
WATER_FRAMES :: 32

Tex :: enum u8 {
	Stone,
	Dirt,
	Grass_Top,
	Grass_Side,
	Sand,
	Gravel,
	Bedrock,
	Oak_Log,
	Oak_Log_Top,
	Oak_Leaves,
	Birch_Log,
	Birch_Log_Top,
	Birch_Leaves,
	Tall_Grass,
	Dandelion,
	Poppy,
	Scorched,
	Monolith,
	Sandstone,
	Limestone,
	Granite,
	Basalt,
	Peridotite,
	Ringwoodite,
	Bridgmanite,
	Molten_Iron,
	Iron_Core,
	// климат (0.015)
	Snow,
	Ice,
	Spruce_Log,
	Spruce_Log_Top,
	Spruce_Leaves,
	Acacia_Log,
	Acacia_Log_Top,
	Acacia_Leaves,
	Jungle_Log,
	Jungle_Log_Top,
	Jungle_Leaves,
	Cactus_Side,
	Cactus_Top,
	Dead_Bush,
	Water, // первый кадр анимации воды, за ним ещё WATER_FRAMES-1 слоёв
}

TEX_LAYER_COUNT :: int(Tex.Water) + WATER_FRAMES

RGBA :: [4]u8
Pixels :: [TEX_SIZE * TEX_SIZE]RGBA

@(private = "file")
rgb :: proc "contextless" (r, g, b: u8) -> RGBA {return {r, g, b, 255}}

@(private = "file")
h :: proc(x, y: int, seed: u32) -> f32 {return eng.hash2f(i32(x), i32(y), seed)}

@(private = "file")
vn :: proc(x, y: int, cell: f32, seed: u32) -> f32 {
	return eng.tile_value_noise(f32(x), f32(y), cell, i32(f32(TEX_SIZE) / cell), seed)
}

@(private = "file")
pick :: proc(pal: []RGBA, t: f32) -> RGBA {
	i := clamp(int(t * f32(len(pal))), 0, len(pal) - 1)
	return pal[i]
}

@(private = "file")
stretch :: proc(n, lo, hi: f32) -> f32 {return clamp((n - lo) / (hi - lo), 0, 0.999)}

@(private = "file")
put :: proc(img: ^Pixels, x, y: int, c: RGBA) {
	if x < 0 || y < 0 || x >= TEX_SIZE || y >= TEX_SIZE do return
	img[y * TEX_SIZE + x] = c
}

@(private = "file")
mix_rgb :: proc(a, b: RGBA, t: f32) -> RGBA {
	return {
		u8(math.lerp(f32(a.r), f32(b.r), t)),
		u8(math.lerp(f32(a.g), f32(b.g), t)),
		u8(math.lerp(f32(a.b), f32(b.b), t)),
		255,
	}
}

GRASS_PAL := []RGBA{{78, 117, 44, 255}, {88, 130, 50, 255}, {97, 142, 55, 255}, {105, 152, 60, 255}, {113, 161, 65, 255}, {123, 171, 71, 255}}
DIRT_PAL := []RGBA{{89, 62, 42, 255}, {106, 75, 52, 255}, {119, 85, 58, 255}, {132, 95, 66, 255}, {132, 95, 66, 255}, {144, 104, 72, 255}, {156, 114, 80, 255}}
OAK_BARK_PAL := []RGBA{{66, 51, 30, 255}, {80, 62, 37, 255}, {94, 74, 44, 255}, {104, 82, 49, 255}, {116, 92, 56, 255}}

@(private = "file")
gen_stone :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(94, 94, 94), rgb(108, 108, 108), rgb(118, 118, 118), rgb(125, 125, 125), rgb(125, 125, 125), rgb(133, 133, 133), rgb(143, 143, 143)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.5 * vn(x, y, 4, 1) + 0.3 * vn(x, y, 2, 2) + 0.2 * h(x, y, 3)
		img[y * TEX_SIZE + x] = pick(pal, stretch(n, 0.18, 0.82))
	}
	return
}

@(private = "file")
gen_dirt :: proc() -> (img: Pixels) {
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.75 * h(x, y, 10) + 0.25 * vn(x, y, 4, 11)
		img[y * TEX_SIZE + x] = pick(DIRT_PAL, stretch(n, 0.1, 0.9))
	}
	return
}

@(private = "file")
gen_grass_top :: proc() -> (img: Pixels) {
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.7 * h(x, y, 20) + 0.3 * vn(x, y, 4, 21)
		img[y * TEX_SIZE + x] = pick(GRASS_PAL, stretch(n, 0.1, 0.9))
	}
	return
}

@(private = "file")
gen_grass_side :: proc() -> (img: Pixels) {
	img = gen_dirt()
	for x in 0 ..< TEX_SIZE {
		fringe := 3
		if h(x, 0, 22) < 0.55 do fringe += 1
		if fringe == 4 && h(x, 0, 23) < 0.3 do fringe += 1
		for y in 0 ..< fringe {
			n := 0.7 * h(x, y, 24) + 0.3 * vn(x, y, 4, 21)
			c := pick(GRASS_PAL, stretch(n, 0.1, 0.9))
			if y == fringe - 1 do c = mix_rgb(c, rgb(60, 96, 34), 0.35)
			img[y * TEX_SIZE + x] = c
		}
	}
	return
}

@(private = "file")
gen_sand :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(204, 191, 144), rgb(212, 199, 153), rgb(218, 206, 161), rgb(223, 212, 168), rgb(229, 219, 177)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.8 * h(x, y, 30) + 0.2 * vn(x, y, 4, 31)
		c := pick(pal, stretch(n, 0.1, 0.9))
		if h(x, y, 32) < 0.05 do c = rgb(193, 177, 130)
		img[y * TEX_SIZE + x] = c
	}
	return
}

@(private = "file")
gen_gravel :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(84, 79, 77), rgb(102, 96, 93), rgb(119, 114, 111), rgb(136, 131, 128), rgb(154, 148, 144), rgb(124, 111, 102)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.6 * vn(x, y, 2, 40) + 0.4 * h(x, y, 41)
		img[y * TEX_SIZE + x] = pick(pal, stretch(n, 0.15, 0.85))
	}
	return
}

@(private = "file")
gen_bedrock :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(34, 34, 34), rgb(56, 56, 56), rgb(82, 82, 82), rgb(108, 108, 108), rgb(138, 138, 138)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.6 * vn(x, y, 2, 45) + 0.4 * h(x, y, 46)
		img[y * TEX_SIZE + x] = pick(pal, stretch(n, 0.15, 0.85))
	}
	return
}

@(private = "file")
gen_log_side :: proc(pal: []RGBA, seed: u32) -> (img: Pixels) {
	for x in 0 ..< TEX_SIZE {
		col := h(x, 0, seed)
		phase := int(h(x, 1, seed + 1) * 4)
		for y in 0 ..< TEX_SIZE {
			seg := h(x, (y + phase) / 4, seed + 2)
			n := 0.5 * col + 0.3 * seg + 0.2 * h(x, y, seed + 3)
			c := pick(pal, stretch(n, 0.15, 0.85))
			if col < 0.18 && h(x, y, seed + 4) < 0.8 do c = pal[0]
			img[y * TEX_SIZE + x] = c
		}
	}
	return
}

@(private = "file")
gen_log_top :: proc(bark: []RGBA, light, mid, dark: RGBA, seed: u32) -> (img: Pixels) {
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		if x == 0 || y == 0 || x == TEX_SIZE - 1 || y == TEX_SIZE - 1 {
			img[y * TEX_SIZE + x] = pick(bark, h(x, y, seed))
			continue
		}
		dx := f32(x) - 7.5
		dy := f32(y) - 7.5
		cheb := max(abs(dx), abs(dy))
		eu := math.sqrt(dx * dx + dy * dy)
		r := 0.65 * cheb + 0.35 * eu + (h(x, y, seed + 1) - 0.5) * 0.7
		c: RGBA
		switch int(r) % 3 {
		case 0:
			c = light
		case 1:
			c = mid
		case:
			c = dark
		}
		if r < 1.2 do c = dark
		img[y * TEX_SIZE + x] = c
	}
	return
}

@(private = "file")
gen_leaves :: proc(pal: []RGBA, seed: u32) -> (img: Pixels) {
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.6 * h(x, y, seed) + 0.4 * vn(x, y, 4, seed + 1)
		c := pick(pal, stretch(n, 0.12, 0.88))
		hole := h(x, y, seed + 2)
		if hole < 0.16 || (vn(x, y, 2, seed + 3) < 0.3 && hole < 0.42) do c.a = 0
		img[y * TEX_SIZE + x] = c
	}
	return
}

@(private = "file")
gen_birch_log :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(196, 195, 186), rgb(208, 207, 199), rgb(217, 216, 209), rgb(226, 226, 220)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		img[y * TEX_SIZE + x] = pick(pal, 0.7 * h(x, y, 70) + 0.3 * vn(x, y, 4, 71))
	}
	for y in 0 ..< TEX_SIZE {
		if h(0, y, 72) > 0.38 do continue
		start := int(h(1, y, 73) * TEX_SIZE)
		length := 2 + int(h(2, y, 74) * 5)
		for i in 0 ..< length {
			x := (start + i) % TEX_SIZE
			c := (i == 0 || i == length - 1) ? rgb(84, 78, 66) : rgb(46, 43, 37)
			img[y * TEX_SIZE + x] = c
		}
	}
	return
}

@(private = "file")
gen_tall_grass :: proc() -> (img: Pixels) {
	dark := rgb(58, 98, 32)
	light := rgb(118, 172, 66)
	for x in 1 ..< TEX_SIZE - 1 {
		if h(x, 0, 80) > 0.62 do continue
		height := 5 + int(h(x, 1, 81) * 10)
		lean := 0
		if h(x, 2, 82) < 0.35 do lean = h(x, 3, 83) < 0.5 ? -1 : 1
		for i in 0 ..< height {
			y := TEX_SIZE - 1 - i
			xx := x + (i > height / 2 ? lean : 0)
			t := f32(i) / f32(height) * 0.8 + h(x, y, 84) * 0.2
			put(&img, xx, y, mix_rgb(dark, light, t))
		}
	}
	return
}

@(private = "file")
gen_flower :: proc(petal_light, petal_mid, petal_dark, centre: RGBA) -> (img: Pixels) {
	stem := rgb(62, 116, 32)
	leaf := rgb(78, 138, 40)
	for y in 9 ..< TEX_SIZE do put(&img, 7, y, stem)
	put(&img, 6, 12, leaf);put(&img, 5, 11, leaf);put(&img, 8, 13, leaf)
	put(&img, 9, 12, leaf);put(&img, 6, 13, stem);put(&img, 8, 14, stem)
	// головка цветка
	rows := [5][2]int{{6, 9}, {5, 10}, {5, 10}, {5, 10}, {6, 9}}
	for r, i in rows {
		y := 4 + i
		for x in r[0] ..= r[1] {
			c := petal_mid
			if i == 0 || x == r[0] do c = petal_light
			if i == 4 || x == r[1] do c = petal_dark
			put(&img, x, y, c)
		}
	}
	put(&img, 7, 6, centre);put(&img, 8, 6, centre);put(&img, 7, 7, centre);put(&img, 8, 7, centre)
	return
}

@(private = "file")
gen_scorched :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(34, 30, 27), rgb(44, 38, 33), rgb(54, 46, 39), rgb(64, 54, 45), rgb(72, 60, 49)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.6 * h(x, y, 90) + 0.4 * vn(x, y, 4, 91)
		c := pick(pal, stretch(n, 0.1, 0.9))
		a := h(x, y, 92)
		if a < 0.07 {
			c = rgb(118, 112, 104) // пепел
		} else if a < 0.1 {
			c = rgb(20, 18, 17) // уголь
		}
		img[y * TEX_SIZE + x] = c
	}
	return
}

// Гладкий тёмный камень с едва заметным сиреневым отливом.
@(private = "file")
gen_monolith :: proc() -> (img: Pixels) {
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.7 * vn(x, y, 8, 120) + 0.3 * h(x, y, 121)
		v := 20 + n * 9
		c := rgb(u8(v), u8(v * 0.94), u8(v * 1.25))
		if (x + y * 3) % 16 == 0 && h(x, y, 122) < 0.5 do c = rgb(u8(v + 8), u8(v + 6), u8(v * 1.25 + 12)) // блик
		img[y * TEX_SIZE + x] = c
	}
	return
}

// Песчаник: тёпло-жёлтый, с тонкими горизонтальными прослойками.
@(private = "file")
gen_sandstone :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(176, 140, 92), rgb(190, 153, 101), rgb(201, 164, 110), rgb(210, 174, 119), rgb(219, 185, 129)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		layer := h(0, y, 130) * 0.5 + 0.5 * h(1, y / 2, 131)
		n := 0.45 * layer + 0.35 * h(x, y, 132) + 0.2 * vn(x, y, 4, 133)
		c := pick(pal, stretch(n, 0.15, 0.85))
		if y % 5 == 0 && h(x, y, 134) < 0.7 do c = mix_rgb(c, rgb(150, 112, 70), 0.45)
		img[y * TEX_SIZE + x] = c
	}
	return
}

// Известняк: светлый серо-кремовый, с редкими ракушками.
@(private = "file")
gen_limestone :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(170, 166, 150), rgb(182, 178, 162), rgb(192, 188, 172), rgb(200, 196, 181), rgb(208, 205, 190)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.55 * vn(x, y, 4, 140) + 0.45 * h(x, y, 141)
		c := pick(pal, stretch(n, 0.15, 0.85))
		if h(x, y, 142) < 0.04 do c = rgb(150, 144, 126) // ракушка
		img[y * TEX_SIZE + x] = c
	}
	return
}

// Гранит: серо-розовый, в крапинку — светлые и тёмные кристаллы.
@(private = "file")
gen_granite :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(138, 118, 112), rgb(152, 130, 122), rgb(164, 141, 132), rgb(176, 152, 141)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.4 * vn(x, y, 4, 150) + 0.6 * h(x, y, 151)
		c := pick(pal, stretch(n, 0.1, 0.9))
		s := h(x, y, 152)
		if s < 0.12 {
			c = rgb(44, 40, 40) // тёмная слюда
		} else if s > 0.9 {
			c = rgb(222, 214, 206) // кварц
		}
		img[y * TEX_SIZE + x] = c
	}
	return
}

// Базальт: тёмно-серый, мелкозернистый (застывшая лава, кора океанов).
@(private = "file")
gen_basalt :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(40, 40, 43), rgb(48, 48, 51), rgb(56, 56, 60), rgb(64, 64, 68), rgb(72, 72, 76)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.6 * h(x, y, 160) + 0.4 * vn(x, y, 2, 161)
		c := pick(pal, stretch(n, 0.1, 0.9))
		if h(x, y, 162) < 0.03 do c = rgb(30, 30, 32) // пора
		img[y * TEX_SIZE + x] = c
	}
	return
}

// Перидотит (порода мантии): тёмно-оливковый с зелёными кристаллами оливина.
@(private = "file")
gen_peridotite :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(58, 66, 44), rgb(68, 77, 50), rgb(78, 88, 56), rgb(88, 99, 62)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.5 * vn(x, y, 4, 170) + 0.5 * h(x, y, 171)
		c := pick(pal, stretch(n, 0.1, 0.9))
		if h(x, y, 172) > 0.88 do c = rgb(118, 150, 70) // оливин
		img[y * TEX_SIZE + x] = c
	}
	return
}

// Рингвудит (переходная зона мантии, 410–660 км): оливин под давлением —
// синеватый, с густо-синими кристаллами.
@(private = "file")
gen_ringwoodite :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(52, 58, 78), rgb(60, 68, 92), rgb(70, 78, 106), rgb(80, 90, 120)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.5 * vn(x, y, 4, 180) + 0.5 * h(x, y, 181)
		c := pick(pal, stretch(n, 0.1, 0.9))
		if h(x, y, 182) > 0.86 do c = rgb(70, 92, 196) // кристаллы
		img[y * TEX_SIZE + x] = c
	}
	return
}

// Бриджманит с ферропериклазом (нижняя мантия): плотный, тёмно-бурый,
// с тёмными зёрнами.
@(private = "file")
gen_bridgmanite :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(62, 50, 42), rgb(72, 58, 48), rgb(82, 66, 54), rgb(94, 76, 62)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.4 * vn(x, y, 2, 190) + 0.6 * h(x, y, 191)
		c := pick(pal, stretch(n, 0.1, 0.9))
		if h(x, y, 192) < 0.1 do c = rgb(38, 34, 32) // ферропериклаз
		img[y * TEX_SIZE + x] = c
	}
	return
}

// Жидкое железо внешнего ядра: раскалённое добела, с более тёмными струями.
@(private = "file")
gen_molten_iron :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(214, 96, 24), rgb(238, 140, 40), rgb(252, 190, 70), rgb(255, 232, 150)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.7 * vn(x, y, 4, 200) + 0.3 * vn(x, y, 2, 201)
		img[y * TEX_SIZE + x] = pick(pal, stretch(n, 0.15, 0.85))
	}
	return
}

// Железо с никелем (твёрдое внутреннее ядро): металл с отблесками кристаллов.
@(private = "file")
gen_iron_core :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(118, 116, 112), rgb(136, 134, 130), rgb(154, 152, 148), rgb(176, 174, 170)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		n := 0.6 * vn(x, y, 8, 210) + 0.4 * h(x, y, 211)
		c := pick(pal, stretch(n, 0.1, 0.9))
		if h(x, y, 212) > 0.93 do c = rgb(214, 212, 206) // блеск граней
		img[y * TEX_SIZE + x] = c
	}
	return
}

// Снег: белый с голубоватыми тенями.
@(private = "file")
gen_snow :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(222, 230, 238), rgb(232, 238, 244), rgb(242, 246, 250), rgb(250, 252, 255)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		img[y * TEX_SIZE + x] = pick(pal, 0.5 * h(x, y, 220) + 0.5 * vn(x, y, 4, 221))
	}
	return
}

// Лёд: голубой, с белыми трещинами и пузырьками.
@(private = "file")
gen_ice :: proc() -> (img: Pixels) {
	pal := []RGBA{rgb(142, 178, 222), rgb(156, 190, 230), rgb(170, 202, 236), rgb(186, 214, 242)}
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		c := pick(pal, 0.7 * vn(x, y, 8, 230) + 0.3 * h(x, y, 231))
		if abs(f32(x) - f32(y) * 0.6 - 3 - 4 * vn(0, y, 4, 232)) < 0.6 do c = rgb(214, 232, 248) // трещина
		if h(x, y, 233) > 0.96 do c = rgb(236, 244, 252)
		img[y * TEX_SIZE + x] = c
	}
	return
}

// Кактус сбоку: зелёные рёбра с колючками.
@(private = "file")
gen_cactus_side :: proc() -> (img: Pixels) {
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		rib := x % 4
		c := rib == 0 ? rgb(46, 92, 34) : rib == 2 ? rgb(84, 140, 54) : rgb(64, 118, 44)
		if rib == 2 && (y + x / 4 * 3) % 5 == 0 do c = rgb(226, 222, 170) // колючка
		if h(x, y, 240) < 0.08 do c = rgb(54, 104, 40)
		img[y * TEX_SIZE + x] = c
	}
	return
}

@(private = "file")
gen_cactus_top :: proc() -> (img: Pixels) {
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		dx, dy := f32(x) - 7.5, f32(y) - 7.5
		r := math.sqrt(dx * dx + dy * dy)
		c := int(r) % 3 == 0 ? rgb(70, 124, 48) : rgb(88, 146, 58)
		if r > 7 do c = rgb(46, 92, 34)
		img[y * TEX_SIZE + x] = c
	}
	return
}

// Сухой куст: голые бурые веточки.
@(private = "file")
gen_dead_bush :: proc() -> (img: Pixels) {
	dark := rgb(96, 66, 36)
	light := rgb(146, 104, 58)
	for b in 0 ..< 6 {
		x := 3 + int(h(b, 0, 250) * 10)
		height := 5 + int(h(b, 1, 251) * 8)
		dir := h(b, 2, 252) < 0.5 ? -1 : 1
		for i in 0 ..< height {
			y := TEX_SIZE - 1 - i
			xx := x + dir * (i / 3)
			if xx >= 0 && xx < TEX_SIZE do put(&img, xx, y, mix_rgb(dark, light, f32(i) / f32(height)))
		}
	}
	return
}

@(private = "file")
gen_water :: proc(frame: int) -> (img: Pixels) {
	pal := []RGBA{{38, 76, 184, 168}, {50, 94, 206, 168}, {66, 114, 222, 172}, {94, 142, 236, 178}}
	phase := f32(frame) / f32(WATER_FRAMES) * math.TAU
	for y in 0 ..< TEX_SIZE do for x in 0 ..< TEX_SIZE {
		fx := f32(x) / TEX_SIZE * math.TAU
		fy := f32(y) / TEX_SIZE * math.TAU
		a := math.sin(2 * fx + fy + phase)
		b := math.sin(fx - 2 * fy - 2 * phase)
		c := math.sin(3 * fx + 2 * fy + phase)
		v := (a * 0.5 + b * 0.3 + c * 0.2) * 0.5 + 0.5
		img[y * TEX_SIZE + x] = pick(pal, v)
	}
	return
}

// Прозрачным пикселям даём средний цвет непрозрачных, иначе мипмапы
// дают тёмную "кайму" у листвы и травы.
@(private = "file")
fix_transparent :: proc(img: ^Pixels) {
	sum: [3]f32
	n: f32
	for p in img^ {
		if p.a > 0 {
			sum += {f32(p.r), f32(p.g), f32(p.b)}
			n += 1
		}
	}
	if n == 0 do return
	avg := sum / n
	for &p in img^ {
		if p.a == 0 do p = {u8(avg.r), u8(avg.g), u8(avg.b), 0}
	}
}

gen_texture :: proc(t: Tex) -> Pixels {
	switch t {
	case .Stone:
		return gen_stone()
	case .Dirt:
		return gen_dirt()
	case .Grass_Top:
		return gen_grass_top()
	case .Grass_Side:
		return gen_grass_side()
	case .Sand:
		return gen_sand()
	case .Gravel:
		return gen_gravel()
	case .Bedrock:
		return gen_bedrock()
	case .Oak_Log:
		return gen_log_side(OAK_BARK_PAL, 50)
	case .Oak_Log_Top:
		return gen_log_top(OAK_BARK_PAL, rgb(182, 146, 90), rgb(165, 131, 79), rgb(146, 114, 67), 55)
	case .Oak_Leaves:
		return gen_leaves([]RGBA{rgb(36, 72, 17), rgb(46, 88, 22), rgb(56, 102, 28), rgb(66, 116, 34), rgb(80, 132, 41)}, 60)
	case .Birch_Log:
		return gen_birch_log()
	case .Birch_Log_Top:
		return gen_log_top([]RGBA{rgb(208, 207, 199), rgb(217, 216, 209)}, rgb(206, 187, 133), rgb(189, 169, 117), rgb(170, 150, 101), 75)
	case .Birch_Leaves:
		return gen_leaves([]RGBA{rgb(64, 98, 37), rgb(76, 114, 45), rgb(88, 128, 53), rgb(100, 140, 59), rgb(114, 154, 67)}, 65)
	case .Tall_Grass:
		return gen_tall_grass()
	case .Dandelion:
		return gen_flower(rgb(255, 240, 92), rgb(250, 208, 36), rgb(216, 160, 18), rgb(226, 150, 12))
	case .Poppy:
		return gen_flower(rgb(236, 64, 52), rgb(204, 32, 30), rgb(150, 18, 18), rgb(44, 30, 24))
	case .Scorched:
		return gen_scorched()
	case .Monolith:
		return gen_monolith()
	case .Sandstone:
		return gen_sandstone()
	case .Limestone:
		return gen_limestone()
	case .Granite:
		return gen_granite()
	case .Basalt:
		return gen_basalt()
	case .Ringwoodite:
		return gen_ringwoodite()
	case .Bridgmanite:
		return gen_bridgmanite()
	case .Molten_Iron:
		return gen_molten_iron()
	case .Iron_Core:
		return gen_iron_core()
	case .Peridotite:
		return gen_peridotite()
	case .Snow:
		return gen_snow()
	case .Ice:
		return gen_ice()
	case .Spruce_Log:
		return gen_log_side([]RGBA{rgb(44, 30, 18), rgb(56, 38, 22), rgb(68, 47, 27), rgb(80, 56, 33)}, 260)
	case .Spruce_Log_Top:
		return gen_log_top([]RGBA{rgb(56, 38, 22), rgb(68, 47, 27)}, rgb(150, 112, 66), rgb(132, 97, 56), rgb(112, 81, 46), 265)
	case .Spruce_Leaves:
		return gen_leaves([]RGBA{rgb(24, 52, 34), rgb(30, 62, 40), rgb(36, 72, 46), rgb(44, 84, 54), rgb(52, 96, 62)}, 270)
	case .Acacia_Log:
		return gen_log_side([]RGBA{rgb(88, 82, 72), rgb(104, 97, 86), rgb(118, 110, 98), rgb(132, 124, 110)}, 280)
	case .Acacia_Log_Top:
		return gen_log_top([]RGBA{rgb(104, 97, 86), rgb(118, 110, 98)}, rgb(196, 112, 60), rgb(176, 96, 50), rgb(154, 82, 42), 285)
	case .Acacia_Leaves:
		return gen_leaves([]RGBA{rgb(82, 96, 30), rgb(98, 112, 38), rgb(112, 126, 44), rgb(126, 140, 52), rgb(142, 152, 62)}, 290)
	case .Jungle_Log:
		return gen_log_side([]RGBA{rgb(98, 78, 46), rgb(116, 94, 56), rgb(132, 108, 66), rgb(88, 116, 50)}, 300)
	case .Jungle_Log_Top:
		return gen_log_top([]RGBA{rgb(86, 70, 38), rgb(98, 82, 44)}, rgb(176, 136, 76), rgb(158, 120, 66), rgb(138, 104, 56), 305)
	case .Jungle_Leaves:
		return gen_leaves([]RGBA{rgb(30, 92, 18), rgb(38, 110, 22), rgb(48, 128, 28), rgb(60, 146, 34), rgb(74, 162, 42)}, 310)
	case .Cactus_Side:
		return gen_cactus_side()
	case .Cactus_Top:
		return gen_cactus_top()
	case .Dead_Bush:
		return gen_dead_bush()
	case .Water:
		return gen_water(0)
	}
	return {}
}

// Возвращает пиксели всех слоёв массива текстур (RGBA8).
build_block_textures :: proc(allocator := context.allocator) -> []u8 {
	layer_bytes :: TEX_SIZE * TEX_SIZE * 4
	out := make([]u8, TEX_LAYER_COUNT * layer_bytes, allocator)
	write :: proc(out: []u8, layer: int, img: Pixels) {
		img := img
		fix_transparent(&img)
		base := layer * layer_bytes
		for p, i in img {
			out[base + i * 4 + 0] = p.r
			out[base + i * 4 + 1] = p.g
			out[base + i * 4 + 2] = p.b
			out[base + i * 4 + 3] = p.a
		}
	}
	for t in Tex {
		if t == .Water do continue
		write(out, int(t), gen_texture(t))
	}
	for f in 0 ..< WATER_FRAMES {
		write(out, int(Tex.Water) + f, gen_water(f))
	}
	return out
}

// Отладка: сохраняет все текстуры блоков в PNG (увеличенные в 8 раз).
dump_textures_png :: proc(path: string) -> bool {
	SCALE :: 8
	count := int(Tex.Water) + 1
	w := count * TEX_SIZE * SCALE
	hgt := TEX_SIZE * SCALE
	data := make([]u8, w * hgt * 4, context.temp_allocator)
	for t in 0 ..< count {
		img := gen_texture(Tex(t))
		for y in 0 ..< hgt do for x in 0 ..< TEX_SIZE * SCALE {
			p := img[(y / SCALE) * TEX_SIZE + x / SCALE]
			if p.a == 0 do p = (((x / SCALE) + (y / SCALE)) % 2 == 0) ? RGBA{200, 0, 200, 255} : RGBA{120, 0, 120, 255}
			o := (y * w + t * TEX_SIZE * SCALE + x) * 4
			data[o + 0] = p.r
			data[o + 1] = p.g
			data[o + 2] = p.b
			data[o + 3] = 255
		}
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	return stbi.write_png(cpath, i32(w), i32(hgt), 4, raw_data(data), i32(w * 4)) != 0
}
