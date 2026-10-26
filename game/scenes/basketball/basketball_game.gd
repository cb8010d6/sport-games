class_name RSBasketballGame
extends RSPartyGame
## 篮球 (basketball three-point contest, a motion game for 1-4): everyone shoots on their own
## rooftop half court at once (split screen). Five racks round the arc, five balls each, the
## last ball of every rack is the money ball. The player walks between racks and picks up the
## balls by themselves; the controller is the shooting hand: hold B to bring the ball up to
## the set point, then flick the wrist up like a jump shot and let go of B. The flick's speed
## is the shot's power (a meter after each shot shows where it landed), turning the controller
## left or right while setting pushes the shot that way.
##
## Points: 100 a make, 200 for a money ball, +30 for a swish (nothing but net), ×1.5 while on
## fire (three makes in a row), +200 for clearing a whole rack.
##
## Debug: `-- --demo=N` (bot shooters), `--map=N`, `--at=5,12,30` screenshot times with --shots.

const TIME_LIMIT := 70.0
const RACKS := 5
const BALLS := 5
const MAKE := 100
const MONEY := 200
const SWISH := 30
const RACK_BONUS := 200
const FIRE_AT := 3
const FIRE_MULT := 1.5
const P_IDEAL := 9.0             ## rad/s: wrist flick for a perfect shot
const P_FAKE := 2.5              ## below this it was no flick at all
const LAT_FULL := 0.3            ## rad of controller turn = a full "error" sideways
const ANGLE := 0.9               ## rad, launch angle (52°)
const JOG := 3.0
const NEXT_AFTER := 0.55         ## SHOOT -> next pickup
const RESOLVE_T := 3.5           ## a ball still not in after this long is a miss
const GOLD := Color(1.0, 0.84, 0.3)
const FIRE_COL := Color(1.0, 0.55, 0.15)
const INTRO := 4.0
const SLOW := 0.4
const CLIP_KEEP := 7.0
const PODIUM_AT := Vector3(8.5, 0.0, 14.3)
const PODIUM := [[0.0, 0.8], [-1.5, 0.55], [1.5, 0.36]]
const SFX := ["bounce", "rim", "board", "step", "swish", "buzzer", "applause", "city_amb", "chime", "pickup", "ding",
	"beep", "go", "fail", "thud"]

enum St { WALK, PICK, READY, SET, RELEASE, SHOOT, DONE }

class Shooter:
	var rig: RSBallerRig
	var court := 0
	var st := St.WALK
	var st_t := 0.0
	var rack := 0
	var ball_i := 0
	var held: RSBasketball
	var flying: Array[RSBasketball] = []
	var results: Array = []          ## [rack][ball]: 0 pending, 1 made, 2 swish, 3 missed
	var streak := 0
	var best_streak := 0
	var fire := false
	var made := 0
	var swishes := 0
	var money_made := 0
	var shots := 0
	var pos := Vector3.ZERO
	var face := Basis()
	var walk_from := Vector3.ZERO
	var walk_to := Vector3.ZERO
	var walk_d := 0.0
	var step_d := 0.0
	var set_yaw := 0.0
	var rel_t := 0.0                 ## controller clock at the release of B
	var e_raw := 0.0
	var lat_raw := 0.0
	var peak := 0.0
	var meter_t := -10.0
	var bot := false
	var bot_wait := 0.0
	var bot_sigma := 0.15
	var rng := RandomNumberGenerator.new()
	var flash := ""
	var flash_en := ""
	var flash_col := Color.WHITE
	var flash_t := -10.0
	var hint := ""
	var hint_t := 0.0
	var hints_seen: Dictionary = {}
	var oled_t := 0.0
	var cam_pos := Vector3.ZERO
	var cam_look := Vector3.ZERO
	# Replay of the best shot: frames of the rig and the ball on the game clock.
	var rec: Array = []
	var pend: Array = []
	var pend_pts := 0
	var pend_name := ""
	var pend_ball := 0
	var clip_ball := 0               ## instance id of the replayed ball
	var post := -1.0
	var clip: Array = []
	var clip_pts := 0
	var clip_name := ""
	var replay := RSReplay.new()
	var rp_ball: RSBasketball


var _court: RSBallCourt
var _env: Node3D
var _time_left := TIME_LIMIT
var _beep := 4
var _buzzed := false
var _ambience: AudioStreamPlayer
var _crowd: AudioStreamPlayer
var _rng := RandomNumberGenerator.new()
var _podium: RSPodium
var _podium_on := false
var _podium_at := 0.0
var _podium_order: Array = []
var _lobby_a := 0.0
var _gain := 0.0


func _game_name() -> String:
	return tr("篮球 · 三分大赛")


func _oled_name() -> String:
	return "3PT"


