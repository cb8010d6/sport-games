class_name RSGolfSurface
extends RefCounted
## Baked coarse terrain only. A preserves the legacy 2.5 m grid, edge bias and both normals.
## The sampler is construction-only: no callback, array creation or formula in runtime queries.

const CELL := 2.5  ## coarse cells, m; green refinement is a later slice
const QUERY_NORMAL_STEP := 0.35  ## legacy query normal stencil, m

var origin: Vector2:
	get:
		return _origin
var cells: Vector2i:
	get:
		return _cells
var _origin := Vector2.ZERO
var _cells := Vector2i.ZERO
var _width := 0
var _height := 0
var _h := PackedFloat32Array()


func build(at: Vector2, cell_count: Vector2i, sample_height: Callable) -> void:
	assert(at.is_finite() and cell_count.x > 0 and cell_count.y > 0 and sample_height.is_valid(), "Valid terrain domain and sampler required")
	_origin = at
	_cells = cell_count
	_width = _cells.x + 1
	_height = _cells.y + 1
	_h.resize(_width * _height)
	for j in _height:
		for i in _width:
			var x := _origin.x + i * CELL
			var z := _origin.y + j * CELL
			var y: float = sample_height.call(x, z)
			assert(is_finite(y), "Terrain sample must be finite")
			_h[j * _width + i] = y
	# sample_height is deliberately not stored; a bound sampler cannot keep its owner alive.


func height_at(x: float, z: float) -> float:
	var fx := clampf((x - _origin.x) / CELL, 0.0, _width - 1.001)
	var fz := clampf((z - _origin.y) / CELL, 0.0, _height - 1.001)
	var i := int(fx)
	var j := int(fz)
	var u := fx - i
	var v := fz - j
	var k := j * _width + i
	# Same original diagonal and arithmetic order as the emitted mesh.
	var h00 := _h[k]
	var h10 := _h[k + 1]
	var h01 := _h[k + _width]
	var h11 := _h[k + _width + 1]
	if u + v <= 1.0:
		return h00 + (h10 - h00) * u + (h01 - h00) * v
	return h11 + (h01 - h11) * (1.0 - u) + (h10 - h11) * (1.0 - v)


func normal_at(x: float, z: float) -> Vector3:
	var e := QUERY_NORMAL_STEP
	var dx := height_at(x + e, z) - height_at(x - e, z)
	var dz := height_at(x, z + e) - height_at(x, z - e)
	return Vector3(-dx, 2.0 * e, -dz).normalized()


func geometric_normal_at(x: float, z: float) -> Vector3:
	## Upward face normal; distinct from both the legacy query and shading normals.
	var fx := clampf((x - _origin.x) / CELL, 0.0, _width - 1.001)
	var fz := clampf((z - _origin.y) / CELL, 0.0, _height - 1.001)
	var i := int(fx)
	var j := int(fz)
	var k := j * _width + i
	if fx - i + fz - j <= 1.0:
		return Vector3(_h[k] - _h[k + 1], CELL, _h[k] - _h[k + _width]).normalized()
	return Vector3(_h[k + _width] - _h[k + _width + 1], CELL, _h[k + 1] - _h[k + _width + 1]).normalized()


func contains_xz(x: float, z: float) -> bool:
	return x >= _origin.x and z >= _origin.y and x <= _origin.x + _cells.x * CELL and z <= _origin.y + _cells.y * CELL


func chunk_mesh(region: Rect2i) -> ArrayMesh:
	assert(region.position.x >= 0 and region.position.y >= 0 and region.size.x > 0 and region.size.y > 0 and region.end.x <= _cells.x and region.end.y <= _cells.y, "Chunk must contain valid cells")
	var i0 := region.position.x
	var j0 := region.position.y
	var i1 := region.end.x
	var j1 := region.end.y
	var w := i1 - i0 + 1
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	verts.resize(w * (j1 - j0 + 1))
	norms.resize(verts.size())
	var n := 0
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var x := _origin.x + i * CELL
			var z := _origin.y + j * CELL
			verts[n] = Vector3(x, _h[j * _width + i], z)
			var hl := _h[j * _width + maxi(i - 1, 0)]
			var hr := _h[j * _width + mini(i + 1, _width - 1)]
			var hd := _h[maxi(j - 1, 0) * _width + i]
			var hu := _h[mini(j + 1, _height - 1) * _width + i]
			norms[n] = Vector3(hl - hr, 2.0 * CELL, hd - hu).normalized()
			n += 1
	var idx := PackedInt32Array()
	for j in range(j1 - j0):
		for i in range(w - 1):
			var a := j * w + i
			idx.append_array([a, a + 1, a + w, a + 1, a + w + 1, a + w])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
