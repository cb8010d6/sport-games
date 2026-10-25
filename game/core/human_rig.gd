class_name RSHumanRig
extends Node3D
## Base for the procedurally posed MakeHuman characters (CC0, built by tools/blender/make_*.py):
## loads a rigged .glb under `body`, measures the skeleton, and poses bones with FK and two-bone
## IK in body space. A subclass fills _pose for every bone in DRIVEN each frame (spine and head
## with _fk, legs and arms with _limb) and then calls _apply_pose().
##
## Body space: the character faces -Z. The skeleton faces +Z, so it hangs under `body` turned
## half round (_to_body).

const DRIVEN := ["pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "head",
	"thigh_l", "calf_l", "foot_l", "thigh_r", "calf_r", "foot_r",
	"clavicle_l", "upperarm_l", "lowerarm_l", "hand_l", "clavicle_r", "upperarm_r", "lowerarm_r", "hand_r"]

var body := Node3D.new()

var _skel: Skeleton3D
var _to_body := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)   ## skeleton space -> body space
var _bone := {}                ## name -> index
var _rest := {}                ## index -> rest pose, global, in body space
var _pose := {}                ## index -> this frame's pose, global, in body space
var _thigh_len := 0.43
var _shin_len := 0.43
var _upper_len := 0.25
var _fore_len := 0.26
var _ankle_h := 0.088          ## ankle joint above the shoe sole
var _ankle_back := 0.068       ## ankle joint behind the middle of the shoe
var _hip_mid := Vector3.ZERO   ## rest midpoint of the hip joints, body space


func set_layers(mask: int) -> void:
	## Render layers of everything in the rig (replays show a rider in their own view only).
	for v: VisualInstance3D in find_children("*", "VisualInstance3D", true, false):
		v.layers = mask


# ------------------------------------------------------------------------- loading ----

func _load_character(path: String) -> Node3D:
	var rider: Node3D = (load(path) as PackedScene).instantiate()
	rider.transform = _to_body
	body.add_child(rider)
	_skel = rider.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	# Skeleton space -> body space, through whatever nodes the import put in between.
	var xf := Transform3D()
	var n: Node = _skel
	while n != body:
		xf = (n as Node3D).transform * xf
		n = n.get_parent()
	_to_body = xf
	for b in _skel.get_bone_count():
		_bone[_skel.get_bone_name(b)] = b
		_rest[b] = _to_body * _skel.get_bone_global_rest(b)
		_pose[b] = _rest[b]
	_thigh_len = rest_point("thigh_l").distance_to(rest_point("calf_l"))
	_shin_len = rest_point("calf_l").distance_to(rest_point("foot_l"))
	_upper_len = rest_point("upperarm_l").distance_to(rest_point("lowerarm_l"))
	_fore_len = rest_point("lowerarm_l").distance_to(rest_point("hand_l"))
	_hip_mid = (rest_point("thigh_l") + rest_point("thigh_r")) * 0.5

	for mi: MeshInstance3D in rider.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		var nm := String(mi.name).to_lower()
		if nm.contains("shoes"):
			# Feet: how high the ankle sits above the sole, and how far behind the shoe's middle.
			var box := _to_body * mi.get_aabb()
			var foot := rest_point("foot_l")
			_ankle_h = foot.y - box.position.y
			_ankle_back = absf(foot.z - box.get_center().z)
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s) as StandardMaterial3D
			if m != null:
				_tune_material(m, nm)

	# Relaxed hands: fingers curled a little, thumbs less.
	for bone_name: String in _bone:
		for f in ["index", "middle", "ring", "pinky", "thumb"]:
			if bone_name.begins_with(f):
				var b: int = _bone[bone_name]
				var curl := 0.18 if f == "thumb" else (0.35 if bone_name.contains("_01") else 0.5)
				_skel.set_bone_pose_rotation(b, _skel.get_bone_rest(b).basis.get_rotation_quaternion() * Quaternion(Vector3.RIGHT, curl))
	return rider


func rest_point(bone_name: String) -> Vector3:
	## A bone's head in the rest pose, body space.
	return (_rest[_bone[bone_name]] as Transform3D).origin


func _tune_material(m: StandardMaterial3D, part: String) -> void:
	## The glTF import makes every material alpha-blended; only hair, brows and lashes are.
	RSSettings.load_once()
	if part.contains("eyebrow") or part.contains("eyelash") or _is_hair(part):
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		m.alpha_scissor_threshold = 0.35
		if RSSettings.upscale == 0 and RSSettings.quality >= 1:
			# Alpha-to-coverage only does anything while MSAA is in effect, and
			# apply_viewport turns MSAA off at the lowest tier and under FSR.
			m.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE_AND_TO_ONE
		m.alpha_antialiasing_edge = 0.3
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.roughness = 0.55
		if not _is_hair(part):
			# Brows and lashes: thin cards that catch the sky; keep them dark and matte.
			m.albedo_color = Color(0.45, 0.4, 0.38)
			m.roughness = 0.9
			m.metallic_specular = 0.2
	else:
		m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	if part.contains("body"):
		m.roughness = 0.52
		# Subsurface scattering costs per pixel on every character; keep it for the
		# top two quality tiers. Materials are tuned once at build time, so a menu
		# quality change only reaches rigs built afterwards.
		m.subsurf_scatter_enabled = RSSettings.quality >= 2
		m.subsurf_scatter_strength = 0.35
		m.subsurf_scatter_skin_mode = true
	elif part.contains("low-poly"):
		m.roughness = 0.15
	elif part.contains("shoes"):
		m.roughness = 0.6
	elif not _is_hair(part) and not part.contains("eye"):
		m.roughness = 0.85                       # cloth


