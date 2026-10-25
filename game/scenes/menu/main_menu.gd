extends Control
## Start screen: pick a game. Mouse, keyboard (arrows + Enter) or any controller
## (B = next, C = previous, A = open). Esc in a game comes back here. The last entry switches
## the language (中文 / English) and rebuilds the screen.
## Layout: the numbered sport list and a grid of modes on the left, the selected sport's
## picture full screen behind them with its title plate bottom right, button prompts along the
## bottom. Non-sport entries show the live backdrop instead: two bot riders skate the seaside
## street from the skate game, filmed by a camera that cuts between chase and tracking shots.

const MODES := [   ## the entries after the sports from RSCatalog
	{"name": "单人挑战", "oled": "SOLO", "scene": "", "page": "solo", "desc": "选择电脑难度，挑战三个分数目标，收集每个项目的星星。"},
	{"name": "派对大赛", "oled": "PARTY", "scene": "", "page": "party", "desc": "选择 3–6 个项目，连续比赛并累计名次积分。"},
	{"name": "玩家 / 手柄", "oled": "PLAYERS", "scene": "", "page": "players", "desc": "编辑玩家档案，扫码连接手机，分配手柄编号、查看电量与校准。"},
	{"name": "本地排行榜", "oled": "RECORDS", "scene": "", "page": "records", "desc": "查看每个项目、每张地图的个人最佳成绩。"},
	{"name": "设置", "oled": "SETTINGS", "scene": "", "page": "settings", "desc": "调整画面、声音、语言和色弱友好配色。"},
	{"name": "致谢与素材", "oled": "CREDITS", "scene": "", "page": "credits", "desc": "游戏引擎、角色、场景素材及许可说明。"},
	{"name": "手柄调试", "oled": "DEBUG", "scene": "res://scenes/debug/controller_debug.tscn",
		"desc": "查看姿态、按键、挥动检测和屏幕预览；分配玩家编号、归零、校准。"},
	{"name": "语言 Language：%s", "oled": "LANGUAGE", "scene": "",
		"desc": "按 A 切换界面语言：中文 / English"},
]
const SHOT_TIME := 7.0           ## seconds per camera shot in the backdrop

var entries: Array = RSCatalog.games() + MODES   ## the menu sports, then MODES
var _sports := RSCatalog.games().size()          ## how many of entries are sports

var _buttons: Array[Button] = []
var _row_labels: Array = []      ## per button: its labels, recoloured when it is selected
var _desc: Label
var _status: Label
var _index := 0
var _pages: RSMenuPages
var _settings: RSPauseMenu
var _menu_grid: VBoxContainer    ## both lists, inside the scroll container
var _preview: RSGamePreview
var _info: VBoxContainer         ## title plate, bottom right
var _info_title: Label
var _info_tag: Label
var _stats: HBoxContainer
var _best: Label
var _backdrop: SubViewport

var _course: RSSkateCourse
var _cam: Camera3D
var _riders: Array[RSSkater] = []
var _bots: Array[RSSkateBot] = []
var _shot := 0
var _shot_t := 0.0
var _cam_pos := Vector3.ZERO
var _cam_look := Vector3.ZERO
var _side := 1.0


