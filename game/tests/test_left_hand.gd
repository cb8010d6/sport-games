extends Node
## Compare mirrored physical samples through shared gestures and six real game scenes.
## The runner isolates profiles and optionally captures the player-settings page.

var _checks := 0
var _failures := 0
var _scene: Variant


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


func _frames(count := 8) -> void:
	for _i in count:
		await get_tree().process_frame


func _controller(slot: int) -> RSController:
	var c := RSController.new()
	c.player = slot
	c.connected = true
	c.kind = "phone"
	return c


func _sample(c: RSController, q: Quaternion, gyro := Vector3.ZERO) -> void:
	c.push_sample(c.sample_time + 0.02, q, gyro, Vector3.UP * 9.8, Vector3.ZERO)


func _profiles() -> void:
	for slot in range(1, 5):
		_check(not RSProfiles.left_handed(slot), "legacy profile defaults to right hand")
	_check(RSProfiles.update(1, "P1", 0, 0, 1) == OK, "left preference saves")
	RSProfiles._loaded = false
	_check(RSProfiles.left_handed(1) and not RSProfiles.left_handed(2), "profiles round trip independently")
	RSProfiles.update(1, "P1", 0, 0)
	_check(RSProfiles.left_handed(1), "four-argument update preserves handedness")
	_check(RSProfiles.update(1, "Bad", 0, 0, 2) == ERR_INVALID_PARAMETER and RSProfiles.player_name(1) == "P1", "invalid hand does not mutate profile")
	_check(not RSProfiles.left_handed(0) and not RSProfiles.left_handed(5), "unassigned/invalid slots remain right handed")
	var cf := ConfigFile.new()
	cf.load(RSProfiles.PATH)
	cf.set_value("2", "left_handed", "true")
	RSSave.write(RSProfiles.PATH, cf)
	RSProfiles._loaded = false
	_check(not RSProfiles.left_handed(2), "invalid saved type does not enable mirroring")


