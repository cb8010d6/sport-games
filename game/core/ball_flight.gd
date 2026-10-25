class_name RSBallFlight
extends RefCounted
## Pure single-ball flight for table tennis, tennis and volleyball; no nodes or game rules.
## Units: metres, seconds, kilograms; +Y up; positions are ball centres. Spin is world-frame
## angular velocity in rad/s (right-hand rule: topspin along +X is about -Z).
## Authoritative state uses 64-bit float components. Steps use scalar arithmetic and sqrt;
## Vector3 values are only inputs/outputs. World geometry and ball parameters are shared by
## copy(); finish configuring them before copying. Call set_ball() after editing a Ball.

signal contacted(kind: int, id: StringName, point: Vector3, normal_speed: float)

const HZ := 240
const STEP := 1.0 / HZ
const MAX_FRAME_STEPS := 60
const GRAVITY := 9.81               ## m/s²
const CONTACT_SURFACE := 0
const CONTACT_NET := 1
const CONTACT_CORD := 2
const MAX_CONTACTS := 4
const REST_SPEED := 0.15            ## m/s, outgoing normal speed that settles on a plane
const STOP_SPEED := 0.02            ## m/s, rolling stop threshold
const EPS := 1e-9                   ## m, separation tolerance
const CLOCK_EPS := 1e-10            ## ticks, only snaps floating-point clock residue
const TABLE_SIZE := Vector2(1.525, 2.74)
const TABLE_HEIGHT := 0.76
const TABLE_NET_HEIGHT := 0.1525
const TABLE_NET_HALF := 0.915
const TENNIS_NET_HEIGHT := 0.914
const TENNIS_NET_HALF := 6.4
const BEACH_NET_HEIGHT := 2.43
const BEACH_NET_DEPTH := 1.0
const BEACH_NET_HALF := 4.25


class Ball:
	var mass := 0.0577              ## kg
	var radius := 0.0335            ## m
	var drag := 0.55                ## Cd
	var lift_max := 0.35            ## cap on Cl = S / (1 + 2 S), S = r |w| / |v|
	var spin_decay := 0.03          ## 1/s
	var inertia := 0.55             ## I / (m r²)
	var air_density := 1.2          ## kg/m³

	func _init(m := 0.0577, r := 0.0335, cd := 0.55, lift := 0.35,
			decay := 0.03, inertia_factor := 0.55) -> void:
		mass = m
		radius = r
		drag = cd
		lift_max = lift
		spin_decay = decay
		inertia = inertia_factor


class Surface:
	var restitution := 0.8
	var restitution_drop := 0.0     ## COR lost per m/s of normal approach speed
	var restitution_min := 0.05
	var friction := 0.5             ## Coulomb coefficient
	var spin_grip := 0.0            ## extra contact slip reversal for grippy materials
	var rolling := 0.03             ## rolling resistance / normal load
	var mass := INF                 ## kg, effective hitter mass; INF for a fixed surface
	var dwell := 0.0                ## 0..1, turn outgoing motion towards the hitter's path

	func _init(e := 0.8, mu := 0.5, grip := 0.0, roll := 0.03) -> void:
		restitution = e
		friction = mu
		spin_grip = grip
		rolling = roll


class Prediction:
	var bounces := PackedVector3Array()
	var bounce_times := PackedFloat64Array()
	var bounce_ids: Array[StringName] = []
	var bounce_velocities := PackedVector3Array()
	var net_crossed := false
	var net_clearance := INF        ## first crossing, or first touch if the net blocks crossing
	var net_time := -1.0            ## seconds from predict(), at that crossing/touch
	var net_hit := false
	var end_position := Vector3.ZERO
	var end_velocity := Vector3.ZERO
	var end_time := 0.0
	var settled := false

	func landed() -> bool:
		return not bounces.is_empty()

	func land_point() -> Vector3:
		return bounces[0] if landed() else end_position

	func land_time() -> float:
		return bounce_times[0] if landed() else -1.0


class _Plane:
	var id: StringName
	var key: String
	var surface: Surface
	## origin (3), normal (3), tangent u (3), tangent v (3), half extents (2).
	var p: PackedFloat64Array


class _Net:
	var id: StringName
	var key: String
	var surface: Surface
	var cord: Surface
	var p: PackedFloat64Array
	## centre x/z, horizontal normal x/z, half width, top, bottom.
	var c: PackedFloat64Array


