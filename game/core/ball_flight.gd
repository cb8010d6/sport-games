class_name RSBallFlight
extends RefCounted
## Deterministic flight of one ball for net and racket games (table tennis, tennis, volleyball): fixed-step
## integration of gravity, quadratic drag, Magnus lift and spin decay; analytic sphere sweeps against bounded planes
## (floor, court, table) and nets (mesh + top cord) with per-surface restitution and friction; a racket / hand hit
## model; and prediction for bots that runs the very same step function, so a prediction equals the live flight.
##
## Units: metres, seconds, kilograms. Spin is the angular velocity in rad/s, world frame, right-hand rule: a ball
## flying along +X with topspin spins about -Z. +Y is up. Positions are the ball centre.
##
## Determinism: the state is kept in 64-bit GDScript floats and a step only uses + - * / and sqrt (exactly rounded
## IEEE operations), never 32-bit Vector3 maths or sin / exp. The trajectory is a pure function of the start
## snapshot and the tick count, so frame rate and the way advance() chunks frame time only change which tick is
## current, never the states. For LAN play send snapshot() right after a hit and restore() it on the other machine
## (hit inputs pass through 32-bit vectors and are not guaranteed identical); both then compute the same flight.
##
## Usage: f := RSBallFlight.new(RSBallFlight.ball_tennis()); f.add_tennis_court(RSBallFlight.surface_clay());
## f.set_state(pos, vel, spin); every frame f.advance(delta) and draw f.render_position(). Listen to `contacted`
## for bounces. Bots: f.predict(), f.time_to_plane(), f.aim(). Prediction costs ~1 step per 1/240 s of flight;
## run it once per contact or hit, not every frame.

## A bounce or net touch during step(); not emitted by prediction copies. normal_speed is the approach speed (m/s).
signal contacted(kind: int, id: StringName, point: Vector3, normal_speed: float)

const HZ := 240                     ## fixed steps per second
const STEP := 1.0 / HZ              ## s
const MAX_FRAME_STEPS := 60         ## advance() runs at most this many steps per call; the rest of a long hitch is dropped
const MAX_CONTACTS := 4             ## contacts resolved inside one step
const GRAVITY := 9.81               ## m/s^2
const REST_SPEED := 0.15            ## m/s: a plane bounce slower than this along the normal settles into rolling
const STOP_SPEED := 0.02            ## m/s: a rolling ball slower than this stops
const EPS := 1e-9                   ## m: contact tolerance

const CONTACT_SURFACE := 0
const CONTACT_NET := 1              ## the net mesh
const CONTACT_CORD := 2             ## the top cord / tape of a net

const TABLE_SIZE := Vector2(1.525, 2.74)   ## m, table tennis table width x length
const TABLE_HEIGHT := 0.76                 ## m
const TABLE_NET_HEIGHT := 0.1525           ## m above the table
const TABLE_NET_HALF := 0.915              ## m, half the net length (overhangs the table by 15.25 cm)
const TENNIS_SIZE := Vector2(10.97, 23.77) ## m, doubles court
const TENNIS_NET_HEIGHT := 0.914           ## m at the centre strap
const TENNIS_NET_HALF := 6.4               ## m, half the net length between the posts
const BEACH_SIZE := Vector2(8.0, 16.0)     ## m, beach volleyball court
const BEACH_NET_HEIGHT := 2.43             ## m, men's net top
const BEACH_NET_DEPTH := 1.0               ## m, height of the net mesh below the top tape
const BEACH_NET_HALF := 4.25               ## m, half the net length


class Ball:
	## Physical constants of one ball type; presets are RSBallFlight.ball_*().
	var mass := 0.0577              ## kg
	var radius := 0.0335            ## m
	var drag := 0.55                ## drag coefficient Cd
	var lift_max := 0.35            ## cap of the Magnus lift coefficient Cl = S / (1 + 2 S), S = r |w| / |v|
	var spin_decay := 0.03          ## 1/s, fraction of spin lost per second in flight
	var inertia := 0.55             ## I / (m r^2): 2/5 solid sphere, 2/3 thin shell
	var air_density := 1.2          ## kg/m^3

	func _init(m := 0.0577, r := 0.0335, cd := 0.55, cl_max := 0.35, decay := 0.03, inertia_factor := 0.55) -> void:
		mass = m
		radius = r
		drag = cd
		lift_max = cl_max
		spin_decay = decay
		inertia = inertia_factor


