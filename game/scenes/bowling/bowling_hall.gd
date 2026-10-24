class_name RSBowlingHall
extends Node3D
## Bowling's visual-only indoor hall; bowling_game.gd retains all physics and rules.
## Metres, +Y up, foul line at Z=0 and pins toward -Z. Build once during world setup.

const LANE_SHADER := preload("res://shaders/bowling_lane.gdshader")
const MASK_SHADER := preload("res://shaders/bowling_mask.gdshader")
const HDRI := "res://assets/polyhaven/hdris/rooftop_night/rooftop_night_4k.hdr"
const ROOM_WIDTH := 15.6
const CEILING := 4.8
const PINK := Color(1.0, 0.12, 0.48)
const CYAN := Color(0.12, 0.65, 1.0)
const POOL_ROWS := [-1.0, -7.0, -13.0] ## metres along the lanes

var _length := 18.29
var _half := 0.525
var _gutter := 0.235
var _spacing := 2.6
var _materials: Dictionary[String, Material] = {}
var _arrow: Mesh


func configure(length_m: float, half_m: float, gutter_m: float, spacing_m: float, label_font: Font) -> void:
	_length = length_m
	_half = half_m
	_gutter = gutter_m
	_spacing = spacing_m
	_materials["wall"] = RSPbr.surface("painted_plaster_wall", 1.4, Color(0.64, 0.65, 0.71), {"normal_depth": 0.75})
	_materials["brick"] = RSPbr.surface("red_brick", 1.6, Color(0.7, 0.61, 0.55), {"normal_depth": 0.65})
	_materials["ceiling"] = RSPbr.surface("white_plaster_02", 1.2, Color(0.43, 0.47, 0.56), {"normal_depth": 0.7})
	_materials["floor"] = RSPbr.surface("large_grey_tiles", 1.6, Color(0.74, 0.7, 0.67))
	_materials["metal"] = _scan("metal_plate", Color(0.42, 0.45, 0.5), 0.8)
	_materials["wood"] = _scan("plywood", Color(0.95, 0.81, 0.62), 0.75)
	_materials["side"] = _scan("beam_wall_01", Color(0.62, 0.55, 0.48), 1.3)
	_materials["acoustic"] = _scan("white_plaster_02", Color(0.27, 0.3, 0.37), 0.6)
	_materials["rubber"] = finish(Color(0.022, 0.025, 0.035), 0.83)
	_materials["trim"] = finish(Color(0.08, 0.1, 0.15), 0.36, 0.65)
	_materials["seat"] = finish(Color(0.2, 0.31, 0.4), 0.48)
	_materials["shell"] = finish(Color(0.73, 0.76, 0.79), 0.26, 0.12)
	_materials["mark"] = finish(Color(0.035, 0.025, 0.02), 0.42)
	_materials["white"] = _emission(Color(1.0, 0.86, 0.65), 2.1)
	_materials["pink"] = _emission(PINK, 2.2)
	_materials["cyan"] = _emission(CYAN, 2.2)
	_materials["lane"] = _lane_material()
	_arrow = _arrow_mesh()
	for player in range(1, 5):
		var color: Color = RSControllerModel.PLAYER_COLORS[player]
		_materials["player%d" % player] = _emission(color, 2.0)
		var mask := ShaderMaterial.new()
		mask.shader = MASK_SHADER
		mask.set_shader_parameter("player_color", color)
		mask.set_shader_parameter("panel_size", Vector2(_spacing - 0.1, 1.4))
		mask.set_shader_parameter("pattern_offset", float(player) * 0.19)
		_materials["panel%d" % player] = mask
	var lightbox := ShaderMaterial.new()
	lightbox.shader = MASK_SHADER
	lightbox.set_shader_parameter("player_color", CYAN)
	lightbox.set_shader_parameter("panel_size", Vector2(1.35, 2.4))
	_materials["lightbox"] = lightbox
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


