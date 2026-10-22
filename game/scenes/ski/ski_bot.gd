class_name RSSkiBot
extends RefCounted
## Autopilot for demo skiers: a racing line through the gates, lined up on the kickers,
## tucks on the straights and checks speed before the jumps, spins and grabs that fit the
## predicted air time. A little human error: now and then a gate is cut too fine or a spin
## comes round short.

var sk: RSSkier
var course: RSSkiCourse
var c := RSMotionControls.new()

var _rng := RandomNumberGenerator.new()
var _points: Array[Dictionary] = []   ## {s, x, kind ("gate" / "ramp" / "lip"), w}
var _i := 0
var _skill := 0.9
var _vmax := 24.0
var _push_cd := 0.0
var _was_air := false
var _air: Dictionary = {}
var _air_t := 0.0
var _spun := 0.0
var _popped_for := -1
var _err := 0.0


func _init(skier: RSSkier, seed_value: int, ability: float = -1.0) -> void:
	sk = skier
	course = skier.course
	_rng.seed = seed_value
	_skill = _rng.randf_range(0.84, 0.97)
	_vmax = _rng.randf_range(22.0, 27.0)
	if ability >= 0.0:
		_skill = clampf(ability, 0.5, 0.99)
		_vmax = lerpf(16.0, 29.0, clampf((ability - 0.5) / 0.5, 0.0, 1.0))
	for g in course.gates:
		# Through the gate a little on the inside of the next turn, with some slop.
		var x := float(g["x"]) - float(g["side"]) * float(g["w"]) * 0.25
		x += _rng.randf_range(-1.0, 1.0) * float(g["w"]) * (1.0 - _skill) * 4.0
		_points.append({"s": float(g["s"]), "x": x, "kind": "gate", "w": float(g["w"])})
	for k in course.kickers:
		var lip: float = k["lip"]
		var x := course.centre(lip) + float(k["u"])
		_points.append({"s": lip - float(k["len"]) - 14.0, "x": x, "kind": "ramp", "w": 2.0})
		_points.append({"s": lip, "x": x, "kind": "lip", "w": 2.0, "h": float(k["h"])})
	_points.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["s"] < b["s"])


func update(dt: float) -> RSMotionControls:
	c.ollie = 0.0
	c.flip = 0
	c.push = false
	c.yaw_delta = 0.0
	c.grab = false
	var s := sk.s()
	while _i < _points.size() and float(_points[_i]["s"]) < s:
		_i += 1
	if sk.finished:
		c.steer = 0.0
		c.pitch = 0.0
		return c
	match sk.mode:
		RSSkier.Mode.RIDE:
			_was_air = false
			_ride(dt, s)
		RSSkier.Mode.AIR:
			_in_air(dt)
		_:
			c.steer = 0.0
			c.pitch = 0.0
	return c


func _target(s: float) -> Vector2:
	## (x, s) to steer at: the next point, sliding on to the one after as it comes close.
	if _i >= _points.size():
		return Vector2(course.centre(s + 30.0), s + 30.0)
	var a: Dictionary = _points[_i]
	var at := Vector2(float(a["x"]), float(a["s"]))
	if a["kind"] == "lip" or _i + 1 >= _points.size():
		return at
	var ds := at.y - s
	var b: Dictionary = _points[_i + 1]
	if b["kind"] == "lip":
		return at
	var blend := clampf(1.0 - ds / 9.0, 0.0, 0.6)
	return at.lerp(Vector2(float(b["x"]), float(b["s"])), blend)


