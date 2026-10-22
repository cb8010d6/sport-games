class_name RSTournament
extends RefCounted
## Scene-independent party session. Equal scores share the rank and its points.

const POINTS := [10, 7, 5, 3]
static var games: Array = []
static var entrants: Dictionary = {} # slot -> {name, points}
static var index := 0
static var round_done := false


static func active() -> bool:
	return not games.is_empty()


static func begin(selection: Array, slots: Array) -> bool:
	if selection.size() < 3 or selection.size() > 6 or slots.is_empty():
		return false
	var chosen: Array = []
	for game_id: String in selection:
		if RSCatalog.find_game(game_id).is_empty() or game_id in chosen:
			return false
		chosen.append(game_id)
	var people: Dictionary = {}
	for slot: int in slots:
		if slot < 1 or slot > 4:
			return false
		people[slot] = {"name": RSProfiles.player_name(slot), "points": 0}
	games = chosen
	entrants = people
	index = 0
	round_done = false
	return true


static func record(game_id: String, results: Array) -> bool:
	if not active() or round_done or games[index] != game_id:
		return false
	var seen: Array = []
	for row: Dictionary in results:
		var slot := int(row.get("slot", 0))
		if entrants.has(slot) and not slot in seen:
			var rank := clampi(int(row.get("rank", 4)), 1, 4)
			entrants[slot]["points"] += POINTS[rank - 1]
			seen.append(slot)
	round_done = true
	return true


static func standings() -> Array:
	var rows: Array = []
	for slot: int in entrants:
		var row: Dictionary = entrants[slot].duplicate()
		row["slot"] = slot
		rows.append(row)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["points"] > b["points"] if a["points"] != b["points"] else a["slot"] < b["slot"])
	return rows


static func last_round() -> bool:
	return active() and index == games.size() - 1


static func advance() -> String:
	if not active() or not round_done or last_round():
		return ""
	index += 1
	round_done = false
	return RSCatalog.find_game(games[index])["scene"]


static func clear() -> void:
	games.clear()
	entrants.clear()
	index = 0
	round_done = false