static func apply_intro(camera: Camera3D, elapsed: float, duration: float, lane_x: float, end: Vector3, look: Vector3) -> void:
	## Two public flyover segments: lounge -> pin detail -> the unchanged aiming camera.
	var cut := duration * 0.48
	var near := Vector3(lane_x + 0.35, 1.3, -15.0)
	var pins := Vector3(lane_x, 0.25, -18.7)
	if elapsed < cut:
		RSIntro.apply(camera, elapsed, cut, Vector3(5.7, 2.7, 8.5), Vector3(lane_x + 1.5, 3.3, -9.0), near,
			Vector3(0, 0.9, -7.0), pins, 62.0, 45.0)
	else:
		RSIntro.apply(camera, elapsed - cut, duration - cut, near, Vector3(lane_x - 1.2, 3.25, -3.8), end,
			pins, look, 45.0, 50.0)


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
	environment.ambient_light_color = Color(0.76, 0.8, 0.9)
	environment.ambient_light_energy = 0.64
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	environment.ssao_enabled = true
	environment.glow_enabled = true
	environment.glow_intensity = 0.65
	environment.glow_bloom = 0.04
	RSSettings.environment(environment)
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-64, -12, 0)
	key.light_color = Color(1.0, 0.91, 0.78)
	key.light_energy = 0.62
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 40.0
	RSSettings.sun_shadows(key)
	add_child(key)
	for z: float in POOL_ROWS:
		for x: float in [-_spacing, _spacing]:
			var lamp := SpotLight3D.new()
			lamp.name = "LanePool_%d_%d" % [int(x), int(z)]
			lamp.position = Vector3(x, 4.08, z)
			lamp.rotation_degrees.x = -90
			lamp.spot_range = 7.5
			lamp.spot_angle = 52.0
			lamp.spot_attenuation = 1.6
			lamp.light_energy = 2.6
			lamp.light_color = Color(1.0, 0.87, 0.7)
			add_child(lamp)
	for lane in 4:
		var lamp := SpotLight3D.new()
		lamp.name = "PinDeckLight%d" % lane
		lamp.position = Vector3((lane - 1.5) * _spacing, 3.35, -_length + 0.8)
		lamp.spot_range = 6.0
		lamp.spot_angle = 49.0
		lamp.light_energy = 2.0
		lamp.light_color = Color(0.87, 0.93, 1.0)
		add_child(lamp)
		lamp.look_at(Vector3(lamp.position.x, 0.9, -_length - 1.1))


func _shell() -> void:
	_panel("Floor", Vector2(ROOM_WIDTH, 31.5), Vector3(0, -0.6, -6.25), "floor")
	# The ceiling is visual only: the broad key remains a soft interior fill.
	var ceiling := _panel("Ceiling", Vector2(ROOM_WIDTH, 31.5), Vector3(0, CEILING, -6.25), "ceiling")
	ceiling.rotation.x = PI
	ceiling.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var back := _panel("BackWall", Vector2(ROOM_WIDTH, 5.4), Vector3(0, 2.1, -22.0), "wall")
	back.rotation.x = PI / 2.0
	var front := _panel("LoungeWall", Vector2(ROOM_WIDTH, 5.4), Vector3(0, 2.1, 9.5), "wall")
	front.rotation.x = -PI / 2.0
	var wall_fins: Array[Transform3D] = []
	for side: float in [-1.0, 1.0]:
		var wall := _panel("SideWall", Vector2(5.4, 31.5), Vector3(side * ROOM_WIDTH * 0.5, 2.1, -6.25), "wall")
		wall.rotation.z = side * PI / 2.0
		var lower := _panel("BrickWainscot", Vector2(1.65, 31.5), Vector3(side * 7.775, 0.225, -6.25), "brick")
		lower.rotation.z = side * PI / 2.0
		_box(Vector3(0.15, 0.16, 31), Vector3(side * 7.65, 0.05, -6.25), "trim", 0.025)
		_box(Vector3(0.035, 0.045, 30.8), Vector3(side * 7.54, 0.16, -6.25), "pink")
		_box(Vector3(1.8, 0.58, 26.5), Vector3(side * 6.45, -0.3, -8.75), "side")
		_box(Vector3(0.055, 0.055, 30.8), Vector3(side * 7.72, 3.65, -6.25), "cyan")
		for z: float in [-16.0, -7.0, 2.0]:
			_box(Vector3(0.12, 1.55, 2.6), Vector3(side * 7.66, 2.15, z), "trim", 0.06)
			var art := _panel("WallLightbox", Vector2(1.35, 2.4), Vector3(side * 7.58, 2.15, z), "lightbox")
			art.rotation.z = side * PI / 2.0
		for i in 40:
			wall_fins.append(Transform3D(Basis.IDENTITY, Vector3(side * 7.68, 1.15, 7.8 - i * 0.74)))
	_batch_box(Vector3(0.09, 1.45, 0.06), "wood", wall_fins)
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
		_box(Vector3(side_width, 0.32, length_m), Vector3(x + side * (_spacing * 0.5 - side_width * 0.5), 0.06, center), "side")
		_box(Vector3(0.018, 0.012, -end), Vector3(x + side * (_half + _gutter + 0.02), 0.225, end * 0.5), "player%d" % player)
	_box(Vector3(_spacing, 0.1, 1.6), Vector3(x, -0.55, end - 0.8), "rubber")
	_box(Vector3(_spacing, 1.4, 0.2), Vector3(x, 0.1, end - 1.6), "rubber")
	_box(Vector3(_half * 2.0, 0.004, 0.03), Vector3(x, 0.004, 0), "mark")
	var targets: Array[Transform3D] = []
	for k in 7:
		targets.append(Transform3D(Basis.IDENTITY, Vector3(x + (k - 3) * 0.13, 0.004, -4.6 - absi(k - 3) * 0.3)))
	var arrows := _batch(_arrow, _materials["mark"], targets)
	arrows.name = "GuideArrows"
	var dot := CylinderMesh.new()
	dot.top_radius = 0.014
	dot.bottom_radius = 0.014
	dot.height = 0.003
	dot.radial_segments = 12
	var dots: Array[Transform3D] = []
	for z: float in [0.65, 3.0]:
		for k in 7:
			dots.append(Transform3D(Basis.IDENTITY, Vector3(x + (k - 3) * 0.13, 0.004, z)))
	_batch(dot, _materials["mark"], dots).name = "GuideDots"
	_box(Vector3(_spacing - 0.02, 1.52, 0.24), Vector3(x, 1.8, end - 0.48), "trim", 0.045)
	var mask := _panel("MaskingArtwork", Vector2(_spacing - 0.1, 1.4), Vector3(x, 1.8, end - 0.34), "panel%d" % player)
	mask.rotation.x = PI / 2.0
	for y: float in [1.065, 2.535]:
		_box(Vector3(_spacing - 0.08, 0.035, 0.045), Vector3(x, y, end - 0.31), "player%d" % player, 0.012)
	for side: float in [-1.0, 1.0]:
		_box(Vector3(0.035, 1.48, 0.045), Vector3(x + side * (_spacing - 0.08) * 0.5, 1.8, end - 0.31), "player%d" % player, 0.012)
	var label := Label3D.new()
	label.text = "P%d" % player # no-i18n
	label.font = label_font
	label.font_size = 128
	label.pixel_size = 0.0055
	label.outline_size = 3
	label.modulate = RSUi.TEXT
	label.position = Vector3(x - 0.67, 1.8, end - 0.28)
	add_child(label)