func _how_to_play() -> String:
	return (tr("三分线外五个球架，每架五个球，最后一个是双倍分的花球（Money Ball）。拿球、走位都是自动的，你只管投：\n") +
		tr("按住 B = 把球举到头顶　　像投篮那样往上甩手腕，同时松开 B = 出手\n") +
		tr("甩得越快球飞得越远：太轻会砸前沿，太重会砸篮板。出手后看右边的力度条调整。举球时手柄左右转 = 往左右偏。\n") +
		tr("进球 100，花球 200，空心 +30，连进三球 = 手感火热（×1.5），一架全进 +200。"))


func _countdown_time() -> float:
	return INTRO + COUNTDOWN_TIME


func _parse_arg(arg: String) -> void:
	if arg.begins_with("--at="):
		shot_times = []
		for v in arg.get_slice("=", 1).split(","):
			shot_times.append(float(v))


func _sh(p: Player) -> Shooter:
	return p.data


# --------------------------------------------------------------------------- world ----

func _setup_world() -> void:
	_rng.seed = 2323
	RSSfx.warm_up(SFX)
	RSBasketball.warm_up_fire(self)
	_ambience = RSSfx.loop(self, "city_amb")
	_crowd = RSSfx.loop(self, "applause")
	_podium = RSPodium.new()
	add_child(_podium)
	_build_podium()
	lobby_cam.far = 4000
	lobby_cam.fov = 58
	if shot_times == [0.5, 2.5, 9.0, 16.0, 25.0]:
		shot_times = [3.0, 9.0, 14.0, 22.0, 34.0, 48.0, 62.0]


func _maps() -> Array:
	return RSBallCourt.MAPS


func _map_info(i: int) -> String:
	# The English name under the Chinese one; in English it would only repeat the title.
	var en := "" if RSLang.english() else str(RSBallCourt.MAPS[i]["en"])
	return (en + (tr("　夜间灯光　湿地面") if RSBallCourt.MAPS[i]["lights"] else tr("　黄昏　城市天际线"))).strip_edges()


func _load_map(_i: int) -> void:
	if _court:
		_court.queue_free()
		_env.queue_free()
	if demo:
		print("map %d %s" % [map_index, RSBallCourt.MAPS[map_index]["en"]])
	_court = RSBallCourt.new(map_index)
	add_child(_court)
	_env = Node3D.new()
	add_child(_env)
	_court.setup_environment(_env)
	_lobby_a = 0.0


func _oled_lobby(p: Player) -> void:
	send_ui(p, {"clear": true, "title": "3PT " + str(RSBallCourt.MAPS[map_index]["en"]).get_slice(" ", 0), "main": "P%d" % p.c.player,
		"sub": "READY!" if p.ready else "PRESS A", "legends": ["READY", "MAP", "MENU", null]})


func _lobby_process(delta: float) -> void:
	# A slow orbit over the roof.
	_lobby_a += delta * 0.05
	var c := Vector3(0, 1.5, 4.0)
	lobby_cam.position = c + Vector3(sin(_lobby_a) * 30.0, 9.0 + sin(_lobby_a * 0.7) * 2.0, 12.0 + cos(_lobby_a) * 14.0)
	lobby_cam.look_at(c)
	_ambience.volume_db = lerpf(_ambience.volume_db, -14.0 + RSSfx.trim_db("city_amb"), 1.0 - exp(-delta))
	_crowd.volume_db = lerpf(_crowd.volume_db, -60.0, 1.0 - exp(-delta * 2.0))


# ----------------------------------------------------------------------- shooters ----

func _player_added(p: Player) -> void:
	var s := Shooter.new()
	p.data = s
	s.court = clampi(p.c.player - 1, 0, RSBallCourt.COURTS - 1)
	s.rig = RSBallerRig.new(color_of(p), avatar_of(p))
	add_child(s.rig)
	s.rig.visible = false
	s.rp_ball = RSBasketball.new(0, false)
	s.rp_ball.collision_layer = 0
	s.rp_ball.visible = false
	add_child(s.rp_ball)
	s.rp_ball.set_layers(1 << p.c.player)


func _player_removed(p: Player) -> void:
	var s := _sh(p)
	_clear_balls(s)
	s.rig.queue_free()
	s.rp_ball.queue_free()


func _clear_balls(s: Shooter) -> void:
	if s.held:
		s.held.queue_free()
		s.held = null
	for b in s.flying:
		b.queue_free()
	s.flying.clear()


func _player_button(p: Player, button: int, pressed: bool) -> void:
	if button != RSController.BTN_B or phase != Phase.PLAY:
		return
	var s := _sh(p)
	if pressed and s.st == St.READY:
		_to(s, St.SET)
		s.set_yaw = _heading(p.c.motion_orientation())
		s.rig.play(RSBallerRig.Move.SET)
	elif not pressed and s.st == St.SET:
		s.rel_t = p.c.sample_time
		_to(s, St.RELEASE)


func _player_cancel_hold(p: Player, button: int) -> void:
	# Paused or disconnected while holding the ball up: lower it, no shot.
	if button != RSController.BTN_B:
		return
	var s := _sh(p)
	if s.st == St.SET:
		_to(s, St.READY)
		s.rig.play(RSBallerRig.Move.HOLD)


