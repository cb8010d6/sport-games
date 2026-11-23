class_name RSSave
extends RefCounted
## Versioned ConfigFile storage for profiles, records and settings. Existing unversioned
## files are version 0. A verified previous copy survives interrupted file replacement.
## Checksums detect accidental corruption; they are not an anti-cheat mechanism.

const VERSION := 1
const META := "_save"
const MAX_BYTES := 4 * 1024 * 1024


static func read(path: String) -> ConfigFile:
	for suffix: String in ["", ".bak", ".tmp"]:
		var candidate := _inspect(path + suffix)
		if candidate["future"]:
			push_warning("RSSave: unsupported version, preserving %s" % (path + suffix))
			return ConfigFile.new()
		if candidate["error"] == OK:
			if not suffix.is_empty():
				push_warning("RSSave: recovered %s from %s" % [path, suffix])
			return candidate["config"]
		if candidate["error"] != ERR_FILE_NOT_FOUND:
			push_warning("RSSave: invalid %s (%s)" % [path + suffix, error_string(candidate["error"])])
	return ConfigFile.new()


static func write(path: String, config: ConfigFile) -> Error:
	# Recheck disk on every write: another/newer build may have changed it since load.
	var previous: ConfigFile = null
	var previous_suffix := ""
	for suffix: String in ["", ".bak", ".tmp"]:
		var candidate := _inspect(path + suffix)
		if candidate["future"]:
			return ERR_FILE_UNRECOGNIZED
		if previous == null and candidate["error"] == OK:
			previous = candidate["config"]
			previous_suffix = suffix
	var pending := ConfigFile.new()
	var err := pending.parse(config.encode_to_text())
	if err != OK:
		return err
	pending.set_value(META, "version", VERSION)
	pending.set_value(META, "sha256", _digest(pending))
	# Do not replace a backup that is the sole valid copy. If .tmp is the sole copy,
	# preserve it as .bak before reusing .tmp for the next save.
	if previous != null and previous_suffix != ".bak":
		err = _verified_save(path + ".bak.tmp", previous)
		if err != OK:
			return err
		err = DirAccess.rename_absolute(path + ".bak.tmp", path + ".bak")
		if err != OK:
			return err
	err = _verified_save(path + ".tmp", pending)
	if err != OK:
		return err
	return DirAccess.rename_absolute(path + ".tmp", path)


static func _inspect(path: String) -> Dictionary:
	var result := {"error": ERR_FILE_NOT_FOUND, "future": false, "config": ConfigFile.new()}
	if not FileAccess.file_exists(path):
		return result
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		result["error"] = FileAccess.get_open_error()
		return result
	var size := file.get_length()
	file.close()
	if size == 0 or size > MAX_BYTES:
		result["error"] = ERR_FILE_CORRUPT
		return result
	var config: ConfigFile = result["config"]
	result["error"] = config.load(path)
	if result["error"] != OK:
		return result
	var version: Variant = config.get_value(META, "version", 0)
	if not version is int or version < 0 or (version == 0 and config.has_section(META)):
		result["error"] = ERR_FILE_CORRUPT
	elif version > VERSION:
		result["future"] = true
		result["error"] = ERR_FILE_UNRECOGNIZED
	elif version == VERSION:
		var checksum: Variant = config.get_value(META, "sha256", "")
		if not checksum is String or checksum != _digest(config):
			result["error"] = ERR_FILE_CORRUPT
	return result


static func _digest(config: ConfigFile) -> String:
	var has_hash := config.has_section_key(META, "sha256")
	var hash_value: Variant = config.get_value(META, "sha256") if has_hash else null
	if has_hash:
		config.erase_section_key(META, "sha256")
	var result := config.encode_to_text().sha256_text()
	if hash_value != null:
		config.set_value(META, "sha256", hash_value)
	return result


static func _verified_save(path: String, config: ConfigFile) -> Error:
	var err := config.save(path)
	if err != OK:
		return err
	return _inspect(path)["error"]


static func integer(config: ConfigFile, section: String, key: String, fallback: int) -> int:
	var value: Variant = config.get_value(section, key, fallback)
	return value if value is int else fallback


static func boolean(config: ConfigFile, section: String, key: String, fallback: bool) -> bool:
	var value: Variant = config.get_value(section, key, fallback)
	return value if value is bool else fallback


static func string_value(config: ConfigFile, section: String, key: String, fallback: String) -> String:
	var value: Variant = config.get_value(section, key, fallback)
	return value if value is String else fallback
