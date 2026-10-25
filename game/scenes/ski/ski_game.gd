extends RSPartyGame
## 滑雪 (skiing, a motion game for 1-4): everyone races the same run at once (split screen),
## through the gates and over the kickers to the finish arena. Pick the map in the lobby (B
## or ←/→): a sunny groomer, a pine forest at dusk, a floodlit night run or a glacier in a
## storm (RSSkiMaps). The controller is the skis: tilt to turn (gentle = carve, hard = skid),
## tip forward to tuck, back to brake, flick up to jump, turn it in the air to spin, hold B to
## grab (B on the snow: pole push). Points for gates, tricks and the finishing order.
##
## Debug: `-- --demo=N` (bot skiers), `--map=N`, `--at=5,12,30` screenshot times with --shots.

const TIME_LIMIT := 150.0
const AFTER_FIRST := 25.0      ## once someone finishes, the rest have this long
const PLACE_BONUS := [1500, 1000, 600, 300]
const GATE_POINTS := 100
const GATE_MISS := 50
const GOLD := Color(1.0, 0.84, 0.3)
const INTRO := 4.2             ## camera flyover before the 3-2-1
const SLOW := 0.45             ## replay speed
const CLIP_MAX := 4.0
const PRE_ROLL := 1.0
const POST_ROLL := 1.0
const PODIUM_AFTER := 32.0     ## podium this far past the finish line
const PODIUM := [[0.0, 0.8], [-1.5, 0.55], [1.5, 0.36]]   ## [x, height] for 1st, 2nd, 3rd
const SNOW_LAYER := 10         ## the lobby/podium camera's own snowfall
const SFX := ["carve", "skid", "wind", "wind_amb", "applause", "snowland", "pole", "thud", "chime", "pickup",
	"ding", "beep", "go", "fail"]

class Racer:
	var sk: RSSkier
	var gest := RSMotionGestures.new()
	var bot: RSSkiBot
	var ctl := RSMotionControls.new()
	var push_ev := false
	var cam_pos := Vector3.ZERO
	var cam_off := Vector3.ZERO
	var cam_look := Vector3.ZERO
	var cam_fwd := Vector3.FORWARD
	var shake := 0.0
	var place := 0
	var tricks := 0
	var hint := ""
	var hint_t := 0.0
	var hints_seen: Dictionary = {}
	var banked_t := -10.0
	var banked_pts := 0
	var banked_names := ""
	var banked_sketchy := false
	var gate_t := -10.0
	var gate_ok := true
	var oled_t := 0.0
	var orbit := 0.0
	var snow: GPUParticles3D
	# Replay of the best jump (or the finish): frames of the rig on the game clock.
	var rec: Array = []
	var air_from := 0.0
	var pend: Array = []
	var pend_pts := 0
	var pend_names := ""
	var post := -1.0
	var clip: Array = []
	var clip_pts := 0
	var clip_names := ""
	var replay := RSReplay.new()
	var rp_side := Vector3.RIGHT


var _course: RSSkiCourse
var _env: Node3D
var _time_left := TIME_LIMIT
var _finishers := 0
var _all_done_t := -1.0
var _lobby_s := 0.0
var _beep := 4
var _crowd: AudioStreamPlayer
var _ambience: AudioStreamPlayer
var _rng := RandomNumberGenerator.new()
var _podium: RSPodium
var _podium_on := false
var _podium_at := 0.0
var _podium_order: Array = []
var _lobby_snow: GPUParticles3D
var _board_lines: PackedStringArray = []


func _game_name() -> String:
	return tr("滑雪")


func _oled_name() -> String:
	return "SKI"


func _how_to_play() -> String:
	return (tr("从山顶滑到终点，穿过旗门、飞跳台。手柄就是滑雪板：\n") +
		tr("左右倾斜 = 转弯（轻 = 刻滑不减速，重 = 搓雪急转）　往前压 = 团身加速　往后仰 = 刹车\n") +
		tr("快速往上一抬 = 起跳；空中水平转动手柄 = 转体，按住 B = 抓板　地上按 B = 撑杖加速\n") +
		tr("每过一道旗门 +100，漏门 -50；落地要对准方向，不然会摔。先到终点有名次奖励。\n") +
		tr("按 A 准备时的拿法就是“平”，长按 D 1 秒可以重新设定。"))


func _countdown_time() -> float:
	return INTRO + COUNTDOWN_TIME


func _parse_arg(arg: String) -> void:
	if arg.begins_with("--at="):
		shot_times = []
		for v in arg.get_slice("=", 1).split(","):
			shot_times.append(float(v))


func _racer(p: Player) -> Racer:
	return p.data


# --------------------------------------------------------------------------- world ----

func _setup_world() -> void:
	_rng.seed = 5151
	RSSfx.warm_up(SFX)
	_crowd = RSSfx.loop(self, "applause")
	_ambience = RSSfx.loop(self, "wind_amb")
	_podium = RSPodium.new()
	add_child(_podium)
	_build_podium()
	_lobby_snow = _make_snow(1 << SNOW_LAYER)
	lobby_cam.cull_mask = 1 | (1 << SNOW_LAYER)
	lobby_cam.far = 5000
	lobby_cam.fov = 62
	if shot_times == [0.5, 2.5, 9.0, 16.0, 25.0]:
		shot_times = [5.0, 9.0, 16.0, 26.0, 38.0, 50.0, 62.0]


func _maps() -> Array:
	return RSSkiMaps.MAPS


