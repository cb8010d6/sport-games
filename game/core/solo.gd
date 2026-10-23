class_name RSSolo
extends RefCounted
## One human and one physical AI opponent. Challenge stars are derived from existing
## official map-0 records, so demos/custom rules cannot create progress or save files.

const DIFFICULTIES := ["简单", "普通", "困难"]
const GOALS := {"plane": [3000, 8000, 15000], "archery": [25, 50, 75],
	"bowling": [30, 60, 100], "skate": [3000, 10000, 25000],
	"ski": [2000, 5000, 9000], "basketball": [800, 2000, 3500]}
static var game_id := ""
static var slot := 1
static var difficulty := 1


static func begin(id: String, player_slot: int, level: int) -> String:
	var entry := RSCatalog.find_game(id)
	if entry.is_empty() or not GOALS.has(id) or player_slot < 1 or player_slot > 4 or level < 0 or level > 2:
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


static func earned(id: String, score: int) -> int:
	var count := 0
	for goal: int in GOALS.get(id, []):
		count += int(score >= goal)
	return count


static func stars(id: String, player_slot: int) -> int:
	if player_slot < 1 or player_slot > 4 or not GOALS.has(id):
		return 0
	return earned(id, RSRecords.best(id, 0, player_slot))


static func total_stars(player_slot: int) -> int:
	var count := 0
	for id: String in GOALS:
		count += stars(id, player_slot)
	return count
