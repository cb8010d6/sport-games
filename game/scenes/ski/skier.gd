class_name RSSkier
extends Node3D
## One racer on an RSSkiCourse: carving physics, jumps and tricks, gates, nets and crashes.
## Driven by RSMotionControls (the same motion gestures as the skateboard, or a bot):
##  - tilt left/right: turn. Gentle tilt carves (keeps speed); full tilt at speed skids
##    (tighter, slower, snow spray). Tilt the tip back: brake (snowplough / hockey stop).
##  - tip forward: tuck (less drag, wider turns).
##  - flick up: jump (on a kicker's lip it goes higher); in the air turn the controller to
##    spin, hold B to grab. Land with the skis along the way you fly, or crash.
##  - B on the ground: pole push (only helps when slow).
## Results go out as signals for the game's scoring and HUD.

signal gate_passed(index: int)
signal gate_missed(index: int)
signal trick_landed(points: int, names: PackedStringArray, sketchy: bool)
signal crashed(reason: String)
signal landed(impact: float)
signal net_hit(strength: float)
signal finished_run()

enum Mode { RIDE, AIR, CRASH }

const GRAV := 9.81
const DRAG_STAND := 0.0042     ## a = k v^2
const DRAG_TUCK := 0.0018
const MU := 0.045              ## snow friction
const CARVE_R := 11.0          ## tightest carved radius (full tilt)
const PIVOT := 1.5             ## rad/s turn at walking pace
const MAX_SPEED := 33.0
const MAX_ANGLE := 1.45        ## heading at most this far from the fall line
const POP_MIN := 2.6
const POP_MAX := 4.6
const SPIN_GAIN := 2.0
const CRASH_TIME := 1.8
const PUSH_V := 1.4
const PUSH_MAX := 7.0
const SILENT_DB := -59.0       ## pause inaudible loops; retain their playback position
const SPIN_POINTS := {360: 400, 540: 650, 720: 950, 900: 1300, 1080: 1700, 1260: 2200, 1440: 2800}
const GRABS := ["Mute", "Safety", "Tail", "Japan"]

var course: RSSkiCourse
var color := Color.WHITE
var rig: RSSkierRig
var player_layer := 1

var pos := Vector3.ZERO        ## on the snow under the bindings, world
var vel := Vector3.ZERO
var draw_pos := Vector3.ZERO   ## where the skier is drawn: pos, smoothed between sub-steps
var clock := RSFixedStep.new() ## sub-step clock (fixed 120 Hz, capped per frame)
var heading := 0.0             ## where the skis point, rad about +Y, 0 = -Z
var mode := Mode.RIDE
var spin := 0.0                ## in the air: turned from the takeoff heading
var tuck := 0.0
var skid := 0.0
var finished := false
var run_time := 0.0
var finish_time := 0.0
var air_t := 0.0
var next_gate := 0
var gates_hit := 0
var gates_missed := 0
var gate_streak := 0
var invulnerable := 0.0
var gain_db := 0.0
var top_speed := 0.0
var best_trick := 0

var _rng := RandomNumberGenerator.new()
var _popped := false
var _turn_rate := 0.0
var _lean := 0.0
var _grab_kind := 0
var _grab_t := 0.0
var _crash_t := 0.0
var _push_t := -1.0
var _plant_t := -1.0
var _plant_side := 1.0
var _last_steer_sign := 0.0
var _net_cd := 0.0
var _rig_yaw := 0.0
var _stop_side := 1.0
var _land_flash := 0.0
var _frac := 1.0                ## share of this frame's controller turn per sub-step

var _carve: AudioStreamPlayer
var _skid_snd: AudioStreamPlayer
var _wind: AudioStreamPlayer
var _spray: GPUParticles3D
var _puff: GPUParticles3D
var _shadow: MeshInstance3D
var _tag: Label3D


func _init(c: RSSkiCourse, col: Color, variant: int, layer: int) -> void:
	course = c
	color = col
	player_layer = layer
	rig = RSSkierRig.new(col, variant)
	_rng.seed = 2000 + layer


