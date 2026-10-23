class_name RSBowlingHall
extends Node3D
## Bowling's visual-only indoor hall; bowling_game.gd retains all physics and rules.
## Metres, +Y up, foul line at Z=0 and pins toward -Z. Build once during world setup.

const LANE_SHADER := preload("res://shaders/bowling_lane.gdshader")
const HDRI := "res://assets/polyhaven/hdris/rooftop_night/rooftop_night_4k.hdr"
const ROOM_WIDTH := 15.6
const CEILING := 4.8
const PINK := Color(1.0, 0.12, 0.48)
const CYAN := Color(0.12, 0.65, 1.0)

var _length := 18.29
var _half := 0.525
var _gutter := 0.235
var _spacing := 2.6
var _materials: Dictionary[String, Material] = {}


func configure(length_m: float, half_m: float, gutter_m: float, spacing_m: float, label_font: Font) -> void:
	_length = length_m
	_half = half_m
	_gutter = gutter_m
	_spacing = spacing_m
	_materials["wall"] = RSPbr.surface("painted_plaster_wall", 2.0, Color(0.25, 0.28, 0.43), {"normal_depth": 0.4})
	_materials["floor"] = RSPbr.surface("large_grey_tiles", 2.0, Color(0.38, 0.38, 0.48))
	_materials["metal"] = _scan("metal_plate", Color(0.25, 0.28, 0.35), 0.8)
	_materials["wood"] = _scan("plywood", Color(0.8, 0.63, 0.41), 0.75)
	_materials["rubber"] = finish(Color(0.022, 0.025, 0.035), 0.83)
	_materials["trim"] = finish(Color(0.08, 0.1, 0.15), 0.36, 0.65)
	_materials["seat"] = finish(Color(0.16, 0.2, 0.3), 0.57)
	_materials["mark"] = finish(Color(0.1, 0.06, 0.035), 0.42)
	_materials["white"] = _emission(Color(1.0, 0.86, 0.65), 2.1)
	_materials["pink"] = _emission(PINK, 2.2)
	_materials["cyan"] = _emission(CYAN, 2.2)
	_materials["lane"] = _lane_material()
	for player in range(1, 5):
		var color: Color = RSControllerModel.PLAYER_COLORS[player]
		_materials["player%d" % player] = _emission(color, 2.0)
		_materials["panel%d" % player] = finish(color.darkened(0.6), 0.32, 0.25)
	_lighting()
	_shell()
	for i in 4:
		_lane((i - 1.5) * _spacing, i + 1, label_font)
	_lounge()
	_fixtures()


static func finish(color: Color, roughness: float, metal := 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metal
	return material


static func pin_material() -> StandardMaterial3D:
	var material := finish(Color.WHITE, 0.23)
	material.vertex_color_use_as_albedo = true
	material.clearcoat_enabled = true
	material.clearcoat = 0.75
	material.clearcoat_roughness = 0.15
	return material


static func ball_material(color: Color) -> StandardMaterial3D:
	var material := finish(color, 0.17)
	material.clearcoat_enabled = true
	material.clearcoat = 1.0
	material.clearcoat_roughness = 0.1
	return material


func _scan(id: String, tint: Color, size_m: float) -> ORMMaterial3D:
	var material := RSPbr.standard(id, size_m, tint)
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	return material


func _emission(color: Color, energy: float) -> StandardMaterial3D:
	var material := finish(color, 0.3)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	return material


func _lane_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = LANE_SHADER
	var maps := RSPbr.maps("plywood")
	material.set_shader_parameter("albedo_tex", maps[0])
	material.set_shader_parameter("normal_tex", maps[1])
	material.set_shader_parameter("orm_tex", maps[2])
	return material


func _lighting(hdri_path: String = HDRI) -> void:
	var environment := Environment.new()
	if ResourceLoader.exists(hdri_path):
		var panorama := PanoramaSkyMaterial.new()
		panorama.panorama = load(hdri_path) as Texture2D
		var sky := Sky.new()
		sky.sky_material = panorama
		environment.sky = sky
		environment.background_mode = Environment.BG_SKY
		environment.ambient_light_sky_contribution = 0.25
		environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	else:
		# Source-only CI omits Poly Haven; retain indoor light without loading absent art.
		environment.background_mode = Environment.BG_COLOR
		environment.background_color = Color(0.08, 0.09, 0.16)
		environment.ambient_light_sky_contribution = 0.0
		environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.63, 0.69, 0.85)
	environment.ambient_light_energy = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	environment.ssao_enabled = true
	environment.glow_enabled = true
	environment.glow_intensity = 0.55
	environment.glow_bloom = 0.04
	RSSettings.environment(environment)
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-64, -12, 0)
	key.light_color = Color(1.0, 0.91, 0.78)
	key.light_energy = 0.7
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 40.0
	RSSettings.sun_shadows(key)
	add_child(key)
	for z: float in [2.0, -6.0, -14.0, -19.0]:
		var lamp := OmniLight3D.new()
		lamp.position = Vector3(0, 3.7, z)
		lamp.omni_range = 13.0
		lamp.light_energy = 1.0
		lamp.light_color = Color(1.0, 0.87, 0.68)
		add_child(lamp)


