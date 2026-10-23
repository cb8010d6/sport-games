extends Node
## Isolated benchmark contract tests. Real-render cases use short windows, not FPS baselines.
## The Python runner owns disposable user data, sentinels and strict process diagnostics.

const TIMEOUT_MSEC := 90000
var _checks := 0
var _failures := 0
var _mode := "unit"
var _players := 2
var _language := 0
var _output := ""
var _user := ""
var _sentinels: Dictionary = {}
var _scene: Node
var _sampler: RSBenchmark
var _reports: Array[Dictionary] = []
var _progress_stage := ""
var _case_reports: Array[Dictionary] = []
var _full_duration := false


func _ready() -> void:
	_mode = OS.get_environment("RS_BENCH_TEST_MODE")
	_players = int(OS.get_environment("RS_BENCH_TEST_PLAYERS"))
	_language = int(OS.get_environment("RS_BENCH_TEST_LANGUAGE"))
	_full_duration = OS.get_environment("RS_BENCH_TEST_FULL_DURATION") == "1"
	_output = OS.get_environment("RS_BENCH_TEST_OUTPUT")
	_user = OS.get_environment("RS_BENCH_TEST_USER")
	if OS.get_environment("RS_TEST_MODE") != "1" or _output.is_empty() or _user.is_empty():
		push_error("Run tools/test_benchmark.py with isolated user data")
		RSExit.quit(get_tree(), 1)
		return
	var actual := OS.get_user_data_dir().replace("\\", "/").simplify_path().trim_suffix("/")
	var expected := _user.replace("\\", "/").simplify_path().trim_suffix("/")
	if (actual.to_lower() if OS.get_name() == "Windows" else actual) != (expected.to_lower() if OS.get_name() == "Windows" else expected):
		push_error("Benchmark test user directory does not match isolated runner data")
		RSExit.quit(get_tree(), 1)
		return
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("Benchmark test failed: " + message)


func _files(directory: String, prefix: String = "") -> Dictionary:
	var found: Dictionary = {}
	var access := DirAccess.open(directory)
	if access == null:
		return found
	for name: String in access.get_files():
		if prefix == "vulkan/" and name.begins_with("pipelines.") and name.ends_with(".cache"):
			continue
		if prefix.begins_with("benchmarks/") and name in ["results.json", "samples.csv"]:
			continue
		found[prefix + name] = FileAccess.get_sha256(directory.path_join(name))
	for name: String in access.get_directories():
		if prefix.is_empty() and name in ["logs", "shader_cache"]:
			continue
		found.merge(_files(directory.path_join(name), prefix + name + "/"))
	return found


func _unchanged(label: String) -> void:
	_check(_files(_user) == _sentinels, label + ": protected files and directory inventory unchanged")


func _state() -> Dictionary:
	return {"fps": RSSettings.fps, "quality": RSSettings.quality, "window": RSSettings.window,
		"upscale": RSSettings.upscale, "hdr": RSSettings.hdr, "language": RSSettings.language,
		"color_safe": RSSettings.color_safe, "camera_shake": RSSettings.camera_shake,
		"volumes": RSSettings.volumes.duplicate(), "size": get_tree().root.size,
		"position": DisplayServer.window_get_position(), "mode": DisplayServer.window_get_mode(),
		"vsync": DisplayServer.window_get_vsync_mode(), "max_fps": Engine.max_fps,
		"paused": get_tree().paused}


func _fixture() -> Dictionary:
	var samples: Array[Dictionary] = []
	for frame_ms: float in [1.0, 2.0, 3.0, 94.0]:
		samples.append({"frame_ms": frame_ms, "cpu_process_ms": 2.0, "gpu_ms": null,
			"gpu_viewports_ms": {"root": null, "player_1": 1.2},
			"cpu_render_viewports_ms": {"root": 0.0, "player_1": 0.2},
			"draw_calls": 20, "video_memory_bytes": 1024, "nodes": 42})
	return {"schema_version": 1, "status": "PASS", "errors": [], "game": "plane", "map": 0,
		"players": 2, "quality": 1, "warmup_seconds": 0.0, "duration_seconds": 0.1,
		"elapsed_seconds": 0.1, "frames": 4, "samples": samples, "metadata": {}}


