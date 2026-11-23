class_name RSSolo
extends RefCounted
## One human and one physical AI opponent. Challenge stars are derived from existing
## official map-0 records, so demos/custom rules cannot create progress or save files.
## The goals come from each game's RSGameModule manifest (solo_goals).

const DIFFICULTIES := ["简单", "普通", "困难"]
static var game_id := ""
static var slot := 1
static var difficulty := 1


static func begin(id: String, player_slot: int, level: int) -> String:
	var entry := RSCatalog.find_game(id)
	if entry.is_empty() or goals(id).is_empty() or player_slot < 1 or player_slot > 4 or level < 0 or level > 2:
		return ""
	game_id = id
	slot = player_slot
	difficulty = level
	RSTournament.clear()
	return entry["scene"]


static func clear() -> void:
	game_id = ""


static func active(id: String) -> bool:
	return not game_id.is_empty() and game_id == id


static func opponent_slot() -> int:
	return slot % 4 + 1


static func difficulty_name() -> String:
	return RSLang.t(DIFFICULTIES[difficulty])


static func goals(id: String) -> Array:
	## Three ascending score goals of a menu game; [] for unknown or hidden games.
	return RSCatalog.solo_goals(id) if not RSCatalog.find_game(id).is_empty() else []


static func earned(id: String, score: int) -> int:
	var count := 0
	for goal: int in goals(id):
		count += int(score >= goal)
	return count


static func stars(id: String, player_slot: int) -> int:
	if player_slot < 1 or player_slot > 4 or goals(id).is_empty():
		return 0
	return earned(id, RSRecords.best(id, 0, player_slot))


static func total_stars(player_slot: int) -> int:
	var count := 0
	for game: Dictionary in RSCatalog.games():
		count += stars(game["id"], player_slot)
	return count
