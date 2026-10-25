class_name RSBenchmarkMenu
extends Control
## Settings-only benchmark host. Real games are children; cleanup precedes settings restore.
## Wall-clock warmup/sample defaults stay 10/30 s; tests may inject shorter durations explicitly.
## Three views share one themed layer: the config page, the run overlay and the results page.
## Every look comes from RSUi (docs/UI_THEME.md); buttons stay outside the result scroll area.

signal run_completed(reports: Array[Dictionary])
signal _case_finished(report: Dictionary)

static var CASES := RSCatalog.benchmark_ids()   ## manifests with benchmark = true, in menu order
const RESOLUTIONS := [Vector2i(1600, 900), Vector2i(1920, 1080)]
const BENCH_SEED := 20261023
const MIN_GPU_COVERAGE := 0.5     ## below this share of valid viewport readings the estimate is withheld
static var return_to_settings := false
var warmup_seconds := 10.0
var duration_seconds := 30.0
var running := false
var results: Array[Dictionary] = []
var _session := RSBenchmarkSession.new()
var _game: RSPartyGame
var _sampler: RSBenchmark
var _cancelled := false
var _closing := false
var _case_name := ""
var _run_config: Dictionary = {}
var _players: OptionButton
var _quality: OptionButton
var _resolution: OptionButton
var _backdrop: ColorRect
var _config: PanelContainer
var _results: PanelContainer
var _overlay: PanelContainer
var _message: Label
var _status: Label
var _detail: Label
var _stage: PanelContainer
var _progress: ProgressBar
var _graph: FrameGraph
var _results_subtitle: Label
var _results_status: PanelContainer
var _results_scroll: ScrollContainer
var _results_column: VBoxContainer
var _export_message: Label
var _export: Button
var _start: Button
var _again: Button
var _cancel: Button
var _controls: Array[BaseButton] = []

class FrameGraph extends Control:
	const CAPACITY := 96
	const MAX_MS := 60.0          ## vertical scale; slower frames are clipped at the top
	const GRID_MS := [20.0, 40.0]
	var values := PackedFloat32Array()
	var count := 0
	var cursor := 0
	var stretch_history := false
	var target_ms := 0.0          ## reference frame budget line; 0 hides it

	func _init() -> void:
		values.resize(CAPACITY)
		custom_minimum_size = Vector2(0, 64)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func sample(frame_ms: float) -> void:
		values[cursor] = frame_ms
		cursor = (cursor + 1) % CAPACITY
		count = mini(count + 1, CAPACITY)
		queue_redraw()

	func clear() -> void:
		count = 0
		cursor = 0
		queue_redraw()

	func _y(ms: float) -> float:
		return size.y * (1.0 - minf(ms / MAX_MS, 1.0))

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), RSUi.SCRIM)
		var font := RSUi.font()
		var font_size := RSUi.text_size(12)
		for ms: float in GRID_MS:
			draw_line(Vector2(0, _y(ms)), Vector2(size.x, _y(ms)), RSUi.STROKE, 1.0)
			draw_string(font, Vector2(6, _y(ms) - 4), "%.0f ms" % ms, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, RSUi.TEXT_MUTED)
		if target_ms > 0.0:
			draw_dashed_line(Vector2(0, _y(target_ms)), Vector2(size.x, _y(target_ms)), RSUi.HIGHLIGHT, 1.5, 8.0)
			draw_string(font, Vector2(0, _y(target_ms) - 4), "%.0f FPS" % (1000.0 / target_ms), HORIZONTAL_ALIGNMENT_RIGHT, size.x - 6, font_size, RSUi.HIGHLIGHT)
		if count < 2:
			return
		var width_steps := maxi(1, count - 1) if stretch_history else CAPACITY - 1
		var line := PackedVector2Array()
		line.resize(count)
		for i in count:
			line[i] = Vector2(i * size.x / width_steps, _y(values[posmod(cursor - count + i, CAPACITY)]))
		var area := line.duplicate()
		area.append(Vector2(line[-1].x, size.y))
		area.append(Vector2(0, size.y))
		draw_colored_polygon(area, Color(RSUi.ACCENT, 0.16))
		draw_polyline(line, RSUi.ACCENT, 2.0, true)


