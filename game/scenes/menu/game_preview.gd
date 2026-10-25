class_name RSGamePreview
extends TextureRect
## Static, scene-rendered sport previews shown full screen behind the menu. Selection loads at
## most one texture per ID; non-sport items and missing art hide the picture (the live backdrop
## shows again) without blocking navigation.

var _textures: Dictionary = {}
var game_id := ""


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func show_game(entry: Dictionary) -> void:
	game_id = str(entry.get("id", ""))
	visible = false
	if game_id.is_empty():
		return
	if not _textures.has(game_id):
		var path := str(entry.get("preview", ""))   # the manifest's preview (RSGameModule)
		if path.is_empty() or not ResourceLoader.exists(path):
			return
		_textures[game_id] = load(path) as Texture2D
	if texture != _textures[game_id]:
		modulate.a = 0.4
		create_tween().tween_property(self, "modulate:a", 1.0, 0.2)
	texture = _textures[game_id]
	visible = texture != null


func covers_screen() -> bool:
	## Fully faded in: whatever is behind it needs no rendering.
	return visible and modulate.a >= 1.0
