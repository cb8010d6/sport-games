extends Node
## Full three-event integration: actual scenes, bots, scoring and result-button transitions.

var _seen: Array = []
var _expected: Dictionary = {}
var _failed := false
var _mode := "normal"
var _count := 2
var _missing_tested := false
var _exit_started := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_start.call_deferred()


func _start() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	# Keep this driver alive while the real game scenes replace one another.
	get_tree().current_scene = null
	_mode = OS.get_environment("RS_PARTY_RECOVERY_MODE")
	if _mode.is_empty():
		_mode = "normal"
	_count = int(OS.get_environment("RS_PARTY_PLAYERS")) if OS.has_environment("RS_PARTY_PLAYERS") else 2
	if _mode not in ["normal", "missing", "exit"] or _count not in [2, 4]:
		get_tree().quit(1)
		return
	var slots: Array = []
	for slot in range(1, _count + 1):
		slots.append(slot)
		_expected[slot] = 0
	_check(RSTournament.begin(["plane", "archery", "bowling"], slots), "valid tournament starts")
	get_tree().change_scene_to_file(RSCatalog.find_game("plane")["scene"])


func _process(_delta: float) -> void:
	var current := get_tree().current_scene
	if not current is RSPartyGame:
		return
	var game := current as RSPartyGame
	if _mode == "exit":
		if not _exit_started and game.phase == RSPartyGame.Phase.LOBBY:
			_exit_started = true
			_exit_checks.call_deferred(game)
		return
	if _mode == "missing" and not _missing_tested and RSTournament.index == 1 and game.phase == RSPartyGame.Phase.LOBBY:
		_missing_tested = true
		game.demo = 0
		var missing: RSPartyGame.Player = game.ordered()[-1]
		missing.fake = false
		missing.c.connected = false
		game._sync_players()  # Real lobby removal, not a fabricated result row.
		_check(game.players.size() == _count - 1, "missing entrant is removed only in the next lobby")
		for p: RSPartyGame.Player in game.players.values():
			game._set_ready(p, true)
		game._process(0.0)
		_check(game.phase == RSPartyGame.Phase.COUNTDOWN, "ready present entrants can continue the second event")
	if game.phase != RSPartyGame.Phase.RESULTS or game.phase_time < maxf(game.results_delay, 1.0) + 0.1:
		return
	if game.game_id() in _seen:
		return
	_seen.append(game.game_id())
	var list := game.ranked_players()
	var rank := 1
	for i in list.size():
		var player: RSPartyGame.Player = list[i]
		if i > 0 and player.score != (list[i - 1] as RSPartyGame.Player).score:
			rank = i + 1
		_expected[player.c.player] += RSTournament.POINTS[rank - 1]
		if RSTournament.entrants[player.c.player]["points"] != _expected[player.c.player]:
			_failed = true
		if RSRecords.best(game.game_id(), game.map_index, player.c.player) != -1:
			_failed = true # a demo bot must not write a personal best
	for slot: int in _expected:
		_check(RSTournament.entrants[slot]["points"] == _expected[slot], "all slots retain exactly their earned points")
	if _mode == "missing" and RSTournament.index == 1:
		_check(list.size() == _count - 1 and RSTournament.entrants.has(_count), "absence keeps the original entrant and adds zero this event")
	if _mode == "missing" and RSTournament.index == 2:
		_check(list.size() == _count, "original slot can rejoin the next event")
	print("RS_PARTY_EVENT_DONE: " + game.game_id())
	if RSTournament.last_round():
		game._on_button((list[0] as RSPartyGame.Player).c, RSController.BTN_A, true)
		_failed = _failed or not game._tournament_final_shown
		_finish.call_deferred()
	else:
		game._on_button((list[0] as RSPartyGame.Player).c, RSController.BTN_A, true)


func _check(ok: bool, label: String) -> void:
	if not ok:
		_failed = true
		push_error("Party recovery: " + label)


func _c(game: RSPartyGame, controller: RSController) -> void:
	game._on_button(controller, RSController.BTN_C, true)
	game._on_button(controller, RSController.BTN_C, false)


func _settle_exit_layout() -> void:
	# Containers queue their sort; inspect the rendered layout after it has settled.
	for frame in 2:
		await get_tree().process_frame


func _check_exit_layout(game: RSPartyGame, page: Control, footer: Label, pending: bool) -> void:
	var notice := game.ui._exit_notice
	_check(notice.is_visible_in_tree() == pending, "real C state controls the visible exit notice")
	_check(footer.visible == (not pending), "normal page footer is hidden only while confirming")
	_check(is_equal_approx(page.offset_bottom, notice.offset_top if pending else 0.0), "confirmation reserves its actual top offset and restores the full page")
	var content := (page.get_child(0) as Control).get_global_rect()
	_check(game.get_viewport().get_visible_rect().grow(0.01).encloses(content), "actual page content remains entirely inside the logical window")
	if pending:
		var notice_rect := notice.get_global_rect()
		_check(not footer.is_visible_in_tree() or not footer.get_global_rect().intersects(notice_rect), "normal footer and confirmation never visibly overlap")
		_check(content.end.y <= notice_rect.position.y + 0.01, "actual page content ends above the confirmation notice")
	else:
		_check(footer.is_visible_in_tree(), "current page normal footer becomes visible again")


