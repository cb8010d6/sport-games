class_name RSArenaHall
extends RefCounted
## Shared indoor shell and environment, in metres. xform is world-space; its origin is
## the floor centre. Six inward-facing, zero-thickness panels preserve the exact internal
## size/AABB, with beams and fixtures inside. No collisions, sun or project-specific layout.
## Build off-tree at identity, then attach: fixtures inherit the same final room transform.

class Preset:
	var floor_id := "concrete_floor_painted"
	var wall_id := "concrete_wall_003"
	var ceiling_color := Color(0.18, 0.19, 0.21)
	var hdri := ""
	var ambient := Color(0.55, 0.57, 0.6)
	var ambient_energy := 0.6
	var exposure := 1.0
	var fog_density := 0.002
	var light_rows := 3
	var light_cols := 4
	var real_lights := 2


static var _scanned: Dictionary = {}
static var _ceilings: Dictionary = {}


static func preset_gym() -> Preset:
	return Preset.new()


static func preset_boxing() -> Preset:
	var p := Preset.new()
	p.floor_id = "plywood"
	p.ceiling_color = Color(0.08, 0.09, 0.11)
	p.ambient = Color(0.4, 0.42, 0.5)
	p.ambient_energy = 0.22
	p.fog_density = 0.004
	# The project adds its ring-focused hanging lamps; no ceiling wash brightens the crowd.
	p.light_rows = 0
	p.light_cols = 0
	p.real_lights = 0
	return p


static func preset_hall() -> Preset:
	var p := Preset.new()
	p.floor_id = "concrete_floor_worn_001"
	p.ceiling_color = Color(0.2, 0.19, 0.18)
	p.ambient = Color(0.6, 0.57, 0.52)
	p.ambient_energy = 0.55
	p.exposure = 1.05
	p.fog_density = 0.0015
	p.light_rows = 2
	p.light_cols = 4
	return p


static func build(parent: Node3D, xform: Transform3D, size: Vector3, preset: Preset) -> Node3D:
	var root := Node3D.new()
	root.name = "ArenaHall" # no-i18n
	var floor_material := _material(preset.floor_id)
	var wall_material := _material(preset.wall_id)
	var ceiling_material := _ceiling_material(preset.ceiling_color)
	# Exact cardinal bases keep the zero-thickness bounds exact, without quarter-turn drift.
	_panel(root, &"Floor", Vector2(size.x, size.z), Transform3D(Basis(Vector3.RIGHT, Vector3.FORWARD, Vector3.UP), Vector3.ZERO), floor_material)
	_panel(root, &"Ceiling", Vector2(size.x, size.z), Transform3D(Basis(Vector3.RIGHT, Vector3.BACK, Vector3.DOWN), Vector3(0, size.y, 0)), ceiling_material)
	_panel(root, &"BackWall", Vector2(size.x, size.y), Transform3D(Basis.IDENTITY, Vector3(0, size.y * 0.5, -size.z * 0.5)), wall_material)
	_panel(root, &"FrontWall", Vector2(size.x, size.y), Transform3D(Basis(Vector3.LEFT, Vector3.UP, Vector3.FORWARD), Vector3(0, size.y * 0.5, size.z * 0.5)), wall_material)
	_panel(root, &"LeftWall", Vector2(size.z, size.y), Transform3D(Basis(Vector3.FORWARD, Vector3.UP, Vector3.RIGHT), Vector3(-size.x * 0.5, size.y * 0.5, 0)), wall_material)
	_panel(root, &"RightWall", Vector2(size.z, size.y), Transform3D(Basis(Vector3.BACK, Vector3.UP, Vector3.LEFT), Vector3(size.x * 0.5, size.y * 0.5, 0)), wall_material)
	_beams(root, size)
	var world := WorldEnvironment.new()
	world.name = "Environment" # no-i18n
	world.environment = _environment(preset)
	root.add_child(world)
	var lights := RSArenaLights.LightSpec.new()
	lights.real_lights = preset.real_lights
	lights.range = maxf(size.x, size.z)
	var grid := RSArenaLights.ceiling_grid(root, Rect2(-size.x * 0.4, -size.z * 0.4, size.x * 0.8, size.z * 0.8),
		maxf(size.y - 0.35, 0.0), preset.light_rows, preset.light_cols, lights)
	grid.name = "Lights" # no-i18n
	# Until this point root is an unattached identity, so world-based fixture builders
	# produced room-local data. Attach once, preserving the entire shell/fixture alignment.
	root.transform = _world(parent).affine_inverse() * xform
	parent.add_child(root)
	return root


static func _environment(p: Preset) -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = p.ceiling_color.darkened(0.5)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = p.ambient
	env.ambient_light_energy = maxf(p.ambient_energy, 0.0)
	env.ambient_light_sky_contribution = 0.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	# An empty path never reaches either exists() or load(). HDRI is optional reflected fill.
	if p.hdri != "" and ResourceLoader.exists(p.hdri):
		var panorama := PanoramaSkyMaterial.new()
		panorama.panorama = load(p.hdri) as Texture2D
		var sky := Sky.new()
		sky.sky_material = panorama
		env.sky = sky
		env.ambient_light_sky_contribution = 0.25
		env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = maxf(p.exposure, 0.01)
	env.ssao_enabled = true
	env.ssr_enabled = true
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.1
	env.fog_enabled = p.fog_density > 0.0
	env.fog_density = maxf(p.fog_density, 0.0)
	env.fog_light_color = p.ambient
	RSSettings.environment(env)
	return env


static func _material(id: String) -> BaseMaterial3D:
	if not _scanned.has(id):
		_scanned[id] = RSPbr.standard(id)
	return _scanned[id] as BaseMaterial3D


static func _ceiling_material(color: Color) -> StandardMaterial3D:
	if not _ceilings.has(color):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.85
		_ceilings[color] = mat
	return _ceilings[color] as StandardMaterial3D


static func _panel(parent: Node3D, name: StringName, size: Vector2, xform: Transform3D, mat: Material) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-size.x, -size.y, 0) * 0.5, Vector3(size.x, -size.y, 0) * 0.5,
		Vector3(-size.x, size.y, 0) * 0.5, Vector3(size.x, size.y, 0) * 0.5])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, size.y), size, Vector2.ZERO, Vector2(size.x, 0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 1, 2, 3]) # clockwise, inward +Z
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, mat)
	var node := MeshInstance3D.new()
	node.name = name
	node.mesh = mesh
	node.transform = xform
	parent.add_child(node)


static func _beams(parent: Node3D, size: Vector3) -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size.x, minf(0.2, size.y * 0.1), minf(0.2, size.z * 0.1))
	mesh.material = _material("beam_wall_01")
	var count := maxi(1, ceili(size.z / 4.0))
	for i in count:
		var node := MeshInstance3D.new()
		node.name = "Beam%d" % i # no-i18n
		node.mesh = mesh
		node.position = Vector3(0, size.y - mesh.size.y * 0.5, -size.z * 0.5 + (i + 0.5) * size.z / count)
		parent.add_child(node)


static func _world(node: Node3D) -> Transform3D:
	var world := Transform3D.IDENTITY
	var ancestor: Node = node
	# Godot's transform inheritance stops at a plain Node, even with spatial ancestors above it.
	while ancestor is Node3D:
		var spatial := ancestor as Node3D
		world = spatial.transform * world
		if spatial.top_level:
			break
		ancestor = ancestor.get_parent()
	return world
