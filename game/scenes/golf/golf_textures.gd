class_name RSGolfTextures
extends RefCounted
## Golf terrain samplers only: cache mip-ready textures without editing shared imports/resources.
## Called during course construction, never from a chunk or frame update.

static var _cache: Dictionary = {}


static func load_mipped(path: String, normal_map := false) -> Texture2D:
	var key := ("normal:" if normal_map else "color:") + path
	if _cache.has(key):
		return _cache[key]
	if not ResourceLoader.exists(path):
		push_error("RSGolfTextures: missing texture: " + path)
		return null
	var source := load(path) as Texture2D
	if source == null:
		push_error("RSGolfTextures: expected Texture2D: " + path)
		return null
	var result := _prepare(source, normal_map, path)
	if result != null:
		_cache[key] = result
	return result


static func _prepare(source: Texture2D, normal_map: bool, context: String) -> Texture2D:
	var original := source.get_image()
	if original == null or original.is_empty():
		push_error("RSGolfTextures: empty image: " + context)
		return null
	if original.has_mipmaps():
		return source
	var image := original.duplicate() as Image
	if image.is_compressed():
		var decompress_error := image.decompress()
		if decompress_error != OK:
			push_error("RSGolfTextures: decompress failed (%d): %s" % [decompress_error, context])
			return null
	var mip_error := image.generate_mipmaps(normal_map)
	if mip_error != OK:
		push_error("RSGolfTextures: mip generation failed (%d): %s" % [mip_error, context])
		return null
	var texture := ImageTexture.create_from_image(image)
	if texture == null:
		push_error("RSGolfTextures: texture creation failed: " + context)
	return texture
