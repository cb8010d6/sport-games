extends Node
## RSRaceTrack: route geometry against analytic shapes, grid queries against brute force,
## gates, laps, finish interpolation, live placing and ties, rubber-banding, bot following,
## determinism and a performance budget (4 racers at 120 Hz on a 2 km route).

const HZ := 120.0
const BUDGET_STEP_US := 1000.0     ## 4 racers + standings + 4 bots per 120 Hz step, generous for CI
const BUDGET_GLOBAL_US := 400.0    ## one cold closest-point query on a 2 km route

var _checks := 0
var _failures := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("FAIL: " + message)


func _near(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


func _run() -> void:
	_straight()
	_circle()
	_grid_matches_brute_force()
	_hairpin_continuity()
	_gates_open()
	_laps_closed()
	_standings()
	_rubber_band()
	_follower()
	_determinism()
	_performance()
	print("RS_RACE_TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)


# --------------------------------------------------------------------- shapes ----

func _line(len_m: float) -> PackedVector3Array:
	return PackedVector3Array([Vector3(0, 0, 0), Vector3(0, -len_m * 0.5, -len_m * 0.5), Vector3(0, -len_m, -len_m)])


func _circle_points(radius: float, count: int, clockwise: bool) -> PackedVector3Array:
	## Starts at (0, 0, 0) heading -Z; clockwise seen from above turns right.
	var pts := PackedVector3Array()
	for i in count:
		var a := TAU * i / count
		var side := 1.0 if clockwise else -1.0
		pts.append(Vector3(side * radius * (1.0 - cos(a)), 0, -radius * sin(a)))
	return pts


func _two_km_loop() -> PackedVector3Array:
	## Wiggly closed loop of roughly 2 km: a stretched ellipse with bends.
	var pts := PackedVector3Array()
	for i in 48:
		var a := TAU * i / 48.0
		var r := 1.0 + 0.18 * sin(3.0 * a) + 0.08 * cos(5.0 * a)
		pts.append(Vector3(r * 420.0 * sin(a), 4.0 * sin(2.0 * a), r * 220.0 * (1.0 - cos(a)) * -1.0))
	return pts


# ---------------------------------------------------------------------- tests ----

func _straight() -> void:
	var t := RSRaceTrack.new(_line(100.0), false, 0.0)
	_check(_near(t.length, 100.0, 0.0001), "straight length uses horizontal distance")
	_check(t.point_at(30).is_equal_approx(Vector3(0, -30, -30)), "point_at interpolates position and height")
	_check(t.point_at(-5).is_equal_approx(Vector3.ZERO) and t.point_at(500).is_equal_approx(Vector3(0, -100, -100)), "open route clamps s")
	_check(t.tangent_at(10).is_equal_approx(Vector3.FORWARD), "tangent points along -Z")
	_check(t.right_at(10).is_equal_approx(Vector3.RIGHT), "right of -Z travel is +X")
	var q := t.project(Vector3(3, 50, -42))
	_check(_near(q.x, 42, 0.0001) and _near(q.y, 3, 0.0001), "projection gives s and signed lateral (+ right)")
	q = t.project(Vector3(-2.5, 0, -42), 40.0)
	_check(_near(q.x, 42, 0.0001) and _near(q.y, -2.5, 0.0001), "hinted projection matches, left is negative")
	q = t.project(Vector3(0, 0, 20))
	_check(_near(q.x, 0, 0.0001), "projection before the start clamps to s = 0")
	_check(_near(t.curvature_at(50), 0, 0.000001), "straight has no curvature")
	var dup := RSRaceTrack.new(PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3(0, 0, -10), Vector3(0, 0, -10), Vector3(0, 0, -20)]))
	_check(_near(dup.length, 20, 0.001) and dup.segment_count() > 0, "duplicate points are dropped before building")
	_check(_near(RSRaceTrack.steer_angle(Vector3.FORWARD, Vector3.ZERO, Vector3(1, 0, -1)), PI / 4, 0.00001), "steer_angle is + for a target on the right")
	_check(_near(RSRaceTrack.steer_angle(Vector3.FORWARD, Vector3.ZERO, Vector3(-1, 0, 0)), -PI / 2, 0.00001), "steer_angle is - for a target on the left")


