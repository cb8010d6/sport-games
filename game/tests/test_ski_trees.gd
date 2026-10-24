extends Node
## Compare the real LOD builder with the frozen pre-LOD generator on all four maps.
## Headless checks prove data/graph contracts; they do not prove the rendered fade.

var _checks := 0
var _failures := 0
var _renderer_checks := 0


func _ready() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		if _failures <= 16:
			push_error("FAIL: " + message)


func _meshes() -> void:
	var legacy := RSSkiTreesLegacy.new()
	var material := StandardMaterial3D.new()
	legacy._mats["fir"] = material
	var before := RandomNumberGenerator.new()
	var after := RandomNumberGenerator.new()
	before.seed = 23 * 31
	after.seed = before.seed
	for v in 4:
		var copy := RandomNumberGenerator.new()
		copy.seed = after.seed
		copy.state = after.state
		var old := legacy._fir_mesh(before, RSSkiTrees.HEIGHTS[v], RSSkiTrees.TIERS[v], RSSkiTrees.LOBES[v])
		var high := RSSkiTrees.fir_mesh(after, RSSkiTrees.HEIGHTS[v], RSSkiTrees.TIERS[v], RSSkiTrees.LOBES[v], material)
		var low := RSSkiTrees.fir_mesh(copy, RSSkiTrees.HEIGHTS[v], RSSkiTrees.TIERS[v], RSSkiTrees.LOW_LOBES, material)
		_check(old.surface_get_arrays(0) == high.surface_get_arrays(0), "all high vertices/normals/UVs/colours/tangents are identical")
		_check(before.state == after.state, "low mesh does not advance the layout RNG")
		var high_arrays := high.surface_get_arrays(0)
		var low_arrays := low.surface_get_arrays(0)
		var high_vertices: PackedVector3Array = high_arrays[Mesh.ARRAY_VERTEX]
		var low_vertices: PackedVector3Array = low_arrays[Mesh.ARRAY_VERTEX]
		_check(high_vertices.size() / 3 == [336, 268, 412, 180][v], "original triangle count")
		_check(low_vertices.size() / 3 == [156, 140, 172, 108][v], "low mesh contains fewer actual triangles")
		_check(high.surface_get_material(0) == low.surface_get_material(0), "both meshes share the original material")
		var high_colours: PackedColorArray = high_arrays[Mesh.ARRAY_COLOR]
		var low_colours: PackedColorArray = low_arrays[Mesh.ARRAY_COLOR]
		_check(high_colours[36] == low_colours[36], "private RNG starts at the same needle colour")
		_check(is_equal_approx(RSSkiTrees.mesh_bounds(high).end.y, RSSkiTrees.HEIGHTS[v] * 0.9), "high CPU bounds retain the original tree height")
		_check(is_equal_approx(RSSkiTrees.mesh_bounds(low).end.y, RSSkiTrees.HEIGHTS[v] * 0.9), "low mesh retains the complete tier stack and height")


func _coarse_materials() -> void:
	var source := ShaderMaterial.new()
	source.shader = preload("res://shaders/snow_fir.gdshader")
	var tint := Color(0.63, 0.74, 0.89, 1.0)
	var light := 0.37
	source.set_shader_parameter("snow_tint", tint)
	source.set_shader_parameter("needle_light", light)
	var course := RSSkiCourse.new(1)
	var layout_state := course._rng.state
	var batches := RSSkiTrees.generate(course, source, course._lift_u())
	var shared: ShaderMaterial
	var low_count := 0
	var far_count := 0
	for batch: Dictionary in batches:
		_check(batch["mesh"].surface_get_material(0) == source, "high and far meshes keep the original material identity")
		if batch["low"] == null:
			far_count += 1
			continue
		var coarse := batch["low"].surface_get_material(0) as ShaderMaterial
		_check(coarse != null and coarse != source, "coarse mesh has an independent shader material")
		if coarse == null:
			continue
		_check(coarse.shader.resource_path == "res://scenes/ski/ski_fir_coarse.gdshader", "only low meshes use the ski coarse shader")
		_check(coarse.get_shader_parameter("snow_tint") == tint, "coarse material copies a non-default snow tint")
		_check(is_equal_approx(float(coarse.get_shader_parameter("needle_light")), light), "coarse material copies non-default needle lighting")
		if shared == null:
			shared = coarse
		_check(coarse == shared, "coarse variants share one material created at initialization")
		low_count += 1
	_check(low_count > 0 and far_count == 1, "fixture covers both LOD and unchanged far batches")
	_check(course._rng.state == layout_state, "coarse material construction consumes no layout RNG")
	_check(source.shader.resource_path == "res://shaders/snow_fir.gdshader", "original high shader remains unchanged")
	if shared != null:
		shared.set_shader_parameter("snow_tint", Color(0.2, 0.3, 0.4, 1.0))
		shared.set_shader_parameter("needle_light", 0.9)
	_check(source.get_shader_parameter("snow_tint") == tint and is_equal_approx(float(source.get_shader_parameter("needle_light")), light), "coarse uniforms do not mutate the original material")
	course.free()


