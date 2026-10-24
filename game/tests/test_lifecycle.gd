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
				"checks": _checks, "errors": _errors, "layout_only": _layout_only}))
		else:
			_check(false, "write lifecycle report")
	print("RS_LIFECYCLE_DONE: %s/%d" % [_game_id, _count])
	RSExit.quit(get_tree(), 0 if _errors.is_empty() else 1)
