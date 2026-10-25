class_name RSRaceTrack
extends RefCounted
## Shared race route for racing sports (jet ski first; skate and ski can migrate later):
## progress along a polyline or Catmull-Rom spline, ordered gates / checkpoints, laps or a
## point-to-point finish, live placing with ties, optional rubber-banding and a bot route
## follower. Pure logic: no nodes, physics or randomness, so the same inputs always give
## the same results, headless or not.
##
## Conventions: metres and seconds. The route lies on the ground, so arc length and every
## projection use the horizontal XZ plane (Y is only carried along by point_at). Godot -Z is
## forward; `lateral` is the signed offset to the right of the direction of travel. `s` is
## arc length from the route start in [0, length]; closed routes wrap and s = 0 is the
## start / finish line (it is not a gate: a gate at s = 0 is also taken on the final
## crossing). A racer's `progress` is unwrapped: lap * length + s.
##
## Usage:
##   var track := RSRaceTrack.new(control_points, true)      # closed loop, spline every 2 m
##   track.laps = 3
##   track.add_gate_between(buoy_left, buoy_right)            # gates stay sorted by s
##   var r := track.add_racer(p.c.player)
##   track.new_race()                                         # every round, then:
##   track.start_racer(r, track.project(grid_pos).x - track.length)   # grid behind the line
##   # each physics step, then once for everyone:
##   var ev := track.update_racer(r, pos, race_clock)        # GATE_MISSED -> penalty
##   track.update_standings()                                 # r.place, r.finish_order
##   # bots:
##   var f := RSRaceTrack.Follower.new(track, 22.0)           # vmax m/s
##   f.lane = 2.0
##   var aim := f.target(r, speed)                            # world point to steer at
##   var steer := RSRaceTrack.steer_angle(forward, pos, aim)  # rad, + = turn right
##   var want := f.speed(r) * track.catch_up(r, best_human.progress)
##
## project, update_racer, update_standings, catch_up and Follower.target / speed do not
## allocate; all tables are built in _init, add_gate and Follower._init. Projection keeps
## each racer on its own part of the route (window around its last s), so hairpins and
## crossing loops do not make it jump to a neighbouring leg; a uniform grid over the
## segments handles the first fix and big jumps (respawn, shortcuts) without a linear scan.

const GATE_PASSED := 1
const GATE_MISSED := 2
const LAP := 4
const FINISHED := 8

const SPLINE_STEP := 2.0       ## m between resampled spline points
const CELL := 16.0             ## m, grid cell edge for global closest-point queries
const MAX_CELLS := 65536       ## bigger routes get bigger cells
const WINDOW := 20.0           ## m searched either side of a racer's last s
const REACQUIRE := 40.0        ## m off the window match before a global search
const WRONG_WAY := 10.0        ## m behind the furthest point reached
const TIE_PROGRESS := 0.001    ## m; closer than this shares a live place
const TIE_TIME := 0.000001     ## s; equal finish times share a place
const MAX_RUBBER := 0.5        ## catch-up factor never leaves [0.5, 1.5]


## One racer's state on the track. Read freely; write only through the track.
class Racer extends RefCounted:
	var id := 0
	var s := 0.0
	var lateral := 0.0
	var progress := 0.0            ## unwrapped metres along the route
	var peak := 0.0                ## furthest progress reached (gates and laps use this)
	var lap := 0                   ## laps completed (closed routes)
	var next_gate := 0             ## gate index to take next; gate_count() when none is left
	var gates_hit := 0
	var gates_missed := 0
	var step_hit := 0              ## gates taken / missed in the latest update_racer
	var step_missed := 0
	var last_gate := -1
	var last_gate_ok := false
	var finished := false
	var finish_time := 0.0         ## interpolated between the two updates around the line
	var finish_order := 0          ## arrival sequence 1, 2, 3 ... (unique); 0 = not yet
	var place := 0                 ## live place, ties share it (1, 1, 3)
	var wrong_way := false
	var _seq := 0                  ## sequence number of the next gate, counting every lap
	var _time := 0.0