func _forest(index: int) -> void:
	# Do not add the course to the scene tree: terrain/props/assets are outside this test.
	var course := RSSkiCourse.new(index)
	var material := StandardMaterial3D.new()
	var layout_state := course._rng.state
	var quality := RSSettings.quality
	var legacy := RSSkiTreesLegacy.new()
	legacy.build(course, material)
	var generated := RSSkiTrees.generate(course, material, course._lift_u())
	_check(generated.size() == legacy.batches.size(), "same CPU batch count")
	RSSkiTrees.build(course, material, course._lift_u())
	_check(course._rng.state == layout_state, "trees never consume the terrain/prop RNG")
	_check(RSSettings.quality == quality, "tree construction never changes the player setting")
	var actual: Array[MultiMeshInstance3D] = []
	for child: Node in course.get_children():
		if child is MultiMeshInstance3D:
			var item := child as MultiMeshInstance3D
			if not item.visibility_parent.is_empty() or item.name == "far_firs":
				actual.append(item)
	_check(actual.size() == legacy.batches.size(), "same nonempty batches in original generation order")
	for b in mini(actual.size(), legacy.batches.size()):
		var item := actual[b]
		var expected: Dictionary = legacy.batches[b]
		var xfs: Array = expected["xfs"]
		var generated_xfs: Array = generated[b]["xfs"]
		var original: ArrayMesh = expected["mesh"]
		_check(item.multimesh.mesh.surface_get_arrays(0) == original.surface_get_arrays(0), "high batch mesh equals the old mesh")
		_check(item.multimesh.instance_count == xfs.size(), "no missing or extra trees")
		var shadow := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if expected["shadows"] else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_check(item.cast_shadow == shadow and item.layers == 1, "original per-batch shadows and render layer")
		for i in xfs.size():
			_check(generated_xfs[i] == xfs[i], "same CPU transform at each original INSTANCE_ID")
		_renderer_upload(item, xfs)
		if item.visibility_parent.is_empty():
			_check(item.name == "far_firs" and item.visibility_range_begin == 0.0 and item.visibility_range_end == 0.0, "far batch remains uncut and unchanged")
			continue
		var coarse := item.get_node(item.visibility_parent) as MultiMeshInstance3D
		_check(coarse != null, "LOD dependency resolves to its matching coarse batch")
		if coarse == null:
			continue
		_check(coarse.cast_shadow == item.cast_shadow and coarse.layers == item.layers, "LOD preserves the batch shadow and layer policy")
		_check(coarse.visibility_range_fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES, "renderer handles the per-camera dependency fade")
		_check(coarse.visibility_range_end == 0.0 and item.visibility_range_end == 0.0, "no far clipping or second independent switch")
		_check(coarse.multimesh.custom_aabb == item.multimesh.custom_aabb, "both LODs use the same distance centre")
		var bounds := item.multimesh.custom_aabb
		var protected_radius := coarse.visibility_range_begin - coarse.visibility_range_begin_margin - bounds.size.length() * 0.5
		_check(protected_radius >= RSSkiTrees.NEAR_DISTANCE - 0.001, "AABB radius protects the nearest tree, not just its centre")
		_renderer_upload(coarse, xfs)
		var high_bounds := RSSkiTrees.mesh_bounds(original)
		var low_bounds := RSSkiTrees.mesh_bounds(coarse.multimesh.mesh)
		for i in xfs.size():
			var xf: Transform3D = xfs[i]
			_check(bounds.grow(0.01).encloses(xf * high_bounds), "CPU bounds contain every high tree")
			_check(bounds.grow(0.01).encloses(xf * low_bounds), "CPU bounds contain every low tree")
		for tier: int in [0, 3, 1, 2, 0, 3]:
			RSSettings.quality = tier
			_check(coarse.visibility_range_begin - coarse.visibility_range_begin_margin - bounds.size.length() * 0.5 >= RSSkiTrees.NEAR_DISTANCE - 0.001, "quality changes never degrade protected near geometry")
		RSSettings.quality = quality
	course.free()


func _renderer_upload(item: MultiMeshInstance3D, xfs: Array) -> void:
	# Dummy headless storage does not retain MultiMesh transforms. Full CPU equality
	# above is mandatory; a hidden real-renderer run additionally checks the upload.
	if OS.get_environment("RS_SKI_TREE_RENDERER_CHECK") != "1":
		return
	for index: int in [0, xfs.size() >> 1, xfs.size() - 1]:
		_renderer_checks += 1
		_check(item.multimesh.get_instance_transform(index) == xfs[index], "real renderer retains each sampled uploaded transform")


func _run() -> void:
	if OS.get_environment("RS_SKI_TREE_RENDERER_CHECK") == "1" and DisplayServer.get_name() == "headless":
		_check(false, "renderer upload check needs a hidden real-renderer run")
	else:
		_meshes()
		_coarse_materials()
		for index in RSSkiMaps.count():
			_forest(index)
	if OS.get_environment("RS_SKI_TREE_RENDERER_CHECK") == "1":
		_check(_renderer_checks > 0, "real-renderer mode must perform upload readbacks")
	print("RS_SKI_TREES_RENDERER_READBACKS: %d" % _renderer_checks)
	print("RS_SKI_TREES_TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)
