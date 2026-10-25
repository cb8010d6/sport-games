shader_type spatial;
render_mode world_vertex_coords, depth_draw_always, cull_disabled;
// The mesh follows a camera, but the wave rest points and all surface patterns stay in world XZ.
#include "res://shaders/water_waves.gdshaderinc"

uniform vec4 deep_color : source_color = vec4(0.015, 0.06, 0.085, 1.0);
uniform vec4 shallow_color : source_color = vec4(0.1, 0.33, 0.32, 1.0);
uniform float clear_depth = 3.5;
uniform float foam_amount = 0.5;
uniform sampler2D foam_tex : source_color, repeat_enable, filter_linear_mipmap;
uniform bool use_foam_texture = false;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform bool detail_normals = true;

varying vec3 world_position;
varying vec3 wave_normal;
varying float crest_height;

float rs_water_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float rs_water_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(rs_water_hash(cell), rs_water_hash(cell + vec2(1.0, 0.0)), f.x),
		mix(rs_water_hash(cell + vec2(0.0, 1.0)), rs_water_hash(cell + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	vec3 offset;
	vec3 normal;
	rs_water_displace(VERTEX.xz, offset, normal);
	// CPU height_at is absolute wave height above the same world-zero rest plane.
	VERTEX = vec3(VERTEX.x, 0.0, VERTEX.z) + offset;
	NORMAL = normal;
	world_position = VERTEX;
	wave_normal = normal;
	crest_height = offset.y;
}

void fragment() {
	vec2 p = world_position.xz;
	vec3 normal = normalize(wave_normal);
	float kept_detail = 1.0;
	if (detail_normals) {
		float footprint = length(fwidth(p));
		kept_detail = clamp(1.6 - footprint * 1.7 * 1.1, 0.0, 1.0);
		vec2 q = p * 1.7 + vec2(wave_time * 0.35, -wave_time * 0.2);
		vec2 chop = vec2(rs_water_noise(q) - rs_water_noise(q + vec2(0.3, 0.0)),
			rs_water_noise(q) - rs_water_noise(q + vec2(0.0, 0.3)));
		normal = normalize(normal + vec3(chop.x, 0.0, chop.y) * kept_detail * 0.15);
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(normal, 0.0)).xyz);

	float raw = texture(depth_tex, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw);
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	ndc.z = raw * 2.0 - 1.0;
#endif
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	scene_view.xyz /= scene_view.w;
	float depth = max(VERTEX.z - scene_view.z, 0.0);
	float opaque = 1.0 - exp(-depth / max(clear_depth, 0.001));
	vec3 color = mix(shallow_color.rgb, deep_color.rgb, opaque);

	float pattern;
	if (use_foam_texture) {
		vec4 texel = texture(foam_tex, p * 0.2 + vec2(wave_time * 0.04, -wave_time * 0.02));
		pattern = texel.r * texel.a;
	} else {
		pattern = rs_water_noise(p * 1.3 + wave_time * 0.25) * 0.7
			+ rs_water_noise(p * 4.1 - wave_time * 0.4) * 0.3;
	}
	float shore = 1.0 - smoothstep(0.0, 1.4 + 0.5 * sin(wave_time * 0.9 + p.x * 0.05), depth);
	float crest = smoothstep(0.12, 0.5, crest_height) * smoothstep(0.1, 0.6, steepness);
	float foam = clamp((shore + crest) * smoothstep(0.35, 0.75, pattern + shore * 0.3) * foam_amount, 0.0, 1.0);
	ALBEDO = mix(color, vec3(0.88, 0.9, 0.9), foam);
	ALPHA = clamp(mix(0.08, 1.0, opaque) + foam, 0.0, 1.0);
	// Sub-pixel detail returns as roughness rather than aliased far-water sparkles.
	ROUGHNESS = clamp(0.03 + (1.0 - kept_detail) * 0.11 + foam * 0.6, 0.0, 1.0);
	SPECULAR = 0.5;
	METALLIC = 0.0;
}
