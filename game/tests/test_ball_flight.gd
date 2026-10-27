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
	_hits()
	_predictions()
	_prediction_limits()
	_net_predictions()
	_time_queries()
	_time_query_bounces()
	_aiming()
	_finite_table_aim()
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
	var reference: WeakRef = weakref(f)
	f.contacted.connect(func(kind: int, id: StringName, point: Vector3, speed: float) -> void:
		var current := reference.get_ref() as RSBallFlight
		if current == null:
			return
		_events.append({"kind": kind, "id": id, "point": point, "speed": speed,
				"tick": current.tick, "v": current.velocity(), "w": current.spin()})) # no-i18n


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


func _hits() -> void:
	var f := RSBallFlight.new(_vacuum())
	var face := RSBallFlight.Surface.new(0.8, 0.0)
	f.set_state(Vector3.ZERO, Vector3(-5, 0, 0))
	f.advance(0.01)
	var tick := f.tick
	_listen(f)
	_check(f.hit(Vector3(1, 2, 3), Vector3(2, 0, 0), Vector3.ZERO, face), "stationary face accepts approaching ball")
	_check(absf(f.velocity().x - 4.0) < 1e-6, "fixed face returns incident speed times restitution")
	_check(f.position().distance_to(Vector3(1 + f.ball.radius, 2, 3)) < 1e-6 and f.tick == tick, "hit moves centre by radius without advancing tick")
	_check(not f.resting and _events.is_empty(), "hit wakes ball without a step contact event")
	f.set_state(Vector3.ZERO, Vector3(-5, 0, 0))
	_check(f.hit(Vector3.ZERO, Vector3.RIGHT, Vector3(3, 0, 0), face) and f.velocity().x > 4.0, "forward swing accelerates return")
	face = RSBallFlight.racket_tennis()
	face.dwell = 0.0
	f.set_state(Vector3.ZERO, Vector3(-5, 0, 0))
	f.hit(Vector3.ZERO, Vector3.RIGHT, Vector3.ZERO, face)
	var ratio := f.ball.mass / face.mass
	var expected := 5.0 * (face.restitution - 5.0 * face.restitution_drop - ratio) / (1.0 + ratio)
	_check(absf(f.velocity().x - expected) < 1e-6, "finite effective racket mass follows two-body normal impulse")
	f.set_state(Vector3.ZERO, Vector3(-5, 0, 0))
	f.hit(Vector3.ZERO, Vector3.RIGHT, Vector3(3, 4, 0), RSBallFlight.racket_table_tennis())
	_check(f.velocity().x > 0.0 and f.spin().z < -1.0, "upward brush gives right-hand topspin for +X return")
	f.set_state(Vector3.ZERO, Vector3(-5, 0, 0))
	f.hit(Vector3.ZERO, Vector3(1, 0.35, 0), Vector3.ZERO, RSBallFlight.racket_table_tennis())
	_check(f.velocity().y > 0.0 and f.spin().z > 1.0, "laid-back face adds lift and backspin")
	f.set_state(Vector3.ZERO, Vector3.RIGHT)
	f.advance(0.01)
	var saved := f.snapshot().to_byte_array()
	_check(not f.hit(Vector3.ONE, Vector3.RIGHT, Vector3.ZERO, face), "departing ball rejects hit")
	_check(f.snapshot().to_byte_array() == saved, "rejected hit leaves complete snapshot unchanged")
	_check(not f.hit(Vector3.ONE, Vector3.ZERO, Vector3.ZERO, face) and f.snapshot().to_byte_array() == saved, "zero face normal is also a state-preserving rejection")
	var volley := RSBallFlight.new(RSBallFlight.ball_volleyball())
	for hands: RSBallFlight.Surface in [RSBallFlight.hands_bump(), RSBallFlight.hands_set(), RSBallFlight.hands_spike()]:
		volley.set_state(Vector3.ZERO, Vector3(0, -3, 0))
		_check(volley.hit(Vector3.ZERO, Vector3.UP, Vector3(0, 4, 1), hands) and volley.velocity().y > 0.0, "volleyball hand preset returns an approaching ball")
	_check(RSBallFlight.hands_set().dwell > RSBallFlight.hands_spike().dwell, "setting pockets the ball more than spiking")
	face = RSBallFlight.Surface.new(0.8, 0.4)
	face.dwell = 0.0
	f.set_state(Vector3.ZERO, Vector3(-5, 0, 0))
	f.hit(Vector3.ZERO, Vector3.RIGHT, Vector3(3, 4, 0), face)
	var without := f.velocity()
	face.dwell = 0.6
	f.set_state(Vector3.ZERO, Vector3(-5, 0, 0))
	f.hit(Vector3.ZERO, Vector3.RIGHT, Vector3(3, 4, 0), face)
	_check(absf(f.velocity().length() - without.length()) < 1e-5 and f.velocity().y > without.y, "dwell turns return toward hand motion while preserving speed")


