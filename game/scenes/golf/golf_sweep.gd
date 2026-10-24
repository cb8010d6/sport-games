class_name RSGolfSweep
extends RefCounted
## Continuous sphere against one CLOSED finite triangle. No marching, integration or rules.
## Reuse one workspace per caller; no retained result/triangle owner or per-cast containers.
## Vector3 coordinates are represented float32 inputs/outputs; root/projection math is scalar double.

const ROUND := 64.0 * 2.220446049250313e-16

var _px := 0.0
var _py := 0.0
var _pz := 0.0
var _dx := 0.0
var _dy := 0.0
var _dz := 0.0
var _radius := 0.0
var _length := 0.0
var _eps := 0.0
var _time_eps := 0.0
var _ax := 0.0
var _ay := 0.0
var _az := 0.0
var _bx := 0.0
var _by := 0.0
var _bz := 0.0
var _cx := 0.0
var _cy := 0.0
var _cz := 0.0
var _abx := 0.0
var _aby := 0.0
var _abz := 0.0
var _acx := 0.0
var _acy := 0.0
var _acz := 0.0
var _nx := 0.0
var _ny := 0.0
var _nz := 0.0
var _aa := 0.0
var _ac := 0.0
var _cc := 0.0
var _det := 0.0
var _qx := 0.0
var _qy := 0.0
var _qz := 0.0
var _part := RSGolfContact.Part.NONE
var _part_id := -1
var _best_distance_squared := 0.0
var _lo := 0.0
var _hi := 0.0
var _front_only := false


func cast_triangle(start: Vector3, end: Vector3, radius: float, a: Vector3, b: Vector3, c: Vector3, out: RSGolfContact, front_only := false, feature_id := -1) -> bool:
	out.reset()
	if not start.is_finite() or not end.is_finite() or not a.is_finite() or not b.is_finite() or not c.is_finite() or not is_finite(radius) or radius <= 0.0 or not is_finite(radius * radius):
		return _invalid(out, "invalid triangle cast input")
	_px = start.x
	_py = start.y
	_pz = start.z
	_dx = float(end.x) - _px
	_dy = float(end.y) - _py
	_dz = float(end.z) - _pz
	_radius = radius
	_length = sqrt(_dx * _dx + _dy * _dy + _dz * _dz)
	_ax = a.x
	_ay = a.y
	_az = a.z
	_bx = b.x
	_by = b.y
	_bz = b.z
	_cx = c.x
	_cy = c.y
	_cz = c.z
	_abx = _bx - _ax
	_aby = _by - _ay
	_abz = _bz - _az
	_acx = _cx - _ax
	_acy = _cy - _ay
	_acz = _cz - _az
	_aa = _abx * _abx + _aby * _aby + _abz * _abz
	_ac = _abx * _acx + _aby * _acy + _abz * _acz
	_cc = _acx * _acx + _acy * _acy + _acz * _acz
	_det = _aa * _cc - _ac * _ac
	if _det <= ROUND * (_aa * _cc + _ac * _ac):
		return _invalid(out, "degenerate triangle")
	_nx = _acy * _abz - _acz * _aby
	_ny = _acz * _abx - _acx * _abz
	_nz = _acx * _aby - _acy * _abx
	var norm := sqrt(_nx * _nx + _ny * _ny + _nz * _nz)
	_nx /= norm
	_ny /= norm
	_nz /= norm
	_front_only = front_only
	var scale := maxf(1.0, maxf(radius, _length))
	scale = maxf(scale, maxf(_max_abs(start), _max_abs(end)))
	scale = maxf(scale, maxf(_max_abs(a), maxf(_max_abs(b), _max_abs(c))))
	_eps = ROUND * scale
	_time_eps = _eps / maxf(_length, _eps)
	_closest(_px, _py, _pz)
	var x := _px - _qx
	var y := _py - _qy
	var z := _pz - _qz
	var distance := sqrt(x * x + y * y + z * z)
	if distance <= radius + _eps:
		_consider(0.0, out, true)
	else:
		_face(1.0, out)
		if not front_only:
			_face(-1.0, out)
		_edge(_ax, _ay, _az, _bx, _by, _bz, out)
		_edge(_bx, _by, _bz, _cx, _cy, _cz, out)
		_edge(_cx, _cy, _cz, _ax, _ay, _az, out)
		_vertex(_ax, _ay, _az, out)
		_vertex(_bx, _by, _bz, out)
		_vertex(_cx, _cy, _cz, out)
	if out.status == RSGolfContact.Status.HIT or out.status == RSGolfContact.Status.OVERLAP:
		out.feature_id = feature_id
		return true
	return false


