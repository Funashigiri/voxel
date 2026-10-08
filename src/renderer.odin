package main

// Отрисовка кадра: небо и звёзды -> дальний проход (рельеф до горизонта,
// облака; своя логарифмическая глубина) -> очистка глубины -> ближний проход
// (чанки, персонажи, вода, частицы) -> рука от первого лица -> интерфейс.

import "core:math"
import "core:math/linalg"
import "core:slice"
import eng "engine"
import gl "vendor:OpenGL"

Chunk_Shader :: struct {
	prog:                                                 u32,
	u_view_proj, u_origin, u_time, u_atlas, u_alpha_cutoff: i32,
	u_fog, u_rot, u_side_shade:                           i32,
}

Entity_Shader :: struct {
	prog:                                                         u32,
	u_mvp, u_model, u_skin, u_light, u_fog, u_tint: i32,
	u_view_proj, u_collapse:                       i32,
}

Sky_Shader :: struct {
	prog:                                                   u32,
	u_inv_view_proj, u_sun_size, u_sun_color, u_px: i32,
	u_moon, u_moon_light:                 i32,
	u_band, u_u2f, u_band_k:              i32,
}

Renderer :: struct {
	chunk:          Chunk_Shader,
	entity:         Entity_Shader,
	sky:            Sky_Shader,
	lens:           Lens_Renderer,
	atlas:          u32,
	underwater:     bool, // камера под водой в этом кадре
	pv:             Planet_View, // как кадр у камеры лежит на шаре
	haze:           [4]f32, // дымка: ослабление, 1/высота, высота камеры, 1/(2R)
	haze_beta:      f32, // ослабление дымки у моря, 1/м
	haze_height:    f32, // высота однородной дымки, м
	cloud_q0:       [3]f32, // облака для шейдеров (CLOUD_GLSL)
	cloud_jq:       matrix[3, 3]f32,
	cloud:          [4]f32,
	off_far:        bool, // отладка (-off:...): выключенные части — для замеров
	off_clouds:     bool,
	off_shadows:    bool,
	player_light:   f32,
	// небо и свет этого кадра (из Sky_State)
	sky_top:        [3]f32,
	sky_horizon:    [3]f32,
	sun_dir:        [3]f32,
	glow:           [4]f32,
	light:          [4]f32, // цвет и яркость освещения, обесцвечивание
	light_k:        f32, // яркость
	chunks_drawn:   int,
	// затенение боков вдоль x и z кадра; после поворота кадра (переход через
	// ребро) значения меняются местами и плавно возвращаются к обычным
	side_shade:     [2]f32,
	anomaly:        [4]f32, // туман ближайшей аномалии: центр от камеры, радиус
}

SIDE_SHADE :: [2]f32{0.6, 0.8}

Frame_Params :: struct {
	world:       ^World,
	player:      ^Character,
	cam:         ^Camera,
	sky:         ^Sky,
	sky_state:   ^Sky_State, // солнце, луны, свет (astro.odin)
	star_sky:    ^Star_Sky, // звёзды и свечение неба (starsky.odin)
	model:       ^Humanoid_Model,
	player_skin: u32,
	capsule:     ^Capsule_Model,
	landing:     ^Landing,
	globe:       ^Globe,
	far:         ^Far_Terrain, // рельеф до горизонта
	clouds:      ^Clouds,
	cloud_shade: f32, // тень облака там, где стоит игрок (1 — нет)
	cloud_over:  f64, // облачность прямо над головой, 0..1
	frame_ms:    f64, // время кадра (сглаженное)
	squad:       ^Squad,
	clock:       ^Game_Clock,
	system:      ^Star_System,
	debug_page:  int, // страница F3 (0 — выкл)
	universe:    ^Universe_Info,
	fps:         f64,
	chunks_drawn: int,
	t:           f32, // доля между тиками
	time:        f64,
	dt:          f32,
	width:       i32,
	height:      i32,
}

