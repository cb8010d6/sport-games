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
	var x := _px + _dx * t - sign_value * _radius * _nx - _ax
	var y := _py + _dy * t - sign_value * _radius * _ny - _ay
	var z := _pz + _dz * t - sign_value * _radius * _nz - _az
	var u := x * _abx + y * _aby + z * _abz
	var v := x * _acx + y * _acy + z * _acz
	var first := u * _cc - v * _ac
	var second := v * _aa - u * _ac
	var tolerance := ROUND * (_det + absf(u * _cc) + absf(v * _ac) + absf(v * _aa) + absf(u * _ac))
	if first >= -tolerance and second >= -tolerance and first + second <= _det + tolerance:
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
	# Voronoi-region closest point, independent of which cast primitive proposed the time.
	var d1 := _abx * (x - _ax) + _aby * (y - _ay) + _abz * (z - _az)
	var d2 := _acx * (x - _ax) + _acy * (y - _ay) + _acz * (z - _az)
	if d1 <= 0.0 and d2 <= 0.0:
		_point(_ax, _ay, _az, RSGolfContact.Part.VERTEX, 0)
		return
	var d3 := _abx * (x - _bx) + _aby * (y - _by) + _abz * (z - _bz)
	var d4 := _acx * (x - _bx) + _acy * (y - _by) + _acz * (z - _bz)
	if d3 >= 0.0 and d4 <= d3:
		_point(_bx, _by, _bz, RSGolfContact.Part.VERTEX, 1)
		return
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		var edge_v := d1 / (d1 - d3)
		_point(_ax + edge_v * _abx, _ay + edge_v * _aby, _az + edge_v * _abz, RSGolfContact.Part.EDGE, 0)
		return
	var d5 := _abx * (x - _cx) + _aby * (y - _cy) + _abz * (z - _cz)
	var d6 := _acx * (x - _cx) + _acy * (y - _cy) + _acz * (z - _cz)
	if d6 >= 0.0 and d5 <= d6:
		_point(_cx, _cy, _cz, RSGolfContact.Part.VERTEX, 2)
		return
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		var edge_w := d2 / (d2 - d6)
		_point(_ax + edge_w * _acx, _ay + edge_w * _acy, _az + edge_w * _acz, RSGolfContact.Part.EDGE, 2)
		return
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and d4 - d3 >= 0.0 and d5 - d6 >= 0.0:
		var edge_bc := (d4 - d3) / ((d4 - d3) + (d5 - d6))
		_point(_bx + edge_bc * (_cx - _bx), _by + edge_bc * (_cy - _by), _bz + edge_bc * (_cz - _bz), RSGolfContact.Part.EDGE, 1)
		return
	var v := vb / (va + vb + vc)
	var w := vc / (va + vb + vc)
	_point(_ax + v * _abx + w * _acx, _ay + v * _aby + w * _acy, _az + v * _abz + w * _acz, RSGolfContact.Part.FACE, 0)


func _point(x: float, y: float, z: float, part: RSGolfContact.Part, id: int) -> void:
	_qx = x
	_qy = y
	_qz = z
	_part = part
	_part_id = id