func _ready() -> void:
	RSSettings.load_once()
	theme = RSUi.theme(20)
	get_tree().root.close_requested.connect(_window_closed)
	RSExit.install(get_tree())
	ControllerHub.button_pressed.connect(_on_button)
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	# A CanvasLayer interrupts theme inheritance, so the layer's root carries the theme again.
	var ui := Control.new()
	ui.theme = theme
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(ui)
	_backdrop = ColorRect.new()
	_backdrop.color = Color(RSUi.SCRIM, 1.0)
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_backdrop)
	_build_config(ui)
	_build_results(ui)
	_build_overlay(ui)
	_results.hide()
	_overlay.hide()
	_players.grab_focus()


func _build_config(ui: Control) -> void:
	_config = _modal(ui, Vector2(1120, 0))
	var column := _column(_config, 14)
	var device := "%s · %s / %s" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_current_rendering_method(), RenderingServer.get_current_rendering_driver_name()]
	var header := _header(column, tr("性能测试"), tr("滑板 → 滑雪 → 篮球 · 地图 1 · 约 2–3 分钟（加载另计）"))
	# The adapter name can be long, so it sits under the subtitle instead of squeezing it from the right.
	header.get_child(1).add_child(_chip(device, RSUi.ACCENT))
	column.add_child(HSeparator.new())
	_players = _option(column, tr("人数"), tr("双人或四人分屏；四人同时渲染更多视口。"), [tr("双人"), tr("四人")], 0)
	var qualities: Array[String] = []
	for quality: String in RSSettings.QUALITY_NAMES:
		qualities.append(tr(quality))
	_quality = _option(column, tr("画质"), tr("只在测试期间临时使用，不改变你的画面设置。"), qualities, RSSettings.quality)
	_resolution = _option(column, tr("分辨率"), tr("窗口模式输出；测试期间关闭超分，使用原生分辨率渲染。"), ["1600 × 900", "1920 × 1080"], 1 if get_tree().root.size == RESOLUTIONS[1] else 0)
	var notes := _card(column, 6)
	notes.add_child(RSUi.label(tr("临时关闭垂直同步与帧率上限，使用原生分辨率；完成或取消后恢复设置，不保存偏好。"), 16, RSUi.TEXT_MUTED, true))
	notes.add_child(RSUi.label(tr("固定场景与起始种子；轨迹和粒子可能随帧率变化。曲线界面的开销计入测量。"), 16, RSUi.TEXT_MUTED, true))
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 14)
	column.add_child(footer)
	_message = RSUi.label("", 17, RSUi.HIGHLIGHT, true)
	_message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_message)
	_start = _button(footer, tr("开始性能测试"), begin_run)
	_start.theme_type_variation = &"RSPrimary"
	_start.custom_minimum_size.x = 240
	column.add_child(RSUi.label(tr("手柄：B / C 选择，A 确认，D 取消 / 返回；键盘：方向键、回车、Esc。"), 15, RSUi.TEXT_MUTED, true))


func _build_results(ui: Control) -> void:
	_results = _modal(ui, Vector2(1480, 820))
	var column := _column(_results, 12)
	var header := _header(column, tr("测试结果"), "")
	_results_subtitle = header.get_child(1).get_child(1) as Label
	_results_status = _chip("", RSUi.GOOD)
	header.add_child(_results_status)
	column.add_child(HSeparator.new())
	_results_scroll = ScrollContainer.new()
	_results_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_results_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_results_scroll)
	_results_column = VBoxContainer.new()
	_results_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_results_column.add_theme_constant_override("separation", 14)
	_results_scroll.add_child(_results_column)
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	column.add_child(footer)
	_export_message = RSUi.label("", 15, RSUi.TEXT_MUTED, true)
	_export_message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_export_message)
	_button(footer, tr("上一页结果"), _scroll_results.bind(-1))
	_button(footer, tr("下一页结果"), _scroll_results.bind(1))
	_button(footer, tr("更改设置"), _show_config)
	_export = _button(footer, tr("导出 JSON / CSV"), export_results)
	_export.disabled = true
	_again = _button(footer, tr("再测一次"), begin_run)
	_again.theme_type_variation = &"RSPrimary"
	_again.custom_minimum_size.x = 180


