class_name RSPauseMenu
extends Control
## In-game pause menu for the party games, driven by any controller (D = back / close,
## B / C = next / previous, A = choose or change the value), the keyboard (Esc, arrows,
## Enter) or the mouse. While it is open the scene tree is paused; the controllers' OLEDs show
## the highlighted item and get their game screen back on close.
##
## Pages: the main page (continue, restart the round, 画面设置 ▸, 声音 ▸, language — reloads
## the scene —, back to the main menu), display (frame rate incl. VRR, quality, upscaling,
## window mode, HDR) and sound (master, music, effects, ambience volume). Settings are
## RSSettings and are saved as soon as they change.
## Accessibility contains cosmetic camera shake and the existing color-safe palette.

signal restart_requested
signal menu_requested
signal tutorial_requested

var game: Node                  ## a party game, or the main menu's settings host
var settings_only := false
var can_restart := true          ## set by the game: restart makes sense right now
var can_tutorial := false

const PAGES := {
	"main": ["resume", "restart", "tutorial", "display", "sound", "accessibility", "language", "menu"],
	"display": ["fps", "quality", "upscale", "window", "hdr", "back"],
	"sound": ["vol_master", "vol_music", "vol_sfx", "vol_ambience", "back"],
	"settings": ["display", "sound", "accessibility", "language", "resume"],
	"accessibility": ["camera_shake", "color_safe", "text_size", "back"],
}
const VALUES := ["fps", "quality", "upscale", "window", "hdr", "language", "color_safe", "camera_shake", "text_size", "vol_master", "vol_music", "vol_sfx", "vol_ambience"]
const VOLUMES := ["vol_master", "vol_music", "vol_sfx", "vol_ambience"]   ## in RSAudio.BUSES order

var _page := "main"
var _rows: Array[Button] = []
var _index := 0
var _saved_ui: Dictionary = {}   ## controller id -> its OLED state before the menu opened
var _col: VBoxContainer
var _title: Label
var _hint: Label
var _normal: StyleBoxFlat
var _focus: StyleBoxFlat


func _init(g: Node, menu_settings: bool = false) -> void:
	game = g
	settings_only = menu_settings
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.01, 0.02, 0.05, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", RSUi.modal_style())
	panel.custom_minimum_size = Vector2(520, 0)
	center.add_child(panel)
	_col = VBoxContainer.new()
	_col.add_theme_constant_override("separation", 10)
	panel.add_child(_col)
	_title = RSUi.label("", 40)
	_title.add_theme_font_override("font", RSUi.font_bold())
	_col.add_child(_title)
	_col.add_child(RSUi.label("Regina Sports" if settings_only else game._game_name(), 17, RSUi.TEXT_MUTED))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 6)
	_col.add_child(gap)
	_normal = RSUi.button_style("normal")
	_focus = RSUi.button_style("focus")
	_hint = RSUi.label(tr("手柄：B / C 上下选，A 确定或切换，D 返回 / 关闭\n键盘：方向键 + 回车，← / → 改设置，Esc 返回 / 关闭"), 15, RSUi.TEXT_MUTED)
	_col.add_child(_hint)
	_show_page(_home_page(), 0)


func _home_page() -> String:
	return "settings" if settings_only else "main"


func is_open() -> bool:
	return visible


func open() -> void:
	if visible:
		return
	visible = true
	game.get_tree().paused = true
	_saved_ui.clear()
	for c: RSController in ControllerHub.connected_controllers():
		_saved_ui[c.id] = c.ui_state.duplicate(true)
	_show_page(_home_page(), 0)
	RSSfx.play(self, "ding", -10.0, 0.9)


func close() -> void:
	if not visible:
		return
	visible = false
	game.get_tree().paused = false
	# Give every controller its game screen back.
	for c: RSController in ControllerHub.connected_controllers():
		if not _saved_ui.has(c.id):
			continue
		var ui := {"clear": true}
		var st: Dictionary = _saved_ui[c.id]
		for key in ["title", "main", "sub", "bar", "legends"]:
			if st.has(key):
				ui[key] = st[key]
		ControllerHub.send_ui(c.id, ui)
	if not settings_only:
		for p: RSPartyGame.Player in game.players.values():
			p.oled_key = ""


func back() -> void:
	## D / Esc: a settings page goes back to the main page, the main page closes the menu.
	if _page == _home_page():
		close()
	else:
		_show_page(_home_page(), (PAGES[_home_page()] as Array).find(_page))
		RSSfx.play(self, "beep", -18.0, 1.2)


