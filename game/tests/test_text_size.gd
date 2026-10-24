extends Node
## Isolated accessibility persistence, live UI sizing and actual sport HUD integration.
## Uses real scene scripts; the test subclass only records rendered text bounds.

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


func _frames(count := 10) -> void:
	for _i in count:
		await get_tree().process_frame


func _capture(suffix: String) -> void:
	var path := OS.get_environment("RS_TEXT_SCREENSHOT")
	if path.is_empty():
		return
	await RenderingServer.frame_post_draw
	_check(get_viewport().get_texture().get_image().save_png(path.trim_suffix(".png") + suffix + ".png") == OK, "native screenshot saved")


func _run() -> void:
	get_tree().root.size = Vector2i(1600, 900)
	get_tree().current_scene = null
	if OS.get_environment("RS_TEXT_VERIFY") == "1":
		_check(RSSettings.text_size == 1, "large text survives a new process")
		_check(RSUi.text_size(24) == 30, "new process uses saved scale")
	elif OS.get_environment("RS_TEXT_GAME").is_empty():
		await _settings()
	else:
		await _game(OS.get_environment("RS_TEXT_GAME"))
	await _finish()


func _reload(value: Variant) -> void:
	var cf := RSSave.read(RSSettings.PATH)
	cf.set_value("accessibility", "text_size", value)
	_check(RSSave.write(RSSettings.PATH, cf) == OK, "typed fixture has valid metadata")
	RSSettings._loaded = false
	RSSettings.load_once()


