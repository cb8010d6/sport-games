extends Node
## Podium geometry/ranking/frustum checks and real three-sport results lifecycle.

const CASES := [
	[[100], [1]], [[100, 80], [1, 2]], [[100, 100], [1, 1]],
	[[100, 80, 60], [1, 2, 3]], [[100, 100, 50], [1, 1, 3]], [[100, 80, 80], [1, 2, 2]],
	[[100, 80, 60, 0], [1, 2, 3, 4]], [[100, 100, 80, 80], [1, 1, 3, 3]],
	[[0, 0, 0, 0], [1, 1, 1, 1]], [[0, -10, -10, -100], [1, 2, 2, 4]],
	[[-10, -10, -10, -10], [1, 1, 1, 1]],
	[[4000000000, 3000000000, 3000000000, -4000000000], [1, 2, 2, 4]],
]
const PROFILES := [
	{"steps": [[0, 0.8], [-1.35, 0.55], [1.35, 0.36]], "size": Vector2(1.3, 1.2), "extra": Vector3(2.4, 0, 0.6), "spacing": 0.9, "buried": 0.0,
		"side": 1.6, "side_speed": -0.12, "distance": 8.5, "dolly": -0.3, "height": 1.7, "look_side": 1.75, "look_height": 1.35},
	{"steps": [[0, 0.8], [-1.5, 0.55], [1.5, 0.36]], "size": Vector2(1.4, 2.1), "extra": Vector3(2.6, 0, 0.8), "spacing": 1.0, "buried": 1.0,
		"side": 2.4, "side_speed": -0.12, "distance": 8.5, "dolly": -0.3, "height": 1.8, "look_side": 2.7, "look_height": 1.3},
	{"steps": [[0, 0.8], [-1.5, 0.55], [1.5, 0.36]], "size": Vector2(1.4, 1.6), "extra": Vector3(2.7, 0, 0.7), "spacing": 1.0, "buried": 0.0,
		"side": -2.6, "side_speed": 0.12, "distance": 6.2, "dolly": -0.15, "height": 3.5, "look_side": 1.4, "look_height": 1.25},
]

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


func _inside(camera: Camera3D, world: Vector3, left_half := true) -> void:
	var at := camera.unproject_position(world)
	var size := camera.get_viewport().get_visible_rect().size
	_check(not camera.is_position_behind(world) and at.x >= size.x * 0.03 - 2 and at.x <= size.x * (0.47 if left_half else 0.97) + 2 and at.y >= size.y * 0.05 - 2 and at.y <= size.y * 0.95 + 2, "podium/player bounds fit the left side, clear of results")


