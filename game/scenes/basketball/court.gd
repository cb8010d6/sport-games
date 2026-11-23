class_name RSBallCourt
extends Node3D
## The basketball game's rooftop: four FIBA half courts side by side (one per player) painted
## on a scanned concrete roof (shaders/court.gdshader), glass backboards on steel goosenecks,
## orange rims built from capsule colliders, nylon nets (RSHoopNet), a five-rack three-point
## layout per court, chain-link fencing over the parapet, and the clutter of a city roof:
## stairwell, wooden water tank, AC units, benches, a boombox, string lights and floodlights.
## Sky, sun and lights come from the map (MAPS, picked in the lobby).
##
## Court i: the rim's centre is above (x_i, 0, 0), the shooter looks down -Z at it. The floor
## is y = 0. Every static collider is on layer 1 and carries meta "kind" (floor, rim, board,
## pole, fence, wall) for the ball's contact sounds.

const MAPS := [
	{
		"name": "天台日落", "en": "SUNSET ROOFTOP",
		"desc": "市中心楼顶的球场，晚霞和高楼当背景。顺光练投篮，最适合第一次玩。",
		"hdri": "res://assets/polyhaven/hdris/sunset_jhbcentral/sunset_jhbcentral_4k.hdr",
		"sky_energy": 1.0, "sky_rot": 1.885, "sun_az": 58.0, "sun_el": 7.5, "sun_color": Color(1.0, 0.7, 0.48),
		"sun_energy": 1.7, "shadow_blur": 2.5, "ambient": 0.75, "exposure": 0.95,
		"fog": Color(0.85, 0.62, 0.5), "fog_density": 0.0012, "lights": false, "wet": 0.0,
		"court": Color(0.12, 0.3, 0.52), "inner": Color(0.16, 0.4, 0.6), "key": Color(0.8, 0.34, 0.15),
	},
	{
		"name": "暮光停车楼", "en": "TWILIGHT DECK",
		"desc": "停车楼顶层，紫色的暮光，刚下过雨的地面映着灯光。泛光灯全开。",
		"hdri": "res://assets/polyhaven/hdris/rooftop_night/rooftop_night_4k.hdr",
		"sky_energy": 0.55, "sky_rot": 0.0, "sun_az": -83.0, "sun_el": 50.0, "sun_color": Color(0.62, 0.66, 0.95),
		"sun_energy": 0.22, "shadow_blur": 1.0, "ambient": 0.55, "exposure": 1.0,
		"fog": Color(0.42, 0.32, 0.5), "fog_density": 0.0016, "lights": true, "wet": 0.7,
		"court": Color(0.06, 0.26, 0.25), "inner": Color(0.08, 0.36, 0.33), "key": Color(0.46, 0.2, 0.56),
	},
]

const PITCH := 17.0
const COURTS := 4
const RIM_H := 3.05
const RIM_R := 0.225           ## inside radius of the ring
const RIM_TUBE := 0.0095
const BOARD_Z := -0.376        ## backboard face
const BOARD_W := 1.8
const BOARD_H := 1.05
const BOARD_Y := 2.9           ## bottom edge
const BASE_Z := -1.576
const POLE_Z := -2.5
const ROOF := Rect2(-38.0, -6.0, 76.0, 27.0)     ## x, z extent of the roof
const PARAPET := 1.1
const FENCE := 3.6             ## chain link above the parapet (back and sides)
const ARC := 6.75
const SPOTS := [[-7.0, 0.3], [-5.3, 5.0], [0.0, 7.15], [5.3, 5.0], [7.0, 0.3]]   ## shooter, court space

var map: Dictionary
var nets: Array[RSHoopNet] = []

var _st: Dictionary = {}
var _mats: Dictionary = {}
var _pads: Array[StandardMaterial3D] = []
var _clocks: Array[Label3D] = []
var _rack_balls: Array = []      ## [court][rack] -> Array[MeshInstance3D]
var _rng := RandomNumberGenerator.new()
var _ball_mesh: Mesh


func _init(index: int = 0) -> void:
	map = MAPS[clampi(index, 0, MAPS.size() - 1)]
	_rng.seed = 404 + index


func _ready() -> void:
	_make_materials()
	_ball_mesh = RSBasketball.mesh()
	_build_roof()
	for i in COURTS:
		_build_hoop(i)
		_build_racks(i)
	_build_fence()
	_build_structures()
	_build_props()
	_build_lights()


# ------------------------------------------------------------------------ queries ----

static func court_x(i: int) -> float:
	return (i - (COURTS - 1) * 0.5) * PITCH


static func rim(i: int) -> Vector3:
	## Centre of the ring, level with its top.
	return Vector3(court_x(i), RIM_H, 0.0)


static func spot(i: int, k: int) -> Vector3:
	## Where the shooter stands for rack k (0 = left corner .. 4 = right corner).
	return Vector3(court_x(i) + float(SPOTS[k][0]), 0.0, float(SPOTS[k][1]))


static func facing(i: int, at: Vector3) -> Basis:
	## Standing at `at`, looking at court i's rim (-Z forward).
	var d := Vector3(court_x(i) - at.x, 0.0, -at.z)
	return Basis.looking_at(d.normalized() if d.length() > 0.01 else Vector3.FORWARD, Vector3.UP)


static func rack_xf(i: int, k: int) -> Transform3D:
	## The ball rack beside spot k: to the shooter's right and a little behind, long side
	## across the line of the shot. Ball 0 (the near end) at local x = -0.5.
	var s := spot(i, k)
	var b := facing(i, s)
	return Transform3D(b, s + b.x * 1.05 + b.z * 0.25)


