extends Node
## Pure route/race data checks; no art, physics nodes, bots or gameplay are required.

var _checks := 0
var _failures := 0


func _ready() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("FAIL: " + message)


func _run() -> void:
	_geometry()
	_projection()
	_gates()
	_laps()
	_finishes()
	_standings()
	_timing()
	print("RS_RACE_TRACK_TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)


func _line() -> RSRaceTrack:
	return RSRaceTrack.new(PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -100)]), false, 0.0)


func _circle(n: int, radius: float, clockwise := true) -> PackedVector3Array:
	var points := PackedVector3Array()
	for i in n:
		var angle := TAU * i / n * (1.0 if clockwise else -1.0)
		points.append(Vector3(radius * cos(angle), 0.0, radius * sin(angle)))
	return points


func _geometry() -> void:
	var line := RSRaceTrack.new(PackedVector3Array([Vector3(0, 3, 0), Vector3(0, 13, -100)]), false, 0.0)
	_check(line.length == 100.0, "line: length is horizontal, independent of elevation")
	_check(line.point_at(50.0) == Vector3(0, 8, -50), "line: point_at carries interpolated Y")
	_check(line.point_at(-5.0) == Vector3(0, 3, 0) and line.point_at(105.0) == Vector3(0, 13, -100), "line: point_at clamps at open endpoints")
	_check(line.tangent_at(30.0) == Vector3.FORWARD and line.right_at(30.0) == Vector3.RIGHT, "line: horizontal tangent and positive-right convention")
	_check(line.curvature_at(30.0) == 0.0 and line.delta_s(30.0, 10.0) == -20.0, "line: zero curvature and signed open delta")
	_check(line.project(Vector3(3, 999, -37)).distance_to(Vector2(37, 3)) < 0.00001, "line: projection ignores Y and signs lateral right")
	_check(absf(RSRaceTrack.steer_angle(Vector3.FORWARD, Vector3.ZERO, Vector3.RIGHT) - PI * 0.5) < 0.000001, "steering: right turn is positive")
	_check(absf(RSRaceTrack.steer_angle(Vector3.FORWARD, Vector3.ZERO, Vector3.LEFT) + PI * 0.5) < 0.000001, "steering: left turn is negative")
	var elevated := PackedVector3Array([Vector3.ZERO, Vector3(0, 100, -25), Vector3(0, -60, -50), Vector3(0, 70, -100)])
	var spline := RSRaceTrack.new(elevated)
	_check(absf(spline.length - 100.0) < 0.0001 and spline.point_at(25.0).distance_to(elevated[1]) < 0.0001, "spline: straight XZ geometry and control-point Y survive resampling")
	var circle := RSRaceTrack.new(_circle(128, 20.0), true, 0.0)
	_check(absf(circle.length - TAU * 20.0) < 0.02, "circle: polyline length agrees with analytic circumference")
	_check(absf(circle.wrap_s(-2.0) - (circle.length - 2.0)) < 0.00001 and absf(circle.delta_s(circle.length - 2.0, 1.0) - 3.0) < 0.00001, "circle: negative s wraps and seam delta takes the short way")
	for i in 32:
		var angle := TAU * i / 32.0
		var s := circle.length * i / 32.0
		var point := Vector3(20.0 * cos(angle), 0.0, 20.0 * sin(angle))
		var tangent := Vector3(-sin(angle), 0.0, cos(angle))
		_check(circle.point_at(s).distance_to(point) < 0.01, "circle: point_at agrees with analytic position")
		_check(circle.tangent_at(s).distance_to(tangent) < 0.03, "circle: tangent agrees with analytic direction")
		_check(absf(circle.curvature_at(s) - 0.05) < 0.0001, "circle: right-turn curvature agrees with 1 / radius")
	var reverse := RSRaceTrack.new(_circle(128, 20.0, false), true, 0.0)
	_check(absf(reverse.curvature_at(10.0) + 0.05) < 0.0001, "circle: left-turn curvature has negative sign")
	var smooth := RSRaceTrack.new(_circle(16, 20.0), true, 1.0)
	_check(absf(smooth.length - TAU * 20.0) < 0.15, "spline circle: sampled Catmull-Rom arc length agrees with circumference")
	for i in 16:
		var s := smooth.length * (i + 0.5) / 16.0
		var angle := TAU * (i + 0.5) / 16.0
		_check(smooth.point_at(s).distance_to(Vector3(20.0 * cos(angle), 0, 20.0 * sin(angle))) < 0.1, "spline circle: midpoint stays near analytic circle")
		_check(absf(smooth.curvature_at(s) - 0.05) < 0.02, "spline circle: curvature is near 1 / radius")


