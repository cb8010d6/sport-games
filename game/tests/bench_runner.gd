extends SceneTree
## CLI adapter for RSBenchmark. Only this disposable test process overrides settings and
## external input; the shared runtime sampler owns the measurement and raw report schema.

const RESOLUTIONS := ["1600x900", "1920x1080", "2560x1440", "2560x1080", "3840x2160"]

var _id := ""
var _players := 0
var _map := -1
var _quality := -1
var _warmup := 10.0
var _duration := 30.0
var _seed := 20261023
var _output := ""
var _resolution := Vector2i(1600, 900)
var _borderless := false
var _errors: Array[String] = []
var _game: Node
var _sampler: Node
var _finishing := false


func _initialize() -> void:
	_parse()
	_validate_environment()
	_run.call_deferred()


func _parse() -> void:
	var options: Dictionary = {}
	var allowed := ["--bench-game", "--demo", "--map", "--bench-quality", "--bench-warmup",
		"--bench-duration", "--bench-output", "--bench-seed", "--bench-resolution"]
	for arg: String in OS.get_cmdline_user_args():
		var key := arg.get_slice("=", 0)
		if key not in allowed or not arg.contains("=") or options.has(key):
			_errors.append("Unknown, duplicate or malformed benchmark argument: " + key)
			continue
		options[key] = arg.substr(key.length() + 1)
	_id = str(options.get("--bench-game", ""))
	_output = str(options.get("--bench-output", ""))
	for key: String in ["--demo", "--map", "--bench-quality", "--bench-seed"]:
		if not str(options.get(key, "")).is_valid_int():
			_errors.append("Missing or invalid integer: " + key)
	_players = int(options.get("--demo", "0"))
	_map = int(options.get("--map", "-1"))
	_quality = int(options.get("--bench-quality", "-1"))
	_seed = int(options.get("--bench-seed", "20261023"))
	for key: String in ["--bench-warmup", "--bench-duration"]:
		if not str(options.get(key, "")).is_valid_float():
			_errors.append("Missing or invalid duration: " + key)
	_warmup = float(options.get("--bench-warmup", "10"))
	_duration = float(options.get("--bench-duration", "30"))
	var size := str(options.get("--bench-resolution", RESOLUTIONS[0]))
	if size not in RESOLUTIONS:
		_errors.append("Unsupported benchmark resolution: " + size)
	else:
		_resolution = Vector2i(int(size.get_slice("x", 0)), int(size.get_slice("x", 1)))
	if RSCatalog.find_game(_id).is_empty() or _players not in [1, 2, 4] or _map < 0 or _quality not in range(4) or _seed < 0:
		_errors.append("Invalid game, player count, map, quality or seed")
	if not is_finite(_warmup) or not is_finite(_duration) or _warmup < 0.0 or _duration <= 0.0:
		_errors.append("Warmup must be finite/nonnegative and duration finite/positive")
	if not _output.is_absolute_path() or _output.begins_with("res://") or _output.begins_with("user://"):
		_errors.append("Benchmark output must be an explicit absolute filesystem path")
		_output = ""


func _within(path: String, directory: String) -> bool:
	var normalized := path.replace("\\", "/").simplify_path().trim_suffix("/")
	var base := directory.replace("\\", "/").simplify_path().trim_suffix("/")
	if OS.get_name() == "Windows":
		normalized = normalized.to_lower()
		base = base.to_lower()
	return normalized == base or normalized.begins_with(base + "/")


func _validate_environment() -> void:
	var isolated := OS.get_environment("RS_BENCH_USER_ROOT")
	if OS.get_environment("RS_TEST_MODE") != "1" or not isolated.is_absolute_path() or not DirAccess.dir_exists_absolute(isolated):
		_errors.append("RS_TEST_MODE=1 and an existing absolute RS_BENCH_USER_ROOT are required")
		return
	if not _within(isolated, OS.get_temp_dir()) or _within(OS.get_temp_dir(), isolated):
		_errors.append("Benchmark user root must be a dedicated child of the system temporary directory")
	for key: String in ["APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"]:
		var value := OS.get_environment(key)
		if not value.is_absolute_path() or not _within(value, isolated) or not DirAccess.dir_exists_absolute(value):
			_errors.append("User environment is not isolated: " + key)
	if not _within(OS.get_user_data_dir(), isolated):
		_errors.append("Godot user data escaped the isolated root; refusing to load settings")
	if not _output.is_empty() and _within(_output, isolated):
		_errors.append("Output must outlive the disposable user directory")
		_output = ""
	for arg: String in OS.get_cmdline_args():
		var key := arg.get_slice("=", 0)
		if key in ["--headless", "--fixed-fps", "--disable-render-loop", "--write-movie"]:
			_errors.append("Unsupported engine argument for real-time rendering: " + key)
	if DisplayServer.get_name() == "headless" or RenderingServer.get_video_adapter_name().is_empty():
		_errors.append("A real window and rendering adapter are required")
		return
	# A window larger than the display gets shrunk by the system; never report that as the requested size.
	var screen := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	if screen.x < _resolution.x or screen.y < _resolution.y:
		_errors.append("Requested %dx%d needs a display at least that large (screen is %dx%d)" % [_resolution.x, _resolution.y, screen.x, screen.y])


