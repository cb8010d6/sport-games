extends Node
## Geometry/data regression for RSArena; no downloaded textures or rendered frames required.

var _checks := 0
var _failures := 0


func _ready() -> void:
	_seat_data()
	_bleachers()
	_parent_transforms()
	_paths_and_ads()
	_empty_inputs()
	_triangle_counter()
	_test_lights()
	print("RS_ARENA_TESTS: %d checks, %d failures" % [_checks, _failures]) # no-i18n
	get_tree().quit(0 if _failures == 0 else 1)


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("ARENA: " + message) # no-i18n


func _close(a: Transform3D, b: Transform3D) -> bool:
	return a.origin.distance_to(b.origin) < 1e-5 and a.basis.is_equal_approx(b.basis)


func _seats(root: Node3D) -> MultiMeshInstance3D:
	for child: Node in root.get_children():
		if child is MultiMeshInstance3D:
			return child as MultiMeshInstance3D
	return null


func _seat_data() -> void:
	var spec := RSArena.Bleacher.new()
	spec.rows = 3
	spec.seats_per_row = 10
	spec.aisle_every = 4
	var seats := RSArena.seat_transforms(Transform3D.IDENTITY, spec)
	_check(seats.size() == 24, "three rows of ten slots minus two aisles per row")
	_check(seats[0].origin.is_equal_approx(Vector3(-2.25, 0.4, -0.4)), "front row height and front-edge origin")
	_check(seats[8].origin.is_equal_approx(Vector3(-2.25, 0.8, -1.2)), "rows advance backwards and rise")
	_check(absf(seats[3].origin.x - seats[2].origin.x - 1.0) < 1e-6, "aisle preserves an empty seat-width slot")
	var ordered := true
	for row in 3:
		for column in 7:
			ordered = ordered and seats[row * 8 + column].origin.x < seats[row * 8 + column + 1].origin.x
	_check(ordered, "seats ordered front-to-back and left-to-right")
	var xform := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(5, 2, -3))
	var world := RSArena.seat_transforms(xform, spec)
	var oriented := true
	for i in seats.size():
		oriented = oriented and _close(world[i], xform * seats[i]) and world[i].basis.z.is_equal_approx(xform.basis.z)
	_check(oriented, "every world seat +Z faces transformed court direction")
	spec.aisle_every = 0
	_check(RSArena.seat_transforms(xform, spec).size() == 30, "aisle_every zero keeps every slot")
	spec.aisle_every = 1
	_check(RSArena.seat_transforms(xform, spec).is_empty(), "aisle_every one safely leaves no seats")


func _bleachers() -> void:
	var holder := Node3D.new()
	var metal: Material
	var plastic: Material
	var default_triangles := 0
	for style: int in [RSArena.BleacherStyle.OUTDOOR_METAL, RSArena.BleacherStyle.INDOOR_SEATS, RSArena.BleacherStyle.RINGSIDE_CHAIRS]:
		var spec := RSArena.Bleacher.new()
		spec.style = style
		var root := RSArena.bleacher(holder, Transform3D.IDENTITY, spec)
		var seats := _seats(root)
		_check(seats != null and seats.multimesh.instance_count == 120, "each style builds one 120-seat MultiMesh")
		var count := RSArena.triangle_count(root)
		_check(count > 0, "each style builds triangle geometry")
		if style == RSArena.BleacherStyle.OUTDOOR_METAL:
			default_triangles = count
			metal = (root.get_node("Metal") as MeshInstance3D).mesh.surface_get_material(0) # no-i18n
			plastic = seats.multimesh.mesh.surface_get_material(0)
		else:
			_check((root.get_node("Metal") as MeshInstance3D).mesh.surface_get_material(0) == metal, "metal material cache shared across styles") # no-i18n
		_check(root.get_child_count() <= 3, "platforms/rails merged into a small number of mesh nodes")
	_check(default_triangles <= 20000, "six-by-twenty outdoor bleacher stays below fixed 20k budget")
	print("ARENA_NUMERIC outdoor_6x20_triangles=%d" % default_triangles) # no-i18n
	var spec := RSArena.Bleacher.new()
	spec.aisle_every = 5
	var second := RSArena.bleacher(holder, Transform3D.IDENTITY, spec)
	_check(_seats(second).multimesh.instance_count == 96, "MultiMesh also deducts aisle slots")
	_check((second.get_node("Metal") as MeshInstance3D).mesh.surface_get_material(0) == metal, "second stand reuses same metal object") # no-i18n
	_check(_seats(second).multimesh.mesh.surface_get_material(0) == plastic, "same seat color reuses plastic object")
	spec.seat_color = Color(0.4, 0.42, 0.45)
	var third := RSArena.bleacher(holder, Transform3D.IDENTITY, spec)
	var changed := _seats(third).multimesh.mesh.surface_get_material(0) as StandardMaterial3D
	_check(changed != plastic and changed.albedo_color == spec.seat_color, "different color has an independent cached material")
	_check((plastic as StandardMaterial3D).albedo_color == Color(0.25, 0.3, 0.38), "later colors cannot recolor earlier seats")
	_check(absf(changed.roughness - 0.6) < 1e-6, "seat plastic roughness is 0.6")
	holder.free()


