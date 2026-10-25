class_name RSSkater
extends Node3D
## One rider: arcade skate physics on an RSSkateCourse, the trick and combo rules, and the
## rider's sounds and effects. Input arrives once per frame as RSMotionControls (from the
## motion gestures or a bot); results go out as signals for the game's HUD and scoring.
##
## Tricks: ollie (flick up), kick/heelflip (flick sideways, on the ground it pops too),
## spins (turn the controller in the air), grabs (hold B in the air), manuals (hold the
## nose up on the ground, balance meter), grinds (land on a rail or ledge, balance meter
## with left/right tilt). Everything since leaving the ground is one combo: the sum of its
## tricks times their count, banked on a clean landing, lost on a bail. Landing straight
## into a manual keeps the combo going.

signal trick_added(entry: Dictionary)
signal combo_banked(points: int, names: PackedStringArray, sketchy: bool)
signal combo_lost(points: int)
signal bailed(reason: String)
signal landed(impact: float)
signal letter_collected(index: int)
signal finished_run()

enum Mode { RIDE, AIR, GRIND, MANUAL, BAIL }

const GRAV := 11.0
const STEP := 0.22             ## highest edge that can be rolled up
const ROLL_DRAG := 0.1
const AIR_DRAG := 0.0022
const PUSH_V := 1.5
const PUSH_MAX := 9.5
const AUTO_PUSH := 3.5
const TURN := 1.8              ## rad/s at full tilt
const MAX_HEADING := 1.2       ## rad either side of straight downhill
const POP_MIN := 2.9
const POP_MAX := 4.3
const SPIN_GAIN := 2.0         ## board spin per radian the controller is turned
const FLIP_TIME := 0.32
const BAIL_TIME := 1.7
const COYOTE := 0.15
const SNAP_RAIL := 0.45
const SNAP_LEDGE := 0.35
const GRIND_FRICTION := 0.7
const STALL_V := 1.6           ## slower than this and the grind ends
const SILENT_DB := -59.0       ## pause inaudible loops; retain their playback position

const SPIN_POINTS := {180: 200, 360: 450, 540: 800, 720: 1200, 900: 1600, 1080: 2200}


var course: RSSkateCourse
var color := Color.WHITE
var rig: RSSkaterRig
var player_layer := 1

var pos := Vector3.ZERO        ## wheel contact point, world
var vel := Vector3.ZERO        ## in the air
var draw_pos := Vector3.ZERO   ## where the rider is drawn: pos, smoothed between sub-steps
var clock := RSFixedStep.new() ## sub-step clock (fixed 120 Hz, capped per frame)
var speed := 0.0               ## on the ground, along heading
var heading := 0.0             ## direction of travel, rad about +Y, 0 = downhill (-Z)
var mode := Mode.RIDE
var spin := 0.0                ## board + body turned from the travel direction
var fakie := false
var needle := 0.0              ## balance meter, -1..1 (manual and grind)
var combo: Array[Dictionary] = []
var letters := [false, false, false, false, false]
var finished := false
var run_time := 0.0
var finish_time := 0.0
var air_t := 0.0
var invulnerable := 0.0
var gain_db := 0.0             ## the game turns riders down when there are several

var _rng := RandomNumberGenerator.new()
var _popped := false
var _frac := 1.0               ## share of this frame's controller turn per sub-step
var _takeoff := Vector2.ZERO   ## (x, s) where the board left the ground
var _flip_total := 0
var _flip_done := 0
var _flip_t := 0.0
var _flip_dir := 1
var _flip_entry: Dictionary = {}
var _grab_entry: Dictionary = {}
var _grab_kind := 0
var _rail: RSSkateCourse.Rail
var _rail_t := 0.0
var _rail_dir := 1.0
var _rail_v := 0.0
var _grind_t := 0.0
var _grind_entry: Dictionary = {}
var _last_rail: RSSkateCourse.Rail
var _since_rail := 10.0
var _manual_nose := false
var _manual_t := 0.0
var _manual_entry: Dictionary = {}
var _drift := 0.0
var _drift_v := 0.0
var _land_grace := 0.0
var _sketchy := false
var _push_t := -1.0
var _since_land := 10.0
var _bail_t := 0.0
var _pop_anim := 0.0
var _rig_yaw := 0.0
var _counts: Dictionary = {}
var _stair_bump := 0.0
var _wheel := 0.0
var _last_c := RSMotionControls.new()

var _roll: AudioStreamPlayer
var _grind_metal: AudioStreamPlayer
var _grind_ledge: AudioStreamPlayer
var _wind: AudioStreamPlayer
var _sparks: GPUParticles3D
var _dust: GPUParticles3D
var _shadow: MeshInstance3D
var _tag: Label3D


func _init(c: RSSkateCourse, col: Color, variant: int, layer: int) -> void:
	course = c
	color = col
	player_layer = layer
	rig = RSSkaterRig.new(col, variant)
	_rng.seed = 1000 + layer


func _ready() -> void:
	add_child(rig)
	_roll = RSSfx.loop(self, "roll")
	_grind_metal = RSSfx.loop(self, "grind_metal")
	_grind_ledge = RSSfx.loop(self, "grind_ledge")
	_wind = RSSfx.loop(self, "wind")
	_make_fx()


