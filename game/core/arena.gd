class_name RSArena
extends RefCounted
## Load-time arena structures, without lights, spectators or game-specific layouts.
## Metres, +Y up, +Z towards the court; a bleacher's origin is its front bottom midpoint.
## Bleacher xform and returned seats are world-space, even under a transformed parent.
## Fence/advertising paths use parent-local coordinates. Each input edge owns one mesh node.

enum BleacherStyle { OUTDOOR_METAL, INDOOR_SEATS, RINGSIDE_CHAIRS }
enum FenceStyle { CHAINLINK, LOW_BOARD, ROPE }

const EPS := 1e-6
const RAIL_RADIUS := 0.025          ## m
const FENCE_POST_PITCH := 2.5        ## m
const CHAIN_PITCH := 0.3            ## m, diagonal wire spacing
const WIRE_RADIUS := 0.006          ## m

static var _scans: Dictionary[String, Material] = {}
static var _plastics: Dictionary[Color, StandardMaterial3D] = {}
static var _advertising: Dictionary[Texture2D, StandardMaterial3D] = {}
static var _placeholder: StandardMaterial3D
static var _rope: StandardMaterial3D
static var _box: BoxMesh
static var _cylinder: CylinderMesh


class Bleacher:
	var style := BleacherStyle.OUTDOOR_METAL
	var rows := 6
	var seats_per_row := 20
	var seat_pitch := 0.5
	var row_depth := 0.8
	var row_rise := 0.4
	var seat_color := Color(0.25, 0.3, 0.38)
	var aisle_every := 0


class _Batch:
	var tool := SurfaceTool.new()
	var pieces := 0

	func _init() -> void:
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	func box(center: Vector3, size: Vector3) -> void:
		if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
			return
		tool.append_from(RSArena._box_mesh(), 0, Transform3D(Basis.from_scale(size), center))
		pieces += 1

	func bar(a: Vector3, b: Vector3, radius: float) -> void:
		var along := b - a
		if along.length_squared() < EPS * EPS:
			return
		var y := along.normalized()
		var ref := Vector3.RIGHT if absf(y.x) < 0.9 else Vector3.FORWARD
		var x := (ref - y * ref.dot(y)).normalized()
		var z := x.cross(y)
		tool.append_from(RSArena._cylinder_mesh(), 0,
				Transform3D(Basis(x * radius, along, z * radius), (a + b) * 0.5))
		pieces += 1

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, u0: float, u1: float) -> void:
		tool.set_normal(Vector3.BACK)
		_vertex(a, Vector2(u0, 1.0))
		_vertex(b, Vector2(u0, 0.0))
		_vertex(c, Vector2(u1, 0.0))
		_vertex(a, Vector2(u0, 1.0))
		_vertex(c, Vector2(u1, 0.0))
		_vertex(d, Vector2(u1, 1.0))
		pieces += 1

	func _vertex(p: Vector3, uv: Vector2) -> void:
		tool.set_uv(uv)
		tool.add_vertex(p)

	func mesh(material: Material, existing: ArrayMesh = null) -> ArrayMesh:
		if pieces == 0:
			return existing
		var result := tool.commit(existing)
		result.surface_set_material(result.get_surface_count() - 1, material)
		return result


static func _box_mesh() -> BoxMesh:
	if _box == null:
		_box = BoxMesh.new()
		_box.size = Vector3.ONE
	return _box


static func _cylinder_mesh() -> CylinderMesh:
	if _cylinder == null:
		_cylinder = CylinderMesh.new()
		_cylinder.top_radius = 1.0
		_cylinder.bottom_radius = 1.0
		_cylinder.height = 1.0
		_cylinder.radial_segments = 6
		_cylinder.rings = 0
	return _cylinder


static func _scan(id: String) -> Material:
	if not _scans.has(id):
		if _has_maps(id):
			_scans[id] = RSPbr.standard(id)
		else:
			# Sparse checkouts can build/test geometry without downloading the scanned textures.
			var fallback := StandardMaterial3D.new()
			fallback.albedo_color = Color(0.38, 0.41, 0.45) if id == "metal_plate" else Color(0.45, 0.42, 0.36) # no-i18n
			fallback.metallic = 0.7 if id == "metal_plate" else 0.0 # no-i18n
			fallback.roughness = 0.6 if id == "metal_plate" else 0.9 # no-i18n
			_scans[id] = fallback
	return _scans[id]


