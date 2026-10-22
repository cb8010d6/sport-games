class_name RSPartyUi
extends Control
## The panels over a party game's views (part of RSPartyGame): the lobby (how to play, map
## card, who is ready, phone QR code), the ranked results, and the pause menu. RSPartyGame runs
## the rounds and says what to show; its hooks (_game_name, _how_to_play, _lobby_extra, _maps)
## fill the lobby.

var game: RSPartyGame
var pause: RSPauseMenu
var lobby_panel: Control
var results_panel: Control

var _lobby_players: RichTextLabel
var _qr_box: Control
var _qr_rect: TextureRect
var _qr_url: Label
var _results_text: RichTextLabel
var _map_title: Label
var _map_line: Label
var _map_desc: Label
var _results_title: Label
var _results_hint: Label
var _results_col: VBoxContainer
var _tutorial_panel: Control
var _tutorial_grid: GridContainer
var _tutorial_cards: Dictionary = {}
var _tutorial_roster := ""


func _init(owner_game: RSPartyGame) -> void:
	game = owner_game
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE


func _ready() -> void:
	# Built once in the tree, so the games' _lobby_extra() hooks see a live panel.
	_build_lobby()
	_build_results()
	_build_tutorials()
	pause = RSPauseMenu.new(game)
	pause.restart_requested.connect(game.restart_round)
	pause.menu_requested.connect(game.go_menu)
	pause.tutorial_requested.connect(game.review_tutorials)
	add_child(pause)


# -------------------------------------------------------------------------- lobby ----

func show_lobby() -> void:
	lobby_panel.visible = true
	results_panel.visible = false
	_tutorial_panel.visible = false


func update_lobby() -> void:
	## Who has joined and who is ready (called every lobby frame; only redraws on change).
	var lines := PackedStringArray()
	for p: RSPartyGame.Player in game.ordered():
		var state := tr("[color=#22c55e]✓ 已准备[/color]") if p.ready else tr("[color=#9aa3b5]按 A 准备[/color]")
		var lesson := game.tutorial_for(p)
		if lesson != null:
			state = RSProfiles.bbcode(lesson.status())
		lines.append("[color=#%s][b]P%d[/b][/color]   %s   %s" % [game.color_of(p).to_html(false), p.c.player, RSProfiles.bbcode(game.name_of(p)), state])
	if lines.is_empty():
		lines.append(tr("[color=#9aa3b5]还没有手柄。\n先运行 hub/run_hub.bat，然后打开 Regina，或用手机扫右边的二维码。[/color]"))
	if not game.demo and not ControllerHub.is_hub_connected():
		lines.append(tr("[color=#f87171]● 未连接 hub —— 请运行 hub/run_hub.bat[/color]"))
	if RSTournament.active():
		lines.append(tr("大赛总积分 · %d / %d") % [RSTournament.index + 1, RSTournament.games.size()])
	var text := "\n".join(lines)
	if _lobby_players.text != text:
		_lobby_players.text = text
	_update_tutorials()


func _build_tutorials() -> void:
	var layout := _centered_panel(980)
	_tutorial_panel = layout[0]
	_tutorial_panel.visible = false
	var col: VBoxContainer = layout[1]
	col.add_child(RSUi.label(tr("新手教学"), 36))
	col.add_child(RSUi.label(tr("先看手柄示范，再完成提示动作。教学完成后回到舒适握姿，按 A 准备。"), 17, RSUi.TEXT_MUTED))
	_tutorial_grid = GridContainer.new()
	_tutorial_grid.columns = 2
	_tutorial_grid.add_theme_constant_override("h_separation", 14)
	_tutorial_grid.add_theme_constant_override("v_separation", 14)
	col.add_child(_tutorial_grid)
	col.add_child(RSUi.label(tr("C 返回菜单　　D / Esc 暂停　　断线后重连可重新练习"), 15, RSUi.TEXT_MUTED))


func _update_tutorials() -> void:
	var active := game.tutorials_active()
	_tutorial_panel.visible = active
	lobby_panel.visible = not active
	if not active:
		return
	var signature := ""
	for p: RSPartyGame.Player in game.ordered():
		signature += "%d;" % p.c.id
	if signature != _tutorial_roster:
		_tutorial_roster = signature
		for child in _tutorial_grid.get_children():
			_tutorial_grid.remove_child(child)
			child.queue_free()
		_tutorial_cards.clear()
		for p: RSPartyGame.Player in game.ordered():
			var card := PanelContainer.new()
			card.custom_minimum_size.x = 450
			card.add_theme_stylebox_override("panel", RSUi.panel_style(14, Color("182334")))
			_tutorial_grid.add_child(card)
			var col := VBoxContainer.new()
			card.add_child(col)
			var title := RSUi.label("", 22, game.color_of(p))
			title.clip_text = true
			col.add_child(title)
			var cue := RSTutorial.Demo.new()
			col.add_child(cue)
			var hint := RSUi.label("", 19)
			hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			hint.custom_minimum_size = Vector2(410, 58)
			col.add_child(hint)
			_tutorial_cards[p.c.id] = {"title": title, "cue": cue, "hint": hint}
	for p: RSPartyGame.Player in game.ordered():
		var card: Dictionary = _tutorial_cards[p.c.id]
		var lesson := game.tutorial_for(p)
		card["title"].text = "P%d · %s" % [p.c.player, game.name_of(p)]
		card["cue"].lesson = lesson
		card["hint"].text = lesson.status() if lesson != null else tr("教学完成，回到舒适握姿后按 A 准备")


func set_qr(url: String, rows: PackedStringArray) -> void:
	if rows.is_empty():
		return
	_qr_rect.texture = RSUi.qr_texture(rows)
	_qr_url.text = url
	_qr_box.visible = true


