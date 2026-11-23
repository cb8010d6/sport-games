shader_type spatial;
#if defined(RT)
#include "res://shaders/rt_pixel_footprint.gdshaderinc"
#endif
// Mountain snow for RSSkiCourse. Vertex colour R = groomed piste (1) .. untouched powder (0).
// Groomed: Poly Haven snow_02 with corduroy ridges along the fall line and the groomer's lanes;
// powder: snow_01 at a larger scale; rock (dark_rock_02) shows through where it is steep.
// Glints: a sparse field of tiny view-dependent sparkles. UVs are world metres.

uniform sampler2D groom_alb : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D groom_nrm : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D groom_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D powder_alb : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D powder_nrm : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_alb : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_nrm : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 snow_tint : source_color = vec4(1.0);
uniform float groom_size = 3.0;
uniform float powder_size = 5.0;
uniform float rock_size = 6.0;
uniform float rock_amount = 1.0;
uniform float sparkle = 1.0;
uniform float far_fade = 1.0;      // 0 on the near mesh: no rock unless it is really steep

varying vec3 wpos;
varying vec3 wnrm;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 uv = wpos.xz;
	float groom = COLOR.r;
	// Large-scale variation so the tiling never lines up.
	float m = vnoise(uv * 0.03) * 0.6 + vnoise(uv * 0.11 + 5.0) * 0.4;

	vec2 g_uv = uv / groom_size;
	vec2 g_uv2 = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * uv / (groom_size * 1.37) + 0.31;
	float w2 = smoothstep(0.35, 0.65, vnoise(uv * 0.09));
	vec3 ga = mix(texture(groom_alb, g_uv).rgb, texture(groom_alb, g_uv2).rgb, w2);
	vec3 gn = normalize(mix(texture(groom_nrm, g_uv).rgb * 2.0 - 1.0, texture(groom_nrm, g_uv2).rgb * 2.0 - 1.0, w2));
	float gr = mix(texture(groom_orm, g_uv).g, texture(groom_orm, g_uv2).g, w2);

	vec2 p_uv = uv / powder_size;
	vec3 pa = texture(powder_alb, p_uv).rgb;
	vec3 pn = texture(powder_nrm, p_uv).rgb * 2.0 - 1.0;

	// Corduroy: fine ridges along the fall line (faded out where they would alias), and
	// slightly different lanes where the groomer passed.
	float phase = wpos.x / 0.045;
#if defined(RT)
	// The ridges repeat every 4.5 cm along world X. Filter by their projected
	// cycles per pixel, including the widening footprint on oblique terrain.
	float phase_width = rs_rt_pixel_footprint(wpos, wnrm, vec3(1.0, 0.0, 0.0), vec3(0.0, 0.0, 1.0),
		CAMERA_POSITION_WORLD, INV_VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE).x / 0.045;
	float aa = 1.0 - smoothstep(0.25, 0.8, phase_width);
#else
	float aa = 1.0 - smoothstep(0.25, 0.8, fwidth(phase));
#endif
	float ridge = sin(phase * 6.2831) * aa;
	float lane = vnoise(vec2(floor(wpos.x / 4.2), wpos.z * 0.004)) - 0.5;
	gn = normalize(gn + vec3(ridge * 0.35, 0.0, 0.0));
	ga *= 1.0 + lane * 0.06 + ridge * 0.03;

	// The scans have grey veins (old snow, shadows baked in): keep only a hint of them, the
	// normal maps carry the texture.
	ga = mix(vec3(0.88), ga, 0.3);
	pa = mix(vec3(0.9), pa, 0.45);
	vec3 alb = mix(pa, ga, groom);
	vec3 nrm = normalize(mix(pn, gn, groom));
	float rough = mix(0.75, gr * 0.9, groom);

	// Rock on steep ground.
	float steep = 1.0 - wnrm.y;
	float rock_w = smoothstep(mix(0.42, 0.3, far_fade), mix(0.55, 0.46, far_fade), steep + (m - 0.5) * 0.25) * rock_amount * (1.0 - groom);
	vec2 r_uv = vec2(wpos.x + wpos.z * 0.5, -wpos.y) / rock_size;
	vec3 ra = texture(rock_alb, r_uv).rgb * 0.9;
	vec3 rn = texture(rock_nrm, r_uv).rgb * 2.0 - 1.0;
	float rr = texture(rock_orm, r_uv).g;

	alb = alb * snow_tint.rgb * (1.0 + (m - 0.5) * 0.08);
	alb = mix(alb, ra, rock_w);
	nrm = normalize(mix(nrm, rn, rock_w));
	rough = mix(rough, rr, rock_w);

	// Glints: rare cells that light up for a narrow range of view directions.
	vec2 cell = floor(wpos.xz * 55.0);
	float h = hash(cell);
	float view_key = dot(VIEW, vec3(0.57, 0.31, 0.76)) * 9.0;
	float glint = step(0.985, h) * smoothstep(0.85, 1.0, sin((view_key + h * 40.0) * 3.1416) * 0.5 + 0.5);
	float near = 1.0 - smoothstep(6.0, 28.0, length(VERTEX));
	EMISSION = vec3(glint * sparkle * near * (1.0 - rock_w) * 1.6);

	ALBEDO = alb;
	ROUGHNESS = rough;
	SPECULAR = 0.45;
	NORMAL_MAP = nrm * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = mix(0.8, 1.0, rock_w);
	AO_LIGHT_AFFECT = 0.3;
	BACKLIGHT = vec3(0.12) * (1.0 - rock_w);    // a little light through the snow
}
