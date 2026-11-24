class_name RSBasketball
extends RigidBody3D
## A basketball for the Jolt solver: 0.6 kg, 0.12 m radius, continuous collision, no bounce of
## its own (each surface carries its bounce: floor 0.8, rim 0.55, board 0.6...). While held it
## is frozen (kinematic) and moved with the hands; launch() throws it with backspin.
## touched(kind, speed) fires on each new contact with a static surface (its meta "kind"), for
## the sounds and the swish / rim / board bookkeeping. set_fire() lights a flame trail.

signal touched(kind: String, speed: float)

const R := 0.12
const SHADER := preload("res://shaders/basketball.gdshader")

static var _mesh: SphereMesh
static var _mats: Dictionary = {}
static var _fire_res: Array = []

var money := false
var touched_rim := false
var touched_board := false
var touched_floor := false
var flight_t := 0.0              ## seconds since launch
var live := false                ## thrown and not yet resolved (made / missed)
var made := false

var _prev_v := Vector3.ZERO
var _contacts: Dictionary = {}   ## collider instance id -> true, last step
var _skin: MeshInstance3D
var _fire: GPUParticles3D


static func mesh() -> SphereMesh:
	if _mesh == null:
		_mesh = SphereMesh.new()
		_mesh.radius = R
		_mesh.height = R * 2.0
		_mesh.radial_segments = 48
		_mesh.rings = 24
	return _mesh


static func material(is_money: bool) -> ShaderMaterial:
	if not _mats.has(is_money):
		var m := ShaderMaterial.new()
		m.shader = SHADER
		m.set_shader_parameter("money", is_money)
		_mats[is_money] = m
	return _mats[is_money]


func _init(layer: int = 2, is_money: bool = false) -> void:
	money = is_money
	mass = 0.6
	collision_layer = layer
	collision_mask = 1
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 6
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp = 0.15
	var pm := PhysicsMaterial.new()
	pm.bounce = 0.0
	pm.friction = 0.7
	physics_material_override = pm
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = R
	cs.shape = sph
	add_child(cs)
	_skin = MeshInstance3D.new()
	_skin.mesh = mesh()
	_skin.material_override = material(is_money)
	add_child(_skin)
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true


func set_money(is_money: bool) -> void:
	money = is_money
	_skin.material_override = material(is_money)


func set_layers(mask: int) -> void:
	_skin.layers = mask
	if _fire:
		_fire.layers = mask


func hold(xf: Transform3D) -> void:
	freeze = true
	live = false
	global_transform = xf


func launch(v: Vector3, w: Vector3) -> void:
	freeze = false
	linear_velocity = v
	angular_velocity = w
	_prev_v = v
	_contacts.clear()
	touched_rim = false
	touched_board = false
	touched_floor = false
	made = false
	live = true
	flight_t = 0.0


func set_fire(on: bool) -> void:
	if on and _fire == null:
		_fire = _make_fire()
		_fire.layers = _skin.layers
		add_child(_fire)
	if _fire:
		_fire.emitting = on


func _physics_process(delta: float) -> void:
	if not freeze:
		flight_t += delta


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var now: Dictionary = {}
	for i in state.get_contact_count():
		var obj := state.get_contact_collider_object(i)
		if obj == null:
			continue
		var id := obj.get_instance_id()
		now[id] = true
		if _contacts.has(id):
			continue
		var n := state.get_contact_local_normal(i)
		var speed := absf(_prev_v.dot(n))
		var kind := str(obj.get_meta("kind", "floor"))
		match kind:
			"rim":
				touched_rim = true
			"board":
				touched_board = true
			"floor":
				touched_floor = true
		if speed > 0.35:
			touched.emit(kind, speed)
	_contacts = now
	_prev_v = state.linear_velocity


func _make_fire() -> GPUParticles3D:
	return _fire_node()


static func _fire_node() -> GPUParticles3D:
	var resources := fire_resources()
	var ps := GPUParticles3D.new()
	ps.amount = 120
	ps.lifetime = 0.4
	ps.local_coords = false
	ps.draw_pass_1 = resources[0]
	ps.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ps.visibility_aabb = AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))
	ps.process_material = resources[1]
	ps.emitting = false
	return ps


static func warm_up_fire(parent: Node) -> void:
	## Warm once during scene setup; the parent also owns cleanup if it leaves early.
	if not parent.is_inside_tree():
		fire_resources()
		return
	var ps := _fire_node()
	parent.add_child(ps)
	ps.emitting = true
	await parent.get_tree().process_frame
	if is_instance_valid(ps):
		ps.queue_free()


static func fire_resources() -> Array:
	## These resources are immutable after construction; only per-ball nodes are toggled.
	if not _fire_res.is_empty():
		return _fire_res
	var q := QuadMesh.new()
	q.size = Vector2(0.22, 0.22)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var dot := GradientTexture2D.new()
	dot.gradient = g
	dot.fill = GradientTexture2D.FILL_RADIAL
	dot.fill_from = Vector2(0.5, 0.5)
	dot.fill_to = Vector2(0.5, 0.0)
	dot.width = 64
	dot.height = 64
	m.albedo_texture = dot
	q.material = m
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = R * 0.9
	pm.direction = Vector3.UP
	pm.spread = 30.0
	pm.initial_velocity_min = 0.2
	pm.initial_velocity_max = 0.6
	pm.gravity = Vector3(0, 1.5, 0)
	pm.scale_min = 0.6
	pm.scale_max = 1.2
	var sc := Curve.new()
	sc.add_point(Vector2(0, 1.0))
	sc.add_point(Vector2(1, 0.2))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.25, 0.6, 1.0])
	ramp.colors = PackedColorArray([Color(1.0, 0.95, 0.6, 1.0), Color(1.0, 0.6, 0.12, 0.9), Color(0.9, 0.2, 0.05, 0.5), Color(0.3, 0.05, 0.02, 0.0)])
	var rt := GradientTexture1D.new()
	rt.gradient = ramp
	pm.color_ramp = rt
	_fire_res = [q, pm]
	return _fire_res