## Bot route following: aim point with lookahead and a lane offset, speed from curvature.
class Follower extends RefCounted:
	var track: RSRaceTrack
	var lane := 0.0                ## m right of the centre line
	var lookahead := 6.0           ## m at standstill
	var lookahead_time := 0.6      ## s of travel added to the lookahead
	var gate_margin := 1.0         ## m kept inside a gate window
	var profile := PackedFloat32Array()

	func _init(race_track: RSRaceTrack, vmax: float, lat_accel := 6.0, brake := 8.0, accel := 0.0) -> void:
		track = race_track
		profile = track.speed_profile(vmax, lat_accel, brake, accel)

	func target(r: Racer, speed: float) -> Vector3:
		## World point to steer at, `lookahead` metres plus `lookahead_time` of travel ahead.
		var s := r.s + lookahead + maxf(speed, 0.0) * lookahead_time
		return track.point_at(s) + track.right_at(s) * lane_for(r)

	func lane_for(r: Racer) -> float:
		## The lane, moved inside the next gate's window (less gate_margin) until that gate
		## is taken, so bots line up for buoys well before they reach them.
		if r.next_gate >= track.gate_count():
			return lane
		var w := track.gate_window(r.next_gate)
		if w.y - w.x <= gate_margin * 2.0:
			return (w.x + w.y) * 0.5
		return clampf(lane, w.x + gate_margin, w.y - gate_margin)

	func speed(r: Racer) -> float:
		return track.profile_at(profile, r.s)


var closed := false
var length := 0.0
var laps := 1                  ## closed routes: laps to finish
var finish_s := -1.0           ## open routes: finish line s; < 0 means the route end
var rubber_full_gap := 80.0    ## m of gap for the full catch-up effect
var rubber_boost := 0.0        ## max speed-up behind the reference (0 = off)
var rubber_brake := 0.0        ## max slow-down ahead of the reference (0 = off)
var racers: Array[Racer] = []
var order: Array[Racer] = []   ## after update_standings(): leader first

var _p := PackedVector2Array()     ## vertices (x, z); closed routes repeat the first at the end
var _y := PackedFloat32Array()
var _cum := PackedFloat64Array()   ## s at each vertex
var _dir := PackedVector2Array()   ## unit direction of each segment
var _len := PackedFloat64Array()   ## segment lengths
var _curv := PackedFloat32Array()  ## signed curvature (1/m, + = turning right) at each vertex
var _gs := PackedFloat64Array()    ## gate s, sorted
var _glo := PackedFloat32Array()   ## gate window, lateral metres
var _ghi := PackedFloat32Array()
var _gx0 := 0.0
var _gz0 := 0.0
var _cell := CELL
var _nx := 1
var _nz := 1
var _cell_start := PackedInt32Array()
var _cell_seg := PackedInt32Array()
var _q_d2 := 0.0
var _q_seg := 0
var _finished_count := 0


func _init(points: PackedVector3Array, loop := false, step := SPLINE_STEP) -> void:
	closed = loop
	var pts := _spline(points, step) if step > 0.0 else points.duplicate()
	_build(pts)
	_build_grid()


# ------------------------------------------------------------------------- route ----

func wrap_s(s: float) -> float:
	return fposmod(s, length) if closed else clampf(s, 0.0, length)


func delta_s(from_s: float, to_s: float) -> float:
	## Signed distance along the route; the short way round on closed routes.
	return wrapf(to_s - from_s, -length * 0.5, length * 0.5) if closed else to_s - from_s


func segment_count() -> int:
	return _len.size()


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
	## (s, lateral) of the closest route point. With hint_s (the racer's last s) only the
	## route near it is searched, unless that match is more than REACQUIRE metres away.
	var q := Vector2(pos.x, pos.z)
	var seg := -1
	if not is_nan(hint_s):
		seg = _nearest_window(q, hint_s)
		if _q_d2 > REACQUIRE * REACQUIRE:
			seg = -1
	if seg < 0:
		seg = _nearest_global(q)
	var v := q - _p[seg]
	var d := _dir[seg]
	var s := _cum[seg] + clampf(v.dot(d), 0.0, _len[seg])
	if closed and s >= length:
		s -= length
	return Vector2(s, v.x * -d.y + v.y * d.x)


static func steer_angle(forward: Vector3, from: Vector3, to: Vector3) -> float:
	## Horizontal angle (rad) from `forward` to the direction from -> to; + = to the right.
	var dx := to.x - from.x
	var dz := to.z - from.z
	return atan2(forward.x * dz - forward.z * dx, forward.x * dx + forward.z * dz)


