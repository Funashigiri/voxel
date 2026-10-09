package main

// Исходники GLSL 3.30.

// Градиент неба (цвета — от высоты солнца, astro.odin) и зарево заката со
// стороны солнца; им же окрашивается туман, чтобы дальние блоки плавно
// растворялись в горизонте. apply_light — освещение мира светом неба.
SKY_GLSL :: `
uniform vec3 u_sky_top;
uniform vec3 u_sky_horizon;
uniform vec4 u_fog_override; // rgb + флаг (1 — камера под водой)
uniform vec3 u_sun_dir;      // направление на солнце (оси кадра)
uniform vec4 u_glow;         // зарево заката: цвет и сила
uniform vec4 u_light;        // освещение: цвет и яркость (rgb), обесцвечивание (a)
vec3 sky_color(vec3 dir) {
	if (u_fog_override.w > 0.5) return u_fog_override.rgb;
	float t = max(dir.y, 0.0);
	vec3 col = mix(u_sky_horizon, u_sky_top, 1.0 - exp(-t * 5.0));
	float sl = length(u_sun_dir.xz);
	float side = sl > 1e-4 ? dot(normalize(dir.xz + vec2(1e-6)), u_sun_dir.xz / sl) : 0.0;
	float hz = pow(1.0 - min(abs(dir.y), 1.0), 6.0);
	col += u_glow.rgb * u_glow.a * hz * (0.2 + 0.8 * pow(max(side, 0.0), 3.0));
	return col;
}
// В темноте цвета пропадают — ночное зрение видит только яркость.
vec3 apply_light(vec3 c) {
	vec3 lit = c * u_light.rgb;
	float l = dot(lit, vec3(0.3, 0.59, 0.11));
	return mix(lit, vec3(l) * vec3(0.85, 0.95, 1.15), u_light.a);
}
`

// Воздушная дымка: даль бледнеет и голубеет (на закате — теплеет, ночью —
// темнеет) — цвет берётся у неба в ту сторону. Плотность дымки падает с
// высотой (экспонента), оптическая толщина вдоль луча — по Симпсону с учётом
// кривизны планеты: на 100 км луч уходит над землёй на ~800 м выше.
HAZE_GLSL :: `
uniform vec4 u_haze; // x — ослабление у моря (1/м), y — 1/высота дымки (1/м), z — высота камеры над морем (м), w — 1/(2R)
float haze_tau(vec3 rel) {
	if (u_haze.x <= 0.0) return 0.0;
	float d = length(rel);
	float hor = dot(rel.xz, rel.xz) * u_haze.w;
	float h0 = u_haze.z;
	float h1 = h0 + rel.y + hor;
	float hm = h0 + 0.5 * rel.y + 0.25 * hor;
	float e0 = exp(-max(h0, -50.0) * u_haze.y);
	float em = exp(-max(hm, -50.0) * u_haze.y);
	float e1 = exp(-max(h1, -50.0) * u_haze.y);
	return u_haze.x * d * (e0 + 4.0 * em + e1) / 6.0;
}
vec3 apply_haze(vec3 col, vec3 rel) {
	float t = haze_tau(rel);
	return mix(col, sky_color(normalize(rel)), 1.0 - exp(-t));
}
`