func rack_ball(i: int, k: int, b: int) -> Vector3:
	## World position of ball b's slot on rack k (slot 0 nearest the shooter).
	return rack_xf(i, k) * Vector3(-0.5 + b * 0.25, 0.92 - b * 0.03, 0.0)


func set_rack(i: int, k: int, left: int, money_left: bool) -> void:
	## Show `left` balls on rack k (the rest have been taken); the last slot holds the
	## money ball while it is still there. Balls roll down to the near end of the tray.
	var balls: Array = _rack_balls[i][k]
	for b in 5:
		var mi: MeshInstance3D = balls[b]
		mi.visible = b < left
		mi.position = rack_xf(i, k).affine_inverse() * rack_ball(i, k, b)
		var money := money_left and b == left - 1
		mi.material_override = RSBasketball.material(money)


func set_clock(i: int, text: String, warn: bool = false) -> void:
	_clocks[i].text = text
	_clocks[i].modulate = Color(1.0, 0.25, 0.15) if warn else Color(1.0, 0.62, 0.15)


func tint(i: int, color: Color) -> void:
	## Court i's post padding in its player's colour.
	_pads[i].albedo_color = color


# ---------------------------------------------------------------------- materials ----

func _make_materials() -> void:
	var floor_m := ShaderMaterial.new()
	floor_m.shader = preload("res://shaders/court.gdshader")
	var t := RSPbr.maps("concrete_floor_painted")
	floor_m.set_shader_parameter("albedo_tex", t[0])
	floor_m.set_shader_parameter("normal_tex", t[1])
	floor_m.set_shader_parameter("orm_tex", t[2])
	floor_m.set_shader_parameter("size_m", 3.2)
	floor_m.set_shader_parameter("pitch", PITCH)
	floor_m.set_shader_parameter("courts", COURTS)
	floor_m.set_shader_parameter("court_col", map["court"])
	floor_m.set_shader_parameter("inner_col", map["inner"])
	floor_m.set_shader_parameter("key_col", map["key"])
	floor_m.set_shader_parameter("wet", map["wet"])
	_mats["floor"] = floor_m
	_mats["wall"] = RSPbr.surface("concrete_floor_worn_001", 3.0, Color(0.85, 0.84, 0.82))
	_mats["plate"] = RSPbr.surface("metal_plate", 1.5)
	_mats["wood"] = RSPbr.surface("beam_wall_01", 2.0, Color(0.78, 0.66, 0.55))
	_mats["vc"] = _vc_mat(0.6, 0.0)
	_mats["steel"] = _vc_mat(0.45, 0.6)
	_mats["paint"] = _vc_mat(0.4, 0.0)
	var glass := StandardMaterial3D.new()
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.albedo_color = Color(0.8, 0.9, 0.95, 0.14)
	glass.roughness = 0.04
	glass.metallic_specular = 1.0
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mats["glass"] = glass
	var rim_m := StandardMaterial3D.new()
	rim_m.albedo_color = Color(0.95, 0.3, 0.06)
	rim_m.metallic = 0.55
	rim_m.roughness = 0.32
	_mats["rim"] = rim_m
	var fence := StandardMaterial3D.new()
	fence.albedo_texture = _fence_texture()
	fence.albedo_color = Color(0.55, 0.57, 0.56)
	fence.metallic = 0.6
	fence.roughness = 0.5
	fence.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fence.cull_mode = BaseMaterial3D.CULL_DISABLED
	fence.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_mats["fence"] = fence
	var lit: bool = map["lights"]
	var bulb := StandardMaterial3D.new()
	bulb.albedo_color = Color(1.0, 0.85, 0.6)
	bulb.emission_enabled = true
	bulb.emission = Color(1.0, 0.7, 0.38)
	bulb.emission_energy_multiplier = 6.0 if lit else 2.2
	_mats["bulb"] = bulb
	var lamp := StandardMaterial3D.new()
	lamp.albedo_color = Color(1, 1, 1) if lit else Color(0.55, 0.58, 0.6)
	lamp.emission_enabled = lit
	lamp.emission = Color(1.0, 0.95, 0.86)
	lamp.emission_energy_multiplier = 7.0
	lamp.roughness = 0.2
	_mats["lamp"] = lamp
	var win := StandardMaterial3D.new()
	win.albedo_color = Color(0.9, 0.75, 0.5)
	win.emission_enabled = true
	win.emission = Color(1.0, 0.72, 0.42)
	win.emission_energy_multiplier = 2.5 if lit else 0.8
	_mats["window"] = win
	var cable := StandardMaterial3D.new()
	cable.albedo_color = Color(0.05, 0.05, 0.05)
	cable.roughness = 0.6
	_mats["cable"] = cable


