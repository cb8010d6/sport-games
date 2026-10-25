class_name RSWaterWake
extends MultiMeshInstance3D
## Fixed-capacity, world-space foam patches shared by one or more vehicles.
## Metres and game-clock seconds. Only XZ, direction and birth data are retained;
## update(t) synchronizes the public surface clock before querying height and normal.
## Spacing compares consecutive accepted emits; independent patches never join vehicles.

const CAPACITY := [64, 128, 256, 256]
const WAKE_SHADER: Shader = preload("res://shaders/rs_water_wake.gdshader")

var lifetime := 4.0
var spacing := 0.6
var _surface: RSWaterSurface
var _slots := 0
var _next := 0
var _count := 0
var _has_last := false
var _last := Vector2.ZERO
var _positions := PackedVector2Array()
var _directions := PackedVector2Array()
var _birth := PackedFloat64Array()
var _width := PackedFloat32Array()
var _strength := PackedFloat32Array()


func _init(surface: RSWaterSurface) -> void:
	_surface = surface
	_slots = _capacity_for_settings()
	_positions.resize(_slots)
	_directions.resize(_slots)
	_birth.resize(_slots)
	_width.resize(_slots)
	_strength.resize(_slots)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = _slots
	mm.visible_instance_count = 0
	multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = WAKE_SHADER
	mat.render_priority = 1
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 0.02 # shader's tiny normal bias, after CPU width scaling
	top_level = true # instance transforms and recorded positions are world-space


func emit(pos: Vector3, dir: Vector3, width: float, strength: float, t: float) -> void:
	var intensity := clampf(strength, 0.0, 1.0)
	if intensity <= 0.0 or width <= 0.0:
		return
	var point := Vector2(pos.x, pos.z)
	var minimum := maxf(spacing, 0.0)
	if _has_last and point.distance_squared_to(_last) < minimum * minimum:
		return
	var direction := Vector2(dir.x, dir.z)
	_positions[_next] = point
	_directions[_next] = direction.normalized() if direction.length_squared() > 0.000001 else Vector2(0, -1)
	_birth[_next] = t
	_width[_next] = width
	_strength[_next] = intensity
	# A replaced slot stays hidden until update has placed it on the current wave.
	multimesh.set_instance_custom_data(_next, Color(0, 0, 0, 0))
	_next = (_next + 1) % _slots
	_count = mini(_count + 1, _slots)
	_has_last = true
	_last = point
	multimesh.visible_instance_count = _count


func update(t: float) -> void:
	_surface.update(t)
	for i in _count:
		var age := clampf((t - _birth[i]) / lifetime, 0.0, 1.0) if lifetime > 0.0 else 1.0
		var point := _positions[i]
		var normal := RSWater.normal_at(_surface.preset, point.x, point.y, t)
		var direction := _directions[i]
		var along := Vector3(direction.x, 0.0, direction.y)
		along = (along - normal * along.dot(normal)).normalized()
		var right := along.cross(normal).normalized()
		var width := _width[i] * (1.0 + age * 2.0)
		var opacity := _strength[i] * (1.0 - age) * (1.0 - age)
		var basis := Basis(right * width, along * maxf(spacing, 0.1) * 1.5, normal)
		var origin := Vector3(point.x, _surface.height_at(point.x, point.y), point.y)
		multimesh.set_instance_transform(i, Transform3D(basis, origin))
		# r = width (m), g = opacity, b = normalized age, a = initial intensity.
		multimesh.set_instance_custom_data(i, Color(width, opacity, age, _strength[i]))


func clear() -> void:
	_next = 0
	_count = 0
	_has_last = false
	multimesh.visible_instance_count = 0


static func _capacity_for_settings() -> int:
	var capacity: int = CAPACITY[clampi(RSSettings.quality, 0, CAPACITY.size() - 1)]
	return floori(capacity * 0.5) if RSSettings.split_tier() else capacity


static func splash(parent: Node3D, pos: Vector3, strength: float) -> void:
	## Replace this small preset internally when RSVfx supplies E2; callers keep this API.
	var intensity := clampf(strength, 0.0, 1.0)
	if intensity <= 0.0:
		return
	var ps := GPUParticles3D.new()
	ps.emitting = false
	ps.one_shot = true
	ps.amount = maxi(1, roundi(_capacity_for_settings() * intensity / 8.0))
	ps.lifetime = 0.8
	ps.explosiveness = 1.0
	ps.local_coords = false
	ps.top_level = true
	ps.position = pos # top-level local coordinates are world coordinates, even off-tree
	ps.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = 65.0
	pm.initial_velocity_min = 1.0 + 2.0 * intensity
	pm.initial_velocity_max = 2.0 + 4.0 * intensity
	pm.gravity = Vector3.DOWN * RSWater.GRAVITY
	var fade := Gradient.new()
	fade.colors = PackedColorArray([Color.WHITE, Color(1, 1, 1, 0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	pm.color_ramp = ramp
	ps.process_material = pm
	var drop := QuadMesh.new()
	drop.size = Vector2(0.08, 0.08)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.85, 0.95, 1.0, 0.8)
	drop.material = mat
	ps.draw_pass_1 = drop
	ps.finished.connect(ps.queue_free)
	parent.add_child(ps)
	ps.emitting = true