func _circle() -> void:
	var radius := 50.0
	for clockwise: bool in [true, false]:
		var t := RSRaceTrack.new(_circle_points(radius, 16, clockwise), true)
		_check(_near(t.length, TAU * radius, TAU * radius * 0.005), "spline circle length within 0.5 %")
		var k := t.curvature_at(t.length * 0.3)
		_check(_near(absf(k), 1.0 / radius, 0.03 / radius), "curvature magnitude is 1 / radius")
		_check(signf(k) == (1.0 if clockwise else -1.0), "curvature sign: + turning right")
		_check(_near(t.wrap_s(t.length + 3.0), 3.0, 0.0001) and _near(t.wrap_s(-3.0), t.length - 3.0, 0.0001), "closed route wraps s")
		_check(_near(t.delta_s(t.length - 2.0, 3.0), 5.0, 0.0001), "delta_s takes the short way across the line")
		for i in 12:
			var a := TAU * (i + 0.5) / 12.0
			var side := 1.0 if clockwise else -1.0
			var centre := Vector3(side * radius, 0, 0)
			var on := Vector3(side * radius * (1.0 - cos(a)), 0, -radius * sin(a))
			var out := centre + (on - centre) * 1.1
			var q := t.project(out)
			_check(_near(q.x / t.length, a / TAU, 0.004), "circle projection s follows the angle")
			# Outside of a right-hand (clockwise) circle is the left side.
			_check(_near(q.y, -side * radius * 0.1, 0.3), "circle lateral sign and size")


func _brute(t: RSRaceTrack, q: Vector3) -> float:
	var best := INF
	for i in t.segment_count():
		var d := t._dir[i]
		var v := Vector2(q.x, q.z) - t._p[i]
		best = minf(best, (v - d * clampf(v.dot(d), 0.0, t._len[i])).length())
	return best


func _grid_matches_brute_force() -> void:
	var t := RSRaceTrack.new(_two_km_loop(), true)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4711
	var worst := 0.0
	for i in 400:
		# Points near the route, far off it, and well outside the grid bounds.
		var q := Vector3(rng.randf_range(-700, 700), 0, rng.randf_range(-700, 250))
		if i % 2 == 0:
			var s := rng.randf_range(0, t.length)
			q = t.point_at(s) + t.right_at(s) * rng.randf_range(-30, 30)
		var p := t.project(q)
		var got := Vector2(q.x, q.z).distance_to(Vector2(t.point_at(p.x).x, t.point_at(p.x).z))
		worst = maxf(worst, absf(got - _brute(t, q)))
	_check(worst < 0.01, "grid query equals brute-force nearest distance (worst %.4f m)" % worst)
	var big := RSRaceTrack.new(PackedVector3Array([Vector3(0, 0, 0), Vector3(20000, 0, 0), Vector3(20000, 0, -20000)]), false, 0.0)
	_check(big._nx * big._nz <= RSRaceTrack.MAX_CELLS + 2 * (big._nx + big._nz), "large routes cap the grid size")
	var p := big.project(Vector3(19990, 0, -10000))
	_check(_near(p.x, 30000, 0.01) and _near(p.y, -10, 0.01), "large route query still exact")


func _hairpin_continuity() -> void:
	# Two parallel legs 8 m apart joined by a hairpin: a racer wide on leg 1 is nearer to leg 2.
	var pts := PackedVector3Array([Vector3(0, 0, 0), Vector3(0, 0, -100), Vector3(-4, 0, -104), Vector3(-8, 0, -100), Vector3(-8, 0, 0)])
	var t := RSRaceTrack.new(pts, false, 0.0)
	var pos := Vector3(-5.5, 0, -50)
	var global := t.project(pos)
	var hinted := t.project(pos, 50.0)
	_check(global.x > t.length * 0.5, "global query snaps to the nearer second leg")
	_check(_near(hinted.x, 50.0, 0.001) and _near(hinted.y, -5.5, 0.001), "hinted query keeps the racer on its own leg")
	var r := t.add_racer(1)
	t.start_racer(r, 0.0)
	for i in 101:
		t.update_racer(r, Vector3(-5.5 * minf(i / 10.0, 1.0), 0, -i * 0.9), i / HZ)
	_check(r.progress < 95.0 and r.progress > 85.0, "tracked racer stays on leg 1 while wide")
	t.update_racer(r, Vector3(-48, 0, -20), 1.0)
	_check(r.progress > t.length - 30.0, "a jump beyond REACQUIRE re-finds the racer globally")


