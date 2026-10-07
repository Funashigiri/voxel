package main

// Скин персонажа: стандартная раскладка Minecraft 64x64.
// Если рядом с игрой лежит assets/skin.png (64x64), используется он,
// иначе рисуется собственный персонаж процедурно.

import "core:fmt"
import "core:image"
import "core:image/png"
import eng "engine"

SKIN_SIZE :: 64

Skin :: struct {
	pixels: [SKIN_SIZE * SKIN_SIZE]RGBA,
}

Box_Face :: enum {
	Top,
	Bottom,
	Right, // правый бок персонажа (-X в модели)
	Front,
	Left,
	Back,
}

// Прямоугольник грани на развёртке коробки w*h*d с началом в (u, v).
box_face_rect :: proc(u, v, w, h, d: int, face: Box_Face) -> (x, y, fw, fh: int) {
	switch face {
	case .Top:
		return u + d, v, w, d
	case .Bottom:
		return u + d + w, v, w, d
	case .Right:
		return u, v + d, d, h
	case .Front:
		return u + d, v + d, w, h
	case .Left:
		return u + d + w, v + d, d, h
	case .Back:
		return u + 2 * d + w, v + d, w, h
	}
	return
}

Skin_Part :: enum {
	Head,
	Body,
	Arm,
	Leg,
}

@(private = "file")
c3 :: proc(r, g, b: u8) -> RGBA {return {r, g, b, 255}}

@(private = "file")
noise :: proc(x, y: int, seed: u32) -> f32 {return eng.hash2f(i32(x), i32(y), seed)}

@(private = "file")
vary :: proc(c: RGBA, x, y: int, seed: u32, amount: f32 = 0.08) -> RGBA {
	f := 1 + (noise(x, y, seed) - 0.5) * 2 * amount
	return {u8(clamp(f32(c.r) * f, 0, 255)), u8(clamp(f32(c.g) * f, 0, 255)), u8(clamp(f32(c.b) * f, 0, 255)), c.a}
}

HAIR := RGBA{78, 50, 30, 255}
HAIR_DARK := RGBA{58, 37, 22, 255}
SKIN_COL := RGBA{222, 170, 128, 255}
SKIN_SHADE := RGBA{200, 148, 108, 255}
SHIRT := RGBA{176, 48, 40, 255}
SHIRT_DARK := RGBA{124, 30, 28, 255}
SHIRT_LIGHT := RGBA{204, 82, 62, 255}
PANTS := RGBA{84, 70, 58, 255}
PANTS_DARK := RGBA{66, 54, 44, 255}
BOOTS := RGBA{50, 38, 30, 255}
BELT := RGBA{64, 42, 24, 255}

// Клетчатая рубашка.
@(private = "file")
plaid :: proc(x, y: int) -> RGBA {
	vx := (x % 4) == 1
	hy := (y % 4) == 2
	c := SHIRT
	if vx && hy {
		c = SHIRT_DARK
	} else if vx || hy {
		c = SHIRT_LIGHT if (x + y) % 2 == 0 else SHIRT_DARK
	}
	return vary(c, x, y, 901, 0.05)
}

@(private = "file")
paint_head :: proc(face: Box_Face, x, y: int) -> RGBA {
	hair := vary(HAIR, x, y, 101, 0.12)
	skin := vary(SKIN_COL, x, y, 102, 0.04)
	switch face {
	case .Top, .Back:
		return hair
	case .Bottom:
		return vary(SKIN_SHADE, x, y, 103, 0.04)
	case .Front:
		if y <= 1 do return hair
		if y == 2 && (x <= 1 || x >= 6 || noise(x, 2, 104) < 0.4) do return hair
		if y == 3 && (x == 0 || x == 7) do return hair
		if y == 3 && (x == 1 || x == 2 || x == 5 || x == 6) do return HAIR_DARK // брови
		if y == 4 {
			switch x {
			case 1, 6:
				return c3(242, 242, 242)
			case 2, 5:
				return c3(54, 92, 150) // глаза
			}
		}
		if y == 5 && (x == 3 || x == 4) do return SKIN_SHADE // нос
		if y == 6 && x >= 2 && x <= 5 do return c3(160, 98, 76) // рот
		return skin
	case .Right, .Left:
		// у правой грани u растёт к лицу, у левой — к затылку
		to_back := face == .Right ? 7 - x : x
		if y <= 2 do return hair
		if y <= 6 && to_back >= 4 do return hair
		if y == 4 && to_back == 3 do return SKIN_SHADE // ухо
		return skin
	}
	return skin
}

