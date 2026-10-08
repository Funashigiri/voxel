package main

// Визуальная часть отряда: значки приказов над головами, метки целей,
// панель отряда в углу экрана и прицел. Всё рисуется пиксельной графикой
// через immediate-рендер движка.

import "core:math"
import "core:math/linalg"
import eng "engine"

// Пиксельная иконка 8x8: '.' — пусто, '1'..'3' — цвета из палитры.
Icon :: struct {
	rows:   [8]string,
	colors: [4]RGBA,
}

ORDER_ICONS := [Order]Icon {
	.Follow = {
		rows = {
			"...11...",
			"..1221..",
			".12..21.",
			"12....21",
			"...11...",
			"..1221..",
			".12..21.",
			"12....21",
		},
		colors = {{}, {24, 78, 26, 255}, {104, 230, 100, 255}, {}},
	},
	.Hold = {
		rows = {
			"..1111..",
			".122221.",
			"12222221",
			"13333331",
			"13333331",
			"12222221",
			".122221.",
			"..1111..",
		},
		colors = {{}, {110, 20, 18, 255}, {222, 52, 42, 255}, {250, 250, 250, 255}},
	},
	.Go_To = {
		rows = {
			".13333..",
			".133333.",
			".13333..",
			".1......",
			".1......",
			".1......",
			".1......",
			"111.....",
		},
		colors = {{}, {70, 50, 30, 255}, {}, {250, 212, 52, 255}},
	},
}

@(private = "file")
DIGITS := [SQUAD_SIZE][5]string{{".1.", "11.", ".1.", ".1.", "111"}, {"11.", "..1", ".1.", "1..", "111"}}

@(private = "file")
WHITE :: RGBA{255, 255, 255, 255}

@(private = "file")
with_alpha :: proc(c: RGBA, a: u8) -> RGBA {return {c.r, c.g, c.b, a}}

@(private = "file")
brighten :: proc(c: [3]u8, k: f32) -> RGBA {
	return {u8(min(f32(c.r) * k, 255)), u8(min(f32(c.g) * k, 255)), u8(min(f32(c.b) * k, 255)), 255}
}

// Иконка-"билборд" в мире (всегда повёрнута к камере).
@(private = "file")
icon_world :: proc(icon: ^Icon, center, right, up: [3]f32, px: f32, alpha: u8, frame: bool) {
	for row, j in icon.rows {
		for i in 0 ..< len(row) {
			ch := row[i]
			if ch == '.' do continue
			col := with_alpha(icon.colors[ch - '0'], alpha)
			x0 := (f32(i) - 4) * px
			y1 := (4 - f32(j)) * px
			o := center + right * x0 + up * (y1 - px)
			eng.imm_quad(o, o + right * px, o + right * px + up * px, o + up * px, col)
		}
	}
	if frame {
		e := 5 * px // рамка выбора чуть больше иконки
		t := px * 0.6
		col := with_alpha(WHITE, alpha)
		edge :: proc(c, r, u: [3]f32, x0, y0, x1, y1: f32, col: RGBA) {
			eng.imm_quad(c + r * x0 + u * y0, c + r * x1 + u * y0, c + r * x1 + u * y1, c + r * x0 + u * y1, col)
		}
		edge(center, right, up, -e, e - t, e, e, col)
		edge(center, right, up, -e, -e, e, -e + t, col)
		edge(center, right, up, -e, -e + t, -e + t, e - t, col)
		edge(center, right, up, e - t, -e + t, e, e - t, col)
	}
}

@(private = "file")
icon_screen :: proc(icon: ^Icon, x, y, px: f32, alpha: u8) {
	for row, j in icon.rows {
		for i in 0 ..< len(row) {
			ch := row[i]
			if ch == '.' do continue
			col := with_alpha(icon.colors[ch - '0'], alpha)
			eng.imm_rect(x + f32(i) * px, y + f32(j) * px, x + f32(i + 1) * px, y + f32(j + 1) * px, col)
		}
	}
}

