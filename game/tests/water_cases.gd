extends RefCounted
## CPU mathematics and shader-interface checks. These do not execute a GPU shader or inspect visuals.

const INCLUDE := "res://shaders/water_waves.gdshaderinc"
const TEST_SHADER := """shader_type spatial;
#include "res://shaders/water_waves.gdshaderinc"
uniform vec4 deep_color : source_color;
uniform vec4 shallow_color : source_color;
uniform float clear_depth;
uniform float foam_amount;
void vertex() {
	vec3 offset;
	vec3 normal;
	rs_water_displace(VERTEX.xz, offset, normal);
	VERTEX += offset;
	NORMAL = normal;
}
"""


static func run(check: Callable) -> void:
	_single_wave(check)
	_flat_water(check)
	for p in [RSWater.preset_bay(), RSWater.preset_lake()]:
		_preset(check, p)
	_shader_contract(check)


static func _single_wave(check: Callable) -> void:
	var p := RSWater.Preset.new()
	p.waves = PackedFloat32Array([0.6, 0.8, 12.0, 0.35])
	p.steepness = 0.45
	check.call(RSWater.displace(p, 0.0, 0.0, 0.0).distance_to(Vector3(0.0945, 0.0, 0.126)) < 0.000001, "water: hand-calculated crestward horizontal offset")
	check.call(RSWater.displace(p, 1.8, 2.4, 0.0).distance_to(Vector3(0.0, 0.35, 0.0)) < 0.000001, "water: quarter-wavelength crest")
	var k := TAU / 12.0
	var quarter_period := PI * 0.5 / sqrt(RSWater.GRAVITY * k)
	check.call(RSWater.displace(p, 0.0, 0.0, quarter_period).distance_to(Vector3(0.0, -0.35, 0.0)) < 0.000001, "water: negative time phase uses deep-water dispersion")
	var theta := k * (0.6 * -2.25 + 0.8 * 4.5) - sqrt(9.81 * k) * 1.7
	var expected := Vector3(0.45 * 0.35 * 0.6 * cos(theta), 0.35 * sin(theta), 0.45 * 0.35 * 0.8 * cos(theta))
	check.call(RSWater.displace(p, -2.25, 4.5, 1.7).distance_to(expected) < 0.000001, "water: single-wave formula at a nonzero rest point and time")
	# Two identical waves retain vertical amplitude and split the shared Q evenly.
	p.waves.append_array(p.waves.duplicate())
	var doubled := RSWater.displace(p, -2.25, 4.5, 1.7)
	check.call(doubled.distance_to(Vector3(expected.x, 2.0 * expected.y, expected.z)) < 0.000001, "water: Q_i is Q / wave count")
	# A steep, short wave exposes the horizontal derivative in the surface normal.
	p.waves = PackedFloat32Array([1.0, 0.0, 4.0, 0.2])
	p.steepness = 0.6
	var rest_x := 0.5
	var offset := RSWater.displace(p, rest_x, 0.0, 0.0)
	var slope := (0.2 * PI * 0.5 * cos(PI * 0.25)) / (1.0 - 0.6 * 0.2 * PI * 0.5 * sin(PI * 0.25))
	var normal := Vector3(-slope, 1.0, 0.0).normalized()
	check.call(RSWater.normal_at(p, rest_x + offset.x, offset.z, 0.0).distance_to(normal) < 0.001, "water: normal includes horizontal Gerstner derivatives")


static func _flat_water(check: Callable) -> void:
	var empty := RSWater.Preset.new()
	check.call(empty.wave_count() == 0 and RSWater.displace(empty, 3.0, -7.0, 5.0) == Vector3.ZERO, "water: no waves has no displacement")
	check.call(RSWater.height_at(empty, 3.0, -7.0, 5.0) == 0.0 and RSWater.normal_at(empty, 3.0, -7.0, 5.0) == Vector3.UP, "water: no waves has zero height and up normal")
	_material(check, empty)
	var p := RSWater.preset_bay()
	for i in p.wave_count():
		p.waves[i * 4 + 3] = 0.0
	check.call(RSWater.displace(p, 12.0, -8.0, 31.0) == Vector3.ZERO and RSWater.height_at(p, 12.0, -8.0, 31.0) == 0.0, "water: zero amplitudes remain still")
	check.call(RSWater.normal_at(p, 12.0, -8.0, 31.0) == Vector3.UP, "water: zero amplitudes have an up normal")