func quiet() -> void:
	## Silence the rolling / grinding / wind loops (they are only driven while stepping).
	for a: AudioStreamPlayer in [_roll, _grind_metal, _grind_ledge, _wind]:
		_set_loop_db(a, -80.0)


func _set_loop_db(a: AudioStreamPlayer, db: float) -> void:
	a.volume_db = db
	a.stream_paused = db <= SILENT_DB


func active_loops() -> int:
	var count := 0
	for a: AudioStreamPlayer in [_roll, _grind_metal, _grind_ledge, _wind]:
		if a != null and not a.stream_paused:
			count += 1
	return count


func place(x: float, s: float) -> void:
	pos = course.world(x, s)
	draw_pos = pos
	clock.reset(pos)
	vel = Vector3.ZERO
	speed = 0.0
	heading = 0.0
	mode = Mode.RIDE
	spin = 0.0
	fakie = false
	needle = 0.0
	combo.clear()
	_counts.clear()
	letters = [false, false, false, false, false]
	finished = false
	run_time = 0.0
	invulnerable = 0.0
	_push_t = -1.0
	_rig_yaw = 0.0
	_grab_kind = 0
	_flip_total = 0
	_flip_done = 0
	rig.end_bail()
	_visuals(0.0, RSMotionControls.new())


func s() -> float:
	return -pos.z


func current_speed() -> float:
	return Vector2(vel.x, vel.z).length() if mode == Mode.AIR else (_rail_v if mode == Mode.GRIND else speed)


func combo_base() -> int:
	var total := 0.0
	for e in combo:
		total += float(e["pts"])
	return int(total)


func combo_value() -> int:
	return combo_base() * combo.size()


func rail_name() -> String:
	return _rail.name if mode == Mode.GRIND and _rail != null else ""


func grind_time() -> float:
	return _grind_t if mode == Mode.GRIND else 0.0


func grinding_ledge() -> bool:
	return mode == Mode.GRIND and _rail != null and _rail.ledge


# --------------------------------------------------------------------------- step ----

func step(dt: float, c: RSMotionControls, racing: bool) -> void:
	## Advance the rider by one frame. `racing` is false during the countdown (hold still).
	_last_c = c
	if racing:
		run_time += dt
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
	# Pops, flips and pushes happen once per frame, before the physics substeps.
	if finished:
		return
	if c.ollie > 0.0 or c.flip != 0:
		var strength := c.ollie if c.ollie > 0.0 else 0.75
		match mode:
			Mode.RIDE, Mode.MANUAL:
				_ollie(strength, c.flip)
			Mode.GRIND:
				_grind_exit(true, strength, c.steer, c.flip)
			Mode.AIR:
				if air_t < COYOTE and not _popped:
					_ollie(strength, c.flip)
				elif c.flip != 0:
					_start_flip(c.flip)
	if c.push and mode == Mode.RIDE and _push_t < 0.0 and speed < PUSH_MAX:
		_push_t = 0.0


func _sub(dt: float, c: RSMotionControls) -> void:
	invulnerable = maxf(invulnerable - dt, 0.0)
	_since_rail += dt
	_since_land += dt
	match mode:
		Mode.RIDE, Mode.MANUAL:
			_ride(dt, c)
		Mode.AIR:
			_air(dt, c)
		Mode.GRIND:
			_grind(dt, c)
		Mode.BAIL:
			_bail_step(dt)
	if mode != Mode.BAIL:
		_check_letters()
		if not finished and s() >= RSSkateCourse.FINISH_S:
			finished = true
			finish_time = run_time
			if mode in [Mode.RIDE, Mode.MANUAL] and not combo.is_empty():
				_bank(_sketchy)
			finished_run.emit()


func _dir(h: float) -> Vector3:
	return Vector3(-sin(h), 0.0, -cos(h))


# ----------------------------------------------------------------------- ground ----

