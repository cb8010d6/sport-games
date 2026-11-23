shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled;
// CPU transforms already follow the wave normal and contain the widening patch scale.
varying vec4 wake_data;

void vertex() {
	wake_data = INSTANCE_CUSTOM;
	// Local Z is the wave normal; only the rendered foam is biased to avoid z-fighting.
	VERTEX.z += 0.01;
}

void fragment() {
	vec2 edge = abs(UV - vec2(0.5));
	float sides = 1.0 - smoothstep(0.25, 0.5, edge.x);
	float ends = 1.0 - smoothstep(0.3, 0.5, edge.y);
	vec2 cell = floor(vec2(UV.x * max(wake_data.r, 0.01), UV.y) * 24.0);
	float grain = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
	ALBEDO = vec3(0.86, 0.92, 0.93);
	ALPHA = clamp(wake_data.g * sides * ends * mix(0.6, 1.0, grain), 0.0, 1.0);
	ROUGHNESS = 0.65;
	SPECULAR = 0.15;
	METALLIC = 0.0;
}