func _round_started(list: Array) -> void:
	_podium.reset()
	_time_left = TIME_LIMIT
	_beep = 4
	_buzzed = false
	_gain = -3.0 * (list.size() - 1)
	for i in RSBallCourt.COURTS:
		for k in RACKS:
			_court.set_rack(i, k, BALLS, true)
		_court.set_clock(i, "%d" % int(TIME_LIMIT))
	for p: Player in list:
		var s := _sh(p)
		_clear_balls(s)
		s.rig.visible = true
		s.rig.set_layers(1)
		s.rack = 0
		s.ball_i = 0
		s.results = []
		for k in RACKS:
			s.results.append([0, 0, 0, 0, 0])
		s.streak = 0
		s.best_streak = 0
		s.fire = false
		s.made = 0
		s.swishes = 0
		s.money_made = 0
		s.shots = 0
		s.meter_t = -10.0
		s.flash_t = -10.0
		s.hint_t = 0.0
		s.rec.clear()
		s.pend.clear()
		s.post = -1.0
		s.clip = []
		s.replay.reset(s.clip)
		s.clip_pts = 0
		s.bot = p.fake
		s.rng.seed = 77 + p.c.player * 31 + _rng.randi_range(0, 9999)
		s.bot_sigma = s.rng.randf_range(0.12, 0.17) * bot_error()
		_court.tint(s.court, color_of(p))
		_place(s, RSBallCourt.spot(s.court, 0))
		_to(s, St.WALK)
		s.walk_d = 0.0
		s.walk_from = s.pos
		s.walk_to = s.pos
		s.rig.play(RSBallerRig.Move.IDLE)
		s.rig.update(0.0)
		send_ui(p, {"clear": true, "title": "3PT", "main": "0", "sub": "READY", "legends": ["", "SHOOT", "", null]})
		_camera(p, s, 0.0, true)


func _to_lobby() -> void:
	super._to_lobby()
	_podium.reset()
	_podium_on = false
	ui.results_on_right(false)
	for p: Player in players.values():
		var s := _sh(p)
		s.rig.visible = false
		s.rp_ball.visible = false
		_clear_balls(s)
	if _court:
		for i in RSBallCourt.COURTS:
			for k in RACKS:
				_court.set_rack(i, k, BALLS, true)
	_update_map_card()


func _countdown_process(delta: float) -> void:
	var b := ceili(_countdown_time() - phase_time)
	if b < _beep:
		_beep = b
		RSSfx.play(self, "beep", -8.0)
	for p: Player in players.values():
		var s := _sh(p)
		s.rig.update(delta)
		_camera(p, s, delta, false)
	_ambience.volume_db = lerpf(_ambience.volume_db, -16.0 + RSSfx.trim_db("city_amb"), 1.0 - exp(-delta))


func _play_started() -> void:
	RSSfx.play(self, "go", -6.0)
	for p: Player in players.values():
		_pick(_sh(p))


func _play_process(delta: float) -> void:
	_time_left = maxf(_time_left - delta, 0.0)
	var busy := false
	for p: Player in players.values():
		var s := _sh(p)
		_step_shooter(p, s, delta)
		s.rig.update(delta)
		if s.held:
			s.held.hold(Transform3D(s.rig.global_basis * Basis(Vector3.RIGHT, 0.4), s.rig.hand_ball()))
		_record(s, delta)
		_camera(p, s, delta, false)
		_hints(p, s, delta)
		_update_oled(p, s, delta)
		_court.set_clock(s.court, "%d" % ceili(_time_left), _time_left <= 10.0)
		for ball in s.flying:
			busy = busy or ball.live
		busy = busy or (s.st != St.DONE and _time_left > 0.0)
	if _time_left <= 0.0 and not _buzzed:
		_buzzed = true
		RSSfx.play(self, "buzzer", -4.0)
		for p: Player in players.values():
			var s := _sh(p)
			if s.held and s.st != St.SHOOT:
				s.held.queue_free()
				s.held = null
			if s.st != St.SHOOT:
				_to(s, St.DONE)
				s.rig.play(RSBallerRig.Move.IDLE)
	var near := 0.0
	for p: Player in players.values():
		near = maxf(near, float(_sh(p).streak >= FIRE_AT))
	_crowd.volume_db = lerpf(_crowd.volume_db, -26.0 + near * 6.0, 1.0 - exp(-delta * 2.0))
	if not busy:
		finish_round()


func _results_process(delta: float) -> void:
	if phase_time < _podium_at:
		for p: Player in players.values():
			_replay_step(p, delta)
		return
	if not _podium_on:
		_podium_start()
	_podium_step(delta)


func _result_detail(p: Player) -> String:
	var s := _sh(p)
	return tr("命中 %d/%d　空心 %d　花球 %d/%d　最长连中 %d") % [s.made, s.shots, s.swishes, s.money_made, RACKS, s.best_streak]


# ------------------------------------------------------------------ shooting flow ----

func _to(s: Shooter, st: St) -> void:
	s.st = st
	s.st_t = 0.0


