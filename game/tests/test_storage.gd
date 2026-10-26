extends Node
## Real-file recovery tests. The runner provides an isolated user data directory.

const BASE := "user://save-tests/"
var _failures := 0
var _checks := 0


func _ready() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1":
		push_error("Run tools/test_storage.py with isolated user data.")
		get_tree().quit(1)
		return
	if OS.get_environment("RS_STORAGE_REOPEN") == "1":
		_reopen.call_deferred()
	else:
		_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("FAIL: " + message)


func _config(value: int) -> ConfigFile:
	var config := ConfigFile.new()
	config.set_value("data", "value", value)
	return config


func _raw(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null, "fixture opened: " + path)
	if file != null:
		file.store_string(value)
		file.close()


func _value(path: String) -> int:
	return RSSave.integer(RSSave.read(path), "data", "value", -1)


func _reopen() -> void:
	RSSettings.load_once()
	_check(RSSettings.FPS[RSSettings.fps] == 60 and RSSettings.window == 1, "settings survive process restart")
	_check(RSRecords.best("ski", 0, 2) == 30, "records survive process restart")
	_check(ProjectSettings.get_setting("custom/preserved", "") == "keep", "engine loads versioned override at startup")
	print("RS_STORAGE_REOPEN: %s" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures else 0)