func _predictions() -> void:
	var f := RSBallFlight.new(RSBallFlight.ball_tennis())
	f.add_plane(&"ground", RSBallFlight.surface_hard_court(), Vector3.ZERO) # no-i18n
	f.set_state(Vector3(0, 2, -2), Vector3(3, 1, 7), Vector3(20, 10, -40))
	f.advance(0.023)
	_listen(f)
	var saved := f.snapshot().to_byte_array()
	var start_tick := f.tick
	var result := f.predict(3.0, 2)
	_check(f.snapshot().to_byte_array() == saved and _events.is_empty(), "prediction neither mutates live state nor emits live contacts")
	_check(result.bounces.size() == 2 and result.bounce_times.size() == 2 and result.bounce_ids.size() == 2 and result.bounce_velocities.size() == 2, "prediction records all four bounce arrays consistently")
	for _i in 720:
		f.step()
		if not _events.is_empty():
			break
	_check(result.landed() and not _events.is_empty(), "prediction and real simulation both reach first bounce")
	if result.landed() and not _events.is_empty():
		var point: Vector3 = _events[0]["point"] # no-i18n
		_check(result.land_point() == point and result.land_point().distance_to(point) == 0.0, "first predicted and real contact positions match with zero error")
		_check(result.bounce_ids[0] == &"ground" and result.bounce_velocities[0].y < 0.0, "bounce ID and pre-impact velocity are recorded") # no-i18n
		var end_tick_time := (f.tick - start_tick) * RSBallFlight.STEP
		_check(result.land_time() > end_tick_time - RSBallFlight.STEP and result.land_time() <= end_tick_time, "bounce time includes fixed-step contact fraction, relative to call")
	var empty := f.predict(0.0)
	_check(not empty.landed() and empty.land_time() == -1.0 and empty.land_point() == f.position() and empty.end_time == 0.0, "zero-horizon prediction exposes safe end state")
	var zero := RSBallFlight.new(_vacuum())
	zero.add_plane(&"floor", RSBallFlight.Surface.new(0.0, 0.0), Vector3.ZERO) # no-i18n
	zero.set_state(Vector3(0, 0.034, 0), Vector3(0, -0.01, 0))
	var settled := zero.predict(3.0)
	_check(settled.settled and settled.end_time < 3.0, "prediction stops when ball settles")
	var corridor := RSBallFlight.new(_vacuum())
	var elastic := RSBallFlight.Surface.new(1.0, 0.0)
	corridor.add_plane(&"left", elastic, Vector3(-0.04, 0, 0), Vector3.RIGHT) # no-i18n
	corridor.add_plane(&"right", elastic, Vector3(0.04, 0, 0), Vector3.LEFT) # no-i18n
	corridor.set_state(Vector3(0, 1, 0), Vector3(100, 0, 0))
	var four := corridor.predict(RSBallFlight.STEP, 4)
	_check(four.bounces.size() == 4, "prediction records all four contacts inside one fixed step")
	var chronological := four.bounces.size() == 4
	for i in four.bounce_times.size():
		chronological = chronological and four.bounce_times[i] > 0.0 and four.bounce_times[i] <= RSBallFlight.STEP
		if i > 0:
			chronological = chronological and four.bounce_times[i] > four.bounce_times[i - 1]
	_check(chronological, "same-step contacts preserve fractional chronological order")
	_check(corridor.predict(RSBallFlight.STEP, 1).bounces.size() == 1, "prediction records only the requested bounce prefix")
	var reference: WeakRef = weakref(corridor)
	_listen(corridor)
	corridor = null
	_check(reference.get_ref() == null, "contact recording fixture does not retain a flight through its signal")


