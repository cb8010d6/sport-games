extends Control
## Start screen: pick a game. Mouse, keyboard (arrows + Enter) or any controller
## (B = next, C = previous, A = open). Esc in a game comes back here. The last entry switches
## the language (中文 / English) and rebuilds the screen.
## Behind the menu, two bot riders skate the seaside street from the skate game, filmed by a
## camera that cuts between a chase shot and a tracking shot alongside.

const GAMES := RSCatalog.GAMES + [
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

var _buttons: Array[Button] = []
var _desc: Label
var _status: Label
var _index := 0
var _pages: RSMenuPages
var _settings: RSPauseMenu
var _menu_grid: GridContainer

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
	var cli_game := "plane"
	var cli_launch := false
	for a: String in OS.get_cmdline_user_args():
		if a == "--demo" or a.begins_with("--demo="):
			cli_launch = true
		elif a.begins_with("--game="):
			cli_game = a.trim_prefix("--game=")
			cli_launch = true
	if cli_launch:
		for game: Dictionary in GAMES:
			if game.has("id") and game["id"] == cli_game:
				print("CLI game: %s" % cli_game)
				get_tree().change_scene_to_file.call_deferred(game["scene"])
				return
		push_error("Unknown --game id")
		get_tree().quit(2)
		return
	theme = RSUi.theme(20)
	RSTournament.clear()
	if "--static-menu" in OS.get_cmdline_user_args():
		var bg := ColorRect.new()
		bg.color = Color("152338")
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(bg)
	else:
		_build_backdrop()

	# Darken the left side for the menu column; the street stays clear on the right.
	var shade := TextureRect.new()
	var grad := GradientTexture2D.new()
	grad.gradient = Gradient.new()
	grad.gradient.offsets = PackedFloat32Array([0.0, 0.42, 0.75])
	grad.gradient.colors = PackedColorArray([Color(0.02, 0.04, 0.08, 0.86), Color(0.02, 0.04, 0.08, 0.7), Color(0.02, 0.04, 0.08, 0.0)])
	grad.fill_from = Vector2(0, 0)
	grad.fill_to = Vector2(1, 0)
	shade.texture = grad
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	margin.add_theme_constant_override("margin_left", 48)
	margin.add_theme_constant_override("margin_top", 48)
	margin.add_theme_constant_override("margin_bottom", 40)
	add_child(margin)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(660, 0)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 10)
	margin.add_child(col)
	var title := RSUi.label("Regina Sports", 64)
	col.add_child(title)
	var sub := RSUi.label(tr("体感运动游戏 · 拿起手柄就能玩"), 22, Color(0.85, 0.9, 1.0))
	col.add_child(sub)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 6)
	col.add_child(gap)

	var normal := RSUi.panel_style(16, Color(0.06, 0.09, 0.16, 0.5))
	var hover := RSUi.panel_style(16, Color(0.1, 0.14, 0.24, 0.8))
	var focus := RSUi.panel_style(16, Color(1.0, 1.0, 1.0, 0.16))
	focus.set_border_width_all(3)
	focus.border_color = Color.WHITE
	for s: StyleBox in [normal, hover, focus]:
		s.content_margin_top = 6
		s.content_margin_bottom = 6
	_menu_grid = GridContainer.new()
	_menu_grid.columns = 2
	_menu_grid.add_theme_constant_override("h_separation", 12)
	_menu_grid.add_theme_constant_override("v_separation", 8)
	col.add_child(_menu_grid)
	for i in GAMES.size():
		var b := Button.new()
		b.text = "  " + _name(i)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(324, 48)
		b.add_theme_font_size_override("font_size", 22)
		b.add_theme_stylebox_override("normal", normal)
		b.add_theme_stylebox_override("hover", hover)
		b.add_theme_stylebox_override("pressed", hover)
		b.add_theme_stylebox_override("focus", focus)
		b.pressed.connect(_open.bind(i))
		b.focus_entered.connect(_on_focus.bind(i))
		b.mouse_entered.connect(b.grab_focus)
		_menu_grid.add_child(b)
		_buttons.append(b)
	_desc = RSUi.label("", 18, Color(0.95, 0.97, 1.0))
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc.custom_minimum_size = Vector2(660, 72)
	col.add_child(_desc)
	var hint := RSUi.label(tr("手柄：B / C 选择，A 进入　　键盘：方向键 + 回车\n游戏里短按 D 或 Esc 打开暂停菜单：重新开始、画面设置、语言、回主菜单"), 15, Color(0.88, 0.92, 1.0, 0.8))
	col.add_child(hint)
	_status = RSUi.label("", 15)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status)
	_pages = RSMenuPages.new()
	add_child(_pages)
	_pages.closed.connect(_restore_focus)
	_settings = RSPauseMenu.new(self, true)
	add_child(_settings)
	_settings.visibility_changed.connect(func() -> void:
		if not _settings.visible:
			_restore_focus())

	ControllerHub.button_pressed.connect(_on_button)
	ControllerHub.controller_connected.connect(_send_oled)
	_buttons[0].grab_focus()
	RSSettings.apply(get_tree())
	RSMusic.attach(self).play_track("menu")


func _build_backdrop() -> void:
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(svc)
	var vp := SubViewport.new()
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
		_status.add_theme_color_override("font_color", Color(1.0, 0.82, 0.78))
		return
	var live := ControllerHub.connected_controllers()
	_status.text = tr("● hub 已连接 · %d 个手柄") % live.size() if not live.is_empty() else tr("● hub 已连接 · 还没有手柄：打开 Regina 或用手机扫码（二维码在游戏大厅和调试场景里）")
	_status.add_theme_color_override("font_color", Color(0.8, 1.0, 0.85))


func _on_focus(i: int) -> void:
	_index = i
	_desc.text = tr(GAMES[i]["desc"])
	var game_id: String = GAMES[i].get("id", "")
	if not game_id.is_empty():
		var best := RSRecords.overall_best(game_id)
		_desc.text += "\n" + (tr("最佳成绩：%d") % best if best >= 0 else tr("暂无纪录"))
	for c in ControllerHub.connected_controllers():
		_send_oled(c)


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
	ControllerHub.send_ui(c.id, {"clear": true, "title": "REGINA", "main": GAMES[_index]["oled"], "sub": "%d / %d" % [_index + 1, GAMES.size()],
		"legends": ["OPEN", "NEXT", "PREV", null]})


func _name(i: int) -> String:
	if GAMES[i]["scene"] == "" and not GAMES[i].has("page"):
		return tr(GAMES[i]["name"]) % RSSettings.language_name()
	return tr(GAMES[i]["name"])


func _open(i: int) -> void:
	if _pages.visible or _settings.is_open():
		return
	if GAMES[i].has("page"):
		_menu_grid.visible = false
		if GAMES[i]["page"] == "settings":
			_settings.open()
		else:
			_pages.open(GAMES[i]["page"])
		return
	if GAMES[i]["scene"] == "":
		RSSettings.next_language()
		get_tree().reload_current_scene()
		return
	get_tree().change_scene_to_file(GAMES[i]["scene"])


func _restore_focus() -> void:
	_menu_grid.visible = true
	_buttons[_index].grab_focus()