func _math() -> void:
	var parent := Node3D.new()
	add_child(parent)
	parent.transform = Transform3D(Basis(Vector3.UP, 0.7), Vector3(50, 3, -20))
	var camera := Camera3D.new()
	parent.add_child(camera)
	camera.fov = 42
	for profile: Dictionary in PROFILES:
		var podium := RSPodium.new()
		parent.add_child(podium)
		podium.transform = Transform3D(Basis(Vector3.UP, -0.2), Vector3(3, 1, 4))
		podium.configure(profile.steps, profile.size, profile.extra, profile.spacing, ThemeDB.fallback_font, profile.buried)
		_check(not podium.visible and podium.get_child_count() == 12, "four reusable slots are built once, initially hidden")
		var meshes: Array = podium._blocks.map(func(block: MeshInstance3D) -> int: return block.mesh.get_instance_id())
		var trims: Array = podium._trims.map(func(trim: StandardMaterial3D) -> int: return trim.get_instance_id())
		for item: Array in CASES:
			var scores := PackedInt64Array(item[0])
			var ranks: Array = item[1]
			podium.present(scores)
			_check(podium.visible, "nonempty standings show podium")
			for i in scores.size():
				var rank: int = ranks[i]
				_check(podium.rank(i) == rank and podium.cheer(i) == (1.0 if rank == 1 else (0.5 if rank <= 3 else 0.0)), "ties share the result rank and celebration")
				var x: float = float(profile.steps[i][0]) if i < 3 else profile.extra.x
				if i >= 3 and rank <= 3:
					x = maxf(x, float(profile.steps[2][0]) + profile.size.x + 0.1)
				var height: float = float(profile.steps[rank - 1][1]) if rank <= 3 else 0
				var expected := podium.global_transform * Vector3(x, height, 0 if i < 3 else profile.extra.z)
				_check(podium.spot(i).distance_to(expected) < 0.001, "spot uses correct rank height and world transform")
				_check(podium._blocks[i].visible == (rank <= 3), "fourth step is visible only for a medal tie")
				if rank <= 3:
					var block := podium._blocks[i]
					_check(is_equal_approx(block.position.y + (block.mesh as BoxMesh).size.y * 0.5, height), "feet meet the actual mesh surface, including buried bases")
					_check(podium._labels[i].text == str(rank) and podium._bands[i].material_override == podium._trims[rank - 1], "tied labels and medals match ranks")
			_check(podium.get_child_count() == 12 and meshes == podium._blocks.map(func(block: MeshInstance3D) -> int: return block.mesh.get_instance_id()) and trims == podium._trims.map(func(trim: StandardMaterial3D) -> int: return trim.get_instance_id()), "present reuses nodes, meshes and materials")
			for elapsed: float in [-1, 0, 1, 3, 6, 10]:
				podium.apply_camera(camera, elapsed, profile.side, profile.side_speed, profile.distance, profile.dolly, profile.height, profile.look_side, profile.look_height)
				var time := clampf(elapsed, 0, 6)
				var distance: float = profile.distance + time * profile.dolly
				var expected: Vector3 = podium.global_position + podium.global_basis.z * distance + podium.global_basis.x * (profile.side + time * profile.side_speed) + Vector3.UP * profile.height
				var target: Vector3 = podium.global_position + podium.global_basis.x * (profile.look_side * distance / profile.distance) + Vector3.UP * profile.look_height
				_check(camera.global_position.distance_to(expected) < 0.001 and (-camera.global_basis.z).dot((target - expected).normalized()) > 0.99999, "configured camera profile and six-second endpoint are retained")
				var basis := camera.global_basis
				for keep: Camera3D.KeepAspect in [Camera3D.KEEP_HEIGHT, Camera3D.KEEP_WIDTH]:
					camera.keep_aspect = keep
					podium.fit_left(camera)
					for point: Vector3 in podium._bounds:
						_inside(camera, podium.to_global(point))
					_check(camera.global_basis.is_equal_approx(basis) and camera.fov == 42, "framing preserves camera orientation and FOV")
					var position := camera.global_position
					podium.fit_left(camera)
					_check(camera.global_position.distance_to(position) < 0.001, "framing is stable on repeated updates")
			podium.reset()
			_check(not podium.visible and podium._ranks.is_empty() and podium._bounds.is_empty(), "reset clears the previous ceremony")
		podium.present(PackedInt64Array())
		_check(not podium.visible, "no participants produce no phantom winners")
		podium.apply_camera(camera, 0, 0, 0, 0, 0, 1, 0, 2)
		_check(camera.global_transform.is_finite() and absf(camera.global_basis.determinant() - 1) < 0.001, "zero-distance vertical camera has a valid basis")
		podium.queue_free()
		await _frames(1)
	parent.queue_free()
	await _frames(1)


func _state(id: String, p: RSPartyGame.Player) -> Variant:
	match id:
		"skate": return _scene._rider(p)
		"ski": return _scene._racer(p)
		_: return _scene._sh(p)


func _rig(id: String, p: RSPartyGame.Player) -> Node3D:
	var state: Variant = _state(id, p)
	return state.rig if id == "basketball" else state.sk.rig


func _wait_phase(phase: int) -> void:
	for _i in 2400:
		await get_tree().process_frame
		if _scene.phase == phase:
			return
	_check(false, "real scene reaches requested phase")


func _capture(suffix: String) -> void:
	var prefix := OS.get_environment("RS_PODIUM_SCREENSHOT")
	if prefix.is_empty():
		return
	# Let the existing procedural celebration settle before inspecting its rendered pose.
	for _i in 90:
		_scene._podium_step(1.0 / 60.0)
	await _frames()
	await RenderingServer.frame_post_draw
	_check(get_viewport().get_texture().get_image().save_png(prefix + "-" + suffix + ".png") == OK, "native podium screenshot saved")