func _vc_mat(roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = roughness
	m.metallic = metallic
	return m


func _fence_texture() -> ImageTexture:
	## Chain link: one tile = 2 x 2 diamonds of galvanised wire. Alpha-blended with plain
	## mipmaps, so far away it fades to the grey veil a real fence makes.
	var n := 128
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var a := fposmod(float(x + y) / 64.0, 1.0)
			var b := fposmod(float(x - y) / 64.0, 1.0)
			var d := minf(minf(a, 1.0 - a), minf(b, 1.0 - b)) * 64.0
			var wire := clampf(3.0 - d, 0.0, 1.0)
			var shade := 0.7 + 0.3 * clampf(1.0 - d / 3.0, 0.0, 1.0)
			img.set_pixel(x, y, Color(shade, shade, shade, wire))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# ------------------------------------------------------------------ mesh builders ----

func _surf(mat_name: String) -> SurfaceTool:
	if not _st.has(mat_name):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_st[mat_name] = st
	return _st[mat_name]


func _commit(node_name: String, shadows: bool = true) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	for mat_name: String in _st:
		var st: SurfaceTool = _st[mat_name]
		var mat: Material = _mats[mat_name]
		if mat is ShaderMaterial:
			st.generate_tangents()
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	_st.clear()
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _box(mat_name: String, xf: Transform3D, size: Vector3, color: Color = Color.WHITE) -> void:
	## A box (in xf's frame) with planar UVs in metres (world-scaled for the scanned surfaces).
	var st := _surf(mat_name)
	var h := size * 0.5
	var faces := [
		[Vector3.RIGHT, Vector3.BACK, Vector3.UP], [Vector3.LEFT, Vector3.FORWARD, Vector3.UP],
		[Vector3.UP, Vector3.RIGHT, Vector3.BACK], [Vector3.DOWN, Vector3.RIGHT, Vector3.FORWARD],
		[Vector3.BACK, Vector3.LEFT, Vector3.UP], [Vector3.FORWARD, Vector3.RIGHT, Vector3.UP]]
	for f: Array in faces:
		var n: Vector3 = f[0]
		var a: Vector3 = f[1]
		var b: Vector3 = f[2]
		var c := n * h
		var ea := a * (h * a).abs().length()
		var eb := b * (h * b).abs().length()
		var pts := [c - ea - eb, c + ea - eb, c + ea + eb, c - ea + eb]
		var la := (h * a).abs().length() * 2.0
		var lb := (h * b).abs().length() * 2.0
		var uvs := [Vector2(0, lb), Vector2(la, lb), Vector2(la, 0), Vector2(0, 0)]
		var wn := (xf.basis * n).normalized()
		for i: int in [0, 1, 2, 0, 2, 3]:
			st.set_normal(wn)
			st.set_color(color)
			st.set_uv(uvs[i])
			st.add_vertex(xf * (pts[i] as Vector3))


func _cyl(mat_name: String, a: Vector3, b: Vector3, r: float, color: Color, sides: int = 8) -> void:
	var st := _surf(mat_name)
	var y := (b - a).normalized()
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	var len := a.distance_to(b)
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var n0 := x * cos(a0) + z * sin(a0)
		var n1 := x * cos(a1) + z * sin(a1)
		var quad := [[a + n0 * r, n0, 0.0], [a + n1 * r, n1, 0.0], [b + n1 * r, n1, len], [b + n0 * r, n0, len]]
		for k: int in [0, 1, 2, 0, 2, 3]:
			st.set_normal(quad[k][1])
			st.set_color(color)
			st.set_uv(Vector2(TAU * r * (i + float(k == 1 or k == 2)) / sides, quad[k][2]))
			st.add_vertex(quad[k][0])


func _body(kind: String, bounce: float, friction: float) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.name = kind
	sb.collision_layer = 1
	sb.collision_mask = 0
	var pm := PhysicsMaterial.new()
	pm.bounce = bounce
	pm.friction = friction
	sb.physics_material_override = pm
	sb.set_meta("kind", kind)
	add_child(sb)
	return sb


func _shape(sb: StaticBody3D, shape: Shape3D, xf: Transform3D) -> void:
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.transform = xf
	sb.add_child(cs)


func _box_shape(sb: StaticBody3D, xf: Transform3D, size: Vector3) -> void:
	var b := BoxShape3D.new()
	b.size = size
	_shape(sb, b, xf)


# -------------------------------------------------------------------------- roof ----

func _build_roof() -> void:
	# Floor: one quad (the shader draws the courts), a thick box collider under it.
	var st := _surf("floor")
	var r := ROOF
	var pts := [Vector3(r.position.x, 0, r.end.y), Vector3(r.end.x, 0, r.end.y), Vector3(r.end.x, 0, r.position.y), Vector3(r.position.x, 0, r.position.y)]
	for k: int in [0, 2, 1, 0, 3, 2]:
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2((pts[k] as Vector3).x, (pts[k] as Vector3).z))
		st.add_vertex(pts[k])
	var fl := _commit("floor")
	fl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var floor_body := _body("floor", 0.8, 0.8)
	_box_shape(floor_body, Transform3D(Basis(), Vector3(r.get_center().x, -0.5, r.get_center().y)), Vector3(r.size.x, 1.0, r.size.y))

	# Parapet round the edge, a coping on top; the walls drop away below the roof.
	var walls := _body("wall", 0.5, 0.7)
	var t := 0.3
	var sides := [
		[Vector3(r.get_center().x, 0, r.position.y - t * 0.5), Vector3(r.size.x + t * 2.0, 0, t)],
		[Vector3(r.get_center().x, 0, r.end.y + t * 0.5), Vector3(r.size.x + t * 2.0, 0, t)],
		[Vector3(r.position.x - t * 0.5, 0, r.get_center().y), Vector3(t, 0, r.size.y)],
		[Vector3(r.end.x + t * 0.5, 0, r.get_center().y), Vector3(t, 0, r.size.y)]]
	for s: Array in sides:
		var c: Vector3 = s[0]
		var sz: Vector3 = s[1]
		_box("wall", Transform3D(Basis(), c + Vector3(0, (PARAPET - 6.0) * 0.5, 0)), Vector3(sz.x, PARAPET + 6.0, sz.z))
		_box("wall", Transform3D(Basis(), c + Vector3(0, PARAPET + 0.04, 0)), Vector3(sz.x + 0.12, 0.08, sz.z + 0.12), Color(0.8, 0.8, 0.8))
		_box_shape(walls, Transform3D(Basis(), c + Vector3(0, PARAPET * 0.5, 0)), Vector3(sz.x, PARAPET, sz.z))
	# Roof drains and a few repair patches, as flat dark plates.
	for i in 6:
		var at := Vector3(_rng.randf_range(r.position.x + 2, r.end.x - 2), 0.004, r.end.y - _rng.randf_range(0.5, 1.2))
		_box("steel", Transform3D(Basis(), at), Vector3(0.35, 0.01, 0.35), Color(0.15, 0.15, 0.16))
	_commit("parapet")


