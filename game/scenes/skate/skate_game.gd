extends RSPartyGame
## 滑板 (skateboard, a P1 motion game): everyone rides the same downhill street to the sea at
## the same time (split screen), scoring trick combos on the way; arriving early earns a
## placing bonus. The controller is the board: tilt to carve, flick the tip up to ollie,
## flick sideways for flips, turn it in the air to spin, hold B to grab (B on the ground
## pushes). Grinds and manuals have a balance meter. See RSSkater for the rules.
##
## Debug: `-- --demo=N` (bot riders), `-- --at=5,12,30` screenshot times with --shots.

const TIME_LIMIT := 150.0
const AFTER_FIRST := 25.0      ## once someone finishes, the rest have this long
const PLACE_BONUS := [1500, 1000, 600, 300]
const LETTERS := "SKATE"
const GOLD := Color(1.0, 0.84, 0.3)
const INTRO := 3.4             ## camera flyover before the 3-2-1
const SLOW := 0.45             ## replay speed
const CLIP_MAX := 3.6          ## seconds of a combo kept for the replay (the end of it)
const PRE_ROLL := 0.9          ## replay starts this long before the combo
const POST_ROLL := 0.9         ## ...and runs on this long after the landing
const PODIUM_S := 566.0
const PODIUM := [[0.0, 0.8], [-1.35, 0.55], [1.35, 0.36]]   ## [x, height] for 1st, 2nd, 3rd
const SFX := ["roll", "grind_metal", "grind_ledge", "wind", "applause", "pop", "land", "flip", "push", "bail",
	"thud", "chime", "pickup", "ding", "beep", "go", "fail"]


class Rider:
	var sk: RSSkater
	var gest := RSMotionGestures.new()
	var bot: RSSkateBot
	var ctl := RSMotionControls.new()
	var push_ev := false
	var letter_nodes: Array[Label3D] = []
	var cam_pos := Vector3.ZERO
	var cam_look := Vector3.ZERO
	var cam_fwd := Vector3.FORWARD
	var shake := 0.0
	var place := 0
	var best_combo := 0
	var tricks := 0
	var hint := ""
	var hint_t := 0.0
	var hints_seen: Dictionary = {}
	var banked_t := -10.0
	var banked_pts := 0
	var banked_names := ""
	var banked_sketchy := false
	var oled_t := 0.0
	var orbit := 0.0
	# Replay of the best combo: frames of the rig (transform + pose inputs) on the game clock.
	var rec: Array = []
	var combo_from := 0.0
	var pend: Array = []
	var pend_pts := 0
	var pend_names := ""
	var post := -1.0
	var clip: Array = []
	var clip_pts := 0
	var clip_names := ""
	var replay := RSReplay.new()
	var rp_side := Vector3.RIGHT


var _course: RSSkateCourse
var _time_left := TIME_LIMIT
var _finishers := 0
var _all_done_t := -1.0
var _lobby_s := 0.0
var _beep := 4
var _crowd: AudioStreamPlayer
var _rng := RandomNumberGenerator.new()
var _podium: RSPodium
var _podium_on := false
var _podium_at := 0.0
var _podium_order: Array = []


func _game_name() -> String:
	return tr("滑板")


func _oled_name() -> String:
	return "SKATE"


func _how_to_play() -> String:
	return (tr("顺着海边的下坡街道滑到终点，一路做动作攒连招。手柄就是滑板：\n") +
		tr("左右倾斜 = 转向　快速往上一抬 = 起跳 (Ollie)　按 B = 蹬地加速\n") +
		tr("空中：左右快速一甩 = 翻板　水平转动手柄 = 转体　按住 B = 抓板\n") +
		tr("跳上栏杆或台子边 = 磨杆，左右倾斜保持平衡；地上把手柄往后仰 = Manual\n") +
		tr("连招分 = 动作分之和 × 动作个数，落地不摔才算。收集 S-K-A-T-E 字母、先到终点都有奖励。\n") +
		tr("按 A 准备时的拿法就是“平”，长按 D 1 秒可以重新设定。"))


func _countdown_time() -> float:
	return INTRO + COUNTDOWN_TIME


func _parse_arg(arg: String) -> void:
	if arg.begins_with("--at="):
		shot_times = []
		for v in arg.get_slice("=", 1).split(","):
			shot_times.append(float(v))


func _rider(p: Player) -> Rider:
	return p.data


# --------------------------------------------------------------------------- world ----

