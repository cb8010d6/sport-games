extends Node
## Exercise actual sports scenes with loopback UDP controllers and real pause/menu signals.
## Synthetic packets test the software path; they do not certify physical controller feel.

var _errors: Array[String] = []
var _peer := PacketPeerUDP.new()
var _count := 2
var _game_id := "plane"
var _report := ""
var _captures := ""
var _layout_only := false
var _recovery_mode := ""
var _recovery_elapsed := 0.0
var _checks := 0
var _heartbeat_at := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--lifecycle-game="):
			_game_id = arg.trim_prefix("--lifecycle-game=")
		elif arg.begins_with("--lifecycle-players="):
			_count = int(arg.trim_prefix("--lifecycle-players="))
		elif arg.begins_with("--lifecycle-report="):
			_report = arg.trim_prefix("--lifecycle-report=")
		elif arg.begins_with("--capture-output="):
			_captures = arg.trim_prefix("--capture-output=")
		elif arg == "--layout-only":
			_layout_only = true
		elif arg.begins_with("--round-recovery="):
			_recovery_mode = arg.trim_prefix("--round-recovery=")
	_peer.set_dest_address("127.0.0.1", ControllerHub.listen_port())
	_run.call_deferred()


func _process(_delta: float) -> void:
	if Time.get_ticks_msec() - _heartbeat_at >= 500:
		_heartbeat_at = Time.get_ticks_msec()
		_peer.put_packet(JSON.stringify({"type": "roster", "controllers": []}).to_utf8_buffer())


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_errors.append(label)
		push_error("Lifecycle: " + label)


func _frames(count: int = 3) -> void:
	for _i in count:
		await get_tree().process_frame


func _roster(disconnected: int = 0) -> void:
	var entries: Array = []
	for slot in range(1, _count + 1):
		entries.append({"id": 80 + slot, "player": slot, "kind": ["phone", "regina", "sim"][slot % 3],
			"name": "Fixture P%d" % slot, "connected": slot != disconnected, "battery": 80})
	_peer.put_packet(JSON.stringify({"type": "roster", "controllers": entries}).to_utf8_buffer())
	await _frames()


func _send_input(slot: int, buttons: int) -> void:
	var packet := PackedByteArray()
	packet.resize(16)
	packet[0] = 0x49
	packet[1] = 1
	packet[2] = 80 + slot
	packet[3] = buttons
	_peer.put_packet(packet)
	await _frames()


func _tap(slot: int, button: int) -> void:
	await _send_input(slot, button)
	await _send_input(slot, 0)


func _until_phase(game: RSPartyGame, wanted: int) -> bool:
	for _i in 1200:
		if game.phase == wanted:
			return true
		await _frames(1)
	_check(false, "phase timeout: %d" % wanted)
	return false


func _capture(name: String) -> void:
	if _captures.is_empty():
		return
	await RenderingServer.frame_post_draw
	var picture := get_viewport().get_texture().get_image()
	_check(picture.save_png(_captures.path_join(name + ".png")) == OK, "save screenshot " + name)


func _pause_check(game: RSPartyGame) -> void:
	await _tap(1, RSController.BTN_D)
	_check(game.ui.pause.is_open() and get_tree().paused, "D pauses the real scene")
	var clock := game._clock
	var phase_time := game.phase_time
	await _frames(5)
	_check(game._clock == clock and game.phase_time == phase_time, "pause freezes game clocks")
	await _tap(1, RSController.BTN_A)
	_check(not game.ui.pause.is_open() and not get_tree().paused, "A resumes through pause menu")
	await _frames()
	_check(game._clock > clock, "resume advances game clock")