func _gates_open() -> void:
	var t := RSRaceTrack.new(PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -200)]), false, 0.0)
	t.finish_s = 180.0
	_check(t.add_gate(60, -3, 3) == 0 and t.add_gate(20, -2, 2) == 0 and t.add_gate(100, 1, 5) == 2, "gates are kept sorted by s")
	var bi := t.add_gate_between(Vector3(4, 0, -140), Vector3(-4, 0, -140))
	_check(bi == 3 and _near(t.gate_s(3), 140, 0.001) and t.gate_window(3).is_equal_approx(Vector2(-4, 4)), "gate between markers projects and orders its window")
	t.add_gate(190, -2, 2)
	_check(t.gate_point(2).is_equal_approx(Vector3(3, 0, -100)), "gate_point is the window middle")
	var r := t.add_racer(7)
	t.new_race()
	t.start_racer(r, 0.0)
	_check(r.next_gate == 0, "first gate is next")
	var events := 0
	var lat := 0.0
	var passed := 0
	var missed := 0
	for i in 2200:
		var z := i * 0.1
		lat = 4.0 if z > 90.0 and z < 110.0 else (2.5 if z > 10.0 and z < 30.0 else 0.0)
		var ev := t.update_racer(r, Vector3(lat, 0, -z), i / HZ)
		events |= ev
		passed += r.step_hit
		missed += r.step_missed
		if ev & RSRaceTrack.GATE_MISSED:
			_check(r.last_gate == 0 and not r.last_gate_ok, "the 2.5 m line misses the narrow gate at 20 m")
	_check(r.gates_hit == 3 and r.gates_missed == 1 and passed == 3 and missed == 1, "hits and misses counted once each")
	_check(r.finished and events & RSRaceTrack.FINISHED and events & RSRaceTrack.GATE_PASSED, "finish and gate events raised")
	_check(r.next_gate == t.gate_count(), "no gate after the finish is pending")
	_check(_near(r.finish_time, 1800.0 / HZ, 0.0001), "finish time interpolated at the line")
	_check(t.fraction(r) == 1.0, "fraction is 1 after the finish")
	# A big step crosses several gates at once; going back and forward does not repeat them.
	var b := t.add_racer(8)
	t.start_racer(b, 10.0)
	_check(b.next_gate == 0, "start before the first gate")
	t.update_racer(b, Vector3(0, 0, -30), 0.1)
	t.update_racer(b, Vector3(0, 0, -25), 0.2)
	t.update_racer(b, Vector3(0, 0, -22), 0.3)
	_check(not b.wrong_way and b.gates_hit == 1, "small reversal is not wrong way")
	t.update_racer(b, Vector3(0, 0, -15), 0.4)
	_check(b.wrong_way, "riding back past WRONG_WAY sets wrong_way")
	t.update_racer(b, Vector3(0, 0, -35), 0.5)
	_check(not b.wrong_way and b.gates_hit == 1 and b.gates_missed == 0, "re-crossing a gate does not count again")
	t.update_racer(b, Vector3(0, 0, -120), 0.8)
	_check(b.step_hit + b.step_missed == 2 and b.gates_hit + b.gates_missed == 3, "one long step resolves every gate it crosses")
	_check(b.last_gate == 2 and not b.last_gate_ok, "centre line misses the offset gate")


