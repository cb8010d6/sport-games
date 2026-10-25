// Same rest-point formula and analytic tangents as RSWater. Distances are metres.
// Q_i = clamp(Q, 0, 1) / N, so horizontal amplitude is Q_i * A_i.
// The caller supplies game-clock seconds to wave_time and CPU queries, freezing both on pause.
#define RS_WATER_MAX_WAVES 4
const float RS_WATER_GRAVITY = 9.81;
const float RS_WATER_TAU = 6.283185307179586;

uniform vec4 waves[RS_WATER_MAX_WAVES]; // dir_x, dir_z, wavelength, amplitude
uniform int wave_count = 0;
uniform float steepness = 0.5;
uniform float wave_time = 0.0;

void rs_water_displace(vec2 p0, out vec3 offset, out vec3 normal) {
	offset = vec3(0.0);
	vec3 tangent_x = vec3(1.0, 0.0, 0.0);
	vec3 tangent_z = vec3(0.0, 0.0, 1.0);
	int count = clamp(wave_count, 0, RS_WATER_MAX_WAVES);
	float q = clamp(steepness, 0.0, 1.0) / max(float(count), 1.0);
	for (int i = 0; i < RS_WATER_MAX_WAVES; i++) {
		if (i >= count) {
			break;
		}
		vec2 d = waves[i].xy;
		float wavelength = waves[i].z;
		float amplitude = waves[i].w;
		if (wavelength <= 0.0 || amplitude == 0.0) {
			continue;
		}
		float k = RS_WATER_TAU / wavelength;
		float theta = k * dot(d, p0) - sqrt(RS_WATER_GRAVITY * k) * wave_time;
		float horizontal = q * amplitude * cos(theta);
		offset += vec3(d.x * horizontal, amplitude * sin(theta), d.y * horizontal);
		vec3 derivative = vec3(-q * d.x * sin(theta), cos(theta), -q * d.y * sin(theta)) * (k * amplitude);
		tangent_x += derivative * d.x;
		tangent_z += derivative * d.y;
	}
	normal = normalize(cross(tangent_z, tangent_x));
}
