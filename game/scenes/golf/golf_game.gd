class_name RSGolfGame
extends RSPartyGame
## G1 playable shell: one shared course, independent scripted balls, three simultaneous holes.
## A/B/C are temporary button input; no official records until rules/physics/gestures are ready.

const BALL_RADIUS := 0.12  ## enlarged placeholder ball for visibility, m
const BOT_DELAY := 1.5    ## effective play seconds before a bot shot
const CARD_SECONDS := 6.0 ## between-hole holding time; formal scorecard arrives in G6

var course: RSGolfCourse
var hole_index := 0
var hole_elapsed := 0.0
var card_elapsed := -1.0
var _world: Node3D


func _game_name() -> String:
	return tr("高尔夫")


func _oled_name() -> String:
	return "GOLF"


func _how_to_play() -> String:
	return tr("G1占位输入：A切换60/120/220米，按住B再松开击球，C取消。三洞一局，每洞150秒，各自同时打球；不计正式纪录。")


func can_record(_p: Player) -> bool:
	return false  # Placeholder trajectories must never become official personal bests.


func _maps() -> Array:
	return RSGolfCourse.MAPS


func _map_info(_i: int) -> String:
	return tr("3洞 · 标准杆12 · G1占位局")


func _setup_world() -> void:
	lobby_cam.far = 1800.0


func _load_map(index: int) -> void:
	if is_instance_valid(_world):
		remove_child(_world)
		_world.queue_free()
	_world = Node3D.new()
	add_child(_world)
	course = RSGolfCourse.new(index)
	_world.add_child(course)
	var sun := course.setup_environment(_world)
	RSSettings.sun_shadows(sun)
	hole_index = 0
	hole_elapsed = 0.0
	card_elapsed = -1.0
	var tee := course.tee_pos(0)
	lobby_cam.position = tee + Vector3(35.0, 38.0, 45.0)
	lobby_cam.look_at(tee + course.tee_dir(0) * 65.0)
	for p: Player in players.values():
		_state(p).reset()
		_place(p)


func _player_added(p: Player) -> void:
	var state := RSGolfState.new()
	p.data = state
	state.ball = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = BALL_RADIUS
	mesh.height = BALL_RADIUS * 2.0
	state.ball.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = color_of(p)
	state.ball.material_override = material
	state.ball.layers = 1 << p.c.player
	add_child(state.ball)
	_place(p)


func _player_removed(p: Player) -> void:
	_state(p).ball.queue_free()
	p.data = null


func _round_started(_ordered: Array) -> void:
	hole_index = 0
	hole_elapsed = 0.0
	card_elapsed = -1.0
	for p: Player in players.values():
		_state(p).reset()
		_place(p)


func _place(p: Player) -> void:
	_state(p).start_hole(hole_index, int(course.holes[hole_index]["par"]), course.tee_pos(hole_index) + Vector3.UP * BALL_RADIUS)
	_sync_ball(p)
	_send_status(p)


func _play_process(delta: float) -> void:
	if card_elapsed >= 0.0:
		card_elapsed += delta
		if card_elapsed >= CARD_SECONDS:
			hole_index += 1
			hole_elapsed = 0.0
			card_elapsed = -1.0
			for p: Player in players.values():
				_place(p)
		return
	var active_delta := minf(delta, RSGolfState.HOLE_SECONDS - hole_elapsed)
	hole_elapsed += active_delta
	var complete := not players.is_empty()
	for p: Player in players.values():
		var state := _state(p)
		if not p.c.connected:
			state.armed = false
		state.advance(active_delta)
		if hole_elapsed >= RSGolfState.HOLE_SECONDS:
			state.cap_hole()
		elif p.fake and not state.done and not state.flying:
			state.bot_wait += active_delta
			if state.bot_wait >= BOT_DELAY:
				_shoot(p)
		p.score = state.score()
		_sync_ball(p)
		complete = complete and state.done
	if complete:
		if hole_index == course.hole_count() - 1:
			finish_round()
		else:
			card_elapsed = 0.0


func _player_button(p: Player, button: int, pressed: bool) -> void:
	if phase != Phase.PLAY or card_elapsed >= 0.0 or not p.c.connected:
		return
	var state := _state(p)
	if state.done or state.flying:
		return
	if button == RSController.BTN_C and pressed:
		state.armed = false
	elif button == RSController.BTN_A and pressed and not state.armed:
		state.reach_index = (state.reach_index + 1) % RSGolfState.REACHES.size()
	elif button == RSController.BTN_B:
		if pressed:
			state.armed = true
		elif state.armed:
			_shoot(p)
	_send_status(p)


func _shoot(p: Player) -> void:
	var state := _state(p)
	var pin := course.pin_pos(hole_index) + Vector3.UP * BALL_RADIUS
	var reach: float = RSGolfState.REACHES[state.reach_index]
	var target := pin if state.position.distance_to(pin) <= reach else course.aim_point(hole_index, state.position, reach) + Vector3.UP * BALL_RADIUS
	if state.launch(target, pin):
		_send_status(p)


func _sync_ball(p: Player) -> void:
	var state := _state(p)
	state.ball.position = state.position
	var direction := course.tee_dir(hole_index)
	p.cam.position = state.position - direction * 7.0 + Vector3.UP * 4.0
	p.cam.look_at(state.position + direction * 8.0)


func _send_status(p: Player) -> void:
	var state := _state(p)
	send_ui(p, {"title": "GOLF G1", "main": "H%d / 3" % (hole_index + 1),
		"sub": "%d M | %d SHOTS" % [RSGolfState.REACHES[state.reach_index], state.strokes[hole_index]],
		"legends": ["DIST", "SHOT", "CANCEL", null]})


func _player_recentered(p: Player) -> void:
	_state(p).armed = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED:
		for p: Player in players.values():
			_state(p).armed = false


func _result_detail(p: Player) -> String:
	var total := 0
	var limits := 0
	for value: int in _state(p).strokes:
		total += value
	for value: int in _state(p).capped:
		limits += value
	return tr("G1占位局 · %d杆 · %d洞上限（不计纪录）") % [total, limits]


func _state(p: Player) -> RSGolfState:
	return p.data as RSGolfState
