extends Node
## Mip preparation preserves shared data, renormalizes normal maps, and reuses cached textures.

var _checks := 0
var _failures := 0


func _ready() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("FAIL: " + message)


func _run() -> void:
	var invalid := OS.get_environment("RS_GOLF_TEXTURE_INVALID")
	if not invalid.is_empty():
		var path := "res://tests/missing-golf-texture.png" if invalid == "missing" else "res://tests/test_golf_surface.tscn"
		_check(RSGolfTextures.load_mipped(path) == null and RSGolfTextures._cache.is_empty(), "failure is not cached")
		print("RS_GOLF_TEXTURE_REJECTION: %d checks, %d failures" % [_checks, _failures])
		get_tree().quit(1)
		return
	_synthetic()
	_actual_samplers()
	_courses()
	RSGolfTextures._cache.clear()
	print("RS_GOLF_TEXTURE_TESTS: %d checks, %d failures" % [_checks, _failures])
	await get_tree().create_timer(0.35).timeout
	get_tree().quit(1 if _failures else 0)


func _synthetic() -> void:
	var image := Image.create_empty(2, 2, false, Image.FORMAT_RGB8)
	for y in 2:
		image.set_pixel(0, y, Color(0.9, 0.5, 0.8))
		image.set_pixel(1, y, Color(0.1, 0.5, 0.8))
	var source := ImageTexture.create_from_image(image)
	var before := source.get_image().get_data()
	var color := RSGolfTextures._prepare(source, false, "synthetic color")
	var normal := RSGolfTextures._prepare(source, true, "synthetic normal")
	_check(color != source and normal != source and color != normal, "missing mips create private textures")
	_check(color.get_width() == 2 and color.get_height() == 2 and color.get_image().get_mipmap_count() == 1, "dimensions and complete mip chain")
	_check(source.get_image().get_data() == before and not source.get_image().has_mipmaps() and image.get_data() == before, "shared Texture2D and original Image pixels/mips unchanged")
	_check(color.get_image().get_data().slice(0, before.size()) == before and normal.get_image().get_data().slice(0, before.size()) == before, "generated textures preserve every base-level pixel")
	_check(_mip_vector(normal.get_image()).length() > 0.97 and _mip_vector(color.get_image()).length() < 0.7, "normal flag renormalizes final mip vectors")
	_check(RSGolfTextures._prepare(color, true, "already mipped") == color, "existing mip resource identity preserved even for another flag")
	var dxt := Image.create_from_data(4, 4, false, Image.FORMAT_DXT1, PackedByteArray([0, 248, 0, 248, 0, 0, 0, 0]))
	var compressed := ImageTexture.create_from_image(dxt)
	var compressed_before := compressed.get_image().get_data()
	_check(compressed.get_image().is_compressed(), "DXT1 fixture exercises compressed input")
	var decompressed := RSGolfTextures._prepare(compressed, false, "synthetic DXT1")
	_check(decompressed != null and not decompressed.get_image().is_compressed() and decompressed.get_image().has_mipmaps(), "compressed copy decompressed before mip generation")
	_check(decompressed.get_image().get_pixel(0, 0) == Color.RED, "DXT1 base-level red remains exact after decompression/mips")
	_check(compressed.get_image().is_compressed() and compressed.get_image().get_data() == compressed_before, "compressed source remains byte-identical")


func _mip_vector(image: Image) -> Vector3:
	var data := image.get_data()
	var offset := image.get_mipmap_offset(1)
	return Vector3(data[offset], data[offset + 1], data[offset + 2]) / 127.5 - Vector3.ONE


func _actual_samplers() -> void:
	const TEMPLATE := "res://assets/polyhaven/textures/%s/%s_%s_2k.jpg"
	for id in ["leafy_grass", "withered_grass", "coast_sand_01", "playground_sand"]:
		for normal_map in [false, true]:
			var path := TEMPLATE % [id, id, "nor_gl" if normal_map else "diff"]
			var source := load(path) as Texture2D
			var original := source.get_image()
			var before := original.get_data()
			var texture := RSGolfTextures.load_mipped(path, normal_map)
			_check(texture != null and texture.get_image().has_mipmaps(), "all real samplers have mip chains")
			_check(texture == RSGolfTextures.load_mipped(path, normal_map), "same path/flag returns identical cached resource")
			_check(texture.get_size() == source.get_size() and source.get_image().get_data() == before and source.get_image().has_mipmaps() == original.has_mipmaps(), "real shared resource dimensions/pixels/mips preserved")
			_check(texture == source if original.has_mipmaps() else texture != source, "existing mips reused; only missing mips copied")
	var path := TEMPLATE % ["leafy_grass", "leafy_grass", "diff"]
	var color := RSGolfTextures.load_mipped(path)
	var normal := RSGolfTextures.load_mipped(path, true)
	_check(color == normal if (load(path) as Texture2D).get_image().has_mipmaps() else color != normal, "normal flag is part of cache key")


func _courses() -> void:
	var grass: Texture2D
	for index in 2:
		var course := RSGolfCourse.new(index)
		add_child(course)
		var shared: ShaderMaterial
		var chunks := 0
		for child: Node in course.get_children():
			var mesh := child as MeshInstance3D
			if mesh == null:
				continue
			var material := mesh.material_override as ShaderMaterial
			if material != null and material.shader.resource_path == "res://shaders/golf_terrain.gdshader":
				if shared == null:
					shared = material
				_check(shared == material, "terrain chunks share one material without rebuilding samplers")
				chunks += 1
		_check(chunks == (54 if index == 0 else 42), "both actual maps connected to terrain material")
		for uniform in ["grass_tex", "grass_nor", "rough_tex", "rough_nor", "sand_tex", "sand_nor"]:
			var texture := shared.get_shader_parameter(uniform) as Texture2D
			_check(texture != null and texture.get_image().has_mipmaps(), "all six actual terrain samplers are mip-ready")
		var current := shared.get_shader_parameter("grass_tex") as Texture2D
		_check(grass == null or current == grass, "maps reuse shared grass texture cache")
		grass = current
		remove_child(course)
		course.free()
