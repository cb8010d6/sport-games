class_name RSRecords
extends RefCounted
## One personal best per slot, game and map. Bots and debug rounds never call submit().

const PATH := "user://records.cfg"
static var _loaded := false
static var _boards: Dictionary = {}


static func load_once() -> void:
	if _loaded:
		return
	_loaded = true
	var cf := RSSave.read(PATH)
	_boards.clear()
	for key: String in cf.get_sections():
		if not cf.has_section_key(key, "entries"):
			continue
		var rows: Variant = cf.get_value(key, "entries", [])
		if not rows is Array:
			continue
		var by_slot: Dictionary = {}
		for row: Variant in rows:
			if row is Dictionary and row.get("slot") is int and row.get("score") is int:
				var slot: int = row["slot"]
				if slot >= 1 and slot <= 4 and row["score"] >= 0:
					if not by_slot.has(slot) or row["score"] > by_slot[slot]["score"]:
						by_slot[slot] = {"slot": slot, "score": row["score"],
							"name": RSProfiles.clean_name(row["name"] if row.get("name") is String else "", slot),
							"date": row["date"] if row.get("date") is String else ""}
		_boards[key] = by_slot.values()


static func key_for(game_id: String, map_id: int) -> String:
	return "%s/map_%d" % [game_id, map_id]


static func leaderboard(game_id: String, map_id: int) -> Array:
	load_once()
	var rows: Array = _boards.get(key_for(game_id, map_id), []).duplicate(true)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["score"] > b["score"] if a["score"] != b["score"] else a["slot"] < b["slot"])
	return rows


static func best(game_id: String, map_id: int, slot: int = 0) -> int:
	for row: Dictionary in leaderboard(game_id, map_id):
		if slot == 0 or row["slot"] == slot:
			return int(row["score"])
	return -1


static func overall_best(game_id: String) -> int:
	load_once()
	var result := -1
	for key: String in _boards:
		if key.begins_with(game_id + "/"):
			for row: Dictionary in _boards[key]:
				result = maxi(result, int(row["score"]))
	return result


static func submit(game_id: String, map_id: int, slot: int, score: int) -> bool:
	if slot < 1 or slot > 4 or score < 0:
		return false
	load_once()
	if score <= best(game_id, map_id, slot):
		return false
	var key := key_for(game_id, map_id)
	var previous: Array = _boards.get(key, []).duplicate(true)
	var rows: Array = []
	for row: Dictionary in previous:
		if row["slot"] != slot:
			rows.append(row)
	rows.append({"slot": slot, "name": RSProfiles.player_name(slot), "score": score,
		"date": Time.get_datetime_string_from_system()})
	_boards[key] = rows
	var cf := ConfigFile.new()
	for board: String in _boards:
		cf.set_value(board, "entries", _boards[board])
	var err := RSSave.write(PATH, cf)
	if err != OK:
		_boards[key] = previous
		push_error("RSRecords: cannot save records (%s)" % error_string(err))
		return false
	return true
