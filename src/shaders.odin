package main

// Исходники GLSL 3.30.

// Градиент неба; им же окрашивается туман, чтобы дальние блоки
// плавно растворялись в горизонте.
SKY_GLSL :: `
uniform vec3 u_sky_top;
uniform vec3 u_sky_horizon;
uniform vec4 u_fog_override; // rgb + флаг (1 — камера под водой)
vec3 sky_color(vec3 dir) {
	if (u_fog_override.w > 0.5) return u_fog_override.rgb;
	float t = max(dir.y, 0.0);
	return mix(u_sky_horizon, u_sky_top, 1.0 - exp(-t * 5.0));
}
`

// Туман аномалии (вершина куба-планеты): шар радиуса R, плотность
// k·(1 − r²/R²)² — густо у столпа, редеет к краю. Оптическая толщина вдоль
// луча от камеры считается точно: интеграл многочлена по отрезку внутри шара.
ANOMALY_GLSL :: `
uniform vec4 u_anomaly; // xyz — центр относительно камеры, w — радиус (0 — далеко)
const vec3 ANOMALY_COLOR = vec3(0.62, 0.58, 0.70);
const float ANOMALY_DENSITY = 0.25; // в центре видно ~8 блоков
float anomaly_depth(vec3 dir, float dist) {
	float R = u_anomaly.w;
	if (R <= 0.0) return 0.0;
	vec3 oc = -u_anomaly.xyz;       // камера относительно центра
	float b = dot(dir, oc);
	float h2 = dot(oc, oc) - b * b; // квадрат расстояния от центра до луча
	float R2 = R * R;
	if (h2 >= R2) return 0.0;
	float hw = sqrt(R2 - h2);
	// s = t + b — параметр от ближайшей к центру точки луча
	float lo = max(-hw, b);
	float hi = min(hw, dist + b);
	if (hi <= lo) return 0.0;
	float a = 1.0 - h2 / R2;
	vec2 u = vec2(lo, hi) / R;
	vec2 u3 = u * u * u;
	vec2 F = a * a * u - (2.0 * a / 3.0) * u3 + u3 * u * u / 5.0;
	return ANOMALY_DENSITY * R * (F.y - F.x);
}
vec3 apply_anomaly(vec3 col, vec3 rel, float dist) {
	float tau = anomaly_depth(rel / max(length(rel), 1e-4), dist);
	return mix(col, ANOMALY_COLOR, 1.0 - exp(-tau));
}
`