class Surface:
	## Contact parameters of a fixed surface or of a moving hitter (racket, forearms, hand); presets are
	## RSBallFlight.surface_*(), racket_*() and hands_*().
	var restitution := 0.8          ## normal coefficient of restitution at low impact speed
	var restitution_drop := 0.0     ## restitution lost per m/s of normal impact speed (rackets lose COR when hit hard)
	var restitution_min := 0.05
	var friction := 0.5             ## Coulomb coefficient of the tangential impulse
	var spin_grip := 0.0            ## 0: friction can at most stop the contact slip (rolling); > 0: grippy rubber reverses it
	var rolling := 0.03             ## rolling resistance as a fraction of g once the ball settles on the surface
	var mass := INF                 ## kg, effective mass of a moving hitter at the contact point; INF = immovable
	var dwell := 0.0                ## 0..1 hitters only: the ball pockets in the strings / rubber and leaves partly
	                                ## along the swing path; 0 = pure impulse, 1 = fully along the hitter velocity

	func _init(e := 0.8, mu := 0.5, grip := 0.0, roll := 0.03) -> void:
		restitution = e
		friction = mu
		spin_grip = grip
		rolling = roll


class Prediction:
	## Result of predict(). Times are seconds from the moment predict() was called.
	var bounces := PackedVector3Array()          ## surface contact points (ball centre), in order
	var bounce_times := PackedFloat64Array()
	var bounce_ids: Array[StringName] = []
	var bounce_velocities := PackedVector3Array() ## velocity just before each bounce
	var net_crossed := false       ## the ball centre crossed a net plane inside the net's width
	var net_clearance := INF       ## m between the ball's bottom and the net top at the first crossing (< 0: touched)
	var net_time := -1.0
	var net_hit := false           ## touched a net mesh or cord before the last recorded bounce
	var end_position := Vector3.ZERO
	var end_velocity := Vector3.ZERO
	var end_time := 0.0
	var settled := false           ## the ball came to rest

	func landed() -> bool:
		return not bounces.is_empty()

	func land_point() -> Vector3:
		return bounces[0] if not bounces.is_empty() else end_position

	func land_time() -> float:
		return bounce_times[0] if not bounce_times.is_empty() else -1.0


class _Plane:
	var id: StringName
	var surface: Surface
	var p: PackedFloat64Array      ## point (3), normal (3), axis u (3), axis v (3), half extents (2)


class _Net:
	var id: StringName
	var surface: Surface
	var cord: Surface
	var c: PackedFloat64Array      ## centre x, z, normal x, z, half width, top y, bottom y


var ball: Ball
var tick := 0                      ## steps since the last set_state() / restore()
var resting := false               ## settled on a plane and rolling (or stopped)
var emit_events := true

var _planes: Array[_Plane] = []
var _nets: Array[_Net] = []
var _px := 0.0
var _py := 0.0
var _pz := 0.0
var _vx := 0.0
var _vy := 0.0
var _vz := 0.0
var _wx := 0.0
var _wy := 0.0
var _wz := 0.0
var _qx := 0.0                     ## position before the last step, for render interpolation
var _qy := 0.0
var _qz := 0.0
var _rest_plane := -1
var _acc := 0.0
var _kd := 0.0                     ## drag acceleration per (m/s)^2
var _km := 0.0                     ## lift acceleration per (m/s)^2 per unit Cl
var _decay := 1.0
var _ax := 0.0                     ## scratch output of _accel()
var _ay := 0.0
var _az := 0.0
var _hit_kind := 0                 ## scratch output of _sweep()
var _hit_index := 0
var _hnx := 0.0
var _hny := 0.0
var _hnz := 0.0
var _record: Prediction = null
var _ignore_nets := false


func _init(b: Ball = null) -> void:
	set_ball(b if b != null else ball_tennis())


func set_ball(b: Ball) -> void:
	ball = b
	var area := PI * b.radius * b.radius
	_kd = 0.5 * b.air_density * b.drag * area / b.mass
	_km = 0.5 * b.air_density * area / b.mass
	_decay = maxf(1.0 - b.spin_decay * STEP, 0.0)


# --- presets ------------------------------------------------------------------------------------------------------

static func ball_table_tennis() -> Ball:
	return Ball.new(0.0027, 0.020, 0.50, 0.45, 0.15, 2.0 / 3.0)    # 40 mm, 2.7 g celluloid / ABS shell


static func ball_tennis() -> Ball:
	return Ball.new(0.0577, 0.0335, 0.55, 0.35, 0.03, 0.55)        # 6.7 cm, 57.7 g, felt drag


