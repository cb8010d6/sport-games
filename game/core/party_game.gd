class_name RSPartyGame
extends Node3D
## Shared frame for the 1-4 player games: lobby (A = ready, phone QR code), one split-screen
## view + HUD per player, 3-2-1 countdown, ranked results (A = again, C = menu), Esc back to
## the menu, and debug flags. A game extends this and overrides the "game hooks"; scores go
## in Player.score, the game's own per-player state in Player.data.
##
## Games with several maps list them in _maps(): the lobby then shows a map card (B or ←/→ to
## change, remembered per game) and _load_map() rebuilds the world for the chosen one.
##
## D (a short press, on any controller) or Esc opens the pause menu (RSPauseMenu): continue,
## restart the round, display settings (RSSettings), language, main menu.
##
## The split-screen views live in RSPartyViews (`views`), the lobby / results / pause panels in
## RSPartyUi (`ui`); this script runs the rounds and draws the HUDs.
##
## Debug flags (after `--`): `--demo=N` adds N bot players (no hub needed; the game drives
## them), `--shots=<path prefix>` saves screenshots at `shot_times` and quits, `--map=N`.

enum Phase { LOBBY, COUNTDOWN, PLAY, RESULTS }

const MENU_SCENE := "res://scenes/menu/main_menu.tscn"
const COUNTDOWN_TIME := 3.0
const MENU_TAP_MS := 800         ## D held longer than this is the hub's recenter, not the menu


class Player:
	var c: RSController
	var fake := false
	var ready := false
	var score := 0
	var data: Variant            ## the game's per-player state
	var cell: Control            ## this player's split-screen rect
	var cam: Camera3D
	var hud: PlayerHud
	var oled_key := ""           ## last OLED update, to skip identical ones

	func popup(text: String, color: Color = Color.WHITE) -> void:
		hud.popups.append([text, color, float(hud.game.get("_clock"))])


class PlayerHud extends Control:
	var player: Player
	var game: Node
	var popups: Array = []       ## [text, color, start time on the game clock]

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		game._hud_draw(self)


class Overlay extends Control:
	var game: Node

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		game._overlay_draw(self)


var phase := Phase.LOBBY
var phase_time := 0.0
var players: Dictionary = {}     ## controller id -> Player
var demo := 0
var solo_mode := false
var lobby_cam: Camera3D
var font: Font
var shot_times: Array = [0.5, 2.5, 9.0, 16.0, 25.0]
var map_index := 0               ## the loaded map (games with _maps())

static var _last_map: Dictionary = {}   ## game script path -> map picked last time
var results_delay := 0.0         ## seconds of RESULTS before the results panel shows

var _badge := StyleBoxFlat.new()
var _pill := StyleBoxFlat.new()
var views: RSPartyViews          ## the players' split-screen cells
var ui: RSPartyUi                ## lobby, results and pause panels
var _shots := ""
var _shot_i := 0
var _clock := 0.0
var _pending_map := -1
var _pending_t := 0.0
var _d_down: Dictionary = {}     ## controller id -> ticks (ms) when D went down
var _beat := -1        # countdown second last buzzed
var _records_enabled := true
var _result_committed := false
var _smoke_report := ""
var _smoke_shot := ""
var _smoke_done := false
var _tournament_final_shown := false
var _tutorials: Dictionary = {}  ## controller id -> its active lobby lesson
var _music: RSMusic


# ---------------------------------------------------------------------- game hooks ----

func _game_name() -> String:
	return ""


func _oled_name() -> String:
	## ASCII, at most 10 characters (OLED title).
	return ""


func _how_to_play() -> String:
	return ""


func _countdown_time() -> float:
	## Length of the COUNTDOWN phase; anything over the 3-2-1 is free for an intro.
	return COUNTDOWN_TIME


func _parse_arg(_arg: String) -> void:
	pass


func _setup_world() -> void:
	## Build the scene and place lobby_cam.
	pass


func _maps() -> Array:
	## [{name, en, desc}, ...] for a game with a choice of maps (empty = no map card).
	return []


func _map_info(i: int) -> String:
	## Second line of the lobby map card.
	return str(_maps()[i].get("en", ""))


