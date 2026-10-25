class_name RSRaceTrack
extends RefCounted
## Shared racing route: horizontal XZ arc length / projection, ordered gates and standings.
## Metres and game-clock seconds; Y is carried only by point_at. Lateral and turns are
## positive to the right. step <= 0 keeps a polyline; positive step samples Catmull-Rom.
## s wraps on closed routes; progress is unwrapped and may be negative on the starting grid.
## Call update_racer for everyone, then update_standings once to commit finish_order.
## Hinted projection follows the connected local distance basin; an off-route respawn
## beyond REACQUIRE uses the prebuilt spatial grid. No nodes, randomness or hot-path arrays.

const GATE_PASSED := 1
const GATE_MISSED := 2
const LAP := 4
const FINISHED := 8
const SPLINE_STEP := 2.0
const CELL := 16.0              ## m, global projection grid cell edge
const MAX_CELLS := 65536
const WINDOW := 20.0            ## m searched either side of the previous s
const REACQUIRE := 40.0         ## m from the local match before global reacquisition
const WRONG_WAY := 10.0         ## m behind the furthest progress, suppressing small reversals
const TIE_PROGRESS := 0.001     ## m, strict live-place tie threshold


class Racer extends RefCounted:
	var id := 0
	var s := 0.0
	var lateral := 0.0
	var progress := 0.0
	var lap := 0
	var next_gate := 0
	var gates_hit := 0
	var gates_missed := 0
	var finished := false
	var finish_time := 0.0
	var finish_order := 0
	var place := 0
	var wrong_way := false
	var _peak := 0.0
	var _seq := 0
	var _time := 0.0


var closed := false
var length := 0.0
var laps := 1
var finish_s := -1.0
var racers: Array[Racer] = []
var order: Array[Racer] = []

var _p := PackedVector2Array()
var _y := PackedFloat32Array()
var _cum := PackedFloat64Array()
var _dir := PackedVector2Array()
var _len := PackedFloat64Array()
var _curv := PackedFloat32Array()
var _gs := PackedFloat64Array()
var _glo := PackedFloat32Array()
var _ghi := PackedFloat32Array()
var _gx0 := 0.0
var _gz0 := 0.0
var _cell := CELL
var _nx := 1
var _nz := 1
var _cell_start := PackedInt32Array()
var _cell_seg := PackedInt32Array()
var _q_d2 := INF
var _q_tie := INF
var _q_s := 0.0
var _q_seg := 0
var _finished_count := 0


func _init(points: PackedVector3Array, loop := false, step := SPLINE_STEP) -> void:
	closed = loop
	_build(_spline(points, step) if step > 0.0 else points)
	_build_grid()


func wrap_s(s: float) -> float:
	return fposmod(s, length) if closed else clampf(s, 0.0, length)


func delta_s(from_s: float, to_s: float) -> float:
	return wrapf(to_s - from_s, -length * 0.5, length * 0.5) if closed else to_s - from_s


func point_at(s: float) -> Vector3:
	var ws := wrap_s(s)
	var i := _seg_at(ws)
	var t := clampf((ws - _cum[i]) / _len[i], 0.0, 1.0)
	var p := _p[i].lerp(_p[i + 1], t)
	return Vector3(p.x, lerpf(_y[i], _y[i + 1], t), p.y)


func tangent_at(s: float) -> Vector3:
	var d := _dir[_seg_at(wrap_s(s))]
	return Vector3(d.x, 0.0, d.y)


func right_at(s: float) -> Vector3:
	var d := _dir[_seg_at(wrap_s(s))]
	return Vector3(-d.y, 0.0, d.x)


func curvature_at(s: float) -> float:
	var ws := wrap_s(s)
	var i := _seg_at(ws)
	return lerpf(_curv[i], _curv[i + 1], clampf((ws - _cum[i]) / _len[i], 0.0, 1.0))