func _ready() -> void:
	add_child(rig)
	_carve = RSSfx.loop(self, "carve")
	_skid_snd = RSSfx.loop(self, "skid")
	_wind = RSSfx.loop(self, "wind")
	_make_fx()


func quiet() -> void:
	for a: AudioStreamPlayer in [_carve, _skid_snd, _wind]:
		_set_loop_db(a, -80.0)


func _set_loop_db(a: AudioStreamPlayer, db: float) -> void:
	a.volume_db = db
	a.stream_paused = db <= SILENT_DB


func active_loops() -> int:
	var count := 0
	for a: AudioStreamPlayer in [_carve, _skid_snd, _wind]:
		if a != null and not a.stream_paused:
			count += 1
	return count


func place(u: float, s: float) -> void:
	pos = course.world(u, s)
	draw_pos = pos
	clock.reset(pos)
	heading = course.heading_at(s)
	vel = Vector3.ZERO
	mode = Mode.RIDE
	spin = 0.0
	tuck = 0.0
	skid = 0.0
	finished = false
	run_time = 0.0
	finish_time = 0.0
	next_gate = 0
	gates_hit = 0
	gates_missed = 0
	gate_streak = 0
	invulnerable = 0.0
	top_speed = 0.0
	best_trick = 0
	_grab_kind = 0
	_push_t = -1.0
	_plant_t = -1.0
	_rig_yaw = 0.0
	rig.end_crash()
	_visuals(0.0, RSMotionControls.new())


func launch(v: float) -> void:
	## Out of the start gate: a push along the skis.
	vel = _dir(heading) * v
	RSSfx.play(self, "pole", -10.0 + gain_db)
	_push_t = 0.3


func s() -> float:
	return -pos.z


func current_speed() -> float:
	return vel.length()


func _dir(h: float) -> Vector3:
	return Vector3(-sin(h), 0.0, -cos(h))


# --------------------------------------------------------------------------- step ----

func step(dt: float, c: RSMotionControls, racing: bool) -> void:
	## Advance one frame. `racing` is false before the start (stand in the start gate).
	if racing:
		run_time += dt if not finished else 0.0
		_events(c)
		var n := clock.advance(dt)
		_frac = 1.0 / n if n > 0 else 1.0
		if n == 0 and mode == Mode.AIR:
			spin += c.yaw_delta * SPIN_GAIN   # this frame's turn, with no sub-step to carry it
		for i in n:
			var before := pos
			_sub(clock.h, c)
			if i == n - 1:
				clock.push(before, pos)
	draw_pos = clock.draw(pos)
	_visuals(dt, c)


func _events(c: RSMotionControls) -> void:
	if finished or mode == Mode.CRASH:
		return
	if c.ollie > 0.0 and mode == Mode.RIDE:
		_jump(c.ollie)
	elif c.ollie > 0.0 and mode == Mode.AIR and air_t < 0.15 and not _popped:
		# A late pop just after leaving a lip still counts.
		vel.y += lerpf(POP_MIN, POP_MAX, c.ollie) * 0.6
		_popped = true
	if c.push and mode == Mode.RIDE and _push_t < 0.0:
		_push_t = 0.0


func _sub(dt: float, c: RSMotionControls) -> void:
	invulnerable = maxf(invulnerable - dt, 0.0)
	_net_cd = maxf(_net_cd - dt, 0.0)
	match mode:
		Mode.RIDE:
			_ride(dt, c)
		Mode.AIR:
			_air(dt, c)
		Mode.CRASH:
			_crash_step(dt)
	_gates()
	top_speed = maxf(top_speed, current_speed())
	if not finished and s() >= course.length:
		finished = true
		finish_time = run_time
		_stop_side = 1.0 if _rng.randf() < 0.5 else -1.0
		finished_run.emit()


# ------------------------------------------------------------------------ ground ----

