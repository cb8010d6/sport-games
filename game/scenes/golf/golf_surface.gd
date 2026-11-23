class_name RSGolfSurface
extends RefCounted
## One conforming triangulation for rendered terrain, height, smooth normals and face access.
## Canonical quarter-metre keys are construction-only; runtime queries read packed caches.

const CELL := 2.5  ## coarse cells, m
const KEY_STEP := 0.25  ## fine edge step = 2 keys; fan centre = (5, 5) keys
const COARSE_KEYS := 10
const FINE_KEYS := 2
const EDGE_EPS := 0.000001  ## barycentric containment tolerance
const MAX_COORD := 4096.0  ## float32 vertex precision stays below 1 mm in this local domain
const MAX_BASE_CELLS := 250000
const MAX_TRIANGLES := 300000
const CORNERS := [Vector2i(0, 0), Vector2i(10, 0), Vector2i(10, 10), Vector2i(0, 10)]
const NEIGHBOURS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]

var origin: Vector2:
	get:
		return _origin
var cells: Vector2i:
	get:
		return _cells
var triangle_count: int:
	get:
		return _faces.size()
var vertex_count: int:
	get:
		return _vertices.size()
var _origin := Vector2.ZERO
var _end := Vector2.ZERO
var _cells := Vector2i.ZERO
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _indices := PackedInt32Array()
var _faces := PackedVector3Array()
var _first := PackedInt32Array()
var _counts := PackedInt32Array()
var _built := false
var _failed := false


func build(at: Vector2, cell_count: Vector2i, sample_height: Callable, patches: Array[Rect2i] = []) -> bool:
	_clear()
	var end_x := float(at.x) + float(cell_count.x) * CELL
	var end_z := float(at.y) + float(cell_count.y) * CELL
	if not at.is_finite() or cell_count.x <= 0 or cell_count.y <= 0 or cell_count.x * cell_count.y > MAX_BASE_CELLS or not sample_height.is_valid() or maxf(maxf(absf(at.x), absf(at.y)), maxf(absf(end_x), absf(end_z))) > MAX_COORD:
		push_error("RSGolfSurface: invalid terrain domain or sampler")
		return false
	_origin = at
	_end = Vector2(end_x, end_z)
	_cells = cell_count
	var fine := PackedByteArray()
	fine.resize(_cells.x * _cells.y)
	for patch: Rect2i in patches:
		if not _valid_region(patch):
			push_error("RSGolfSurface: invalid refinement patch")
			return false
		for j in range(patch.position.y, patch.end.y):
			for i in range(patch.position.x, patch.end.x):
				fine[j * _cells.x + i] = 1
	_first.resize(fine.size())
	_counts.resize(fine.size())
	var cache: Dictionary = {}
	for j in _cells.y:
		for i in _cells.x:
			var cell := Vector2i(i, j)
			var index := j * _cells.x + i
			var base := cell * COARSE_KEYS
			_first[index] = _faces.size()
			if fine[index]:
				for z in 5:
					for x in 5:
						_quad(base + Vector2i(x, z) * FINE_KEYS, FINE_KEYS, cache, sample_height)
			else:
				var mask := 0
				for edge in 4:
					var near: Vector2i = cell + NEIGHBOURS[edge]
					if near.x >= 0 and near.y >= 0 and near.x < _cells.x and near.y < _cells.y and fine[near.y * _cells.x + near.x]:
						mask |= 1 << edge
				if mask == 0:
					_quad(base, COARSE_KEYS, cache, sample_height)
				else:
					_fan(base, mask, cache, sample_height)
			_counts[index] = _faces.size() - _first[index]
			if _failed:
				_clear()
				return false
	for i in _normals.size():
		_normals[i] = _normals[i].normalized()
	_built = true
	return true  # Neither sampler nor canonical-key dictionary survives construction.


func _clear() -> void:
	_built = false
	_failed = false
	_vertices.clear()
	_normals.clear()
	_indices.clear()
	_faces.clear()
	_first.clear()
	_counts.clear()
	_cells = Vector2i.ZERO


func _vertex(key: Vector2i, cache: Dictionary, sampler: Callable) -> int:
	if _failed:
		return -1
	if cache.has(key):
		return int(cache[key])
	var x := _origin.x + key.x * KEY_STEP
	var z := _origin.y + key.y * KEY_STEP
	var y: float = sampler.call(x, z)
	if not is_finite(y) or absf(y) > MAX_COORD:
		_failed = true
		push_error("RSGolfSurface: invalid terrain sample")
		return -1
	var index := _vertices.size()
	cache[key] = index
	_vertices.append(Vector3(x, y, z))
	_normals.append(Vector3.ZERO)
	return index


func _quad(base: Vector2i, step: int, cache: Dictionary, sampler: Callable) -> void:
	var a := _vertex(base, cache, sampler)
	var b := _vertex(base + Vector2i(step, 0), cache, sampler)
	var c := _vertex(base + Vector2i(0, step), cache, sampler)
	var d := _vertex(base + Vector2i(step, step), cache, sampler)
	_triangle(a, b, c)
	_triangle(b, d, c)


func _fan(base: Vector2i, mask: int, cache: Dictionary, sampler: Callable) -> void:
	var centre := _vertex(base + Vector2i(5, 5), cache, sampler)
	for edge in 4:
		var start: Vector2i = base + CORNERS[edge]
		var delta: Vector2i = CORNERS[(edge + 1) % 4] - CORNERS[edge]
		var steps := 5 if mask & (1 << edge) else 1
		var previous := _vertex(start, cache, sampler)
		for k in range(1, steps + 1):
			var next := _vertex(start + delta * k / steps, cache, sampler)
			_triangle(centre, previous, next)
			previous = next


