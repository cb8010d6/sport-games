extends Node
const TutorialCases := preload("res://tests/tutorial_cases.gd")
const CatalogCases := preload("res://tests/catalog_cases.gd")
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
	# Quality tiers reach the positional shadow atlas and the rig materials (#57).
	var saved_quality := RSSettings.quality
	var saved_upscale := RSSettings.upscale
	var probe_vp := SubViewport.new()
	RSSettings.quality = 0
	RSSettings.apply_viewport(probe_vp)
	_check(probe_vp.positional_shadow_atlas_size == 1024, "lowest quality shrinks the positional shadow atlas (#57)")
	RSSettings.quality = 3
	RSSettings.apply_viewport(probe_vp)
	_check(probe_vp.positional_shadow_atlas_size == 4096, "top quality keeps the full positional shadow atlas (#57)")
	probe_vp.free()
	var probe_rig := RSHumanRig.new()
	var skin := StandardMaterial3D.new()
	RSSettings.quality = 0
	probe_rig._tune_material(skin, "body")
	_check(not skin.subsurf_scatter_enabled, "lowest quality turns subsurface scattering off (#57)")
	RSSettings.quality = 2
	probe_rig._tune_material(skin, "body")
	_check(skin.subsurf_scatter_enabled, "higher quality keeps subsurface scattering (#57)")
	var hair := StandardMaterial3D.new()
	RSSettings.quality = 0
	probe_rig._tune_material(hair, "ponytail")
	_check(hair.alpha_antialiasing_mode == BaseMaterial3D.ALPHA_ANTIALIASING_OFF, "lowest quality turns alpha-to-coverage off (#57)")
	RSSettings.quality = 2
	probe_rig._tune_material(hair, "ponytail")
	_check(hair.alpha_antialiasing_mode == BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE_AND_TO_ONE, "higher quality keeps alpha-to-coverage (#57)")
	probe_rig.free()
	RSSettings.quality = saved_quality
	RSSettings.upscale = saved_upscale
	# Menu glyph discs come from the RSUi factory (#57).
	var glyph := RSUi.glyph_style()
	_check(glyph.bg_color == RSUi.TEXT and glyph.corner_radius_top_left == 14, "menu glyph style comes from RSUi (#57)")
	# Animated HUD sizes snap to a coarse ladder (#57).
	_check(RSPartyGame._snap_font_size(15.3) == 15, "small font sizes snap to whole pixels (#57)")
	_check(RSPartyGame._snap_font_size(36.9) == 36 and RSPartyGame._snap_font_size(37.4) == 38, "mid font sizes snap to 2px steps (#57)")
	_check(RSPartyGame._snap_font_size(120.0) == 119 and RSPartyGame._snap_font_size(130.0) == 128, "display font sizes snap to wide steps (#57)")
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
	_check(load("res://scenes/menu/main_menu.gd") != null, "main menu compiles")
	CatalogCases.run(_check)
	TutorialCases.run(_check)
	await TutorialCases.integration(self, _check)
	await get_tree().process_frame
	# Let the audio thread release the pause-menu cue before shutting down the test process.
	await get_tree().create_timer(0.25).timeout
	print("RS_SHELL_TESTS: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