func _ride(dt: float, c: RSMotionControls) -> void:
	var n := course.normal(pos.x, pos.z)
	var steer := clampf(c.steer, -1.0, 1.0)
	var brake := clampf((c.pitch - 0.45) / 0.4, 0.0, 1.0)
	var want_tuck := clampf((-c.pitch - 0.25) / 0.35, 0.0, 1.0)
	if finished:
		brake = 1.0
		steer = 0.0
		want_tuck = 0.0
	tuck = move_toward(tuck, want_tuck * (1.0 - absf(steer) * 0.6), dt * 3.0)
	vel -= n * vel.dot(n)
	var spd := vel.length()
	# Turning: carve radius from the tilt, a pivot at low speed, less in a tuck.
	var edge := absf(steer)
	var rate := maxf(PIVOT * (1.0 - smoothstep(4.0, 10.0, spd)), spd / CARVE_R) * edge * lerpf(1.0, 0.65, tuck)
	_turn_rate = -signf(steer) * rate
	heading += _turn_rate * dt
	var fall := course.heading_at(s())
	heading = fall + clampf(wrapf(heading - fall, -PI, PI), -MAX_ANGLE, MAX_ANGLE)
	# Gravity along the slope.
	var g := Vector3(0, -GRAV, 0)
	vel += (g - n * g.dot(n)) * dt
	# Skis grip: sideways speed turns into speed along the skis (carving), or is scrubbed
	# off when they skid (full tilt at speed, braking, finishing).
	var f := _dir(heading)
	f = (f - n * f.dot(n)).normalized()
	var side := n.cross(f).normalized()
	skid = maxf(clampf((edge - 0.78) / 0.22, 0.0, 1.0) * smoothstep(7.0, 13.0, spd), brake)
	var vf := vel.dot(f)
	var vl := vel.dot(side)
	var grip := lerpf(11.0, 3.5, skid)
	var moved := vl * (1.0 - exp(-grip * dt))
	vl -= moved
	vf += absf(moved) * lerpf(0.97, 0.35, skid) * (1.0 if vf >= 0.0 else -1.0)
	if vf < 0.0 and spd < 2.0:
		vf *= exp(-6.0 * dt)       # don't slide backwards up the hill
	vel = f * vf + side * vl
	# Drag, snow friction, skid and brake.
	spd = vel.length()
	if spd > 0.01:
		var k := lerpf(DRAG_STAND, DRAG_TUCK, tuck)
		var decel := k * spd * spd + MU * GRAV * n.y + skid * 2.2 + brake * 5.5
		vel -= vel / spd * minf(decel * dt, spd)
	if spd > MAX_SPEED:
		vel *= MAX_SPEED / spd
	# Pole push: a double-pole stroke, helps only when slow.
	if _push_t >= 0.0:
		var before := _push_t
		_push_t += dt / 0.6
		if before < 0.45 and _push_t >= 0.45:
			RSSfx.play(self, "pole", -12.0 + gain_db, _rng.randf_range(0.9, 1.1))
			if vel.dot(f) < PUSH_MAX:
				vel += f * PUSH_V * (1.0 - clampf(vel.dot(f) / PUSH_MAX, 0.0, 1.0))
		if _push_t >= 1.0:
			_push_t = -1.0
	# Pole plant at each new turn.
	var sg := signf(steer) if absf(steer) > 0.3 else 0.0
	if sg != 0.0 and sg != _last_steer_sign and spd > 4.0 and spd < 22.0 and _plant_t < 0.0 and tuck < 0.5:
		_plant_t = 0.0
		_plant_side = sg
		RSSfx.play(self, "pole", -20.0 + gain_db, _rng.randf_range(1.0, 1.2))
	if sg != 0.0:
		_last_steer_sign = sg
	if _plant_t >= 0.0:
		_plant_t += dt / 0.45
		if _plant_t >= 1.0:
			_plant_t = -1.0

	var np := pos + vel * dt
	np = _nets(np, dt)
	var h := course.height(np.x, np.z)
	if np.y > h + 0.1 and vel.y > -1.0:
		# The snow dropped away under the skis: airborne (a lip, a knoll at speed).
		pos = np
		_take_off(false)
		return
	np.y = h
	pos = np


