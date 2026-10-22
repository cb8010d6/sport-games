extends Node
## Launch the real menu and scenes through a synthetic UDP human controller. CPU plays
## the normal physics to natural results. Layout mode captures UI without a full round.

var _peer := PacketPeerUDP.new()
var _errors: Array[String] = []
var _checks := 0
var _id := "plane"
var _level := 1
var _slot := 1
var _heartbeat := 0
var _captures := ""
var _layout := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	_id = OS.get_environment("RS_SOLO_GAME")
	_level = int(OS.get_environment("RS_SOLO_LEVEL"))
	_slot = [1, 3, 4][_level]
	_captures = OS.get_environment("RS_SOLO_CAPTURE")
	_layout = not _captures.is_empty()
	_peer.set_dest_address("127.0.0.1", ControllerHub.LISTEN_PORT)
	_run.call_deferred()


func _process(_delta: float) -> void:
	if Time.get_ticks_msec() - _heartbeat >= 500:
		_heartbeat = Time.get_ticks_msec()
		_peer.put_packet(JSON.stringify({"type": "roster", "controllers": []}).to_utf8_buffer())


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_errors.append(label)
		push_error("Solo: " + label)


func _frames(count: int = 3) -> void:
	for _i in count:
		await get_tree().process_frame


func _roster(connected: bool) -> void:
	var entries: Array = []
	for slot in range(1, 5):
		entries.append({"id": 80 + slot, "player": slot, "kind": "phone", "name": "Fixture P%d" % slot,
			"connected": connected if slot == _slot else true, "battery": 80})
	_peer.put_packet(JSON.stringify({"type": "roster", "controllers": entries}).to_utf8_buffer())
	await _frames()


func _tap(slot: int, button: int) -> void:
	for value: int in [button, 0]:
		_send_input(slot, value)
		await _frames()


func _send_input(slot: int, value: int) -> void:
	var packet := PackedByteArray()
	packet.resize(16)
	packet[0] = 0x49
	packet[1] = 1
	packet[2] = 80 + slot
	packet[3] = value
	_peer.put_packet(packet)


func _until(game: RSPartyGame, wanted: int) -> bool:
	var last_input := -1
	for _i in 22000:
		if game.phase == wanted:
			_send_input(_slot, 0)
			await _frames()
			return true
		# Archery and bowling wait for a human action rather than a clock. Exercise
		# press/hold/release via UDP; keep the human eligible for formal records.
		if wanted == RSPartyGame.Phase.RESULTS and game.phase == RSPartyGame.Phase.PLAY and _id in ["archery", "bowling"]:
			var button := RSController.BTN_A if _id == "archery" else RSController.BTN_B
			var value := button if fmod(game.phase_time, 2.4) < 1.6 else 0
			if value != last_input:
				_send_input(_slot, value)
				last_input = value
		await _frames(1)
	_check(false, "phase timed out: %d" % wanted)
	return false


func _capture(name: String) -> void:
	if not _layout:
		return
	await _frames(6) # Allow container layout and render-thread submissions to settle.
	await RenderingServer.frame_post_draw
	_check(get_viewport().get_texture().get_image().save_png(_captures.path_join(name + ".png")) == OK, "capture " + name)


