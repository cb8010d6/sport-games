extends Node2D
## Rendered HUD experiment, deliberately outside CI. Never run with --headless.
## Relative --shots paths are resolved from the repository root, above res://.

const WINDOW_SIZE := Vector2i(1600, 900)
const DURATION_US := 10_000_000
const SETTLE_SECONDS := 1.1
const OUTLINE := Color(0.01, 0.015, 0.03, 0.75)
# Deliberately invariant Chinese glyph corpus, exempt from product UI translation.
const SAMPLE_TITLE := "HUD 字体 0123456789"  # no-i18n: font metrics fixture
const SAMPLE_POPUP_LABEL := "加分飘字 36-45"  # no-i18n: font metrics fixture
const SAMPLE_POPUP := "+128 完美加分"  # no-i18n: font metrics fixture
const SAMPLE_COUNTDOWN_LABEL := "倒数 120-150"  # no-i18n: font metrics fixture
const SAMPLE_COUNTDOWN := "倒数 3"  # no-i18n: font metrics fixture
const SAMPLE_SCORE_LABEL := "分数弹跳 40-47"  # no-i18n: font metrics fixture
const SAMPLE_SCORE := "得分 0123456789"  # no-i18n: font metrics fixture
const SAMPLE_SMALL := "中文与数字 0123456789 +128"  # no-i18n: font metrics fixture

var _modes: Array[String] = ["raster", "msdf"]
var _shots_dir := ""
var _bold: Font
var _numeric: Font
var _files: Array[FontFile] = []
var _drawing := false
var _seconds := 0.0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("Real rendering is required; --headless is not a valid experiment.")
		return
	if not _parse_options():
		return
	var window := get_window()
	window.mode = Window.MODE_WINDOWED
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	window.content_scale_size = WINDOW_SIZE
	window.size = WINDOW_SIZE
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run.call_deferred()


func _parse_options() -> bool:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--font-mode="):
			var mode := arg.trim_prefix("--font-mode=")
			if mode not in ["raster", "msdf", "both"]:
				_fail("Expected --font-mode=raster|msdf|both.")
				return false
			_modes.clear()
			if mode == "both":
				_modes.append("raster")
				_modes.append("msdf")
			else:
				_modes.append(mode)
		elif arg.begins_with("--shots="):
			_shots_dir = arg.trim_prefix("--shots=")
			if _shots_dir.is_empty():
				_fail("--shots requires a directory.")
				return false
		else:
			_fail("Unknown probe option: " + arg)
			return false
	if not _shots_dir.is_empty():
		if _shots_dir.is_relative_path():
			_shots_dir = ProjectSettings.globalize_path("res://").path_join("..").path_join(_shots_dir).simplify_path()
		else:
			_shots_dir = ProjectSettings.globalize_path(_shots_dir)
		var error := DirAccess.make_dir_recursive_absolute(_shots_dir)
		if error != OK:
			_fail("Cannot create screenshot directory: %s" % error_string(error))
			return false
	return true


func _run() -> void:
	print("RS_FONT_PROBE_INFO: order=%s duration_s=10 resolution=1600x900 vsync=off max_fps=0" % ",".join(_modes))
	print("RS_FONT_PROBE_INFO: cold_clone_glyphs=true first_frame=enable_to_first_post_draw p99=R7 wall_clock_not_gpu=true")
	for mode: String in _modes:
		await _release_fonts()
		# Clone both branches with one map so shared Noto data remains shared within a mode.
		var copies: Dictionary = {}
		_bold = _copy_font(RSUi.font_bold(), mode == "msdf", copies)
		_numeric = _copy_font(RSUi.font_numeric(), mode == "msdf", copies)
		copies.clear()
		await _measure(mode)
		if not _shots_dir.is_empty():
			var saved := await _save_shot(mode)
			if not saved:
				return
	await _release_fonts()
	get_tree().quit()


func _copy_font(source: Font, msdf: bool, copies: Dictionary) -> Font:
	if source == null:
		return null
	var key := source.get_instance_id()
	if copies.has(key):
		return copies[key] as Font
	# A shallow duplicate alone would leave FontVariation.base_font and fallbacks shared.
	var copy := source.duplicate() as Font
	copies[key] = copy
	if copy is FontFile:
		var file := copy as FontFile
		file.clear_cache()
		file.multichannel_signed_distance_field = msdf
		file.msdf_pixel_range = 8
		file.msdf_size = 48
		_files.append(file)
	elif copy is SystemFont:
		var system := copy as SystemFont
		system.multichannel_signed_distance_field = msdf
		system.msdf_pixel_range = 8
		system.msdf_size = 48
	if source is FontVariation:
		(copy as FontVariation).base_font = _copy_font((source as FontVariation).base_font, msdf, copies)
	var fallbacks: Array[Font] = []
	for fallback: Font in source.fallbacks:
		fallbacks.append(_copy_font(fallback, msdf, copies))
	copy.fallbacks = fallbacks
	return copy


