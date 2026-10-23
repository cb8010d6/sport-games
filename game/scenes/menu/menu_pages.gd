class_name RSMenuPages
extends Control
## Main-menu pages share one focusable, scrolling modal. Controller B/C navigate, A acts.

signal closed
var _col: VBoxContainer
var _page := ""
var _focus: Array[Control] = []
var _device_rows: VBoxContainer
var _device_signature := ""
var _message: Label
var _checks: Array[CheckBox] = []
var _qr_box: VBoxContainer
var _qr_rect: TextureRect
var _qr_url: Label
var _solo_slot := 1
var _solo_difficulty := 1


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	visible = false
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.color = RSUi.SCRIM
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(1000, 750)
	panel.add_theme_stylebox_override("panel", RSUi.modal_style())
	center.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	_col = VBoxContainer.new()
	_col.size_flags_horizontal = SIZE_EXPAND_FILL
	_col.add_theme_constant_override("separation", 14)
	scroll.add_child(_col)
	ControllerHub.qr_received.connect(_update_qr)


func open(page: String) -> void:
	_page = page
	visible = true
	_focus.clear()
	_checks.clear()
	for child in _col.get_children():
		_col.remove_child(child)
		child.queue_free()
	var titles := {"players": tr("玩家 / 手柄"), "records": tr("本地排行榜"), "party": tr("派对大赛"), "credits": tr("致谢与素材"), "solo": tr("单人挑战")}
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 18)
	_col.add_child(header)
	_button(header, tr("◀ 返回"), close)
	var title := RSUi.label(titles[page], 34)
	title.add_theme_font_override("font", RSUi.font_bold())
	header.add_child(title)
	_col.add_child(HSeparator.new())
	match page:
		"players":
			_build_players()
		"records":
			_build_records()
		"party":
			_build_party()
		"solo":
			_build_solo()
		"credits":
			_build_credits()
	_wire_focus()
	_focus[0].grab_focus()


func close() -> void:
	visible = false
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func on_button(button: int) -> void:
	if not visible:
		return
	if button == RSController.BTN_D:
		close()
		return
	var current := get_viewport().gui_get_focus_owner()
	var at := _focus.find(current)
	if button == RSController.BTN_B or button == RSController.BTN_C:
		var step := 1 if button == RSController.BTN_B else -1
		_focus[posmod(at + step, _focus.size())].grab_focus()
	elif button == RSController.BTN_A:
		if current is OptionButton:
			# Cycle directly so the whole page remains usable with four controller buttons.
			current.select((current.selected + 1) % current.item_count)
			current.item_selected.emit(current.selected)
		elif current is BaseButton:
			if current.toggle_mode:
				current.button_pressed = not current.button_pressed
			else:
				current.pressed.emit()