func project(pos: Vector3, hint_s := NAN) -> Vector2:
	var q := Vector2(pos.x, pos.z)
	_q_d2 = INF
	_q_tie = INF
	if is_finite(hint_s):
		_nearest_window(q, wrap_s(hint_s))
	if _q_d2 > REACQUIRE * REACQUIRE:
		_q_d2 = INF
		_q_tie = INF
		_nearest_global(q)
	var v := q - _p[_q_seg]
	var d := _dir[_q_seg]
	return Vector2(wrap_s(_q_s), -v.x * d.y + v.y * d.x)


static func steer_angle(forward: Vector3, from: Vector3, to: Vector3) -> float:
	var dx := to.x - from.x
	var dz := to.z - from.z
	return atan2(forward.x * dz - forward.z * dx, forward.x * dx + forward.z * dz)


func add_gate(s: float, lo := -INF, hi := INF) -> int:
	## Add all gates before starting racers; insertion returns their sorted s index.
	var ws := wrap_s(s)
	var i := _gs.bsearch(ws, false)
	_gs.insert(i, ws)
	_glo.insert(i, minf(lo, hi))
	_ghi.insert(i, maxf(lo, hi))
	return i


func add_gate_between(a: Vector3, b: Vector3) -> int:
	var s := project((a + b) * 0.5).x
	var c := point_at(s)
	var right := right_at(s)
	return add_gate(s, (a - c).dot(right), (b - c).dot(right))


func gate_count() -> int:
	return _gs.size()


func gate_s(i: int) -> float:
	return _gs[i]


func gate_window(i: int) -> Vector2:
	return Vector2(_glo[i], _ghi[i])


func gate_point(i: int) -> Vector3:
	var middle := (_glo[i] + _ghi[i]) * 0.5 if is_finite(_glo[i]) and is_finite(_ghi[i]) else 0.0
	return point_at(_gs[i]) + right_at(_gs[i]) * middle


func add_racer(id: int) -> Racer:
	var r := Racer.new()
	r.id = id
	racers.append(r)
	order.append(r)
	start_racer(r, 0.0)
	return r


func remove_racer(r: Racer) -> void:
	racers.erase(r)
	order.erase(r)


func new_race() -> void:
	_finished_count = 0
	for r: Racer in racers:
		start_racer(r, 0.0)


func start_racer(r: Racer, start_progress: float, time := 0.0) -> void:
	r.progress = start_progress
	r._peak = start_progress
	r.s = wrap_s(start_progress)
	r.lateral = 0.0
	r.lap = clampi(floori(start_progress / length), 0, maxi(laps, 1)) if closed else 0
	r.gates_hit = 0
	r.gates_missed = 0
	r.finished = false
	r.finish_time = 0.0
	r.finish_order = 0
	r.place = 0
	r.wrong_way = false
	r._time = time
	var g := _gs.size()
	r._seq = floori(maxf(start_progress, 0.0) / length) * g if closed else 0
	while _gate_progress(r._seq) <= start_progress:
		r._seq += 1
	r.next_gate = _gate_index(r._seq) if _gate_progress(r._seq) <= _finish_progress() else g


func update_racer(r: Racer, pos: Vector3, time: float) -> int:
	var q := project(pos, r.s)
	var previous := r.progress
	var previous_lat := r.lateral
	var previous_time := r._time
	if closed:
		r.progress += delta_s(r.s, q.x)
	else:
		r.progress = q.x
		# Retain signed grid positions and finish-line overshoot for time interpolation.
		if q.x <= 0.0:
			r.progress = minf((pos - point_at(0.0)).dot(tangent_at(0.0)), 0.0)
		elif q.x >= length:
			r.progress += maxf((pos - point_at(length)).dot(tangent_at(length)), 0.0)
	r.s = q.x
	r.lateral = q.y
	r._time = time
	r.wrong_way = not r.finished and r._peak - r.progress > WRONG_WAY
	if r.finished or r.progress <= r._peak:
		return 0
	var event := 0
	var finish := _finish_progress()
	var span := r.progress - previous
	var gp := _gate_progress(r._seq)
	while gp <= r.progress and gp <= finish:
		var i := _gate_index(r._seq)
		var lateral := lerpf(previous_lat, q.y, clampf((gp - previous) / span, 0.0, 1.0))
		if lateral >= _glo[i] and lateral <= _ghi[i]:
			r.gates_hit += 1
			event |= GATE_PASSED
		else:
			r.gates_missed += 1
			event |= GATE_MISSED
		r._seq += 1
		gp = _gate_progress(r._seq)
	r.next_gate = _gate_index(r._seq) if gp <= finish else _gs.size()
	r._peak = r.progress
	if closed:
		var lap := clampi(floori(r._peak / length), 0, maxi(laps, 1))
		if lap > r.lap:
			r.lap = lap
			event |= LAP
	if r._peak >= finish:
		r.finished = true
		r.wrong_way = false
		r.finish_time = lerpf(previous_time, time, clampf((finish - previous) / span, 0.0, 1.0))
		event |= FINISHED
	return event