func _projection() -> void:
	var hairpin := RSRaceTrack.new(PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -50), Vector3(2, 0, -50), Vector3(2, 0, 0)]), false, 0.0)
	_check(absf(hairpin.project(Vector3(1.2, 0, -45), 44.0).x - 45.0) < 0.00001, "hairpin: hint keeps its leg even when the return leg is physically closer")
	_check(absf(hairpin.project(Vector3(2, 0, -10), 10.0).x - 10.0) < 0.00001, "hairpin: a nearby shortcut does not snap to the far return leg")
	_sweep_projection(hairpin, 0.5, "hairpin")
	# Both branches of this small X are inside the 20 m hint window.
	var eight := RSRaceTrack.new(PackedVector3Array([Vector3(-4, 0, -4), Vector3(4, 0, 4), Vector3(-4, 0, 4), Vector3(4, 0, -4)]), false, 0.0)
	var crossing := sqrt(32.0)
	_check(absf(eight.project(Vector3.ZERO, crossing).x - crossing) < 0.00001, "crossing: first visit stays on the first branch")
	_check(absf(eight.project(Vector3.ZERO, eight.length - crossing).x - (eight.length - crossing)) < 0.00001, "crossing: later visit stays on the later branch")
	_sweep_projection(eight, 0.2, "figure eight")
	var long_line := RSRaceTrack.new(PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -300)]), false, 0.0)
	_check(absf(long_line.project(Vector3(0, 0, -35), 0.0).x - RSRaceTrack.WINDOW) < 0.00001, "hint window clips even a very long segment")
	_check(absf(long_line.project(Vector3(0, 0, -180), 20.0).x - 180.0) < 0.00001, "respawn: a distant local match reacquires through the global grid")
	var points := PackedVector3Array([Vector3(-60, 0, -30), Vector3(20, 0, -5), Vector3(55, 0, -45), Vector3(60, 0, 60), Vector3(-50, 0, 30)])
	var grid := RSRaceTrack.new(points, false, 0.0)
	for i in 200:
		var pos := Vector3((i * 17 % 211) - 105, i * 3.0, (i * 31 % 197) - 98)
		_check(grid.project(pos).distance_to(_linear_projection(points, pos)) < 0.0001, "global grid: projection agrees with an independent all-segment search")


func _sweep_projection(track: RSRaceTrack, step: float, label: String) -> void:
	var previous := 0.0
	var s := 0.0
	while s <= track.length:
		var projected := track.project(track.point_at(s), previous).x
		_check(projected >= previous - 0.0001 and absf(projected - s) < 0.0001, label + ": hinted progress is monotonic and stays on its route")
		previous = projected
		s += step


func _linear_projection(points: PackedVector3Array, pos: Vector3) -> Vector2:
	var best := INF
	var answer := Vector2.ZERO
	var start := 0.0
	for i in points.size() - 1:
		var a := Vector2(points[i].x, points[i].z)
		var d := Vector2(points[i + 1].x, points[i + 1].z) - a
		var segment_length := d.length()
		d /= segment_length
		var v := Vector2(pos.x, pos.z) - a
		var along := clampf(v.dot(d), 0.0, segment_length)
		var distance := (v - d * along).length_squared()
		if distance < best - 0.000001:
			best = distance
			answer = Vector2(start + along, -v.x * d.y + v.y * d.x)
		start += segment_length
	return answer