# ------------------------------------------------------------------------- hoops ----

func _build_hoop(i: int) -> void:
	var x := court_x(i)
	var steel := Color(0.16, 0.17, 0.19)
	var white := Color(0.95, 0.95, 0.95)
	var board_c := Vector3(x, BOARD_Y + BOARD_H * 0.5, BOARD_Z - 0.015)

	# Glass board, white border and shooter's square painted on its face, steel frame behind.
	_box("glass", Transform3D(Basis(), board_c), Vector3(BOARD_W, BOARD_H, 0.03))
	var face := BOARD_Z + 0.002
	var lw := 0.05
	for e: Array in [[0.0, BOARD_H * 0.5 - lw * 0.5, BOARD_W, lw], [0.0, -BOARD_H * 0.5 + lw * 0.5, BOARD_W, lw],
			[BOARD_W * 0.5 - lw * 0.5, 0.0, lw, BOARD_H], [-BOARD_W * 0.5 + lw * 0.5, 0.0, lw, BOARD_H]]:
		_box("paint", Transform3D(Basis(), Vector3(x + float(e[0]), board_c.y + float(e[1]), face)), Vector3(e[2], e[3], 0.003), white)
	var sq_b := RIM_H
	for e: Array in [[0.0, sq_b + 0.45 - lw * 0.5, 0.59, lw], [-0.295 + lw * 0.5, sq_b + 0.225, lw, 0.45], [0.295 - lw * 0.5, sq_b + 0.225, lw, 0.45],
			[0.0, sq_b + lw * 0.5, 0.59, lw]]:
		_box("paint", Transform3D(Basis(), Vector3(x + float(e[0]), float(e[1]), face)), Vector3(e[2], e[3], 0.003), white)
	var back := BOARD_Z - 0.05
	for e: Array in [[0.0, BOARD_H * 0.5, BOARD_W + 0.04, 0.04], [0.0, -BOARD_H * 0.5, BOARD_W + 0.04, 0.04],
			[BOARD_W * 0.5, 0.0, 0.04, BOARD_H], [-BOARD_W * 0.5, 0.0, 0.04, BOARD_H]]:
		_box("steel", Transform3D(Basis(), Vector3(x + float(e[0]), board_c.y + float(e[1]), back)), Vector3(e[2], e[3], 0.04), steel)
	# Padding along the bottom edge.
	_box("vc", Transform3D(Basis(), Vector3(x, BOARD_Y + 0.025, BOARD_Z - 0.02)), Vector3(BOARD_W + 0.02, 0.05, 0.07), Color(0.08, 0.08, 0.09))

	# Gooseneck: square post behind the baseline, arm out to the board, a diagonal brace.
	var post_top := BOARD_Y + BOARD_H * 0.62
	_box("steel", Transform3D(Basis(), Vector3(x, post_top * 0.5, POLE_Z)), Vector3(0.16, post_top, 0.16), steel)
	var arm_z0 := POLE_Z
	var arm_z1 := back - 0.02
	_box("steel", Transform3D(Basis(), Vector3(x, post_top - 0.08, (arm_z0 + arm_z1) * 0.5)), Vector3(0.12, 0.12, arm_z1 - arm_z0), steel)
	_box("steel", Transform3D(Basis(), Vector3(x, BOARD_Y + 0.25, (arm_z0 + arm_z1) * 0.5)), Vector3(0.1, 0.1, arm_z1 - arm_z0), steel)
	_cyl("steel", Vector3(x, BOARD_Y - 0.6, POLE_Z + 0.08), Vector3(x, post_top - 0.15, arm_z1 - 0.6), 0.04, steel, 6)
	# Base plate and bolts.
	_box("steel", Transform3D(Basis(), Vector3(x, 0.01, POLE_Z)), Vector3(0.5, 0.02, 0.5), Color(0.22, 0.22, 0.23))
	_commit("hoop_%d" % i)

	# Post padding in the player's colour.
	var pad := StandardMaterial3D.new()
	pad.albedo_color = Color(0.2, 0.22, 0.26)
	pad.roughness = 0.75
	_pads.append(pad)
	var pmi := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(0.36, 1.9, 0.36)
	pmi.mesh = pm
	pmi.material_override = pad
	pmi.position = Vector3(x, 0.95, POLE_Z)
	add_child(pmi)

	# Ring, hooks, bracket.
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = RIM_R
	tm.outer_radius = RIM_R + RIM_TUBE * 2.0
	tm.rings = 48
	tm.ring_segments = 10
	ring.mesh = tm
	ring.material_override = _mats["rim"]
	ring.position = Vector3(x, RIM_H - RIM_TUBE, 0.0)
	add_child(ring)
	var c := Vector3(x, RIM_H - RIM_TUBE, 0.0)
	for h in 12:
		var a := TAU * (h + 0.5) / 12.0
		var at := c + Vector3(cos(a), 0, sin(a)) * (RIM_R + RIM_TUBE)
		_cyl("rim", at, at + Vector3(0, -0.035, 0), 0.004, Color.WHITE, 4)
	_box("rim", Transform3D(Basis(), Vector3(x, RIM_H - 0.03, (BOARD_Z - RIM_R) * 0.5 - 0.005)), Vector3(0.14, 0.04, BOARD_Z * -1.0 - RIM_R - 0.01))
	_box("rim", Transform3D(Basis(), Vector3(x, RIM_H - 0.09, BOARD_Z + 0.008)), Vector3(0.24, 0.16, 0.016))
	_commit("rim_%d" % i)

	# Colliders: the ring as a loop of capsules, the bracket, the board, the post and arm.
	var rim_body := _body("rim", 0.55, 0.6)
	var segs := 24
	var rr := RIM_R + RIM_TUBE
	for s in segs:
		var a0 := TAU * s / segs
		var a1 := TAU * (s + 1) / segs
		var p0 := c + Vector3(cos(a0), 0, sin(a0)) * rr
		var p1 := c + Vector3(cos(a1), 0, sin(a1)) * rr
		var cap := CapsuleShape3D.new()
		cap.radius = RIM_TUBE
		cap.height = p0.distance_to(p1) + RIM_TUBE * 2.0
		var dir := (p1 - p0).normalized()
		_shape(rim_body, cap, Transform3D(RSHumanRig._frame(dir, Vector3.UP), (p0 + p1) * 0.5))
	_box_shape(rim_body, Transform3D(Basis(), Vector3(x, RIM_H - 0.03, (BOARD_Z - RIM_R) * 0.5)), Vector3(0.12, 0.04, -BOARD_Z - RIM_R - 0.02))
	var board_body := _body("board", 0.6, 0.5)
	_box_shape(board_body, Transform3D(Basis(), Vector3(x, board_c.y, BOARD_Z - 0.04)), Vector3(BOARD_W, BOARD_H, 0.08))
	var pole := _body("pole", 0.35, 0.6)
	_box_shape(pole, Transform3D(Basis(), Vector3(x, post_top * 0.5, POLE_Z)), Vector3(0.36, post_top, 0.36))
	_box_shape(pole, Transform3D(Basis(), Vector3(x, post_top - 0.08, (arm_z0 + arm_z1) * 0.5)), Vector3(0.12, 0.12, arm_z1 - arm_z0))

	var net := RSHoopNet.new()
	net.position = Vector3(x, RIM_H - RIM_TUBE, 0.0)
	add_child(net)
	nets.append(net)

	# Shot clock on top of the board.
	_box("vc", Transform3D(Basis(), Vector3(x, BOARD_Y + BOARD_H + 0.17, BOARD_Z - 0.04)), Vector3(0.62, 0.28, 0.14), Color(0.05, 0.05, 0.06))
	_cyl("steel", Vector3(x - 0.2, BOARD_Y + BOARD_H, BOARD_Z - 0.04), Vector3(x - 0.2, BOARD_Y + BOARD_H + 0.04, BOARD_Z - 0.04), 0.02, steel, 6)
	_cyl("steel", Vector3(x + 0.2, BOARD_Y + BOARD_H, BOARD_Z - 0.04), Vector3(x + 0.2, BOARD_Y + BOARD_H + 0.04, BOARD_Z - 0.04), 0.02, steel, 6)
	_commit("clock_%d" % i)
	var lbl := Label3D.new()
	lbl.text = "60"
	lbl.font = RSUi.font()
	lbl.font_size = 64
	lbl.pixel_size = 0.0034
	lbl.outline_size = 0
	lbl.modulate = Color(1.0, 0.62, 0.15)
	lbl.shaded = false
	lbl.double_sided = false
	lbl.position = Vector3(x, BOARD_Y + BOARD_H + 0.17, BOARD_Z + 0.032)
	add_child(lbl)
	_clocks.append(lbl)