func _game(id: String) -> void:
	_scene = (load(RSCatalog.find_game(id)["scene"]) as PackedScene).instantiate()
	get_tree().root.add_child(_scene)
	get_tree().current_scene = _scene
	await _wait_phase(RSPartyGame.Phase.COUNTDOWN)
	for pattern in 4:
		_scene.phase_time = _scene._countdown_time()
		await _wait_phase(RSPartyGame.Phase.PLAY)
		await _frames(20)
		_scene.set_process(false)
		for p: RSPartyGame.Player in _scene.ordered():
			p.score = (4 - p.c.player) * 10 if pattern == 0 else (50 if p.c.player <= 2 else 0)
			if pattern == 2:
				p.score = 0
			elif pattern == 3:
				p.score = 4000000000 if p.c.player == 1 else -4000000000
			var state: Variant = _state(id, p)
			state.post = -1.0
			state.clip = state.rec.slice(-2) if pattern == 0 else []
		_scene.finish_round()
		var scores: Array = _scene.ordered().map(func(p: RSPartyGame.Player) -> int: return p.score)
		_scene.phase_time = _scene._podium_at + 2.0
		_scene.set_process(true)
		await _frames(2)
		_scene.set_process(false)
		_check(_scene._podium_on and _scene._podium.visible and not _scene.views.visible and _scene.lobby_cam.current, "real results hand over from replay to shared podium")
		_check(_scene.ui.results_panel.visible and _scene.ui.results_panel.anchor_left == 0.5, "results appear on the right after the original delay")
		_check(_scene._podium_order == _scene.ranked_players(), "ceremony uses the same deterministic order as results")
		for i in _scene._podium_order.size():
			var p: RSPartyGame.Player = _scene._podium_order[i]
			var place := 1
			for score: int in scores:
				if score > p.score:
					place += 1
			_check(_scene._podium.rank(i) == place, "real tied rank matches competition ranking")
			var rig := _rig(id, p)
			var at: Vector3 = _scene._podium_spot(i)
			_check(rig.global_position.distance_to(at - (Vector3.UP * RSSkaterRig.DECK_Y if id == "skate" else Vector3.ZERO)) < 0.001, "actor stands on the actual shared step or terrain")
			if id == "basketball":
				_check(rig.move == (RSBallerRig.Move.CHEER if place == 1 else (RSBallerRig.Move.CELEBRATE if place <= 3 else RSBallerRig.Move.SAD)), "basketball shares celebration for tied champions")
				_check(not _state(id, p).rp_ball.visible, "replay ball hides for ceremony")
			else:
				_check(rig.cheer == (1.0 if place == 1 else (0.5 if place <= 3 else 0.0)), "ski/skate share celebration for tied champions")
		for elapsed: float in [0, 3, 6, 10]:
			_scene.phase_time = _scene._podium_at + elapsed
			_scene._podium_step(0.0)
			for i in _scene._podium_order.size():
				var at: Vector3 = _scene._podium_spot(i)
				_inside(_scene.lobby_cam, at)
				_inside(_scene.lobby_cam, at + Vector3.UP * 2.2)
				if id == "basketball":
					var camera: Vector3 = _scene.lobby_cam.global_position
					var fence_z := RSBallCourt.ROOF.end.y + 0.15
					var crossing := (fence_z - camera.z) / (at.z - camera.z)
					_check(crossing <= 0 or crossing >= 1 or camera.lerp(at, crossing).y > RSBallCourt.PARAPET + 1.21, "camera sees feet over the front glass handrail")
		_scene.phase_time = _scene._podium_at + 3.0
		_scene._podium_step(0.0)
		if pattern in [0, 2]:
			await _capture("normal" if pattern == 0 else "tie")
		_check(scores == _scene.ordered().map(func(p: RSPartyGame.Player) -> int: return p.score), "ceremony does not change scores")
		_scene.set_process(true)
		_scene.open_pause()
		var time: float = _scene.phase_time
		var pose: Transform3D = _scene.lobby_cam.global_transform
		await _frames()
		_check(get_tree().paused and _scene.phase_time == time and _scene.lobby_cam.global_transform == pose, "pause freezes ceremony and camera")
		_scene.ui.pause.close()
		_scene.restart_round()
		await _wait_phase(RSPartyGame.Phase.COUNTDOWN)
		_check(not _scene._podium.visible and _scene._podium._ranks.is_empty() and _scene._podium.get_child_count() == 12 and _scene.views.visible, "restart clears ceremony and restores split views without new nodes")
		if id == "skate":
			_check(_rig(id, _scene.ordered()[0]).board.visible, "restart restores the skateboard")


func _run() -> void:
	get_tree().root.size = Vector2i(1600, 900)
	get_tree().current_scene = null
	var id := OS.get_environment("RS_PODIUM_GAME")
	if id.is_empty():
		await _math()
	else:
		await _game(id)
	get_tree().paused = false
	if is_instance_valid(_scene):
		get_tree().current_scene = null
		_scene.queue_free()
	await _frames(1)
	print("RS_PODIUM_TESTS: %d checks, %d failures" % [_checks, _failures])
	RSExit.quit(get_tree(), 1 if _failures else 0)