func _statistics_tests() -> void:
	var fixture := _fixture()
	var stats := RSBenchmark.statistics(fixture)
	_check(is_equal_approx(float(stats.get("avg_fps", -1)), 40.0), "FPS uses summed frame intervals")
	_check(is_equal_approx(float(stats.get("frame_ms_p50", -1)), 2.5), "R7 p50")
	_check(is_equal_approx(float(stats.get("frame_ms_p95", -1)), 80.35), "R7 p95")
	_check(is_equal_approx(float(stats.get("frame_ms_p99", -1)), 91.27), "R7 p99")
	_check(is_equal_approx(float(stats.get("frame_ms_worst", -1)), 94.0), "worst interval")
	_check(is_equal_approx(float(stats.get("one_percent_low_fps", -1)), 1000.0 / 94.0), "1 percent low is slow-tail mean reciprocal")
	_check(stats.get("gpu_ms_avg") == null and stats.get("gpu_samples", -1) == 0, "whole-frame GPU stays unavailable")
	var averages: Dictionary = stats.get("gpu_viewports_ms_avg", {})
	var coverage: Dictionary = stats.get("gpu_viewports_coverage", {})
	_check(averages.get("root") == null and is_equal_approx(float(averages.get("player_1", -1)), 1.2), "viewport null is not zero")
	_check(is_zero_approx(float(coverage.get("root", -1))) and is_equal_approx(float(coverage.get("player_1", -1)), 1.0), "GPU coverage has an explicit denominator")
	var partial := _fixture()
	partial["samples"][2]["gpu_viewports_ms"]["player_1"] = 0.0
	partial["samples"][3]["gpu_viewports_ms"]["player_1"] = null
	var partial_stats := RSBenchmark.statistics(partial)
	_check(is_equal_approx(float(partial_stats["gpu_viewports_coverage"]["player_1"]), 0.5), "zero/null GPU samples reduce coverage")
	_check(is_equal_approx(float(partial_stats["gpu_viewports_ms_avg"]["player_1"]), 1.2), "missing GPU samples do not bias average toward zero")
	var estimate := RSBenchmarkMenu.bound_estimate(stats)
	_check(estimate["verdict"] == "cpu" and is_equal_approx(float(estimate["gpu_ms"]), 1.2) and is_equal_approx(float(estimate["cpu_ms"]), 2.0), "null viewport is skipped; CPU process above GPU viewport sum estimates CPU-bound")
	_check(is_equal_approx(float(estimate["frame_ms"]), 25.0), "estimate frame time is the reciprocal of average FPS")
	var gpu_heavy := _fixture()
	for sample: Dictionary in gpu_heavy["samples"]:
		sample["gpu_viewports_ms"]["player_1"] = 3.0
	_check(RSBenchmarkMenu.bound_estimate(RSBenchmark.statistics(gpu_heavy))["verdict"] == "gpu", "GPU viewport sum above CPU process estimates GPU-bound")
	var sparse := _fixture()
	for i in 3:
		sparse["samples"][i]["gpu_viewports_ms"]["player_1"] = null
	_check(RSBenchmarkMenu.bound_estimate(RSBenchmark.statistics(sparse))["verdict"] == "unknown", "low GPU coverage withholds the estimate")
	_check(RSBenchmark.statistics({"samples": []}).is_empty(), "empty samples do not produce statistics")
	for status: String in ["FAIL", "CANCELLED"]:
		var failed := _fixture()
		failed["status"] = status
		_check(RSBenchmark.statistics(failed).is_empty(), "non-PASS does not produce valid statistics: " + status)
	for value: float in [0.0, -1.0, NAN, INF]:
		var invalid := _fixture()
		invalid["samples"][0]["frame_ms"] = value
		_check(RSBenchmark.statistics(invalid).is_empty(), "invalid frame time rejected")
	for change: Dictionary in [{"cpu_process_ms": NAN}, {"draw_calls": -1}, {"nodes": INF}]:
		var invalid := _fixture()
		invalid["samples"][0].merge(change, true)
		_check(RSBenchmark.statistics(invalid).is_empty(), "invalid CPU or count cannot produce statistics")
	var tail := _fixture()
	tail["samples"].clear()
	for i in 101:
		var sample: Dictionary = fixture["samples"][0].duplicate(true)
		sample["frame_ms"] = 40.0 if i == 0 else (20.0 if i == 1 else 10.0)
		tail["samples"].append(sample)
	tail["frames"] = 101
	tail["elapsed_seconds"] = 1.05
	tail["duration_seconds"] = 1.05
	_check(is_equal_approx(float(RSBenchmark.statistics(tail).get("one_percent_low_fps", -1)), 1000.0 / 30.0), "ceil selects two slowest frames from 101")