var ball: Ball
var tick := 0
var resting := false
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
var _qx := 0.0                     ## position before the last step, for rendering
var _qy := 0.0
var _qz := 0.0
var _acc := 0.0                    ## fractional ticks, always < 1 after advance()
var _rest_plane := -1
var _kd := 0.0
var _km := 0.0
var _decay := 1.0
var _ax := 0.0                     ## scratch acceleration, never part of a snapshot
var _ay := 0.0
var _az := 0.0
var _contacts_left := 0
var _hit_fraction := 2.0
var _hit_kind := 0
var _hit_index := 0
var _hit_key := ""                 # no-i18n
var _hnx := 0.0
var _hny := 0.0
var _hnz := 0.0
var _rect: PackedFloat64Array       ## scratch rectangle and chord in its local basis
var _ru := 0.0
var _rv := 0.0
var _rn := 0.0
var _du := 0.0
var _dv := 0.0
var _dn := 0.0
var _rect_kind := 0
var _rect_index := 0
var _rect_key := ""                # no-i18n
var _one_sided := true
var _record: Prediction
var _record_tick := 0
var _record_limit := 0
var _elapsed := 0.0                ## elapsed time within the current fixed step
var _ignore_nets := false          ## aim copies only; world arrays remain shared/read-only


func _init(b: Ball = null) -> void:
	set_ball(b if b != null else ball_tennis())


func set_ball(b: Ball) -> void:
	ball = b
	var area := PI * b.radius * b.radius
	_km = 0.5 * b.air_density * area / b.mass
	_kd = _km * b.drag
	_decay = maxf(1.0 - b.spin_decay * STEP, 0.0)


static func ball_table_tennis() -> Ball:
	return Ball.new(0.0027, 0.020, 0.50, 0.45, 0.15, 2.0 / 3.0)


static func ball_tennis() -> Ball:
	return Ball.new()


static func ball_volleyball() -> Ball:
	return Ball.new(0.27, 0.106, 0.30, 0.35, 0.08, 2.0 / 3.0)


static func surface_hard_court() -> Surface:
	return Surface.new(0.78, 0.60)


static func surface_clay() -> Surface:
	return Surface.new(0.83, 0.75)


static func surface_grass() -> Surface:
	return Surface.new(0.74, 0.45)


static func surface_table() -> Surface:
	return Surface.new(0.89, 0.25, 0.0, 0.01)


static func surface_floor() -> Surface:
	return Surface.new(0.80, 0.40)


static func surface_sand() -> Surface:
	return Surface.new(0.25, 0.90, 0.0, 0.80)


static func surface_net() -> Surface:
	return Surface.new(0.12, 0.50)


static func surface_net_cord() -> Surface:
	return Surface.new(0.35, 0.30)


static func racket_table_tennis() -> Surface:
	var s := Surface.new(0.88, 0.80, 0.25)
	s.restitution_drop = 0.004
	s.mass = 0.15
	s.dwell = 0.15
	return s


static func racket_tennis() -> Surface:
	var s := Surface.new(0.86, 0.45, 0.10)
	s.restitution_drop = 0.002
	s.mass = 0.30
	s.dwell = 0.20
	return s


static func hands_bump() -> Surface:
	var s := Surface.new(0.50, 0.60)
	s.mass = 3.0
	return s


static func hands_set() -> Surface:
	var s := Surface.new(0.25, 0.70)
	s.mass = 2.0
	s.dwell = 0.6
	return s


static func hands_spike() -> Surface:
	var s := Surface.new(0.60, 0.70)
	s.mass = 1.5
	s.dwell = 0.1
	return s


func add_plane(id: StringName, surface: Surface, point: Vector3, normal := Vector3.UP,
		half_extents := Vector2(INF, INF), axis := Vector3.RIGHT) -> int:
	if normal.length_squared() == 0.0:
		push_error("RSBallFlight.add_plane: zero normal") # no-i18n
		return -1
	var n := normal.normalized()
	var u := axis - n * axis.dot(n)
	if u.length_squared() < EPS:
		var fallback := Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.FORWARD
		u = fallback - n * fallback.dot(n)
	u = u.normalized()
	var pl := _Plane.new()
	pl.id = id
	pl.key = str(id)
	pl.surface = surface
	pl.p = _rectangle(point, n, u, half_extents)
	_planes.append(pl)
	return _planes.size() - 1