func _prediction_limits() -> void:
	var f := RSBallFlight.new(_vacuum())
	f.add_plane(&"floor", RSBallFlight.surface_floor(), Vector3.ZERO) # no-i18n
	f.set_state(Vector3(0, 0.034, 0), Vector3.DOWN)
	var saved := f.snapshot().to_byte_array()
	var short := f.predict(0.0001)
	_check(not short.landed() and short.bounce_times.is_empty() and short.bounce_ids.is_empty() and short.bounce_velocities.is_empty(), "prediction excludes a floor contact after its sub-step horizon")
	_check(short.end_time > 0.0 and short.end_time <= 0.0001 and short.end_velocity.y < 0.0, "prediction end state stays before the out-of-window rebound")
	var within := f.predict(0.0006)
	_check(within.landed() and within.land_time() > 0.0001 and within.land_time() <= 0.0006, "prediction includes a floor contact inside a sub-step horizon")
	_check(within.end_time <= 0.0006, "prediction never reports an end time after max_time")
	_check(f.snapshot().to_byte_array() == saved, "clipped predictions preserve the original snapshot")
	f = RSBallFlight.new(_vacuum())
	f.add_net(&"net", RSBallFlight.surface_net(), Vector3.ZERO, Vector3.BACK, 2.0, 1.0, 0.0) # no-i18n
	f.set_state(Vector3(0, 1.5, -0.05), Vector3(0, 0, 30))
	short = f.predict(0.0001)
	_check(not short.net_crossed and not short.net_hit and short.net_time == -1.0, "prediction excludes a net crossing after its horizon")
	within = f.predict(0.002)
	_check(within.net_crossed and within.net_time <= 0.002 and within.end_time <= 0.002, "prediction includes an in-window net crossing without advancing past the horizon")
	f.set_state(Vector3(0, 0.5, -0.05), Vector3(0, 0, 30))
	short = f.predict(0.0001)
	_check(not short.net_hit and short.net_time == -1.0, "prediction excludes a net touch after its horizon")
	within = f.predict(0.001)
	_check(within.net_hit and within.net_time > 0.0001 and within.net_time <= 0.001, "prediction retains a net touch inside its horizon")


func _net_predictions() -> void:
	var f := RSBallFlight.new(_vacuum())
	f.add_net(&"net", RSBallFlight.surface_net(), Vector3.ZERO, Vector3.BACK, 2.0, 1.0, 0.0, RSBallFlight.surface_net_cord()) # no-i18n
	f.set_state(Vector3(0, 1.5, -0.05), Vector3(0, 0, 30))
	var over := f.predict(0.05)
	_check(over.net_crossed and not over.net_hit and over.net_clearance > 0.4 and over.net_time > 0.0, "clear flight reports positive first-crossing clearance")
	f.set_state(Vector3(0, 1.0 + f.ball.radius, -0.05), Vector3(0, 0, 30))
	var grazing := f.predict(0.01)
	_check(grazing.net_hit and absf(grazing.net_clearance) < 0.002, "grazing top cord reports nearly zero clearance")
	f.set_state(Vector3(0, 0.5, -0.05), Vector3(0, 0, 30))
	var below := f.predict(0.05)
	_check(below.net_hit and not below.net_crossed and below.net_clearance < -0.5 and below.net_time > 0.0, "blocked low ball reports negative touch clearance despite never crossing plane")
	f.set_state(Vector3(3, 0.5, -0.05), Vector3(0, 0, 30))
	var outside := f.predict(0.05)
	_check(not outside.net_hit and not outside.net_crossed and outside.net_clearance == INF, "crossing outside net width does not invent a net event")