static func ball_volleyball() -> Ball:
	return Ball.new(0.27, 0.106, 0.30, 0.35, 0.08, 2.0 / 3.0)      # beach ball, 66-68 cm round, 270 g


static func surface_hard_court() -> Surface:
	return Surface.new(0.78, 0.60)          # ITF medium pace: fast, low bounce


static func surface_clay() -> Surface:
	return Surface.new(0.83, 0.75)          # slow: more friction, steeper and higher bounce, more spin effect


static func surface_grass() -> Surface:
	return Surface.new(0.74, 0.45)


static func surface_table() -> Surface:
	return Surface.new(0.89, 0.25, 0.0, 0.01)   # ITTF: 30.5 cm drop rebounds at least 23 cm


static func surface_floor() -> Surface:
	return Surface.new(0.80, 0.40, 0.0, 0.03)   # wooden sports floor


static func surface_sand() -> Surface:
	return Surface.new(0.25, 0.90, 0.0, 0.80)


static func surface_net() -> Surface:
	return Surface.new(0.12, 0.50)


static func surface_net_cord() -> Surface:
	return Surface.new(0.35, 0.30)


static func racket_table_tennis() -> Surface:
	var s := Surface.new(0.88, 0.80, 0.25)      # inverted rubber: high grip, reverses slip for heavy spin
	s.restitution_drop = 0.004
	s.mass = 0.15
	s.dwell = 0.15
	return s


static func racket_tennis() -> Surface:
	var s := Surface.new(0.86, 0.45, 0.10)
	s.restitution_drop = 0.002
	s.mass = 0.30                               # effective mass near the sweet spot of a 300 g racket
	s.dwell = 0.20
	return s


static func hands_bump() -> Surface:
	var s := Surface.new(0.50, 0.60)            # forearm platform
	s.mass = 3.0
	return s


static func hands_set() -> Surface:
	var s := Surface.new(0.25, 0.70)            # soft hands: absorb, then push along the hand velocity
	s.mass = 2.0
	s.dwell = 0.6
	return s


static func hands_spike() -> Surface:
	var s := Surface.new(0.60, 0.70)
	s.mass = 1.5
	s.dwell = 0.1
	return s


# --- world --------------------------------------------------------------------------------------------------------

func add_plane(id: StringName, surface: Surface, point: Vector3, normal := Vector3.UP,
		half_extents := Vector2(INF, INF), axis := Vector3.RIGHT) -> int:
	## A one-sided rectangle (or infinite plane) the ball bounces off from the normal side. half_extents are along
	## `axis` (projected into the plane) and normal x axis. Returns the plane index.
	var n := normal.normalized()
	var u := (axis - n * axis.dot(n)).normalized()
	var v := n.cross(u)
	var pl := _Plane.new()
	pl.id = id
	pl.surface = surface
	pl.p = PackedFloat64Array([point.x, point.y, point.z, n.x, n.y, n.z, u.x, u.y, u.z, v.x, v.y, v.z,
			half_extents.x, half_extents.y])
	_planes.append(pl)
	return _planes.size() - 1


func add_net(id: StringName, surface: Surface, center: Vector3, normal: Vector3, half_width: float, top: float,
		bottom: float, cord: Surface = null) -> int:
	## A vertical net through `center` (only x and z are used) facing `normal` (horizontal), from `bottom` to `top`
	## height and `half_width` either side. The top edge is a cord the ball can clip; both sides collide.
	var n := Vector3(normal.x, 0.0, normal.z).normalized()
	var net := _Net.new()
	net.id = id
	net.surface = surface
	net.cord = cord if cord != null else surface
	net.c = PackedFloat64Array([center.x, center.z, n.x, n.z, half_width, top, bottom])
	_nets.append(net)
	return _nets.size() - 1


func clear_world() -> void:
	_planes = []
	_nets = []
	resting = false


func add_table_tennis_table(floor_center: Vector3, length_axis := Vector3.FORWARD, floor := surface_floor()) -> void:
	## Floor, ITTF table top and net centred on floor_center, the table's length along length_axis.
	var along := Vector3(length_axis.x, 0.0, length_axis.z).normalized()
	var side := along.cross(Vector3.UP)
	add_plane(&"floor", floor, floor_center)
	var top := floor_center + Vector3.UP * TABLE_HEIGHT
	add_plane(&"table", surface_table(), top, Vector3.UP, Vector2(TABLE_SIZE.x * 0.5, TABLE_SIZE.y * 0.5), side)
	add_net(&"net", surface_net(), top, along, TABLE_NET_HALF, top.y + TABLE_NET_HEIGHT, top.y, surface_net_cord())


