class_name RSGamePreview
extends PanelContainer
## Static, scene-rendered sport previews. Selection loads at most one texture per ID;
## non-sport items and missing art hide the card without blocking navigation.

var _image: TextureRect
var _title: Label
var _textures: Dictionary = {}
var game_id := ""


func _ready() -> void:
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -800
	offset_right = -48
	offset_top = -255
	offset_bottom = 255
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_stylebox_override("panel", RSUi.panel_style(20, Color(0.035, 0.055, 0.09, 0.94)))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	add_child(col)
	_title = RSUi.label("", 32)
	_title.clip_text = true
	col.add_child(_title)
	var aspect := AspectRatioContainer.new()
	aspect.ratio = 16.0 / 9.0
	aspect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(aspect)
	_image = TextureRect.new()
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	aspect.add_child(_image)
	col.add_child(RSUi.label(tr("画面预览 · 地图 1"), 17, RSUi.TEXT_MUTED))
	visible = false


func show_game(entry: Dictionary) -> void:
	game_id = str(entry.get("id", ""))
	visible = false
	if game_id.is_empty():
		return
	if not _textures.has(game_id):
		var path := "res://assets/previews/%s.jpg" % game_id
		if not ResourceLoader.exists(path):
			return
		_textures[game_id] = load(path) as Texture2D
	_image.texture = _textures[game_id]
	_title.text = tr(str(entry["name"]))
	visible = _image.texture != null
