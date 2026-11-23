extends Node3D
## Controller debug scene (P0): live 3D models of every connected controller, status cards,
## pairing / player assignment, phone QR code, motion plots, swing detection and OLED preview.
## Everything is built in code so the scene file stays trivial.

const PANEL_BG := Color(0.07, 0.08, 0.11, 0.92)
const TEXT_MUTED := Color(0.6, 0.64, 0.72)
const BTN_NAMES := ["A", "B", "C", "D"]
const CAM_TARGET := Vector3(0, 1.15, -0.2)

var _models: Dictionary = {}       ## controller id -> RSControllerModel
var _cards: Dictionary = {}        ## controller id -> {root, labels...}
var _detectors: Dictionary = {}    ## controller id -> RSSwingDetector
var _selected_id := 0

var _ui_root: Control
var _left_panel: Control
var _bottom_panel: Control
var _cam: Camera3D
var _cards_box: VBoxContainer
var _hub_label: Label
var _qr_rect: TextureRect
var _url_label: Label
var _log: RichTextLabel
var _plot_gyro: RSPlot
var _plot_lin: RSPlot
var _oled: RSOledPreview
var _sel_label: Label
var _font: SystemFont


func _ready() -> void:
	_build_world()
	_build_ui()
	ControllerHub.roster_changed.connect(_on_roster_changed)
	ControllerHub.controller_event.connect(_on_controller_event)
	ControllerHub.button_pressed.connect(_on_button_pressed)
	ControllerHub.samples_received.connect(_on_samples)
	ControllerHub.qr_received.connect(_on_qr)
	if not ControllerHub.qr_rows.is_empty():
		_on_qr(ControllerHub.phone_url, ControllerHub.qr_rows)
	_log_line(tr("[color=#8b93a7]等待 hub……先运行 hub/run_hub.bat[/color]"))
	_on_roster_changed()
	for c in ControllerHub.connected_controllers():
		_send_debug_ui(c)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug_ui"):
		_ui_root.visible = not _ui_root.visible
	elif event.is_action_pressed("recenter_all"):
		ControllerHub.recenter(0)
	elif event.is_action_pressed("ui_cancel"):
		get_tree().change_scene_to_file("res://scenes/menu/main_menu.tscn")


func _process(_delta: float) -> void:
	var ok := ControllerHub.is_hub_connected()
	_hub_label.text = tr("● hub 已连接") if ok else tr("● 未连接 hub —— 请运行 hub/run_hub.bat")
	_hub_label.add_theme_color_override("font_color", Color(0.3, 0.85, 0.45) if ok else Color(0.95, 0.45, 0.35))
	for id in _cards.keys():
		_update_card(id)
	_layout_models()
	_frame_camera()


# --------------------------------------------------------------------------- world ----

func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.22, 0.45, 0.88)
	sky_mat.sky_horizon_color = Color(0.78, 0.86, 0.98)
	sky_mat.ground_horizon_color = Color(0.78, 0.86, 0.98)
	sky_mat.ground_bottom_color = Color(0.35, 0.42, 0.5)
	sky_mat.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# AgX (4.4+) keeps saturated toon colours from clipping; fall back to ACES on older builds.
	var v := Engine.get_version_info()
	var agx := int(v.major) > 4 or int(v.minor) >= 4
	env.tonemap_mode = (4 if agx else 3) as Environment.ToneMapper  # 4 = TONE_MAPPER_AGX, 3 = ACES
	env.ssao_enabled = true
	env.ssao_radius = 0.8
	env.ssao_intensity = 1.6
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.04
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.12
	env.fog_enabled = true
	env.fog_light_color = Color(0.75, 0.84, 0.97)
	env.fog_density = 0.008
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -35, 0)
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 30.0
	add_child(sun)

	# Ground + a round stage, in the shared toon material.
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	ground.mesh = plane
	ground.material_override = RSMeshUtil.toon_material(Color(0.62, 0.8, 0.55), 0.0, 0.9)
	add_child(ground)
	var stage := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 4.5
	cyl.bottom_radius = 4.7
	cyl.height = 0.25
	cyl.radial_segments = 64
	stage.mesh = cyl
	stage.position = Vector3(0, 0.12, -0.5)
	stage.material_override = RSMeshUtil.toon_material(Color(0.95, 0.93, 0.88), 0.15, 0.8)
	add_child(stage)
	# A few rounded "set dressing" blocks in player colours, for judging the toon look.
	var deco := [[Vector3(-7, 0.6, -11), Color(0.23, 0.51, 0.96)], [Vector3(8, 0.9, -13), Color(0.94, 0.27, 0.27)],
		[Vector3(-12, 0.5, -6), Color(0.13, 0.77, 0.37)], [Vector3(13, 0.7, -7), Color(0.96, 0.62, 0.04)]]
	for d in deco:
		var mi := MeshInstance3D.new()
		var h: float = d[0].y * 2.0
		mi.mesh = RSMeshUtil.rounded_box(Vector3(1.6, h, 1.6), 0.35)
		mi.material_override = RSMeshUtil.toon_material(d[1], 0.4)
		mi.position = d[0]
		add_child(mi)

	_cam = Camera3D.new()
	_cam.position = Vector3(0, 3.0, 2.4)
	_cam.fov = 50
	add_child(_cam)
	_cam.look_at(CAM_TARGET)