func _laps_closed() -> void:
	var t := RSRaceTrack.new(_circle_points(40.0, 12, true), true)
	t.laps = 3
	var g := [t.length * 0.25, t.length * 0.5, t.length * 0.75]
	for s: float in g:
		t.add_gate(s, -3, 3)
	var r := t.add_racer(1)
	t.new_race()
	t.start_racer(r, -12.0)
	_check(_near(r.s, t.length - 12.0, 0.001) and r.next_gate == 0, "grid behind the line starts on the previous lap")
	var laps_seen := 0
	var finish_ev := 0
	var step := 0.25
	var s := -12.0
	var time := 0.0
	while s < t.length * 3.0 + 20.0:
		s += step
		time += 1.0 / HZ
		var ev := t.update_racer(r, t.point_at(s) + t.right_at(s) * (1.0 * sin(s * 0.1)), time)
		if ev & RSRaceTrack.LAP:
			laps_seen += 1
		if ev & RSRaceTrack.FINISHED:
			finish_ev += 1
	_check(laps_seen == 3 and r.lap == 3, "three laps counted, first line crossing is not a lap")
	_check(finish_ev == 1 and r.finished, "finish raised once")
	_check(r.gates_hit == 9 and r.gates_missed == 0, "every gate on every lap taken once")
	var expected := (t.length * 3.0 + 12.0) / step / HZ
	_check(_near(r.finish_time, expected, 1.5 / HZ), "finish time from the unwrapped distance")
	_check(_near(r.progress, s, 0.05), "progress keeps counting after the finish")
	# A racer that cuts a third of the lap misses the gate there.
	var c := t.add_racer(2)
	t.start_racer(c, 1.0)
	var cs := 1.0
	while cs < t.length * 0.3:
		cs += 1.0
		var off := 10.0 * clampf((cs - t.length * 0.15) / 10.0, 0.0, 1.0)
		t.update_racer(c, t.point_at(cs) + t.right_at(cs) * off, cs)
	_check(c.gates_missed == 1 and c.next_gate == 1, "gate missed when crossing outside its window")


func _standings() -> void:
	var t := RSRaceTrack.new(PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -200)]), false, 0.0)
	t.finish_s = 100.0
	var rs: Array[RSRaceTrack.Racer] = []
	for id in 4:
		rs.append(t.add_racer(id + 1))
	t.new_race()
	for r: RSRaceTrack.Racer in rs:
		t.start_racer(r, 0.0)
	t.update_racer(rs[0], Vector3(0, 0, -10), 0.1)
	t.update_racer(rs[1], Vector3(0, 0, -30), 0.1)
	t.update_racer(rs[2], Vector3(0, 0, -30), 0.1)
	t.update_racer(rs[3], Vector3(0, 0, -5), 0.1)
	t.update_standings()
	_check(rs[1].place == 1 and rs[2].place == 1 and rs[0].place == 3 and rs[3].place == 4, "equal progress shares a place (1, 1, 3, 4)")
	_check(t.order[0] == rs[1] and t.order[1] == rs[2], "exact ties ordered by id")
	_check(t.leader() == rs[1] and _near(t.gap_to_leader(rs[3]), 25, 0.001) and t.gap_to_leader(rs[1]) == 0.0, "leader and gap")
	# Same step, updated in reverse: the one that crossed earlier in the step finishes first.
	t.update_racer(rs[3], Vector3(0, 0, -98), 1.0)
	t.update_racer(rs[0], Vector3(0, 0, -90), 1.0)
	t.update_racer(rs[3], Vector3(0, 0, -102), 1.1)     # crosses at 1.05
	t.update_racer(rs[0], Vector3(0, 0, -110), 1.1)     # crosses at 1.05 too: tie
	t.update_racer(rs[1], Vector3(0, 0, -60), 1.1)
	t.update_racer(rs[2], Vector3(0, 0, -101), 1.1)     # 30 -> 101 from 0.1 s: crosses at ~1.086
	t.update_standings()
	_check(rs[0].finished and rs[3].finished and rs[2].finished and not rs[1].finished, "three finished")
	_check(rs[0].finish_order == 1 and rs[3].finish_order == 2 and rs[2].finish_order == 3, "arrival order by interpolated time, id on exact ties")
	_check(rs[0].place == 1 and rs[3].place == 1 and rs[2].place == 3 and rs[1].place == 4, "equal finish times share a place, finished ahead of riders still racing")
	t.update_racer(rs[1], Vector3(0, 0, -100), 3.0)
	t.update_racer(rs[2], Vector3(0, 0, -100), 3.0)
	t.update_standings()
	_check(rs[1].finish_order == 4 and rs[1].place == 4 and rs[2].finish_order == 3, "late finisher is fourth; finish order stays frozen")
	t.new_race()
	for r: RSRaceTrack.Racer in rs:
		t.start_racer(r, 0.0)
	t.update_racer(rs[2], Vector3(0, 0, -101), 0.5)
	t.update_standings()
	_check(rs[2].finish_order == 1 and rs[0].finish_order == 0, "new_race restarts the arrival order")
	t.remove_racer(rs[2])
	t.update_standings()
	_check(t.order.size() == 3 and t.racers.size() == 3 and not t.order.has(rs[2]), "removed racer leaves the standings")