func _run() -> void:
	if not _errors.is_empty():
		_finish(_failure_report())
		return
	seed(_seed)
	RSSettings.load_once()
	RSSettings.quality = _quality
	RSSettings.window = 0
	RSSettings.fps = RSSettings.FPS.find(RSSettings.UNCAPPED)
	RSSettings.upscale = 0
	RSSettings.hdr = false
	RSSettings.apply(self)
	_fit_window()
	var hub := root.get_node_or_null("ControllerHub")
	if hub == null:
		_abort("ControllerHub autoload was not initialized")
		return
	hub.set_process(false)
	# Resolve the autoload-dependent game/sampler graph after SceneTree initialization.
	var packed := load(str(RSCatalog.find_game(_id)["scene"])) as PackedScene
	if packed == null:
		_abort("Cannot load requested game scene")
		return
	_game = packed.instantiate()
	if _game == null or not _game.has_method("configure_benchmark"):
		_abort("Requested scene does not implement the benchmark interface")
		return
	var configured: int = _game.call("configure_benchmark", _players, _map)
	if configured != OK:
		_abort("Invalid benchmark participants or map")
		return
	root.add_child(_game)
	current_scene = _game
	RSSettings.apply(self)
	var script := load("res://core/benchmark.gd") as GDScript
	if script == null:
		_abort("Cannot load the shared benchmark sampler")
		return
	_sampler = script.new() as Node
	root.add_child(_sampler)
	_sampler.connect("completed", _on_completed)
	var request := {"game": _id, "map": _map, "players": _players, "quality": _quality,
		"warmup_seconds": _warmup, "duration_seconds": _duration, "seed": _seed, "resolution": _resolution}
	var started: int = _sampler.call("begin", _game, request)
	if started != OK:
		_abort("Shared sampler refused benchmark request: %d" % started)
		return
	print("RS_BENCH_START: " + _id)


func _fit_window() -> void:
	## A decorated window as large as the screen gets clamped to the usable area (title bar,
	## taskbar). Drop the decorations and cover the screen instead; still windowed mode.
	if DisplayServer.window_get_size() == _resolution:
		return
	var screen := DisplayServer.window_get_current_screen()
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	DisplayServer.window_set_position(DisplayServer.screen_get_position(screen))
	DisplayServer.window_set_size(_resolution)
	_borderless = true


func _failure_report() -> Dictionary:
	return {"schema_version": 1, "status": "FAIL", "game": _id, "map": _map, "players": _players,
		"quality": _quality, "warmup_seconds": _warmup, "duration_seconds": _duration,
		"elapsed_seconds": 0.0, "frames": 0, "samples": [], "metadata": {}, "errors": _errors.duplicate()}


func _abort(reason: String) -> void:
	if _finishing:
		return
	_errors.append(reason)
	_finishing = true
	_finish.call_deferred(_failure_report())


func _on_completed(report: Dictionary) -> void:
	if _finishing:
		return
	_finishing = true
	_finish.call_deferred(report)


func _finish(report: Dictionary) -> void:
	_finishing = true
	if report.get("metadata") is Dictionary:
		(report["metadata"] as Dictionary)["window_borderless"] = _borderless
	if is_instance_valid(_sampler):
		_sampler.queue_free()
		_sampler = null
	if is_instance_valid(_game):
		RSExit.silence(_game)
		if current_scene == _game:
			current_scene = null
		_game.queue_free()
		_game = null
	paused = false
	var drain_until := Time.get_ticks_msec() + 350
	while Time.get_ticks_msec() < drain_until:
		await process_frame
	var file := FileAccess.open(_output, FileAccess.WRITE) if not _output.is_empty() else null
	if file == null:
		_errors.append("Cannot write benchmark output")
	else:
		file.store_string(JSON.stringify(report))
		file.flush()
		if file.get_error() != OK:
			_errors.append("Cannot flush benchmark output")
		file.close()
	var passed: bool = report.get("status") == "PASS" and _errors.is_empty()
	if passed:
		print("RS_BENCH_DONE: " + _id)
	else:
		for error: String in report.get("errors", []):
			push_error("Benchmark: " + error)
		for error: String in _errors:
			push_error("Benchmark adapter: " + error)
	quit(0 if passed else 1)