func _ride(dt: float, c: RSMotionControls) -> void:
	var ss := s()
	var on_stairs := course.stairs_at(ss)
	# Manual: hold the nose (or tail) up, keep the balance needle in the middle.
	if mode == Mode.RIDE and not finished and not on_stairs and speed > 1.5 and absf(c.pitch) > 0.42 and _push_t < 0.0:
		mode = Mode.MANUAL
		_manual_nose = c.pitch < 0.0
		_manual_t = 0.0
		_manual_entry = {}
		_drift = 0.0
		_drift_v = 0.0
		_land_grace = 0.0
	if mode == Mode.MANUAL:
		_manual_t += dt
		var p := -c.pitch if _manual_nose else c.pitch
		_balance(dt, (p - 0.62) * 1.8, _manual_t)
		if _manual_t > 0.3 and _manual_entry.is_empty():
			_manual_entry = _add("Nose Manual" if _manual_nose else "Manual", 50.0)
		if not _manual_entry.is_empty():
			_manual_entry["pts"] = float(_manual_entry["pts"]) + 180.0 * dt
		if needle > 1.0:
			_bail(tr("翘过头了"))
			return
		if needle < -1.0 or p < 0.18 or on_stairs:
			mode = Mode.RIDE
			needle = 0.0
			_land_grace = 0.25
	elif _land_grace > 0.0:
		_land_grace -= dt
		if _land_grace <= 0.0 and not combo.is_empty():
			_bank(_sketchy)

	var steer := c.steer
	if finished:
		steer = clampf(heading * 2.0 - pos.x * 0.08, -1.0, 1.0)
	heading -= steer * TURN * dt * (0.55 if mode == Mode.MANUAL else 1.0)
	heading = clampf(heading, -MAX_HEADING, MAX_HEADING)
	var dir := _dir(heading)
	var surf := course.surface(pos.x, ss, pos.y + STEP)
	var g_dir := surf.y * -dir.z
	var acc := -GRAV * g_dir / sqrt(1.0 + g_dir * g_dir) - ROLL_DRAG - AIR_DRAG * speed * speed
	if mode == Mode.MANUAL:
		acc -= 0.25
	if finished:
		acc -= 2.2
	speed = maxf(speed + acc * dt, 0.0 if finished else 0.6)

	# Pushing: B, or on its own when crawling along.
	if mode == Mode.RIDE and not finished and _push_t < 0.0 and speed < AUTO_PUSH and _since_land > 0.4:
		_push_t = 0.0
	if _push_t >= 0.0:
		var before := _push_t
		_push_t += dt / 0.55
		if before < 0.35 and _push_t >= 0.35:
			speed = minf(speed + PUSH_V, maxf(speed, PUSH_MAX))
			RSSfx.play(self, "push", -10.0 + gain_db, _rng.randf_range(0.9, 1.1))
		if _push_t >= 1.0 or mode != Mode.RIDE:
			_push_t = -1.0

	var nx := _blocked(pos.x + dir.x * speed * dt, ss - dir.z * speed * dt, dir)
	if is_inf(nx):
		return
	var ns := ss - dir.z * speed * dt
	var nsurf := course.surface(nx, ns, pos.y + STEP)
	var vy := speed * g_dir
	var predicted := pos.y + vy * dt
	if nsurf.x < predicted - 0.012:
		# The ground falls away faster than gravity can follow: airborne.
		pos = Vector3(nx, predicted, -ns)
		vel = dir * speed + Vector3(0.0, vy, 0.0)
		_take_off(false)
		return
	pos = Vector3(nx, nsurf.x, -ns)
	if on_stairs:
		_stair_bump += speed * dt
		if _stair_bump > RSSkateCourse.STAIR_TREAD:
			_stair_bump = 0.0
			rig.impact(1.2)
			RSSfx.play(self, "land", -14.0 + gain_db, _rng.randf_range(1.2, 1.4))
			landed.emit(1.5)


func _blocked(nx: float, ns: float, dir: Vector3) -> float:
	## Walls, obstacle sides, poles and rails in the way of a grounded rider. Returns the x
	## to move to (sliding along a side), or INF when the move is stopped.
	var lim := course.bound(ns) - 0.3
	if absf(nx) > lim:
		if absf(dir.x) * speed > 4.5 and invulnerable <= 0.0:
			_bail(tr("撞墙了"))
			return INF
		heading *= 0.3
		speed *= 0.995
		return signf(nx) * lim
	if course.top(nx, ns) > pos.y + STEP:
		if course.top(pos.x, ns) > pos.y + STEP:
			# Straight into the front of something: stop, and turn toward the nearer way round.
			if speed > 3.0 and invulnerable <= 0.0:
				_bail(tr("撞上障碍了"))
				return INF
			speed = 0.6
			var left := 0.0
			while left < 4.0 and course.top(pos.x - left, ns) > pos.y + STEP:
				left += 0.25
			var right := 0.0
			while right < 4.0 and course.top(pos.x + right, ns) > pos.y + STEP:
				right += 0.25
			heading = clampf(heading + (0.02 if left < right else -0.02), -MAX_HEADING, MAX_HEADING)
			return INF
		if absf(dir.x) * speed > 3.5 and invulnerable <= 0.0:
			_bail(tr("撞上障碍了"))
			return INF
		# Glancing off a side: scrape along it.
		heading *= 0.4
		speed *= 0.995
		return pos.x
	for p in course.posts:
		if absf(p.y - ns) < 1.2 and Vector2(nx - p.x, ns - p.y).length() < p.z + 0.25:
			if speed > 2.5 and invulnerable <= 0.0:
				_bail(tr("撞到柱子了"))
			else:
				heading += 0.6 * signf(pos.x - p.x)
			return INF
	var a := Vector2(pos.x, -pos.z)
	var b := Vector2(nx, ns)
	for r in course.rails:
		if r.ledge:
			continue
		var t := _cross(a, b, Vector2(r.a.x, -r.a.z), Vector2(r.b.x, -r.b.z))
		if t < 0.0:
			continue
		var above := r.point(t).y - pos.y
		if above < 0.15 or above > 1.4:
			continue
		var along := absf(Vector2(dir.x, -dir.z).dot(Vector2(r.dir.x, -r.dir.z).normalized()))
		if speed * sqrt(maxf(1.0 - along * along, 0.0)) > 2.0 and invulnerable <= 0.0:
			_bail(tr("被栏杆绊倒了"))
			return INF
		# Rolled into it at a shallow angle: shoved off to the side you came from and turned
		# away, or a rider running straight along the bar would be stopped there for good.
		var away := signf(pos.x - r.point(t).x)
		if away == 0.0:
			away = 1.0
		heading = clampf(heading * 0.5 - away * 0.12, -MAX_HEADING, MAX_HEADING)
		speed *= 0.9
		return pos.x + away * 0.04
	return nx


