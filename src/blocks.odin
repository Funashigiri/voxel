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
	Monolith, // неразрушимый столп в вершине куба-планеты (аномалия)
	// недра (0.012): осадочные слои, кора материков и океанов, мантия
	Sandstone,
	Limestone,
	Granite,
	Basalt,
	Peridotite,
	// глубокие недра (0.013): переходная зона, нижняя мантия, ядро
	Ringwoodite,
	Bridgmanite,
	Molten_Iron,
	Iron_Core,
	// климат (0.015): снег, лёд, деревья и растения природных зон
	Snow,
	Ice,
	Spruce_Log,
	Spruce_Leaves,
	Acacia_Log,
	Acacia_Leaves,
	Jungle_Log,
	Jungle_Leaves,
	Cactus,
	Dead_Bush,
	// деревья (0.016): сучья и ветви — кора со всех сторон
	Oak_Wood,
	Birch_Wood,
	Spruce_Wood,
	Acacia_Wood,
	Jungle_Wood,
}

// Русские названия (F3: что под ногами).
BLOCK_NAMES := [Block]string {
	.Air          = "воздух",
	.Stone        = "камень",
	.Dirt         = "земля",
	.Grass        = "трава",
	.Sand         = "песок",
	.Gravel       = "гравий",
	.Bedrock      = "коренная порода",
	.Water        = "вода",
	.Oak_Log      = "дуб",
	.Oak_Leaves   = "листва дуба",
	.Birch_Log    = "берёза",
	.Birch_Leaves = "листва берёзы",
	.Tall_Grass   = "высокая трава",
	.Dandelion    = "одуванчик",
	.Poppy        = "мак",
	.Scorched     = "выжженная земля",
	.Monolith     = "столп аномалии",
	.Sandstone    = "песчаник",
	.Limestone    = "известняк",
	.Granite      = "гранит",
	.Basalt       = "базальт",
	.Peridotite   = "перидотит (верхняя мантия)",
	.Ringwoodite  = "рингвудит (переходная зона)",
	.Bridgmanite  = "бриджманит (нижняя мантия)",
	.Molten_Iron  = "жидкое железо (внешнее ядро)",
	.Iron_Core    = "железо с никелем (твёрдое ядро)",
	.Snow         = "снег",
	.Ice          = "лёд",
	.Spruce_Log   = "ель",
	.Spruce_Leaves = "хвоя ели",
	.Acacia_Log   = "акация",
	.Acacia_Leaves = "листва акации",
	.Jungle_Log   = "тропическое дерево",
	.Jungle_Leaves = "листва тропического дерева",
	.Cactus       = "кактус",
	.Dead_Bush    = "сухой куст",
	.Oak_Wood     = "ветвь дуба",
	.Birch_Wood   = "ветвь берёзы",
	.Spruce_Wood  = "ветвь ели",
	.Acacia_Wood  = "ветвь акации",
	.Jungle_Wood  = "ветвь тропического дерева",
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
	BLOCK_INFO[.Monolith] = cube(all_faces(.Monolith))
	BLOCK_INFO[.Sandstone] = cube(all_faces(.Sandstone))
	BLOCK_INFO[.Limestone] = cube(all_faces(.Limestone))
	BLOCK_INFO[.Granite] = cube(all_faces(.Granite))
	BLOCK_INFO[.Basalt] = cube(all_faces(.Basalt))
	BLOCK_INFO[.Peridotite] = cube(all_faces(.Peridotite))
	BLOCK_INFO[.Ringwoodite] = cube(all_faces(.Ringwoodite))
	BLOCK_INFO[.Bridgmanite] = cube(all_faces(.Bridgmanite))
	BLOCK_INFO[.Molten_Iron] = cube(all_faces(.Molten_Iron))
	BLOCK_INFO[.Iron_Core] = cube(all_faces(.Iron_Core))
	BLOCK_INFO[.Snow] = cube(all_faces(.Snow))
	BLOCK_INFO[.Ice] = cube(all_faces(.Ice))
	BLOCK_INFO[.Spruce_Log] = cube(column_faces(.Spruce_Log, .Spruce_Log_Top, .Spruce_Log_Top))
	BLOCK_INFO[.Acacia_Log] = cube(column_faces(.Acacia_Log, .Acacia_Log_Top, .Acacia_Log_Top))
	BLOCK_INFO[.Jungle_Log] = cube(column_faces(.Jungle_Log, .Jungle_Log_Top, .Jungle_Log_Top))
	BLOCK_INFO[.Cactus] = cube(column_faces(.Cactus_Side, .Cactus_Top, .Cactus_Top))
	for b in ([3]Block{.Spruce_Leaves, .Acacia_Leaves, .Jungle_Leaves}) {
		t := b == .Spruce_Leaves ? Tex.Spruce_Leaves : b == .Acacia_Leaves ? Tex.Acacia_Leaves : Tex.Jungle_Leaves
		BLOCK_INFO[b] = {render = .Leaves, solid = true, blocks_light = true, tex = all_faces(t)}
	}
	BLOCK_INFO[.Dead_Bush] = {render = .Cross, tex = all_faces(.Dead_Bush)}
	BLOCK_INFO[.Oak_Log] = cube(column_faces(.Oak_Log, .Oak_Log_Top, .Oak_Log_Top))
	BLOCK_INFO[.Birch_Log] = cube(column_faces(.Birch_Log, .Birch_Log_Top, .Birch_Log_Top))
	BLOCK_INFO[.Oak_Wood] = cube(all_faces(.Oak_Log))
	BLOCK_INFO[.Birch_Wood] = cube(all_faces(.Birch_Log))
	BLOCK_INFO[.Spruce_Wood] = cube(all_faces(.Spruce_Log))
	BLOCK_INFO[.Acacia_Wood] = cube(all_faces(.Acacia_Log))
	BLOCK_INFO[.Jungle_Wood] = cube(all_faces(.Jungle_Log))
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

// Ствол дерева (или кактус) — не затирает листву соседей при генерации.
is_log :: proc(b: Block) -> bool {
	#partial switch b {
	case .Oak_Log, .Birch_Log, .Spruce_Log, .Acacia_Log, .Jungle_Log, .Cactus, .Oak_Wood, .Birch_Wood, .Spruce_Wood, .Acacia_Wood, .Jungle_Wood:
		return true
	}
	return false
}

is_plant :: proc(b: Block) -> bool {
	return BLOCK_INFO[b].render == .Cross
}

// Хвоя и вечнозелёная листва — не опадают.
evergreen_leaves :: proc "contextless" (b: Block) -> bool {
	return b == .Spruce_Leaves || b == .Acacia_Leaves || b == .Jungle_Leaves
}

// Листва, что опадает на зиму (дуб, берёза): голая крона не держит свет неба.
deciduous_leaves :: proc "contextless" (b: Block) -> bool {
	return b == .Oak_Leaves || b == .Birch_Leaves
}
