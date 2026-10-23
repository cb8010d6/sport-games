class_name RSUi
extends RefCounted
## Shared look for the 2D UI, in a sports-broadcast style: the bundled fonts (Noto Sans SC for
## text, Barlow Condensed for titles and numbers), the colour tokens and one Theme that styles
## every standard control (buttons, lists, check boxes, text fields, scroll bars), so screens get
## the same look by setting theme = RSUi.theme() instead of styling each widget.

const PANEL_BG := Color(0.03, 0.045, 0.07, 0.9)
const TEXT_MUTED := Color(0.64, 0.68, 0.76)
const TEXT := Color("f4f6fa")
const INK := Color("0a0d14")                      ## text on ACCENT
const ACCENT := Color("ffd60a")                   ## the one hot colour: selection, primary actions
const HIGHLIGHT := Color("ffb547")                ## stars, map line, things to act on
const GOOD := Color("34d399")
const BAD := Color("ff6b6b")
const STROKE := Color(1, 1, 1, 0.1)
const SURFACE := Color(0.03, 0.04, 0.065, 0.96)   ## modal panels
const SCRIM := Color(0.01, 0.015, 0.03, 0.82)     ## dims what is behind a modal
const RADIUS := 2                                 ## nearly square corners everywhere
const SKEW := 0.22                                ## lean of selection bars and HUD plates

const _FONT_DIR := "res://assets/fonts/"

static var _font: FontVariation
static var _font_tags: RegEx
static var _fonts: Dictionary = {}


static func font() -> Font:
	## Body text: Noto Sans SC Medium, then the system CJK font for rare characters outside the
	## bundled subset.
	if _font == null:
		_font = _noto(500)
	return _font


static func _noto(weight: int) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = load(_FONT_DIR + "NotoSansSC-RS.ttf")
	fv.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
	var system := SystemFont.new()
	system.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", "Source Han Sans SC", "sans-serif"])
	system.font_weight = weight
	fv.fallbacks = [system]
	return fv


static func _barlow(file: String, cjk_weight: int) -> Font:
	## Barlow has no CJK glyphs, so Chinese in the same string falls back to Noto at a weight
	## that matches.
	if not _fonts.has(file):
		var f := (load(_FONT_DIR + file) as FontFile).duplicate() as FontFile
		f.fallbacks = [_noto(cjk_weight)]
		_fonts[file] = f
	return _fonts[file]


static func font_numeric() -> Font:
	## Scores, timers and stats: Barlow Condensed Bold Italic, tabular-looking condensed digits.
	return _barlow("BarlowCondensed-BoldItalic.ttf", 700)


static func font_label() -> Font:
	## Small upright tags ("SKATE", "P1"), letter-spaced like broadcast captions.
	if not _fonts.has("label"):
		var fv := FontVariation.new()
		fv.base_font = _barlow("BarlowCondensed-SemiBold.ttf", 700)
		fv.spacing_glyph = 3
		_fonts["label"] = fv
	return _fonts["label"]


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


static func fit_text_size(text: String, base: float, width: float, baseline: float, height: float, f: Font = null) -> int:
	## Single-line HUD text: reserve an edge margin and respect the actual font metrics.
	var fs := text_size(base)
	if f == null:
		f = font()
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


static func panel_style(radius: int = RADIUS, bg: Color = PANEL_BG) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(18)
	sb.border_color = STROKE
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

static var _check_icons: Dictionary = {}


static func font_bold() -> Font:
	## Titles and the logo: Barlow Condensed ExtraBold Italic for Latin, Noto Sans SC Black for
	## Chinese.
	return _barlow("BarlowCondensed-ExtraBoldItalic.ttf", 900)


static func font_strong() -> Font:
	## Emphasis inside body text (names, sport titles in lists): Noto Sans SC Bold.
	if not _fonts.has("noto700"):
		_fonts["noto700"] = _noto(700)
	return _fonts["noto700"]


static func modal_style() -> StyleBoxFlat:
	## A full panel over the game or menu: opaque, square, an accent rule along the top.
	var sb := panel_style(0, SURFACE)
	sb.set_content_margin_all(32)
	sb.set_border_width_all(0)
	sb.border_width_top = 4
	sb.border_color = ACCENT
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_size = 24
	sb.shadow_offset = Vector2(0, 10)
	return sb


static func hud_style(radius: float = RADIUS) -> StyleBoxFlat:
	## Solid plate behind HUD text drawn over the game: dark enough to read on snow, no outline.
	var sb := panel_style(int(radius), Color(0.02, 0.03, 0.05, 0.8))
	sb.set_border_width_all(0)
	sb.set_content_margin_all(0)
	return sb