func _shell() -> void:
	_panel("Floor", Vector2(ROOM_WIDTH, 31.5), Vector3(0, -0.6, -6.25), "floor")
	# The ceiling is visual only: the broad key remains a soft interior fill.
	var ceiling := _panel("Ceiling", Vector2(ROOM_WIDTH, 31.5), Vector3(0, CEILING, -6.25), "wall")
	ceiling.rotation.x = PI
	ceiling.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var back := _panel("BackWall", Vector2(ROOM_WIDTH, 5.4), Vector3(0, 2.1, -22.0), "wall")
	back.rotation.x = PI / 2.0
	var front := _panel("LoungeWall", Vector2(ROOM_WIDTH, 5.4), Vector3(0, 2.1, 9.5), "wall")
	front.rotation.x = -PI / 2.0
	for side: float in [-1.0, 1.0]:
		var wall := _panel("SideWall", Vector2(5.4, 31.5), Vector3(side * ROOM_WIDTH * 0.5, 2.1, -6.25), "wall")
		wall.rotation.z = side * PI / 2.0
		_box(Vector3(0.12, 0.22, 31), Vector3(side * 7.65, -0.35, -6.25), "trim")
		_box(Vector3(1.8, 0.58, 26.5), Vector3(side * 6.45, -0.3, -8.75), "trim")
		_box(Vector3(0.055, 0.055, 30.8), Vector3(side * 7.72, 3.65, -6.25), "cyan")
	for i in 2:
		_box(Vector3(15.4, 0.06, 0.055), Vector3(0, 3.75 + i * 0.3, -21.93), "pink" if i == 0 else "cyan")
	_box(Vector3(10.5, 0.58, 4.7), Vector3(0, -0.3, 6.85), "trim")
	_panel("LoungeFloor", Vector2(10.5, 4.7), Vector3(0, -0.005, 6.85), "floor")


func _lane(x: float, player: int, label_font: Font) -> void:
	var end := -_length - 1.0
	var length_m := 4.5 - end
	var center := 4.5 - length_m * 0.5
	_box(Vector3(_half * 2.0, 0.095, length_m), Vector3(x, -0.0525, center), "wood")
	# UV.y is metres from the approach toward the pit, shared by the oil shader.
	var surface := _panel("Lane%d" % player, Vector2(_half * 2.0, length_m), Vector3(x, 0.001, center), "lane")
	surface.rotation.y = PI
	var side_width := _spacing * 0.5 - _half - _gutter
	for side: float in [-1.0, 1.0]:
		_gutter_mesh(x + side * (_half + _gutter * 0.5), end)
		_box(Vector3(side_width, 0.32, length_m), Vector3(x + side * (_spacing * 0.5 - side_width * 0.5), 0.06, center), "trim")
		_box(Vector3(0.018, 0.012, -end), Vector3(x + side * (_half + _gutter + 0.02), 0.225, end * 0.5), "player%d" % player)
	_box(Vector3(_spacing, 0.1, 1.6), Vector3(x, -0.55, end - 0.8), "rubber")
	_box(Vector3(_spacing, 1.4, 0.2), Vector3(x, 0.1, end - 1.6), "rubber")
	_box(Vector3(_half * 2.0, 0.004, 0.03), Vector3(x, 0.004, 0), "mark")
	var triangle := PrismMesh.new()
	triangle.size = Vector3(0.05, 0.16, 0.004)
	var targets: Array[Transform3D] = []
	for k in 7:
		targets.append(Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3(x + (k - 3) * 0.13, 0.004, -4.6 - absi(k - 3) * 0.3)))
	_batch(triangle, _materials["mark"], targets)
	_box(Vector3(_spacing - 0.1, 1.1, 0.18), Vector3(x, 1.55, end - 0.4), "panel%d" % player)
	_box(Vector3(_spacing - 0.16, 0.025, 0.025), Vector3(x, 1.04, end - 0.29), "player%d" % player)
	var label := Label3D.new()
	label.text = "P%d" % player # no-i18n
	label.font = label_font
	label.font_size = 96
	label.pixel_size = 0.005
	label.outline_size = 8
	label.position = Vector3(x, 1.55, end - 0.29)
	add_child(label)


