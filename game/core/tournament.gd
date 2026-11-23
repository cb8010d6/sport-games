class_name RSTournament
extends RefCounted
## Scene-independent party session. Equal scores share the rank and its points.

const POINTS := [10, 7, 5, 3]
static var games: Array = []
static var entrants: Dictionary = {} # slot -> {name, points}
static var index := 0
static var round_done := false


class ExitGuard:
	## Per-game input state. Time/phase/eligibility come from RSPartyGame; no scene or UI access.
	const SECONDS := 3.0
	var eligible: Callable
	var controller: RSController
	var _slot := 0
	var _phase := -1
	var _until := 0.0

	func pending() -> bool:
		return controller != null

	func clear() -> void:
		controller = null
		_slot = 0
		_phase = -1
		_until = 0.0

	func validate(active: bool, phase: int, now: float) -> void:
		if controller != null and (not active or phase != _phase or now >= _until or controller.player != _slot or not _allowed(controller)):
			clear()

	func request(c: RSController, phase: int, now: float) -> bool:
		if not _allowed(c):
			return false
		validate(true, phase, now)
		if controller == c:
			clear()
			return true
		controller = c
		_slot = c.player
		_phase = phase
		_until = now + SECONDS
		return false

	func lost(c: RSController) -> void:
		if controller != null and controller.id == c.id:
			clear()

	func _allowed(c: RSController) -> bool:
		return c != null and eligible.is_valid() and bool(eligible.call(c))


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
	# Missing slots keep earlier points and receive zero for this event, without last-place points.
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


static func missing(results: Array) -> PackedInt32Array:
	var slots := PackedInt32Array()
	for slot: int in entrants:
		var present := false
		for row: Dictionary in results:
			present = present or int(row.get("slot", 0)) == slot
		if not present:
			slots.append(slot)
	return slots


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