renderer_init :: proc(r: ^Renderer) -> bool {
	loc :: eng.uniform_loc
	{
		p := eng.shader_create("chunk", CHUNK_VS, CHUNK_FS) or_return
		r.chunk = {
			prog           = p,
			u_view_proj    = loc(p, "u_view_proj"),
			u_origin       = loc(p, "u_origin"),
			u_time         = loc(p, "u_time"),
			u_atlas        = loc(p, "u_atlas"),
			u_alpha_cutoff = loc(p, "u_alpha_cutoff"),
			u_fog          = loc(p, "u_fog"),
			u_rot          = loc(p, "u_rot"),
			u_side_shade   = loc(p, "u_side_shade"),
		}
	}
	{
		p := eng.shader_create("entity", ENTITY_VS, ENTITY_FS) or_return
		r.entity = {
			prog          = p,
			u_mvp         = loc(p, "u_mvp"),
			u_model       = loc(p, "u_model"),
			u_skin        = loc(p, "u_skin"),
			u_light       = loc(p, "u_light_k"),
			u_fog         = loc(p, "u_fog"),
			u_tint        = loc(p, "u_tint"),
			u_view_proj   = loc(p, "u_view_proj"),
			u_collapse    = loc(p, "u_collapse"),
		}
	}
	{
		p := eng.shader_create("sky", SKY_VS, SKY_FS) or_return
		r.sky = {
			prog            = p,
			u_inv_view_proj = loc(p, "u_inv_view_proj"),
			u_sun_size      = loc(p, "u_sun_size"),
			u_sun_color     = loc(p, "u_sun_color"),
			u_px            = loc(p, "u_px"),
			u_moon          = loc(p, "u_moon"),
			u_moon_light    = loc(p, "u_moon_light"),
			u_band          = loc(p, "u_band"),
			u_u2f           = loc(p, "u_u2f"),
			u_band_k        = loc(p, "u_band_k"),
		}
	}
	eng.imm_init() or_return
	lens_init(&r.lens) or_return
	eng.text_init()

	pixels := build_block_textures(context.temp_allocator)
	r.atlas = eng.texture_array_create(TEX_SIZE, TEX_SIZE, i32(TEX_LAYER_COUNT), pixels)

	r.player_light = 1
	r.side_shade = SIDE_SHADE
	r.haze_beta = HAZE_BETA
	r.haze_height = HAZE_HEIGHT
	return true
}

WATER_FOG_COLOR :: [4]f32{0.12, 0.24, 0.55, 1}
WATER_FOG :: [2]f32{1, 34}
NO_FOG :: [2]f32{1e8, 2e8} // над водой тумана нет — дальше дымка (HAZE_GLSL)
HAZE_BETA :: 4e-5 // ослабление у моря, 1/м: в ясную погоду видно ~100 км
HAZE_HEIGHT :: 1400.0 // высота однородной дымки на планете с земной тяжестью, м

@(private = "file")
Frustum :: [6][4]f32

@(private = "file")
frustum_from :: proc(m: eng.Mat4) -> (f: Frustum) {
	row :: proc(m: eng.Mat4, i: int) -> [4]f32 {return {m[i, 0], m[i, 1], m[i, 2], m[i, 3]}}
	r0, r1, r2, r3 := row(m, 0), row(m, 1), row(m, 2), row(m, 3)
	f = {r3 + r0, r3 - r0, r3 + r1, r3 - r1, r3 + r2, r3 - r2}
	return
}

@(private = "file")
aabb_visible :: proc(f: ^Frustum, mn, mx: [3]f32) -> bool {
	for pl in f^ {
		p := [3]f32{pl.x > 0 ? mx.x : mn.x, pl.y > 0 ? mx.y : mn.y, pl.z > 0 ? mx.z : mn.z}
		if pl.x * p.x + pl.y * p.y + pl.z * p.z + pl.w < 0 do return false
	}
	return true
}

@(private = "file")
Visible_Chunk :: struct {
	chunk:  ^Chunk,
	origin: [3]f32,
	rot:    [4]f32,
	dist2:  f32,
}