func speed_profile(vmax: float, lat_accel: float, brake: float, accel := 0.0) -> PackedFloat32Array:
	## Target speed at each vertex: capped by lateral acceleration in the bends, with
	## braking (and, if accel > 0, acceleration) limits spread along the route.
	var n := _p.size()
	var v := PackedFloat32Array()
	v.resize(n)
	for i in n:
		v[i] = minf(vmax, sqrt(maxf(lat_accel, 0.0) / maxf(absf(_curv[i]), 0.000001)))
	var passes := 2 if closed else 1
	if brake > 0.0:
		for k in passes * (n - 1):
			var i := (n - 2) - k % (n - 1)
			v[i] = minf(v[i], sqrt(v[i + 1] * v[i + 1] + 2.0 * brake * _len[i]))
			if closed and i == 0:
				v[n - 1] = v[0]
	if accel > 0.0:
		for k in passes * (n - 1):
			var i := 1 + k % (n - 1)
			v[i] = minf(v[i], sqrt(v[i - 1] * v[i - 1] + 2.0 * accel * _len[i - 1]))
			if closed and i == n - 1:
				v[0] = v[n - 1]
	return v


func profile_at(profile: PackedFloat32Array, s: float) -> float:
	var ws := wrap_s(s)
	var i := _seg_at(ws)
	return lerpf(profile[i], profile[i + 1], clampf((ws - _cum[i]) / _len[i], 0.0, 1.0))


# ------------------------------------------------------------------------- gates ----

func add_gate(s: float, lo := -INF, hi := INF) -> int:
	## A gate across the route at s, passable for lateral offsets in [lo, hi]. Returns its
	## index in s order. Add every gate before starting racers.
	var ws := wrap_s(s)
	var i := _gs.bsearch(ws, false)
	_gs.insert(i, ws)
	_glo.insert(i, minf(lo, hi))
	_ghi.insert(i, maxf(lo, hi))
	return i


func add_gate_between(a: Vector3, b: Vector3) -> int:
	## A gate between two markers (buoys, flags) placed across the route.
	var s := project((a + b) * 0.5).x
	var c := point_at(s)
	var r := right_at(s)
	return add_gate(s, (a - c).dot(r), (b - c).dot(r))


func gate_count() -> int:
	return _gs.size()


func gate_s(i: int) -> float:
	return _gs[i]


func gate_window(i: int) -> Vector2:
	return Vector2(_glo[i], _ghi[i])


func gate_point(i: int) -> Vector3:
	## Middle of the gate window (the route point for an unbounded gate).
	var mid := 0.0
	if is_finite(_glo[i]) and is_finite(_ghi[i]):
		mid = (_glo[i] + _ghi[i]) * 0.5
	return point_at(_gs[i]) + right_at(_gs[i]) * mid


func gate_progress(seq: int) -> float:
	## Unwrapped position of gate number `seq` counted over every lap; INF past the last.
	var g := _gs.size()
	if g == 0:
		return INF
	if closed:
		return floori(float(seq) / g) * length + _gs[posmod(seq, g)]
	return _gs[seq] if seq < g else INF


func finish_progress() -> float:
	if closed:
		return maxi(laps, 1) * length
	return clampf(finish_s, 0.0, length) if finish_s >= 0.0 else length


# ------------------------------------------------------------------------ racers ----

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
	## Forget the previous arrival order; call before start_racer() for a new round.
	_finished_count = 0
	for r: Racer in racers:
		r.finish_order = 0
		r.place = 0


func start_racer(r: Racer, start_progress: float, time := 0.0) -> void:
	## Put a racer on the grid. On closed routes a negative start is behind the line, so
	## the first crossing does not count as a lap.
	r.progress = start_progress if closed else clampf(start_progress, 0.0, length)
	r.peak = r.progress
	r.s = wrap_s(r.progress)
	r.lateral = 0.0
	r.lap = 0
	r.gates_hit = 0
	r.gates_missed = 0
	r.step_hit = 0
	r.step_missed = 0
	r.last_gate = -1
	r.last_gate_ok = false
	r.finished = false
	r.finish_time = 0.0
	r.finish_order = 0
	r.place = 0
	r.wrong_way = false
	r._time = time
	var g := _gs.size()
	r._seq = 0
	if g > 0:
		if closed:
			r._seq = floori(r.peak / length) * g
		while gate_progress(r._seq) <= r.peak:
			r._seq += 1
	r.next_gate = _gate_index(r._seq)