func _place(s: Shooter, at: Vector3) -> void:
	s.pos = at
	s.face = RSBallCourt.facing(s.court, at)
	s.rig.global_transform = Transform3D(s.face, at)


func _pick(s: Shooter) -> void:
	_to(s, St.PICK)
	s.rig.pick_at = s.rig.global_transform.affine_inverse() * _court.rack_ball(s.court, s.rack, 0)
	s.rig.play(RSBallerRig.Move.PICKUP)


func _step_shooter(p: Player, s: Shooter, delta: float) -> void:
	s.st_t += delta
	match s.st:
		St.WALK:
			if s.walk_d <= 0.01:
				_pick(s)
				return
			var u := clampf(s.st_t * JOG / s.walk_d, 0.0, 1.0)
			var at := s.walk_from.lerp(s.walk_to, u)
			var dir := (s.walk_to - s.walk_from).normalized()
			var face := RSBallCourt.facing(s.court, at)
			# Run facing the way you're going, turn to the rim for the last bit.
			var run := Basis.looking_at(dir, Vector3.UP).slerp(face, smoothstep(0.75, 1.0, u))
			s.pos = at
			s.face = run
			s.rig.global_transform = Transform3D(run, at)
			s.rig.walk_speed = JOG * (1.0 - smoothstep(0.85, 1.0, u))
			s.step_d += JOG * delta
			if s.step_d > 0.75:
				s.step_d = 0.0
				RSSfx.play(self, "step", -20.0 + _gain, s.rng.randf_range(0.92, 1.08))
			if u >= 1.0:
				_place(s, s.walk_to)
				_pick(s)
		St.PICK:
			if s.held == null and s.rig.move_t >= RSBallerRig.PICK_GRAB:
				var money := s.ball_i == BALLS - 1
				s.held = RSBasketball.new(1 << p.c.player, money)
				add_child(s.held)
				s.held.touched.connect(_on_touch.bind(p, s.held))
				s.held.set_fire(s.fire)
				_court.set_rack(s.court, s.rack, BALLS - 1 - s.ball_i, true)
				RSSfx.play(self, "bounce", -24.0 + _gain, 1.3)
			if s.rig.move_t >= RSBallerRig.PICK_T:
				_to(s, St.READY)
				s.rig.play(RSBallerRig.Move.HOLD)
				s.bot_wait = s.rng.randf_range(0.15, 0.4)
		St.READY:
			if s.bot and s.st_t >= s.bot_wait:
				_to(s, St.SET)
				s.rig.play(RSBallerRig.Move.SET)
				s.bot_wait = s.rng.randf_range(0.3, 0.5)
		St.SET:
			if s.bot and s.st_t >= s.bot_wait:
				s.e_raw = clampf(s.rng.randfn(0.0, s.bot_sigma), -0.8, 0.8)
				s.lat_raw = clampf(s.rng.randfn(0.0, s.bot_sigma * 0.8), -0.8, 0.8)
				s.peak = P_IDEAL * (1.0 + s.e_raw)
				_shoot(p, s)
		St.RELEASE:
			# Wait a moment so the end of the flick is in the controller history.
			if s.st_t >= 0.05:
				_read_flick(p, s)
				if s.peak < P_FAKE:
					p.popup(tr("没有甩手腕 —— 松开 B 的同时往上甩"), Color(1.0, 0.75, 0.5))
					_to(s, St.READY)
					s.rig.play(RSBallerRig.Move.HOLD)
				else:
					_shoot(p, s)
		St.SHOOT:
			if s.held and s.rig.move_t >= RSBallerRig.RELEASE_T:
				_launch(p, s)
			if s.rig.move_t >= NEXT_AFTER and s.held == null:
				_next(s)


func _shoot(p: Player, s: Shooter) -> void:
	_to(s, St.SHOOT)
	s.rig.play(RSBallerRig.Move.SHOOT)
	s.meter_t = _clock
	haptic(p, "tap")


func _next(s: Shooter) -> void:
	if _time_left <= 0.0:
		_to(s, St.DONE)
		return
	s.ball_i += 1
	if s.ball_i < BALLS:
		_pick(s)
		return
	s.ball_i = 0
	s.rack += 1
	if s.rack >= RACKS:
		_to(s, St.DONE)
		s.rig.play(RSBallerRig.Move.IDLE)
		return
	_to(s, St.WALK)
	s.walk_from = s.pos
	s.walk_to = RSBallCourt.spot(s.court, s.rack)
	s.walk_d = s.walk_from.distance_to(s.walk_to)
	s.step_d = 0.0
	s.rig.play(RSBallerRig.Move.WALK)


func _heading(q: Quaternion) -> float:
	var f := q * Vector3.FORWARD
	if absf(f.y) > 0.85:
		f = q * (Vector3.DOWN if f.y > 0.0 else Vector3.UP)
	return atan2(-f.x, -f.z)