func _test_lights() -> void:
	# Keep transformed parents off-tree so no global-transform fallback can hide bad accesses.
	var grand := Node3D.new()
	grand.transform = Transform3D(Basis(Vector3.UP, 0.4), Vector3(4, 1, -5))
	var holder := Node3D.new()
	holder.transform = Transform3D(Basis(Vector3.UP, -0.2).scaled(Vector3(2, 1, 1)), Vector3(2, 0, 3))
	grand.add_child(holder)
	var parent_world := grand.transform * holder.transform
	var spec := RSArenaLights.LightSpec.new()
	spec.real_lights = 2
	spec.cast_shadows = true
	var xform := Transform3D(Basis(Vector3.UP, 0.6), Vector3(-6, 0, -8))
	var aim := Vector3(2, 1, 3)
	var tower := RSArenaLights.flood_tower(holder, xform, 12.0, 6, aim, spec)
	_check(_close(parent_world * tower.transform, xform), "lights: tower keeps world placement under off-tree transformed parents")
	var heads := 0
	var aimed := true
	var glow: Material
	for node: Node in tower.get_children():
		if node is Node3D and str(node.name).begins_with("Head"):
			heads += 1
			var head := node as Node3D
			var world := xform * head.transform
			aimed = aimed and world.basis.z.normalized().distance_to((aim - world.origin).normalized()) < 1e-5
			var lens := head.get_child(0) as MeshInstance3D
			if glow == null:
				glow = lens.material_override
			else:
				_check(lens.material_override == glow, "lights: identical heads share the same glowing material")
			for child: Node in head.get_children():
				if child is SpotLight3D:
					var world_light := world * (child as SpotLight3D).transform
					aimed = aimed and (-world_light.basis.z).normalized().distance_to((aim - world.origin).normalized()) < 1e-5
	_check(heads == 6 and aimed, "lights: six lamp heads and actual -Z lights aim at the world target")
	_check(RSArenaLights.real_light_count(tower) == spec.real_lights, "lights: a tower uses the requested real-light count")
	var grid := RSArenaLights.ceiling_grid(holder, Rect2(-10, -6, 20, 12), 7.0, 4, 6, spec)
	_check(grid.get_child_count() == 24 and RSArenaLights.real_light_count(grid) == 2, "lights: a four-by-six ceiling array shares two real lights across all panels")
	var down := true
	for node: Node in grid.get_children():
		var head := node as Node3D
		down = down and head.basis.z.is_equal_approx(Vector3.DOWN) and head.position.y == 7.0
	_check(down, "lights: ceiling panels face straight down without an off-tree look_at")
	var hanging := RSArenaLights.hanging_lamps(holder, Vector3(0, 1, 0), Vector2(6, 6), 5.0, 4, spec)
	_check(RSArenaLights.real_light_count(hanging) == 2 and RSArenaLights.real_light_count(holder) == 6, "lights: recursive counting includes every local fixture")
	for root: Node3D in [tower, grid, hanging]:
		for light: Node in root.find_children("*", "Light3D", true, false):
			_check(not (light as Light3D).shadow_enabled, "lights: absent 57-05 keeps local shadows off even when requested")
	var second := RSArenaLights.flood_tower(holder, Transform3D.IDENTITY, 8.0, 2, aim, spec)
	_check((second.get_child(0) as MultiMeshInstance3D).material_override == (tower.get_child(0) as MultiMeshInstance3D).material_override, "lights: separate fixtures share cached metal")
	_check(((second.get_child(1).get_child(0)) as MeshInstance3D).material_override == glow, "lights: separate fixtures share cached emissive material")
	holder.top_level = true
	var detached := RSArenaLights.ceiling_grid(holder, Rect2(0, 0, 4, 4), 4.0, 1, 1, spec)
	_check(_close(holder.transform * detached.transform, Transform3D.IDENTITY), "lights: world placement stops at a top-level ancestor")
	var board := RSScoreboard.new(Vector2(4, 2), "TEST")
	holder.add_child(board)
	board.set_scores("11", "9")
	_check(board._left.text == "11" and board._right.text == "9" and board._left.font == RSUi.font_numeric(), "scoreboard: scores use shared numeric font and requested text")
	var writes := board._text_updates
	board.set_scores("11", "9")
	_check(board._text_updates == writes, "scoreboard: identical scores do not assign label text again")
	board.set_line("ROUND 2")
	writes = board._text_updates
	board.set_line("ROUND 2")
	_check(board._line.text == "ROUND 2" and board._text_updates == writes, "scoreboard: identical middle text is not reassigned")
	board.set_scores("12", "9")
	_check(board._text_updates == writes + 1, "scoreboard: only the changed side receives an assignment")
	board.set_colors(Color(0.2, 0.4, 0.9), Color(0.9, 0.25, 0.2))
	_check(board._left.modulate == Color(0.2, 0.4, 0.9) and board._right.modulate == Color(0.9, 0.25, 0.2), "scoreboard: callers choose side colors")
	var another := RSScoreboard.new(Vector2(3, 1.5))
	holder.add_child(another)
	_check((board.get_child(0) as MeshInstance3D).material_override == (another.get_child(0) as MeshInstance3D).material_override, "scoreboard: bottom panels share their emissive material")
	grand.free()
	_test_lights_node_bridge()


