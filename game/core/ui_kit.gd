class_name RSUi
extends RefCounted
## Shared look for the 2D UI: a CJK-capable system font, the colour tokens and one Theme that
## styles every standard control (buttons, lists, check boxes, text fields, scroll bars), so
## screens get the same look by setting theme = RSUi.theme() instead of styling each widget.

const PANEL_BG := Color(0.06, 0.08, 0.12, 0.92)
const TEXT_MUTED := Color(0.6, 0.64, 0.72)
const TEXT := Color("f1f5f9")
const ACCENT := Color("38bdf8")                   ## focus ring, selection, primary actions
const HIGHLIGHT := Color("fbbf24")                ## stars, map line, things to act on
const GOOD := Color("4ade80")
const BAD := Color("f87171")
const STROKE := Color(1, 1, 1, 0.09)
const SURFACE := Color(0.055, 0.07, 0.105, 0.97)  ## modal panels
const SCRIM := Color(0.01, 0.02, 0.05, 0.8)       ## dims what is behind a modal
const RADIUS := 12                                ## controls; panels use 22

static var _font: SystemFont
static var _font_tags: RegEx


static func font() -> Font:
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", "Source Han Sans SC", "sans-serif"])
	return _font


static func theme(font_size: int = 18) -> Theme:
	var t := Theme.new()
	_style(t)
	t.default_font = font()
	t.set_meta("rs_text_base", font_size)
	t.default_font_size = text_size(font_size)
	return t


static func text_size(base: float) -> int:
	return maxi(8, roundi(base * RSSettings.TEXT_SCALES[RSSettings.text_size]))


static func set_text_size(control: Control, base: int, key: StringName = &"font_size") -> void:
	control.set_meta("rs_text_" + key, base)
	control.add_theme_font_size_override(key, text_size(base))


static func set_rich_text(control: RichTextLabel, source: String) -> void:
	## Rebuild numeric BBCode sizes from the original, never from already scaled text.
	control.set_meta("rs_text_source", source)
	if _font_tags == null:
		_font_tags = RegEx.new()
		_font_tags.compile("\\[font_size=([0-9]+)\\]")
	var result := source
	var tags := _font_tags.search_all(source)
	tags.reverse()
	for tag: RegExMatch in tags:
		result = result.substr(0, tag.get_start()) + "[font_size=%d]" % text_size(int(tag.get_string(1))) + result.substr(tag.get_end())
	control.text = result


static func apply_text_sizes(root: Node) -> void:
	## Called only when settings are applied. New controls already use the current scale.
	if root is Control:
		var control := root as Control
		for key: StringName in [&"font_size", &"normal_font_size"]:
			if control.has_meta("rs_text_" + key):
				control.add_theme_font_size_override(key, text_size(control.get_meta("rs_text_" + key)))
		if control.theme != null and control.theme.has_meta("rs_text_base"):
			control.theme.default_font_size = text_size(control.theme.get_meta("rs_text_base"))
		if control is RichTextLabel and control.has_meta("rs_text_source"):
			set_rich_text(control, control.get_meta("rs_text_source"))
	for child: Node in root.get_children():
		apply_text_sizes(child)


static func fit_text_size(text: String, base: float, width: float, baseline: float, height: float) -> int:
	## Single-line HUD text: reserve an edge margin and respect the actual font metrics.
	var fs := text_size(base)
	var f := font()
	var width_at_size := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var fit := minf(1.0, width / maxf(width_at_size, 1.0))
	fit = minf(fit, baseline / maxf(f.get_ascent(fs), 1.0))
	fit = minf(fit, (height - baseline) / maxf(f.get_descent(fs), 1.0))
	fs = maxi(8, floori(fs * fit))
	# Font hinting rounds glyph advances; usually at most one final pixel is needed.
	while fs > 8 and (f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > width
			or f.get_ascent(fs) > baseline or f.get_descent(fs) > height - baseline):
		fs -= 1
	return fs


static func panel_style(radius: int = 16, bg: Color = PANEL_BG) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(18)
	sb.border_color = Color(1, 1, 1, 0.08)
	sb.set_border_width_all(1)
	return sb