static func _cross(p1: Vector2, p2: Vector2, q1: Vector2, q2: Vector2) -> float:
	## Where segment p1-p2 crosses q1-q2, as a parameter along q (or -1).
	var r := p2 - p1
	var s := q2 - q1
	var den := r.cross(s)
	if absf(den) < 1e-9:
		return -1.0
	var t := (q1 - p1).cross(s) / den
	var u := (q1 - p1).cross(r) / den
	return u if t >= 0.0 and t <= 1.0 and u >= 0.0 and u <= 1.0 else -1.0


# -------------------------------------------------------------------------- air ----

func _ollie(strength: float, flip_dir: int) -> void:
	var dir := _dir(heading)
	var surf := course.surface(pos.x, s(), pos.y + 0.05)
	var g_dir := surf.y * -dir.z
	var pop := lerpf(POP_MIN, POP_MAX, clampf(strength, 0.0, 1.0))
	var base := vel if mode == Mode.AIR else dir * speed + Vector3(0.0, speed * g_dir, 0.0)
	if mode == Mode.AIR:
		base.y = maxf(base.y, 0.0)
	if mode == Mode.MANUAL:
		mode = Mode.RIDE
	vel = base + Vector3(0.0, pop, 0.0)
	if mode != Mode.AIR:
		_take_off(true)
	_popped = true
	_pop_anim = 1.0
	_push_t = -1.0
	RSSfx.play(self, "pop", -4.0 + gain_db, _rng.randf_range(0.92, 1.08))
	if flip_dir != 0:
		_start_flip(flip_dir)


func _take_off(popped: bool) -> void:
	mode = Mode.AIR
	air_t = 0.0
	_popped = popped
	_takeoff = Vector2(pos.x, s())
	_flip_total = 0
	_flip_done = 0
	_flip_t = 0.0
	_flip_entry = {}
	_grab_entry = {}
	_grab_kind = 0
	_land_grace = 0.0


func _start_flip(d: int) -> void:
	if _flip_total >= 3 or (_flip_total > 0 and _flip_done < _flip_total - 1):
		return
	if _flip_total == 0:
		_flip_dir = d
		_flip_t = 0.0
	_flip_total += 1
	RSSfx.play(self, "flip", -9.0 + gain_db, _rng.randf_range(0.95, 1.15))


func _air(dt: float, c: RSMotionControls) -> void:
	air_t += dt
	vel.y -= GRAV * dt
	var hv := Vector2(vel.x, vel.z).rotated(c.steer * 0.45 * dt)
	vel.x = hv.x
	vel.z = hv.y
	spin += c.yaw_delta * SPIN_GAIN * _frac
	# Flips: one board rotation every FLIP_TIME, renamed as they stack up.
	if _flip_done < _flip_total:
		_flip_t += dt
		if _flip_t >= FLIP_TIME:
			_flip_t = 0.0
			_flip_done += 1
			_flip_named()
	# Grabs: hold B; the tilt picks which.
	if c.grab and air_t > 0.08 and _flip_done >= _flip_total and not finished:
		if _grab_entry.is_empty():
			_grab_kind = 1
			if c.steer < -0.4:
				_grab_kind = 2
			elif c.pitch < -0.4:
				_grab_kind = 3
			elif c.pitch > 0.4:
				_grab_kind = 4
			_grab_entry = _add(["Indy", "Melon", "Nosegrab", "Tailgrab"][_grab_kind - 1], 150.0)
		_grab_entry["pts"] = float(_grab_entry["pts"]) + 250.0 * dt
	else:
		_grab_entry = {}
		_grab_kind = 0

	var nx := pos.x + vel.x * dt
	var ns := s() - vel.z * dt
	var ny := pos.y + vel.y * dt
	var lim := course.bound(ns) - 0.3
	if absf(nx) > lim:
		nx = signf(nx) * lim
		vel.x *= -0.2
	var top := course.top(nx, ns)
	if top > ny + 0.12:
		# Flew into the side of something.
		var front := course.top(pos.x, ns) > ny + 0.12
		var into := absf(vel.z) if front else absf(vel.x)
		if into > 3.0 and invulnerable <= 0.0:
			_bail(tr("撞上障碍了"))
			return
		if front:
			vel.z = 0.0
			ns = s()
		else:
			vel.x = 0.0
			nx = pos.x
	for p in course.posts:
		if absf(p.y - ns) < 1.2 and Vector2(nx - p.x, ns - p.y).length() < p.z + 0.25 and ny - course.H(ns) < 6.0:
			if invulnerable <= 0.0:
				_bail(tr("撞到柱子了"))
				return
	pos = Vector3(nx, ny, -ns)
	if _try_snap():
		return
	var surf := course.surface(pos.x, ns, pos.y + 0.12)
	if pos.y <= surf.x and vel.y <= 0.5:
		_land(surf)


