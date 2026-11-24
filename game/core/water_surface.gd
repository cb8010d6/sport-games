class_name RSWaterSurface
extends MeshInstance3D
## Shared water on the world Y = 0 rest plane. center locates the dense region in XZ;
## translate this node in XZ on whole grid steps to follow a camera without moving wave phase.
## The caller supplies the same game-clock seconds to update and every physics query.

const FOAM_TEXTURE := "res://assets/shared/materials/acg_foam002/acg_foam002_diff_2k.png"
const WATER_SHADER: Shader = preload("res://shaders/rs_water.gdshader")
const NEAR_RADIUS := 16.0        ## m either side of the dense region's centre
const NEAR_STEP := [1.0, 0.5, 0.25]
const FAR_STEP := [8.0, 4.0, 2.0]

var preset: RSWater.Preset
var _size := Vector2.ZERO
var _time := 0.0
var _mesh_tier := -1
var _water_material := ShaderMaterial.new()


## center.y is ignored: it is not a water-level offset above the world-zero rest plane.
func _init(p: RSWater.Preset, size: Vector2, center := Vector3.ZERO) -> void:
	_size = size
	position = Vector3(center.x, 0.0, center.z)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_water_material.shader = WATER_SHADER
	material_override = _water_material
	# Do not ask the loader for a missing optional asset: fallback is a normal setup state.
	var foam: Texture2D = load(FOAM_TEXTURE) if ResourceLoader.exists(FOAM_TEXTURE) else null
	_water_material.set_shader_parameter("foam_tex", foam)
	_water_material.set_shader_parameter("use_foam_texture", foam != null)
	set_preset(p)
	apply_quality()


func set_preset(p: RSWater.Preset) -> void:
	preset = p
	RSWater.apply_to(preset, _water_material)
	var amplitude := 0.0
	for i in preset.wave_count():
		amplitude += absf(preset.waves[i * 4 + 3])
	# Vertex displacement must remain visible beyond the flat mesh's culling bounds.
	extra_cull_margin = maxf(amplitude * (1.0 + clampf(preset.steepness, 0.0, 1.0)), 0.05)


func update(t: float) -> void:
	_time = t
	_water_material.set_shader_parameter(&"wave_time", t)


func apply_quality() -> void:
	# High and ultra share one geometry tier; split views lower that geometry tier once.
	var tier := clampi(RSSettings.quality, 0, 2)
	if RSSettings.split_tier():
		tier = maxi(tier - 1, 0)
	_water_material.set_shader_parameter("detail_normals", tier > 0)
	if tier == _mesh_tier:
		return
	_mesh_tier = tier
	mesh = _make_mesh(float(NEAR_STEP[tier]), float(FAR_STEP[tier]))


func height_at(x: float, z: float) -> float:
	return RSWater.height_at(preset, x, z, _time)


func _axis(half_extent: float, near_step: float, far_step: float) -> PackedFloat32Array:
	var positive := PackedFloat32Array([0.0])
	var inner := minf(half_extent, NEAR_RADIUS)
	for i in ceili(inner / near_step):
		positive.append(minf((i + 1) * near_step, inner))
	for i in ceili((half_extent - inner) / far_step):
		positive.append(minf(inner + (i + 1) * far_step, half_extent))
	var axis := PackedFloat32Array()
	axis.resize(positive.size() * 2 - 1)
	for i in positive.size() - 1:
		axis[i] = -positive[positive.size() - 1 - i]
	for i in positive.size():
		axis[positive.size() - 1 + i] = positive[i]
	return axis


func _make_mesh(near_step: float, far_step: float) -> ArrayMesh:
	var xs := _axis(_size.x * 0.5, near_step, far_step)
	var zs := _axis(_size.y * 0.5, near_step, far_step)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	vertices.resize(xs.size() * zs.size())
	normals.resize(vertices.size())
	normals.fill(Vector3.UP)
	uvs.resize(vertices.size())
	indices.resize((xs.size() - 1) * (zs.size() - 1) * 6)
	var next := 0
	for z in zs.size():
		for x in xs.size():
			var i := z * xs.size() + x
			vertices[i] = Vector3(xs[x], 0.0, zs[z])
			uvs[i] = Vector2(xs[x] / _size.x + 0.5, zs[z] / _size.y + 0.5)
			if x + 1 < xs.size() and z + 1 < zs.size():
				# Godot's clockwise front face; adjacent cells share the exact same vertices.
				indices[next] = i
				indices[next + 1] = i + 1
				indices[next + 2] = i + xs.size()
				indices[next + 3] = i + 1
				indices[next + 4] = i + xs.size() + 1
				indices[next + 5] = i + xs.size()
				next += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result
