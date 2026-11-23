extends Node
## Independent timeline checks and real scene recording/playback with isolated bots.

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


func _frames(count := 6) -> void:
	for _i in count:
		await get_tree().process_frame


func _expected(clip: Array, elapsed: float, speed: float) -> Array:
	var time := float(clip[0]["t"]) + clampf(elapsed * maxf(speed, 0), 0, float(clip.back()["t"]) - float(clip[0]["t"]))
	var index := 0
	for i in clip.size():
		if float(clip[i]["t"]) <= time:
			index = i
	var next := mini(index + 1, clip.size() - 1)
	var weight := clampf((time - float(clip[index]["t"])) / maxf(float(clip[next]["t"]) - float(clip[index]["t"]), 0.0001), 0, 1)
	return [index, next, weight]


func _math() -> void:
	var frames: Array = []
	for i in 1000:
		RSReplay.record(frames, {"t": i / 50.0, "id": i}, 1.0)
		_check(float(frames.back()["t"]) - float(frames[0]["t"]) <= 1.000001, "recording retains only its time window")
	_check(frames.size() <= 51, "long recording remains bounded")
	var cut := RSReplay.since(frames, 19.5)
	_check(cut.size() == 25 and cut[0]["id"] == 975, "clip selection includes the exact start timestamp")
	cut.clear()
	_check(not frames.is_empty(), "clip container does not alias the rolling recording")
	_check(RSReplay.since(frames, 100).is_empty(), "future clip selection is empty")
	_check(is_equal_approx(RSReplay.duration(frames), 1.0), "recording duration is in game seconds")
	for sample in 16:
		var clip: Array = []
		var time := 1000.0 + sample
		for i in 2 + sample % 7:
			clip.append({"t": time, "id": i})
			time += 0.0 if sample % 3 == 0 and i % 2 == 0 else 0.05 + 0.1 * (i % 3)
		for speed: float in [-1.0, 0.0, 0.4, 0.45, 1.0, 2.0]:
			var replay := RSReplay.new()
			replay.reset(clip)
			var previous := 0
			for elapsed: float in [-1.0, 0.0, 0.11, 0.25, 1.0, 2.0, 10.0, 1000.0]:
				_check(replay.sample(elapsed, speed), "multi-frame clip is available")
				var expected := _expected(clip, elapsed, speed)
				_check(replay.index == expected[0] and replay.a["id"] == expected[0] and replay.b["id"] == expected[1], "frame pair matches an independent timestamp search")
				_check(is_equal_approx(replay.weight, expected[2]), "interpolation handles irregular and duplicate timestamps")
				_check(replay.crossed_from == previous + 1, "every crossed frame is reported exactly once, including large jumps")
				previous = replay.index
	var replay := RSReplay.new()
	var clip: Array = [{"t": 10.0}, {"t": 11.0}, {"t": 12.0}, {"t": 13.0}]
	replay.reset(clip)
	replay.sample(3, 1)
	replay.sample(1.5, 1)
	_check(replay.index == 1 and replay.crossed_from == 2 and replay.weight == 0.5, "backward seek updates pose without replaying events")
	replay.sample(2.5, 1)
	_check(replay.index == 2 and replay.crossed_from == 2, "playback resumes normally after a seek")
	replay.sample(2.5, 1)
	_check(replay.crossed_from > replay.index, "frozen playback does not repeat impacts")
	var other := RSReplay.new()
	other.reset(clip)
	other.sample(0.5, 1)
	_check(other.index == 0 and replay.index == 2, "players own independent cursors")
	replay.reset([])
	_check(not replay.sample(1, 1) and replay.a.is_empty() and replay.b.is_empty() and replay.index == 0, "reset releases the previous clip and pose")
	replay.reset([{"t": 1.0}])
	_check(not replay.sample(1, 1), "one frame has no replay")
	_check(RSReplay.duration([]) == 0 and RSReplay.duration([{"t": 1.0}]) == 0, "empty and one-frame clips have zero duration")
	_check(RSReplay.lead_out(0, 9) == 0 and RSReplay.lead_out(-1, 9) == 0, "missing clips skip straight to the podium")
	_check(is_equal_approx(RSReplay.lead_out(20, 8.5), 8.8) and is_equal_approx(RSReplay.lead_out(20, 9), 9.3), "sports retain their existing replay caps and tail")
	_check(is_equal_approx(RSReplay.lead_out(2, 9), 2.3), "short clips retain their natural duration")
	RSReplay.record(frames, {"t": 30.0}, -1)
	_check(frames.size() == 1, "negative recording window retains only the current timestamp")