func _build_overlay(ui: Control) -> void:
	_overlay = PanelContainer.new()
	var style := RSUi.modal_style()
	style.set_content_margin_all(20)
	_overlay.add_theme_stylebox_override("panel", style)
	_overlay.position = Vector2(24, 24)
	_overlay.custom_minimum_size = Vector2(560, 0)
	ui.add_child(_overlay)
	var column := _column(_overlay, 10)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	column.add_child(top)
	_status = _title(tr("性能测试"), 24)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_status)
	_stage = _chip("", RSUi.ACCENT)
	top.add_child(_stage)
	_detail = RSUi.label("", 18, RSUi.TEXT)
	column.add_child(_detail)
	_progress = ProgressBar.new()
	_progress.show_percentage = false
	_progress.custom_minimum_size.y = 10
	var track := RSUi.card_style()
	track.set_content_margin_all(0)
	_progress.add_theme_stylebox_override("background", track)
	var fill := RSUi.chip_style(RSUi.ACCENT)
	fill.bg_color = RSUi.ACCENT
	fill.set_content_margin_all(0)
	_progress.add_theme_stylebox_override("fill", fill)
	column.add_child(_progress)
	column.add_child(RSUi.label(tr("帧时间曲线 · 0–60 毫秒"), 14, RSUi.TEXT_MUTED))
	_graph = FrameGraph.new()
	_graph.custom_minimum_size.y = 96
	column.add_child(_graph)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 12)
	column.add_child(bottom)
	var hint := RSUi.label(tr("Esc / 手柄 D 取消"), 15, RSUi.TEXT_MUTED)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(hint)
	_cancel = _button(bottom, tr("取消测试"), cancel_run)


# ------------------------------------------------------------------ widgets ----

func _modal(ui: Control, minimum: Vector2) -> PanelContainer:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = minimum
	panel.add_theme_stylebox_override("panel", RSUi.modal_style())
	center.add_child(panel)
	return panel


func _column(parent: Control, separation: int) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", separation)
	parent.add_child(column)
	return column


func _title(text: String, size: int) -> Label:
	var label := RSUi.label(text, size, RSUi.TEXT)
	label.add_theme_font_override("font", RSUi.font_bold())
	return label


func _header(parent: Control, title: String, subtitle: String) -> HBoxContainer:
	## Back button, bold title over a muted subtitle; callers append a status chip on the right.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 18)
	parent.add_child(header)
	_button(header, tr("◀ 返回"), _back).size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", 2)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(titles)
	titles.add_child(_title(title, 34))
	titles.add_child(RSUi.label(subtitle, 17, RSUi.TEXT_MUTED, true))
	return header


func _chip(text: String, tint: Color, size: int = 16) -> PanelContainer:
	var chip := PanelContainer.new()
	chip.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.add_child(RSUi.label(text, size, tint))
	_tint_chip(chip, text, tint)
	return chip


func _tint_chip(chip: PanelContainer, text: String, tint: Color) -> void:
	chip.add_theme_stylebox_override("panel", RSUi.chip_style(tint))
	var label := chip.get_child(0) as Label
	label.text = text
	label.add_theme_color_override("font_color", tint)


func _card(parent: Control, separation: int = 8) -> VBoxContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", RSUi.card_style())
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", separation)
	card.add_child(box)
	return box


