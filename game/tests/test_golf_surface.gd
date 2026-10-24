extends Node
## B: emitted topology, independent barycentric queries, and engine static-mesh raycasts.

const EPS := 0.001  ## m; numerical contract compares NEW queries against NEW emitted triangles
const NORMAL_EPS := 0.00001
const MESH_NORMAL_EPS := 12.0 / 65535.0  ## conservative octahedral UNORM16 roundtrip allowance
const GOLDEN := "res://tests/data/golf_surface_coarse.json"  ## A evidence remains unchanged
const EXPECTED_TRIANGLES := [257730, 207920]
const EXPECTED_CHUNKS := [54, 42]
const PATCHES := [[Rect2i(85, 81, 18, 18), Rect2i(145, 120, 17, 16), Rect2i(179, 315, 19, 18)],
	[Rect2i(89, 59, 18, 18), Rect2i(120, 237, 18, 18), Rect2i(183, 176, 16, 16)]]
const ADJACENT := [Vector2i(1, 0), Vector2i(2, 1), Vector2i(1, 2), Vector2i(0, 1)]

class Sampler extends RefCounted:
	var calls := 0
	var mode := 0

	func sample(x: float, z: float) -> float:
		calls += 1
		if mode == 0:
			return 10.0 if x > 0.0 and z > 0.0 else 0.0
		if mode == 1:
			return 2.0 * x - 3.0 * z + 7.0
		return sin(x * 0.13) * 2.0 + z * z * 0.1

var _checks := 0
var _failures := 0
var _triangle_queries := 0
var _ray_queries := 0
var _max_height_error := 0.0
var _max_normal_error := 0.0
var _max_mesh_normal_error := 0.0
var _max_vertex_normal_error := 0.0


func _ready() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("FAIL: " + message)


func _run() -> void:
	var invalid := OS.get_environment("RS_GOLF_SURFACE_INVALID")
	if not invalid.is_empty():
		_invalid_case(invalid)
		print("RS_GOLF_SURFACE_REJECTION: %d checks, %d failures" % [_checks, _failures])
		get_tree().quit(1)
		return
	_normal_codec()
	_pure_surface()
	await _topology_cases()
	var golden: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN))
	for expected: Dictionary in golden["maps"]:
		var course := RSGolfCourse.new(int(expected["map"]))
		add_child(course)
		var meshes := _course_samples(course, expected)
		await _raycasts(course.surface, meshes, _ray_points(course.surface))
		course.queue_free()
		await get_tree().process_frame
	print("RS_GOLF_SURFACE_TRIANGLES: %d queries, %d engine rays, max height error %.9f m, max face normal error %.9f" % [_triangle_queries, _ray_queries, _max_height_error, _max_normal_error])
	print("RS_GOLF_SURFACE_MESH_NORMAL: max vertex codec distance %.9f, max interpolated mesh/query distance %.9f" % [_max_vertex_normal_error, _max_mesh_normal_error])
	print("RS_GOLF_SURFACE_TESTS: %d checks, %d failures" % [_checks, _failures])
	await get_tree().create_timer(0.35).timeout
	get_tree().quit(1 if _failures else 0)


