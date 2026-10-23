class_name RSBenchmark
extends Node
## Real rendered-frame samples and shared CLI/menu statistics. The host owns the game,
## temporary settings and cleanup; this node never selects scenes, saves settings or exits.
## Frame intervals use monotonic post-draw ticks. GPU readings describe individual viewports.

signal completed(report: Dictionary)
signal progress_changed(stage: String, elapsed: float, duration: float, frame_ms: float)

enum Stage { IDLE, WAITING, WARMUP, SAMPLING, ENDING }
const START_TIMEOUT := 120.0
const PROGRESS_USEC := 250000
const MAX_SAMPLES := 1000000
const STAGE_NAMES := ["idle", "waiting_for_play", "warmup", "sampling", "finished"]

var _game: RSPartyGame
var _host_scene: Node
var _request: Dictionary = {}
var _metadata: Dictionary = {}
var _errors: Array[String] = []
var _stage := Stage.IDLE
var _started_us := 0
var _warm_us := 0
var _sample_us := 0
var _last_us := 0
var _progress_us := 0
var _elapsed := 0.0
var _count := 0
var _capacity := 0
var _expected_hdr := false
var _viewports: Array[Viewport] = []
var _viewport_names := PackedStringArray()
var _frame_ms := PackedFloat64Array()
var _cpu_ms := PackedFloat64Array()
var _draw_calls := PackedInt64Array()
var _memory := PackedInt64Array()
var _nodes := PackedInt64Array()
var _gpu_times := PackedFloat64Array()
var _render_cpu_times := PackedFloat64Array()


func begin(game: RSPartyGame, request: Dictionary) -> Error:
	if _stage != Stage.IDLE:
		return ERR_ALREADY_IN_USE
	if not is_inside_tree() or not is_instance_valid(game) or not game.is_inside_tree() or game.get_tree() != get_tree() or not game.benchmark_mode:
		return ERR_INVALID_PARAMETER
	if not _valid_request(game, request):
		return ERR_INVALID_PARAMETER
	if DisplayServer.get_name() == "headless" or RenderingServer.get_video_adapter_name().is_empty():
		return ERR_UNAVAILABLE
	# Engine simulation/movie flags invalidate rendering conditions, independently
	# of the application's command-line interface owned by RSPartyGame.
	for arg: String in OS.get_cmdline_args():
		if arg.get_slice("=", 0) in ["--headless", "--fixed-fps", "--disable-render-loop", "--write-movie"]:
			return ERR_UNAVAILABLE
	_game = game
	_host_scene = get_tree().current_scene
	_request = request.duplicate(true)
	var resolution := _resolution(request["resolution"])
	_request["resolution"] = resolution
	_expected_hdr = RSSettings.hdr
	_errors.clear()
	_count = 0
	_elapsed = 0.0
	_started_us = Time.get_ticks_usec()
	_warm_us = 0
	_sample_us = 0
	_progress_us = 0
	_metadata = _describe(resolution)
	_prepare_buffers()
	_stage = Stage.WAITING
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	RenderingServer.frame_post_draw.connect(_after_draw)
	var reason := _health_error()
	if not reason.is_empty():
		_end("FAIL", reason)
	return OK