func add_tennis_court(court: Surface, floor_center := Vector3.ZERO, length_axis := Vector3.FORWARD) -> void:
	## Infinite court surface and the net, net line through floor_center across length_axis.
	var along := Vector3(length_axis.x, 0.0, length_axis.z).normalized()
	add_plane(&"court", court, floor_center)
	add_net(&"net", surface_net(), floor_center, along, TENNIS_NET_HALF, floor_center.y + TENNIS_NET_HEIGHT,
			floor_center.y, surface_net_cord())


func add_beach_court(floor_center := Vector3.ZERO, length_axis := Vector3.FORWARD) -> void:
	## Sand and a beach volleyball net (open below the mesh), net line through floor_center.
	var along := Vector3(length_axis.x, 0.0, length_axis.z).normalized()
	add_plane(&"sand", surface_sand(), floor_center)
	var top := floor_center.y + BEACH_NET_HEIGHT
	add_net(&"net", surface_net(), floor_center, along, BEACH_NET_HALF, top, top - BEACH_NET_DEPTH, surface_net_cord())


# --- state --------------------------------------------------------------------------------------------------------

func set_state(position: Vector3, velocity: Vector3, spin := Vector3.ZERO) -> void:
	_px = position.x
	_py = position.y
	_pz = position.z
	_vx = velocity.x
	_vy = velocity.y
	_vz = velocity.z
	_wx = spin.x
	_wy = spin.y
	_wz = spin.z
	_qx = _px
	_qy = _py
	_qz = _pz
	tick = 0
	_acc = 0.0
	resting = false
	_rest_plane = -1


func position() -> Vector3:
	return Vector3(_px, _py, _pz)


func velocity() -> Vector3:
	return Vector3(_vx, _vy, _vz)


func spin() -> Vector3:
	return Vector3(_wx, _wy, _wz)


func time() -> float:
	return tick * STEP


func render_position() -> Vector3:
	## Position between the last two steps by the time advance() has not consumed yet; draw this.
	var a := _acc / STEP
	return Vector3(_qx + (_px - _qx) * a, _qy + (_py - _qy) * a, _qz + (_pz - _qz) * a)


func energy() -> float:
	## J: kinetic (incl. spin) + potential above y = 0. Never increases at a contact with a fixed surface.
	var lin := _vx * _vx + _vy * _vy + _vz * _vz
	var rot := ball.inertia * ball.radius * ball.radius * (_wx * _wx + _wy * _wy + _wz * _wz)
	return 0.5 * ball.mass * (lin + rot) + ball.mass * GRAVITY * _py


func snapshot() -> PackedFloat64Array:
	## Exact state (tick, position, velocity, spin, rest) for the network or a replay.
	return PackedFloat64Array([tick, _px, _py, _pz, _vx, _vy, _vz, _wx, _wy, _wz, 1.0 if resting else 0.0, _rest_plane])


func restore(s: PackedFloat64Array) -> void:
	if s.size() != 12:
		push_error("RSBallFlight.restore: bad snapshot size %d" % s.size())
		return
	tick = int(s[0])
	_px = s[1]
	_py = s[2]
	_pz = s[3]
	_vx = s[4]
	_vy = s[5]
	_vz = s[6]
	_wx = s[7]
	_wy = s[8]
	_wz = s[9]
	_rest_plane = int(s[11])
	resting = s[10] != 0.0 and _rest_plane >= 0 and _rest_plane < _planes.size()
	_qx = _px
	_qy = _py
	_qz = _pz
	_acc = 0.0


func copy() -> RSBallFlight:
	## Same ball, colliders (shared, do not add more to the copy) and exact state; emits no events.
	var f := RSBallFlight.new(ball)
	f._planes = _planes
	f._nets = _nets
	f.restore(snapshot())
	f._acc = _acc
	f.emit_events = false
	return f


# --- stepping -----------------------------------------------------------------------------------------------------

func advance(delta: float) -> int:
	## Run the fixed steps that fit in the accumulated frame time; returns how many ran.
	_acc += maxf(delta, 0.0)
	var n := 0
	while _acc >= STEP and n < MAX_FRAME_STEPS:
		step()
		_acc -= STEP
		n += 1
	if n == MAX_FRAME_STEPS:
		_acc = minf(_acc, STEP)
	return n


func advance_to_tick(target: int) -> void:
	## Step until `tick` reaches target (e.g. a hit event's tick converted from the shared match clock).
	while tick < target:
		step()


