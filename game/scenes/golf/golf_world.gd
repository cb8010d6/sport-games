class_name RSGolfWorld
extends RefCounted
## Golf-only immutable geometry plus reusable query workspaces; one caller at a time.
## Terrain is the rendered triangle cache. Hazard queries use exact finite volumes, not lies.

const TIME_EPS := 1.0e-9  ## dimensionless simultaneous-contact arithmetic budget
const DIRECTION_EPS := 1.0e-12  ## m per cast; separating/tangent start contacts do not block
const TREE_CELL := 20.0  ## m, broad phase only
const CUP_RADIUS := 0.054  ## m

var surface: RSGolfSurface
var bounds: RSGolfBounds
var pin := Vector3.ZERO
var wind := Vector3.ZERO
var gravity := Vector3.DOWN * 9.81  ## m/s²
var trees: Array = []
var ponds: Array = []
var sea_level := -INF
var last_triangle_casts := 0
var _lie: Callable
var _tree_grid: Dictionary = {}
var _tree_radius := 0.0
var _interval := RSGolfIntervals.new()
var _sweep := RSGolfSweep.new()
var _triangle := RSGolfContact.new()
var _low_y := 0.0
var _high_y := 0.0


func configure(terrain: RSGolfSurface, boundary: RSGolfBounds, water: Array, trunks: Array, cup: Vector3, ocean: float, sampler: Callable, breeze := Vector3.ZERO) -> bool:
	if terrain == null or terrain.triangle_count == 0 or boundary == null or not cup.is_finite() or not breeze.is_finite() or is_nan(ocean) or ocean == INF:
		push_error("RSGolfWorld: built finite geometry required")
		return false
	surface = terrain
	bounds = boundary
	ponds = water
	trees = trunks
	pin = cup
	sea_level = ocean
	wind = breeze
	_lie = sampler
	_tree_grid.clear()
	_tree_radius = 0.0
	for row: Array in ponds:
		if row.size() < 4:
			push_error("RSGolfWorld: invalid water geometry")
			return false
		var centre: Vector2 = row[0]
		var axes: Vector2 = row[1]
		if not centre.is_finite() or not axes.is_finite() or axes.x <= 0.0 or axes.y <= 0.0 or not is_finite(float(row[2])) or not is_finite(float(row[3])):
			push_error("RSGolfWorld: invalid water geometry")
			return false
	for i in trees.size():
		var row: Array = trees[i]
		if row.size() < 5:
			push_error("RSGolfWorld: invalid tree geometry")
			return false
		var ground: Vector3 = row[0]
		var centre: Vector3 = row[1]
		if not ground.is_finite() or not centre.is_finite() or centre.y <= ground.y or not is_finite(float(row[2])) or not is_finite(float(row[3])) or not is_finite(float(row[4])) or float(row[2]) <= 0.0 or float(row[3]) <= 0.0 or float(row[4]) <= 0.0:
			push_error("RSGolfWorld: invalid tree geometry")
			return false
		_tree_radius = maxf(_tree_radius, maxf(float(row[2]), float(row[3])))
		var key := Vector2i(floori(ground.x / TREE_CELL), floori(ground.z / TREE_CELL))
		if not _tree_grid.has(key):
			_tree_grid[key] = PackedInt32Array()
		var indices: PackedInt32Array = _tree_grid[key]
		indices.append(i)
		_tree_grid[key] = indices
	return true


func lie_at(point: Vector3) -> int:
	return int(_lie.call(point)) if _lie.is_valid() else RSGolfCourse.Lie.FAIRWAY


func storage_clearance(point: Vector3) -> float:
	# Separate represented Vector3 rounding from the scalar cast's shape/error budget.
	var scale := maxf(1.0, maxf(absf(point.x), maxf(absf(point.y), absf(point.z))))
	return maxf(1.0e-6, scale * 1.2e-7)


