class_name RSSkateBot
extends RefCounted
## Autopilot for demo riders: picks a line through the course (kickers, rails, ledges,
## manual pads), pops at the right spots, does tricks that fit the predicted air time,
## and balances grinds and manuals with a little human wobble (so it bails now and then).

var sk: RSSkater
var course: RSSkateCourse
var c := RSMotionControls.new()

var _rng := RandomNumberGenerator.new()
var _plan: Array[Dictionary] = []
var _i := 0
var _lane := 0.0
var _was_air := false
var _air: Dictionary = {}
var _air_t := 0.0
var _spun := 0.0
var _push_cd := 0.0
var _popped_for := -1
var _prev_steer := 0.0
var _prev_pitch := 0.0
var _skill := 0.9


func _init(skater: RSSkater, seed_value: int, ability: float = -1.0) -> void:
	sk = skater
	course = skater.course
	_rng.seed = seed_value
	_lane = _rng.randf_range(-5.0, 5.0)
	_skill = _rng.randf_range(0.82, 0.97)
	if ability >= 0.0:
		_skill = clampf(ability, 0.5, 0.99)
	_make_plan()


func _make_plan() -> void:
	var cands: Array[Dictionary] = []
	for f in course.features:
		match f["type"]:
			"kicker":
				cands.append({"kind": "kicker", "x": f["x"], "w": f["w"], "s0": f["s0"], "s1": f["lip"] + 8.0, "lip": f["lip"], "p": 0.75})
			"pad":
				cands.append({"kind": "pad", "x": f["x"], "w": f["w"], "s0": f["s0"], "s1": f["s1"], "p": 0.5})
	for r in course.rails:
		if r.name == "Curb":
			continue
		var x := r.a.x
		if r.ledge:
			# Ride just outside the ledge so the board meets its edge.
			var top := course.top(x + 0.3, -r.a.z + 1.0)
			x += -0.12 if top > course.H(-r.a.z + 1.0) + 0.1 else 0.12
		cands.append({"kind": "rail", "x": x, "w": 0.0, "s0": -r.a.z, "s1": -r.b.z, "rail": r, "p": 0.5 if r.ledge else 0.7})
	for st: Array in [[125.0, 129.2], [300.0, 306.0]]:
		cands.append({"kind": "stairs", "x": 999.0, "w": 99.0, "s0": st[0], "s1": st[1] + 3.0, "p": 1.0})
	cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["s0"] < b["s0"])
	var free_from := 10.0
	for cd in cands:
		var stairs: bool = cd["kind"] == "stairs"
		if cd["s0"] < free_from + 7.0 and not stairs:
			continue
		if not stairs and _rng.randf() > cd["p"]:
			continue
		if stairs and not _plan.is_empty() and _plan[-1]["s1"] > cd["s0"]:
			continue      # already flying over them
		_plan.append(cd)
		free_from = cd["s1"]


func update(dt: float) -> RSMotionControls:
	c.ollie = 0.0
	c.flip = 0
	c.push = false
	c.yaw_delta = 0.0
	c.grab = false
	var s := sk.s()
	while _i < _plan.size() and _plan[_i]["s1"] < s:
		_i += 1
	var tgt: Dictionary = _plan[_i] if _i < _plan.size() and _plan[_i]["s0"] - s < 45.0 else {}
	var tx := _lane
	if not tgt.is_empty() and tgt["kind"] != "stairs":
		tx = tgt["x"]
		# Missed the line onto a rail: don't cut across it now that it has started.
		if tgt["kind"] == "rail" and s > float(tgt["s0"]) - 0.3 and sk.mode != RSSkater.Mode.GRIND and absf(sk.pos.x - tx) > 0.4:
			tx = sk.pos.x + signf(sk.pos.x - tx) * 0.5
	match sk.mode:
		RSSkater.Mode.RIDE, RSSkater.Mode.MANUAL:
			_was_air = false
			_ride(dt, s, tx, tgt)
		RSSkater.Mode.AIR:
			_in_air(dt, tx, tgt)
		RSSkater.Mode.GRIND:
			_was_air = false
			if sk.rail_name() == "Curb" and sk.grind_time() > 0.4:
				c.ollie = 0.7      # ended up on the curb by accident: hop off
			var drift := sk.needle - _prev_steer * 1.1
			c.steer = clampf(-drift / 1.1 * _skill + _rng.randf_range(-0.08, 0.08), -1.0, 1.0)
			c.pitch = 0.0
		_:
			c.steer = 0.0
			c.pitch = 0.0
	_prev_steer = c.steer
	_prev_pitch = c.pitch
	return c