func _setup_world() -> void:
	_rng.seed = 4242
	_course = RSSkateCourse.new()
	add_child(_course)
	RSSkateCourse.setup_environment(self)
	RSSfx.warm_up(SFX)
	_crowd = RSSfx.loop(self, "applause")
	_build_podium()
	lobby_cam.fov = 60
	if shot_times == [0.5, 2.5, 9.0, 16.0, 25.0]:
		shot_times = [5.0, 12.0, 20.0, 30.0, 42.0, 56.0, 68.0]


func _lobby_process(delta: float) -> void:
	_lobby_s = fmod(_lobby_s + delta * 8.0, RSSkateCourse.FINISH_S)
	var s := _lobby_s
	lobby_cam.position = _course.world(sin(s * 0.03) * 5.0, s, 7.5)
	lobby_cam.look_at(_course.world(0.0, s + 28.0, 0.5))


# ------------------------------------------------------------------------- riders ----

func _player_added(p: Player) -> void:
	var r := Rider.new()
	p.data = r
	r.sk = RSSkater.new(_course, color_of(p), avatar_of(p), p.c.player)
	add_child(r.sk)
	r.sk.visible = false
	r.sk.combo_banked.connect(_on_banked.bind(p))
	r.sk.combo_lost.connect(_on_lost.bind(p))
	r.sk.bailed.connect(_on_bailed.bind(p))
	r.sk.landed.connect(_on_landed.bind(p))
	r.sk.letter_collected.connect(_on_letter.bind(p))
	r.sk.finished_run.connect(_on_finished.bind(p))
	# Each rider has their own S-K-A-T-E letters, seen only in their own view.
	for i in 5:
		var l := Label3D.new()
		l.text = LETTERS[i]
		l.font = font
		l.font_size = 160
		l.pixel_size = 0.008
		l.outline_size = 36
		l.modulate = GOLD
		l.outline_modulate = color_of(p).darkened(0.4)
		l.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		l.layers = 1 << p.c.player
		l.position = _course.letters[i]
		l.visible = false
		add_child(l)
		r.letter_nodes.append(l)


func _player_removed(p: Player) -> void:
	var r := _rider(p)
	r.sk.queue_free()
	for l in r.letter_nodes:
		l.queue_free()


func _player_ready(p: Player, is_ready: bool) -> void:
	if is_ready:
		_rider(p).gest.capture(p.c.motion_orientation())


func _player_recentered(p: Player) -> void:
	_rider(p).gest.capture(p.c.motion_orientation())
	p.popup(tr("已重设“平”的姿势"))


func _player_button(p: Player, button: int, pressed: bool) -> void:
	if pressed and button == RSController.BTN_B:
		_rider(p).push_ev = true


func _round_started(list: Array) -> void:
	_podium.reset()
	_time_left = TIME_LIMIT
	_finishers = 0
	_all_done_t = -1.0
	_beep = 4
	var n := list.size()
	for i in n:
		var p: Player = list[i]
		var r := _rider(p)
		r.sk.place((i - (n - 1) * 0.5) * 2.6, RSSkateCourse.START_S - 4.0)
		r.sk.gain_db = -3.0 * (n - 1)
		r.sk.visible = true
		r.place = 0
		r.best_combo = 0
		r.tricks = 0
		r.hint_t = 0.0
		r.banked_t = -10.0
		r.orbit = 0.0
		r.rec.clear()
		r.pend.clear()
		r.post = -1.0
		r.clip = []
		r.replay.reset(r.clip)
		r.clip_pts = 0
		r.combo_from = 0.0
		r.sk.rig.cheer = 0.0
		r.sk.rig.board.visible = true
		r.sk.rig.set_layers(1)
		for l in r.letter_nodes:
			l.visible = true
		if p.fake:
			r.bot = RSSkateBot.new(r.sk, 77 + p.c.player * 13 + _rng.randi_range(0, 9999), bot_ability())
		send_ui(p, {"clear": true, "title": "SKATE", "main": "0", "sub": "READY", "legends": ["", "PUSH", "", null]})
		_camera(p, r, 0.0, true)


func _to_lobby() -> void:
	super._to_lobby()
	_podium.reset()
	_podium_on = false
	for p: Player in players.values():
		var r := _rider(p)
		r.sk.visible = false
		for l in r.letter_nodes:
			l.visible = false


func _countdown_process(delta: float) -> void:
	var b := ceili(_countdown_time() - phase_time)
	if b < _beep:
		_beep = b
		RSSfx.play(self, "beep", -8.0)
	for p: Player in players.values():
		var r := _rider(p)
		r.sk.step(delta, _controls(p, r, delta), false)
		_camera(p, r, delta, false)
	_spin_letters()


func _play_started() -> void:
	RSSfx.play(self, "go", -6.0)


