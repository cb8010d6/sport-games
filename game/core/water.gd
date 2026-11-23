class_name RSWater
extends RefCounted
## Shared Gerstner waves in metres, with the caller's game-clock seconds on CPU and GPU.
## Directions must be unit vectors and wavelengths positive. Each complete tuple is one wave.
## Q_i = clamp(Q, 0, 1) / N: horizontal amplitude is Q_i * A_i, including zero-amplitude waves.
## Pass the same t to queries and the material's wave_time; pausing that clock freezes both.

const MAX_WAVES := 4
const GRAVITY := 9.81


class Preset:
	var waves := PackedFloat32Array() # dir_x, dir_z, wavelength, amplitude; at most MAX_WAVES.
	var steepness := 0.5
	var deep_color := Color(0.015, 0.06, 0.085)
	var shallow_color := Color(0.1, 0.33, 0.32)
	var clear_depth := 3.5
	var foam_amount := 0.5

	func wave_count() -> int:
		return mini(MAX_WAVES, floori(waves.size() / 4.0))


static func preset_bay() -> Preset:
	var p := Preset.new()
	p.waves = PackedFloat32Array([
		0.8, 0.6, 32.0, 0.45,
		0.6, -0.8, 16.0, 0.22,
		-1.0, 0.0, 7.0, 0.09,
		0.0, -1.0, 3.0, 0.035,
	])
	return p


static func preset_lake() -> Preset:
	var p := Preset.new()
	p.waves = PackedFloat32Array([
		0.6, 0.8, 8.0, 0.12,
		-0.8, 0.6, 3.5, 0.06,
		1.0, 0.0, 1.4, 0.025,
	])
	p.steepness = 0.35
	p.deep_color = Color(0.025, 0.08, 0.06)
	p.shallow_color = Color(0.14, 0.28, 0.14)
	p.clear_depth = 2.5
	p.foam_amount = 0.2
	return p


## Offset of a rest point p0, not the surface height at a displaced world x/z.
static func displace(p: Preset, x0: float, z0: float, t: float) -> Vector3:
	var offset := Vector3.ZERO
	var count := p.wave_count()
	var q := clampf(p.steepness, 0.0, 1.0) / maxi(count, 1)
	for i in count:
		var start := i * 4
		var d := Vector2(p.waves[start], p.waves[start + 1])
		var wavelength := p.waves[start + 2]
		var amplitude := p.waves[start + 3]
		if wavelength <= 0.0 or amplitude == 0.0:
			continue
		var k := TAU / wavelength
		var theta := k * d.dot(Vector2(x0, z0)) - sqrt(GRAVITY * k) * t
		var horizontal := q * amplitude * cos(theta)
		offset += Vector3(d.x * horizontal, amplitude * sin(theta), d.y * horizontal)
	return offset


## Three fixed-point steps invert the horizontal displacement, without allocating arrays.
static func _rest_at(p: Preset, x: float, z: float, t: float) -> Vector2:
	var rest := Vector2(x, z)
	for _step in 3:
		var offset := displace(p, rest.x, rest.y, t)
		rest = Vector2(x - offset.x, z - offset.z)
	return rest


## World-space surface height; the bay/lake presets stay within 2 cm for Q <= 0.6.
static func height_at(p: Preset, x: float, z: float, t: float) -> float:
	var rest := _rest_at(p, x, z, t)
	return displace(p, rest.x, rest.y, t).y


## Analytic tangents of the full displaced surface, evaluated at the same inverse rest point.
static func normal_at(p: Preset, x: float, z: float, t: float) -> Vector3:
	var rest := _rest_at(p, x, z, t)
	var tangent_x := Vector3.RIGHT
	var tangent_z := Vector3.BACK
	var count := p.wave_count()
	var q := clampf(p.steepness, 0.0, 1.0) / maxi(count, 1)
	for i in count:
		var start := i * 4
		var d := Vector2(p.waves[start], p.waves[start + 1])
		var wavelength := p.waves[start + 2]
		var amplitude := p.waves[start + 3]
		if wavelength <= 0.0 or amplitude == 0.0:
			continue
		var k := TAU / wavelength
		var theta := k * d.dot(rest) - sqrt(GRAVITY * k) * t
		var derivative := Vector3(-q * d.x * sin(theta), cos(theta), -q * d.y * sin(theta)) * (k * amplitude)
		tangent_x += derivative * d.x
		tangent_z += derivative * d.y
	return tangent_z.cross(tangent_x).normalized()


## The surface shader declares the color/depth/foam uniforms; the include owns wave uniforms.
## wave_time belongs to the caller's clock and is deliberately preserved when applying presets.
static func apply_to(p: Preset, mat: ShaderMaterial) -> void:
	var packed := PackedVector4Array()
	packed.resize(MAX_WAVES)
	for i in p.wave_count():
		var start := i * 4
		packed[i] = Vector4(p.waves[start], p.waves[start + 1], p.waves[start + 2], p.waves[start + 3])
	mat.set_shader_parameter("waves", packed)
	mat.set_shader_parameter("wave_count", p.wave_count())
	mat.set_shader_parameter("steepness", p.steepness)
	mat.set_shader_parameter("deep_color", p.deep_color)
	mat.set_shader_parameter("shallow_color", p.shallow_color)
	mat.set_shader_parameter("clear_depth", p.clear_depth)
	mat.set_shader_parameter("foam_amount", p.foam_amount)