func _session_tests() -> void:
	var session := RSBenchmarkSession.new()
	var original_hdr := RSSettings.hdr
	if DisplayServer.get_name() != "headless":
		RSSettings.hdr = true
	var before := _state()
	session.restore(get_tree())
	session.restore(get_tree())
	_check(_state() == before, "inactive restore is idempotent")
	_check(session.begin(get_tree(), -1, Vector2i(1600, 900)) == ERR_INVALID_PARAMETER, "invalid quality rejected")
	_check(session.begin(get_tree(), 1, Vector2i(640, 480)) == ERR_INVALID_PARAMETER, "invalid resolution rejected")
	get_tree().paused = true
	_check(session.begin(get_tree(), 1, Vector2i(1600, 900)) == ERR_INVALID_PARAMETER, "paused tree rejected")
	get_tree().paused = false
	if DisplayServer.get_name() == "headless":
		_check(session.begin(get_tree(), 1, Vector2i(1600, 900)) == ERR_UNAVAILABLE, "headless cannot begin rendered session")
	else:
		_check(session.begin(get_tree(), 0, Vector2i(1920, 1080)) == OK, "real session begins")
		_check(RSSettings.quality == 0 and RSSettings.upscale == 0 and Engine.max_fps == 0, "temporary benchmark settings applied")
		_check(RSSettings.hdr == before["hdr"], "session preserves HDR without driver restart or override write")
		_check(get_tree().root.size == Vector2i(1920, 1080), "temporary output resolution applied")
		_check(session.begin(get_tree(), 1, Vector2i(1600, 900)) == ERR_INVALID_PARAMETER, "active session cannot be overwritten")
		var active_results: Array[Dictionary] = [_fixture()]
		_check(session.write_results(active_results, _output.path_join("active-export")) == ERR_INVALID_PARAMETER, "active export rejected")
		session.restore(get_tree())
		await _frames()
		_check(_state() == before, "all memory and actual window settings restored")
		session.restore(get_tree())
		_check(_state() == before, "second restore remains a no-op")
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
		await _frames()
		var maximized := _state()
		_check(session.begin(get_tree(), 0, Vector2i(1600, 900)) == OK, "maximized session begins")
		await _frames()
		_check(DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED and get_tree().root.size == Vector2i(1600, 900), "maximized start applies requested client resolution")
		session.restore(get_tree())
		await _frames()
		_check(DisplayServer.window_get_mode() == maximized["mode"], "maximized mode restored")
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		get_tree().root.size = before["size"]
		DisplayServer.window_set_position(before["position"])
		DisplayServer.window_set_mode(before["mode"])
		await _frames()
	RSSettings.hdr = original_hdr
	var empty: Array[Dictionary] = []
	_check(session.write_results(empty, _output.path_join("empty-export")) == ERR_INVALID_PARAMETER, "empty export rejected")
	var results: Array[Dictionary] = [_fixture()]
	var blocked := _output.path_join("export-target-is-a-file")
	var blocker := FileAccess.open(blocked, FileAccess.WRITE)
	_check(blocker != null, "export failure fixture is writable")
	if blocker != null:
		blocker.store_string("preserve existing file")
		blocker.close()
		var restored := _state()
		_check(session.write_results(results, blocked) != OK, "export to an existing regular file returns an explicit error")
		_check(FileAccess.get_file_as_string(blocked) == "preserve existing file", "failed export does not overwrite the obstacle")
		session.restore(get_tree())
		_check(_state() == restored, "export failure leaves restored settings and window unchanged")
	var directory := _output.path_join("fixture-export")
	_check(session.write_results(results, directory) == OK, "fixture export succeeds")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("results.json")))
	_check(parsed is Dictionary and parsed.get("schema_version") == 1 and parsed.get("runs", []).size() == 1, "exported JSON schema and run count")
	if parsed is Dictionary and not parsed.get("runs", []).is_empty():
		# JSON numbers deserialize as floats and arrays lose their GDScript element type.
		var expected_samples: Variant = JSON.parse_string(JSON.stringify(_fixture()["samples"]))
		_check(parsed["runs"][0]["samples"] == expected_samples, "export preserves raw samples and nulls")
		_check(is_equal_approx(float(parsed["runs"][0]["statistics"]["avg_fps"]), 40.0), "export retains shared statistics")
	_check(FileAccess.file_exists(directory.path_join("samples.csv")), "CSV exported with JSON")
	_unchanged("session tests")
	var game := RSPartyGame.new()
	_check(game.configure_benchmark(0, 0) == ERR_INVALID_PARAMETER, "empty benchmark party rejected")
	_check(game.configure_benchmark(2, -1) == ERR_INVALID_PARAMETER, "negative map rejected")
	_check(game.configure_benchmark(2, 0) == OK and game.benchmark_mode, "headless configuration fixture needs no world or rendering")
	_check(game.benchmark_viewports().is_empty(), "detached game has no measured viewports")
	var sampler := RSBenchmark.new()
	_check(sampler.begin(game, {}) == ERR_INVALID_PARAMETER, "detached sampler cannot begin")
	sampler.free()
	game.free()