func _math() -> void:
	var left := _controller(1)
	var right := _controller(2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 731
	var mirror := Basis(Vector3(-1, 0, 0), Vector3.UP, Vector3.BACK)
	for _i in 24:
		var q := Quaternion.from_euler(Vector3(rng.randf_range(-2, 2), rng.randf_range(-2, 2), rng.randf_range(-2, 2)))
		var g := Vector3(rng.randf_range(-8, 8), rng.randf_range(-8, 8), rng.randf_range(-8, 8))
		_sample(left, q, g)
		_sample(right, q, g)
		_check(Basis(left.motion_orientation()).is_equal_approx(mirror * Basis(q) * mirror), "pose equals M R M")
		var world := q * g
		_check((left.motion_orientation() * left.motion_gyro(g)).is_equal_approx(Vector3(world.x, -world.y, -world.z)), "world angular velocity reflects axially")
		_check(left.motion_gyro(g).length_squared() == g.length_squared(), "mirroring preserves swing speed")
		_check(right.motion_orientation() == q and right.motion_gyro(g) == g, "right-hand input unchanged")
		_check(left.orientation == q and left.gyro == g and left.hist_quat[left.history_index(0)] == q, "raw sample/history unchanged")
		_check(is_equal_approx(left.motion_roll(), -right.motion_roll()), "roll reverses")
	var a := RSMotionGestures.new()
	var b := RSMotionGestures.new()
	left = _controller(1)
	right = _controller(2)
	a.capture(left.motion_orientation())
	b.capture(right.motion_orientation())
	var out_left := RSMotionControls.new()
	var out_right := RSMotionControls.new()
	var roll := Quaternion(Vector3.FORWARD, 0.5)
	_sample(left, roll, Vector3(0, 2, -8))
	_sample(right, roll, Vector3(0, 2, -8))
	a.read(left, out_left)
	b.read(right, out_right)
	_check(out_left.steer < 0 and out_right.steer > 0 and is_equal_approx(out_left.steer, -out_right.steer), "steering mirrors")
	_check(out_left.flip == -out_right.flip and out_right.flip != 0, "sideways flick mirrors")
	_check(is_equal_approx(out_left.yaw_delta, -out_right.yaw_delta) and out_right.yaw_delta != 0, "turning mirrors")
	a.read(left, out_left)
	_check(out_left.flip == 0 and out_left.yaw_delta == 0, "history is not consumed twice")
	var jump_left := 0.0
	var jump_right := 0.0
	for _i in 5:
		_sample(left, Quaternion(Vector3.RIGHT, 0.4), Vector3(8, 0, 0))
		_sample(right, Quaternion(Vector3.RIGHT, 0.4), Vector3(8, 0, 0))
		a.read(left, out_left)
		b.read(right, out_right)
		jump_left = maxf(jump_left, out_left.ollie)
		jump_right = maxf(jump_right, out_right.ollie)
	_check(is_equal_approx(out_left.pitch, out_right.pitch), "fore/aft tilt unchanged")
	_check(jump_left == jump_right and jump_left > 0, "upward flick timing and strength unchanged")
	for entry: Dictionary in RSCatalog.games():
		var id: String = entry["id"]
		if RSCatalog.lessons(id).is_empty() or RSCatalog.lessons(id)[0] != "TILT_RIGHT":
			continue   # this check starts from a lesson that opens with the right tilt
		var c := _controller(1)
		var lesson := RSTutorial.new(id)
		lesson.start(c)
		_check(lesson.instruction() == tr("向左倾斜手柄，并保持片刻"), "left-hand tutorial instruction")
		lesson.update(c, RSTutorial.DEMO_SECONDS + 0.01)
		_sample(c, Quaternion(Vector3.FORWARD, 0.5))
		lesson.update(c, 0.31)
		_check(lesson.index == 0, "wrong physical direction rejected in left-hand lesson")
		_sample(c, Quaternion(Vector3.FORWARD, -0.5))
		lesson.update(c, 0.31)
		_check(lesson.index == 1, "mirrored physical direction completes left-hand lesson")


func _players_page() -> void:
	_scene = (load("res://scenes/menu/main_menu.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(_scene)
	get_tree().current_scene = _scene
	for i in _scene.entries.size():
		if _scene.entries[i].get("page", "") == "players":
			_scene._open(i)
			break
	await _frames()
	var rows := 0
	for row: Node in _scene._pages._col.get_children():
		if not row is HBoxContainer or row.get_child_count() != 6 or not row.get_child(4) is OptionButton:
			continue
		rows += 1
		var hand := row.get_child(4) as OptionButton
		hand.select(1 if rows % 2 else 0)
		(row.get_child(5) as Button).pressed.emit()
		_check(RSProfiles.left_handed(rows) == (rows % 2 == 1), "player row saves its own hand")
		var end: float = row.get_global_rect().position.x
		for item: Control in row.get_children():
			_check(Rect2(Vector2.ZERO, Vector2(1600, 900)).encloses(item.get_global_rect()), "player row control stays on screen")
			_check(item.global_position.x >= end, "player row controls do not overlap")
			end = item.get_global_rect().end.x
	_check(rows == 4, "four independently editable handedness rows")
	var output := OS.get_environment("RS_HAND_SCREENSHOT")
	if not output.is_empty():
		await _frames()
		await RenderingServer.frame_post_draw
		_check(get_viewport().get_texture().get_image().save_png(output) == OK, "player settings screenshot saved")


func _game(id: String) -> void:
	for slot in range(1, 5):
		RSProfiles.update(slot, "P%d" % slot, slot - 1, slot - 1, 1 if slot % 2 else 0)
	_scene = (load(RSCatalog.find_game(id)["scene"]) as PackedScene).instantiate()
	get_tree().root.add_child(_scene)
	get_tree().current_scene = _scene
	for _i in 1800:
		await get_tree().process_frame
		if _scene.phase == RSPartyGame.Phase.PLAY:
			break
	_check(_scene.phase == RSPartyGame.Phase.PLAY, "game reaches play")
	var results: Array[Vector2] = []
	for p: RSPartyGame.Player in _scene.ordered():
		p.fake = false
		p.c = _controller(p.c.player)
		match id:
			"plane":
				_scene._player_ready(p, true)
				p.c.orientation = Quaternion(Vector3.FORWARD, 0.5) * Quaternion(Vector3.RIGHT, 0.2)
				results.append(_scene._read_stick(p))
			"archery":
				_scene._capture_aim(p)
				p.c.orientation = Quaternion(Vector3.UP, 0.25) * Quaternion(Vector3.RIGHT, 0.1)
				_scene._archer(p).drawing = false
				_scene._update_view(p, 0.1)
				var aim: Vector3 = _scene._archer(p).aim
				results.append(Vector2(aim.x, aim.y))
			"bowling":
				_scene._start_swing(p)
				p.c.orientation = Quaternion(Vector3.FORWARD, 0.35) * Quaternion(Vector3.RIGHT, 0.4)
				_scene._track_swing(p)
				results.append(Vector2(_scene._twist(p), _scene._bowler(p).swing_angle))
			"basketball":
				var shooter: Variant = _scene._sh(p)
				shooter.set_yaw = _scene._heading(p.c.motion_orientation())
				for _sample_i in 20:
					_sample(p.c, Quaternion(Vector3.UP, 0.2), Vector3(_scene.P_IDEAL, 0, 0))
				shooter.rel_t = p.c.sample_time
				_scene._read_flick(p, shooter)
				results.append(Vector2(shooter.lat_raw, shooter.e_raw))
			"skate", "ski":
				_scene._player_ready(p, true)
				_sample(p.c, Quaternion(Vector3.FORWARD, 0.5) * Quaternion(Vector3.RIGHT, 0.2), Vector3(0, 0, -8))
				var rider: Variant = _scene._rider(p) if id == "skate" else _scene._racer(p)
				var motion := RSMotionControls.new()
				rider.gest.read(p.c, motion)
				results.append(Vector2(motion.steer, motion.pitch))
	for index in range(0, results.size(), 2):
		_check(absf(results[index].x) > 0.01, id + " receives nonzero real gesture input")
		_check(is_equal_approx(results[index].x, -results[index + 1].x), id + " mirrors lateral input per player")
		_check(is_equal_approx(results[index].y, results[index + 1].y), id + " preserves vertical input/power")


func _run() -> void:
	get_tree().root.size = Vector2i(1600, 900)
	get_tree().current_scene = null
	if OS.get_environment("RS_HAND_VERIFY") == "1":
		for slot in range(1, 5):
			_check(RSProfiles.left_handed(slot) == (slot % 2 == 1), "hand preferences survive a new process")
	else:
		var id := OS.get_environment("RS_HAND_GAME")
		if id.is_empty():
			_profiles()
			_math()
			await _players_page()
		else:
			await _game(id)
	if is_instance_valid(_scene):
		get_tree().current_scene = null
		_scene.queue_free()
	await get_tree().process_frame
	print("RS_LEFT_HAND: %d checks, %d failures" % [_checks, _failures])
	RSExit.quit(get_tree(), 1 if _failures else 0)