static func label(text: String, size: int, color: Color = Color.WHITE, wrap: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	set_text_size(l, size)
	l.add_theme_color_override("font_color", color)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


static func qr_texture(rows: PackedStringArray) -> ImageTexture:
	## Hub QR matrix ("1" = dark) -> texture with a quiet zone, scaled up for nearest filtering.
	var n := rows.size()
	var img := Image.create_empty(n + 4, n + 4, false, Image.FORMAT_RGB8)
	img.fill(Color.WHITE)
	for y in n:
		var row: String = rows[y]
		for x in mini(n, row.length()):
			if row[x] == "1":
				img.set_pixel(x + 2, y + 2, Color.BLACK)
	img.resize((n + 4) * 4, (n + 4) * 4, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(img)


# ------------------------------------------------------------------------ styling ----

static var _bold: SystemFont
static var _check_icons: Dictionary = {}


static func font_bold() -> Font:
	## Titles and the logo; the same families as font().
	if _bold == null:
		_bold = font().duplicate() as SystemFont
		_bold.font_weight = 700
	return _bold


static func modal_style() -> StyleBoxFlat:
	## A full panel over the game or menu: opaque, roomy, lifted by a soft shadow.
	var sb := panel_style(22, SURFACE)
	sb.set_content_margin_all(28)
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 28
	sb.shadow_offset = Vector2(0, 8)
	return sb


static func card_style() -> StyleBoxFlat:
	## A group inside a panel (a map, a player, a game's records).
	var sb := panel_style(RADIUS + 2, Color(1, 1, 1, 0.045))
	sb.set_content_margin_all(16)
	return sb


static func chip_style(tint: Color) -> StyleBoxFlat:
	## A small rounded tag behind a status line, tinted by what it says.
	var sb := panel_style(RADIUS, Color(tint, 0.14))
	sb.border_color = Color(tint, 0.35)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	return sb


static func button_style(state: String) -> StyleBoxFlat:
	## "normal", "hover", "pressed", "disabled" or "focus". Godot draws focus over the others, so
	## it is a tint plus an accent ring whose thicker leading edge marks the selection.
	var bg: Color = {"normal": Color(0.09, 0.12, 0.18, 0.72), "hover": Color(0.13, 0.17, 0.25, 0.9),
		"pressed": Color(ACCENT, 0.3), "disabled": Color(0.09, 0.12, 0.18, 0.35), "focus": Color(ACCENT, 0.14)}[state]
	var sb := panel_style(RADIUS, bg)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	if state == "focus":
		sb.border_color = ACCENT
		sb.set_border_width_all(2)
		sb.border_width_left = 6
	elif state == "disabled":
		sb.border_color = Color(1, 1, 1, 0.04)
	return sb


static func _style(t: Theme) -> void:
	for type: StringName in [&"Button", &"OptionButton", &"MenuButton", &"CheckBox"]:
		for state: String in ["normal", "hover", "pressed", "disabled", "focus"]:
			t.set_stylebox(state, type, button_style(state))
		t.set_stylebox(&"hover_pressed", type, button_style("hover"))
		t.set_color(&"font_color", type, TEXT)
		for key: StringName in [&"font_hover_color", &"font_focus_color", &"font_pressed_color", &"font_hover_pressed_color"]:
			t.set_color(key, type, Color.WHITE)
		t.set_color(&"font_disabled_color", type, Color(TEXT_MUTED, 0.5))
		t.set_constant(&"h_separation", type, 10)
	t.set_icon(&"checked", &"CheckBox", _check_icon(true))
	t.set_icon(&"unchecked", &"CheckBox", _check_icon(false))
	t.set_icon(&"checked_disabled", &"CheckBox", _check_icon(true))
	t.set_icon(&"unchecked_disabled", &"CheckBox", _check_icon(false))

	# The one call to action on a page (start the party, play).
	t.set_type_variation(&"RSPrimary", &"Button")
	for state: String in ["normal", "hover", "pressed", "focus"]:
		var sb := button_style("normal")
		sb.bg_color = {"normal": ACCENT.darkened(0.08), "hover": ACCENT, "pressed": ACCENT.darkened(0.25), "focus": Color(0, 0, 0, 0)}[state]
		if state == "focus":
			sb.border_color = Color.WHITE
			sb.set_border_width_all(3)
		t.set_stylebox(state, &"RSPrimary", sb)
	for key: StringName in [&"font_color", &"font_hover_color", &"font_focus_color", &"font_pressed_color", &"font_hover_pressed_color"]:
		t.set_color(key, &"RSPrimary", Color("06121f"))

	var popup := panel_style(RADIUS, SURFACE)
	popup.set_content_margin_all(8)
	t.set_stylebox(&"panel", &"PopupMenu", popup)
	var popup_hover := panel_style(RADIUS - 4, Color(ACCENT, 0.22))
	popup_hover.set_border_width_all(0)
	t.set_stylebox(&"hover", &"PopupMenu", popup_hover)
	t.set_color(&"font_color", &"PopupMenu", TEXT)
	t.set_color(&"font_hover_color", &"PopupMenu", Color.WHITE)
	t.set_constant(&"v_separation", &"PopupMenu", 10)
	t.set_constant(&"item_start_padding", &"PopupMenu", 12)
	t.set_constant(&"item_end_padding", &"PopupMenu", 12)

	var field := panel_style(RADIUS - 2, Color(0, 0, 0, 0.28))
	field.border_color = STROKE
	field.content_margin_left = 14
	field.content_margin_right = 14
	field.content_margin_top = 8
	field.content_margin_bottom = 8
	t.set_stylebox(&"normal", &"LineEdit", field)
	var field_focus := field.duplicate() as StyleBoxFlat
	field_focus.bg_color = Color(0, 0, 0, 0)
	field_focus.border_color = ACCENT
	field_focus.set_border_width_all(2)
	t.set_stylebox(&"focus", &"LineEdit", field_focus)
	t.set_color(&"font_color", &"LineEdit", TEXT)
	t.set_color(&"caret_color", &"LineEdit", ACCENT)
	t.set_color(&"selection_color", &"LineEdit", Color(ACCENT, 0.35))
	t.set_color(&"font_placeholder_color", &"LineEdit", Color(TEXT_MUTED, 0.7))

	var line := StyleBoxLine.new()
	line.color = STROKE
	line.thickness = 1
	t.set_stylebox(&"separator", &"HSeparator", line)
	t.set_constant(&"separation", &"HSeparator", 14)

	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.03)
	track.set_corner_radius_all(4)
	track.content_margin_left = 4
	track.content_margin_right = 4
	t.set_stylebox(&"scroll", &"VScrollBar", track)
	for key: StringName in [&"grabber", &"grabber_highlight", &"grabber_pressed"]:
		var grab := StyleBoxFlat.new()
		grab.bg_color = Color(1, 1, 1, 0.2) if key == &"grabber" else Color(ACCENT, 0.7)
		grab.set_corner_radius_all(4)
		t.set_stylebox(key, &"VScrollBar", grab)

	t.set_stylebox(&"panel", &"PanelContainer", panel_style())
	t.set_color(&"font_color", &"Label", TEXT)
	t.set_color(&"default_color", &"RichTextLabel", TEXT)


static func _check_icon(on: bool) -> ImageTexture:
	## A 26 px rounded box, filled with a tick when on; distance fields keep the edges smooth.
	if _check_icons.has(on):
		return _check_icons[on]
	const N := 26
	const R := 6.0
	var half := Vector2(N, N) * 0.5
	var tick: Array[Vector2] = [Vector2(7, 13.5), Vector2(11, 17.5), Vector2(19, 9)]
	var img := Image.create_empty(N, N, false, Image.FORMAT_RGBA8)
	for y in N:
		for x in N:
			var p := Vector2(x + 0.5, y + 0.5)
			var q := (p - half).abs() - (half - Vector2(2.0 + R, 2.0 + R))
			var box := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - R
			var c: Color
			if on:
				c = Color(ACCENT, clampf(0.5 - box, 0.0, 1.0))
				var d := minf(Geometry2D.get_closest_point_to_segment(p, tick[0], tick[1]).distance_to(p),
					Geometry2D.get_closest_point_to_segment(p, tick[1], tick[2]).distance_to(p))
				c = Color(c.lerp(Color("06121f"), clampf(2.1 - d, 0.0, 1.0)), c.a)
			else:
				c = Color(TEXT_MUTED, clampf(1.0 - absf(box + 0.75), 0.0, 1.0) * 0.9)
			img.set_pixel(x, y, c)
	_check_icons[on] = ImageTexture.create_from_image(img)
	return _check_icons[on]
