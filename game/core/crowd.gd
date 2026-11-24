class_name RSCrowd
## Spectators for finish areas: a low-poly fan (MultiMesh-ready) whose shirt colour comes from
## the instance colour and whose hop/wave rhythm comes from the instance custom data
## (phase, tempo), animated by shaders/crowd.gdshader.

const SHIRTS := [Color(0.95, 0.3, 0.3), Color(0.2, 0.5, 0.95), Color(1.0, 0.8, 0.2), Color(0.2, 0.75, 0.4), Color(0.95, 0.95, 0.95),
	Color(0.6, 0.35, 0.8), Color(0.1, 0.12, 0.16), Color(1.0, 0.55, 0.2)]
const V2_MESH := "res://assets/shared/crowd/crowd_person.tres"
const CROWD_SHADER := preload("res://shaders/crowd.gdshader")

static var _mesh: Mesh


static func mesh() -> Mesh:
	## V2 surface 0 is clothing; surface 1 is skin. Missing assets keep the capsule fan.
	if _mesh == null:
		var replacement: Mesh
		if ResourceLoader.exists(V2_MESH):
			replacement = load(V2_MESH) as Mesh
		_mesh = _skin_mask(replacement) if replacement != null else person_mesh()
	return _mesh


static func person_mesh() -> ArrayMesh:
	## Capsule body (shirt colour per instance) + head and raised arms (skin).
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var body := CapsuleMesh.new()
	body.radius = 0.2
	body.height = 1.15
	body.radial_segments = 8
	body.rings = 3
	st.append_from(body, 0, Transform3D(Basis(), Vector3(0, 0.6, 0)))
	var mesh := st.commit()
	var head_st := SurfaceTool.new()
	head_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var head := SphereMesh.new()
	head.radius = 0.14
	head.height = 0.28
	head.radial_segments = 8
	head.rings = 4
	head_st.append_from(head, 0, Transform3D(Basis(), Vector3(0, 1.38, 0)))
	var arm := CapsuleMesh.new()
	arm.radius = 0.06
	arm.height = 0.6
	arm.radial_segments = 6
	arm.rings = 2
	head_st.append_from(arm, 0, Transform3D(Basis(Vector3.BACK, 0.35), Vector3(-0.3, 1.35, 0)))
	head_st.append_from(arm, 0, Transform3D(Basis(Vector3.BACK, -0.35), Vector3(0.3, 1.35, 0)))
	head_st.commit(mesh)
	return _skin_mask(mesh)


static func _skin_mask(source: Mesh) -> ArrayMesh:
	# A material_override covers every surface: carry the skin flag in UV2.x instead.
	# This is prepared once for mesh(), leaving every crowd group free to own its cheer.
	var result := ArrayMesh.new()
	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var mask := PackedVector2Array()
		mask.resize(vertices.size())
		mask.fill(Vector2(1.0 if surface == 1 else 0.0, 0.0))
		arrays[Mesh.ARRAY_TEX_UV2] = mask
		var primitive := (source as ArrayMesh).surface_get_primitive_type(surface) if source is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
		result.add_surface_from_arrays(primitive, arrays)
		var material := ShaderMaterial.new()
		material.shader = CROWD_SHADER
		material.set_shader_parameter("skin", surface == 1)
		result.surface_set_material(surface, material)
	return result


static func place(parent: Node, xforms: Array[Transform3D], rng: RandomNumberGenerator, shirts: Array = SHIRTS) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh()
	mm.instance_count = xforms.size()
	var buffer := PackedFloat32Array()
	for i in xforms.size():
		var xform := xforms[i]
		# Preserve the legacy RNG order: shirt, phase, then tempo for each fan.
		var color := shirts[rng.randi_range(0, shirts.size() - 1)] as Color
		var custom := Color(rng.randf(), rng.randf_range(0.7, 1.3), 0, 0)
		# 3D row-major matrix (12), RGBA (4), phase/tempo/unused (4).
		buffer.append_array(PackedFloat32Array([
			xform.basis.x.x, xform.basis.y.x, xform.basis.z.x, xform.origin.x,
			xform.basis.x.y, xform.basis.y.y, xform.basis.z.y, xform.origin.y,
			xform.basis.x.z, xform.basis.y.z, xform.basis.z.z, xform.origin.z,
			color.r, color.g, color.b, color.a, custom.r, custom.g, custom.b, custom.a]))
	mm.buffer = buffer
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	var material := ShaderMaterial.new()
	material.shader = CROWD_SHADER
	material.set_shader_parameter("cheer", 0.6)
	mmi.material_override = material
	parent.add_child(mmi)
	return mmi


static func fill_seats(parent: Node, seats: Array[Transform3D], occupancy: float,
		rng: RandomNumberGenerator, shirts: Array = SHIRTS) -> MultiMeshInstance3D:
	## Seats use RSArena's world coordinates, while place() retains its local-coordinate API.
	var selected: Array[Transform3D] = []
	var chance := clampf(occupancy, 0.0, 1.0)
	for seat in seats:
		if chance >= 1.0 or (chance > 0.0 and rng.randf() < chance):
			selected.append(seat)
	var mmi := place(parent, selected, rng, shirts)
	mmi.top_level = true
	mmi.transform = Transform3D.IDENTITY
	return mmi


static func cheer(mmi: MultiMeshInstance3D, intensity: float) -> void:
	var material := mmi.material_override as ShaderMaterial
	if material != null:
		material.set_shader_parameter("cheer", clampf(intensity, 0.0, 1.0))