func _exit_checks(game: RSPartyGame) -> void:
	game.set_process(false)
	game.demo = 0
	var controllers: Array[RSController] = []
	for p: RSPartyGame.Player in game.ordered():
		p.fake = false
		p.ready = false
		controllers.append(p.c)
	var first := controllers[0]
	var second := controllers[1]
	var before := RSTournament.entrants.duplicate(true)
	_c(game, first)
	_check(RSTournament.entrants == before and game._tournament_exit.pending(), "first lobby C preserves tournament points")
	await _settle_exit_layout()
	_check_exit_layout(game, game.ui.lobby_panel, game.ui._lobby_hint, true)
	var stranger := RSController.new()
	stranger.id = 250
	stranger.player = 1
	stranger.connected = true
	_c(game, stranger)
	_check(RSTournament.entrants == before and game._tournament_exit.controller == first, "unknown controller cannot confirm or replace the request")
	_c(game, second)
	_check(RSTournament.active() and game._tournament_exit.controller == second, "two controllers cannot combine their first C presses")
	game._on_button(second, RSController.BTN_B, true)
	_check(not game._tournament_exit.pending(), "another button cancels confirmation")
	await _settle_exit_layout()
	_check_exit_layout(game, game.ui.lobby_panel, game.ui._lobby_hint, false)
	_c(game, first)
	game._process(RSTournament.ExitGuard.SECONDS)
	_check(not game._tournament_exit.pending() and RSTournament.active(), "confirmation expires exactly at its deadline")
	await _settle_exit_layout()
	_check_exit_layout(game, game.ui.lobby_panel, game.ui._lobby_hint, false)
	_c(game, first)
	_check(RSTournament.active(), "C after expiry starts a new confirmation")
	first.connected = false
	ControllerHub.controller_disconnected.emit(first)
	first.connected = true
	_check(not game._tournament_exit.pending(), "event disconnect and same-frame reconnect cancel the old request")
	_c(game, first)
	first.connected = false
	ControllerHub.roster_changed.emit()
	first.connected = true
	_check(not game._tournament_exit.pending(), "roster-only disconnect and reconnect cancel immediately")
	_c(game, first)
	first.player = 2
	ControllerHub.roster_changed.emit()
	first.player = 1
	_check(not game._tournament_exit.pending(), "slot remap cannot retain a confirmation")
	_c(game, first)
	game.pick_map(1)
	_check(not game._tournament_exit.pending(), "map operation cancels confirmation")
	_c(game, first)
	game.open_pause()
	_check(get_tree().paused and not game._tournament_exit.pending(), "pause opens through the real route and cancels confirmation")
	game.ui.pause.close()
	_c(game, first)
	var clock := game._clock
	game.set_process(true)
	get_tree().paused = true
	for frame in 5:
		await get_tree().process_frame
	_check(game._clock == clock and game._tournament_exit.pending(), "paused tree freezes confirmation time")
	get_tree().paused = false
	game.set_process(false)
	game.finish_round()
	_check(not game._tournament_exit.pending(), "results transition clears confirmation")
	game.ui.show_results()
	await _settle_exit_layout()
	_check_exit_layout(game, game.ui.results_panel, game.ui._results_hint, false)
	before = RSTournament.entrants.duplicate(true)
	_c(game, first)
	_check(RSTournament.entrants == before, "first results C also preserves earned points")
	await _settle_exit_layout()
	_check_exit_layout(game, game.ui.results_panel, game.ui._results_hint, true)
	game._on_button(first, RSController.BTN_B, true)
	await _settle_exit_layout()
	_check_exit_layout(game, game.ui.results_panel, game.ui._results_hint, false)
	_c(game, first)
	game._to_lobby()
	_check(not game._tournament_exit.pending(), "return to lobby clears confirmation")
	await _settle_exit_layout()
	_check_exit_layout(game, game.ui.lobby_panel, game.ui._lobby_hint, false)
	for controller: RSController in controllers:
		controller.connected = false
	game._sync_players()
	game._process(0.0)
	_check(game.players.is_empty() and game.phase == RSPartyGame.Phase.LOBBY, "zero entrants never start a countdown")
	for controller: RSController in controllers:
		controller.connected = true
		game._add_player(controller, false)
	_c(game, first)
	_c(game, first)
	_check(not RSTournament.active() and RSTournament.entrants.is_empty(), "same controller's two valid C presses exit and clear the tournament")
	for frame in 2:
		await get_tree().process_frame
	_finish.call_deferred()


func _finish() -> void:
	var scene := get_tree().current_scene
	if is_instance_valid(scene):
		for audio: AudioStreamPlayer in scene.find_children("*", "AudioStreamPlayer", true, false):
			audio.stop()
			audio.stream = null
		get_tree().current_scene = null
		scene.queue_free()
	# Fixed-fps gameplay can outrun the real audio mixer. Free the final scene and
	# let worker threads drain before checking shutdown, rather than hiding leaks.
	var until := Time.get_ticks_msec() + 350
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
	var incomplete := _mode != "exit" and (_seen.size() != 3 or (_mode == "missing" and not _missing_tested))
	print("RS_PARTY_FLOW: " + ("FAIL" if _failed or incomplete else "PASS"))
	get_tree().quit(1 if _failed or incomplete else 0)