func _option(parent: Control, title: String, hint: String, names: Array[String], selected: int) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	_card(parent).add_child(row)
	var text := VBoxContainer.new()
	text.add_theme_constant_override("separation", 2)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text)
	text.add_child(_title(title, 22))
	text.add_child(RSUi.label(hint, 16, RSUi.TEXT_MUTED, true))
	var option := OptionButton.new()
	option.custom_minimum_size = Vector2(380, 44)
	option.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for item_name: String in names:
		option.add_item(item_name)
	option.select(selected)
	row.add_child(option)
	_controls.append(option)
	return option


func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 44
	button.pressed.connect(action)
	parent.add_child(button)
	_controls.append(button)
	return button


func _metric(grid: GridContainer, name: String, value: String, wrap: bool = false) -> void:
	grid.add_child(RSUi.label(name, 17, RSUi.TEXT_MUTED))
	var label := RSUi.label(value, 18, RSUi.TEXT, wrap)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(label)


func _metric_grid(parent: Control, pairs: int = 1) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = pairs * 2
	grid.add_theme_constant_override("h_separation", 16 if pairs == 1 else 28)
	grid.add_theme_constant_override("v_separation", 6)
	parent.add_child(grid)
	return grid


# --------------------------------------------------------------------- flow ----

func begin_run() -> void:
	if running or _closing:
		return
	results.clear()
	_clear_results()
	_message.text = ""
	_export_message.text = ""
	_export.disabled = true
	_graph.clear()
	_cancelled = false
	var resolution: Vector2i = RESOLUTIONS[_resolution.selected]
	var quality := _quality.selected
	var players := 2 if _players.selected == 0 else 4
	_run_config = {"players": players, "quality": quality, "resolution": resolution,
		"warmup_seconds": warmup_seconds, "duration_seconds": duration_seconds}
	var error := _session.begin(get_tree(), quality, resolution)
	if error != OK:
		_show_config()
		_message.text = tr("无法开始性能测试（错误 %d）。") % error
		return
	running = true
	_graph.target_ms = 1000.0 / _target_fps(players)
	_backdrop.hide()
	_config.hide()
	_results.hide()
	_overlay.show()
	_cancel.grab_focus()
	for game_id: String in CASES:
		if _cancelled or _closing:
			break
		_case_name = tr(RSCatalog.find_game(game_id)["name"])
		_status.text = _case_name
		_detail.text = tr("加载中…")
		_tint_chip(_stage, tr("加载"), RSUi.TEXT_MUTED)
		_progress.value = 0.0
		seed(BENCH_SEED)
		var packed := load(RSCatalog.find_game(game_id)["scene"]) as PackedScene
		if packed == null:
			results.append({"game": game_id, "status": "FAIL", "errors": [tr("场景加载失败。")]})
			break
		_game = packed.instantiate() as RSPartyGame
		if _game == null or _game.configure_benchmark(players, 0) != OK:
			results.append({"game": game_id, "status": "FAIL", "errors": [tr("测试场景配置失败。")]})
			await _cleanup_case()
			break
		add_child(_game)
		_sampler = RSBenchmark.new()
		add_child(_sampler)
		_sampler.progress_changed.connect(_on_progress)
		_sampler.completed.connect(_accept_report)
		var request := {"game": game_id, "map": 0, "players": players, "quality": quality,
			"warmup_seconds": warmup_seconds, "duration_seconds": duration_seconds, "seed": BENCH_SEED, "resolution": resolution}
		error = _sampler.begin(_game, request)
		var report: Dictionary = {"game": game_id, "status": "FAIL", "errors": [tr("采样器启动失败（错误 %d）。") % error]}
		if error == OK:
			report = await _case_finished
		var metadata: Dictionary = report.get("metadata", {})
		metadata["entrypoint"] = "in_game"
		metadata["overlay_enabled"] = true
		metadata["overlay_refresh_seconds"] = 0.25
		report["metadata"] = metadata
		results.append(report)
		await _cleanup_case()
		if report.get("status") != "PASS":
			break
	_restore_session()
	running = false
	if not _closing:
		_overlay.hide()
		_show_results()
	run_completed.emit(results)