func has_map_card() -> bool:
	return _map_title != null


func set_map_card(title: String, line: String, desc: String) -> void:
	_map_title.text = title
	_map_line.text = line
	_map_desc.text = desc


# ------------------------------------------------------------------------ results ----

func set_results(lines: PackedStringArray, show_now: bool) -> void:
	_results_text.text = "\n".join(lines)
	results_panel.visible = show_now


func results_on_right(on: bool) -> void:
	## With a podium framed on the left half, the results move to the right one.
	results_panel.anchor_left = 0.5 if on else 0.0


func show_tournament_podium(rows: Array) -> void:
	results_on_right(false)
	_results_title.text = tr("大赛总领奖台")
	_results_text.visible = false
	_results_hint.text = tr("A / C 返回主菜单")
	var podium := HBoxContainer.new()
	podium.alignment = BoxContainer.ALIGNMENT_CENTER
	podium.add_theme_constant_override("separation", 14)
	_results_col.add_child(podium)
	_results_col.move_child(podium, _results_hint.get_index())
	for i: int in [1, 0, 2, 3]:
		if i >= rows.size():
			continue
		var row: Dictionary = rows[i]
		var col := VBoxContainer.new()
		col.custom_minimum_size = Vector2(160, 300)
		col.alignment = BoxContainer.ALIGNMENT_END
		podium.add_child(col)
		var name_label := RSUi.label(str(row["name"]), 22)
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(name_label)
		var block := PanelContainer.new()
		block.custom_minimum_size.y = [180, 130, 95, 65][i]
		block.add_theme_stylebox_override("panel", RSUi.panel_style(12, RSProfiles.player_color(row["slot"]).darkened(0.3)))
		col.add_child(block)
		var rank := 1
		for j in i:
			if rows[j]["points"] > row["points"]:
				rank += 1
		var label := RSUi.label("#%d · P%d\n%d" % [rank, row["slot"], row["points"]], 30)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		block.add_child(label)


# -------------------------------------------------------------------------- build ----

func _build_lobby() -> void:
	var lobby := _centered_panel(820)
	lobby_panel = lobby[0]
	var col: VBoxContainer = lobby[1]
	col.add_child(RSUi.label(game._game_name(), 40))
	var how := RSUi.label(game._how_to_play(), 17, RSUi.TEXT_MUTED)
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART     # English runs longer than Chinese
	col.add_child(how)
	if game._maps().size() > 1:
		_build_map_card(col)
	game._lobby_extra(col)
	var tutorial := Button.new()
	tutorial.text = tr("重看教学（T）")
	tutorial.pressed.connect(game.review_tutorials)
	col.add_child(tutorial)
	col.add_child(HSeparator.new())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	col.add_child(row)
	_lobby_players = RichTextLabel.new()
	_lobby_players.bbcode_enabled = true
	_lobby_players.fit_content = true
	_lobby_players.scroll_active = false
	_lobby_players.size_flags_horizontal = SIZE_EXPAND_FILL
	_lobby_players.add_theme_font_size_override("normal_font_size", 22)
	row.add_child(_lobby_players)
	_qr_box = VBoxContainer.new()
	_qr_box.visible = false
	row.add_child(_qr_box)
	_qr_rect = TextureRect.new()
	_qr_rect.custom_minimum_size = Vector2(150, 150)
	_qr_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_qr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_qr_box.add_child(_qr_rect)
	_qr_box.add_child(RSUi.label(tr("手机扫码加入"), 14, RSUi.TEXT_MUTED))
	_qr_url = RSUi.label("", 11, RSUi.TEXT_MUTED)
	_qr_box.add_child(_qr_url)
	col.add_child(RSUi.label(tr("A 准备 / 取消　　C 返回菜单　　D / Esc 暂停菜单　　所有人准备好后自动开始"), 15, RSUi.TEXT_MUTED))


func _build_map_card(col: VBoxContainer) -> void:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", RSUi.panel_style(14, Color(0.12, 0.15, 0.22, 0.95)))
	col.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	card.add_child(v)
	_map_title = RSUi.label("", 28)
	v.add_child(_map_title)
	_map_line = RSUi.label("", 16, Color(1.0, 0.84, 0.3))
	v.add_child(_map_line)
	_map_desc = RSUi.label("", 16, RSUi.TEXT_MUTED)
	_map_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_map_desc)
	v.add_child(RSUi.label(tr("B 或 ← / → 换地图"), 14, RSUi.TEXT_MUTED))


func _build_results() -> void:
	var results := _centered_panel(640)
	results_panel = results[0]
	var col: VBoxContainer = results[1]
	_results_col = col
	_results_title = RSUi.label(tr("成绩"), 40)
	col.add_child(_results_title)
	_results_text = RichTextLabel.new()
	_results_text.bbcode_enabled = true
	_results_text.fit_content = true
	_results_text.scroll_active = false
	_results_text.add_theme_font_size_override("normal_font_size", 18)
	_results_text.add_theme_constant_override("line_separation", 6)
	col.add_child(_results_text)
	_results_hint = RSUi.label(tr("A 继续　　C 返回菜单　　D / Esc 暂停菜单") if RSTournament.active() else tr("A 再来一局　　C 返回菜单　　D / Esc 暂停菜单"), 15, RSUi.TEXT_MUTED)
	col.add_child(_results_hint)


func _centered_panel(width: float) -> Array:
	## [the full-screen centring container, the panel's column]
	var center := CenterContainer.new()
	center.set_anchors_preset(PRESET_FULL_RECT)
	center.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", RSUi.panel_style(20))
	panel.custom_minimum_size = Vector2(width, 0)
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	panel.add_child(col)
	return [center, col]