func _load_map(_i: int) -> void:
	## Build (or rebuild) the world for map i; map_index is already set.
	pass


func _player_added(_p: Player) -> void:
	pass


func _player_removed(_p: Player) -> void:
	pass


func _player_ready(_p: Player, _is_ready: bool) -> void:
	pass


func _lobby_process(_delta: float) -> void:
	pass


func _round_started(_ordered: Array) -> void:
	## Countdown begins: place everyone, send the in-game OLED screen.
	pass


func _countdown_process(_delta: float) -> void:
	pass


func _play_started() -> void:
	pass


func _play_process(_delta: float) -> void:
	## Call finish_round() when the round is over.
	pass


func _results_process(_delta: float) -> void:
	pass


func _player_button(_p: Player, _button: int, _pressed: bool) -> void:
	## Buttons during the countdown and play (A in the lobby / results is handled here).
	pass


func _lobby_extra(_col: VBoxContainer) -> void:
	## Add game options (e.g. a map picker) to the lobby panel, under the how-to-play text.
	pass


func _lobby_button(_p: Player, _button: int) -> void:
	## A button other than A pressed in the lobby (e.g. B to change the map).
	pass


func _player_recentered(_p: Player) -> void:
	pass


func _result_detail(_p: Player) -> String:
	## Second line of a player's results entry.
	return ""


func _draw_hud(_h: PlayerHud, _p: Player, _k: float) -> void:
	pass


func _draw_overlay(_o: Overlay, _k: float) -> void:
	pass


# ---------------------------------------------------------------------- lifecycle ----

func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--round=") or a.begins_with("--frames="):
			_records_enabled = false
		if a.begins_with("--demo"):
			demo = clampi(int(a.get_slice("=", 1)) if a.contains("=") else 1, 1, 4)
		elif a.begins_with("--shots="):
			_shots = a.get_slice("=", 1)
		elif a.begins_with("--map="):
			_last_map[get_script().resource_path] = int(a.get_slice("=", 1))
		elif a.begins_with("--smoke-report="):
			_smoke_report = a.trim_prefix("--smoke-report=")
		elif a.begins_with("--smoke-shot="):
			_smoke_shot = a.trim_prefix("--smoke-shot=")
		else:
			_parse_arg(a)
	solo_mode = demo == 0 and RSSolo.active(game_id())
	font = RSUi.font()
	ControllerHub.process_mode = Node.PROCESS_MODE_ALWAYS   # buttons still arrive while paused
	map_index = posmod(int(_last_map.get(get_script().resource_path, map_index)), maxi(_maps().size(), 1))
	_badge.set_corner_radius_all(10)
	_pill.bg_color = Color(0.07, 0.08, 0.11, 0.8)
	lobby_cam = Camera3D.new()
	lobby_cam.fov = 55
	lobby_cam.far = 3000
	lobby_cam.cull_mask = 1
	add_child(lobby_cam)
	_setup_world()
	if not _maps().is_empty():
		_load_map(map_index)
	_build_ui()
	_update_map_card()
	RSSettings.apply(get_tree())
	RSExit.install(get_tree())   # also covers games launched directly by tests and tools
	_music = RSMusic.attach(self)
	ControllerHub.button_pressed.connect(_on_button.bind(true))
	ControllerHub.button_released.connect(_on_button.bind(false))
	ControllerHub.controller_event.connect(_on_event)
	ControllerHub.qr_received.connect(ui.set_qr)
	if not ControllerHub.qr_rows.is_empty():
		ui.set_qr(ControllerHub.phone_url, ControllerHub.qr_rows)
	for i in demo:
		var c := RSController.new()
		c.id = 200 + i
		c.player = i + 1
		c.kind = "replay"
		c.display_name = "Bot-%d" % (i + 1)
		c.connected = true
		_add_player(c, true)
	if solo_mode:
		var c := RSController.new()
		c.id = -1 # Real UDP controller IDs are unsigned bytes.
		c.player = RSSolo.opponent_slot()
		c.kind = "bot"
		c.display_name = tr("电脑 · %s") % RSSolo.difficulty_name()
		c.connected = true
		_add_player(c, true)
	_to_lobby()


