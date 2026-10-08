package main

// Типы блоков и их свойства.

Block :: enum u8 {
	Air,
	Stone,
	Dirt,
	Grass,
	Sand,
	Gravel,
	Bedrock,
	Water,
	Oak_Log,
	Oak_Leaves,
	Birch_Log,
	Birch_Leaves,
	Tall_Grass,
	Dandelion,
	Poppy,
	Scorched, // выжженная земля (место посадки капсулы)
}

Render_Kind :: enum u8 {
	None,
	Cube, // обычный непрозрачный куб
	Leaves, // куб с дырками (alpha-test), грани между листьями рисуются ("fancy")
	Cross, // растения: две диагональные плоскости
	Liquid, // полупрозрачная вода
}

// Порядок граней важен: от него зависят нормали, затенение и меш.
Face :: enum u8 {
	East, // +X
	West, // -X
	Up, // +Y
	Down, // -Y
	South, // +Z
	North, // -Z
}

FACE_DIR := [Face][3]i32 {
	.East  = {1, 0, 0},
	.West  = {-1, 0, 0},
	.Up    = {0, 1, 0},
	.Down  = {0, -1, 0},
	.South = {0, 0, 1},
	.North = {0, 0, -1},
}

Block_Info :: struct {
	render:       Render_Kind,
	solid:        bool, // есть коллизия
	opaque:       bool, // полностью закрывает соседние грани, отбрасывает AO
	blocks_light: bool, // тень от неба (карта высот освещения)
	tex:          [Face]Tex,
}

BLOCK_INFO: [Block]Block_Info

@(private = "file")
all_faces :: proc(t: Tex) -> [Face]Tex {
	return {.East = t, .West = t, .Up = t, .Down = t, .South = t, .North = t}
}

@(private = "file")
column_faces :: proc(side, top, bottom: Tex) -> [Face]Tex {
	return {.East = side, .West = side, .Up = top, .Down = bottom, .South = side, .North = side}
}

blocks_init :: proc() {
	cube :: proc(tex: [Face]Tex) -> Block_Info {
		return {render = .Cube, solid = true, opaque = true, blocks_light = true, tex = tex}
	}
	BLOCK_INFO[.Air] = {render = .None}
	BLOCK_INFO[.Stone] = cube(all_faces(.Stone))
	BLOCK_INFO[.Dirt] = cube(all_faces(.Dirt))
	BLOCK_INFO[.Grass] = cube(column_faces(.Grass_Side, .Grass_Top, .Dirt))
	BLOCK_INFO[.Sand] = cube(all_faces(.Sand))
	BLOCK_INFO[.Gravel] = cube(all_faces(.Gravel))
	BLOCK_INFO[.Bedrock] = cube(all_faces(.Bedrock))
	BLOCK_INFO[.Scorched] = cube(all_faces(.Scorched))
	BLOCK_INFO[.Oak_Log] = cube(column_faces(.Oak_Log, .Oak_Log_Top, .Oak_Log_Top))
	BLOCK_INFO[.Birch_Log] = cube(column_faces(.Birch_Log, .Birch_Log_Top, .Birch_Log_Top))
	BLOCK_INFO[.Water] = {
		render       = .Liquid,
		blocks_light = true,
		tex          = all_faces(.Water),
	}
	BLOCK_INFO[.Oak_Leaves] = {
		render       = .Leaves,
		solid        = true,
		blocks_light = true,
		tex          = all_faces(.Oak_Leaves),
	}
	BLOCK_INFO[.Birch_Leaves] = {
		render       = .Leaves,
		solid        = true,
		blocks_light = true,
		tex          = all_faces(.Birch_Leaves),
	}
	BLOCK_INFO[.Tall_Grass] = {render = .Cross, tex = all_faces(.Tall_Grass)}
	BLOCK_INFO[.Dandelion] = {render = .Cross, tex = all_faces(.Dandelion)}
	BLOCK_INFO[.Poppy] = {render = .Cross, tex = all_faces(.Poppy)}
}

is_plant :: proc(b: Block) -> bool {
	return BLOCK_INFO[b].render == .Cross
}
