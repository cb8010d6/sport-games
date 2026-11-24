shader_type spatial;
render_mode cull_disabled;
// Ski-only coarse fir material. Preserve the original primary snow-edge noise,
// vertex colours, lighting parameters and INSTANCE_ID salt. Secondary needle and
// normal micro-noise are omitted only beyond the protected high-detail region.

uniform vec4 snow_tint : source_color = vec4(1.0);
uniform float needle_light = 1.0;

varying vec3 lpos;

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x), mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y);
	float b = mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x), mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y);
	return mix(a, b, f.z);
}

void vertex() {
	lpos = VERTEX + vec3(float(INSTANCE_ID) * 3.17);
}

void fragment() {
	float n1 = vnoise(lpos * 9.0);
	float snow = COLOR.a;
	snow = smoothstep(0.35, 0.65, snow + (n1 - 0.5) * 0.6);
	// Use the old secondary-noise midpoint (0.7 + 0.5 * 0.55), keeping the
	// original colour and primary variation without a second eight-sine noise.
	vec3 needles = COLOR.rgb * 0.975 * (0.85 + n1 * 0.3) * needle_light;
	vec3 white = snow_tint.rgb * (0.9 + n1 * 0.1);
	ALBEDO = mix(needles, white, snow);
	ROUGHNESS = mix(0.85, 0.7, snow);
	SPECULAR = mix(0.3, 0.5, snow);
	BACKLIGHT = mix(COLOR.rgb * 0.4, vec3(0.15), snow);
}