func _play_process(delta: float) -> void:
	_time_left -= delta
	var all_done := true
	var near := 999.0
	for p: Player in players.values():
		var r := _rider(p)
		r.sk.step(delta, _controls(p, r, delta), true)
		_record(r, delta)
		_camera(p, r, delta, false)
		_hints(p, r, delta)
		_update_oled(p, r, delta)
		all_done = all_done and r.sk.finished
		near = minf(near, absf(r.sk.s() - RSSkateCourse.FINISH_S))
	_spin_letters()
	var cheer := clampf(1.0 - near / 90.0, 0.0, 1.0) * 0.7 + (0.3 if _finishers > 0 else 0.0)
	_crowd.volume_db = lerpf(_crowd.volume_db, linear_to_db(maxf(cheer, 0.001)) - 10.0, 1.0 - exp(-delta * 2.0))
	if all_done:
		_all_done_t = maxf(_all_done_t, 0.0) + delta
		if _all_done_t > 3.0:
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
	var r := _rider(p)
	var got := 0
	for g: bool in r.sk.letters:
		got += int(g)
	var run := (tr("用时 %.1f 秒（第 %d 个到）") % [r.sk.finish_time, r.place]) if r.sk.finished else tr("没到终点")
	return tr("%s　最高连招 %s　字母 %d/5") % [run, _fmt(r.best_combo), got]


func _controls(p: Player, r: Rider, dt: float) -> RSMotionControls:
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


func _spin_letters() -> void:
	for p: Player in players.values():
		var nodes := _rider(p).letter_nodes
		for i in nodes.size():
			nodes[i].position.y = _course.letters[i].y + sin(_clock * 2.0 + i) * 0.15


# ------------------------------------------------------------------------ scoring ----

func _on_banked(points: int, names: PackedStringArray, sketchy: bool, p: Player) -> void:
	_log(p, "banked %d %s%s" % [points, " + ".join(names), " (sketchy)" if sketchy else ""])
	var r := _rider(p)
	p.score += points
	r.best_combo = maxi(r.best_combo, points)
	r.tricks += names.size()
	r.banked_t = _clock
	r.banked_pts = points
	r.banked_sketchy = sketchy
	r.banked_names = _trick_line(names)
	# Best so far: cut the replay from the recording once the landing has run on a little.
	if points > maxi(r.clip_pts, r.pend_pts if r.post >= 0.0 else 0):
		r.pend = RSReplay.since(r.rec, r.combo_from - PRE_ROLL)
		r.pend_pts = points
		r.pend_names = _trick_line(names, 3)
		r.post = POST_ROLL
	toast(p, "+%d" % points, 700)
	haptic(p, "hit")


func _on_lost(points: int, p: Player) -> void:
	_log(p, "lost %d" % points)
	p.popup(tr("连招没了  -%s") % _fmt(points), Color(1.0, 0.5, 0.45))


func _on_bailed(reason: String, p: Player) -> void:
	_log(p, "BAIL " + reason)
	var r := _rider(p)
	r.shake = 0.7
	p.popup(tr("摔倒了！") + reason, Color(1.0, 0.45, 0.4))
	toast(p, "BAIL!", 900)
	haptic(p, "crash")


func _on_landed(impact: float, p: Player) -> void:
	var r := _rider(p)
	r.shake = maxf(r.shake, clampf((impact - 3.0) / 9.0, 0.0, 0.4))


func _on_letter(i: int, p: Player) -> void:
	_log(p, "letter %s" % LETTERS[i])
	var r := _rider(p)
	r.letter_nodes[i].visible = false
	p.score += 250
	p.popup(tr("字母 %s  +250") % LETTERS[i], GOLD)
	var got := 0
	for g: bool in r.sk.letters:
		got += int(g)
	if got == 5:
		p.score += 1500
		p.popup(tr("S-K-A-T-E 全部收集！ +1500"), GOLD)
		RSSfx.play(self, "chime", -4.0, 1.3)


func _on_finished(p: Player) -> void:
	_log(p, "finished %.1f s, score %d" % [_rider(p).sk.run_time, p.score])
	var r := _rider(p)
	_finishers += 1
	r.place = _finishers
	var bonus: int = PLACE_BONUS[mini(r.place - 1, PLACE_BONUS.size() - 1)]
	if players.size() == 1:
		bonus = 1000
	p.score += bonus
	p.popup(tr("到达终点！第 %d 名  +%d") % [r.place, bonus] if players.size() > 1 else tr("到达终点！ +%d") % bonus, GOLD)
	toast(p, "FINISH #%d" % r.place, 1200)
	if _finishers == 1:
		_time_left = minf(_time_left, AFTER_FIRST)


func _log(p: Player, text: String) -> void:
	if demo:
		print("[%6.1f] P%d s=%5.1f  %s" % [_clock, p.c.player, _rider(p).sk.s(), text])