func cast(start: Vector3, end: Vector3, radius: float, grounded: bool, canopy: PackedByteArray, trunk: PackedByteArray, cup_locked: bool, out: RSGolfWorldHit) -> void:
	out.reset()
	last_triangle_casts = 0
	if surface == null or bounds == null or not start.is_finite() or not end.is_finite() or not is_finite(radius) or radius <= 0.0 or canopy.size() != trees.size() or trunk.size() != trees.size():
		_invalid(out, "invalid sphere query")
		return
	var boundary_time := bounds.first_exit(start, end)
	if is_nan(boundary_time):
		_invalid(out, "invalid boundary query")
		return
	if boundary_time != INF:
		var at := _at(start, end, boundary_time)
		_offer(RSGolfWorldHit.Kind.OB, boundary_time, at, at, Vector3.ZERO, 0.0, -1, out)
	_water(start, end, radius, out)
	if grounded and not cup_locked and radius < CUP_RADIUS:
		var flat_start := Vector3(start.x, 0.0, start.z)
		var flat_end := Vector3(end.x, 0.0, end.z)
		if _interval.sphere(flat_start, flat_end, Vector3(pin.x, 0.0, pin.z), CUP_RADIUS - radius):
			var at := _at(start, end, _interval.lo)
			_offer(RSGolfWorldHit.Kind.CUP, _interval.lo, pin, at, Vector3.UP, 0.0, -1, out)
	_trees(start, end, radius, canopy, out)
	if out.kind != RSGolfWorldHit.Kind.INVALID:
		_terrain(start, end, radius, out)


func support(point: Vector3, radius: float, out: RSGolfWorldHit) -> bool:
	out.reset()
	if surface == null or not point.is_finite() or not surface.contains_xz(point.x, point.z):
		return false
	var region := _region(point, point, radius)
	_low_y = INF
	_high_y = -INF
	for j in range(region.position.y, region.end.y):
		for i in range(region.position.x, region.end.x):
			var span := surface.cell_triangles(Vector2i(i, j))
			for triangle in range(span.x, span.x + span.y):
				var a := surface.triangle_vertex(triangle, 0)
				var b := surface.triangle_vertex(triangle, 1)
				var c := surface.triangle_vertex(triangle, 2)
				if not _overlaps_xz(point, point, radius, a, b, c):
					continue
				_low_y = minf(_low_y, minf(a.y, minf(b.y, c.y)))
				_high_y = maxf(_high_y, maxf(a.y, maxf(b.y, c.y)))
	if _low_y == INF:
		return false
	var clearance := storage_clearance(point)
	var start := Vector3(point.x, _high_y + radius + clearance, point.z)
	var end := Vector3(point.x, _low_y - radius - clearance, point.z)
	_terrain(start, end, radius, out)
	if out.kind != RSGolfWorldHit.Kind.TERRAIN:
		return false
	# Keep the requested XZ fixed; a normal offset every resting tick would create drift.
	out.centre.y += clearance / maxf(out.normal.y, 0.01)
	return true


func land_under(point: Vector3) -> bool:
	if not bounds.contains(point):
		return false
	var height := surface.height_at(point.x, point.z)
	return is_finite(height) and height > water_level_at(point.x, point.z) + storage_clearance(point)


func legal_placement(point: Vector3, radius: float, out: RSGolfWorldHit) -> bool:
	if not land_under(point) or not support(point, radius, out):
		return false
	for i in trees.size():
		if inside_trunk(i, out.centre, radius):
			return false
	return true


func water_level_at(x: float, z: float) -> float:
	var level := sea_level
	for row: Array in ponds:
		var centre: Vector2 = row[0]
		var axes: Vector2 = row[1]
		var turn: float = row[2]
		var cosine := cos(turn)
		var sine := sin(turn)
		var rx := float(x) - centre.x
		var rz := float(z) - centre.y
		var u := (rx * cosine + rz * sine) / axes.x
		var v := (-rx * sine + rz * cosine) / axes.y
		if u * u + v * v <= 1.0:
			level = maxf(level, float(row[3]))
	return level


func inside_canopy(index: int, point: Vector3, radius: float) -> bool:
	var row: Array = trees[index]
	var ground: Vector3 = row[0]
	var centre: Vector3 = row[1]
	var horizontal := float(row[2]) + radius
	var vertical := float(row[2]) / 0.8 + radius
	var x := (float(point.x) - centre.x) / horizontal
	var y := (float(point.y) - centre.y) / vertical
	var z := (float(point.z) - centre.z) / horizontal
	return x * x + y * y + z * z <= 1.0 and point.y >= ground.y + float(row[4]) * 0.3 - radius