func _ready() -> void:
	RSExit.install(get_tree())
	var cli_game: String = entries[0].get("id", "")
	var cli_launch := false
	for a: String in OS.get_cmdline_user_args():
		if a == "--demo" or a.begins_with("--demo="):
			cli_launch = true
		elif a.begins_with("--game="):
			cli_game = a.trim_prefix("--game=")
			cli_launch = true
		elif a.begins_with("--dump-catalog="):
			# Tools read the discovered manifests (also from an exported build) and quit.
			var error := RSCatalog.write_dump(a.trim_prefix("--dump-catalog="))
			if error != OK:
				push_error("Cannot write the catalog dump: %s" % error_string(error))
			else:
				print("RS_CATALOG_DONE: %d" % RSCatalog.modules(true).size())
			set_process(false)
			RSExit.quit(get_tree(), 0 if error == OK else 1)
			return
	if cli_launch:
		# Hidden (ready = false) modules are reachable here so unfinished games can be tested.
		var game := RSCatalog.find_game(cli_game, true)
		if not game.is_empty():
			print("CLI game: %s" % cli_game)
			get_tree().change_scene_to_file.call_deferred(game["scene"])
			return
		push_error("Unknown --game id")
		set_process(false)   # the menu is not built; _process would touch missing nodes
		RSExit.quit(get_tree(), 2)
		return
	theme = RSUi.theme(20)
	RSTournament.clear()
	RSSolo.clear()
	if "--static-menu" in OS.get_cmdline_user_args():
		var bg := ColorRect.new()
		bg.color = Color("152338")
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(bg)
	else:
		_build_backdrop()

	_preview = RSGamePreview.new()
	add_child(_preview)
	# Darken the left side for the lists and the bottom for the title plate and prompts.
	add_child(_shade(Vector2(0, 0), Vector2(1, 0), [0.0, 0.36, 0.66], [0.94, 0.8, 0.0]))
	add_child(_shade(Vector2(0, 1), Vector2(0, 0.45), [0.0, 1.0], [0.9, 0.0]))

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	margin.add_theme_constant_override("margin_left", 64)
	margin.add_theme_constant_override("margin_top", 44)
	margin.add_theme_constant_override("margin_bottom", 96)
	add_child(margin)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(540, 0)
	col.add_theme_constant_override("separation", 4)
	margin.add_child(col)
	var logo := HBoxContainer.new()
	logo.add_theme_constant_override("separation", 12)
	col.add_child(logo)
	for part: Array in [["REGINA", RSUi.TEXT], ["SPORTS", RSUi.ACCENT]]:
		var word := RSUi.label(part[0], 52, part[1])
		word.add_theme_font_override("font", RSUi.font_bold())
		logo.add_child(word)
	col.add_child(RSUi.label(tr("体感运动游戏 · 拿起手柄就能玩"), 17, RSUi.TEXT_MUTED))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 22)
	col.add_child(gap)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	_menu_grid = VBoxContainer.new()
	_menu_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_menu_grid.add_theme_constant_override("separation", 4)
	scroll.add_child(_menu_grid)
	var modes := GridContainer.new()
	modes.columns = 2
	modes.add_theme_constant_override("h_separation", 8)
	modes.add_theme_constant_override("v_separation", 4)
	for i in entries.size():
		var sport := i < _sports
		if i == _sports:
			var line := HSeparator.new()
			line.add_theme_constant_override("separation", 22)
			_menu_grid.add_child(line)
			_menu_grid.add_child(modes)
		var b := _row(i, sport)
		(_menu_grid if sport else modes).add_child(b)
		_buttons.append(b)

	_info = VBoxContainer.new()
	_info.anchor_left = 1.0
	_info.anchor_right = 1.0
	_info.anchor_top = 1.0
	_info.anchor_bottom = 1.0
	_info.offset_left = -704
	_info.offset_right = -64
	_info.offset_bottom = -100
	_info.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_info.alignment = BoxContainer.ALIGNMENT_END
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info.add_theme_constant_override("separation", 14)
	add_child(_info)
	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", 18)
	_info.add_child(heading)
	_info_title = RSUi.label("", 84)
	_info_title.add_theme_font_override("font", RSUi.font_bold())
	heading.add_child(_info_title)
	_info_tag = RSUi.label("", 34, RSUi.ACCENT)
	_info_tag.add_theme_font_override("font", RSUi.font_bold())
	_info_tag.size_flags_vertical = Control.SIZE_SHRINK_END
	heading.add_child(_info_tag)
	_desc = RSUi.label("", 18, Color(RSUi.TEXT, 0.85), true)
	_desc.add_theme_constant_override("line_spacing", 6)
	_info.add_child(_desc)
	_stats = HBoxContainer.new()
	_stats.add_theme_constant_override("separation", 2)
	_info.add_child(_stats)
	_stat(tr("人数"), "1–4")
	_best = _stat(tr("最佳成绩"), "")

	# Button prompts and the hub status along the bottom.
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -64
	var bar_bg := RSUi.panel_style(0, Color(0.01, 0.015, 0.03, 0.86))
	bar_bg.border_width_top = 1
	bar_bg.content_margin_left = 64
	bar_bg.content_margin_right = 64
	bar_bg.content_margin_top = 8
	bar_bg.content_margin_bottom = 8
	bar.add_theme_stylebox_override("panel", bar_bg)
	add_child(bar)
	var prompts := HBoxContainer.new()
	prompts.add_theme_constant_override("separation", 30)
	bar.add_child(prompts)
	_status = RSUi.label("", 15, RSUi.TEXT, true)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	prompts.add_child(_status)
	prompts.add_child(_prompt(["A"], tr("进入")))
	prompts.add_child(_prompt(["B", "C"], tr("选择")))
	prompts.add_child(_prompt(["D"], tr("游戏中暂停")))
	prompts.add_child(RSUi.label(tr("键盘：方向键 + 回车 · Esc"), 15, RSUi.TEXT_MUTED))
	_pages = RSMenuPages.new()
	add_child(_pages)
	_pages.closed.connect(_restore_focus)
	_settings = RSPauseMenu.new(self, true)
	add_child(_settings)
	_settings.benchmark_requested.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/menu/benchmark_menu.tscn"))
	_settings.visibility_changed.connect(func() -> void:
		if not _settings.visible:
			_restore_focus())

	ControllerHub.button_pressed.connect(_on_button)
	ControllerHub.controller_connected.connect(_send_oled)
	_buttons[0].grab_focus()
	_on_focus(0)
	RSSettings.apply(get_tree())
	RSMusic.attach(self).play_track("menu")
	if RSBenchmarkMenu.return_to_settings:
		RSBenchmarkMenu.return_to_settings = false
		for i in entries.size():
			if entries[i].get("page", "") == "settings":
				_buttons[i].grab_focus()
				_open(i)
				_settings.focus_benchmark()
				break


