// Finish-line fans (MultiMesh): per-instance shirt colour, custom data = (phase, tempo).
// Everyone hops and waves on their own beat; the second surface is heads and arms (skin).
shader_type spatial;
render_mode diffuse_toon, specular_toon;

uniform bool skin = false;
uniform float cheer : hint_range(0.0, 1.0) = 0.6;

varying vec3 tint;

float hash(float n) {
	return fract(sin(n * 91.3458) * 47453.5453);
}

void vertex() {
	float phase = INSTANCE_CUSTOM.x * 6.2831;
	float tempo = INSTANCE_CUSTOM.y;
	float hop = max(sin(TIME * 6.0 * tempo + phase), 0.0);
	// At the legacy default (0.6), this is exactly 1: old hop/wave amplitudes remain.
	float motion = mix(0.08, 1.0, clamp(cheer, 0.0, 1.0) / 0.6);
	if (VERTEX.y > 1.15 && abs(VERTEX.x) > 0.18) {
		VERTEX.x += sin(TIME * 9.0 * tempo + phase) * 0.06 * motion * sign(VERTEX.x);
		VERTEX.y += hop * 0.08 * motion;
	}
	VERTEX.y += hop * 0.16 * motion;
	float h = hash(INSTANCE_CUSTOM.x * 13.0);
	tint = (skin || UV2.x > 0.5) ? mix(vec3(0.95, 0.76, 0.62), vec3(0.42, 0.27, 0.18), h * h) : COLOR.rgb;
}

void fragment() {
	ALBEDO = tint;
	ROUGHNESS = 0.8;
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION = tint * fres * 0.25;
}