func _jump(strength: float) -> void:
	var n := course.normal(pos.x, pos.z)
	vel += n * lerpf(POP_MIN, POP_MAX, strength)
	pos.y += 0.02
	_take_off(true)
	RSSfx.play(self, "pole", -16.0 + gain_db, 0.7)


func _take_off(popped: bool) -> void:
	mode = Mode.AIR
	air_t = 0.0
	spin = 0.0
	_popped = popped
	_grab_kind = 0
	_grab_t = 0.0
	_push_t = -1.0
	_plant_t = -1.0


func _nets(np: Vector3, dt: float) -> Vector3:
	var ss := -np.z
	var u := course.lateral(np.x, np.z)
	var lim := course.bound(ss) - 0.35
	if absf(u) <= lim or ss < -20.0 or ss > course.length + 60.0:
		return np
	np.x = course.centre(ss) + signf(u) * lim
	var into := vel.x * signf(u)
	if into <= 0.0:
		return np        # already heading back in
	vel.x = -vel.x * 0.25
	vel *= 0.94
	heading = lerp_angle(heading, course.heading_at(ss), 0.25)
	if _net_cd <= 0.0:
		_net_cd = 0.5
		net_hit.emit(into)
		RSSfx.play(self, "thud", linear_to_db(clampf(into / 8.0, 0.15, 1.0)) - 10.0 + gain_db, 0.8)
		if into > 9.0 and invulnerable <= 0.0 and mode == Mode.RIDE:
			_crash(tr("撞到防护网了"))
	return np


# --------------------------------------------------------------------------- air ----

func _air(dt: float, c: RSMotionControls) -> void:
	air_t += dt
	vel.y -= GRAV * dt
	vel -= vel * 0.0012 * vel.length() * dt
	if not c.grab:
		var hv := Vector2(vel.x, vel.z).rotated(c.steer * 0.15 * dt)
		vel.x = hv.x
		vel.z = hv.y
	spin += c.yaw_delta * SPIN_GAIN * _frac
	if c.grab and air_t > 0.12 and not finished:
		if _grab_kind == 0:
			_grab_kind = 1
			if c.steer < -0.4:
				_grab_kind = 4
			elif c.pitch < -0.4:
				_grab_kind = 2
			elif c.pitch > 0.4:
				_grab_kind = 3
		_grab_t += dt
	elif _grab_kind != 0 and not c.grab:
		_grab_kind = -_grab_kind     # let go: remember it for the landing
	var np := pos + vel * dt
	np = _nets(np, dt)
	pos = np
	var h := course.height(pos.x, pos.z)
	if pos.y <= h and vel.y <= 0.5:
		pos.y = h
		_land()


func _land() -> void:
	var n := course.normal(pos.x, pos.z)
	var impact := maxf(-vel.dot(n), 0.0)
	var hv := Vector3(vel.x, 0.0, vel.z)
	var k := roundi(spin / PI)
	var off := absf(spin - k * PI)
	mode = Mode.RIDE
	var big := air_t > 0.35
	if big and (off > 0.75 or impact > 17.0) and invulnerable <= 0.0 and not finished:
		_crash(tr("落地没站稳") if off > 0.75 else tr("落地太重了"))
		return
	var sketchy := off > 0.4 or impact > 12.5
	if hv.length() > 0.5:
		heading = atan2(-hv.x, -hv.z)
	# Speed along the snow survives; the part into the slope is soaked up by the knees.
	vel -= n * vel.dot(n)
	vel *= 0.82 if sketchy else 0.96
	# Whole turns vanish; a half turn left over swings round on the snow (a revert).
	_rig_yaw = wrapf(_rig_yaw - (k - k % 2) * PI, -PI, PI)
	spin = 0.0
	if big:
		var names := PackedStringArray()
		var pts := 0
		var degrees := absi(k) * 180
		if degrees >= 360:
			names.append(str(degrees))
			pts += int(SPIN_POINTS.get(mini(degrees, 1440), 2800))
		elif absi(k) == 1:
			names.append("180")
			pts += 200
		if _grab_kind != 0:
			names.append(GRABS[absi(_grab_kind) - 1] + " Grab")
			pts += 150 + int(_grab_t * 350.0)
		if air_t > 0.9:
			names.append("Big Air")
			pts += int(220.0 * air_t)
		if pts == 0 and _popped and air_t > 0.8:
			names.append("Air")
			pts = int(60.0 * air_t)
		if sketchy:
			pts = int(pts * 0.5)
		if pts > 0 and not finished:
			best_trick = maxi(best_trick, pts)
			trick_landed.emit(pts, names, sketchy)
		rig.impact(clampf(impact * 0.25, 0.5, 2.6))
		RSSfx.play(self, "snowland", linear_to_db(clampf(impact / 8.0, 0.3, 1.0)) - 4.0 + gain_db, _rng.randf_range(0.9, 1.05))
		if impact > 7.0:
			RSSfx.play(self, "thud", -12.0 + gain_db, 0.8)
		_puff.restart()
		_puff.emitting = true
		landed.emit(impact)
	_grab_kind = 0
	_grab_t = 0.0
	_land_flash = 0.3 if big else 0.0