static func _has_maps(id: String) -> bool:
	for resolution: String in RSPbr.RESOLUTIONS:
		var base := RSPbr.ROOT + id + "/" + id # no-i18n
		var suffix := "_" + resolution + ".jpg" # no-i18n
		var albedo := ResourceLoader.exists(base + "_diff" + suffix) or ResourceLoader.exists(base + "_diff_" + resolution + ".png") # no-i18n
		if albedo and ResourceLoader.exists(base + "_nor_gl" + suffix) and ResourceLoader.exists(base + "_arm" + suffix): # no-i18n
			return true
	return false


static func _plastic(color: Color) -> StandardMaterial3D:
	if not _plastics.has(color):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.6
		_plastics[color] = material
	return _plastics[color]


static func _ad_material(atlas: Texture2D) -> StandardMaterial3D:
	if atlas == null:
		if _placeholder == null:
			_placeholder = StandardMaterial3D.new()
			_placeholder.albedo_color = RSUi.SURFACE
			_placeholder.roughness = 0.8
		return _placeholder
	if not _advertising.has(atlas):
		var material := StandardMaterial3D.new()
		material.albedo_texture = atlas
		material.roughness = 0.8
		material.texture_repeat = false
		_advertising[atlas] = material
	return _advertising[atlas]


static func _rope_material() -> StandardMaterial3D:
	if _rope == null:
		_rope = StandardMaterial3D.new()
		_rope.albedo_color = Color(0.68, 0.64, 0.53)
		_rope.roughness = 1.0
	return _rope


static func _valid(spec: Bleacher) -> bool:
	return spec.rows > 0 and spec.seats_per_row > 0 and spec.seat_pitch > 0.0 and spec.row_depth > 0.0 and spec.row_rise >= 0.0


static func seat_transforms(xform: Transform3D, spec: Bleacher) -> Array[Transform3D]:
	var seats: Array[Transform3D] = []
	if not _valid(spec):
		return seats
	for row in spec.rows:
		for column in spec.seats_per_row:
			# Every Nth slot is an aisle, without shrinking the footprint or moving its neighbours.
			if spec.aisle_every > 0 and (column + 1) % spec.aisle_every == 0:
				continue
			var p := Vector3((column - (spec.seats_per_row - 1) * 0.5) * spec.seat_pitch,
					(row + 1) * spec.row_rise, -(row + 0.5) * spec.row_depth)
			seats.append(xform * Transform3D(Basis.IDENTITY, p))
	return seats


static func _parent_world(parent: Node3D) -> Transform3D:
	# Node3D.global_transform reports an error outside the scene tree; builders also work there.
	var world := parent.transform
	var node := parent
	while not node.top_level and node.get_parent() is Node3D:
		node = node.get_parent() as Node3D
		world = node.transform * world
	return world


