extends Node
## B1 resource/geometry checks and unchanged real bowling lifecycle, with isolated bot data.
## Optional screenshots capture the real split screens and a separate hall inspection camera.

var _checks := 0
var _failures := 0
var _scene: Variant


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("FAIL: " + message)


func _frames(count := 6) -> void:
	for _i in count:
		await get_tree().process_frame


func _wait_phase(phase: int) -> void:
	for _i in 1200:
		await get_tree().process_frame
		if _scene.phase == phase:
			return
	_check(false, "bowling reaches the requested real game phase")


func _missing_hdri() -> void:
	var hall := RSBowlingHall.new()
	add_child(hall)
	hall._lighting("res://tests/bowling_environment_missing.hdr")
	var world := hall.find_children("*", "WorldEnvironment", true, false)[0] as WorldEnvironment
	var environment := world.environment
	_check(environment.background_mode == Environment.BG_COLOR and environment.background_color == Color(0.08, 0.09, 0.16), "missing optional HDRI uses the explicit indoor background")
	_check(environment.sky == null, "missing optional HDRI creates no empty sky")
	_check(environment.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR and environment.ambient_light_energy > 0 and environment.ambient_light_sky_contribution == 0, "missing optional HDRI retains independent indoor ambient light")
	_check(environment.reflected_light_source == Environment.REFLECTION_SOURCE_DISABLED, "missing optional HDRI disables sky reflections")
	hall.queue_free()
	await _frames()


func _collision_layout() -> void:
	var bodies: Array[StaticBody3D] = []
	for child: Node in _scene.get_children():
		if child is StaticBody3D:
			bodies.append(child)
	_check(bodies.size() == 28, "original seven collision boxes per lane")
	# Independent pre-B1 dimensions and friction, in construction order.
	var sizes := [Vector3(1.05, 0.1, 23.79), Vector3(0.235, 0.1, 19.29), Vector3(0.54, 0.32, 23.79),
		Vector3(0.235, 0.1, 19.29), Vector3(0.54, 0.32, 23.79), Vector3(2.6, 0.1, 1.6), Vector3(2.6, 1.4, 0.2)]
	var offsets := [Vector3(0, -0.05, -7.395), Vector3(-0.6425, -0.15, -9.645), Vector3(-1.03, 0.06, -7.395),
		Vector3(0.6425, -0.15, -9.645), Vector3(1.03, 0.06, -7.395), Vector3(0, -0.55, -20.09), Vector3(0, 0.1, -20.89)]
	var friction := [0.08, 0.3, 0.3, 0.3, 0.3, 0.8, 0.9]
	for lane in 4:
		for item in 7:
			var body := bodies[lane * 7 + item]
			var shape := body.get_child(0) as CollisionShape3D
			_check(shape.shape is BoxShape3D and (shape.shape as BoxShape3D).size.is_equal_approx(sizes[item]), "collision box retains original size")
			_check(body.position.is_equal_approx(offsets[item] + Vector3((lane - 1.5) * 2.6, 0, 0)), "collision box retains original position")
			_check(is_equal_approx(body.physics_material_override.friction, friction[item]), "rolling friction remains unchanged")