func _frame_camera() -> void:
	## Shift the lens so the models sit in the middle of the area the panels leave free.
	var vp := get_viewport().get_visible_rect().size
	var free := Rect2(Vector2.ZERO, vp)
	if _ui_root.visible:
		var left := _left_panel.get_global_rect().end.x
		free = Rect2(left, 0.0, vp.x - left, _bottom_panel.get_global_rect().position.y)
	var shift := (free.get_center() - vp * 0.5) / (vp * 0.5)
	var half_h := _cam.position.distance_to(CAM_TARGET) * tan(deg_to_rad(_cam.fov) * 0.5)
	_cam.h_offset = lerpf(_cam.h_offset, -shift.x * half_h * vp.x / vp.y, 0.2)
	_cam.v_offset = lerpf(_cam.v_offset, shift.y * half_h, 0.2)


func _layout_models() -> void:
	var live: Array[RSController] = ControllerHub.connected_controllers()
	var n := live.size()
	for i in n:
		var m := _models.get(live[i].id) as RSControllerModel
		if m:
			var target := Vector3((i - (n - 1) * 0.5) * 1.7, 1.2, 0.0)
			m.position = m.position.lerp(target, 0.15) if m.position != Vector3.ZERO else target


# ------------------------------------------------------------------------------ UI ----

func _panel_style(radius: int = 16) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(14)
	sb.border_color = Color(1, 1, 1, 0.06)
	sb.set_border_width_all(1)
	return sb