func _read_flick(p: Player, s: Shooter) -> void:
	## Peak rotation speed around the release of B, and how far the controller was turned
	## from where it pointed when B went down (read just before the flick).
	var c := p.c
	var peak := 0.0
	var turn_at := 0.0
	var have_turn := false
	for age in c.history_size():
		var i := c.history_index(age)
		var t := c.hist_time[i]
		if t > s.rel_t + 0.03:
			continue
		if t < s.rel_t - 0.4:
			break
		peak = maxf(peak, c.hist_gyro[i].length())
		if t <= s.rel_t - 0.25 and not have_turn:
			turn_at = _heading(c.motion_pose(c.hist_quat[i]))
			have_turn = true
	if not have_turn:
		turn_at = _heading(c.motion_orientation())
	s.peak = peak
	s.e_raw = (peak - P_IDEAL) / P_IDEAL
	s.lat_raw = clampf(-wrapf(turn_at - s.set_yaw, -PI, PI) / LAT_FULL, -1.5, 1.5)


static func assist(e: float) -> float:
	## Shot error from the gesture's error: a near-perfect flick is made, a fair one is rim
	## action, a poor one a clear miss.
	var a := absf(e)
	if a <= 0.15:
		return e * 0.04
	if a <= 0.3:
		return signf(e) * (0.006 + (a - 0.15) * 0.1)
	return signf(e) * (0.021 + (a - 0.3) * 0.35)


func _launch(p: Player, s: Shooter) -> void:
	var b := s.held
	s.held = null
	var from := s.rig.hand_ball()
	var rim := RSBallCourt.rim(s.court)
	var flat := Vector3(rim.x - from.x, 0.0, rim.z - from.z)
	var d := flat.length()
	var h := rim.y - from.y
	# Speed to drop through the middle of the ring at ANGLE, for the solver's own stepping
	# (semi-implicit Euler falls g*T*dt/2 short of the ideal parabola).
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var dt := 1.0 / Engine.physics_ticks_per_second
	var rise := d * tan(ANGLE) - h
	var T := (-g * dt * 0.5 + sqrt(pow(g * dt * 0.5, 2.0) + 2.0 * g * rise)) / g
	var v := d / (T * cos(ANGLE))
	var e := assist(s.e_raw) + s.rng.randf_range(-0.002, 0.002)
	var lat := assist(s.lat_raw) * 0.9 + s.rng.randf_range(-0.002, 0.002)
	var dir := flat.normalized().rotated(Vector3.UP, lat)
	var vel := (dir * cos(ANGLE) + Vector3.UP * sin(ANGLE)) * v * (1.0 + e)
	b.launch(vel, dir.cross(Vector3.UP) * 14.0)
	b.set_meta("rack", s.rack)
	b.set_meta("ball", s.ball_i)
	b.set_meta("fire", s.fire)
	b.set_meta("prev", from)
	b.set_meta("t0", _clock)
	s.flying.append(b)
	s.shots += 1
	_log(p, "shot r%d b%d peak %.1f e %.2f -> %.4f lat %.2f -> %.4f" % [s.rack, s.ball_i, s.peak, s.e_raw, e, s.lat_raw, lat])


func _physics_process(delta: float) -> void:
	if _court == null or phase != Phase.PLAY and phase != Phase.COUNTDOWN:
		return
	var near: Array = [[], [], [], []]
	for p: Player in players.values():
		var s := _sh(p)
		var rim := RSBallCourt.rim(s.court)
		var net := _court.nets[s.court]
		for b: RSBasketball in s.flying:
			var at := b.global_position
			near[s.court].append(at)
			if not b.live:
				continue
			var prev: Vector3 = b.get_meta("prev", at)
			b.set_meta("prev", at)
			var plane := rim.y - RSBasketball.R
			if prev.y >= plane and at.y < plane and Vector2(at.x - rim.x, at.z - rim.z).length() < RSBallCourt.RIM_R - 0.02:
				_made(p, s, b)
			elif b.touched_floor or b.flight_t > RESOLVE_T or at.y < -2.0:
				_missed(p, s, b)
			var k := net.drag(at)
			if k > 0.0:
				var v := b.linear_velocity
				var c := Vector3(rim.x - at.x, 0.0, rim.z - at.z)
				v.y *= exp(-5.0 * k * delta)
				v.x = v.x * exp(-7.0 * k * delta) + c.x * 6.0 * k * delta
				v.z = v.z * exp(-7.0 * k * delta) + c.z * 6.0 * k * delta
				b.linear_velocity = v
		if s.held:
			near[s.court].append(s.held.global_position)
		# Balls long resolved and out of the way go.
		for j in range(s.flying.size() - 1, -1, -1):
			var b := s.flying[j]
			if not b.live and _clock - float(b.get_meta("t0", 0.0)) > 7.0:
				b.queue_free()
				s.flying.remove_at(j)
	for i in RSBallCourt.COURTS:
		_court.nets[i].advance(delta, near[i])


# ------------------------------------------------------------------------ scoring ----