# ------------------------------------------------------------------------- crash ----

func _crash(reason: String) -> void:
	mode = Mode.CRASH
	_crash_t = 0.0
	_grab_kind = 0
	spin = 0.0
	rig.start_crash()
	RSSfx.play(self, "snowland", -2.0 + gain_db, 0.75)
	RSSfx.play(self, "thud", -6.0 + gain_db, 0.7)
	_puff.restart()
	_puff.emitting = true
	crashed.emit(reason)


func _crash_step(dt: float) -> void:
	_crash_t += dt
	# Tumble and slide to a stop down the snow.
	var n := course.normal(pos.x, pos.z)
	vel.y -= GRAV * dt
	vel *= exp(-2.6 * dt)
	var np := pos + vel * dt
	np = _nets(np, dt)
	var h := course.height(np.x, np.z)
	if np.y < h:
		np.y = h
		vel -= n * minf(vel.dot(n), 0.0)
	pos = np
	if _crash_t >= CRASH_TIME:
		# Back up, skis pointing down the run, inside the nets.
		var ss := s()
		var u := clampf(course.lateral(pos.x, pos.z), -course.half_width(ss) + 1.0, course.half_width(ss) - 1.0)
		pos = course.world(u, ss)
		heading = course.heading_at(ss)
		vel = _dir(heading) * 3.0
		mode = Mode.RIDE
		invulnerable = 1.2
		rig.end_crash()


# ------------------------------------------------------------------------- gates ----

func _gates() -> void:
	while next_gate < course.gates.size() and s() >= float(course.gates[next_gate]["s"]):
		var g: Dictionary = course.gates[next_gate]
		var through := absf(pos.x - float(g["x"])) < float(g["w"]) and mode != Mode.CRASH
		if through:
			gates_hit += 1
			gate_streak += 1
			gate_passed.emit(next_gate)
		else:
			gates_missed += 1
			gate_streak = 0
			gate_missed.emit(next_gate)
		next_gate += 1


# ----------------------------------------------------------------------- visuals ----

