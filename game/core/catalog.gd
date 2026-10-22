class_name RSCatalog
extends RefCounted
## Stable IDs are used by saves and party sessions, independent of translated titles.

const GAMES := [
	{"id": "plane", "name": "螺旋桨飞机", "oled": "PLANE", "scene": "res://scenes/plane/plane_game.tscn",
		"desc": "倾斜手柄控制俯仰和滚转，穿过尽量多的圆环。1–4 人分屏。"},
	{"id": "archery", "name": "射箭", "oled": "ARCHERY", "scene": "res://scenes/archery/archery_game.tscn",
		"desc": "用手柄瞄准，按住 A 拉弓、松开放箭。3 轮 15 / 25 / 40 米，有风。1–4 人分屏同时射。"},
	{"id": "bowling", "name": "保龄球", "oled": "BOWLING", "scene": "res://scenes/bowling/bowling_game.tscn",
		"desc": "按住 B 挥臂、松开出球，挥得越快球越快，松手时拧手腕打出弧线。每局 5 格，1–4 人各打各的球道。"},
	{"id": "skate", "name": "滑板", "oled": "SKATE", "scene": "res://scenes/skate/skate_game.tscn",
		"desc": "顺着海边的下坡街道滑到终点：起跳、翻板、转体、抓板，跳上栏杆磨杆，地上 Manual，连招越长分越高。1–4 人分屏同时滑。"},
	{"id": "ski", "name": "滑雪", "oled": "SKI", "scene": "res://scenes/ski/ski_game.tscn",
		"desc": "从山顶滑到终点：倾斜转弯穿旗门，往前压团身加速，飞跳台转体抓板。4 张地图（晴空 / 黄昏松林 / 夜场 / 暴风雪冰川），大厅按 B 选。1–4 人分屏同时滑。"},
	{"id": "basketball", "name": "篮球", "oled": "3PT", "scene": "res://scenes/basketball/basketball_game.tscn",
		"desc": "三分大赛：5 个球架 × 5 个球，按住 B 举球，往上甩手腕同时松开 B 出手。花球双倍、空心加分、连进三球手感火热。2 张天台地图，1–4 人分屏各投各的。"},
]


static func find_game(id: String) -> Dictionary:
	for game: Dictionary in GAMES:
		if game["id"] == id:
			return game
	return {}