func _resources(hall: RSBowlingHall) -> void:
	_check(hall.find_children("*", "CollisionObject3D", true, false).is_empty(), "decorative hall has no physics")
	_check(hall.find_children("*", "MultiMeshInstance3D", true, false).size() >= 10, "repeated arrows, seating and lights are batched")
	for id: String in ["plywood", "metal_plate", "painted_plaster_wall", "large_grey_tiles", "red_brick", "white_plaster_02", "beam_wall_01"]:
		for map: Variant in RSPbr.maps(id):
			_check(map is Texture2D, "registered PBR map resolves: " + id)
	var world := hall.find_children("*", "WorldEnvironment", true, false)[0] as WorldEnvironment
	var environment := world.environment
	_check(environment.sky.sky_material is PanoramaSkyMaterial and (environment.sky.sky_material as PanoramaSkyMaterial).panorama != null, "registered HDRI reflection source resolves")
	_check(environment.reflected_light_source == Environment.REFLECTION_SOURCE_SKY, "indoor PBR has sky reflections")
	_check(is_zero_approx(environment.glow_bloom), "glow does not bloom ordinary non-emissive surfaces")
	var quality := RSSettings.quality
	RSSettings.quality = 0
	RSSettings.environment(environment)
	_check(not environment.ssao_enabled and not environment.glow_enabled, "low quality disables requested screen effects")
	RSSettings.quality = quality
	RSSettings.environment(environment)
	_check(environment.ssao_enabled == (quality >= 1) and environment.glow_enabled == (quality >= 1), "quality restoration restores requested screen effects")
	var key := hall.find_children("*", "DirectionalLight3D", true, false)[0] as DirectionalLight3D
	_check(key.shadow_enabled and key.light_angular_distance == 0, "pin shadows remain on with ordinary filtering at medium quality")
	_check(hall.find_children("LanePool*", "SpotLight3D", true, false).size() == 6, "six actual spotlights align with visible lane luminaires")
	_check(hall.find_children("PinDeckLight*", "SpotLight3D", true, false).size() == 4, "each masking unit has independent pin-deck lighting")
	for label: Label3D in hall.find_children("*", "Label3D", true, false):
		var font := label.font as FontVariation
		var shared_font := RSUi.font_label() as FontVariation
		_check(font != null and font != shared_font and font.base_font != shared_font.base_font, "3D signage owns its font copy without changing shared UI resources")
		_check(font.base_font is FontFile and (font.base_font as FontFile).multichannel_signed_distance_field, "world signage renders with MSDF")
		_check((font.base_font as FontFile).msdf_pixel_range >= label.outline_size * 2, "MSDF range contains the complete outline distance on both sides")
		_check(font.base_font.get_data() == shared_font.base_font.get_data() and font.spacing_glyph == shared_font.spacing_glyph, "signage preserves the bundled glyph source and label spacing")
		_check(label.alpha_cut == Label3D.ALPHA_CUT_OPAQUE_PREPASS and label.outline_size >= 10 and label.outline_modulate == RSUi.INK, "world signs have opaque prepass and dark high-contrast outlines")
	_check(hall.find_children("SignBackground*", "MeshInstance3D", true, false).size() == 4, "four signs have solid dark background plates")
	var cushions := hall.get_node("SeatCushions") as MultiMeshInstance3D
	_check(cushions.multimesh.mesh is ArrayMesh and cushions.multimesh.instance_count == 8, "eight seats share a procedural bevelled cushion mesh")
	_check((hall.get_node("LampHousings") as MultiMeshInstance3D).multimesh.mesh is ArrayMesh, "luminaires have rounded three-dimensional housings")
	for lane in 4:
		var light := hall._materials["player%d" % (lane + 1)] as StandardMaterial3D
		_check(light.emission == RSControllerModel.PLAYER_COLORS[lane + 1], "each lane retains its original distinct player colour")
		var artwork := hall._materials["panel%d" % (lane + 1)] as ShaderMaterial
		_check(artwork.shader == RSBowlingHall.MASK_SHADER and artwork.get_shader_parameter("player_color") == RSControllerModel.PLAYER_COLORS[lane + 1], "masking artwork has its own graphic shader and player colour")
		var surface := hall.get_node("Lane%d" % (lane + 1)) as MeshInstance3D
		_check(surface.material_override is ShaderMaterial and (surface.material_override as ShaderMaterial).shader == RSBowlingHall.LANE_SHADER, "lane uses the dedicated varnish/oil shader")
		var data := surface.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = data[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = data[Mesh.ARRAY_TEX_UV]
		for i in vertices.size():
			var point := surface.to_global(vertices[i])
			_check(absf(point.z - (4.5 - uvs[i].y)) < 0.001, "lane UV metres run from approach toward pit")
			_check(absf(absf(point.x - (lane - 1.5) * 2.6) - 0.525) < 0.001 and absf(point.y - 0.001) < 0.001, "lane top matches original bounds above collision")
	for player: RSPartyGame.Player in _scene.ordered():
		var state: Variant = _scene._bowler(player)
		_check(state.pins.size() == 10 and is_equal_approx(state.ball.mass, 6.5), "ten pins and original ball mass")
		var ball_shape := (state.ball.get_child(0) as CollisionShape3D).shape as SphereShape3D
		_check(is_equal_approx(ball_shape.radius, 0.109) and is_equal_approx(state.ball.physics_material_override.friction, 0.25) and is_equal_approx(state.ball.physics_material_override.bounce, 0.05), "original ball collision and contact material")
		for pin: RigidBody3D in state.pins:
			var material := (pin.get_child(1) as MeshInstance3D).material_override as StandardMaterial3D
			_check(material != null and material.vertex_color_use_as_albedo and material.clearcoat_enabled, "PBR pin lacquer retains red vertex stripes")
			_check(is_equal_approx(pin.mass, 1.5) and pin.center_of_mass == Vector3(0, 0.14, 0), "pin physical mass and centre remain unchanged")
			var pin_shape := (pin.get_child(0) as CollisionShape3D).shape as CylinderShape3D
			_check(is_equal_approx(pin_shape.radius, 0.058) and is_equal_approx(pin_shape.height, 0.38) and is_equal_approx(pin.physics_material_override.friction, 0.45) and is_equal_approx(pin.physics_material_override.bounce, 0.35), "original pin collision and contact material")


func _scores() -> void:
	var frames: int = _scene._frames
	_scene._frames = 5
	var strikes: Array[int] = [10, 10, 10, 10, 10, 10, 10]
	var spares: Array[int] = [5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5]
	var open: Array[int] = [9, 0, 9, 0, 9, 0, 9, 0, 9, 0]
	_check(_scene._total(strikes) == 150, "five perfect frames retain bonus scoring")
	_check(_scene._total(spares) == 75, "five spares retain bonus scoring")
	_check(_scene._total(open) == 45, "open frames retain normal scoring")
	_scene._frames = frames


func _hud_layout() -> void:
	var count: int = _scene._frames
	var states: Array = []
	for player: RSPartyGame.Player in _scene.ordered():
		var state: Variant = _scene._bowler(player)
		states.append([state.rolls.duplicate(), state.frame, state.step])
		state.step = _scene.Step.DONE
	for frames: int in [5, 10]:
		_scene._frames = frames
		for player: RSPartyGame.Player in _scene.ordered():
			var state: Variant = _scene._bowler(player)
			state.rolls.clear()
			for _i in frames + 2:
				state.rolls.append(10)
			state.frame = frames - 1
			player.hud.queue_redraw()
		await _frames()
		for player: RSPartyGame.Player in _scene.ordered():
			var cells: Array = _scene.score_cells.get(player.hud.get_instance_id(), [])
			_check(cells.size() == frames, "actual HUD draws all five/ten score cells")
			for cell: Array in cells:
				_check(Rect2(Vector2.ZERO, player.hud.size).encloses(cell[0]), "score cells fit the real split-screen HUD")
				_check(not (cell[1] as Array).is_empty(), "actual score cell draws frame, roll and cumulative numbers")
				for row: Array in cell[1]:
					_check((cell[0] as Rect2).grow(0.5).encloses(row[1]), "actual enlarged scoreboard glyphs fit their own cell: %s %s in %s" % [row[0], row[1], cell[0]])
	_scene._frames = count
	for i in states.size():
		var state: Variant = _scene._bowler(_scene.ordered()[i])
		state.rolls.assign(states[i][0])
		state.frame = states[i][1]
		state.step = states[i][2]
	var label_font := RSUi.font_label()
	_check(label_font.has_char(0x4fdd) and label_font.has_char(0x9f84), "shared label font resolves Chinese fallback glyphs")


func _intro() -> void:
	await _wait_phase(RSPartyGame.Phase.COUNTDOWN)
	_scene.set_process(false)
	var count: int = _scene.get_child_count()
	for fraction: float in [0.0, 0.48, 1.0]:
		_scene.phase_time = _scene.INTRO * fraction
		for player: RSPartyGame.Player in _scene.ordered():
			_scene._place_cam(player, 0.0, true)
			var state: Variant = _scene._bowler(player)
			var expected := Vector3(5.7, 2.7, 8.5)
			var fov := 62.0
			if fraction == 0.48:
				expected = Vector3(state.lane_x + 0.35, 1.3, -15.0)
				fov = 45.0
			elif fraction == 1.0:
				expected = Vector3(state.lane_x + state.pos * 0.5, 1.5, 3.2)
				fov = 50.0
			_check(player.cam.position.distance_to(expected) < 0.001, "intro anchors join the lounge, pin detail and original aim camera")
			_check(is_equal_approx(player.cam.fov, fov), "intro FOV joins both segments and returns to the original aim FOV")
			_check(player.cam.global_transform.is_finite() and player.score == 0, "intro keeps finite cameras and unchanged scores")
	var shake := RSSettings.camera_shake
	_scene.phase_time = _scene.INTRO * 0.3
	for player: RSPartyGame.Player in _scene.ordered():
		RSSettings.camera_shake = true
		_scene._place_cam(player, 0.0, true)
		var transform := player.cam.transform
		RSSettings.camera_shake = false
		_scene._place_cam(player, 0.0, true)
		_check(player.cam.transform.is_equal_approx(transform), "smooth venue flyover introduces no jitter with either camera-shake setting")
	RSSettings.camera_shake = shake
	_scene.phase_time = _scene.INTRO * 0.18
	_scene._countdown_process(0.0)
	await _capture("intro")
	_scene.set_process(true)
	_scene.open_pause()
	var time: float = _scene.phase_time
	var pose: Transform3D = _scene.ordered()[0].cam.transform
	await _frames()
	_check(get_tree().paused and _scene.phase_time == time and _scene.ordered()[0].cam.transform == pose, "pause freezes venue flyover and camera")
	_scene.ui.pause.close()
	_check(_scene.get_child_count() == count, "flyover reuses the loaded venue")
	_scene.set_process(true)


func _play_cameras() -> void:
	for player: RSPartyGame.Player in _scene.ordered():
		var state: Variant = _scene._bowler(player)
		var step: int = state.step
		state.step = _scene.Step.AIM
		_scene._place_cam(player, 0.0, true)
		_check(player.cam.position.is_equal_approx(Vector3(state.lane_x + state.pos * 0.5, 1.5, 3.2)) and is_equal_approx(player.cam.fov, 50), "play restores the original aim pose and FOV")
		_check(state.look.is_equal_approx(Vector3(state.lane_x, 0.2, -18.29 * 0.6)), "play restores the original aim target")
		state.step = _scene.Step.ROLLING
		_scene._place_cam(player, 0.0, true)
		var z := clampf(state.ball.global_position.z, -18.29 + 4.5, 0.0)
		_check(player.cam.position.is_equal_approx(Vector3(state.lane_x, 1.1, z + 2.6)) and is_equal_approx(player.cam.fov, 50), "rolling retains the original chase pose and FOV")
		_check(state.look.is_equal_approx(Vector3(state.lane_x, 0.15, -18.29 - 0.2)), "rolling retains the original chase target")
		state.step = step
		_scene._place_cam(player, 0.0, true)


func _capture(suffix: String) -> void:
	var prefix := OS.get_environment("RS_BOWLING_SCREENSHOT")
	if prefix.is_empty():
		return
	await _frames(12)
	await RenderingServer.frame_post_draw
	_check(get_viewport().get_texture().get_image().save_png(prefix + "-" + suffix + ".png") == OK, "native split-screen screenshot saved")


func _hall_capture() -> void:
	var prefix := OS.get_environment("RS_BOWLING_SCREENSHOT")
	if prefix.is_empty():
		return
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1600, 900)
	viewport.world_3d = _scene.get_world_3d()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	RSSettings.apply_viewport(viewport)
	add_child(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.position = Vector3(7.1, 3.4, 8.8)
	camera.look_at(Vector3(0, 1.2, -7.5))
	camera.fov = 68
	await _frames(12)
	await RenderingServer.frame_post_draw
	_check(viewport.get_texture().get_image().save_png(prefix + "-hall.png") == OK, "inspection camera captures seating, ball return and hall")
	viewport.queue_free()


func _run() -> void:
	await _missing_hdri()
	# Observe the actual drawing calls; do not duplicate scoreboard geometry in the test.
	var probe := GDScript.new()
	probe.source_code = """extends "res://scenes/bowling/bowling_game.gd"
var score_cells: Dictionary = {}
func _draw_hud(h: PlayerHud, p: Player, k: float) -> void:
	score_cells[h.get_instance_id()] = []
	super._draw_hud(h, p, k)
func draw_box(ci: CanvasItem, rect: Rect2, color: Color, radius: float = RSUi.RADIUS) -> void:
	if ci is PlayerHud and color == RSUi.PANEL_BG:
		score_cells[ci.get_instance_id()].append([rect, []])
	super.draw_box(ci, rect, color, radius)
func draw_text(ci: CanvasItem, text: String, pos: Vector2, size: float, color: Color, center := false, right := false, f: Font = null) -> void:
	if ci is PlayerHud and not score_cells[ci.get_instance_id()].is_empty():
		var cell: Array = score_cells[ci.get_instance_id()][-1]
		if pos.y >= cell[0].position.y and pos.y <= cell[0].end.y:
			var used: Font = font if f == null else f
			var width: float = 2.0 * minf(pos.x - 4.0, ci.size.x - pos.x - 4.0) if center else (pos.x - 4.0 if right else ci.size.x - pos.x - 4.0)
			var fs := RSUi.fit_text_size(text, size, width, pos.y - 4.0, ci.size.y - 8.0, used)
			var w := used.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var at := pos - Vector2(w * (0.5 if center else (1.0 if right else 0.0)), used.get_ascent(fs))
			cell[1].append([text, Rect2(at, Vector2(w, used.get_height(fs)))])
	super.draw_text(ci, text, pos, size, color, center, right, f)
"""
	_check(probe.reload() == OK, "actual bowling HUD observer compiles")
	_scene = probe.new()
	get_tree().root.add_child(_scene)
	get_tree().current_scene = _scene
	await _intro()
	await _wait_phase(RSPartyGame.Phase.PLAY)
	_scene.set_process(false)
	_scene.set_physics_process(false)
	var hall := _scene.get_node("BowlingHall") as RSBowlingHall
	_collision_layout()
	_resources(hall)
	_scores()
	_play_cameras()
	await _hud_layout()
	var nodes := hall.get_child_count()
	var materials: Array = hall._materials.values().map(func(material: Material) -> int: return material.get_instance_id())
	await _capture("play")
	_scene.open_pause()
	var time: float = _scene.phase_time
	await _frames()
	_check(get_tree().paused and _scene.phase_time == time, "pause freezes the original game clock")
	_scene.ui.pause.close()
	await _hall_capture()
	_scene.restart_round()
	_scene.set_process(true)
	await _wait_phase(RSPartyGame.Phase.COUNTDOWN)
	_scene.set_process(false)
	_check(hall.get_child_count() == nodes and materials == hall._materials.values().map(func(material: Material) -> int: return material.get_instance_id()), "restart reuses hall nodes, meshes and materials")
	for player: RSPartyGame.Player in _scene.ordered():
		var state: Variant = _scene._bowler(player)
		_check(player.score == 0 and state.rolls.is_empty() and state.standing.count(true) == 10, "restart restores rack and score")
		_check(player.cam.global_transform.is_finite(), "2/4-player camera remains valid")
	var weak: WeakRef = weakref(hall)
	get_tree().current_scene = null
	_scene.queue_free()
	await _frames()
	_check(weak.get_ref() == null, "hall releases with the game scene")
	print("RS_BOWLING_ENVIRONMENT_TESTS: %d checks, %d failures" % [_checks, _failures])
	RSExit.quit(get_tree(), 1 if _failures else 0)