func _unhandled_input(event: InputEvent) -> void:
	if phase == Phase.LOBBY and event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_T:
		review_tutorials()
		get_viewport().set_input_as_handled()
	elif phase == Phase.LOBBY and event.is_action_pressed("ui_right"):
		pick_map(1)
	elif phase == Phase.LOBBY and event.is_action_pressed("ui_left"):
		pick_map(-1)
	elif event.is_action_pressed("ui_cancel"):
		open_pause()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("recenter_all"):
		ControllerHub.recenter(0)


func go_menu() -> void:
	get_tree().paused = false
	RSTournament.clear()
	RSSolo.clear()
	get_tree().change_scene_to_file(MENU_SCENE)


func open_pause() -> void:
	if _shots.is_empty():
		ui.pause.can_restart = phase != Phase.LOBBY and not (RSTournament.active() and RSTournament.round_done)
		ui.pause.can_tutorial = phase == Phase.LOBBY and not players.is_empty() and demo == 0
		ui.pause.open()


func restart_round() -> void:
	## Pause menu: back through the lobby with everyone ready, so the countdown starts at once.
	_to_lobby()
	for p: Player in players.values():
		_set_ready(p, true)


func _process(delta: float) -> void:
	_clock += delta
	phase_time += delta
	match phase:
		Phase.LOBBY:
			_sync_players()
			_update_tutorials(delta)
			if _pending_map >= 0:
				_pending_t -= delta
				if _pending_t <= 0.0:
					_apply_pending_map()
			_lobby_process(delta)
			var all_ready := not players.is_empty()
			if solo_mode:
				all_ready = players.size() == 2 and ordered().any(func(p: Player) -> bool: return not p.fake and p.c.connected)
			if RSTournament.active():
				all_ready = players.size() == RSTournament.entrants.size()
			for p: Player in players.values():
				if p.fake and not p.ready and phase_time > 0.8:
					_set_ready(p, true)
				all_ready = all_ready and p.ready
			ui.update_lobby()
			if all_ready:
				_start_countdown()
		Phase.COUNTDOWN:
			_countdown_process(delta)
			var beat := ceili(_countdown_time() - phase_time)
			if beat != _beat and beat <= COUNTDOWN_TIME and beat > 0:
				haptic_all("count")
			_beat = beat
			if phase_time >= _countdown_time():
				phase = Phase.PLAY
				phase_time = 0.0
				haptic_all("go")
				_play_started()
		Phase.PLAY:
			_play_process(delta)
		Phase.RESULTS:
			_results_process(delta)
			if not ui.results_panel.visible and phase_time >= results_delay:
				ui.results_panel.visible = true
			if not _smoke_report.is_empty() and not _smoke_done and phase_time > results_delay + 1.0:
				_smoke_done = true
				_complete_smoke()
	_take_shots()


func _complete_smoke() -> void:
	if not _smoke_shot.is_empty() and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(_smoke_shot)
	var scores: Array = []
	for p: Player in ranked_players():
		scores.append({"slot": p.c.player, "score": p.score})
	var report := FileAccess.open(_smoke_report, FileAccess.WRITE)
	if report == null:
		push_error("Cannot write smoke report")
		RSExit.quit(get_tree(), 1)
		return
	report.store_string(JSON.stringify({"game": game_id(), "map": map_index, "players": scores, "phase": "results"}))
	report.close()
	print("RS_SMOKE_DONE: " + game_id())
	RSExit.quit(get_tree())


# ------------------------------------------------------------------------ players ----

func ordered() -> Array:
	## Players sorted by player number (= split-screen order).
	var list := players.values()
	list.sort_custom(func(a: Player, b: Player) -> bool: return a.c.player < b.c.player)
	return list


func color_of(p: Player) -> Color:
	return RSProfiles.player_color(p.c.player)


func avatar_of(p: Player) -> int:
	return RSProfiles.avatar(p.c.player)


func name_of(p: Player) -> String:
	return p.c.display_name if p.fake else RSProfiles.player_name(p.c.player)