func _test_lights_node_bridge() -> void:
	# A plain Node interrupts Node3D transform inheritance. Read the actual in-tree
	# world transforms rather than replaying the builder's ancestor calculation.
	var grand := Node3D.new()
	grand.position = Vector3(10, 0, 0)
	add_child(grand)
	var bridge := Node.new()
	grand.add_child(bridge)
	var holder := Node3D.new()
	bridge.add_child(holder)
	var spec := RSArenaLights.LightSpec.new()
	spec.real_lights = 2
	var aim := Vector3(4, 1, 10)
	var tower := RSArenaLights.flood_tower(holder, Transform3D.IDENTITY, 8.0, 3, aim, spec)
	var root_error := tower.global_position.length()
	_check(_close(tower.global_transform, Transform3D.IDENTITY), "lights: plain Node bridge excludes the translated grandparent from world tower placement")
	var aim_error := 0.0
	for light: SpotLight3D in tower.find_children("*", "SpotLight3D", true, false):
		var actual := (-light.global_basis.z).normalized()
		var expected := (aim - light.global_position).normalized()
		aim_error = maxf(aim_error, actual.distance_to(expected))
	_check(RSArenaLights.real_light_count(tower) == 2 and aim_error < 1e-5, "lights: actual spot directions reach the world target across a plain Node bridge")
	var grid := RSArenaLights.ceiling_grid(holder, Rect2(-2, -2, 4, 4), 6.0, 2, 2, spec)
	_check(_close(grid.global_transform, Transform3D.IDENTITY), "lights: world ceiling array placement also stops at a plain Node bridge")
	var center := Vector3(3, 1, -2)
	var hanging := RSArenaLights.hanging_lamps(holder, center, Vector2(4, 4), 5.0, 4, spec)
	_check(_close(hanging.global_transform, Transform3D(Basis.IDENTITY, center)), "lights: hanging fixture world center ignores ancestors beyond a plain Node bridge")
	print("ARENA_NUMERIC lights_node_bridge_root_error_m=%.9f max_aim_direction_error=%.9f" % [root_error, aim_error]) # no-i18n
	grand.free()