static func _preset(check: Callable, p: RSWater.Preset) -> void:
	var count := p.wave_count()
	check.call(count >= 3 and count <= RSWater.MAX_WAVES, "water: presets have three or four waves")
	for i in count:
		var start := i * 4
		var d := Vector2(p.waves[start], p.waves[start + 1])
		check.call(absf(d.length() - 1.0) < 0.000001 and p.waves[start + 2] > 0.0, "water: preset directions are unit vectors and wavelengths positive")
	var repeated := RSWater.height_at(p, -3.25, 7.75, 12.5)
	check.call(repeated == RSWater.height_at(p, -3.25, 7.75, 12.5), "water: same game-clock time gives the same height")
	# Exercise the promised inversion bound at the maximum supported test steepness.
	p.steepness = 0.6
	var max_error := 0.0
	var max_normal_error := 0.0
	var max_step := 0.0
	for t in [0.0, 1.25, 12.5]:
		for i in 100:
			var rest := Vector2((i % 10 - 4.5) * 2.3, (floori(i / 10.0) - 4.5) * 2.3)
			var offset := RSWater.displace(p, rest.x, rest.y, t)
			var world := rest + Vector2(offset.x, offset.z)
			var height := RSWater.height_at(p, world.x, world.y, t)
			max_error = maxf(max_error, absf(height - offset.y))
			var normal := RSWater.normal_at(p, world.x, world.y, t)
			check.call(absf(normal.length() - 1.0) < 0.000001 and normal.y > 0.0, "water: surface normal is unit length and faces up")
			var e := 0.01
			var slope_x := (RSWater.height_at(p, world.x + e, world.y, t) - RSWater.height_at(p, world.x - e, world.y, t)) / (2.0 * e)
			var slope_z := (RSWater.height_at(p, world.x, world.y + e, t) - RSWater.height_at(p, world.x, world.y - e, t)) / (2.0 * e)
			max_normal_error = maxf(max_normal_error, normal.distance_to(Vector3(-slope_x, 1.0, -slope_z).normalized()))
			max_step = maxf(max_step, absf(RSWater.height_at(p, world.x, world.y, t + 1.0 / 120.0) - height))
	check.call(max_error < 0.02, "water: 100 displaced rest points invert within 2 cm at three times: %.8f m" % max_error)
	check.call(max_normal_error < 0.001, "water: analytic normals match independent world-height finite differences: %.8f" % max_normal_error)
	check.call(max_step < 0.05, "water: a 1/120 s game-clock step changes height by less than 5 cm: %.8f m" % max_step)
	_material(check, p)


static func _shader_contract(check: Callable) -> void:
	var code := FileAccess.get_file_as_string(INCLUDE)
	var declaration := RegEx.new()
	declaration.compile("#define\\s+RS_WATER_MAX_WAVES\\s+(\\d+)")
	var found := declaration.search(code)
	check.call(found != null and int(found.get_string(1)) == RSWater.MAX_WAVES, "water: shader and CPU maximum wave counts agree")
	check.call(code.contains("uniform float wave_time = 0.0;"), "water: shader takes the caller's game-clock time")
	declaration.compile("\\bTIME\\b")
	check.call(declaration.search(code) == null, "water: shader never uses the independent built-in clock")


static func _material(check: Callable, p: RSWater.Preset) -> void:
	var shader := Shader.new()
	shader.code = TEST_SHADER
	var names := PackedStringArray()
	for uniform: Dictionary in shader.get_shader_uniform_list():
		names.append(uniform["name"])
	for name in ["waves", "wave_count", "steepness", "wave_time", "deep_color", "shallow_color", "clear_depth", "foam_amount"]:
		check.call(names.has(name), "water: minimal include shader exposes uniform " + name)
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("wave_time", 17.25)
	RSWater.apply_to(p, mat)
	var packed: PackedVector4Array = mat.get_shader_parameter("waves")
	check.call(packed.size() == RSWater.MAX_WAVES, "water: material wave array has the fixed shader length")
	for i in RSWater.MAX_WAVES:
		var expected := Vector4.ZERO
		if i < p.wave_count():
			var start := i * 4
			expected = Vector4(p.waves[start], p.waves[start + 1], p.waves[start + 2], p.waves[start + 3])
		check.call(packed[i] == expected, "water: material packs every wave and zero-pads unused entries")
	check.call(mat.get_shader_parameter("wave_count") == p.wave_count() and mat.get_shader_parameter("steepness") == p.steepness, "water: material wave count and steepness match the preset")
	check.call(mat.get_shader_parameter("deep_color") == p.deep_color and mat.get_shader_parameter("shallow_color") == p.shallow_color, "water: material colors match the preset")
	check.call(mat.get_shader_parameter("clear_depth") == p.clear_depth and mat.get_shader_parameter("foam_amount") == p.foam_amount, "water: material depth and foam match the preset")
	check.call(mat.get_shader_parameter("wave_time") == 17.25, "water: applying a preset preserves the caller's game clock")