func can_record(p: Player) -> bool:
	return not p.fake and p.c.kind != "replay" and demo == 0 and _shots.is_empty() and _records_enabled


func bot_error() -> float:
	return [2.4, 1.0, 0.35][RSSolo.difficulty] if solo_mode else 1.0


func bot_ability() -> float:
	return [0.62, 0.9, 0.99][RSSolo.difficulty] if solo_mode else -1.0


func tutorial_for(p: Player) -> RSTutorial:
	return _tutorials.get(p.c.id)


func tutorials_active() -> bool:
	for lesson: RSTutorial in _tutorials.values():
		if lesson.started and not lesson.finished:
			return true
	return false


func review_tutorials() -> void:
	if phase != Phase.LOBBY:
		return
	for p: Player in players.values():
		if not p.fake and p.c.kind != "replay":
			_set_ready(p, false)
			var lesson := RSTutorial.new(game_id())
			lesson.start(p.c)
			_tutorials[p.c.id] = lesson


func _update_tutorials(delta: float) -> void:
	for id in _tutorials.keys():
		var p: Player = players.get(id)
		if p == null:
			_tutorials.erase(id)
			continue
		var lesson: RSTutorial = _tutorials[id]
		lesson.update(p.c, delta)
		if lesson.finished:
			RSProfiles.complete_tutorial(p.c.player, game_id())
			haptic(p, "hit")
			_tutorials.erase(id)
			_oled_lobby(p)


func game_id() -> String:
	return get_script().resource_path.get_base_dir().get_file()


func ranked_players() -> Array:
	## Unified ranking hook. Future games with different win rules may override this.
	var list := ordered()
	list.sort_custom(func(a: Player, b: Player) -> bool:
		return a.score > b.score if a.score != b.score else a.c.player < b.c.player)
	return list


func _add_player(c: RSController, fake: bool) -> Player:
	var p := Player.new()
	p.c = c
	p.fake = fake
	if not fake and c.kind == "phone":
		RSProfiles.import_phone_name(c.player, str(c.info.get("profile_name", "")))
	views.add(p)
	players[c.id] = p
	_player_added(p)
	if not fake and c.kind != "replay" and not RSProfiles.tutorial_done(c.player, game_id()):
		_tutorials[c.id] = RSTutorial.new(game_id())
	return p


func _remove_player(id: int) -> void:
	var p: Player = players[id]
	_player_removed(p)
	views.remove(p)
	players.erase(id)
	_tutorials.erase(id)


func _sync_players() -> void:
	if demo:
		return   # bots only, keep real controllers out of it
	for id in players.keys():
		var p: Player = players[id]
		if not p.fake and (not p.c.connected or (solo_mode and p.c.player != RSSolo.slot)):
			_remove_player(id)
	for c in ControllerHub.connected_controllers():
		if solo_mode and (c.player != RSSolo.slot or c.kind == "replay"):
			continue
		if RSTournament.active() and not RSTournament.entrants.has(c.player):
			continue
		if c.player < 1 or c.player > 4 or players.has(c.id) or players.size() >= 4:
			continue
		var taken := false
		for p: Player in players.values():
			taken = taken or p.c.player == c.player
		if not taken:
			_oled_lobby(_add_player(c, false))
# ------------------------------------------------------------------------- phases ----

func _to_lobby() -> void:
	_music.play_track("lobby")
	phase = Phase.LOBBY
	phase_time = 0.0
	views.visible = false
	lobby_cam.current = true
	ui.show_lobby()
	for p: Player in players.values():
		p.ready = false
		_oled_lobby(p)


func _start_countdown() -> void:
	_music.silence()
	_result_committed = false
	phase = Phase.COUNTDOWN
	phase_time = 0.0
	_beat = -1
	for p: Player in players.values():
		p.score = 0
		p.oled_key = ""
		p.hud.popups.clear()
	_apply_pending_map()
	ui.lobby_panel.visible = false
	views.visible = true
	views.layout()
	lobby_cam.current = false
	_round_started(ordered())