// Шум облаков — тот же, что в clouds.odin (целочисленный хеш, value noise):
// по нему же считаются тени облаков на земле и освещённость там, где стоим.
CLOUD_GLSL :: `
uniform vec3 u_cloud_q0; // камера в координатах шума облаков
uniform mat3 u_cloud_jq; // оси кадра -> координаты шума
uniform vec4 u_cloud;    // x — облачность мира, y — время (медленные перемены), z — высота облаков над морем (м), w — 1: облака есть
uniform sampler3D u_cloud_noise; // значения в узлах решётки (128³, повторяется)
// Value noise: текстура сама смешивает 8 узлов — нужно лишь сдвинуть точку
// внутри клетки по плавной кривой (smoothstep), как в clouds.odin.
float cloud_vnoise(vec3 p) {
	vec3 fl = floor(p);
	vec3 f = p - fl;
	vec3 u = f * f * (3.0 - 2.0 * f);
	return texture(u_cloud_noise, (mod(fl, 128.0) + u + 0.5) / 128.0).r;
}
// Плотность облака 0..1. fp — размер пикселя в единицах шума: мелкие октавы
// вдали гаснут (заменяются средним), чтобы не мерцали; octaves — сколько считать.
float cloud_density(vec3 q, float fp, int octaves) {
	float sum = 0.0, amp = 0.5, f = 1.0;
	for (int i = 0; i < 5; i++) {
		float w = i < octaves ? clamp(2.0 - 4.0 * fp * f, 0.0, 1.0) : 0.0;
		sum += amp * (w > 0.0 ? mix(0.5, cloud_vnoise(q * f + float(i) * 17.31), w) : 0.5);
		amp *= 0.5;
		f *= 2.0;
	}
	float n = sum / 0.96875;
	float cov = u_cloud.x + 0.45 * (cloud_vnoise(q / 40.0 + vec3(0.0, u_cloud.y, 0.0)) - 0.5) * 2.0;
	float thr = 0.5 + 0.2 * (0.5 - cov) * 2.0;
	return smoothstep(thr, thr + 0.14, n);
}
float cloud_alpha(float d) {
	return 1.0 - exp(-d * 3.5);
}
// Тень облаков на земле в точке rel (относительно камеры, оси кадра).
float cloud_shadow(vec3 rel) {
	float sy = u_sun_dir.y;
	if (u_cloud.w < 0.5 || sy <= 0.0) return 1.0;
	float h = u_haze.z + rel.y + dot(rel.xz, rel.xz) * u_haze.w;
	if (h > u_cloud.z) return 1.0; // выше облаков — тени нет
	float t = (u_cloud.z - h) / max(sy, 0.05);
	vec3 q = u_cloud_q0 + u_cloud_jq * (rel + u_sun_dir * t);
	float a = cloud_alpha(cloud_density(q, 0.0, 3)) * smoothstep(0.0, 1.0, sy / 0.1);
	return 1.0 - 0.55 * a;
}
`

// Логарифмическая глубина дальнего прохода: от метров до тысяч километров.
LOGDEPTH_GLSL :: `
uniform float u_logk; // 2 / log2(дальняя граница + 1)
vec4 log_depth(vec4 p) {
	p.z = (log2(max(p.w, 1e-6) + 1.0) * u_logk - 1.0) * p.w;
	return p;
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
// Времена года на поверхности (climate.odin): оттенок травы и листвы по
// климату, трава жухнет зимой и в засуху, листва дуба и берёзы осенью желтеет и
// краснеет, зимой опадает; в мороз (если идут осадки) ложится снег.
SEASON_GLSL :: `
const vec3 SNOW_COLOR = vec3(0.9, 0.93, 0.98);
// оттенок по климату: сухо — желтее, холодно — буро-оливковый
vec3 grass_tint(vec3 c, vec2 tint) {
	vec3 m = mix(vec3(1.0), vec3(1.32, 1.08, 0.52), tint.x);
	m = mix(m, vec3(0.8, 0.7, 0.48), tint.y);
	return c * m;
}
// зимой и в сухой сезон трава жухнет
vec3 grass_season(vec3 c, float t, float p) {
	float dormant = max(smoothstep(4.0, -2.0, t), smoothstep(25.0, 5.0, p) * smoothstep(12.0, 18.0, t) * 0.8);
	return mix(c, c * vec3(1.12, 0.92, 0.5), dormant);
}
// осень: при похолодании ниже ~13 °C листва желтеет (весной молодая листва зелёная)
vec3 leaf_autumn(vec3 c, float t, float trend, vec3 autumn) {
	float a = trend < 0.0 ? smoothstep(13.0, 7.0, t) : 0.0;
	float lum = dot(c, vec3(0.3, 0.59, 0.11));
	return mix(c, autumn * lum * 2.2, a);
}
// 0 — в листве, 1 — голые ветки: осенью листья опадают при 9…3 °C,
// весной распускаются при 6…10 °C
float leaves_bare(float t, float trend) {
	return trend < 0.0 ? smoothstep(9.0, 3.0, t) : smoothstep(10.0, 6.0, t);
}
// осенние цвета: берёза — золотая, дуб — от жёлто-бурого до рыжего
vec3 autumn_color(bool birch, float h) {
	return birch ? mix(vec3(0.98, 0.8, 0.2), vec3(0.92, 0.64, 0.16), h) : mix(vec3(0.8, 0.62, 0.2), vec3(0.66, 0.36, 0.12), h);
}
// гладкий шум (0…1) — у соседних блоков одного дерева почти одинаковый
float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}
float vnoise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x), mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
	           mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x), mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