func _visuals(dt: float, c: RSMotionControls) -> void:
	var up := Vector3.UP
	var fwd := _dir(heading)
	if mode == Mode.RIDE or mode == Mode.CRASH:
		up = course.normal(pos.x, pos.z)
	else:
		var hv := Vector2(vel.x, vel.z)
		if hv.length() > 0.5:
			fwd = Vector3(hv.x, 0.0, hv.y).normalized()
	var z := -(fwd - up * fwd.dot(up)).normalized()
	var x := up.cross(z).normalized()
	rig.global_transform = Transform3D(Basis(x, up, z).orthonormalized(), draw_pos)
	var spd := current_speed()
	var target := spin
	if finished and mode == Mode.RIDE:
		target = _stop_side * 1.2 * smoothstep(0.5, 3.0, spd) if spd > 0.6 else _stop_side * 0.3
	_rig_yaw = lerp_angle(_rig_yaw, target, 1.0 - exp(-dt * (22.0 if mode == Mode.AIR else 5.0)))
	rig.yaw = _rig_yaw
	rig.grounded = 0.0 if mode == Mode.AIR else 1.0
	rig.grab = maxi(_grab_kind, 0)
	rig.feet_lift = (0.8 if _grab_kind > 0 else 0.3) if mode == Mode.AIR and air_t > 0.1 else 0.0
	rig.push = _push_t
	rig.plant = _plant_t
	rig.plant_side = _plant_side
	match mode:
		Mode.RIDE:
			var want := atan(spd * -_turn_rate / GRAV)
			if finished:
				want = -_stop_side * 0.6 * smoothstep(1.0, 6.0, spd)
			_lean = lerpf(_lean, clampf(want, -1.05, 1.05), 1.0 - exp(-dt * 9.0))
			rig.lean = _lean
			rig.edge = _lean * 0.35
			rig.tuck = tuck
			rig.crouch = 0.3 + 0.25 * clampf(absf(_lean), 0.0, 1.0) + 0.15 * skid + 0.6 * tuck
			rig.wedge = clampf((c.pitch - 0.45) / 0.4, 0.0, 1.0) * (1.0 - smoothstep(4.0, 9.0, spd)) if not finished else 0.0
			rig.arms = 0.1 + 0.3 * skid
		Mode.AIR:
			_lean = lerpf(_lean, 0.0, 1.0 - exp(-dt * 6.0))
			rig.lean = _lean
			rig.edge = 0.0
			rig.tuck = 0.0
			rig.crouch = 0.5 if _grab_kind <= 0 else 0.9
			rig.arms = 0.55 if _grab_kind <= 0 else 0.3
			rig.wedge = 0.0
		Mode.CRASH:
			rig.lean = 0.0
			rig.tuck = 0.0
			rig.wedge = 0.0
	rig.update(dt)
	_update_fx(dt)
	_update_audio(dt)


func _make_fx() -> void:
	# Snow spray off the ski tails, a puff on landing, a soft contact shadow, a name tag.
	var flake := QuadMesh.new()
	flake.size = Vector2(0.12, 0.12)
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fm.vertex_color_use_as_albedo = true
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.albedo_texture = _soft_dot()
	flake.material = fm

	_spray = GPUParticles3D.new()
	_spray.amount = 90
	_spray.lifetime = 0.6
	_spray.local_coords = false
	_spray.emitting = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 0.6, 1)
	pm.spread = 30.0
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 5.0
	pm.gravity = Vector3(0, -6, 0)
	pm.damping_min = 1.5
	pm.damping_max = 3.0
	pm.scale_min = 0.6
	pm.scale_max = 1.8
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.25, 0.02, 0.3)
	var ramp := Gradient.new()
	ramp.colors = PackedColorArray([Color(1, 1, 1, 0.9), Color(0.95, 0.97, 1.0, 0.0)])
	var rt := GradientTexture1D.new()
	rt.gradient = ramp
	pm.color_ramp = rt
	_spray.process_material = pm
	_spray.draw_pass_1 = flake
	_spray.top_level = true
	add_child(_spray)

	_puff = GPUParticles3D.new()
	_puff.amount = 40
	_puff.lifetime = 0.9
	_puff.one_shot = true
	_puff.explosiveness = 1.0
	_puff.emitting = false
	_puff.local_coords = false
	var dm := ParticleProcessMaterial.new()
	dm.direction = Vector3(0, 0.5, 0)
	dm.spread = 80.0
	dm.initial_velocity_min = 1.0
	dm.initial_velocity_max = 3.5
	dm.gravity = Vector3(0, -2.5, 0)
	dm.damping_min = 2.0
	dm.damping_max = 3.0
	dm.scale_min = 1.5
	dm.scale_max = 3.5
	var dramp := Gradient.new()
	dramp.colors = PackedColorArray([Color(1, 1, 1, 0.75), Color(1, 1, 1, 0.0)])
	var drt := GradientTexture1D.new()
	drt.gradient = dramp
	dm.color_ramp = drt
	_puff.process_material = dm
	_puff.draw_pass_1 = flake
	_puff.top_level = true
	add_child(_puff)

	_shadow = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(1.0, 1.6)
	q.orientation = PlaneMesh.FACE_Y
	_shadow.mesh = q
	var shm := StandardMaterial3D.new()
	shm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shm.albedo_color = Color(0.05, 0.08, 0.16, 0.4)
	shm.albedo_texture = _soft_dot()
	_shadow.material_override = shm
	_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shadow.top_level = true
	add_child(_shadow)

	_tag = Label3D.new()
	_tag.text = "P%d" % player_layer
	_tag.font = RSUi.font()
	_tag.font_size = 64
	_tag.pixel_size = 0.006
	_tag.outline_size = 16
	_tag.modulate = color.lightened(0.25)
	_tag.outline_modulate = Color(0.05, 0.05, 0.08)
	_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tag.no_depth_test = true
	_tag.top_level = true
	# Seen by everyone except this skier (each camera sees layer 1 + its own player layer).
	var mask := 0
	for p in range(1, 5):
		if p != player_layer:
			mask |= 1 << p
	_tag.layers = mask
	add_child(_tag)