func finish_round() -> void:
	if _result_committed:
		return
	_result_committed = true
	_music.play_track("victory")
	phase = Phase.RESULTS
	phase_time = 0.0
	var list := ranked_players()
	var lines := PackedStringArray()
	var results: Array = []
	var rank := 1
	for i in list.size():
		var p: Player = list[i]
		if i > 0 and p.score != (list[i - 1] as Player).score:
			rank = i + 1
		var fresh := false
		if can_record(p):
			fresh = RSRecords.submit(game_id(), map_index, p.c.player, p.score)
		lines.append(tr("[font_size=30]第 %d 名  [color=#%s]P%d[/color]  %d 分[/font_size]\n[color=#9aa3b5]%s[/color]") % [
			rank, color_of(p).to_html(false), p.c.player, p.score,
			RSProfiles.bbcode(name_of(p)) + " · " + _result_detail(p)])
		if fresh:
			lines.append("[color=#fbbf24]" + tr("新纪录！") + "[/color]")
		if solo_mode and can_record(p) and map_index == 0:
			lines.append(tr("挑战星数：%d / 3（地图 1 个人最佳）") % RSSolo.stars(game_id(), p.c.player))
		results.append({"slot": p.c.player, "rank": rank, "score": p.score})
		send_ui(p, {"clear": true, "title": "RESULT", "main": "#%d" % rank, "sub": "%d PTS" % p.score,
			"legends": ["NEXT" if RSTournament.active() else "AGAIN", "", "MENU", null]})
		haptic(p, "win" if rank == 1 else "hit")
	if RSTournament.active():
		RSTournament.record(game_id(), results)
		lines.append("\n" + tr("大赛总积分 · %d / %d") % [RSTournament.index + 1, RSTournament.games.size()])
		for row: Dictionary in RSTournament.standings():
			lines.append("P%d · %s · %d" % [row["slot"], RSProfiles.bbcode(row["name"]), row["points"]])
		lines.append(tr("大赛完成！A 查看总领奖台") if RSTournament.last_round() else tr("A 进入下一个项目"))
	ui.set_results(lines, results_delay <= 0.0)


func _set_ready(p: Player, value: bool) -> void:
	if value and _tutorials.has(p.c.id):
		return
	p.ready = value
	_player_ready(p, value)
	_oled_lobby(p)


func _on_button(c: RSController, button: int, pressed: bool) -> void:
	if solo_mode and (c.player != RSSolo.slot or c.kind == "replay"):
		return
	# D: a short press toggles the pause menu (a long one is the hub's recenter).
	if button == RSController.BTN_D:
		if pressed:
			_d_down[c.id] = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - int(_d_down.get(c.id, -100000)) < MENU_TAP_MS:
			if ui.pause.is_open():
				ui.pause.back()
			elif players.has(c.id) or players.is_empty():
				open_pause()
		return
	if ui.pause.is_open():
		if pressed:
			ui.pause.on_button(button)
		return
	if pressed and button == RSController.BTN_C and phase in [Phase.LOBBY, Phase.RESULTS]:
		go_menu()
		return
	var p: Player = players.get(c.id)
	if p == null:
		return
	if phase == Phase.LOBBY and _tutorials.has(c.id):
		_tutorials[c.id].on_button(c, button, pressed)
		return
	if phase == Phase.LOBBY and tutorials_active() and button == RSController.BTN_B:
		return
	if pressed and button == RSController.BTN_A and phase == Phase.LOBBY:
		_set_ready(p, not p.ready)
	elif pressed and phase == Phase.LOBBY and button == RSController.BTN_B and _maps().size() > 1:
		pick_map(1)
	elif pressed and phase == Phase.LOBBY:
		_lobby_button(p, button)
	elif pressed and button == RSController.BTN_A and phase == Phase.RESULTS:
		if phase_time > maxf(results_delay, 1.0) and ui.results_panel.visible:
			if RSTournament.active():
				if RSTournament.last_round():
					if not _tournament_final_shown:
						_tournament_final_shown = true
						ui.show_tournament_podium(RSTournament.standings())
						for participant: Player in players.values():
							send_ui(participant, {"clear": true, "title": "PARTY", "main": "FINISHED", "legends": ["MENU", "", "MENU", null]})
					else:
						go_menu()
				else:
					get_tree().change_scene_to_file(RSTournament.advance())
			else:
				_to_lobby()
	elif phase in [Phase.COUNTDOWN, Phase.PLAY]:
		_player_button(p, button, pressed)