func _triangle(a: int, b: int, c: int) -> void:
	if _failed:
		return
	var area := (_vertices[c] - _vertices[a]).cross(_vertices[b] - _vertices[a])
	if area.y <= 0.0 or not area.is_finite() or _faces.size() >= MAX_TRIANGLES:
		_failed = true
		push_error("RSGolfSurface: invalid triangle or triangle budget exceeded")
		return
	_indices.append(a)
	_indices.append(b)
	_indices.append(c)
	_faces.append(area.normalized())
	_normals[a] += area
	_normals[b] += area
	_normals[c] += area


func contains_xz(x: float, z: float) -> bool:
	return _built and is_finite(x) and is_finite(z) and x >= _origin.x and z >= _origin.y and x <= _end.x and z <= _end.y


func triangle_at(x: float, z: float) -> int:
	return _locate(x, z, false)


func cell_triangles(cell: Vector2i) -> Vector2i:
	if not _built or cell.x < 0 or cell.y < 0 or cell.x >= _cells.x or cell.y >= _cells.y:
		push_error("RSGolfSurface: invalid cell query")
		return Vector2i(-1, 0)
	var index := cell.y * _cells.x + cell.x
	return Vector2i(_first[index], _counts[index])


func triangle_vertex(triangle: int, corner: int) -> Vector3:
	if not _built or triangle < 0 or triangle >= _faces.size() or corner < 0 or corner > 2:
		push_error("RSGolfSurface: invalid triangle query")
		return Vector3(NAN, NAN, NAN)
	return _vertices[_indices[triangle * 3 + corner]]


func height_at(x: float, z: float) -> float:
	var triangle := _locate(x, z, true)
	if triangle < 0:
		return NAN
	var w := _weights(triangle, clampf(x, _origin.x, _end.x), clampf(z, _origin.y, _end.y))
	var index := triangle * 3
	return _vertices[_indices[index]].y * w.x + _vertices[_indices[index + 1]].y * w.y + _vertices[_indices[index + 2]].y * w.z


func normal_at(x: float, z: float) -> Vector3:
	var triangle := _locate(x, z, true)
	if triangle < 0:
		return Vector3(NAN, NAN, NAN)
	var w := _weights(triangle, clampf(x, _origin.x, _end.x), clampf(z, _origin.y, _end.y))
	var index := triangle * 3
	return (_normals[_indices[index]] * w.x + _normals[_indices[index + 1]] * w.y + _normals[_indices[index + 2]] * w.z).normalized()


func geometric_normal_at(x: float, z: float) -> Vector3:
	var triangle := _locate(x, z, true)
	return _faces[triangle] if triangle >= 0 else Vector3(NAN, NAN, NAN)


func _locate(x: float, z: float, clamp_outside: bool) -> int:
	if not _built or not is_finite(x) or not is_finite(z):
		push_error("RSGolfSurface: query needs a built surface and finite coordinates")
		return -1
	if clamp_outside:
		x = clampf(x, _origin.x, _end.x)
		z = clampf(z, _origin.y, _end.y)
	elif not contains_xz(x, z):
		return -1
	var i := mini(floori((x - _origin.x) / CELL), _cells.x - 1)
	var j := mini(floori((z - _origin.y) / CELL), _cells.y - 1)
	var cell := j * _cells.x + i
	var triangle := _first[cell]
	var end := triangle + _counts[cell]
	while triangle < end:
		var w := _weights(triangle, x, z)
		if minf(w.x, minf(w.y, w.z)) >= -EDGE_EPS:
			return triangle
		triangle += 1
	push_error("RSGolfSurface: no emitted triangle contains query")
	return -1


func _weights(triangle: int, x: float, z: float) -> Vector3:
	var index := triangle * 3
	var a := _vertices[_indices[index]]
	var b := _vertices[_indices[index + 1]]
	var c := _vertices[_indices[index + 2]]
	var area := (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
	var u := ((x - a.x) * (c.z - a.z) - (c.x - a.x) * (z - a.z)) / area
	var v := ((b.x - a.x) * (z - a.z) - (x - a.x) * (b.z - a.z)) / area
	return Vector3(1.0 - u - v, u, v)


func _valid_region(region: Rect2i) -> bool:
	return region.position.x >= 0 and region.position.y >= 0 and region.size.x > 0 and region.size.y > 0 and region.size.x <= _cells.x and region.size.y <= _cells.y and region.position.x <= _cells.x - region.size.x and region.position.y <= _cells.y - region.size.y


func chunk_mesh(region: Rect2i) -> ArrayMesh:
	if not _built or not _valid_region(region):
		push_error("RSGolfSurface: invalid chunk query")
		return null
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var indices := PackedInt32Array()
	var local: Dictionary = {}
	for j in range(region.position.y, region.end.y):
		for i in range(region.position.x, region.end.x):
			var cell := j * _cells.x + i
			for k in range(_first[cell] * 3, (_first[cell] + _counts[cell]) * 3):
				var global := _indices[k]
				if not local.has(global):
					local[global] = verts.size()
					verts.append(_vertices[global])
					norms.append(_normals[global])
				indices.append(int(local[global]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