func on_button(button: int) -> void:
	## A controller button while the menu is open.
	match button:
		RSController.BTN_A:
			_choose(_index)
		RSController.BTN_B:
			_move(1)
		RSController.BTN_C:
			_move(-1)
		RSController.BTN_D:
			back()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		back()
	elif event.is_action_pressed("ui_right"):
		_change(_index, 1, false)
	elif event.is_action_pressed("ui_left"):
		_change(_index, -1, false)
	else:
		return
	get_viewport().set_input_as_handled()


func _items() -> Array:
	return PAGES[_page]


func _show_page(page: String, focus: int) -> void:
	_page = page
	for b in _rows:
		b.queue_free()
	_rows.clear()
	for i in _items().size():
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 54)
		RSUi.set_text_size(b, 24)
		b.add_theme_stylebox_override("normal", _normal)
		b.add_theme_stylebox_override("hover", _normal)
		b.add_theme_stylebox_override("pressed", _focus)
		b.add_theme_stylebox_override("focus", _focus)
		b.focus_mode = Control.FOCUS_ALL
		b.pressed.connect(_choose.bind(i))
		b.focus_entered.connect(_on_focus.bind(i))
		b.mouse_entered.connect(b.grab_focus)
		_col.add_child(b)
		_rows.append(b)
	_col.move_child(_hint, -1)
	_title.text = {"main": tr("暂停"), "settings": tr("设置"), "display": tr("画面设置"), "sound": tr("声音"), "accessibility": tr("无障碍")}[page]
	_index = clampi(focus, 0, _rows.size() - 1)
	_refresh()
	if visible:
		_rows[_index].grab_focus()


func _move(step: int) -> void:
	var i := _index
	for _n in _rows.size():
		i = posmod(i + step, _rows.size())
		if not _rows[i].disabled:
			break
	_rows[i].grab_focus()
	RSSfx.play(self, "beep", -18.0, 1.4)


func _on_focus(i: int) -> void:
	_index = i
	_send_oled()


func _choose(i: int) -> void:
	match _items()[i]:
		"resume":
			close()
		"restart":
			if can_restart:
				close()
				restart_requested.emit()
		"tutorial":
			if can_tutorial:
				close()
				tutorial_requested.emit()
		"display", "sound", "accessibility":
			_show_page(_items()[i], 0)
			RSSfx.play(self, "beep", -18.0, 1.6)
		"back":
			back()
		"menu":
			game.get_tree().paused = false
			menu_requested.emit()
		_:
			_change(i, 1, true)


func _change(i: int, step: int, wrap: bool) -> void:
	## Step a setting. A (wrap) cycles round; the arrow keys stop at the ends of the volumes.
	var item: String = _items()[i]
	match item:
		"fps":
			RSSettings.fps = posmod(RSSettings.fps + step, RSSettings.FPS.size())
		"quality":
			RSSettings.quality = posmod(RSSettings.quality + step, RSSettings.QUALITY_NAMES.size())
		"window":
			RSSettings.window = posmod(RSSettings.window + step, RSSettings.WINDOW_NAMES.size())
		"upscale":
			RSSettings.upscale = posmod(RSSettings.upscale + step, RSSettings.UPSCALE_NAMES.size())
		"hdr":
			RSSettings.hdr = not RSSettings.hdr
		"color_safe":
			RSSettings.color_safe = not RSSettings.color_safe
		"camera_shake":
			RSSettings.camera_shake = not RSSettings.camera_shake
		"text_size":
			RSSettings.text_size = posmod(RSSettings.text_size + step, RSSettings.TEXT_SCALES.size())
		"language":
			# Every text in the scene was built in the old language: start it again.
			RSSettings.next_language()
			game.get_tree().paused = false
			game.get_tree().reload_current_scene()
			return
		"vol_master", "vol_music", "vol_sfx", "vol_ambience":
			var k := VOLUMES.find(item)
			var v: int = RSSettings.volumes[k] + step
			RSSettings.volumes[k] = posmod(v, RSAudio.STEPS + 1) if wrap else clampi(v, 0, RSAudio.STEPS)
			RSSettings.save()
			RSSettings.apply_volumes()
			RSSfx.play(self, "ding", -12.0, 1.3)
			_refresh()
			return
		_:
			return
	RSSettings.save()
	RSSettings.apply(game.get_tree())
	RSSfx.play(self, "ding", -12.0, 1.3)
	_refresh()