static func _rectangle(p: Vector3, n: Vector3, u: Vector3, half: Vector2) -> PackedFloat64Array:
	# Store an orthonormal basis in doubles, including for normals rotated off the world axes.
	var nx := float(n.x)
	var ny := float(n.y)
	var nz := float(n.z)
	var length := sqrt(nx * nx + ny * ny + nz * nz)
	nx /= length
	ny /= length
	nz /= length
	var dot := u.x * nx + u.y * ny + u.z * nz
	var ux := u.x - dot * nx
	var uy := u.y - dot * ny
	var uz := u.z - dot * nz
	length = sqrt(ux * ux + uy * uy + uz * uz)
	ux /= length
	uy /= length
	uz /= length
	return PackedFloat64Array([p.x, p.y, p.z, nx, ny, nz, ux, uy, uz,
			ny * uz - nz * uy, nz * ux - nx * uz, nx * uy - ny * ux, absf(half.x), absf(half.y)])


func add_net(id: StringName, surface: Surface, center: Vector3, normal: Vector3, half_width: float,
		top: float, bottom: float, cord: Surface = null) -> int:
	var n := Vector3(normal.x, 0.0, normal.z)
	if n.length_squared() == 0.0 or top < bottom:
		push_error("RSBallFlight.add_net: invalid normal or height") # no-i18n
		return -1
	n = n.normalized()
	var net := _Net.new()
	net.id = id
	net.key = str(id)
	net.surface = surface
	net.cord = cord if cord != null else surface
	net.p = _rectangle(Vector3(center.x, (top + bottom) * 0.5, center.z), n,
			Vector3(n.z, 0.0, -n.x), Vector2(half_width, (top - bottom) * 0.5))
	net.p[1] = (top + bottom) * 0.5
	net.p[12] = absf(half_width)
	net.p[13] = (top - bottom) * 0.5
	net.c = PackedFloat64Array([center.x, center.z, net.p[3], net.p[5], absf(half_width), top, bottom])
	_nets.append(net)
	return _nets.size() - 1


func clear_world() -> void:
	_planes = []
	_nets = []
	resting = false
	_rest_plane = -1


func add_table_tennis_table(floor_center: Vector3, length_axis := Vector3.FORWARD, floor := surface_floor()) -> void:
	var along := Vector3(length_axis.x, 0.0, length_axis.z).normalized()
	var top := floor_center + Vector3.UP * TABLE_HEIGHT
	add_plane(&"floor", floor, floor_center) # no-i18n
	add_plane(&"table", surface_table(), top, Vector3.UP, TABLE_SIZE * 0.5, along.cross(Vector3.UP)) # no-i18n
	add_net(&"net", surface_net(), top, along, TABLE_NET_HALF, top.y + TABLE_NET_HEIGHT, top.y, surface_net_cord()) # no-i18n


func add_tennis_court(court: Surface, floor_center := Vector3.ZERO, length_axis := Vector3.FORWARD) -> void:
	var along := Vector3(length_axis.x, 0.0, length_axis.z).normalized()
	add_plane(&"court", court, floor_center) # no-i18n
	add_net(&"net", surface_net(), floor_center, along, TENNIS_NET_HALF,
			floor_center.y + TENNIS_NET_HEIGHT, floor_center.y, surface_net_cord()) # no-i18n


func add_beach_court(floor_center := Vector3.ZERO, length_axis := Vector3.FORWARD) -> void:
	var along := Vector3(length_axis.x, 0.0, length_axis.z).normalized()
	var top := floor_center.y + BEACH_NET_HEIGHT
	add_plane(&"sand", surface_sand(), floor_center) # no-i18n
	add_net(&"net", surface_net(), floor_center, along, BEACH_NET_HALF, top, top - BEACH_NET_DEPTH, surface_net_cord()) # no-i18n


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
	return Vector3(_qx + (_px - _qx) * _acc, _qy + (_py - _qy) * _acc, _qz + (_pz - _qz) * _acc)


func snapshot() -> PackedFloat64Array:
	## First 12 entries: tick, position, velocity, spin, rest flag, supporting plane.
	## Last four preserve render interpolation and fractional frame time exactly.
	return PackedFloat64Array([tick, _px, _py, _pz, _vx, _vy, _vz, _wx, _wy, _wz,
			1.0 if resting else 0.0, _rest_plane, _qx, _qy, _qz, _acc])