// Цвета неба и тумана. Под водой туман синий и густой (как в Minecraft).
@(private = "file")
set_sky_uniforms :: proc(r: ^Renderer, prog: u32) {
	eng.set_vec3(eng.uniform_loc(prog, "u_sky_top"), r.sky_top)
	eng.set_vec3(eng.uniform_loc(prog, "u_sky_horizon"), r.sky_horizon)
	eng.set_vec3(eng.uniform_loc(prog, "u_sun_dir"), r.sun_dir)
	eng.set_vec4(eng.uniform_loc(prog, "u_glow"), r.glow)
	eng.set_vec4(eng.uniform_loc(prog, "u_light"), r.light)
	water := WATER_FOG_COLOR * [4]f32{r.light_k, r.light_k, r.light_k, 1} // ночью под водой черно
	eng.set_vec4(eng.uniform_loc(prog, "u_fog_override"), r.underwater ? water : {})
	eng.set_vec4(eng.uniform_loc(prog, "u_anomaly"), r.anomaly)
	eng.set_vec4(eng.uniform_loc(prog, "u_haze"), r.haze)
	eng.set_vec3(eng.uniform_loc(prog, "u_cloud_q0"), r.cloud_q0)
	gl.UniformMatrix3fv(eng.uniform_loc(prog, "u_cloud_jq"), 1, false, &r.cloud_jq[0, 0])
	eng.set_vec4(eng.uniform_loc(prog, "u_cloud"), r.cloud)
	eng.set_i32(eng.uniform_loc(prog, "u_cloud_noise"), 3)
}

// Дымка и облака этого кадра — для всех шейдеров.
@(private = "file")
update_air :: proc(r: ^Renderer, fp: ^Frame_Params) {
	pv := &r.pv
	r.haze = {r.underwater ? 0 : r.haze_beta, 1 / r.haze_height, f32(pv.cam_h), f32(1 / (2 * pv.radius))}
	r.cloud = {}
	if c := fp.clouds; c != nil {
		q := cloud_q(c, pv.pc)
		r.cloud_q0 = {f32(q.x), f32(q.y), f32(q.z)}
		for i in 0 ..< 3 do for k in 0 ..< 3 do r.cloud_jq[i, k] = f32(pv.j[i, k] / CLOUD_SCALE)
		r.cloud = {f32(c.cover), f32(c.time / 1800), f32(c.height), r.off_shadows ? 0 : 1}
		gl.ActiveTexture(gl.TEXTURE3)
		gl.BindTexture(gl.TEXTURE_3D, c.noise_tex)
		gl.ActiveTexture(gl.TEXTURE0)
	}
}

// Солнце и луны для шейдера неба.
@(private = "file")
sky_uniforms_sun :: proc(r: ^Renderer, fp: ^Frame_Params) {
	st := fp.sky_state
	eng.set_f32(r.sky.u_sun_size, f32(st.sun_ang_r))
	sc := st.sun_color
	eng.set_vec4(r.sky.u_sun_color, {sc.r, sc.g, sc.b, f32(st.sun_visible)})
	eng.set_f32(r.sky.u_px, 2 * math.tan(math.to_radians(fp.cam.fov) / 2) / f32(max(fp.height, 1)))
	moon, moon_light: [MAX_MOONS][4]f32
	for i in 0 ..< st.moon_n {
		m := &st.moons[i]
		moon[i] = {m.frame.x, m.frame.y, m.frame.z, f32(m.ang_r)}
		// в тени планеты луна тускнеет и краснеет (лунное затмение); пепельный свет — ночью
		s := f32(m.shadow)
		c := [3]f32{0.95, 0.93, 0.88} * s + [3]f32{0.3, 0.07, 0.02} * (1 - s) * 0.6
		moon_light[i] = {c.r, c.g, c.b, 0.035 * (1 - st.brightness)}
	}
	gl.Uniform4fv(r.sky.u_moon, MAX_MOONS, &moon[0][0])
	gl.Uniform4fv(r.sky.u_moon_light, MAX_MOONS, &moon_light[0][0])
	// свечение неба (полоса галактики) — когда фоновый расчёт готов
	band_k: f32 = 0
	if ss := fp.star_sky; ss != nil && ss.ready {
		band_k = st.band_vis
		gl.ActiveTexture(gl.TEXTURE1)
		gl.BindTexture(gl.TEXTURE_2D, ss.tex)
		gl.ActiveTexture(gl.TEXTURE0)
	}
	eng.set_i32(r.sky.u_band, 1)
	eng.set_f32(r.sky.u_band_k, band_k)
	u2f: matrix[3, 3]f32
	for i in 0 ..< 3 do for j in 0 ..< 3 do u2f[i, j] = f32(st.uni_to_frame[i, j])
	gl.UniformMatrix3fv(r.sky.u_u2f, 1, false, &u2f[0, 0])
}