func _trick_line(names: PackedStringArray, limit: int = 4) -> String:
	if names.size() <= limit:
		return " + ".join(names)
	return "… + " + " + ".join(names.slice(names.size() - limit))


func _fmt(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if n < 0 else "") + s + out


# ------------------------------------------------------------------------- camera ----

func _camera(p: Player, r: Rider, dt: float, snap: bool) -> void:
	var sk := r.sk
	var fwd := Vector3(-sin(sk.heading), 0.0, -cos(sk.heading))
	if sk.mode == RSSkater.Mode.AIR and Vector2(sk.vel.x, sk.vel.z).length() > 0.5:
		fwd = Vector3(sk.vel.x, 0.0, sk.vel.z).normalized()
	var k := 1.0 if snap else 1.0 - exp(-dt * 6.5)
	r.cam_fwd = fwd if snap else r.cam_fwd.lerp(fwd, 1.0 - exp(-dt * 3.0)).normalized()
	var spd := sk.current_speed()
	var dist := 4.6 + clampf(spd - 8.0, 0.0, 6.0) * 0.16
	var want := sk.pos - r.cam_fwd * dist + Vector3.UP * 1.9
	var look := sk.pos + r.cam_fwd * 3.2 + Vector3.UP * 0.9
	if sk.mode == RSSkater.Mode.BAIL:
		want = r.cam_pos.lerp(sk.pos - r.cam_fwd * 5.5 + Vector3.UP * 2.6, 0.02)
		look = sk.pos + Vector3.UP * 0.5
	elif sk.finished and spd < 2.0:
		r.orbit += dt * 0.35
		want = sk.pos + Vector3(sin(r.orbit) * 4.0, 1.7, cos(r.orbit) * 4.0)
		look = sk.pos + Vector3.UP * 0.9
	want.x = clampf(want.x, -RSSkateCourse.BOUND + 0.6, RSSkateCourse.BOUND - 0.6)
	want.y = maxf(want.y, _course.top(want.x, -want.z) + 0.8)
	if snap:
		r.cam_pos = want
		r.cam_look = look
	else:
		var ky := 1.0 - exp(-dt * 4.0)
		r.cam_pos = Vector3(lerpf(r.cam_pos.x, want.x, k), lerpf(r.cam_pos.y, want.y, ky), lerpf(r.cam_pos.z, want.z, k))
		r.cam_look = r.cam_look.lerp(look, minf(k * 1.4, 1.0))
	r.shake = maxf(r.shake - dt * 1.6, 0.0)
	var jitter := Vector3(_rng.randf() - 0.5, _rng.randf() - 0.5, _rng.randf() - 0.5) * r.shake * 0.35
	# Consume the same RNG values so this visual option cannot change gameplay.
	if not RSSettings.camera_shake:
		jitter = Vector3.ZERO
	p.cam.global_position = r.cam_pos + jitter
	if p.cam.global_position.distance_to(r.cam_look) > 0.1:
		p.cam.look_at(r.cam_look + jitter * 0.5)
	p.cam.fov = lerpf(p.cam.fov, 66.0 + clampf(spd - 6.0, 0.0, 10.0) * 1.3, 1.0 if snap else 1.0 - exp(-dt * 2.0))
	if phase == Phase.COUNTDOWN and phase_time < INTRO:
		# Intro: from high over the start, looking down the street to the sea, swooping in
		# behind the rider.
		var p0 := sk.pos + Vector3(0.0, 26.0, 36.0)
		var p1 := sk.pos + Vector3(5.0 * signf(sk.pos.x + 0.01), 5.0, 13.0)
		RSIntro.apply(p.cam, phase_time, INTRO, p0, p1, r.cam_pos,
			sk.pos + Vector3(0.0, -8.0, -120.0), r.cam_look, 50.0, 66.0)


# ------------------------------------------------------------------- hints / OLED ----