func restore(s: PackedFloat64Array) -> void:
	if s.size() != 16:
		push_error("RSBallFlight.restore: invalid snapshot size") # no-i18n
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
	_qx = s[12]
	_qy = s[13]
	_qz = s[14]
	_acc = s[15]


func copy() -> RSBallFlight:
	var f := RSBallFlight.new(ball)
	f._planes = _planes
	f._nets = _nets
	f.restore(snapshot())
	f.emit_events = false
	f._ignore_nets = _ignore_nets
	return f


func advance(delta: float) -> int:
	_acc += maxf(delta, 0.0) * HZ
	var whole := floori(_acc + CLOCK_EPS)
	_acc = maxf(_acc - whole, 0.0)
	if _acc < CLOCK_EPS:
		_acc = 0.0
	var n := mini(whole, MAX_FRAME_STEPS)
	for _i in n:
		step()
	return n


func advance_to_tick(target: int) -> void:
	while tick < target:
		step()


func step() -> void:
	_qx = _px
	_qy = _py
	_qz = _pz
	tick += 1
	_elapsed = 0.0
	_contacts_left = MAX_CONTACTS
	if resting:
		_roll(STEP)
	else:
		_fly(STEP)
	_wx *= _decay
	_wy *= _decay
	_wz *= _decay


func _accel(vx: float, vy: float, vz: float) -> void:
	var speed := sqrt(vx * vx + vy * vy + vz * vz)
	_ax = -_kd * speed * vx
	_ay = -GRAVITY - _kd * speed * vy
	_az = -_kd * speed * vz
	var rotation := sqrt(_wx * _wx + _wy * _wy + _wz * _wz)
	var cx := _wy * vz - _wz * vy
	var cy := _wz * vx - _wx * vz
	var cz := _wx * vy - _wy * vx
	var cross_length := sqrt(cx * cx + cy * cy + cz * cz)
	if speed > EPS and cross_length > EPS:
		var ratio := ball.radius * rotation / speed
		var lift := minf(ball.lift_max, ratio / (1.0 + 2.0 * ratio))
		var scale := _km * speed * speed * lift / cross_length
		_ax += cx * scale
		_ay += cy * scale
		_az += cz * scale


func _fly(dt: float) -> void:
	var left := dt
	while left > 0.0 and _contacts_left > 0:
		# Midpoint RK2 is exact in vacuum; sweep its position chord before committing it.
		_accel(_vx, _vy, _vz)
		var half := left * 0.5
		var mx := _vx + _ax * half
		var my := _vy + _ay * half
		var mz := _vz + _az * half
		_accel(mx, my, mz)
		var nx := _vx + _ax * left
		var ny := _vy + _ay * left
		var nz := _vz + _az * left
		var dx := mx * left
		var dy := my * left
		var dz := mz * left
		var f := _sweep(dx, dy, dz)
		if f > 1.0:
			_record_net(dx, dy, dz, left)
			_elapsed += left
			_px += dx
			_py += dy
			_pz += dz
			_vx = nx
			_vy = ny
			_vz = nz
			return
		_record_net(dx * f, dy * f, dz * f, left * f)
		_elapsed += left * f
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
	# At the contact budget keep the last safe position, rather than tunnel through a fifth collider.


func _sweep(dx: float, dy: float, dz: float, skip_plane := -1) -> float:
	_hit_fraction = 2.0
	for i in _planes.size():
		if i != skip_plane:
			var pl := _planes[i]
			_sweep_rectangle(pl.p, dx, dy, dz, CONTACT_SURFACE, i, pl.key, true)
	for i in (0 if _ignore_nets else _nets.size()):
		var net := _nets[i]
		_sweep_rectangle(net.p, dx, dy, dz, CONTACT_NET, i, net.key, false)
	return _hit_fraction


