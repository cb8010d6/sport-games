extends Node
## Opening-path geometry and real three-sport integration with isolated demo players.
## The analytic reference is independent of the production de Casteljau interpolation.

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


func _ease(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _bezier(a: Vector3, b: Vector3, c: Vector3, u: float) -> Vector3:
	return (1.0 - u) * (1.0 - u) * a + 2.0 * u * (1.0 - u) * b + u * u * c


func _pose(camera: Camera3D, position: Vector3, target: Vector3, fov: float) -> void:
	_check(camera.global_position.distance_to(position) < 0.001, "camera follows analytic world-space curve")
	_check((-camera.global_basis.z).dot((target - position).normalized()) > 0.99999, "camera faces the expected target")
	_check(absf(camera.fov - fov) < 0.001, "FOV matches the original profile")
	_check(absf(camera.global_basis.determinant() - 1.0) < 0.0001, "camera basis remains orthonormal")


func _math() -> void:
	var parent := Node3D.new()
	add_child(parent)
	parent.transform = Transform3D(Basis(Vector3.UP, 0.7), Vector3(50, 3, -20))
	var camera := Camera3D.new()
	parent.add_child(camera)
	var rng := RandomNumberGenerator.new()
	rng.seed = 92371
	for sample in 16:
		var start := Vector3(rng.randf_range(-100, 100), rng.randf_range(20, 80), rng.randf_range(20, 80))
		var via := Vector3(rng.randf_range(-30, 30), 10, 10)
		var end := Vector3(rng.randf_range(-5, 5), 2, 5)
		var target := Vector3(0, -5, -100)
		var delay: float = [0.0, 0.25, 0.3, 0.4, 1.0][sample % 5]
		for fraction: float in [-1.0, 0.0, 0.2, 0.5, 0.8, 1.0, 2.0]:
			var u := _ease(fraction)
			var look_u := (1.0 if u >= 1.0 else 0.0) if delay == 1.0 else _ease((u - delay) / (1.0 - delay))
			RSIntro.apply(camera, fraction * 4.0, 4.0, start, via, end, target, Vector3.ZERO, 50, 70, delay)
			_pose(camera, _bezier(start, via, end, u), target.lerp(Vector3.ZERO, look_u), 50 + 20 * u)
	for duration: float in [0.0, -3.0]:
		RSIntro.apply(camera, 0, duration, Vector3.ONE, Vector3.UP, Vector3(1, 2, 3), Vector3.ZERO, Vector3.FORWARD, 50, 66)
		_check(camera.global_position.distance_to(Vector3(1, 2, 3)) < 0.001 and is_equal_approx(camera.fov, 66), "disabled opening cuts to endpoint")
	var before := camera.global_basis
	RSIntro.apply(camera, 1, 1, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, 50, 66)
	_check(camera.global_basis.is_equal_approx(before), "coincident target preserves orientation")
	RSIntro.apply(camera, 1, 1, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.UP, Vector3.UP, 50, 66)
	_check((-camera.global_basis.z).is_equal_approx(Vector3.UP), "vertical shot uses a valid alternate up vector")
	_check(absf(camera.global_basis.determinant() - 1.0) < 0.0001, "vertical shot has a valid basis")
	for elapsed: float in [-1.0, 0.0, 0.3, 0.6, 1.7, 2.8, 3.1, 3.4, 5.0]:
		var old_fade := clampf(elapsed / 0.6, 0.0, 1.0) * clampf((3.4 - elapsed) / 0.6, 0.0, 1.0)
		_check(is_equal_approx(RSIntro.fade(elapsed, 3.4), old_fade), "normal title fade remains equivalent")
	_check(RSIntro.fade(0.1, 0.2) == 1.0, "short title reaches full opacity")
	_check(RSIntro.fade(0, 0) == 0 and RSIntro.fade(0, -1) == 0, "disabled opening has no title")
	_check(RSIntro.fade(0.1, 1, 0) == 1.0 and RSIntro.fade(1, 1, 0) == 0.0, "instant title still ends on time")
	parent.queue_free()
	await _frames(1)


func _run() -> void:
	get_tree().root.size = Vector2i(1600, 900)
	get_tree().current_scene = null
	var id := OS.get_environment("RS_INTRO_GAME")
	if id.is_empty():
		await _math()
	else:
		await _game(id)
	get_tree().paused = false
	if is_instance_valid(_scene):
		get_tree().current_scene = null
		_scene.queue_free()
	await _frames(1)
	print("RS_INTRO_TESTS: %d checks, %d failures" % [_checks, _failures])
	RSExit.quit(get_tree(), 1 if _failures else 0)


func _wait_phase(phase: int) -> void:
	for _i in 2400:
		await get_tree().process_frame
		if _scene.phase == phase:
			return
	_check(false, "real game reaches requested phase")


func _camera(id: String, player: RSPartyGame.Player) -> Variant:
	var state: Variant
	match id:
		"skate": state = _scene._rider(player)
		"ski": state = _scene._racer(player)
		_: state = _scene._sh(player)
	_scene._camera(player, state, 0.0, true)
	return state


func _reference(id: String, player: RSPartyGame.Player, state: Variant, fraction: float) -> void:
	var u := _ease(fraction)
	var start: Vector3
	var via: Vector3
	var look: Vector3
	var delay: float
	var fov_start: float
	var fov_end: float
	match id:
		"skate":
			start = state.sk.pos + Vector3(0, 26, 36)
			via = state.sk.pos + Vector3(5 * signf(state.sk.pos.x + 0.01), 5, 13)
			look = state.sk.pos + Vector3(0, -8, -120)
			delay = 0.25
			fov_start = 50
			fov_end = 66
		"ski":
			start = _scene._course.world(-40, -60, 60)
			via = state.sk.pos + Vector3(6 * signf(state.sk.pos.x - _scene._course.centre(0) + 0.01), 4, 12)
			look = _scene._course.world(0, 180, 0)
			delay = 0.3
			fov_start = 55
			fov_end = 64
		_:
			start = Vector3(RSBallCourt.court_x(state.court) * 0.4, 26, 46)
			via = state.pos + RSBallCourt.facing(state.court, state.pos).z * 9 + Vector3.UP * 5
			look = Vector3(RSBallCourt.court_x(state.court), 1, 2)
			delay = 0.4
			fov_start = 50
			fov_end = 47
	_pose(player.cam, _bezier(start, via, state.cam_pos, u), look.lerp(state.cam_look, _ease((u - delay) / (1 - delay))), lerpf(fov_start, fov_end, u))


func _capture(suffix: String) -> void:
	var prefix := OS.get_environment("RS_INTRO_SCREENSHOT")
	if prefix.is_empty():
		return
	await _frames()
	await RenderingServer.frame_post_draw
	_check(get_viewport().get_texture().get_image().save_png(prefix + "-" + suffix + ".png") == OK, "native screenshot saved")


func _game(id: String) -> void:
	_scene = (load(RSCatalog.find_game(id)["scene"]) as PackedScene).instantiate()
	get_tree().root.add_child(_scene)
	get_tree().current_scene = _scene
	await _wait_phase(RSPartyGame.Phase.COUNTDOWN)
	_scene.set_process(false)
	var scores: Array = _scene.ordered().map(func(p: RSPartyGame.Player) -> int: return p.score)
	for fraction: float in [0.0, 0.1, 0.25, 0.5, 0.75, 0.99]:
		_scene.phase_time = fraction * _scene.INTRO
		for player: RSPartyGame.Player in _scene.ordered():
			var state: Variant = _camera(id, player)
			_reference(id, player, state, fraction)
		if fraction == 0.0 or fraction == 0.5 or fraction == 0.99:
			await _capture("start" if fraction == 0.0 else ("middle" if fraction == 0.5 else "end"))
	_check(scores == _scene.ordered().map(func(p: RSPartyGame.Player) -> int: return p.score), "flyover does not change scores")
	_scene.set_process(true)
	_scene.open_pause()
	var time: float = _scene.phase_time
	var pose: Transform3D = _scene.ordered()[0].cam.global_transform
	await _frames()
	_check(get_tree().paused and _scene.phase_time == time and _scene.ordered()[0].cam.global_transform == pose, "pause freezes opening time and camera")
	_scene.ui.pause.close()
	await _wait_phase(RSPartyGame.Phase.PLAY)
	_check(_scene.phase_time < 0.5, "opening hands over to normal play")
	_scene.restart_round()
	await _wait_phase(RSPartyGame.Phase.COUNTDOWN)
	_scene.set_process(false)
	_check(_scene.phase_time < _scene.INTRO, "restart creates a fresh opening")
	for player: RSPartyGame.Player in _scene.ordered():
		var state: Variant = _camera(id, player)
		_reference(id, player, state, _scene.phase_time / _scene.INTRO)
