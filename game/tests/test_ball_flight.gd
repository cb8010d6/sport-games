extends Node
## Deterministic, numeric regression cases for the public RSBallFlight contract.

var _checks := 0
var _failures := 0
var _events: Array[Dictionary] = []


func _ready() -> void:
	_vacuum_parabola()
	_forces()
	_frame_clock()
	_snapshot_and_copy()
	_table_rebound()
	_materials_and_impulses()
	_net_sweeps()
	_plane_edges()
	_rest_and_budget()
	_presets()
	print("RS_BALL_FLIGHT_TESTS: %d checks, %d failures" % [_checks, _failures]) # no-i18n
	get_tree().quit(0 if _failures == 0 else 1)


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("BALL: " + message) # no-i18n


func _vacuum() -> RSBallFlight.Ball:
	var b := RSBallFlight.ball_tennis()
	b.air_density = 0.0
	b.spin_decay = 0.0
	return b


func _listen(f: RSBallFlight) -> void:
	_events.clear()
	f.contacted.connect(func(kind: int, id: StringName, point: Vector3, speed: float) -> void:
		_events.append({"kind": kind, "id": id, "point": point, "speed": speed,
				"tick": f.tick, "v": f.velocity(), "w": f.spin()})) # no-i18n


func _same(a: RSBallFlight, b: RSBallFlight) -> bool:
	return a.snapshot().to_byte_array() == b.snapshot().to_byte_array()


func _vacuum_parabola() -> void:
	var f := RSBallFlight.new(_vacuum())
	f.set_state(Vector3(1, 2, -1), Vector3(3, 4, -2))
	f.advance_to_tick(RSBallFlight.HZ)
	var s := f.snapshot()
	var error := sqrt((s[1] - 4.0) * (s[1] - 4.0) + (s[2] - 1.095) * (s[2] - 1.095) + (s[3] + 3.0) * (s[3] + 3.0))
	_check(error < 1e-9, "vacuum parabola: < 1 nm after 1 s")
	_check(absf(s[5] + 5.81) < 1e-10, "vacuum velocity matches analytic gravity")
	_check(f.tick == 240 and f.time() == 1.0, "240 Hz time and tick")
	print("BALL_NUMERIC vacuum_error_m=%.12f" % error) # no-i18n


func _forces() -> void:
	var f := RSBallFlight.new(RSBallFlight.ball_table_tennis())
	f.set_state(Vector3(0, 20, 0), Vector3(12, 0, 0), Vector3(0, 0, -100))
	var previous := 12.0
	var monotone := true
	for _i in 240:
		f.step()
		var vx := f.snapshot()[4]
		monotone = monotone and vx > 0.0 and vx < previous
		previous = vx
	_check(monotone, "drag decreases horizontal speed at every step")
	_check(f.spin().length() > 80.0 and f.spin().length() < 90.0, "spin decays at preset 0.15/s")
	var plain := _landing_x(0.0)
	var top := _landing_x(-150.0)
	var back := _landing_x(150.0)
	_check(top < plain - 0.05, "topspin lands closer than no spin")
	_check(back > plain + 0.05, "backspin lands farther than no spin")
	print("BALL_NUMERIC landing_m top=%.6f plain=%.6f back=%.6f" % [top, plain, back]) # no-i18n
	var axial := RSBallFlight.new(RSBallFlight.ball_tennis())
	axial.set_state(Vector3.ZERO, Vector3(8, 0, 0), Vector3(50, 0, 0))
	axial.step()
	_check(axial.snapshot()[3] == 0.0, "spin parallel to velocity adds no sideways lift")


func _landing_x(wz: float) -> float:
	var f := RSBallFlight.new(RSBallFlight.ball_tennis())
	f.add_plane(&"ground", RSBallFlight.surface_hard_court(), Vector3.ZERO) # no-i18n
	f.set_state(Vector3(0, 2, 0), Vector3(8, 0, 0), Vector3(0, 0, wz))
	_listen(f)
	for _i in 720:
		f.step()
		if not _events.is_empty():
			return (_events[0]["point"] as Vector3).x # no-i18n
	_check(false, "landing trajectory must reach ground")
	return INF


