class_name RSBenchmarkMenu
extends Control
## Settings-only benchmark host. Real games are children; cleanup precedes settings restore.
## Wall-clock warmup/sample defaults stay 10/30 s; tests may inject shorter durations explicitly.

signal run_completed(reports: Array[Dictionary])
signal _case_finished(report: Dictionary)

const CASES := ["skate", "ski", "basketball"]
const RESOLUTIONS := [Vector2i(1600, 900), Vector2i(1920, 1080)]
const BENCH_SEED := 20261023
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
var _players: OptionButton
var _quality: OptionButton
var _resolution: OptionButton
var _config: PanelContainer
var _overlay: PanelContainer
var _status: Label
var _progress: ProgressBar
var _graph: FrameGraph
var _result_text: Label
var _results_scroll: ScrollContainer
var _results_column: VBoxContainer
var _result_navigation: HBoxContainer
var _export: Button
var _controls: Array[BaseButton] = []

class FrameGraph extends Control:
	const CAPACITY := 96
	var values := PackedFloat32Array()
	var count := 0
	var cursor := 0
	var stretch_history := false

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

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.05, 0.9))
		var width_steps := maxi(1, count - 1) if stretch_history else CAPACITY - 1
		for i in range(1, count):
			var previous := values[posmod(cursor - count + i - 1, CAPACITY)]
			var current := values[posmod(cursor - count + i, CAPACITY)]
			draw_line(Vector2((i - 1) * size.x / width_steps, size.y * (1.0 - minf(previous / 60.0, 1.0))),
				Vector2(i * size.x / width_steps, size.y * (1.0 - minf(current / 60.0, 1.0))), Color(0.3, 0.85, 1.0), 2.0)


func _ready() -> void:
	RSSettings.load_once()
	theme = RSUi.theme(20)
	get_tree().root.close_requested.connect(_window_closed)
	RSExit.install(get_tree())
	ControllerHub.button_pressed.connect(_on_button)
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	_config = PanelContainer.new()
	_config.theme = theme
	_config.custom_minimum_size = Vector2(1000, 0)
	_config.add_theme_stylebox_override("panel", RSUi.panel_style())
	center.add_child(_config)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	_config.add_child(column)
	column.add_child(RSUi.label(tr("性能测试"), 36))
	var device := "%s · %s / %s" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_current_rendering_method(), RenderingServer.get_current_rendering_driver_name()]
	column.add_child(_label(device))
	column.add_child(_label(tr("滑板 → 滑雪 → 篮球 · 地图 1 · 约 2–3 分钟（加载另计）")))
	column.add_child(_label(tr("临时关闭垂直同步与帧率上限，使用原生分辨率；完成或取消后恢复设置，不保存偏好。")))
	column.add_child(_label(tr("固定场景与起始种子；轨迹和粒子可能随帧率变化。曲线界面的开销计入测量。")))
	_players = _option(column, tr("人数"), [tr("双人"), tr("四人")], 0)
	var qualities: Array[String] = []
	for quality: String in RSSettings.QUALITY_NAMES:
		qualities.append(tr(quality))
	_quality = _option(column, tr("画质"), qualities, RSSettings.quality)
	_resolution = _option(column, tr("分辨率"), ["1600 × 900", "1920 × 1080"], 1 if get_tree().root.size == RESOLUTIONS[1] else 0)
	_button(column, tr("开始性能测试"), begin_run)
	_export = _button(column, tr("导出 JSON / CSV"), export_results)
	_export.disabled = true
	_button(column, tr("返回设置"), _back)
	_result_text = _label("")
	_result_text.add_theme_font_size_override("font_size", 16)
	_results_scroll = ScrollContainer.new()
	_results_scroll.custom_minimum_size.y = 200
	_results_column = VBoxContainer.new()
	_results_column.add_theme_constant_override("separation", 8)
	_results_scroll.add_child(_results_column)
	_results_column.add_child(_result_text)
	column.add_child(_results_scroll)
	_results_scroll.hide()
	_result_navigation = HBoxContainer.new()
	column.add_child(_result_navigation)
	_button(_result_navigation, tr("上一页结果"), _scroll_results.bind(-1)).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(_result_navigation, tr("下一页结果"), _scroll_results.bind(1)).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_result_navigation.hide()
	column.add_child(_label(tr("手柄：B / C 选择，A 确认，D 取消 / 返回；键盘：方向键、回车、Esc。")))
	_overlay = PanelContainer.new()
	_overlay.theme = theme
	_overlay.position = Vector2(18, 18)
	_overlay.custom_minimum_size = Vector2(520, 0)
	_overlay.add_theme_stylebox_override("panel", RSUi.panel_style())
	layer.add_child(_overlay)
	var progress_column := VBoxContainer.new()
	_overlay.add_child(progress_column)
	_status = _label("")
	_status.custom_minimum_size.x = 460
	progress_column.add_child(_status)
	_progress = ProgressBar.new()
	progress_column.add_child(_progress)
	progress_column.add_child(RSUi.label(tr("帧时间曲线 · 0–60 毫秒"), 14))
	_graph = FrameGraph.new()
	progress_column.add_child(_graph)
	_button(progress_column, tr("取消测试"), cancel_run)
	_overlay.hide()
	_controls[0].grab_focus()