func _ride(dt: float, s: float, tx: float, tgt: Dictionary) -> void:
	var lookahead := maxf(5.0, sk.speed * 0.8)
	var want := atan2(-(tx - sk.pos.x), lookahead)
	c.steer = clampf((sk.heading - want) * 2.5, -1.0, 1.0)
	c.pitch = 0.0
	_push_cd -= dt
	if sk.speed < 7.5 and _push_cd <= 0.0 and sk.mode == RSSkater.Mode.RIDE:
		c.push = true
		_push_cd = 0.9
	if tgt.is_empty():
		return
	var kind: String = tgt["kind"]
	var on_line := absf(sk.pos.x - tx) < (float(tgt["w"]) * 0.5 if kind == "kicker" else 0.32)
	if kind == "kicker" and on_line and s >= float(tgt["lip"]) - 0.35 - sk.speed * 0.02 and s < float(tgt["lip"]) and _popped_for != _i:
		_pop(0.95, true)
	elif kind == "rail" and absf(sk.pos.x - tx) < 0.9 and _popped_for != _i:
		var lead := sk.speed * 0.2
		if s >= float(tgt["s0"]) - lead and s < float(tgt["s0"]) + 1.5:
			_pop(1.0, false)
	elif kind == "stairs" and s >= float(tgt["s0"]) - 0.6 and _popped_for != _i:
		_pop(1.0, true)
	elif kind == "pad" and s > float(tgt["s0"]) + 0.6 and s < float(tgt["s1"]) - 1.2 and absf(sk.pos.x - tx) < float(tgt["w"]) * 0.5:
		var drift := sk.needle - (_prev_pitch - 0.62) * 1.8 if sk.mode == RSSkater.Mode.MANUAL else 0.0
		c.pitch = 0.62 - drift / 1.8 * _skill + _rng.randf_range(-0.03, 0.03)


func _pop(strength: float, flip_ok: bool) -> void:
	c.ollie = strength
	_popped_for = _i
	if flip_ok and _rng.randf() < 0.35:
		c.flip = -1 if _rng.randf() < 0.6 else 1


func _in_air(dt: float, tx: float, tgt: Dictionary) -> void:
	c.steer = clampf((tx - sk.pos.x) * 0.6, -1.0, 1.0) if not tgt.is_empty() and tgt["kind"] == "rail" else 0.0
	c.pitch = 0.0
	if not _was_air:
		_was_air = true
		_air_t = 0.0
		_spun = 0.0
		_air = _plan_air(_predict_air())
	_air_t += dt
	if _air.get("flip2", -1.0) >= 0.0 and _air_t >= float(_air["flip2"]):
		c.flip = int(_air["dir"])
		_air["flip2"] = -1.0
	if _air.get("flip", -1.0) >= 0.0 and _air_t >= float(_air["flip"]):
		c.flip = int(_air["dir"])
		_air["flip"] = -1.0
	var spin_goal: float = _air.get("spin", 0.0)
	if absf(_spun) < absf(spin_goal):
		var rate: float = spin_goal / maxf(float(_air["T"]) - 0.3, 0.3)
		var d := rate * dt
		_spun += d
		c.yaw_delta = d / RSSkater.SPIN_GAIN
	var g0: float = _air.get("grab0", -1.0)
	c.grab = g0 >= 0.0 and _air_t >= g0 and _air_t <= float(_air["grab1"])


func _predict_air() -> float:
	var p := sk.pos
	var v := sk.vel
	var t := 0.0
	while t < 3.0:
		v.y -= RSSkater.GRAV * 0.02
		p += v * 0.02
		t += 0.02
		if p.y <= course.surface(p.x, -p.z, p.y + 0.12).x and v.y < 0.0:
			break
	return t


func _plan_air(T: float) -> Dictionary:
	var a := {"T": T, "dir": -1 if _rng.randf() < 0.6 else 1}
	var already_flipping := sk.combo.size() > 0 and str(sk.combo[-1]["name"]).ends_with("flip")
	var r := _rng.randf()
	if T > 0.48 and not already_flipping and r < 0.7:
		a["flip"] = 0.02
		if T > 1.05 and _rng.randf() < 0.5:
			a["flip2"] = RSSkater.FLIP_TIME + 0.04
	if T > 0.75 and _rng.randf() < 0.55:
		a["spin"] = PI * (2.0 if T > 1.15 and _rng.randf() < 0.5 else 1.0) * (1.0 if _rng.randf() < 0.5 else -1.0)
	if T > 0.95 and not a.has("flip2") and _rng.randf() < 0.6:
		a["grab0"] = 0.4 if a.has("flip") else 0.15
		a["grab1"] = T - 0.3
	# Now and then a rider gets it wrong and bails.
	if _rng.randf() > _skill and a.has("flip"):
		a["flip"] = maxf(T - 0.15, 0.02)
	return a
