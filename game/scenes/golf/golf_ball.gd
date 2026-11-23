class_name RSGolfBall
extends RefCounted
## One independent 120 Hz golf ball: semi-implicit flight, finite sphere sweeps and rolling.
## Renderers interpolate previous_position/position; scoring consumes at most one outcome.

enum Mode { REST, FLIGHT, ROLL, HOLED, PENALTY, FROZEN, INVALID }
const STEP := 1.0 / 120.0  ## s, never scaled for bot presentation
const RADIUS := 0.02135  ## m
const DRAG := 0.0045  ## 1/m; acceleration = -DRAG * relative_speed * relative_velocity
const SPIN_LIFT := 0.0002  ## Magnus acceleration coefficient for rad/s and m/s inputs
const MAX_LIFT := 4.0  ## m/s²
const SPIN_DECAY := 0.15  ## 1/s in flight
const MAX_SPEED := 150.0  ## m/s, reject nonphysical/unbounded casts before broad-phase traversal
const MAX_SPIN := 1000.0  ## rad/s
const REST_SPEED := 0.05  ## m/s
const REST_TICKS := 48  ## 0.4 s under the static-friction threshold
const MAX_TICKS := 3000  ## 25 s single-shot safety budget
const MAX_CONTACTS := 12  ## contacts per unchanged fixed step
const BOUNCE_SPEED := 0.5  ## m/s normal impact below this transitions to supported rolling
const SUPPORT_GAP := 0.001  ## m, contact storage/support budget, not sweep radius inflation
const CUP_SPEED := 1.5  ## m/s at first cup entry
const CUP_GLANCE := 0.8
const CANOPY_SPEED := 0.65
const PATH_CAPACITY := MAX_TICKS * (MAX_CONTACTS + 1) + 1
const RESTITUTION := [0.35, 0.35, 0.25, 0.10, 0.25, 0.25, 0.05, 0.0, 0.0]
const RESISTANCE := [0.45, 0.45, 0.8, 1.8, 0.18, 0.35, 2.5, 0.0, 0.0]  ## m/s²

var position := Vector3.ZERO
var previous_position := Vector3.ZERO
var velocity := Vector3.ZERO
var spin := Vector3.ZERO
var mode := Mode.REST
var age_ticks := 0
var outcome := -1  ## RSGolfRules.Outcome, or -1 while the shot is active
var _world: RSGolfWorld
var _hit := RSGolfWorldHit.new()
var _support := RSGolfWorldHit.new()
var _drop := RSGolfDrop.new()
var _normal := Vector3.UP
var _settled_ticks := 0
var _canopy := PackedByteArray()
var _trunk := PackedByteArray()
var _cup_locked := false
var _previous_shot := Vector3.ZERO
var _path := PackedVector3Array()
var _path_count := 0


func _init() -> void:
	_path.resize(PATH_CAPACITY)


func reset(world: RSGolfWorld, at: Vector3) -> bool:
	_world = world
	if world == null or not world.legal_placement(at, RADIUS, _support):
		_invalid("a legal supported position is required")
		return false
	position = _support.centre
	previous_position = position
	_normal = _support.normal
	velocity = Vector3.ZERO
	spin = Vector3.ZERO
	mode = Mode.REST
	outcome = -1
	age_ticks = 0
	_settled_ticks = 0
	_path_count = 0
	_canopy.resize(world.trees.size())
	_trunk.resize(world.trees.size())
	_canopy.fill(0)
	_trunk.fill(0)
	_cup_locked = false
	return true


func strike(initial_velocity: Vector3, initial_spin := Vector3.ZERO, rolling := false) -> bool:
	if mode != Mode.REST or _world == null or not position.is_finite() or not initial_velocity.is_finite() or not initial_spin.is_finite() or initial_velocity.length() > MAX_SPEED or initial_spin.length() > MAX_SPIN:
		_invalid("finite bounded shot inputs required")
		return false
	velocity = initial_velocity
	spin = initial_spin
	previous_position = position
	_previous_shot = position
	mode = Mode.ROLL if rolling else Mode.FLIGHT
	outcome = -1
	age_ticks = 0
	_settled_ticks = 0
	_canopy.fill(0)
	_trunk.fill(0)
	_cup_locked = false
	_path_count = 0
	_record()
	return true