func _gutter_mesh(x: float, end: float) -> void:
	# Raised lips and a shallow curved liner sit above the unchanged flat collision.
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 12:
		var a := PI * i / 12.0
		var b := PI * (i + 1) / 12.0
		var x0 := -cos(a) * _gutter * 0.5
		var x1 := -cos(b) * _gutter * 0.5
		var y0 := 0.006 - sin(a) * 0.1
		var y1 := 0.006 - sin(b) * 0.1
		for vertex: Vector3 in [Vector3(x0, y0, 0), Vector3(x1, y1, end), Vector3(x1, y1, 0), Vector3(x0, y0, 0), Vector3(x0, y0, end), Vector3(x1, y1, end)]:
			tool.add_vertex(vertex)
	tool.generate_normals()
	var mesh := MeshInstance3D.new()
	mesh.name = "Gutter"
	mesh.mesh = tool.commit()
	mesh.material_override = _materials["metal"]
	mesh.position.x = x
	add_child(mesh)


func _lounge() -> void:
	for x: float in [-_spacing, _spacing]:
		_box(Vector3(0.62, 0.44, 1.75), Vector3(x, 0.24, 2.5), "metal")
		_box(Vector3(0.54, 0.11, 1.5), Vector3(x, 0.51, 2.5), "rubber")
		_box(Vector3(0.64, 0.75, 0.48), Vector3(x, 0.4, 1.48), "metal")
		_box(Vector3(0.38, 0.18, 0.025), Vector3(x, 0.48, 1.73), "rubber")
		for offset: float in [-0.16, 0.16]:
			_box(Vector3(0.035, 0.1, 1.25), Vector3(x + offset, 0.63, 2.6), "trim")
		var ball := SphereMesh.new()
		ball.radius = 0.109
		ball.height = 0.218
		_batch(ball, ball_material(CYAN if x > 0 else PINK), [Transform3D(Basis.IDENTITY, Vector3(x, 0.66, 2.65)), Transform3D(Basis.IDENTITY, Vector3(x, 0.66, 3.05))])
	var seats: Array[Transform3D] = []
	var backs: Array[Transform3D] = []
	var legs: Array[Transform3D] = []
	for lane in 4:
		for side: float in [-0.36, 0.36]:
			var x := (lane - 1.5) * _spacing + side
			seats.append(Transform3D(Basis.IDENTITY, Vector3(x, 0.43, 7.1)))
			backs.append(Transform3D(Basis(Vector3.RIGHT, -0.1), Vector3(x, 0.76, 7.4)))
			legs.append(Transform3D(Basis.IDENTITY, Vector3(x, 0.19, 7.15)))
	_batch_box(Vector3(0.62, 0.13, 0.65), "seat", seats)
	_batch_box(Vector3(0.62, 0.58, 0.13), "seat", backs)
	_batch_box(Vector3(0.08, 0.38, 0.48), "metal", legs)
	for x: float in [-_spacing, 0.0, _spacing]:
		_box(Vector3(0.55, 0.07, 0.7), Vector3(x, 0.57, 7.0), "wood")
		_box(Vector3(0.08, 0.55, 0.08), Vector3(x, 0.26, 7.0), "metal")


func _fixtures() -> void:
	var rails: Array[Transform3D] = []
	var lights: Array[Transform3D] = []
	var beams: Array[Transform3D] = []
	for row in 5:
		var z := 5.5 - row * 5.3
		beams.append(Transform3D(Basis.IDENTITY, Vector3(0, 4.6, z)))
		for x: float in [-3.9, -1.3, 1.3, 3.9]:
			rails.append(Transform3D(Basis.IDENTITY, Vector3(x, 4.35, z)))
			lights.append(Transform3D(Basis.IDENTITY, Vector3(x, 4.28, z)))
	_batch_box(Vector3(15.4, 0.16, 0.15), "trim", beams)
	_batch_box(Vector3(0.26, 0.11, 2.0), "metal", rails)
	_batch_box(Vector3(0.17, 0.025, 1.85), "white", lights)


func _box(size: Vector3, at: Vector3, material: String) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _materials[material]
	instance.position = at
	add_child(instance)
	return instance


func _panel(label: String, size: Vector2, at: Vector3, material: String) -> MeshInstance3D:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for uv: Vector2 in [Vector2.ZERO, Vector2(size.x, size.y), Vector2(0, size.y), Vector2.ZERO, Vector2(size.x, 0), size]:
		tool.set_normal(Vector3.UP)
		tool.set_tangent(Plane(1, 0, 0, -1))
		tool.set_uv(uv)
		tool.add_vertex(Vector3(uv.x - size.x * 0.5, 0, uv.y - size.y * 0.5))
	var instance := MeshInstance3D.new()
	instance.name = label
	instance.mesh = tool.commit()
	instance.material_override = _materials[material]
	instance.position = at
	add_child(instance)
	return instance


func _batch_box(size: Vector3, material: String, transforms: Array[Transform3D]) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	_batch(mesh, _materials[material], transforms)


func _batch(mesh: Mesh, material: Material, transforms: Array[Transform3D]) -> void:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	instance.material_override = material
	add_child(instance)