func update_standings() -> void:
	## Insertion sort reuses order. Committed arrivals are fixed; this frame's new arrivals
	## are ordered by their interpolated times before receiving unique finish_order values.
	var n := order.size()
	for i in n:
		var r := order[i]
		var j := i - 1
		while j >= 0 and _ahead(r, order[j]):
			order[j + 1] = order[j]
			j -= 1
		order[j + 1] = r
	var tie_progress := INF
	var tie_place := 0
	for i in n:
		var r := order[i]
		if r.finished:
			if r.finish_order == 0:
				_finished_count += 1
				r.finish_order = _finished_count
			r.place = i + 1
		elif tie_progress - r.progress < TIE_PROGRESS:
			r.place = tie_place
		else:
			tie_progress = r.progress
			tie_place = i + 1
			r.place = tie_place


func fraction(r: Racer) -> float:
	var finish := _finish_progress()
	return 1.0 if r.finished or finish <= 0.0 else clampf(r.progress / finish, 0.0, 1.0)


func leader() -> Racer:
	return order[0] if not order.is_empty() else null


func gap_to_leader(r: Racer) -> float:
	return maxf(order[0].progress - r.progress, 0.0) if not order.is_empty() else 0.0


func _ahead(a: Racer, b: Racer) -> bool:
	if a.finished != b.finished:
		return a.finished
	if a.finished:
		if a.finish_order != 0 or b.finish_order != 0:
			return a.finish_order != 0 and (b.finish_order == 0 or a.finish_order < b.finish_order)
		if a.finish_time != b.finish_time:
			return a.finish_time < b.finish_time
	elif a.progress != b.progress:
		return a.progress > b.progress
	return a.id < b.id


func _finish_progress() -> float:
	return maxi(laps, 1) * length if closed else (clampf(finish_s, 0.0, length) if finish_s >= 0.0 else length)


func _gate_progress(seq: int) -> float:
	var g := _gs.size()
	if g == 0:
		return INF
	return floori(float(seq) / g) * length + _gs[posmod(seq, g)] if closed else (_gs[seq] if seq < g else INF)


func _gate_index(seq: int) -> int:
	var g := _gs.size()
	return posmod(seq, g) if closed and g > 0 else mini(seq, g)


func _seg_at(s: float) -> int:
	return clampi(_cum.bsearch(s, false) - 1, 0, _len.size() - 1)


func _query_segment(i: int, q: Vector2, start: float, lower: float, upper: float, hint := NAN) -> float:
	var v := q - _p[i]
	var along := clampf(v.dot(_dir[i]), maxf(lower - start, 0.0), minf(upper - start, _len[i]))
	var d2 := (v - _dir[i] * along).length_squared()
	var s := start + along
	var tie := absf(s - hint) if is_finite(hint) else float(i)
	if d2 < _q_d2 - 0.000001 or (absf(d2 - _q_d2) <= 0.000001 and tie < _q_tie):
		_q_d2 = d2
		_q_tie = tie
		_q_s = s
		_q_seg = i
	return d2


