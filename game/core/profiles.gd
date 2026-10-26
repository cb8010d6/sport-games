class_name RSProfiles
extends RefCounted
## Four local player slots. Slot IDs stay stable when names or controllers change.

const PATH := "user://profiles.cfg"
const COLORS := [Color("3b82f6"), Color("ef4444"), Color("22c55e"), Color("f59e0b"),
	Color("a78bfa"), Color("f472b6"), Color("22d3ee"), Color("f8fafc")]
const ACCESSIBLE_COLORS := [Color("0072b2"), Color("e69f00"), Color("cc79a7"), Color("009e73")]
static var _loaded := false
static var _slots: Dictionary = {}


static func load_once() -> void:
	if _loaded:
		return
	_loaded = true
	var cf := RSSave.read(PATH)
	for slot in range(1, 5):
		var key := str(slot)
		_slots[slot] = {
			"name": clean_name(RSSave.string_value(cf, key, "name", "P%d" % slot), slot),
			"color": clampi(RSSave.integer(cf, key, "color", slot - 1), 0, COLORS.size() - 1),
			"avatar": clampi(RSSave.integer(cf, key, "avatar", slot - 1), 0, 3),
			"phone_name": RSSave.string_value(cf, key, "phone_name", ""),
			"tutorials": _tutorial_ids(cf.get_value(key, "tutorials", [])),
			"left_handed": RSSave.boolean(cf, key, "left_handed", false),
		}


static func _tutorial_ids(value: Variant) -> Array:
	var result: Array = []
	if value is Array or value is PackedStringArray:
		for item: Variant in value:
			if item is String and not item in result:
				result.append(item)
	return result


static func clean_name(value: String, slot: int = 1) -> String:
	var result := ""
	for ch in value.strip_edges():
		if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127:
			result += ch
	result = result.substr(0, 20).strip_edges()
	return result if not result.is_empty() else "P%d" % slot


static func profile(slot: int) -> Dictionary:
	load_once()
	return _slots[clampi(slot, 1, 4)].duplicate(true)


static func player_name(slot: int) -> String:
	## Read _slots directly: these run per HUD frame, profile() would deep-copy.
	load_once()
	return str(_slots[clampi(slot, 1, 4)]["name"])


static func player_color(slot: int) -> Color:
	if RSSettings.color_safe:
		return ACCESSIBLE_COLORS[clampi(slot - 1, 0, 3)]
	load_once()
	return COLORS[int(_slots[clampi(slot, 1, 4)]["color"])]


static func avatar(slot: int) -> int:
	load_once()
	return int(_slots[clampi(slot, 1, 4)]["avatar"])


static func left_handed(slot: int) -> bool:
	load_once()
	return bool(_slots[slot]["left_handed"]) if slot >= 1 and slot <= 4 else false


static func update(slot: int, name: String, color: int, look: int, hand: int = -1) -> Error:
	## hand: -1 preserves the current preference, 0 = right, 1 = left.
	if hand < -1 or hand > 1:
		return ERR_INVALID_PARAMETER
	load_once()
	slot = clampi(slot, 1, 4)
	var previous: Dictionary = _slots[slot].duplicate(true)
	_slots[slot]["name"] = clean_name(name, slot)
	_slots[slot]["color"] = clampi(color, 0, COLORS.size() - 1)
	_slots[slot]["avatar"] = clampi(look, 0, 3)
	if hand >= 0:
		_slots[slot]["left_handed"] = hand == 1
	var err := save()
	if err != OK:
		_slots[slot] = previous
	return err


static func import_phone_name(slot: int, name: String) -> void:
	## Only an explicit phone nickname replaces a slot name, and only when it changes.
	if slot < 1 or slot > 4 or name in ["", "phone", "Phone", "手机手柄"]: # no-i18n
		return
	load_once()
	var clean := clean_name(name, slot)
	if _slots[slot]["phone_name"] != clean:
		var previous: Dictionary = _slots[slot].duplicate(true)
		_slots[slot]["phone_name"] = clean
		_slots[slot]["name"] = clean
		if save() != OK:
			_slots[slot] = previous


static func save() -> Error:
	load_once()
	var cf := ConfigFile.new()
	for slot in _slots:
		for field: String in _slots[slot]:
			cf.set_value(str(slot), field, _slots[slot][field])
	var err := RSSave.write(PATH, cf)
	if err != OK:
		push_error("RSProfiles: cannot save profiles (%s)" % error_string(err))
	return err


static func tutorial_done(slot: int, game_id: String) -> bool:
	return game_id in profile(slot)["tutorials"]


static func complete_tutorial(slot: int, game_id: String) -> Error:
	load_once()
	if slot < 1 or slot > 4 or game_id.is_empty():
		return ERR_INVALID_PARAMETER
	if game_id in _slots[slot]["tutorials"]:
		return OK
	_slots[slot]["tutorials"].append(game_id)
	var err := save()
	if err != OK:
		_slots[slot]["tutorials"].erase(game_id)
	return err


static func bbcode(value: String) -> String:
	## Untrusted phone/profile names are plain text, including in rich-text results.
	return value.replace("[", "[lb]")