func configure_run(players: int, quality: int, resolution: Vector2i) -> Error:
	if running or players not in [2, 4] or quality not in range(4) or resolution not in RESOLUTIONS:
		return ERR_INVALID_PARAMETER
	_players.select(0 if players == 2 else 1)
	_quality.select(quality)
	_resolution.select(RESOLUTIONS.find(resolution))
	return OK


func _accept_report(report: Dictionary) -> void:
	if not _closing:
		_case_finished.emit(report)


func cancel_run() -> void:
	if not running:
		return
	_cancelled = true
	if is_instance_valid(_sampler):
		_sampler.cancel()


func _cleanup_case() -> void:
	_stop_case()
	var until := Time.get_ticks_msec() + RSExit.DRAIN_MSEC
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame


func _stop_case() -> void:
	if is_instance_valid(_sampler):
		_sampler.queue_free()
		_sampler = null
	if is_instance_valid(_game):
		_game.process_mode = Node.PROCESS_MODE_DISABLED
		RSExit.silence(_game)
		_game.queue_free()
		_game = null


func _on_progress(stage: String, elapsed: float, duration: float, frame_ms: float) -> void:
	var stage_name := tr("预热") if stage == "warmup" else tr("采样") if stage == "sampling" else tr("等待比赛开始")
	_tint_chip(_stage, stage_name, RSUi.GOOD if stage == "sampling" else RSUi.HIGHLIGHT if stage == "warmup" else RSUi.TEXT_MUTED)
	_detail.text = tr("%.1f / %.1f 秒 · %.1f FPS") % [elapsed, duration, 1000.0 / frame_ms if frame_ms > 0 else 0.0]
	_progress.value = elapsed / duration * 100.0 if duration > 0 else 0.0
	if frame_ms > 0:
		_graph.sample(frame_ms)


func _show_config() -> void:
	_results.hide()
	_backdrop.show()
	_config.show()
	_start.grab_focus()


static func _target_fps(players: int) -> float:
	return 60.0 if players == 2 else 45.0


static func bound_estimate(stats: Dictionary) -> Dictionary:
	## Rough GPU-/CPU-bound hint from data the sampler already records: the sum of the per-viewport
	## GPU render means against the CPU process mean. Viewport timings are not a whole presented
	## frame and exclude driver/present waits, so the UI always labels this as an estimate.
	var gpu_ms := 0.0
	var readings := 0
	var averages: Dictionary = stats.get("gpu_viewports_ms_avg", {})
	var coverage: Dictionary = stats.get("gpu_viewports_coverage", {})
	var covered := true
	for name: String in averages:
		if averages[name] != null:
			gpu_ms += float(averages[name])
			readings += 1
			covered = covered and float(coverage.get(name, 0.0)) >= MIN_GPU_COVERAGE
	var cpu_ms := float(stats.get("cpu_process_ms_avg", 0.0))
	var avg_fps := float(stats.get("avg_fps", 0.0))
	var verdict := "unknown"
	if readings > 0 and covered and avg_fps > 0.0:
		verdict = "gpu" if gpu_ms >= cpu_ms else "cpu"
	return {"verdict": verdict, "gpu_ms": gpu_ms, "cpu_ms": cpu_ms, "frame_ms": 1000.0 / avg_fps if avg_fps > 0.0 else 0.0}


func _verdict_text(verdict: String) -> String:
	return {"gpu": tr("估计：GPU 受限"), "cpu": tr("估计：CPU 受限")}.get(verdict, tr("无法估计瓶颈"))


func _verdict_tint(verdict: String) -> Color:
	return {"gpu": RSUi.ACCENT, "cpu": RSUi.HIGHLIGHT}.get(verdict, RSUi.TEXT_MUTED)