static func _resolution(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Array and value.size() == 2 and value[0] is int and value[1] is int:
		return Vector2i(value[0], value[1])
	return Vector2i.ZERO


static func _valid_request(game: RSPartyGame, request: Dictionary) -> bool:
	for key: String in ["game", "map", "players", "quality", "warmup_seconds", "duration_seconds", "seed", "resolution"]:
		if not request.has(key):
			return false
	for key: String in ["map", "players", "quality", "seed"]:
		if not request[key] is int:
			return false
	for key: String in ["warmup_seconds", "duration_seconds"]:
		if not _number(request[key], 0.0):
			return false
	var resolution := _resolution(request["resolution"])
	return request["game"] is String and request["game"] == game.game_id() and request["map"] == game.map_index and request["players"] == game.demo and request["players"] in [1, 2, 4] and request["quality"] in range(4) and request["seed"] >= 0 and float(request["duration_seconds"]) > 0.0 and resolution.x > 0 and resolution.y > 0


func cancel() -> void:
	if _stage >= Stage.WAITING and _stage <= Stage.SAMPLING:
		_end("CANCELLED")


func _describe(resolution: Vector2i) -> Dictionary:
	# The potentially slow OS query runs before warmup, never inside the sample window.
	var driver := OS.get_video_adapter_driver_info()
	var build := OS.get_environment("REGINA_BUILD_COMMIT")
	return {"gpu": RenderingServer.get_video_adapter_name(), "gpu_vendor": RenderingServer.get_video_adapter_vendor(),
		"driver": " ".join(driver) if not driver.is_empty() else null,
		"driver_source": "OS active-adapter query; may differ from a manually selected rendering adapter",
		"gpu_api_version": RenderingServer.get_video_adapter_api_version(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"godot_version": Engine.get_version_info()["string"], "resolution": [resolution.x, resolution.y],
		"application_version": ProjectSettings.get_setting("application/config/version", "unknown"),
		"power_state": null, "power_state_source": "Not collected by the runtime; use external AC monitoring for a formal baseline",
		"source_commit": build if not build.is_empty() else null,
		"sampler_version": "rsbenchmark-1", "seed": _request["seed"],
		"reproducibility": {"global_seed_applied_by_host": true, "scene_rng_fully_controlled": false,
			"limitations": "Host sets global seed before scene construction; local RNG seeds and physics/tick scheduling are not overridden; demo input varies with frame timing"},
		"input": "Benchmark demo bots; physical game navigation ignored",
		"gpu_ms_scope": "per_viewport_only; not a whole presented frame; gpu_ms is unavailable",
		"viewport_timing_scope": "RenderingServer last available viewport render work; not presentation wall time",
		"cpu_process_scope": "Performance.TIME_PROCESS * 1000; engine process time, not OS CPU utilization",
		"sampling": "frame_post_draw wall-clock intervals; includes host overlay and sampler overhead",
		"settings": {"quality": _request["quality"], "window": "windowed", "fps": "uncapped", "vsync": "disabled", "upscale": 0,
			"hdr": _expected_hdr, "hdr_active": RSSettings.hdr_active()}}


func _prepare_buffers() -> void:
	_viewports = _game.benchmark_viewports()
	_viewport_names.clear()
	for viewport: Viewport in _viewports:
		var label := "root" if viewport == get_tree().root else "viewport_%d" % _viewport_names.size()
		for player: RSPartyGame.Player in _game.ordered():
			if is_instance_valid(player.cam) and player.cam.get_viewport() == viewport:
				label = "player_%d" % player.c.player
		_viewport_names.append(label)
		RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
	_capacity = maxi(4, ceili(minf(float(_request["duration_seconds"]) * 2000.0 + 2.0, float(MAX_SAMPLES))))
	_frame_ms.resize(_capacity)
	_cpu_ms.resize(_capacity)
	_draw_calls.resize(_capacity)
	_memory.resize(_capacity)
	_nodes.resize(_capacity)
	_gpu_times.resize(_capacity * _viewports.size())
	_render_cpu_times.resize(_capacity * _viewports.size())
	_metadata["viewport_names"] = _viewport_names
	_metadata["sample_capacity"] = _capacity


func _health_error() -> String:
	if not is_instance_valid(_game) or not _game.is_inside_tree() or get_tree().current_scene != _host_scene:
		return "Game scene changed or was freed"
	if get_tree().paused:
		return "Game was paused"
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED or get_tree().root.size != _request["resolution"] or DisplayServer.window_get_size() != _request["resolution"]:
		return "Window was minimized, resized or left the requested windowed resolution"
	if Engine.time_scale != 1.0 or Engine.max_fps != 0 or DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED:
		return "Time scale, FPS cap or VSync changed"
	if RSSettings.quality != _request["quality"] or RSSettings.upscale != 0 or RSSettings.hdr != _expected_hdr or RSSettings.window != 0 or RSSettings.fps < 0 or RSSettings.fps >= RSSettings.FPS.size() or RSSettings.FPS[RSSettings.fps] != RSSettings.UNCAPPED:
		return "Benchmark settings changed"
	if not _game.benchmark_mode or _game.demo != _request["players"] or _game.map_index != _request["map"] or _game.players.size() != _request["players"]:
		return "Demo participants or selected map changed"
	if (_stage == Stage.WARMUP or _stage == Stage.SAMPLING) and _game.phase != RSPartyGame.Phase.PLAY:
		return "PLAY ended before the requested warmup and measurement completed"
	for viewport: Viewport in _viewports:
		if not is_instance_valid(viewport) or not viewport.is_inside_tree():
			return "A measured viewport was freed"
	return ""


func _process(_delta: float) -> void:
	if _stage < Stage.WAITING or _stage > Stage.SAMPLING:
		return
	var reason := _health_error()
	if not reason.is_empty():
		_end("FAIL", reason)
		return
	var now := Time.get_ticks_usec()
	if _stage == Stage.WAITING and float(now - _started_us) / 1000000.0 > START_TIMEOUT:
		_end("FAIL", "Timed out waiting for PLAY")
	elif _stage != Stage.WAITING and float(now - _warm_us) / 1000000.0 > float(_request["warmup_seconds"]) + float(_request["duration_seconds"]) + 10.0:
		_end("FAIL", "Rendered-frame sampling timed out")
	else:
		_notify_progress(now)


func _notify_progress(now: int, force: bool = false) -> void:
	if not force and now - _progress_us < PROGRESS_USEC:
		return
	_progress_us = now
	var elapsed := float(now - _started_us) / 1000000.0
	var duration := START_TIMEOUT
	if _stage == Stage.WARMUP:
		elapsed = float(now - _warm_us) / 1000000.0
		duration = float(_request["warmup_seconds"])
	elif _stage == Stage.SAMPLING:
		elapsed = _elapsed
		duration = float(_request["duration_seconds"])
	progress_changed.emit(STAGE_NAMES[_stage], elapsed, duration, _frame_ms[_count - 1] if _count > 0 else 0.0)


func _after_draw() -> void:
	if _stage < Stage.WAITING or _stage > Stage.SAMPLING:
		return
	var reason := _health_error()
	if not reason.is_empty():
		_end("FAIL", reason)
		return
	var now := Time.get_ticks_usec()
	if _stage == Stage.WAITING:
		if _game.phase == RSPartyGame.Phase.PLAY:
			_stage = Stage.WARMUP
			_warm_us = now
			_notify_progress(now, true)
		return
	if _stage == Stage.WARMUP:
		if float(now - _warm_us) / 1000000.0 >= float(_request["warmup_seconds"]):
			_stage = Stage.SAMPLING
			_sample_us = now
			_last_us = now
			_notify_progress(now, true)
		return
	if _count >= _capacity or now <= _last_us:
		_end("FAIL", "Sample capacity exhausted or rendered timestamps did not advance")
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
	if _elapsed >= float(_request["duration_seconds"]) and _count >= 2:
		_end("PASS")


func _end(status: String, reason: String = "") -> void:
	if _stage < Stage.WAITING or _stage > Stage.SAMPLING:
		return
	_stage = Stage.ENDING
	set_process(false)
	if not reason.is_empty():
		_errors.append(reason)
	_detach()
	_finish.call_deferred(status)


func _detach() -> void:
	if RenderingServer.frame_post_draw.is_connected(_after_draw):
		RenderingServer.frame_post_draw.disconnect(_after_draw)
	for viewport: Viewport in _viewports:
		if is_instance_valid(viewport):
			RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), false)
	_viewports.clear()


