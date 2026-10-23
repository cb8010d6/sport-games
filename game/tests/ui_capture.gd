extends Node
## Reproducible, rendered UI captures; use --static-menu to omit only the 3D backdrop.


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _run() -> void:
	var output := ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--ui-shots="):
			output = arg.trim_prefix("--ui-shots=")
	if output.is_empty():
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	for locale: int in [0, 1]:
		RSSettings.language = locale
		RSLang.apply(locale)
		var menu: Control = load("res://scenes/menu/main_menu.tscn").instantiate()
		add_child(menu)
		var lang := "zh" if locale == 0 else "en"
		await _capture(output.path_join(lang + "-menu.png"))
		for page: String in ["players", "records", "party", "solo", "credits"]:
			menu._pages.open(page)
			await _capture(output.path_join(lang + "-" + page + ".png"))
			menu._pages.close()
		menu._settings.open()
		await _capture(output.path_join(lang + "-settings.png"))
		menu._settings.close()
		menu.queue_free()
		await get_tree().process_frame
	print("RS_UI_CAPTURES_DONE")
	get_tree().quit()


func _capture(path: String) -> void:
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	var err := get_viewport().get_texture().get_image().save_png(path)
	if err != OK:
		push_error("Capture failed: " + path)