static func _is_hair(part: String) -> bool:
	for h in ["short0", "ponytail", "bob0", "afro", "long0", "braid"]:
		if part.contains(h):
			return true
	return false


# ---------------------------------------------------------------------- posing ----

func _joint(bone_name: String) -> Vector3:
	## Where a bone's head sits this frame, from its (already posed) parent.
	var b: int = _bone[bone_name]
	return (_pose[_skel.get_bone_parent(b)] as Transform3D) * _skel.get_bone_rest(b).origin


func _delta(bone_name: String) -> Basis:
	## This frame's rotation of a bone relative to its rest, body space.
	var b: int = _bone[bone_name]
	return (_pose[b] as Transform3D).basis * (_rest[b] as Transform3D).basis.inverse()


func _fk(bone_name: String, rot: Basis) -> void:
	## Pose a bone at its parent's joint, turned by `rot` (body space) from its rest.
	var b: int = _bone[bone_name]
	_pose[b] = Transform3D(rot * (_rest[b] as Transform3D).basis, _joint(bone_name))


func _limb(upper: String, lower: String, target: Vector3, l1: float, l2: float, pole: Vector3, hinge_rest: Vector3) -> void:
	## Two-bone IK from the upper bone's joint to `target`, the middle joint bending toward
	## `pole`. Each bone is swung from its rest so the joint's hinge axis stays the hinge axis
	## (hinge_rest = ZERO: take it from the rest pose's own bend).
	var a: int = _bone[upper]
	var b: int = _bone[lower]
	var root := _joint(upper)
	var ik := _ik(root, target, l1, l2, pole)
	var mid: Vector3 = ik[0]
	var end: Vector3 = ik[1]
	var y0a := (_rest[a] as Transform3D).basis.y.normalized()
	var y0b := (_rest[b] as Transform3D).basis.y.normalized()
	var h0 := hinge_rest if hinge_rest != Vector3.ZERO else y0a.cross(y0b)
	var h1 := (mid - root).cross(end - mid)
	if h1.length() < 1e-4:
		h1 = pole.cross(end - root)
	var r1 := _frame(mid - root, h1) * _frame(y0a, h0).transposed()
	_pose[a] = Transform3D(r1 * (_rest[a] as Transform3D).basis, root)
	var r2 := _frame(end - mid, h1) * _frame(y0b, h0).transposed()
	_pose[b] = Transform3D(r2 * (_rest[b] as Transform3D).basis, _joint(lower))


static func _frame(y: Vector3, side: Vector3) -> Basis:
	## Orthonormal frame with Y along `y` and X as close to `side` as it can be.
	y = y.normalized()
	var x := side - y * side.dot(y)
	x = x.normalized() if x.length() > 1e-5 else y.cross(Vector3.FORWARD).normalized()
	return Basis(x, y, x.cross(y))


func _apply_pose() -> void:
	for bone_name: String in DRIVEN:
		var b: int = _bone[bone_name]
		var parent := _skel.get_bone_parent(b)
		if parent < 0:
			continue
		var local: Transform3D = (_pose[parent] as Transform3D).affine_inverse() * (_pose[b] as Transform3D)
		_skel.set_bone_pose_position(b, local.origin)
		_skel.set_bone_pose_rotation(b, local.basis.get_rotation_quaternion())


static func _ik(root: Vector3, target: Vector3, l1: float, l2: float, pole: Vector3) -> Array:
	## Two-bone IK: returns [joint, end]; the joint bends toward `pole`.
	var d := target - root
	var dist := clampf(d.length(), absf(l1 - l2) + 0.01, l1 + l2 - 0.002)
	var n := d.normalized() if d.length() > 1e-4 else Vector3.DOWN
	var a := (l1 * l1 - l2 * l2 + dist * dist) / (2.0 * dist)
	var h := sqrt(maxf(l1 * l1 - a * a, 0.0))
	var pv := pole - n * pole.dot(n)
	pv = pv.normalized() if pv.length() > 1e-4 else n.cross(Vector3.RIGHT).normalized()
	return [root + n * a + pv * h, root + n * dist]


# ---------------------------------------------------------------------- helpers ----

func _mat(color: Color, roughness: float, metallic: float = 0.0, tex: Texture2D = null) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.albedo_texture = tex
	m.roughness = roughness
	m.metallic = metallic
	return m


func _mi(mesh: Mesh, mat: Material, parent: Node3D, xf: Transform3D = Transform3D()) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = xf
	parent.add_child(mi)
	return mi