func _build_racks(i: int) -> void:
	var steel := Color(0.1, 0.1, 0.11)
	var per: Array = []
	for k in 5:
		var xf := rack_xf(i, k)
		# Sloped double rail on four legs, a lip at the low end.
		for z: float in [-0.09, 0.09]:
			_cyl("steel", xf * Vector3(-0.66, 0.8, z), xf * Vector3(0.62, 0.68, z), 0.016, steel, 6)
		for e: Array in [[-0.6, -0.12], [-0.6, 0.12], [0.56, -0.12], [0.56, 0.12]]:
			var top := xf * Vector3(float(e[0]), 0.8 - (float(e[0]) + 0.66) * 0.093, float(e[1]) * 0.75)
			_cyl("steel", xf * Vector3(float(e[0]), 0.0, float(e[1]) * 1.3), top, 0.015, steel, 6)
		_cyl("steel", xf * Vector3(-0.66, 0.78, -0.12), xf * Vector3(-0.66, 0.9, -0.12), 0.012, steel, 6)
		_cyl("steel", xf * Vector3(-0.66, 0.78, 0.12), xf * Vector3(-0.66, 0.9, 0.12), 0.012, steel, 6)
		_cyl("steel", xf * Vector3(-0.6, 0.12, -0.16), xf * Vector3(0.56, 0.12, -0.16), 0.012, steel, 6)
		_cyl("steel", xf * Vector3(-0.6, 0.12, 0.16), xf * Vector3(0.56, 0.12, 0.16), 0.012, steel, 6)
		var balls: Array = []
		var holder := Node3D.new()
		holder.transform = xf
		add_child(holder)
		for b in 5:
			var mi := MeshInstance3D.new()
			mi.mesh = _ball_mesh
			mi.material_override = RSBasketball.material(b == 4)
			mi.rotation = Vector3(_rng.randf() * TAU, _rng.randf() * TAU, 0.0)
			holder.add_child(mi)
			mi.position = xf.affine_inverse() * rack_ball(i, k, b)
			balls.append(mi)
		per.append(balls)
	_rack_balls.append(per)
	_commit("racks_%d" % i)


