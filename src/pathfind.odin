package main

// Поиск пути по блокам (A*) для спутников.
// Узел — клетка, в которой стоят ноги персонажа. Можно ходить по ровному
// (в т.ч. по диагонали без срезания углов), запрыгивать на 1 блок,
// спрыгивать до 3 блоков вниз и плавать по поверхности воды.

import pq "core:container/priority_queue"
import "core:math"

Cell :: [3]i32

PATH_MAX_NODES :: 4000
PATH_MAX_FALL :: 3

@(private = "file")
DIRS := [8][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}

@(private = "file")
passable :: proc(w: ^World, x, y, z: i32) -> bool {
	return !world_is_solid(w, x, y, z)
}

@(private = "file")
is_water :: proc(w: ^World, c: Cell) -> bool {
	b, _ := world_get_block(w, c.x, c.y, c.z)
	return b == .Water
}

// Можно ли стоять ногами в этой клетке: место для тела 1x2 и опора снизу
// (твёрдый блок или поверхность воды).
standable :: proc(w: ^World, c: Cell) -> bool {
	if !passable(w, c.x, c.y, c.z) || !passable(w, c.x, c.y + 1, c.z) do return false
	if !passable(w, c.x, c.y - 1, c.z) do return true
	return is_water(w, c) && !is_water(w, c + Cell{0, 1, 0})
}

cell_of :: proc(pos: [3]f64) -> Cell {
	return {i32(math.floor(pos.x)), i32(math.floor(pos.y + 0.01)), i32(math.floor(pos.z))}
}

cell_center :: proc(c: Cell) -> [3]f64 {
	return {f64(c.x) + 0.5, f64(c.y), f64(c.z) + 0.5}
}

// Ближайшая клетка, где можно стоять, в радиусе r от `near`.
find_stand_cell :: proc(w: ^World, near: Cell, r: i32) -> (Cell, bool) {
	best: Cell
	best_d := max(i32)
	for dy in i32(-3) ..= 3 do for dz in -r ..= r do for dx in -r ..= r {
		c := near + Cell{dx, dy, dz}
		d := dx * dx + dz * dz + dy * dy * 2
		if d < best_d && standable(w, c) {
			best = c
			best_d = d
		}
	}
	return best, best_d != max(i32)
}

@(private = "file")
Neighbor :: struct {
	cell: Cell,
	cost: f32,
}

@(private = "file")
neighbors :: proc(w: ^World, c: Cell) -> (out: [8]Neighbor, n: int) {
	add :: proc(out: ^[8]Neighbor, n: ^int, w: ^World, cell: Cell, cost: f32) {
		extra: f32 = is_water(w, cell) ? 1.5 : 0
		out[n^] = {cell, cost + extra}
		n^ += 1
	}
	for d in DIRS {
		nx, nz := c.x + d.x, c.z + d.y
		diag := d.x != 0 && d.y != 0
		if diag {
			// не срезаем углы
			if !passable(w, c.x + d.x, c.y, c.z) || !passable(w, c.x + d.x, c.y + 1, c.z) ||
			   !passable(w, c.x, c.y, c.z + d.y) || !passable(w, c.x, c.y + 1, c.z + d.y) {
				continue
			}
		}
		base: f32 = diag ? 1.414 : 1
		same := Cell{nx, c.y, nz}
		if standable(w, same) {
			add(&out, &n, w, same, base)
			continue
		}
		up := Cell{nx, c.y + 1, nz}
		if !diag && passable(w, c.x, c.y + 2, c.z) && standable(w, up) {
			add(&out, &n, w, up, base + 0.8)
			continue
		}
		if passable(w, nx, c.y, nz) && passable(w, nx, c.y + 1, nz) {
			for dy in i32(1) ..= PATH_MAX_FALL {
				down := Cell{nx, c.y - dy, nz}
				if standable(w, down) {
					add(&out, &n, w, down, base + 0.3 * f32(dy))
					break
				}
				if !passable(w, down.x, down.y, down.z) do break
			}
		}
	}
	return
}