func _button(parent: Node, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = 42
	b.pressed.connect(action)
	parent.add_child(b)
	_focus.append(b)
	return b


func _option(parent: Node, labels: Array, selected: int) -> OptionButton:
	var opt := OptionButton.new()
	for text: String in labels:
		opt.add_item(text)
	opt.select(selected)
	parent.add_child(opt)
	_focus.append(opt)
	return opt


func _wire_focus() -> void:
	for i in _focus.size():
		var item := _focus[i]
		var prev := item.get_path_to(_focus[posmod(i - 1, _focus.size())])
		var next := item.get_path_to(_focus[(i + 1) % _focus.size()])
		item.focus_neighbor_top = prev
		item.focus_neighbor_bottom = next
		item.focus_next = next
		item.focus_previous = prev


func _build_players() -> void:
	var hint := RSUi.label(tr("档案按 P1–P4 保存，跨项目通用。名字可用键盘或手机手柄设置。"), 17, RSUi.TEXT_MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_col.add_child(hint)
	for slot in range(1, 5):
		var data := RSProfiles.profile(slot)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		_col.add_child(row)
		row.add_child(RSUi.label("P%d" % slot, 24, RSProfiles.player_color(slot)))
		var name_edit := LineEdit.new()
		name_edit.text = data["name"]
		name_edit.max_length = 20
		name_edit.custom_minimum_size.x = 210
		name_edit.accessibility_name = tr("玩家名字")
		row.add_child(name_edit)
		_focus.append(name_edit)
		var colors := _option(row, [tr("蓝"), tr("红"), tr("绿"), tr("橙"), tr("紫"), tr("粉"), tr("青"), tr("白")], data["color"])
		var look := _option(row, [tr("角色 %d") % 1, tr("角色 %d") % 2, tr("角色 %d") % 3, tr("角色 %d") % 4], data["avatar"])
		_button(row, tr("保存档案"), func() -> void:
			var err := RSProfiles.update(slot, name_edit.text, colors.selected, look.selected)
			name_edit.text = RSProfiles.player_name(slot)
			_message.text = tr("已保存") if err == OK else tr("保存失败，请检查用户目录权限"))
	_col.add_child(HSeparator.new())
	_col.add_child(RSUi.label(tr("已连接手柄 · 配对 / 分配 / 电量 / 校准"), 23))
	var instructions := RSUi.label(tr("打开 Regina 自动配对；手机与电脑连接同一 Wi-Fi，扫码加入。校准时将手柄平放不动。"), 16, RSUi.TEXT_MUTED)
	instructions.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_col.add_child(instructions)
	_device_rows = VBoxContainer.new()
	_col.add_child(_device_rows)
	_message = RSUi.label("", 17)
	_col.add_child(_message)
	_qr_box = VBoxContainer.new()
	_col.add_child(_qr_box)
	_qr_rect = TextureRect.new()
	_qr_rect.custom_minimum_size = Vector2(160, 160)
	_qr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_qr_rect.texture_filter = TEXTURE_FILTER_NEAREST
	_qr_box.add_child(_qr_rect)
	_qr_url = RSUi.label("", 16)
	_qr_box.add_child(_qr_url)
	_update_qr(ControllerHub.phone_url, ControllerHub.qr_rows)
	_device_signature = ""
	_refresh_devices()


func _update_qr(url: String, rows: PackedStringArray) -> void:
	if not is_instance_valid(_qr_box) or not _qr_box.is_inside_tree():
		return
	_qr_box.visible = not rows.is_empty()
	if not rows.is_empty():
		_qr_rect.texture = RSUi.qr_texture(rows)
		_qr_url.text = url


func _process(_delta: float) -> void:
	if visible and _page == "players":
		_refresh_devices()


func _refresh_devices() -> void:
	var live := ControllerHub.connected_controllers()
	var signature := str(ControllerHub.is_hub_connected())
	for c: RSController in live:
		signature += "%d:%d:%d:%s:%s" % [c.id, c.player, c.battery, c.display_name, c.calibrating]
	if signature == _device_signature:
		return
	_device_signature = signature
	var focused := get_viewport().gui_get_focus_owner()
	var rebuild_focus := focused != null and _device_rows.is_ancestor_of(focused)
	for child in _device_rows.get_children():
		_device_rows.remove_child(child)
		child.queue_free()
	_focus = _focus.filter(func(item: Control) -> bool: return is_instance_valid(item) and item.is_inside_tree())
	if not ControllerHub.is_hub_connected():
		_device_rows.add_child(RSUi.label(tr("● 未连接 hub —— 请先运行 hub/run_hub.bat"), 18))
	elif live.is_empty():
		_device_rows.add_child(RSUi.label(tr("等待手柄连接…"), 18))
	for c: RSController in live:
		if c.kind == "phone":
			RSProfiles.import_phone_name(c.player, str(c.info.get("profile_name", "")))
		var row := HBoxContainer.new()
		_device_rows.add_child(row)
		var battery := tr("电量未知") if c.battery < 0 else "%d%%" % c.battery
		var label := RSUi.label("%s · %s · %s" % [c.display_name, c.kind, battery], 18)
		label.clip_text = true
		label.size_flags_horizontal = SIZE_EXPAND_FILL
		row.add_child(label)
		var assign := _option(row, [tr("未分配"), "P1", "P2", "P3", "P4"], clampi(c.player, 0, 4))
		assign.item_selected.connect(func(slot: int) -> void: ControllerHub.set_player(c.id, slot))
		_button(row, tr("归零"), func() -> void: ControllerHub.recenter(c.id))
		var calibrate := _button(row, tr("校准中…") if c.calibrating else tr("校准"), func() -> void: ControllerHub.calibrate(c.id))
		calibrate.disabled = c.calibrating
	_wire_focus()
	if rebuild_focus and not _focus.is_empty():
		_focus[0].grab_focus()


func _build_records() -> void:
	var hint := RSUi.label(tr("只保存正式比赛中每位玩家的最佳成绩；演示和自定义规则不计入。"), 17, RSUi.TEXT_MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_col.add_child(hint)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	_col.add_child(grid)
	for game: Dictionary in RSCatalog.GAMES:
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", RSUi.card_style())
		card.size_flags_horizontal = SIZE_EXPAND_FILL
		grid.add_child(card)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 6)
		card.add_child(box)
		var name_label := RSUi.label(tr(game["name"]), 24)
		name_label.add_theme_font_override("font", RSUi.font_bold())
		box.add_child(name_label)
		var maps := 4 if game["id"] == "ski" else (2 if game["id"] == "basketball" else 1)
		for map_id in maps:
			var rows := RSRecords.leaderboard(game["id"], map_id)
			var lines := PackedStringArray([tr("地图 %d") % (map_id + 1)])
			for row: Dictionary in rows:
				lines.append("  P%d · %s · %d" % [row["slot"], row.get("name", ""), row["score"]])
			if rows.is_empty():
				lines.append(tr("暂无纪录"))
			box.add_child(RSUi.label("\n".join(lines), 18, RSUi.TEXT_MUTED))


func _build_party() -> void:
	var hint := RSUi.label(tr("选择 3–6 个项目连续比赛。名次积分 10 / 7 / 5 / 3，同分共享名次。"), 18)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_col.add_child(hint)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 10)
	_col.add_child(grid)
	for game: Dictionary in RSCatalog.GAMES:
		var check := CheckBox.new()
		check.text = tr(game["name"])
		check.button_pressed = _checks.size() < 3
		check.custom_minimum_size = Vector2(450, 52)
		grid.add_child(check)
		_checks.append(check)
		_focus.append(check)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_col.add_child(row)
	_button(row, tr("随机 3 项"), func() -> void: _random_party(3))
	_button(row, tr("全部 6 项"), func() -> void: _random_party(6))
	_button(row, tr("开始大赛"), _start_party).theme_type_variation = &"RSPrimary"
	_message = RSUi.label("", 18, RSUi.HIGHLIGHT)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_col.add_child(_message)


func _build_solo() -> void:
	var hint := RSUi.label(tr("一位真人对战一位电脑。挑战星数按地图 1 的正式个人最佳计算，既有纪录也计入；每个目标一星。"), 18)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_col.add_child(hint)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	_col.add_child(row)
	row.add_child(RSUi.label(tr("玩家档案"), 20))
	var profile := _option(row, ["P1", "P2", "P3", "P4"], _solo_slot - 1)
	profile.item_selected.connect(func(index: int) -> void:
		_solo_slot = index + 1
		open("solo"))
	row.add_child(RSUi.label(tr("电脑难度"), 20))
	var difficulty := _option(row, [tr("简单"), tr("普通"), tr("困难")], _solo_difficulty)
	difficulty.item_selected.connect(func(index: int) -> void: _solo_difficulty = index)
	_col.add_child(RSUi.label(tr("P%d · %s · 星数 %d / 18") % [_solo_slot, RSProfiles.player_name(_solo_slot), RSSolo.total_stars(_solo_slot)], 24))
	_message = RSUi.label("", 18, RSUi.HIGHLIGHT)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_col.add_child(_message)
	for game: Dictionary in RSCatalog.GAMES:
		var id: String = game["id"]
		var goals := PackedStringArray()
		for goal: int in RSSolo.GOALS[id]:
			goals.append(str(goal))
		var game_row := HBoxContainer.new()
		game_row.add_theme_constant_override("separation", 16)
		_col.add_child(game_row)
		var play := _button(game_row, "▶  " + tr(game["name"]), _start_solo.bind(id))
		play.alignment = HORIZONTAL_ALIGNMENT_LEFT
		play.custom_minimum_size.x = 320
		var stars := RSSolo.stars(id, _solo_slot)
		var star_label := RSUi.label("★".repeat(stars) + "☆".repeat(3 - stars), 26, RSUi.HIGHLIGHT)  # no-i18n
		star_label.custom_minimum_size.x = 96
		game_row.add_child(star_label)
		var targets := RSUi.label(tr("单局分数目标：%s") % " / ".join(goals), 17, RSUi.TEXT_MUTED)
		targets.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		targets.size_flags_horizontal = SIZE_EXPAND_FILL
		game_row.add_child(targets)


func _start_solo(id: String) -> void:
	var connected := false
	for c: RSController in ControllerHub.connected_controllers():
		connected = connected or (c.player == _solo_slot and c.kind != "replay")
	if not connected:
		_message.text = tr("请先连接分配给 P%d 的手柄，可在玩家 / 手柄页分配。") % _solo_slot
		return
	var scene := RSSolo.begin(id, _solo_slot, _solo_difficulty)
	if not scene.is_empty():
		# Challenges use map 1; the normal map selector remains available in the lobby.
		RSPartyGame._last_map[scene.replace(".tscn", ".gd")] = 0
		get_tree().change_scene_to_file(scene)


func _random_party(count: int) -> void:
	var indices := range(RSCatalog.GAMES.size())
	indices.shuffle()
	for i in _checks.size():
		_checks[i].button_pressed = i in indices.slice(0, count)


func _start_party() -> void:
	var selected: Array = []
	for i in _checks.size():
		if _checks[i].button_pressed:
			selected.append(RSCatalog.GAMES[i]["id"])
	var slots: Array = []
	for c: RSController in ControllerHub.connected_controllers():
		if c.player >= 1 and c.player <= 4 and not c.player in slots:
			slots.append(c.player)
	if not RSTournament.begin(selected, slots):
		_message.text = tr("请选择 3–6 个项目，并连接至少一个已分配玩家编号的手柄。")
		return
	get_tree().change_scene_to_file(RSCatalog.find_game(selected[0])["scene"])


func _build_credits() -> void:
	var text := RSUi.label(tr("Regina Sports 原创代码与维护者声明的 AI 原创素材：MIT。\n\nGodot Engine：MIT；Jolt Physics：MIT。\n背景音乐：本项目乐谱与合成，CC0。\nPoly Haven：CC0 天空、材质、模型及树木素材。\nMakeHuman / MPFB：使用官方 CC0 系统素材导出的角色。\n角色素材历史署名：Data Collection AB、Joel Palmius、Jonas Hauquier。\n\n当前音效、手柄模型与涂鸦的 AI 原创声明见 ASSET_PROVENANCE.md。\n逐项作者、素材 ID 与来源见 docs/THIRD_PARTY.md 和素材目录中的 CREDITS.md。\n打包发布时仍需汇总实际捆绑依赖的完整许可。"), 21, RSUi.TEXT_MUTED)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_col.add_child(text)
