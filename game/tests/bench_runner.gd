extends SceneTree
## Rendered demo benchmark. Sampling uses real post-draw ticks, never simulation delta.
## Settings and input isolation apply only to this disposable process; nothing is saved.

const RESOLUTION := Vector2i(1600, 900)
const START_TIMEOUT := 120.0
const MAX_SAMPLES := 1000000

var _id := ""
var _players := 0
var _map := -1
var _quality := -1
var _warmup := 10.0
var _duration := 30.0
var _seed := 20261023
var _output := ""
var _errors: Array[String] = []
var _metadata: Dictionary = {}
var _game: Node
var _play_phase := -1
var _stage := "setup"
var _started_us := 0
var _warm_us := 0
var _sample_us := 0
var _last_us := 0
var _elapsed := 0.0
var _count := 0
var _capacity := 0
var _finishing := false
var _viewports: Array[Viewport] = []
var _viewport_names := PackedStringArray()
var _frame_ms := PackedFloat64Array()
var _cpu_ms := PackedFloat64Array()
var _draw_calls := PackedInt64Array()
var _memory := PackedInt64Array()
var _nodes := PackedInt64Array()
var _gpu_times := PackedFloat64Array()
var _render_cpu_times := PackedFloat64Array()


func _initialize() -> void:
	_parse()
	_validate_environment()
	_run.call_deferred()


func _parse() -> void:
	var options: Dictionary = {}
	var allowed := ["--bench-game", "--demo", "--map", "--bench-quality", "--bench-warmup",
		"--bench-duration", "--bench-output", "--bench-seed"]
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


func _run() -> void:
	if not _errors.is_empty():
		_finish()
		return
	_started_us = Time.get_ticks_usec()
	seed(_seed)
	RSSettings.load_once()
	RSSettings.quality = _quality
	RSSettings.window = 0
	RSSettings.fps = RSSettings.FPS.find(RSSettings.UNCAPPED)
	RSSettings.upscale = 0
	RSSettings.hdr = false
	RSSettings.apply(self)
	# Physical input is irrelevant to demo bots and must not pause or navigate a run.
	var hub := root.get_node_or_null("ControllerHub")
	if hub == null:
		_abort("ControllerHub autoload was not initialized")
		return
	hub.set_process(false)
	_metadata = _describe()
	# Load scenes after autoload initialization. A -s script must not resolve the
	# game's autoload-dependent script graph before SceneTree has initialized it.
	var packed := load(str(RSCatalog.find_game(_id)["scene"])) as PackedScene
	if packed == null:
		_abort("Cannot load requested game scene")
		return
	_game = packed.instantiate()
	if not _game.has_method("ordered") or not _game.has_method("_maps"):
		_abort("Requested scene does not implement the party game interface")
		return
	var maps: Array = _game.call("_maps")
	if _map >= maxi(1, maps.size()):
		_abort("Requested map is outside this game's catalog")
		return
	var party := load("res://core/party_game.gd") as Script
	var phases: Dictionary = party.get_script_constant_map()["Phase"]
	_play_phase = int(phases["PLAY"])
	root.add_child(_game)
	current_scene = _game
	_game.set_process_unhandled_input(false)
	RSSettings.apply(self)
	_prepare_buffers()
	if not _runtime_ok():
		return
	_stage = "waiting_for_play"
	RenderingServer.frame_post_draw.connect(_after_draw)
	print("RS_BENCH_START: " + _id)