func _nearest_window(q: Vector2, hint: float) -> void:
	var window := minf(WINDOW, length * 0.49) if closed else WINDOW
	var lower := hint - window
	var upper := hint + window
	var first := _seg_at(hint)
	var initial := _query_segment(first, q, _cum[first], lower, upper, hint)
	# Search the connected distance basin, stopping before another leg beyond a local
	# maximum. A plain closest-in-window search can jump across a narrow hairpin or an X.
	var direction := -1
	while direction <= 1:
		var i := first
		var start := _cum[first]
		var previous := initial
		var count := 1
		while count < _len.size():
			if direction > 0:
				start += _len[i]
				i += 1
			else:
				i -= 1
			if not closed and (i < 0 or i >= _len.size()):
				break
			i = posmod(i, _len.size())
			if direction < 0:
				start -= _len[i]
			if start > upper or start + _len[i] < lower:
				break
			var best := _q_d2
			var best_tie := _q_tie
			var best_s := _q_s
			var best_seg := _q_seg
			var distance := _query_segment(i, q, start, lower, upper, hint)
			if distance > previous + 0.000001:
				_q_d2 = best
				_q_tie = best_tie
				_q_s = best_s
				_q_seg = best_seg
				break
			previous = distance
			count += 1
		direction += 2


func _nearest_global(q: Vector2) -> void:
	var cx := clampi(floori((q.x - _gx0) / _cell), 0, _nx - 1)
	var cz := clampi(floori((q.y - _gz0) / _cell), 0, _nz - 1)
	var radius := 0
	while radius < maxi(_nx, _nz):
		var x0 := maxi(cx - radius, 0)
		var x1 := mini(cx + radius, _nx - 1)
		var z0 := maxi(cz - radius, 0)
		var z1 := mini(cz + radius, _nz - 1)
		var z := z0
		while z <= z1:
			var x := x0
			while x <= x1:
				if radius == 0 or x == x0 or x == x1 or z == z0 or z == z1:
					var cell := z * _nx + x
					var entry := _cell_start[cell]
					while entry < _cell_start[cell + 1]:
						var seg := _cell_seg[entry]
						_query_segment(seg, q, _cum[seg], 0.0, length)
						entry += 1
				x += 1
			z += 1
		# Every unseen nearest point lies outside this cell rectangle.
		var edge := INF
		if x0 > 0:
			edge = minf(edge, q.x - (_gx0 + x0 * _cell))
		if x1 < _nx - 1:
			edge = minf(edge, _gx0 + (x1 + 1) * _cell - q.x)
		if z0 > 0:
			edge = minf(edge, q.y - (_gz0 + z0 * _cell))
		if z1 < _nz - 1:
			edge = minf(edge, _gz0 + (z1 + 1) * _cell - q.y)
		if _q_d2 < edge * edge:
			return
		radius += 1


static func _same_xz(a: Vector3, b: Vector3) -> bool:
	return Vector2(a.x - b.x, a.z - b.z).length_squared() <= 0.000001


static func _dedupe(points: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p: Vector3 in points:
		if out.is_empty() or not _same_xz(p, out[out.size() - 1]):
			out.append(p)
	return out


func _spline(points: PackedVector3Array, step: float) -> PackedVector3Array:
	var c := _dedupe(points)
	if closed and c.size() > 2 and _same_xz(c[0], c[c.size() - 1]):
		c.resize(c.size() - 1)
	var n := c.size()
	if n < 3:
		return c
	var out := PackedVector3Array()
	for i in (n if closed else n - 1):
		var p1 := c[i]
		var p2 := c[(i + 1) % n]
		var p0 := c[posmod(i - 1, n)] if closed or i > 0 else p1 * 2.0 - p2
		var p3 := c[(i + 2) % n] if closed or i + 2 < n else p2 * 2.0 - p1
		var samples := maxi(1, ceili(Vector2(p2.x - p1.x, p2.z - p1.z).length() / step))
		for j in samples:
			out.append(_catmull(p0, p1, p2, p3, float(j) / samples))
	out.append(c[0] if closed else c[n - 1])
	return out


static func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, u: float) -> Vector3:
	# Centripetal knots depend only on horizontal distance, just like route arc length.
	var t1 := maxf(sqrt(Vector2(p1.x - p0.x, p1.z - p0.z).length()), 0.0001)
	var t2 := t1 + maxf(sqrt(Vector2(p2.x - p1.x, p2.z - p1.z).length()), 0.0001)
	var t3 := t2 + maxf(sqrt(Vector2(p3.x - p2.x, p3.z - p2.z).length()), 0.0001)
	var t := lerpf(t1, t2, u)
	var a1 := p0 * ((t1 - t) / t1) + p1 * (t / t1)
	var a2 := p1 * ((t2 - t) / (t2 - t1)) + p2 * ((t - t1) / (t2 - t1))
	var a3 := p2 * ((t3 - t) / (t3 - t2)) + p3 * ((t - t2) / (t3 - t2))
	var b1 := a1 * ((t2 - t) / t2) + a2 * (t / t2)
	var b2 := a2 * ((t3 - t) / (t3 - t1)) + a3 * ((t - t1) / (t3 - t1))
	return b1 * ((t2 - t) / (t2 - t1)) + b2 * ((t - t1) / (t2 - t1))


