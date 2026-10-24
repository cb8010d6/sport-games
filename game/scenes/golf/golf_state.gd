class_name RSGolfState
extends RefCounted
## G1 round state and deliberately scripted flight, in metres/seconds. No terrain physics,
## penalties or gesture detection yet; G2/G3 replace those parts without changing score units.

const HOLE_SECONDS := 150.0  ## effective play seconds per hole
const FLIGHT_SECONDS := 1.2  ## placeholder arc duration, s
const ARC_HEIGHT := 12.0    ## placeholder apex above the straight segment, m
const REACHES := [60.0, 120.0, 220.0]  ## selectable placeholder distance, m

var ball: MeshInstance3D
var hole := 0
var par := 4
var strokes := PackedInt32Array([0, 0, 0])
var points := PackedInt32Array([0, 0, 0])
var capped := PackedByteArray([0, 0, 0])
var position := Vector3.ZERO
var armed := false
var flying := false
var done := false
var reach_index := 2
var bot_wait := 0.0
var _from := Vector3.ZERO
var _target := Vector3.ZERO
var _pin := Vector3.ZERO
var _flight_time := 0.0


func reset() -> void:
	strokes.fill(0)
	points.fill(0)
	capped.fill(0)
	reach_index = 2
	armed = false
	flying = false
	done = false
	bot_wait = 0.0


func start_hole(index: int, standard: int, tee: Vector3) -> void:
	hole = index
	par = standard
	position = tee
	armed = false
	flying = false
	done = false
	bot_wait = 0.0
	_flight_time = 0.0


func launch(target: Vector3, pin: Vector3) -> bool:
	if done or flying:
		return false
	armed = false
	strokes[hole] += 1
	_from = position
	_target = target
	_pin = pin
	_flight_time = 0.0
	flying = true
	bot_wait = 0.0
	return true


func advance(delta: float) -> void:
	if not flying or done:
		return
	_flight_time = minf(_flight_time + delta, FLIGHT_SECONDS)
	var u := _flight_time / FLIGHT_SECONDS
	position = _from.lerp(_target, u) + Vector3.UP * (4.0 * ARC_HEIGHT * u * (1.0 - u))
	if u < 1.0:
		return
	flying = false
	if position.distance_to(_pin) < 0.03:
		_finish(false)
	elif strokes[hole] >= par + 4:
		cap_hole()


func cap_hole() -> void:
	if done:
		return
	strokes[hole] = par + 4
	_finish(true)


func score() -> int:
	var total := 0
	for value: int in points:
		total += value
	return total


func _finish(limit: bool) -> void:
	done = true
	armed = false
	flying = false
	capped[hole] = int(limit)
	points[hole] = maxi(0, 2 + par - strokes[hole])
