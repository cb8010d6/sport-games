extends Node
## Exercise the real menu with keyboard, mouse and binary UDP controller packets.
## The Python runner supplies disposable player data and optional native screenshots.

var _menu: Variant
var _failures := 0
var _checks := 0
var _udp := PacketPeerUDP.new()


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


func _frames(count := 6) -> void:
	for _i in count:
		await get_tree().process_frame


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	get_viewport().push_input(event)
	event = InputEventKey.new()
	event.keycode = code
	event.pressed = false
	get_viewport().push_input(event)
	await _frames()


func _button(button: int) -> void:
	var packet := PackedByteArray()
	packet.resize(16)
	packet.encode_u8(0, 0x49)
	packet.encode_u8(1, 1)
	packet.encode_u8(2, 231)
	packet.encode_u8(3, button)
	_udp.put_packet(packet)
	await _frames(12)
	packet.encode_u8(3, 0)
	_udp.put_packet(packet)
	await _frames(12)


func _selected(index: int, source: String) -> void:
	var entry: Dictionary = _menu.GAMES[index]
	var card: RSGamePreview = _menu._preview
	_check(_menu._index == index, source + " selects index")
	_check(card.visible and card.game_id == entry["id"], source + " selects preview")
	_check(card._title.text == tr(entry["name"]), source + " translates title")
	_check(_menu._desc.text.begins_with(tr(entry["desc"])), source + " updates description")
	_check(card._image.texture != null and card._image.texture.resource_path.ends_with("/%s.jpg" % entry["id"]), source + " matches texture")
	_check(card._image.texture.get_size() == Vector2(1600, 900), source + " native image dimensions")
	var screen := Rect2(Vector2.ZERO, Vector2(1600, 900))
	_check(screen.encloses(card.get_global_rect()), source + " preview stays on screen")
	_check(not card.get_global_rect().intersects(_menu._menu_grid.get_global_rect()), source + " preview clears buttons")
	_check(card.get_global_rect().encloses(card._image.get_global_rect()), source + " image stays inside card")
	_check(card._title.get_theme_font("font").get_string_size(card._title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 32).x <= card._title.size.x, source + " title fits")


func _capture(id: String) -> void:
	var output := OS.get_environment("RS_MENU_PREVIEW_OUTPUT")
	if output.is_empty():
		return
	await RenderingServer.frame_post_draw
	var picture := get_viewport().get_texture().get_image()
	_check(picture.get_size() == Vector2i(1600, 900), "screenshot resolution")
	_check(picture.save_png(output.path_join(id + ".png")) == OK, "screenshot save")


func _run() -> void:
	# Headless windows do not apply the display-server --resolution flag.
	get_tree().root.size = Vector2i(1600, 900)
	await _frames()
	get_tree().current_scene = null
	_menu = (load("res://scenes/menu/main_menu.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(_menu)
	get_tree().current_scene = _menu
	await _frames(12)
	_selected(0, "initial focus")
	await _key(KEY_RIGHT)
	_selected(1, "keyboard right")
	var hover := InputEventMouseMotion.new()
	hover.position = _menu._buttons[2].get_global_rect().get_center()
	get_viewport().push_input(hover)
	await _frames()
	_selected(2, "mouse hover")
	# Move off the buttons before testing keyboard/controller focus.
	hover = InputEventMouseMotion.new()
	hover.position = Vector2(1580, 880)
	get_viewport().push_input(hover)
	await _frames()
	_udp.set_dest_address("127.0.0.1", ControllerHub.listen_port())
	await _button(RSController.BTN_B)
	_selected(3, "UDP next")
	await _button(RSController.BTN_C)
	_selected(2, "UDP previous")
	for index in RSCatalog.GAMES.size():
		_menu._buttons[index].grab_focus()
		await _frames()
		_selected(index, "catalog %d" % index)
		await _capture(RSCatalog.GAMES[index]["id"])
	_check(_menu._preview._textures.size() == 6, "one cached texture per sport")
	_check(_menu.find_children("*", "RSPartyGame", true, false).is_empty(), "menu does not instantiate sport games")
	_menu._preview.show_game({"id": "missing-preview-test", "name": ""})
	_check(not _menu._preview.visible, "missing art hides preview")
	_menu._restore_focus()
	_check(_menu._preview.visible, "focus restores after missing art")
	for index in range(RSCatalog.GAMES.size(), _menu.GAMES.size()):
		_menu._buttons[index].grab_focus()
		await _frames()
		_check(not _menu._preview.visible, "non-sport hides preview %d" % index)
		if _menu.GAMES[index].has("page"):
			_menu._open(index)
			await _frames()
			_check(not _menu._preview.visible and not _menu._menu_grid.visible, "modal hides menu")
			if _menu.GAMES[index]["page"] == "settings":
				_menu._settings.close()
			else:
				_menu._pages.close()
			await _frames()
			_check(_menu._menu_grid.visible and not _menu._preview.visible, "modal restores non-sport focus")
	await _button(RSController.BTN_B)
	_selected(0, "UDP wrap forward")
	await _button(RSController.BTN_C)
	_check(_menu._index == _menu.GAMES.size() - 1 and not _menu._preview.visible, "UDP wrap backward")
	_udp.close()
	for audio: AudioStreamPlayer in _menu.find_children("*", "AudioStreamPlayer", true, false):
		audio.stop()
		audio.stream = null
	get_tree().current_scene = null
	_menu.queue_free()
	var until := Time.get_ticks_msec() + 350
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
	print("RS_MENU_PREVIEW_TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)
