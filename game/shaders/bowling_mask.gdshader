shader_type spatial;
// Original masking-unit artwork. UV is metres on the vertical panel, never an external image.
// Four player colours share one shader; emissive bands complement the actual pin-deck lights.

uniform vec4 player_color : source_color = vec4(0.2, 0.6, 1.0, 1.0);
uniform vec2 panel_size = vec2(2.5, 1.4);
uniform float pattern_offset = 0.0;

// Box-filter a finite band; subpixel lines lose energy instead of flickering at full brightness.
float filtered_band(float value, float lower, float upper, float footprint) {
	return clamp((value - lower) / footprint + 0.5, 0.0, 1.0)
		- clamp((value - upper) / footprint + 0.5, 0.0, 1.0);
}

void fragment() {
	vec2 p = UV / panel_size;
	float pattern = p.x * 3.3 + p.y * 0.8 + pattern_offset;
	float diagonal = fract(pattern);
	// Take derivatives before fract so the periodic seam cannot inflate the filter footprint.
	float footprint = max(fwidth(pattern), 0.0001);
	float band = filtered_band(diagonal, 0.45, 0.71, footprint);
	float fine = filtered_band(diagonal, 0.77, 0.79, footprint);
	float radius = length((p - vec2(0.78, 0.48)) * vec2(1.0, 0.56));
	float arc = filtered_band(radius, 0.227, 0.253, max(fwidth(radius), 0.0001));
	vec3 ink = vec3(0.016, 0.024, 0.045);
	ALBEDO = mix(ink, player_color.rgb, 0.18 + band * 0.52);
	EMISSION = player_color.rgb * (fine * 0.35 + arc * 0.22 + band * 0.06);
	ROUGHNESS = 0.38;
	METALLIC = 0.15;
}