@(private = "file")
paint_body :: proc(face: Box_Face, x, y: int) -> RGBA {
	switch face {
	case .Top:
		return plaid(x, y)
	case .Bottom:
		return vary(PANTS, x, y, 201)
	case .Front, .Back, .Right, .Left:
		if face == .Front && y <= 1 && x >= 3 && x <= 4 do return SKIN_COL // вырез
		if y == 10 {
			if face == .Front && (x == 3 || x == 4) do return c3(196, 166, 64) // пряжка
			return vary(BELT, x, y, 202)
		}
		if y == 11 do return vary(PANTS, x, y, 203)
		return plaid(x, y)
	}
	return SHIRT
}

@(private = "file")
paint_arm :: proc(face: Box_Face, x, y: int) -> RGBA {
	switch face {
	case .Top:
		return plaid(x, y)
	case .Bottom:
		return vary(SKIN_SHADE, x, y, 301)
	case .Front, .Back, .Right, .Left:
		if y <= 3 do return plaid(x, y)
		if y == 4 do return vary(SHIRT_DARK, x, y, 302)
		return vary(SKIN_COL, x, y, 303, 0.04)
	}
	return SKIN_COL
}

@(private = "file")
paint_leg :: proc(face: Box_Face, x, y: int) -> RGBA {
	switch face {
	case .Top:
		return vary(PANTS, x, y, 401)
	case .Bottom:
		return c3(34, 26, 20)
	case .Front, .Back, .Right, .Left:
		if y >= 9 do return vary(BOOTS, x, y, 402, 0.1)
		c := PANTS
		if noise(x, y, 403) < 0.25 do c = PANTS_DARK
		return vary(c, x, y, 404, 0.05)
	}
	return PANTS
}

@(private = "file")
paint_box :: proc(s: ^Skin, u, v, w, h, d: int, part: Skin_Part) {
	for face in Box_Face {
		rx, ry, fw, fh := box_face_rect(u, v, w, h, d, face)
		for y in 0 ..< fh do for x in 0 ..< fw {
			c: RGBA
			switch part {
			case .Head:
				c = paint_head(face, x, y)
			case .Body:
				c = paint_body(face, x, y)
			case .Arm:
				c = paint_arm(face, x, y)
			case .Leg:
				c = paint_leg(face, x, y)
			}
			s.pixels[(ry + y) * SKIN_SIZE + rx + x] = c
		}
	}
}

skin_generate :: proc() -> (s: Skin) {
	// всё, что не покрыто коробками (и слои одежды), остаётся прозрачным
	paint_box(&s, 0, 0, 8, 8, 8, .Head)
	paint_box(&s, 16, 16, 8, 12, 4, .Body)
	paint_box(&s, 40, 16, 4, 12, 4, .Arm) // правая рука
	paint_box(&s, 32, 48, 4, 12, 4, .Arm) // левая рука
	paint_box(&s, 0, 16, 4, 12, 4, .Leg) // правая нога
	paint_box(&s, 16, 48, 4, 12, 4, .Leg) // левая нога
	return
}

// Пытается загрузить assets/skin.png (64x64 RGBA). Иначе — процедурный скин.
skin_load_or_generate :: proc(path: string) -> Skin {
	img, err := png.load_from_file(path, {.alpha_add_if_missing})
	if err != nil {
		return skin_generate()
	}
	defer image.destroy(img)
	if img.width != SKIN_SIZE || img.height != SKIN_SIZE || img.channels != 4 || img.depth != 8 {
		fmt.eprintfln("[skin] %s: нужен PNG 64x64 RGBA, получен %dx%d — используется встроенный скин", path, img.width, img.height)
		return skin_generate()
	}
	s: Skin
	data := img.pixels.buf[:]
	for i in 0 ..< SKIN_SIZE * SKIN_SIZE {
		s.pixels[i] = {data[i * 4], data[i * 4 + 1], data[i * 4 + 2], data[i * 4 + 3]}
	}
	fmt.printfln("[skin] загружен %s", path)
	return s
}