func _made(p: Player, s: Shooter, b: RSBasketball) -> void:
	b.live = false
	b.made = true
	var rk: int = b.get_meta("rack")
	var bi: int = b.get_meta("ball")
	var swish := not b.touched_rim and not b.touched_board
	var pts := MONEY if b.money else MAKE
	if swish:
		pts += SWISH
	var on_fire: bool = b.get_meta("fire")
	if on_fire:
		pts = roundi(pts * FIRE_MULT)
	s.results[rk][bi] = 2 if swish else 1
	s.made += 1
	s.swishes += int(swish)
	s.money_made += int(b.money)
	s.streak += 1
	s.best_streak = maxi(s.best_streak, s.streak)
	p.score += pts
	var label := (tr("花球空心！") if b.money else tr("空心！")) if swish else (tr("花球进了！") if b.money else tr("进了！"))
	_flash(s, label, GOLD if b.money or swish else Color(0.55, 1.0, 0.6), "SWISH!" if swish else ("MONEY!" if b.money else "IN!"))
	p.popup("+%d" % pts, GOLD if b.money else Color.WHITE)
	RSSfx.play(self, "swish", (-3.0 if swish else -9.0) + _gain, s.rng.randf_range(0.95, 1.05))
	if b.money:
		RSSfx.play(self, "chime", -10.0 + _gain)
	toast(p, "+%d" % pts, 600)
	haptic(p, "good" if b.money or swish else "hit")
	if s.streak == FIRE_AT:
		s.fire = true
		p.popup(tr("手感火热！ON FIRE ×1.5"), FIRE_COL)
		RSSfx.play(self, "pickup", -8.0 + _gain)
		if s.held:
			s.held.set_fire(true)
	_rack_done(p, s, rk)
	_log(p, "MADE %s +%d" % ["swish" if swish else "rim", pts])
	if pts > maxi(s.clip_pts, s.pend_pts if s.post >= 0.0 else 0) or pts == s.clip_pts and b.money:
		var t0 := float(b.get_meta("t0")) - 1.1
		s.pend = RSReplay.since(s.rec, t0)
		s.pend_pts = pts
		s.pend_name = label.trim_suffix("！").trim_suffix("!")   # no-i18n
		s.pend_ball = b.get_instance_id()
		s.post = 1.3


func _missed(p: Player, s: Shooter, b: RSBasketball) -> void:
	b.live = false
	var rk: int = b.get_meta("rack")
	var bi: int = b.get_meta("ball")
	s.results[rk][bi] = 3
	if s.fire:
		p.popup(tr("火熄了"), Color(0.75, 0.8, 0.9))
	s.fire = false
	s.streak = 0
	if s.held:
		s.held.set_fire(false)
	var text := tr("没进")
	if not b.touched_rim and not b.touched_board:
		text = tr("三不沾！")
	elif s.e_raw < -0.15:
		text = tr("短了")
	elif s.e_raw > 0.15:
		text = tr("长了")
	_flash(s, text, Color(1.0, 0.55, 0.5), "MISS")
	_rack_done(p, s, rk)
	_log(p, "missed (%s)" % text)


func _rack_done(p: Player, s: Shooter, rk: int) -> void:
	var all_in := true
	for r: int in s.results[rk]:
		if r == 0:
			return
		all_in = all_in and r != 3
	if all_in:
		p.score += RACK_BONUS
		p.popup(tr("整架全进！+%d") % RACK_BONUS, GOLD)
		RSSfx.play(self, "chime", -6.0 + _gain, 1.25)


func _flash(s: Shooter, text: String, col: Color, en: String) -> void:
	s.flash = text
	s.flash_en = en
	s.flash_col = col
	s.flash_t = _clock


func _on_touch(kind: String, speed: float, p: Player, _b: RSBasketball) -> void:
	var s := _sh(p)
	var loud := clampf(speed / 7.0, 0.0, 1.0)
	var db := -30.0 + 24.0 * sqrt(loud) + _gain
	var pitch := s.rng.randf_range(0.94, 1.06)
	match kind:
		"rim":
			RSSfx.play(self, "rim", db + 3.0, pitch)
			if speed > 2.0:
				haptic(p, "bump")
		"board":
			RSSfx.play(self, "board", db + 2.0, pitch)
		"pole":
			RSSfx.play(self, "rim", db - 2.0, pitch * 0.6)
		"fence":
			RSSfx.play(self, "thud", db - 6.0, pitch * 1.4)
		_:
			RSSfx.play(self, "bounce", db, pitch)


func _log(p: Player, text: String) -> void:
	if demo:
		print("[%6.1f] P%d  %s" % [_clock, p.c.player, text])


# ------------------------------------------------------------------------- camera ----