@(private = "file")
Open_Node :: struct {
	cell: Cell,
	f:    f32,
}

@(private = "file")
Node_Info :: struct {
	g:      f32,
	parent: Cell,
	closed: bool,
}

// Ищет путь от start до goal. Если цель недостижима — ведёт в ближайшую
// к ней найденную клетку (reached = false). Путь не включает start.
find_path :: proc(w: ^World, start, goal: Cell, allocator := context.allocator) -> (path: [dynamic]Cell, reached: bool) {
	path = make([dynamic]Cell, allocator)
	if start == goal do return path, true

	h :: proc(a, b: Cell) -> f32 {
		d := [3]f32{f32(a.x - b.x), f32(a.y - b.y), f32(a.z - b.z)}
		return math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
	}

	info := make(map[Cell]Node_Info, 1024, context.temp_allocator)
	open: pq.Priority_Queue(Open_Node)
	pq.init(&open, proc(a, b: Open_Node) -> bool {return a.f < b.f}, pq.default_swap_proc(Open_Node), 256, context.temp_allocator)

	info[start] = {g = 0, parent = start}
	pq.push(&open, Open_Node{start, h(start, goal)})
	best := start
	best_h := h(start, goal)
	expanded := 0

	for pq.len(open) > 0 && expanded < PATH_MAX_NODES {
		cur := pq.pop(&open)
		ci := &info[cur.cell]
		if ci.closed do continue
		ci.closed = true
		expanded += 1
		if cur.cell == goal {
			best = goal
			reached = true
			break
		}
		if hh := h(cur.cell, goal); hh < best_h {
			best_h = hh
			best = cur.cell
		}
		g := ci.g
		nbs, count := neighbors(w, cur.cell)
		for nb in nbs[:count] {
			ng := g + nb.cost
			if existing, ok := info[nb.cell]; ok && (existing.closed || existing.g <= ng) do continue
			info[nb.cell] = {g = ng, parent = cur.cell}
			pq.push(&open, Open_Node{nb.cell, ng + h(nb.cell, goal) * 1.2})
		}
	}

	// восстановление пути
	for c := best; c != start; c = info[c].parent {
		append(&path, c)
	}
	for i in 0 ..< len(path) / 2 {
		path[i], path[len(path) - 1 - i] = path[len(path) - 1 - i], path[i]
	}
	return
}

// Можно ли пройти по прямой между центрами клеток на одной высоте
// (с учётом ширины тела) — для сглаживания пути.
@(private = "file")
straight_walkable :: proc(w: ^World, a, b: Cell) -> bool {
	if a.y != b.y do return false
	ax, az := f64(a.x) + 0.5, f64(a.z) + 0.5
	bx, bz := f64(b.x) + 0.5, f64(b.z) + 0.5
	dist := math.sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az))
	steps := int(dist / 0.25) + 1
	for i in 0 ..= steps {
		t := f64(i) / f64(steps)
		px := ax + (bx - ax) * t
		pz := az + (bz - az) * t
		for corner in ([4][2]f64{{-0.3, -0.3}, {0.3, -0.3}, {-0.3, 0.3}, {0.3, 0.3}}) {
			c := Cell{i32(math.floor(px + corner.x)), a.y, i32(math.floor(pz + corner.y))}
			if !standable(w, c) do return false
		}
	}
	return true
}

// Убирает лишние промежуточные точки, чтобы спутники шли по прямой, а не "лесенкой".
smooth_path :: proc(w: ^World, start: Cell, path: ^[dynamic]Cell) {
	if len(path) < 2 do return
	out := make([dynamic]Cell, 0, len(path), context.temp_allocator)
	anchor := start
	for i in 0 ..< len(path) {
		last := i == len(path) - 1
		if last || !straight_walkable(w, anchor, path[i + 1]) {
			append(&out, path[i])
			anchor = path[i]
		}
	}
	clear(path)
	append(path, ..out[:])
}