func _hints(p: Player, r: Rider, dt: float) -> void:
	r.hint_t -= dt
	if p.fake or r.hint_t > 0.0:
		return
	var sk := r.sk
	if phase_time < 0.5:
		_hint(r, "start", 1, tr("左右倾斜 = 转向　快速往上一抬 = 起跳　B = 蹬地加速"), 6.0)
	elif sk.mode == RSSkater.Mode.AIR and sk.air_t > 0.12 and sk.vel.y > -2.0:
		_hint(r, "air", 3, tr("空中：左右一甩 = 翻板　水平转动 = 转体　按住 B = 抓板"), 3.0)
	elif sk.mode == RSSkater.Mode.GRIND:
		_hint(r, "grind", 2, tr("磨杆中：左右倾斜，让指针保持在中间"), 3.0)
	elif sk.mode == RSSkater.Mode.MANUAL:
		_hint(r, "manual", 2, tr("Manual：前后微调手柄，让指针保持在中间"), 3.0)
	elif sk.mode == RSSkater.Mode.RIDE:
		var s := sk.s()
		for rail in _course.rails:
			if rail.name != "Curb" and -rail.a.z > s + 5.0 and -rail.a.z < s + 16.0 and absf(rail.a.x - sk.pos.x) < 2.5:
				_hint(r, "rail", 2, tr("前面有栏杆：对准它、快到时起跳就能磨杆"), 3.0)
				return
		for f in _course.features:
			if f["type"] == "pad" and s > f["s0"] - 6.0 and s < f["s0"] and absf(f["x"] - sk.pos.x) < f["w"] * 0.5:
				_hint(r, "pad", 1, tr("台子上试试：把手柄往后仰 = Manual（翘头平衡）"), 3.0)
				return


func _hint(r: Rider, key: String, times: int, text: String, dur: float) -> void:
	var n: int = r.hints_seen.get(key, 0)
	if n >= times:
		return
	r.hints_seen[key] = n + 1
	r.hint = text
	r.hint_t = dur


func _update_oled(p: Player, r: Rider, dt: float) -> void:
	r.oled_t -= dt
	if r.oled_t > 0.0:
		return
	var sk := r.sk
	var letters := ""
	for i in 5:
		letters += LETTERS[i] if sk.letters[i] else "_"
	var main := str(p.score)
	var sub := "%d KM/H" % roundi(sk.current_speed() * 3.6)
	if not sk.combo.is_empty():
		main = "%dx%d" % [sk.combo_base(), sk.combo.size()]
		sub = str(sk.combo[-1]["name"]).to_upper()
	elif sk.finished:
		sub = "FINISH #%d" % r.place
	elif sk.mode == RSSkater.Mode.BAIL:
		sub = "BAIL!"
	var key := "%s|%s|%s" % [letters, main, sub]
	if key == p.oled_key:
		return
	p.oled_key = key
	r.oled_t = 0.15
	send_ui(p, {"title": "SKATE " + letters, "main": main, "sub": sub})


# ---------------------------------------------------------------------------- HUD ----