func _map_info(i: int) -> String:
	var m := RSSkiMaps.get_map(i)
	# The English name under the Chinese one; in English it would only repeat the title.
	var en := "" if RSLang.english() else str(m["en"])
	return (tr("%s　难度 %s　%d 米　%d 个跳台") % [en, RSSkiMaps.stars(i), roundi(float(m["length"])), (m["kickers"] as Array).size()]).strip_edges()


func _load_map(i: int) -> void:
	if _course:
		_course.queue_free()
		_env.queue_free()
	if demo:
		print("map %d %s" % [map_index, RSSkiMaps.get_map(map_index)["en"]])
	_course = RSSkiCourse.new(map_index)
	add_child(_course)
	_env = Node3D.new()
	add_child(_env)
	_course.setup_environment(_env)
	for p: Player in players.values():
		_racer(p).sk.course = _course
	var podium_s := _course.length + PODIUM_AFTER
	_podium.position = _course.world(0.0, podium_s)
	_podium.rotation.y = _course.heading_at(podium_s)
	var amount := float(_course.map["snowfall"])
	for sn: GPUParticles3D in _snow_systems():
		sn.emitting = amount > 0.0
		sn.amount_ratio = maxf(amount, 0.01)
	_board_lines = []
	_course.set_board(str(_course.map["en"]))
	_lobby_s = 0.0


func _snow_systems() -> Array[GPUParticles3D]:
	var out: Array[GPUParticles3D] = [_lobby_snow]
	for p: Player in players.values():
		out.append(_racer(p).snow)
	return out


