extends Node
## G1-only headless checks. Run through tools/test_golf.py with disposable user data.

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
	_state_checks()
	var connections := ControllerHub.button_pressed.get_connections().size()
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
		_check(state.done and state.strokes[0] > 0 and state.strokes[1] > 0 and state.strokes[2] > 0, "every player completes three holes")
		_check(p.score == state.score() and p.score > 0, "Stableford points reach common results")
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
	_check(_game.hole_index == 0 and state.score() == 0 and state.strokes[2] == 0, "restart clears previous round")
	var reach := state.reach_index
	_game._player_button(p, RSController.BTN_A, true)
	_check(state.reach_index != reach, "A selects placeholder distance")
	_game._player_button(p, RSController.BTN_B, false)
	_check(state.strokes[0] == 0, "release without arming is ignored")
	_game._player_button(p, RSController.BTN_B, true)
	_game._player_button(p, RSController.BTN_C, true)
	_game._player_button(p, RSController.BTN_B, false)
	_check(not state.armed and not state.flying, "C cancels placeholder shot")
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
	_check(state.strokes[0] == 0, "pause release cannot launch")
	_game._player_button(p, RSController.BTN_B, true)
	_game._player_button(p, RSController.BTN_B, false)
	_game._player_button(p, RSController.BTN_B, false)
	_check(state.flying and state.strokes[0] == 1, "one armed release launches exactly once")
	p.c.connected = false
	state.armed = true
	_game._play_process(0.01)
	_check(not state.armed, "disconnect cancels pending input")
	p.c.connected = true
	_game.hole_elapsed = RSGolfState.HOLE_SECONDS - 0.01
	_game._play_process(0.02)
	for other: RSPartyGame.Player in _game.players.values():
		var other_state := other.data as RSGolfState
		_check(other_state.done and other_state.strokes[0] == other_state.par + 4, "deadline caps every unfinished player")
	_check(_game.card_elapsed == 0.0, "first completed hole enters hold")
	_game._play_process(RSGolfGame.CARD_SECONDS)
	_check(_game.hole_index == 1 and _game.hole_elapsed == 0.0, "hole transition resets effective timer")
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
	_check(state.score() == 0 and state.strokes[0] == 0 and _game.hole_index == 0, "map switch clears project state")
	_deadline_checks(p)
	var ball: WeakRef = weakref(state.ball)
	_game._remove_player(p.c.id)
	await get_tree().process_frame
	_check(ball.get_ref() == null and p.data == null, "player removal releases project state")


func _deadline_checks(p: RSPartyGame.Player) -> void:
	_game.phase = RSPartyGame.Phase.PLAY
	for flight_left: float in [0.015, 0.005, -1.0]:
		_game._round_started(_game.ordered())
		for other: RSPartyGame.Player in _game.players.values():
			if other != p:
				(other.data as RSGolfState).cap_hole()
		var state := p.data as RSGolfState
		_game.hole_elapsed = RSGolfState.HOLE_SECONDS - 0.01
		var remaining := RSGolfState.HOLE_SECONDS - _game.hole_elapsed
		var pin := _game.course.pin_pos(0) + Vector3.UP * RSGolfGame.BALL_RADIUS
		state.launch(pin, pin)
		state.advance(RSGolfState.FLIGHT_SECONDS - (remaining if flight_left < 0.0 else flight_left))
		_game._play_process(0.02)
		_check(state.done and state.capped[0] == int(flight_left > remaining), "deadline only accepts arrivals at or before effective time")
		_check(_game.hole_elapsed == RSGolfState.HOLE_SECONDS, "crossing frame consumes only remaining play time")


func _state_checks() -> void:
	var state := RSGolfState.new()
	state.start_hole(0, 4, Vector3.ZERO)
	_check(state.score() == 0, "unfinished holes have no free points")
	_check(state.launch(Vector3.ZERO, Vector3.ZERO), "first launch accepted")
	_check(not state.launch(Vector3.ONE, Vector3.ZERO), "in-flight duplicate rejected")
	state.advance(RSGolfState.FLIGHT_SECONDS)
	_check(state.done and state.score() == 5 and state.strokes[0] == 1, "hole in one Stableford")
	state.cap_hole()
	_check(state.strokes[0] == 1 and state.score() == 5, "completed hole immune to timeout")
	state.reset()
	state.start_hole(0, 4, Vector3.ZERO)
	state.strokes[0] = 7
	state.launch(Vector3.ZERO, Vector3.ZERO)
	state.advance(RSGolfState.FLIGHT_SECONDS)
	_check(state.done and state.capped[0] == 0 and state.strokes[0] == 8, "last allowed shot can hole")
	state.reset()
	state.start_hole(0, 3, Vector3.ZERO)
	state.launch(Vector3.ONE, Vector3.ZERO)
	state.cap_hole()
	state.advance(100.0)
	_check(state.done and not state.flying and state.strokes[0] == 7 and state.score() == 0, "timeout freezes flight and caps")
	state.cap_hole()
	_check(state.strokes[0] == 7, "repeated timeout idempotent")
	var scores := PackedInt32Array()
	for shots: Array in [[4, 3, 5], [3, 2, 9]]:
		state.reset()
		for index in range(3):
			state.start_hole(index, [4, 3, 5][index], Vector3.ZERO)
			state.strokes[index] = shots[index] - 1
			state.launch(Vector3.ZERO, Vector3.ZERO)
			state.advance(RSGolfState.FLIGHT_SECONDS)
		scores.append(state.score())
	_check(scores[0] == 6 and scores[1] == 6, "different stroke totals can tie on Stableford")
