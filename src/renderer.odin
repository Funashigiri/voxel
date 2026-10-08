package main

// Отрисовка кадра: небо -> непрозрачные чанки -> персонаж -> вода ->
// облака -> рука от первого лица -> прицел.

import "core:math"
import "core:math/linalg"
import "core:slice"
import eng "engine"
import gl "vendor:OpenGL"

Chunk_Shader :: struct {
	prog:                                                 u32,
	u_view_proj, u_origin, u_time, u_atlas, u_alpha_cutoff: i32,
	u_fog:                                                i32,
}

Entity_Shader :: struct {
	prog:                                                         u32,
	u_mvp, u_model, u_skin, u_light, u_fog: i32,
}

Sky_Shader :: struct {
	prog:                                                   u32,
	u_inv_view_proj, u_sun_dir: i32,
}

Cloud_Shader :: struct {
	prog:                                                  u32,
	u_view_proj, u_origin, u_fog: i32,
}

Renderer :: struct {
	chunk:          Chunk_Shader,
	entity:         Entity_Shader,
	sky:            Sky_Shader,
	cloud:          Cloud_Shader,
	atlas:          u32,
	fog:            [2]f32, // туман над водой (из дальности прорисовки)
	underwater:     bool, // камера под водой в этом кадре
	player_light:   f32,
	chunks_drawn:   int,
}

Frame_Params :: struct {
	world:       ^World,
	player:      ^Character,
	cam:         ^Camera,
	sky:         ^Sky,
	model:       ^Humanoid_Model,
	player_skin: u32,
	squad:       ^Squad,
	t:           f32, // доля между тиками
	time:        f64,
	dt:          f32,
	width:       i32,
	height:      i32,
}

renderer_init :: proc(r: ^Renderer, view_radius: i32) -> bool {
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
		}
	}
	{
		p := eng.shader_create("entity", ENTITY_VS, ENTITY_FS) or_return
		r.entity = {
			prog          = p,
			u_mvp         = loc(p, "u_mvp"),
			u_model       = loc(p, "u_model"),
			u_skin        = loc(p, "u_skin"),
			u_light       = loc(p, "u_light"),
			u_fog         = loc(p, "u_fog"),
		}
	}
	{
		p := eng.shader_create("sky", SKY_VS, SKY_FS) or_return
		r.sky = {
			prog            = p,
			u_inv_view_proj = loc(p, "u_inv_view_proj"),
			u_sun_dir       = loc(p, "u_sun_dir"),
		}
	}
	{
		p := eng.shader_create("cloud", CLOUD_VS, CLOUD_FS) or_return
		r.cloud = {
			prog          = p,
			u_view_proj   = loc(p, "u_view_proj"),
			u_origin      = loc(p, "u_origin"),
			u_fog         = loc(p, "u_fog"),
		}
	}
	eng.imm_init() or_return

	pixels := build_block_textures(context.temp_allocator)
	r.atlas = eng.texture_array_create(TEX_SIZE, TEX_SIZE, i32(TEX_LAYER_COUNT), pixels)

	view_blocks := f32(view_radius * CHUNK_SIZE)
	r.fog = {view_blocks * 0.55, view_blocks * 0.95}
	r.player_light = 1
	return true
}

WATER_FOG_COLOR :: [4]f32{0.12, 0.24, 0.55, 1}
WATER_FOG :: [2]f32{1, 34}

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
	dist2:  f32,
}

// Цвета неба и тумана. Под водой туман синий и густой (как в Minecraft).
@(private = "file")
set_sky_uniforms :: proc(r: ^Renderer, prog: u32) {
	eng.set_vec3(eng.uniform_loc(prog, "u_sky_top"), SKY_TOP)
	eng.set_vec3(eng.uniform_loc(prog, "u_sky_horizon"), SKY_HORIZON)
	eng.set_vec4(eng.uniform_loc(prog, "u_fog_override"), r.underwater ? WATER_FOG_COLOR : {})
}

// Плавно подстраивает яркость персонажа под свет в его клетке (тень деревьев и т.п.).
@(private = "file")
update_light :: proc(light: ^f32, w: ^World, ch: ^Character, t, dt: f32) {
	pos := character_render_pos(ch, t)
	target := world_sky_light(w, i32(math.floor(pos.x)), i32(math.floor(pos.y + 1)), i32(math.floor(pos.z)))
	light^ += (target - light^) * min(1, dt * 6)
}