// Туман ближайшей аномалии (вершины куба) — относительно камеры, в осях кадра.
// Точка берётся на шаре, как у дальнего рельефа: туман виден за десятки км.
@(private = "file")
update_anomaly :: proc(r: ^Renderer) {
	pv := &r.pv
	_, cd := nearest_anomaly(pv.up)
	centre := cd * (pv.radius + ANOMALY_Y - Y_SEA)
	r.anomaly = {}
	if len3(centre - pv.pc) < 80_000 {
		rel := planet_rel(pv, centre)
		r.anomaly = {f32(rel.x), f32(rel.y), f32(rel.z), ANOMALY_RADIUS}
	}
}

// Плавно подстраивает яркость персонажа под свет в его клетке (тень деревьев и т.п.).
@(private = "file")
update_light :: proc(light: ^f32, w: ^World, ch: ^Character, t, dt: f32) {
	pos := character_render_pos(ch, t)
	target := world_sky_light(w, i32(math.floor(pos.x)), i32(math.floor(pos.y + 1)), i32(math.floor(pos.z)))
	light^ += (target - light^) * min(1, dt * 6)
}

// Дальний рельеф (тайлы, столп аномалии) и облака — с логарифмической
// глубиной от метров до тысяч километров.
@(private = "file")
draw_far :: proc(r: ^Renderer, fp: ^Frame_Params) {
	cam := fp.cam
	far_update_mask(fp.far, fp.world, cam.pos)
	aspect := f32(fp.width) / f32(max(fp.height, 1))
	vp := linalg.matrix4_perspective_f32(math.to_radians(cam.fov), aspect, 1, f32(FAR_LOG_FAR)) * cam.view
	frustum := frustum_from(vp)
	gl.Disable(gl.CULL_FACE)
	gl.UseProgram(fp.far.prog)
	set_sky_uniforms(r, fp.far.prog)
	far_draw(fp.far, &r.pv, vp, &frustum, r.side_shade)

	if c := fp.clouds; c != nil && !r.off_clouds {
		gl.Enable(gl.BLEND)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.DepthMask(false)
		gl.DepthFunc(gl.LEQUAL)
		gl.UseProgram(c.prog)
		set_sky_uniforms(r, c.prog)
		eng.set_f32(eng.uniform_loc(c.prog, "u_px"), 2 * math.tan(math.to_radians(cam.fov) / 2) / f32(max(fp.height, 1)))
		clouds_draw(c, &r.pv, vp)
		gl.Disable(gl.BLEND)
		gl.DepthMask(true)
		gl.DepthFunc(gl.LESS)
	}
	gl.Enable(gl.CULL_FACE)
}

@(private = "file")
draw_character :: proc(r: ^Renderer, fp: ^Frame_Params, ch: ^Character, skin: u32, light: f32) {
	cam := fp.cam
	pose, body_yaw := character_pose(ch, fp.t)
	feet := character_render_pos(ch, fp.t)
	rel := [3]f32{f32(feet.x - cam.pos.x), f32(feet.y - cam.pos.y), f32(feet.z - cam.pos.z)}
	eng.set_f32(r.entity.u_light, light * fp.cloud_shade)
	gl.BindTexture(gl.TEXTURE_2D, skin)
	humanoid_model_draw(fp.model, &r.entity, cam.view_proj, rel, body_yaw, &pose)
}