func _sweep_rectangle(p: PackedFloat64Array, dx: float, dy: float, dz: float,
		kind: int, index: int, key: String, one_sided: bool) -> void:
	_rect = p
	_rect_kind = kind
	_rect_index = index
	_rect_key = key
	_one_sided = one_sided
	var x := _px - p[0]
	var y := _py - p[1]
	var z := _pz - p[2]
	_ru = x * p[6] + y * p[7] + z * p[8]
	_rv = x * p[9] + y * p[10] + z * p[11]
	_rn = x * p[3] + y * p[4] + z * p[5]
	_du = dx * p[6] + dy * p[7] + dz * p[8]
	_dv = dx * p[9] + dy * p[10] + dz * p[11]
	_dn = dx * p[3] + dy * p[4] + dz * p[5]
	var side := 1.0 if one_sided or _rn >= 0.0 else -1.0
	var distance := side * _rn - ball.radius
	if side * _dn < 0.0 and distance >= -EPS:
		var f := maxf(distance, 0.0) / (-side * _dn)
		if f <= 1.0 and absf(_ru + _du * f) <= p[12] and absf(_rv + _dv * f) <= p[13]:
			_offer(f, 0.0, 0.0, side, kind)
	# Rectangle Minkowski boundary: four finite cylinders and four corner spheres.
	# Infinite extents have no corresponding boundary; half-infinite strips still work.
	if p[12] < INF:
		_edge(-p[12], 0.0, false, p[13], kind)
		_edge(p[12], 0.0, false, p[13], kind)
	if p[13] < INF:
		_edge(0.0, -p[13], true, p[12], kind)
		_edge(0.0, p[13], true, p[12], CONTACT_CORD if kind == CONTACT_NET else kind)
	if p[12] < INF and p[13] < INF:
		_corner(-p[12], -p[13], kind)
		_corner(p[12], -p[13], kind)
		var top_kind := CONTACT_CORD if kind == CONTACT_NET else kind
		_corner(-p[12], p[13], top_kind)
		_corner(p[12], p[13], top_kind)


static func _entry(a: float, b: float, c: float) -> float:
	## First root of squared distance = r²; negative b means approaching.
	if a <= 0.0 or b >= 0.0:
		return 2.0
	if c <= 0.0:
		return 0.0
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return 2.0
	# This root form avoids cancellation when starting very close to an edge.
	return 2.0 * c / (-b + sqrt(disc))


func _edge(u: float, v: float, along_u: bool, extent: float, kind: int) -> void:
	var radial := _rv - v if along_u else _ru - u
	var delta := _dv if along_u else _du
	var along := _ru - u if along_u else _rv - v
	var travel := _du if along_u else _dv
	var f := _entry(delta * delta + _dn * _dn, 2.0 * (radial * delta + _rn * _dn),
			radial * radial + _rn * _rn - ball.radius * ball.radius)
	if f > 1.0 or absf(along + travel * f) > extent:
		return
	var outside := (_rv + _dv * f - v) * v if along_u else (_ru + _du * f - u) * u
	if outside < 0.0:
		return
	var r := ball.radius
	var tangent := (radial + delta * f) / r
	_offer(f, 0.0 if along_u else tangent, tangent if along_u else 0.0, (_rn + _dn * f) / r, kind)


func _corner(u: float, v: float, kind: int) -> void:
	var x := _ru - u
	var y := _rv - v
	var f := _entry(_du * _du + _dv * _dv + _dn * _dn,
			2.0 * (x * _du + y * _dv + _rn * _dn), x * x + y * y + _rn * _rn - ball.radius * ball.radius)
	if f <= 1.0 and (x + _du * f) * u >= 0.0 and (y + _dv * f) * v >= 0.0:
		_offer(f, (x + _du * f) / ball.radius, (y + _dv * f) / ball.radius, (_rn + _dn * f) / ball.radius, kind)


func _offer(f: float, u: float, v: float, n: float, kind: int) -> void:
	if f < 0.0 or (_one_sided and n < -EPS) or u * _du + v * _dv + n * _dn >= 0.0:
		return
	if f > _hit_fraction:
		return
	if f == _hit_fraction:
		# Stable simultaneous contacts by ID; the top cord owns the mesh's top boundary.
		if _rect_key > _hit_key or (_rect_key == _hit_key and kind <= _hit_kind):
			return
	_hit_fraction = f
	_hit_kind = kind
	_hit_index = _rect_index
	_hit_key = _rect_key
	var length := sqrt(u * u + v * v + n * n)
	u /= length
	v /= length
	n /= length
	_hnx = _rect[6] * u + _rect[9] * v + _rect[3] * n
	_hny = _rect[7] * u + _rect[10] * v + _rect[4] * n
	_hnz = _rect[8] * u + _rect[11] * v + _rect[5] * n