func _frames(count: int = 3) -> void:
	for _i in count:
		await get_tree().process_frame


func _run() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_sentinels = _files(_user)
	_check(_sentinels.size() == 12, "all player main/backup/temporary sentinels installed")
	RSSettings.load_once()
	RSLang.apply(_language)
	_statistics_tests()
	await _session_tests()
	if _mode == "core":
		await _core_tests()
	elif _mode == "ui":
		await _ui_tests()
	else:
		_check(_mode == "unit", "known test mode")
	_unchanged("suite completion")
	var file := FileAccess.open(_output.path_join("test-report.json"), FileAccess.WRITE)
	_check(file != null, "test report writable")
	var report := {"mode": _mode, "players": _players, "language": _language,
		"checks": _checks, "failures": _failures, "baseline": false, "core_reports": _case_reports}
	if file != null:
		file.store_string(JSON.stringify(report))
		file.close()
	print("RS_BENCHMARK_TEST: %s players=%d language=%d checks=%d failures=%d" % [_mode, _players, _language, _checks, _failures])
	RSExit.quit(get_tree(), 1 if _failures else 0)
	return


func _core_tests() -> void:
	var maps_before: Dictionary = RSPartyGame._last_map.duplicate(true)
	var hub_before: Dictionary = ControllerHub.controllers.duplicate()
	var controller := RSController.new()
	controller.id = 7
	controller.player = 1
	controller.kind = "phone"
	controller.connected = true
	controller.info = {"profile_name": "SHOULD_NOT_SAVE"}
	ControllerHub.controllers[7] = controller
	for action: String in ["success", "cancel_warmup", "cancel_sampling", "early_end"]:
		seed(20261023)
		var session := RSBenchmarkSession.new()
		var before := _state()
		_check(session.begin(get_tree(), 0, Vector2i(1600, 900)) == OK, action + ": session begins")
		var game := (load("res://scenes/plane/plane_game.tscn") as PackedScene).instantiate() as RSPartyGame
		_check(game.configure_benchmark(3, 0) == ERR_INVALID_PARAMETER, "unsupported player count rejected before entry")
		_check(game.configure_benchmark(_players, 1) == ERR_INVALID_PARAMETER, "unsupported map rejected before entry")
		_check(game.configure_benchmark(_players, 0) == OK, action + ": configuration before tree entry")
		_scene = game
		add_child(game)
		_check(game.configure_benchmark(1, 0) == ERR_ALREADY_IN_USE, "configuration after tree entry rejected")
		_check(game.demo == _players and game.benchmark_mode and game.players.size() == _players, "requested pure demo participants")
		for player: RSPartyGame.Player in game.ordered():
			_check(player.fake and player.c.kind == "replay" and not game.can_record(player), "demo cannot write personal records")
		game._sync_players()
		game._on_button(controller, RSController.BTN_C, true)
		game.open_pause()
		_check(game.players.size() == _players and not game.ui.pause.is_open(), "physical controller cannot join, navigate or pause")
		var views := game.benchmark_viewports()
		_check(views.size() == _players + 1 and views[0] == get_tree().root, "root plus all split viewports collected")
		var rids: Array[RID] = []
		for viewport: Viewport in views:
			_check(viewport.get_viewport_rid() not in rids, "viewport RID is unique")
			rids.append(viewport.get_viewport_rid())
		_sampler = RSBenchmark.new()
		add_child(_sampler)
		_reports.clear()
		_progress_stage = ""
		_sampler.completed.connect(func(report: Dictionary) -> void: _reports.append(report))
		_sampler.progress_changed.connect(func(stage: String, _elapsed: float, _duration: float, _ms: float) -> void: _progress_stage = stage)
		var request := {"game": "plane", "map": 0, "players": _players, "quality": 0,
			"warmup_seconds": 10.0 if action == "cancel_warmup" else 0.1,
			"duration_seconds": 0.3 if action == "success" else 30.0,
			"seed": 20261023, "resolution": Vector2i(1600, 900)}
		var invalid := request.duplicate(true)
		invalid["players"] = 3
		_check(_sampler.begin(game, invalid) == ERR_INVALID_PARAMETER and _reports.is_empty(), "invalid request does not start or emit completed")
		_check(_sampler.begin(game, request) == OK, action + ": real sampler begins")
		if action != "success":
			var target := "warmup" if action == "cancel_warmup" else "sampling"
			await _wait_stage(target)
			if action == "early_end":
				game.finish_round()
			else:
				_sampler.cancel()
		await _wait_reports()
		if not _reports.is_empty():
			var report := _reports[0]
			_case_reports.append({"action": action, "report": report})
			if action == "success":
				_check(report.get("status") == "PASS", "real rendered short window succeeds")
				_validate_actual(report)
			elif action == "early_end":
				_check(report.get("status") == "FAIL" and str(report.get("errors", [])).contains("PLAY ended"), "early result phase fails with an explicit cause")
			else:
				_check(report.get("status") == "CANCELLED" and report.get("errors", ["missing"]).is_empty(), "cancel is distinct from PASS and FAIL")
				_check(RSBenchmark.statistics(report).is_empty(), "partial cancelled samples cannot become valid statistics")
		_sampler.cancel()
		await _frames()
		_check(_reports.size() == 1, "completed emitted exactly once, including repeated cancel")
		_sampler.queue_free()
		_sampler = null
		await _release_scene()
		session.restore(get_tree())
		await _frames()
		_check(_state() == before, action + ": preferences and window restored")
		_check(_sampler_count() == 0 and get_tree().root.find_children("*", "SubViewport", true, false).is_empty(), "round leaves no sampler or split viewports")
		_unchanged(action)
	ControllerHub.controllers = hub_before
	_check(RSPartyGame._last_map == maps_before, "benchmark never changes ordinary map memory")