static func bleacher(parent: Node3D, xform: Transform3D, spec: Bleacher) -> Node3D:
	var root := Node3D.new()
	root.name = &"Bleacher" # no-i18n
	root.transform = _parent_world(parent).affine_inverse() * xform
	parent.add_child(root)
	if not _valid(spec):
		return root
	var metal := _Batch.new()
	var risers := _Batch.new()
	var width := spec.seats_per_row * spec.seat_pitch
	var depth := spec.rows * spec.row_depth
	for row in spec.rows:
		var y := (row + 1) * spec.row_rise
		var z := -(row + 0.5) * spec.row_depth
		if spec.style == BleacherStyle.OUTDOOR_METAL:
			var deck := maxf(0.02, y - 0.08)
			metal.box(Vector3(0, deck - 0.02, z), Vector3(width, 0.04, spec.row_depth))
			for side: float in [-1.0, 1.0]:
				metal.bar(Vector3(side * width * 0.45, 0, z), Vector3(side * width * 0.45, deck, z), RAIL_RADIUS)
		else:
			var height := row * spec.row_rise
			risers.box(Vector3(0, height * 0.5, z), Vector3(width, height, spec.row_depth))
	# Side/rear safety rails share one metal mesh with the outdoor platforms and supports.
	for side: float in [-1.0, 1.0]:
		var a := Vector3(side * width * 0.5, spec.row_rise + 0.7, 0)
		var b := Vector3(a.x, spec.rows * spec.row_rise + 0.7, -depth)
		metal.bar(a, b, RAIL_RADIUS)
		metal.bar(Vector3(a.x, 0, 0), a, RAIL_RADIUS)
		metal.bar(Vector3(b.x, 0, -depth), b, RAIL_RADIUS)
	metal.bar(Vector3(-width * 0.5, spec.rows * spec.row_rise + 0.7, -depth),
			Vector3(width * 0.5, spec.rows * spec.row_rise + 0.7, -depth), RAIL_RADIUS)
	_add_mesh(root, &"Metal", metal.mesh(_scan("metal_plate"))) # no-i18n
	if risers.pieces > 0:
		var id := "concrete_wall_003" if spec.style == BleacherStyle.INDOOR_SEATS else "beam_wall_01" # no-i18n
		_add_mesh(root, &"Risers", risers.mesh(_scan(id))) # no-i18n
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _chair(spec)
	var seats := seat_transforms(Transform3D.IDENTITY, spec)
	mm.instance_count = seats.size()
	# Submit the actual row-major 3x4 instance buffer once. The headless backend stores
	# bulk buffers, but its individual transform setter/getter are unimplemented stubs.
	var buffer := PackedFloat32Array()
	buffer.resize(seats.size() * 12)
	for i: int in seats.size():
		var seat: Transform3D = seats[i]
		var offset: int = i * 12
		for row: int in 3:
			for column: int in 3:
				buffer[offset + row * 4 + column] = seat.basis[column][row]
			buffer[offset + row * 4 + 3] = seat.origin[row]
	mm.buffer = buffer
	var chairs := MultiMeshInstance3D.new()
	chairs.name = &"Seats" # no-i18n
	chairs.multimesh = mm
	root.add_child(chairs)
	return root


static func _chair(spec: Bleacher) -> ArrayMesh:
	var plastic := _Batch.new()
	var frame := _Batch.new()
	var width := minf(0.44, spec.seat_pitch * 0.9)
	var depth := minf(0.44, spec.row_depth * 0.65)
	plastic.box(Vector3(0, -0.025, 0), Vector3(width, 0.05, depth))
	if spec.style == BleacherStyle.OUTDOOR_METAL:
		frame.box(Vector3(0, -0.065, 0), Vector3(width * 0.6, 0.03, depth * 0.6))
	else:
		plastic.box(Vector3(0, 0.16, -depth * 0.5), Vector3(width, 0.32, 0.04))
		var leg := maxf(0.05, spec.row_rise)
		for side: float in [-1.0, 1.0]:
			if spec.style == BleacherStyle.RINGSIDE_CHAIRS:
				frame.bar(Vector3(side * width * 0.4, -leg, -depth * 0.45), Vector3(side * width * 0.4, -0.04, depth * 0.4), 0.012)
				frame.bar(Vector3(side * width * 0.4, -leg, depth * 0.45), Vector3(side * width * 0.4, 0.28, -depth * 0.5), 0.012)
			else:
				frame.box(Vector3(side * width * 0.35, -leg * 0.5, 0), Vector3(0.03, leg, depth * 0.6))
	return frame.mesh(_scan("metal_plate"), plastic.mesh(_plastic(spec.seat_color))) # no-i18n


static func _add_mesh(parent: Node3D, label: StringName, mesh: ArrayMesh) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = mesh
	parent.add_child(node)
	return node


static func _segment(a: Vector3, b: Vector3) -> Transform3D:
	var x := (b - a).normalized()
	if x.length_squared() < EPS:
		return Transform3D(Basis.IDENTITY, a)
	var up := Vector3.UP if absf(x.y) < 0.99 else Vector3.FORWARD
	var z := x.cross(up).normalized()
	return Transform3D(Basis(x, z.cross(x), z), (a + b) * 0.5)