func _parent_transforms() -> void:
	# Deliberately keep this hierarchy outside the tree: no global_transform access is safe here.
	var grand := Node3D.new()
	var parent := Node3D.new()
	grand.transform = Transform3D(Basis(Vector3.UP, PI / 3.0), Vector3(2, 1, -3))
	parent.transform = Transform3D(Basis(Vector3.UP, -0.25).scaled(Vector3(2, 1, 1)), Vector3(-2, 0.5, 4))
	grand.add_child(parent)
	var spec := RSArena.Bleacher.new()
	spec.rows = 2
	spec.seats_per_row = 5
	spec.aisle_every = 3
	var xform := Transform3D(Basis(Vector3.UP, -0.8), Vector3(4, 3, 8))
	var root := RSArena.bleacher(parent, xform, spec)
	var expected := RSArena.seat_transforms(xform, spec)
	var mm := _seats(root).multimesh
	var actual_root := grand.transform * parent.transform * root.transform
	_check(_close(actual_root, xform), "bleacher root keeps its world xform under transformed parents")
	# Dummy rendering cannot read individual instances; inspect the real submitted buffer.
	var buffer := mm.buffer
	var stored := buffer.size() == mm.instance_count * 12
	_check(stored, "MultiMesh retains all twelve transform floats for every seat")
	var aligned := stored and expected.size() == mm.instance_count
	var max_position_error := 0.0
	var max_basis_error := 0.0
	if stored:
		_check(_close(_buffer_transform(buffer, 0), Transform3D(Basis.IDENTITY, Vector3(-1, 0.4, -0.4))), "first stored seat preserves position and unit axes without mesh-size scaling")
		for i: int in expected.size():
			var actual := actual_root * _buffer_transform(buffer, i)
			aligned = aligned and _close(actual, expected[i])
			max_position_error = maxf(max_position_error, actual.origin.distance_to(expected[i].origin))
			for axis: int in 3:
				max_basis_error = maxf(max_basis_error, (actual.basis[axis] - expected[i].basis[axis]).length())
	_check(aligned, "MultiMesh seat positions and orientations equal public world seat transforms")
	print("ARENA_NUMERIC stored_seats=%d max_position_error_m=%.9f max_basis_error=%.9f" % [mm.instance_count, max_position_error, max_basis_error]) # no-i18n
	parent.top_level = true
	var detached := RSArena.bleacher(parent, xform, spec)
	_check(_close(parent.transform * detached.transform, xform), "top-level parent stops inherited transforms")
	grand.free()


func _buffer_transform(buffer: PackedFloat32Array, index: int) -> Transform3D:
	var o: int = index * 12
	return Transform3D(Basis(Vector3(buffer[o], buffer[o + 4], buffer[o + 8]),
			Vector3(buffer[o + 1], buffer[o + 5], buffer[o + 9]),
			Vector3(buffer[o + 2], buffer[o + 6], buffer[o + 10])),
			Vector3(buffer[o + 3], buffer[o + 7], buffer[o + 11]))