func update_racer(r: Racer, pos: Vector3, time: float) -> int:
	## Move a racer to `pos` at race time `time`; returns GATE_PASSED | GATE_MISSED | LAP |
	## FINISHED bits for what happened since the last update. Finished racers keep their s
	## and progress updated but raise no more events.
	r.step_hit = 0
	r.step_missed = 0
	var q := project(pos, r.s)
	var prev := r.progress
	var prev_lat := r.lateral
	var prev_time := r._time
	r.progress += delta_s(r.s, q.x)
	r.s = q.x
	r.lateral = q.y
	r._time = time
	r.wrong_way = not r.finished and r.peak - r.progress > WRONG_WAY
	if r.finished or r.progress <= r.peak:
		return 0
	var ev := 0
	var fin := finish_progress()
	var span := r.progress - prev
	var gp := gate_progress(r._seq)
	while gp <= r.progress and gp <= fin:
		var i := _gate_index(r._seq)
		var lat := lerpf(prev_lat, q.y, (gp - prev) / span)
		r.last_gate = i
		r.last_gate_ok = lat >= _glo[i] and lat <= _ghi[i]
		if r.last_gate_ok:
			r.gates_hit += 1
			r.step_hit += 1
			ev |= GATE_PASSED
		else:
			r.gates_missed += 1
			r.step_missed += 1
			ev |= GATE_MISSED
		r._seq += 1
		gp = gate_progress(r._seq)
	r.next_gate = _gate_index(r._seq) if gp <= fin else _gs.size()
	r.peak = r.progress
	if closed:
		var lap := clampi(floori(r.peak / length), 0, maxi(laps, 1))
		if lap > r.lap:
			r.lap = lap
			ev |= LAP
	if r.peak >= fin:
		r.finished = true
		r.finish_time = lerpf(prev_time, time, clampf((fin - prev) / span, 0.0, 1.0))
		ev |= FINISHED
	return ev


func fraction(r: Racer) -> float:
	## Share of the race done, for progress bars.
	var fin := finish_progress()
	if r.finished or fin <= 0.0:
		return 1.0
	return clampf(r.peak / fin, 0.0, 1.0)


func update_standings() -> void:
	## Sort `order` (finished by time, then the rest by progress; id breaks exact ties so the
	## order is stable), hand out finish_order to new finishers and set live places.
	var n := order.size()
	for i in n:
		var r := order[i]
		var j := i - 1
		while j >= 0 and _ahead(r, order[j]):
			order[j + 1] = order[j]
			j -= 1
		order[j + 1] = r
	for i in n:
		var r := order[i]
		if r.finished and r.finish_order == 0:
			_finished_count += 1
			r.finish_order = _finished_count
		r.place = order[i - 1].place if i > 0 and _tied(order[i - 1], r) else i + 1


func leader() -> Racer:
	return order[0] if not order.is_empty() else null


func gap_to_leader(r: Racer) -> float:
	## Metres behind the leader by progress (0 for the leader).
	return maxf(order[0].progress - r.progress, 0.0) if not order.is_empty() else 0.0


func catch_up(r: Racer, reference_progress: float) -> float:
	## Speed factor pulling `r` towards the reference (for example the best human's
	## progress). 1.0 while rubber_boost and rubber_brake are 0 (the default) and after the finish.
	if r.finished:
		return 1.0
	return rubber_band(reference_progress - r.progress, rubber_full_gap, rubber_boost, rubber_brake)


static func rubber_band(gap: float, full_gap: float, boost: float, brake: float) -> float:
	## gap > 0 is behind the reference: up to 1 + boost at full_gap; gap < 0 is ahead: down
	## to 1 - brake. Linear in between, clamped, and both limits are capped at MAX_RUBBER.
	if full_gap <= 0.0:
		return 1.0
	var x := clampf(gap / full_gap, -1.0, 1.0)
	return 1.0 + x * clampf(boost if x > 0.0 else brake, 0.0, MAX_RUBBER)


# ---------------------------------------------------------------------- internals ----

func _ahead(a: Racer, b: Racer) -> bool:
	if a.finished != b.finished:
		return a.finished
	if a.finished:
		if a.finish_time != b.finish_time:
			return a.finish_time < b.finish_time
	elif a.progress != b.progress:
		return a.progress > b.progress
	return a.id < b.id


func _tied(a: Racer, b: Racer) -> bool:
	if a.finished != b.finished:
		return false
	if a.finished:
		return absf(a.finish_time - b.finish_time) <= TIE_TIME
	return absf(a.progress - b.progress) <= TIE_PROGRESS


