class_name RSGolfState
extends RefCounted
## Scene/input adapter around pure rules. Flight is still a scripted 144-tick arc, not G3 physics.

const FLIGHT_TICKS := 144
const ARC_HEIGHT := 12.0  ## placeholder apex above the straight segment, m
const REACHES := [60.0, 120.0, 220.0]  ## selectable placeholder distance, m

var rules := RSGolfRules.new()
var events: Array[RSGolfRules.Event] = []  ## reused at 120 Hz; entries exist only on contact
var ball: MeshInstance3D
var position := Vector3.ZERO
var armed := false
var requested := false
var flying := false
var reach_index := 2
var bot_ticks := 0
var done: bool:
	get:
		return rules.finished()
var _from := Vector3.ZERO
var _target := Vector3.ZERO
var _pin := Vector3.ZERO
var _flight_tick := 0
var _command_seq := 0
var _command: RSGolfRules.StrokeKey
var _shot: RSGolfRules.StrokeKey


func reset(pars: PackedInt32Array, slot: int) -> void:
	rules.reset_round(pars, slot)
	cancel_input()
	events.clear()
	reach_index = 2
	flying = false
	bot_ticks = 0
	_command_seq = 0
	_shot = null


func start_hole(index: int, tee: Vector3) -> bool:
	if not rules.start_hole(index):
		return false
	position = tee
	cancel_input()
	events.clear()
	flying = false
	bot_ticks = 0
	_flight_tick = 0
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


func launch(target: Vector3, pin: Vector3) -> bool:
	if not requested:
		return false
	requested = false
	_shot = rules.try_stroke(_command)
	_command = null
	if _shot == null:
		return false
	_from = position
	_target = target
	_pin = pin
	_flight_tick = 0
	flying = true
	bot_ticks = 0
	return true


func advance_tick(next_tick: int) -> void:
	events.clear()
	if not flying or done:
		return
	_flight_tick += 1
	var u := float(_flight_tick) / FLIGHT_TICKS
	position = _from.lerp(_target, u) + Vector3.UP * (4.0 * ARC_HEIGHT * u * (1.0 - u))
	if _flight_tick == FLIGHT_TICKS:
		flying = false
		var kind := RSGolfRules.Outcome.HOLED if position.distance_to(_pin) < 0.03 else RSGolfRules.Outcome.REST
		events.append(RSGolfRules.Event.new(_shot, kind, next_tick))


func after_tick() -> void:
	if done:
		flying = false
		cancel_input()