func _paths_and_ads() -> void:
	var holder := Node3D.new()
	var path := PackedVector3Array([Vector3.ZERO, Vector3(5, 0, 0), Vector3(5, 0, 3), Vector3(7, 1, 3)])
	for style: int in [RSArena.FenceStyle.CHAINLINK, RSArena.FenceStyle.LOW_BOARD, RSArena.FenceStyle.ROPE]:
		var root := RSArena.fence(holder, path, 1.2, style)
		_check(root.get_child_count() == 3, "each fence style keeps exactly three path segments")
		var positioned := true
		for i in 3:
			var segment := root.get_child(i) as MeshInstance3D
			positioned = positioned and segment.mesh != null
			positioned = positioned and segment.position.is_equal_approx((path[i] + path[i + 1]) * 0.5)
			positioned = positioned and segment.basis.x.is_equal_approx((path[i + 1] - path[i]).normalized())
		_check(positioned and RSArena.triangle_count(root) > 0, "fence segments follow full 3D path with finite geometry")
	var plain := RSArena.ad_boards(holder, path, 2.0, 1.0)
	_check(plain.get_child_count() == 3, "advertising keeps one mesh node per input segment")
	var material := ((plain.get_child(0) as MeshInstance3D).mesh.surface_get_material(1) as StandardMaterial3D)
	_check(material.albedo_texture == null and material.albedo_color == RSUi.SURFACE, "null atlas uses themed solid placeholder")
	_check(RSArena.triangle_count(plain) == 56, "four complete boards contribute exactly 56 triangles")
	var image := Image.create(6, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var atlas := ImageTexture.create_from_image(image)
	var ads := RSArena.ad_boards(holder, path, 2.0, 1.0, atlas, 3)
	var board := 0
	var uv_ok := true
	var dimensions_ok := true
	for i in 3:
		var segment := ads.get_child(i) as MeshInstance3D
		var mesh := segment.mesh
		var arrays := mesh.surface_get_arrays(1)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var expected_count: Array[int] = [2, 1, 1]
		dimensions_ok = dimensions_ok and vertices.size() == expected_count[i] * 6
		for j: int in expected_count[i]:
			var offset: int = j * 6
			var lo := float(board % 3) / 3.0
			var hi := float(board % 3 + 1) / 3.0
			uv_ok = uv_ok and absf(uv[offset].x - lo) < 1e-6 and absf(uv[offset + 2].x - hi) < 1e-6
			uv_ok = uv_ok and uv[offset].y == 1.0 and uv[offset + 1].y == 0.0
			dimensions_ok = dimensions_ok and absf(vertices[offset + 2].x - vertices[offset].x - 2.0) < 1e-6
			dimensions_ok = dimensions_ok and absf(vertices[offset + 1].y - vertices[offset].y - 1.0) < 1e-6
			dimensions_ok = dimensions_ok and vertices[offset + 2].x <= path[i].distance_to(path[i + 1]) * 0.5 + 1e-6
			board += 1
	_check(board == 4 and uv_ok, "atlas slots cycle 0,1,2,0 continuously across corners")
	_check(dimensions_ok, "boards keep width/height and do not extend across path corners")
	var again := RSArena.ad_boards(holder, path, 2.0, 1.0, atlas, 1)
	_check((again.get_child(0) as MeshInstance3D).mesh.surface_get_material(1) == (ads.get_child(0) as MeshInstance3D).mesh.surface_get_material(1), "atlas material cached independently of per-mesh slot UVs")
	var fallback := RSArena.ad_boards(holder, path, 2.0, 1.0, null, 0)
	_check((fallback.get_child(0) as MeshInstance3D).mesh.surface_get_material(1) == material, "null atlas and invalid slots reuse safe placeholder")
	holder.free()


func _empty_inputs() -> void:
	var holder := Node3D.new()
	var spec := RSArena.Bleacher.new()
	spec.rows = 0
	_check(RSArena.seat_transforms(Transform3D.IDENTITY, spec).is_empty(), "zero rows produce no seat data")
	_check(RSArena.triangle_count(RSArena.bleacher(holder, Transform3D.IDENTITY, spec)) == 0, "zero rows produce safe empty stand")
	spec.rows = 1
	spec.seats_per_row = 0
	_check(RSArena.seat_transforms(Transform3D.IDENTITY, spec).is_empty(), "zero seats produce no seat data")
	_check(RSArena.triangle_count(RSArena.bleacher(holder, Transform3D.IDENTITY, spec)) == 0, "zero seats produce safe empty stand")
	var empty := PackedVector3Array()
	_check(RSArena.fence(holder, empty, 1.0, RSArena.FenceStyle.CHAINLINK).get_child_count() == 0, "empty fence path is safe")
	_check(RSArena.ad_boards(holder, empty, 1.0, 1.0).get_child_count() == 0, "empty advertising path is safe")
	var duplicate := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.RIGHT])
	var fence := RSArena.fence(holder, duplicate, 0.0, RSArena.FenceStyle.ROPE)
	var ads := RSArena.ad_boards(holder, duplicate, 2.0, 1.0)
	_check(fence.get_child_count() == 2 and RSArena.triangle_count(fence) == 0, "zero-height and repeated-point fence retains safe empty segments")
	_check(ads.get_child_count() == 2 and RSArena.triangle_count(ads) == 0, "short/zero advertising segments do not stretch a board")
	holder.free()


func _triangle_counter() -> void:
	var holder := Node3D.new()
	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.ONE, Vector3.UP])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	arrays[Mesh.ARRAY_INDEX] = null
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var single := MeshInstance3D.new()
	single.mesh = mesh
	holder.add_child(single)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = 3
	var repeated := MultiMeshInstance3D.new()
	repeated.multimesh = mm
	holder.add_child(repeated)
	_check(RSArena.triangle_count(holder) == 12, "counter includes indexed/nonindexed surfaces and all MultiMesh instances")
	var nested := Node3D.new()
	holder.add_child(nested)
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	nested.add_child(box)
	_check(RSArena.triangle_count(holder) == 24, "counter recursively includes primitive meshes")
	var lines := ArrayMesh.new()
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT])
	lines.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var line_node := MeshInstance3D.new()
	line_node.mesh = lines
	holder.add_child(line_node)
	_check(RSArena.triangle_count(holder) == 24, "counter ignores line primitives")
	holder.free()