func _build_backdrop() -> void:
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(svc)
	var vp := SubViewport.new()
	_backdrop = vp
	vp.msaa_3d = Viewport.MSAA_2X
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	vp.own_world_3d = true
	svc.add_child(vp)
	var world := Node3D.new()
	vp.add_child(world)
	_course = RSSkateCourse.new()
	world.add_child(_course)
	RSSkateCourse.setup_environment(world)
	_cam = Camera3D.new()
	_cam.far = 3000
	_cam.cull_mask = 1           # not the riders' name tags (player layers)
	world.add_child(_cam)
	var colors := [Color(0.23, 0.51, 0.96), Color(0.94, 0.27, 0.27)]
	for i in 2:
		var sk := RSSkater.new(_course, colors[i], 1 + i * 2, 0)
		sk.gain_db = -80.0
		world.add_child(sk)
		sk.place(-1.5 + i * 3.0, RSSkateCourse.START_S + 30.0 + i * 6.0)
		_riders.append(sk)
		_bots.append(RSSkateBot.new(sk, 4100 + i * 37))
	_cut()


func _process(delta: float) -> void:
	_status_text()
	if _riders.is_empty():
		return
	# A sport picture covers the street: stop rendering and simulating it until it shows again.
	var covered := _preview.covers_screen()
	_backdrop.render_target_update_mode = SubViewport.UPDATE_DISABLED if covered else SubViewport.UPDATE_ALWAYS
	if covered:
		return
	for i in _riders.size():
		var sk := _riders[i]
		sk.step(delta, _bots[i].update(delta), true)
		if sk.finished and sk.current_speed() < 2.0:
			sk.place(-1.5 + i * 3.0, RSSkateCourse.START_S + 10.0 + i * 6.0)
	_shot_t += delta
	if _shot_t > SHOT_TIME:
		_cut()
	_film(delta, false)


func _lead() -> RSSkater:
	return _riders[0] if _riders[0].s() >= _riders[1].s() or _riders[1].finished else _riders[1]


func _cut() -> void:
	_shot = (_shot + 1) % 3
	_shot_t = 0.0
	_side = -_side
	_film(0.0, true)