// Значки над головами и метки целей. Позиции — относительно камеры.
squad_draw_world :: proc(s: ^Squad, cam: ^Camera, t: f32, time: f64) {
	right := [3]f32{cam.view[0, 0], cam.view[0, 1], cam.view[0, 2]}
	up := [3]f32{cam.view[1, 0], cam.view[1, 1], cam.view[1, 2]}
	rel :: proc(p: [3]f64, cam: ^Camera) -> [3]f32 {
		return {f32(p.x - cam.pos.x), f32(p.y - cam.pos.y), f32(p.z - cam.pos.z)}
	}

	for &c, i in s.members {
		b := &c.body
		feet := rel(character_render_pos(b, t), cam)
		eye := math.lerp(b.prev_eye_h, b.eye_h, t)
		head := feet + [3]f32{0, eye + 0.63, 0}
		icon_world(&ORDER_ICONS[c.order], head, right, up, 0.055, 235, s.selected[i])

		if c.marker <= 0 do continue
		a := u8(c.marker * 230)
		col := with_alpha(brighten(c.color, 1.35), a)
		g := rel(cell_center(c.goal), cam) + [3]f32{0, 0.03, 0}
		// рамка на земле
		h: f32 = 0.45
		th: f32 = 0.08
		flat :: proc(g: [3]f32, x0, z0, x1, z1: f32, col: RGBA) {
			eng.imm_quad(g + [3]f32{x0, 0, z1}, g + [3]f32{x1, 0, z1}, g + [3]f32{x1, 0, z0}, g + [3]f32{x0, 0, z0}, col)
		}
		flat(g, -h, -h, h, -h + th, col)
		flat(g, -h, h - th, h, h, col)
		flat(g, -h, -h + th, -h + th, h - th, col)
		flat(g, h - th, -h + th, h, h - th, col)
		pulse := f32(0.5 + 0.5 * math.sin(time * 5))
		q := 0.1 + 0.08 * pulse
		flat(g, -q, -q, q, q, col)
		// флажок над меткой — цвета спутника
		flag := ORDER_ICONS[.Go_To]
		flag.colors[3] = brighten(c.color, 1.35)
		bob := f32(0.08 * math.sin(time * 3))
		icon_world(&flag, g + [3]f32{0, 1.0 + bob, 0}, right, up, 0.05, a, false)
	}
	eng.imm_flush(cam.view_proj)
}

gui_scale :: proc(height: i32) -> f32 {
	return max(1, math.round(f32(height) / 360))
}

// Панель отряда в левом нижнем углу: номер, цвет спутника, текущий приказ.
squad_draw_hud :: proc(s: ^Squad, width, height: i32) {
	g := gui_scale(height)
	CARD_W :: 31
	CARD_H :: 14
	for &c, i in s.members {
		x := (4 + f32(i) * (CARD_W + 3)) * g
		y := f32(height) - (4 + CARD_H) * g
		sel := s.selected[i]
		eng.imm_rect(x, y, x + CARD_W * g, y + CARD_H * g, {0, 0, 0, sel ? 140 : 80})
		if sel {
			eng.imm_rect(x, y, x + CARD_W * g, y + g, WHITE)
			eng.imm_rect(x, y + (CARD_H - 1) * g, x + CARD_W * g, y + CARD_H * g, WHITE)
			eng.imm_rect(x, y + g, x + g, y + (CARD_H - 1) * g, WHITE)
			eng.imm_rect(x + (CARD_W - 1) * g, y + g, x + CARD_W * g, y + (CARD_H - 1) * g, WHITE)
		}
		alpha: u8 = sel ? 255 : 150
		for row, j in DIGITS[i] {
			for k in 0 ..< len(row) {
				if row[k] == '.' do continue
				px := x + f32(3 + k) * g
				py := y + f32(5 + j) * g
				eng.imm_rect(px, py, px + g, py + g, with_alpha(WHITE, alpha))
			}
		}
		sw := with_alpha(brighten(c.color, 1.1), alpha)
		eng.imm_rect(x + 9 * g, y + 4 * g, x + 16 * g, y + 11 * g, sw)
		icon_screen(&ORDER_ICONS[c.order], x + 20 * g, y + 3 * g, g, alpha)
	}
	eng.imm_flush(linalg.matrix_ortho3d_f32(0, f32(width), f32(height), 0, -1, 1))
}

// Прицел, инвертирующий цвет под собой (как в Minecraft).
draw_crosshair :: proc(width, height: i32) {
	g := gui_scale(height)
	cx, cy := f32(width) / 2, f32(height) / 2
	half := 4.5 * g
	th := g
	eng.imm_rect(cx - half, cy - th / 2, cx + half, cy + th / 2, WHITE)
	eng.imm_rect(cx - th / 2, cy - half, cx + th / 2, cy - th / 2, WHITE)
	eng.imm_rect(cx - th / 2, cy + th / 2, cx + th / 2, cy + half, WHITE)
	eng.imm_flush(linalg.matrix_ortho3d_f32(0, f32(width), f32(height), 0, -1, 1))
}