func _describe() -> Dictionary:
	# This potentially slow OS query happens before the scene and warmup, never in samples.
	var driver := OS.get_video_adapter_driver_info()
	return {"gpu": RenderingServer.get_video_adapter_name(), "gpu_vendor": RenderingServer.get_video_adapter_vendor(),
		"driver": " ".join(driver) if not driver.is_empty() else null,
		"driver_source": "OS active-adapter query; may differ from a manually selected rendering adapter",
		"gpu_api_version": RenderingServer.get_video_adapter_api_version(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"godot_version": Engine.get_version_info()["string"], "resolution": [root.size.x, root.size.y],
		"seed": _seed, "reproducibility": {"global_seed_set": true, "scene_rng_fully_controlled": false,
			"limitations": "Scene-local RNG seeds and physics/tick scheduling are not overridden; demo input varies with frame timing"},
		"input": "Demo bots; external Hub processing and game keyboard navigation disabled",
		"gpu_ms_scope": "per_viewport_only; not a whole presented frame; gpu_ms is unavailable",
		"viewport_timing_scope": "RenderingServer last available viewport render work; not presentation wall time",
		"cpu_process_scope": "Performance.TIME_PROCESS * 1000; engine process time, not OS CPU utilization",
		"sampling": "frame_post_draw wall-clock intervals; JSON construction occurs after measurement",
		"settings": {"quality": _quality, "window": "windowed", "fps": "uncapped", "vsync": "disabled", "upscale": 0, "hdr": false}}


func _prepare_buffers() -> void:
	_viewports.append(root)
	_viewport_names.append("root")
	var ordered: Array = _game.call("ordered")
	for player: RefCounted in ordered:
		var camera: Camera3D = player.get("cam")
		var controller: RSController = player.get("c")
		_viewports.append(camera.get_viewport())
		_viewport_names.append("player_%d" % controller.player)
	for node: Node in root.find_children("*", "SubViewport", true, false):
		var viewport := node as Viewport
		if viewport not in _viewports:
			_viewports.append(viewport)
			_viewport_names.append("extra_%d" % _viewports.size())
	for viewport: Viewport in _viewports:
		RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
	_capacity = maxi(4, ceili(minf(_duration * 2000.0 + 2.0, float(MAX_SAMPLES))))
	_frame_ms.resize(_capacity)
	_cpu_ms.resize(_capacity)
	_draw_calls.resize(_capacity)
	_memory.resize(_capacity)
	_nodes.resize(_capacity)
	_gpu_times.resize(_capacity * _viewports.size())
	_render_cpu_times.resize(_capacity * _viewports.size())
	_metadata["viewport_names"] = _viewport_names
	_metadata["sample_capacity"] = _capacity


func _process(_delta: float) -> bool:
	if _stage in ["waiting_for_play", "warmup", "sampling"] and not _finishing:
		if not _runtime_ok():
			return false
		var now := Time.get_ticks_usec()
		if _stage == "waiting_for_play" and float(now - _started_us) / 1000000.0 > START_TIMEOUT:
			_abort("Timed out waiting for PLAY")
		elif _stage != "waiting_for_play" and float(now - _warm_us) / 1000000.0 > _warmup + _duration + 10.0:
			_abort("Rendered-frame sampling timed out")
	return false


func _runtime_ok() -> bool:
	var reason := ""
	if not is_instance_valid(_game) or (_game.is_inside_tree() and current_scene != _game):
		reason = "Game scene changed or was freed"
	elif paused:
		reason = "Game was paused"
	elif DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED or root.size != RESOLUTION or DisplayServer.window_get_size() != RESOLUTION:
		reason = "Window was minimized, resized or left 1600x900 windowed mode"
	elif Engine.time_scale != 1.0 or Engine.max_fps != 0 or DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED:
		reason = "Time scale, FPS cap or VSync changed"
	elif RSSettings.quality != _quality or RSSettings.upscale != 0 or RSSettings.hdr or RSSettings.window != 0 or RSSettings.FPS[RSSettings.fps] != RSSettings.UNCAPPED:
		reason = "Benchmark settings changed"
	elif int(_game.get("demo")) != _players or int(_game.get("map_index")) != _map or (_game.get("players") as Dictionary).size() != _players:
		reason = "Demo participants or selected map changed"
	elif _stage in ["warmup", "sampling"] and int(_game.get("phase")) != _play_phase:
		reason = "PLAY ended before the requested warmup and measurement completed"
	if not reason.is_empty():
		_abort(reason)
		return false
	return true


func _after_draw() -> void:
	if _finishing or not _runtime_ok():
		return
	var now := Time.get_ticks_usec()
	if _stage == "waiting_for_play":
		if int(_game.get("phase")) == _play_phase:
			_stage = "warmup"
			_warm_us = now
		return
	if _stage == "warmup":
		if float(now - _warm_us) / 1000000.0 >= _warmup:
			_stage = "sampling"
			_sample_us = now
			_last_us = now
		return
	if _stage != "sampling":
		return
	if _count >= _capacity:
		_abort("Preallocated sample capacity exhausted")
		return
	if now <= _last_us:
		_abort("Rendered frame timestamps did not advance")
		return
	_frame_ms[_count] = float(now - _last_us) / 1000.0
	_cpu_ms[_count] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_draw_calls[_count] = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_memory[_count] = int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	_nodes[_count] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	for i in _viewports.size():
		var rid := _viewports[i].get_viewport_rid()
		var at := _count * _viewports.size() + i
		_gpu_times[at] = RenderingServer.viewport_get_measured_render_time_gpu(rid)
		_render_cpu_times[at] = RenderingServer.viewport_get_measured_render_time_cpu(rid)
	_count += 1
	_last_us = now
	_elapsed = float(now - _sample_us) / 1000000.0
	if _elapsed >= _duration and _count >= 2:
		_finishing = true
		_finish.call_deferred()


func _abort(reason: String) -> void:
	if _finishing:
		return
	_errors.append(reason)
	_finishing = true
	_finish.call_deferred()


func _finish() -> void:
	_finishing = true
	_stage = "finished"
	if RenderingServer.frame_post_draw.is_connected(_after_draw):
		RenderingServer.frame_post_draw.disconnect(_after_draw)
	for viewport: Viewport in _viewports:
		if is_instance_valid(viewport):
			RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), false)
	_viewports.clear()
	# Release audio before the scene; allow the worker real time to drain, even on failure.
	if is_instance_valid(_game):
		for audio: AudioStreamPlayer in _game.find_children("*", "AudioStreamPlayer", true, false):
			audio.stop()
			audio.stream = null
		if current_scene == _game:
			current_scene = null
		_game.queue_free()
		_game = null
	paused = false
	var drain_until := Time.get_ticks_msec() + 350
	while Time.get_ticks_msec() < drain_until:
		await process_frame
	var samples: Array[Dictionary] = []
	for frame in _count:
		var gpu: Dictionary = {}
		var cpu: Dictionary = {}
		for i in _viewport_names.size():
			var at := frame * _viewport_names.size() + i
			var gpu_ms := _gpu_times[at]
			var cpu_ms := _render_cpu_times[at]
			gpu[_viewport_names[i]] = gpu_ms if is_finite(gpu_ms) and gpu_ms > 0.0 else null
			cpu[_viewport_names[i]] = cpu_ms if is_finite(cpu_ms) and cpu_ms >= 0.0 else null
		samples.append({"frame_ms": _frame_ms[frame], "cpu_process_ms": _cpu_ms[frame], "gpu_ms": null,
			"draw_calls": _draw_calls[frame], "video_memory_bytes": _memory[frame], "nodes": _nodes[frame],
			"gpu_viewports_ms": gpu, "cpu_render_viewports_ms": cpu})
	var report := {"schema_version": 1, "status": "PASS" if _errors.is_empty() else "FAIL", "game": _id,
		"map": _map, "players": _players, "quality": _quality, "warmup_seconds": _warmup,
		"duration_seconds": _duration, "elapsed_seconds": _elapsed, "frames": _count,
		"samples": samples, "metadata": _metadata, "errors": _errors}
	var file := FileAccess.open(_output, FileAccess.WRITE) if not _output.is_empty() else null
	if file == null:
		_errors.append("Cannot write benchmark output")
	else:
		file.store_string(JSON.stringify(report))
		file.close()
	if _errors.is_empty():
		print("RS_BENCH_DONE: " + _id)
	else:
		for error: String in _errors:
			push_error("Benchmark: " + error)
	quit(0 if _errors.is_empty() else 1)