func _show_results() -> void:
	_clear_results()
	var complete := results.size() == CASES.size() and results.all(func(report: Dictionary) -> bool: return report.get("status") == "PASS")
	if _cancelled:
		_tint_chip(_results_status, tr("测试已取消，结果不完整。"), RSUi.HIGHLIGHT)
	elif complete:
		_tint_chip(_results_status, tr("测试完成，设置已恢复。"), RSUi.GOOD)
	else:
		_tint_chip(_results_status, tr("测试未完成，设置已恢复。"), RSUi.BAD)
	var players: int = _run_config.get("players", 2)
	var resolution: Vector2i = _run_config.get("resolution", RESOLUTIONS[0])
	_results_subtitle.text = tr("%s · 画质 %s · %d × %d") % [tr("双人") if players == 2 else tr("四人"),
		tr(RSSettings.QUALITY_NAMES[_run_config.get("quality", 0)]), resolution.x, resolution.y]
	var cards := GridContainer.new()
	cards.columns = CASES.size()
	cards.add_theme_constant_override("h_separation", 14)
	_results_column.add_child(cards)
	for report: Dictionary in results:
		_scene_card(cards, report)
	var lower := HBoxContainer.new()
	lower.add_theme_constant_override("separation", 14)
	_results_column.add_child(lower)
	var graphs := _card(lower, 8)
	(graphs.get_parent() as Control).size_flags_stretch_ratio = 1.3
	graphs.add_child(_title(tr("帧时间曲线"), 22))
	var bounds := _card(lower, 8)
	bounds.add_child(_title(tr("瓶颈估计"), 22))
	bounds.add_child(RSUi.label(tr("估计方法：把各视口 GPU 渲染时间相加，与 CPU process 时间比较，较大的一方视为瓶颈。视口时间不是整帧 GPU 时间，也不含驱动与呈现等待，仅供参考。"), 15, RSUi.TEXT_MUTED, true))
	for report: Dictionary in results:
		var game_name := tr(RSCatalog.find_game(report["game"])["name"])
		var stats := RSBenchmark.statistics(report)
		if stats.is_empty():
			continue
		_add_result_graph(graphs, report, game_name)
		var estimate := bound_estimate(stats)
		bounds.add_child(RSUi.label("%s · %s" % [game_name, _verdict_text(estimate["verdict"])], 18, _verdict_tint(estimate["verdict"])))
		bounds.add_child(RSUi.label(tr("GPU 视口合计 %.2f ms · CPU process %.2f ms · 平均帧 %.2f ms") % [estimate["gpu_ms"], estimate["cpu_ms"], estimate["frame_ms"]], 15, RSUi.TEXT, true))
		bounds.add_child(RSUi.label(tr("GPU 各视口均值（毫秒，非整帧）：%s") % _viewport_list(stats.get("gpu_viewports_ms_avg", {}), "%.2f"), 14, RSUi.TEXT_MUTED, true))
		bounds.add_child(RSUi.label(tr("GPU 各视口有效覆盖率（0–1，有效读数占比）：%s") % _viewport_list(stats.get("gpu_viewports_coverage", {}), "%.2f"), 14, RSUi.TEXT_MUTED, true))
	if graphs.get_child_count() == 1:
		graphs.add_child(RSUi.label(tr("没有完整的采样数据。"), 16, RSUi.TEXT_MUTED, true))
	_system_card(_results_column)
	_results_scroll.scroll_vertical = 0
	_backdrop.show()
	_config.hide()
	_results.show()
	_export.disabled = results.is_empty()
	_again.grab_focus()