func _exit_tree() -> void:
	_detach()


func _finish(status: String) -> void:
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
	var report := {"schema_version": 1, "status": status, "game": _request["game"], "map": _request["map"],
		"players": _request["players"], "quality": _request["quality"], "warmup_seconds": _request["warmup_seconds"],
		"duration_seconds": _request["duration_seconds"], "elapsed_seconds": _elapsed, "frames": _count,
		"samples": samples, "metadata": _metadata, "errors": _errors.duplicate()}
	_game = null
	_host_scene = null
	_stage = Stage.IDLE
	completed.emit(report)


static func _number(value: Variant, minimum: float) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) >= minimum


static func _percentile(sorted: PackedFloat64Array, fraction: float) -> float:
	var position := float(sorted.size() - 1) * fraction
	var lower := floori(position)
	return lerpf(sorted[lower], sorted[ceili(position)], position - float(lower))


static func statistics(report: Dictionary) -> Dictionary:
	## R7 percentiles and FPS from summed intervals, matching tools/bench.py.
	if report.get("status", "PASS") != "PASS" or not report.get("samples") is Array:
		return {}
	var samples: Array = report["samples"]
	if samples.is_empty():
		return {}
	var times := PackedFloat64Array()
	times.resize(samples.size())
	var total := 0.0
	var cpu_total := 0.0
	var draws := 0.0
	var memory := 0
	var nodes := 0
	var gpu_totals: Dictionary = {}
	var gpu_counts: Dictionary = {}
	for i in samples.size():
		if not samples[i] is Dictionary:
			return {}
		var sample: Dictionary = samples[i]
		for key: String in ["frame_ms", "cpu_process_ms", "draw_calls", "video_memory_bytes", "nodes"]:
			if not _number(sample.get(key), 0.0):
				return {}
		var ms := float(sample["frame_ms"])
		if ms <= 0.0:
			return {}
		times[i] = ms
		total += ms
		cpu_total += float(sample["cpu_process_ms"])
		draws += float(sample["draw_calls"])
		memory = maxi(memory, int(sample["video_memory_bytes"]))
		nodes = maxi(nodes, int(sample["nodes"]))
		if not sample.get("gpu_viewports_ms", {}) is Dictionary:
			return {}
		var gpu: Dictionary = sample.get("gpu_viewports_ms", {})
		for name: String in gpu:
			if not gpu_counts.has(name):
				gpu_counts[name] = 0
				gpu_totals[name] = 0.0
			if _number(gpu[name], 0.0) and float(gpu[name]) > 0.0:
				gpu_totals[name] += float(gpu[name])
				gpu_counts[name] += 1
	times.sort()
	var slow_count := ceili(float(times.size()) * 0.01)
	var slow_total := 0.0
	for i in range(times.size() - slow_count, times.size()):
		slow_total += times[i]
	var gpu_average: Dictionary = {}
	var gpu_coverage: Dictionary = {}
	for name: String in gpu_counts:
		gpu_average[name] = float(gpu_totals[name]) / float(gpu_counts[name]) if gpu_counts[name] > 0 else null
		gpu_coverage[name] = float(gpu_counts[name]) / float(samples.size())
	return {"avg_fps": 1000.0 * float(samples.size()) / total, "frame_ms_p50": _percentile(times, 0.5),
		"frame_ms_p95": _percentile(times, 0.95), "frame_ms_p99": _percentile(times, 0.99),
		"frame_ms_worst": times[-1], "one_percent_low_fps": 1000.0 * float(slow_count) / slow_total,
		"cpu_process_ms_avg": cpu_total / float(samples.size()), "gpu_ms_avg": null, "gpu_samples": 0,
		"draw_calls_avg": draws / float(samples.size()), "video_memory_bytes_max": memory, "nodes_max": nodes,
		"gpu_viewports_ms_avg": gpu_average, "gpu_viewports_coverage": gpu_coverage}
