extends "res://scenes/basketball/basketball_game.gd"
## Isolated experiment: shared gameplay, fork properties accessed through reflection.

const FORK_COMMIT := "135dff3887a3d2ccf45cafbd9bdffa7b718e1e76"
var _mode := "rtx"
var _warmup := 12.0
var _duration := 20.0
var _report := "user://rtx-benchmark.json"
var _samples: Array[float] = []
var _started := 0
var _previous := 0
var _memory := 0
var _running := false
var _view_count := 0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--render-mode="):
			_mode = arg.get_slice("=", 1)
		elif arg.begins_with("--report="):
			_report = arg.trim_prefix("--report=")
		elif arg.begins_with("--warmup="):
			_warmup = maxf(float(arg.get_slice("=", 1)), 0.0)
		elif arg.begins_with("--duration="):
			_duration = maxf(float(arg.get_slice("=", 1)), 1.0)
	if _mode not in ["raster", "rtx"]:
		_block("Unknown render mode")
		return
	if _mode == "rtx":
		var probe := Environment.new()
		if not _has_property(probe, &"pathtracing_enabled"):
			_block("This engine has no NVIDIA path tracing API")
			return
		if OS.get_name() != "Windows":
			_block("Pinned fork enables Streamline only on Windows")
			return
		if not str(Engine.get_version_info().get("hash", "")).begins_with(FORK_COMMIT.left(9)):
			_block("Engine commit differs from the pinned NVIDIA fork")
			return
		if DisplayServer.get_name() == "headless":
			_block("Headless mode cannot measure RTX rendering")
			return
		var rd := RenderingServer.get_rendering_device()
		if rd == null or not ClassDB.class_has_integer_constant("RenderingDevice", "SUPPORTS_RAYTRACING_PIPELINE"):
			_block("No ray tracing rendering device")
			return
		if not rd.has_feature(ClassDB.class_get_integer_constant("RenderingDevice", "SUPPORTS_RAYTRACING_PIPELINE")):
			_block("GPU or driver does not support ray tracing pipelines")
			return
		if not "RTX" in RenderingServer.get_video_adapter_name().to_upper():
			_block("DLSS Ray Reconstruction experiment requires an NVIDIA RTX GPU")
			return
	if OS.get_cmdline_user_args().has("--probe-only"):
		_write_report({"status": "probe_passed", "mode": _mode})
		get_tree().quit()
		return
	super._ready()
	Engine.max_fps = 0
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	for node: Node in find_children("*", "WorldEnvironment", true, false):
		var environment: Environment = (node as WorldEnvironment).environment
		if _has_property(environment, &"pathtracing_enabled"):
			environment.set("pathtracing_enabled", _mode == "rtx")
			if _mode == "rtx":
				environment.set("pathtracing_denoiser", ClassDB.class_get_integer_constant("RenderingServer", "PT_DENOISER_DLSS_RAY_RECONSTRUCTION"))
				environment.set("pathtracing_samples_per_pixel", 1)
	var viewports: Array[Viewport] = [get_viewport()]
	for node: Node in find_children("*", "SubViewport", true, false):
		viewports.append(node as SubViewport)
		_view_count += 1
	if _view_count != demo or demo not in [1, 2, 4]:
		_block("Expected 1, 2 or 4 bot player viewports")
		return
	for viewport: Viewport in viewports:
		if _has_property(viewport, &"frame_generation"):
			viewport.set("frame_generation", false)
		viewport.msaa_3d = Viewport.MSAA_DISABLED
		viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		viewport.scaling_3d_scale = 0.66 if _mode == "rtx" else 1.0
		viewport.scaling_3d_mode = ClassDB.class_get_integer_constant("Viewport", "SCALING_3D_MODE_DLSS") if _mode == "rtx" else Viewport.SCALING_3D_MODE_BILINEAR
	_started = Time.get_ticks_usec()
	_previous = _started
	_running = true
	print("RTX experiment configured: ", _mode, ", views=", _view_count)


func _process(delta: float) -> void:
	if not _running:
		return
	super._process(delta)
	var now := Time.get_ticks_usec()
	var elapsed := float(now - _started) / 1000000.0
	if elapsed >= _warmup and phase == Phase.PLAY:
		_samples.append(float(now - _previous) / 1000.0)
		_memory = maxi(_memory, int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)))
	_previous = now
	if elapsed >= _warmup + _duration:
		if _samples.size() < 10:
			_block("Not enough gameplay frames; no performance result")
			return
		_samples.sort()
		var total := 0.0
		for sample in _samples:
			total += sample
		_write_report({"status": "measured", "mode": _mode, "players": demo, "map": map_index,
			"engine": Engine.get_version_info(), "gpu": RenderingServer.get_video_adapter_name(),
			"driver": RenderingServer.get_current_rendering_driver_name(),
			"resolution": get_viewport().get_visible_rect().size, "frame_generation": false,
			"frames": _samples.size(), "average_fps": 1000.0 * _samples.size() / total,
			"frame_ms_p50": _samples[int(_samples.size() * 0.50)],
			"frame_ms_p95": _samples[mini(int(_samples.size() * 0.95), _samples.size() - 1)],
			"peak_video_memory_bytes": _memory,
			"note": "Wall frame times; verify DLSS RR debug views and visuals on device. Not an input latency measurement."})
		get_tree().quit()


func _has_property(object: Object, property: StringName) -> bool:
	for item: Dictionary in object.get_property_list():
		if item.name == property:
			return true
	return false


func _block(reason: String) -> void:
	print("RTX experiment blocked: ", reason)
	_write_report({"status": "blocked", "reason": reason, "mode": _mode})
	get_tree().quit(2)


func _write_report(data: Dictionary) -> void:
	var file := FileAccess.open(_report, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write benchmark report")
		get_tree().quit(3)
		return
	file.store_string(JSON.stringify(data, "\t") + "\n")
