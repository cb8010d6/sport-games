extends Node
## Performance guards (#53): the indexed skate course lookups answer exactly like the old
## linear scans, the ride clock never runs more than RSFixedStep.MAX_STEPS sub-steps a frame
## (also at 30 FPS) and keeps real time, and the split-screen shadow tier switches the sun
## and restores the scene's values.

var _failures := 0
var _checks := 0


func _ready() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1":
		push_error("Run tools/test_perf.py with isolated user data.")
		get_tree().quit(1)
		return
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("FAIL: " + message)


func _run() -> void:
	_course_lookups()
	_clock()
	await _riders_at_30fps()
	await _idle_loops()
	_split_shadow_tier()
	for i in 3:   # let freed riders' rendering resources go before quitting
		await get_tree().process_frame
	print("RS_PERF_TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)


# ---------------------------------------------------------------- old linear lookups ----

func _old_h(c: RSSkateCourse, s: float) -> float:
	var n := c._ps.size()
	if s <= c._ps[0]:
		return c._py[0]
	for i in range(1, n):
		if s <= c._ps[i]:
			return lerpf(c._py[i - 1], c._py[i], (s - c._ps[i - 1]) / (c._ps[i] - c._ps[i - 1]))
	return c._py[n - 1]


func _old_slope(c: RSSkateCourse, s: float) -> float:
	for i in range(1, c._ps.size()):
		if s <= c._ps[i]:
			return (c._py[i] - c._py[i - 1]) / (c._ps[i] - c._ps[i - 1])
	return 0.0


func _old_surface(c: RSSkateCourse, x: float, s: float, y_max: float) -> Vector3:
	var base := _old_h(c, s)
	var best := Vector3(base, _old_slope(c, s), -1.0)
	if absf(x) > RSSkateCourse.HALF_W and not c.stairs_at(s):
		best.x += RSSkateCourse.CURB
	for i in c.pieces.size():
		var p := c.pieces[i]
		if p.contains(x, s):
			var y := base + p.rel(s)
			if y <= y_max and y > best.x:
				best = Vector3(y, _old_slope(c, s) + p.slope(s), float(i))
	return best


func _old_top(c: RSSkateCourse, x: float, s: float) -> float:
	var base := _old_h(c, s)
	var best := base + (RSSkateCourse.CURB if absf(x) > RSSkateCourse.HALF_W and not c.stairs_at(s) else 0.0)
	for p in c.pieces:
		if p.contains(x, s):
			best = maxf(best, base + p.rel(s))
	return best


func _course_lookups() -> void:
	var c := RSSkateCourse.new()
	# Every knot and piece edge (and just either side of it), plus a regular sweep.
	var ss: Array[float] = []
	for k in c._ps:
		ss.append_array([k, k - 0.001, k + 0.001])
	for p in c.pieces:
		ss.append_array([p.s0, p.s1, p.s0 - 0.001, p.s1 + 0.001, (p.s0 + p.s1) * 0.5])
	var s := -100.0
	while s < 660.0:
		ss.append(s)
		s += 0.37
	var xs: Array[float] = [-13.0, -10.2, -9.0, -6.5, -3.1, -0.4, 0.0, 1.7, 4.4, 8.9, 9.1, 11.8]
	for p in c.pieces:
		xs.append_array([p.x0, p.x1])
	var bad := {"H": 0, "road_slope": 0, "surface": 0, "top": 0}
	var points := 0
	for sv in ss:
		if c.H(sv) != _old_h(c, sv):
			bad["H"] += 1
		if c.road_slope(sv) != _old_slope(c, sv):
			bad["road_slope"] += 1
		var base := _old_h(c, sv)
		for xv in xs:
			points += 1
			for y_max: float in [base + 0.3, base + 1.6, 1e9]:
				if c.surface(xv, sv, y_max) != _old_surface(c, xv, sv, y_max):
					bad["surface"] += 1
			if c.top(xv, sv) != _old_top(c, xv, sv):
				bad["top"] += 1
	for key: String in bad:
		_check(bad[key] == 0, "%s equals the linear scan at every sampled point (%d differ)" % [key, bad[key]])
	_check(points > 50000, "course lookups sampled enough points (%d)" % points)
	# Cost per call, old vs new (informational; printed for the performance write-up).
	var t0 := Time.get_ticks_usec()
	for i in 20000:
		_old_surface(c, -2.0 + (i % 9), 30.0 + (i % 500), 1e9)
	var t1 := Time.get_ticks_usec()
	for i in 20000:
		c.surface(-2.0 + (i % 9), 30.0 + (i % 500), 1e9)
	var t2 := Time.get_ticks_usec()
	print("RS_PERF_LOOKUP: surface() linear %.2f us, indexed %.2f us, %d pieces, %d knots" % [
		(t1 - t0) / 20000.0, (t2 - t1) / 20000.0, c.pieces.size(), c._ps.size()])
	c.free()


# ----------------------------------------------------------------------- ride clock ----

func _clock() -> void:
	for fps: float in [30.0, 40.0, 60.0, 75.0, 100.0, 144.0, 240.0]:
		var clk := RSFixedStep.new()
		var simulated := 0.0
		var most := 0
		var dt := 1.0 / fps
		for i in 600:
			var n := clk.advance(dt)
			most = maxi(most, n)
			simulated += n * clk.h
		_check(most <= RSFixedStep.MAX_STEPS, "%d FPS: at most %d sub-steps a frame (saw %d)" % [fps, RSFixedStep.MAX_STEPS, most])
		_check(absf(simulated + clk.acc - 600.0 * dt) < 1e-6, "%d FPS: simulated time keeps up with real time" % fps)
		var old_steps := ceili(dt / (1.0 / 120.0))
		print("RS_PERF_STEPS: %d FPS old %d sub-steps/frame, new at most %d" % [fps, old_steps, most])
	var clk := RSFixedStep.new()
	_check(clk.advance(1.0 / 60.0) == 2 and clk.advance(1.0 / 60.0) == 2, "60 FPS runs exactly two sub-steps a frame")
	_check(clk.advance(0.5) == RSFixedStep.MAX_STEPS and is_equal_approx(clk.h, RSFixedStep.MAX_H) and clk.acc == 0.0,
		"a half-second hitch runs MAX_STEPS steps of MAX_H and drops the rest")
	# Drawing carries the last sub-step's motion over the leftover time and snaps after a teleport.
	clk.reset(Vector3.ZERO)
	clk.advance(1.5 / 120.0)
	clk.push(Vector3.ZERO, Vector3(1, 0, 0))
	_check(clk.draw(Vector3(1, 0, 0)).is_equal_approx(Vector3(1.5, 0, 0)), "draw() carries the last step's motion over the leftover time")
	clk.advance(0.5 / 120.0)
	clk.push(Vector3(1, 0, 0), Vector3(2, 0, 0))
	_check(clk.draw(Vector3(2, 0, 0)) == Vector3(2, 0, 0), "draw() is the simulated position when no time is left over")
	_check(clk.draw(Vector3(9, 0, 0)) == Vector3(9, 0, 0), "draw() follows a position moved outside the sub-steps")
	clk.push(Vector3(9, 0, 0), Vector3(30, 0, 0))
	_check(clk.draw(Vector3(30, 0, 0)) == Vector3(30, 0, 0), "draw() does not blend across a teleport")


func _riders_at_30fps() -> void:
	## Real riders driven by bots at a steady 30 FPS: the cap holds every frame and they ride.
	## CI checks out the game without the character art; the clock checks above still run there.
	if not (ResourceLoader.exists(RSSkaterRig.RIDERS[1]) and ResourceLoader.exists(RSSkierRig.SKIERS[1])):
		print("RS_PERF_SKIP: rider models not checked out; 30 FPS rider check skipped")
		return
	var skate := RSSkateCourse.new()
	var sk := RSSkater.new(skate, Color.WHITE, 1, 0)
	add_child(sk)
	sk.place(0.0, RSSkateCourse.START_S)
	var sk_bot := RSSkateBot.new(sk, 4100)
	var ski := RSSkiCourse.new(0)
	var sr := RSSkier.new(ski, Color.WHITE, 1, 0)
	add_child(sr)
	sr.place(0.0, 5.0)
	var sr_bot := RSSkiBot.new(sr, 91)
	await get_tree().process_frame
	var dt := 1.0 / 30.0
	var most := 0
	var t0 := Time.get_ticks_usec()
	for i in 300:
		sk.step(dt, sk_bot.update(dt), true)
		most = maxi(most, sk.clock.steps)
		sr.step(dt, sr_bot.update(dt), true)
		most = maxi(most, sr.clock.steps)
	var spent := (Time.get_ticks_usec() - t0) / 300.0
	_check(most <= RSFixedStep.MAX_STEPS, "skater and skier at 30 FPS: at most %d sub-steps a frame (saw %d)" % [RSFixedStep.MAX_STEPS, most])
	_check(sk.s() > RSSkateCourse.START_S + 20.0, "the skater rides down the street at 30 FPS (s = %.1f)" % sk.s())
	_check(sr.s() > 25.0, "the skier rides down the slope at 30 FPS (s = %.1f)" % sr.s())
	_check(sk.draw_pos.distance_to(sk.pos) < 1.0 and sr.draw_pos.distance_to(sr.pos) < 1.0, "riders are drawn next to their simulated position")
	print("RS_PERF_RIDERS: skater + skier step at 30 FPS: %.1f us per frame" % spent)
	sk.free()
	sr.free()
	skate.free()
	ski.free()
	for i in 3:
		await get_tree().process_frame


func _idle_loops() -> void:
	if not (ResourceLoader.exists(RSSkaterRig.RIDERS[1]) and ResourceLoader.exists(RSSkierRig.SKIERS[1])):
		print("RS_PERF_SKIP: rider models not checked out; idle loop check skipped")
		return
	var skate := RSSkateCourse.new()
	var sk := RSSkater.new(skate, Color.WHITE, 1, 0)
	add_child(sk)
	var ski := RSSkiCourse.new(0)
	var sr := RSSkier.new(ski, Color.WHITE, 1, 0)
	add_child(sr)
	await get_tree().process_frame
	var sk_before := sk.active_loops()
	var sr_before := sr.active_loops()
	_check(sk_before == 4 and sr_before == 3, "new riders expose all four / three unpaused loops")
	# place() runs visuals/audio with delta 0 and correctly pauses the initial -80 dB.
	# Sample the factory state above, before placement applies that idle-audio update.
	sk.place(0.0, RSSkateCourse.START_S)
	sr.place(0.0, 5.0)
	for rider in [sk, sr]:
		var loop: AudioStreamPlayer = rider._wind
		rider._set_loop_db(loop, rider.SILENT_DB)
		_check(loop.stream_paused and loop.volume_db == rider.SILENT_DB, "loop pauses at the inclusive silent threshold")
		rider._set_loop_db(loop, rider.SILENT_DB + 0.1)
		_check(not loop.stream_paused, "loop resumes immediately above the threshold")
	sk.quiet()
	sr.quiet()
	_check(sk.active_loops() == 0 and sr.active_loops() == 0, "quiet pauses every rider loop")
	print("RS_PERF_LOOPS: idle skater %d -> %d, idle skier %d -> %d" % [
		sk_before, sk.active_loops(), sr_before, sr.active_loops()])
	var sk_bot := RSSkateBot.new(sk, 4100)
	var sr_bot := RSSkiBot.new(sr, 91)
	for i in 60:
		var dt := 1.0 / 30.0
		sk.step(dt, sk_bot.update(dt), true)
		sr.step(dt, sr_bot.update(dt), true)
	_check(sk.active_loops() > 0, "the moving skater automatically resumes a loop after quiet")
	_check(sr.active_loops() > 0, "the moving skier automatically resumes a loop after quiet")
	sk.quiet()
	sr.quiet()
	_check(sk.active_loops() == 0 and sr.active_loops() == 0, "quiet works again after bot-driven resumption")
	sk.free()
	sr.free()
	skate.free()
	ski.free()
	for i in 3:
		await get_tree().process_frame


# ------------------------------------------------------------- split shadow tier ----

func _split_shadow_tier() -> void:
	var world := Node3D.new()
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 110.0
	world.add_child(sun)
	var lamp := DirectionalLight3D.new()   # a scene that already uses two cascades is left alone
	lamp.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	lamp.directional_shadow_max_distance = 40.0
	world.add_child(lamp)
	var split_1 := sun.directional_shadow_split_1
	RSSettings.set_views(1, world)
	RSSettings.apply_world(world)
	_check(sun.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS and sun.directional_shadow_max_distance == 110.0,
		"one view keeps the scene's four cascades and distance")
	for n in [2, 3, 4, 2, 1]:
		RSSettings.set_views(n, world)
		var tier: bool = n >= RSSettings.SPLIT_TIER_VIEWS
		_check(RSSettings.split_tier() == tier, "%d views: split tier is %s" % [n, tier])
		_check(sun.directional_shadow_mode == (DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if tier else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS),
			"%d views: sun cascades follow the tier" % n)
		_check(is_equal_approx(sun.directional_shadow_max_distance, 110.0 * (RSSettings.SPLIT_SHADOW_DISTANCE if tier else 1.0)),
			"%d views: shadow distance follows the tier" % n)
		_check(is_equal_approx(sun.directional_shadow_split_1, RSSettings.SPLIT_SHADOW_SPLIT if tier else split_1),
			"%d views: near cascade split follows the tier" % n)
		_check(lamp.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS and lamp.directional_shadow_max_distance == 40.0,
			"%d views: a two-cascade light keeps its scene values" % n)
	# Re-applying the quality gates (a lobby map switch, #54) keeps the tier and stays idempotent.
	RSSettings.set_views(4, world)
	RSSettings.apply_world(world)
	RSSettings.apply_world(world)
	_check(sun.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		and is_equal_approx(sun.directional_shadow_max_distance, 110.0 * RSSettings.SPLIT_SHADOW_DISTANCE),
		"apply_world keeps the split tier without compounding it")
	# A sun built while four views are up starts in the tier.
	var late := DirectionalLight3D.new()
	late.directional_shadow_max_distance = 90.0
	world.add_child(late)
	RSSettings.apply_world(world)
	_check(late.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		and is_equal_approx(late.directional_shadow_max_distance, 90.0 * RSSettings.SPLIT_SHADOW_DISTANCE),
		"a sun built during a four-view round joins the tier")
	RSSettings.set_views(1, world)
	_check(late.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS and late.directional_shadow_max_distance == 90.0,
		"leaving the tier restores the late sun's scene values")
	world.free()