func _rubber_band() -> void:
	var t := RSRaceTrack.new(PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -500)]), false, 0.0)
	var r := t.add_racer(1)
	t.update_racer(r, Vector3(0, 0, -100), 1.0)
	_check(t.catch_up(r, 300.0) == 1.0 and t.catch_up(r, 0.0) == 1.0, "rubber-banding is off by default")
	t.rubber_boost = 0.1
	t.rubber_brake = 0.05
	_check(_near(t.catch_up(r, 140.0), 1.05, 0.00001), "half the full gap gives half the boost")
	_check(_near(t.catch_up(r, 400.0), 1.1, 0.00001), "boost bounded at full gap")
	_check(_near(t.catch_up(r, 0.0), 0.95, 0.00001), "leader ahead of the reference is slowed, bounded")
	_check(t.catch_up(r, 100.0) == 1.0, "no gap, no change")
	_check(_near(RSRaceTrack.rubber_band(1000, 10, 5, 5), 1.0 + RSRaceTrack.MAX_RUBBER, 0.00001) and _near(RSRaceTrack.rubber_band(-1000, 10, 5, 5), 1.0 - RSRaceTrack.MAX_RUBBER, 0.00001), "factors capped at MAX_RUBBER")
	_check(RSRaceTrack.rubber_band(50, 0, 0.2, 0.2) == 1.0, "zero full gap disables it")
	var last := 0.0
	var mono := true
	for i in 41:
		var f := RSRaceTrack.rubber_band(-200.0 + i * 10.0, 80.0, 0.12, 0.08)
		mono = mono and f >= last
		last = f
	_check(mono, "factor grows with the gap")
	t.update_racer(r, Vector3(0, 0, -500), 2.0)
	_check(t.catch_up(r, 1000.0) == 1.0, "finished racers are not rubber-banded")


func _sim_bot(t: RSRaceTrack, r: RSRaceTrack.Racer, f: RSRaceTrack.Follower, start: float, seconds: float) -> Dictionary:
	## Point-mass bot: heading turns toward the aim point at a bounded rate, speed eases to the profile.
	var pos := t.point_at(start) + t.right_at(start) * f.lane
	var fwd := t.tangent_at(start)
	var speed := 0.0
	var max_lat := 0.0
	var top := 0.0
	var steps := int(seconds * HZ)
	var dt := 1.0 / HZ
	for i in steps:
		var aim := f.target(r, speed)
		var ang := clampf(RSRaceTrack.steer_angle(fwd, pos, aim), -2.0 * dt, 2.0 * dt)
		fwd = fwd.rotated(Vector3.UP, -ang)
		var want := f.speed(r)
		speed = move_toward(speed, want, (4.0 if want > speed else 9.0) * dt)
		top = maxf(top, speed)
		pos += fwd * speed * dt
		t.update_racer(r, pos, (i + 1) * dt)
		max_lat = maxf(max_lat, absf(r.lateral))
		if r.finished:
			break
	return {"max_dev": max_lat, "top": top}