func _arrow_mesh() -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	# A flat inlaid chevron reads at an oblique camera angle; no physical volume is added.
	var points := [Vector3(-0.048, 0, 0.11), Vector3(0, 0, -0.15), Vector3(0.048, 0, 0.11)]
	for point: Vector3 in points:
		tool.set_normal(Vector3.UP)
		tool.add_vertex(point)
	return tool.commit()


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
		_box(Vector3(0.62, 0.42, 1.8), Vector3(x, 0.23, 2.5), "shell", 0.12).name = "BallReturnBase"
		_box(Vector3(0.51, 0.12, 1.46), Vector3(x, 0.49, 2.62), "rubber", 0.055)
		_box(Vector3(0.7, 0.76, 0.68), Vector3(x, 0.4, 1.55), "shell", 0.16).name = "BallReturnHood"
		_box(Vector3(0.46, 0.24, 0.035), Vector3(x, 0.48, 1.91), "rubber", 0.09)
		_box(Vector3(0.36, 0.025, 0.025), Vector3(x, 0.69, 1.9), "cyan", 0.01)
		var rails: Array[Transform3D] = []
		for offset: float in [-0.16, 0.16]:
			rails.append(Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3(x + offset, 0.59, 2.65)))
		_batch(_cylinder(0.022, 1.27), _materials["metal"], rails)
		var ball := SphereMesh.new()
		ball.radius = 0.109
		ball.height = 0.218
		_batch(ball, ball_material(CYAN if x > 0 else PINK), [Transform3D(Basis.IDENTITY, Vector3(x, 0.69, 2.65)), Transform3D(Basis.IDENTITY, Vector3(x, 0.69, 3.05))])
	var seats: Array[Transform3D] = []
	var backs: Array[Transform3D] = []
	var legs: Array[Transform3D] = []
	var arms: Array[Transform3D] = []
	for lane in 4:
		for side: float in [-0.36, 0.36]:
			var x := (lane - 1.5) * _spacing + side
			seats.append(Transform3D(Basis.IDENTITY, Vector3(x, 0.43, 7.1)))
			backs.append(Transform3D(Basis(Vector3.RIGHT, -0.1), Vector3(x, 0.76, 7.4)))
			legs.append(Transform3D(Basis.IDENTITY, Vector3(x, 0.19, 7.15)))
		for side: float in [-0.73, 0.73]:
			arms.append(Transform3D(Basis.IDENTITY, Vector3((lane - 1.5) * _spacing + side, 0.59, 7.12)))
	_batch_round(Vector3(0.66, 0.15, 0.72), 0.07, "seat", seats).name = "SeatCushions"
	_batch_round(Vector3(0.66, 0.59, 0.18), 0.08, "seat", backs).name = "SeatBacks"
	_batch_round(Vector3(0.1, 0.22, 0.58), 0.045, "seat", arms)
	_batch(_cylinder(0.045, 0.38), _materials["metal"], legs)
	for x: float in [-_spacing, 0.0, _spacing]:
		_batch(_cylinder(0.38, 0.065), _materials["wood"], [Transform3D(Basis.IDENTITY, Vector3(x, 0.59, 6.85))])
		_batch(_cylinder(0.035, 0.55), _materials["metal"], [Transform3D(Basis.IDENTITY, Vector3(x, 0.28, 6.85))])
		_batch(_cylinder(0.25, 0.04), _materials["trim"], [Transform3D(Basis.IDENTITY, Vector3(x, 0.02, 6.85))])