func _gate_index(seq: int) -> int:
	var g := _gs.size()
	if g == 0:
		return 0
	return posmod(seq, g) if closed else mini(seq, g)


func _seg_at(ws: float) -> int:
	return clampi(_cum.bsearch(ws, false) - 1, 0, _len.size() - 1)


func _seg_d2(i: int, q: Vector2) -> float:
	var v := q - _p[i]
	var d := _dir[i]
	return (v - d * clampf(v.dot(d), 0.0, _len[i])).length_squared()


func _nearest_window(q: Vector2, hint_s: float) -> int:
	var segs := _len.size()
	var a := _seg_at(wrap_s(hint_s - WINDOW))
	var b := _seg_at(wrap_s(hint_s + WINDOW))
	var count := b - a + 1
	if closed:
		count = segs if WINDOW * 2.0 >= length else posmod(b - a, segs) + 1
	var best := INF
	var best_i := a
	var i := a
	for _k in count:
		var d2 := _seg_d2(i, q)
		if d2 < best:
			best = d2
			best_i = i
		i += 1
		if i == segs:
			i = 0
	_q_d2 = best
	return best_i


func _nearest_global(q: Vector2) -> int:
	var ci := clampi(floori((q.x - _gx0) / _cell), 0, _nx - 1)
	var cj := clampi(floori((q.y - _gz0) / _cell), 0, _nz - 1)
	_q_d2 = INF
	_q_seg = 0
	var ring := 0
	while true:
		var i0 := ci - ring
		var i1 := ci + ring
		var j0 := cj - ring
		var j1 := cj + ring
		for j in range(maxi(j0, 0), mini(j1, _nz - 1) + 1):
			if j == j0 or j == j1:
				for i in range(maxi(i0, 0), mini(i1, _nx - 1) + 1):
					_visit_cell(j * _nx + i, q)
			else:
				# Inner rows of the ring only have its two side cells.
				if i0 >= 0:
					_visit_cell(j * _nx + i0, q)
				if i1 < _nx:
					_visit_cell(j * _nx + i1, q)
		# Every segment not yet seen lies outside the visited square of cells.
		var bound := INF
		if i0 > 0:
			bound = minf(bound, q.x - (_gx0 + i0 * _cell))
		if i1 < _nx - 1:
			bound = minf(bound, _gx0 + (i1 + 1) * _cell - q.x)
		if j0 > 0:
			bound = minf(bound, q.y - (_gz0 + j0 * _cell))
		if j1 < _nz - 1:
			bound = minf(bound, _gz0 + (j1 + 1) * _cell - q.y)
		if bound == INF or _q_d2 <= bound * bound:
			break
		ring += 1
	return _q_seg


func _visit_cell(c: int, q: Vector2) -> void:
	for k in range(_cell_start[c], _cell_start[c + 1]):
		var seg := _cell_seg[k]
		var d2 := _seg_d2(seg, q)
		# Lowest index on exact ties, so the answer does not depend on the visiting order.
		if d2 < _q_d2 or (d2 == _q_d2 and seg < _q_seg):
			_q_d2 = d2
			_q_seg = seg


func _spline(points: PackedVector3Array, step: float) -> PackedVector3Array:
	## Centripetal Catmull-Rom through the control points, sampled about every `step` m.
	var c := _dedupe(points)
	if closed and c.size() > 2 and c[0].is_equal_approx(c[c.size() - 1]):
		c.resize(c.size() - 1)
	var m := c.size()
	if m < 3:
		return c
	var out := PackedVector3Array()
	var spans := m if closed else m - 1
	for i in spans:
		var p1 := c[i]
		var p2 := c[(i + 1) % m]
		var p0 := c[posmod(i - 1, m)] if closed or i > 0 else p1 * 2.0 - p2
		var p3 := c[(i + 2) % m] if closed or i + 2 < m else p2 * 2.0 - p1
		var k := maxi(1, ceili(p1.distance_to(p2) / step))
		for j in k:
			out.append(_catmull(p0, p1, p2, p3, float(j) / k))
	out.append(c[0] if closed else c[m - 1])
	return out


