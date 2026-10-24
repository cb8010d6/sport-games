shader_type spatial;
// Original masking-unit artwork. UV is metres on the vertical panel, never an external image.
// Four player colours share one shader; emissive bands complement the actual pin-deck lights.

uniform vec4 player_color : source_color = vec4(0.2, 0.6, 1.0, 1.0);
uniform vec2 panel_size = vec2(2.5, 1.4);
uniform float pattern_offset = 0.0;

void fragment() {
	vec2 p = UV / panel_size;
	float diagonal = fract(p.x * 3.3 + p.y * 0.8 + pattern_offset);
	float band = smoothstep(0.44, 0.46, diagonal) * (1.0 - smoothstep(0.7, 0.72, diagonal));
	float fine = 1.0 - smoothstep(0.007, 0.014, abs(diagonal - 0.78));
	float radius = length((p - vec2(0.78, 0.48)) * vec2(1.0, 0.56));
	float arc = 1.0 - smoothstep(0.008, 0.018, abs(radius - 0.24));
	vec3 ink = vec3(0.016, 0.024, 0.045);
	ALBEDO = mix(ink, player_color.rgb, 0.18 + band * 0.52);
	EMISSION = player_color.rgb * (fine * 1.8 + arc * 0.9 + band * 0.16);
	ROUGHNESS = 0.38;
	METALLIC = 0.15;
}