func _on_event(c: RSController, ev: String) -> void:
	var p: Player = players.get(c.id)
	if p and ev == "recentered":
		_player_recentered(p)


# --------------------------------------------------------------------------- OLED ----

func send_ui(p: Player, ui: Dictionary) -> void:
	if not p.fake:
		ControllerHub.send_ui(p.c.id, ui)


func vibrate(p: Player, ms: int) -> void:
	if not p.fake:
		ControllerHub.vibrate(p.c.id, ms)


func haptic(p: Player, name: String) -> void:
	## A named vibration (ControllerHub.HAPTICS); prefer these over raw lengths.
	if not p.fake:
		ControllerHub.haptic(p.c.id, name)


func haptic_all(name: String) -> void:
	for p: Player in players.values():
		haptic(p, name)


func toast(p: Player, text: String, ms: int = 700) -> void:
	send_ui(p, {"toast": {"ms": ms, "text": text}})


func _oled_lobby(p: Player) -> void:
	if _tutorials.has(p.c.id):
		send_ui(p, {"clear": true, "title": _oled_name(), "main": "TUTORIAL", "sub": "PRESS A", "legends": ["LEARN", "", "MENU", null]})
		return
	send_ui(p, {"clear": true, "title": _oled_name(), "main": "P%d" % p.c.player, "sub": "READY!" if p.ready else "PRESS A",
		"legends": ["READY", "MAP" if _maps().size() > 1 else "", "MENU", null]})


# --------------------------------------------------------------------------- maps ----

func pick_map(step: int) -> void:
	## Lobby: show the next / previous map on the card now, load it once the picking stops.
	if demo or _maps().size() < 2:
		return
	var from := _pending_map if _pending_map >= 0 else map_index
	_pending_map = posmod(from + step, _maps().size())
	_pending_t = 0.45
	for p: Player in players.values():
		if not p.fake and p.ready:
			_set_ready(p, false)
	RSSfx.play(self, "ding", -10.0, 1.2)
	_update_map_card()


func _apply_pending_map() -> void:
	if _pending_map < 0:
		return
	var m := _pending_map
	_pending_map = -1
	if m != map_index:
		map_index = m
		_last_map[get_script().resource_path] = m
		_load_map(m)
	_update_map_card()


func _update_map_card() -> void:
	if not ui.has_map_card():
		return
	var i := _pending_map if _pending_map >= 0 else map_index
	var m: Dictionary = _maps()[i]
	ui.set_map_card(tr("◀  地图 %d/%d：%s  ▶") % [i + 1, _maps().size(), tr(m["name"])], _map_info(i),
		tr(str(m.get("desc", ""))) + ("" if _pending_map < 0 else tr("　（加载中…）")))
	for p: Player in players.values():
		_oled_lobby(p)


# ----------------------------------------------------------------------------- UI ----

func _build_ui() -> void:
	## Views at the bottom, the shared overlay (countdown, clock) over them, panels on top.
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = RSUi.theme(18)
	layer.add_child(root)
	views = RSPartyViews.new(self)
	root.add_child(views)
	var overlay := Overlay.new()
	overlay.game = self
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(overlay)
	ui = RSPartyUi.new(self)
	root.add_child(ui)


# -------------------------------------------------------------------- HUD drawing ----

func draw_text(ci: CanvasItem, text: String, pos: Vector2, size: float, color: Color, center := false, right := false) -> void:
	## Outlined text; pos is the baseline's start (its centre when `center`, its end when `right`).
	var fs := maxi(8, int(size))
	var at := pos
	if center or right:
		at.x -= font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x * (0.5 if center else 1.0)
	ci.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, maxi(3, fs / 6), Color(0.05, 0.07, 0.12, 0.7))
	ci.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)