func _invalid(out: RSGolfContact, message: String) -> bool:
	out.reset()
	out.status = RSGolfContact.Status.INVALID
	push_error("RSGolfSweep: " + message)
	return false


func _max_abs(value: Vector3) -> float:
	return maxf(absf(value.x), maxf(absf(value.y), absf(value.z)))


func _face(sign_value: float, out: RSGolfContact) -> void:
	var velocity := _nx * _dx + _ny * _dy + _nz * _dz
	if velocity == 0.0 or sign_value * velocity > 0.0:
		return
	var height := _nx * (_px - _ax) + _ny * (_py - _ay) + _nz * (_pz - _az)
	var t := (sign_value * _radius - height) / velocity
	if t < 0.0 or t > 1.0:
		return
	_consider(t, out)


func _interval(mx: float, my: float, mz: float, dx: float, dy: float, dz: float) -> bool:
	var a := dx * dx + dy * dy + dz * dz
	var c := mx * mx + my * my + mz * mz
	if a == 0.0:
		_lo = 0.0
		_hi = 1.0
		return c <= _radius * _radius
	var middle := -(mx * dx + my * dy + mz * dz) / a
	var x := mx + middle * dx
	var y := my + middle * dy
	var z := mz + middle * dz
	var nearest := x * x + y * y + z * z
	var gap := _radius * _radius - nearest
	var tolerance := _eps * (2.0 * sqrt(nearest) + _eps) + ROUND * (_radius * _radius + nearest)
	if gap < -tolerance:
		return false
	var half := sqrt(maxf(0.0, gap) / a)
	_lo = maxf(0.0, middle - half)
	_hi = minf(1.0, middle + half)
	return _lo <= _hi


func _edge(ax: float, ay: float, az: float, bx: float, by: float, bz: float, out: RSGolfContact) -> void:
	var ux := bx - ax
	var uy := by - ay
	var uz := bz - az
	var length := sqrt(ux * ux + uy * uy + uz * uz)
	ux /= length
	uy /= length
	uz /= length
	var mx := _px - ax
	var my := _py - ay
	var mz := _pz - az
	var start := mx * ux + my * uy + mz * uz
	var velocity := _dx * ux + _dy * uy + _dz * uz
	if not _interval(mx - ux * start, my - uy * start, mz - uz * start, _dx - ux * velocity, _dy - uy * velocity, _dz - uz * velocity):
		return
	var lo := _lo
	var hi := _hi
	if velocity == 0.0:
		if start < 0.0 or start > length:
			return
	else:
		var first := -start / velocity
		var last := (length - start) / velocity
		lo = maxf(lo, minf(first, last))
		hi = minf(hi, maxf(first, last))
	if lo <= hi:
		_consider(lo, out)


func _vertex(x: float, y: float, z: float, out: RSGolfContact) -> void:
	if _interval(_px - x, _py - y, _pz - z, _dx, _dy, _dz):
		_consider(_lo, out)