func _draw_hud(h: PlayerHud, p: Player, k: float) -> void:
	var r := _rider(p)
	var sk := r.sk
	var sz := h.size
	var col := color_of(p)
	if phase == Phase.RESULTS:
		_draw_replay(h, p, k)
		return
	if phase == Phase.COUNTDOWN and phase_time < INTRO:
		return

	# S-K-A-T-E under the score.
	for i in 5:
		var box := Rect2(Vector2(20 + i * 31, 66) * k, Vector2(27, 27) * k)
		var got: bool = sk.letters[i]
		h.draw_rect(box, col if got else Color(0, 0, 0, 0.35))
		draw_text(h, LETTERS[i], box.position + Vector2(13.5, 21) * k, 19 * k, Color.WHITE if got else Color(1, 1, 1, 0.35), true)

	# Run progress: everyone's position on the way to the finish.
	var bar := Rect2(Vector2(sz.x - 250 * k, 30 * k), Vector2(220 * k, 8 * k))
	h.draw_rect(bar, Color(0, 0, 0, 0.35))
	for q: Player in players.values():
		var f := clampf(_rider(q).sk.s() / RSSkateCourse.FINISH_S, 0.0, 1.0)
		var at := bar.position + Vector2(bar.size.x * f, bar.size.y * 0.5)
		h.draw_circle(at, (8.0 if q == p else 5.0) * k, color_of(q))
		if q == p:
			h.draw_arc(at, 8.0 * k, 0, TAU, 20, Color.WHITE, 2.0 * k, true)
	h.draw_rect(Rect2(bar.end - Vector2(0, 14 * k), Vector2(3 * k, 16 * k)), Color.WHITE)
	var to_go := maxi(0, roundi(RSSkateCourse.FINISH_S - sk.s()))
	draw_text(h, tr("终点 %d m") % to_go if not sk.finished else tr("已到终点"), bar.position + Vector2(bar.size.x, 32 * k), 15 * k, Color(0.92, 0.95, 1.0), false, true)

	draw_text(h, "%d km/h" % roundi(sk.current_speed() * 3.6), Vector2(20 * k, sz.y - 20 * k), 18 * k, Color(0.92, 0.95, 1.0))

	# Speed lines at the screen edges when going fast.
	var fast := clampf((sk.current_speed() - 9.0) / 6.0, 0.0, 1.0)
	if fast > 0.0 and phase == Phase.PLAY:
		var c := sz * 0.5
		for i in 18:
			var a := TAU * i / 18.0 + float(int(_clock * 20.0) % 7) * 0.13
			var d := Vector2(cos(a), sin(a))
			var r0 := sz.length() * (0.36 + 0.04 * sin(_clock * 13.0 + i))
			h.draw_line(c + d * r0, c + d * (r0 + 60 * k), Color(1, 1, 1, 0.12 * fast), 2.0 * k)

	# Balance meter above the rider while grinding or in a manual.
	if sk.mode in [RSSkater.Mode.GRIND, RSSkater.Mode.MANUAL]:
		var head := sk.pos + Vector3.UP * 2.35
		if not p.cam.is_position_behind(head):
			_draw_balance(h, p.cam.unproject_position(head), 58 * k, sk.needle, k)

	# The combo being built, or the one just banked.
	var y := sz.y - 64 * k
	if not sk.combo.is_empty():
		var names := PackedStringArray()
		for e in sk.combo:
			names.append(str(e["name"]))
		draw_text(h, _trick_line(names), Vector2(sz.x * 0.5, y - 40 * k), 21 * k, Color.WHITE, true)
		var pulse := 1.0 + 0.04 * sin(_clock * 12.0)
		draw_text(h, "%s × %d" % [_fmt(sk.combo_base()), sk.combo.size()], Vector2(sz.x * 0.5, y), 38 * k * pulse, GOLD, true)
	elif _clock - r.banked_t < 1.6:
		var a := clampf(1.6 - (_clock - r.banked_t), 0.0, 1.0)
		var c1 := Color(1.0, 0.7, 0.35, a) if r.banked_sketchy else Color(GOLD, a)
		draw_text(h, r.banked_names, Vector2(sz.x * 0.5, y - 40 * k), 19 * k, Color(1, 1, 1, a * 0.85), true)
		draw_text(h, (tr("勉强落地  +%s") if r.banked_sketchy else "+%s") % _fmt(r.banked_pts), Vector2(sz.x * 0.5, y), 44 * k, c1, true)

	if r.hint_t > 0.0 and not sk.finished:
		var a := clampf(r.hint_t, 0.0, 1.0)
		draw_pill(h, r.hint, Vector2(sz.x * 0.5, sz.y * 0.2), 17 * k, Color(1, 1, 1, a))

	if sk.finished:
		draw_text(h, tr("完成！第 %d 名") % r.place if players.size() > 1 else tr("完成！"), Vector2(sz.x * 0.5, sz.y * 0.3), 46 * k, GOLD, true)
		var waiting := false
		for q: Player in players.values():
			waiting = waiting or not _rider(q).sk.finished
		if waiting and phase == Phase.PLAY:
			draw_text(h, tr("等其他玩家到终点…"), Vector2(sz.x * 0.5, sz.y * 0.3 + 40 * k), 20 * k, Color(0.92, 0.95, 1.0), true)


func _draw_balance(h: Control, at: Vector2, radius: float, needle: float, k: float) -> void:
	## Arc from left (-1) to right (+1) over the top, green in the middle, red at the ends.
	var a0 := PI * 1.2
	var a1 := PI * 1.8
	var segs := 12
	for i in segs:
		var t0 := float(i) / segs
		var t1 := float(i + 1) / segs
		var mid := absf((t0 + t1) - 1.0)
		var c := Color(0.3, 0.9, 0.45).lerp(Color(1.0, 0.85, 0.2), clampf(mid * 2.0, 0.0, 1.0)).lerp(Color(1.0, 0.3, 0.25), clampf(mid * 2.0 - 1.0, 0.0, 1.0))
		h.draw_arc(at, radius, lerpf(a0, a1, t0), lerpf(a0, a1, t1), 4, c, 7.0 * k, true)
	var na := lerpf(a0, a1, clampf(needle, -1.0, 1.0) * 0.5 + 0.5)
	var tip := at + Vector2(cos(na), sin(na)) * (radius + 8 * k)
	h.draw_line(at + Vector2(cos(na), sin(na)) * (radius - 14 * k), tip, Color.WHITE, 4.0 * k, true)
	h.draw_circle(tip, 4.0 * k, Color.WHITE)