func _flip_named() -> void:
	var base := "Kickflip" if _flip_dir < 0 else "Heelflip"
	var names := [base, "Double " + base, "Triple " + base]
	var pts := [300.0, 700.0, 1200.0]
	var k := clampi(_flip_done - 1, 0, 2)
	if _flip_entry.is_empty():
		_flip_entry = _add(names[k], pts[k])
	else:
		_flip_entry["name"] = names[k]
		_flip_entry["pts"] = pts[k]
		trick_added.emit(_flip_entry)


func _land(surf: Vector3) -> void:
	var n := Vector3(0.0, 1.0, surf.y).normalized()
	var impact := maxf(-vel.dot(n), 0.0)
	pos.y = surf.x
	var hv := Vector3(vel.x, 0.0, vel.z)
	var quiet := not _popped and air_t < 0.15 and combo.is_empty() and _flip_total == 0
	var k := roundi(spin / PI)
	var off := absf(spin - k * PI)
	var flipping := _flip_done < _flip_total
	var flip_progress := _flip_t / FLIP_TIME
	if off > 0.8 or (flipping and flip_progress < 0.7):
		_bail(tr("没站稳") if off > 0.8 else tr("板子没翻完"))
		return
	_sketchy = off > 0.42 or flipping
	if flipping:
		_flip_done = _flip_total
		_flip_named()
	var degrees := absi(k) * 180
	if degrees >= 180:
		_add(("BS " if spin > 0.0 else "FS ") + str(degrees), float(SPIN_POINTS.get(mini(degrees, 1080), 2200)))
	for g in course.gaps:
		if _takeoff.y >= g.take0 and _takeoff.y <= g.take1 and _takeoff.x >= g.x0 and _takeoff.x <= g.x1 and s() >= g.land:
			_add(g.name, float(g.points))
			RSSfx.play(self, "ding", -8.0 + gain_db)
	if air_t > 1.0:
		_add("Big Air", 200.0 * air_t)
	if _popped and combo.is_empty() and air_t > 0.45:
		_add("Ollie", 50.0)
	if absi(k) % 2 == 1:
		fakie = not fakie
	spin = 0.0
	_flip_total = 0
	_flip_done = 0
	_grab_entry = {}
	_grab_kind = 0
	mode = Mode.RIDE
	if hv.length() > 0.3:
		heading = clampf(atan2(-hv.x, -hv.z), -MAX_HEADING, MAX_HEADING)
	var dir := _dir(heading)
	speed = maxf(hv.dot(dir), 0.6) * (0.86 if _sketchy else 0.97)
	_since_land = 0.0
	_land_grace = 0.35
	if quiet:
		_land_grace = 0.05
		return
	rig.impact(clampf(impact * 0.55, 0.5, 3.2))
	RSSfx.play(self, "land", linear_to_db(clampf(impact / 6.0, 0.25, 1.0)) - 3.0 + gain_db, _rng.randf_range(0.9, 1.05))
	_dust.restart()
	_dust.emitting = true
	landed.emit(impact)


# ------------------------------------------------------------------------ grinds ----

func _try_snap() -> bool:
	var hv := Vector2(vel.x, vel.z)
	if hv.length() < 1.0 or finished:
		return false
	var ss := s()
	for r in course.rails:
		if r == _last_rail and _since_rail < 0.4:
			continue
		if ss < minf(-r.a.z, -r.b.z) - 0.5 or ss > maxf(-r.a.z, -r.b.z) + 0.5:
			continue
		if r.flat_dist(pos) > (SNAP_LEDGE if r.ledge else SNAP_RAIL):
			continue
		var t := r.flat_t(pos)
		var ry := r.point(t).y
		if pos.y < ry - 0.15 or pos.y > ry + 0.7:
			continue
		if pos.y > ry + 0.05 and vel.y > 0.5:
			continue
		var along := hv.normalized().dot(Vector2(r.dir.x, r.dir.z).normalized())
		if absf(along) < 0.7:
			continue
		var remain := (1.0 - t) * r.length if along > 0.0 else t * r.length
		if remain < 0.8:
			continue
		if _flip_done < _flip_total and _flip_t / FLIP_TIME < 0.7:
			_bail(tr("板子没翻完"))
			return true
		_start_grind(r, t, signf(along), hv.length() * absf(along))
		return true
	return false


func _start_grind(r: RSSkateCourse.Rail, t: float, d: float, v: float) -> void:
	if _flip_done < _flip_total:
		_flip_done = _flip_total
		_flip_named()
	mode = Mode.GRIND
	_rail = r
	_rail_t = t
	_rail_dir = d
	_rail_v = maxf(v, 2.0)
	_grind_t = 0.0
	_drift = _rng.randf_range(-0.15, 0.15)
	_drift_v = 0.0
	_grab_entry = {}
	_grab_kind = 0
	var travel := r.dir * d
	var rail_heading := atan2(-travel.x, -travel.z)
	var board_yaw := heading + spin + (PI if fakie else 0.0)
	var rel := wrapf(board_yaw - rail_heading, -PI, PI)
	fakie = absf(rel) > PI * 0.5
	if fakie:
		rel = wrapf(rel + PI, -PI, PI)
	heading = rail_heading
	var a := absf(rel)
	var grind_name: String
	if a < 0.45:
		grind_name = "5-0 Grind" if r.ledge else "50-50 Grind"
		spin = 0.0
	elif a < 1.05:
		grind_name = "Smith Grind" if r.ledge else "Crooked Grind"
		spin = 0.5 * signf(rel)
	else:
		grind_name = "Lipslide" if r.ledge else "Boardslide"
		spin = PI * 0.5 * signf(rel)
	if r.name == "Curb":
		grind_name = "Curb " + grind_name
	_grind_entry = _add(grind_name, 150.0 if a >= 1.05 else 100.0)
	pos = r.point(t)
	rig.impact(0.8)
	RSSfx.play(self, "land", -12.0 + gain_db, 1.4)