func _follower() -> void:
	var t := RSRaceTrack.new(_two_km_loop(), true)
	t.laps = 1
	var gates := 12
	for i in gates:
		var s := t.length * (i + 0.5) / gates
		t.add_gate(s, -2.0 + (i % 3) * 2.0 - 2.5, -2.0 + (i % 3) * 2.0 + 2.5)
	var f := RSRaceTrack.Follower.new(t, 26.0, 6.0, 7.0, 4.0)
	_check(f.profile.size() == t._p.size(), "one profile speed per vertex")
	var ok_brake := true
	var ok_accel := true
	var vmax_ok := true
	var n := f.profile.size()
	for i in n - 1:
		var a := f.profile[i]
		var b := f.profile[i + 1]
		ok_brake = ok_brake and a * a <= b * b + 2.0 * 7.0 * t._len[i] + 0.01
		ok_accel = ok_accel and b * b <= a * a + 2.0 * 4.0 * t._len[i] + 0.01
		vmax_ok = vmax_ok and a <= 26.0001 and a > 0.0
	_check(ok_brake and ok_accel and vmax_ok, "profile respects braking, acceleration and top speed")
	_check(_near(f.profile[0], f.profile[n - 1], 0.0001), "closed profile meets itself at the line")
	var tight := 0.0
	var tight_s := 0.0
	for i in 400:
		var s := t.length * i / 400.0
		if absf(t.curvature_at(s)) > tight:
			tight = absf(t.curvature_at(s))
			tight_s = s
	_check(t.profile_at(f.profile, tight_s) <= sqrt(6.0 / tight) + 0.5, "tightest bend capped by lateral acceleration")
	_check(t.profile_at(f.profile, tight_s) < 25.0, "bot slows for the tightest bend")
	var r := t.add_racer(1)
	t.new_race()
	t.start_racer(r, 0.0)
	f.lane = 1.5
	var aim := f.target(r, 0.0)
	var along := t.project(aim)
	_check(_near(along.x, f.lookahead, 0.3), "aim point leads by the lookahead")
	f.lane = 0.0
	var aim_fast := t.project(f.target(r, 20.0))
	_check(_near(aim_fast.x, f.lookahead + 20.0 * f.lookahead_time, 0.5), "lookahead grows with speed")
	f.lane = 10.0
	var w := t.gate_window(0)
	var near_gate := t.gate_s(0) - 3.0
	t.start_racer(r, near_gate)
	var squeezed := t.project(f.target(r, 0.0))
	_check(squeezed.y <= w.y - f.gate_margin + 0.05 and squeezed.y >= w.x + f.gate_margin - 0.05, "lane is squeezed into the next gate window")
	_check(is_equal_approx(f.lane_for(r), w.y - f.gate_margin), "lane_for clamps to the window less the margin")
	t.add_gate(t.length * 0.9, 3.0, 4.0)
	t.start_racer(r, t.length * 0.9 - 5.0)
	_check(is_equal_approx(f.lane_for(r), 3.5), "a gate narrower than twice the margin is aimed at its middle")
	t.start_racer(r, t.length * 0.99)
	_check(f.lane_for(r) == f.lane, "no gate left: the plain lane")
	f.lane = 0.5
	t.start_racer(r, 0.0)
	var res := _sim_bot(t, r, f, 0.0, 200.0)
	_check(r.finished, "bot completes the 2 km lap (%.1f s)" % r.finish_time)
	_check(r.gates_missed == 0 and r.gates_hit == t.gate_count(), "bot takes every gate (%d hit, %d missed)" % [r.gates_hit, r.gates_missed])
	_check(float(res["max_dev"]) < 6.0, "bot stays near the route (max %.2f m)" % float(res["max_dev"]))


func _race(seed_value: int) -> PackedFloat64Array:
	var t := RSRaceTrack.new(_two_km_loop(), true)
	t.laps = 1
	t.rubber_boost = 0.08
	t.rubber_brake = 0.04
	for i in 8:
		t.add_gate(t.length * (i + 0.5) / 8.0, -6, 6)
	var bots: Array[RSRaceTrack.Follower] = []
	var rs: Array[RSRaceTrack.Racer] = []
	var pos: Array[Vector3] = []
	var fwd: Array[Vector3] = []
	var spd := PackedFloat32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	t.new_race()
	for i in 4:
		var f := RSRaceTrack.Follower.new(t, rng.randf_range(22, 27), 6.0, 7.0, 4.0)
		f.lane = -3.0 + i * 2.0
		bots.append(f)
		var r := t.add_racer(i + 1)
		t.start_racer(r, -2.0 - i)
		rs.append(r)
		pos.append(t.point_at(-2.0 - i) + t.right_at(-2.0 - i) * f.lane)
		fwd.append(t.tangent_at(-2.0 - i))
		spd.append(0.0)
	var dt := 1.0 / HZ
	for step in int(140 * HZ):
		var ref := rs[0].progress
		for i in 4:
			var aim := bots[i].target(rs[i], spd[i])
			var ang := clampf(RSRaceTrack.steer_angle(fwd[i], pos[i], aim), -2.0 * dt, 2.0 * dt)
			fwd[i] = fwd[i].rotated(Vector3.UP, -ang)
			var want := bots[i].speed(rs[i]) * t.catch_up(rs[i], ref)
			spd[i] = move_toward(spd[i], want, (4.0 if want > spd[i] else 9.0) * dt)
			pos[i] += fwd[i] * spd[i] * dt
			t.update_racer(rs[i], pos[i], (step + 1) * dt)
		t.update_standings()
	var out := PackedFloat64Array()
	for r: RSRaceTrack.Racer in rs:
		for v: float in [r.finish_time, r.place, r.finish_order, r.progress, r.gates_hit]:
			out.append(v)
	return out


