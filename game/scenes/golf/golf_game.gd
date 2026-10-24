class_name RSGolfGame
extends RSPartyGame
## M1 project shell: shared 120 Hz clock and independent sphere-swept physical balls.
## A/B/C are temporary button input; no official records until rules/physics/gestures are ready.

const BALL_RADIUS := RSGolfBall.RADIUS  ## physical and rendered radius, m
const BOT_TICKS := 180    ## 1.5 effective play seconds before a bot shot
const BOT_FINISH_SPEED := 4.0  ## maximum presentation speed after every human has finished
const CARD_SECONDS := 6.0 ## between-hole holding time; formal scorecard arrives in G6
const STEP := 1.0 / RSGolfRules.HZ  ## effective play seconds
const TICK_EPS := 1e-10  ## seconds; floating-point comparison tolerance, debt is retained

var course: RSGolfCourse
var hole_index := 0
var hole_tick := 0
var hole_elapsed: float:
	get:
		return float(hole_tick) / RSGolfRules.HZ
var card_elapsed := -1.0
var _world: Node3D
var _pars := PackedInt32Array()
var _round_players: Array = []
var _accumulator := 0.0
var physics_world: RSGolfWorld
var _aim_support := RSGolfWorldHit.new()


func _game_name() -> String:
	return tr("高尔夫")


func _oled_name() -> String:
	return "GOLF"


func _how_to_play() -> String:
	return tr("占位输入：A切换60/120/220米，按住B再松开击球，C取消。三洞一局，每洞150秒，各自同时打球；不计正式纪录。")


func can_record(_p: Player) -> bool:
	return false  # Temporary buttons and unfinished milestone acceptance never write official records.


func _maps() -> Array:
	return RSGolfCourse.MAPS


func _map_info(_i: int) -> String:
	return tr("3洞 · 标准杆12 · 占位出手")


func _setup_world() -> void:
	lobby_cam.far = 1800.0
	ControllerHub.controller_disconnected.connect(_on_controller_disconnected)
	ControllerHub.roster_changed.connect(_cancel_disconnected_inputs)


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
	_pars.clear()
	for data: Dictionary in course.holes:
		_pars.append(int(data["par"]))
	hole_index = 0
	hole_tick = 0
	_accumulator = 0.0
	card_elapsed = -1.0
	_configure_physics()
	var tee := course.tee_pos(0)
	lobby_cam.position = tee + Vector3(35.0, 38.0, 45.0)
	lobby_cam.look_at(tee + course.tee_dir(0) * 65.0)
	for p: Player in players.values():
		_state(p).reset(_pars, p.c.player)
		_place(p)


func _player_added(p: Player) -> void:
	var state := RSGolfState.new()
	p.data = state
	state.reset(_pars, p.c.player)
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
	_round_players.erase(p)
	_state(p).ball.queue_free()
	p.data = null


func _round_started(_ordered: Array) -> void:
	hole_index = 0
	hole_tick = 0
	_accumulator = 0.0
	_round_players = ordered()
	card_elapsed = -1.0
	_configure_physics()
	for p: Player in players.values():
		_state(p).reset(_pars, p.c.player)
		_place(p)


func _place(p: Player) -> void:
	if not _state(p).start_hole(hole_index, course.tee_pos(hole_index), physics_world):
		push_error("RSGolfGame: invalid hole transition")
		return
	_sync_ball(p)
	_send_status(p)


func _play_process(delta: float) -> void:
	if not is_finite(delta) or delta < 0.0 or not is_finite(_accumulator + delta):
		push_error("RSGolfGame: delta must be finite and nonnegative")
		return
	if phase != Phase.PLAY or get_tree().paused:
		return
	if card_elapsed >= 0.0:
		card_elapsed += delta
		if card_elapsed >= CARD_SECONDS:
			hole_index += 1
			hole_tick = 0
			_accumulator = 0.0
			card_elapsed = -1.0
			_configure_physics()
			for p: Player in players.values():
				_place(p)
		return
	var elapsed := delta * _simulation_speed()
	if not is_finite(_accumulator + elapsed):
		push_error("RSGolfGame: delta must be finite and nonnegative")
		return
	_accumulator += elapsed
	while _accumulator + TICK_EPS >= STEP:
		_accumulator -= STEP
		_play_tick()
		if phase != Phase.PLAY or card_elapsed >= 0.0:
			_accumulator = 0.0  # A phase boundary never donates leftover time to a new hole.
			break
	for p: Player in _round_players:
		_sync_ball(p)