func _grind(dt: float, c: RSMotionControls) -> void:
	_grind_t += dt
	var r := _rail
	# Concrete drags more than steel; curbs are for a quick stab, not a free ride.
	var curb := r.name == "Curb"
	var friction := (2.6 if curb else 1.5) if r.ledge else GRIND_FRICTION
	_rail_v += (-GRAV * r.dir.y * _rail_dir - friction) * dt
	var moved := _rail_v * dt
	_rail_t += _rail_dir * moved / r.length
	# Points by the metre, so dragging along slowly doesn't farm them.
	var per_m := (14.0 if curb else 26.0) if r.ledge else 30.0
	_grind_entry["pts"] = float(_grind_entry["pts"]) + per_m * (1.2 if absf(spin) > 1.0 else 1.0) * moved
	_balance(dt, c.steer * 1.1, _grind_t)
	if absf(needle) > 1.0:
		_bail(tr("从栏杆上摔下来了"))
		return
	pos = r.point(_rail_t)
	if _rail_t <= 0.0 or _rail_t >= 1.0 or _rail_v < STALL_V:
		_grind_exit(false, 0.0, 0.0, 0)


func _grind_exit(popped: bool, strength: float, steer: float, flip_dir: int) -> void:
	var travel := _rail.dir * _rail_dir
	var side := travel.cross(Vector3.UP).normalized()
	vel = travel * _rail_v + Vector3(0.0, 0.8, 0.0)
	if popped:
		vel += Vector3(0.0, lerpf(POP_MIN, POP_MAX, strength) * 0.85, 0.0) + side * steer * 1.6
		RSSfx.play(self, "pop", -5.0 + gain_db, 1.05)
		_pop_anim = 1.0
	_last_rail = _rail
	_since_rail = 0.0
	needle = 0.0
	# Out of a slide the board swings back straight.
	spin = 0.0
	_take_off(popped)
	if flip_dir != 0:
		_start_flip(flip_dir)


func _balance(dt: float, input_term: float, t: float) -> void:
	## Balance meter: a wandering disturbance (harder the longer you hold it) that also
	## falls toward whichever side the needle already leans; your tilt is added on top.
	var noise := 2.4 + 0.35 * t
	var tip := 1.8 + 0.25 * t
	_drift_v += (_rng.randf_range(-1.0, 1.0) * noise + needle * tip - _drift * 0.8) * dt
	_drift_v *= exp(-dt * 1.2)
	_drift += _drift_v * dt
	needle = _drift + input_term


# ------------------------------------------------------------------- bail / combo ----

func _bail(reason: String) -> void:
	if mode == Mode.BAIL:
		return
	var lost := combo_value()
	combo.clear()
	_counts.clear()
	var hv := Vector3(vel.x, 0.0, vel.z)
	if mode == Mode.AIR and hv.length() > 0.5:
		heading = clampf(atan2(-hv.x, -hv.z), -MAX_HEADING, MAX_HEADING)
		speed = hv.length()
	elif mode == Mode.GRIND:
		speed = _rail_v
	mode = Mode.BAIL
	_bail_t = 0.0
	needle = 0.0
	_push_t = -1.0
	_flip_total = 0
	_flip_done = 0
	_grab_entry = {}
	_grab_kind = 0
	spin = 0.0
	rig.start_bail(speed)
	RSSfx.play(self, "bail", -2.0 + gain_db)
	if lost > 0:
		combo_lost.emit(lost)
	bailed.emit(reason)


func _bail_step(dt: float) -> void:
	_bail_t += dt
	speed = maxf(speed - 7.0 * dt, 0.0)
	var dir := _dir(heading)
	var nx := clampf(pos.x + dir.x * speed * dt, -course.bound(s()) + 0.5, course.bound(s()) - 0.5)
	var ns := s() - dir.z * speed * dt
	if course.top(nx, ns) > pos.y + 0.5:
		nx = pos.x
		ns = s()
		speed = 0.0
	var surf := course.surface(nx, ns, maxf(pos.y, course.H(ns)) + 0.3)
	pos = Vector3(nx, lerpf(pos.y, surf.x, minf(1.0, dt * 20.0)), -ns)
	if _bail_t >= BAIL_TIME:
		_respawn()


func _respawn() -> void:
	var ss := s() + 1.0
	var best := clampf(pos.x, -RSSkateCourse.HALF_W + 0.6, RSSkateCourse.HALF_W - 0.6)
	for k in 30:
		var x := clampf(pos.x + (k + 1) / 2 * 0.7 * (1.0 if k % 2 == 0 else -1.0), -RSSkateCourse.HALF_W + 0.6, RSSkateCourse.HALF_W - 0.6)
		var clear := true
		for probe: float in [0.0, 2.0, 4.0]:
			if course.top(x, ss + probe) > course.H(ss + probe) + 0.01:
				clear = false
		if clear:
			best = x
			break
	pos = course.world(best, ss)
	heading = 0.0
	speed = 4.0
	mode = Mode.RIDE
	spin = 0.0
	fakie = false
	_rig_yaw = 0.0
	invulnerable = 1.5
	_since_land = 0.0
	rig.end_bail()