func _film(dt: float, snap: bool) -> void:
	var sk := _lead()
	var fwd := Vector3(-sin(sk.heading), 0.0, -cos(sk.heading))
	var want: Vector3
	var look: Vector3
	match _shot:
		0:   # chase, low behind
			want = sk.pos - fwd * 4.2 + Vector3.UP * 1.4
			look = sk.pos + fwd * 4.0 + Vector3.UP * 0.8
		1:   # tracking alongside, a little ahead
			want = sk.pos + Vector3(_side * 3.6, 1.0, 0.0) + fwd * 1.5
			look = sk.pos + Vector3.UP * 0.9
		_:   # high and wide, ahead, the street and the sea beyond
			want = sk.pos + fwd * 9.0 + Vector3(_side * 5.0, 4.5, 0.0)
			look = sk.pos + Vector3.UP * 0.6
	want.x = clampf(want.x, -RSSkateCourse.BOUND + 0.6, RSSkateCourse.BOUND - 0.6)
	want.y = maxf(want.y, _course.top(want.x, -want.z) + 0.6)
	var k := 1.0 if snap else 1.0 - exp(-dt * 4.0)
	_cam_pos = want if snap else _cam_pos.lerp(want, k)
	_cam_look = look if snap else _cam_look.lerp(look, minf(k * 1.5, 1.0))
	_cam.global_position = _cam_pos
	if _cam_pos.distance_to(_cam_look) > 0.1:
		_cam.look_at(_cam_look)
	_cam.fov = 58.0 if _shot != 2 else 48.0


func _status_text() -> void:
	if not ControllerHub.is_hub_connected():
		_status.text = tr("● 未连接 hub —— 请先运行 hub/run_hub.bat")
		_status.add_theme_color_override("font_color", RSUi.BAD)
		return
	var ble_warning := ControllerHub.ble_warning()
	if not ble_warning.is_empty():
		_status.text = ble_warning
		_status.add_theme_color_override("font_color", RSUi.HIGHLIGHT)
		return
	var live := ControllerHub.connected_controllers()
	_status.text = tr("● hub 已连接 · %d 个手柄") % live.size() if not live.is_empty() else tr("● hub 已连接 · 还没有手柄：打开 Regina 或用手机扫码（二维码在游戏大厅和调试场景里）")
	_status.add_theme_color_override("font_color", RSUi.GOOD)


func _on_focus(i: int) -> void:
	_paint_row(_index, false)
	_index = i
	_paint_row(i, true)
	_preview.show_game(entries[i])
	_info_title.text = _name(i)
	_info_tag.text = entries[i]["oled"] if RSSettings.language == 0 else ""
	_desc.text = tr(entries[i]["desc"])
	var game_id: String = entries[i].get("id", "")
	_stats.visible = not game_id.is_empty()
	if _stats.visible:
		var best := RSRecords.overall_best(game_id)
		_best.text = str(best) if best >= 0 else "—"
	for c in ControllerHub.connected_controllers():
		_send_oled(c)


func _row(i: int, sport: bool) -> Button:
	## A list entry: number, name and English tag for sports; a smaller name for the modes.
	## The leaning accent bar comes from the theme's hover / focus styles.
	var b := Button.new()
	b.custom_minimum_size = Vector2(530 if sport else 261, RSUi.text_size(54 if sport else 42))
	var empty := StyleBoxEmpty.new()
	b.add_theme_stylebox_override("normal", empty)
	b.add_theme_stylebox_override("disabled", empty)
	b.pressed.connect(_open.bind(i))
	b.focus_entered.connect(_on_focus.bind(i))
	b.mouse_entered.connect(b.grab_focus)
	var box := HBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 22
	box.offset_right = -22
	box.add_theme_constant_override("separation", 16)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(box)
	var labels: Array[Label] = []
	if sport:
		var num := RSUi.label("%02d" % (i + 1), 21)
		num.add_theme_font_override("font", RSUi.font_numeric())
		num.custom_minimum_size.x = 26
		num.set_meta("rs_alpha", 0.55)
		labels.append(num)
	var title := RSUi.label(_name(i), 24 if sport else 18)
	title.add_theme_font_override("font", RSUi.font_strong())
	if not sport:   # mode names share a half-width cell; long English ones are trimmed
		title.clip_text = true
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.set_meta("rs_alpha", 0.86 if sport else 0.76)
	labels.append(title)
	if sport and RSSettings.language == 0:
		var tag := RSUi.label(entries[i]["oled"], 15)
		tag.add_theme_font_override("font", RSUi.font_label())
		tag.set_meta("rs_alpha", 0.5)
		labels.append(tag)
	for l: Label in labels:
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.size_flags_vertical = Control.SIZE_FILL
		box.add_child(l)
	_row_labels.append(labels)
	_paint_row(_row_labels.size() - 1, false)
	return b