func _run() -> void:
	_check(DirAccess.make_dir_recursive_absolute(BASE) == OK, "fixture directory")
	var path := BASE + "round-trip.cfg"
	_check(_value(path) == -1, "missing save defaults")
	_check(_config(12).save(path) == OK, "legacy fixture")
	_check(_value(path) == 12, "unversioned save readable")
	_check(RSSave.write(path, _config(34)) == OK, "legacy upgraded")
	_check(_value(path) == 34 and _value(path + ".bak") == 12, "previous legacy copy preserved")
	var saved := ConfigFile.new()
	_check(saved.load(path) == OK and saved.get_value(RSSave.META, "version") == 1, "version persisted")
	_check(str(saved.get_value(RSSave.META, "sha256")).length() == 64, "checksum persisted")
	var unchanged := _config(56)
	var encoded := unchanged.encode_to_text()
	_check(RSSave.write(BASE + "caller.cfg", unchanged) == OK and unchanged.encode_to_text() == encoded, "caller config not mutated")
	_check(RSSave.write(path, _config(56)) == OK, "second write")
	saved.load(path)
	saved.set_value("data", "value", 999)
	saved.save(path)
	_check(_value(path) == 34, "checksum mismatch recovers previous save")
	_check(RSSave.write(path, _config(78)) == OK, "write after recovery")
	_check(_value(path) == 78 and _value(path + ".bak") == 34, "sole valid backup preserved")
	_raw(path + ".bak", "")
	_check(_value(path) == 78, "bad backup cannot hide valid main")

	var interrupted := BASE + "interrupted.cfg"
	_check(RSSave.write(interrupted, _config(81)) == OK, "interrupted fixture")
	_check(DirAccess.rename_absolute(interrupted, interrupted + ".tmp") == OK, "simulate pre-promotion exit")
	_check(_value(interrupted) == 81, "temporary save recovery")
	_check(RSSave.write(interrupted, _config(82)) == OK, "write after temp recovery")
	_check(_value(interrupted) == 82 and _value(interrupted + ".bak") == 81, "temp recovery backed up before reuse")
	_check(DirAccess.remove_absolute(interrupted) == OK, "simulate replacement gap")
	_check(_value(interrupted) == 81, "replacement gap recovers backup")

	var syntax := BASE + "syntax.cfg"
	_config(91).save(syntax + ".bak")
	_raw(syntax, "[broken")
	_check(_value(syntax) == 91, "malformed syntax recovers backup")
	var empty := BASE + "empty.cfg"
	_raw(empty, "")
	_raw(empty + ".bak", "")
	_raw(empty + ".tmp", "")
	_check(_value(empty) == -1, "all copies invalid defaults")
	_check(RSSave.write(empty, _config(92)) == OK and _value(empty) == 92, "fresh write after all copies lost")
	var large := BASE + "large.cfg"
	_raw(large, "x".repeat(RSSave.MAX_BYTES + 1))
	_check(_value(large) == -1, "oversized save rejected before parsing")
	for invalid: Variant in [-1, 0, "1", {}, true]:
		var metadata := _config(99)
		metadata.set_value(RSSave.META, "version", invalid)
		metadata.save(BASE + "metadata.cfg")
		_check(_value(BASE + "metadata.cfg") == -1, "invalid metadata type/version rejected")

	var future := BASE + "future.cfg"
	_check(RSSave.write(future, _config(100)) == OK, "future base fixture")
	var newer := _config(101)
	newer.set_value(RSSave.META, "version", RSSave.VERSION + 1)
	newer.save(future)
	var original := FileAccess.get_file_as_bytes(future)
	_check(_value(future) == -1, "future main does not fall back to older data")
	_check(RSSave.write(future, _config(102)) == ERR_FILE_UNRECOGNIZED, "future main refuses writes")
	_check(FileAccess.get_file_as_bytes(future) == original, "future file untouched")
	newer.save(future + ".bak")
	DirAccess.remove_absolute(future)
	_check(RSSave.write(future, _config(103)) == ERR_FILE_UNRECOGNIZED, "future backup protected")
	DirAccess.remove_absolute(future + ".bak")
	newer.save(future + ".tmp")
	_check(RSSave.write(future, _config(104)) == ERR_FILE_UNRECOGNIZED, "future temporary file protected")
	_raw(BASE + "bad-temp.cfg.tmp", "")
	_check(_value(BASE + "bad-temp.cfg") == -1, "incomplete temporary file rejected")
	_check(RSSave.write(BASE + "missing-parent/file.cfg", _config(105)) != OK, "write failure propagated")
	_public_compatibility()
	print("RS_STORAGE_TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)


func _public_compatibility() -> void:
	var profiles := ConfigFile.new()
	profiles.set_value("1", "name", "Legacy Name")
	profiles.set_value("1", "color", 5)
	profiles.set_value("1", "avatar", 2)
	profiles.set_value("1", "tutorials", ["ski", "ski", 7])
	profiles.set_value("2", "color", {})
	profiles.set_value("2", "avatar", [])
	profiles.set_value("2", "name", {})
	profiles.save(RSProfiles.PATH)
	RSProfiles._loaded = false
	_check(RSProfiles.player_name(1) == "Legacy Name" and RSProfiles.avatar(1) == 2, "legacy profiles compatible")
	_check(RSProfiles.tutorial_done(1, "ski") and RSProfiles.profile(1)["tutorials"].size() == 1, "legacy tutorial list sanitized")
	_check(RSProfiles.player_name(2) == "P2" and RSProfiles.avatar(2) == 1, "bad profile field types default")
	_check(RSProfiles.update(1, "Updated", 4, 3) == OK, "public profile migration")
	RSProfiles._loaded = false
	_check(RSProfiles.player_name(1) == "Updated", "migrated profile reload")
	var future_profile := RSSave.read(RSProfiles.PATH)
	future_profile.set_value(RSSave.META, "version", RSSave.VERSION + 1)
	future_profile.save(RSProfiles.PATH)
	var before := FileAccess.get_file_as_bytes(RSProfiles.PATH)
	# The runner expects exactly this one public API error, in addition to syntax corruption.
	_check(RSProfiles.update(1, "Must Roll Back", 0, 0) != OK, "external future version detected after load")
	_check(RSProfiles.player_name(1) == "Updated", "failed profile update rolls back memory")
	_check(FileAccess.get_file_as_bytes(RSProfiles.PATH) == before, "public API preserves future data")

	var records := ConfigFile.new()
	records.set_value("ski/map_0", "entries", [
		{"slot": 1, "score": 10, "name": "Old"}, {"slot": 1, "score": 20, "name": []},
		{"slot": 2, "score": -5}, {"slot": 3, "score": "bad"}, {"slot": 9, "score": 99}])
	records.save(RSRecords.PATH)
	RSRecords._loaded = false
	_check(RSRecords.best("ski", 0, 1) == 20 and RSRecords.leaderboard("ski", 0).size() == 1, "legacy record validation and deduplication")
	_check(RSRecords.leaderboard("ski", 0)[0]["name"] == "P1", "malformed record name defaults")
	_check(RSRecords.submit("ski", 0, 2, 30), "public records migration")
	RSRecords._loaded = false
	_check(RSRecords.best("ski", 0, 2) == 30 and not RSRecords._boards.has(RSSave.META), "metadata not a leaderboard")

	var settings := ConfigFile.new()
	settings.set_value("display", "fps", 2)
	settings.set_value("display", "fullscreen", true)
	settings.set_value("display", "quality", {})
	settings.set_value("display", "upscale", [])
	settings.set_value("general", "language", {})
	settings.set_value("audio", "master", [])
	settings.set_value("accessibility", "color_safe", "false")
	settings.save(RSSettings.PATH)
	RSSettings._loaded = false
	RSSettings.quality = 2
	RSSettings.load_once()
	_check(RSSettings.FPS[RSSettings.fps] == 60 and RSSettings.window == 1, "legacy fps and fullscreen migration")
	_check(RSSettings.quality == 2 and RSSettings.upscale == 0 and RSSettings.language == 0, "bad display field types default")
	_check(not RSSettings.color_safe and RSSettings.volumes[0] == 10, "bad bool and audio types default")
	var override := ConfigFile.new()
	override.set_value("custom", "preserved", "keep")
	override.save(RSSettings.OVERRIDE_PATH)
	_check(RSSettings.save() == OK, "public settings migration")
	_check(RSSave.read(RSSettings.OVERRIDE_PATH).get_value("custom", "preserved") == "keep", "override preserves unknown keys")
	settings.set_value("display", "upscale", 1)   # 0.77, which FSR 2 has no preset for
	settings.save(RSSettings.PATH)
	RSSettings._loaded = false
	RSSettings.load_once()
	_check(RSSettings.UPSCALE_SCALES[RSSettings.upscale] == 0.67, "legacy upscale moves to the nearest FSR 2 preset")
	settings.set_value("display", "upscaling", 1)
	settings.save(RSSettings.PATH)
	RSSettings._loaded = false
	RSSettings.load_once()
	_check(RSSettings.upscale == 1 and RSSettings.UPSCALE_SCALES[1] == 1.0, "new upscale key wins over the legacy one")
	_check(RSSettings.save() == OK and not RSSave.read(RSSettings.PATH).has_section_key("display", "upscale"), "legacy upscale key dropped on save")
