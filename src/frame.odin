package main

// Переход через ребро грани куба-планеты.
//
// Игра идёт в сетке одной грани ("кадр"), её координаты продолжаются через
// рёбра на соседние грани. Когда игрок уходит за ребро дальше чем на
// FRAME_HYSTERESIS блоков, кадром становится соседняя грань: всё, что хранит
// координаты, переводится в её сетку (поворот на 90°·k и сдвиг). Для игрока
// это незаметно — мир вокруг тот же, меняются только числа. Чанки хранятся по
// своим граням, поэтому ничего не перегенерируется.

import "core:fmt"
import "core:math"

FRAME_HYSTERESIS :: 4.0 // блоков за ребром, чтобы не прыгать туда-сюда на самом стыке

Frame_Refs :: struct {
	world:    ^World,
	player:   ^Character,
	squad:    ^Squad,
	landing:  ^Landing,
	cam:      ^Camera,
	sky:      ^Sky,
	renderer: ^Renderer,
}

// Проверяет, не ушёл ли игрок за ребро, и если ушёл — переключает кадр.
frame_follow :: proc(f: Frame_Refs) -> bool {
	g := &f.world.geo
	n := f64(g.n)
	p := f.player.pos
	ox := p.x < -FRAME_HYSTERESIS || p.x >= n + FRAME_HYSTERESIS
	oz := p.z < -FRAME_HYSTERESIS || p.z >= n + FRAME_HYSTERESIS
	if !ox && !oz do return false
	if (p.x < 0 || p.x >= n) && (p.z < 0 || p.z >= n) do return false // у вершины — там столп
	e: Edge = ox ? (p.x < 0 ? .NX : .PX) : (p.z < 0 ? .NZ : .PZ)
	link := g.edges[g.face][e]
	from := g.face
	frame_apply(f, link.m, link.face)
	g.face = link.face
	fmt.printfln("Переход через ребро: %s -> %s", FACE_NAMES[from], FACE_NAMES[g.face])
	return true
}

// Переводит всё, что хранит координаты кадра, в кадр грани new_face
// (m — общее преобразование старого кадра в новый).
frame_apply :: proc(f: Frame_Refs, m: Xform, new_face: Cube_Face) {
	g := &f.world.geo
	turn := xform_yaw(m, 0) // поворот кадра — добавка ко всем углам yaw

	frame_character(m, turn, f.player)
	for &c in f.squad.members {
		// спутник у вершины может стоять на третьей грани — у неё в новом кадре своя сетка
		cm := entity_xform(g, m, new_face, c.body.pos)
		cturn := xform_yaw(cm, 0)
		frame_character(cm, cturn, &c.body)
		c.home = tp(cm, c.home)
		c.goal = tc(cm, c.goal)
		c.path_goal = tc(cm, c.path_goal)
		for &cell in c.path do cell = tc(cm, cell)
		c.progress_pos = tp(cm, c.progress_pos)
		c.look_yaw += cturn
	}

	l := f.landing
	l.cam_yaw += turn
	l.cam_from = tp(m, l.cam_from)
	l.cam_from_yaw += turn
	for &pod in l.pods {
		pod.pos = tp(m, pod.pos)
		pod.vel = tv(m, pod.vel)
		pod.yaw += turn
		pod.formation = tv(m, pod.formation)
		pod.chute_pos = tp(m, pod.chute_pos)
		pod.chute_vel = tv(m, pod.chute_vel)
		pod.chute_rot.y -= turn // поворот матрицей вокруг Y идёт в обратную сторону от yaw
		for i in 0 ..< pod.path_n do pod.path[i] = tc(m, pod.path[i])
		pod.exit_goal = tp(m, pod.exit_goal)
		pod.hole.center = tp(m, pod.hole.center)
	}
	for &pt in l.particles.list {
		pt.pos = tp(m, pt.pos)
		x, z := xform_vec(m, f64(pt.vel.x), f64(pt.vel.z))
		pt.vel.x, pt.vel.z = f32(x), f32(z)
		pt.target = tp(m, pt.target)
	}

	cam := f.cam
	cam.pos = tp(m, cam.pos)
	cam.yaw += turn
	cam.hand_yaw += turn

	sky_rebase(f.sky, m)
	if m.r[0][0] == 0 {
		// оси x и z кадра поменялись местами — затенение боков тоже, плавно вернётся
		r := f.renderer
		r.side_shade = {r.side_shade.y, r.side_shade.x}
	}
}

// Преобразование для точки p старого кадра. Обычно это m, но у вершины куба
// точка может лежать на третьей грани (не старой и не новой): сетка той грани
// в новом кадре повёрнута иначе (вокруг вершины 270°, а не 360°).
@(private = "file")
entity_xform :: proc(g: ^Planet_Geo, m: Xform, new_face: Cube_Face, p: [3]f64) -> Xform {
	face, _, _, ok := geo_resolve(g, g.face, i32(math.floor(p.x)), i32(math.floor(p.z)))
	if !ok || face == g.face || face == new_face do return m
	to_face: Xform
	for e in Edge {
		if g.edges[g.face][e].face == face do to_face = g.edges[g.face][e].m
	}
	next := g^
	next.face = new_face
	m2, placed := geo_frame_of(&next, face)
	if !placed do return m
	return xform_compose(m2, to_face)
}

@(private = "file")
frame_character :: proc(m: Xform, turn: f32, c: ^Character) {
	c.pos = tp(m, c.pos)
	c.prev_pos = tp(m, c.prev_pos)
	c.vel = tv(m, c.vel)
	c.yaw += turn
	c.prev_yaw += turn
	c.body_yaw += turn
	c.prev_body_yaw += turn
}

@(private = "file")
tp :: proc(m: Xform, p: [3]f64) -> [3]f64 {
	x, z := xform_pos(m, p.x, p.z)
	return {x, p.y, z}
}

@(private = "file")
tv :: proc(m: Xform, v: [3]f64) -> [3]f64 {
	x, z := xform_vec(m, v.x, v.z)
	return {x, v.y, z}
}

@(private = "file")
tc :: proc(m: Xform, c: Cell) -> Cell {
	x, z := xform_cell(m, c.x, c.z)
	return {x, c.y, z}
}

// Самопроверка (-selftest): точка до и после смены кадра должна попадать в
// одну и ту же клетку планеты — в том числе у вершин, на третьих гранях.
frame_selftest :: proc(geo: Planet_Geo) -> (checked, errors: int) {
	g := geo
	n := g.n
	for face in Cube_Face {
		for e in Edge {
			g.face = face
			link := g.edges[face][e]
			// точки вокруг всех четырёх углов грани и вдоль ребра
			for corner in ([4][2]i32{{0, 0}, {n, 0}, {0, n}, {n, n}}) {
				for dz := i32(-40); dz <= 40; dz += 7 do for dx := i32(-40); dx <= 40; dx += 7 {
					x, z := corner.x + dx, corner.y + dz
					f0, gx0, gz0, ok := geo_resolve(&g, face, x, z)
					if !ok do continue
					me := entity_xform(&g, link.m, link.face, {f64(x) + 0.5, 0, f64(z) + 0.5})
					nx, nz := xform_cell(me, x, z)
					f1, gx1, gz1, ok1 := geo_resolve(&g, link.face, nx, nz)
					// пропускаем только точки граней, которых нет в новом кадре
					next := g
					next.face = link.face
					if _, placed := geo_frame_of(&next, f0); !placed do continue
					checked += 1
					if !ok1 {
						errors += 1
						continue
					}
					if f0 != f1 || gx0 != gx1 || gz0 != gz1 do errors += 1
				}
			}
		}
	}
	return
}
