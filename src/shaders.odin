package main

// Исходники GLSL 3.30.

// Градиент неба; им же окрашивается туман, чтобы дальние блоки
// плавно растворялись в горизонте.
SKY_GLSL :: `
uniform vec3 u_sky_top;
uniform vec3 u_sky_horizon;
vec3 sky_color(vec3 dir) {
	float t = max(dir.y, 0.0);
	return mix(u_sky_horizon, u_sky_top, 1.0 - exp(-t * 5.0));
}
`

// ---------------------------------------------------------------- чанки
CHUNK_VS :: `#version 330 core
layout(location = 0) in uvec4 a_pos;  // xyz: 1/16 блока, w: свет | грань<<8 | флаги<<11
layout(location = 1) in uvec4 a_tex;  // u, v (тексели), слой
uniform mat4 u_view_proj;
uniform vec3 u_origin;   // начало чанка относительно камеры
uniform float u_time;
out vec3 v_uvl;
out float v_light;
out vec3 v_rel;
// Направленное затенение граней как в Minecraft: верх 1.0, бока 0.8/0.6, низ 0.5.
const float FACE_SHADE[7] = float[7](0.6, 0.6, 1.0, 0.5, 0.8, 0.8, 1.0);
void main() {
	vec3 p = vec3(a_pos.xyz) * (1.0 / 16.0) + u_origin;
	uint face = (a_pos.w >> 8u) & 7u;
	uint flags = a_pos.w >> 11u;
	float layer = float(a_tex.z);
	if ((flags & 1u) != 0u) layer += float(int(u_time * 10.0) % 32); // WATER_FRAMES
	v_uvl = vec3(vec2(a_tex.xy) * (1.0 / 16.0), layer);
	v_light = float(a_pos.w & 255u) / 255.0 * FACE_SHADE[face];
	v_rel = p;
	gl_Position = u_view_proj * vec4(p, 1.0);
}
`

CHUNK_FS :: `#version 330 core
in vec3 v_uvl;
in float v_light;
in vec3 v_rel;
uniform sampler2DArray u_atlas;
uniform float u_alpha_cutoff;
uniform vec2 u_fog;
out vec4 o_color;
` + SKY_GLSL + `
void main() {
	vec4 c = texture(u_atlas, v_uvl);
	if (c.a < u_alpha_cutoff) discard;
	vec3 col = c.rgb * v_light;
	float fog = clamp((length(v_rel.xz) - u_fog.x) / (u_fog.y - u_fog.x), 0.0, 1.0);
	col = mix(col, sky_color(normalize(v_rel)), fog);
	o_color = vec4(col, c.a);
}
`

// ---------------------------------------------------------------- небо
SKY_VS :: `#version 330 core
out vec2 v_ndc;
void main() {
	vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2) * 2.0 - 1.0;
	v_ndc = p;
	gl_Position = vec4(p, 0.0, 1.0);
}
`

SKY_FS :: `#version 330 core
in vec2 v_ndc;
uniform mat4 u_inv_view_proj;
uniform vec3 u_sun_dir;
out vec4 o_color;
` + SKY_GLSL + `
void main() {
	vec4 a = u_inv_view_proj * vec4(v_ndc, 1.0, 1.0);
	vec3 dir = normalize(a.xyz / a.w);
	vec3 col = sky_color(dir);

	// квадратное пиксельное солнце с ореолом
	float sd = dot(dir, u_sun_dir);
	if (sd > 0.0) {
		vec3 right = normalize(cross(u_sun_dir, vec3(0.0, 0.0, 1.0)));
		vec3 up = cross(right, u_sun_dir);
		vec2 q = vec2(dot(dir, right), dot(dir, up)) / sd;
		vec2 px = floor(q / 0.16 * 16.0) + 0.5;
		float m = max(abs(px.x), abs(px.y));
		if (m < 16.0) {
			float g = 1.0 - m / 16.0;
			col += vec3(1.0, 0.92, 0.7) * g * g * 0.45;
		}
		if (m < 8.0) col = vec3(1.0, 0.96, 0.72);
		if (m < 6.0) col = vec3(1.0, 1.0, 0.93);
	}
	o_color = vec4(col, 1.0);
}
`

// ---------------------------------------------------------------- персонаж
ENTITY_VS :: `#version 330 core
layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec3 a_normal;
uniform mat4 u_mvp;
uniform mat4 u_model;    // в мировые оси (относительно камеры)
out vec2 v_uv;
out vec3 v_normal;
out vec3 v_rel;
void main() {
	v_uv = a_uv;
	v_normal = mat3(u_model) * a_normal;
	v_rel = (u_model * vec4(a_pos, 1.0)).xyz;
	gl_Position = u_mvp * vec4(a_pos, 1.0);
}
`

ENTITY_FS :: `#version 330 core
in vec2 v_uv;
in vec3 v_normal;
in vec3 v_rel;
uniform sampler2D u_skin;
uniform float u_light;
uniform vec2 u_fog;
out vec4 o_color;
` + SKY_GLSL + `
// два источника света, как у мобов в Minecraft
const vec3 L0 = vec3(0.16169, 0.80845, -0.56592);
const vec3 L1 = vec3(-0.16169, 0.80845, 0.56592);
void main() {
	vec4 c = texture(u_skin, v_uv);
	if (c.a < 0.1) discard;
	vec3 n = normalize(v_normal);
	float diff = min(1.0, 0.4 + 0.6 * (max(dot(n, L0), 0.0) + max(dot(n, L1), 0.0)));
	vec3 col = c.rgb * diff * u_light;
	float fog = clamp((length(v_rel.xz) - u_fog.x) / (u_fog.y - u_fog.x), 0.0, 1.0);
	col = mix(col, sky_color(normalize(v_rel)), fog);
	o_color = vec4(col, 1.0);
}
`

// ---------------------------------------------------------------- облака
CLOUD_VS :: `#version 330 core
layout(location = 0) in vec3 a_pos;
layout(location = 1) in float a_shade;
uniform mat4 u_view_proj;
uniform vec3 u_origin;
out float v_shade;
out vec3 v_rel;
void main() {
	vec3 p = a_pos + u_origin;
	v_rel = p;
	v_shade = a_shade;
	gl_Position = u_view_proj * vec4(p, 1.0);
}
`

CLOUD_FS :: `#version 330 core
in float v_shade;
in vec3 v_rel;
uniform vec2 u_fog;
out vec4 o_color;
` + SKY_GLSL + `
void main() {
	vec3 col = vec3(1.0) * v_shade;
	float fog = clamp((length(v_rel.xz) - u_fog.x) / (u_fog.y - u_fog.x), 0.0, 1.0);
	col = mix(col, sky_color(normalize(v_rel)), fog);
	o_color = vec4(col, 0.8 * (1.0 - fog));
}
`