func _draw_overlay(o: Overlay, k: float) -> void:
	if phase == Phase.COUNTDOWN and phase_time < INTRO:
		var a := RSIntro.fade(phase_time, INTRO)
		draw_text(o, tr("海滨大坡"), Vector2(o.size.x * 0.5, o.size.y * 0.4), 84 * k, Color(1, 1, 1, a), true)
		draw_text(o, tr("SEASIDE DOWNHILL  ·  %d 米滑到海边") % roundi(RSSkateCourse.FINISH_S - RSSkateCourse.START_S),
			Vector2(o.size.x * 0.5, o.size.y * 0.4 + 56 * k), 24 * k, Color(1, 0.9, 0.6, a), true)
	elif phase == Phase.COUNTDOWN:
		draw_text(o, tr("倾斜手柄转向，快速往上一抬就能起跳"), Vector2(o.size.x * 0.5, o.size.y * 0.45 + 60 * k), 26 * k, Color(0.92, 0.95, 1.0), true)
	elif phase == Phase.PLAY:
		draw_clock(o, _time_left, k)
	elif phase == Phase.RESULTS and _podium_on:
		_draw_podium_tags(o, k)


# ------------------------------------------------------------------------ replays ----

func _record(r: Rider, dt: float) -> void:
	var rig := r.sk.rig
	RSReplay.record(r.rec, {"t": _clock, "xf": rig.global_transform, "imp": rig.impacts, "in": [rig.crouch, rig.lean,
		rig.yaw, rig.flip, rig.board_pitch, rig.board_lift, rig.feet_lift, rig.arms, rig.balance, rig.push,
		rig.grab, rig.wheel_speed]}, CLIP_MAX + PRE_ROLL + POST_ROLL + 1.0)
	rig.impacts = 0.0
	if r.post >= 0.0:
		r.pend.append(r.rec.back())
		r.post -= dt
		if r.post < 0.0:
			_keep_clip(r)
	if r.sk.combo.is_empty():
		r.combo_from = _clock


func _keep_clip(r: Rider) -> void:
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
		var r := _rider(p)
		if r.post >= 0.0:
			_keep_clip(r)
		longest = maxf(longest, RSReplay.duration(r.clip) / SLOW)
		r.replay.reset(r.clip)
		r.sk.quiet()
		r.sk.rig.end_bail()
		if r.clip.size() > 1:
			r.sk.rig.set_layers(1 << p.c.player)
			# The replay camera runs alongside, on the side with more street.
			var a: Vector3 = (r.clip[0]["xf"] as Transform3D).origin
			var b: Vector3 = (r.clip.back()["xf"] as Transform3D).origin
			var travel := Vector3(b.x - a.x, 0.0, b.z - a.z)
			travel = travel.normalized() if travel.length() > 0.5 else Vector3.FORWARD
			r.rp_side = travel.cross(Vector3.UP).normalized()
			if signf(r.rp_side.x) == signf((a.x + b.x) * 0.5) and absf(a.x + b.x) > 2.0:
				r.rp_side = -r.rp_side
			r.cam_pos = a + r.rp_side * 3.6 + Vector3.UP * 1.0
			r.cam_look = a + Vector3.UP * 0.8
	_podium_at = RSReplay.lead_out(longest, 8.5)
	results_delay = _podium_at + 1.6
	_podium_on = false
	super.finish_round()


func _replay_step(p: Player, delta: float) -> void:
	var r := _rider(p)
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
				RSSfx.play(self, "land", -14.0 + r.sk.gain_db, 0.7)
		crossed += 1
	var fa := r.replay.a
	var fb := r.replay.b
	var u := r.replay.weight
	rig.global_transform = (fa["xf"] as Transform3D).interpolate_with(fb["xf"], u)
	var ia: Array = fa["in"]
	var ib: Array = fb["in"]
	rig.crouch = lerpf(ia[0], ib[0], u)
	rig.lean = lerpf(ia[1], ib[1], u)
	rig.yaw = lerpf(ia[2], ib[2], u)
	rig.flip = lerpf(ia[3], ib[3], u)
	rig.board_pitch = lerpf(ia[4], ib[4], u)
	rig.board_lift = lerpf(ia[5], ib[5], u)
	rig.feet_lift = lerpf(ia[6], ib[6], u)
	rig.arms = lerpf(ia[7], ib[7], u)
	rig.balance = lerpf(ia[8], ib[8], u)
	rig.push = ia[9]
	rig.grab = ia[10]
	rig.wheel_speed = lerpf(ia[11], ib[11], u)
	rig.update(delta * SLOW)
	# Tracking shot: alongside and a little ahead, looking back at the rider.
	var at := rig.global_position
	var fwd := ((fb["xf"] as Transform3D).origin - (fa["xf"] as Transform3D).origin)
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 1e-3 else -r.rp_side.cross(Vector3.UP)
	var want := at + r.rp_side * 3.4 + fwd * 1.2 + Vector3.UP * 0.9
	want.x = clampf(want.x, -RSSkateCourse.BOUND + 0.6, RSSkateCourse.BOUND - 0.6)
	want.y = maxf(want.y, _course.top(want.x, -want.z) + 0.6)
	var k := 1.0 - exp(-delta * 3.0)
	r.cam_pos = r.cam_pos.lerp(want, k)
	r.cam_look = r.cam_look.lerp(at + Vector3.UP * 0.8, minf(k * 2.0, 1.0))
	p.cam.global_position = r.cam_pos
	p.cam.look_at(r.cam_look)
	p.cam.fov = lerpf(p.cam.fov, 52.0, k)