func _label(item: String) -> String:
	match item:
		"resume":
			return tr("◀ 返回") if settings_only else tr("继续游戏")
		"restart":
			return tr("重新开始本局")
		"tutorial":
			return tr("新手教学")
		"display":
			return tr("画面设置　▸")
		"sound":
			return tr("声音　▸")
		"accessibility":
			return tr("无障碍　▸")
		"back":
			return tr("◀ 返回")
		"fps":
			return tr("帧率　　◀ %s ▶") % RSSettings.fps_name()
		"quality":
			return tr("画质　　◀ %s ▶") % RSSettings.quality_name()
		"upscale":
			return tr("超分　　◀ %s ▶") % RSSettings.upscale_name()
		"window":
			return tr("显示　　◀ %s ▶") % RSSettings.window_name()
		"hdr":
			return tr("HDR　　◀ %s ▶") % RSSettings.hdr_name()
		"color_safe":
			return tr("色弱友好配色　◀ %s ▶") % (tr("开") if RSSettings.color_safe else tr("关"))
		"camera_shake":
			return tr("镜头晃动　◀ %s ▶") % (tr("开") if RSSettings.camera_shake else tr("关"))
		"text_size":
			return tr("界面字号　◀ %s ▶") % RSSettings.text_size_name()
		"language":
			return tr("语言 Language　◀ %s ▶") % RSSettings.language_name()
		"vol_master":
			return tr("总音量　◀ %s ▶") % RSSettings.volume_name(0)
		"vol_music":
			return tr("音乐　　◀ %s ▶") % RSSettings.volume_name(1)
		"vol_sfx":
			return tr("音效　　◀ %s ▶") % RSSettings.volume_name(2)
		"vol_ambience":
			return tr("环境声　◀ %s ▶") % RSSettings.volume_name(3)
		_:
			return tr("返回主菜单")


func _oled_label(item: String) -> Array:
	match item:
		"resume":
			return ["RESUME", ""]
		"restart":
			return ["RESTART", ""]
		"tutorial":
			return ["TUTORIAL", ""]
		"display":
			return ["DISPLAY", ">"]
		"sound":
			return ["SOUND", ">"]
		"accessibility":
			return ["ACCESS", ">"]
		"back":
			return ["BACK", ""]
		"fps":
			return ["FPS", RSSettings.fps_oled()]
		"quality":
			return ["QUALITY", ["LOW", "MID", "HIGH", "ULTRA"][RSSettings.quality]]
		"upscale":
			return ["UPSCALE", ["NATIVE", "FSR Q", "FSR B", "FSR P", "FSR UP"][RSSettings.upscale]]
		"window":
			return ["WINDOW", ["WINDOW", "FULL", "EXCL"][RSSettings.window]]
		"hdr":
			return ["HDR", RSSettings.hdr_oled()]
		"color_safe":
			return ["COLORS", "ACCESSIBLE" if RSSettings.color_safe else "DEFAULT"]
		"camera_shake":
			return ["CAM SHAKE", "ON" if RSSettings.camera_shake else "OFF"]
		"text_size":
			return ["TEXT SIZE", "125%" if RSSettings.text_size == 1 else "100%"]
		"language":
			return ["LANGUAGE", ["CHINESE", "ENGLISH"][RSSettings.language]]
		"vol_master", "vol_music", "vol_sfx", "vol_ambience":
			var k := VOLUMES.find(item)
			var v: int = RSSettings.volumes[k]
			return [["VOLUME", "MUSIC", "EFFECTS", "AMBIENCE"][k], "MUTE" if v <= 0 else "%d%%" % (v * 100 / RSAudio.STEPS)]
		_:
			return ["MENU", ""]


func _refresh() -> void:
	if _rows.is_empty():
		return
	for i in _rows.size():
		var item: String = _items()[i]
		_rows[i].text = "  " + _label(item)
		_rows[i].disabled = (item == "restart" and not can_restart) or (item == "tutorial" and not can_tutorial)
	_send_oled()


func _send_oled() -> void:
	if not visible or _rows.is_empty():
		return
	var item: String = _items()[_index]
	var o := _oled_label(item)
	for c: RSController in ControllerHub.connected_controllers():
		ControllerHub.send_ui(c.id, {"clear": true, "title": "SETTINGS" if settings_only else "PAUSED", "main": o[0], "sub": o[1],
			"legends": ["CHANGE" if item in VALUES else "OK", "NEXT", "PREV", "BACK" if _page != _home_page() else "CLOSE"]})