# ------------------------------------------------------------------------- fence ----

func _build_fence() -> void:
	## Chain link on the parapet along the back and the sides, posts every 3 m, top rail.
	var r := ROOF
	var y0 := PARAPET + 0.08
	var y1 := y0 + FENCE
	var runs := [
		[Vector3(r.position.x, 0, r.position.y - 0.15), Vector3(r.end.x, 0, r.position.y - 0.15)],
		[Vector3(r.position.x - 0.15, 0, r.position.y), Vector3(r.position.x - 0.15, 0, r.end.y)],
		[Vector3(r.end.x + 0.15, 0, r.position.y), Vector3(r.end.x + 0.15, 0, r.end.y)]]
	var fence_body := _body("fence", 0.25, 0.8)
	var post := Color(0.5, 0.52, 0.53)
	for run: Array in runs:
		var a: Vector3 = run[0]
		var b: Vector3 = run[1]
		var len := a.distance_to(b)
		var st := _surf("fence")
		var n := (b - a).cross(Vector3.UP).normalized()
		var q := [a + Vector3(0, y0, 0), b + Vector3(0, y0, 0), b + Vector3(0, y1, 0), a + Vector3(0, y1, 0)]
		var uv := [Vector2(0, FENCE), Vector2(len, FENCE), Vector2(len, 0), Vector2(0, 0)]
		for k: int in [0, 1, 2, 0, 2, 3]:
			st.set_normal(n)
			st.set_uv((uv[k] as Vector2) / 0.11)
			st.add_vertex(q[k])
		var posts := ceili(len / 3.0)
		for p in posts + 1:
			var at := a.lerp(b, float(p) / posts)
			_cyl("steel", at + Vector3(0, PARAPET, 0), at + Vector3(0, y1 + 0.05, 0), 0.03, post, 8)
		_cyl("steel", a + Vector3(0, y1, 0), b + Vector3(0, y1, 0), 0.022, post, 8)
		_cyl("steel", a + Vector3(0, y0 + 0.02, 0), b + Vector3(0, y0 + 0.02, 0), 0.015, post, 6)
		var mid := (a + b) * 0.5
		var size := Vector3(absf(b.x - a.x) + 0.1, FENCE, absf(b.z - a.z) + 0.1)
		_box_shape(fence_body, Transform3D(Basis(), mid + Vector3(0, (y0 + y1) * 0.5, 0)), size)
	# Glass balustrade along the front (open to the view), steel handrail.
	var fz := r.end.y + 0.15
	_box("glass", Transform3D(Basis(), Vector3(r.get_center().x, PARAPET + 0.55, fz)), Vector3(r.size.x, 1.0, 0.02))
	_cyl("steel", Vector3(r.position.x, PARAPET + 1.08, fz), Vector3(r.end.x, PARAPET + 1.08, fz), 0.03, post, 8)
	var x := r.position.x
	while x <= r.end.x + 0.01:
		_cyl("steel", Vector3(x, PARAPET, fz), Vector3(x, PARAPET + 1.08, fz), 0.025, post, 6)
		x += 2.5
	_box_shape(fence_body, Transform3D(Basis(), Vector3(r.get_center().x, PARAPET + 0.55, fz)), Vector3(r.size.x, 1.1, 0.1))
	_commit("fence")


# -------------------------------------------------------------------- structures ----

func _build_structures() -> void:
	var r := ROOF
	# Stairwell bulkhead in the front-left corner: concrete box, steel door, a wall lamp.
	var sw := Rect2(r.position.x, 15.6, 5.2, r.end.y - 15.6)
	var h := 3.2
	var c := Vector3(sw.get_center().x, h * 0.5, sw.get_center().y)
	_box("wall", Transform3D(Basis(), c), Vector3(sw.size.x, h, sw.size.y))
	_box("wall", Transform3D(Basis(), c + Vector3(0, h * 0.5 + 0.1, 0)), Vector3(sw.size.x + 0.3, 0.2, sw.size.y + 0.3), Color(0.75, 0.75, 0.75))
	var door := Vector3(sw.end.x + 0.01, 1.05, sw.get_center().y)
	_box("plate", Transform3D(Basis(), door), Vector3(0.04, 2.1, 1.0), Color(0.35, 0.42, 0.48))
	_box("steel", Transform3D(Basis(), door + Vector3(0.04, 0.0, 0.35)), Vector3(0.04, 0.03, 0.12), Color(0.7, 0.7, 0.7))
	_box("window", Transform3D(Basis(), Vector3(sw.end.x + 0.06, 2.45, sw.get_center().y)), Vector3(0.1, 0.12, 0.35))
	var body := _body("wall", 0.4, 0.7)
	_box_shape(body, Transform3D(Basis(), c), Vector3(sw.size.x, h, sw.size.y))
	_commit("stairwell")
	var wl := OmniLight3D.new()
	wl.light_color = Color(1.0, 0.75, 0.45)
	wl.light_energy = 2.0 if map["lights"] else 0.6
	wl.omni_range = 7.0
	wl.position = Vector3(sw.end.x + 0.4, 2.4, sw.get_center().y)
	add_child(wl)

	# Wooden water tank on a steel stand in the front-right corner.
	var tc := Vector3(r.end.x - 3.2, 0.0, 17.6)
	var legs := 1.6
	for a in 6:
		var ang := TAU * a / 6.0
		var at := tc + Vector3(cos(ang), 0, sin(ang)) * 1.5
		_cyl("steel", at, at + Vector3(0, legs, 0), 0.07, Color(0.2, 0.18, 0.17), 6)
	_box("steel", Transform3D(Basis(), tc + Vector3(0, legs, 0)), Vector3(3.6, 0.15, 3.6), Color(0.22, 0.2, 0.18))
	var tank := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.65
	cm.bottom_radius = 1.75
	cm.height = 3.2
	cm.radial_segments = 40
	tank.mesh = cm
	tank.material_override = RSPbr.standard("beam_wall_01", 1.2, Color(0.75, 0.62, 0.5))
	tank.position = tc + Vector3(0, legs + 0.075 + 1.6, 0)
	add_child(tank)
	var roof_m := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.05
	cone.bottom_radius = 1.85
	cone.height = 1.0
	cone.radial_segments = 40
	roof_m.mesh = cone
	roof_m.material_override = RSPbr.standard("metal_plate", 1.0, Color(0.5, 0.45, 0.42))
	roof_m.position = tc + Vector3(0, legs + 3.35 + 0.5, 0)
	add_child(roof_m)
	for b in 4:
		_cyl("steel", tc + Vector3(0, legs + 0.5 + b * 0.75, 0) + Vector3(0, 0, 0), tc + Vector3(0, legs + 0.52 + b * 0.75, 0), 1.77, Color(0.12, 0.12, 0.12), 32)
	var tb := _body("wall", 0.3, 0.7)
	var tshape := CylinderShape3D.new()
	tshape.radius = 1.75
	tshape.height = legs + 3.4
	_shape(tb, tshape, Transform3D(Basis(), tc + Vector3(0, (legs + 3.4) * 0.5, 0)))
	_commit("tank")