func _deadline_checks(game: Variant) -> void:
	# Call the real processing and input paths at exact boundaries. Restore the
	# ordinary live scene afterward; this is not a second scoring implementation.
	game.set_process(false)
	game.set_physics_process(false)
	var p: RSPartyGame.Player = game.players[81]
	if _game_id == "archery":
		var s: Variant = game._archer(p)
		s.wait_t = game.SHOT_WAIT - 0.5
		game._on_button(p.c, RSController.BTN_A, true)
		s.draw_t = 1.0
		game._on_button(p.c, RSController.BTN_A, false)
		_check(s.arrows_left == game.ARROWS - 1 and game._arrow_in_flight(s), "before-deadline release launches a real arrow")
		game._process(game.SHOT_WAIT)
		_check(s.arrows_left == game.ARROWS - 1 and s.hits.size() == 1, "in-flight arrow follows physics and settles once without a waiting timeout")
		game._process(0.0)
		_check(s.hits.size() == 1, "settled arrow is not scored twice")
		game._begin_round(0)
		game._stage = game.Stage.SHOOT
		game._on_button(p.c, RSController.BTN_A, true)
		game._process(game.SHOT_WAIT - 0.5)
		game._on_button(p.c, RSController.BTN_A, true)
		_check(s.wait_t == game.SHOT_WAIT - 0.5, "repeated draw presses do not renew the arrow deadline")
		game._process(0.5)
		_check(s.arrows_left == game.ARROWS - 1 and s.hits.size() == 1 and s.hits[0].z == 0 and not s.drawing, "exact deadline consumes one zero-ring arrow and cancels drawing")
		game._on_button(p.c, RSController.BTN_A, false)
		_check(s.arrows_left == game.ARROWS - 1 and s.hits.size() == 1, "late release cannot consume or score the expired arrow again")
		s.wait_t = game.SHOT_WAIT
		game._on_button(p.c, RSController.BTN_A, true)
		_check(s.arrows_left == game.ARROWS - 2 and not s.drawing, "deadline press cannot renew the expired arrow")
		s.wait_t = game.SHOT_WAIT + 0.5
		game._on_button(p.c, RSController.BTN_A, true)
		game._on_button(p.c, RSController.BTN_A, false)
		_check(s.arrows_left == 0 and s.hits.size() == game.ARROWS, "after-deadline input consumes only the final zero arrow")
	else:
		var s: Variant = game._bowler(p)
		s.step_t = game.AIM_WAIT - 0.5
		game._on_button(p.c, RSController.BTN_B, true)
		_check(s.step == game.Step.SWING, "before-deadline B enters the original swing path")
		s.step_t = 6.0
		game._on_button(p.c, RSController.BTN_B, true)
		game._process(0.0)
		_check(s.step == game.Step.SWING and s.step_t == 6.0, "repeat B does not renew swing and original six-second boundary stays exclusive")
		game._process(0.01)
		_check(s.step == game.Step.ROLLING, "held swing still auto-releases after six seconds")
		game._physics_process(1.0 / 60.0)
		game._round_started(game.ordered())
		var standing: Array = s.standing.duplicate()
		s.step_t = game.AIM_WAIT
		game._on_button(p.c, RSController.BTN_B, true)
		_check(s.rolls == [0] and s.ball_in_frame == 1 and s.standing == standing, "first-ball deadline consumes zero and keeps the standing rack")
		game._on_button(p.c, RSController.BTN_B, false)
		_check(s.rolls == [0] and s.step == game.Step.AIM, "late B release does not turn a timed-out throw into a shot")
		s.pins[0].global_position.y = -1.0
		s.step_t = game.AIM_WAIT + 0.5
		game._process(0.0)
		_check(s.rolls == [0, 0] and s.frame == 1 and p.score == 0, "timeout never scans an old fallen pin and advances through normal frame rules")
		var original_frames: int = game._frames
		for frame_count: int in [5, 10]:
			game._frames = frame_count
			game._round_started(game.ordered())
			s.frame = frame_count - 1
			for _roll in (frame_count - 1) * 2:
				s.rolls.append(0)
			_knock_pins(game, p, 10)
			_check(s.ball_in_frame == 1 and s.step == game.Step.AIM, "final-frame strike earns its normal bonus throws")
			for _bonus in 2:
				s.step_t = game.AIM_WAIT
				game._process(0.0)
			_check(s.step == game.Step.DONE and s.rolls.slice(-3) == [10, 0, 0] and p.score == 10, "five/ten-frame strike bonuses can time out without extra points")
			game._round_started(game.ordered())
			s.frame = frame_count - 1
			for _roll in (frame_count - 1) * 2:
				s.rolls.append(0)
			s.step_t = game.AIM_WAIT
			game._process(0.0)
			_knock_pins(game, p, 10)
			_check(s.ball_in_frame == 2 and s.step == game.Step.AIM, "zero then spare earns the normal final bonus")
			s.step_t = game.AIM_WAIT
			game._process(0.0)
			_check(s.step == game.Step.DONE and s.rolls.slice(-3) == [0, 10, 0] and p.score == 10, "five/ten-frame spare bonus timeout settles once")
		game._frames = original_frames
	# A real roster disconnect/reconnect must not change the current waiting clock.
	game.restart_round()
	game.set_process(true)
	game.set_physics_process(true)
	if not await _until_phase(game, RSPartyGame.Phase.PLAY):
		return
	game.set_process(false)
	game._process(2.0)
	var wait_before: float = game._archer(p).wait_t if _game_id == "archery" else game._bowler(p).step_t
	await _roster(1)
	await _roster()
	var wait_after: float = game._archer(p).wait_t if _game_id == "archery" else game._bowler(p).step_t
	_check(game.players[81] == p and wait_before == wait_after, "same PLAY slot reconnect does not reset its deadline")
	game.set_process(true)
	await _tap(1, RSController.BTN_D)
	var frozen_wait: float = game._archer(p).wait_t if _game_id == "archery" else game._bowler(p).step_t
	await _frames(5)
	var paused_wait: float = game._archer(p).wait_t if _game_id == "archery" else game._bowler(p).step_t
	_check(get_tree().paused and frozen_wait == paused_wait, "real pause freezes the waiting deadline")
	await _tap(1, RSController.BTN_A)
	game.restart_round()
	if await _until_phase(game, RSPartyGame.Phase.PLAY):
		var reset_wait: float = game._archer(p).wait_t if _game_id == "archery" else game._bowler(p).step_t
		_check(reset_wait < 1.0, "restart gives the new round a fresh waiting clock")