func _draw_replay(h: PlayerHud, p: Player, k: float) -> void:
	var r := _rider(p)
	var sz := h.size
	var bar := maxf(sz.y * 0.08, 64.0 * k)   # covers the score badge
	h.draw_rect(Rect2(Vector2.ZERO, Vector2(sz.x, bar)), Color(0.02, 0.02, 0.03))
	h.draw_rect(Rect2(Vector2(0, sz.y - bar), Vector2(sz.x, bar)), Color(0.02, 0.02, 0.03))
	draw_text(h, "P%d" % p.c.player, Vector2(20 * k, bar * 0.5 + 9 * k), 24 * k, color_of(p))
	if r.clip.size() < 2:
		draw_text(h, tr("这局没有成功落地的连招"), Vector2(sz.x * 0.5, sz.y - bar * 0.5 + 8 * k), 22 * k, Color(0.92, 0.95, 1.0), true)
		return
	if fmod(_clock, 1.0) < 0.6:
		h.draw_circle(Vector2(sz.x - 150 * k, bar * 0.5), 7 * k, Color(1.0, 0.25, 0.2))
	draw_text(h, "REPLAY", Vector2(sz.x - 136 * k, bar * 0.5 + 8 * k), 22 * k, Color.WHITE)
	draw_text(h, tr("最佳连招  ") + r.clip_names, Vector2(sz.x * 0.5, sz.y - bar - 44 * k), 22 * k, Color.WHITE, true)
	draw_text(h, "+" + _fmt(r.clip_pts), Vector2(sz.x * 0.5, sz.y - bar - 8 * k), 40 * k, GOLD, true)


# ------------------------------------------------------------------------- podium ----

func _build_podium() -> void:
	_podium = RSPodium.new()
	_podium.position = _course.world(0.0, PODIUM_S, 0.0)
	add_child(_podium)
	_podium.configure(PODIUM, Vector2(1.3, 1.2), Vector3(2.4, 0, 0.6), 0.9, font, 0.0)


func _podium_spot(i: int) -> Vector3:
	var at := _podium.spot(i)
	return at


func _podium_start() -> void:
	_podium_on = true
	views.visible = false
	lobby_cam.current = true
	lobby_cam.fov = 42.0
	# The results panel sits on the right half; the podium is framed on the left.
	ui.results_on_right(true)
	_podium_order = ranked_players()
	var scores := PackedInt64Array()
	for p: Player in _podium_order:
		scores.append(p.score)
	_podium.present(scores)
	for i in _podium_order.size():
		var rig := _rider(_podium_order[i]).sk.rig
		rig.set_layers(1)
		rig.end_bail()
		rig.board.visible = false
		rig.global_transform = Transform3D(Basis(Vector3.UP, -PI * 0.5), _podium_spot(i) - Vector3(0, RSSkaterRig.DECK_Y, 0))
		rig.crouch = 0.05
		rig.lean = 0.0
		rig.yaw = 0.0
		rig.flip = 0.0
		rig.board_pitch = 0.0
		rig.board_lift = 0.0
		rig.feet_lift = 0.0
		rig.arms = 0.1
		rig.balance = 0.0
		rig.push = -1.0
		rig.grab = 0
		rig.wheel_speed = 0.0
		rig.cheer = _podium.cheer(i)
	RSSfx.play(self, "chime", -4.0)


func _podium_step(delta: float) -> void:
	_podium.apply_camera(lobby_cam, phase_time - _podium_at, 1.6, -0.12, 8.5, -0.3, 1.7, 1.75, 1.35)
	_podium.fit_left(lobby_cam)
	for p: Player in players.values():
		_rider(p).sk.rig.update(delta)
	_crowd.volume_db = lerpf(_crowd.volume_db, -9.0, 1.0 - exp(-delta * 1.5))


func _draw_podium_tags(o: Overlay, k: float) -> void:
	for i in _podium_order.size():
		var p: Player = _podium_order[i]
		var head := _podium_spot(i) + Vector3.UP * 2.0
		if lobby_cam.is_position_behind(head):
			continue
		var at := lobby_cam.unproject_position(head)
		draw_pill(o, "P%d" % p.c.player, at, 20 * k, color_of(p))