func _gates() -> void:
	var track := _line()
	track.finish_s = 80.0
	track.add_gate(60.0, -2.0, 2.0)
	_check(track.add_gate_between(Vector3(-2, 0, -20), Vector3(2, 0, -20)) == 0, "gates: buoy gates insert in s order")
	track.add_gate(40.0, 1.0, -1.0)
	track.add_gate(90.0)
	_check(track.gate_count() == 4 and track.gate_s(1) == 40.0 and track.gate_window(1) == Vector2(-1, 1), "gates: sorted positions and ordered lateral bounds")
	_check(track.gate_point(0) == Vector3(0, 0, -20) and track.gate_point(3) == Vector3(0, 0, -90), "gates: finite and unbounded gate centres lie on the route")
	var r := track.add_racer(1)
	track.start_racer(r, 10.0, 1.0)
	_check(track.update_racer(r, Vector3(0, 0, -25), 2.0) == RSRaceTrack.GATE_PASSED and r.next_gate == 1, "gates: crossing within a window passes the next gate")
	_check(track.update_racer(r, Vector3(4, 0, -45), 4.0) == RSRaceTrack.GATE_MISSED and r.next_gate == 2, "gates: going outside the window reports a miss and advances")
	_check(track.update_racer(r, Vector3(0, 0, -65), 6.0) == RSRaceTrack.GATE_PASSED and r.next_gate == track.gate_count(), "gates: gates beyond an early finish are excluded")
	_check(r.gates_hit == 2 and r.gates_missed == 1, "gates: hit and miss counters accumulate")
	_check(track.update_racer(r, Vector3(0, 0, -50), 7.0) == 0 and r.wrong_way, "gates: reversing does not consume already-visited gates")
	_check(track.update_racer(r, Vector3(0, 0, -65), 8.0) == 0 and not r.wrong_way and r.gates_hit == 2, "gates: recrossing old gates does not score twice")
	var interpolated := _line()
	interpolated.add_gate(10.0, -1.0, 1.0)
	var diagonal := interpolated.add_racer(2)
	interpolated.start_racer(diagonal, 5.0)
	interpolated.update_racer(diagonal, Vector3(-4, 0, -5), 1.0)
	_check(interpolated.update_racer(diagonal, Vector3(4, 0, -15), 2.0) == RSRaceTrack.GATE_PASSED, "gates: use interpolated crossing lateral, even when both sampled endpoints are outside")
	var multiple := _line()
	multiple.add_gate(5.0, -1.0, 1.0)
	multiple.add_gate(10.0, -4.0, 4.0)
	multiple.add_gate(15.0, -1.0, 1.0)
	var fast := multiple.add_racer(3)
	multiple.update_racer(fast, Vector3(3, 0, 0), 0.0)
	var event := multiple.update_racer(fast, Vector3(3, 0, -18), 1.0)
	_check(event == (RSRaceTrack.GATE_PASSED | RSRaceTrack.GATE_MISSED) and fast.next_gate == 3 and fast.gates_hit == 1 and fast.gates_missed == 2, "gates: one update can report several ordered passes and misses")


func _laps() -> void:
	var track := RSRaceTrack.new(PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -20), Vector3(20, 0, -20), Vector3(20, 0, 0)]), true, 0.0)
	track.laps = 2
	track.add_gate(0.0)
	track.add_gate(10.0)
	track.add_gate(50.0)
	var r := track.add_racer(1)
	track.start_racer(r, -4.0)
	_check(r.progress == -4.0 and r.lap == 0 and track.fraction(r) == 0.0, "closed grid: negative progress is behind the line, with no completed lap")
	var lap_events := 0
	for i in range(1, 43):
		var progress := -4.0 + i * 4.0
		var event := track.update_racer(r, track.point_at(progress), i * 0.5)
		if event & RSRaceTrack.LAP:
			lap_events += 1
		if i == 1:
			_check(r.lap == 0 and not (event & RSRaceTrack.LAP), "closed grid: first starting-line crossing is not a lap")
	_check(r.finished and r.lap == 2 and lap_events == 2, "closed laps: two forward finish-line crossings complete two laps")
	_check(r.gates_hit == 7 and r.next_gate == track.gate_count(), "closed gates: ordered gates repeat each lap and a gate at zero is taken on the final crossing")
	_check(track.fraction(r) == 1.0, "closed laps: finished fraction is one")
	track.laps = 1
	track.start_racer(r, track.length - 3.0, 4.0)
	var final_event := track.update_racer(r, track.point_at(1.0), 6.0)
	_check(final_event == (RSRaceTrack.GATE_PASSED | RSRaceTrack.LAP | RSRaceTrack.FINISHED) and absf(r.finish_time - 5.5) < 0.000001, "closed finish: interpolate the final seam crossing and take the final zero gate")
	track.start_racer(r, 2.0)
	_check(track.update_racer(r, track.point_at(-2.0), 1.0) == 0 and r.lap == 0 and r.progress < 0.0, "closed reverse: crossing the start backwards does not add a lap")
	track.start_racer(r, 35.0)
	track.update_racer(r, track.point_at(17.0), 2.0)
	_check(r.wrong_way, "closed reverse: moving far behind peak progress sets wrong_way")