render_frame :: proc(r: ^Renderer, frame: Frame_Params) {
	fp := frame
	cam := fp.cam
	p := fp.player
	gl.Viewport(0, 0, fp.width, fp.height)
	{
		b, _ := world_get_block(fp.world, i32(math.floor(cam.pos.x)), i32(math.floor(cam.pos.y)), i32(math.floor(cam.pos.z)))
		r.underwater = b == .Water
	}
	fog := r.underwater ? WATER_FOG : NO_FOG
	r.pv = planet_view_make(&fp.world.geo, cam.pos)
	update_anomaly(r)
	update_air(r, &fp)
	st := fp.sky_state
	r.sky_top, r.sky_horizon, r.sun_dir, r.glow = st.sky_top, st.sky_horizon, st.sun_frame, st.glow
	r.light = {st.light.r, st.light.g, st.light.b, st.desat}
	r.light_k = st.brightness
	r.side_shade += (SIDE_SHADE - r.side_shade) * min(1, fp.dt * 1.5)
	gl.ClearColor(r.sky_horizon.r, r.sky_horizon.g, r.sky_horizon.b, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

	// ---- небо
	gl.Disable(gl.DEPTH_TEST)
	gl.DepthMask(false)
	gl.UseProgram(r.sky.prog)
	eng.set_mat4(r.sky.u_inv_view_proj, linalg.matrix4_inverse_f32(cam.view_proj))
	sky_uniforms_sun(r, &fp)
	set_sky_uniforms(r, r.sky.prog)
	gl.BindVertexArray(fp.sky.empty_vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	// звёзды и планеты — поверх неба, под землёй и облаками
	if fp.star_sky != nil && !r.underwater do starsky_draw(fp.star_sky, fp.sky_state, cam.view_proj, fp.time, fp.height, r.anomaly)
	gl.Enable(gl.DEPTH_TEST)
	gl.DepthFunc(gl.LESS)
	gl.DepthMask(true)

	// ---- дальний проход: рельеф до горизонта и облака (своя глубина)
	if !r.underwater && fp.far != nil && !r.off_far {
		draw_far(r, &fp)
		gl.Clear(gl.DEPTH_BUFFER_BIT) // блоки всегда ближе — рисуются поверх
	}

	// ---- непрозрачные чанки (спереди назад)
	gl.Enable(gl.CULL_FACE)
	gl.CullFace(gl.BACK)
	gl.FrontFace(gl.CCW)
	gl.UseProgram(r.chunk.prog)
	eng.set_mat4(r.chunk.u_view_proj, cam.view_proj)
	eng.set_f32(r.chunk.u_time, f32(fp.time))
	eng.set_vec2(r.chunk.u_fog, fog)
	eng.set_i32(r.chunk.u_atlas, 0)
	eng.set_f32(r.chunk.u_alpha_cutoff, 0.5)
	eng.set_vec2(r.chunk.u_side_shade, r.side_shade)
	set_sky_uniforms(r, r.chunk.prog)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D_ARRAY, r.atlas)

	frustum := frustum_from(cam.view_proj)
	visible := make([dynamic]Visible_Chunk, 0, len(fp.world.chunks), context.temp_allocator)
	for _, c in fp.world.chunks {
		if !c.meshed do continue
		// чанк соседней грани лежит в кадре повёрнутым на 90°·k
		m, placed := geo_frame_of(&fp.world.geo, c.key.face)
		if !placed do continue
		fx, fz := xform_pos(m, f64(c.key.x * CHUNK_SIZE), f64(c.key.z * CHUNK_SIZE))
		origin := [3]f32{f32(fx - cam.pos.x), f32(-cam.pos.y), f32(fz - cam.pos.z)}
		rot := [4]f32{f32(m.r[0][0]), f32(m.r[1][0]), f32(m.r[0][1]), f32(m.r[1][1])}
		far := [2]f32{rot.x + rot.z, rot.y + rot.w} * CHUNK_SIZE // образ угла (16, 16)
		mn := [3]f32{origin.x + min(0, far.x), origin.y, origin.z + min(0, far.y)}
		mx := [3]f32{origin.x + max(0, far.x), origin.y + f32(c.max_y + 1), origin.z + max(0, far.y)}
		if !aabb_visible(&frustum, mn, mx) do continue
		centre := (mn + mx) / 2
		append(&visible, Visible_Chunk{c, origin, rot, centre.x * centre.x + centre.z * centre.z})
	}
	slice.sort_by(visible[:], proc(a, b: Visible_Chunk) -> bool {return a.dist2 < b.dist2})
	for &v in visible {
		eng.set_vec3(r.chunk.u_origin, v.origin)
		eng.set_vec4(r.chunk.u_rot, v.rot)
		chunk_mesh_draw(&v.chunk.opaque_mesh)
	}
	r.chunks_drawn = len(visible)

	// ---- персонажи: игрок (от третьего лица) и отряд
	gl.UseProgram(r.entity.prog)
	eng.set_i32(r.entity.u_skin, 0)
	eng.set_vec2(r.entity.u_fog, fog)
	set_sky_uniforms(r, r.entity.prog)
	eng.set_vec4(r.entity.u_tint, {})
	eng.set_vec4(r.entity.u_collapse, {})
	eng.set_mat4(r.entity.u_view_proj, cam.view_proj)
	ld := fp.landing
	landing_ui := ld.active // пока игрок без управления — никакого интерфейса
	update_light(&r.player_light, fp.world, p, fp.t, fp.dt)
	if ld.pods[0].rider_out && (cam.mode != .First_Person || landing_ui) {
		draw_character(r, &fp, p, fp.player_skin, r.player_light)
	}
	for &c, i in fp.squad.members {
		update_light(&c.light, fp.world, &c.body, fp.t, fp.dt)
		if ld.pods[i + 1].rider_out do draw_character(r, &fp, &c.body, c.skin_tex, c.light)
	}
	draw_pods(r, &fp)

	// ---- вода (сзади вперёд, полупрозрачная)
	gl.UseProgram(r.chunk.prog)
	eng.set_f32(r.chunk.u_alpha_cutoff, 0.001)
	gl.BindTexture(gl.TEXTURE_2D_ARRAY, r.atlas)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.DepthMask(false)
	gl.Disable(gl.CULL_FACE)
	#reverse for &v in visible[:] {
		if v.chunk.water_mesh.quads == 0 do continue
		eng.set_vec3(r.chunk.u_origin, v.origin)
		eng.set_vec4(r.chunk.u_rot, v.rot)
		chunk_mesh_draw(&v.chunk.water_mesh)
	}
	gl.Enable(gl.CULL_FACE)

	// ---- частицы (дым и пыль, затем светящиеся — огонь, искры)
	gl.Disable(gl.CULL_FACE)
	if len(ld.particles.list) > 0 {
		particles_draw(&ld.particles, cam, false, r.light.rgb)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE)
		particles_draw(&ld.particles, cam, true, r.light.rgb)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	}

	// ---- чёрные дыры (искажают уже нарисованную сцену)
	if holes := landing_holes(ld); len(holes) > 0 {
		lens_draw(&r.lens, holes, cam, fp.width, fp.height)
		gl.Enable(gl.BLEND)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.DepthMask(false)
		gl.Disable(gl.CULL_FACE)
	}

	// ---- значки приказов и метки целей (видны сквозь воду, но не сквозь землю)
	if !landing_ui do squad_draw_world(fp.squad, cam, fp.t, fp.time)
	gl.Enable(gl.CULL_FACE)
	gl.DepthMask(true)
	gl.Disable(gl.BLEND)

	if cam.mode == .First_Person && !landing_ui {
		// ---- рука
		gl.Clear(gl.DEPTH_BUFFER_BIT)
		gl.UseProgram(r.entity.prog)
		gl.BindTexture(gl.TEXTURE_2D, fp.player_skin)
		eng.set_f32(r.entity.u_light, r.player_light * fp.cloud_shade)
		eng.set_vec2(r.entity.u_fog, {1e6, 2e6})
		eng.set_vec4(eng.uniform_loc(r.entity.prog, "u_haze"), {})
		aspect := f32(fp.width) / f32(max(fp.height, 1))
		hand_proj := linalg.matrix4_perspective_f32(math.to_radians(f32(BASE_FOV)), aspect, NEAR_PLANE, 10)
		sway_pitch := eng.wrap_angle(p.pitch - cam.hand_pitch) * 0.1
		sway_yaw := eng.wrap_angle(p.yaw - cam.hand_yaw) * 0.1
		hand :=
			cam.bob *
			linalg.matrix4_rotate_f32(sway_pitch, {1, 0, 0}) *
			linalg.matrix4_rotate_f32(sway_yaw, {0, 1, 0}) *
			HAND_TRANSFORM()
		view_to_world := linalg.matrix4_inverse_f32(cam.view)
		humanoid_model_draw_hand(fp.model, &r.entity, hand_proj, view_to_world, hand)

	}

	// ---- интерфейс
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.Enable(gl.BLEND)
	fp.chunks_drawn = r.chunks_drawn
	if landing_ui {
		if fp.debug_page > 0 {
			gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
			hud_draw(&fp)
		}
	} else {
		if cam.mode != .Third_Front {
			gl.BlendFunc(gl.ONE_MINUS_DST_COLOR, gl.ONE_MINUS_SRC_COLOR)
			draw_crosshair(fp.width, fp.height)
		}
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		squad_draw_hud(fp.squad, fp.width, fp.height)
		hud_draw(&fp)
	}
	gl.Disable(gl.BLEND)
	gl.Enable(gl.DEPTH_TEST)
	gl.Enable(gl.CULL_FACE)
	gl.BindVertexArray(0)
}

