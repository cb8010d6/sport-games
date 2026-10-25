extends Node
const TutorialCases := preload("res://tests/tutorial_cases.gd")
const CatalogCases := preload("res://tests/catalog_cases.gd")
const WaterCases := preload("res://tests/water_cases.gd")
const SwingCases := preload("res://tests/swing_cases.gd")
const SwingClassifyCases := preload("res://tests/swing_classify_cases.gd")
## Run this scene with an isolated APPDATA directory; it writes actual ConfigFile saves.

var _failures := 0


func _ready() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1":
		push_error("Use tools/test_game.py: these tests need an isolated user data directory.")
		get_tree().quit(1)
		return
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		push_error("FAIL: " + message)


func _run() -> void:
	_check(RSProfiles.clean_name("  Test\nName  ") == "TestName", "nickname sanitization")
	_check(RSProfiles.bbcode("[b]Name") == "[lb]b]Name", "rich text nickname escaping")
	_check(RSProfiles.update(1, "Example Player", 5, 3) == OK, "profile save")
	RSProfiles._loaded = false
	_check(RSProfiles.player_name(1) == "Example Player" and RSProfiles.avatar(1) == 3, "profile round trip")
	RSProfiles.import_phone_name(1, "Example Phone")
	_check(RSProfiles.player_name(1) == "Example Phone", "phone nickname import")
	RSProfiles.update(1, "Manual Name", 2, 1)
	RSProfiles.import_phone_name(1, "Example Phone")
	_check(RSProfiles.player_name(1) == "Manual Name", "unchanged phone nickname does not overwrite local edit")
	RSRecords._loaded = true
	RSRecords._boards.clear()
	_check(RSRecords.submit("ski", 0, 1, 100), "first record")
	_check(not RSRecords.submit("ski", 0, 1, 90), "lower score ignored")
	_check(not RSRecords.submit("ski", 0, 1, 100), "equal score ignored")
	_check(RSRecords.submit("ski", 1, 1, 50), "maps isolated")
	_check(RSRecords.submit("ski", 0, 2, 100), "second profile")
	_check(not RSRecords.submit("ski", 0, 0, 1000), "invalid slot ignored")
	RSRecords._loaded = false
	RSRecords._boards.clear()
	_check(RSRecords.best("ski", 0, 1) == 100 and RSRecords.best("ski", 1, 1) == 50, "record round trip")
	_check(RSRecords.best("archery", 0) == -1, "games isolated")
	_check(RSRecords.leaderboard("ski", 0).size() == 2, "one best per player")
	var game := RSPartyGame.new()
	var player := RSPartyGame.Player.new()
	player.c = RSController.new()
	player.c.kind = "phone"
	_check(game.can_record(player), "standard phone match can record")
	player.c.kind = "replay"
	_check(not game.can_record(player), "recorded controller replay cannot set a record")
	player.c.kind = "phone"
	player.fake = true
	_check(not game.can_record(player), "bot cannot record")
	player.fake = false
	game._records_enabled = false
	_check(not game.can_record(player), "custom rules cannot record")
	game.free()
	var selection := ["plane", "archery", "bowling"]
	_check(not RSTournament.begin(["plane", "plane", "ski"], [1]), "duplicate game rejected")
	_check(not RSTournament.begin(selection, []), "empty party rejected")
	_check(RSTournament.begin(selection, [1, 2, 3]), "party start")
	var results := [{"slot": 1, "rank": 1}, {"slot": 2, "rank": 1}, {"slot": 3, "rank": 3}]
	_check(not RSTournament.record("ski", results), "wrong scene cannot score")
	_check(RSTournament.record("plane", results), "party score")
	_check(not RSTournament.record("plane", results), "duplicate score rejected")
	_check(RSTournament.entrants[1]["points"] == 10 and RSTournament.entrants[2]["points"] == 10 and RSTournament.entrants[3]["points"] == 5, "ties share rank points")
	_check(RSTournament.advance().contains("archery"), "advance changes scene")
	_check(RSTournament.advance().is_empty(), "cannot skip unfinished round")
	RSTournament.record("archery", results)
	RSTournament.advance()
	_check(RSTournament.last_round(), "last round")
	RSTournament.record("bowling", results)
	_check(RSTournament.advance().is_empty(), "last round cannot advance")
	_check(RSTournament.standings()[0]["points"] == 30, "party totals")
	RSTournament.clear()
	_check(not RSTournament.active(), "party cancel")
	var ui_game := RSPartyGame.new()
	var party_ui := RSPartyUi.new(ui_game)
	add_child(party_ui)
	party_ui.show_tournament_podium([
		{"slot": 1, "name": "P1", "points": 30},
		{"slot": 2, "name": "P2", "points": 30},
		{"slot": 3, "name": "P3", "points": 10},
	])
	var display_heights: Array = []
	for col: Node in party_ui._results_col.get_children():
		if col is HBoxContainer:
			for cell: Node in col.get_children():
				for part: Node in (cell as VBoxContainer).get_children():
					if part is PanelContainer:
						display_heights.append((part as PanelContainer).custom_minimum_size.y)
	_check(display_heights == [180.0, 180.0, 95.0], "tied tournament ranks share the podium height (#57)")
	party_ui.queue_free()
	await get_tree().process_frame
	ui_game.free()
	RSAudio.set_volume(RSAudio.MUSIC, 0)
	_check(AudioServer.is_bus_mute(AudioServer.get_bus_index(RSAudio.MUSIC)), "music mute")
	RSSettings.volumes = [9, 0, 6, 5]
	RSSettings.color_safe = true
	RSSettings.save()
	RSSettings._loaded = false
	RSSettings.load_once()
	_check(RSSettings.volumes == [9, 0, 6, 5] and RSSettings.color_safe, "settings round trip")
	_quality_cases()
	# Menu glyph discs come from the RSUi factory (#57).
	var glyph := RSUi.glyph_style()
	_check(glyph.bg_color == RSUi.TEXT and glyph.corner_radius_top_left == 14, "menu glyph style comes from RSUi (#57)")
	_font_cases()
	var hub_events := [0]
	ControllerHub.controller_connected.connect(func(_c: RSController) -> void: hub_events[0] += 1)
	var hub_event := func(ev: String) -> PackedByteArray:
		return JSON.stringify({"type": "event", "controller": 9, "name": ev}).to_utf8_buffer()
	ControllerHub._handle_json(hub_event.call("connected"))
	_check(hub_events[0] == 1, "first connect emits controller_connected")
	ControllerHub._handle_json(JSON.stringify({"type": "roster", "controllers": [{"id": 9, "kind": "phone", "name": "T", "player": 1, "connected": true}]}).to_utf8_buffer())
	_check(hub_events[0] == 1, "roster after the connect event does not emit twice")
	ControllerHub._handle_json(hub_event.call("disconnected"))
	ControllerHub._handle_json(hub_event.call("connected"))
	_check(hub_events[0] == 2, "reconnect emits controller_connected again (#50)")
	# #55: disconnecting mid-hold cancels the button (never a plain release),
	# exactly once, and clears the held state.
	var cancels := [0]
	var plain_releases := [0]
	ControllerHub.button_cancelled.connect(func(_c: RSController, _b: int) -> void: cancels[0] += 1)
	ControllerHub.button_released.connect(func(_c: RSController, _b: int) -> void: plain_releases[0] += 1)
	ControllerHub.controllers[9].buttons = RSController.BTN_A
	ControllerHub._handle_json(hub_event.call("disconnected"))
	ControllerHub._handle_json(hub_event.call("disconnected"))
	_check(cancels[0] == 1 and plain_releases[0] == 0, "disconnect mid-hold cancels the button once, without a release (#55)")
	_check(ControllerHub.controllers[9].buttons == 0, "disconnect clears the held buttons (#55)")
	# The roster alone reporting it offline -- no disconnected event -- cancels
	# the same way, and a repeat does not cancel twice; with the held buttons
	# cleared, no late release can surface when it comes back (#55).
	var roster9 := func(online: bool) -> PackedByteArray:
		return JSON.stringify({"type": "roster", "controllers": [{"id": 9, "kind": "phone", "name": "T", "player": 1, "connected": online}]}).to_utf8_buffer()
	ControllerHub._handle_json(roster9.call(true))
	ControllerHub.controllers[9].buttons = RSController.BTN_A
	ControllerHub._handle_json(roster9.call(false))
	_check(cancels[0] == 2 and plain_releases[0] == 0, "roster-only offline cancels the held button, no event needed (#55)")
	_check(ControllerHub.controllers[9].buttons == 0, "roster-only offline clears the held buttons (#55)")
	ControllerHub._handle_json(roster9.call(false))
	ControllerHub._handle_json(hub_event.call("disconnected"))
	_check(cancels[0] == 2, "repeated offline roster/event does not cancel twice (#55)")
	ControllerHub.controllers.erase(9)
	var pause := RSPauseMenu.new(self, true)
	add_child(pause)
	pause.open()
	_check(get_tree().paused and pause.is_open(), "main menu settings open")
	_check(ControllerHub.process_mode == Node.PROCESS_MODE_ALWAYS, "controller hub opts out of pausing itself")
	_check(ControllerHub.can_process(), "controller hub keeps polling while settings pause the tree (#56)")
	pause._choose(0) # display
	pause.back()
	_check(pause._page == "settings", "settings back navigation")
	pause.close()
	_check(not get_tree().paused, "settings close unpauses")
	pause.queue_free()
	var pages := RSMenuPages.new()
	add_child(pages)
	for page: String in ["players", "records", "party", "credits"]:
		pages.open(page)
		_check(pages.visible and pages._focus.size() > 0, "menu page: " + page)
		pages.close()
	pages.queue_free()
	# A controller that drops out of the roster is kept, only marked
	# disconnected: player state keys on the RSController object, so the same
	# id coming back must reuse it (#45, review of the local purge).
	var dropped := [0]
	ControllerHub.controller_disconnected.connect(func(_c: RSController) -> void: dropped[0] += 1)
	ControllerHub._handle_json(JSON.stringify({"type": "roster", "controllers": [{"id": 7, "kind": "phone", "name": "T", "player": 1, "connected": true}]}).to_utf8_buffer())
	_check(ControllerHub.controllers.has(7), "roster adds the controller locally")
	var kept: RSController = ControllerHub.controllers[7]
	ControllerHub._handle_json(JSON.stringify({"type": "roster", "controllers": []}).to_utf8_buffer())
	_check(ControllerHub.controllers.get(7) == kept and not kept.connected, "controller missing from the next roster is kept, marked disconnected (#45)")
	_check(dropped[0] == 1, "dropped controller emits controller_disconnected once")
	ControllerHub._handle_json(JSON.stringify({"type": "roster", "controllers": [{"id": 7, "kind": "phone", "name": "T", "player": 1, "connected": true}]}).to_utf8_buffer())
	_check(ControllerHub.controllers.get(7) == kept and kept.connected, "returning id reuses the same controller object (#45)")
	# Vanishing from the roster mid-hold cancels the held buttons too (#55).
	var vanish_cancels := [0]
	ControllerHub.button_cancelled.connect(func(_c: RSController, _b: int) -> void: vanish_cancels[0] += 1)
	kept.buttons = RSController.BTN_B
	ControllerHub._handle_json(JSON.stringify({"type": "roster", "controllers": []}).to_utf8_buffer())
	_check(vanish_cancels[0] == 1 and kept.buttons == 0, "vanishing from the roster cancels held buttons (#45/#55)")
	_check(load("res://scenes/menu/main_menu.gd") != null, "main menu compiles")
	CatalogCases.run(_check)
	WaterCases.run(_check)
	TutorialCases.run(_check)
	SwingCases.run(_check)
	SwingClassifyCases.run(_check)
	await TutorialCases.integration(self, _check)
	await get_tree().process_frame
	# Let the audio thread release the pause-menu cue before shutting down the test process.
	await get_tree().create_timer(0.25).timeout
	print("RS_SHELL_TESTS: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)


func _quality_cases() -> void:
	var saved_quality := RSSettings.quality
	var saved_upscale := RSSettings.upscale
	var orphan_count := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var probe_vp := SubViewport.new()
	var probe_rig := RSHumanRig.new()
	# Concrete rigs parent body while building; this material-only probe must own it too.
	probe_rig.add_child(probe_rig.body)
	var skin := StandardMaterial3D.new()
	var hair := StandardMaterial3D.new()
	for upscale: int in RSSettings.UPSCALE_SCALES.size():
		RSSettings.upscale = upscale
		for quality: int in RSSettings.QUALITY_NAMES.size():
			RSSettings.quality = quality
			RSSettings.apply_viewport(probe_vp)
			_check(probe_vp.positional_shadow_atlas_size == [1024, 2048, 4096, 4096][quality], "positional atlas follows every quality tier (#57)")
			probe_rig._tune_material(skin, "body")
			_check(skin.subsurf_scatter_enabled == (quality >= 2), "skin SSS follows every quality tier (#57)")
			# Reuse the material to also catch stale A2C after high -> low or native -> FSR.
			probe_rig._tune_material(hair, "ponytail")
			var expected := BaseMaterial3D.ALPHA_ANTIALIASING_OFF if probe_vp.msaa_3d == Viewport.MSAA_DISABLED else BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE_AND_TO_ONE
			_check(hair.alpha_antialiasing_mode == expected, "hair alpha-to-coverage agrees with actual viewport MSAA (#57)")
	probe_vp.free()
	probe_rig.free()
	_check(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == orphan_count, "quality probes release all owned nodes (#57)")
	RSSettings.quality = saved_quality
	RSSettings.upscale = saved_upscale


func _font_cases() -> void:
	var previous := 0
	var monotonic := true
	var idempotent := true
	var rounds_down := true
	var bounded_steps := true
	for sample: int in range(16, 6401):
		var requested := sample / 16.0
		var snapped := RSUi.snap_font_size(requested)
		monotonic = monotonic and snapped >= previous
		idempotent = idempotent and RSUi.snap_font_size(snapped) == snapped
		rounds_down = rounds_down and RSUi.snap_font_size(requested, true) <= requested
		if previous >= 64:
			bounded_steps = bounded_steps and snapped - previous <= previous / 32.0
		previous = snapped
	_check(monotonic and idempotent and rounds_down and bounded_steps, "font ladder is monotonic, idempotent, bounded and safe to round down (#57)")
	var saved_text_size := RSSettings.text_size
	for text_setting: int in RSSettings.TEXT_SCALES.size():
		RSSettings.text_size = text_setting
		for viewport_scale: float in [0.6, 1.0, 1.6, 2.0]:
			for animation: Vector2 in [Vector2(36, 45), Vector2(40, 47.2), Vector2(120, 150), Vector2(130, 149.5), Vector2(36.48, 39.52)]:
				var sizes := {}
				for frame: int in range(129):
					var base := lerpf(animation.x, animation.y, frame / 128.0) * viewport_scale
					sizes[RSUi.snap_font_size(RSUi.text_size(base))] = true
				_check(sizes.size() <= 16, "each HUD animation uses a bounded set of raster sizes at either text scale (#57)")
		var f := RSUi.font_bold()
		for width: float in [92.0, 240.0]:
			var fs := RSUi.fit_text_size("倒数测试", 150.0, width, 90.0, 140.0, f, true) # no-i18n: font metrics fixture
			_check(fs == RSUi.snap_font_size(fs), "fitted HUD text stays on the font ladder (#57)")
			_check(f.get_string_size("倒数测试", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= width and f.get_ascent(fs) <= 90.0 and f.get_descent(fs) <= 50.0, "snapped HUD text respects all fit bounds (#57)") # no-i18n: font metrics fixture
	RSSettings.text_size = saved_text_size
