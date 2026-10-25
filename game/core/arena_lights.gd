class_name RSArenaLights
extends RefCounted
## Shared venue fixtures in metres: root +Z faces the court; xform/aim/rect/center are world data.
## Build at scene load. Every fixture shares cached geometry/materials; real_lights is a
## total per fixture/array, bounded by its heads. Projects audit the usual four-light venue budget.
## Ancestor local transforms also work off-tree, without global_transform or look_at calls.

class LightSpec:
	var color := Color(1.0, 0.97, 0.9)
	var energy := 4.0
	var range := 40.0
	var real_lights := 1
	var cast_shadows := false


static var _box: BoxMesh
static var _metal: StandardMaterial3D
static var _glow: Dictionary = {}


static func flood_tower(parent: Node3D, xform: Transform3D, height: float, heads: int, aim: Vector3, spec: LightSpec) -> Node3D:
	var root := _root(parent, xform)
	var rods: Array[Transform3D] = []
	var corners := PackedVector3Array([Vector3(-0.25, 0, -0.5), Vector3(0.25, 0, -0.5), Vector3(0.25, 0, 0), Vector3(-0.25, 0, 0)])
	var bands := maxi(1, ceili(maxf(height, 0.0) / 3.0))
	for i in 4:
		_beam(rods, corners[i], corners[i] + Vector3.UP * height, 0.07)
		for row in bands:
			var a := corners[i] + Vector3.UP * height * row / bands
			var b := corners[(i + 1) % 4] + Vector3.UP * height * row / bands
			_beam(rods, a, b, 0.045)
			_beam(rods, a, b + Vector3.UP * height / bands, 0.035)
	_beam(rods, Vector3(-maxi(heads, 1) * 0.55, height, -0.2), Vector3(maxi(heads, 1) * 0.55, height, -0.2), 0.12)
	_frame(root, rods)
	var lamps: Array[Node3D] = []
	var local_aim := xform.affine_inverse() * aim
	for i in maxi(heads, 0):
		var at := Vector3((i - (heads - 1) * 0.5) * 1.1, height, 0)
		lamps.append(_head(root, at, local_aim - at, Vector3(0.9, 0.5, 0.18), spec))
	_real_lights(lamps, spec)
	return root


static func ceiling_grid(parent: Node3D, rect: Rect2, height: float, rows: int, cols: int, spec: LightSpec) -> Node3D:
	var root := _root(parent, Transform3D.IDENTITY)
	var lamps: Array[Node3D] = []
	var area := rect.abs()
	for row in maxi(rows, 0):
		for col in maxi(cols, 0):
			var at := Vector3(area.position.x + (col + 0.5) * area.size.x / cols, height,
				area.position.y + (row + 0.5) * area.size.y / rows)
			lamps.append(_head(root, at, Vector3.DOWN, Vector3(1.2, 0.65, 0.12), spec))
	_real_lights(lamps, spec)
	return root


static func hanging_lamps(parent: Node3D, center: Vector3, size: Vector2, height: float, count: int, spec: LightSpec) -> Node3D:
	var root := _root(parent, Transform3D(Basis.IDENTITY, center))
	var rods: Array[Transform3D] = []
	var lamps: Array[Node3D] = []
	for i in maxi(count, 0):
		var angle := TAU * i / count + PI * 0.25
		var at := Vector3(cos(angle) * size.x * 0.5, height, sin(angle) * size.y * 0.5) if count > 1 else Vector3(0, height, 0)
		_beam(rods, at, at + Vector3.UP * 0.8, 0.035)
		lamps.append(_head(root, at, Vector3.DOWN, Vector3(0.8, 0.8, 0.25), spec))
	_frame(root, rods)
	_real_lights(lamps, spec)
	return root


static func real_light_count(root: Node3D) -> int:
	return _count_local_lights(root)


static func _count_local_lights(node: Node) -> int:
	var count := 1 if node is SpotLight3D or node is OmniLight3D else 0
	for i in node.get_child_count():
		count += _count_local_lights(node.get_child(i))
	return count


static func _world(node: Node3D) -> Transform3D:
	var world := Transform3D.IDENTITY
	var ancestor: Node = node
	while ancestor != null:
		if ancestor is Node3D:
			var spatial := ancestor as Node3D
			world = spatial.transform * world
			if spatial.top_level:
				break
		ancestor = ancestor.get_parent()
	return world


static func _root(parent: Node3D, xform: Transform3D) -> Node3D:
	var root := Node3D.new()
	root.transform = _world(parent).affine_inverse() * xform
	parent.add_child(root)
	return root


static func _facing(direction: Vector3) -> Basis:
	var z := direction.normalized() if direction.length_squared() > 0.000001 else Vector3.BACK
	var up := Vector3.FORWARD if absf(z.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var x := up.cross(z).normalized()
	return Basis(x, z.cross(x).normalized(), z)


static func _head(parent: Node3D, at: Vector3, direction: Vector3, size: Vector3, spec: LightSpec) -> Node3D:
	var head := Node3D.new()
	head.name = "Head%d" % parent.get_child_count() # no-i18n
	head.transform = Transform3D(_facing(direction), at)
	parent.add_child(head)
	var body := MeshInstance3D.new()
	body.mesh = _unit_box()
	body.scale = size
	var key := Vector4(spec.color.r, spec.color.g, spec.color.b, maxf(spec.energy, 0.0))
	if not _glow.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = spec.color
		mat.roughness = 0.3
		mat.emission_enabled = true
		mat.emission = spec.color
		mat.emission_energy_multiplier = maxf(spec.energy, 0.0)
		_glow[key] = mat
	body.material_override = _glow[key] as StandardMaterial3D
	head.add_child(body)
	return head


static func _real_lights(heads: Array[Node3D], spec: LightSpec) -> void:
	var count := clampi(spec.real_lights, 0, heads.size())
	for i in count:
		var index := floori((heads.size() - 1) * 0.5) if count == 1 else roundi(float(i) * (heads.size() - 1) / (count - 1))
		var light := SpotLight3D.new()
		light.light_color = spec.color
		light.light_energy = maxf(spec.energy, 0.0)
		light.spot_range = maxf(spec.range, 0.1)
		light.spot_angle = 55.0
		light.rotation.y = PI # Light3D -Z follows the head's +Z emitting face.
		# 57-05 is absent: keep every local shadow off until local_shadows is available.
		light.shadow_enabled = false
		heads[index].add_child(light)


static func _unit_box() -> BoxMesh:
	if _box == null:
		_box = BoxMesh.new()
		_box.size = Vector3.ONE
	return _box


static func _beam(rods: Array[Transform3D], a: Vector3, b: Vector3, width: float) -> void:
	var delta := b - a
	if delta.length_squared() <= 0.000001:
		return
	var y := delta.normalized()
	var guide := Vector3.RIGHT if absf(y.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var x := guide.cross(y).normalized()
	rods.append(Transform3D(Basis(x * width, y * delta.length(), x.cross(y).normalized() * width), (a + b) * 0.5))


static func _frame(parent: Node3D, rods: Array[Transform3D]) -> void:
	if rods.is_empty():
		return
	if _metal == null:
		_metal = RSPbr.standard("metal_plate")
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _unit_box()
	mm.instance_count = rods.size()
	for i in rods.size():
		mm.set_instance_transform(i, rods[i])
	var frame := MultiMeshInstance3D.new()
	frame.multimesh = mm
	frame.material_override = _metal
	parent.add_child(frame)