func active() -> bool:
	return mode == Mode.FLIGHT or mode == Mode.ROLL


func freeze() -> void:
	if active():
		mode = Mode.FROZEN


func recovery_position(water: bool) -> Vector3:
	return _drop.find(_world, _path, _path_count, _previous_shot, RADIUS, water)


func step() -> void:
	if not active():
		return
	previous_position = position
	outcome = -1
	age_ticks += 1
	_update_entries()
	if mode == Mode.ROLL and not _prepare_roll():
		return
	if mode == Mode.FLIGHT:
		var relative := velocity - _world.wind
		var lift := spin.cross(relative) * SPIN_LIFT
		if lift.length() > MAX_LIFT:
			lift = lift.normalized() * MAX_LIFT
		velocity += (_world.gravity - relative * (DRAG * relative.length()) + lift) * STEP
		spin *= 1.0 - SPIN_DECAY * STEP
	if not velocity.is_finite() or velocity.length() > MAX_SPEED:
		_invalid("integration produced an invalid velocity")
		return
	var remaining := STEP
	var contacts := 0
	while remaining > 1.0e-12 and active():
		_update_entries()
		var end := position + velocity * remaining
		_world.cast(position, end, RADIUS, mode == Mode.ROLL, _canopy, _trunk, _cup_locked, _hit)
		if _hit.kind == RSGolfWorldHit.Kind.INVALID:
			mode = Mode.INVALID  # The geometry query already emitted the unique diagnostic.
			return
		if _hit.kind == RSGolfWorldHit.Kind.NONE:
			position = end
			_record()
			remaining = 0.0
			break
		position = _hit.centre
		_record()
		remaining *= 1.0 - _hit.fraction
		contacts += 1
		if _hit.kind == RSGolfWorldHit.Kind.CUP:
			_cup_locked = true
			if velocity.length() <= CUP_SPEED:
				position = _world.pin
				_finish(RSGolfRules.Outcome.HOLED)
			else:
				velocity *= CUP_GLANCE
		elif _hit.kind == RSGolfWorldHit.Kind.WATER:
			_finish(RSGolfRules.Outcome.WATER)
		elif _hit.kind == RSGolfWorldHit.Kind.OB:
			_finish(RSGolfRules.Outcome.OB)
		elif _hit.kind == RSGolfWorldHit.Kind.CANOPY:
			_canopy[_hit.feature_id] = 1
			velocity *= CANOPY_SPEED
		else:
			_resolve_solid()
		if contacts == MAX_CONTACTS and remaining > 1.0e-12 and active():
			_invalid("contact iteration budget exhausted")
			return
	if mode == Mode.ROLL:
		_follow_support()
	if not position.is_finite() or not velocity.is_finite():
		_invalid("integration produced a nonfinite state")
		return
	if active() and _world.bounds.contains(position):
		var floor_height := _world.surface.height_at(position.x, position.z) + RADIUS
		if position.y < floor_height - _world.storage_clearance(position) * 8.0:
			_invalid("sphere penetrated rendered terrain")
			return
	if active() and age_ticks == MAX_TICKS:
		if _world.legal_placement(position, RADIUS, _support):
			position = _support.centre
			_finish(RSGolfRules.Outcome.REST)
		else:
			_finish(RSGolfRules.Outcome.OB)


func _prepare_roll() -> bool:
	if not _world.support(position, RADIUS, _support):
		_invalid("rolling needs a finite terrain support")
		return false
	var gap := position.y - _support.centre.y
	var tolerance := maxf(SUPPORT_GAP, _world.storage_clearance(position) * 4.0)
	if gap < -tolerance:
		_invalid("rolling sphere penetrated terrain")
		return false
	if gap > tolerance:
		mode = Mode.FLIGHT
		_settled_ticks = 0
		return true
	position.y = _support.centre.y
	_normal = _support.normal
	velocity = velocity.slide(_normal)
	var gravity := _world.gravity.slide(_normal)
	var lie := clampi(_world.lie_at(_support.point), 0, RESISTANCE.size() - 1)
	var friction: float = RESISTANCE[lie]
	if velocity.length() < REST_SPEED and gravity.length() <= friction:
		velocity = Vector3.ZERO
		_settled_ticks += 1
		if _settled_ticks >= REST_TICKS:
			_finish(RSGolfRules.Outcome.REST)
			return false
	else:
		_settled_ticks = 0
		velocity += gravity * STEP
		var speed := velocity.length()
		if speed > 0.0:
			velocity *= maxf(0.0, speed - friction * STEP) / speed
	return true