func _ui_tests() -> void:
	var before := _state()
	var menu := (load("res://scenes/menu/benchmark_menu.tscn") as PackedScene).instantiate() as RSBenchmarkMenu
	_scene = menu
	get_tree().root.add_child(menu)
	get_tree().current_scene = menu
	await _frames()
	_check(menu.configure_run(_players, 2 if _full_duration else 0, Vector2i(1600, 900)) == OK, "public UI configuration")
	_check(menu.warmup_seconds == 10.0 and menu.duration_seconds == 30.0, "shipping UI keeps full measurement defaults")
	if not _full_duration:
		menu.warmup_seconds = 0.1
		menu.duration_seconds = 0.3
	await _screenshot("options.png")
	var completion := {"count": 0}
	menu.run_completed.connect(func(_results: Array[Dictionary]) -> void: completion["count"] += 1)
	menu.begin_run()
	_check(menu.running, "public UI start creates a running session")
	_check(menu.configure_run(_players, 1, Vector2i(1600, 900)) != OK, "running UI rejects reconfiguration")
	var finished: bool = await _wait_ui(menu)
	if not finished:
		await _release_scene()
		return
	_check(completion["count"] == 1 and menu.results.size() == 3, "real three-scene sequence completes exactly once")
	var ids: Array[String] = []
	for report: Dictionary in menu.results:
		ids.append(str(report.get("game", "")))
		_check(report.get("status") == "PASS", "actual UI case completed successfully")
		_validate_actual(report)
	_check(ids == ["skate", "ski", "basketball"], "actual fixed scene order")
	_check(_state() == before, "successful UI sequence restores preferences and actual window")
	await _screenshot("results.png")
	var scroll := menu.get("_results_scroll") as ScrollContainer
	_check(scroll.scroll_vertical == 0, "results initially show the first page")
	var next_page: Button
	for control: BaseButton in menu.get("_controls"):
		var button := control as Button
		if button != null and button.text == RSLang.t("下一页结果"):
			next_page = button
	_check(next_page != null, "next result page has a controller-focusable button")
	for _i in 8:
		if next_page != null:
			next_page.grab_focus()
			menu.call("_on_button", null, RSController.BTN_A)
		await _frames()
	_check(scroll.scroll_vertical > 0, "result navigation reaches the lower frame graphs")
	var scrollbar := scroll.get_v_scroll_bar()
	_check(is_equal_approx(float(scroll.scroll_vertical), scrollbar.max_value - scrollbar.page), "result navigation reaches the last page without overshooting")
	await _screenshot("results-end.png")
	var exports_before := DirAccess.get_directories_at(_user.path_join("benchmarks")) if DirAccess.dir_exists_absolute(_user.path_join("benchmarks")) else PackedStringArray()
	menu.export_results()
	var exports_after := DirAccess.get_directories_at(_user.path_join("benchmarks"))
	var new_exports: Array[String] = []
	for name: String in exports_after:
		if name not in exports_before:
			new_exports.append(name)
	_check(new_exports.size() == 1, "UI explicit export creates one result directory")
	if new_exports.size() == 1:
		var directory := _user.path_join("benchmarks").path_join(new_exports[0])
		var decoded: Variant = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("results.json")))
		_check(decoded is Dictionary and decoded.get("runs", []).size() == 3, "actual UI export contains all three measured runs")
		if decoded is Dictionary:
			var exported_runs: Array = decoded.get("runs", [])
			for i in mini(exported_runs.size(), menu.results.size()):
				var expected_statistics: Variant = JSON.parse_string(JSON.stringify(RSBenchmark.statistics(menu.results[i])))
				_check(exported_runs[i]["statistics"] == expected_statistics, "exported statistics retain FPS, percentiles, tail and unavailable GPU coverage")
		_check(FileAccess.file_exists(directory.path_join("samples.csv")), "actual UI CSV exists")
		_check(DirAccess.copy_absolute(directory.path_join("results.json"), _output.path_join("ui-results.json")) == OK, "actual UI JSON evidence retained outside disposable data")
		_check(DirAccess.copy_absolute(directory.path_join("samples.csv"), _output.path_join("ui-samples.csv")) == OK, "actual UI CSV evidence retained outside disposable data")
	_unchanged("actual successful UI and explicit export")
	for iteration in 2:
		menu.warmup_seconds = 10.0
		menu.duration_seconds = 30.0
		menu.begin_run()
		menu.cancel_run()
		finished = await _wait_ui(menu)
		if not finished:
			await _release_scene()
			return
		_check(completion["count"] == iteration + 2, "restart/cancel completes once")
		_check(menu.results.size() == 1 and menu.results[0].get("status") == "CANCELLED", "UI cancellation never displays a successful full run")
		_check(_state() == before, "cancelled UI sequence restores original state")
		_check(_sampler_count() == 0 and menu.find_children("*", "SubViewport", true, false).is_empty(), "consecutive UI runs clean all samplers and viewports")
		_unchanged("UI cancel iteration")
	menu.call("_back")
	var until := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < until:
		var current := get_tree().current_scene
		if current != null and current.get_script().resource_path == "res://scenes/menu/main_menu.gd":
			break
		await get_tree().process_frame
	await _frames()
	_scene = get_tree().current_scene
	_check(_scene != null and _scene.get_script().resource_path == "res://scenes/menu/main_menu.gd", "return to main menu completes")
	if _scene != null and _scene.get("_settings") is RSPauseMenu:
		var settings: RSPauseMenu = _scene.get("_settings")
		_check(settings.is_open(), "return reopens the settings page")
		_check(settings._items()[settings._index] == "benchmark", "settings focus returns to performance entry")
		settings.close()
	else:
		_check(false, "main menu exposes its real settings page")
	await _release_scene()


