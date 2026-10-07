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
	u_fog, u_sky_top, u_sky_horizon:                      i32,
}

Entity_Shader :: struct {
	prog:                                                         u32,
	u_mvp, u_model, u_skin, u_light, u_fog, u_sky_top, u_sky_horizon: i32,
}

Sky_Shader :: struct {
	prog:                                                   u32,
	u_inv_view_proj, u_sun_dir, u_sky_top, u_sky_horizon: i32,
}

Cloud_Shader :: struct {
	prog:                                                  u32,
	u_view_proj, u_origin, u_fog, u_sky_top, u_sky_horizon: i32,
}

UI_Shader :: struct {
	prog:               u32,
	u_screen, u_color: i32,
}

Renderer :: struct {
	chunk:          Chunk_Shader,
	entity:         Entity_Shader,
	sky:            Sky_Shader,
	cloud:          Cloud_Shader,
	ui:             UI_Shader,
	atlas:          u32,
	ui_vao, ui_vbo: u32,
	fog:            [2]f32,
	player_light:   f32,
	chunks_drawn:   int,
}

Frame_Params :: struct {
	world:       ^World,
	player:      ^Player,
	cam:         ^Camera,
	sky:         ^Sky,
	model:       ^Player_Model,
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
			u_sky_top      = loc(p, "u_sky_top"),
			u_sky_horizon  = loc(p, "u_sky_horizon"),
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
			u_sky_top     = loc(p, "u_sky_top"),
			u_sky_horizon = loc(p, "u_sky_horizon"),
		}
	}
	{
		p := eng.shader_create("sky", SKY_VS, SKY_FS) or_return
		r.sky = {
			prog            = p,
			u_inv_view_proj = loc(p, "u_inv_view_proj"),
			u_sun_dir       = loc(p, "u_sun_dir"),
			u_sky_top       = loc(p, "u_sky_top"),
			u_sky_horizon   = loc(p, "u_sky_horizon"),
		}
	}
	{
		p := eng.shader_create("cloud", CLOUD_VS, CLOUD_FS) or_return
		r.cloud = {
			prog          = p,
			u_view_proj   = loc(p, "u_view_proj"),
			u_origin      = loc(p, "u_origin"),
			u_fog         = loc(p, "u_fog"),
			u_sky_top     = loc(p, "u_sky_top"),
			u_sky_horizon = loc(p, "u_sky_horizon"),
		}
	}
	{
		p := eng.shader_create("ui", UI_VS, UI_FS) or_return
		r.ui = {
			prog     = p,
			u_screen = loc(p, "u_screen"),
			u_color  = loc(p, "u_color"),
		}
	}

	pixels := build_block_textures(context.temp_allocator)
	r.atlas = eng.texture_array_create(TEX_SIZE, TEX_SIZE, i32(TEX_LAYER_COUNT), pixels)

	gl.GenVertexArrays(1, &r.ui_vao)
	gl.GenBuffers(1, &r.ui_vbo)
	gl.BindVertexArray(r.ui_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.ui_vbo)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, size_of([2]f32), 0)
	gl.BindVertexArray(0)

	view_blocks := f32(view_radius * CHUNK_SIZE)
	r.fog = {view_blocks * 0.55, view_blocks * 0.95}
	r.player_light = 1
	return true
}

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

@(private = "file")
set_sky_uniforms :: proc(top, horizon: i32) {
	eng.set_vec3(top, SKY_TOP)
	eng.set_vec3(horizon, SKY_HORIZON)
}

@(private = "file")
ui_rect :: proc(out: ^[dynamic][2]f32, x0, y0, x1, y1: f32) {
	append(out, [2]f32{x0, y0}, [2]f32{x1, y0}, [2]f32{x1, y1}, [2]f32{x0, y0}, [2]f32{x1, y1}, [2]f32{x0, y1})
}

