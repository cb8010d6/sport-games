extends Node
## Coarse extraction: independent emitted-triangle queries and portable old-course samples.

const EPS := 0.0001  ## m / unit-normal distance; same-host full hashes are a separate audit
const GOLDEN := "res://tests/data/golf_surface_coarse.json"

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
var _max_height_error := 0.0
var _max_normal_error := 0.0


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
	_pure_surface()
	var golden: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN))
	for expected: Dictionary in golden["maps"]:
		var course := RSGolfCourse.new(int(expected["map"]))
		add_child(course)
		_course_samples(course, expected)
		course.queue_free()
		await get_tree().process_frame
	print("RS_GOLF_SURFACE_TRIANGLES: %d queries, max height error %.9f m, max face normal error %.9f" % [_triangle_queries, _max_height_error, _max_normal_error])
	print("RS_GOLF_SURFACE_TESTS: %d checks, %d failures" % [_checks, _failures])
	await get_tree().create_timer(0.35).timeout
	get_tree().quit(1 if _failures else 0)


func _pure_surface() -> void:
	var sampler := Sampler.new()
	var surface := RSGolfSurface.new()
	surface.build(Vector2.ZERO, Vector2i.ONE, sampler.sample)
	_check(sampler.calls == 4, "one callback per canonical vertex")
	_check(surface.height_at(0.625, 0.625) == 0.0 and surface.height_at(1.875, 1.875) == 5.0, "noncoplanar ABC0 D10 selects original diagonal")
	_check(surface.geometric_normal_at(0.625, 0.625) == Vector3.UP, "lower noncoplanar face normal")
	_check(surface.geometric_normal_at(1.875, 1.875).distance_to(Vector3(-4, 1, -4).normalized()) < EPS, "upper noncoplanar face normal")
	_check(absf(surface.height_at(2.5, 2.5) - 9.98) < EPS and surface.height_at(100, 100) == surface.height_at(2.5, 2.5), "legacy max-edge bias and outside clamp preserved")
	_check(surface.contains_xz(0, 0) and surface.contains_xz(2.5, 2.5) and not surface.contains_xz(2.5001, 1) and not surface.contains_xz(-0.0001, 1), "geometric domain includes edges, excludes outside")
	var mesh := surface.chunk_mesh(Rect2i(0, 0, 1, 1))
	var arrays := mesh.surface_get_arrays(0)
	_check(arrays[Mesh.ARRAY_INDEX] == PackedInt32Array([0, 1, 2, 1, 3, 2]), "original vertex order and winding")
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	_check(normals[3].distance_to(Vector3(-10, 5, -10).normalized()) < EPS and normals[3].distance_to(surface.normal_at(1.875, 1.875)) > 0.05, "legacy shading stencil remains distinct from query normal")
	_check_mesh(surface, mesh)
	_check(sampler.calls == 4, "mesh and all query types never call sampler")
	var reference: WeakRef = weakref(sampler)
	sampler = null
	_check(reference.get_ref() == null, "surface does not retain bound callback owner")
	var plane := Sampler.new()
	plane.mode = 1
	surface.build(Vector2(10, -20), Vector2i(4, 3), plane.sample)
	_check(plane.calls == 20 and surface.origin == Vector2(10, -20) and surface.cells == Vector2i(4, 3), "rebuild replaces grid, origin and samples")
	_check(absf(surface.height_at(12.5, -17.5) - 84.5) < EPS, "analytical plane height after rebuild")
	var up := Vector3(-2, 1, 3).normalized()
	_check(surface.normal_at(12.5, -17.5).distance_to(up) < EPS and surface.geometric_normal_at(12.5, -17.5).distance_to(up) < EPS, "analytical plane interior normals")
	_check_mesh(surface, surface.chunk_mesh(Rect2i(0, 0, 4, 3)))
	_check(plane.calls == 20, "rebuilt grid also has no runtime sampler calls")
	var nonlinear := Sampler.new()
	nonlinear.mode = 2
	surface.build(Vector2.ZERO, Vector2i(50, 3), nonlinear.sample)
	var left := surface.chunk_mesh(Rect2i(0, 0, 48, 3))
	var right := surface.chunk_mesh(Rect2i(48, 0, 2, 3))
	var la := left.surface_get_arrays(0)
	var ra := right.surface_get_arrays(0)
	var lv: PackedVector3Array = la[Mesh.ARRAY_VERTEX]
	var rv: PackedVector3Array = ra[Mesh.ARRAY_VERTEX]
	var ln: PackedVector3Array = la[Mesh.ARRAY_NORMAL]
	var rn: PackedVector3Array = ra[Mesh.ARRAY_NORMAL]
	for j in 4:
		_check(lv[j * 49 + 48] == rv[j * 3] and ln[j * 49 + 48] == rn[j * 3], "chunk48 duplicates identical global vertices and normals")
	_check_mesh(surface, left)
	_check_mesh(surface, right)
	_check(nonlinear.calls == 204, "chunk split does not resample shared border")


