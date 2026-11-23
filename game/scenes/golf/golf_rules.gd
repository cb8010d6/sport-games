class_name RSGolfRules
extends RefCounted
## Pure scoring ledger. Tick means last completed 1/120 s step; no scene, geometry or storage.
## Commands carry that start tick. Contacts at the end of tick 18000 precede its timeout.

enum Outcome { REST, HOLED, WATER, OB }
enum Status { UNPLAYED, READY, FLIGHT, DROP, HOLED, CAPPED }
enum Recovery { NONE, WATER_BACKTRACK, PREVIOUS_SHOT }
const HZ := 120
const HOLE_TICKS := 18000  ## 150 effective play seconds
const PRIORITY := [3, 0, 1, 2]  ## equal-order contact tie: cup, water, OB, rest

class StrokeKey extends RefCounted:
	var _owner: RefCounted
	var slot: int
	var epoch: int
	var hole: int
	var seq: int
	var tick: int

	func _init(player: int, generation: int, index: int, serial: int, at: int) -> void:
		slot = player
		epoch = generation
		hole = index
		seq = serial
		tick = at

class Event extends RefCounted:
	var key: StrokeKey
	var kind: Outcome
	var tick: int
	var order: int

	func _init(shot: StrokeKey, outcome: Outcome, at: int, contact_order := 0) -> void:
		key = shot
		kind = outcome
		tick = at
		order = contact_order

var epoch := 0
var hole := -1
var tick := 0
var recovery := Recovery.NONE
var _slot := 0
var _owner := RefCounted.new()  ## per-ledger identity; never a reference back to the ledger
var _pars := PackedInt32Array()
var _strokes := PackedInt32Array()
var _penalties := PackedInt32Array()
var _points := PackedInt32Array()
var _states := PackedInt32Array()
var _reasons: Array[String] = []
var _shot: StrokeKey
var _shot_seq := 0
var _last_command := -1


func reset_round(pars: PackedInt32Array, slot: int) -> void:
	assert(pars.size() == 3 and slot >= 1 and slot <= 4, "Three holes and a local player slot required")
	for standard: int in pars:
		assert(standard >= 1, "Par must be positive")
	epoch += 1
	_slot = slot
	_pars = pars.duplicate()
	_strokes.resize(3)
	_penalties.resize(3)
	_points.resize(3)
	_states.resize(3)
	_reasons.resize(3)
	_strokes.fill(0)
	_penalties.fill(0)
	_points.fill(0)
	_states.fill(Status.UNPLAYED)
	_reasons.fill("")
	hole = -1
	tick = 0
	_shot = null
	recovery = Recovery.NONE


func start_hole(index: int) -> bool:
	if index != hole + 1 or index >= _pars.size() or (hole >= 0 and not finished()):
		return false
	hole = index
	tick = 0
	_shot_seq = 0
	_last_command = -1
	_shot = null
	recovery = Recovery.NONE
	_states[hole] = Status.READY
	return true


func command_key(seq: int, at_tick: int) -> StrokeKey:
	var key := StrokeKey.new(_slot, epoch, hole, seq, at_tick)
	key._owner = _owner
	return key


func try_stroke(command: StrokeKey) -> StrokeKey:
	if not _context(command) or command.seq <= 0 or command.seq <= _last_command:
		return null
	_last_command = command.seq
	if not ready() or command.tick != tick:
		return null  # A rejected observed release is consumed, never queued for later readiness.
	_shot_seq += 1
	_shot = StrokeKey.new(_slot, epoch, hole, _shot_seq, tick)
	_shot._owner = _owner
	_strokes[hole] += 1
	_states[hole] = Status.FLIGHT
	return _shot


func resolve_tick(next_tick: int, events: Array[Event]) -> bool:
	assert(hole >= 0, "Start a hole before resolving ticks")
	if hole < 0:
		return false
	if finished() or next_tick == tick:
		return false
	assert(next_tick == tick + 1 and next_tick <= HOLE_TICKS, "Resolve contiguous ticks only")
	if next_tick != tick + 1 or next_tick > HOLE_TICKS:
		return false
	tick = next_tick
	var best := -1
	for i in events.size():
		var event := events[i]
		if event == null or event.tick != tick or event.order < 0 or not _matches(event.key) or _states[hole] != Status.FLIGHT:
			continue
		if event.kind < Outcome.REST or event.kind > Outcome.OB:
			continue
		if best < 0 or event.order < events[best].order or (event.order == events[best].order and PRIORITY[event.kind] < PRIORITY[events[best].kind]):
			best = i
	var changed := best >= 0
	if changed:
		var kind := events[best].kind
		if kind == Outcome.HOLED:
			_finish(Status.HOLED, "holed")
		elif kind == Outcome.WATER or kind == Outcome.OB:
			_penalties[hole] += 1
			_strokes[hole] = mini(_strokes[hole] + 1, _pars[hole] + 4)
			if _strokes[hole] == _pars[hole] + 4:
				_finish(Status.CAPPED, "penalty_limit")
			else:
				_states[hole] = Status.DROP
				recovery = Recovery.WATER_BACKTRACK if kind == Outcome.WATER else Recovery.PREVIOUS_SHOT
		elif _strokes[hole] == _pars[hole] + 4:
			_finish(Status.CAPPED, "stroke_limit")
		else:
			_states[hole] = Status.READY
	if tick == HOLE_TICKS and not finished():
		_strokes[hole] = _pars[hole] + 4
		_finish(Status.CAPPED, "timeout")
		changed = true
	return changed


func complete_drop(key: StrokeKey) -> bool:
	if hole < 0 or _states[hole] != Status.DROP or not _matches(key):
		return false
	_states[hole] = Status.READY
	recovery = Recovery.NONE
	return true


func ready() -> bool:
	return hole >= 0 and _states[hole] == Status.READY and tick < HOLE_TICKS


func finished() -> bool:
	return hole >= 0 and _states[hole] >= Status.HOLED


func stroke_count() -> int:
	return _strokes[hole] if hole >= 0 else 0


func score() -> int:
	var total := 0
	for value: int in _points:
		total += value
	return total


func summary() -> Dictionary:
	var rows: Array[Dictionary] = []
	var total := 0
	var relative := 0
	var limits := 0
	for i in _pars.size():
		total += _strokes[i]
		if _states[i] >= Status.HOLED:
			relative += _strokes[i] - _pars[i]
		limits += int(_states[i] == Status.CAPPED)
		rows.append({"par": _pars[i], "strokes": _strokes[i], "penalties": _penalties[i],
			"points": _points[i], "status": _states[i], "reason": _reasons[i]})
	return {"score": score(), "strokes": total, "relative": relative, "capped": limits, "holes": rows}


func _context(key: StrokeKey) -> bool:
	return key != null and key._owner == _owner and key.slot == _slot and key.epoch == epoch and key.hole == hole


func _matches(key: StrokeKey) -> bool:
	return _context(key) and key == _shot


func _finish(status: Status, reason: String) -> void:
	_states[hole] = status
	_reasons[hole] = reason
	_points[hole] = maxi(0, 2 + _pars[hole] - _strokes[hole])
	recovery = Recovery.NONE