// ---------------------------------------------------------------- чанки
CHUNK_VS :: `#version 330 core
layout(location = 0) in uvec4 a_pos;  // xyz: 1/16 блока, w: свет | грань<<8 | флаги<<11
layout(location = 1) in uvec4 a_tex;  // u, v (тексели), слой
uniform mat4 u_view_proj;
uniform vec3 u_origin;     // начало чанка относительно камеры
uniform vec4 u_rot;        // поворот сетки грани чанка в кадр (mat2 по столбцам)
uniform vec2 u_side_shade; // затенение боков, смотрящих вдоль x и вдоль z кадра
uniform float u_time;
out vec3 v_uvl;
out float v_light;
out vec3 v_rel;
// Направленное затенение граней как в Minecraft: верх 1.0, бока 0.8/0.6, низ 0.5.
const float FACE_SHADE[7] = float[7](0.6, 0.6, 1.0, 0.5, 0.8, 0.8, 1.0);
void main() {
	vec3 q = vec3(a_pos.xyz) * (1.0 / 16.0) - 1.0; // позиции сдвинуты на +1 блок
	vec2 xz = mat2(u_rot.xy, u_rot.zw) * q.xz;
	vec3 p = vec3(xz.x, q.y, xz.y) + u_origin;
	uint face = (a_pos.w >> 8u) & 7u;
	float shade = FACE_SHADE[face];
	if (face < 2u || face == 4u || face == 5u) {
		bool along_x = (face < 2u) != (u_rot.x == 0.0); // поворот на 90° меняет оси
		shade = along_x ? u_side_shade.x : u_side_shade.y;
	}
	uint flags = a_pos.w >> 11u;
	float layer = float(a_tex.z);
	if ((flags & 1u) != 0u) layer += float(int(u_time * 10.0) % 32); // WATER_FRAMES
	v_uvl = vec3(vec2(a_tex.xy) * (1.0 / 16.0), layer);
	v_light = float(a_pos.w & 255u) / 255.0 * shade;
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
` + SKY_GLSL + ANOMALY_GLSL + `
void main() {
	vec4 c = texture(u_atlas, v_uvl);
	if (c.a < u_alpha_cutoff) discard;
	vec3 col = c.rgb * v_light;
	float fog = clamp((length(v_rel.xz) - u_fog.x) / (u_fog.y - u_fog.x), 0.0, 1.0);
	col = mix(col, sky_color(normalize(v_rel)), fog);
	col = apply_anomaly(col, v_rel, length(v_rel));
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
` + SKY_GLSL + ANOMALY_GLSL + `
void main() {
	vec4 a = u_inv_view_proj * vec4(v_ndc, 1.0, 1.0);
	vec3 dir = normalize(a.xyz / a.w);
	vec3 col = sky_color(dir);

	// квадратное пиксельное солнце с ореолом
	float sd = dot(dir, u_sun_dir);
	if (sd > 0.0 && u_fog_override.w < 0.5) {
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
	col = apply_anomaly(col, dir, 1e4);
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
uniform mat4 u_view_proj;
uniform vec4 u_collapse; // xyz — центр чёрной дыры (относительно камеры), w — 0..1
out vec2 v_uv;
out vec3 v_normal;
out vec3 v_rel;
void main() {
	v_uv = a_uv;
	v_normal = mat3(u_model) * a_normal;
	vec3 wp = (u_model * vec4(a_pos, 1.0)).xyz;
	if (u_collapse.w > 0.0) {
		// стягивание в точку: дальние части затягиваются позже, всё закручивается
		vec3 d = wp - u_collapse.xyz;
		float r = length(d);
		float k = u_collapse.w;
		float s = pow(1.0 - k, 1.0 + 1.5 / (r + 0.3));
		float a = k * k * 7.0 / (r + 0.6);
		d = vec3(d.x * cos(a) - d.z * sin(a), d.y * (1.0 - 0.3 * k), d.x * sin(a) + d.z * cos(a));
		wp = u_collapse.xyz + d * s;
		gl_Position = u_view_proj * vec4(wp, 1.0);
	} else {
		gl_Position = u_mvp * vec4(a_pos, 1.0);
	}
	v_rel = wp;
}
`

ENTITY_FS :: `#version 330 core
in vec2 v_uv;
in vec3 v_normal;
in vec3 v_rel;
uniform sampler2D u_skin;
uniform float u_light;
uniform vec2 u_fog;
uniform vec4 u_tint; // rgb + сила (свечение, вспышки)
out vec4 o_color;
` + SKY_GLSL + ANOMALY_GLSL + `
// два источника света, как у мобов в Minecraft
const vec3 L0 = vec3(0.16169, 0.80845, -0.56592);
const vec3 L1 = vec3(-0.16169, 0.80845, 0.56592);
void main() {
	vec4 c = texture(u_skin, v_uv);
	if (c.a < 0.1) discard;
	vec3 n = normalize(v_normal);
	float diff = min(1.0, 0.4 + 0.6 * (max(dot(n, L0), 0.0) + max(dot(n, L1), 0.0)));
	vec3 col = c.rgb * diff * u_light;
	col = mix(col, u_tint.rgb, u_tint.a);
	float fog = clamp((length(v_rel.xz) - u_fog.x) / (u_fog.y - u_fog.x), 0.0, 1.0);
	col = mix(col, sky_color(normalize(v_rel)), fog);
	col = apply_anomaly(col, v_rel, length(v_rel));
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
` + SKY_GLSL + ANOMALY_GLSL + `
void main() {
	vec3 col = vec3(1.0) * v_shade;
	float fog = clamp((length(v_rel.xz) - u_fog.x) / (u_fog.y - u_fog.x), 0.0, 1.0);
	col = mix(col, sky_color(normalize(v_rel)), fog);
	col = apply_anomaly(col, v_rel, length(v_rel));
	o_color = vec4(col, 0.8 * (1.0 - fog));
}
`