func _framed(fps: int) -> RSBallFlight:
	var f := RSBallFlight.new(RSBallFlight.ball_tennis())
	f.add_plane(&"floor", RSBallFlight.surface_floor(), Vector3.ZERO) # no-i18n
	f.add_net(&"net", RSBallFlight.surface_net(), Vector3.ZERO, Vector3.BACK, 4.0, 1.2, 0.0) # no-i18n
	f.set_state(Vector3(0.2, 2, -3), Vector3(2, 3, 16), Vector3(25, 50, -60))
	for _i in fps * 3:
		f.advance(1.0 / fps)
	return f


func _frame_clock() -> void:
	var a := _framed(30)
	var b := _framed(60)
	var c := _framed(144)
	_check(a.tick == 720 and b.tick == 720 and c.tick == 720, "all frame rates run exactly 720 ticks")
	_check(_same(a, b) and _same(a, c), "30/60/144 FPS complete snapshots match byte for byte")
	var f := RSBallFlight.new(_vacuum())
	f.set_state(Vector3.ZERO, Vector3.RIGHT)
	_check(f.advance(RSBallFlight.STEP * 1.5) == 1, "fractional frame advances whole ticks")
	_check(absf(f.render_position().x - RSBallFlight.STEP * 0.5) < 1e-9, "render interpolates previous/current position")
	var saved := f.snapshot()
	_check(f.advance(-1.0) == 0 and f.snapshot() == saved, "negative delta is ignored")
	f.set_state(Vector3.ZERO, Vector3.RIGHT)
	_check(f.advance(1.125) == 60 and f.tick == 60, "hitch respects 60 step budget")
	_check(f.advance(0.0) == 0, "hitch excess is dropped without debt")
	f.advance_to_tick(65)
	f.advance_to_tick(60)
	_check(f.tick == 65, "advance_to_tick does not rewind")


func _snapshot_and_copy() -> void:
	var f := RSBallFlight.new(_vacuum())
	f.add_plane(&"ground", RSBallFlight.surface_floor(), Vector3.ZERO) # no-i18n
	f.set_state(Vector3(0, 0.5, 0), Vector3(2, -1, 0), Vector3(0, 2, -4))
	f.advance(0.137)
	var saved := f.snapshot()
	var duplicate := f.copy()
	_check(_same(f, duplicate) and not duplicate.emit_events, "copy preserves complete state and suppresses events")
	_check(f.render_position() == duplicate.render_position(), "copy preserves interpolation")
	var emitted := [0]
	duplicate.contacted.connect(func(_kind: int, _id: StringName, _point: Vector3, _speed: float) -> void:
		emitted[0] += 1)
	duplicate.advance_to_tick(200)
	_check(emitted[0] == 0 and f.snapshot() == saved, "copy can bounce without events or mutating original")
	f.advance(0.017)
	f.advance_to_tick(200)
	var continuous := f.snapshot()
	f.restore(saved)
	_check(f.snapshot() == saved, "restore preserves fractional clock and previous position")
	f.advance(0.017)
	f.advance_to_tick(200)
	_check(f.snapshot().to_byte_array() == continuous.to_byte_array(), "restore continuation is byte-identical")
	f.set_state(Vector3.ONE, Vector3.ZERO)
	_check(f.tick == 0 and not f.resting and f.snapshot()[15] == 0.0, "set_state resets tick, rest and clock")
	f.clear_world()
	f.set_state(Vector3(0, 0.05, 0), Vector3.DOWN)
	_listen(f)
	f.advance_to_tick(100)
	_check(_events.is_empty() and f.position().y < 0.0, "clear_world removes collisions")


