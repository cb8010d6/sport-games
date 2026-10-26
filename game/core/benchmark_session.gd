class_name RSBenchmarkSession
extends RefCounted
## Temporary benchmark display settings and explicit result exports. No player save APIs.
## The menu owns the session and must restore it on success, failure, cancellation and exit.

var _active := false
var _settings: Dictionary = {}
var _window: Dictionary = {}


static func export_directory() -> String:
	return "user://benchmarks/" + Time.get_datetime_string_from_system().replace(":", "-") + "-" + str(Time.get_ticks_msec())


func begin(tree: SceneTree, quality: int, resolution: Vector2i) -> Error:
	if _active or tree.paused or quality not in range(4) or resolution not in [Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440)]:
		return ERR_INVALID_PARAMETER
	if DisplayServer.get_name() == "headless":
		return ERR_UNAVAILABLE
	RSSettings.load_once()
	_settings = {"fps": RSSettings.fps, "quality": RSSettings.quality, "window": RSSettings.window,
		"upscale": RSSettings.upscale, "hdr": RSSettings.hdr, "language": RSSettings.language,
		"nvidia_lighting": RSSettings.nvidia_lighting, "nvidia_fg": RSSettings.nvidia_fg,
		"color_safe": RSSettings.color_safe, "camera_shake": RSSettings.camera_shake,
		"volumes": RSSettings.volumes.duplicate()}
	_window = {"size": tree.root.size, "position": DisplayServer.window_get_position(),
		"mode": DisplayServer.window_get_mode(), "vsync": DisplayServer.window_get_vsync_mode(),
		"max_fps": Engine.max_fps, "paused": tree.paused}
	_active = true
	RSSettings.quality = quality
	RSSettings.fps = RSSettings.FPS.find(RSSettings.UNCAPPED)
	RSSettings.window = 0
	RSSettings.upscale = 0
	RSSettings.nvidia_lighting = 0
	RSSettings.nvidia_fg = false
	RSSettings.apply(tree)
	# Maximized windows must leave that mode before Godot can resize their client area.
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	tree.root.size = resolution
	return OK


func restore(tree: SceneTree) -> void:
	if not _active:
		return
	_active = false
	RSSettings.fps = _settings["fps"]
	RSSettings.quality = _settings["quality"]
	RSSettings.window = _settings["window"]
	RSSettings.upscale = _settings["upscale"]
	RSSettings.nvidia_lighting = _settings["nvidia_lighting"]
	RSSettings.nvidia_fg = _settings["nvidia_fg"]
	RSSettings.hdr = _settings["hdr"]
	RSSettings.language = _settings["language"]
	RSSettings.color_safe = _settings["color_safe"]
	RSSettings.camera_shake = _settings["camera_shake"]
	RSSettings.volumes = _settings["volumes"].duplicate()
	RSSettings.apply(tree)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	tree.root.size = _window["size"]
	DisplayServer.window_set_position(_window["position"])
	DisplayServer.window_set_mode(_window["mode"])
	DisplayServer.window_set_vsync_mode(_window["vsync"])
	Engine.max_fps = _window["max_fps"]
	tree.paused = _window["paused"]
	_settings.clear()
	_window.clear()


func write_results(results: Array[Dictionary], directory: String) -> Error:
	## Called after sampling/restoration. Export failure is reported; no save file is touched.
	if _active or results.is_empty() or directory.is_empty():
		return ERR_INVALID_PARAMETER
	var err := DirAccess.make_dir_recursive_absolute(directory)
	if err != OK:
		return err
	var file := FileAccess.open(directory.path_join("results.json"), FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	var runs: Array[Dictionary] = []
	for result: Dictionary in results:
		var exported := result.duplicate()
		exported["statistics"] = RSBenchmark.statistics(result)
		runs.append(exported)
	file.store_string(JSON.stringify({"schema_version": 1, "runs": runs,
		"exported_at_utc": Time.get_datetime_string_from_system(true) + "Z",
		"application_version": ProjectSettings.get_setting("application/config/version", "unknown")}, "\t"))
	err = _close_written(file)
	if err != OK:
		return err
	file = FileAccess.open(directory.path_join("samples.csv"), FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_csv_line(PackedStringArray(["game", "map", "players", "quality", "frame", "frame_ms",
		"cpu_process_ms", "viewport", "gpu_viewport_ms", "cpu_render_viewport_ms", "draw_calls", "video_memory_bytes", "nodes"]))
	for result: Dictionary in results:
		var samples: Array = result.get("samples", [])
		for frame in samples.size():
			var sample: Dictionary = samples[frame]
			var gpu: Dictionary = sample.get("gpu_viewports_ms", {})
			var cpu: Dictionary = sample.get("cpu_render_viewports_ms", {})
			for viewport: String in gpu:
				file.store_csv_line(PackedStringArray([str(result["game"]), str(result["map"]), str(result["players"]),
					str(result["quality"]), str(frame), str(sample["frame_ms"]), str(sample["cpu_process_ms"]), viewport,
					"" if gpu[viewport] == null else str(gpu[viewport]), "" if cpu.get(viewport) == null else str(cpu[viewport]),
					str(sample["draw_calls"]), str(sample["video_memory_bytes"]), str(sample["nodes"])]))
	return _close_written(file)


static func _close_written(file: FileAccess) -> Error:
	file.flush()
	var err := file.get_error()
	file.close()
	return err