func _add(trick: String, pts: float) -> Dictionary:
	## A trick joins the combo; repeats in one combo are worth less each time.
	var n: int = _counts.get(trick, 0)
	_counts[trick] = n + 1
	var e := {"name": trick, "pts": pts * maxf(0.25, 1.0 - 0.25 * n)}
	combo.append(e)
	trick_added.emit(e)
	return e


func _bank(sketchy: bool) -> void:
	if combo.is_empty():
		return
	var value := combo_value()
	if sketchy:
		value = int(value * 0.75)
	var names := PackedStringArray()
	for e in combo:
		names.append(str(e["name"]))
	combo.clear()
	_counts.clear()
	_sketchy = false
	RSSfx.play(self, "chime", -8.0 + gain_db, clampf(0.9 + names.size() * 0.06, 0.9, 1.5))
	combo_banked.emit(value, names, sketchy)


func _check_letters() -> void:
	var head := pos + Vector3.UP * 0.9
	for i in 5:
		if not letters[i] and head.distance_to(course.letters[i]) < 1.5:
			letters[i] = true
			RSSfx.play(self, "pickup", -6.0 + gain_db)
			letter_collected.emit(i)


# ----------------------------------------------------------------------- visuals ----

func _visuals(dt: float, c: RSMotionControls) -> void:
	var ss := s()
	var up := Vector3.UP
	var fwd := _dir(heading)
	match mode:
		Mode.RIDE, Mode.MANUAL, Mode.BAIL:
			var surf := course.surface(pos.x, ss, pos.y + 0.05)
			up = Vector3(0.0, 1.0, surf.y).normalized()
		Mode.AIR:
			var hv := Vector2(vel.x, vel.z)
			if hv.length() > 0.5:
				fwd = Vector3(hv.x, clampf(vel.y / hv.length(), -1.0, 1.0) * 0.25, hv.y).normalized()
		Mode.GRIND:
			fwd = _rail.dir * _rail_dir
	var z := -(fwd - up * fwd.dot(up)).normalized()
	var x := up.cross(z).normalized()
	var stair_shake := Vector3(0, 0.02 * sin(run_time * 60.0), 0) if mode == Mode.RIDE and course.stairs_at(ss) else Vector3.ZERO
	rig.global_transform = Transform3D(Basis(x, up, z).orthonormalized(), draw_pos + stair_shake)

	var target := spin + (PI if fakie else 0.0)
	_rig_yaw = lerp_angle(_rig_yaw, target, 1.0 - exp(-dt * 22.0))
	_pop_anim = maxf(_pop_anim - dt * 4.0, 0.0)
	rig.yaw = _rig_yaw
	rig.flip = (_flip_done + _flip_t / FLIP_TIME) * TAU * -_flip_dir if _flip_done < _flip_total else 0.0
	rig.feet_lift = 1.0 if _flip_done < _flip_total else 0.0
	rig.grab = _grab_kind
	rig.board_lift = 0.12 if _grab_kind != 0 else 0.0
	rig.push = _push_t
	rig.balance = needle if mode in [Mode.GRIND, Mode.MANUAL] else 0.0
	var steer := c.steer
	match mode:
		Mode.RIDE:
			rig.crouch = 0.28 + 0.1 * clampf(speed / 12.0, 0.0, 1.0)
			rig.lean = steer * 0.3 * clampf(speed / 6.0, 0.0, 1.0)
			rig.arms = 0.15 + absf(steer) * 0.35
			rig.board_pitch = 0.0
		Mode.MANUAL:
			rig.crouch = 0.4
			rig.lean = 0.0
			rig.arms = 1.0
			rig.board_pitch = (-0.24 if _manual_nose else 0.24) + needle * 0.07
		Mode.AIR:
			rig.crouch = 0.12 if air_t < 0.08 and _popped else (1.0 if _grab_kind != 0 else 0.62)
			rig.lean = 0.0
			rig.arms = 0.6
			rig.board_pitch = 0.42 * _pop_anim
		Mode.GRIND:
			rig.crouch = 0.5
			rig.lean = needle * 0.25
			rig.arms = 1.0
			rig.board_pitch = 0.0
	_wheel = current_speed() if mode in [Mode.RIDE, Mode.MANUAL] else _wheel * exp(-dt * 0.8)
	rig.wheel_speed = _wheel
	rig.update(dt)
	_update_fx(dt)
	_update_audio(dt)