func _settings() -> void:
	_check(RSSettings.text_size == 0, "old settings default to standard")
	for value: Variant in ["1", true, 1.5, -5, 99, 1, 0]:
		_reload(value)
		_check(RSSettings.text_size == (1 if typeof(value) == TYPE_INT and value > 0 else 0), "invalid types default; integer values clamp")
	var host := Control.new()
	host.theme = RSUi.theme(20)
	add_child(host)
	var label := RSUi.label("Sample", 24)
	host.add_child(label)
	var button := Button.new()
	host.add_child(button)
	var rich := RichTextLabel.new()
	rich.bbcode_enabled = true
	RSUi.set_text_size(rich, 18, &"normal_font_size")
	host.add_child(rich)
	RSUi.set_rich_text(rich, "[font_size=30]P1[/font_size] [lb]font_size=999]")
	RSSettings.text_size = 1
	for _i in 3:
		RSUi.apply_text_sizes(host)
	await _frames()
	_check(label.get_theme_font_size("font_size") == 30, "explicit font scales once")
	_check(button.get_theme_font_size("font_size") == 25, "theme inheritance scales once")
	_check(rich.get_theme_font_size("normal_font_size") == 23, "rich normal size scales")
	_check(rich.text == "[font_size=38]P1[/font_size] [lb]font_size=999]", "BBCode scales once; escaped player text remains literal")
	var fresh := RSUi.label("New", 24)
	_check(fresh.get_theme_font_size("font_size") == 30, "new controls use current size")
	fresh.free()
	RSSettings.text_size = 0
	RSUi.apply_text_sizes(host)
	_check(label.get_theme_font_size("font_size") == 24 and host.theme.default_font_size == 20, "standard restores original sizes")
	_check(rich.text.begins_with("[font_size=30]"), "standard restores original BBCode")
	host.queue_free()
	await _frames()
	_scene = (load("res://scenes/menu/main_menu.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(_scene)
	get_tree().current_scene = _scene
	await _frames()
	var settings_index := -1
	for i in _scene.GAMES.size():
		if _scene.GAMES[i].get("page", "") == "settings":
			settings_index = i
	_scene._open(settings_index)
	var menu: RSPauseMenu = _scene._settings
	menu._choose(menu._items().find("accessibility"))
	menu._choose(menu._items().find("text_size"))
	await _frames()
	_check(RSSettings.text_size == 1 and get_tree().paused, "setting changes live while paused")
	_check(menu._oled_label("text_size") == ["TEXT SIZE", "125%"], "OLED exposes current size")
	_check(menu._rows[0].get_theme_font_size("font_size") == 30, "existing settings button resized")
	for row: Button in menu._rows:
		_check(_screen().encloses(row.get_global_rect()), "large settings row remains on screen")
	await _capture("-settings")
	menu.back()
	await _frames()
	for row: Button in menu._rows:
		_check(_screen().encloses(row.get_global_rect()), "large home setting remains on screen")
	menu.close()
	await _frames()
	var scroll: ScrollContainer = _scene._menu_grid.get_parent()
	_check(scroll.follow_focus, "sport list follows focus")
	for item: Button in _scene._buttons:
		item.grab_focus()
		await _frames(3)
		_check(scroll.get_global_rect().grow(1).encloses(item.get_global_rect()), "each focused sport remains visible")
		_check(_screen().encloses(item.get_global_rect()), "focused menu item remains on screen")
	_scene._buttons[0].grab_focus()
	await _frames()
	await _capture("-menu")
	for page: String in ["players", "solo", "party", "records", "credits"]:
		_scene._pages.open(page)
		await _frames()
		for item: Control in _scene._pages._focus:
			item.grab_focus()
			await _frames(3)
			_check(_screen().encloses(item.get_global_rect()), "modal focused control stays on screen: " + page)
		await _capture("-" + page)
		_scene._pages.close()
	_check(RSSettings.save() == OK, "large text persisted for new process")


func _screen() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(1600, 900))


func _game(id: String) -> void:
	RSSettings.text_size = 1
	var script := GDScript.new()
	script.source_code = """extends "%s"
var text_bounds: Dictionary = {}
var clock_bounds := Rect2()
var time_label_bounds := Rect2()
func _hud_draw(h: PlayerHud) -> void:
	text_bounds[h.get_instance_id()] = []
	super._hud_draw(h)
func draw_text(ci: CanvasItem, text: String, pos: Vector2, size: float, color: Color, center := false, right := false, f: Font = null) -> void:
	if ci is PlayerHud or ci is Overlay:
		var used: Font = font if f == null else f
		var bounds: Vector2 = ci.size
		var width: float = 2.0 * minf(pos.x - 4.0, bounds.x - pos.x - 4.0) if center else (pos.x - 4.0 if right else bounds.x - pos.x - 4.0)
		var fs := RSUi.fit_text_size(text, size, width, pos.y - 4.0, bounds.y - 8.0, used)
		var w := used.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var at := pos - Vector2(w * (0.5 if center else (1.0 if right else 0.0)), used.get_ascent(fs))
		var rect := Rect2(at, Vector2(w, used.get_height(fs)))
		if ci is PlayerHud:
			text_bounds[ci.get_instance_id()].append([text, rect])
		elif text == tr("剩余时间"):
			time_label_bounds = rect
	super.draw_text(ci, text, pos, size, color, center, right, f)
func _plate_rect(text: String, center: Vector2, fs: int, f: Font) -> Rect2:
	var rect := super._plate_rect(text, center, fs, f)
	if text.contains(":"):
		clock_bounds = rect
	return rect
""" % (RSCatalog.find_game(id)["scene"] as String).replace(".tscn", ".gd")
	_check(script.reload() == OK, "instrumented actual scene compiles")
	_scene = script.new()
	get_tree().root.add_child(_scene)
	get_tree().current_scene = _scene
	for _i in 1800:
		await get_tree().process_frame
		if _scene.phase == RSPartyGame.Phase.PLAY:
			break
	_check(_scene.phase == RSPartyGame.Phase.PLAY, "actual game reaches play")
	# Show the regular HUD rather than the first few frames' GO banner / archery round card.
	for _i in 900:
		await get_tree().process_frame
		if _scene.phase_time >= 3.5:
			break
	await _capture("-play")
	if _scene.players.size() == 3:
		_check(_scene.time_label_bounds.size.x > 0 and not _scene.clock_bounds.intersects(_scene.time_label_bounds), "three-player clock clears its enlarged caption")
	for player: RSPartyGame.Player in _scene.ordered():
		var rows: Array = _scene.text_bounds.get(player.hud.get_instance_id(), [])
		_check(not rows.is_empty(), "actual HUD produced text")
		var speed_rect := Rect2()
		for row: Array in rows:
			if (row[0] as String).ends_with(" km/h"):
				speed_rect = row[1]
		for row: Array in rows:
			_check(Rect2(Vector2.ZERO, player.hud.size).grow(1).encloses(row[1]), "rendered HUD text inside cell: " + row[0])
			var global_text := Rect2((row[1] as Rect2).position + player.hud.global_position, (row[1] as Rect2).size)
			_check(not _scene.clock_bounds.intersects(global_text), "clock clears player text: " + row[0])
			if id == "ski" and row[0] == tr("团身"):
				_check(not speed_rect.intersects(row[1]), "large speed and tuck hint do not overlap")
	var menu: RSPauseMenu = _scene.ui.pause
	menu.open()
	await _frames()
	for row: Button in menu._rows:
		_check(_screen().encloses(row.get_global_rect()), "large in-game pause row inside screen")
	menu._choose(menu._items().find("accessibility"))
	var clock: float = _scene.phase_time
	var scores: Array = _scene.ordered().map(func(p: RSPartyGame.Player) -> int: return p.score)
	menu._change(menu._items().find("text_size"), -1, false)
	menu._change(menu._items().find("text_size"), 1, false)
	await _frames()
	_check(_scene.phase_time == clock and scores == _scene.ordered().map(func(p: RSPartyGame.Player) -> int: return p.score), "live text change preserves paused round and scores")
	menu.close()
	if id == "basketball":
		# Worst-case simultaneous feedback, at the verdict's largest animated size.
		_scene.set_process(false)
		for player: RSPartyGame.Player in _scene.ordered():
			var shot: Variant = _scene._sh(player)
			shot.flash = tr("进了！")
			shot.flash_t = _scene._clock
			shot.st = RSBasketballGame.St.DONE
			player.hud.popups.clear()
			player.popup("+100", Color.WHITE)
		await _frames()
		for player: RSPartyGame.Player in _scene.ordered():
			var meter := RSBasketballHud.power_meter_rect(player.hud.size, clampf(player.hud.size.y / 600.0, 0.6, 1.6))
			meter.position += player.hud.global_position
			_check(not _scene.clock_bounds.intersects(meter), "clock clears the actual basketball power meter")
			var feedback: Array[Rect2] = []
			for row: Array in _scene.text_bounds[player.hud.get_instance_id()]:
				if row[0] in [tr("进了！"), tr("投完了！"), "+100"]:
					feedback.append(row[1])
			_check(feedback.size() == 3, "simultaneous shot, score and done feedback rendered")
			for i in feedback.size():
				for j in i:
					_check(not feedback[i].intersects(feedback[j]), "large basketball feedback does not overlap")
		await _capture("-feedback")
	# Four-player rich results use the real formatter, without writing demo records.
	_scene.finish_round()
	_scene.ui.results_on_right(true)
	await _frames()
	_scene.ui.results_panel.visible = true
	await _frames()
	_check(_scene.ui._results_text.text.contains("[font_size=38]"), "real result formatter enlarged")
	_check(_screen().encloses(_scene.ui._results_text.get_global_rect()), "large results stay inside screen")
	await _capture("-results")
	# Exercise the real tutorial cards with each project's longest practice instruction.
	_scene.set_process(false)
	_scene.phase = RSPartyGame.Phase.LOBBY
	_scene.ui.results_panel.visible = false
	_scene.ui._tutorial_roster = ""
	for player: RSPartyGame.Player in _scene.ordered():
		var lesson := RSTutorial.new(id)
		lesson.start(player.c)
		for i in lesson.steps.size():
			if tr(lesson.steps[i]["text"]).length() > tr(lesson.steps[lesson.index]["text"]).length():
				lesson.index = i
		_scene._tutorials[player.c.id] = lesson
	_scene.ui._update_tutorials()
	await _frames()
	_check(_scene.ui._tutorial_panel.visible and not _scene.ui._tutorial_cards.is_empty(), "real tutorial cards are visible")
	for card: Dictionary in _scene.ui._tutorial_cards.values():
		_check(_screen().encloses(card["hint"].get_global_rect()), "large tutorial hint stays on screen")
		_check(not card["hint"].get_global_rect().intersects(card["cue"].get_global_rect()), "large hint clears the demonstration")
	await _capture("-tutorial")


func _finish() -> void:
	get_tree().paused = false
	if is_instance_valid(_scene):
		get_tree().current_scene = null
		_scene.queue_free()
	await _frames(1)
	print("RS_TEXT_SIZE: %d checks, %d failures" % [_checks, _failures])
	RSExit.quit(get_tree(), 1 if _failures else 0)