render_frame :: proc(r: ^Renderer, fp: Frame_Params) {
	cam := fp.cam
	p := fp.player
	gl.Viewport(0, 0, fp.width, fp.height)
	gl.ClearColor(SKY_HORIZON.r, SKY_HORIZON.g, SKY_HORIZON.b, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

	// ---- небо
	gl.Disable(gl.DEPTH_TEST)
	gl.DepthMask(false)
	gl.UseProgram(r.sky.prog)
	eng.set_mat4(r.sky.u_inv_view_proj, linalg.matrix4_inverse_f32(cam.view_proj))
	eng.set_vec3(r.sky.u_sun_dir, fp.sky.sun_dir)
	set_sky_uniforms(r.sky.u_sky_top, r.sky.u_sky_horizon)
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
	eng.set_vec2(r.chunk.u_fog, r.fog)
	eng.set_i32(r.chunk.u_atlas, 0)
	eng.set_f32(r.chunk.u_alpha_cutoff, 0.5)
	set_sky_uniforms(r.chunk.u_sky_top, r.chunk.u_sky_horizon)
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

	// ---- персонаж (от третьего лица)
	{
		eye := player_render_pos(p, fp.t)
		target := world_sky_light(fp.world, i32(math.floor(eye.x)), i32(math.floor(eye.y + 1)), i32(math.floor(eye.z)))
		r.player_light += (target - r.player_light) * min(1, fp.dt * 6)
	}
	gl.UseProgram(r.entity.prog)
	eng.set_i32(r.entity.u_skin, 0)
	eng.set_f32(r.entity.u_light, r.player_light)
	eng.set_vec2(r.entity.u_fog, r.fog)
	set_sky_uniforms(r.entity.u_sky_top, r.entity.u_sky_horizon)
	gl.BindTexture(gl.TEXTURE_2D, fp.model.skin_tex)
	if cam.mode != .First_Person {
		pose, body_yaw := player_pose(p, fp.t)
		feet := player_render_pos(p, fp.t)
		rel := [3]f32{f32(feet.x - cam.pos.x), f32(feet.y - cam.pos.y), f32(feet.z - cam.pos.z)}
		player_model_draw(fp.model, &r.entity, cam.view_proj, rel, body_yaw, &pose)
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
	gl.DepthMask(true)
	gl.Enable(gl.CULL_FACE)

	// ---- облака: сначала глубина, потом цвет (без двойного наложения граней)
	cloud_origin := sky_update_clouds(fp.sky, cam.pos, fp.time)
	if fp.sky.cloud_verts > 0 {
		gl.UseProgram(r.cloud.prog)
		eng.set_mat4(r.cloud.u_view_proj, cam.view_proj)
		eng.set_vec3(r.cloud.u_origin, cloud_origin)
		cloud_far := f32(CLOUD_RADIUS * CLOUD_CELL)
		eng.set_vec2(r.cloud.u_fog, {cloud_far * 0.45, cloud_far * 0.95})
		set_sky_uniforms(r.cloud.u_sky_top, r.cloud.u_sky_horizon)
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
		gl.BindTexture(gl.TEXTURE_2D, fp.model.skin_tex)
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
		player_model_draw_hand(fp.model, &r.entity, hand_proj, view_to_world, hand)

		// ---- прицел (инвертирует цвет под собой, как в Minecraft)
		scale := max(1, math.round(f32(fp.height) / 360))
		cx, cy := f32(fp.width) / 2, f32(fp.height) / 2
		th := scale // толщина
		half := 4.5 * scale
		verts := make([dynamic][2]f32, context.temp_allocator)
		ui_rect(&verts, cx - half, cy - th / 2, cx + half, cy + th / 2)
		ui_rect(&verts, cx - th / 2, cy - half, cx + th / 2, cy - th / 2)
		ui_rect(&verts, cx - th / 2, cy + th / 2, cx + th / 2, cy + half)
		gl.Disable(gl.DEPTH_TEST)
		gl.Disable(gl.CULL_FACE)
		gl.Enable(gl.BLEND)
		gl.BlendFunc(gl.ONE_MINUS_DST_COLOR, gl.ONE_MINUS_SRC_COLOR)
		gl.UseProgram(r.ui.prog)
		eng.set_vec2(r.ui.u_screen, {f32(fp.width), f32(fp.height)})
		eng.set_vec4(r.ui.u_color, {1, 1, 1, 1})
		gl.BindVertexArray(r.ui_vao)
		gl.BindBuffer(gl.ARRAY_BUFFER, r.ui_vbo)
		gl.BufferData(gl.ARRAY_BUFFER, len(verts) * size_of([2]f32), raw_data(verts), gl.STREAM_DRAW)
		gl.DrawArrays(gl.TRIANGLES, 0, i32(len(verts)))
		gl.Disable(gl.BLEND)
		gl.Enable(gl.DEPTH_TEST)
		gl.Enable(gl.CULL_FACE)
	}
	gl.BindVertexArray(0)
}

// Положение правой руки в пространстве камеры (подобрано на глаз).
HAND_TRANSFORM :: proc() -> eng.Mat4 {
	return linalg.matrix4_translate_f32({0.55, -0.6, -0.35}) *
		linalg.matrix4_rotate_f32(0.25, {0, 1, 0}) *
		linalg.matrix4_rotate_f32(math.to_radians(f32(115)), {1, 0, 0}) *
		linalg.matrix4_rotate_f32(0.0, {0, 1, 0})
}