func _scene_card(parent: Control, report: Dictionary) -> void:
	var card := _card(parent, 8)
	var game_name := tr(RSCatalog.find_game(report["game"])["name"])
	card.add_child(_title(game_name, 26))
	if report.get("status") != "PASS":
		card.add_child(_chip(tr("测试未完成"), RSUi.BAD))
		var reason := tr("已取消") if report.get("status") == "CANCELLED" else _failure_message(report.get("errors", []))
		card.add_child(RSUi.label(reason, 17, RSUi.TEXT_MUTED, true))
		return
	var stats := RSBenchmark.statistics(report)
	var headline := HBoxContainer.new()
	headline.add_theme_constant_override("separation", 10)
	card.add_child(headline)
	var fps := _title("%.1f" % stats["avg_fps"], 56)
	headline.add_child(fps)
	var unit := RSUi.label(tr("平均 FPS"), 18, RSUi.TEXT_MUTED)
	unit.size_flags_vertical = Control.SIZE_SHRINK_END
	headline.add_child(unit)
	var target := _target_fps(int(report.get("players", 2)))
	var met := float(stats["avg_fps"]) >= target
	card.add_child(_chip(tr("参考目标 %.0f FPS：%s") % [target, tr("达标") if met else tr("未达标")], RSUi.GOOD if met else RSUi.BAD))
	var grid := _metric_grid(card)
	_metric(grid, "1% low", "%.1f FPS" % stats["one_percent_low_fps"])
	_metric(grid, tr("p95 / p99 帧时间"), "%.2f / %.2f ms" % [stats["frame_ms_p95"], stats["frame_ms_p99"]])
	_metric(grid, tr("最差帧"), "%.2f ms" % stats["frame_ms_worst"])
	_metric(grid, "CPU process", "%.2f ms" % stats["cpu_process_ms_avg"])
	var estimate := bound_estimate(stats)
	card.add_child(_chip(_verdict_text(estimate["verdict"]), _verdict_tint(estimate["verdict"])))


func _system_card(parent: Control) -> void:
	var card := _card(parent, 8)
	card.add_child(_title(tr("系统与设置"), 22))
	var metadata: Dictionary = {}
	for report: Dictionary in results:
		var candidate: Dictionary = report.get("metadata", {})
		if not str(candidate.get("gpu", "")).is_empty():
			metadata = candidate
			break
	var driver: Variant = metadata.get("driver")
	if driver == null:
		driver = " ".join(OS.get_video_adapter_driver_info())
	var memory := int(OS.get_memory_info().get("physical", -1))
	var resolution: Vector2i = _run_config.get("resolution", RESOLUTIONS[0])
	var grid := _metric_grid(card, 2)
	_metric(grid, "CPU", tr("%s · %d 线程") % [OS.get_processor_name(), OS.get_processor_count()], true)
	_metric(grid, "GPU", str(metadata.get("gpu", RenderingServer.get_video_adapter_name())), true)
	_metric(grid, tr("驱动"), str(driver) if not str(driver).is_empty() else tr("未知"), true)
	_metric(grid, tr("内存"), "%.1f GB" % (memory / 1073741824.0) if memory > 0 else tr("未知"))
	_metric(grid, tr("渲染"), "%s / %s" % [metadata.get("rendering_method", RenderingServer.get_current_rendering_method()), metadata.get("rendering_driver", RenderingServer.get_current_rendering_driver_name())], true)
	_metric(grid, tr("分辨率"), tr("%d × %d · 窗口") % [resolution.x, resolution.y])
	_metric(grid, tr("画质"), tr(RSSettings.QUALITY_NAMES[_run_config.get("quality", 0)]))
	_metric(grid, tr("超分"), tr("%s（测试期间关闭）") % tr(RSSettings.UPSCALE_NAMES[0]))
	_metric(grid, tr("垂直同步 / 帧率上限"), tr("关闭"))
	_metric(grid, tr("采样时长"), tr("预热 %s 秒 · 采样 %s 秒") % [str(_run_config.get("warmup_seconds", warmup_seconds)), str(_run_config.get("duration_seconds", duration_seconds))])
	_metric(grid, "Godot", str(metadata.get("godot_version", Engine.get_version_info()["string"])), true)


func _viewport_list(values: Dictionary, format: String) -> String:
	var parts := PackedStringArray()
	for name: String in values:
		parts.append("%s %s" % [name, "—" if values[name] == null else format % float(values[name])])
	return " · ".join(parts)