func _play_tick() -> void:
	var next_tick := hole_tick + 1
	var complete := not _round_players.is_empty()
	var skip_bot_wait := _humans_finished()
	for p: Player in _round_players:
		var state := _state(p)
		if not p.c.connected:
			state.cancel_input()
		elif p.fake and state.rules.ready():
			state.bot_ticks += 1
			if skip_bot_wait or state.bot_ticks >= BOT_TICKS:
				state.arm(hole_tick)
				state.request(hole_tick)
		if state.requested:
			_shoot(p)
		state.advance_tick(next_tick)
		state.rules.resolve_tick(next_tick, state.events)
		state.after_tick()
		p.score = state.rules.score()
		complete = complete and state.done
	hole_tick = next_tick
	if complete:
		if hole_index == course.hole_count() - 1:
			finish_round()
		else:
			card_elapsed = 0.0


func _humans_finished() -> bool:
	var found := false
	for p: Player in _round_players:
		if not p.fake:
			found = true
			if not _state(p).done:
				return false
	return found  # Pure demo has no human finish transition and keeps the benchmark cadence.


func _simulation_speed() -> float:
	return BOT_FINISH_SPEED if _humans_finished() else 1.0


func _player_button(p: Player, button: int, pressed: bool) -> void:
	if phase != Phase.PLAY or card_elapsed >= 0.0 or not p.c.connected:
		return
	var state := _state(p)
	if button == RSController.BTN_C and pressed:
		state.cancel_input()
		return
	if not state.rules.ready() or state.requested:
		return
	if button == RSController.BTN_A and pressed and not state.armed:
		state.reach_index = (state.reach_index + 1) % RSGolfState.REACHES.size()
	elif button == RSController.BTN_B:
		if pressed:
			state.arm(hole_tick)
		elif state.armed:
			state.request(hole_tick)
	_send_status(p)


func _shoot(p: Player) -> void:
	var state := _state(p)
	var reach: float = RSGolfState.REACHES[state.reach_index]
	var target := course.aim_point(hole_index, state.position, reach)
	if not physics_world.support(target, BALL_RADIUS, _aim_support):
		push_error("RSGolfGame: shot target has no terrain support")
		return
	if state.launch(_aim_support.centre):
		_send_status(p)


func _sync_ball(p: Player) -> void:
	var state := _state(p)
	var at := state.render_position(_accumulator / STEP)
	state.ball.position = at
	var direction := course.tee_dir(hole_index)
	p.cam.position = at - direction * 7.0 + Vector3.UP * 4.0
	p.cam.look_at(at + direction * 8.0)


func _configure_physics() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261024 + course.map_index * 31 + hole_index * 997
	var angle := rng.randf_range(0.0, TAU)
	var speeds: Array = course.map["wind"]
	var speed := rng.randf_range(float(speeds[0]), float(speeds[1]))
	var direction := Vector3(cos(angle), 0.0, sin(angle))
	physics_world = RSGolfWorld.new()
	if not physics_world.configure(course.surface, course.bounds, course.water_levels, course.trees, course.pin_pos(hole_index), course.sea_level if course.sea_level > -100.0 else -INF, course.lie_at, direction * speed):
		push_error("RSGolfGame: invalid physical world")
	course.set_wind(direction, speed)


func _send_status(p: Player) -> void:
	var state := _state(p)
	send_ui(p, {"title": "GOLF", "main": "H%d / 3" % (hole_index + 1),
		"sub": "%d M | %d SHOTS" % [RSGolfState.REACHES[state.reach_index], state.rules.stroke_count()],
		"legends": ["DIST", "SHOT", "CANCEL", null]})


func _player_recentered(p: Player) -> void:
	_state(p).cancel_input()


func _on_controller_disconnected(controller: RSController) -> void:
	var p: Player = players.get(controller.id)
	if p != null:
		_state(p).cancel_input()


func _cancel_disconnected_inputs() -> void:
	for p: Player in players.values():
		if not p.c.connected:
			_state(p).cancel_input()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED:
		for p: Player in players.values():
			_state(p).cancel_input()


func _result_detail(p: Player) -> String:
	var summary := _state(p).rules.summary()
	var relative := "E" if summary["relative"] == 0 else "%+d" % summary["relative"]
	var holes := PackedStringArray()
	for row: Dictionary in summary["holes"]:
		holes.append("%d/%d" % [row["strokes"], row["points"]])
	return tr("占位局 · %d杆（%s）· %d洞上限 · 各洞%s（杆/分，不计纪录）") % [summary["strokes"], relative, summary["capped"], ", ".join(holes)]


func _state(p: Player) -> RSGolfState:
	return p.data as RSGolfState