func _build_ui() -> void:
	_font = SystemFont.new()
	_font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", "Source Han Sans SC", "sans-serif"])
	var theme := Theme.new()
	theme.default_font = _font
	theme.default_font_size = 15

	var layer := CanvasLayer.new()
	add_child(layer)
	_ui_root = Control.new()
	_ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_root.theme = theme
	layer.add_child(_ui_root)

	# Left column: hub status, phone QR, controller cards.
	var left := PanelContainer.new()
	left.add_theme_stylebox_override("panel", _panel_style())
	left.position = Vector2(16, 16)
	left.custom_minimum_size = Vector2(400, 0)
	left.anchor_bottom = 1.0
	left.offset_bottom = -16
	_ui_root.add_child(left)
	_left_panel = left
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	left.add_child(col)

	var title := Label.new()
	title.text = tr("Regina Sports · 手柄调试")
	title.add_theme_font_size_override("font_size", 22)
	col.add_child(title)
	_hub_label = Label.new()
	col.add_child(_hub_label)

	var qr_row := HBoxContainer.new()
	qr_row.add_theme_constant_override("separation", 12)
	col.add_child(qr_row)
	_qr_rect = TextureRect.new()
	_qr_rect.custom_minimum_size = Vector2(120, 120)
	_qr_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_qr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr_row.add_child(_qr_rect)
	var qr_text := VBoxContainer.new()
	qr_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	qr_row.add_child(qr_text)
	var qr_title := Label.new()
	qr_title.text = tr("用手机扫码加入")
	qr_text.add_child(qr_title)
	_url_label = Label.new()
	_url_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_url_label.add_theme_color_override("font_color", TEXT_MUTED)
	_url_label.add_theme_font_size_override("font_size", 13)
	_url_label.text = tr("（hub 启动后显示）")
	qr_text.add_child(_url_label)
	var qr_hint := Label.new()
	qr_hint.text = tr("同一 Wi-Fi；首次打开需信任证书")
	qr_hint.add_theme_color_override("font_color", TEXT_MUTED)
	qr_hint.add_theme_font_size_override("font_size", 12)
	qr_text.add_child(qr_hint)

	var tools := HBoxContainer.new()
	col.add_child(tools)
	tools.add_child(_make_button(tr("全部归零 (R)"), func() -> void: ControllerHub.recenter(0)))
	tools.add_child(_make_button(tr("全部校准"), func() -> void: ControllerHub.calibrate(0)))
	tools.add_child(_make_button(tr("屏幕测试"), _send_test_ui))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	_cards_box = VBoxContainer.new()
	_cards_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards_box.add_theme_constant_override("separation", 10)
	scroll.add_child(_cards_box)

	var help := Label.new()
	help.text = tr("长按手柄 D 键 1 秒 = 归零   F1 隐藏界面   Esc 返回菜单")
	help.add_theme_color_override("font_color", TEXT_MUTED)
	help.add_theme_font_size_override("font_size", 12)
	col.add_child(help)

	# Bottom right: plots, OLED preview, event log for the selected controller.
	var bottom := PanelContainer.new()
	bottom.add_theme_stylebox_override("panel", _panel_style())
	bottom.anchor_left = 0.0
	bottom.anchor_right = 1.0
	bottom.anchor_top = 1.0
	bottom.anchor_bottom = 1.0
	bottom.offset_left = 432
	bottom.offset_right = -16
	bottom.offset_top = -236
	bottom.offset_bottom = -16
	_ui_root.add_child(bottom)
	_bottom_panel = bottom
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	bottom.add_child(row)

	var plots := VBoxContainer.new()
	plots.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(plots)
	_sel_label = Label.new()
	_sel_label.add_theme_color_override("font_color", TEXT_MUTED)
	_sel_label.add_theme_font_size_override("font_size", 13)
	plots.add_child(_sel_label)
	_plot_gyro = RSPlot.new()
	_plot_gyro.title = tr("角速度 rad/s（本体坐标）")
	_plot_gyro.range_value = 15.0
	_plot_gyro.size_flags_vertical = Control.SIZE_EXPAND_FILL
	plots.add_child(_plot_gyro)
	_plot_lin = RSPlot.new()
	_plot_lin.source = RSPlot.Source.LINEAR_ACCEL
	_plot_lin.title = tr("线加速度 m/s²（世界坐标，已去重力）")
	_plot_lin.range_value = 30.0
	_plot_lin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	plots.add_child(_plot_lin)

	var oled_col := VBoxContainer.new()
	row.add_child(oled_col)
	var oled_title := Label.new()
	oled_title.text = tr("手柄屏幕 64×128")
	oled_title.add_theme_color_override("font_color", TEXT_MUTED)
	oled_title.add_theme_font_size_override("font_size", 13)
	oled_col.add_child(oled_title)
	_oled = RSOledPreview.new()
	_oled.custom_minimum_size = Vector2(96, 192)
	oled_col.add_child(_oled)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.custom_minimum_size = Vector2(320, 0)
	_log.add_theme_font_size_override("normal_font_size", 13)
	row.add_child(_log)


func _make_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b


func _log_line(bb: String) -> void:
	var t := Time.get_time_string_from_system()
	_log.append_text("[color=#5d6475]%s[/color]  %s\n" % [t, bb])


# --------------------------------------------------------------- controller cards ----