func _determinism() -> void:
	var a := _race(99)
	var b := _race(99)
	_check(a == b, "same inputs give bit-identical results")
	var all_done := true
	for i in 4:
		all_done = all_done and a[i * 5] > 0.0
	_check(all_done, "all four bots finish the race")


func _performance() -> void:
	var t := RSRaceTrack.new(_two_km_loop(), true)
	_check(t.length > 1800.0 and t.length < 2600.0, "perf route is about 2 km (%.0f m)" % t.length)
	t.laps = 100
	for i in 10:
		t.add_gate(t.length * (i + 0.5) / 10.0, -8, 8)
	var rs: Array[RSRaceTrack.Racer] = []
	var bots: Array[RSRaceTrack.Follower] = []
	for i in 4:
		rs.append(t.add_racer(i + 1))
		bots.append(RSRaceTrack.Follower.new(t, 25.0))
		bots[i].lane = i - 1.5
	t.new_race()
	for r: RSRaceTrack.Racer in rs:
		t.start_racer(r, 0.0)
	var steps := int(HZ * 60.0)
	var sink := 0.0
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var t0 := Time.get_ticks_usec()
	for step in steps:
		for i in 4:
			var s := (step + 1) * (20.0 + i) / HZ
			var pos := t.point_at(s) + t.right_at(s) * (3.0 * sin(s * 0.05 + i))
			t.update_racer(rs[i], pos, step / HZ)
			sink += bots[i].target(rs[i], 20.0).x + bots[i].speed(rs[i]) + t.catch_up(rs[i], rs[0].progress)
		t.update_standings()
	var per_step := float(Time.get_ticks_usec() - t0) / steps
	_check(Performance.get_monitor(Performance.OBJECT_COUNT) == objects, "hot path creates no objects")
	print("RS_RACE_PERF: %.1f us per 120 Hz step (4 racers + standings + 4 bots)" % per_step)
	_check(per_step < BUDGET_STEP_US, "4 racers at 120 Hz well under budget (%.1f us per step, budget %.0f)" % [per_step, BUDGET_STEP_US])
	_check(rs[3].progress > 1000.0 and rs[0].gates_hit > 0 and rs[0].gates_missed == 0, "perf run really raced (sink %.0f)" % sink)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var qs := PackedVector3Array()
	for i in 2000:
		# Respawns and first fixes: anywhere within 60 m of the route.
		var s := rng.randf_range(0, t.length)
		qs.append(t.point_at(s) + t.right_at(s) * rng.randf_range(-60, 60))
	t0 = Time.get_ticks_usec()
	for q in qs:
		sink += t.project(q).x
	var per_query := float(Time.get_ticks_usec() - t0) / qs.size()
	print("RS_RACE_PERF: %.1f us per global closest-point query (%d segments)" % [per_query, t.segment_count()])
	var brute_t0 := Time.get_ticks_usec()
	for i in 50:
		sink += _brute(t, qs[i])
	var per_brute := float(Time.get_ticks_usec() - brute_t0) / 50.0
	print("RS_RACE_PERF: %.1f us per brute-force query, for comparison" % per_brute)
	_check(per_query * 4.0 < per_brute, "grid query beats a linear scan by 4x or more")
	_check(per_query < BUDGET_GLOBAL_US, "global query is indexed (%.1f us, budget %.0f)" % [per_query, BUDGET_GLOBAL_US])
