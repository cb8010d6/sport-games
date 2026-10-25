class_name RSCatalog
extends RefCounted
## Stable IDs are used by saves and party sessions, independent of translated titles.
## Each sport describes itself in game/scenes/<id>/<id>_module.tres (RSGameModule); this class
## discovers them once with ResourceLoader.list_directory, which also lists the remapped files
## of an exported pck. games() is the menu list (ready modules by order); hidden modules can
## still be opened with --game=<id>. tools/catalog.py reads the same files for the tools.

const ROOT := "res://scenes/"
const MAX_OLED := 10

static var _modules: Array[RSGameModule] = []
static var _loaded := false


static func modules(include_hidden := false) -> Array[RSGameModule]:
	if not _loaded:
		_loaded = true
		_modules = _discover()
	var list: Array[RSGameModule] = []
	for m: RSGameModule in _modules:
		if include_hidden or m.ready:
			list.append(m)
	return list


static func module(id: String, include_hidden := false) -> RSGameModule:
	for m: RSGameModule in modules(include_hidden):
		if m.id == id:
			return m
	return null


static func games(include_hidden := false) -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	for m: RSGameModule in modules(include_hidden):
		list.append(_entry(m))
	return list


static func find_game(id: String, include_hidden := false) -> Dictionary:
	var m := module(id, include_hidden)
	return {} if m == null else _entry(m)


static func maps(id: String) -> Array:
	## The MAPS constant named by the manifest (what the game's _maps() returns); [] = one map.
	var m := module(id, true)
	if m == null or m.maps_script.is_empty():
		return []
	var script := load(m.maps_script) as Script
	var value: Variant = script.get_script_constant_map().get("MAPS") if script else null
	if not value is Array:
		push_error("Catalog maps_script has no MAPS array: " + m.maps_script)
		return []
	return value


static func lessons(id: String) -> PackedStringArray:
	var m := module(id, true)
	return PackedStringArray() if m == null else m.lessons


static func solo_goals(id: String) -> Array:
	var m := module(id, true)
	return [] if m == null else Array(m.solo_goals)


static func dump() -> Dictionary:
	## Everything the tools need, hidden modules included (tools/catalog.py reads this JSON).
	var rows: Array = []
	for m: RSGameModule in modules(true):
		var row := _entry(m)
		var names: Array = []
		for map: Dictionary in maps(m.id):
			names.append({"name": str(map.get("name", "")), "en": str(map.get("en", ""))})
		row["maps"] = names
		rows.append(row)
	return {"version": 1, "games": rows}


static func write_dump(path: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(dump(), "\t"))
	file.close()
	return OK


static func _entry(m: RSGameModule) -> Dictionary:
	return {"id": m.id, "name": m.name, "oled": m.oled, "scene": m.scene, "desc": m.desc,
		"maps_script": m.maps_script, "lessons": Array(m.lessons), "solo_goals": Array(m.solo_goals),
		"players": [m.players.x, m.players.y], "mode": m.mode, "ambience": m.ambience,
		"preview": m.preview, "ready": m.ready, "order": m.order}


static func _discover() -> Array[RSGameModule]:
	var found: Array[RSGameModule] = []
	for folder: String in ResourceLoader.list_directory(ROOT):
		if not folder.ends_with("/"):
			continue
		var id := folder.trim_suffix("/")
		var path := ROOT + "%s/%s_module.tres" % [id, id]   # no-i18n
		if not ResourceLoader.exists(path):
			continue
		var m := load(path) as RSGameModule
		var problem := _problem(m, id)
		if problem.is_empty():
			found.append(m)
		else:
			push_error("Invalid game module %s: %s" % [path, problem])
	found.sort_custom(func(a: RSGameModule, b: RSGameModule) -> bool:
		return a.order < b.order if a.order != b.order else a.id < b.id)
	return found


static func _problem(m: RSGameModule, folder: String) -> String:
	if m == null:
		return "not an RSGameModule"
	if m.id != folder:
		return "id must equal the folder name"
	if m.name.is_empty() or m.desc.is_empty():
		return "missing name or desc"
	if m.oled.is_empty() or m.oled.length() > MAX_OLED or m.oled != m.oled.to_upper() or not _ascii(m.oled):
		return "oled must be ASCII capitals, at most %d characters" % MAX_OLED
	if not ResourceLoader.exists(m.scene):
		return "scene not found"
	if not m.maps_script.is_empty() and not ResourceLoader.exists(m.maps_script):
		return "maps_script not found"
	if m.players.x < 1 or m.players.y > 4 or m.players.x > m.players.y:
		return "players must lie within 1-4"
	if m.mode not in RSGameModule.MODES:
		return "unknown mode"
	return ""


static func _ascii(text: String) -> bool:
	for i in text.length():
		if text.unicode_at(i) < 32 or text.unicode_at(i) > 126:
			return false
	return true