func draw_pill(ci: CanvasItem, text: String, center: Vector2, size: float, color: Color = Color.WHITE) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(size)).x + size
	_pill.set_corner_radius_all(int(size * 0.65))
	ci.draw_style_box(_pill, Rect2(center - Vector2(w, size * 1.36) * 0.5, Vector2(w, size * 1.36)))
	draw_text(ci, text, center + Vector2(0, size * 0.36), size, color, true)


func draw_clock(o: Control, seconds: float, k: float, warn_below: float = 10.0) -> void:
	## Shared clock, kept off the players' score corners: top centre for one player, on the
	## seam between views for 2 or 4, big in the empty quarter for 3.
	var t := ceili(seconds)
	var label := "%d:%02d" % [t / 60, t % 60]
	var n := players.size()
	var sz := o.size
	var fs := 38.0 * k
	var mid := Vector2(sz.x * 0.5, 38 * k)
	if n == 2 or n == 4:
		mid = sz * 0.5
	elif n == 3:
		mid = sz * 0.75
		fs = 72.0 * k
		draw_text(o, tr("剩余时间"), mid - Vector2(0, 62 * k), 24 * k, Color(0.85, 0.89, 0.96), true)
	draw_pill(o, label, mid, fs, Color(1.0, 0.45, 0.4) if t <= warn_below and phase == Phase.PLAY else Color.WHITE)


func _hud_draw(h: PlayerHud) -> void:
	var p := h.player
	if phase == Phase.LOBBY:
		return
	var sz := h.size
	var k := clampf(sz.y / 600.0, 0.6, 1.6)
	# Player badge + score, top left.
	_badge.bg_color = color_of(p)
	h.draw_style_box(_badge, Rect2(Vector2(18, 18) * k, Vector2(62, 40) * k))
	draw_text(h, "P%d" % p.c.player, Vector2(49, 47) * k, 26 * k, Color.WHITE, true)
	draw_text(h, str(p.score), Vector2(92, 52) * k, 42 * k, Color.WHITE)
	_draw_hud(h, p, k)
	# Popups, rising and fading.
	var y := sz.y * 0.36
	for i in range(h.popups.size() - 1, -1, -1):
		var age := _clock - float(h.popups[i][2])
		if age > 1.2:
			h.popups.remove_at(i)
			continue
		var c: Color = h.popups[i][1]
		c.a = 1.0 - maxf(age - 0.7, 0.0) / 0.5
		draw_text(h, h.popups[i][0], Vector2(sz.x * 0.5, y - age * 40.0 * k), 34 * k, c, true)
		y -= 44 * k
	if not p.fake and not p.c.connected:
		draw_text(h, tr("手柄断线 —— 等待重连"), Vector2(sz.x * 0.5, sz.y * 0.62), 26 * k, Color(1.0, 0.75, 0.55), true)


func _overlay_draw(o: Overlay) -> void:
	var sz := o.size
	var k := clampf(sz.y / 900.0, 0.6, 2.0)
	_draw_overlay(o, k)
	if phase == Phase.COUNTDOWN and _countdown_time() - phase_time <= COUNTDOWN_TIME:
		draw_text(o, str(maxi(ceili(_countdown_time() - phase_time), 1)), Vector2(sz.x * 0.5, sz.y * 0.45), 150 * k, Color.WHITE, true)
	elif phase == Phase.PLAY and phase_time < 0.8:
		draw_text(o, "GO!", Vector2(sz.x * 0.5, sz.y * 0.45), 150 * k, Color(1, 1, 1, 1.0 - phase_time / 0.8), true)
	if phase != Phase.LOBBY and not demo and not ControllerHub.is_hub_connected():
		draw_text(o, tr("● 未连接 hub —— 请运行 hub/run_hub.bat"), Vector2(sz.x * 0.5, sz.y - 24 * k), 20 * k, Color(1.0, 0.5, 0.45), true)


func _take_shots() -> void:
	if _shots.is_empty() or _shot_i >= shot_times.size() or _clock < shot_times[_shot_i]:
		return
	get_viewport().get_texture().get_image().save_png("%s_%d.png" % [_shots, _shot_i])
	_shot_i += 1
	if _shot_i >= shot_times.size():
		RSExit.quit(get_tree())
