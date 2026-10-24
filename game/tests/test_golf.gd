extends Node
## Rules plus real shell checks. Run through tools/test_golf.py with disposable user data.
const RuleCases := preload("res://tests/golf_rule_cases.gd")

var _game: RSGolfGame
var _checks := 0
var _failures := 0


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


func _run() -> void:
	var invalid := OS.get_environment("RS_GOLF_INVALID_DELTA")
	if not invalid.is_empty():
		var probe := RSGolfGame.new()
		probe._play_process(-1.0 if invalid == "negative" else NAN)
		_check(probe.hole_tick == 0 and probe._accumulator == 0.0, "invalid delta cannot create a tick")
		probe.free()
		print("RS_GOLF_INVALID_DELTA: %d checks, %d failures" % [_checks, _failures])
		get_tree().quit(1)
		return
	RuleCases.run(_check)
	var connections := ControllerHub.button_pressed.get_connections().size()
	var disconnect_connections := ControllerHub.controller_disconnected.get_connections().size()
	var roster_connections := ControllerHub.roster_changed.get_connections().size()
	_game = (load("res://scenes/golf/golf_game.tscn") as PackedScene).instantiate() as RSGolfGame
	_game.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(_game)
	Engine.max_fps = 0  # Fixed simulation delta without a monitor-dependent wall-time cap.
	_check(_game.course.hole_count() == 3 and _game._maps().size() == 2, "two maps with three holes")
	_check(_game.players.size() == _game.demo and _game.demo in [1, 2, 4], "requested demo slots")
	await _wait_phase(RSPartyGame.Phase.RESULTS, 30000)
	_check(_game.phase == RSPartyGame.Phase.RESULTS and _game.hole_index == 2, "natural demo finishes all holes")
	for p: RSPartyGame.Player in _game.players.values():
		var state := p.data as RSGolfState
		var played := state.done
		for row: Dictionary in state.rules.summary()["holes"]:
			played = played and row["strokes"] > 0
		_check(played, "every player completes three holes")
		_check(p.score == state.rules.score() and p.score > 0, "Stableford points reach common results")
		_check(not _game.can_record(p), "placeholder demo never records")
	var human := RSPartyGame.Player.new()
	human.c = RSController.new()
	human.c.kind = "phone"
	_check(not _game.can_record(human), "placeholder human also never records")
	var committed_time := _game.phase_time
	_game.finish_round()
	_check(_game.phase_time == committed_time and _game._result_committed, "result commit is idempotent")
	for slot in range(1, 5):
		_check(RSRecords.best("golf", _game.map_index, slot) == -1, "no personal best submitted")
	await _lifecycle()
	var reference: WeakRef = weakref(_game)
	for audio: AudioStreamPlayer in _game.find_children("*", "AudioStreamPlayer", true, false):
		audio.stop()
		audio.stream = null
	_game.queue_free()
	_game = null
	for frame in range(4):
		await get_tree().process_frame
	_check(reference.get_ref() == null, "scene released")
	_check(ControllerHub.button_pressed.get_connections().size() == connections, "controller signal connections released")
	_check(ControllerHub.controller_disconnected.get_connections().size() == disconnect_connections, "disconnect signal released")
	_check(ControllerHub.roster_changed.get_connections().size() == roster_connections, "roster signal released")
	# Fixed-fps test frames can outrun the real audio mixer even with the Dummy driver.
	var drain_until := Time.get_ticks_msec() + 350
	while Time.get_ticks_msec() < drain_until:
		OS.delay_msec(1)
		await get_tree().process_frame
	print("RS_GOLF_TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)


func _wait_phase(target: int, frames: int) -> void:
	for frame in range(frames):
		if _game.phase == target:
			return
		await get_tree().process_frame
	_check(false, "phase deadline")


func _lifecycle() -> void:
	_game.restart_round()
	await _wait_phase(RSPartyGame.Phase.PLAY, 400)
	var p: RSPartyGame.Player = _game.ordered()[0]
	var state := p.data as RSGolfState
	_check(_game.hole_index == 0 and state.rules.score() == 0 and state.rules.summary()["holes"][2]["strokes"] == 0, "restart clears previous round")
	var reach := state.reach_index
	_game._player_button(p, RSController.BTN_A, true)
	_check(state.reach_index != reach, "A selects placeholder distance")
	_game._player_button(p, RSController.BTN_B, false)
	_check(state.rules.stroke_count() == 0, "release without arming is ignored")
	_game._player_button(p, RSController.BTN_B, true)
	_game._player_button(p, RSController.BTN_C, true)
	_game._player_button(p, RSController.BTN_B, false)
	_check(not state.armed and not state.requested and not state.flying, "C cancels placeholder shot")
	_game._player_button(p, RSController.BTN_B, true)
	_game.open_pause()
	var elapsed := _game.hole_elapsed
	var position := state.position
	for frame in range(5):
		await get_tree().process_frame
	_check(get_tree().paused and _game.hole_elapsed == elapsed and state.position == position, "pause freezes round and ball")
	_check(not state.armed, "pause cancels pending shot")
	_game.ui.pause.close()
	_game._player_button(p, RSController.BTN_B, false)
	_check(state.rules.stroke_count() == 0, "pause release cannot launch")
	_game._player_button(p, RSController.BTN_B, true)
	_game._player_button(p, RSController.BTN_B, false)
	_game._player_button(p, RSController.BTN_B, false)
	_check(state.requested and state.rules.stroke_count() == 0, "release queues a command without advancing time")
	_game._play_process(RSGolfGame.STEP)
	_check(state.flying and state.rules.stroke_count() == 1, "one armed release launches exactly once")
	p.fake = false
	p.c.connected = false
	state.armed = true
	_game._play_process(0.01)
	_check(not state.armed and not state.requested and not p.fake, "disconnect cancels input without bot takeover")
	p.c.connected = true
	for other: RSPartyGame.Player in _game.players.values():
		other.fake = false
	_game._play_process(150.0)
	for other: RSPartyGame.Player in _game.players.values():
		var other_state := other.data as RSGolfState
		_check(other_state.done and other_state.rules.stroke_count() == int(other_state.rules.summary()["holes"][0]["par"]) + 4, "deadline caps every unfinished player")
	_check(_game.card_elapsed == 0.0, "first completed hole enters hold")
	_game._play_process(RSGolfGame.CARD_SECONDS)
	_check(_game.hole_index == 1 and _game.hole_elapsed == 0.0, "hole transition resets effective timer")
	for other: RSPartyGame.Player in _game.players.values():
		other.fake = true
	_game._to_lobby()
	for other: RSPartyGame.Player in _game.players.values():
		other.ready = false
	var old_course: WeakRef = weakref(_game.course)
	var old_world: WeakRef = weakref(_game.course.get_parent())
	var expected_map := 1 - _game.map_index
	var original_demo := _game.demo
	_game.demo = 0  # The public map picker is intentionally disabled in demo mode.
	_game.pick_map(1)
	_check(_game._pending_map == expected_map, "map picker schedules the chosen map")
	_game._apply_pending_map()
	_game.demo = original_demo
	for frame in range(2):
		await get_tree().process_frame
	_check(_game.map_index == expected_map and _game.course.map_index == expected_map, "public map picker rebuilds selected map")
	_check(old_course.get_ref() == null and old_world.get_ref() == null, "old map and environment released")
	_check(_game._world.get_child_count() == 3, "one course, sky and sun remain")
	_check(state.rules.score() == 0 and state.rules.stroke_count() == 0 and _game.hole_index == 0, "map switch clears project state")
	_disconnect_checks(p)
	_deadline_checks(p)
	_chunk_checks(p)
	_coordination_checks(p)
	var ball: WeakRef = weakref(state.ball)
	_game._remove_player(p.c.id)
	await get_tree().process_frame
	_check(ball.get_ref() == null and p.data == null, "player removal releases project state")


func _disconnect_checks(p: RSPartyGame.Player) -> void:
	_game.phase = RSPartyGame.Phase.PLAY
	for other: RSPartyGame.Player in _game.players.values():
		other.fake = false
	for roster: bool in [false, true]:
		_game._round_started(_game.ordered())
		var state := p.data as RSGolfState
		_game._player_button(p, RSController.BTN_B, true)
		_game._player_button(p, RSController.BTN_B, false)
		_check(state.requested, "disconnect race starts with queued release")
		p.c.connected = false
		if roster:
			ControllerHub.roster_changed.emit()
		else:
			ControllerHub.controller_disconnected.emit(p.c)
		p.c.connected = true  # Both Hub messages can precede the next simulation tick.
		_game._play_process(RSGolfGame.STEP)
		_check(state.rules.stroke_count() == 0 and not state.flying and not state.requested and not p.fake, "transient disconnect cancels queued release without takeover")
		_game._player_button(p, RSController.BTN_B, true)
		_game._player_button(p, RSController.BTN_B, false)
		_game._play_process(RSGolfGame.STEP)
		_check(state.rules.stroke_count() == 1 and state.flying, "reconnected player requires a fresh release")
	for other: RSPartyGame.Player in _game.players.values():
		other.fake = true


func _coordination_setup(human: RSPartyGame.Player, bot: RSPartyGame.Player, seed_value: int) -> void:
	_game.phase = RSPartyGame.Phase.PLAY
	_game._round_started(_game.ordered())
	for p: RSPartyGame.Player in _game.players.values():
		p.fake = false
		p.c.connected = true
		if p != bot:
			var state := p.data as RSGolfState
			var pin := _game.course.pin_pos(0) + Vector3.UP * RSGolfGame.BALL_RADIUS
			state.arm(0)
			state.request(0)
			state.launch(pin, pin)
			state._flight_tick = RSGolfState.FLIGHT_TICKS - 1
	_game._play_tick()  # Legal first-step contacts; the bot remains READY on the same clock.
	for p: RSPartyGame.Player in _game.players.values():
		p.fake = p != human
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var state := bot.data as RSGolfState
	state.position = _game.course.pin_pos(0) - _game.course.tee_dir(0) * rng.randf_range(80, 180)
	state.reach_index = 0


func _coordination_run(human: RSPartyGame.Player, bot: RSPartyGame.Player, seed_value: int, batched: bool) -> Dictionary:
	_coordination_setup(human, bot, seed_value)
	var calls := 0
	while _game.card_elapsed < 0.0 and calls < RSGolfRules.HOLE_TICKS:
		if batched:
			_game._play_process(RSGolfGame.STEP)  # Four unchanged fixed steps per render interval.
		else:
			_game._play_tick()  # 1x reference scheduler; same immediate-shot policy and rule clock.
		calls += 1
	var state := bot.data as RSGolfState
	_check(state.done and _game.card_elapsed == 0.0, "only the final bot terminal state opens the scorecard")
	return {"summary": state.rules.summary(), "position": state.position, "tick": _game.hole_tick, "calls": calls}


func _coordination_checks(human: RSPartyGame.Player) -> void:
	var extra_id := -9401  # synthetic demo-1 opponent, never registered in ControllerHub
	if _game.players.size() == 1:
		var controller := RSController.new()
		controller.id = extra_id
		controller.player = 2
		controller.connected = true
		controller.kind = "bot"
		_game._add_player(controller, true)
	var bot: RSPartyGame.Player = _game.ordered()[1]
	_game.phase = RSPartyGame.Phase.PLAY
	_game._round_started(_game.ordered())
	_check(not _game._humans_finished() and _game._simulation_speed() == 1.0, "pure demo never accelerates")
	human.fake = false
	_check(not _game._humans_finished() and _game._simulation_speed() == 1.0, "an unfinished human keeps the normal cadence")
	_coordination_setup(human, bot, 71)
	_check(_game._humans_finished() and _game._simulation_speed() == 4.0 and _game.card_elapsed < 0.0, "human finish enables speed without cutting off bot")
	var tick := _game.hole_tick
	_game.open_pause()
	_game._play_process(1.0)
	_check(_game.hole_tick == tick and _game._accumulator == 0.0, "pause also freezes accelerated match time")
	_game.ui.pause.close()
	_game._play_process(RSGolfGame.STEP)
	var state := bot.data as RSGolfState
	_check(state.flying and state.rules.stroke_count() == 1 and state._flight_tick == 4 and _game.hole_tick == tick + 4, "ready bot shoots on next step and advances at most4x")
	for seed_value: int in [71, 913, 2026]:
		var reference := _coordination_run(human, bot, seed_value, false)
		var fast := _coordination_run(human, bot, seed_value, true)
		_check(reference["summary"] == fast["summary"] and reference["position"] == fast["position"] and reference["tick"] == fast["tick"], "same-seed 1x and4x preserve strokes/points/landing/deadline")
		_check(fast["calls"] <= ceili(float(reference["calls"]) / 4.0), "speed changes scheduling, not fixed-step size")
	_game._play_process(RSGolfGame.CARD_SECONDS * 0.5)
	_check(_game.hole_index == 0 and _game.card_elapsed == RSGolfGame.CARD_SECONDS * 0.5, "scorecard wall time is not accelerated")
	_game._play_process(RSGolfGame.CARD_SECONDS * 0.5)
	_check(_game.hole_index == 1 and _game.hole_tick == 0 and _game._accumulator == 0.0 and _game._simulation_speed() == 1.0, "new hole clears speed transition and accumulated time")
	for left: int in [2, 3]:
		_coordination_setup(human, bot, 71)
		bot.fake = false  # Hold this READY player without bot input until the final two ticks.
		_game._play_process(float(RSGolfRules.HOLE_TICKS - 3) * RSGolfGame.STEP)
		bot.fake = true
		state = bot.data as RSGolfState
		state.arm(_game.hole_tick)
		state.request(_game.hole_tick)
		_game._shoot(bot)
		state._target = state._pin
		state._flight_tick = RSGolfState.FLIGHT_TICKS - left
		_game._play_process(RSGolfGame.STEP)
		var row: Dictionary = state.rules.summary()["holes"][0]
		_check(state.done and row["status"] == (RSGolfRules.Status.HOLED if left == 2 else RSGolfRules.Status.CAPPED), "4x contact at deadline wins; a later contact cannot score")
		_check(_game.hole_tick == RSGolfRules.HOLE_TICKS and _game._accumulator == 0.0 and _game.card_elapsed == 0.0, "4x gives no extra match time or future-hole debt")
	if _game.players.has(extra_id):
		_game._remove_player(extra_id)
	for p: RSPartyGame.Player in _game.players.values():
		p.fake = true


func _deadline_checks(p: RSPartyGame.Player) -> void:
	_game.phase = RSPartyGame.Phase.PLAY
	for other: RSPartyGame.Player in _game.players.values():
		other.fake = false
	for left: int in [3, 1, 2]:
		_game._round_started(_game.ordered())
		_game._play_process(float(RSGolfRules.HOLE_TICKS - 3) * RSGolfGame.STEP)
		var state := p.data as RSGolfState
		state.arm(_game.hole_tick)
		state.request(_game.hole_tick)
		_game._play_process(RSGolfGame.STEP)
		state._target = state._pin
		state._flight_tick = RSGolfState.FLIGHT_TICKS - left
		_game._play_process(4.0 * RSGolfGame.STEP)
		var row: Dictionary = state.rules.summary()["holes"][0]
		_check(state.done and row["status"] == (RSGolfRules.Status.CAPPED if left > 2 else RSGolfRules.Status.HOLED), "cross-frame deadline contacts before/at/after")
		var expected_tick := RSGolfRules.HOLE_TICKS - int(left == 1 and _game.players.size() == 1)
		_check(_game.hole_tick == expected_tick and _game.card_elapsed == 0.0 and _game._accumulator == 0.0, "completion consumes no future hole time")
	for other: RSPartyGame.Player in _game.players.values():
		other.fake = true


func _chunk_checks(p: RSPartyGame.Player) -> void:
	_game.phase = RSPartyGame.Phase.PLAY
	for other: RSPartyGame.Player in _game.players.values():
		other.fake = false
	var reference := Vector3.ZERO
	for fps: int in [30, 60, 144, 1]:
		_game._round_started(_game.ordered())
		var state := p.data as RSGolfState
		state.arm(0)
		state.request(0)
		for frame in range(fps * 2):
			_game._play_process(1.0 / fps)
		if fps == 30:
			reference = state.position
		_check(_game.hole_tick == 240 and state.rules.tick == 240 and state.position.is_equal_approx(reference), "frame chunks and long backlog preserve every rule step")
	_game._round_started(_game.ordered())
	_game._play_process(RSGolfGame.STEP * 0.5)
	var debt := _game._accumulator
	_game.open_pause()
	_game._play_process(10.0)
	_check(_game._accumulator == debt and _game.hole_tick == 0, "paused calls do not accumulate time")
	_game.ui.pause.close()
	_game._play_process(RSGolfGame.STEP * 0.5)
	_check(_game.hole_tick == 1, "pause preserves preexisting fractional step")
	for other: RSPartyGame.Player in _game.players.values():
		other.fake = true