// Капсулы высадки и их парашюты.
@(private = "file")
draw_pods :: proc(r: ^Renderer, fp: ^Frame_Params) {
	cam := fp.cam
	eng.set_f32(r.entity.u_light, fp.cloud_shade)
	for &pod in fp.landing.pods {
		if pod.state != .Gone {
			root := capsule_matrix(cam, pod.pos, pod.yaw, pod.tilt.x, pod.tilt.y)
			if pod.state == .Collapsing {
				c := pod.hole.center - cam.pos
				eng.set_vec4(r.entity.u_collapse, {f32(c.x), f32(c.y), f32(c.z), pod.collapse})
				eng.set_vec4(r.entity.u_tint, {0, 0, 0, pod.collapse * 0.6})
			}
			capsule_draw(fp.capsule, &r.entity, cam, root, pod.hatch, pod.chute == .Packed)
			eng.set_vec4(r.entity.u_collapse, {})
			eng.set_vec4(r.entity.u_tint, {})
			if pod.chute == .Open {
				g := eng.smoothstep(0, CHUTE_GROW, pod.chute_t)
				flutter := 1 + 0.06 * math.sin(pod.chute_t * 23)
				m := root * linalg.matrix4_translate_f32({0, POD_TOP, 0}) * linalg.matrix4_scale_f32({g * flutter, 0.3 + 0.7 * g, g / flutter})
				capsule_draw_chute(fp.capsule, &r.entity, cam, m)
			}
		}
		if pod.chute == .Torn {
			rel := [3]f32{f32(pod.chute_pos.x - cam.pos.x), f32(pod.chute_pos.y - cam.pos.y), f32(pod.chute_pos.z - cam.pos.z)}
			m :=
				linalg.matrix4_translate_f32(rel) *
				linalg.matrix4_rotate_f32(pod.chute_rot.y, {0, 1, 0}) *
				linalg.matrix4_rotate_f32(pod.chute_rot.x, {1, 0, 0}) *
				linalg.matrix4_rotate_f32(pod.chute_rot.z, {0, 0, 1})
			capsule_draw_chute(fp.capsule, &r.entity, cam, m)
		}
	}
}

// Положение правой руки в пространстве камеры (подобрано на глаз).
HAND_TRANSFORM :: proc() -> eng.Mat4 {
	return linalg.matrix4_translate_f32({0.55, -0.6, -0.35}) *
		linalg.matrix4_rotate_f32(0.25, {0, 1, 0}) *
		linalg.matrix4_rotate_f32(math.to_radians(f32(115)), {1, 0, 0}) *
		linalg.matrix4_rotate_f32(0.0, {0, 1, 0})
}
