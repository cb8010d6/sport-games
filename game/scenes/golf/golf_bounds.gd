class_name RSGolfBounds
extends RefCounted
## Exact closed union of every hole's 62 m route capsules, intersected with the terrain domain.
## Rasterized fairway/green fields never participate in OB. Reuse the interval workspace.

const RADIUS := 62.0  ## m from the nearest line-of-play segment, including its endpoints
const TIME_EPS := 1.0e-12  ## arithmetic tie only; no metre-scale boundary inflation

var _surface: RSGolfSurface
var _starts := PackedVector2Array()
var _ends := PackedVector2Array()
var _lower := PackedFloat64Array()
var _upper := PackedFloat64Array()
var _interval := RSGolfIntervals.new()


func build(surface: RSGolfSurface, routes: Array[PackedVector2Array]) -> bool:
	_surface = null
	_starts.clear()
	_ends.clear()
	for path: PackedVector2Array in routes:
		for i in range(1, path.size()):
			if not path[i - 1].is_finite() or not path[i].is_finite():
				push_error("RSGolfBounds: finite routes required")
				return false
			_starts.append(path[i - 1])
			_ends.append(path[i])
	if surface == null or surface.triangle_count == 0 or _starts.is_empty():
		push_error("RSGolfBounds: built terrain and routes required")
		return false
	_surface = surface
	_lower.resize(_starts.size())
	_upper.resize(_starts.size())
	return true


func distance(point: Vector3) -> float:
	return sqrt(_distance_squared(point))


func contains(point: Vector3) -> bool:
	return _surface != null and point.is_finite() and _surface.contains_xz(point.x, point.z) and _distance_squared(point) <= RADIUS * RADIUS


func first_exit(start: Vector3, end: Vector3) -> float:
	if not start.is_finite() or not end.is_finite() or _surface == null:
		push_error("RSGolfBounds: finite cast on built bounds required")
		return NAN
	if not contains(start):
		return 0.0
	for i in _starts.size():
		var a := Vector3(_starts[i].x, 0.0, _starts[i].y)
		var b := Vector3(_ends[i].x, 0.0, _ends[i].y)
		var from := Vector3(start.x, 0.0, start.z)
		var to := Vector3(end.x, 0.0, end.z)
		if _interval.capsule(from, to, a, b, RADIUS):
			_lower[i] = _interval.lo
			_upper[i] = _interval.hi
		else:
			_lower[i] = INF
			_upper[i] = -INF
	# Only the interval component containing t=0 is legal. Re-entry cannot erase an earlier exit.
	var covered := 0.0
	var changed := true
	while changed:
		changed = false
		for i in _starts.size():
			if _lower[i] <= covered + TIME_EPS and _upper[i] > covered:
				covered = _upper[i]
				changed = true
	var exit_time := covered if covered < 1.0 else INF
	var minimum := _surface.origin
	var maximum := minimum + Vector2(_surface.cells) * RSGolfSurface.CELL
	var dx := float(end.x) - start.x
	var dz := float(end.z) - start.z
	if end.x < minimum.x:
		exit_time = minf(exit_time, (minimum.x - start.x) / dx)
	elif end.x > maximum.x:
		exit_time = minf(exit_time, (maximum.x - start.x) / dx)
	if end.z < minimum.y:
		exit_time = minf(exit_time, (minimum.y - start.z) / dz)
	elif end.z > maximum.y:
		exit_time = minf(exit_time, (maximum.y - start.z) / dz)
	return exit_time


func _distance_squared(point: Vector3) -> float:
	var best := INF
	for i in _starts.size():
		var ax := float(_starts[i].x)
		var az := float(_starts[i].y)
		var dx := float(_ends[i].x) - ax
		var dz := float(_ends[i].y) - az
		var rx := float(point.x) - ax
		var rz := float(point.z) - az
		var length_squared := dx * dx + dz * dz
		var along := clampf((rx * dx + rz * dz) / length_squared, 0.0, 1.0) if length_squared > 0.0 else 0.0
		var x := rx - along * dx
		var z := rz - along * dz
		best = minf(best, x * x + z * z)
	return best
