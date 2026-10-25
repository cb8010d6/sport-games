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
	_surface(check)
	_wake(check)


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


static func _surface(check: Callable) -> void:
	var old_quality := RSSettings.quality
	var old_views := RSSettings.views
	RSSettings.quality = 3
	RSSettings.views = 1
	var surface := RSWaterSurface.new(RSWater.preset_bay(), Vector2(200, 200), Vector3(8, 12, -16))
	check.call(surface.position == Vector3(8, 0, -16), "water surface: centre positions XZ without introducing a different water level")
	var mat := surface.material_override as ShaderMaterial
	var original_mesh := surface.mesh
	check.call(original_mesh is ArrayMesh and original_mesh.get_surface_count() == 1, "water surface: construction creates an indexed mesh")
	var arrays := original_mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	check.call(vertices[0] == Vector3(-100, 0, -100) and vertices[vertices.size() - 1] == Vector3(100, 0, 100) and indices.size() > 0, "water surface: mesh covers the requested extent")
	var smallest := INF
	var largest := 0.0
	for i in vertices.size() - 1:
		if vertices[i + 1].z != vertices[i].z:
			break
		var gap := vertices[i + 1].x - vertices[i].x
		smallest = minf(smallest, gap)
		largest = maxf(largest, gap)
	check.call(smallest == 0.25 and largest == 2.0, "water surface: high quality has dense centre and coarse outer grid spacing")
	surface.update(1.5)
	check.call(mat.get_shader_parameter("wave_time") == 1.5 and surface.mesh == original_mesh, "water surface: update writes only the shared game clock")
	var bay_waves: PackedVector4Array = mat.get_shader_parameter("waves")
	var lake := RSWater.preset_lake()
	surface.set_preset(lake)
	check.call(mat.get_shader_parameter("waves") != bay_waves and surface.mesh == original_mesh and mat.get_shader_parameter("wave_time") == 1.5, "water surface: preset change updates waves without rebuilding or resetting time")
	check.call(surface.height_at(4.25, -7.5) == RSWater.height_at(lake, 4.25, -7.5, 1.5), "water surface: convenience height query uses world coordinates and current time")
	surface.position = Vector3(24, 0, -32)
	check.call(surface.height_at(4.25, -7.5) == RSWater.height_at(lake, 4.25, -7.5, 1.5), "water surface: moving the grid does not move the CPU wave phase")
	if not ResourceLoader.exists(RSWaterSurface.FOAM_TEXTURE):
		check.call(mat.get_shader_parameter("use_foam_texture") == false, "water surface: missing optional foam texture uses procedural fallback")
	var previous_count := 2147483647
	var counts := PackedInt32Array()
	counts.resize(4)
	for quality in [3, 2, 1, 0]:
		RSSettings.quality = quality
		surface.apply_quality()
		var count := (surface.mesh as ArrayMesh).surface_get_array_len(0)
		counts[quality] = count
		check.call(count <= previous_count, "water surface: lowering quality never increases vertex count")
		previous_count = count
		var same_mesh := surface.mesh
		surface.apply_quality()
		check.call(surface.mesh == same_mesh, "water surface: an unchanged quality tier reuses the mesh")
	check.call(counts[3] == counts[2] and counts[2] > counts[1] and counts[1] > counts[0], "water surface: ultra and high share density, with distinct medium and low tiers")
	RSSettings.views = RSSettings.SPLIT_TIER_VIEWS
	for quality in [1, 2, 3]:
		RSSettings.quality = quality
		surface.apply_quality()
		check.call((surface.mesh as ArrayMesh).surface_get_array_len(0) < counts[quality], "water surface: split tier lowers medium, high and ultra mesh density")
	RSSettings.quality = 0
	surface.apply_quality()
	check.call((surface.mesh as ArrayMesh).surface_get_array_len(0) == counts[0] and mat.get_shader_parameter("detail_normals") == false, "water surface: low quality is the density floor and disables fine normals")
	RSSettings.quality = old_quality
	RSSettings.views = old_views
	surface.free()