func _knock_pins(game: Variant, p: RSPartyGame.Player, count: int) -> void:
	var s: Variant = game._bowler(p)
	var moved := 0
	for i in s.pins.size():
		if s.standing[i] and moved < count:
			s.pins[i].global_position.y = -1.0
			moved += 1
	game._count_pins(p)


func _round_recovery(game: RSPartyGame) -> void:
	await _deadline_checks(game)
	if game.phase != RSPartyGame.Phase.PLAY:
		return
	var original: RSPartyGame.Player = game.players[81]
	for p: RSPartyGame.Player in game.ordered():
		p.fake = p != original
	if _recovery_mode == "disconnected":
		await _roster(1)
	_check(game.players[81] == original and not original.fake, "recovery retains P1 in PLAY instead of removing the waiting player")
	var started := game._clock
	for _frame in 260 * 60:
		if game.phase == RSPartyGame.Phase.RESULTS:
			break
		await _frames(1)
	_recovery_elapsed = game._clock - started
	_check(game.phase == RSPartyGame.Phase.RESULTS and _recovery_elapsed <= 260.0, "idle/disconnected real scene reaches RESULTS within bounded effective time")
	_check(original.score == 0 and game.players[81] == original, "waiting player finishes with zero and keeps the PLAY slot")
	_check(original.c.connected == (_recovery_mode == "idle"), "requested disconnect/connected-idle condition persists")
	for p: RSPartyGame.Player in game.ordered():
		_check(RSRecords.best(_game_id, game.map_index, p.c.player) == -1, "recovery fixture writes no personal record")
	get_tree().current_scene = null
	game.queue_free()
	await _frames(3)


