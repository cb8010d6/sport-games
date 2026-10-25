extends RefCounted
## Compatibility of the manifest catalog with the hard-coded tables it replaced (RSCatalog.GAMES,
## RSTutorial.LESSONS, RSSolo.GOALS before issue #39): IDs, order, menu text, scenes, lessons and
## goals stay identical, so saves, records, tutorial flags, party points and solo stars do too.

const LEGACY := [
	["plane", "螺旋桨飞机", "PLANE", "倾斜手柄控制俯仰和滚转，穿过尽量多的圆环。1–4 人分屏。"],
	["archery", "射箭", "ARCHERY", "用手柄瞄准，按住 A 拉弓、松开放箭。3 轮 15 / 25 / 40 米，有风。1–4 人分屏同时射。"],
	["bowling", "保龄球", "BOWLING", "按住 B 挥臂、松开出球，挥得越快球越快，松手时拧手腕打出弧线。每局 5 格，1–4 人各打各的球道。"],
	["skate", "滑板", "SKATE", "顺着海边的下坡街道滑到终点：起跳、翻板、转体、抓板，跳上栏杆磨杆，地上 Manual，连招越长分越高。1–4 人分屏同时滑。"],
	["ski", "滑雪", "SKI", "从山顶滑到终点：倾斜转弯穿旗门，往前压团身加速，飞跳台转体抓板。4 张地图（晴空 / 黄昏松林 / 夜场 / 暴风雪冰川），大厅按 B 选。1–4 人分屏同时滑。"],
	["basketball", "篮球", "3PT", "三分大赛：5 个球架 × 5 个球，按住 B 举球，往上甩手腕同时松开 B 出手。花球双倍、空心加分、连进三球手感火热。2 张天台地图，1–4 人分屏各投各的。"],
]
const LEGACY_LESSONS := {
	"plane": [RSTutorial.TILT_RIGHT, RSTutorial.TILT_FORWARD, RSTutorial.BOOST],
	"archery": [RSTutorial.AIM, RSTutorial.DRAW],
	"bowling": [RSTutorial.TILT_RIGHT, RSTutorial.THROW],
	"skate": [RSTutorial.TILT_RIGHT, RSTutorial.JUMP, RSTutorial.GRAB],
	"ski": [RSTutorial.TILT_RIGHT, RSTutorial.TILT_FORWARD, RSTutorial.JUMP, RSTutorial.GRAB],
	"basketball": [RSTutorial.AIM, RSTutorial.THROW],
}
const LEGACY_GOALS := {"plane": [3000, 8000, 15000], "archery": [25, 50, 75],
	"bowling": [30, 60, 100], "skate": [3000, 10000, 25000],
	"ski": [2000, 5000, 9000], "basketball": [800, 2000, 3500]}
const LEGACY_MAPS := {"ski": 4, "basketball": 2}


static func run(check: Callable) -> void:
	var games := RSCatalog.games()
	check.call(games.size() == LEGACY.size(), "catalog lists the six menu games")
	for i in mini(games.size(), LEGACY.size()):
		var entry: Dictionary = games[i]
		var id: String = LEGACY[i][0]
		check.call(entry["id"] == id, "catalog order and ID: " + id)
		check.call(entry["name"] == LEGACY[i][1] and entry["oled"] == LEGACY[i][2] and entry["desc"] == LEGACY[i][3], "menu text unchanged: " + id)
		check.call(entry["scene"] == "res://scenes/%s/%s_game.tscn" % [id, id], "scene unchanged: " + id)
		check.call(RSCatalog.find_game(id) == entry, "find_game returns the menu entry: " + id)
		check.call(RSTutorial.new(id).steps == LEGACY_LESSONS[id], "tutorial steps unchanged: " + id)
		check.call(RSSolo.goals(id) == LEGACY_GOALS[id], "solo goals unchanged: " + id)
		check.call(maxi(RSCatalog.maps(id).size(), 1) == LEGACY_MAPS.get(id, 1), "map count unchanged: " + id)
		check.call(ResourceLoader.exists(entry["preview"]) or not DirAccess.dir_exists_absolute("res://assets/previews"), "preview exists: " + id)
	check.call(RSCatalog.find_game("missing").is_empty() and RSCatalog.module("missing", true) == null, "unknown ID rejected")
	check.call(RSSolo.goals("missing").is_empty() and RSSolo.stars("missing", 1) == 0, "unknown game has no goals")
	check.call(RSTutorial.step_list(PackedStringArray(["TILT_RIGHT", "THROW"])) == [RSTutorial.TILT_RIGHT, RSTutorial.THROW], "lesson names resolve to step constants")
	check.call(RSCatalog.dump()["games"].size() == RSCatalog.modules(true).size(), "dump lists every module")
	# Saves keyed by the same IDs: records -> solo stars, tutorial flags, party points.
	RSRecords._loaded = true
	RSRecords._boards.clear()
	RSRecords.submit("basketball", 0, 2, 2000)
	RSRecords.submit("plane", 0, 2, 15000)
	RSRecords.submit("ski", 1, 2, 99999)
	check.call(RSSolo.stars("basketball", 2) == 2 and RSSolo.stars("plane", 2) == 3 and RSSolo.stars("ski", 2) == 0, "stars from existing map-1 records")
	check.call(RSSolo.total_stars(2) == 5, "total stars over the catalog games")
	RSRecords._boards.clear()
	check.call(RSTournament.begin(["skate", "ski", "basketball"], [1, 2]), "party accepts catalog IDs")
	check.call(RSTournament.record("skate", [{"slot": 1, "rank": 1}, {"slot": 2, "rank": 2}]), "party records by ID")
	check.call(RSTournament.standings()[0]["points"] == 10 and RSTournament.standings()[1]["points"] == 7, "party points unchanged")
	check.call(RSTournament.advance() == "res://scenes/ski/ski_game.tscn", "party advances to the catalog scene")
	RSTournament.clear()