func _fixtures() -> void:
	var rails: Array[Transform3D] = []
	var lights: Array[Transform3D] = []
	var beams: Array[Transform3D] = []
	var baffles: Array[Transform3D] = []
	var acoustic: Array[Transform3D] = []
	for i in 36:
		baffles.append(Transform3D(Basis.IDENTITY, Vector3(-4.9 + i * 0.28, 4.59, -6.2)))
	for row in 4:
		var z := 5.0 - row * 7.2
		beams.append(Transform3D(Basis.IDENTITY, Vector3(0, 4.6, z)))
		for x: float in [-6.2, 6.2]:
			acoustic.append(Transform3D(Basis.IDENTITY, Vector3(x, 4.53, z)))
	for z: float in POOL_ROWS:
		for x: float in [-_spacing, _spacing]:
			rails.append(Transform3D(Basis.IDENTITY, Vector3(x, 4.23, z)))
			lights.append(Transform3D(Basis.IDENTITY, Vector3(x, 4.13, z)))
	_batch_box(Vector3(0.065, 0.22, 28.8), "wood", baffles).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_batch_round(Vector3(1.6, 0.16, 2.9), 0.035, "acoustic", acoustic).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_batch_box(Vector3(15.4, 0.12, 0.15), "trim", beams).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_batch_round(Vector3(0.6, 0.17, 1.8), 0.075, "metal", rails).name = "LampHousings"
	_batch_round(Vector3(0.48, 0.065, 1.65), 0.03, "white", lights).name = "LampDiffusers"
	var spots: Array[Transform3D] = []
	var bulbs: Array[Transform3D] = []
	var stems: Array[Transform3D] = []
	var direction := Vector3(0, -2.45, -1.9).normalized()
	var facing := Basis(Vector3.RIGHT, -2.482)
	for lane in 4:
		var at := Vector3((lane - 1.5) * _spacing, 3.35, -_length + 0.8)
		spots.append(Transform3D(facing, at))
		bulbs.append(Transform3D(facing, at + direction * 0.13))
		stems.append(Transform3D(Basis.IDENTITY, Vector3(at.x, 3.93, at.z)))
	_batch(_cylinder(0.09, 0.2), _materials["trim"], spots)
	_batch(_cylinder(0.065, 0.025), _materials["white"], bulbs)
	_batch_box(Vector3(0.035, 1.0, 0.035), "metal", stems)


func _box(size: Vector3, at: Vector3, material: String, bevel := 0.0) -> MeshInstance3D:
	var mesh: Mesh
	if bevel > 0:
		mesh = RSMeshUtil.rounded_box(size, bevel, 6, 16)
	else:
		var box := BoxMesh.new()
		box.size = size
		mesh = box
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


func _batch_box(size: Vector3, material: String, transforms: Array[Transform3D]) -> MultiMeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _batch(mesh, _materials[material], transforms)


func _batch_round(size: Vector3, radius: float, material: String, transforms: Array[Transform3D]) -> MultiMeshInstance3D:
	return _batch(RSMeshUtil.rounded_box(size, radius, 6, 16), _materials[material], transforms)


func _cylinder(radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 20
	return mesh


func _batch(mesh: Mesh, material: Material, transforms: Array[Transform3D]) -> MultiMeshInstance3D:
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
	return instance
