class_name RSGolfState
extends RefCounted
## Scene/input adapter around pure rules and a separate 120 Hz physical ball; no G4 gestures.

class Visual extends RefCounted:
	## Read-only presentation: inflated mesh radius never enters the physical ball or rules.
	const MIN_DIAMETER := 8.0  ## output pixels of this player's actual 3D viewport
	const SAMPLES := 16
	const SAMPLE_SECONDS := 0.025
	const TRAIL_SECONDS := 0.4
	const TRAIL_LENGTH := 5.0  ## m of actual rendered history, not a predicted trajectory
	const TRAIL_ALPHA := 0.22
	const RING_RADIUS := 0.18  ## m; at least this large on supported land
	const RING_CLEARANCE := 0.006  ## m above the rendered terrain

	var ball: MeshInstance3D
	var trail: MultiMeshInstance3D
	var ring: MeshInstance3D
	var display_radius := RSGolfBall.RADIUS
	var _instances := MultiMesh.new()
	var _positions := PackedVector3Array()
	var _times := PackedFloat64Array()
	var _head := -1
	var _count := 0
	var _clock := 0.0
	var _last_sample := -INF
	var _flight := false
	var _color := Color.WHITE

	func _init(parent: Node3D, color: Color, layer: int) -> void:
		_color = color
		_positions.resize(SAMPLES)
		_times.resize(SAMPLES)
		ball = MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = RSGolfBall.RADIUS
		sphere.height = RSGolfBall.RADIUS * 2.0
		sphere.radial_segments = 16
		sphere.rings = 8
		ball.mesh = sphere
		ball.material_override = _material(Color.WHITE.lerp(color, 0.2))
		ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ball.layers = layer
		parent.add_child(ball)
		var segment := CylinderMesh.new()
		segment.top_radius = 1.0
		segment.bottom_radius = 1.0
		segment.height = 1.0
		segment.radial_segments = 6
		segment.rings = 1
		_instances.transform_format = MultiMesh.TRANSFORM_3D
		_instances.use_colors = true
		_instances.mesh = segment
		_instances.instance_count = SAMPLES - 1
		_instances.visible_instance_count = 0
		trail = MultiMeshInstance3D.new()
		trail.multimesh = _instances
		var tint := _material(Color.WHITE)
		tint.vertex_color_use_as_albedo = true
		tint.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		trail.material_override = tint
		trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		trail.layers = layer
		parent.add_child(trail)
		ring = MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.92
		torus.outer_radius = 1.0
		torus.rings = 32
		torus.ring_segments = 6
		ring.mesh = torus
		var ring_color := Color(color, 0.55)
		var ring_material := _material(ring_color)
		ring_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		ring.material_override = ring_material
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ring.layers = layer
		parent.add_child(ring)
		reset()

	static func _material(color: Color) -> StandardMaterial3D:
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		return material

	static func radius_for_camera(camera: Camera3D, at: Vector3) -> float:
		if not camera.is_inside_tree() or camera.is_position_behind(at):
			return RSGolfBall.RADIUS
		var size := camera.get_viewport().get_visible_rect().size
		var local := camera.get_camera_transform().affine_inverse() * at
		if size.x <= 0.0 or size.y <= 0.0 or -local.z <= camera.near or -local.z >= camera.far:
			return RSGolfBall.RADIUS
		var projection := camera.get_camera_projection()
		var clip := projection * Vector4(local.x, local.y, local.z, 1.0)
		var focal := minf(absf(projection.x.x) * size.x, absf(projection.y.y) * size.y) * 0.5
		if focal <= 0.0 or clip.w <= 0.0:
			return RSGolfBall.RADIUS
		return maxf(RSGolfBall.RADIUS, MIN_DIAMETER * 0.5 * clip.w / focal)

	func reset() -> void:
		_head = -1
		_count = 0
		_clock = 0.0
		_last_sample = -INF
		_flight = false
		_instances.visible_instance_count = 0
		trail.visible = false
		ring.visible = false

	func update(at: Vector3, mode: RSGolfBall.Mode, finished: bool, camera: Camera3D, surface: RSGolfSurface, delta: float) -> void:
		_clock += delta
		display_radius = radius_for_camera(camera, at)
		ball.position = at
		ball.scale = Vector3.ONE * (display_radius / RSGolfBall.RADIUS)
		var flying := mode == RSGolfBall.Mode.FLIGHT and not finished
		if flying and not _flight:
			_count = 0
			_head = -1
			_last_sample = -INF
		_flight = flying
		if flying:
			if _count == 0 or _clock - _last_sample >= SAMPLE_SECONDS:
				_head = (_head + 1) % SAMPLES
				_count = mini(_count + 1, SAMPLES)
				_last_sample = _clock
			_positions[_head] = at
			_times[_head] = _clock
			_update_trail(at)
		else:
			_instances.visible_instance_count = 0
			trail.visible = false
		var grounded := mode == RSGolfBall.Mode.REST or mode == RSGolfBall.Mode.ROLL
		ring.visible = grounded and not finished and surface.contains_xz(at.x, at.z)
		if ring.visible:
			var normal := surface.geometric_normal_at(at.x, at.z)
			var centre := Vector3(at.x, surface.height_at(at.x, at.z), at.z) + normal * RING_CLEARANCE
			var radius := maxf(RING_RADIUS, display_radius * 2.2)
			ring.transform = Transform3D(Basis(Quaternion(Vector3.UP, normal)).scaled(Vector3.ONE * radius), centre)

	func _update_trail(at: Vector3) -> void:
		var visible := 0
		var distance := 0.0
		var recent := at
		var width := maxf(0.004, display_radius * 0.18)
		for i in maxi(0, _count - 1):
			var index := (_head - i - 1 + SAMPLES) % SAMPLES
			var age := _clock - _times[index]
			if age > TRAIL_SECONDS or distance >= TRAIL_LENGTH:
				break
			var older := _positions[index]
			var length := recent.distance_to(older)
			if length <= 1.0e-6:
				continue
			if length > TRAIL_LENGTH - distance:
				older = recent.lerp(older, (TRAIL_LENGTH - distance) / length)
				length = TRAIL_LENGTH - distance
			var y := (older - recent) / length
			var x := y.cross(Vector3.UP)
			if x.length_squared() < 1.0e-6:
				x = y.cross(Vector3.RIGHT)
			x = x.normalized()
			var z := x.cross(y)
			_instances.set_instance_transform(visible, Transform3D(Basis(x * width, y * length, z * width), (recent + older) * 0.5))
			_instances.set_instance_color(visible, Color(_color, TRAIL_ALPHA * (1.0 - age / TRAIL_SECONDS)))
			visible += 1
			distance += length
			recent = older
		_instances.visible_instance_count = visible
		var pad := TRAIL_LENGTH + width
		_instances.custom_aabb = AABB(at - Vector3.ONE * pad, Vector3.ONE * (pad * 2.0))
		trail.visible = visible > 0

	func release() -> void:
		ball.queue_free()
		trail.queue_free()
		ring.queue_free()

const REACHES := RSGolfShot.REACHES

var rules := RSGolfRules.new()
var events: Array[RSGolfRules.Event] = []  ## reused at 120 Hz; entries exist only on contact
var ball: MeshInstance3D
var visual: Visual
var camera_focus := Vector3.ZERO
var camera_ready := false
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
