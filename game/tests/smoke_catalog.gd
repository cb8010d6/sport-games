extends Node
## Read the lobby's real map lists without building the worlds or connecting controllers.


func _ready() -> void:
	var output := ""
	var selected := PackedStringArray()
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--catalog-output="):
			output = arg.trim_prefix("--catalog-output=")
		elif arg.begins_with("--games="):
			selected = arg.trim_prefix("--games=").split(",")
	if output.is_empty():
		push_error("Missing smoke catalog output path")
		get_tree().quit(1)
		return
	var cases: Array = []
	for entry: Dictionary in RSCatalog.GAMES:
		var id: String = entry["id"]
		if not selected.is_empty() and id not in selected:
			continue
		var scene := load(entry["scene"]) as PackedScene
		if scene == null:
			get_tree().quit(1)
			return
		var game := scene.instantiate() as RSPartyGame
		if game == null:
			push_error("Catalog scene must extend RSPartyGame: " + id)
			get_tree().quit(1)
			return
		var maps := game._maps()
		for index in maxi(maps.size(), 1):
			var map_name: String = str(maps[index].get("en", maps[index].get("name", ""))) if not maps.is_empty() else "Default"
			cases.append({"game": id, "scene": entry["scene"], "map": index, "map_name": map_name})
		game.free()
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write smoke catalog")
		get_tree().quit(1)
		return
	file.store_string(JSON.stringify(cases))
	file.close()
	print("RS_SMOKE_CATALOG_DONE")
	get_tree().quit()