func _time_queries() -> void:
	var f := RSBallFlight.new(_vacuum())
	f.set_state(Vector3(0, 2, 0), Vector3(3, 2, 0))
	f.advance(0.01)
	var saved := f.snapshot().to_byte_array()
	var crossing := f.time_to_plane(Vector3(1, 0, 0), Vector3.RIGHT)
	var p := f.copy()
	var before := p.position().x
	var actual := -1.0
	for i in 240:
		p.step()
		var after := p.position().x
		if before < 1.0 and after >= 1.0:
			actual = (i + (1.0 - before) / (after - before)) * RSBallFlight.STEP
			break
		before = after
	_check(actual >= 0.0 and absf(crossing - actual) < RSBallFlight.STEP, "time_to_plane matches actual interpolated crossing within one step")
	var rise := f.time_to_height(2.1, 3.0, false)
	var fall := f.time_to_height(2.1, 3.0, true)
	_check(rise > 0.0 and fall > rise, "height query distinguishes ascending and descending crossings")
	_check(f.time_to_height(100.0) == -1.0 and f.time_to_plane(Vector3(-1, 0, 0), Vector3.RIGHT, 0.1) == -1.0, "unreached height/plane returns -1")
	_check(f.time_to_plane(Vector3.ZERO, Vector3.ZERO) == -1.0, "zero query normal is rejected")
	var future := f.probe(0.537)
	p = f.copy()
	p.advance_to_tick(p.tick + floori(0.537 * RSBallFlight.HZ))
	_check(_same(future, p) and not future.emit_events, "probe uses whole fixed steps without the per-frame hitch cap")
	_check(f.snapshot().to_byte_array() == saved, "all time queries and probes preserve original snapshot")


func _time_query_bounces() -> void:
	var elastic := RSBallFlight.Surface.new(1.0, 0.0)
	var corridor := RSBallFlight.new(_vacuum())
	corridor.add_plane(&"left", elastic, Vector3(-0.04, 0, 0), Vector3.RIGHT) # no-i18n
	corridor.add_plane(&"right", elastic, Vector3(0.04, 0, 0), Vector3.LEFT) # no-i18n
	corridor.set_state(Vector3(0, 1, 0), Vector3(100, 0, 0))
	_listen(corridor)
	var saved := corridor.snapshot().to_byte_array()
	var plane := corridor.time_to_plane(Vector3(0.003, 0, 0), Vector3.RIGHT, RSBallFlight.STEP)
	_check(plane > 0.0 and absf(plane - 0.00003) < 1e-7, "plane query finds the first crossing before same-step bounces return to the starting side")
	_check(corridor.time_to_plane(Vector3(0.003, 0, 0), Vector3.RIGHT, 0.00002) == -1.0, "plane query excludes a crossing after its sub-step horizon")
	_check(corridor.snapshot().to_byte_array() == saved and _events.is_empty(), "bouncing plane queries preserve live state and emit no live contacts")
	var vertical := RSBallFlight.new(_vacuum())
	vertical.add_plane(&"bottom", elastic, Vector3(0, 0.96, 0), Vector3.UP) # no-i18n
	vertical.add_plane(&"top", elastic, Vector3(0, 1.04, 0), Vector3.DOWN) # no-i18n
	vertical.set_state(Vector3(0, 1, 0), Vector3(0, 100, 0))
	_listen(vertical)
	saved = vertical.snapshot().to_byte_array()
	var rise := vertical.time_to_height(1.003, RSBallFlight.STEP, false)
	var fall := vertical.time_to_height(0.997, RSBallFlight.STEP, true)
	_check(rise > 0.0 and absf(rise - 0.00003) < 1e-7, "ascending height query sees a crossing hidden by a same-step ceiling rebound")
	_check(fall > rise and absf(fall - 0.00016) < 1e-7, "descending height query uses the post-rebound segment rather than the whole-step chord")
	_check(vertical.time_to_height(1.003, 0.00002, false) == -1.0, "height query excludes a crossing after its sub-step horizon")
	_check(vertical.snapshot().to_byte_array() == saved and _events.is_empty(), "bouncing height queries preserve live state and emit no live contacts")