func _release_fonts() -> void:
	# Replace the canvas draw commands before clearing caches or dropping their owners.
	_drawing = false
	queue_redraw()
	await RenderingServer.frame_post_draw
	for file: FontFile in _files:
		file.clear_cache()
	_bold = null
	_numeric = null
	_files.clear()
	# Allow deferred renderer deletion and the low-frequency Performance monitor to settle.
	# This does not promise that every driver allocation or pipeline cache is released.
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	await RenderingServer.frame_post_draw


func _measure(mode: String) -> void:
	var tex_start := int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))
	var frames := PackedFloat64Array()
	_seconds = 0.0
	_drawing = true
	var started := Time.get_ticks_usec()
	var previous := started
	var elapsed_us := 0
	queue_redraw()
	while true:
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		elapsed_us = now - started
		frames.append(float(now - previous) / 1000.0)
		if elapsed_us >= DURATION_US:
			break
		previous = now
		_seconds = float(elapsed_us) / 1_000_000.0
		queue_redraw()
	var tex_end := int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))
	var sorted := frames.duplicate()
	sorted.sort()
	var rank := float(sorted.size() - 1) * 0.99
	var p99 := lerpf(sorted[floori(rank)], sorted[ceili(rank)], rank - floorf(rank))
	print("RS_FONT_PROBE: mode=%s tex_mem_start=%d tex_mem_end=%d first_frame_ms=%.3f p99_frame_ms=%.3f max_frame_ms=%.3f" % [mode, tex_start, tex_end, frames[0], p99, sorted[-1]])
	print("RS_FONT_PROBE_INFO: mode=%s samples=%d elapsed_ms=%.3f cloned_font_files=%d" % [mode, frames.size(), float(elapsed_us) / 1000.0, _files.size()])


func _save_shot(mode: String) -> bool:
	# Identical peak phase in both images; capture/resize/PNG I/O are outside the sample.
	_seconds = 0.5
	queue_redraw()
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null or image.is_empty() or image.get_size() != WINDOW_SIZE:
		_fail("Expected a rendered 1600x900 viewport for the screenshot.")
		return false
	image.resize(WINDOW_SIZE.x * 2, WINDOW_SIZE.y * 2, Image.INTERPOLATE_NEAREST)
	var path := _shots_dir.path_join("font_probe_%s_2x.png" % mode)
	var error := image.save_png(path)
	if error != OK:
		_fail("Cannot save screenshot: %s" % error_string(error))
		return false
	print("RS_FONT_PROBE_INFO: mode=%s screenshot=%s" % [mode, path])
	return true


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(WINDOW_SIZE)), Color("101722"))
	if not _drawing:
		return
	var pulse := 0.5 - 0.5 * cos(TAU * fmod(_seconds, 1.0))
	# Fixed Chinese test corpus, not product UI; both modes draw exactly the same strings.
	_text(SAMPLE_TITLE, Vector2(100, 80), 28, _bold, RSUi.TEXT)
	_text(SAMPLE_POPUP_LABEL, Vector2(100, 140), 22, _bold, RSUi.TEXT_MUTED)
	_text(SAMPLE_POPUP, Vector2(100, 270 - pulse * 55), lerpf(36, 45, pulse), _bold, RSUi.GOOD)
	_text(SAMPLE_COUNTDOWN_LABEL, Vector2(100, 360), 22, _bold, RSUi.TEXT_MUTED)
	_text(SAMPLE_COUNTDOWN, Vector2(100, 550), lerpf(120, 150, pulse), _bold, RSUi.ACCENT)
	_text(SAMPLE_SCORE_LABEL, Vector2(900, 360), 22, _numeric, RSUi.TEXT_MUTED)
	_text(SAMPLE_SCORE, Vector2(900, 470 - pulse * 12), lerpf(40, 47, pulse), _numeric, RSUi.TEXT)
	_text(SAMPLE_SMALL, Vector2(100, 720), 18, _bold, RSUi.TEXT)
	_text(SAMPLE_SMALL, Vector2(100, 780), 24, _numeric, RSUi.TEXT)


func _text(text: String, at: Vector2, size: float, font: Font, color: Color) -> void:
	var fs := RSUi.snap_font_size(size)
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, maxi(3, fs / 7), Color(OUTLINE, OUTLINE.a * color.a))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)


func _fail(message: String) -> void:
	push_error("RS_FONT_PROBE_ERROR: " + message)
	get_tree().quit(1)