func _table_rebound() -> void:
	var f := RSBallFlight.new(RSBallFlight.ball_table_tennis())
	f.add_table_tennis_table(Vector3.ZERO)
	f.set_state(Vector3(0, RSBallFlight.TABLE_HEIGHT + f.ball.radius + 0.3, -0.5), Vector3.ZERO)
	_listen(f)
	var apex := -INF
	for _i in 240:
		f.step()
		if _events.size() == 1:
			apex = maxf(apex, f.snapshot()[2] - RSBallFlight.TABLE_HEIGHT - f.ball.radius)
		if _events.size() >= 2:
			break
	_check(_events.size() >= 2 and _events[0]["id"] == &"table", "drop reaches table and bounces twice") # no-i18n
	_check(absf(apex - 0.23) < 0.025, "0.3 m ITTF table drop rebounds 0.23 +/- 0.025 m")
	print("BALL_NUMERIC table_rebound_m=%.6f" % apex) # no-i18n


func _first_bounce(surface: RSBallFlight.Surface, vx := 12.0, vy := -2.0) -> RSBallFlight:
	var f := RSBallFlight.new(_vacuum())
	f.add_plane(&"court", surface, Vector3.ZERO) # no-i18n
	f.set_state(Vector3(0, 0.1, 0), Vector3(vx, vy, 0))
	_listen(f)
	for _i in 240:
		f.step()
		if not _events.is_empty():
			return f
	_check(false, "material fixture must collide")
	return f


func _materials_and_impulses() -> void:
	var hard := _first_bounce(RSBallFlight.surface_hard_court())
	var clay := _first_bounce(RSBallFlight.surface_clay())
	_check(RSBallFlight.surface_clay().friction > RSBallFlight.surface_hard_court().friction, "clay has higher friction")
	_check(clay.velocity().x < hard.velocity().x - 0.1, "clay slows horizontal travel more than hard court")
	_check(absf(clay.spin().z) > absf(hard.spin().z), "tangential impulse also changes spin")
	print("BALL_NUMERIC court_vx_mps hard=%.6f clay=%.6f" % [hard.velocity().x, clay.velocity().x]) # no-i18n
	var elastic := RSBallFlight.Surface.new(1.0, 0.6)
	var f := _first_bounce(elastic, 6.0, -3.0)
	var event: Dictionary = _events[0]
	var v: Vector3 = event["v"] # no-i18n
	var w: Vector3 = event["w"] # no-i18n
	var speed: float = event["speed"] # no-i18n
	var before := 36.0 + speed * speed
	var after := v.length_squared() + f.ball.inertia * f.ball.radius * f.ball.radius * w.length_squared()
	_check(after <= before + 1e-5 and after < before - 0.01, "fixed-surface friction dissipates kinetic energy")
	var momentum := -f.ball.radius * v.x + f.ball.inertia * f.ball.radius * f.ball.radius * w.z
	_check(absf(momentum + f.ball.radius * 6.0) < 1e-7, "friction conserves angular momentum about contact")
	var dropping := RSBallFlight.Surface.new(0.9, 0.0)
	dropping.restitution_drop = 0.03
	dropping.restitution_min = 0.5
	_first_bounce(dropping, 0.0, -20.0)
	event = _events[0]
	v = event["v"] # no-i18n
	speed = event["speed"] # no-i18n
	_check(absf(v.y / speed - 0.5) < 1e-7, "speed-dependent restitution clamps at minimum")


func _net_flight(position: Vector3, velocity: Vector3) -> RSBallFlight:
	var f := RSBallFlight.new(_vacuum())
	f.add_net(&"net_a", RSBallFlight.surface_net(), Vector3.ZERO, Vector3.BACK,
			1.0, 1.5, 0.5, RSBallFlight.surface_net_cord()) # no-i18n
	f.set_state(position, velocity)
	_listen(f)
	f.step()
	return f