func _exercise() -> void:
	get_tree().current_scene = null
	var entry := RSCatalog.find_game(_game_id)
	if entry.is_empty() or _count not in [2, 4]:
		_check(false, "invalid lifecycle case")
		return
	for slot in range(1, _count + 1):
		RSProfiles.complete_tutorial(slot, _game_id)
	var scene := load(entry["scene"]) as PackedScene
	var game := scene.instantiate() as RSPartyGame
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	game._records_enabled = false
	await _roster()
	_check(game.players.size() == _count, "UDP roster joins every player")
	if game.players.size() != _count:
		return
	if not _layout_only and _game_id in ["basketball", "ski"]:
		await _quality_after_map_switch_check(game)
	if not _layout_only:
		await _tap(1, RSController.BTN_A)
		_check(game.players[81].ready, "UDP A readies player")
		await _roster(1)
		_check(not game.players.has(81), "lobby disconnect removes player")
		await _roster()
		_check(game.players.has(81) and not game.players[81].ready, "rejoin requires fresh ready")
	for slot in range(1, _count + 1):
		await _tap(slot, RSController.BTN_A)
	if not await _until_phase(game, RSPartyGame.Phase.PLAY):
		return
	await _frames(60 if _layout_only else 10)
	_check(game.players.size() == _count and game.views.visible, "all split-screen views active")
	var rectangles: Array[Rect2] = []
	for p: RSPartyGame.Player in game.ordered():
		var rect := p.cell.get_rect()
		_check(rect.size.x > 0 and rect.size.y > 0 and p.cam.current, "positive cell and current camera")
		_check(get_viewport().get_visible_rect().encloses(rect), "split-screen cell stays inside screen")
		for other: Rect2 in rectangles:
			_check(not rect.intersects(other), "split-screen cells do not overlap")
		rectangles.append(rect)
	await _capture("play")
	if not _recovery_mode.is_empty():
		_check(_game_id in ["archery", "bowling"] and _recovery_mode in ["idle", "disconnected"], "valid real-scene round recovery case")
		if _game_id in ["archery", "bowling"] and _recovery_mode in ["idle", "disconnected"]:
			await _round_recovery(game)
		return
	if not _layout_only:
		var original: RSPartyGame.Player = game.players[81]
		original.score = 123
		await _roster(1)
		_check(game.players[81] == original and not original.c.connected, "playing disconnect retains slot")
		await _roster()
		_check(game.players[81] == original and original.c.connected and original.score == 123, "playing rejoin preserves score")
		await _pause_check(game)
		await _tap(1, RSController.BTN_D)
		await _tap(1, RSController.BTN_B)
		await _tap(1, RSController.BTN_A)
		_check(not get_tree().paused, "restart closes pause menu")
		_check(game.players[81].score == 0, "restart clears old score")
		if not await _until_phase(game, RSPartyGame.Phase.PLAY):
			return
		game.finish_round()
		game.finish_round()
		_check(game.phase == RSPartyGame.Phase.RESULTS and game._result_committed, "duplicate finish keeps committed results")
		# The cinematic sports choose their delay in finish_round(); use the real gate.
		for _i in 1800:
			if game.ui.results_panel.visible and game.phase_time > maxf(game.results_delay, 1.0) + 0.1:
				break
			await _frames(1)
		_check(game.ui.results_panel.visible, "results appear after replay and podium")
		var podium_on: Variant = game.get("_podium_on")
		if podium_on != null:
			game.finish_round()
			_check(game.get("_podium_on") == podium_on, "finish_round again in results keeps podium state (#57)")
		await _tap(1, RSController.BTN_A)
		_check(game.phase == RSPartyGame.Phase.LOBBY and not game.players[81].ready, "results A returns to unready lobby")
	else:
		game._to_lobby()
	if _count == 4:
		game.review_tutorials()
		game.ui.update_lobby()
		await _frames()
		_check(game.ui._tutorial_panel.visible and game.ui._tutorial_grid.get_child_count() == 4, "four tutorial cards visible")
		await _capture("tutorial")
	await _tap(1, RSController.BTN_C)
	await _frames(3)
	var menu := get_tree().current_scene
	_check(menu != null and menu.get_script().resource_path == "res://scenes/menu/main_menu.gd" and not get_tree().paused, "C returns to real menu")
	if menu != null:
		get_tree().current_scene = null
		menu.queue_free()
	await _frames(3)


func _quality_after_map_switch_check(game: RSPartyGame) -> void:
	## Issue #54: a world built by a lobby map switch starts from scene values, so the
	## quality gates must be re-applied to it. At low quality the switched map's SSR
	## and glow stay off and its sun keeps an ordinary shadow edge (no PCSS).
	var previous := RSSettings.quality
	RSSettings.quality = 0
	var target := posmod(game.map_index + 1, game._maps().size())
	game.pick_map(1)
	for _i in 600:
		if game.map_index == target and game._pending_map < 0:
			break
		await _frames(1)
	_check(game.map_index == target, "lobby map switch completes at low quality")
	await _frames(3)  # let the replaced world leave the tree before inspecting this one
	var worlds := game.find_children("*", "WorldEnvironment", true, false)
	_check(not worlds.is_empty(), "switched map has a world environment")
	for we: WorldEnvironment in worlds:
		_check(not we.environment.ssr_enabled, "low quality keeps SSR off after a map switch")
		_check(not we.environment.glow_enabled, "low quality keeps glow off after a map switch")
	var suns := game.find_children("*", "DirectionalLight3D", true, false)
	_check(not suns.is_empty(), "switched map has a sun")
	for sun: DirectionalLight3D in suns:
		_check(sun.light_angular_distance == 0.0, "low quality keeps PCSS off after a map switch")
	RSSettings.quality = previous
	RSSettings.apply_world(game)


func _run() -> void:
	await _exercise()
	get_tree().paused = false
	set_process(false)
	_peer.close()
	ControllerHub.controllers.clear()
	if not _report.is_empty():
		var file := FileAccess.open(_report, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify({"game": _game_id, "players": _count,
				"checks": _checks, "errors": _errors, "layout_only": _layout_only,
				"recovery_mode": _recovery_mode, "recovery_elapsed_seconds": _recovery_elapsed}))
		else:
			_check(false, "write lifecycle report")
	print("RS_LIFECYCLE_DONE: %s/%d" % [_game_id, _count])
	RSExit.quit(get_tree(), 0 if _errors.is_empty() else 1)