@(private = "file")
draw_character :: proc(r: ^Renderer, fp: ^Frame_Params, ch: ^Character, skin: u32, light: f32) {
	cam := fp.cam
	pose, body_yaw := character_pose(ch, fp.t)
	feet := character_render_pos(ch, fp.t)
	rel := [3]f32{f32(feet.x - cam.pos.x), f32(feet.y - cam.pos.y), f32(feet.z - cam.pos.z)}
	eng.set_f32(r.entity.u_light, light)
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
	fog := r.underwater ? WATER_FOG : r.fog
	gl.ClearColor(SKY_HORIZON.r, SKY_HORIZON.g, SKY_HORIZON.b, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

	// ---- небо
	gl.Disable(gl.DEPTH_TEST)
	gl.DepthMask(false)
	gl.UseProgram(r.sky.prog)
	eng.set_mat4(r.sky.u_inv_view_proj, linalg.matrix4_inverse_f32(cam.view_proj))
	eng.set_vec3(r.sky.u_sun_dir, fp.sky.sun_dir)
	set_sky_uniforms(r, r.sky.prog)
	gl.BindVertexArray(fp.sky.empty_vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.Enable(gl.DEPTH_TEST)
	gl.DepthFunc(gl.LESS)
	gl.DepthMask(true)

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
	set_sky_uniforms(r, r.chunk.prog)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D_ARRAY, r.atlas)

	frustum := frustum_from(cam.view_proj)
	visible := make([dynamic]Visible_Chunk, 0, len(fp.world.chunks), context.temp_allocator)
	for _, c in fp.world.chunks {
		if !c.meshed do continue
		origin := [3]f32 {
			f32(f64(c.key.x * CHUNK_SIZE) - 1 - cam.pos.x),
			f32(-1 - cam.pos.y),
			f32(f64(c.key.y * CHUNK_SIZE) - 1 - cam.pos.z),
		}
		mn := origin + 1
		mx := mn + [3]f32{CHUNK_SIZE, f32(c.max_y + 2), CHUNK_SIZE}
		if !aabb_visible(&frustum, mn, mx) do continue
		centre := mn + [3]f32{8, 0, 8}
		append(&visible, Visible_Chunk{c, origin, centre.x * centre.x + centre.z * centre.z})
	}
	slice.sort_by(visible[:], proc(a, b: Visible_Chunk) -> bool {return a.dist2 < b.dist2})
	for &v in visible {
		eng.set_vec3(r.chunk.u_origin, v.origin)
		chunk_mesh_draw(&v.chunk.opaque_mesh)
	}
	r.chunks_drawn = len(visible)

	// ---- персонажи: игрок (от третьего лица) и отряд
	gl.UseProgram(r.entity.prog)
	eng.set_i32(r.entity.u_skin, 0)
	eng.set_vec2(r.entity.u_fog, fog)
	set_sky_uniforms(r, r.entity.prog)
	update_light(&r.player_light, fp.world, p, fp.t, fp.dt)
	if cam.mode != .First_Person do draw_character(r, &fp, p, fp.player_skin, r.player_light)
	for &c in fp.squad.members {
		update_light(&c.light, fp.world, &c.body, fp.t, fp.dt)
		draw_character(r, &fp, &c.body, c.skin_tex, c.light)
	}

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
		chunk_mesh_draw(&v.chunk.water_mesh)
	}
	gl.Enable(gl.CULL_FACE)

	// ---- значки приказов и метки целей (видны сквозь воду, но не сквозь землю)
	gl.Disable(gl.CULL_FACE)
	squad_draw_world(fp.squad, cam, fp.t, fp.time)
	gl.Enable(gl.CULL_FACE)
	gl.DepthMask(true)

	// ---- облака: сначала глубина, потом цвет (без двойного наложения граней)
	cloud_origin := sky_update_clouds(fp.sky, cam.pos, fp.time)
	if fp.sky.cloud_verts > 0 {
		gl.UseProgram(r.cloud.prog)
		eng.set_mat4(r.cloud.u_view_proj, cam.view_proj)
		eng.set_vec3(r.cloud.u_origin, cloud_origin)
		cloud_far := f32(CLOUD_RADIUS * CLOUD_CELL)
		eng.set_vec2(r.cloud.u_fog, r.underwater ? WATER_FOG : [2]f32{cloud_far * 0.45, cloud_far * 0.95})
		set_sky_uniforms(r, r.cloud.prog)
		gl.BindVertexArray(fp.sky.cloud_vao)
		gl.ColorMask(false, false, false, false)
		gl.DrawArrays(gl.TRIANGLES, 0, fp.sky.cloud_verts)
		gl.ColorMask(true, true, true, true)
		gl.DepthFunc(gl.LEQUAL)
		gl.DepthMask(false)
		gl.DrawArrays(gl.TRIANGLES, 0, fp.sky.cloud_verts)
		gl.DepthMask(true)
		gl.DepthFunc(gl.LESS)
	}
	gl.Disable(gl.BLEND)

	if cam.mode == .First_Person {
		// ---- рука
		gl.Clear(gl.DEPTH_BUFFER_BIT)
		gl.UseProgram(r.entity.prog)
		gl.BindTexture(gl.TEXTURE_2D, fp.player_skin)
		eng.set_f32(r.entity.u_light, r.player_light)
		eng.set_vec2(r.entity.u_fog, {1e6, 2e6})
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
	if cam.mode != .Third_Front {
		gl.BlendFunc(gl.ONE_MINUS_DST_COLOR, gl.ONE_MINUS_SRC_COLOR)
		draw_crosshair(fp.width, fp.height)
	}
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	squad_draw_hud(fp.squad, fp.width, fp.height)
	gl.Disable(gl.BLEND)
	gl.Enable(gl.DEPTH_TEST)
	gl.Enable(gl.CULL_FACE)
	gl.BindVertexArray(0)
}

// Положение правой руки в пространстве камеры (подобрано на глаз).
HAND_TRANSFORM :: proc() -> eng.Mat4 {
	return linalg.matrix4_translate_f32({0.55, -0.6, -0.35}) *
		linalg.matrix4_rotate_f32(0.25, {0, 1, 0}) *
		linalg.matrix4_rotate_f32(math.to_radians(f32(115)), {1, 0, 0}) *
		linalg.matrix4_rotate_f32(0.0, {0, 1, 0})
}