func _exercise() -> Dictionary:
	_check(RSSolo.begin("invalid", 1, 1).is_empty(), "invalid game rejected")
	_check(RSSolo.begin(_id, 0, 1).is_empty() and RSSolo.begin(_id, 1, 3).is_empty(), "invalid slot/difficulty rejected")
	var goals: Array = RSSolo.GOALS[_id]
	_check(RSSolo.earned(_id, -1) == 0 and RSSolo.earned(_id, goals[0] - 1) == 0, "below goal boundary")
	for i in 3:
		_check(RSSolo.earned(_id, goals[i]) == i + 1, "inclusive challenge boundary")
	RSProfiles.complete_tutorial(_slot, _id)
	get_tree().current_scene = null
	var menu := (load(RSPartyGame.MENU_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(menu)
	get_tree().current_scene = menu
	menu._pages._solo_slot = _slot
	menu._pages._solo_difficulty = _level
	menu._pages.open("solo")
	menu._pages._start_solo(_id)
	_check(not RSSolo.active(_id), "menu refuses missing controller")
	await _roster(true)
	if _layout:
		await _frames(6)
		for control: Control in menu._pages._focus:
			_check(get_viewport().get_visible_rect().encloses(control.get_global_rect()), "menu action stays on screen")
	await _capture("menu")
	menu._pages._start_solo(_id)
	await _frames(5)
	var game := get_tree().current_scene as RSPartyGame
	_check(game != null and game.solo_mode and game.demo == 0, "menu starts formal solo scene")
	if game == null:
		return {}
	_check(RSSolo.slot == _slot and RSSolo.difficulty == _level and not RSTournament.active(), "menu selection preserved")
	await _roster(false)
	await _frames(90)
	_check(game.players.size() == 1 and game.players[-1].fake, "spectators cannot occupy CPU slot")
	_check(game.phase == RSPartyGame.Phase.LOBBY, "CPU cannot start without human")
	await _roster(true)
	_check(game.players.size() == 2 and game.players.has(80 + _slot), "selected human joins")
	var human: RSPartyGame.Player = game.players[80 + _slot]
	var cpu: RSPartyGame.Player = game.players[-1]
	_check(cpu.c.player != _slot and cpu.c.player == RSSolo.opponent_slot(), "distinct stable player slots")
	_check(game.can_record(human) and not game.can_record(cpu), "only formal human can record")
	_check(game.bot_error() == [2.4, 1.0, 0.35][_level] and game.bot_ability() == [0.62, 0.9, 0.99][_level], "difficulty parameters connected")
	await _capture("lobby")
	await _tap(_slot, RSController.BTN_A)
	if not await _until(game, RSPartyGame.Phase.PLAY):
		return {}
	await _frames(60 if _layout else 6)
	_check(game.views.visible and game.players.size() == 2, "two active split-screen views")
	await _capture("play")
	await _tap(RSSolo.opponent_slot(), RSController.BTN_C)
	_check(get_tree().current_scene == game, "spectator cannot leave match")
	await _roster(false)
	_check(game.players[80 + _slot] == human and not human.c.connected, "playing disconnect retains human")
	await _roster(true)
	_check(game.players[80 + _slot] == human and human.c.connected, "playing reconnect retains human")
	await _tap(_slot, RSController.BTN_D)
	var clock := game._clock
	await _frames(5)
	_check(get_tree().paused and game._clock == clock, "pause freezes both participants")
	await _tap(_slot, RSController.BTN_A)
	_check(not get_tree().paused, "controller resumes")
	if _layout:
		# The runner's disposable save directory lets the real results path draw stars.
		# This forced result is labelled layout_only and never substitutes for a round.
		game.finish_round()
	elif not await _until(game, RSPartyGame.Phase.RESULTS):
		return {}
	var scores := {"human_score": human.score, "cpu_score": cpu.score, "map": game.map_index}
	if game.map_index == 0:
		_check(game.ui._results_text.text.contains(RSLang.t("挑战星数：%d / 3（地图 1 个人最佳）") % RSSolo.stars(_id, _slot)), "results include challenge star label")
	_check(RSRecords.best(_id, game.map_index, cpu.c.player) == -1, "CPU never writes records")
	if not _layout:
		_check(RSRecords.best(_id, game.map_index, _slot) == human.score, "natural human result saved")
		var expected_stars := RSSolo.earned(_id, human.score) if game.map_index == 0 else 0
		_check(RSSolo.stars(_id, _slot) == expected_stars, "only map 1 contributes challenge stars")
		RSRecords._loaded = false
		_check(RSSolo.stars(_id, _slot) == expected_stars, "stars survive record reload")
		_check(RSSolo.stars(_id, cpu.c.player) == 0 and RSSolo.stars(_id, 0) == 0, "CPU and invalid slot cannot gain stars")
	for _i in 1800:
		if game.ui.results_panel.visible and game.phase_time > maxf(game.results_delay, 1.0):
			break
		await _frames(1)
	await _capture("results")
	await _tap(_slot, RSController.BTN_A)
	_check(game.phase == RSPartyGame.Phase.LOBBY and not human.ready, "again requires fresh human ready")
	await _roster(false)
	_check(game.players.size() == 1, "lobby disconnect removes human")
	await _roster(true)
	_check(game.players.size() == 2 and not game.players[80 + _slot].ready, "lobby rejoin stays unready")
	await _tap(_slot, RSController.BTN_C)
	await _frames(5)
	_check(not RSSolo.active(_id) and not is_instance_valid(game), "return to menu clears solo session")
	return scores


func _run() -> void:
	var report := await _exercise()
	report.merge({"game": _id, "level": _level, "slot": _slot, "checks": _checks,
		"passed": _errors.is_empty(), "errors": _errors, "layout_only": _layout})
	var file := FileAccess.open(OS.get_environment("RS_SOLO_REPORT"), FileAccess.WRITE)
	if file == null:
		get_tree().quit(1)
		return
	file.store_string(JSON.stringify(report))
	file.close()
	print("RS_SOLO_TEST: %s" % ("PASS" if _errors.is_empty() else "FAIL"))
	# Quit the way the game does, with the final menu still playing its cue.
	RSExit.quit(get_tree(), 0 if _errors.is_empty() else 1)