func _resolve() -> void:
	_contacts_left -= 1
	var surface: Surface
	var id: StringName
	if _hit_kind == CONTACT_SURFACE:
		surface = _planes[_hit_index].surface
		id = _planes[_hit_index].id
	else:
		var net := _nets[_hit_index]
		surface = net.cord if _hit_kind == CONTACT_CORD else net.surface
		id = net.id
	if _record != null:
		var at := (tick - 1 - _record_tick) * STEP + _elapsed
		if _hit_kind == CONTACT_SURFACE and _record.bounces.size() < _record_limit:
			_record.bounces.append(position())
			_record.bounce_times.append(at)
			_record.bounce_ids.append(id)
			_record.bounce_velocities.append(velocity())
		elif _hit_kind != CONTACT_SURFACE:
			_record.net_hit = true
			if _record.net_time < 0.0:
				# A blocked ball never crosses the plane: report first-touch clearance/time instead.
				_record.net_clearance = _py - ball.radius - _nets[_hit_index].c[5]
				_record.net_time = at
	var speed := _impact(_hnx, _hny, _hnz, surface)
	resting = false
	_rest_plane = -1
	if _hit_kind == CONTACT_SURFACE and _hny > 0.5:
		var p := _planes[_hit_index].p
		var out := _vx * p[3] + _vy * p[4] + _vz * p[5]
		# Edge normals must not become a supporting infinite plane.
		var alignment := _hnx * p[3] + _hny * p[4] + _hnz * p[5]
		if alignment > 1.0 - EPS and out < REST_SPEED:
			_vx -= out * p[3]
			_vy -= out * p[4]
			_vz -= out * p[5]
			resting = true
			_rest_plane = _hit_index
	if emit_events:
		contacted.emit(_hit_kind, id, position(), speed)
	_px += _hnx * EPS
	_py += _hny * EPS
	_pz += _hnz * EPS


func _impact(nx: float, ny: float, nz: float, surface: Surface, ux := 0.0, uy := 0.0, uz := 0.0) -> float:
	var rx := _vx - ux
	var ry := _vy - uy
	var rz := _vz - uz
	var vn := rx * nx + ry * ny + rz * nz
	if vn >= 0.0:
		return 0.0
	var e := clampf(surface.restitution + surface.restitution_drop * vn, surface.restitution_min, 1.0)
	var mass_ratio := ball.mass / surface.mass
	var jn := -(1.0 + e) * vn / (1.0 + mass_ratio)
	var r := ball.radius
	var sx := rx - vn * nx - r * (_wy * nz - _wz * ny)
	var sy := ry - vn * ny - r * (_wz * nx - _wx * nz)
	var sz := rz - vn * nz - r * (_wx * ny - _wy * nx)
	var slip := sqrt(sx * sx + sy * sy + sz * sz)
	var jt := 0.0
	if slip > EPS:
		jt = minf(surface.friction * jn, (1.0 + surface.spin_grip) * slip * ball.inertia / (1.0 + ball.inertia * (1.0 + mass_ratio)))
		sx /= slip
		sy /= slip
		sz /= slip
	_vx += jn * nx - jt * sx
	_vy += jn * ny - jt * sy
	_vz += jn * nz - jt * sz
	var gain := jt / (ball.inertia * r)
	_wx += gain * (ny * sz - nz * sy)
	_wy += gain * (nz * sx - nx * sz)
	_wz += gain * (nx * sy - ny * sx)
	var moving := sqrt(ux * ux + uy * uy + uz * uz)
	var outgoing := sqrt(_vx * _vx + _vy * _vy + _vz * _vz)
	if surface.dwell > 0.0 and moving > EPS and outgoing > EPS:
		var bx := _vx / outgoing * (1.0 - surface.dwell) + ux / moving * surface.dwell
		var by := _vy / outgoing * (1.0 - surface.dwell) + uy / moving * surface.dwell
		var bz := _vz / outgoing * (1.0 - surface.dwell) + uz / moving * surface.dwell
		var length := sqrt(bx * bx + by * by + bz * bz)
		if length > EPS and bx * nx + by * ny + bz * nz > 0.0:
			_vx = bx * outgoing / length
			_vy = by * outgoing / length
			_vz = bz * outgoing / length
	return -vn