func _build(points: PackedVector3Array) -> void:
	var pts := _dedupe(points)
	if closed and pts.size() > 2:
		if _same_xz(pts[0], pts[pts.size() - 1]):
			pts[pts.size() - 1] = pts[0]
		else:
			pts.append(pts[0])
	if pts.size() < (4 if closed else 2):
		push_error("RSRaceTrack needs at least %d distinct horizontal points" % (3 if closed else 2))
		closed = false
		pts = PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -1)])
	var n := pts.size()
	_p.resize(n)
	_y.resize(n)
	_cum.resize(n)
	_curv.resize(n)
	_dir.resize(n - 1)
	_len.resize(n - 1)
	for i in n:
		_p[i] = Vector2(pts[i].x, pts[i].z)
		_y[i] = pts[i].y
	for i in n - 1:
		var d := _p[i + 1] - _p[i]
		_len[i] = d.length()
		_dir[i] = d / _len[i]
		_cum[i + 1] = _cum[i] + _len[i]
	length = _cum[n - 1]
	for i in n:
		var a := i - 1
		var b := i
		if closed and (i == 0 or i == n - 1):
			a = n - 2
			b = 0
		elif i == 0 or i == n - 1:
			continue
		_curv[i] = atan2(_dir[a].cross(_dir[b]), _dir[a].dot(_dir[b])) / ((_len[a] + _len[b]) * 0.5)


func _build_grid() -> void:
	var lo := _p[0]
	var hi := _p[0]
	for p: Vector2 in _p:
		lo = lo.min(p)
		hi = hi.max(p)
	var span := hi - lo
	_cell = CELL
	_nx = floori(span.x / _cell) + 1
	_nz = floori(span.y / _cell) + 1
	while _nx * _nz > MAX_CELLS:
		_cell *= 2.0
		_nx = floori(span.x / _cell) + 1
		_nz = floori(span.y / _cell) + 1
	_gx0 = lo.x
	_gz0 = lo.y
	_cell_start.resize(_nx * _nz + 1)
	_cell_start.fill(0)
	# Compressed rows: count references, prefix-sum, then fill without per-cell arrays.
	for fill in 2:
		var cursor := _cell_start.duplicate() if fill == 1 else PackedInt32Array()
		for s in _len.size():
			var a := _p[s].min(_p[s + 1])
			var b := _p[s].max(_p[s + 1])
			for z in range(floori((a.y - _gz0) / _cell), mini(floori((b.y - _gz0) / _cell), _nz - 1) + 1):
				for x in range(floori((a.x - _gx0) / _cell), mini(floori((b.x - _gx0) / _cell), _nx - 1) + 1):
					var cell := z * _nx + x
					if fill == 0:
						_cell_start[cell + 1] += 1
					else:
						_cell_seg[cursor[cell]] = s
						cursor[cell] += 1
		if fill == 0:
			for cell in _nx * _nz:
				_cell_start[cell + 1] += _cell_start[cell]
			_cell_seg.resize(_cell_start[_nx * _nz])
