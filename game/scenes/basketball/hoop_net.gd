class_name RSHoopNet
extends MeshInstance3D
## A nylon basketball net: 12 cords knotted into diamonds, 7 rows of knots from the rim hooks
## down 45 cm, as a Verlet cloth. The top row hangs on the hooks; the rest swing under gravity
## with a little memory of their rest shape (knotted cord is stiff), and are pushed out of any
## ball passing through, so a swish snaps the net and a rim-in shakes it. Drawn as thin
## three-sided cords, rebuilt only while the net is moving; it sleeps when still.
##
## Node origin = centre of the ring tube. advance(dt, balls) with the balls' world positions
## (fixed 120 Hz substeps inside, so replays at any speed behave the same).

const STRINGS := 12
const ROWS := 7
const LEN := 0.45
const R_TOP := RSBallCourt.RIM_R + RSBallCourt.RIM_TUBE
const R_BOT := 0.15
const HOOK_Y := -0.035
const STEP := 1.0 / 120.0
const GRAVITY := 9.8
const DAMP := 0.985
const SHAPE := 2.5               ## pull back toward the rest shape, 1/s
const ITERS := 6
const CORD := 0.0045
const QUAD := [0, 2, 1, 0, 3, 2]

var _pos := PackedVector3Array()
var _prev := PackedVector3Array()
var _rest := PackedVector3Array()
var _links: Array[Vector3i] = []   ## a, b, rest length (mm, as int)
var _acc := 0.0
var _awake := true
var _still_t := 0.0
var _dirty := true
var _im := ImmediateMesh.new()
var _local: Array[Vector3] = []


func _ready() -> void:
	mesh = _im
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.94, 0.94, 0.92)
	m.roughness = 0.85
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = m
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	custom_aabb = AABB(Vector3(-0.4, -0.7, -0.4), Vector3(0.8, 0.8, 0.8))
	for r in ROWS:
		var u := float(r) / (ROWS - 1)
		var rad := lerpf(R_TOP, R_BOT, pow(u, 0.85))
		var y := HOOK_Y - u * LEN
		for s in STRINGS:
			var a := (s + 0.5 + 0.5 * (r % 2)) * TAU / STRINGS
			_rest.append(Vector3(cos(a) * rad, y, sin(a) * rad))
	_pos = _rest.duplicate()
	_prev = _rest.duplicate()
	for r in ROWS - 1:
		for s in STRINGS:
			var a := r * STRINGS + s
			var b0 := (r + 1) * STRINGS + s
			var b1 := (r + 1) * STRINGS + posmod(s + (1 if r % 2 == 1 else -1), STRINGS)
			for b in [b0, b1]:
				_links.append(Vector3i(a, b, roundi(_rest[a].distance_to(_rest[b]) * 1000.0)))
	_rebuild()


func advance(dt: float, balls: Array) -> void:
	## Read balls synchronously; do not retain the caller's reusable array.
	_local.clear()
	for b: Vector3 in balls:
		var p := to_local(b)
		if Vector2(p.x, p.z).length() < 0.7 and p.y > -1.0 and p.y < 0.5:
			_local.append(p)
	if not _local.is_empty():
		_awake = true
		_still_t = 0.0
	if not _awake:
		return
	_acc = minf(_acc + dt, STEP * 8.0)
	while _acc >= STEP:
		_acc -= STEP
		_step(_local)
	_dirty = true


func _step(balls: Array[Vector3]) -> void:
	var moved := 0.0
	var g := Vector3(0, -GRAVITY * STEP * STEP, 0)
	var k := SHAPE * STEP
	for i in range(STRINGS, _pos.size()):
		var p := _pos[i]
		var v := (p - _prev[i]) * DAMP
		_prev[i] = p
		p += v + g
		p += (_rest[i] - p) * k
		_pos[i] = p
	var rb := RSBasketball.R + CORD * 1.5
	for it in ITERS:
		for l in _links:
			var a := l.x
			var b := l.y
			var d := _pos[b] - _pos[a]
			var len := d.length()
			if len < 1e-6:
				continue
			var rest := l.z * 0.001
			if len <= rest:
				continue          # cords go slack, they don't push
			var corr := d * ((len - rest) / len)
			if a < STRINGS:
				_pos[b] -= corr
			else:
				_pos[a] += corr * 0.5
				_pos[b] -= corr * 0.5
		for c in balls:
			for i in range(STRINGS, _pos.size()):
				var d := _pos[i] - c
				var dl := d.length()
				if dl < rb and dl > 1e-6:
					_pos[i] = c + d * (rb / dl)
	for i in range(STRINGS, _pos.size()):
		moved = maxf(moved, _pos[i].distance_squared_to(_prev[i]))
	if moved < 1e-9 and balls.is_empty():
		_still_t += STEP
		if _still_t > 1.0:
			_awake = false
	else:
		_still_t = 0.0


func drag(ball_world: Vector3) -> float:
	## How deep a ball is in the net (0 outside .. 1 well inside), for slowing it down.
	var p := to_local(ball_world)
	var r := Vector2(p.x, p.z).length()
	if p.y > -0.05 or p.y < HOOK_Y - LEN - 0.05 or r > R_TOP:
		return 0.0
	return clampf((-0.05 - p.y) / 0.12, 0.0, 1.0) * clampf((R_TOP - r) / 0.05, 0.0, 1.0)


func _process(_delta: float) -> void:
	if _dirty:
		_dirty = false
		_rebuild()


func _rebuild() -> void:
	_im.clear_surfaces()
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for l in _links:
		_cord(_pos[l.x], _pos[l.y])
	# The loops over the hooks.
	for s in STRINGS:
		var a := TAU * (s + 0.5) / STRINGS
		_cord(Vector3(cos(a) * R_TOP, 0.0, sin(a) * R_TOP), _pos[s])
	_im.surface_end()


func _cord(a: Vector3, b: Vector3) -> void:
	var y := b - a
	if y.length() < 1e-5:
		return
	y = y.normalized()
	var x := y.cross(Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	for i in 3:
		var a0 := TAU * i / 3.0
		var a1 := TAU * (i + 1) / 3.0
		var n0 := x * cos(a0) + z * sin(a0)
		var n1 := x * cos(a1) + z * sin(a1)
		var nm := (n0 + n1).normalized()
		var q0 := a + n0 * CORD
		var q1 := a + n1 * CORD
		var q2 := b + n1 * CORD
		var q3 := b + n0 * CORD
		for k: int in QUAD:
			var vertex := q0
			match k:
				1: vertex = q1
				2: vertex = q2
				3: vertex = q3
			_im.surface_set_normal(nm)
			_im.surface_add_vertex(vertex)