func _make_fx() -> void:
	# Sparks off the rail, a dust puff on landing, a soft contact shadow, a name tag.
	_sparks = GPUParticles3D.new()
	_sparks.amount = 60
	_sparks.lifetime = 0.35
	_sparks.local_coords = false
	_sparks.emitting = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 0.7, 1)
	pm.spread = 40.0
	pm.initial_velocity_min = 1.5
	pm.initial_velocity_max = 4.5
	pm.gravity = Vector3(0, -9, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.2
	var ramp := Gradient.new()
	ramp.colors = PackedColorArray([Color(1.0, 0.95, 0.7, 1.0), Color(1.0, 0.55, 0.15, 1.0), Color(0.9, 0.2, 0.05, 0.0)])
	var rt := GradientTexture1D.new()
	rt.gradient = ramp
	pm.color_ramp = rt
	_sparks.process_material = pm
	var spark_mesh := QuadMesh.new()
	spark_mesh.size = Vector2(0.03, 0.03)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	sm.vertex_color_use_as_albedo = true
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	spark_mesh.material = sm
	_sparks.draw_pass_1 = spark_mesh
	_sparks.top_level = true
	add_child(_sparks)

	_dust = GPUParticles3D.new()
	_dust.amount = 16
	_dust.lifetime = 0.7
	_dust.one_shot = true
	_dust.explosiveness = 1.0
	_dust.emitting = false
	_dust.local_coords = false
	var dm := ParticleProcessMaterial.new()
	dm.direction = Vector3(0, 0.25, 0)
	dm.spread = 90.0
	dm.initial_velocity_min = 0.6
	dm.initial_velocity_max = 2.0
	dm.gravity = Vector3(0, 0.3, 0)
	dm.damping_min = 2.0
	dm.damping_max = 3.0
	dm.scale_min = 0.7
	dm.scale_max = 1.4
	var dramp := Gradient.new()
	dramp.colors = PackedColorArray([Color(0.85, 0.8, 0.72, 0.55), Color(0.85, 0.8, 0.72, 0.0)])
	var drt := GradientTexture1D.new()
	drt.gradient = dramp
	dm.color_ramp = drt
	_dust.process_material = dm
	var puff := QuadMesh.new()
	puff.size = Vector2(0.35, 0.35)
	var pmat := StandardMaterial3D.new()
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	pmat.vertex_color_use_as_albedo = true
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pmat.albedo_texture = _soft_dot()
	puff.material = pmat
	_dust.draw_pass_1 = puff
	_dust.top_level = true
	add_child(_dust)

	_shadow = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(1.0, 1.0)
	q.orientation = PlaneMesh.FACE_Y
	_shadow.mesh = q
	var shm := StandardMaterial3D.new()
	shm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shm.albedo_color = Color(0.02, 0.02, 0.05, 0.5)
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
	# Seen by everyone except this rider (each camera sees layer 1 + its own player layer).
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
	var grinding := mode == Mode.GRIND
	_sparks.emitting = grinding
	if grinding:
		var back := -(_rail.dir * _rail_dir)
		_sparks.global_transform = Transform3D(Basis.looking_at(-back, Vector3.UP), p + Vector3.UP * 0.02)
		(_sparks.process_material as ParticleProcessMaterial).initial_velocity_max = 2.0 if _rail.ledge else 4.5
		_sparks.amount_ratio = 0.35 if _rail.ledge else 1.0
	_dust.global_position = p + Vector3.UP * 0.05
	var ground := course.surface(p.x, -p.z, p.y + 0.05).x
	var height := maxf(p.y - ground, 0.0)
	_shadow.global_position = Vector3(p.x, ground + 0.025, p.z)
	_shadow.scale = Vector3.ONE * (1.1 + height * 0.15)
	(_shadow.material_override as StandardMaterial3D).albedo_color.a = clampf(0.5 - height * 0.08, 0.12, 0.5)
	_tag.global_position = p + Vector3.UP * 2.15


func _update_audio(dt: float) -> void:
	var k := 1.0 - exp(-dt * 12.0)
	var rolling := mode in [Mode.RIDE, Mode.MANUAL] and speed > 0.3
	var roll_db := linear_to_db(clampf(speed / 10.0, 0.05, 1.0)) - 9.0 + gain_db + RSSfx.trim_db("roll") if rolling else -60.0
	_set_loop_db(_roll, lerpf(_roll.volume_db, roll_db, k))
	_roll.pitch_scale = clampf(0.65 + speed / 16.0, 0.5, 1.6)
	var metal := mode == Mode.GRIND and not _rail.ledge
	var ledge := mode == Mode.GRIND and _rail.ledge
	_set_loop_db(_grind_metal, lerpf(_grind_metal.volume_db, (-7.0 + gain_db) if metal else -60.0, 0.5 if metal else k))
	_set_loop_db(_grind_ledge, lerpf(_grind_ledge.volume_db, (-6.0 + gain_db) if ledge else -60.0, 0.5 if ledge else k))
	if mode == Mode.GRIND:
		_grind_metal.pitch_scale = clampf(0.8 + _rail_v / 20.0, 0.7, 1.4)
		_grind_ledge.pitch_scale = clampf(0.8 + _rail_v / 20.0, 0.7, 1.4)
	var fast := clampf((current_speed() - 7.0) / 8.0, 0.0, 1.0)
	if mode == Mode.AIR:
		fast = maxf(fast, clampf(air_t, 0.0, 1.0) * 0.8)
	_set_loop_db(_wind, lerpf(_wind.volume_db, linear_to_db(maxf(fast, 0.001)) - 14.0 + gain_db, k * 0.5))