func _soft_dot() -> GradientTexture2D:
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	t.width = 64
	t.height = 64
	return t


func _update_fx(_dt: float) -> void:
	var p := draw_pos
	var spd := current_speed()
	var spraying := mode == Mode.RIDE and spd > 4.0 and (skid > 0.15 or absf(_lean) > 0.55)
	_spray.emitting = spraying
	if spraying:
		# Off the outside of the turn, thrown back and up.
		var back := -_dir(heading)
		var out := Vector3(back.z, 0, -back.x) * signf(_lean)
		_spray.global_transform = Transform3D(Basis.looking_at(-(back * 0.6 + out * 0.8 + Vector3.UP * 0.2).normalized(), Vector3.UP), p + back * 0.5 + Vector3.UP * 0.05)
		_spray.amount_ratio = clampf(maxf(skid, (absf(_lean) - 0.5) * 2.0) * clampf(spd / 14.0, 0.3, 1.0), 0.15, 1.0)
	_puff.global_position = p + Vector3.UP * 0.1
	var ground := course.height(p.x, p.z)
	var height := maxf(p.y - ground, 0.0)
	_shadow.global_transform = Transform3D(Basis(Vector3.UP, heading), Vector3(p.x, ground + 0.03, p.z))
	_shadow.scale = Vector3.ONE * (1.0 + height * 0.12)
	(_shadow.material_override as StandardMaterial3D).albedo_color.a = clampf(0.4 - height * 0.06, 0.1, 0.4)
	_tag.global_position = p + Vector3.UP * 2.2


func _update_audio(dt: float) -> void:
	var k := 1.0 - exp(-dt * 10.0)
	var spd := current_speed()
	var on := mode == Mode.RIDE and spd > 0.5
	var carve_db := linear_to_db(clampf(spd / 16.0, 0.05, 1.0) * (0.55 + 0.45 * clampf(absf(_lean), 0.0, 1.0))) - 8.0 + gain_db + RSSfx.trim_db("carve") if on else -60.0
	_set_loop_db(_carve, lerpf(_carve.volume_db, carve_db, k))
	_carve.pitch_scale = clampf(0.75 + spd / 30.0, 0.7, 1.5)
	var skid_db := linear_to_db(clampf(skid * spd / 10.0, 0.01, 1.0)) - 6.0 + gain_db + RSSfx.trim_db("skid") if on and skid > 0.05 else -60.0
	_set_loop_db(_skid_snd, lerpf(_skid_snd.volume_db, skid_db, k))
	_skid_snd.pitch_scale = clampf(0.85 + spd / 40.0, 0.8, 1.4)
	var fast := clampf((spd - 8.0) / 16.0, 0.0, 1.0)
	if mode == Mode.AIR:
		fast = maxf(fast, clampf(air_t, 0.0, 1.0) * 0.8)
	_set_loop_db(_wind, lerpf(_wind.volume_db, linear_to_db(maxf(fast, 0.001)) - 12.0 + gain_db, k * 0.5))
	_wind.pitch_scale = clampf(0.8 + spd / 50.0, 0.8, 1.5)