func _make_snow(layers: int) -> GPUParticles3D:
	## Falling snow in a box that follows a camera (only that camera sees it).
	var flake := QuadMesh.new()
	flake.size = Vector2(0.035, 0.035)
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.albedo_color = Color(1, 1, 1, 0.85)
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var dot := GradientTexture2D.new()
	dot.gradient = g
	dot.fill = GradientTexture2D.FILL_RADIAL
	dot.fill_from = Vector2(0.5, 0.5)
	dot.fill_to = Vector2(0.5, 0.0)
	dot.width = 32
	dot.height = 32
	fm.albedo_texture = dot
	flake.material = fm
	var ps := GPUParticles3D.new()
	ps.amount = 2400
	ps.lifetime = 2.6
	ps.preprocess = 2.6
	ps.local_coords = false
	ps.visibility_aabb = AABB(Vector3(-30, -30, -30), Vector3(60, 60, 60))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(16, 8, 16)
	pm.direction = Vector3(0.25, -1, 0.1)
	pm.spread = 12.0
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 4.0
	pm.gravity = Vector3(0.6, -1.2, 0.0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.5
	pm.turbulence_noise_scale = 4.0
	pm.scale_min = 0.6
	pm.scale_max = 1.6
	ps.process_material = pm
	ps.draw_pass_1 = flake
	ps.layers = layers
	ps.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ps.top_level = true
	ps.emitting = false
	add_child(ps)
	return ps


func _oled_lobby(p: Player) -> void:
	send_ui(p, {"clear": true, "title": "SKI " + str(RSSkiMaps.get_map(map_index)["en"]).get_slice(" ", 0), "main": "P%d" % p.c.player,
		"sub": "READY!" if p.ready else "PRESS A", "legends": ["READY", "MAP", "MENU", null]})


func _lobby_process(delta: float) -> void:
	# A slow flight down the run.
	_lobby_s = fmod(_lobby_s + delta * 14.0, _course.length + 40.0)
	var s := _lobby_s - 20.0
	var at := _course.world(sin(s * 0.012) * 10.0, s, 11.0)
	at.y = maxf(at.y, _course.ground(at.x, at.z) + 6.0)
	lobby_cam.position = at
	lobby_cam.look_at(_course.world(0.0, s + 55.0, 1.0))
	_follow_snow(_lobby_snow, lobby_cam)
	_ambience.volume_db = lerpf(_ambience.volume_db, _ambience_db(), 1.0 - exp(-delta))
	_crowd.volume_db = lerpf(_crowd.volume_db, -60.0, 1.0 - exp(-delta * 2.0))


func _ambience_db() -> float:
	return -16.0 + float(_course.map["snowfall"]) * 8.0 + RSSfx.trim_db("wind_amb")


func _follow_snow(sn: GPUParticles3D, cam: Camera3D) -> void:
	sn.global_position = cam.global_position + (-cam.global_basis.z) * 8.0 + Vector3.UP * 4.0


# ------------------------------------------------------------------------ racers ----

func _player_added(p: Player) -> void:
	var r := Racer.new()
	p.data = r
	r.sk = RSSkier.new(_course, color_of(p), avatar_of(p), p.c.player)
	add_child(r.sk)
	r.sk.visible = false
	r.sk.gate_passed.connect(_on_gate.bind(p, true))
	r.sk.gate_missed.connect(_on_gate.bind(p, false))
	r.sk.trick_landed.connect(_on_trick.bind(p))
	r.sk.crashed.connect(_on_crash.bind(p))
	r.sk.landed.connect(_on_landed.bind(p))
	r.sk.net_hit.connect(_on_net.bind(p))
	r.sk.finished_run.connect(_on_finished.bind(p))
	r.snow = _make_snow(1 << p.c.player)
	var amount := float(_course.map["snowfall"])
	r.snow.emitting = amount > 0.0
	r.snow.amount_ratio = maxf(amount, 0.01)


func _player_removed(p: Player) -> void:
	var r := _racer(p)
	r.sk.queue_free()
	r.snow.queue_free()


func _player_ready(p: Player, is_ready: bool) -> void:
	if is_ready:
		_racer(p).gest.capture(p.c.motion_orientation())


func _player_recentered(p: Player) -> void:
	_racer(p).gest.capture(p.c.motion_orientation())
	p.popup(tr("已重设“平”的姿势"))


func _player_button(p: Player, button: int, pressed: bool) -> void:
	if pressed and button == RSController.BTN_B:
		_racer(p).push_ev = true


func _round_started(list: Array) -> void:
	_podium.reset()
	_time_left = TIME_LIMIT
	_finishers = 0
	_all_done_t = -1.0
	_beep = 4
	_board_lines = []
	_course.set_board(str(_course.map["en"]))
	var n := list.size()
	for i in n:
		var p: Player = list[i]
		var r := _racer(p)
		r.sk.place((i - (n - 1) * 0.5) * 2.4, -4.0)
		r.sk.gain_db = -3.0 * (n - 1)
		r.sk.visible = true
		r.place = 0
		r.tricks = 0
		r.hint_t = 0.0
		r.banked_t = -10.0
		r.gate_t = -10.0
		r.orbit = 0.0
		r.rec.clear()
		r.pend.clear()
		r.post = -1.0
		r.clip = []
		r.replay.reset(r.clip)
		r.clip_pts = 0
		r.air_from = 0.0
		r.sk.rig.cheer = 0.0
		r.sk.rig.set_layers(1)
		r.bot = null
		if p.fake:
			r.bot = RSSkiBot.new(r.sk, 91 + p.c.player * 17 + _rng.randi_range(0, 9999), bot_ability())
		send_ui(p, {"clear": true, "title": "SKI", "main": "0", "sub": "READY", "legends": ["", "POLE", "", null]})
		_camera(p, r, 0.0, true)


func _to_lobby() -> void:
	super._to_lobby()
	_podium.reset()
	_podium_on = false
	ui.results_on_right(false)
	for p: Player in players.values():
		var r := _racer(p)
		r.sk.visible = false
		r.sk.quiet()
	_update_map_card()


func _countdown_process(delta: float) -> void:
	var b := ceili(_countdown_time() - phase_time)
	if b < _beep:
		_beep = b
		RSSfx.play(self, "beep", -8.0)
	for p: Player in players.values():
		var r := _racer(p)
		r.sk.step(delta, _controls(p, r, delta), false)
		_camera(p, r, delta, false)
	_ambience.volume_db = lerpf(_ambience.volume_db, _ambience_db(), 1.0 - exp(-delta))


func _play_started() -> void:
	RSSfx.play(self, "go", -6.0)
	for p: Player in players.values():
		_racer(p).sk.launch(3.5)


func _play_process(delta: float) -> void:
	_time_left -= delta
	var all_done := true
	var near := 999.0
	for p: Player in players.values():
		var r := _racer(p)
		r.sk.step(delta, _controls(p, r, delta), true)
		_record(r, delta)
		_camera(p, r, delta, false)
		_hints(p, r, delta)
		_update_oled(p, r, delta)
		all_done = all_done and r.sk.finished
		near = minf(near, absf(r.sk.s() - _course.length))
	var cheer := clampf(1.0 - near / 120.0, 0.0, 1.0) * 0.7 + (0.3 if _finishers > 0 else 0.0)
	_crowd.volume_db = lerpf(_crowd.volume_db, linear_to_db(maxf(cheer, 0.001)) - 10.0, 1.0 - exp(-delta * 2.0))
	_ambience.volume_db = lerpf(_ambience.volume_db, _ambience_db() - 4.0, 1.0 - exp(-delta))
	if all_done:
		_all_done_t = maxf(_all_done_t, 0.0) + delta
		if _all_done_t > 3.5:
			finish_round()
	elif _time_left <= 0.0:
		_time_left = 0.0
		finish_round()


func _results_process(delta: float) -> void:
	if phase_time < _podium_at:
		for p: Player in players.values():
			_replay_step(p, delta)
		_crowd.volume_db = lerpf(_crowd.volume_db, -22.0, 1.0 - exp(-delta * 1.0))
		return
	if not _podium_on:
		_podium_start()
	_podium_step(delta)


func _result_detail(p: Player) -> String:
	var r := _racer(p)
	var sk := r.sk
	var run := (tr("用时 %.1f 秒（第 %d 个到）") % [sk.finish_time, r.place]) if sk.finished else tr("没到终点")
	return tr("%s　旗门 %d/%d　最佳动作 %s　最高 %d km/h") % [run, sk.gates_hit, _course.gates.size(), _fmt(sk.best_trick), roundi(sk.top_speed * 3.6)]


func _controls(p: Player, r: Racer, dt: float) -> RSMotionControls:
	var c := r.ctl
	if r.bot:
		c = r.bot.update(dt)
	elif p.c.connected:
		r.gest.read(p.c, c)
		c.grab = p.c.is_pressed(RSController.BTN_B)
		c.push = r.push_ev
	else:
		c.steer = 0.0
		c.pitch = 0.0
		c.ollie = 0.0
		c.flip = 0
		c.yaw_delta = 0.0
		c.grab = false
		c.push = false
	r.push_ev = false
	return c


# ------------------------------------------------------------------------ scoring ----

func _on_gate(index: int, p: Player, ok: bool) -> void:
	var r := _racer(p)
	r.gate_t = _clock
	r.gate_ok = ok
	if ok:
		var bonus := mini(r.sk.gate_streak - 1, 10) * 10
		p.score += GATE_POINTS + bonus
		RSSfx.play(self, "pickup", -16.0 + r.sk.gain_db, 1.0 + minf(r.sk.gate_streak, 10) * 0.02)
	else:
		p.score = maxi(p.score - GATE_MISS, 0)
		p.popup(tr("漏门  -%d") % GATE_MISS, Color(1.0, 0.5, 0.45))
		RSSfx.play(self, "fail", -14.0 + r.sk.gain_db)
		haptic(p, "miss")
	_log(p, "gate %d %s" % [index, "ok" if ok else "MISSED"])


func _on_trick(points: int, names: PackedStringArray, sketchy: bool, p: Player) -> void:
	_log(p, "trick %d %s%s" % [points, " + ".join(names), " (sketchy)" if sketchy else ""])
	var r := _racer(p)
	p.score += points
	r.tricks += 1
	r.banked_t = _clock
	r.banked_pts = points
	r.banked_sketchy = sketchy
	r.banked_names = " + ".join(names)
	if points > maxi(r.clip_pts, r.pend_pts if r.post >= 0.0 else 0):
		r.pend = RSReplay.since(r.rec, r.air_from - PRE_ROLL)
		r.pend_pts = points
		r.pend_names = r.banked_names
		r.post = POST_ROLL
	toast(p, "+%d" % points, 700)
	haptic(p, "hit")


func _on_crash(reason: String, p: Player) -> void:
	_log(p, "CRASH " + reason)
	var r := _racer(p)
	r.shake = 0.8
	p.popup(tr("摔倒了！") + reason, Color(1.0, 0.45, 0.4))
	toast(p, "CRASH!", 900)
	haptic(p, "crash")


func _on_landed(impact: float, p: Player) -> void:
	var r := _racer(p)
	r.shake = maxf(r.shake, clampf((impact - 3.0) / 10.0, 0.0, 0.45))


func _on_net(strength: float, p: Player) -> void:
	var r := _racer(p)
	r.shake = maxf(r.shake, clampf(strength / 14.0, 0.1, 0.5))
	haptic(p, "bump")


func _on_finished(p: Player) -> void:
	var r := _racer(p)
	_log(p, "finished %.1f s, score %d" % [r.sk.run_time, p.score])
	_finishers += 1
	r.place = _finishers
	var bonus: int = PLACE_BONUS[mini(r.place - 1, PLACE_BONUS.size() - 1)]
	if players.size() == 1:
		bonus = 1000
	p.score += bonus
	p.popup(tr("到达终点！第 %d 名  +%d") % [r.place, bonus] if players.size() > 1 else tr("到达终点！ +%d") % bonus, GOLD)
	toast(p, "FINISH #%d" % r.place, 1200)
	RSSfx.play(self, "chime", -8.0)
	if _finishers == 1:
		_time_left = minf(_time_left, AFTER_FIRST)
	_board_lines.append("%d  P%d  %s" % [r.place, p.c.player, _fmt_time(r.sk.finish_time)])
	_course.set_board("\n".join(_board_lines.slice(maxi(0, _board_lines.size() - 4))))
	# No jump to show in the replay: show crossing the line instead.
	if r.clip.is_empty() and r.post < 0.0:
		r.pend = RSReplay.since(r.rec, _clock - 2.6)
		r.pend_pts = 0
		r.pend_names = tr("冲过终点  ") + _fmt_time(r.sk.finish_time)
		r.post = POST_ROLL


func _log(p: Player, text: String) -> void:
	if demo:
		print("[%6.1f] P%d s=%6.1f v=%4.1f  %s" % [_clock, p.c.player, _racer(p).sk.s(), _racer(p).sk.current_speed(), text])


func _fmt(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if n < 0 else "") + s + out


func _fmt_time(t: float) -> String:
	return "%d:%05.2f" % [int(t / 60.0), fmod(t, 60.0)]


# ------------------------------------------------------------------------- camera ----

func _camera(p: Player, r: Racer, dt: float, snap: bool) -> void:
	var sk := r.sk
	var at := sk.draw_pos   # drawn (smoothed) position, as the rider mesh
	var fwd := Vector3(-sin(sk.heading), 0.0, -cos(sk.heading))
	if sk.mode == RSSkier.Mode.AIR and Vector2(sk.vel.x, sk.vel.z).length() > 0.5:
		fwd = Vector3(sk.vel.x, 0.0, sk.vel.z).normalized()
	# Lean the view down the fall line a little so turns don't swing the camera wildly.
	fwd = fwd.lerp(Vector3(-sin(_course.heading_at(sk.s())), 0.0, -cos(_course.heading_at(sk.s()))), 0.35).normalized()
	var k := 1.0 if snap else 1.0 - exp(-dt * 5.0)
	r.cam_fwd = fwd if snap else r.cam_fwd.lerp(fwd, 1.0 - exp(-dt * 2.5)).normalized()
	var spd := sk.current_speed()
	var dist := 4.6 + clampf(spd - 8.0, 0.0, 18.0) * 0.1
	var want := at - r.cam_fwd * dist + Vector3.UP * (2.3 + clampf(spd - 10.0, 0.0, 15.0) * 0.04)
	var look := at + r.cam_fwd * 6.0 + Vector3.UP * 0.4
	if sk.mode == RSSkier.Mode.CRASH:
		want = r.cam_pos.lerp(at - r.cam_fwd * 6.0 + Vector3.UP * 3.0, 0.03)
		look = at + Vector3.UP * 0.4
	elif sk.finished and spd < 2.5:
		r.orbit += dt * 0.35
		want = at + Vector3(sin(r.orbit) * 4.5, 1.8, cos(r.orbit) * 4.5)
		look = at + Vector3.UP * 1.0
	want.y = maxf(want.y, _course.height(want.x, want.z) + 1.0)
	if snap:
		r.cam_off = want - at
		r.cam_pos = want
		r.cam_look = look
	elif sk.mode == RSSkier.Mode.CRASH or (sk.finished and spd < 2.5):
		r.cam_pos = r.cam_pos.lerp(want, k)
		r.cam_off = r.cam_pos - at
		r.cam_look = r.cam_look.lerp(look, minf(k * 1.4, 1.0))
	else:
		# Smooth the offset from the skier, not the position: no lag however fast.
		r.cam_off = r.cam_off.lerp(want - at, k)
		r.cam_pos = at + r.cam_off
		r.cam_look = r.cam_look.lerp(look, minf(k * 2.5, 1.0))
	r.cam_pos.y = maxf(r.cam_pos.y, _course.height(r.cam_pos.x, r.cam_pos.z) + 0.8)
	# Never inside another skier: rise over anyone right in front of the lens.
	for q: Player in players.values():
		var o := _racer(q).sk
		if o == sk or not o.visible:
			continue
		var d := (r.cam_pos - (o.pos + Vector3.UP * 1.0)).length()
		if d < 1.8:
			r.cam_pos.y = maxf(r.cam_pos.y, o.pos.y + 1.0 + sqrt(1.8 * 1.8 - minf(d * d, 3.0)) + 0.4)
	r.shake = maxf(r.shake - dt * 1.6, 0.0)
	var jitter := Vector3(_rng.randf() - 0.5, _rng.randf() - 0.5, _rng.randf() - 0.5) * r.shake * 0.35
	# Consume the same RNG values so this visual option cannot change gameplay.
	if not RSSettings.camera_shake:
		jitter = Vector3.ZERO
	p.cam.global_position = r.cam_pos + jitter
	if p.cam.global_position.distance_to(r.cam_look) > 0.1:
		p.cam.look_at(r.cam_look + jitter * 0.5)
	p.cam.fov = lerpf(p.cam.fov, 62.0 + clampf(spd - 8.0, 0.0, 18.0) * 0.6, 1.0 if snap else 1.0 - exp(-dt * 2.0))
	if phase == Phase.COUNTDOWN and phase_time < INTRO:
		# Intro: high over the run looking down the valley, then swooping in behind the racer.
		var ahead := _course.world(0.0, 180.0, 0.0)
		var p0 := _course.world(-40.0, -60.0, 60.0)
		var p1 := at + Vector3(6.0 * signf(at.x - _course.centre(0.0) + 0.01), 4.0, 12.0)
		RSIntro.apply(p.cam, phase_time, INTRO, p0, p1, r.cam_pos, ahead, r.cam_look, 55.0, 64.0, 0.3)
	_follow_snow(r.snow, p.cam)


# ------------------------------------------------------------------- hints / OLED ----

func _hints(p: Player, r: Racer, dt: float) -> void:
	r.hint_t -= dt
	if p.fake or r.hint_t > 0.0:
		return
	var sk := r.sk
	if phase_time < 0.5:
		_hint(r, "start", 1, tr("按 B 撑杖出发　左右倾斜 = 转弯　往前压 = 团身加速"), 5.0)
	elif sk.mode == RSSkier.Mode.AIR and sk.air_t > 0.15 and sk.vel.y > -2.0:
		_hint(r, "air", 3, tr("空中：水平转动手柄 = 转体　按住 B = 抓板　落地前对准方向"), 3.0)
	elif sk.mode == RSSkier.Mode.RIDE:
		var s := sk.s()
		for kk in _course.kickers:
			var lip: float = kk["lip"]
			if s > lip - float(kk["len"]) - 40.0 and s < lip - float(kk["len"]):
				_hint(r, "kicker", 2, tr("前面是跳台：对准它，到台边快速往上一抬！"), 3.5)
				return
		if sk.next_gate < _course.gates.size() and phase_time > 8.0:
			var g: Dictionary = _course.gates[sk.next_gate]
			if float(g["s"]) - s < 25.0 and absf(float(g["x"]) - sk.pos.x) > float(g["w"]) + 4.0:
				_hint(r, "gate", 2, tr("从两面旗子中间穿过去：往旗门那边倾斜"), 3.0)


func _hint(r: Racer, key: String, times: int, text: String, dur: float) -> void:
	var n: int = r.hints_seen.get(key, 0)
	if n >= times:
		return
	r.hints_seen[key] = n + 1
	r.hint = text
	r.hint_t = dur


func _update_oled(p: Player, r: Racer, dt: float) -> void:
	r.oled_t -= dt
	if r.oled_t > 0.0:
		return
	var sk := r.sk
	var main := str(p.score)
	var sub := "%d KM/H" % roundi(sk.current_speed() * 3.6)
	if sk.finished:
		sub = "FINISH #%d" % r.place
	elif sk.mode == RSSkier.Mode.CRASH:
		sub = "CRASH!"
	elif _clock - r.banked_t < 1.2:
		sub = "+%d" % r.banked_pts
	var title := "SKI %d/%d" % [sk.gates_hit, _course.gates.size()]
	var key := "%s|%s|%s" % [title, main, sub]
	if key == p.oled_key:
		return
	p.oled_key = key
	r.oled_t = 0.15
	send_ui(p, {"title": title, "main": main, "sub": sub})


# ---------------------------------------------------------------------------- HUD ----

func _draw_hud(h: PlayerHud, p: Player, k: float) -> void:
	var r := _racer(p)
	var sk := r.sk
	var sz := h.size
	if phase == Phase.RESULTS:
		_draw_replay(h, p, k)
		return
	if phase == Phase.COUNTDOWN and phase_time < INTRO:
		return
	var pale := Color(0.92, 0.95, 1.0)

	RSSkiHud.draw_stats(self, h, sk, _course.gates.size(), _fmt_time(sk.finish_time if sk.finished else sk.run_time), k, GOLD)

	# Run progress: everyone's position on the way to the finish.
	var bar := Rect2(Vector2(sz.x - 250 * k, 30 * k), Vector2(220 * k, 8 * k))
	h.draw_style_box(_pill, Rect2(bar.position - Vector2(16, 16) * k, bar.size + Vector2(32 * k, 56 * k)))
	draw_box(h, bar, Color(1, 1, 1, 0.25), 0)
	for q: Player in players.values():
		var f := clampf(_racer(q).sk.s() / _course.length, 0.0, 1.0)
		var at := bar.position + Vector2(bar.size.x * f, bar.size.y * 0.5)
		h.draw_circle(at, (8.0 if q == p else 5.0) * k, color_of(q))
		if q == p:
			h.draw_arc(at, 8.0 * k, 0, TAU, 20, Color.WHITE, 2.0 * k, true)
	h.draw_rect(Rect2(bar.end - Vector2(0, 14 * k), Vector2(3 * k, 16 * k)), Color.WHITE)
	var to_go := maxi(0, roundi(_course.length - sk.s()))
	draw_text(h, tr("终点 %d m") % to_go if not sk.finished else tr("已到终点"), bar.position + Vector2(bar.size.x, 32 * k), 15 * k, pale, false, true)

	# Next gate: a marker over it in its colour.
	if sk.next_gate < _course.gates.size() and not sk.finished:
		var g: Dictionary = _course.gates[sk.next_gate]
		var gs: float = g["s"]
		if gs - sk.s() < 70.0:
			var top := Vector3(float(g["x"]), _course.height(float(g["x"]), -gs) + 2.6, -gs)
			if not p.cam.is_position_behind(top):
				var at := p.cam.unproject_position(top)
				var col := Color(0.95, 0.2, 0.15) if int(g["color"]) == 0 else Color(0.2, 0.45, 1.0)
				var s := (9.0 + 9.0 * clampf(1.0 - (gs - sk.s()) / 70.0, 0.0, 1.0)) * k
				h.draw_colored_polygon(PackedVector2Array([at + Vector2(-s, -s * 1.2), at + Vector2(s, -s * 1.2), at]), Color(col, 0.85))
				h.draw_polyline(PackedVector2Array([at + Vector2(-s, -s * 1.2), at + Vector2(s, -s * 1.2), at, at + Vector2(-s, -s * 1.2)]), Color(1, 1, 1, 0.9), 2.0 * k, true)

	# Gate passed / missed flash.
	if _clock - r.gate_t < 0.7:
		var a := clampf(0.7 - (_clock - r.gate_t), 0.0, 0.7) / 0.7
		if r.gate_ok:
			var streak := "  ×%d" % sk.gate_streak if sk.gate_streak >= 3 else ""
			draw_text(h, "+%d%s" % [GATE_POINTS + mini(sk.gate_streak - 1, 10) * 10, streak], Vector2(sz.x * 0.5, sz.y * 0.36), 30 * k, Color(0.55, 1.0, 0.6, a), true, false, RSUi.font_bold())

	# Speed lines at the screen edges when going fast.
	var fast := clampf((sk.current_speed() - 16.0) / 10.0, 0.0, 1.0)
	if fast > 0.0 and phase == Phase.PLAY:
		var c := sz * 0.5
		for i in 22:
			var ang := TAU * i / 22.0 + float(int(_clock * 20.0) % 7) * 0.13
			var d := Vector2(cos(ang), sin(ang))
			var r0 := sz.length() * (0.36 + 0.04 * sin(_clock * 13.0 + i))
			h.draw_line(c + d * r0, c + d * (r0 + 70 * k), Color(1, 1, 1, 0.13 * fast), 2.0 * k)

	# The trick just landed.
	var y := sz.y - 64 * k
	if _clock - r.banked_t < 1.8:
		var a := clampf(1.8 - (_clock - r.banked_t), 0.0, 1.0)
		var c1 := Color(1.0, 0.7, 0.35, a) if r.banked_sketchy else Color(GOLD, a)
		draw_text(h, r.banked_names, Vector2(sz.x * 0.5, y - 40 * k), 21 * k, Color(1, 1, 1, a * 0.9), true)
		draw_text(h, (tr("勉强落地  +%s") if r.banked_sketchy else "+%s") % _fmt(r.banked_pts), Vector2(sz.x * 0.5, y), 44 * k, c1, true, false, RSUi.font_bold())
	elif sk.mode == RSSkier.Mode.AIR and sk.air_t > 0.25:
		var deg := roundi(absf(sk.spin) / PI * 180.0 / 90.0) * 90
		var t := "%d°" % deg if deg >= 90 else ""
		if sk.rig.grab > 0:
			t += ("  " if t != "" else "") + RSSkier.GRABS[sk.rig.grab - 1] + " Grab"
		if t != "":
			draw_text(h, t, Vector2(sz.x * 0.5, y), 34 * k, Color.WHITE, true)

	if r.hint_t > 0.0 and not sk.finished:
		var a := clampf(r.hint_t, 0.0, 1.0)
		draw_pill(h, r.hint, Vector2(sz.x * 0.5, sz.y * 0.2), 17 * k, Color(1, 1, 1, a))

	if sk.finished:
		draw_text(h, tr("完成！第 %d 名") % r.place if players.size() > 1 else tr("完成！"), Vector2(sz.x * 0.5, sz.y * 0.3), 46 * k, GOLD, true, false, RSUi.font_bold())
		draw_text(h, _fmt_time(sk.finish_time), Vector2(sz.x * 0.5, sz.y * 0.3 + 44 * k), 28 * k, Color.WHITE, true, false, num_font)
		var waiting := false
		for q: Player in players.values():
			waiting = waiting or not _racer(q).sk.finished
		if waiting and phase == Phase.PLAY:
			draw_text(h, tr("等其他玩家到终点…"), Vector2(sz.x * 0.5, sz.y * 0.3 + 80 * k), 20 * k, pale, true)


func _draw_overlay(o: Overlay, k: float) -> void:
	var m := _course.map
	if phase == Phase.COUNTDOWN and phase_time < INTRO:
		var a := RSIntro.fade(phase_time, INTRO)
		draw_title_card(o, tr(str(m["name"])), tr("%s  ·  %d 米  ·  %d 道旗门  ·  难度 %s") % [m["en"], roundi(_course.length), _course.gates.size(), RSSkiMaps.stars(map_index)], a, k)
	elif phase == Phase.COUNTDOWN:
		draw_text(o, tr("倾斜手柄转弯，往前压团身，往后仰刹车"), Vector2(o.size.x * 0.5, o.size.y * 0.45 + 60 * k), 26 * k, Color(0.92, 0.95, 1.0), true)
	elif phase == Phase.PLAY:
		draw_clock(o, _time_left, k)
	elif phase == Phase.RESULTS and _podium_on:
		_draw_podium_tags(o, k)


# ------------------------------------------------------------------------ replays ----

func _record(r: Racer, dt: float) -> void:
	var rig := r.sk.rig
	RSReplay.record(r.rec, {"t": _clock, "xf": rig.global_transform, "imp": rig.impacts, "in": [rig.crouch, rig.tuck, rig.lean,
		rig.edge, rig.yaw, rig.wedge, rig.grounded, rig.plant, rig.plant_side, rig.push, rig.grab, rig.feet_lift, rig.arms,
		1.0 if rig.is_crashing() else 0.0]}, CLIP_MAX + PRE_ROLL + POST_ROLL + 1.0)
	rig.impacts = 0.0
	if r.post >= 0.0:
		r.pend.append(r.rec.back())
		r.post -= dt
		if r.post < 0.0:
			_keep_clip(r)
	if r.sk.mode != RSSkier.Mode.AIR:
		r.air_from = _clock


func _keep_clip(r: Racer) -> void:
	var end := float(r.pend.back()["t"]) if not r.pend.is_empty() else 0.0
	r.clip = RSReplay.since(r.pend, end - CLIP_MAX - POST_ROLL)
	r.clip_pts = r.pend_pts
	r.clip_names = r.pend_names
	r.pend = []
	r.pend_pts = 0
	r.post = -1.0


func finish_round() -> void:
	var longest := 0.0
	for p: Player in players.values():
		var r := _racer(p)
		if r.post >= 0.0:
			_keep_clip(r)
		longest = maxf(longest, RSReplay.duration(r.clip) / SLOW)
		r.replay.reset(r.clip)
		r.sk.quiet()
		r.sk.rig.end_crash()
		if r.clip.size() > 1:
			r.sk.rig.set_layers(1 << p.c.player)
			var a: Vector3 = (r.clip[0]["xf"] as Transform3D).origin
			var b: Vector3 = (r.clip.back()["xf"] as Transform3D).origin
			var travel := Vector3(b.x - a.x, 0.0, b.z - a.z)
			travel = travel.normalized() if travel.length() > 0.5 else Vector3.FORWARD
			r.rp_side = travel.cross(Vector3.UP).normalized()
			# Film from the side with more piste.
			var mid := (a + b) * 0.5
			if signf(r.rp_side.x) == signf(_course.lateral(mid.x, mid.z)):
				r.rp_side = -r.rp_side
			r.cam_pos = a + r.rp_side * 6.0 + Vector3.UP * 1.5
			r.cam_look = a + Vector3.UP * 0.8
	_podium_at = RSReplay.lead_out(longest, 9.0)
	results_delay = _podium_at + 1.6
	_podium_on = false
	super.finish_round()


func _replay_step(p: Player, delta: float) -> void:
	var r := _racer(p)
	var rig := r.sk.rig
	if not r.replay.sample(phase_time, SLOW):
		rig.update(delta)
		_camera(p, r, delta, false)
		return
	var crossed := r.replay.crossed_from
	while crossed <= r.replay.index:
		var imp := float(r.clip[crossed]["imp"])
		if imp > 0.0:
			rig.impact(imp)
			if imp > 0.9:
				RSSfx.play(self, "snowland", -10.0 + r.sk.gain_db, 0.75)
		crossed += 1
	var fa := r.replay.a
	var fb := r.replay.b
	var u := r.replay.weight
	rig.global_transform = (fa["xf"] as Transform3D).interpolate_with(fb["xf"], u)
	var ia: Array = fa["in"]
	var ib: Array = fb["in"]
	rig.crouch = lerpf(ia[0], ib[0], u)
	rig.tuck = lerpf(ia[1], ib[1], u)
	rig.lean = lerpf(ia[2], ib[2], u)
	rig.edge = lerpf(ia[3], ib[3], u)
	rig.yaw = lerp_angle(ia[4], ib[4], u)
	rig.wedge = lerpf(ia[5], ib[5], u)
	rig.grounded = lerpf(ia[6], ib[6], u)
	rig.plant = ia[7]
	rig.plant_side = ia[8]
	rig.push = ia[9]
	rig.grab = ia[10]
	rig.feet_lift = lerpf(ia[11], ib[11], u)
	rig.arms = lerpf(ia[12], ib[12], u)
	var crash := float(ia[13]) > 0.5
	if crash and not rig.is_crashing():
		rig.start_crash()
	elif not crash and rig.is_crashing():
		rig.end_crash()
	rig.update(delta * SLOW)
	# Tracking shot: alongside and a little ahead, looking back at the skier.
	var at := rig.global_position
	var fwd := ((fb["xf"] as Transform3D).origin - (fa["xf"] as Transform3D).origin)
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 1e-3 else -r.rp_side.cross(Vector3.UP)
	var want := at + r.rp_side * 5.5 + fwd * 2.0 + Vector3.UP * 1.2
	want.y = maxf(want.y, _course.height(want.x, want.z) + 0.8)
	var k := 1.0 - exp(-delta * 3.0)
	r.cam_pos = r.cam_pos.lerp(want, k)
	r.cam_look = r.cam_look.lerp(at + Vector3.UP * 0.8, minf(k * 2.0, 1.0))
	p.cam.global_position = r.cam_pos
	p.cam.look_at(r.cam_look)
	p.cam.fov = lerpf(p.cam.fov, 52.0, k)
	_follow_snow(r.snow, p.cam)


func _draw_replay(h: PlayerHud, p: Player, k: float) -> void:
	var r := _racer(p)
	var sz := h.size
	var bar := maxf(sz.y * 0.08, 64.0 * k)
	h.draw_rect(Rect2(Vector2.ZERO, Vector2(sz.x, bar)), Color(0.02, 0.02, 0.03))
	h.draw_rect(Rect2(Vector2(0, sz.y - bar), Vector2(sz.x, bar)), Color(0.02, 0.02, 0.03))
	draw_text(h, "P%d" % p.c.player, Vector2(20 * k, bar * 0.5 + 9 * k), 24 * k, color_of(p))
	if r.clip.size() < 2:
		draw_text(h, tr("这局没有可回放的镜头"), Vector2(sz.x * 0.5, sz.y - bar * 0.5 + 8 * k), 22 * k, Color(0.92, 0.95, 1.0), true)
		return
	if fmod(_clock, 1.0) < 0.6:
		h.draw_circle(Vector2(sz.x - 150 * k, bar * 0.5), 7 * k, Color(1.0, 0.25, 0.2))
	draw_text(h, "REPLAY", Vector2(sz.x - 136 * k, bar * 0.5 + 8 * k), 22 * k, Color.WHITE)
	if r.clip_pts > 0:
		draw_text(h, tr("最佳动作  ") + r.clip_names, Vector2(sz.x * 0.5, sz.y - bar - 44 * k), 22 * k, Color.WHITE, true)
		draw_text(h, "+" + _fmt(r.clip_pts), Vector2(sz.x * 0.5, sz.y - bar - 8 * k), 40 * k, GOLD, true, false, RSUi.font_bold())
	else:
		draw_text(h, r.clip_names, Vector2(sz.x * 0.5, sz.y - bar - 12 * k), 30 * k, GOLD, true)


# ------------------------------------------------------------------------- podium ----

func _build_podium() -> void:
	_podium.configure(PODIUM, Vector2(1.4, 2.1), Vector3(2.6, 0, 0.8), 1.0, font, 1.0)


func _podium_spot(i: int) -> Vector3:
	var at := _podium.spot(i)
	if i >= 3 and _podium.rank(i) > 3:
		at.y = _course.height(at.x, at.z)
	return at


func _podium_start() -> void:
	_podium_on = true
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
		var rig := _racer(_podium_order[i]).sk.rig
		rig.set_layers(1)
		rig.end_crash()
		# Face up the hill (toward the camera), skis on.
		rig.global_transform = Transform3D(_podium.global_basis * Basis(Vector3.UP, PI), _podium_spot(i))
		rig.crouch = 0.05
		rig.tuck = 0.0
		rig.lean = 0.0
		rig.edge = 0.0
		rig.yaw = 0.0
		rig.wedge = 0.0
		rig.grounded = 1.0
		rig.plant = -1.0
		rig.push = -1.0
		rig.grab = 0
		rig.feet_lift = 0.0
		rig.arms = 0.1
		rig.cheer = _podium.cheer(i)
	RSSfx.play(self, "chime", -4.0)


func _podium_step(delta: float) -> void:
	_podium.apply_camera(lobby_cam, phase_time - _podium_at, 2.4, -0.12, 8.5, -0.3, 1.8, 2.7, 1.3)
	_podium.fit_left(lobby_cam)
	_follow_snow(_lobby_snow, lobby_cam)
	for p: Player in players.values():
		_racer(p).sk.rig.update(delta)
	_crowd.volume_db = lerpf(_crowd.volume_db, -9.0, 1.0 - exp(-delta * 1.5))


func _draw_podium_tags(o: Overlay, k: float) -> void:
	for i in _podium_order.size():
		var p: Player = _podium_order[i]
		var head := _podium_spot(i) + Vector3.UP * 2.1
		if lobby_cam.is_position_behind(head):
			continue
		var at := lobby_cam.unproject_position(head)
		draw_pill(o, "P%d" % p.c.player, at, 20 * k, color_of(p))
