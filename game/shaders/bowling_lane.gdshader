shader_type spatial;
// Bowling-only varnished plywood: UV is metres from the approach toward the pit.
// Visual oil distribution only; friction and the original ball physics stay unchanged.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float board_width = 0.026923; // 39 boards across the original 1.05 m lane.
uniform float approach_length = 4.5;

float hash(float value) {
	return fract(sin(value * 127.1) * 43758.5453);
}

void fragment() {
	float board = floor(UV.x / board_width);
	float offset = hash(board);
	vec2 scan_uv = vec2(UV.x * 1.8 + offset, UV.y * 0.26 + offset * 3.0);
	vec3 wood = texture(albedo_tex, scan_uv).rgb;
	vec3 orm = texture(orm_tex, scan_uv).rgb;
	float edge_distance = min(fract(UV.x / board_width), 1.0 - fract(UV.x / board_width)) * board_width;
	float seam = 1.0 - smoothstep(0.00015, 0.0006, edge_distance);
	float end_distance = min(fract((UV.y + offset * 3.0) / 2.7), 1.0 - fract((UV.y + offset * 3.0) / 2.7)) * 2.7;
	float end_seam = 1.0 - smoothstep(0.0003, 0.0013, end_distance);
	float oil = smoothstep(approach_length - 0.2, approach_length + 0.8, UV.y)
		* (1.0 - smoothstep(approach_length + 10.0, approach_length + 15.5, UV.y));
	ALBEDO = wood * vec3(1.08, 0.88, 0.58) * mix(0.94, 1.06, offset) * (1.0 - max(seam, end_seam) * 0.24);
	AO = orm.r;
	ROUGHNESS = clamp(mix(0.32, 0.13, oil) + (orm.g - 0.5) * 0.06, 0.1, 0.4);
	METALLIC = 0.0;
	SPECULAR = 0.55;
	CLEARCOAT = 0.8;
	CLEARCOAT_ROUGHNESS = 0.12;
	NORMAL_MAP = texture(normal_tex, scan_uv).rgb;
	NORMAL_MAP_DEPTH = 0.12;
}