func _state(id: String, p: RSPartyGame.Player) -> Variant:
	match id:
		"skate": return _scene._rider(p)
		"ski": return _scene._racer(p)
		_: return _scene._sh(p)


func _rig(id: String, state: Variant) -> Node3D:
	return state.rig if id == "basketball" else state.sk.rig


func _wait_phase(phase: int) -> void:
	for _i in 2400:
		await get_tree().process_frame
		if _scene.phase == phase:
			return
	_check(false, "real game reaches requested phase")


func _pose(id: String, p: RSPartyGame.Player) -> void:
	var state: Variant = _state(id, p)
	var expected := _expected(state.clip, _scene.phase_time, _scene.SLOW)
	var a: Dictionary = state.clip[expected[0]]
	var b: Dictionary = state.clip[expected[1]]
	var u: float = expected[2]
	var xf: Transform3D = (a["xf"] as Transform3D).interpolate_with(b["xf"], u)
	var rig := _rig(id, state)
	_check(rig.global_transform.is_equal_approx(xf), "recorded world transform is interpolated without physics")
	_check(state.replay.index == expected[0] and is_equal_approx(state.replay.weight, u), "sport uses its independent shared cursor")
	if id == "basketball":
		var has: bool = a["balls"].has(state.clip_ball)
		_check(state.rp_ball.visible == has, "ball visibility follows its recorded instance id")
		if has:
			var ball: Transform3D = a["balls"][state.clip_ball][0]
			if b["balls"].has(state.clip_ball):
				ball = ball.interpolate_with(b["balls"][state.clip_ball][0], u)
			_check(state.rp_ball.global_transform.is_equal_approx(ball), "ball follows its recorded arc")
	else:
		var names: Array = ["crouch", "lean", "yaw", "flip", "board_pitch", "board_lift", "feet_lift", "arms", "balance", "push", "grab", "wheel_speed"] if id == "skate" else ["crouch", "tuck", "lean", "edge", "yaw", "wedge", "grounded", "plant", "plant_side", "push", "grab", "feet_lift", "arms"]
		for i in names.size():
			var stepped: bool = names[i] in ["push", "grab", "plant", "plant_side"]
			var value: float = float(a["in"][i]) if stepped else (lerp_angle(a["in"][i], b["in"][i], u) if id == "ski" and names[i] == "yaw" else lerpf(a["in"][i], b["in"][i], u))
			_check(is_equal_approx(float(rig.get(names[i])), value), "recorded pose input " + names[i])
	_check(p.cam.global_transform.is_finite() and absf(p.cam.global_basis.determinant() - 1) < 0.001, "replay camera remains valid")


func _capture() -> void:
	var path := OS.get_environment("RS_REPLAY_SCREENSHOT")
	if path.is_empty():
		return
	await _frames()
	await RenderingServer.frame_post_draw
	_check(get_viewport().get_texture().get_image().save_png(path) == OK, "native replay screenshot saved")