func _net_sweeps() -> void:
	var f := _net_flight(Vector3(-0.2, 1, -0.08), Vector3(18, 0, 24))
	_check(_events.size() == 1, "30 m/s oblique ball contacts thin net within one step")
	if not _events.is_empty():
		var e: Dictionary = _events[0]
		_check(e["kind"] == RSBallFlight.CONTACT_NET and e["id"] == &"net_a", "net signal kind and ID") # no-i18n
		_check(e["tick"] == 1 and absf(e["speed"] - 24.0) < 1e-9, "signal tick and incident normal speed") # no-i18n
		_check(absf((e["point"] as Vector3).z + f.ball.radius) < 1e-7, "signal reports contact ball centre") # no-i18n
	_check(f.velocity().z < 0.0 and f.position().z < -f.ball.radius, "net consumes remaining time on incident side")
	_net_flight(Vector3(0, 1.52, -0.07), Vector3(0, 0, 30))
	_check(not _events.is_empty() and _events[0]["kind"] == RSBallFlight.CONTACT_CORD, "ball above mesh clips top cord") # no-i18n
	_net_flight(Vector3(0, 1.58, 0), Vector3(0, -30, 0))
	_check(not _events.is_empty() and _events[0]["kind"] == RSBallFlight.CONTACT_CORD, "vertical drop hits cord without crossing mesh plane") # no-i18n
	_net_flight(Vector3(1.02, 1, -0.08), Vector3(0, 0, 30))
	_check(not _events.is_empty() and _events[0]["kind"] == RSBallFlight.CONTACT_NET, "sphere sweep includes net side edge") # no-i18n
	_net_flight(Vector3(1.02, 1.52, -0.08), Vector3(0, 0, 30))
	_check(not _events.is_empty() and _events[0]["kind"] == RSBallFlight.CONTACT_CORD, "top corner belongs to cord") # no-i18n
	_net_flight(Vector3(0, 0.48, -0.08), Vector3(0, 0, 30))
	_check(not _events.is_empty(), "sphere sweep includes lower net edge")
	f = _net_flight(Vector3(1.05, 1, -0.05), Vector3(0, 0, 30))
	_check(_events.is_empty() and f.position().z > 0.0, "ball beyond expanded net width passes")
	f = _net_flight(Vector3(0, 0.45, -0.05), Vector3(0, 0, 30))
	_check(_events.is_empty() and f.position().z > 0.0, "ball below open net bottom passes")
	f = _net_flight(Vector3(0, 1, 0.08), Vector3(0, 0, -30))
	_check(not _events.is_empty() and f.velocity().z > 0.0, "net collides from both sides")


func _bounded(position: Vector3, velocity: Vector3) -> RSBallFlight:
	var f := RSBallFlight.new(_vacuum())
	f.add_plane(&"table_edge", RSBallFlight.surface_table(), Vector3.ZERO,
			Vector3.UP, Vector2.ONE) # no-i18n
	f.set_state(position, velocity)
	_listen(f)
	f.step()
	return f


func _plane_edges() -> void:
	var f := _bounded(Vector3(1.02, 0.08, 0), Vector3(0, -30, 0))
	_check(not _events.is_empty() and f.velocity().x > 0.0, "30 m/s ball outside face projection hits rounded edge")
	f = _bounded(Vector3(1.02, 0.08, 1.02), Vector3(0, -30, 0))
	_check(not _events.is_empty() and f.velocity().x > 0.0 and f.velocity().z > 0.0, "sphere sweep includes finite-plane corner")
	f = _bounded(Vector3(1.05, 0.08, 0), Vector3(0, -30, 0))
	_check(_events.is_empty() and f.position().y < 0.0, "bounded plane does not act as infinite floor")
	_bounded(Vector3(0, -0.08, 0), Vector3(0, 30, 0))
	_check(_events.is_empty(), "plane backside is noncolliding")
	_bounded(Vector3(1.02, -0.08, 0), Vector3(0, 30, 0))
	_check(_events.is_empty(), "rounded edge also respects one-sided plane")