func _paint_row(i: int, selected: bool) -> void:
	if i >= _row_labels.size():
		return
	for l: Label in _row_labels[i]:
		l.add_theme_color_override("font_color", RSUi.INK if selected else Color(RSUi.TEXT, l.get_meta("rs_alpha")))


func _stat(caption: String, value: String) -> Label:
	var cell := PanelContainer.new()
	var bg := RSUi.hud_style(0)
	bg.content_margin_left = 18
	bg.content_margin_right = 18
	bg.content_margin_top = 10
	bg.content_margin_bottom = 10
	cell.add_theme_stylebox_override("panel", bg)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats.add_child(cell)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	cell.add_child(box)
	box.add_child(RSUi.label(caption, 14, RSUi.TEXT_MUTED))
	var number := RSUi.label(value, 32, RSUi.TEXT)
	number.add_theme_font_override("font", RSUi.font_numeric())
	box.add_child(number)
	return number


func _prompt(keys: Array, action: String) -> HBoxContainer:
	## Controller button glyphs followed by what they do.
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	for key: String in keys:
		var glyph := RSUi.label(key, 15, RSUi.INK)
		glyph.add_theme_font_override("font", RSUi.font_numeric())
		glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		glyph.custom_minimum_size = Vector2(28, 28)
		glyph.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		glyph.add_theme_stylebox_override("normal", RSUi.glyph_style())
		box.add_child(glyph)
	var l := RSUi.label(action, 15)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size_flags_vertical = Control.SIZE_FILL
	box.add_child(l)
	return box


func _shade(from: Vector2, to: Vector2, offsets: Array, alphas: Array) -> TextureRect:
	var shade := TextureRect.new()
	var grad := GradientTexture2D.new()
	grad.gradient = Gradient.new()
	grad.gradient.offsets = PackedFloat32Array(offsets)
	var colors := PackedColorArray()
	for a: float in alphas:
		colors.append(Color(0.02, 0.03, 0.05, a))
	grad.gradient.colors = colors
	grad.fill_from = from
	grad.fill_to = to
	shade.texture = grad
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return shade


func _on_button(_c: RSController, button: int) -> void:
	if _settings.is_open():
		_settings.on_button(button)
		return
	if _pages.visible:
		_pages.on_button(button)
		return
	match button:
		RSController.BTN_A:
			_open(_index)
		RSController.BTN_B:
			_buttons[(_index + 1) % _buttons.size()].grab_focus()
		RSController.BTN_C:
			_buttons[(_index + _buttons.size() - 1) % _buttons.size()].grab_focus()


func _send_oled(c: RSController) -> void:
	ControllerHub.send_ui(c.id, {"clear": true, "title": "REGINA", "main": entries[_index]["oled"], "sub": "%d / %d" % [_index + 1, entries.size()],
		"legends": ["OPEN", "NEXT", "PREV", null]})


func _name(i: int) -> String:
	if entries[i]["scene"] == "" and not entries[i].has("page"):
		return tr(entries[i]["name"]) % RSSettings.language_name()
	return tr(entries[i]["name"])


func _open(i: int) -> void:
	if _pages.visible or _settings.is_open():
		return
	if entries[i].has("page"):
		_menu_grid.visible = false
		_info.visible = false
		_preview.visible = false
		if entries[i]["page"] == "settings":
			_settings.open()
		else:
			_pages.open(entries[i]["page"])
		return
	if entries[i]["scene"] == "":
		RSSettings.next_language()
		get_tree().reload_current_scene()
		return
	get_tree().change_scene_to_file(entries[i]["scene"])


func _restore_focus() -> void:
	_menu_grid.visible = true
	_info.visible = true
	_buttons[_index].grab_focus()
	_preview.show_game(entries[_index])
