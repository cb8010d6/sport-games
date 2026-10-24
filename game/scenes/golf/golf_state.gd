class_name RSGolfState
extends RefCounted
## Scene/input adapter around pure rules and a separate 120 Hz physical ball; no G4 gestures.

const REACHES := RSGolfShot.REACHES

var rules := RSGolfRules.new()
var events: Array[RSGolfRules.Event] = []  ## reused at 120 Hz; entries exist only on contact
var ball: MeshInstance3D
var motion := RSGolfBall.new()
var position: Vector3:
	get:
		return motion.position
var armed := false
var requested := false
var flying: bool:
	get:
		return motion.active()
var reach_index := 2
var bot_ticks := 0
var done: bool:
	get:
		return rules.finished()
var _world: RSGolfWorld
var _aim := RSGolfShot.new()
var _command_seq := 0
var _command: RSGolfRules.StrokeKey
var _shot: RSGolfRules.StrokeKey


func reset(pars: PackedInt32Array, slot: int) -> void:
	rules.reset_round(pars, slot)
	cancel_input()
	events.clear()
	reach_index = 2
	motion.freeze()
	bot_ticks = 0
	_command_seq = 0
	_shot = null


func start_hole(index: int, tee: Vector3, world: RSGolfWorld) -> bool:
	if not rules.start_hole(index):
		return false
	_world = world
	if not motion.reset(world, tee):
		return false
	cancel_input()
	events.clear()
	bot_ticks = 0
	_shot = null
	return true


func arm(at_tick: int) -> void:
	if rules.ready() and not requested:
		_command_seq += 1
		_command = rules.command_key(_command_seq, at_tick)
		armed = true


func request(at_tick: int) -> void:
	if armed:
		_command.tick = at_tick
		requested = true
		armed = false


func cancel_input() -> void:
	armed = false
	requested = false
	_command = null


func launch(target: Vector3) -> bool:
	if not requested:
		return false
	requested = false
	if not _aim.aim(_world, position, target, reach_index):
		_command = null
		return false
	_shot = rules.try_stroke(_command)
	_command = null
	if _shot == null:
		return false
	if not motion.strike(_aim.velocity, _aim.spin, _aim.rolling):
		return false
	bot_ticks = 0
	return true


func advance_tick(next_tick: int) -> void:
	events.clear()
	if not flying or done:
		return
	motion.step()
	if motion.outcome >= 0:
		events.append(RSGolfRules.Event.new(_shot, motion.outcome, next_tick))


func after_tick() -> void:
	if done:
		motion.freeze()
		cancel_input()
	elif rules.recovery != RSGolfRules.Recovery.NONE:
		var water := rules.recovery == RSGolfRules.Recovery.WATER_BACKTRACK
		var recovery := motion.recovery_position(water)
		if recovery.is_finite() and rules.complete_drop(_shot):
			motion.reset(_world, recovery)
			bot_ticks = 0


func place_at(point: Vector3) -> bool:
	return motion.reset(_world, point)


func render_position(alpha: float) -> Vector3:
	return motion.previous_position.lerp(position, clampf(alpha, 0.0, 1.0)) if flying else position