func _build_props() -> void:
	var r := ROOF
	var benches: Array = []
	var bins: Array = []
	var crates: Array = []
	var ac: Array = []
	var ac_rust: Array = []
	var plants: Array = []
	var lamps: Array = []
	var face_court := Basis(Vector3.UP, PI)          # props face +Z by default; turn to face the courts
	for i in COURTS:
		var x := court_x(i)
		var bx := 5.6 if i == 2 else 3.2          # court 2's deck holds the podium
		benches.append(Transform3D(face_court, Vector3(x - bx, 0, 15.2)))
		benches.append(Transform3D(face_court, Vector3(x + bx, 0, 15.2)))
		bins.append(Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), Vector3(x + (7.0 if i == 2 else 5.0), 0, 15.6)))
	# A boombox on the bench behind court 1; spare balls and crates by the stairwell.
	RSProps.place(self, "urban_boombox", [Transform3D(Basis(Vector3.UP, PI + 0.3).scaled(Vector3.ONE * 1.4), Vector3(court_x(1) - 2.8, 0.47, 15.15))])
	for k in 4:
		crates.append(Transform3D(Basis(Vector3.UP, _rng.randf_range(-0.2, 0.2)), Vector3(r.position.x + 6.2 + (k % 2) * 0.62, 0.36 * floori(k / 2.0), 19.6)))
	for k in 5:
		var at := Vector3(r.position.x + 7.6 + k * 0.32, 0.12, 20.4 - (k % 2) * 0.25)
		var mi := MeshInstance3D.new()
		mi.mesh = _ball_mesh
		mi.material_override = RSBasketball.material(false)
		mi.position = at
		mi.rotation = Vector3(_rng.randf() * TAU, _rng.randf() * TAU, 0)
		add_child(mi)
	# AC units and planters along the front, lamps at the deck's corners.
	var x := r.position.x + 12.0
	while x < r.end.x - 9.0:
		if _rng.randf() < 0.5:
			(ac if _rng.randf() < 0.6 else ac_rust).append(Transform3D(face_court, Vector3(x, 0, r.end.y - 0.55)))
		else:
			plants.append(Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), Vector3(x, 0, r.end.y - 0.5)))
		x += _rng.randf_range(2.4, 4.0)
	for z: float in [-4.6, 13.8]:
		for lx: float in [r.position.x + 0.8, r.end.x - 0.8]:
			lamps.append(Transform3D(Basis(Vector3.UP, (0.0 if lx < 0 else PI) + PI * 0.5), Vector3(lx, 0, z)))
	RSProps.place(self, "urban_bench", benches)
	RSProps.place(self, "urban_bin", bins)
	RSProps.place(self, "urban_crate", crates)
	RSProps.place(self, "urban_aircon", ac)
	RSProps.place(self, "urban_aircon_rust", ac_rust)
	RSProps.place(self, "urban_planter", plants)
	RSProps.place(self, "urban_lamp", lamps)
	var lamp_h := RSProps.size("urban_lamp").y
	for l: Transform3D in lamps:
		var ol := OmniLight3D.new()
		ol.light_color = Color(1.0, 0.78, 0.5)
		ol.light_energy = 3.0 if map["lights"] else 0.0
		ol.omni_range = 12.0
		ol.position = l.origin + Vector3(0, lamp_h - 0.5, 0) + l.basis.x * 0.0
		ol.visible = map["lights"]
		add_child(ol)
	var bench_body := _body("wall", 0.3, 0.7)
	for b: Transform3D in benches:
		_box_shape(bench_body, Transform3D(Basis(), b.origin + Vector3(0, 0.25, 0)), Vector3(1.6, 0.5, 0.6))

	# String lights over the deck: catenaries between poles, bulbs every 0.7 m.
	var bulbs: Array = []
	var pole_xs := [r.position.x + 6.0, -PITCH, 0.0, PITCH, r.end.x - 6.5]
	var h := 4.6
	for p: float in pole_xs:
		_cyl("steel", Vector3(p, 0, 18.6), Vector3(p, h + 0.2, 18.6), 0.05, Color(0.15, 0.15, 0.16), 8)
		_cyl("steel", Vector3(p, 0, 13.8), Vector3(p, h + 0.2, 13.8), 0.05, Color(0.15, 0.15, 0.16), 8)
	var spans: Array = []
	for j in pole_xs.size() - 1:
		spans.append([Vector3(pole_xs[j], h, 18.6), Vector3(pole_xs[j + 1], h, 18.6)])
		spans.append([Vector3(pole_xs[j], h, 13.8), Vector3(pole_xs[j + 1], h, 13.8)])
		spans.append([Vector3(pole_xs[j], h, 13.8), Vector3(pole_xs[j + 1], h, 18.6)])
	for s: Array in spans:
		var a: Vector3 = s[0]
		var b: Vector3 = s[1]
		var len := a.distance_to(b)
		var sag := len * 0.06
		var n := ceili(len / 0.7)
		var prev := a
		for k in range(1, n + 1):
			var u := float(k) / n
			var at := a.lerp(b, u) + Vector3(0, -sag * 4.0 * u * (1.0 - u), 0)
			_cyl("cable", prev, at, 0.006, Color.BLACK, 3)
			if k < n:
				bulbs.append(Transform3D(Basis().scaled(Vector3.ONE * 0.05), at + Vector3(0, -0.06, 0)))
			prev = at
	_commit("props")
	var sphere := SphereMesh.new()
	sphere.radial_segments = 8
	sphere.rings = 4
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sphere
	mm.instance_count = bulbs.size()
	for k in bulbs.size():
		mm.set_instance_transform(k, bulbs[k])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = _mats["bulb"]
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	for j in pole_xs.size() - 1:
		var ol := OmniLight3D.new()
		ol.light_color = Color(1.0, 0.72, 0.42)
		ol.light_energy = 1.6 if map["lights"] else 0.5
		ol.omni_range = 7.5
		ol.position = Vector3((float(pole_xs[j]) + float(pole_xs[j + 1])) * 0.5, h - 0.6, 16.2)
		add_child(ol)


