extends Node
## Isolated settings/menu checks and real skate/ski camera integration.
## Cosmetic jitter must not alter RNG consumption, player physics or scores.

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


func _frames(count := 8) -> void:
	for _i in count:
		await get_tree().process_frame


func _run() -> void:
	if OS.get_environment("RS_CAMERA_VERIFY") == "1":
		_check(not RSSettings.camera_shake, "setting survives a new process")
		await _finish()
		return
	get_tree().root.size = Vector2i(1600, 900)
	get_tree().current_scene = null
	var id := OS.get_environment("RS_CAMERA_GAME")
	if id.is_empty():
		await _settings()
	else:
		await _camera(id)
	await _finish()


func _settings() -> void:
	_check(RSSettings.camera_shake, "legacy/default settings keep camera shake")
	RSSettings.camera_shake = false
	RSSettings.save()
	RSSettings._loaded = false
	RSSettings.load_once()
	_check(not RSSettings.camera_shake, "false round trip")
	var cf := RSSave.read(RSSettings.PATH)
	cf.set_value("accessibility", "camera_shake", "false")
	# Keep recovery metadata valid so this tests the field type, not backup recovery.
	_check(RSSave.write(RSSettings.PATH, cf) == OK, "invalid-type fixture has a valid checksum")
	RSSettings._loaded = false
	RSSettings.load_once()
	_check(RSSettings.camera_shake, "invalid string uses the compatible default")
	_scene = (load("res://scenes/menu/main_menu.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(_scene)
	get_tree().current_scene = _scene
	await _frames()
	var index := -1
	for i in _scene.entries.size():
		if _scene.entries[i].get("page", "") == "settings":
			index = i
	_scene._open(index)
	var menu: RSPauseMenu = _scene._settings
	_check(menu.is_open() and get_tree().paused, "main-menu settings pause background")
	menu._choose(menu._items().find("accessibility"))
	await _frames()
	_check(menu._page == "accessibility", "accessibility page reachable")
	_check(menu._title.text == tr("无障碍"), "page title translated")
	var camera_index := menu._items().find("camera_shake")
	menu._choose(camera_index)
	_check(not RSSettings.camera_shake, "A toggles camera shake off")
	_check(menu._oled_label("camera_shake") == ["CAM SHAKE", "OFF"], "OLED reports disabled")
	menu._change(camera_index, -1, false)
	_check(RSSettings.camera_shake, "left arrow toggles camera shake on")
	menu._change(camera_index, 1, false)
	_check(not RSSettings.camera_shake, "right arrow toggles camera shake off")
	cf.load(RSSettings.PATH)
	_check(cf.get_value("accessibility", "camera_shake", true) == false, "menu persists a boolean")
	await _frames()
	var screen := Rect2(Vector2.ZERO, Vector2(1600, 900))
	for row: Button in menu._rows:
		_check(screen.encloses(row.get_global_rect()), "accessibility row stays on screen")
	var output := OS.get_environment("RS_CAMERA_SCREENSHOT")
	if not output.is_empty():
		await RenderingServer.frame_post_draw
		_check(get_viewport().get_texture().get_image().save_png(output) == OK, "settings screenshot saved")
	menu.back()
	_check(menu._page == "settings", "back returns to main settings")
	menu.close()
	_check(not get_tree().paused, "close resumes background")


func _camera(id: String) -> void:
	_scene = (load(RSCatalog.find_game(id)["scene"]) as PackedScene).instantiate()
	get_tree().root.add_child(_scene)
	get_tree().current_scene = _scene
	for _i in 1800:
		await get_tree().process_frame
		if _scene.phase == RSPartyGame.Phase.PLAY:
			break
	_check(_scene.phase == RSPartyGame.Phase.PLAY, "real game reaches play")
	for player: RSPartyGame.Player in _scene.ordered():
		var rider: Variant = _scene._rider(player) if id == "skate" else _scene._racer(player)
		var state: int = _scene._rng.state
		var score := player.score
		var position: Vector3 = rider.sk.pos
		var velocity: Vector3 = rider.sk.vel
		rider.shake = 0.8
		RSSettings.camera_shake = true
		_scene._camera(player, rider, 0.0, false)
		_check(player.cam.global_position.distance_to(rider.cam_pos) > 0.001, "impact produces visible jitter")
		var consumed: int = _scene._rng.state
		_scene._rng.state = state
		rider.shake = 0.8
		RSSettings.camera_shake = false
		_scene._camera(player, rider, 0.0, false)
		_check(player.cam.global_position.is_equal_approx(rider.cam_pos), "disabled impact has no camera offset")
		var stable := Transform3D(Basis.IDENTITY, rider.cam_pos).looking_at(rider.cam_look)
		_check(player.cam.global_basis.is_equal_approx(stable.basis), "disabled impact has no look-at jitter")
		_check(_scene._rng.state == consumed, "disabled jitter consumes identical RNG values")
		_check(rider.sk.pos == position and rider.sk.vel == velocity and player.score == score, "camera setting preserves physics and score")
		RSSettings.camera_shake = true
		rider.shake = 0.0
		_scene._camera(player, rider, 0.0, false)
		_check(player.cam.global_position.is_equal_approx(rider.cam_pos), "enabled camera without impact remains stable")
	# Check that the same page is available during an actual round.
	var menu: RSPauseMenu = _scene.ui.pause
	menu.open()
	await _frames()
	for row: Button in menu._rows:
		_check(Rect2(Vector2.ZERO, Vector2(1600, 900)).encloses(row.get_global_rect()), "in-game pause row stays on screen")
	menu._choose(menu._items().find("accessibility"))
	_check(menu._page == "accessibility", "in-game accessibility page reachable")
	menu.close()


func _finish() -> void:
	get_tree().paused = false
	if is_instance_valid(_scene):
		for audio: AudioStreamPlayer in _scene.find_children("*", "AudioStreamPlayer", true, false):
			audio.stop()
			audio.stream = null
		get_tree().current_scene = null
		_scene.queue_free()
	var until := Time.get_ticks_msec() + 350
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
	print("RS_CAMERA_COMFORT: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)