func _normal_codec() -> void:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	for x in [-4, -1, 0, 1, 4]:
		for z in [-4, -1, 0, 1, 4]:
			vertices.append_array(PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.BACK]))
			var normal := Vector3(x, 1, z).normalized()
			normals.append_array(PackedVector3Array([normal, normal, normal]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var returned: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	var codec_matches := true
	var max_error := 0.0
	for i in normals.size():
		codec_matches = codec_matches and returned[i] == _oct16(normals[i])
		max_error = maxf(max_error, normals[i].distance_to(returned[i]))
	_check(codec_matches and max_error <= MESH_NORMAL_EPS, "actual ArrayMesh normal roundtrip matches explicit octahedral UNORM16 codec")
	print("RS_GOLF_SURFACE_NORMAL_CODEC: max unit normal roundtrip distance %.9f" % max_error)


func _oct16(normal: Vector3) -> Vector3:
	# Keep the multiplication in float32 Vector2 components, like the native mesh codec.
	var scaled := normal.octahedron_encode() * 65535.0
	return Vector3.octahedron_decode(Vector2(floorf(scaled.x), floorf(scaled.y)) / 65535.0)


func _pure_surface() -> void:
	var sampler := Sampler.new()
	var surface := RSGolfSurface.new()
	_check(surface.build(Vector2.ZERO, Vector2i.ONE, sampler.sample), "coarse construction succeeds")
	_check(sampler.calls == 4 and surface.vertex_count == 4, "one callback per canonical vertex")
	_check(surface.height_at(0.625, 0.625) == 0.0 and surface.height_at(1.875, 1.875) == 5.0, "ABC0 D10 selects original diagonal, not bilinear")
	_check(surface.geometric_normal_at(0.625, 0.625) == Vector3.UP and surface.geometric_normal_at(1.875, 1.875).distance_to(Vector3(-4, 1, -4).normalized()) < NORMAL_EPS, "noncoplanar upward face normals")
	_check(surface.height_at(2.5, 2.5) == 10.0 and surface.height_at(100, 100) == 10.0, "exact closed maximum replaces A edge bias")
	_check(surface.triangle_at(2.5, 2.5) >= 0 and surface.triangle_at(2.5001, 1) == -1 and surface.triangle_at(-0.0001, 1) == -1, "triangle domain excludes outside without inventing geometry")
	var mesh := surface.chunk_mesh(Rect2i(0, 0, 1, 1))
	_check_mesh(surface, mesh)
	_topology(surface, mesh)
	_smooth_normals(surface, mesh)
	_check(surface.normal_at(0.625, 0.625).distance_to(Vector3.UP) > 0.05, "smooth query now follows global area normals, not A stencil")
	_check(sampler.calls == 4, "queries and mesh never call sampler")
	var reference: WeakRef = weakref(sampler)
	sampler = null
	_check(reference.get_ref() == null, "no retained sampler owner")
	var plane := Sampler.new()
	plane.mode = 1
	_check(surface.build(Vector2(10, -20), Vector2i(4, 3), plane.sample), "rebuild succeeds")
	_check(plane.calls == 20 and surface.origin == Vector2(10, -20) and surface.cells == Vector2i(4, 3), "rebuild replaces canonical cache")
	_check(absf(surface.height_at(12.5, -17.5) - 84.5) < EPS, "analytical plane height")
	var up := Vector3(-2, 1, 3).normalized()
	_check(surface.normal_at(10, -20).distance_to(up) < NORMAL_EPS and surface.geometric_normal_at(12.5, -17.5).distance_to(up) < NORMAL_EPS, "analytical plane normals include exact outer corner")
	_check_mesh(surface, surface.chunk_mesh(Rect2i(0, 0, 4, 3)))
	_check(plane.calls == surface.vertex_count, "rebuild runtime never resamples")


func _topology_cases() -> void:
	var sample := Sampler.new()
	sample.mode = 2
	for mask in 16:
		var patches: Array[Rect2i] = []
		var neighbours := 0
		for edge in 4:
			if mask & (1 << edge):
				patches.append(Rect2i(ADJACENT[edge], Vector2i.ONE))
				neighbours += 1
		var surface := RSGolfSurface.new()
		var before := sample.calls
		_check(surface.build(Vector2.ZERO, Vector2i(3, 3), sample.sample, patches), "neighbour mask builds")
		_check(surface.cell_triangles(Vector2i.ONE).y == (2 if neighbours == 0 else 4 + 4 * neighbours), "central fan count for all16 masks")
		_check(sample.calls - before == surface.vertex_count, "fine and fan vertices sampled once")
		var mesh := surface.chunk_mesh(Rect2i(0, 0, 3, 3))
		_check_mesh(surface, mesh)
		_topology(surface, mesh)
		_smooth_normals(surface, mesh)
		await _raycasts(surface, [mesh], _ray_points(surface))
	var diagonal := RSGolfSurface.new()
	diagonal.build(Vector2.ZERO, Vector2i(3, 3), sample.sample, [Rect2i(0, 0, 1, 1)])
	_check(diagonal.cell_triangles(Vector2i.ONE).y == 2, "diagonal-only neighbour has no fan")
	_topology(diagonal, diagonal.chunk_mesh(Rect2i(0, 0, 3, 3)))
	var overlap := RSGolfSurface.new()
	var patches: Array[Rect2i] = [Rect2i(0, 0, 2, 2), Rect2i(1, 1, 2, 2)]
	overlap.build(Vector2.ZERO, Vector2i(3, 3), sample.sample, patches)
	var mesh := overlap.chunk_mesh(Rect2i(0, 0, 3, 3))
	_check(overlap.triangle_count == 374, "overlap union has7 fine cells and2 two-edge fans")
	_topology(overlap, mesh)
	patches.append(patches[0])
	var duplicate := RSGolfSurface.new()
	duplicate.build(Vector2.ZERO, Vector2i(3, 3), sample.sample, patches)
	_check(mesh.surface_get_arrays(0) == duplicate.chunk_mesh(Rect2i(0, 0, 3, 3)).surface_get_arrays(0), "duplicate patches do not change canonical data")
	var seam := RSGolfSurface.new()
	seam.build(Vector2.ZERO, Vector2i(50, 3), sample.sample, [Rect2i(47, 1, 2, 1)])
	var left := seam.chunk_mesh(Rect2i(0, 0, 48, 3))
	var right := seam.chunk_mesh(Rect2i(48, 0, 2, 3))
	var boundary: Dictionary = {}
	var arrays := left.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i in vertices.size():
		if vertices[i].x == 120.0:
			boundary[vertices[i].z] = [vertices[i], normals[i]]
	arrays = right.surface_get_arrays(0)
	vertices = arrays[Mesh.ARRAY_VERTEX]
	normals = arrays[Mesh.ARRAY_NORMAL]
	for i in vertices.size():
		if vertices[i].x == 120.0:
			_check(boundary.has(vertices[i].z) and boundary[vertices[i].z][0] == vertices[i] and boundary[vertices[i].z][1] == normals[i], "chunk48 canonical positions and global normals identical")
	_check_mesh(seam, left)
	_check_mesh(seam, right)
	_topology(seam, seam.chunk_mesh(Rect2i(0, 0, 50, 3)))
	await _raycasts(seam, [left, right], [Vector2(120, 3.75), Vector2(119.5, 2.5), Vector2(120.5, 5)])


func _course_samples(course: RSGolfCourse, expected: Dictionary) -> Array[ArrayMesh]:
	var surface := course.surface
	_check(surface.origin == Vector2(expected["origin"][0], expected["origin"][1]) and surface.cells + Vector2i.ONE == Vector2i(expected["vertices_size"][0], expected["vertices_size"][1]), "A origin/domain unchanged")
	_check(course._green_patches(surface.cells) == PATCHES[course.map_index], "coarse-aligned green coverage masks")
	var unchanged := 0
	for row: Array in expected["queries"]:
		var cell := Vector2i(floori((row[0] - surface.origin.x) / surface.CELL), floori((row[1] - surface.origin.y) / surface.CELL))
		if surface.cell_triangles(cell).y == 2:
			_check(absf(surface.height_at(row[0], row[1]) - float(row[2])) <= EPS, "A interior coarse height unchanged outside patches/fans")
			unchanged += 1
	_check(unchanged >= 20, "substantial unchanged A sample coverage")
	for index in course.holes.size():
		var hole: Dictionary = course.holes[index]
		var tee: Array = expected["queries"][index * 3]
		var pin: Array = expected["queries"][index * 3 + 1]
		var green: Array = expected["queries"][index * 3 + 2]
		_check(hole["tee2"] == Vector2(tee[0], tee[1]) and hole["pin2"] == Vector2(pin[0], pin[1]) and hole["green_c"] == Vector2(green[0], green[1]), "hole XZ anchors match independent A golden")
	for patch: Rect2i in course._green_patches(surface.cells):
		for j in range(patch.position.y, patch.end.y):
			for i in range(patch.position.x, patch.end.x):
				_check(surface.cell_triangles(Vector2i(i, j)).y == 50, "every green patch cell has5x5 fine quads")
	var meshes: Array[ArrayMesh] = []
	var triangles := 0
	for child: Node in course.get_children():
		var instance := child as MeshInstance3D
		if instance == null:
			continue
		var material := instance.material_override as ShaderMaterial
		if material != null and material.shader.resource_path == "res://shaders/golf_terrain.gdshader":
			var mesh := instance.mesh as ArrayMesh
			meshes.append(mesh)
			triangles += mesh.surface_get_array_index_len(0) / 3
			_check_mesh(surface, mesh)
	_check(meshes.size() == EXPECTED_CHUNKS[course.map_index] and triangles == EXPECTED_TRIANGLES[course.map_index] and surface.triangle_count == triangles, "measured map chunk/triangle budget")
	_emitted_normal_codec(surface, meshes)
	return meshes


func _emitted_normal_codec(surface: RSGolfSurface, meshes: Array[ArrayMesh]) -> void:
	var sources: Dictionary = {}
	for i in surface.vertex_count:
		sources[surface._vertices[i]] = surface._normals[i]
	var exact := true
	for mesh: ArrayMesh in meshes:
		var arrays := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in vertices.size():
			var source: Vector3 = sources[vertices[i]]
			exact = exact and normals[i] == _oct16(source)
			_max_vertex_normal_error = maxf(_max_vertex_normal_error, source.distance_to(normals[i]))
	_check(exact and _max_vertex_normal_error <= MESH_NORMAL_EPS, "all actual map/chunk normals exactly match explicit cache-to-mesh codec")


func _check_mesh(surface: RSGolfSurface, mesh: ArrayMesh) -> void:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var max_error := 0.0
	var max_normal_error := 0.0
	var smooth_error := 0.0
	var positive_area := true
	for i in range(0, indices.size(), 3):
		var a := vertices[indices[i]]
		var b := vertices[indices[i + 1]]
		var c := vertices[indices[i + 2]]
		var p := a * 0.2 + b * 0.3 + c * 0.5
		var area := (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
		positive_area = positive_area and area > 0.0
		# Independent plane/barycentric calculation from actual emitted triangle vertices.
		var u := ((p.x - a.x) * (c.z - a.z) - (c.x - a.x) * (p.z - a.z)) / area
		var v := ((b.x - a.x) * (p.z - a.z) - (p.x - a.x) * (b.z - a.z)) / area
		var expected_y := a.y + (b.y - a.y) * u + (c.y - a.y) * v
		max_error = maxf(max_error, absf(surface.height_at(p.x, p.z) - expected_y))
		max_normal_error = maxf(max_normal_error, (c - a).cross(b - a).normalized().distance_to(surface.geometric_normal_at(p.x, p.z)))
		var smooth := (normals[indices[i]] * (1.0 - u - v) + normals[indices[i + 1]] * u + normals[indices[i + 2]] * v).normalized()
		smooth_error = maxf(smooth_error, smooth.distance_to(surface.normal_at(p.x, p.z)))
		var triangle := surface.triangle_at(p.x, p.z)
		positive_area = positive_area and triangle >= 0 and surface.triangle_vertex(triangle, 0) == a and surface.triangle_vertex(triangle, 1) == b and surface.triangle_vertex(triangle, 2) == c
		_triangle_queries += 1
	_max_height_error = maxf(_max_height_error, max_error)
	_max_normal_error = maxf(_max_normal_error, max_normal_error)
	_max_mesh_normal_error = maxf(_max_mesh_normal_error, smooth_error)
	_check(positive_area, "positive winding and real triangle access agree")
	_check(max_error <= EPS, "every emitted triangle barycentric height within1mm")
	_check(max_normal_error <= NORMAL_EPS and smooth_error <= MESH_NORMAL_EPS, "face normal semantics and decoded mesh normal codec allowance")


func _key(vertex: Vector3) -> Vector2i:
	return Vector2i(roundi(vertex.x / 0.25), roundi(vertex.z / 0.25))


func _topology(surface: RSGolfSurface, mesh: ArrayMesh) -> void:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var edges: Dictionary = {}
	var area := 0.0
	for i in range(0, indices.size(), 3):
		var a := vertices[indices[i]]
		var b := vertices[indices[i + 1]]
		var c := vertices[indices[i + 2]]
		area += (c - a).cross(b - a).y * 0.5
		for e in 3:
			var first := _key(vertices[indices[i + e]])
			var last := _key(vertices[indices[i + (e + 1) % 3]])
			if first.x > last.x or (first.x == last.x and first.y > last.y):
				var swap := first
				first = last
				last = swap
			var edge := Vector4i(first.x, first.y, last.x, last.y)
			edges[edge] = int(edges.get(edge, 0)) + 1
	var welded := true
	var end := surface.origin + Vector2(surface.cells) * surface.CELL
	for edge: Vector4i in edges:
		var boundary := (edge.x == edge.z and (edge.x * 0.25 == surface.origin.x or edge.x * 0.25 == end.x)) or (edge.y == edge.w and (edge.y * 0.25 == surface.origin.y or edge.y * 0.25 == end.y))
		welded = welded and int(edges[edge]) == (1 if boundary else 2)
	_check(welded, "independent emitted-edge counts have no cracks/T-junctions/nonmanifold edges")
	_check(absf(area - surface.cells.x * surface.cells.y * surface.CELL * surface.CELL) <= EPS, "full projected area without holes or overlap")


func _smooth_normals(surface: RSGolfSurface, mesh: ArrayMesh) -> void:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var sums: Dictionary = {}
	for i in range(0, indices.size(), 3):
		var a := vertices[indices[i]]
		var b := vertices[indices[i + 1]]
		var c := vertices[indices[i + 2]]
		var area := (c - a).cross(b - a)
		for e in 3:
			var key := _key(vertices[indices[i + e]])
			sums[key] = (sums.get(key, Vector3.ZERO) as Vector3) + area
	var correct := true
	for i in vertices.size():
		var expected: Vector3 = sums[_key(vertices[i])]
		correct = correct and normals[i].distance_to(expected.normalized()) <= MESH_NORMAL_EPS
		correct = correct and surface.normal_at(vertices[i].x, vertices[i].z).distance_to(expected.normalized()) <= NORMAL_EPS
	_check(correct, "global area normals independently reconstructed from emitted faces")


func _ray_points(surface: RSGolfSurface) -> Array[Vector2]:
	var points: Array[Vector2] = []
	var kinds: Dictionary = {}
	for j in surface.cells.y:
		for i in surface.cells.x:
			var kind := surface.cell_triangles(Vector2i(i, j)).y
			if not kinds.has(kind):
				kinds[kind] = true
				points.append(surface.origin + Vector2(i + 0.27, j + 0.63) * surface.CELL)
	points.append(surface.origin + Vector2(0.002, 0.002))
	points.append(surface.origin + Vector2(surface.cells) * surface.CELL - Vector2(0.002, 0.002))
	return points


func _raycasts(surface: RSGolfSurface, meshes: Array[ArrayMesh], points: Array[Vector2]) -> void:
	var faces := PackedVector3Array()
	var lowest := INF
	var highest := -INF
	for mesh: ArrayMesh in meshes:
		var arrays := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for index: int in indices:
			faces.append(vertices[index])
			lowest = minf(lowest, vertices[index].y)
			highest = maxf(highest, vertices[index].y)
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	var collision := CollisionShape3D.new()
	collision.shape = shape
	var body := StaticBody3D.new()
	body.add_child(collision)
	add_child(body)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := body.get_world_3d().direct_space_state
	for point: Vector2 in points:
		var ray := PhysicsRayQueryParameters3D.create(Vector3(point.x, highest + 1.0, point.y), Vector3(point.x, lowest - 1.0, point.y))
		var hit := space.intersect_ray(ray)
		_check(not hit.is_empty() and absf((hit["position"] as Vector3).y - surface.height_at(point.x, point.y)) <= EPS, "engine vertical raycast matches emitted query within1mm")
		_ray_queries += 1
	body.queue_free()
	await get_tree().process_frame


func _invalid_case(kind: String) -> void:
	var surface := RSGolfSurface.new()
	var sampler := Sampler.new()
	if kind == "unbuilt":
		_check(is_nan(surface.height_at(0, 0)), "unbuilt query fails visibly")
		return
	surface.build(Vector2.ZERO, Vector2i.ONE, sampler.sample)
	match kind:
		"nan-query":
			_check(is_nan(surface.height_at(NAN, 0)), "NaN query rejected")
		"inf-query":
			_check(surface.triangle_at(INF, 0) == -1, "infinite query rejected")
		"bad-cell":
			_check(surface.cell_triangles(Vector2i(-1, 0)) == Vector2i(-1, 0), "invalid cell rejected")
		"bad-triangle":
			_check(not surface.triangle_vertex(999, 0).is_finite(), "invalid triangle rejected")
		"bad-chunk":
			_check(surface.chunk_mesh(Rect2i(0, 0, 2, 1)) == null, "invalid chunk rejected")
		"bad-patch":
			_check(not surface.build(Vector2.ZERO, Vector2i.ONE, sampler.sample, [Rect2i(-1, 0, 1, 1)]) and not surface.contains_xz(0, 0), "invalid rebuild cannot expose old surface")
		"overflow-patch":
			_check(not surface.build(Vector2.ZERO, Vector2i.ONE, sampler.sample, [Rect2i(2147483600, 0, 100, 1)]) and surface.triangle_count == 0, "rectangle overflow rejected before iteration")
		"huge-domain":
			_check(not surface.build(Vector2(1e20, 0), Vector2i.ONE, sampler.sample) and surface.triangle_count == 0, "unsafe coordinate precision rejected")
		"inf-domain":
			_check(not surface.build(Vector2(INF, 0), Vector2i.ONE, sampler.sample) and surface.vertex_count == 0, "infinite domain rejected")
		"nan-sample":
			_check(not surface.build(Vector2.ZERO, Vector2i.ONE, _nan_sample) and surface.vertex_count == 0, "nonfinite height clears incomplete surface")


func _nan_sample(_x: float, _z: float) -> float:
	return NAN