func _ride(dt: float, s: float) -> void:
	# Head for a point not far ahead, part way across to the target in piste terms, so the
	# line follows the bends instead of cutting across them.
	var t := _target(s)
	var ds := maxf(t.y - s, 5.0)
	var sa := minf(ds, maxf(12.0, sk.current_speed() * 0.9))
	var u0 := course.lateral(sk.pos.x, sk.pos.z)
	var ut := t.x - course.centre(t.y)
	var xa := course.centre(s + sa) + lerpf(u0, ut, sa / ds)
	var want := atan2(-(xa - sk.pos.x), sa)
	_err = lerpf(_err, _rng.randf_range(-0.12, 0.12), dt * 2.0)
	c.steer = clampf((sk.heading - want) * 2.6 + _err * (1.0 - _skill) * 4.0, -1.0, 1.0)
	var spd := sk.current_speed()
	# Speed: tuck when running straight, check before a jump, brake if it gets silly.
	var cap := _vmax
	var nk := _next_kick(s)
	if not nk.is_empty() and float(nk["s"]) - s < 70.0:
		cap = 12.0 + float(nk["h"]) * 1.5
	c.pitch = 0.0
	if spd < cap - 1.0 and absf(c.steer) < 0.3:
		c.pitch = -0.75
	elif spd > cap + 1.5:
		c.pitch = 0.75
	_push_cd -= dt
	if spd < 5.0 and _push_cd <= 0.0:
		c.push = true
		_push_cd = 0.7
	# Pop off the lip.
	if not nk.is_empty() and _popped_for != int(nk["i"]):
		var lip := float(nk["s"])
		if s >= lip - 0.4 - spd * 0.03 and s < lip and absf(sk.pos.x - float(nk["x"])) < 3.0:
			c.ollie = _rng.randf_range(0.7, 1.0)
			_popped_for = int(nk["i"])


func _next_kick(s: float) -> Dictionary:
	for j in range(_i, _points.size()):
		var p: Dictionary = _points[j]
		if p["kind"] == "lip" and float(p["s"]) >= s - 0.5:
			return {"s": p["s"], "x": p["x"], "h": p["h"], "i": j}
		if float(p["s"]) - s > 120.0:
			break
	return {}


func _in_air(dt: float) -> void:
	c.steer = 0.0
	c.pitch = 0.0
	if not _was_air:
		_was_air = true
		_air_t = 0.0
		_spun = 0.0
		_air = _plan_air(_predict_air())
	_air_t += dt
	var goal: float = _air.get("spin", 0.0)
	if absf(_spun) < absf(goal):
		var rate: float = goal / maxf(float(_air["T"]) - 0.35, 0.3)
		var d := rate * dt
		if absf(_spun + d) > absf(goal):
			d = goal - _spun
		_spun += d
		c.yaw_delta = d / RSSkier.SPIN_GAIN
	var g0: float = _air.get("grab0", -1.0)
	c.grab = g0 >= 0.0 and _air_t >= g0 and _air_t <= float(_air["grab1"])
	if c.grab:
		c.pitch = float(_air.get("grab_pitch", 0.0))
		c.steer = float(_air.get("grab_steer", 0.0))


func _predict_air() -> float:
	var p := sk.pos
	var v := sk.vel
	var t := 0.0
	while t < 4.0:
		v.y -= RSSkier.GRAV * 0.02
		p += v * 0.02
		t += 0.02
		if v.y < 0.0 and p.y <= course.height(p.x, p.z):
			break
	return t


func _plan_air(T: float) -> Dictionary:
	var a := {"T": T}
	var dir := 1.0 if _rng.randf() < 0.5 else -1.0
	if T > 1.05 and _rng.randf() < 0.75:
		var turns := 2.0
		if T > 1.5 and _rng.randf() < 0.5:
			turns = 4.0
		elif T > 1.3 and _rng.randf() < 0.35:
			turns = 3.0
		a["spin"] = PI * turns * dir
		# Now and then it comes round short.
		if _rng.randf() > _skill:
			a["spin"] = float(a["spin"]) - dir * _rng.randf_range(0.5, 1.0)
	if T > 0.8 and _rng.randf() < 0.65:
		a["grab0"] = 0.2
		a["grab1"] = T - 0.35
		var kind := _rng.randi_range(0, 3)
		a["grab_pitch"] = [0.0, -0.6, 0.6, 0.0][kind]
		a["grab_steer"] = [0.0, 0.0, 0.0, -0.6][kind]
	return a