func _rest_and_budget() -> void:
	var slow := RSBallFlight.Surface.new(0.0, 0.0, 0.0, 0.4)
	slow.restitution_min = 0.0
	var f := RSBallFlight.new(_vacuum())
	f.add_plane(&"floor", slow, Vector3.ZERO) # no-i18n
	f.set_state(Vector3(0, f.ball.radius + 0.001, 0), Vector3(1, -0.1, 0))
	_listen(f)
	f.advance_to_tick(500)
	_check(f.resting and f.velocity() == Vector3.ZERO and f.spin() == Vector3.ZERO, "low bounce settles, rolls and stops")
	_check(_events.size() == 1, "resting contact does not emit a bounce every tick")
	var restored := f.copy()
	f.step()
	restored.step()
	_check(_same(f, restored), "resting snapshot continuation is exact")
	slow.rolling = 0.0
	f = RSBallFlight.new(_vacuum())
	f.add_plane(&"ledge", slow, Vector3.ZERO, Vector3.UP, Vector2(0.08, 1)) # no-i18n
	f.set_state(Vector3(0, f.ball.radius + 0.001, 0), Vector3(1, -0.1, 0))
	f.advance_to_tick(240)
	_check(not f.resting and f.position().y < -1.0, "rolling off finite support resumes flight")
	f = RSBallFlight.new(_vacuum())
	f.add_plane(&"floor", slow, Vector3.ZERO) # no-i18n
	f.add_net(&"rolling_net", RSBallFlight.surface_net(), Vector3.ZERO, Vector3.BACK, 1.0, 1.0, 0.0) # no-i18n
	f.set_state(Vector3(0, f.ball.radius + 0.00001, -0.1), Vector3(0, -0.01, 1))
	_listen(f)
	f.advance_to_tick(30)
	var net_hit := false
	for e: Dictionary in _events:
		net_hit = net_hit or e["kind"] == RSBallFlight.CONTACT_NET # no-i18n
	_check(net_hit and f.position().z < 0.0, "rolling ball still sweeps nets")
	var elastic := RSBallFlight.Surface.new(1.0, 0.0)
	f = RSBallFlight.new(_vacuum())
	f.add_plane(&"left", elastic, Vector3(-0.04, 0, 0), Vector3.RIGHT) # no-i18n
	f.add_plane(&"right", elastic, Vector3(0.04, 0, 0), Vector3.LEFT) # no-i18n
	f.set_state(Vector3(0, 1, 0), Vector3(100, 0, 0))
	_listen(f)
	f.step()
	_check(_events.size() == 4 and absf(f.position().x) <= 0.006501, "four-contact budget keeps final safe position")
	var a := _corner_order(false)
	var b := _corner_order(true)
	_check(_same(a, b), "simultaneous contacts are independent of insertion order")


func _corner_order(reverse: bool) -> RSBallFlight:
	var f := RSBallFlight.new(_vacuum())
	var s := RSBallFlight.Surface.new(1.0, 0.0)
	if reverse:
		f.add_plane(&"z", s, Vector3.ZERO, Vector3.FORWARD) # no-i18n
	f.add_plane(&"a", s, Vector3.ZERO, Vector3.LEFT) # no-i18n
	if not reverse:
		f.add_plane(&"z", s, Vector3.ZERO, Vector3.FORWARD) # no-i18n
	f.set_state(Vector3(-0.1, 1, -0.1), Vector3(30, 0, 30))
	_listen(f)
	f.step()
	_check(_events.size() == 2 and _events[0]["id"] == &"a", "simultaneous contacts use stable ID order") # no-i18n
	return f


func _presets() -> void:
	var f := RSBallFlight.new(RSBallFlight.ball_volleyball())
	f.add_beach_court(Vector3(0, 2, 0), Vector3.RIGHT)
	f.set_state(Vector3(-0.2, 4, 0), Vector3(30, 0, 0))
	_listen(f)
	f.advance_to_tick(2)
	_check(not _events.is_empty() and _events[0]["kind"] == RSBallFlight.CONTACT_NET, "beach preset respects floor offset and length axis") # no-i18n
	f = RSBallFlight.new(_vacuum())
	f.add_tennis_court(RSBallFlight.surface_grass(), Vector3(0, 2, 0), Vector3.RIGHT)
	f.set_state(Vector3(-0.1, 2.5, 0), Vector3(30, 0, 0))
	_listen(f)
	f.step()
	_check(not _events.is_empty() and _events[0]["id"] == &"net", "tennis preset supplies rotated net") # no-i18n
