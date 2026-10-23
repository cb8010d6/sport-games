class_name RSUi
extends RefCounted
## Shared look for the 2D UI: a CJK-capable system font and dark rounded panels.

const PANEL_BG := Color(0.07, 0.08, 0.11, 0.9)
const TEXT_MUTED := Color(0.6, 0.64, 0.72)

static var _font: SystemFont
static var _font_tags: RegEx


static func font() -> Font:
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", "Source Han Sans SC", "sans-serif"])
	return _font


static func theme(font_size: int = 18) -> Theme:
	var t := Theme.new()
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