func _roll(dt: float) -> void:
	if dt <= 0.0 or _contacts_left <= 0:
		return
	var p := _planes[_rest_plane].p
	# Gravity projected into the support plane, including rotational inertia.
	var g := GRAVITY / (1.0 + ball.inertia)
	_vx += g * p[4] * p[3] * dt
	_vy += g * (p[4] * p[4] - 1.0) * dt
	_vz += g * p[4] * p[5] * dt
	var speed := sqrt(_vx * _vx + _vy * _vy + _vz * _vz)
	var slow := _planes[_rest_plane].surface.rolling * GRAVITY * p[4] * dt
	var scale := 0.0 if speed <= maxf(slow, STOP_SPEED) else (speed - slow) / speed
	_vx *= scale
	_vy *= scale
	_vz *= scale
	var dx := _vx * dt
	var dy := _vy * dt
	var dz := _vz * dt
	var f := _sweep(dx, dy, dz, _rest_plane)
	if f <= 1.0:
		_record_net(dx * f, dy * f, dz * f, dt * f)
		_elapsed += dt * f
		_px += dx * f
		_py += dy * f
		_pz += dz * f
		_resolve()
		_fly(dt * (1.0 - f))
		return
	_record_net(dx, dy, dz, dt)
	_elapsed += dt
	_px += dx
	_py += dy
	_pz += dz
	_wx = (p[4] * _vz - p[5] * _vy) / ball.radius
	_wy = (p[5] * _vx - p[3] * _vz) / ball.radius
	_wz = (p[3] * _vy - p[4] * _vx) / ball.radius
	var x := _px - p[0]
	var y := _py - p[1]
	var z := _pz - p[2]
	if absf(x * p[6] + y * p[7] + z * p[8]) > p[12] or absf(x * p[9] + y * p[10] + z * p[11]) > p[13]:
		resting = false
		_rest_plane = -1


func hit(contact_point: Vector3, face_normal: Vector3, hitter_velocity: Vector3, hitter: Surface) -> bool:
	var length := sqrt(face_normal.x * face_normal.x + face_normal.y * face_normal.y + face_normal.z * face_normal.z)
	if length <= EPS:
		return false
	var nx := face_normal.x / length
	var ny := face_normal.y / length
	var nz := face_normal.z / length
	if _impact(nx, ny, nz, hitter, hitter_velocity.x, hitter_velocity.y, hitter_velocity.z) <= 0.0:
		return false
	_px = contact_point.x + nx * ball.radius
	_py = contact_point.y + ny * ball.radius
	_pz = contact_point.z + nz * ball.radius
	_qx = _px
	_qy = _py
	_qz = _pz
	resting = false
	_rest_plane = -1
	return true


func _record_net(dx: float, dy: float, dz: float, duration: float) -> void:
	if _record == null or _ignore_nets or _record.net_crossed:
		return
	var best := 2.0
	var clearance := INF
	for net: _Net in _nets:
		var c := net.c
		var d0 := (_px - c[0]) * c[2] + (_pz - c[1]) * c[3]
		var d1 := d0 + dx * c[2] + dz * c[3]
		if d0 == d1 or d0 * d1 > 0.0:
			continue
		var f := d0 / (d0 - d1)
		var along := (_px + dx * f - c[0]) * -c[3] + (_pz + dz * f - c[1]) * c[2]
		if f < best and absf(along) <= c[4]:
			best = f
			clearance = _py + dy * f - ball.radius - c[5]
	if best <= 1.0:
		_record.net_crossed = true
		if _record.net_time < 0.0:
			_record.net_clearance = clearance
			_record.net_time = (tick - 1 - _record_tick) * STEP + _elapsed + duration * best


func predict(max_time := 3.0, max_bounces := 1) -> Prediction:
	var result := Prediction.new()
	var f := copy()
	f._record = result
	f._record_tick = f.tick
	f._record_limit = max_bounces
	if max_bounces > 0:
		for _i in maxi(0, ceili(max_time * HZ)):
			if f.resting:
				break
			f.step()
			if result.bounces.size() >= max_bounces:
				break
	result.settled = f.resting
	result.end_position = f.position()
	result.end_velocity = f.velocity()
	result.end_time = (f.tick - f._record_tick) * STEP
	return result


func time_to_height(height: float, max_time := 3.0, descending := true) -> float:
	var f := copy()
	for i in maxi(0, ceili(max_time * HZ)):
		var before := f._py
		f.step()
		var crossed := before >= height and f._py <= height if descending else before <= height and f._py >= height
		if crossed and before != f._py:
			var at := (i + (before - height) / (before - f._py)) * STEP
			return at if at <= max_time else -1.0
		if f.resting:
			break
	return -1.0