static func _wake(check: Callable) -> void:
	var old_quality := RSSettings.quality
	var old_views := RSSettings.views
	RSSettings.quality = 0
	RSSettings.views = 1
	var surface := RSWaterSurface.new(RSWater.preset_bay(), Vector2(20, 20))
	for quality in 4:
		RSSettings.quality = quality
		for views in [1, 4]:
			RSSettings.views = views
			var budget := RSWaterWake.new(surface)
			var expected := int(RSWaterWake.CAPACITY[quality])
			if views >= RSSettings.SPLIT_TIER_VIEWS:
				expected = floori(expected * 0.5)
			check.call(budget.multimesh.instance_count == expected, "water wake: quality and split tier set fixed capacity at construction")
			budget.free()
	RSSettings.quality = 0
	RSSettings.views = 1
	var wake := RSWaterWake.new(surface)
	var capacity := wake.multimesh.instance_count
	for i in capacity + 3:
		wake.emit(Vector3(i, 999, 0), Vector3.FORWARD, 1.0, 1.0, i * 0.001)
	wake.update(0.5)
	check.call(wake.multimesh.instance_count == capacity and wake.multimesh.visible_instance_count == capacity, "water wake: overflow keeps a fixed instance budget")
	var oldest := INF
	var newest := -INF
	for i in capacity:
		var xf := wake.multimesh.get_instance_transform(i)
		oldest = minf(oldest, xf.origin.x)
		newest = maxf(newest, xf.origin.x)
		check.call(absf(xf.origin.y - surface.height_at(xf.origin.x, xf.origin.z)) < 0.000001, "water wake: every patch follows current surface height, ignoring emitted Y")
		check.call(xf.basis.z.distance_to(RSWater.normal_at(surface.preset, xf.origin.x, xf.origin.z, 0.5)) < 0.000001 and absf(xf.basis.y.normalized().dot(xf.basis.z)) < 0.000001, "water wake: tangent plane and height share the same surface time")
	check.call(oldest == 3.0 and newest == capacity + 2, "water wake: overflow overwrites the oldest records")
	var initial := wake.multimesh.get_instance_custom_data(0)
	wake.update(2.0)
	var aged := wake.multimesh.get_instance_custom_data(0)
	check.call(aged.r > initial.r and aged.g < initial.g, "water wake: patches widen and fade with age")
	wake.update(10.0)
	for i in capacity:
		check.call(wake.multimesh.get_instance_custom_data(i).g == 0.0, "water wake: expired patches have zero opacity")
	wake.clear()
	check.call(wake.multimesh.visible_instance_count == 0, "water wake: clear hides all instances")
	wake.emit(Vector3.ZERO, Vector3.ZERO, 1.0, 1.0, 20.0)
	wake.emit(Vector3(0.3, 100, 0), Vector3.RIGHT, 1.0, 1.0, 20.1)
	check.call(wake.multimesh.visible_instance_count == 1, "water wake: sub-spacing emits are rejected by horizontal distance")
	wake.emit(Vector3(1.2, 0, 0), Vector3.RIGHT, 1.0, 1.0, 20.2)
	wake.update(20.2)
	check.call(wake.multimesh.visible_instance_count == 2, "water wake: clear resets spacing and sufficiently spaced emits add records")
	wake.lifetime = 0.0
	wake.update(20.2)
	check.call(wake.multimesh.get_instance_custom_data(1).g == 0.0, "water wake: a zero lifetime is immediately transparent")
	wake.free()
	var parent := Node3D.new()
	RSSettings.views = 4
	RSWaterWake.splash(parent, Vector3(2, 3, 4), 1.0)
	var splash := parent.get_child(0) as GPUParticles3D
	check.call(splash != null and splash.one_shot and splash.emitting and splash.top_level and splash.position == Vector3(2, 3, 4), "water splash: an off-tree parent supports a world-positioned one-shot without global access")
	check.call(splash.amount == 4, "water splash: low quality split views keep a small particle budget")
	RSWaterWake.splash(parent, Vector3.ZERO, 0.0)
	check.call(parent.get_child_count() == 1, "water splash: zero strength creates no particle node")
	parent.free()
	surface.free()
	RSSettings.quality = old_quality
	RSSettings.views = old_views