func _game(id: String) -> void:
	_scene = (load(RSCatalog.find_game(id)["scene"]) as PackedScene).instantiate()
	get_tree().root.add_child(_scene)
	get_tree().current_scene = _scene
	await _wait_phase(RSPartyGame.Phase.COUNTDOWN)
	_scene.phase_time = _scene._countdown_time()
	await _wait_phase(RSPartyGame.Phase.PLAY)
	await _frames(150)
	_scene.set_process(false)
	var scores: Array = _scene.ordered().map(func(p: RSPartyGame.Player) -> int: return p.score)
	for p: RSPartyGame.Player in _scene.ordered():
		var state: Variant = _state(id, p)
		state.post = -1.0
		state.pend = []
		state.clip = RSReplay.since(state.rec, _scene._clock - 1.0)
		_check(state.clip.size() > 2, "actual gameplay records a replayable clip")
		if id == "basketball":
			state.clip_name = _scene._game_name()
			state.clip_ball = 0
			for frame: Dictionary in state.clip:
				if not frame["balls"].is_empty():
					state.clip_ball = frame["balls"].keys()[0]
					break
		else:
			state.clip_names = _scene._game_name()
	_scene.finish_round()
	_check(_scene.phase == RSPartyGame.Phase.RESULTS and _scene._podium_at > 0, "finish enters replay before podium")
	for elapsed: float in [0.0, 0.1, 0.7, 1.3, 2.1]:
		_scene.phase_time = elapsed
		for p: RSPartyGame.Player in _scene.ordered():
			_scene._replay_step(p, 0.0)
			_pose(id, p)
	# Advance the real tracking/pose smoothing at 60 Hz before checking the rendered frame.
	for p: RSPartyGame.Player in _scene.ordered():
		_state(id, p).replay.reset(_state(id, p).clip)
	for i in 91:
		_scene.phase_time = i / 60.0
		for p: RSPartyGame.Player in _scene.ordered():
			_scene._replay_step(p, 1.0 / 60.0)
	await _capture()
	var missing: Variant = _state(id, _scene.ordered().back())
	var kept: Array = missing.clip
	missing.clip = []
	missing.replay.reset(missing.clip)
	_scene._replay_step(_scene.ordered().back(), 0.0)
	_check(missing.replay.a.is_empty(), "one player can have no highlight while other players replay")
	missing.clip = kept
	missing.replay.reset(kept)
	_check(scores == _scene.ordered().map(func(p: RSPartyGame.Player) -> int: return p.score), "replay never scores again")
	_check(Engine.time_scale == 1.0, "slow motion does not alter global simulation time")
	_scene.set_process(true)
	_scene.open_pause()
	var time: float = _scene.phase_time
	var index: int = _state(id, _scene.ordered()[0]).replay.index
	var pose := _rig(id, _state(id, _scene.ordered()[0])).global_transform
	await _frames()
	_check(get_tree().paused and time == _scene.phase_time and index == _state(id, _scene.ordered()[0]).replay.index and pose == _rig(id, _state(id, _scene.ordered()[0])).global_transform, "pause freezes replay cursor and pose")
	_scene.ui.pause.close()
	_scene.phase_time = _scene._podium_at
	await _frames(2)
	_check(_scene._podium_on, "replay hands over to the real podium")
	_scene.restart_round()
	await _wait_phase(RSPartyGame.Phase.COUNTDOWN)
	_scene.set_process(false)
	for p: RSPartyGame.Player in _scene.ordered():
		var state: Variant = _state(id, p)
		_check(state.rec.is_empty() and state.clip.is_empty() and state.pend.is_empty() and state.replay.a.is_empty() and state.replay.index == 0, "restart clears recording, clip and cursor")
	_scene.finish_round()
	_check(_scene._podium_at == 0.0 and is_equal_approx(_scene.results_delay, 1.6), "all-miss round skips replay with original results delay")
	_scene.set_process(true)
	await _frames(2)
	_check(_scene._podium_on, "empty replay reaches podium without invalid indexing")


func _run() -> void:
	get_tree().root.size = Vector2i(1600, 900)
	get_tree().current_scene = null
	var id := OS.get_environment("RS_REPLAY_GAME")
	if id.is_empty():
		_math()
	else:
		await _game(id)
	get_tree().paused = false
	if is_instance_valid(_scene):
		get_tree().current_scene = null
		_scene.queue_free()
	await _frames(1)
	print("RS_REPLAY_TESTS: %d checks, %d failures" % [_checks, _failures])
	RSExit.quit(get_tree(), 1 if _failures else 0)