func _follow_support() -> void:
	if not _world.support(position, RADIUS, _support):
		mode = Mode.FLIGHT
		return
	var tolerance := maxf(SUPPORT_GAP, _world.storage_clearance(position) * 4.0)
	var gap := position.y - _support.centre.y
	if gap < -tolerance:
		_invalid("sweep missed an uphill terrain contact")
	elif gap <= tolerance:
		position.y = _support.centre.y
		_normal = _support.normal
		velocity = velocity.slide(_normal)
	else:
		mode = Mode.FLIGHT


func _resolve_solid() -> void:
	var best := -1
	var approach := 0.0
	for i in _hit.count:
		var value := velocity.dot(_hit.normals[i])
		if value < approach:
			approach = value
			best = i
	var terrain := false
	for i in _hit.count:
		terrain = terrain or _hit.solid_kinds[i] == RSGolfWorldHit.Kind.TERRAIN
	if best >= 0:
		var bounce := 0.2
		if _hit.solid_kinds[best] == RSGolfWorldHit.Kind.TERRAIN:
			var lie := clampi(_world.lie_at(_hit.point), 0, RESTITUTION.size() - 1)
			bounce = RESTITUTION[lie]
		elif _trunk[_hit.solid_ids[best]] != 0:
			bounce = 0.0  # Retain the solid constraint, but never repeat a same-tree impulse inside it.
		if terrain and -approach <= BOUNCE_SPEED:
			bounce = 0.0
		velocity -= _hit.normals[best] * ((1.0 + bounce) * approach)
	# One restitution impulse, then non-penetrating projections; no extra energy at shared edges.
	for iteration in 8:
		for i in _hit.count:
			var value := velocity.dot(_hit.normals[i])
			if value < 0.0:
				velocity -= _hit.normals[i] * value
	var clearance := _world.storage_clearance(position)
	for i in _hit.count:
		position += _hit.normals[i] * (clearance + _hit.depth)
	for i in _hit.count:
		if _hit.solid_kinds[i] == RSGolfWorldHit.Kind.TRUNK:
			_trunk[_hit.solid_ids[i]] = 1
	if terrain and (best < 0 or -approach <= BOUNCE_SPEED):
		mode = Mode.ROLL
		_settled_ticks = 0
	else:
		mode = Mode.FLIGHT
	_record()


func _update_entries() -> void:
	for i in _canopy.size():
		if _canopy[i] != 0 and not _world.inside_canopy(i, position, RADIUS + _world.storage_clearance(position)):
			_canopy[i] = 0
		if _trunk[i] != 0 and not _world.inside_trunk(i, position, RADIUS + _world.storage_clearance(position)):
			_trunk[i] = 0
	if _cup_locked:
		var x := float(position.x) - _world.pin.x
		var z := float(position.z) - _world.pin.z
		var radius := RSGolfWorld.CUP_RADIUS - RADIUS + _world.storage_clearance(position)
		_cup_locked = x * x + z * z <= radius * radius


func _record() -> void:
	if _path_count > 0 and _path[_path_count - 1] == position:
		return
	if _path_count == PATH_CAPACITY:
		_invalid("shot path capacity exceeded")
		return
	_path[_path_count] = position
	_path_count += 1


func _finish(result: RSGolfRules.Outcome) -> void:
	outcome = result
	mode = Mode.HOLED if result == RSGolfRules.Outcome.HOLED else (Mode.REST if result == RSGolfRules.Outcome.REST else Mode.PENALTY)
	velocity = Vector3.ZERO
	spin = Vector3.ZERO


func _invalid(message: String) -> void:
	mode = Mode.INVALID
	outcome = -1
	push_error("RSGolfBall: " + message)
