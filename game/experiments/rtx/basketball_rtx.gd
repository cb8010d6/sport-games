extends "res://scenes/basketball/basketball_game.gd"
## Isolated experiment: shared gameplay, fork properties accessed through reflection.

const FORK_COMMIT := "036c6c7023ab293699e25b95c775cb332f95406b"
var _mode := "rtx"
var _warmup := 12.0
var _duration := 20.0
var _report := "user://rtx-benchmark.json" # allow: ARCH-SAVE Existing benchmark output, written through RSNvidia.
var _samples: Array[float] = []
var _started := 0
var _previous := 0
var _memory := 0
var _running := false
var _view_count := 0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args(): # allow: ARCH-ARGS Legacy standalone probe must reject unsupported engines before constructing gameplay.
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
		if not RSNvidia.has_property(probe, &"pathtracing_enabled"):
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
		if not RSNvidia.lighting_available(2):
			_block("Vulkan ray tracing pipeline and DLSS Ray Reconstruction are required")
			return
	if OS.get_cmdline_user_args().has("--probe-only"): # allow: ARCH-ARGS Existing standalone probe.
		_write_report({"status": "probe_passed", "mode": _mode})
		RSExit.quit(get_tree())
		return
	RSSettings.load_once()
	RSSettings.upscale = 7 if _mode == "rtx" else 0
	RSSettings.nvidia_lighting = 2 if _mode == "rtx" else 0
	RSSettings.nvidia_preset = 0
	RSSettings.nvidia_sharpness = 0
	RSSettings.nvidia_fg = false
	super._ready()
	Engine.max_fps = 0
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var viewports: Array[Viewport] = [get_viewport()]
	for node: Node in find_children("*", "SubViewport", true, false):
		viewports.append(node as SubViewport)
		_view_count += 1
	if _view_count != demo or demo not in [1, 2, 4]:
		_block("Expected 1, 2 or 4 bot player viewports")
		return
	for viewport: Viewport in viewports:
		viewport.msaa_3d = Viewport.MSAA_DISABLED
		viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
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
			"dlss_preset_requested": RSNvidia.PRESETS[RSSettings.nvidia_preset],
			"resolution": get_viewport().get_visible_rect().size, "frame_generation": false,
			"frames": _samples.size(), "average_fps": 1000.0 * _samples.size() / total,
			"frame_ms_p50": _samples[int(_samples.size() * 0.50)],
			"frame_ms_p95": _samples[mini(int(_samples.size() * 0.95), _samples.size() - 1)],
			"peak_video_memory_bytes": _memory,
			"note": "Wall frame times; verify DLSS RR debug views and visuals on device. Not an input latency measurement."})
		_running = false
		RSExit.quit(get_tree())


func _block(reason: String) -> void:
	print("RTX experiment blocked: ", reason)
	_running = false
	_write_report({"status": "blocked", "reason": reason, "mode": _mode})
	RSExit.quit(get_tree(), 2)


func _write_report(data: Dictionary) -> void:
	if RSNvidia.write_report(_report, data) != OK:
		push_error("Cannot write benchmark report")
		RSExit.quit(get_tree(), 3)
		return