func step() -> void:
	_qx = _px
	_qy = _py
	_qz = _pz
	tick += 1
	if resting:
		_roll(STEP)
		return
	_fly(STEP)
	_wx *= _decay
	_wy *= _decay
	_wz *= _decay


func _accel(vx: float, vy: float, vz: float) -> void:
	var sp := sqrt(vx * vx + vy * vy + vz * vz)
	_ax = -_kd * sp * vx
	_ay = -_kd * sp * vy - GRAVITY
	_az = -_kd * sp * vz
	var w2 := _wx * _wx + _wy * _wy + _wz * _wz
	if w2 > 1e-12 and sp > 1e-6:
		var w := sqrt(w2)
		var s := ball.radius * w / sp
		var k := _km * minf(s / (1.0 + 2.0 * s), ball.lift_max) * sp / w
		_ax += k * (_wy * vz - _wz * vy)
		_ay += k * (_wz * vx - _wx * vz)
		_az += k * (_wx * vy - _wy * vx)


func _fly(dt: float) -> void:
	var left := dt
	for _i in MAX_CONTACTS + 1:
		# Midpoint (RK2) velocity; the position moves along the chord at the midpoint velocity.
		_accel(_vx, _vy, _vz)
		var h := left * 0.5
		var mx := _vx + _ax * h
		var my := _vy + _ay * h
		var mz := _vz + _az * h
		_accel(mx, my, mz)
		var nx := _vx + _ax * left
		var ny := _vy + _ay * left
		var nz := _vz + _az * left
		var dx := mx * left
		var dy := my * left
		var dz := mz * left
		var f := _sweep(dx, dy, dz)
		if f > 1.0:
			_px += dx
			_py += dy
			_pz += dz
			_vx = nx
			_vy = ny
			_vz = nz
			return
		_px += dx * f
		_py += dy * f
		_pz += dz * f
		_vx += (nx - _vx) * f
		_vy += (ny - _vy) * f
		_vz += (nz - _vz) * f
		_resolve()
		left *= 1.0 - f
		if resting:
			_roll(left)
			return
		if left <= 0.0:
			return


func _sweep(dx: float, dy: float, dz: float) -> float:
	## Earliest contact fraction along the move (0..1), or 2.0. Sets _hit_kind / _hit_index / _hn*.
	var best := 2.0
	var r := ball.radius
	for i in _planes.size():
		var p := _planes[i].p
		var nx := p[3]
		var ny := p[4]
		var nz := p[5]
		var dn := dx * nx + dy * ny + dz * nz
		if dn >= 0.0:
			continue
		var d0 := (_px - p[0]) * nx + (_py - p[1]) * ny + (_pz - p[2]) * nz - r
		if d0 < -EPS or d0 + dn >= 0.0:
			continue
		var f := maxf(d0, 0.0) / -dn
		if f >= best:
			continue
		var cx := _px + dx * f - p[0]
		var cy := _py + dy * f - p[1]
		var cz := _pz + dz * f - p[2]
		if absf(cx * p[6] + cy * p[7] + cz * p[8]) > p[12] or absf(cx * p[9] + cy * p[10] + cz * p[11]) > p[13]:
			continue
		best = f
		_hit_kind = CONTACT_SURFACE
		_hit_index = i
		_hnx = nx
		_hny = ny
		_hnz = nz
	if _ignore_nets:
		return best
	for i in _nets.size():
		var c := _nets[i].c
		var nx := c[2]
		var nz := c[3]
		var hw := c[4]
		var top := c[5]
		var d0 := (_px - c[0]) * nx + (_pz - c[1]) * nz
		var dn := dx * nx + dz * nz
		# Net mesh: a two-sided vertical rectangle.
		var s := 1.0 if d0 > 0.0 or (d0 == 0.0 and dn < 0.0) else -1.0
		var e0 := s * d0 - r
		var e1 := s * (d0 + dn) - r
		if s * dn < 0.0 and e0 >= -EPS and e1 < 0.0:
			var f := maxf(e0, 0.0) / (-s * dn)
			var y := _py + dy * f
			var along := (_px + dx * f - c[0]) * -nz + (_pz + dz * f - c[1]) * nx
			if f < best and absf(along) <= hw and y <= top and y >= c[6]:
				best = f
				_hit_kind = CONTACT_NET
				_hit_index = i
				_hnx = s * nx
				_hny = 0.0
				_hnz = s * nz
		# Top cord: the ball centre reaching distance r from the horizontal line (x, top, z) + t * (-nz, 0, nx).
		var wx := _px - c[0]
		var wy := _py - top
		var wz := _pz - c[1]
		var wt := wx * -nz + wz * nx
		var w0x := wx + nz * wt
		var w0z := wz - nx * wt
		var dt := dx * -nz + dz * nx
		var ddx := dx + nz * dt
		var ddz := dz - nx * dt
		var a := ddx * ddx + dy * dy + ddz * ddz
		var b := 2.0 * (w0x * ddx + wy * dy + w0z * ddz)
		var cc := w0x * w0x + wy * wy + w0z * w0z - r * r
		if a <= 0.0 or b >= 0.0 or cc < 0.0:
			continue
		var disc := b * b - 4.0 * a * cc
		if disc < 0.0:
			continue
		var f := (-b - sqrt(disc)) / (2.0 * a)
		if f < 0.0 or f > 1.0 or f >= best or absf(wt + dt * f) > hw:
			continue
		best = f
		_hit_kind = CONTACT_CORD
		_hit_index = i
		_hnx = (w0x + ddx * f) / r
		_hny = (wy + dy * f) / r
		_hnz = (w0z + ddz * f) / r
	return best