func _course_samples(course: RSGolfCourse, expected: Dictionary) -> void:
	_check(course.surface.origin == Vector2(expected["origin"][0], expected["origin"][1]), "old course origin unchanged")
	_check(course.surface.cells + Vector2i.ONE == Vector2i(expected["vertices_size"][0], expected["vertices_size"][1]), "old course dimensions unchanged")
	for row: Array in expected["queries"]:
		_check(absf(course.height_at(row[0], row[1]) - float(row[2])) <= EPS, "portable old height sample")
		_check(course.normal_at(row[0], row[1]).distance_to(Vector3(row[3], row[4], row[5])) <= EPS, "portable old query normal sample")
	var chunks: Array[MeshInstance3D] = []
	for child: Node in course.get_children():
		var instance := child as MeshInstance3D
		if instance == null:
			continue
		var material := instance.material_override as ShaderMaterial
		if material != null and material.shader.resource_path == "res://shaders/golf_terrain.gdshader":
			chunks.append(instance)
	_check(chunks.size() == expected["chunks"].size(), "old terrain chunk count")
	var triangles := 0
	for i in chunks.size():
		var mesh := chunks[i].mesh as ArrayMesh
		var arrays := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		_check(vertices.size() == int(expected["chunks"][i][0]) and indices.size() == int(expected["chunks"][i][1]) * 3, "old per-chunk vertex and triangle counts")
		triangles += indices.size() / 3
		_check_mesh(course.surface, mesh)
	_check(triangles == int(expected["triangles"]), "old total triangle count")
	for entry: Dictionary in expected["chunk_samples"]:
		var arrays := chunks[int(entry["chunk"])].mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for row: Array in entry["samples"]:
			_check(vertices[int(row[0])].distance_to(Vector3(row[1], row[2], row[3])) <= EPS, "portable old mesh vertex sample")
			_check(normals[int(row[0])].distance_to(Vector3(row[4], row[5], row[6])) <= EPS, "portable old shading normal sample")


func _check_mesh(surface: RSGolfSurface, mesh: ArrayMesh) -> void:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var max_error := 0.0
	var max_normal_error := 0.0
	var positive_area := true
	for i in range(0, indices.size(), 3):
		var a := vertices[indices[i]]
		var b := vertices[indices[i + 1]]
		var c := vertices[indices[i + 2]]
		var p := a * 0.2 + b * 0.3 + c * 0.5
		# Independent barycentric plane evaluation from emitted vertices, not grid addressing.
		var area := (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
		positive_area = positive_area and area > 0.0
		var u := ((p.x - a.x) * (c.z - a.z) - (c.x - a.x) * (p.z - a.z)) / area
		var v := ((b.x - a.x) * (p.z - a.z) - (p.x - a.x) * (b.z - a.z)) / area
		var expected_y := a.y + (b.y - a.y) * u + (c.y - a.y) * v
		max_error = maxf(max_error, absf(surface.height_at(p.x, p.z) - expected_y))
		var normal := (c - a).cross(b - a).normalized()
		max_normal_error = maxf(max_normal_error, normal.distance_to(surface.geometric_normal_at(p.x, p.z)))
		_triangle_queries += 1
	_max_height_error = maxf(_max_height_error, max_error)
	_max_normal_error = maxf(_max_normal_error, max_normal_error)
	_check(positive_area, "emitted triangles have positive projected area")
	_check(max_error <= EPS, "every emitted triangle agrees with independent barycentric height")
	_check(max_normal_error <= EPS, "every emitted triangle agrees with upward geometric normal")