func time_to_plane(point: Vector3, normal: Vector3, max_time := 3.0) -> float:
	if normal.length_squared() <= EPS * EPS:
		return -1.0
	var f := copy()
	var d0 := (f._px - point.x) * normal.x + (f._py - point.y) * normal.y + (f._pz - point.z) * normal.z
	if d0 == 0.0 and max_time >= 0.0:
		return 0.0
	for i in maxi(0, ceili(max_time * HZ)):
		f.step()
		var d1 := (f._px - point.x) * normal.x + (f._py - point.y) * normal.y + (f._pz - point.z) * normal.z
		if d0 * d1 <= 0.0 and d0 != d1:
			var at := (i + d0 / (d0 - d1)) * STEP
			return at if at <= max_time else -1.0
		if f.resting:
			break
		d0 = d1
	return -1.0


func probe(seconds: float) -> RSBallFlight:
	var f := copy()
	f.advance_to_tick(f.tick + maxi(0, floori(seconds * HZ + CLOCK_EPS)))
	return f


func aim(from: Vector3, target: Vector3, speed: float, spin := Vector3.ZERO, lob := false, iterations := 8) -> Vector3:
	## Solve heading/pitch with finite differences of the real first-contact simulation.
	## Targets are surface points; their ball centres are one radius above them. Nets are ignored.
	## Trigonometry is not bit-exact across machines: transmit the resulting snapshot, not aim inputs.
	var flat := Vector2(target.x - from.x, target.z - from.z)
	var distance := flat.length()
	if distance < 0.01 or speed <= 0.0 or iterations <= 0:
		return Vector3.ZERO
	var heading := atan2(flat.x, flat.y)
	var vertical := target.y + ball.radius - from.y
	var v2 := speed * speed
	var disc := v2 * v2 - GRAVITY * (GRAVITY * distance * distance + 2.0 * vertical * v2)
	if disc < 0.0 and spin.length_squared() == 0.0:
		return Vector3.ZERO
	var pitch := atan((v2 + (1.0 if lob else -1.0) * sqrt(maxf(disc, 0.0))) / (GRAVITY * distance))
	var horizon := 2.0 * speed / GRAVITY + 2.0 * sqrt(2.0 * absf(vertical) / GRAVITY) + 3.0
	var goal := target + Vector3.UP * ball.radius
	var best := Vector3.ZERO
	var error := INF
	const DIFFERENCE := 0.002        ## rad; large enough to exceed Vector3 output rounding
	for _i in iterations:
		var landed := _aim_point(from, heading, pitch, speed, spin, horizon)
		if not landed.is_finite():
			return best if error < 0.04 else Vector3.ZERO
		var miss := landed.distance_to(goal)
		if miss < error:
			error = miss
			best = _launch(heading, pitch, speed)
		if error < 0.005:
			break
		var h := _aim_point(from, heading + DIFFERENCE, pitch, speed, spin, horizon)
		var p := _aim_point(from, heading, pitch + DIFFERENCE, speed, spin, horizon)
		if not h.is_finite() or not p.is_finite():
			break
		var hx := (h.x - landed.x) / DIFFERENCE
		var hz := (h.z - landed.z) / DIFFERENCE
		var px := (p.x - landed.x) / DIFFERENCE
		var pz := (p.z - landed.z) / DIFFERENCE
		var det := hx * pz - hz * px
		if absf(det) < EPS:
			break
		var ex := landed.x - goal.x
		var ez := landed.z - goal.z
		heading -= clampf((ex * pz - ez * px) / det, -0.35, 0.35)
		pitch = clampf(pitch - clampf((hx * ez - hz * ex) / det, -0.25, 0.25), -1.4, 1.55)
	return best if error < 0.04 else Vector3.ZERO


static func _launch(heading: float, pitch: float, speed: float) -> Vector3:
	return Vector3(sin(heading) * cos(pitch), sin(pitch), cos(heading) * cos(pitch)) * speed


func _aim_point(from: Vector3, heading: float, pitch: float, speed: float, spin: Vector3, horizon: float) -> Vector3:
	var f := copy()
	f._ignore_nets = true
	f.set_state(from, _launch(heading, pitch, speed), spin)
	var result := f.predict(horizon, 1)
	return result.land_point() if result.landed() else Vector3(INF, INF, INF)