// снег: ложится в мороз и копится всю зиму (за несколько месяцев — даже при
// скудных осадках), весной сходит с запаздыванием; в сухом климате его нет
float snow_cover(float t, float trend, float p) {
	float cold = trend < 0.0 ? smoothstep(1.0, -2.0, t) : smoothstep(3.0, -1.0, t);
	return cold * smoothstep(3.0, 20.0, p * 4.0);
}
`

CHUNK_VS :: `#version 330 core
layout(location = 0) in uvec4 a_pos;  // xyz: 1/16 блока, w: свет | грань<<8 | флаги<<11
layout(location = 1) in uvec4 a_tex;  // u, v (тексели), слой, климат (сухость | холод<<4)
uniform mat4 u_view_proj;
uniform vec3 u_origin;     // начало чанка относительно камеры
uniform vec4 u_rot;        // поворот сетки грани чанка в кадр (mat2 по столбцам)
uniform vec2 u_side_shade; // затенение боков, смотрящих вдоль x и вдоль z кадра
uniform float u_time;
uniform float u_chunk_alt; // низ чанка над уровнем моря, м
uniform vec4 u_layer_a;    // слои: верх травы, бок травы, высокая трава, листва дуба
uniform vec4 u_layer_b;    // листва берёзы, хвоя ели, листва акации, листва тропического дерева
uniform vec4 u_layer_c;    // одуванчик, мак
uniform vec3 u_chunk_id;   // номер секции (по модулю 1024) — для шума, привязанного к миру
out vec3 v_uvl;
out vec3 v_wpos; // позиция в сетке грани (по модулю), м
flat out float v_bhash; // свой у каждого блока листвы (0…1, 16 ступеней)
out float v_light;
out vec3 v_rel;
out float v_alt;
out vec2 v_tint;
flat out int v_kind; // 1 — верх травы, 2 — бок травы, 3 — трава-растение, 4 — листопадная листва, 5 — вечнозелёная, 6 — прочий верх, 7 — цветы
flat out int v_face;
flat out float v_hash;
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
	float base = float(a_tex.z);
	float layer = base;
	if ((flags & 1u) != 0u) layer += float(int(u_time * 10.0) % 32); // WATER_FRAMES
	v_uvl = vec3(vec2(a_tex.xy) * (1.0 / 16.0), layer);
	v_light = float(a_pos.w & 255u) / 255.0 * shade;
	v_rel = p;
	v_alt = u_chunk_alt + q.y;
	v_tint = vec2(float(a_tex.w & 15u), float(a_tex.w >> 4u)) / 15.0;
	v_face = int(face);
	int kind = face == 2u ? 6 : 0;
	if (base == u_layer_a.x) kind = 1;
	else if (base == u_layer_a.y) kind = 2;
	else if (base == u_layer_a.z) kind = 3;
	else if (base == u_layer_a.w || base == u_layer_b.x) kind = 4;
	else if (base == u_layer_b.y || base == u_layer_b.z || base == u_layer_b.w) kind = 5;
	else if (base == u_layer_c.x || base == u_layer_c.y) kind = 7;
	if ((flags & 1u) != 0u) kind = 0; // вода
	v_kind = kind;
	vec3 cell = floor(q - vec3(0.01));
	v_hash = fract(sin(dot(cell + u_origin * 0.0, vec3(12.9898, 78.233, 37.719)) + u_chunk_alt * 0.37) * 43758.5453);
	v_bhash = float((flags >> 1u) & 15u) / 15.0;
	v_wpos = u_chunk_id * 16.0 + q;
	gl_Position = u_view_proj * vec4(p, 1.0);
}
`

CHUNK_FS :: `#version 330 core
in vec3 v_uvl;
in float v_light;
in vec3 v_rel;
in float v_alt;
in vec2 v_tint;
flat in int v_kind;
flat in int v_face;
flat in float v_hash;
in vec3 v_wpos;
flat in float v_bhash;
uniform sampler2DArray u_atlas;
uniform float u_alpha_cutoff;
uniform vec2 u_fog; // туман под водой
uniform vec4 u_season; // температура у моря сейчас (°C), её ход за месяц, осадки за месяц (мм); w — 1: климат есть
uniform float u_lapse; // похолодание с высотой, К/м
uniform vec4 u_layer_a;
uniform vec4 u_layer_b;
uniform vec4 u_layer_d; // веточки дуба и берёзы (голая крона)
out vec4 o_color;
` + SKY_GLSL + HAZE_GLSL + CLOUD_GLSL + ANOMALY_GLSL + SEASON_GLSL + `
void main() {
	vec4 c = texture(u_atlas, v_uvl);
	bool twigs = false;
	float t = u_season.x - u_lapse * max(v_alt, 0.0);
	float tree = 0.5; // у каждого дерева свой срок листопада и свой осенний цвет
	if (u_season.w > 0.5 && v_kind == 4) {
		tree = vnoise3(v_wpos / 5.0);
		// лист опадает блоками: у каждого блока листвы свой день
		if (leaves_bare(t + (tree - 0.5) * 4.0, u_season.y) > 0.03 + 0.94 * v_bhash) {
			twigs = true;
			vec2 uv = v_uvl.xy; // узор веточек повёрнут по-своему в каждом блоке
			int hb = int(v_bhash * 15.0 + 0.5);
			if ((hb & 1) != 0) uv.x = 1.0 - uv.x;
			if ((hb & 2) != 0) uv = uv.yx;
			if ((hb & 4) != 0) uv.y = 1.0 - uv.y;
			c = texture(u_atlas, vec3(uv, v_uvl.z == u_layer_a.w ? u_layer_d.x : u_layer_d.y));
			// вдали тонкие веточки не исчезают: в мипмапе прозрачность — доля
			// веточек в клетке, и точка остаётся с такой вероятностью
			float dither = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
			if (c.a <= dither * 0.98 + 0.01) discard;
		}
	}
	if (!twigs && c.a < u_alpha_cutoff) discard;
	vec3 base = c.rgb;
	if (u_season.w > 0.5 && v_kind > 0) {
		float snow = snow_cover(t, u_season.y, u_season.z);
		if (v_kind <= 3) base = grass_season(grass_tint(base, v_tint), t, u_season.z);
		if (v_kind == 4 && !twigs) {
			// листопадные: осенью желтеют, перед листопадом буреют
			float bare = leaves_bare(t + (tree - 0.5) * 4.0, u_season.y);
			vec3 autumn = autumn_color(v_uvl.z == u_layer_b.x, fract(tree * 3.7));
			base = mix(leaf_autumn(grass_tint(base, v_tint * 0.5), t + (tree - 0.5) * 4.0, u_season.y, autumn), vec3(0.42, 0.3, 0.16), bare * 0.5);
		}
		if (v_kind == 3 && snow > 0.6) discard; // траву занесло
		if (v_kind == 7 && (snow > 0.2 || t < 5.0 + 3.0 * v_hash)) discard; // цветы — только в тёплое время
		bool top = v_face == 2 && v_kind != 3;
		if (v_kind == 2 && v_uvl.y < 0.19) top = true; // снег свешивается с края, как у травы в Minecraft
		if (top) base = mix(base, SNOW_COLOR, twigs ? snow * 0.6 : snow);
		else if (v_kind == 5 || v_kind == 4) base = mix(base, SNOW_COLOR, snow * (twigs ? 0.15 : 0.35));
	}
	vec3 col = apply_light(base * v_light * cloud_shadow(v_rel));
	// под водой свет гаснет с глубиной: ниже ~200 м почти темно
	float depth = -(u_haze.z + v_rel.y);
	if (depth > 0.0) col *= exp(-depth / 60.0);
	float fog = clamp((length(v_rel.xz) - u_fog.x) / (u_fog.y - u_fog.x), 0.0, 1.0);
	col = mix(col, sky_color(normalize(v_rel)), fog);
	col = apply_haze(col, v_rel);
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

// Небо: солнце настоящего углового размера (с потемнением к краю и ореолом —
// так глаз видит яркое солнце), луны — освещённые солнцем шары с фазами.
// Тёмная часть луны днём прозрачна, но закрывает солнце — затмения выходят сами.
SKY_FS :: `#version 330 core
in vec2 v_ndc;
uniform mat4 u_inv_view_proj;
uniform float u_sun_size;     // угловой радиус солнца, рад
uniform vec4 u_sun_color;     // цвет диска (rgb), не закрытая лунами доля (a)
uniform float u_px;           // угловой размер пикселя, рад
uniform vec4 u_moon[3];       // направление (xyz) и угловой радиус (w; 0 — луны нет)
uniform vec4 u_moon_light[3]; // освещённая часть: цвет и яркость (rgb); пепельный свет (a)
uniform sampler2D u_band;     // свечение неба: полоса галактики, соседние галактики
uniform mat3 u_u2f;           // оси вселенной -> оси кадра
uniform float u_band_k;       // насколько оно видно сейчас (0 — днём, в сумерках, при луне)
out vec4 o_color;
` + SKY_GLSL + ANOMALY_GLSL + `
float hash12(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
void main() {
	vec4 a = u_inv_view_proj * vec4(v_ndc, 1.0, 1.0);
	vec3 dir = normalize(a.xyz / a.w);
	vec3 col = sky_color(dir);
	bool under = u_fog_override.w > 0.5;

	// солнце
	float sd = length(dir - u_sun_dir); // угол до центра (для малых углов)
	float r = max(u_sun_size, u_px * 0.7);
	float vis = u_sun_color.a;
	vec3 sun_disc = vec3(0.0);
	if (!under && u_sun_dir.y > -u_sun_size - 0.02) {
		float k = smoothstep(r + u_px, r - u_px, sd);
		float x = min(sd / r, 1.0);
		float limb = 1.0 - 0.5 * (1.0 - sqrt(1.0 - x * x));
		sun_disc = u_sun_color.rgb * 1.6 * k * limb;
		col += u_sun_color.rgb * vis * (0.55 * exp(-sd / (r * 2.5 + 0.004)) + 0.12 * exp(-sd / 0.12));
		if (vis < 0.03 && sd > r) col += u_sun_color.rgb * 0.35 * exp(-(sd - r) / (r * 0.9)); // корона
	}

	// свечение неба (у горизонта гаснет в толще воздуха)
	if (u_band_k > 0.0 && !under && dir.y > -0.02) {
		vec3 ud = transpose(u_u2f) * dir;
		vec2 uv = vec2(atan(ud.x, ud.z) / 6.2831853 + 0.5, asin(clamp(ud.y, -1.0, 1.0)) / 3.1415927 + 0.5);
		float air = exp(-0.25 * (1.0 / max(dir.y + 0.03, 0.03) - 1.0));
		col += texture(u_band, uv).rgb * u_band_k * air;
	}

	// луны
	bool covered = false;
	for (int i = 0; i < 3; i++) {
		vec4 m = u_moon[i];
		if (m.w <= 0.0 || under || m.y < -m.w - 0.02) continue;
		float mr = max(m.w, u_px * 0.6);
		vec3 v = dir - m.xyz;
		if (length(v) > mr + u_px) continue;
		vec3 right = normalize(cross(m.xyz, abs(m.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
		vec3 up = cross(right, m.xyz);
		vec2 p = vec2(dot(v, right), dot(v, up)) / mr;
		float q = dot(p, p);
		float edge = smoothstep(1.0 + u_px / mr, 1.0 - u_px / mr, sqrt(q));
		vec3 n = right * p.x + up * p.y - m.xyz * sqrt(max(1.0 - q, 0.0));
		float lit = max(dot(n, u_sun_dir), 0.0);
		vec2 cell = floor((p * 0.5 + 0.5) * 12.0); // пиксельные моря и кратеры
		float tex = 0.8 + 0.3 * hash12(cell) - 0.28 * step(0.7, hash12(cell * 0.37 + 7.0));
		vec3 mc = (u_moon_light[i].rgb * lit + vec3(0.6, 0.7, 0.9) * u_moon_light[i].a) * tex;
		col = mix(col, max(col, mc), edge);
		if (edge > 0.5) covered = true;
	}
	if (!covered) col += sun_disc;
	col = apply_anomaly(col, dir, 8e4);
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
uniform float u_light_k; // свет в клетке персонажа (тень деревьев)
uniform vec2 u_fog;
uniform vec4 u_tint; // rgb + сила (свечение, вспышки)
out vec4 o_color;
` + SKY_GLSL + HAZE_GLSL + ANOMALY_GLSL + `
// два источника света, как у мобов в Minecraft
const vec3 L0 = vec3(0.16169, 0.80845, -0.56592);
const vec3 L1 = vec3(-0.16169, 0.80845, 0.56592);
void main() {
	vec4 c = texture(u_skin, v_uv);
	if (c.a < 0.1) discard;
	vec3 n = normalize(v_normal);
	float diff = min(1.0, 0.4 + 0.6 * (max(dot(n, L0), 0.0) + max(dot(n, L1), 0.0)));
	vec3 col = apply_light(c.rgb * diff * u_light_k);
	col = mix(col, u_tint.rgb, u_tint.a);
	float fog = clamp((length(v_rel.xz) - u_fog.x) / (u_fog.y - u_fog.x), 0.0, 1.0);
	col = mix(col, sky_color(normalize(v_rel)), fog);
	col = apply_haze(col, v_rel);
	col = apply_anomaly(col, v_rel, length(v_rel));
	o_color = vec4(col, 1.0);
}
`

// ---------------------------------------------------------------- дальний рельеф
// Вершины тайла — смещения от его начала в осях планеты; в оси кадра у камеры
// их переводит J⁻¹ (far_terrain.odin). Глубина логарифмическая.
FAR_VS :: `#version 330 core
layout(location = 0) in vec3 a_off;
layout(location = 1) in vec4 a_normal; // оси планеты
layout(location = 2) in vec4 a_color;  // цвет; a = 1 — вода
layout(location = 3) in vec4 a_clim;   // материковость, осадки ×0,01, доли листопадных и хвойных крон
uniform mat4 u_view_proj;
uniform vec3 u_org;       // начало тайла, оси планеты (м)
uniform float u_radius;   // радиус планеты, м
uniform float u_lapse;    // похолодание с высотой, К/м
uniform sampler2D u_clim; // по широте сейчас: температура над океаном и сушей, осадки, ход температуры
uniform mat3 u_jinv;  // оси планеты -> кадр
uniform mat3 u_jt;    // для нормалей (J транспонированная)
uniform vec3 u_rel_o; // начало тайла относительно камеры (кадр)
uniform sampler2D u_mask; // чанки, уже нарисованные блоками
uniform vec3 u_mask_org;  // камера в маске (блоки), размер маски (чанки)
uniform float u_floor;    // 1 — рисуем дно под водой (вершины воды опущены на глубину)
out vec3 v_rel;
out vec3 v_n;
out vec4 v_col;
out vec3 v_season; // температура здесь сейчас, её ход за месяц, осадки за месяц
out vec2 v_crowns; // доли листопадных и хвойных крон
` + LOGDEPTH_GLSL + `
void main() {
	vec3 P = u_org + a_off;
	float r = length(P);
	vec4 z = texture(u_clim, vec2((degrees(asin(clamp(P.y / r, -1.0, 1.0))) + 90.0) / 180.0, 0.5));
	v_season = vec3(mix(z.x, z.y, a_clim.x) - u_lapse * max(r - u_radius, 0.0), z.w, z.z * a_clim.y * 2.55);
	v_crowns = a_clim.zw;
	vec3 rel = u_rel_o + u_jinv * a_off;
	if (u_floor > 0.5 && a_color.a > 0.5) rel.y -= max(a_normal.w * 127.0, 2.0);
	// под блоками (у их края) рельеф опущен: блоки рисуются поверх, а щели на
	// стыке закрывает он, а не небо
	vec2 m = (u_mask_org.xy + rel.xz) / 16.0;
	if (m.x >= 0.0 && m.y >= 0.0 && m.x < u_mask_org.z && m.y < u_mask_org.z && texelFetch(u_mask, ivec2(m), 0).r > 0.25) rel.y -= 6.0;
	v_rel = rel;
	v_n = u_jt * a_normal.xyz;
	v_col = a_color;
	gl_Position = log_depth(u_view_proj * vec4(rel, 1.0));
}
`

FAR_FS :: `#version 330 core
in vec3 v_rel;
in vec3 v_n;
in vec4 v_col;
in vec3 v_season;
in vec2 v_crowns;
uniform float u_season_on; // 1 — климат есть
uniform sampler2D u_mask;   // какие чанки уже нарисованы блоками
uniform vec3 u_mask_org;    // камера в маске (блоки), размер маски (чанки)
uniform vec2 u_side_shade;  // затенение боков вдоль x и z кадра — как у блоков
uniform float u_floor;      // 1 — дно под водой
out vec4 o_color;
` + SKY_GLSL + HAZE_GLSL + CLOUD_GLSL + ANOMALY_GLSL + SEASON_GLSL + `
void main() {
	vec2 m = (u_mask_org.xy + v_rel.xz) / 16.0;
	float under = m.x >= 0.0 && m.y >= 0.0 && m.x < u_mask_org.z && m.y < u_mask_org.z ? texelFetch(u_mask, ivec2(m), 0).r : 0.0;
	if (under > 0.75) discard;
	vec3 n = normalize(v_n);
	float dist = length(v_rel);
	float water = v_col.a;
	// как у блоков: верх 1.0, бока по осям; ровная земля — ровно как верх блока
	vec3 n2 = n * n;
	float shade = n2.y * (n.y > 0.0 ? 1.0 : 0.5) + n2.x * u_side_shade.x + n2.z * u_side_shade.y;
	// вдали склоны к солнцу светлее, от солнца — темнее (на закате горы светятся)
	float k = smoothstep(-0.03, 0.12, u_sun_dir.y) * smoothstep(250.0, 2500.0, dist) * (1.0 - water);
	float lam = (max(dot(n, u_sun_dir), 0.0) + 0.35) / (max(u_sun_dir.y, 0.0) + 0.35);
	shade *= mix(1.0, clamp(lam, 0.55, 1.6), k);
	vec3 base = v_col.rgb;
	if (u_season_on > 0.5 && water < 0.5) {
		// времена года: трава жухнет, листопадные желтеют и голеют, в мороз — снег
		float t = v_season.x;
		float decid = v_crowns.x;
		float conif = v_crowns.y;
		base = mix(base, grass_season(base, t, v_season.z), max(1.0 - decid - conif, 0.0));
		float bare = leaves_bare(t, v_season.y);
		vec3 fall = mix(leaf_autumn(base, t, v_season.y, mix(autumn_color(true, 0.5), autumn_color(false, 0.5), 0.5)), vec3(0.3, 0.26, 0.21), bare * 0.7);
		base = mix(base, fall, decid);
		base = mix(base, SNOW_COLOR, snow_cover(t, v_season.y, v_season.z) * (1.0 - 0.65 * conif - 0.4 * decid * (1.0 - bare)));
	}
	vec3 col = apply_light(base * shade * cloud_shadow(v_rel));
	if (water > 0.5 && (u_floor > 0.5 || under > 0.25 || dot(v_rel, n) > 0.0)) {
		// гладь снизу или под ближней водой: сквозь неё должно быть видно тёмное дно
		col = apply_light(v_col.rgb * 0.45);
	} else if (water > 0.5) {
		// гладь отражает небо, сильнее всего — у горизонта (скользящий взгляд)
		vec3 view = v_rel / max(dist, 1e-3);
		float fres = 0.02 + 0.98 * pow(1.0 - max(-dot(view, n), 0.0), 5.0);
		col = mix(col, sky_color(reflect(view, n)), fres * 0.85 * smoothstep(150.0, 1500.0, dist));
	}
	col = apply_haze(col, v_rel);
	col = apply_anomaly(col, v_rel, dist);
	o_color = vec4(col, 1.0);
}
`

// ---------------------------------------------------------------- облака
// Купол вокруг камеры на шаре радиуса R + высота облаков: (доля пути к краю,
// азимут) -> точка слоя. Кольца идут равными углами от зенита к горизонту.
CLOUD_VS :: `#version 330 core
layout(location = 0) in vec2 a_tp;
uniform mat4 u_view_proj;
uniform mat3 u_jinv; // оси планеты -> кадр
uniform mat3 u_e;    // местные оси камеры (касательная, вверх, касательная) -> оси планеты
uniform vec4 u_geom; // x — облака над камерой (м, < 0 — под ней), y — радиус слоя (м), z — угол до края купола, w — 1: смотрим сверху
out vec3 v_rel;
out vec3 v_v;
out float v_t;
` + LOGDEPTH_GLSL + `
void main() {
	float s = abs(u_geom.x) * tan(a_tp.x * u_geom.z); // путь вдоль слоя
	float psi = s / u_geom.y;
	float sh = sin(0.5 * psi);
	vec3 loc = vec3(u_geom.y * sin(psi) * cos(a_tp.y), u_geom.x - 2.0 * u_geom.y * sh * sh, u_geom.y * sin(psi) * sin(a_tp.y));
	vec3 v = u_e * loc;
	vec3 rel = u_jinv * v;
	v_rel = rel;
	v_v = v;
	v_t = a_tp.x;
	gl_Position = log_depth(u_view_proj * vec4(rel, 1.0));
}
`

// Мягкие кучевые облака снизу: толстые середины темнее, тонкие края светлее,
// против солнца — серебристая кайма, на закате низ подсвечен зарёй; вдали
// растворяются в дымке у горизонта.
CLOUD_FS :: `#version 330 core
in vec3 v_rel;
in vec3 v_v;
in float v_t;
uniform vec3 u_pcs;  // камера в координатах шума
uniform float u_px;  // угловой размер пикселя, рад
uniform vec4 u_geom; // w — 1: смотрим на облака сверху
out vec4 o_color;
` + SKY_GLSL + HAZE_GLSL + CLOUD_GLSL + ANOMALY_GLSL + `
void main() {
	float dist = length(v_rel);
	vec3 view = v_rel / dist;
	// размер пикселя на слое (у горизонта луч скользит — пиксель вытянут); 1800 м — CLOUD_SCALE
	float fp = dist * u_px / max(abs(view.y), 0.02) / 1800.0;
	float d = cloud_density(u_pcs + v_v / 1800.0, fp, 5);
	float a = cloud_alpha(d) * (1.0 - smoothstep(0.92, 1.0, v_t));
	if (a < 0.003) discard;
	float mu = dot(view, u_sun_dir);
	float sun_up = smoothstep(-0.05, 0.1, u_sun_dir.y);
	vec3 col;
	if (u_geom.w > 0.5) {
		// сверху: верх облаков освещён солнцем — плотные середины ярко-белые
		col = vec3(mix(0.84, 1.02, d)) * (0.75 + 0.25 * sun_up);
	} else {
		// низ облака освещён небом (серо-голубой), тонкие края пропускают солнце
		vec3 shadow = vec3(0.64, 0.68, 0.78);
		col = mix(vec3(1.0, 0.99, 0.97), shadow, d * (0.55 + 0.25 * sun_up));
		col += vec3(1.0, 0.97, 0.9) * sun_up * pow(max(mu, 0.0), 6.0) * (1.0 - d) * 1.2;
	}
	col = apply_light(col);
	// заря подсвечивает тонкие края и низ со стороны солнца
	col += u_glow.rgb * u_glow.a * pow(max(mu, 0.0) * 0.5 + 0.5, 3.0) * (1.0 - 0.6 * d) * 0.7;
	col = apply_haze(col, v_rel);
	// за туманом аномалии облаков не видно
	a *= exp(-anomaly_depth(view, dist));
	o_color = vec4(col, a);
}
`

// ---------------------------------------------------------------- звёзды
// Звёзды и планеты — точки на «небесной сфере». Яркость и размер — по
// звёздной величине; у горизонта звёзды тусклее (толща воздуха) и сильнее
// мерцают; слабее предела видимости (сумерки, луна) — не видны.
STAR_VS :: `#version 330 core
layout(location = 0) in vec3 a_dir;    // направление (оси вселенной или инерциальные)
layout(location = 1) in vec4 a_col;    // цвет, звёздная величина
layout(location = 2) in float a_phase; // фаза мерцания; < 0 — планета (не мерцает)
uniform mat4 u_view_proj;
uniform mat3 u_u2f;
uniform float u_mlim;
uniform float u_time;
uniform float u_scale;
uniform vec4 u_moon[3];
out vec3 v_col;
out vec3 v_dir;
void main() {
	vec3 d = normalize(u_u2f * a_dir);
	v_dir = d;
	float air = 1.0 / max(d.y + 0.03, 0.03);
	float m = a_col.a + 0.2 * (air - 1.0);
	float vis = smoothstep(u_mlim + 0.3, u_mlim - 0.7, m) * step(-0.005, d.y);
	for (int i = 0; i < 3; i++) {
		if (u_moon[i].w > 0.0 && length(d - u_moon[i].xyz) < u_moon[i].w) vis = 0.0; // за луной
	}
	float tw = 1.0;
	if (a_phase >= 0.0) {
		float amp = 0.12 + 0.3 * clamp((air - 1.0) / 6.0, 0.0, 1.0);
		tw = 1.0 + amp * sin(u_time * (5.0 + a_phase * 11.0) + a_phase * 40.0) * sin(u_time * (3.1 + a_phase * 7.0));
	}
	v_col = a_col.rgb * (1.3 * pow(10.0, -0.17 * m) * tw * vis);
	gl_PointSize = (m < 0.5 ? 3.5 : m < 2.0 ? 3.0 : m < 4.0 ? 2.5 : 2.0) * u_scale;
	gl_Position = vis > 0.0 ? u_view_proj * vec4(d * 500.0, 1.0) : vec4(2.0, 2.0, 2.0, 1.0);
}
`

STAR_FS :: `#version 330 core
in vec3 v_col;
in vec3 v_dir;
out vec4 o_color;
` + ANOMALY_GLSL + `
void main() {
	float k = 1.0 - smoothstep(0.32, 0.55, length(gl_PointCoord - 0.5));
	o_color = vec4(v_col * k * exp(-anomaly_depth(v_dir, 8e4)), 1.0);
}
`