func _failure_message(errors: Array) -> String:
	for diagnostic: Variant in errors:
		var text := str(diagnostic)
		if text in [tr("场景加载失败。"), tr("测试场景配置失败。")]:
			return text
		if text.begins_with(tr("采样器启动失败（错误 %d）。").get_slice("%d", 0)):
			return text
		var detail := text.to_lower()
		if detail.contains("window"):
			return tr("窗口大小或模式发生变化，请保持测试窗口。")
		if detail.contains("timed out") or detail.contains("timeout"):
			return tr("测试启动或采样超时，请重试。")
		if detail.contains("play ended"):
			return tr("比赛提前结束，未完成所需采样。")
		if detail.contains("settings") or detail.contains("time scale") or detail.contains("fps cap") or detail.contains("vsync"):
			return tr("测试中的画面设置发生变化，请重试。")
		if detail.contains("scene") or detail.contains("viewport") or detail.contains("participants") or detail.contains("selected map"):
			return tr("测试场景已失效，请重新开始。")
		if detail.contains("paused"):
			return tr("测试被暂停，未完成采样。")
	return tr("采样失败，请查看导出的诊断信息。")


func _scroll_results(direction: int) -> void:
	_results_scroll.scroll_vertical += direction * maxi(1, floori(_results_scroll.size.y * 0.85))


func _clear_results() -> void:
	for child: Node in _results_column.get_children():
		_results_column.remove_child(child)
		child.queue_free()


func _add_result_graph(parent: Control, report: Dictionary, game_name: String) -> void:
	var samples: Array = report.get("samples", [])
	if samples.is_empty():
		return
	var bins := mini(FrameGraph.CAPACITY, samples.size())
	parent.add_child(RSUi.label(tr("%s · 全程帧时间：%d 个等帧数箱，每箱最大值（0–60 ms，超出截顶）") % [game_name, bins], 15, RSUi.TEXT_MUTED, true))
	var graph := FrameGraph.new()
	graph.stretch_history = true
	graph.custom_minimum_size.y = 110
	graph.target_ms = 1000.0 / _target_fps(int(report.get("players", 2)))
	parent.add_child(graph)
	for bin_index in bins:
		var first := floori(float(bin_index) * samples.size() / bins)
		var end := floori(float(bin_index + 1) * samples.size() / bins)
		var peak := 0.0
		for frame in range(first, end):
			peak = maxf(peak, float(samples[frame]["frame_ms"]))
		graph.sample(peak)


func export_results() -> void:
	if running or results.is_empty():
		return
	var directory := RSBenchmarkSession.export_directory()
	var error := _session.write_results(results, directory)
	_export_message.text = tr("已导出至：%s") % directory if error == OK else tr("导出失败（错误 %d）。") % error
	_export_message.add_theme_color_override("font_color", RSUi.TEXT_MUTED if error == OK else RSUi.BAD)


func _back() -> void:
	if running:
		cancel_run()
		return
	return_to_settings = true
	get_tree().change_scene_to_file("res://scenes/menu/main_menu.tscn")


func _window_closed() -> void:
	_closing = true
	cancel_run()
	_stop_case()
	_restore_session()


func _exit_tree() -> void:
	_closing = true
	if is_instance_valid(_sampler):
		_sampler.cancel()
	if is_instance_valid(_game):
		RSExit.silence(_game)
	_restore_session()


func _restore_session() -> void:
	var paused := get_tree().paused
	_session.restore(get_tree())
	if _closing:
		get_tree().paused = paused


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_back()
		get_viewport().set_input_as_handled()


func _on_button(_controller: RSController, button: int) -> void:
	if button == RSController.BTN_D:
		_back()
	elif running:
		if button == RSController.BTN_A:
			cancel_run()
	elif button == RSController.BTN_A:
		var focused := get_viewport().gui_get_focus_owner() as BaseButton
		if focused is OptionButton:
			var option := focused as OptionButton
			option.select((option.selected + 1) % option.item_count)
		elif focused != null:
			focused.pressed.emit()
	elif button == RSController.BTN_B or button == RSController.BTN_C:
		var index := _controls.find(get_viewport().gui_get_focus_owner())
		for step in range(1, _controls.size() + 1):
			var candidate := _controls[posmod(index + step * (1 if button == RSController.BTN_B else -1), _controls.size())]
			if candidate.is_visible_in_tree() and not candidate.disabled:
				candidate.grab_focus()
				break
