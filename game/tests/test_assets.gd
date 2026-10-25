extends Node
## Shared asset plumbing: RSPbr material roots and RSProps kit keys / glTF parts (#58 P0).
## Loads prefab glTFs only where their buffers are synced, so it also runs on sparse checkouts.

var _failures := 0
var _checks := 0


func _ready() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("Assets: " + label)


func _run() -> void:
	_pbr_paths()
	var loaded := _props()
	print("RS_ASSETS_PREFABS_LOADED: %d of %d" % [loaded, RSProps.PREFABS.size()])
	print("RS_ASSETS_TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)


func _pbr_paths() -> void:
	_check(RSPbr.folder("clean_asphalt") == "res://assets/polyhaven/textures/clean_asphalt/", "Poly Haven id keeps its folder")
	_check(RSPbr.map_path("clean_asphalt", "nor_gl", "2k") == "res://assets/polyhaven/textures/clean_asphalt/clean_asphalt_nor_gl_2k.jpg", "Poly Haven map name")
	_check(RSPbr.folder("shared:acg_net004a") == "res://assets/shared/materials/acg_net004a/", "shared: root")
	_check(RSPbr.map_path("shared:acg_net004a", "diff", "1k", "png") == "res://assets/shared/materials/acg_net004a/acg_net004a_diff_1k.png", "shared map uses Poly Haven naming")
	_check(RSPbr.folder("nowhere:x") == "" and RSPbr.map_path("nowhere:x", "diff", "2k") == "", "unknown root resolves to nothing")
	var missing := RSPbr.maps("shared:rs_test_missing")
	_check(missing.size() == 3 and missing.all(func(t: Variant) -> bool: return t == null), "missing material gives three nulls")
	var unknown := RSPbr.maps("nowhere:x")
	_check(unknown.all(func(t: Variant) -> bool: return t == null), "unknown root gives three nulls")
	for id: String in ["clean_asphalt", "snow_02"]:
		if ResourceLoader.exists(RSPbr.map_path(id, "diff", "2k")) or ResourceLoader.exists(RSPbr.map_path(id, "diff", "4k")):
			var t := RSPbr.maps(id)
			_check(t[0] is Texture2D and t[1] is Texture2D and t[2] is Texture2D, "synced Poly Haven material loads: " + id)


func _props() -> int:
	_check(RSProps.path("street_lamp_01/street_lamp_01_2k") == "res://assets/polyhaven/models/street_lamp_01/street_lamp_01_2k.gltf", "Poly Haven prefab path")
	_check(RSProps.path("shared:arena/arena_bleacher/arena_bleacher") == "res://assets/shared/arena/arena_bleacher/arena_bleacher.gltf", "shared prefab path")
	var loaded := 0
	for key: String in RSProps.PREFABS:
		var kit := key.get_slice("_", 0)
		_check(kit in RSProps.KITS and key.length() > kit.length() + 1, "prefab key has a kit prefix: " + key)
		var spec: Array = RSProps.PREFABS[key]
		var gltf := RSProps.path(spec[0])
		_check(ResourceLoader.exists(gltf), "prefab glTF exists: " + key)
		if not _buffers_synced(gltf):
			continue
		var root := (load(gltf) as PackedScene).instantiate()
		for part: String in spec[1]:
			_check(root.find_child(part, true, false) is MeshInstance3D, "%s part '%s' is a mesh" % [key, part])
		root.free()
		_check(not RSProps.parts(key).is_empty() and RSProps.size(key).y > 0.0, "prefab has geometry: " + key)
		loaded += 1
	return loaded


func _buffers_synced(gltf: String) -> bool:
	## Poly Haven buffers are downloaded by tools/sync_assets.mjs and may be absent (CI, sparse checkout).
	var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(gltf))
	if not json is Dictionary:
		return false
	for b: Dictionary in json.get("buffers", []):
		if not FileAccess.file_exists(gltf.get_base_dir().path_join(String(b.get("uri", "")))):
			return false
	return true