func _on_roster_changed() -> void:
	for c: RSController in ControllerHub.controllers.values():
		if not _cards.has(c.id):
			_create_card(c)
		if not _models.has(c.id):
			var m := RSControllerModel.new(c)
			add_child(m)
			_models[c.id] = m
		if not _detectors.has(c.id):
			var det := RSSwingDetector.new()
			det.swing_finished.connect(_on_swing)
			_detectors[c.id] = det
	if _selected_id == 0 or not ControllerHub.controllers.has(_selected_id):
		var live := ControllerHub.connected_controllers()
		if not live.is_empty():
			_select(live[0].id)


func _create_card(c: RSController) -> void:
	var panel := PanelContainer.new()
	var sb := _panel_style(12)
	sb.bg_color = Color(0.11, 0.13, 0.17, 1.0)
	panel.add_theme_stylebox_override("panel", sb)
	_cards_box.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)

	var head := HBoxContainer.new()
	v.add_child(head)
	var badge := Label.new()
	badge.custom_minimum_size = Vector2(42, 0)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", 16)
	head.add_child(badge)
	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	head.add_child(name_label)
	var select_btn := _make_button(tr("查看"), func() -> void: _select(c.id))
	select_btn.flat = true
	head.add_child(select_btn)

	var stats := Label.new()
	stats.add_theme_color_override("font_color", TEXT_MUTED)
	stats.add_theme_font_size_override("font_size", 13)
	v.add_child(stats)
	var motion := Label.new()
	motion.add_theme_font_size_override("font_size", 13)
	v.add_child(motion)

	var actions := HBoxContainer.new()
	v.add_child(actions)
	var player_opt := OptionButton.new()
	for p in 5:
		player_opt.add_item(tr("未分配") if p == 0 else tr("玩家 %d") % p, p)
	player_opt.item_selected.connect(func(idx: int) -> void: ControllerHub.set_player(c.id, idx))
	actions.add_child(player_opt)
	actions.add_child(_make_button(tr("归零"), func() -> void: ControllerHub.recenter(c.id)))
	actions.add_child(_make_button(tr("校准"), func() -> void: ControllerHub.calibrate(c.id)))
	actions.add_child(_make_button(tr("响一下"), _ping.bind(c.id)))

	_cards[c.id] = {"root": panel, "style": sb, "badge": badge, "name": name_label, "stats": stats, "motion": motion, "player": player_opt}


func _ping(id: int) -> void:
	ControllerHub.beep(id, 2200, 80)
	ControllerHub.vibrate(id, 60)


func _update_card(id: int) -> void:
	var c := ControllerHub.get_controller(id)
	var card: Dictionary = _cards[id]
	if c == null:
		return
	var color := RSControllerModel.PLAYER_COLORS[clampi(c.player, 0, 4)] as Color
	var badge: Label = card["badge"]
	badge.text = "P%d" % c.player if c.player > 0 else "--"
	badge.add_theme_color_override("font_color", color)
	var sb: StyleBoxFlat = card["style"]
	sb.border_color = color if id == _selected_id else Color(1, 1, 1, 0.06)
	sb.set_border_width_all(2 if id == _selected_id else 1)
	var kind_names := {"regina": "Regina", "phone": tr("手机"), "sim": tr("模拟"), "replay": tr("回放")}
	(card["name"] as Label).text = "%s · %s%s" % [kind_names.get(c.kind, c.kind), c.display_name, "" if c.connected else tr("（离线）")]
	var batt := tr("电量 --") if c.battery < 0 else tr("电量 %d%%%s") % [c.battery, tr(" 充电中") if c.charging else ""]
	var calib := tr("校准中…") if c.calibrating else (tr("已校准") if c.calibrated else tr("未校准"))
	(card["stats"] as Label).text = tr("%s   %.0f Hz   丢包 %.1f%%   %s%s") % [batt, c.rate_hz, c.loss * 100.0, calib, tr("   静止") if c.stationary else ""]
	var btns := ""
	for i in 4:
		btns += ("[%s]" if c.is_pressed(1 << i) else " %s ") % BTN_NAMES[i]
	(card["motion"] as Label).text = tr("俯仰 %+5.0f°  横滚 %+5.0f°  朝向 %+5.0f°   %s  旋钮 %d/%d") % [
		rad_to_deg(c.pitch()), rad_to_deg(c.roll()), rad_to_deg(c.yaw()), btns, c.dial_small, c.dial_big]
	var opt: OptionButton = card["player"]
	if opt.selected != c.player and not opt.has_focus():
		opt.select(c.player)
	(card["root"] as Control).modulate.a = 1.0 if c.connected else 0.5