func _consider(t: float, out: RSGolfContact, initial := false) -> void:
	var x := _px + _dx * t
	var y := _py + _dy * t
	var z := _pz + _dz * t
	_closest(x, y, z)
	var nx := x - _qx
	var ny := y - _qy
	var nz := z - _qz
	var distance := sqrt(nx * nx + ny * ny + nz * nz)
	if not initial and absf(distance - _radius) > _eps * 4.0:
		return  # Reject an infinite plane/axis candidate outside the finite triangle.
	var normal_valid := distance > _eps
	if normal_valid:
		nx /= distance
		ny /= distance
		nz /= distance
	var backface := normal_valid and nx * _nx + ny * _ny + nz * _nz < -ROUND
	var depth := maxf(0.0, _radius - distance)
	if _front_only and backface and (not initial or depth <= _eps):
		return
	if out.status != RSGolfContact.Status.MISS:
		if t > out.fraction + _time_eps:
			return
		if absf(t - out.fraction) <= _time_eps and (_part > out.part or (_part == out.part and _part_id >= out.part_id)):
			return
	out.status = RSGolfContact.Status.OVERLAP if initial and depth > _eps else RSGolfContact.Status.HIT
	out.part = _part
	out.part_id = _part_id
	out.fraction = t
	out.centre = Vector3(x, y, z)
	out.point = Vector3(_qx, _qy, _qz)
	out.normal = Vector3(nx, ny, nz) if normal_valid else Vector3.ZERO
	out.depth = depth
	out.flags = 0
	if initial:
		out.flags |= RSGolfContact.Flag.START_OVERLAP if out.status == RSGolfContact.Status.OVERLAP else RSGolfContact.Flag.START_TOUCH
	if _length == 0.0:
		out.flags |= RSGolfContact.Flag.STATIONARY
	if not normal_valid:
		out.flags |= RSGolfContact.Flag.NORMAL_UNDEFINED
	else:
		var approach := nx * _dx + ny * _dy + nz * _dz
		out.flags |= RSGolfContact.Flag.TANGENT if absf(approach) <= _eps else (RSGolfContact.Flag.APPROACHING if approach < 0.0 else RSGolfContact.Flag.SEPARATING)
	if backface:
		out.flags |= RSGolfContact.Flag.BACKFACE


func _closest(x: float, y: float, z: float) -> void:
	# Project directly; Gram-determinant barycentrics lose the closest point on skinny faces.
	var rx := x - _ax
	var ry := y - _ay
	var rz := z - _az
	var height := _nx * rx + _ny * ry + _nz * rz
	rx -= height * _nx
	ry -= height * _ny
	rz -= height * _nz
	if _inside_edge(_abx, _aby, _abz, rx, ry, rz) and _inside_edge(_cx - _bx, _cy - _by, _cz - _bz, rx - _abx, ry - _aby, rz - _abz) and _inside_edge(-_acx, -_acy, -_acz, rx - _acx, ry - _acy, rz - _acz):
		_point(_ax + rx, _ay + ry, _az + rz, RSGolfContact.Part.FACE, 0)
		return
	# Compare in the local plane: adding the common height squared can hide tiny edge gaps.
	_best_distance_squared = INF
	_closest_edge(rx, ry, rz, 0.0, 0.0, 0.0, _abx, _aby, _abz, 0)
	_closest_edge(rx, ry, rz, _abx, _aby, _abz, _acx, _acy, _acz, 1)
	_closest_edge(rx, ry, rz, _acx, _acy, _acz, 0.0, 0.0, 0.0, 2)


func _inside_edge(ex: float, ey: float, ez: float, rx: float, ry: float, rz: float) -> bool:
	var first := (ey * _nz - ez * _ny) * rx
	var second := (ez * _nx - ex * _nz) * ry
	var third := (ex * _ny - ey * _nx) * rz
	# Roundoff-boundary points use finite edges for stable topology, without shape slop.
	return first + second + third > ROUND * (absf(first) + absf(second) + absf(third))


func _closest_edge(x: float, y: float, z: float, ax: float, ay: float, az: float, bx: float, by: float, bz: float, id: int) -> void:
	var ux := bx - ax
	var uy := by - ay
	var uz := bz - az
	var rx := x - ax
	var ry := y - ay
	var rz := z - az
	var along := clampf((rx * ux + ry * uy + rz * uz) / (ux * ux + uy * uy + uz * uz), 0.0, 1.0)
	var dx := rx - along * ux
	var dy := ry - along * uy
	var dz := rz - along * uz
	var distance_squared := dx * dx + dy * dy + dz * dz
	var part := RSGolfContact.Part.EDGE
	var part_id := id
	if along == 0.0 or along == 1.0:
		part = RSGolfContact.Part.VERTEX
		part_id = id if along == 0.0 else (id + 1) % 3
	if distance_squared > _best_distance_squared:
		return
	if distance_squared == _best_distance_squared and (part > _part or (part == _part and part_id >= _part_id)):
		return
	_best_distance_squared = distance_squared
	_point(_ax + (ax + along * ux), _ay + (ay + along * uy), _az + (az + along * uz), part, part_id)


func _point(x: float, y: float, z: float, part: RSGolfContact.Part, id: int) -> void:
	_qx = x
	_qy = y
	_qz = z
	_part = part
	_part_id = id