static func fence(parent: Node3D, path: PackedVector3Array, height: float, style: FenceStyle) -> Node3D:
	var root := Node3D.new()
	root.name = &"Fence" # no-i18n
	parent.add_child(root)
	for i in maxi(0, path.size() - 1):
		var metal := _Batch.new()
		var other := _Batch.new()
		var length := path[i].distance_to(path[i + 1])
		if length > EPS and height > 0.0:
			var count := maxi(1, ceili(length / FENCE_POST_PITCH))
			for j in count + 1:
				var x := -length * 0.5 + length * j / count
				metal.bar(Vector3(x, 0, 0), Vector3(x, height, 0), RAIL_RADIUS)
			if style == FenceStyle.LOW_BOARD:
				other.box(Vector3(0, height * 0.5, -0.03), Vector3(length, height, 0.06))
			elif style == FenceStyle.ROPE:
				for j in 3:
					other.bar(Vector3(-length * 0.5, height * (j + 1) / 3.0, 0), Vector3(length * 0.5, height * (j + 1) / 3.0, 0), 0.012)
			else:
				_chainlink(metal, length, height)
				metal.bar(Vector3(-length * 0.5, height, 0), Vector3(length * 0.5, height, 0), RAIL_RADIUS)
		var mesh := metal.mesh(_scan("metal_plate")) # no-i18n
		if other.pieces > 0:
			mesh = other.mesh(_rope_material() if style == FenceStyle.ROPE else _scan("beam_wall_01"), mesh) # no-i18n
		var segment := _add_mesh(root, StringName("Segment%d" % i), mesh) # no-i18n
		segment.transform = _segment(path[i], path[i + 1])
	return root


static func _chainlink(batch: _Batch, length: float, height: float) -> void:
	for direction: float in [-1.0, 1.0]:
		for i in ceili((length + height) / CHAIN_PITCH) + 1:
			var start := -length * 0.5 + i * CHAIN_PITCH - (height if direction > 0.0 else 0.0)
			var lo := maxf(0.0, -length * 0.5 - start) if direction > 0.0 else maxf(0.0, start - length * 0.5)
			var hi := minf(height, length * 0.5 - start) if direction > 0.0 else minf(height, start + length * 0.5)
			if hi > lo:
				batch.bar(Vector3(start + direction * lo, lo, 0), Vector3(start + direction * hi, hi, 0), WIRE_RADIUS)


static func ad_boards(parent: Node3D, path: PackedVector3Array, width: float, height: float,
		atlas: Texture2D = null, slots := 1) -> Node3D:
	var root := Node3D.new()
	root.name = &"AdBoards" # no-i18n
	parent.add_child(root)
	var board := 0
	slots = maxi(1, slots)
	for i in maxi(0, path.size() - 1):
		var backing := _Batch.new()
		var faces := _Batch.new()
		var length := path[i].distance_to(path[i + 1])
		if width > EPS and height > 0.0:
			for j in floori((length + EPS) / width):
				var left := -length * 0.5 + j * width
				var right := left + width
				backing.box(Vector3((left + right) * 0.5, height * 0.5, -0.03), Vector3(width, height, 0.06))
				var u0 := float(board % slots) / slots
				var u1 := float(board % slots + 1) / slots
				faces.quad(Vector3(left, 0, 0.001), Vector3(left, height, 0.001),
						Vector3(right, height, 0.001), Vector3(right, 0, 0.001), u0, u1)
				board += 1
		var mesh := faces.mesh(_ad_material(atlas), backing.mesh(_scan("beam_wall_01"))) # no-i18n
		var segment := _add_mesh(root, StringName("Segment%d" % i), mesh) # no-i18n
		segment.transform = _segment(path[i], path[i + 1])
	return root


static func triangle_count(root: Node3D) -> int:
	var total := 0
	if root is MeshInstance3D:
		total += _mesh_triangles((root as MeshInstance3D).mesh)
	elif root is MultiMeshInstance3D:
		var mm := (root as MultiMeshInstance3D).multimesh
		if mm != null:
			total += _mesh_triangles(mm.mesh) * mm.instance_count
	for child: Node in root.get_children():
		if child is Node3D:
			total += triangle_count(child as Node3D)
	return total


static func _mesh_triangles(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for i in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(i)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var count := vertices.size()
		if arrays[Mesh.ARRAY_INDEX] != null:
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if not indices.is_empty():
				count = indices.size()
		var primitive := Mesh.PRIMITIVE_TRIANGLES
		if mesh is ArrayMesh:
			primitive = (mesh as ArrayMesh).surface_get_primitive_type(i)
		if primitive == Mesh.PRIMITIVE_TRIANGLES:
			total += count / 3
		elif primitive == Mesh.PRIMITIVE_TRIANGLE_STRIP:
			total += maxi(0, count - 2)
	return total