func _select(id: int) -> void:
	_selected_id = id
	var c := ControllerHub.get_controller(id)
	_plot_gyro.controller = c
	_plot_lin.controller = c
	_oled.controller = c
	_sel_label.text = tr("正在查看：%s") % (c.display_name if c else "--")


# --------------------------------------------------------------------- events ----

func _on_samples(c: RSController, count: int) -> void:
	var det := _detectors.get(c.id) as RSSwingDetector
	if det:
		det.feed(c, count)


func _on_swing(c: RSController, swing: Dictionary) -> void:
	var axis: Vector3 = swing["axis_body"]
	var dir := tr("绕 X（上下挥）")
	if absf(axis.y) >= absf(axis.x) and absf(axis.y) >= absf(axis.z):
		dir = tr("绕 Y（左右挥，%s）") % (tr("向左") if axis.y > 0.0 else tr("向右"))
	elif absf(axis.z) >= absf(axis.x):
		dir = tr("绕 Z（转腕）")
	elif axis.x < 0.0:
		dir = tr("绕 X（向下挥）")
	else:
		dir = tr("绕 X（向上挥）")
	var peak_dps := rad_to_deg(float(swing["peak_rate"]))
	_log_line(tr("P%d 挥动：峰值 %.0f°/s，%s，扫过 %.0f°，用时 %.0f ms") % [c.player, peak_dps, dir, rad_to_deg(float(swing["angle"])), float(swing["duration"]) * 1000.0])
	ControllerHub.send_ui(c.id, {"toast": {"ms": 700, "text": "SWING %d" % int(peak_dps)}})
	ControllerHub.beep(c.id, int(clampf(800.0 + peak_dps, 900.0, 3500.0)), 50)
	ControllerHub.vibrate(c.id, 40)


func _on_button_pressed(c: RSController, button: int) -> void:
	_log_line(tr("P%d 按下 %s") % [c.player, BTN_NAMES[[1, 2, 4, 8].find(button)]])


func _on_controller_event(c: RSController, ev: String) -> void:
	var names := {"connected": tr("已连接"), "disconnected": tr("已断开"), "recentered": tr("已归零"), "calibrated": tr("零偏校准完成"),
		"calibrate_failed": tr("校准失败（请保持静止）"), "low_battery": tr("电量低")}
	var color := "#f59e0b" if ev in ["calibrate_failed", "low_battery", "disconnected"] else "#22c55e"
	_log_line("[color=%s]#%d %s %s[/color]" % [color, c.id, RSProfiles.bbcode(c.display_name), names.get(ev, ev)])
	if ev == "connected":
		_send_debug_ui(c)


func _send_debug_ui(c: RSController) -> void:
	ControllerHub.send_ui(c.id, {"clear": true, "title": "DEBUG", "legends": ["SWING", "", "", null]})


func _send_test_ui() -> void:
	for c in ControllerHub.connected_controllers():
		ControllerHub.send_ui(c.id, {
			"clear": true, "title": "SCREEN TEST", "main": "P%d" % c.player,
			"bar": {"pct": randi_range(20, 100), "label": "POWER"},
			"legends": ["SHOOT", "BACK", "MENU", null],
			"toast": {"ms": 1200, "text": "HELLO!"}})


func _on_qr(url: String, rows: PackedStringArray) -> void:
	if rows.is_empty():
		return
	var n := rows.size()
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGB8)
	for y in n:
		var row: String = rows[y]
		for x in mini(n, row.length()):
			img.set_pixel(x, y, Color.BLACK if row[x] == "1" else Color.WHITE)
	img.resize(n * 4, n * 4, Image.INTERPOLATE_NEAREST)
	_qr_rect.texture = ImageTexture.create_from_image(img)
	_url_label.text = url