static func select_style(color: Color = ACCENT) -> StyleBoxFlat:
	## The leaning bar behind the selected row; skewed boxes reach SKEW * height / 2 past each
	## side, so rows keep that much free space.
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.skew = Vector2(SKEW, 0)
	sb.anti_aliasing_size = 0.8
	return sb


static func ease_out(t: float) -> float:
	## 0..1 -> 0..1, fast start and soft landing (cubic); clamps outside the range.
	var u := 1.0 - clampf(t, 0.0, 1.0)
	return 1.0 - u * u * u


static func pop_in(control: Control, from_scale: float = 0.96) -> void:
	## Short fade and grow when a panel appears. Bound to the control, so it also runs while
	## the tree is paused if the control does (the pause menu).
	control.modulate.a = 0.0
	var tween := control.create_tween().set_parallel()
	tween.tween_property(control, "modulate:a", 1.0, 0.16)
	tween.tween_method(func(s: float) -> void:
		control.pivot_offset = control.size * 0.5
		control.scale = Vector2(s, s), from_scale, 1.0, 0.2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


static func card_style() -> StyleBoxFlat:
	## A group inside a panel (a map, a player, a game's records): a flat lighter block.
	var sb := panel_style(0, Color(1, 1, 1, 0.05))
	sb.set_content_margin_all(16)
	return sb


static func chip_style(tint: Color) -> StyleBoxFlat:
	## A small square tag behind a status line: dark, with a stripe in the colour of what it says.
	var sb := panel_style(0, Color(0.02, 0.03, 0.05, 0.78))
	sb.border_color = tint
	sb.border_width_left = 4
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	return sb


static func button_style(state: String) -> StyleBoxFlat:
	## "normal", "hover", "pressed", "disabled" or "focus". Hover and focus are the same solid
	## accent bar (dark text, see _style), so a pointer and a controller select alike; Godot draws
	## focus over the state box and under the text.
	var sb: StyleBoxFlat
	if state in ["hover", "focus", "pressed"]:
		sb = select_style(ACCENT.darkened(0.12) if state == "pressed" else ACCENT)
	else:
		sb = panel_style(0, Color(1, 1, 1, 0.025 if state == "disabled" else 0.06))
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


static func _style(t: Theme) -> void:
	for type: StringName in [&"Button", &"OptionButton", &"MenuButton", &"CheckBox"]:
		for state: String in ["normal", "hover", "pressed", "disabled", "focus"]:
			t.set_stylebox(state, type, button_style(state))
		t.set_stylebox(&"hover_pressed", type, button_style("hover"))
		t.set_color(&"font_color", type, TEXT)
		for key: StringName in [&"font_hover_color", &"font_focus_color", &"font_pressed_color", &"font_hover_pressed_color"]:
			t.set_color(key, type, INK)
		t.set_color(&"font_disabled_color", type, Color(TEXT_MUTED, 0.5))
		for key: StringName in [&"icon_hover_color", &"icon_focus_color", &"icon_pressed_color"]:
			t.set_color(key, type, INK)
		t.set_constant(&"h_separation", type, 10)
	# A check box shows its state with the tick, and Godot picks its text colour from the toggle
	# state rather than focus, so it is selected with a light tint and an accent edge instead of
	# the solid bar, and keeps light text throughout.
	var check_focus := panel_style(0, Color(1, 1, 1, 0.14))
	check_focus.border_color = ACCENT
	check_focus.border_width_left = 5
	for state: String in ["hover", "hover_pressed", "focus"]:
		var sb := check_focus.duplicate() as StyleBoxFlat
		sb.content_margin_left = 20
		sb.content_margin_right = 20
		sb.content_margin_top = 8
		sb.content_margin_bottom = 8
		t.set_stylebox(state, &"CheckBox", sb)
	t.set_stylebox(&"pressed", &"CheckBox", button_style("normal"))
	for key: StringName in [&"font_hover_color", &"font_focus_color", &"font_pressed_color", &"font_hover_pressed_color"]:
		t.set_color(key, &"CheckBox", Color.WHITE)
	t.set_icon(&"checked", &"CheckBox", _check_icon(true))
	t.set_icon(&"unchecked", &"CheckBox", _check_icon(false))
	t.set_icon(&"checked_disabled", &"CheckBox", _check_icon(true))
	t.set_icon(&"unchecked_disabled", &"CheckBox", _check_icon(false))

	# The one call to action on a page (start the party, play).
	t.set_type_variation(&"RSPrimary", &"Button")
	# Always the accent bar; focus adds a white edge so the selection still shows on it.
	for state: String in ["normal", "hover", "pressed", "focus"]:
		var sb := button_style("hover")
		sb.bg_color = {"normal": ACCENT, "hover": ACCENT.lightened(0.2), "pressed": ACCENT.darkened(0.15), "focus": Color(0, 0, 0, 0)}[state]
		if state == "focus":
			sb.border_color = Color.WHITE
			sb.set_border_width_all(3)
			sb.set_expand_margin_all(3)
		t.set_stylebox(state, &"RSPrimary", sb)
	for key: StringName in [&"font_color", &"font_hover_color", &"font_focus_color", &"font_pressed_color", &"font_hover_pressed_color"]:
		t.set_color(key, &"RSPrimary", INK)
	t.set_font(&"font", &"RSPrimary", font_strong())

	var popup := panel_style(0, SURFACE)
	popup.set_content_margin_all(6)
	popup.border_width_top = 3
	popup.border_color = ACCENT
	t.set_stylebox(&"panel", &"PopupMenu", popup)
	t.set_stylebox(&"hover", &"PopupMenu", select_style())
	t.set_color(&"font_color", &"PopupMenu", TEXT)
	t.set_color(&"font_hover_color", &"PopupMenu", INK)
	t.set_constant(&"v_separation", &"PopupMenu", 10)
	t.set_constant(&"item_start_padding", &"PopupMenu", 12)
	t.set_constant(&"item_end_padding", &"PopupMenu", 12)

	var field := panel_style(0, Color(0, 0, 0, 0.35))
	field.border_color = Color(1, 1, 1, 0.25)
	field.border_width_bottom = 2
	field.content_margin_left = 14
	field.content_margin_right = 14
	field.content_margin_top = 8
	field.content_margin_bottom = 8
	t.set_stylebox(&"normal", &"LineEdit", field)
	var field_focus := field.duplicate() as StyleBoxFlat
	field_focus.border_color = ACCENT
	field_focus.border_width_bottom = 3
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
	track.set_corner_radius_all(0)
	track.content_margin_left = 4
	track.content_margin_right = 4
	t.set_stylebox(&"scroll", &"VScrollBar", track)
	for key: StringName in [&"grabber", &"grabber_highlight", &"grabber_pressed"]:
		var grab := StyleBoxFlat.new()
		grab.bg_color = Color(1, 1, 1, 0.25) if key == &"grabber" else ACCENT
		t.set_stylebox(key, &"VScrollBar", grab)

	t.set_stylebox(&"panel", &"PanelContainer", panel_style())
	t.set_color(&"font_color", &"Label", TEXT)
	t.set_font(&"bold_font", &"RichTextLabel", font_strong())
	t.set_color(&"default_color", &"RichTextLabel", TEXT)


static func _check_icon(on: bool) -> ImageTexture:
	## A 26 px square box: white with a dark tick when on, a dark well with a grey edge when off,
	## so both read on the dark rows and on the accent bar. Distance fields keep edges smooth.
	if _check_icons.has(on):
		return _check_icons[on]
	const N := 26
	const R := 1.5
	var half := Vector2(N, N) * 0.5
	var tick: Array[Vector2] = [Vector2(7, 13.5), Vector2(11, 17.5), Vector2(19, 9)]
	var img := Image.create_empty(N, N, false, Image.FORMAT_RGBA8)
	for y in N:
		for x in N:
			var p := Vector2(x + 0.5, y + 0.5)
			var q := (p - half).abs() - (half - Vector2(2.0 + R, 2.0 + R))
			var box := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - R
			var c: Color
			var inside := clampf(0.5 - box, 0.0, 1.0)
			var edge := clampf(1.0 - absf(box + 0.75), 0.0, 1.0)
			if on:
				c = Color(Color.WHITE.lerp(INK, edge * 0.6), inside)
				var d := minf(Geometry2D.get_closest_point_to_segment(p, tick[0], tick[1]).distance_to(p),
					Geometry2D.get_closest_point_to_segment(p, tick[1], tick[2]).distance_to(p))
				c = Color(c.lerp(INK, clampf(2.1 - d, 0.0, 1.0)), c.a)
			else:
				c = Color(Color(0, 0, 0, 0.4).lerp(Color(0.5, 0.54, 0.62), edge), maxf(inside * 0.4, edge))
			img.set_pixel(x, y, c)
	_check_icons[on] = ImageTexture.create_from_image(img)
	return _check_icons[on]
