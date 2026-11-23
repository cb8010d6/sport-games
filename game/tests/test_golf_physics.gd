extends Node
## Independent analytic G3 expectations for actual 120 Hz motion, finite hazards and recoveries.
const Fixture := preload("res://tests/golf_physics_fixture.gd")
const R := 0.02135
const H := 1.0 / 120.0

var _checks := 0
var _failures := 0


func _ready() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("FAIL: " + message)


func _near(value: float, expected: float, tolerance: float, message: String) -> void:
	_check(absf(value - expected) <= tolerance, "%s: %s vs %s" % [message, value, expected])


func _run() -> void:
	var invalid := OS.get_environment("RS_GOLF_PHYSICS_INVALID")
	if not invalid.is_empty():
		_rejection(invalid)
		print("RS_GOLF_PHYSICS_REJECTION: %d checks, %d failures" % [_checks, _failures])
		get_tree().quit(1)
		return
	_intervals()
	_bounds()
	_support_and_flight()
	_roll()
	_bounce()
	_water_and_drop()
	_trees()
	_cup_and_priority()
	_state_deadline()
	_safety()
	print("RS_GOLF_PHYSICS_TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)


func _intervals() -> void:
	var interval := RSGolfIntervals.new()
	_check(interval.sphere(Vector3(-2, 0, 0), Vector3(2, 0, 0), Vector3.ZERO, 1.0), "sphere through interval")
	_near(interval.lo, 0.25, 1e-12, "sphere entry")
	_near(interval.hi, 0.75, 1e-12, "sphere exit")
	_check(interval.sphere(Vector3(-2, 1, 0), Vector3(2, 1, 0), Vector3.ZERO, 1.0), "closed tangent")
	_near(interval.lo, 0.5, 1e-12, "tangent time")
	_check(not interval.sphere(Vector3(-2, 1.001, 0), Vector3(2, 1.001, 0), Vector3.ZERO, 1.0), "finite near miss")
	_check(interval.capsule(Vector3(-2, 1, 0), Vector3(2, 1, 0), Vector3.ZERO, Vector3(0, 2, 0), 1.0), "finite cylinder body")
	_near(interval.lo, 0.25, 1e-12, "capsule side entry")
	_check(interval.capsule(Vector3(-2, 3, 0), Vector3(2, 3, 0), Vector3.ZERO, Vector3(0, 2, 0), 1.0), "finite cap tangent")
	_near(interval.lo, 0.5, 1e-12, "capsule cap time")
	_check(not interval.capsule(Vector3(-2, 3.01, 0), Vector3(2, 3.01, 0), Vector3.ZERO, Vector3(0, 2, 0), 1.0), "no infinite cylinder extension")
	_check(interval.ellipse(Vector3(-4, 0, 0), Vector3(4, 0, 0), Vector2.ZERO, Vector2(1, 2), PI / 2.0), "rotated ellipse")
	_near(interval.lo, 0.25, 1e-12, "rotated ellipse horizontal radius")


func _bounds() -> void:
	var routes: Array[PackedVector2Array] = [PackedVector2Array([Vector2(-10, 0), Vector2(10, 0)])]
	var world := Fixture.make(Vector2.ZERO, 0.0, [], [], Vector3.ZERO, Rect2(-100, -100, 200, 200), routes)
	_check(world.bounds.contains(Vector3(0, 100, 62)), "62 metres is inside independently of height")
	_check(not world.bounds.contains(Vector3(0, 0, 62.001)), "62.001 metres is OB")
	_near(world.bounds.first_exit(Vector3(0, 1, 61), Vector3(0, 1, 63)), 0.5, 1e-12, "continuous exact OB crossing")
	_check(world.bounds.first_exit(Vector3(0, 1, 61), Vector3(0, 1, 62)) == INF, "end exactly on closed boundary is inside")
	_near(world.bounds.first_exit(Vector3(0, 1, 62), Vector3(0, 1, 63)), 0.0, 1e-12, "outward from boundary exits immediately")
	var separated: Array[PackedVector2Array] = [PackedVector2Array([Vector2(-10, -70), Vector2(10, -70)]), PackedVector2Array([Vector2(-10, 70), Vector2(10, 70)])]
	world.bounds.build(world.surface, separated)
	_near(world.bounds.first_exit(Vector3(0, 1, -70), Vector3(0, 1, 70)), 62.0 / 140.0, 1e-12, "later re-entry cannot erase first OB")
	var broad: Array[PackedVector2Array] = [PackedVector2Array([Vector2(-1000, 0), Vector2(1000, 0)])]
	world.bounds.build(world.surface, broad)
	_near(world.bounds.first_exit(Vector3(99, 1, 0), Vector3(101, 1, 0)), 0.5, 1e-12, "terrain domain exits before height clamp")
	_check(not world.bounds.contains(Vector3(100.001, 0, 0)), "outside terrain is always OB")
	var out := RSGolfWorldHit.new()
	world.cast(Vector3(99, 1, 0), Vector3(101, 1, 0), R, false, Fixture.flags(world), Fixture.flags(world), false, out)
	_check(out.kind == RSGolfWorldHit.Kind.OB and out.fraction == 0.5, "world emits earliest OB")


func _support_and_flight() -> void:
	var world := Fixture.make(Vector2(0.1, 0.2))
	var out := RSGolfWorldHit.new()
	_check(world.support(Vector3(1, 0, 1), R, out), "sphere support on an analytic slope")
	_near(out.centre.y, 0.3 + R * sqrt(1.05), 3e-6, "support uses sphere radius along geometric normal")
	var initial := out.centre
	for i in 100:
		world.support(out.centre, R, out)
	_check(out.centre.x == initial.x and out.centre.z == initial.z, "support reuse never drifts XZ")
	world = Fixture.make()
	var ball := Fixture.ball(world, Vector3.ZERO)
	ball.position = Vector3(1, 2, 3)  # Explicit airborne fixture, no ground teleport in production.
	ball.strike(Vector3(10, 4, -2))
	ball.step()
	# Independently evaluated semi-implicit equations, coefficient 0.0045, gravity 9.81.
	var speed := sqrt(120.0)
	var expected := Vector3(10, 4, -2) * (1.0 - 0.0045 * speed * H) + Vector3.DOWN * (9.81 * H)
	_check(ball.velocity.distance_to(expected) < 2e-6, "relative quadratic drag and gravity fixed input")
	_check(ball.position.distance_to(Vector3(1, 2, 3) + expected * H) < 3e-7, "semi-implicit position uses updated velocity")
	world.wind = Vector3(5, 0, 0)
	ball = Fixture.ball(world, Vector3.ZERO)
	ball.position.y = 2.0
	ball.strike(Vector3.ZERO)
	ball.step()
	_near(ball.velocity.x, 0.0009375, 1e-9, "wind acts on relative air speed")
	world.wind = Vector3.ZERO
	ball = Fixture.ball(world, Vector3.ZERO)
	ball.position.y = 2.0
	ball.strike(Vector3(100, 0, 0), Vector3(0, 0, 1000))
	ball.step()
	_near(ball.velocity.y, -5.81 * H, 1e-8, "spin lift is bounded to 4 m/s squared")
	_near(ball.spin.z, 998.75, 1e-5, "spin decays once per fixed step")
	var ridge := Fixture.make(Vector2.ZERO, 0.0, [], [], Vector3(8, 0, 8), Rect2(-2.5, -2.5, 5, 5), [], RSGolfCourse.Lie.GREEN, true)
	ridge.cast(Vector3(-1, 0.25, 0), Vector3(1, 0.25, 0), R, false, Fixture.flags(ridge), Fixture.flags(ridge), false, out)
	_check(out.kind == RSGolfWorldHit.Kind.TERRAIN, "finite thin ridge swept before endpoint")
	_near(out.fraction, (0.75 - R * sqrt(2.0)) / 2.0, 2e-7, "independent 45 degree ridge TOI")


func _roll() -> void:
	var world := Fixture.make()
	var ball := Fixture.ball(world, Vector3.ZERO)
	ball.strike(Vector3.RIGHT, Vector3.ZERO, true)
	var ticks := 0
	var nonnegative := true
	while ball.active() and ticks < 1000:
		ball.step()
		nonnegative = nonnegative and ball.velocity.x >= 0.0
		ticks += 1
	_check(ball.outcome == RSGolfRules.Outcome.REST and nonnegative, "flat roll rests without reverse oscillation")
	_near(ball.position.x, 1.0 / 0.36, 0.03, "one metre per second green stopping distance")
	_check(ball._settled_ticks == 48 and ticks >= 48, "rest needs 0.4 continuous effective seconds")
	world = Fixture.make(Vector2(0.1, 0.0))
	ball = Fixture.ball(world, Vector3.ZERO)
	ball.strike(Vector3.ZERO, Vector3.ZERO, true)
	for i in 60:
		ball.step()
	_check(ball.active() and ball.velocity.x < 0.0 and ball._settled_ticks == 0, "slope force above static friction continues rolling")
	# At tan(theta)=0.1, horizontal a = -g*0.1/1.01 + mu/sqrt(1.01).
	# Sixty 120 Hz steps give -0.3960902 m/s; -0.5 was not a valid physical bound.
	var downhill_x := -0.5 * (9.81 * 0.1 / 1.01 - 0.18 / sqrt(1.01))
	_near(ball.velocity.x, downhill_x, 3e-5, "independent downhill acceleration over half a second")
	world = Fixture.make(Vector2(0.01, 0.0))
	ball = Fixture.ball(world, Vector3.ZERO)
	ball.strike(Vector3.ZERO, Vector3.ZERO, true)
	for i in 47:
		ball.step()
	_check(ball.active(), "47 quiet ticks cannot end a shot")
	ball.step()
	_check(ball.outcome == RSGolfRules.Outcome.REST, "48 quiet ticks stop on shallow slope")


func _bounce() -> void:
	for lie in 7:
		var world := Fixture.make(Vector2.ZERO, 0.0, [], [], Vector3(8, 0, 8), Rect2(-10, -10, 20, 20), [], lie)
		world.gravity = Vector3.ZERO
		var ball := Fixture.ball(world, Vector3.ZERO)
		ball.position.y = R + 0.05
		ball.strike(Vector3.DOWN * 12.0)
		ball.step()
		var coefficients := [0.35, 0.35, 0.25, 0.10, 0.25, 0.25, 0.05]
		_near(ball.velocity.y, (12.0 - 0.0045 * 144.0 * H) * float(coefficients[lie]), 2e-6, "surface restitution %d" % lie)
		_check(ball.position.y >= R and ball.active(), "bounce remains above rendered terrain %d" % lie)


func _water_and_drop() -> void:
	var ponds: Array = [[Vector2.ZERO, Vector2.ONE, 0.0, 0.0]]
	var world := Fixture.make(Vector2.ZERO, -1.0, ponds)
	var out := RSGolfWorldHit.new()
	world.cast(Vector3(-2, 5, 0), Vector3(2, 5, 0), R, false, Fixture.flags(world), Fixture.flags(world), false, out)
	_check(out.kind == RSGolfWorldHit.Kind.NONE, "overflight above actual water never penalizes")
	world.cast(Vector3(0, 1, 0), Vector3(0, -0.5, 0), R, false, Fixture.flags(world), Fixture.flags(world), false, out)
	_check(out.kind == RSGolfWorldHit.Kind.WATER, "descending sphere touches finite water")
	_near(out.fraction, (1.0 - R) / 1.5, 1e-12, "water contact includes physical ball radius")
	world.cast(Vector3(2, 1, 0), Vector3(2, -0.5, 0), R, false, Fixture.flags(world), Fixture.flags(world), false, out)
	_check(out.kind == RSGolfWorldHit.Kind.NONE, "no infinite pond plane outside footprint")
	var path := PackedVector3Array([Vector3(-4, 1, 0), Vector3(-2, 1, 0), Vector3(0, R, 0)])
	var drop := RSGolfDrop.new()
	var at := drop.find(world, path, path.size(), Vector3(-4, -1, 0), R, true)
	_near(at.x, -3.0, 2e-6, "drop is two metres behind last land boundary")
	_check(world.land_under(at) and at.distance_to(world.pin) > Vector3(-1, at.y, 0).distance_to(world.pin), "drop is legal and no closer to pin")
	var trees: Array = [[Vector3(-3, -1, 0), Vector3(-3, 4, 0), 1.0, 0.15, 6.0]]
	world = Fixture.make(Vector2.ZERO, -1.0, ponds, trees)
	at = drop.find(world, path, path.size(), Vector3(-4, -1, 0), R, true)
	_near(at.x, -3.5, 2e-6, "invalid first drop advances by exactly half a metre")
	world = Fixture.make(Vector2.ZERO, -1.0, ponds, [], Vector3(-8, -1, 0))
	at = drop.find(world, path, path.size(), Vector3(-4, -1, 0), R, true)
	_near(at.x, -4.0, 2e-6, "no eligible backward point falls back to previous shot")
	at = drop.find(world, path, path.size(), Vector3(-4, -1, 0), R, false)
	_near(at.x, -4.0, 2e-6, "OB always returns previous shot")


func _trees() -> void:
	var trees: Array = [[Vector3.ZERO, Vector3(0, 4, 0), 1.0, 0.1, 5.0]]
	var world := Fixture.make(Vector2.ZERO, 0.0, [], trees)
	world.gravity = Vector3.ZERO
	var ball := Fixture.ball(world, Vector3(-0.3, 0, 0))
	ball.strike(Vector3(48, 0, 0))
	ball.step()
	_near(ball.velocity.x, -(48.0 - 0.0045 * 48.0 * 48.0 * H) * 0.2, 3e-5, "trunk uses swept restitution 0.2")
	_check(ball.position.x < -0.1 - R and ball.active(), "trunk never tunnels through")
	ball = Fixture.ball(world, Vector3(-1, 0, 0.6))
	ball.position.y = 4.0
	ball.strike(Vector3(48, 0, 0))
	ball.step()
	_near(ball.velocity.x, (48.0 - 0.0045 * 48.0 * 48.0 * H) * 0.65, 3e-5, "first canopy entry multiplies speed once")
	var before := ball.velocity.x
	ball.step()
	_near(ball.velocity.x, before - 0.0045 * before * before * H, 3e-5, "remaining inside does not repeat canopy loss")
	for i in 20:
		if ball.position.x > 1.3:
			break
		ball.step()
	_check(ball._canopy[0] == 0 and ball.position.x > 1.0, "leaving tree unlocks a later entry")
	ball.velocity = Vector3(-48, 0, 0)
	var entered := false
	for i in 20:
		before = absf(ball.velocity.x)
		ball.step()
		if ball._canopy[0] != 0:
			_near(absf(ball.velocity.x), (before - 0.0045 * before * before * H) * 0.65, 4e-5, "re-entry after exit applies one new canopy loss")
			entered = true
			break
	_check(entered, "return path actually re-enters canopy")


func _cup_and_priority() -> void:
	var world := Fixture.make(Vector2.ZERO, 0.0, [], [], Vector3.ZERO)
	var slow := Fixture.ball(world, Vector3(-0.05, 0, 0))
	slow.strike(Vector3.RIGHT, Vector3.ZERO, true)
	for i in 3:
		slow.step()
	_check(slow.outcome == RSGolfRules.Outcome.HOLED and slow.position == world.pin, "one m/s grounded sweep enters real cup")
	var fast := Fixture.ball(world, Vector3(-0.05, 0, 0))
	fast.strike(Vector3.RIGHT * 2.0, Vector3.ZERO, true)
	fast.step()
	fast.step()
	_near(fast.velocity.x, (2.0 - 2.0 * 0.18 * H) * 0.8, 3e-7, "fast cup entry loses exactly 20 percent")
	_check(fast.active() and fast.outcome == -1, "fast cup glance does not score")
	var before := fast.velocity.x
	fast.step()
	_near(fast.velocity.x, before - 0.18 * H, 3e-7, "cup lock avoids repeated same-entry losses")
	var out := RSGolfWorldHit.new()
	world.cast(Vector3(-1, 1, 0), Vector3(1, 1, 0), R, false, Fixture.flags(world), Fixture.flags(world), false, out)
	_check(out.kind == RSGolfWorldHit.Kind.NONE, "airborne crossing cannot enter cup")
	world.pin = Vector3(10, 0, 0)
	world.sea_level = 1e-6  # Water, cup and outward OB all contain the represented start centre.
	var start := Vector3(10, R, 0)
	var end := Vector3(11, R, 0)
	world.cast(start, end, R, true, Fixture.flags(world), Fixture.flags(world), false, out)
	_check(out.kind == RSGolfWorldHit.Kind.CUP and out.fraction == 0.0, "simultaneous cup outranks water and OB")
	world.cast(start, end, R, true, Fixture.flags(world), Fixture.flags(world), true, out)
	_check(out.kind == RSGolfWorldHit.Kind.WATER, "same-time water outranks OB")
	world.sea_level = -INF
	world.cast(start, end, R, true, Fixture.flags(world), Fixture.flags(world), true, out)
	_check(out.kind == RSGolfWorldHit.Kind.OB, "reused output clears old hazards and contacts")


func _state_deadline() -> void:
	for entry_tick in [17999, 18000, 18001]:
		var world := Fixture.make(Vector2.ZERO, 0.0, [], [], Vector3.ZERO)
		var state := RSGolfState.new()
		state.reset(PackedInt32Array([4, 3, 5]), 1)
		_check(state.start_hole(0, Vector3(-0.05, 0, 0), world), "deadline fixture starts legally")
		var start_tick: int = entry_tick - 3
		for tick in range(1, start_tick + 1):
			state.rules.resolve_tick(tick, state.events)
		state.arm(start_tick)
		state.request(start_tick)
		_check(state.launch(Vector3.ZERO), "deadline shot consumes an actual command")
		# Exact flat initial speed yields entry after three unchanged physical steps.
		state.motion.velocity = Vector3.RIGHT
		for tick in range(start_tick + 1, RSGolfRules.HOLE_TICKS + 1):
			state.advance_tick(tick)
			state.rules.resolve_tick(tick, state.events)
			state.after_tick()
		var expected := RSGolfRules.Status.CAPPED if entry_tick > 18000 else RSGolfRules.Status.HOLED
		_check(state.rules.summary()["holes"][0]["status"] == expected, "real sphere contact before/at/after deadline %d" % entry_tick)
		_check(not state.flying, "deadline freezes unfinished physical ball")


func _safety() -> void:
	var world := Fixture.make()
	var ball := Fixture.ball(world, Vector3.ZERO)
	ball.strike(Vector3.RIGHT, Vector3.ZERO, true)
	ball.age_ticks = 2999
	ball.step()
	_check(ball.outcome == RSGolfRules.Outcome.REST and ball.position.is_finite(), "25 second guard ends a finite legal shot")
	var out := RSGolfWorldHit.new()
	world.cast(Vector3(0, R + 1e-6, 0), Vector3(0, R + 1, 0), R, false, Fixture.flags(world), Fixture.flags(world), false, out)
	_check(out.kind == RSGolfWorldHit.Kind.NONE, "separating ground touch does not block flight")
	world.cast(Vector3(0, R + 1e-6, 0), Vector3(1, R + 1e-6, 0), R, false, Fixture.flags(world), Fixture.flags(world), false, out)
	_check(out.kind == RSGolfWorldHit.Kind.NONE, "tangent supported sweep has no repeated impact")


func _rejection(kind: String) -> void:
	var world := Fixture.make()
	var ball := Fixture.ball(world, Vector3.ZERO)
	match kind:
		"nan":
			_check(not ball.strike(Vector3(NAN, 0, 0)), "NaN launch is an implementation failure")
			_check(ball.mode == RSGolfBall.Mode.INVALID and ball.outcome == -1, "NaN never becomes a scoreable fallback")
		"penetration":
			ball.strike(Vector3.DOWN)
			ball.position.y = 0.0
			ball.step()
			_check(ball.mode == RSGolfBall.Mode.INVALID and ball.outcome == -1, "deep terrain penetration fails instead of hiding as OB")
		"water":
			_check(not world.configure(world.surface, world.bounds, [[Vector2.ZERO, Vector2(0, 1), 0.0, 0.0]], [], Vector3.ZERO, -INF, Callable()), "zero water axis rejected")
		_:
			_check(false, "unknown rejection fixture")