static func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, u: float) -> Vector3:
	var t1 := maxf(sqrt(p0.distance_to(p1)), 0.0001)
	var t2 := t1 + maxf(sqrt(p1.distance_to(p2)), 0.0001)
	var t3 := t2 + maxf(sqrt(p2.distance_to(p3)), 0.0001)
	var t := lerpf(t1, t2, u)
	var a1 := p0 * ((t1 - t) / t1) + p1 * (t / t1)
	var a2 := p1 * ((t2 - t) / (t2 - t1)) + p2 * ((t - t1) / (t2 - t1))
	var a3 := p2 * ((t3 - t) / (t3 - t2)) + p3 * ((t - t2) / (t3 - t2))
	var b1 := a1 * ((t2 - t) / t2) + a2 * (t / t2)
	var b2 := a2 * ((t3 - t) / (t3 - t1)) + a3 * ((t - t1) / (t3 - t1))
	return b1 * ((t2 - t) / (t2 - t1)) + b2 * ((t - t1) / (t2 - t1))


static func _dedupe(points: PackedVector3Array) -> PackedVector3Array:
	## Drop points that would make zero-length (horizontal) segments.
	var out := PackedVector3Array()
	for p: Vector3 in points:
		if out.is_empty() or Vector2(p.x - out[out.size() - 1].x, p.z - out[out.size() - 1].z).length_squared() > 0.000001:
			out.append(p)
	return out


func _build(points: PackedVector3Array) -> void:
	var pts := _dedupe(points)
	if closed and pts.size() > 2 and not pts[0].is_equal_approx(pts[pts.size() - 1]):
		pts.append(pts[0])
	if pts.size() < (4 if closed else 2):
		push_error("RSRaceTrack needs at least %d distinct points" % (3 if closed else 2))
		closed = false
		pts = PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -1)])
	var n := pts.size()
	_p.resize(n)
	_y.resize(n)
	_cum.resize(n)
	_curv.resize(n)
	_dir.resize(n - 1)
	_len.resize(n - 1)
	_cum[0] = 0.0
	for i in n:
		_p[i] = Vector2(pts[i].x, pts[i].z)
		_y[i] = pts[i].y
	for i in n - 1:
		var d := _p[i + 1] - _p[i]
		_len[i] = d.length()
		_dir[i] = d / _len[i]
		_cum[i + 1] = _cum[i] + _len[i]
	length = _cum[n - 1]
	# Turning angle over the mean neighbouring segment length, then a light smoothing so
	# the bot speed profile does not jitter between samples.
	for i in n:
		_curv[i] = 0.0
		var a := i - 1
		var b := i
		if closed and (i == 0 or i == n - 1):
			a = n - 2
			b = 0
		elif i == 0 or i == n - 1:
			continue
		var d_in := _dir[a]
		var d_out := _dir[b]
		_curv[i] = atan2(d_in.cross(d_out), d_in.dot(d_out)) / ((_len[a] + _len[b]) * 0.5)
	for _pass in 2:
		var prev := _curv[n - 2] if closed else _curv[0]
		for i in n - 1:
			var cur := _curv[i]
			var nxt := _curv[i + 1]
			_curv[i] = (prev + cur * 2.0 + nxt) * 0.25
			prev = cur
		_curv[n - 1] = _curv[0] if closed else _curv[n - 1]


func _build_grid() -> void:
	var lo := _p[0]
	var hi := _p[0]
	for p: Vector2 in _p:
		lo = lo.min(p)
		hi = hi.max(p)
	var span := hi - lo
	_cell = maxf(CELL, sqrt(maxf(span.x, 1.0) * maxf(span.y, 1.0) / MAX_CELLS))
	_gx0 = lo.x
	_gz0 = lo.y
	_nx = floori(span.x / _cell) + 1
	_nz = floori(span.y / _cell) + 1
	_cell_start.resize(_nx * _nz + 1)
	_cell_start.fill(0)
	# Two passes over each segment's cell box: count, then fill (compressed rows).
	for fill in 2:
		var cursor := _cell_start.duplicate() if fill == 1 else PackedInt32Array()
		for s in _len.size():
			var a := _p[s].min(_p[s + 1])
			var b := _p[s].max(_p[s + 1])
			for j in range(floori((a.y - _gz0) / _cell), mini(floori((b.y - _gz0) / _cell), _nz - 1) + 1):
				for i in range(floori((a.x - _gx0) / _cell), mini(floori((b.x - _gx0) / _cell), _nx - 1) + 1):
					var c := j * _nx + i
					if fill == 0:
						_cell_start[c + 1] += 1
					else:
						_cell_seg[cursor[c]] = s
						cursor[c] += 1
		if fill == 0:
			for c in _nx * _nz:
				_cell_start[c + 1] += _cell_start[c]
			_cell_seg.resize(_cell_start[_nx * _nz])