func _validate_actual(report: Dictionary) -> void:
	var samples: Array = report.get("samples", [])
	_check(samples.size() >= 2 and report.get("frames", -1) == samples.size(), "actual report contains its declared frame samples")
	var elapsed := 0.0
	for sample: Dictionary in samples:
		elapsed += float(sample["frame_ms"]) / 1000.0
		_check(float(sample["frame_ms"]) > 0.0 and sample.get("gpu_ms") == null, "real frame interval and unavailable whole-frame GPU")
	_check(is_equal_approx(elapsed, float(report.get("elapsed_seconds", -1))), "sample intervals sum to elapsed time")
	_check(elapsed >= float(report.get("duration_seconds", INF)), "actual duration is sufficient")
	_check(report.get("players", -1) == _players, "actual report matches requested split count")
	var metadata: Dictionary = report.get("metadata", {})
	_check(metadata.get("resolution") == [1600, 900] and not str(metadata.get("gpu", "")).is_empty(), "actual display and GPU metadata")
	_check(not RSBenchmark.statistics(report).is_empty(), "real samples produce shared statistics")


func _wait_stage(stage: String) -> void:
	var until := Time.get_ticks_msec() + TIMEOUT_MSEC
	while Time.get_ticks_msec() < until and _progress_stage != stage and _reports.is_empty():
		await get_tree().process_frame
	_check(_progress_stage == stage, "real sampler reaches " + stage)