func _resolve() -> void:
	var surface: Surface
	var id: StringName
	if _hit_kind == CONTACT_SURFACE:
		surface = _planes[_hit_index].surface
		id = _planes[_hit_index].id
	else:
		var net := _nets[_hit_index]
		surface = net.surface if _hit_kind == CONTACT_NET else net.cord
		id = net.id
	var before := Vector3(_vx, _vy, _vz)
	var speed := _impact(_hnx, _hny, _hnz, surface, 0.0, 0.0, 0.0)
	if _hit_kind == CONTACT_SURFACE and _record != null:
		_record.bounces.append(position())
		_record.bounce_times.append(tick * STEP)
		_record.bounce_ids.append(id)
		_record.bounce_velocities.append(before)
	elif _record != null:
		_record.net_hit = true
	if _hit_kind == CONTACT_SURFACE and _hny > 0.5:
		var out := _vx * _hnx + _vy * _hny + _vz * _hnz
		if out < REST_SPEED:
			# Settle: drop the normal velocity and roll on this plane from now on.
			_vx -= out * _hnx
			_vy -= out * _hny
			_vz -= out * _hnz
			resting = true
			_rest_plane = _hit_index
	if emit_events:
		contacted.emit(_hit_kind, id, position(), speed)


func _impact(nx: float, ny: float, nz: float, s: Surface, ux: float, uy: float, uz: float) -> float:
	## Ball against a surface (unit normal n pointing to the ball) moving at u. Normal: restitution, with the hitter's
	## effective mass; tangential: Coulomb friction on the contact-point slip, capped where the slip stops (rolling),
	## or reverses for grippy surfaces. Returns the approach speed along n, 0 when the ball is not approaching.
	var rx := _vx - ux
	var ry := _vy - uy
	var rz := _vz - uz
	var vn := rx * nx + ry * ny + rz * nz
	if vn >= 0.0:
		return 0.0
	var e := clampf(s.restitution + s.restitution_drop * vn, s.restitution_min, 1.0)
	var mr := ball.mass / s.mass
	var ea := maxf((e - mr) / (1.0 + mr), 0.0)
	var jn := (1.0 + ea) * -vn
	var tx := rx - vn * nx
	var ty := ry - vn * ny
	var tz := rz - vn * nz
	var r := ball.radius
	# Slip of the contact point at -r n: tangential velocity + w x (-r n).
	var sx := tx - r * (_wy * nz - _wz * ny)
	var sy := ty - r * (_wz * nx - _wx * nz)
	var sz := tz - r * (_wx * ny - _wy * nx)
	var slip := sqrt(sx * sx + sy * sy + sz * sz)
	var jt := 0.0
	if slip > 1e-9:
		var k := ball.inertia
		jt = minf(s.friction * jn, (1.0 + s.spin_grip) * slip * k / (1.0 + k))
		sx /= slip
		sy /= slip
		sz /= slip
	var out := -ea * vn
	_vx = ux + tx - jt * sx + out * nx
	_vy = uy + ty - jt * sy + out * ny
	_vz = uz + tz - jt * sz + out * nz
	var spin_gain := jt / (ball.inertia * r)
	_wx += spin_gain * (ny * sz - nz * sy)
	_wy += spin_gain * (nz * sx - nx * sz)
	_wz += spin_gain * (nx * sy - ny * sx)
	var u := sqrt(ux * ux + uy * uy + uz * uz)
	if s.dwell > 0.0 and u > 1e-6:
		# Pocketing: turn the outgoing direction toward the hitter's path, keeping the speed.
		var sp := sqrt(_vx * _vx + _vy * _vy + _vz * _vz)
		var bx := _vx / sp + (ux / u - _vx / sp) * s.dwell
		var by := _vy / sp + (uy / u - _vy / sp) * s.dwell
		var bz := _vz / sp + (uz / u - _vz / sp) * s.dwell
		var bl := sqrt(bx * bx + by * by + bz * bz)
		if bl > 1e-6 and (bx * nx + by * ny + bz * nz) > 0.0:
			_vx = bx / bl * sp
			_vy = by / bl * sp
			_vz = bz / bl * sp
	return -vn