func _camera(p: Player, s: Shooter, dt: float, snap: bool) -> void:
	var rim := RSBallCourt.rim(s.court)
	var face := RSBallCourt.facing(s.court, s.pos)
	var back := face.z
	var right := face.x
	var want := s.pos + back * 3.8 + right * 0.85 + Vector3.UP * 2.2
	var look := rim * 0.7 + (s.pos + Vector3.UP * 1.4) * 0.3 + Vector3.DOWN * 0.3
	var follow: RSBasketball = null
	for b in s.flying:
		if b.live:
			follow = b
	if follow:
		var bp := follow.global_position
		look = look.lerp(bp, clampf(0.3 - maxf(bp.y - 4.5, 0.0) * 0.05, 0.1, 0.3))
	var k := 1.0 if snap else 1.0 - exp(-dt * 4.0)
	s.cam_pos = want if snap else s.cam_pos.lerp(want, k)
	s.cam_look = look if snap else s.cam_look.lerp(look, minf(k * 1.3, 1.0))
	p.cam.global_position = s.cam_pos
	p.cam.look_at(s.cam_look)
	p.cam.fov = 47.0
	if phase == Phase.COUNTDOWN and phase_time < INTRO:
		# Intro: from high over the city edge, swooping down behind the shooter.
		var p0 := Vector3(RSBallCourt.court_x(s.court) * 0.4, 26.0, 46.0)
		var p1 := s.pos + back * 9.0 + Vector3.UP * 5.0
		RSIntro.apply(p.cam, phase_time, INTRO, p0, p1, s.cam_pos,
			Vector3(RSBallCourt.court_x(s.court), 1.0, 2.0), s.cam_look, 50.0, 47.0, 0.4)


# ------------------------------------------------------------------- hints / OLED ----

func _hints(p: Player, s: Shooter, dt: float) -> void:
	s.hint_t -= dt
	if p.fake or s.hint_t > 0.0:
		return
	if s.st == St.READY and s.st_t > 0.6:
		_hint(s, "set", 3, tr("按住 B 把球举起来"), 3.0)
	elif s.st == St.SET and s.st_t > 0.4:
		_hint(s, "flick", 3, tr("像投篮那样往上甩手腕，同时松开 B！"), 3.0)
	elif s.st == St.WALK and s.rack == 1:
		_hint(s, "rack", 1, tr("每架最后一个是花球：进了 200 分"), 3.0)


func _hint(s: Shooter, key: String, times: int, text: String, dur: float) -> void:
	var n: int = s.hints_seen.get(key, 0)
	if n >= times:
		return
	s.hints_seen[key] = n + 1
	s.hint = text
	s.hint_t = dur


func _update_oled(p: Player, s: Shooter, dt: float) -> void:
	s.oled_t -= dt
	if s.oled_t > 0.0:
		return
	var main := str(p.score)
	var sub := "%d/%d" % [s.made, s.shots]
	if _clock - s.flash_t < 1.0:
		sub = s.flash_en
	elif s.fire:
		sub = "ON FIRE " + sub
	var title := "3PT R%d" % mini(s.rack + 1, RACKS)
	var key := "%s|%s|%s" % [title, main, sub]
	if key == p.oled_key:
		return
	p.oled_key = key
	s.oled_t = 0.15
	send_ui(p, {"title": title, "main": main, "sub": sub})


# ---------------------------------------------------------------------------- HUD ----

func _draw_hud(h: PlayerHud, p: Player, k: float) -> void:
	RSBasketballHud.draw_hud(self, h, p, k)

func _draw_overlay(o: Overlay, k: float) -> void:
	RSBasketballHud.draw_overlay(self, o, k)

# ------------------------------------------------------------------------ replays ----

func _record(s: Shooter, dt: float) -> void:
	# Every ball in play by its id, so a replay can follow just the one that went in.
	var balls := {}
	if s.held:
		balls[s.held.get_instance_id()] = [s.held.global_transform, s.held.money]
	for b in s.flying:
		if _clock - float(b.get_meta("t0", 0.0)) < 4.0:
			balls[b.get_instance_id()] = [b.global_transform, b.money]
	RSReplay.record(s.rec, {"t": _clock, "xf": s.rig.global_transform, "pose": s.rig.capture(), "balls": balls}, CLIP_KEEP)
	if s.post >= 0.0:
		s.pend.append(s.rec.back())
		s.post -= dt
		if s.post < 0.0:
			_keep_clip(s)


func _keep_clip(s: Shooter) -> void:
	s.clip = s.pend
	s.clip_pts = s.pend_pts
	s.clip_name = s.pend_name
	s.clip_ball = s.pend_ball
	s.pend = []
	s.pend_pts = 0
	s.post = -1.0


func finish_round() -> void:
	if _result_committed:
		return  # a second call must not reset the replay/podium state below (#57)
	var longest := 0.0
	for p: Player in players.values():
		var s := _sh(p)
		if s.post >= 0.0:
			_keep_clip(s)
		longest = maxf(longest, RSReplay.duration(s.clip) / SLOW)
		s.replay.reset(s.clip)
		_clear_balls(s)
		if s.clip.size() > 1:
			s.rig.set_layers(1 << p.c.player)
	_podium_at = RSReplay.lead_out(longest, 9.0)
	results_delay = _podium_at + 1.6
	_podium_on = false
	super.finish_round()