func inside_trunk(index: int, point: Vector3, radius: float) -> bool:
	var row: Array = trees[index]
	var ground: Vector3 = row[0]
	var centre: Vector3 = row[1]
	var y := clampf(point.y, ground.y, centre.y)
	var x := float(point.x) - ground.x
	var dy := float(point.y) - y
	var z := float(point.z) - ground.z
	var expanded := float(row[3]) + radius
	return x * x + dy * dy + z * z <= expanded * expanded


func _water(start: Vector3, end: Vector3, radius: float, out: RSGolfWorldHit) -> void:
	for i in ponds.size():
		var row: Array = ponds[i]
		if _interval.ellipse(start, end, row[0], row[1], float(row[2])) and _interval.clip_y(start, end, float(row[3]) + radius, true):
			var at := _at(start, end, _interval.lo)
			_offer(RSGolfWorldHit.Kind.WATER, _interval.lo, Vector3(at.x, row[3], at.z), at, Vector3.UP, 0.0, i, out)
	if is_finite(sea_level):
		_interval.lo = 0.0
		_interval.hi = 1.0
		if _interval.clip_y(start, end, sea_level + radius, true):
			var at := _at(start, end, _interval.lo)
			_offer(RSGolfWorldHit.Kind.WATER, _interval.lo, Vector3(at.x, sea_level, at.z), at, Vector3.UP, 0.0, -1, out)


func _trees(start: Vector3, end: Vector3, radius: float, canopy: PackedByteArray, out: RSGolfWorldHit) -> void:
	var pad := _tree_radius + radius
	var minimum := Vector2i(floori((minf(start.x, end.x) - pad) / TREE_CELL), floori((minf(start.z, end.z) - pad) / TREE_CELL))
	var maximum := Vector2i(floori((maxf(start.x, end.x) + pad) / TREE_CELL), floori((maxf(start.z, end.z) + pad) / TREE_CELL))
	for j in range(minimum.y, maximum.y + 1):
		for i in range(minimum.x, maximum.x + 1):
			var key := Vector2i(i, j)
			if not _tree_grid.has(key):
				continue
			var indices: PackedInt32Array = _tree_grid[key]
			for index in indices:
				var row: Array = trees[index]
				var ground: Vector3 = row[0]
				var centre: Vector3 = row[1]
				if canopy[index] == 0:
					var axes := Vector3(float(row[2]) + radius, float(row[2]) / 0.8 + radius, float(row[2]) + radius)
					if _interval.ellipsoid(start, end, centre, axes) and _interval.clip_y(start, end, ground.y + float(row[4]) * 0.3 - radius, false):
						var at := _at(start, end, _interval.lo)
						_offer(RSGolfWorldHit.Kind.CANOPY, _interval.lo, at, at, Vector3.ZERO, 0.0, index, out)
				if _interval.capsule(start, end, ground, Vector3(ground.x, centre.y, ground.z), float(row[3]) + radius):
					var time := _interval.lo
					var at := _at(start, end, time)
					var axis := Vector3(ground.x, clampf(at.y, ground.y, centre.y), ground.z)
					var normal := at - axis
					var distance := normal.length()
					if distance == 0.0:
						_invalid(out, "sphere starts on a trunk axis")
						return
					normal /= distance
					var depth := maxf(0.0, float(row[3]) + radius - distance)
					if time == 0.0 and depth > storage_clearance(start) * 4.0:
						_invalid(out, "sphere starts inside a trunk")
						return
					if time > TIME_EPS or _approach(normal, start, end) < -DIRECTION_EPS:
						_offer(RSGolfWorldHit.Kind.TRUNK, time, axis + normal * float(row[3]), at, normal, depth, index, out)