func _label(text: String) -> Label:
	var label := RSUi.label(text, 18)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = 940
	return label


func _option(parent: Node, title: String, names: Array[String], selected: int) -> OptionButton:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := RSUi.label(title, 20)
	label.custom_minimum_size.x = 180
	row.add_child(label)
	var option := OptionButton.new()
	option.custom_minimum_size = Vector2(480, 36)
	for item_name: String in names:
		option.add_item(item_name)
	option.select(selected)
	row.add_child(option)
	_controls.append(option)
	return option


func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 38
	button.pressed.connect(action)
	parent.add_child(button)
	_controls.append(button)
	return button


func begin_run() -> void:
	if running or _closing:
		return
	results.clear()
	_clear_result_graphs()
	_result_text.text = ""
	_results_scroll.hide()
	_result_navigation.hide()
	_export.disabled = true
	_graph.clear()
	_cancelled = false
	var resolution: Vector2i = RESOLUTIONS[_resolution.selected]
	var quality := _quality.selected
	var players := 2 if _players.selected == 0 else 4
	var error := _session.begin(get_tree(), quality, resolution)
	if error != OK:
		_result_text.text = tr("无法开始性能测试（错误 %d）。") % error
		_results_scroll.show()
		return
	running = true
	_config.hide()
	_overlay.show()
	_controls[-1].grab_focus()
	for game_id: String in CASES:
		if _cancelled or _closing:
			break
		_case_name = tr(RSCatalog.find_game(game_id)["name"])
		_status.text = tr("%s · 加载中…") % _case_name
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
		_config.show()
		_show_results()
		_controls[3].grab_focus()
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
	_status.text = tr("%s · %s · %.1f / %.1f 秒 · %.1f FPS") % [_case_name, stage_name, elapsed, duration, 1000.0 / frame_ms if frame_ms > 0 else 0.0]
	_progress.value = elapsed / duration * 100.0 if duration > 0 else 0.0
	if frame_ms > 0:
		_graph.sample(frame_ms)


func _show_results() -> void:
	_clear_result_graphs()
	var lines: Array[String] = [tr("测试已取消，结果不完整。") if _cancelled else tr("测试完成，设置已恢复。")
		if results.size() == CASES.size() and results.all(func(report: Dictionary) -> bool: return report.get("status") == "PASS")
		else tr("测试未完成，设置已恢复。")]
	for report: Dictionary in results:
		var game_name := tr(RSCatalog.find_game(report["game"])["name"])
		if report.get("status") != "PASS":
			lines.append(tr("%s · 测试未完成：%s") % [game_name, tr("已取消") if report.get("status") == "CANCELLED" else _failure_message(report.get("errors", []))])
			continue
		var stats := RSBenchmark.statistics(report)
		lines.append(tr("%s · 平均 %.1f FPS · 1%% low %.1f · p95/p99 %.2f/%.2f ms · 最差 %.2f ms · CPU process %.2f ms") % [game_name,
			stats["avg_fps"], stats["one_percent_low_fps"], stats["frame_ms_p95"], stats["frame_ms_p99"], stats["frame_ms_worst"], stats["cpu_process_ms_avg"]])
		lines.append(tr("GPU 各视口均值（毫秒，非整帧）：%s") % str(stats.get("gpu_viewports_ms_avg", {})))
		lines.append(tr("GPU 各视口有效覆盖率（0–1，有效读数占比）：%s") % str(stats.get("gpu_viewports_coverage", {})))
		var target := 60.0 if int(report.get("players", 2)) == 2 else 45.0
		lines.append(tr("参考目标 %.0f FPS：%s") % [target, tr("达标") if float(stats["avg_fps"]) >= target else tr("未达标")])
		_add_result_graph(report, game_name)
	_result_text.text = "\n".join(lines)
	_results_scroll.show()
	_result_navigation.show()
	_export.disabled = results.is_empty()


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


func _clear_result_graphs() -> void:
	for child: Node in _results_column.get_children():
		if child != _result_text:
			_results_column.remove_child(child)
			child.queue_free()


func _add_result_graph(report: Dictionary, game_name: String) -> void:
	var samples: Array = report.get("samples", [])
	if samples.is_empty():
		return
	var bins := mini(FrameGraph.CAPACITY, samples.size())
	var title := _label(tr("%s · 全程帧时间：%d 个等帧数箱，每箱最大值（0–60 ms，超出截顶）") % [game_name, bins])
	title.add_theme_font_size_override("font_size", 15)
	_results_column.add_child(title)
	var graph := FrameGraph.new()
	graph.stretch_history = true
	_results_column.add_child(graph)
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
	_result_text.text += "\n" + (tr("已导出至：%s") % directory if error == OK else tr("导出失败（错误 %d）。") % error)


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