func _replay_step(p: Player, delta: float) -> void:
	var s := _sh(p)
	if not s.replay.sample(phase_time, SLOW):
		s.rig.update(delta)
		_camera(p, s, delta, false)
		return
	var fa := s.replay.a
	var fb := s.replay.b
	var u := s.replay.weight
	s.rig.global_transform = (fa["xf"] as Transform3D).interpolate_with(fb["xf"], u)
	s.rig.show_pose(fa["pose"])
	var ball_at := Vector3.ZERO
	var has: bool = (fa["balls"] as Dictionary).has(s.clip_ball)
	if has:
		var ba: Array = fa["balls"][s.clip_ball]
		var bx: Transform3D = ba[0]
		if (fb["balls"] as Dictionary).has(s.clip_ball):
			bx = bx.interpolate_with(fb["balls"][s.clip_ball][0], u)
		ball_at = bx.origin
		s.rp_ball.visible = true
		s.rp_ball.set_money(ba[1])
		s.rp_ball.global_transform = bx
	else:
		s.rp_ball.visible = false
	_court.nets[s.court].advance(delta * SLOW, [ball_at] if has else [])
	# Tracking from the side of the shot, a few metres off the ball: the release, the arc,
	# then the rim and the net filling the frame as the ball drops in.
	var rim := RSBallCourt.rim(s.court)
	var shooter := (s.clip[0]["xf"] as Transform3D).origin
	var line := Vector3(rim.x - shooter.x, 0, rim.z - shooter.z).normalized()
	var side := line.cross(Vector3.UP)
	if side.x * (shooter.x - RSBallCourt.court_x(s.court)) > 0.0:
		side = -side
	var target := s.rig.global_position + Vector3.UP * 1.6
	if has:
		target = ball_at
	var near_rim := clampf(1.0 - Vector2(target.x - rim.x, target.z - rim.z).length() / 4.0, 0.0, 1.0)
	var want := target + side * lerpf(3.6, 2.6, near_rim) - line * lerpf(1.4, 0.6, near_rim) + Vector3.UP * lerpf(0.2, -0.3, near_rim)
	want.y = maxf(want.y, 1.3)
	var look := target.lerp(rim + Vector3.DOWN * 0.2, 0.2 + 0.4 * near_rim)
	var k := 1.0 - exp(-delta * 2.5)
	if phase_time < 0.05:
		s.cam_pos = want
		s.cam_look = look
	s.cam_pos = s.cam_pos.lerp(want, k)
	s.cam_look = s.cam_look.lerp(look, minf(k * 2.0, 1.0))
	p.cam.global_position = s.cam_pos
	p.cam.look_at(s.cam_look)
	p.cam.fov = lerpf(p.cam.fov, 55.0, k)


func _draw_replay(h: PlayerHud, p: Player, k: float) -> void:
	RSBasketballHud.draw_replay(self, h, p, k)

# ------------------------------------------------------------------------- podium ----

func _build_podium() -> void:
	_podium.position = PODIUM_AT
	_podium.configure(PODIUM, Vector2(1.4, 1.6), Vector3(2.7, 0, 0.7), 1.0, font, 0.0)


func _podium_spot(i: int) -> Vector3:
	var at := _podium.spot(i)
	return at


func _podium_start() -> void:
	_podium_on = true
	for p: Player in players.values():
		_sh(p).rp_ball.visible = false
	views.visible = false
	lobby_cam.current = true
	lobby_cam.fov = 42.0
	ui.results_on_right(true)
	_podium_order = ranked_players()
	var scores := PackedInt64Array()
	for p: Player in _podium_order:
		scores.append(p.score)
	_podium.present(scores)
	for i in _podium_order.size():
		var rig := _sh(_podium_order[i]).rig
		rig.set_layers(1)
		rig.global_transform = Transform3D(Basis(Vector3.UP, PI), _podium_spot(i))
		rig.play(RSBallerRig.Move.CHEER if _podium.rank(i) == 1 else (RSBallerRig.Move.CELEBRATE if _podium.rank(i) <= 3 else RSBallerRig.Move.SAD))
	RSSfx.play(self, "chime", -4.0)


func _podium_step(delta: float) -> void:
	# Framing four players retreats beyond the roof edge; film over the glass handrail.
	_podium.apply_camera(lobby_cam, phase_time - _podium_at, -2.6, 0.12, 6.2, -0.15, 3.5, 1.4, 1.25)
	_podium.fit_left(lobby_cam)
	for p: Player in players.values():
		_sh(p).rig.update(delta)
	_crowd.volume_db = lerpf(_crowd.volume_db, -12.0, 1.0 - exp(-delta * 1.5))


func _draw_podium_tags(o: Overlay, k: float) -> void:
	for i in _podium_order.size():
		var p: Player = _podium_order[i]
		var head := _podium_spot(i) + Vector3.UP * 2.15
		if lobby_cam.is_position_behind(head):
			continue
		draw_pill(o, "P%d" % p.c.player, lobby_cam.unproject_position(head), 20 * k, color_of(p))