func _terrain(start: Vector3, end: Vector3, radius: float, out: RSGolfWorldHit) -> void:
	var region := _region(start, end, radius)
	for j in range(region.position.y, region.end.y):
		for i in range(region.position.x, region.end.x):
			var span := surface.cell_triangles(Vector2i(i, j))
			for triangle in range(span.x, span.x + span.y):
				var a := surface.triangle_vertex(triangle, 0)
				var b := surface.triangle_vertex(triangle, 1)
				var c := surface.triangle_vertex(triangle, 2)
				if not _overlaps_xz(start, end, radius, a, b, c) or maxf(start.y, end.y) + radius < minf(a.y, minf(b.y, c.y)) or minf(start.y, end.y) - radius > maxf(a.y, maxf(b.y, c.y)):
					continue
				last_triangle_casts += 1
				if not _sweep.cast_triangle(start, end, radius, a, b, c, _triangle, true, triangle):
					if _triangle.status == RSGolfContact.Status.INVALID:
						_invalid(out, "invalid terrain triangle")
						return
					continue
				if _triangle.fraction == 0.0:
					if _triangle.depth > storage_clearance(start) * 4.0 or bool(_triangle.flags & RSGolfContact.Flag.BACKFACE):
						_invalid(out, "sphere starts inside terrain")
						return
					if _approach(_triangle.normal, start, end) >= -DIRECTION_EPS:
						continue
				_offer(RSGolfWorldHit.Kind.TERRAIN, _triangle.fraction, _triangle.point, _triangle.centre, _triangle.normal, _triangle.depth, triangle, out)
				if out.kind == RSGolfWorldHit.Kind.INVALID:
					return


func _region(start: Vector3, end: Vector3, radius: float) -> Rect2i:
	var origin := surface.origin
	var first := Vector2i(floori((minf(start.x, end.x) - radius - origin.x) / RSGolfSurface.CELL), floori((minf(start.z, end.z) - radius - origin.y) / RSGolfSurface.CELL))
	var last := Vector2i(floori((maxf(start.x, end.x) + radius - origin.x) / RSGolfSurface.CELL), floori((maxf(start.z, end.z) + radius - origin.y) / RSGolfSurface.CELL)) + Vector2i.ONE
	first = first.clamp(Vector2i.ZERO, surface.cells)
	last = last.clamp(Vector2i.ZERO, surface.cells)
	return Rect2i(first, last - first)


func _overlaps_xz(start: Vector3, end: Vector3, radius: float, a: Vector3, b: Vector3, c: Vector3) -> bool:
	return maxf(start.x, end.x) + radius >= minf(a.x, minf(b.x, c.x)) and minf(start.x, end.x) - radius <= maxf(a.x, maxf(b.x, c.x)) and maxf(start.z, end.z) + radius >= minf(a.z, minf(b.z, c.z)) and minf(start.z, end.z) - radius <= maxf(a.z, maxf(b.z, c.z))


func _offer(kind: RSGolfWorldHit.Kind, time: float, point: Vector3, centre: Vector3, normal: Vector3, depth: float, id: int, out: RSGolfWorldHit) -> void:
	if out.kind == RSGolfWorldHit.Kind.INVALID or time > out.fraction + TIME_EPS:
		return
	var simultaneous := absf(time - out.fraction) <= TIME_EPS
	var solid := kind == RSGolfWorldHit.Kind.TRUNK or kind == RSGolfWorldHit.Kind.TERRAIN
	var old_solid := out.kind == RSGolfWorldHit.Kind.TRUNK or out.kind == RSGolfWorldHit.Kind.TERRAIN
	if simultaneous and solid and old_solid:
		if not out.add_normal(normal, kind, id):
			return
		out.depth = maxf(out.depth, depth)
		if kind > out.kind or (kind == out.kind and id >= out.feature_id):
			return
	elif simultaneous and (kind > out.kind or (kind == out.kind and id >= out.feature_id)):
		return
	else:
		out.count = 0
	out.kind = kind
	out.fraction = time
	out.point = point
	out.centre = centre
	out.normal = normal
	out.depth = maxf(out.depth, depth) if simultaneous else depth
	out.feature_id = id
	if solid:
		out.add_normal(normal, kind, id)


func _approach(normal: Vector3, start: Vector3, end: Vector3) -> float:
	return normal.x * (float(end.x) - start.x) + normal.y * (float(end.y) - start.y) + normal.z * (float(end.z) - start.z)


func _at(start: Vector3, end: Vector3, time: float) -> Vector3:
	return Vector3(float(start.x) + (float(end.x) - start.x) * time, float(start.y) + (float(end.y) - start.y) * time, float(start.z) + (float(end.z) - start.z) * time)


func _invalid(out: RSGolfWorldHit, message: String) -> void:
	out.reset()
	out.kind = RSGolfWorldHit.Kind.INVALID
	push_error("RSGolfWorld: " + message)