func _roll(dt: float) -> void:
	var p := _planes[_rest_plane].p
	var sp := sqrt(_vx * _vx + _vy * _vy + _vz * _vz)
	var slow := _planes[_rest_plane].surface.rolling * GRAVITY * dt
	if sp <= maxf(slow, STOP_SPEED):
		_vx = 0.0
		_vy = 0.0
		_vz = 0.0
	else:
		var k := (sp - slow) / sp
		_vx *= k
		_vy *= k
		_vz *= k
	_px += _vx * dt
	_py += _vy * dt
	_pz += _vz * dt
	# Rolling without slip: w = n x v / r.
	var r := ball.radius
	_wx = (p[4] * _vz - p[5] * _vy) / r
	_wy = (p[5] * _vx - p[3] * _vz) / r
	_wz = (p[3] * _vy - p[4] * _vx) / r
	var cx := _px - p[0]
	var cy := _py - p[1]
	var cz := _pz - p[2]
	if absf(cx * p[6] + cy * p[7] + cz * p[8]) > p[12] or absf(cx * p[9] + cy * p[10] + cz * p[11]) > p[13]:
		resting = false            # rolled off the edge: fall from the next step
		_rest_plane = -1


# --- hits ---------------------------------------------------------------------------------------------------------

func hit(contact_point: Vector3, face_normal: Vector3, hitter_velocity: Vector3, hitter: Surface) -> bool:
	## A racket face (or forearms / hand) through contact_point with outward normal face_normal, moving at
	## hitter_velocity (m/s), strikes the ball: the ball centre moves to contact_point + normal * radius and gets the
	## outgoing velocity and spin from _impact. Brushing up across the face gives topspin, a face tilted back gives
	## lift / backspin. Returns false (state unchanged) when the ball is not approaching the face.
	var n := face_normal.normalized()
	if _impact(n.x, n.y, n.z, hitter, hitter_velocity.x, hitter_velocity.y, hitter_velocity.z) <= 0.0:
		return false        # _impact changes nothing when the ball is not approaching
	_px = contact_point.x + n.x * ball.radius
	_py = contact_point.y + n.y * ball.radius
	_pz = contact_point.z + n.z * ball.radius
	_qx = _px
	_qy = _py
	_qz = _pz
	resting = false
	_rest_plane = -1
	return true


# --- prediction ---------------------------------------------------------------------------------------------------

func predict(max_time := 3.0, max_bounces := 1) -> Prediction:
	## Simulate a copy until `max_bounces` surface bounces, max_time seconds or rest. Records bounces, the first net
	## plane crossing and clearance, and net touches. Leaves this flight untouched.
	var out := Prediction.new()
	var f := copy()
	f._record = out
	var t0 := f.tick
	var steps := int(ceil(max_time * HZ))
	for _i in steps:
		f.step()
		if not out.net_crossed:
			_check_net(f, out, t0)
		if out.bounces.size() >= max_bounces or f.resting:
			break
	out.settled = f.resting
	out.end_position = f.position()
	out.end_velocity = f.velocity()
	out.end_time = (f.tick - t0) * STEP
	var since := t0 * STEP
	for i in out.bounce_times.size():
		out.bounce_times[i] -= since
	return out


func _check_net(f: RSBallFlight, out: Prediction, t0: int) -> void:
	for net in f._nets:
		var c := net.c
		var d0 := (f._qx - c[0]) * c[2] + (f._qz - c[1]) * c[3]
		var d1 := (f._px - c[0]) * c[2] + (f._pz - c[1]) * c[3]
		if (d0 > 0.0) == (d1 > 0.0) or d0 == d1:
			continue
		var a := d0 / (d0 - d1)
		var x := f._qx + (f._px - f._qx) * a
		var z := f._qz + (f._pz - f._qz) * a
		if absf((x - c[0]) * -c[3] + (z - c[1]) * c[2]) > c[4]:
			continue
		out.net_crossed = true
		out.net_clearance = f._qy + (f._py - f._qy) * a - f.ball.radius - c[5]
		out.net_time = (f.tick - 1 - t0 + a) * STEP
		return