func _aiming() -> void:
	var tennis := RSBallFlight.new(RSBallFlight.ball_tennis())
	tennis.add_plane(&"court", RSBallFlight.surface_hard_court(), Vector3.ZERO) # no-i18n
	var court_targets: Array[Vector3] = [Vector3(-3, 0, -1), Vector3(3, 0, 1), Vector3(-2, 0, 3), Vector3(2, 0, -3), Vector3(0, 0, 5)]
	_aim_targets(tennis, Vector3(0, 1.8, -8), court_targets, 16.0, Vector3(10, 25, -40))
	var table := RSBallFlight.new(RSBallFlight.ball_table_tennis())
	table.add_plane(&"table", RSBallFlight.surface_table(), Vector3(0, 0.76, 0), Vector3.UP, RSBallFlight.TABLE_SIZE * 0.5) # no-i18n
	var table_targets: Array[Vector3] = [Vector3(-0.5, 0.76, -0.4), Vector3(0.5, 0.76, 0.4), Vector3(-0.3, 0.76, 0.8), Vector3(0.3, 0.76, -0.6), Vector3(0, 0.76, 1.0)]
	_aim_targets(table, Vector3(0, 1.1, -1.1), table_targets, 7.0, Vector3(0, 30, -80))
	var from := Vector3(0, 1.5, -4)
	var target := Vector3(0, 0, 2)
	var low := tennis.aim(from, target, 14.0)
	var high := tennis.aim(from, target, 14.0, Vector3.ZERO, true)
	_check(low != Vector3.ZERO and high != Vector3.ZERO and high.y > low.y + 1.0, "lob chooses a distinct higher arc")
	_aim_landing(tennis, from, target, high, Vector3.ZERO)
	_check(tennis.aim(from, Vector3(0, 0, 1000), 1.0) == Vector3.ZERO, "unreachable aim returns zero")
	_check(tennis.aim(from, target, 0.0) == Vector3.ZERO and tennis.aim(from, target, 14.0, Vector3.ZERO, false, 0) == Vector3.ZERO, "invalid speed and zero solver budget return zero")
	var saved := tennis.snapshot().to_byte_array()
	_listen(tennis)
	tennis.add_net(&"obstruction", RSBallFlight.surface_net(), Vector3.ZERO, Vector3.BACK, 10.0, 10.0, 0.0) # no-i18n
	_check(tennis.aim(from, target, 14.0) == low, "aim ignores net without changing shared world")
	_check(tennis.snapshot().to_byte_array() == saved and _events.is_empty(), "aim changes neither original state nor emits signals")
	var shot := tennis.copy()
	shot.set_state(from, low)
	_check(shot.predict().net_hit, "original world still contains net for subsequent flight prediction")


func _finite_table_aim() -> void:
	var table := RSBallFlight.new(RSBallFlight.ball_table_tennis())
	table.add_plane(&"table", RSBallFlight.surface_table(), Vector3(0, 0.76, 0), Vector3.UP, RSBallFlight.TABLE_SIZE * 0.5) # no-i18n
	var from := Vector3(0, 1.1, -3)
	var target := Vector3(0, 0.76, -1.35)
	var saved := table.snapshot().to_byte_array()
	var launch := table.aim(from, target, 7.0)
	_check(launch != Vector3.ZERO and absf(launch.length() - 7.0) < 1e-5, "aim reaches a finite table edge even when its first trial misses the table")
	_aim_landing(table, from, target, launch, Vector3.ZERO)
	_check(table.aim(from, Vector3(0, 0.76, -1.6), 7.0) == Vector3.ZERO, "aim rejects a landing target outside the finite table")
	_check(table.snapshot().to_byte_array() == saved, "finite table aim preserves the original snapshot")


func _aim_targets(f: RSBallFlight, from: Vector3, targets: Array[Vector3], speed: float, spin: Vector3) -> void:
	var max_error := 0.0
	for target: Vector3 in targets:
		var saved := f.snapshot().to_byte_array()
		var launch := f.aim(from, target, speed, spin)
		_check(launch != Vector3.ZERO and absf(launch.length() - speed) < 1e-5, "reachable aim returns requested launch speed")
		_check(f.snapshot().to_byte_array() == saved, "aim preserves state for each target")
		max_error = maxf(max_error, _aim_landing(f, from, target, launch, spin))
	print("BALL_NUMERIC aim_radius_m=%.4f targets=%d max_error_m=%.6f" % [f.ball.radius, targets.size(), max_error]) # no-i18n


func _aim_landing(f: RSBallFlight, from: Vector3, target: Vector3, launch: Vector3, spin: Vector3) -> float:
	if launch == Vector3.ZERO:
		_check(false, "aim must produce a velocity before verifying actual landing")
		return INF
	var actual := f.copy()
	actual.emit_events = true
	actual.set_state(from, launch, spin)
	_listen(actual)
	for _i in 2400:
		actual.step()
		if not _events.is_empty():
			break
	_check(not _events.is_empty(), "actual aimed flight must reach a first surface contact")
	if _events.is_empty():
		return INF
	var point: Vector3 = _events[0]["point"] # no-i18n
	var error := point.distance_to(target + Vector3.UP * f.ball.radius)
	_check(error < 0.05, "actual first landing error stays below 5 cm (%.6f m)" % error)
	return error