# ------------------------------------------------------------------------ lights ----

func _build_lights() -> void:
	## Floodlight masts between the courts, behind the shooters and behind the fence, aimed
	## at the courts on either side. Only switched on for the night map.
	var lit: bool = map["lights"]
	var steel := Color(0.3, 0.31, 0.33)
	var xs: Array[float] = []
	for i in COURTS + 1:
		xs.append((i - COURTS * 0.5) * PITCH)
	xs[0] += 1.2
	xs[COURTS] -= 1.2
	for row: Array in [[13.6, 9.0, true], [ROOF.position.y - 0.5, 8.0, false]]:
		var z: float = row[0]
		var h: float = row[1]
		for x: float in xs:
			_cyl("steel", Vector3(x, 0, z), Vector3(x, h, z), 0.12, steel, 8)
			for i in COURTS:
				var cx := court_x(i)
				if absf(cx - x) > PITCH * 0.75:
					continue
				var aim := Vector3(cx + signf(x - cx) * 2.0, 0.0, 3.5 if row[2] else 1.5)
				var top := Vector3(x, h, z)
				var dir := (aim - top).normalized()
				var head := top + Vector3(dir.x, 0, dir.z).normalized() * 0.5
				_box("steel", Transform3D(Basis.looking_at(Vector3(dir.x, 0, dir.z).normalized(), Vector3.UP), top + Vector3(dir.x, 0, dir.z).normalized() * 0.25), Vector3(0.12, 0.12, 0.5), steel)
				_box("lamp", Transform3D(Basis.looking_at(dir, Vector3.UP), head), Vector3(0.7, 0.45, 0.12))
				if not lit:
					continue
				var spot := SpotLight3D.new()
				spot.light_color = Color(1.0, 0.95, 0.86)
				spot.light_energy = 14.0 if row[2] else 8.0
				spot.spot_range = 40.0
				spot.spot_angle = 38.0
				spot.spot_attenuation = 0.7
				spot.shadow_enabled = row[2]
				spot.shadow_blur = 1.5
				spot.position = head + dir * 0.1
				add_child(spot)
				spot.look_at(aim)
	_commit("masts")


# ------------------------------------------------------------------- environment ----

func setup_environment(parent: Node) -> DirectionalLight3D:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var pano := PanoramaSkyMaterial.new()
	pano.panorama = load(map["hdri"])
	pano.energy_multiplier = map["sky_energy"]
	var sky := Sky.new()
	sky.sky_material = pano
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	env.sky = sky
	env.sky_rotation = Vector3(0, float(map["sky_rot"]), 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = map["ambient"]
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = map["exposure"]
	env.ssao_enabled = true
	env.ssao_radius = 1.0
	env.ssao_intensity = 1.6
	env.ssr_enabled = float(map["wet"]) > 0.0
	env.ssr_max_steps = 48
	env.glow_enabled = true
	env.glow_intensity = 0.45 if map["lights"] else 0.4
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.08
	env.adjustment_contrast = 1.05
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = map["fog"]
	env.fog_sun_scatter = 0.3
	env.fog_density = map["fog_density"]
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.4
	var we := WorldEnvironment.new()
	we.environment = env
	parent.add_child(we)

	var sun := DirectionalLight3D.new()
	var az := deg_to_rad(float(map["sun_az"]))
	var el := deg_to_rad(float(map["sun_el"]))
	var to_sun := Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))
	sun.basis = Basis.looking_at(-to_sun, Vector3.UP)
	sun.light_color = map["sun_color"]
	sun.light_energy = map["sun_energy"]
	sun.light_angular_distance = 1.5
	sun.shadow_enabled = true
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.0
	sun.shadow_blur = map["shadow_blur"]
	sun.directional_shadow_max_distance = 90.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	parent.add_child(sun)
	return sun