func time_to_height(height: float, max_time := 3.0, descending := true) -> float:
	## Seconds until the ball centre passes `height` (going down, or up when descending is false); -1 if not within
	## max_time. Interpolated inside the step.
	var f := copy()
	var t0 := f.tick
	for _i in int(ceil(max_time * HZ)):
		f.step()
		var crossed := f._qy > height and f._py <= height if descending else f._qy < height and f._py >= height
		if crossed:
			return (f.tick - 1 - t0 + (f._qy - height) / (f._qy - f._py)) * STEP
		if f.resting:
			break
	return -1.0


func time_to_plane(point: Vector3, normal: Vector3, max_time := 3.0) -> float:
	## Seconds until the ball centre crosses the plane (either direction), e.g. a player's hitting plane; -1 if not.
	var f := copy()
	var t0 := f.tick
	var n := normal.normalized()
	var d0 := (f._px - point.x) * n.x + (f._py - point.y) * n.y + (f._pz - point.z) * n.z
	for _i in int(ceil(max_time * HZ)):
		f.step()
		var d1 := (f._px - point.x) * n.x + (f._py - point.y) * n.y + (f._pz - point.z) * n.z
		if (d0 > 0.0) != (d1 > 0.0) and d0 != d1:
			return (f.tick - 1 - t0 + d0 / (d0 - d1)) * STEP
		if f.resting:
			break
		d0 = d1
	return -1.0


func probe(seconds: float) -> RSBallFlight:
	## A copy advanced by `seconds` (rounded down to whole steps): read position() / velocity() of the future ball.
	var f := copy()
	f.advance_to_tick(f.tick + int(seconds * HZ))
	return f


func aim(from: Vector3, target: Vector3, speed: float, spin := Vector3.ZERO, lob := false, iterations := 8) -> Vector3:
	## Launch velocity of `speed` from `from` whose first surface bounce (nets ignored) lands at `target`, using the
	## real drag and Magnus; lob picks the high arc. Returns Vector3.ZERO when out of reach. Uses trigonometry, so
	## the result may differ in the last bits between machines: send the launched snapshot(), not the aim inputs.
	## Check the net separately with predict().net_clearance.
	var flat := Vector3(target.x - from.x, 0.0, target.z - from.z)
	var dist := flat.length()
	if dist < 0.01 or speed <= 0.0:
		return Vector3.ZERO
	var heading := atan2(flat.x, flat.z)
	var pitch := deg_to_rad(55.0) if lob else 0.0
	var best := Vector3.ZERO
	var best_err := INF
	var prev_pitch := NAN
	var prev_err := 0.0
	var max_time := 2.0 * dist / speed + 3.0
	for _i in iterations:
		var v := Vector3(sin(heading) * cos(pitch), sin(pitch), cos(heading) * cos(pitch)) * speed
		var f := copy()
		f._ignore_nets = true
		f.set_state(from, v, spin)
		var pr := f.predict(max_time, 1)
		if not pr.landed():
			pitch -= deg_to_rad(5.0) if not lob else -deg_to_rad(5.0)
			continue
		var land := pr.land_point() - Vector3(0.0, ball.radius, 0.0)
		var off := Vector3(land.x - from.x, 0.0, land.z - from.z)
		var err := off.length() - dist
		var miss := Vector3(target.x - land.x, 0.0, target.z - land.z).length()
		if miss < best_err:
			best_err = miss
			best = v
		if miss < 0.01:
			break
		# Heading: rotate by the angular miss; pitch: secant on the range error (lobs reach further when flatter).
		heading += atan2(flat.x, flat.z) - atan2(off.x, off.z)
		var next := pitch - err * (0.3 / dist) * (-1.0 if lob else 1.0)
		if not is_nan(prev_pitch) and absf(err - prev_err) > 1e-6:
			next = pitch - err * (pitch - prev_pitch) / (err - prev_err)
		prev_pitch = pitch
		prev_err = err
		pitch = clampf(next, deg_to_rad(-60.0), deg_to_rad(80.0))
	return best if best_err < maxf(0.05, dist * 0.02) else Vector3.ZERO