func _wait_reports() -> void:
	var until := Time.get_ticks_msec() + TIMEOUT_MSEC
	while Time.get_ticks_msec() < until and _reports.is_empty():
		await get_tree().process_frame
	_check(not _reports.is_empty(), "sampler completion is bounded")


func _wait_ui(menu: RSBenchmarkMenu) -> bool:
	var budget := RSBenchmarkMenu.CASES.size() * (RSBenchmark.START_TIMEOUT + menu.warmup_seconds + menu.duration_seconds + 10.0)
	var until := Time.get_ticks_msec() + int(budget * 1000.0)
	while Time.get_ticks_msec() < until and is_instance_valid(menu) and menu.running:
		await get_tree().process_frame
	var finished := is_instance_valid(menu) and not menu.running
	_check(finished, "UI completion/cleanup is bounded")
	if not finished and is_instance_valid(menu):
		menu.cancel_run()
	return finished


func _sampler_count() -> int:
	var count := 0
	for node: Node in get_tree().root.find_children("*", "", true, false):
		if node is RSBenchmark:
			count += 1
	return count


func _release_scene() -> void:
	if is_instance_valid(_scene):
		RSExit.silence(_scene)
		if get_tree().current_scene == _scene:
			get_tree().current_scene = null
		_scene.queue_free()
	_scene = null
	var until := Time.get_ticks_msec() + RSExit.DRAIN_MSEC
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame


func _screenshot(name: String) -> void:
	if OS.get_environment("RS_BENCH_TEST_SCREENSHOTS") != "1":
		return
	await _frames()
	await RenderingServer.frame_post_draw
	for node: Node in _scene.find_children("*", "BaseButton", true, false):
		var control := node as Control
		if control.is_visible_in_tree():
			_check(Rect2(Vector2.ZERO, Vector2(1600, 900)).encloses(control.get_global_rect()), "UI action stays inside the actual output")
	_check(get_viewport().get_texture().get_image().save_png(_output.path_join(name)) == OK, "real UI screenshot saved")