func _finishes() -> void:
	var track := _line()
	var r := track.add_racer(1)
	track.start_racer(r, -5.0, 1.0)
	track.update_racer(r, Vector3(0, 0, 3), 2.0)
	_check(r.progress == -3.0 and r.s == 0.0 and track.fraction(r) == 0.0, "open grid: negative starting positions retain signed progress")
	track.update_racer(r, Vector3(0, 0, -2), 3.0)
	_check(absf(r.progress - 2.0) < 0.000001, "open grid: crossing the line removes no arbitrary starting offset")
	track.start_racer(r, 95.0, 10.0)
	_check(track.update_racer(r, Vector3(0, 0, -105), 12.0) == RSRaceTrack.FINISHED, "open finish: crossing the endpoint raises FINISHED")
	_check(absf(r.finish_time - 11.0) < 0.000001, "open finish: time uses physical overshoot beyond the clipped route endpoint")
	track.update_standings()
	var order := r.finish_order
	_check(track.update_racer(r, Vector3(0, 0, -90), 13.0) == 0 and r.finish_time == 11.0 and r.finish_order == order, "open finish: later movement cannot refinish or change the finish time")
	track.finish_s = 60.0
	track.new_race()
	track.start_racer(r, 55.0, 3.0)
	track.update_racer(r, Vector3(0, 0, -65), 5.0)
	_check(r.finished and absf(r.finish_time - 4.0) < 0.000001, "open finish: a custom finish_s interpolates between updates")


func _standings() -> void:
	var track := _line()
	var a := track.add_racer(1)
	var b := track.add_racer(2)
	var c := track.add_racer(3)
	track.start_racer(a, 50.0)
	track.start_racer(b, 50.0005)
	track.start_racer(c, 30.0)
	track.update_standings()
	_check(a.place == 1 and b.place == 1 and c.place == 3, "standings: two leaders within 1 mm share places 1, 1, 3")
	_check(track.leader() == b and absf(track.gap_to_leader(c) - 20.0005) < 0.000001 and track.fraction(a) == 0.5, "standings: order, leader, metre gap and HUD fraction agree")
	track.start_racer(c, 50.0011)
	track.update_standings()
	_check(c.place == 1 and b.place == 1 and a.place == 3, "standings: chained sub-millimetre neighbours cannot merge a wider tie group")
	track.new_race()
	track.start_racer(a, 95.0)
	track.start_racer(b, 95.0)
	track.update_racer(a, Vector3(0, 0, -105), 4.0)
	track.update_racer(b, Vector3(0, 0, -105), 2.0)
	track.update_standings()
	_check(b.finish_order == 1 and a.finish_order == 2 and b.place == 1 and a.place == 2 and c.place == 3, "standings: this frame's arrivals use interpolated time instead of update-call order")
	track.start_racer(c, 95.0)
	track.update_racer(c, Vector3(0, 0, -105), 8.0)
	track.update_racer(b, Vector3(0, 0, -80), 9.0)
	track.update_standings()
	_check(track.order[0] == b and b.finish_order == 1 and c.finish_order == 3, "standings: committed finish_order stays fixed after movement and later arrivals")
	track.new_race()
	for r: RSRaceTrack.Racer in track.racers:
		_check(r.progress == 0.0 and r.s == 0.0 and r.lateral == 0.0 and r.lap == 0 and r.next_gate == 0 and r.gates_hit == 0 and r.gates_missed == 0 and not r.finished and r.finish_time == 0.0 and r.finish_order == 0 and r.place == 0 and not r.wrong_way, "new race: every Racer progress and result field is reset")
	track.start_racer(a, 95.0)
	track.start_racer(b, 95.0)
	track.update_racer(b, Vector3(0, 0, -105), 2.0)
	track.update_racer(a, Vector3(0, 0, -105), 2.0)
	track.update_standings()
	_check(a.finish_order == 1 and b.finish_order == 2 and a.place == 1 and b.place == 2, "standings: equal finish times still get deterministic unique finish orders")
	track.remove_racer(a)
	_check(track.racers.size() == 2 and track.order.size() == 2 and not track.order.has(a), "standings: removing a racer removes both persistent references")
	track.remove_racer(b)
	track.remove_racer(c)
	_check(track.leader() == null and track.gap_to_leader(c) == 0.0, "standings: an empty race has no leader or gap")


func _timing() -> void:
	var track := RSRaceTrack.new(PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -2000)]), false, 0.0)
	var r := track.add_racer(1)
	var began := Time.get_ticks_usec()
	for i in 1000:
		track.update_racer(r, Vector3(0, 0, -float(i)), i / 60.0)
		track.update_standings()
	var elapsed := Time.get_ticks_usec() - began
	_check(absf(r.progress - 999.0) < 0.00001 and not r.finished, "timing: 1000 updates advance the racer to the expected progress")
	print("RS_RACE_TRACK_TIMING: 1000 update_racer + update_standings calls: %d us (%.2f us/update)" % [elapsed, elapsed / 1000.0])
