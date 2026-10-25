extends Node
## RSBallFlight checks: determinism under any frame chunking, bounce / energy sanity, Magnus direction, nets,
## prediction equal to the live flight, hits and real-world plausibility for the three ball presets.

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


func _run() -> void:
	_determinism()
	_bounces()
	_magnus()
	_nets()
	_prediction()
	_hits()
	_plausible()
	print("RS_BALL_TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)


func _tennis(court := RSBallFlight.surface_hard_court()) -> RSBallFlight:
	var f := RSBallFlight.new(RSBallFlight.ball_tennis())
	f.add_tennis_court(court)
	return f


func _table() -> RSBallFlight:
	var f := RSBallFlight.new(RSBallFlight.ball_table_tennis())
	f.add_table_tennis_table(Vector3.ZERO)
	return f


func _finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


func _determinism() -> void:
	# A serve that crosses the net, bounces, rolls and settles: every code path inside step().
	var start := func(f: RSBallFlight) -> void:
		f.set_state(Vector3(0.4, 2.7, 11.9), Vector3(-1.0, -2.0, -38.0), Vector3(-120.0, 40.0, 0.0))
	var ref := _tennis()
	start.call(ref)
	var states: Array[PackedFloat64Array] = [ref.snapshot()]
	var contacts := [0]
	ref.contacted.connect(func(_k: int, _id: StringName, _p: Vector3, _s: float) -> void: contacts[0] += 1)
	for _i in 2400:
		ref.step()
		states.append(ref.snapshot())
	_check(contacts[0] >= 3 and ref.resting, "reference flight bounces several times and settles")
	var rng := RandomNumberGenerator.new()
	rng.seed = 4711
	for pattern in 6:
		var f := _tennis()
		start.call(f)
		var same := true
		while f.tick < 2400:
			var delta := rng.randf_range(0.0005, 0.06) if pattern < 3 else [1.0 / 30.0, 1.0 / 60.0, 1.0 / 144.0][pattern - 3]
			f.advance(delta)
			same = same and f.tick <= 2400 and f.snapshot() == states[f.tick]
		_check(same, "state is bit-identical to the reference at every tick (chunking %d)" % pattern)
	var a := _tennis()
	var b := _tennis()
	start.call(a)
	start.call(b)
	a.advance_to_tick(700)
	var snap := a.snapshot()
	b.restore(snap)
	_check(b.snapshot() == states[700], "restore() reproduces an exact snapshot")
	a.advance_to_tick(1500)
	b.advance_to_tick(1500)
	_check(a.snapshot() == b.snapshot() and a.snapshot() == states[1500], "a restored flight continues identically (LAN hit event)")
	var c := _tennis()
	start.call(c)
	c.advance(0.2)
	var steps := c.advance(10.0)
	_check(steps == RSBallFlight.MAX_FRAME_STEPS, "a long hitch runs a bounded number of steps")


func _apex_after_bounce(f: RSBallFlight) -> float:
	var bounced := false
	var apex := -INF
	for _i in 2000:
		var vy := f.velocity().y
		f.step()
		if not bounced and vy < 0.0 and f.velocity().y > 0.0:
			bounced = true
		if bounced:
			apex = maxf(apex, f.position().y)
			if f.velocity().y < 0.0:
				break
	return apex


func _bounces() -> void:
	var r := RSBallFlight.ball_tennis().radius
	var hard := _tennis()
	hard.set_state(Vector3(0, 2.54 + r, 5), Vector3.ZERO)
	var rebound := _apex_after_bounce(hard) - r
	_check(rebound > 1.25 and rebound < 1.65, "tennis ball dropped from 2.54 m rebounds 1.25-1.65 m (%.3f)" % rebound)
	var tt := _table()
	var rt := RSBallFlight.ball_table_tennis().radius
	tt.set_state(Vector3(0.2, 0.76 + 0.305 + rt, 0.5), Vector3.ZERO)
	var tt_rebound := _apex_after_bounce(tt) - 0.76 - rt
	_check(tt_rebound >= 0.23 and tt_rebound < 0.305, "ITTF table: 30.5 cm drop rebounds >= 23 cm (%.3f)" % tt_rebound)
	var vb := RSBallFlight.new(RSBallFlight.ball_volleyball())
	vb.add_beach_court()
	vb.set_state(Vector3(2, 3.0, 3), Vector3.ZERO)
	var sand := _apex_after_bounce(vb) - RSBallFlight.ball_volleyball().radius
	_check(sand < 0.25, "volleyball barely bounces on sand (%.3f)" % sand)

	# Energy never rises: in flight (drag only removes it, Magnus is perpendicular) or at contacts.
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var rises := 0
	for sample in 12:
		var f := _tennis(RSBallFlight.surface_clay() if sample % 2 else RSBallFlight.surface_hard_court())
		f.set_state(Vector3(rng.randf_range(-3, 3), rng.randf_range(0.5, 3), rng.randf_range(2, 10)),
				Vector3(rng.randf_range(-5, 5), rng.randf_range(-10, 10), rng.randf_range(-30, 30)),
				Vector3(rng.randf_range(-300, 300), rng.randf_range(-300, 300), rng.randf_range(-300, 300)))
		var e := f.energy()
		for _i in 1500:
			f.step()
			var e2 := f.energy()
			if e2 > e + 1e-6 * maxf(e, 1.0):
				rises += 1
			e = e2
		_check(_finite(f.position()) and f.position().y >= r - 1e-6, "random flight stays finite and above the court")
	_check(rises == 0, "energy never increases (%d rises)" % rises)

	# Settling and rolling.
	var roll := _tennis()
	roll.set_state(Vector3(0, 1.0, 5), Vector3(3, 0, 0))
	roll.advance_to_tick(RSBallFlight.HZ * 30)
	_check(roll.resting and roll.velocity() == Vector3.ZERO, "a bouncing ball settles, rolls and stops")
	_check(absf(roll.position().y - r) < 1e-6, "a settled ball rests on the court surface")
	var edge := _table()
	edge.set_state(Vector3(0.0, 0.76 + rt + 0.01, 1.0), Vector3(0, 0, 1.5))
	edge.advance_to_tick(RSBallFlight.HZ * 10)
	_check(edge.resting and absf(edge.position().y - rt) < 1e-6, "a ball rolling off the table falls and settles on the floor")


func _magnus() -> void:
	var f := RSBallFlight.new(RSBallFlight.ball_tennis())
	f.set_state(Vector3.ZERO, Vector3(20, 0, 0), Vector3.ZERO)
	f._accel(20, 0, 0)
	var flat := Vector3(f._ax, f._ay, f._az)
	f.set_state(Vector3.ZERO, Vector3(20, 0, 0), Vector3(0, 0, -200))
	f._accel(20, 0, 0)
	_check(f._ay < flat.y - 1.0 and absf(f._az) < 1e-9, "topspin (spin -Z on +X flight) pushes the ball down")
	f.set_state(Vector3.ZERO, Vector3(20, 0, 0), Vector3(0, 0, 200))
	f._accel(20, 0, 0)
	_check(f._ay > flat.y + 1.0, "backspin lifts the ball")
	f.set_state(Vector3.ZERO, Vector3(20, 0, 0), Vector3(0, 200, 0))
	f._accel(20, 0, 0)
	_check(f._az < -1.0 and absf(f._ay - flat.y) < 1e-9, "sidespin about +Y curves a +X flight toward -Z")
	var weak := RSBallFlight.new(RSBallFlight.ball_tennis())
	weak.set_state(Vector3.ZERO, Vector3(20, 0, 0), Vector3(0, 0, -100))
	weak._accel(20, 0, 0)
	_check(weak._ay > f._ay - 100.0 and weak._ay < flat.y and weak._ay > -9.81 - 9.0, "lift grows with spin and stays bounded")
	var ranges: Array[float] = []
	for spin_z: float in [-300.0, 0.0, 300.0]:
		var g := _tennis()
		g.set_state(Vector3(0, 1.0, 11), Vector3(0, 25 * sin(0.14), -25 * cos(0.14)), Vector3(spin_z, 0, 0))
		ranges.append(g.predict().land_point().z)
	# Flight along -Z: topspin is spin about +X... check with the cross product: (+X) x (-Z) = +Y? No: x x -z = +y.
	_check(ranges[0] < ranges[1] and ranges[1] < ranges[2], "topspin lands shorter, backspin longer (%s)" % str(ranges))
	var spin := Vector3(0, 0, 300)
	var decay := RSBallFlight.new(RSBallFlight.ball_tennis())
	decay.set_state(Vector3(0, 100, 0), Vector3(10, 0, 0), spin)
	decay.advance_to_tick(RSBallFlight.HZ)
	_check(decay.spin().z < 300 and decay.spin().z > 300 * (1.0 - 0.031), "spin decays at the ball's rate in flight")


func _nets() -> void:
	# Low drive into the net from the +Z side: hits the mesh, never crosses, falls back on its own side.
	var f := _tennis()
	f.set_state(Vector3(0, 0.5, 6), Vector3(0, 0.5, -20), Vector3.ZERO)
	var hits := []
	f.contacted.connect(func(k: int, id: StringName, p: Vector3, s: float) -> void: hits.append([k, id, p, s]))
	var pr := f.predict(3.0, 1)
	_check(pr.net_hit and pr.landed() and pr.land_point().z > 0.0, "prediction: drive hits the net and drops on the hitter's side")
	f.advance_to_tick(RSBallFlight.HZ)
	_check(not hits.is_empty() and hits[0][0] == RSBallFlight.CONTACT_NET and hits[0][1] == &"net", "live: net mesh contact event")
	_check(f.position().z > 0.0, "ball never passes through the net mesh")
	# Over the net: clearance from the prediction matches a manual crossing search.
	var g := _tennis()
	g.set_state(Vector3(0, 1.0, 11), Vector3(0, 6.0, -25), Vector3(-150, 0, 0))
	var over := g.predict(3.0, 1)
	var probe := g.copy()
	var prev := probe.position()
	while probe.position().z > 0.0:
		prev = probe.position()
		probe.step()
	var cur := probe.position()
	var y := prev.y + (cur.y - prev.y) * (prev.z / (prev.z - cur.z))
	var expect := y - RSBallFlight.ball_tennis().radius - RSBallFlight.TENNIS_NET_HEIGHT
	_check(over.net_crossed and not over.net_hit and absf(over.net_clearance - expect) < 1e-4, "net clearance %.3f m matches the crossing" % over.net_clearance)
	_check(over.land_point().z < 0.0, "a clean shot lands on the far side")
	# Clipping the tape: aim the ball's bottom 1 cm under the cord top.
	var cord := _tennis()
	var r := RSBallFlight.ball_tennis().radius
	cord.set_state(Vector3(0, RSBallFlight.TENNIS_NET_HEIGHT + r - 0.01, 0.5), Vector3(0, 0, -15), Vector3.ZERO)
	var kinds := []
	cord.contacted.connect(func(k: int, _id: StringName, _p: Vector3, _s: float) -> void: kinds.append(k))
	cord.advance_to_tick(RSBallFlight.HZ / 4)
	_check(kinds.size() > 0 and kinds[0] == RSBallFlight.CONTACT_CORD, "ball clipping the tape hits the cord")
	_check(cord.velocity().length() < 15.0, "cord contact slows the ball")
	# Beach net is open below the mesh.
	var vb := RSBallFlight.new(RSBallFlight.ball_volleyball())
	vb.add_beach_court()
	vb.set_state(Vector3(0, 1.0, 2), Vector3(0, 0.5, -8))
	var under := vb.predict(2.0, 1)
	_check(under.net_crossed and not under.net_hit and under.net_clearance < -1.0, "ball passes under the beach net without touching")
	# Ball resting against nothing: the side of the net away from the ball cannot be hit from behind.
	var tt := _table()
	tt.set_state(Vector3(0.0, 0.76 + 0.1, 1.0), Vector3(0, 0.6, -6), Vector3(-200, 0, 0))
	var low := tt.predict(2.0, 1)
	_check(low.net_hit or low.net_crossed, "table tennis drive interacts with the net plane")


func _prediction() -> void:
	var f := _table()
	f.set_state(Vector3(0.1, 0.95, 1.6), Vector3(-0.3, 1.0, -7.0), Vector3(-300, 30, 0))
	var pr := f.predict(3.0, 2)
	var live := []
	f.contacted.connect(func(k: int, id: StringName, p: Vector3, _s: float) -> void:
		if k == RSBallFlight.CONTACT_SURFACE:
			live.append([id, p, f.tick]))
	f.advance_to_tick(RSBallFlight.HZ * 3)
	_check(pr.bounces.size() == 2 and live.size() >= 2, "two bounces predicted and simulated")
	if pr.bounces.size() == 2 and live.size() >= 2:
		_check(pr.bounces[0] == live[0][1] and pr.bounces[1] == live[1][1], "predicted bounce points equal the live ones exactly")
		_check(pr.bounce_ids[0] == live[0][0] and pr.bounce_times[0] == live[0][2] * RSBallFlight.STEP, "bounce surface and time match")
		_check(pr.bounce_ids[0] == &"table" and pr.land_point().z < 0.0, "drive lands on the far half of the table")
	var g := _tennis()
	g.set_state(Vector3(0, 1.0, 11), Vector3(0, 8.0, -22), Vector3(-150, 0, 0))
	var t_up := g.time_to_height(2.0, 3.0, false)
	var t_down := g.time_to_height(1.0, 3.0, true)
	var t_plane := g.time_to_plane(Vector3.ZERO, Vector3.BACK)
	var h := g.copy()
	var crossing := {}
	var last := h.position()
	for _i in RSBallFlight.HZ * 3:
		h.step()
		var p := h.position()
		if not crossing.has("up") and last.y < 2.0 and p.y >= 2.0:
			crossing["up"] = h.time()
		if not crossing.has("down") and last.y > 1.0 and p.y <= 1.0:
			crossing["down"] = h.time()
		if not crossing.has("plane") and last.z > 0.0 and p.z <= 0.0:
			crossing["plane"] = h.time()
		last = p
	_check(crossing.size() == 3, "manual search finds all crossings")
	_check(absf(t_up - crossing.get("up", 0.0)) <= RSBallFlight.STEP, "time to rise to a height")
	_check(absf(t_down - crossing.get("down", 0.0)) <= RSBallFlight.STEP, "time to fall to a height")
	_check(absf(t_plane - crossing.get("plane", 0.0)) <= RSBallFlight.STEP, "time to reach a plane")
	_check(g.time_to_height(50.0) < 0.0, "unreachable height returns -1")
	var p2 := g.probe(0.5)
	g.advance_to_tick(RSBallFlight.HZ / 2)
	_check(p2.snapshot() == g.snapshot() and g.tick == RSBallFlight.HZ / 2, "probe() equals the live state")
	# Aim: bots ask for a launch velocity to a target with given speed and spin.
	for lob: bool in [false, true]:
		var a := _tennis()
		var target := Vector3(2.5, 0, -9.0)
		var v := a.aim(Vector3(-1, 1.0, 11.5), target, 24.0 if not lob else 18.0, Vector3(-150, 0, 0), lob)
		_check(v != Vector3.ZERO and absf(v.length() - (24.0 if not lob else 18.0)) < 1e-3, "aim returns a velocity of the asked speed (lob %s)" % lob)
		a.set_state(Vector3(-1, 1.0, 11.5), v, Vector3(-150, 0, 0))
		var land := a.predict().land_point()
		_check(Vector2(land.x - target.x, land.z - target.z).length() < 0.25, "aimed shot lands at the target (lob %s, %s)" % [lob, land])
		if lob:
			_check(v.y > 6.0, "lob arc is high")
	var t := _table()
	var tv := t.aim(Vector3(0.3, 0.9, 1.6), Vector3(-0.4, 0.76, -0.9), 9.0, Vector3(-400, 0, 0))
	t.set_state(Vector3(0.3, 0.9, 1.6), tv, Vector3(-400, 0, 0))
	var tp := t.predict()
	_check(tv != Vector3.ZERO and tp.net_crossed and tp.net_clearance > 0.0 and tp.bounce_ids[0] == &"table", "table tennis bot aim clears the net and hits the table")
	_check(_tennis().aim(Vector3(0, 1, 11), Vector3(0, 0, -200), 10.0) == Vector3.ZERO, "out of reach returns zero")


func _hits() -> void:
	var paddle := RSBallFlight.racket_table_tennis()
	var f := _table()
	f.set_state(Vector3(0, 1.0, 1.5), Vector3.ZERO)
	_check(f.hit(Vector3(0, 1.0, 1.5), Vector3(0, 0, -1), Vector3(0, 0, -10), paddle), "racket hits a ball in front of the face")
	var e := paddle.restitution - paddle.restitution_drop * 10.0
	var mr := 0.0027 / paddle.mass
	var expect := 10.0 * (1.0 + (e - mr) / (1.0 + mr))
	_check(absf(f.velocity().length() - expect) < 1e-3 and f.velocity().normalized().is_equal_approx(Vector3(0, 0, -1)), "square hit: speed from restitution and effective mass")
	_check(f.position().is_equal_approx(Vector3(0, 1.0, 1.5 - 0.02)), "ball sits one radius in front of the contact point")
	f.set_state(Vector3(0, 1.0, 1.5), Vector3(0, 0, 4))
	f.hit(Vector3(0, 1.0, 1.5), Vector3(0, 0, -1), Vector3(0, 6, -8), paddle)
	_check(f.spin().x < -50.0 and f.velocity().y > 0.0 and f.velocity().z < 0.0, "brushing up the face gives topspin (spin -X on a -Z shot)")
	f.set_state(Vector3(0, 1.0, 1.5), Vector3(0, 0, 4))
	f.hit(Vector3(0, 1.0, 1.5), Vector3(0, 0.5, -0.866), Vector3(0, 0, -6), paddle)
	_check(f.spin().x > 20.0 and f.velocity().y > 0.5, "an open face lifts the ball with backspin")
	f.set_state(Vector3(0, 1.0, 1.5), Vector3(0, 0, -12))
	var before := f.snapshot()
	_check(not f.hit(Vector3(0, 1.0, 1.5), Vector3(0, 0, -1), Vector3(0, 0, -3), paddle), "a ball moving away from the face is not hit")
	_check(f.snapshot() == before, "a missed hit leaves the state untouched")
	var t := _tennis()
	t.set_state(Vector3(0, 2.8, 11.9), Vector3(0, 0, 0))
	t.hit(Vector3(0, 2.8, 11.9), Vector3(0, -0.1, -1), Vector3(0, -4, -40), RSBallFlight.racket_tennis())
	var serve := t.velocity().length()
	_check(serve > 52.0 and serve < 64.0, "40 m/s racket head serves at 52-64 m/s (%.1f)" % serve)
	var hold := RSBallFlight.racket_tennis()
	hold.dwell = 1.0
	t.set_state(Vector3(0, 1, 5), Vector3(0, 0, 10))
	t.hit(Vector3(0, 1, 5), Vector3(0, 0, -1), Vector3(0, 8, -20), hold)
	_check(t.velocity().normalized().is_equal_approx(Vector3(0, 8, -20).normalized()), "full dwell sends the ball along the swing path")
	var bump := RSBallFlight.new(RSBallFlight.ball_volleyball())
	bump.add_beach_court()
	bump.set_state(Vector3(0, 0.8, 4), Vector3(0, -6, -2))
	bump.hit(Vector3(0, 0.7, 4), Vector3(0, 1, -0.2), Vector3(0, 2, 0), RSBallFlight.hands_bump())
	var peak := bump.position().y + bump.velocity().y * bump.velocity().y / (2 * 9.81)
	_check(bump.velocity().y > 3.0 and peak > 2.0 and peak < 8.0, "forearm bump pops a falling ball up %.1f m" % peak)


func _plausible() -> void:
	# Flat-ish first serve, 50 m/s from 2.8 m at the baseline centre into the deuce service box.
	var serve := _tennis()
	var from := Vector3(0.3, 2.8, 11.885)
	var v := serve.aim(from, Vector3(-2.5, 0, -5.5), 50.0, Vector3(-150, 60, 0))
	serve.set_state(from, v, Vector3(-150, 60, 0))
	var pr := serve.predict()
	var angle := rad_to_deg(asin(v.y / v.length()))
	var land_speed := pr.bounce_velocities[0].length() if pr.landed() else 0.0
	print("RS_BALL_INFO: serve angle %.2f deg, clearance %.3f m, flight %.3f s, bounce speed %.1f m/s" % [angle, pr.net_clearance, pr.land_time(), land_speed])
	_check(angle < -2.0 and angle > -10.0, "a 50 m/s serve into the box leaves 2-10 deg downward (%.2f)" % angle)
	_check(pr.net_crossed and pr.net_clearance > 0.0 and pr.net_clearance < 0.8, "serve clears the net by a plausible margin")
	_check(pr.land_time() > 0.38 and pr.land_time() < 0.62, "serve reaches the box in 0.38-0.62 s")
	_check(land_speed > 30.0 and land_speed < 44.0, "drag slows the serve to 30-44 m/s at the bounce")
	var after := serve.copy()
	after.advance_to_tick(int(pr.land_time() * RSBallFlight.HZ) + 3)
	_check(after.velocity().length() < land_speed and after.velocity().y > 0.0, "the bounce takes speed off and sends the ball up")
	# Same incoming ball on hard court and clay: clay bounces steeper and slower.
	var out := []
	for court: RSBallFlight.Surface in [RSBallFlight.surface_hard_court(), RSBallFlight.surface_clay()]:
		var c := _tennis(court)
		c.set_state(Vector3(0, 0.3, -5), Vector3(0, -6, -22), Vector3(-200, 0, 0))
		c.advance_to_tick(RSBallFlight.HZ / 4)
		out.append(c.velocity())
	_check(out[1].y > out[0].y and absf(out[1].z) < absf(out[0].z), "clay: higher, slower bounce than hard court")
	# Drag: light balls lose speed much faster than a tennis ball.
	var losses := []
	for b: RSBallFlight.Ball in [RSBallFlight.ball_tennis(), RSBallFlight.ball_volleyball(), RSBallFlight.ball_table_tennis()]:
		var d := RSBallFlight.new(b)
		d.set_state(Vector3(0, 1000, 0), Vector3(20, 0, 0))
		d.advance_to_tick(RSBallFlight.HZ / 2)
		losses.append(1.0 - d.velocity().x / 20.0)
	_check(losses[0] > 0.05 and losses[0] < 0.25 and losses[1] > losses[0] and losses[2] > 0.45, "drag losses over 0.5 s: tennis %.2f, volleyball %.2f, table tennis %.2f" % losses)
	# Volleyball jump serve over the 2.43 m net into the far court.
	var vb := RSBallFlight.new(RSBallFlight.ball_volleyball())
	vb.add_beach_court()
	var vs := vb.aim(Vector3(0, 2.9, 8.5), Vector3(1, 0, -6), 20.0, Vector3(-30, 0, 0))
	vb.set_state(Vector3(0, 2.9, 8.5), vs, Vector3(-30, 0, 0))
	var vp := vb.predict()
	_check(vs != Vector3.ZERO and vp.net_clearance > 0.0 and vp.land_time() > 0.7 and vp.land_time() < 1.6, "volleyball serve clears the net and flies 0.7-1.6 s")
