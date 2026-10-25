class_name RSSkiCourse
extends Node3D
## A downhill ski run built from one of RSSkiMaps: the snow (groomed piste between safety nets,
## powder and forest outside, rock and peaks beyond), kickers, slalom gates, start hut, finish
## arena with crowd and timing board, and per map a village, chairlift and floodlights. Sky,
## sun and fog come from setup_environment().
##
## Course space: s = metres down the run (world z = -s), the piste winds left and right around
## x = centre(s) and is half_width(s) wide either side of it. The start gate is at s = 0, the
## finish line at s = length. height(x, z) is the snow everywhere, kickers included.

const PRE := 100.0             ## terrain above the start
const POST := 260.0            ## finish arena, run-out and village below the finish line
const SIDE := 170.0            ## near terrain reaches this far either side of the centre line
const NET := 1.8               ## safety nets this far outside the piste edge
const FAR := 4200.0            ## mountains out to here
const CHUNK_ROWS := 50
const FINISH_W := 14.0         ## extra half width of the finish arena
const LIFT_SPEED := 4.5

var map_index := 0
var map: Dictionary
var length := 1000.0
var gates: Array[Dictionary] = []      ## {s, x, w, color (0 red, 1 blue), side}
var kickers: Array[Dictionary] = []    ## {lip, len, h, u, w}

var _base := PackedFloat32Array()      ## centre-line height every metre from s = -PRE
var _cx := PackedFloat32Array()        ## centre x every metre
var _hw := PackedFloat32Array()        ## piste half width every metre
var _noise := FastNoiseLite.new()
var _ridge := FastNoiseLite.new()
var _rng := RandomNumberGenerator.new()
var _st := {}
var _mats := {}
var _board: Label3D
var _lift_pts := PackedVector3Array()  ## closed loop of the lift cable (up one side, down the other)
var _lift_cum := PackedFloat32Array()
var _chairs: MultiMesh


func _init(index: int = 0) -> void:
	map_index = posmod(index, RSSkiMaps.count())
	map = RSSkiMaps.get_map(map_index)
	length = map["length"]
	_rng.seed = int(map["seed"])
	_noise.seed = int(map["seed"])
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.022
	_noise.fractal_octaves = 3
	_ridge.seed = int(map["seed"]) + 7
	_ridge.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_ridge.frequency = 0.0011
	_ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_ridge.fractal_octaves = 5
	_ridge.fractal_gain = 0.4
	_build_profile()


func _ready() -> void:
	_make_materials()
	_build_terrain()
	_build_far()
	_build_kickers()
	_build_gates()
	_build_nets()
	_build_markers()
	_build_trees()
	_build_rocks()
	_build_start()
	_build_finish()
	if map["village"]:
		_build_village()
	if map["lift"]:
		_build_lift()
	if map["lights"]:
		_build_floodlights()


func _process(delta: float) -> void:
	if _chairs == null:
		return
	var total := _lift_cum[_lift_cum.size() - 1]
	var n := _chairs.instance_count
	var t0 := fmod(Time.get_ticks_msec() * 0.001 * LIFT_SPEED, total)
	for i in n:
		_chairs.set_instance_transform(i, _chair_xf(fmod(t0 + total * i / n, total)))


# ------------------------------------------------------------------------ profile ----

func _build_profile() -> void:
	var prof: Array = map["profile"]
	var w: float = map["half_width"]
	var amp: float = map["amp"]
	var wave: float = map["wave"]
	var ph := _rng.randf() * TAU
	var ph2 := _rng.randf() * TAU
	var ph3 := _rng.randf() * TAU
	# Kickers: a take-off ramp up to the lip; the slope after it steepens for the landing.
	for k: Array in map["kickers"]:
		var h: float = k[1]
		kickers.append({"lip": float(k[0]), "len": h * 6.5, "h": h, "u": float(k[2]) * w * 0.45, "w": 7.0})
	var n := int(PRE + length + POST) + 2
	_base.resize(n)
	_cx.resize(n)
	_hw.resize(n)
	var y := 0.0
	for i in n:
		var s := float(i) - PRE
		var g := 0.36
		if s >= -25.0 and s < 0.0:
			g = 0.04                                   # start platform
		elif s >= 0.0 and s <= length:
			g = _profile_grade(prof, s)
		elif s > length:
			g = lerpf(0.1, -0.03, clampf((s - length) / 90.0, 0.0, 1.0))
		for k in kickers:
			var lip: float = k["lip"]
			g -= 0.1 * _bump(s, lip - k["len"] - 60.0, lip - 2.0)     # run-in: scrub some speed
			g += 0.3 * _bump(s, lip + 2.0, lip + 52.0)                # long, steep landing
		if i > 0:
			y -= g
		_base[i] = y
		var fade := smoothstep(-10.0, 70.0, s) * (1.0 - smoothstep(length - 120.0, length - 30.0, s))
		_cx[i] = amp * fade * (0.65 * sin(TAU * s / wave + ph) + 0.35 * sin(TAU * s / (wave * 0.53) + ph2) - (0.65 * sin(ph) + 0.35 * sin(ph2)) * (1.0 - smoothstep(0.0, 70.0, s)))
		var hw := w * (1.0 + 0.16 * sin(TAU * s / 170.0 + ph3))
		hw = lerpf(9.0, hw, smoothstep(-20.0, 30.0, s))
		hw += FINISH_W * smoothstep(length - 60.0, length - 10.0, s)
		_hw[i] = hw
	# The run goes straight through the jumps (no bend under a skier in the air).
	for k in kickers:
		var lip: float = k["lip"]
		var ia := clampi(int(lip - float(k["len"]) - 50.0 + PRE), 0, n - 1)
		var ib := clampi(int(lip + 70.0 + PRE), 0, n - 1)
		var ca := _cx[ia]
		var cb := _cx[ib]
		for i in range(ia, ib + 1):
			var t := float(i - ia) / (ib - ia)
			var sw := smoothstep(0.0, 0.3, t) * (1.0 - smoothstep(0.7, 1.0, t))
			_cx[i] = lerpf(_cx[i], lerpf(ca, cb, t), sw)


static func _profile_grade(prof: Array, s: float) -> float:
	for i in prof.size() - 1:
		var a: Array = prof[i]
		var b: Array = prof[i + 1]
		if s <= float(b[0]):
			return lerpf(float(a[1]), float(b[1]), smoothstep(float(a[0]), float(b[0]), s))
	return float(prof[-1][1])


static func _bump(s: float, a: float, b: float) -> float:
	## 0 outside a..b, a smooth hump inside.
	if s <= a or s >= b:
		return 0.0
	return sin(PI * (s - a) / (b - a))


func _sample(arr: PackedFloat32Array, s: float) -> float:
	var f := clampf(s + PRE, 0.0, arr.size() - 1.001)
	var i := int(f)
	return lerpf(arr[i], arr[i + 1], f - i)


func base(s: float) -> float:
	if s < -PRE:
		return _base[0] + minf(-PRE - s, 2500.0) * 0.4
	var end := length + POST
	if s > end:
		return _base[_base.size() - 1] - minf(s - end, 900.0) * 0.12
	return _sample(_base, s)


func centre(s: float) -> float:
	return _sample(_cx, s)


func half_width(s: float) -> float:
	return _sample(_hw, s)


func bound(s: float) -> float:
	## Where the nets are: lateral distance from the centre line.
	return half_width(s) + NET


func heading_at(s: float) -> float:
	## Heading (0 = -Z, + = turning left) of the centre line at s.
	return atan2(-(centre(s + 1.0) - centre(s - 1.0)) * 0.5, 1.0)


func world(u: float, s: float, up: float = 0.0) -> Vector3:
	## A point `u` metres right of the centre line at s, `up` above the snow.
	var x := centre(s) + u
	return Vector3(x, height(x, -s) + up, -s)


func lateral(x: float, z: float) -> float:
	return x - centre(-z)


func ground(x: float, z: float) -> float:
	## The snow without the kickers.
	var s := -z
	var u := x - centre(s)
	var h := base(s)
	var e := absf(u) - half_width(s)
	if e > 0.0:
		h += minf(e, 30.0) * 0.12 + maxf(e - 30.0, 0.0) * 0.05
	h += _noise.get_noise_2d(x, z) * lerpf(0.4, 3.0, clampf(e / 14.0, 0.0, 1.0))
	h += _mountain(x, z, u, s)
	return h


func height(x: float, z: float) -> float:
	return ground(x, z) + kick(x, -z)


func kick(x: float, s: float) -> float:
	for k in kickers:
		var lip: float = k["lip"]
		var l: float = k["len"]
		if s > lip or s < lip - l:
			continue
		var du := absf(x - centre(s) - float(k["u"]))
		var hw: float = k["w"] * 0.5
		if du > hw + 0.8:
			continue
		var t := (s - (lip - l)) / l
		return float(k["h"]) * pow(t, 1.8) * clampf((hw + 0.8 - du) / 0.8, 0.0, 1.0)
	return 0.0


func normal(x: float, z: float) -> Vector3:
	var e := 0.3
	var hx := height(x + e, z) - height(x - e, z)
	var hz := height(x, z + e) - height(x, z - e)
	return Vector3(-hx, 2.0 * e, -hz).normalized()


func _mountain(x: float, z: float, u: float, s: float) -> float:
	## Away from the run the mountainside rolls in ridges and gullies; far off, a ring of
	## high peaks stands around the valley.
	var lat := maxf(absf(u) - 105.0, 0.0) + maxf(-PRE - s, 0.0) * 0.5
	var r := _ridge.get_noise_2d(x, z) * 0.5 + 0.5
	var h := lat * 0.06 + r * minf(lat * 0.18, 160.0)
	var d := Vector2(x, z + length * 0.5).length()
	h += smoothstep(1300.0, 3400.0, d) * (250.0 + 1500.0 * r * r)
	return h * smoothstep(0.0, 40.0, lat + maxf(d - 1300.0, 0.0))


# ---------------------------------------------------------------------- materials ----

func _make_materials() -> void:
	var tint: Color = map["snow_tint"]
	var snow := ShaderMaterial.new()
	snow.shader = preload("res://shaders/ski_terrain.gdshader")
	var g := RSPbr.maps("snow_02")
	var p := RSPbr.maps("snow_01")
	var r := RSPbr.maps("dark_rock_02")
	snow.set_shader_parameter("groom_alb", g[0])
	snow.set_shader_parameter("groom_nrm", g[1])
	snow.set_shader_parameter("groom_orm", g[2])
	snow.set_shader_parameter("powder_alb", p[0])
	snow.set_shader_parameter("powder_nrm", p[1])
	snow.set_shader_parameter("rock_alb", r[0])
	snow.set_shader_parameter("rock_nrm", r[1])
	snow.set_shader_parameter("rock_orm", r[2])
	snow.set_shader_parameter("snow_tint", tint)
	snow.set_shader_parameter("rock_amount", float(map["rocks"]) * 0.6 + 0.4)
	snow.set_shader_parameter("sparkle", 1.0 if float(map["sun_energy"]) > 1.0 else 0.35)
	_mats["snow"] = snow
	var far := snow.duplicate() as ShaderMaterial
	far.set_shader_parameter("far_fade", 1.0)
	far.set_shader_parameter("rock_amount", 1.0)
	far.set_shader_parameter("powder_size", 30.0)
	far.set_shader_parameter("rock_size", 60.0)
	far.set_shader_parameter("sparkle", 0.0)
	_mats["far"] = far
	var fir := ShaderMaterial.new()
	fir.shader = preload("res://shaders/snow_fir.gdshader")
	fir.set_shader_parameter("snow_tint", tint)
	fir.set_shader_parameter("needle_light", 0.8 if map["lights"] else 1.0)
	_mats["fir"] = fir
	_mats["vc"] = _vc_mat(0.6)
	_mats["vc_shiny"] = _vc_mat(0.3)
	_mats["wood"] = RSPbr.standard("beam_wall_01", 2.0)
	_mats["bark"] = RSPbr.standard("knotted_pine_bark", 1.5)
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(1.0, 0.85, 0.55)
	glow.emission_enabled = true
	glow.emission = Color(1.0, 0.72, 0.4)
	glow.emission_energy_multiplier = 3.0 if map["lights"] or float(map["sun_el"]) < 12.0 else 0.6
	_mats["window"] = glow
	var net := StandardMaterial3D.new()
	net.albedo_texture = _net_texture()
	net.albedo_color = Color(1.0, 0.32, 0.12)
	net.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	net.alpha_scissor_threshold = 0.5
	net.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
	net.cull_mode = BaseMaterial3D.CULL_DISABLED
	net.roughness = 0.7
	net.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_mats["net"] = net


func _vc_mat(roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = roughness
	return m


func _net_texture() -> ImageTexture:
	## Diamond mesh of a race net: one tile = 4 x 4 cells.
	var n := 64
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var a := fposmod(float(x + y) / 16.0, 1.0)
			var b := fposmod(float(x - y) / 16.0, 1.0)
			var line := minf(minf(a, 1.0 - a), minf(b, 1.0 - b)) < 0.09
			img.set_pixel(x, y, Color(1, 1, 1, 1.0 if line else 0.0))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


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
		if mat is ShaderMaterial or (mat is BaseMaterial3D and (mat as BaseMaterial3D).normal_enabled):
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


func _box(mat_name: String, xf: Transform3D, size: Vector3, color: Color = Color.WHITE, uv_scale: float = 1.0) -> void:
	## An axis box (in xf's frame) with planar UVs in metres.
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
			st.set_uv(uvs[i] * uv_scale)
			st.add_vertex(xf * (pts[i] as Vector3))


func _cyl(mat_name: String, a: Vector3, b: Vector3, r: float, color: Color, sides: int = 8) -> void:
	var st := _surf(mat_name)
	var y := (b - a).normalized()
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var n0 := x * cos(a0) + z * sin(a0)
		var n1 := x * cos(a1) + z * sin(a1)
		var quad := [[a + n0 * r, n0], [a + n1 * r, n1], [b + n1 * r, n1], [b + n0 * r, n0]]
		for k: int in [0, 1, 2, 0, 2, 3]:
			st.set_normal(quad[k][1])
			st.set_color(color)
			st.set_uv(Vector2(float(i) / sides, float(k > 1)))
			st.add_vertex(quad[k][0])


# ------------------------------------------------------------------------ terrain ----

func _columns() -> PackedFloat32Array:
	var wmax := 0.0
	for v in _hw:
		wmax = maxf(wmax, v)
	var inner := wmax + NET + 6.0
	var cols := PackedFloat32Array()
	var u := -SIDE
	while u < -inner:
		cols.append(u)
		u += 8.0 if u < -inner - 40.0 else 3.0
	u = -inner
	while u < inner:
		cols.append(u)
		u += 1.25
	u = inner
	while u < SIDE:
		cols.append(u)
		u += 3.0 if u < inner + 40.0 else 8.0
	cols.append(SIDE)
	return cols


func _build_terrain() -> void:
	## Rows across the run every 2 m, columns fine on the piste and coarse outside, skirts at
	## both edges; normals from the grid itself. Split into chunks so off-screen parts cull.
	var cols := _columns()
	var nc := cols.size() + 2
	var rows: Array[PackedVector3Array] = []
	var tints: Array[PackedColorArray] = []
	var s := -PRE
	while s <= length + POST:
		var pts := PackedVector3Array()
		var vcs := PackedColorArray()
		pts.resize(nc)
		vcs.resize(nc)
		var cx := centre(s)
		var hw := half_width(s)
		for j in cols.size():
			var x := cx + cols[j]
			pts[j + 1] = Vector3(x, ground(x, -s), -s)
			var e := absf(cols[j]) - hw
			var groomed := 1.0 - smoothstep(-0.5, 1.5, e)
			if (s > length - 5.0 and s < length + 90.0) or (s > -30.0 and s < 2.0):
				groomed = maxf(groomed, 1.0 - smoothstep(4.0, 10.0, e))
			vcs[j + 1] = Color(groomed, 0, 0)
		# Skirts hide the seam to the far mountains.
		pts[0] = pts[1] + Vector3(-0.5, -14.0, 0)
		pts[nc - 1] = pts[nc - 2] + Vector3(0.5, -14.0, 0)
		vcs[0] = vcs[1]
		vcs[nc - 1] = vcs[nc - 2]
		rows.append(pts)
		tints.append(vcs)
		s += 2.0
	var nr := rows.size()
	var nrm: Array[PackedVector3Array] = []
	for i in nr:
		var n := PackedVector3Array()
		n.resize(nc)
		var r0 := rows[maxi(i - 1, 0)]
		var r1 := rows[mini(i + 1, nr - 1)]
		var r := rows[i]
		for j in nc:
			var jj := clampi(j, 1, nc - 2)
			var dx := r[mini(jj + 1, nc - 2)] - r[maxi(jj - 1, 1)]
			var dz := r1[jj] - r0[jj]
			var v := dz.cross(dx).normalized()
			n[j] = v if v.y > 0.0 else -v
		nrm.append(n)
	var chunk := 0
	for i in nr - 1:
		var st := _surf("snow")
		var a := rows[i]
		var b := rows[i + 1]
		for j in nc - 1:
			var quad := [[a[j], tints[i][j], nrm[i][j]], [a[j + 1], tints[i][j + 1], nrm[i][j + 1]],
				[b[j + 1], tints[i + 1][j + 1], nrm[i + 1][j + 1]], [b[j], tints[i + 1][j], nrm[i + 1][j]]]
			for k: int in [0, 2, 1, 0, 3, 2]:
				var p: Vector3 = quad[k][0]
				st.set_color(quad[k][1])
				st.set_normal(quad[k][2])
				st.set_uv(Vector2(p.x, p.z))
				st.add_vertex(p)
		if (i + 1) % CHUNK_ROWS == 0 or i == nr - 2:
			_commit("snow_%d" % chunk)
			chunk += 1


func normal_ground(x: float, z: float) -> Vector3:
	var e := 0.6
	var hx := ground(x + e, z) - ground(x - e, z)
	var hz := ground(x, z + e) - ground(x, z - e)
	return Vector3(-hx, 2.0 * e, -hz).normalized()


func _build_far() -> void:
	## The valley walls and the peaks around, to the horizon; sunk a little where the near
	## terrain covers it.
	var step := 45.0
	var z0 := PRE + FAR * 0.5
	var z1 := -(length + POST + FAR)
	var nx := int(2.0 * FAR / step) + 1
	var nz := int((z0 - z1) / step) + 1
	var hs := PackedFloat32Array()
	hs.resize(nx * nz)
	var inside := PackedByteArray()
	inside.resize(nx * nz)
	for iz in nz:
		var z := z0 - iz * step
		for ix in nx:
			var x := -FAR + ix * step
			var u := x - centre(-z)
			var cov := absf(u) < SIDE - 4.0 and -z > -PRE + 4.0 and -z < length + POST - 4.0
			inside[iz * nx + ix] = 1 if cov else 0
			hs[iz * nx + ix] = ground(x, z) - (6.0 if cov else 0.0)
	var st := _surf("far")
	for iz in nz - 1:
		for ix in nx - 1:
			var ids := [iz * nx + ix, iz * nx + ix + 1, (iz + 1) * nx + ix + 1, (iz + 1) * nx + ix]
			if inside[ids[0]] and inside[ids[1]] and inside[ids[2]] and inside[ids[3]]:
				continue
			var ps := []
			for id: int in ids:
				var x := -FAR + (id % nx) * step
				var z := z0 - (id / nx) * step
				ps.append(Vector3(x, hs[id], z))
			for k: int in [0, 2, 1, 0, 3, 2]:
				var p: Vector3 = ps[k]
				var id: int = ids[k]
				var gx := hs[mini(id + 1, hs.size() - 1)] - hs[maxi(id - 1, 0)]
				var gz := hs[mini(id + nx, hs.size() - 1)] - hs[maxi(id - nx, 0)]
				st.set_normal(Vector3(-gx, 4.0 * step * 0.5, gz).normalized())
				st.set_color(Color(0, 0, 0))
				st.set_uv(Vector2(p.x, p.z))
				st.add_vertex(p)
	var mi := _commit("mountains", false)
	mi.extra_cull_margin = 200.0


# ----------------------------------------------------------------------- kickers ----

func _build_kickers() -> void:
	var lip_mat := StandardMaterial3D.new()
	lip_mat.albedo_color = Color(0.1, 0.35, 0.95)
	lip_mat.roughness = 0.6
	_mats["lip"] = lip_mat
	for k in kickers:
		var lip: float = k["lip"]
		var l: float = k["len"]
		var hw: float = k["w"] * 0.5 + 0.8
		var ku: float = k["u"]
		var ns := int(l / 0.5) + 1
		var nu := int(hw * 2.0 / 0.5) + 1
		var st := _surf("snow")
		var grid: Array = []
		for i in ns + 1:
			var s := lip - l + l * float(i) / ns
			var r: Array = []
			for j in nu + 1:
				var u := ku - hw + hw * 2.0 * float(j) / nu
				var x := centre(s) + u
				r.append(Vector3(x, height(x, -s) + 0.01, -s))
			grid.append(r)
		for i in ns:
			for j in nu:
				var q := [grid[i][j], grid[i][j + 1], grid[i + 1][j + 1], grid[i + 1][j]]
				var n := ((q[2] as Vector3) - (q[0] as Vector3)).cross((q[1] as Vector3) - (q[0] as Vector3)).normalized()
				if n.y < 0.0:
					n = -n
				for idx: int in [0, 2, 1, 0, 3, 2]:
					var p: Vector3 = q[idx]
					st.set_color(Color(1, 0, 0))
					st.set_uv(Vector2(p.x, p.z))
					st.set_normal(n)
					st.add_vertex(p)
		# The lip's face, down to the snow it drops onto.
		for j in nu:
			var a: Vector3 = grid[ns][j]
			var b: Vector3 = grid[ns][j + 1]
			var a0 := Vector3(a.x, ground(a.x, a.z - 0.02) - 0.3, a.z)
			var b0 := Vector3(b.x, ground(b.x, b.z - 0.02) - 0.3, b.z)
			for p: Vector3 in [a, b0, b, a, a0, b0]:
				st.set_color(Color(0.6, 0, 0))
				st.set_uv(Vector2(p.x, p.y))
				st.set_normal(Vector3(0, 0.2, -1).normalized())
				st.add_vertex(p)
		# A blue dye line along the lip, and marker poles with flags at its ends.
		var ls := _surf("lip")
		for j in nu:
			var a: Vector3 = grid[ns][j]
			var b: Vector3 = grid[ns][j + 1]
			var a1: Vector3 = (grid[ns - 1][j] as Vector3).lerp(a, 0.4)
			var b1: Vector3 = (grid[ns - 1][j + 1] as Vector3).lerp(b, 0.4)
			for p: Vector3 in [a1, a, b, a1, b, b1]:
				ls.set_normal(Vector3.UP)
				ls.add_vertex(p + Vector3(0, 0.012, 0))
		for side: float in [-1.0, 1.0]:
			var p := world(ku + side * (hw + 0.6), lip - 0.4)
			_cyl("vc_shiny", p, p + Vector3(0, 1.9, 0), 0.025, Color(1.0, 0.45, 0.05))
			_box("vc", Transform3D(Basis(), p + Vector3(side * 0.22, 1.65, 0)), Vector3(0.42, 0.28, 0.01), Color(1.0, 0.45, 0.05))
	_commit("kickers")


# ------------------------------------------------------------------------- gates ----

func _build_gates() -> void:
	var gap: float = map["gate_gap"]
	var gw: float = map["gate_w"]
	var s := 70.0
	var side := 1.0 if _rng.randf() < 0.5 else -1.0
	var color := 0
	while s < length - 70.0:
		var blocked := false
		for k in kickers:
			blocked = blocked or (s > float(k["lip"]) - float(k["len"]) - 18.0 and s < float(k["lip"]) + 58.0)
		if not blocked:
			var hw := half_width(s)
			var x := centre(s) + side * hw * 0.34 + _rng.randf_range(-1.0, 1.0)
			gates.append({"s": s, "x": x, "w": gw, "color": color, "side": side})
			side = -side
			color = 1 - color
		s += gap + _rng.randf_range(-4.0, 4.0)
	var reds := [Color(0.9, 0.08, 0.06), Color(0.06, 0.25, 0.9)]
	for g in gates:
		var gs: float = g["s"]
		var c: Color = reds[g["color"]]
		for side_i: float in [-1.0, 1.0]:
			# A panel between two poles at each side of the gate.
			var x: float = float(g["x"]) + side_i * float(g["w"])
			var x2 := x + side_i * 0.8
			for px: float in [x, x2]:
				var p := Vector3(px, height(px, -gs), -gs)
				_cyl("vc_shiny", p - Vector3(0, 0.2, 0), p + Vector3(0, 1.85, 0), 0.016, c, 6)
			var mid := Vector3((x + x2) * 0.5, height((x + x2) * 0.5, -gs) + 1.35, -gs)
			_box("vc", Transform3D(Basis(), mid), Vector3(0.78, 0.62, 0.012), c)
			_box("vc", Transform3D(Basis(), mid + Vector3(0, -0.06, 0)), Vector3(0.78, 0.09, 0.016), Color(0.96, 0.96, 0.96))
	_commit("gates")


# ----------------------------------------------------------------- nets / markers ----

func _build_nets() -> void:
	var post := Color(0.2, 0.2, 0.22)
	for side: float in [-1.0, 1.0]:
		var st := _surf("net")
		var s := -24.0
		var prev := Vector3.ZERO
		var first := true
		var dist := 0.0
		while s < length + 40.0:
			var u := side * bound(s)
			var x := centre(s) + u
			var p := Vector3(x, ground(x, -s), -s)
			if not first:
				dist += prev.distance_to(p)
				var span := prev.distance_to(p)
				var q := [prev, p, p + Vector3(0, 1.5, 0), prev + Vector3(0, 1.5, 0)]
				var uv := [Vector2(dist - span, 1.5), Vector2(dist, 1.5), Vector2(dist, 0), Vector2(dist - span, 0)]
				var n := ((p - prev).cross(Vector3.UP)).normalized() * -side
				for k: int in [0, 1, 2, 0, 2, 3]:
					st.set_normal(n)
					st.set_uv((uv[k] as Vector2) * 2.0)
					st.add_vertex(q[k])
			if int(s) % 4 == 0 or first:
				_cyl("vc", p - Vector3(0, 0.3, 0), p + Vector3(0, 1.6, 0), 0.03, post, 6)
			prev = p
			first = false
			s += 4.0
	_commit("nets", false)


func _build_markers() -> void:
	## Piste poles along the edges, coloured by difficulty, with orange tops.
	var colors := [Color(0.1, 0.35, 0.95), Color(0.1, 0.35, 0.95), Color(0.1, 0.35, 0.95), Color(0.9, 0.12, 0.1), Color(0.06, 0.06, 0.07), Color(0.06, 0.06, 0.07)]
	var c: Color = colors[int(map["stars"])]
	var s := 20.0
	while s < length - 40.0:
		for side: float in [-1.0, 1.0]:
			var p := world(side * (bound(s) + 2.5), s)
			_cyl("vc_shiny", p - Vector3(0, 0.3, 0), p + Vector3(0, 1.4, 0), 0.03, c, 6)
			_cyl("vc_shiny", p + Vector3(0, 1.4, 0), p + Vector3(0, 1.9, 0), 0.03, Color(1.0, 0.45, 0.05), 6)
		s += 30.0
	_commit("markers")


# ------------------------------------------------------------------------- trees ----

func _build_trees() -> void:
	RSSkiTrees.build(self, _mats["fir"], _lift_u())


func _build_rocks() -> void:
	var amount: float = map["rocks"]
	var xfs: Array = []
	for i in int(70 * amount):
		var s := _rng.randf_range(0.0, length)
		var side := -1.0 if _rng.randf() < 0.5 else 1.0
		var u := side * (bound(s) + _rng.randf_range(4.0, 40.0))
		var x := centre(s) + u
		var sc := _rng.randf_range(0.8, 2.6)
		xfs.append(Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * sc), Vector3(x, ground(x, -s) - 0.35 * sc, -s)))
	RSProps.place(self, "nature_boulder", xfs)


# --------------------------------------------------------------------- start area ----

func _build_start() -> void:
	# Start hut behind the start line, the start wand, and a banner arch.
	_chalet(world(-7.5, -16.0), Vector3(5.0, 3.2, 4.0), PI * 0.5, false)
	for side: float in [-1.0, 1.0]:
		var p := world(side * 4.6, 0.0)
		_box("vc_shiny", Transform3D(Basis(), p + Vector3(0, 0.55, 0)), Vector3(0.18, 1.1, 0.18), Color(0.85, 0.86, 0.9))
	_arch(9.0, "START  起点", Color(0.95, 0.42, 0.18))   # no-i18n: bilingual sign in the world
	_commit("start")


func _arch(s: float, text: String, color: Color) -> void:
	var hw := half_width(s) + 1.2
	var y := maxf(height(centre(s) - hw, -s), height(centre(s) + hw, -s))
	var c := centre(s)
	for side: float in [-1.0, 1.0]:
		var p := Vector3(c + side * hw, height(c + side * hw, -s), -s)
		_box("vc_shiny", Transform3D(Basis(), Vector3(p.x, (p.y + y + 6.6) * 0.5 - 0.3, p.z)), Vector3(0.6, y + 6.6 - p.y + 0.6, 0.6), Color(0.12, 0.13, 0.17))
	_box("vc_shiny", Transform3D(Basis(), Vector3(c, y + 6.4, -s)), Vector3(hw * 2.0 + 1.4, 1.4, 0.4), color)
	for face: float in [1.0, -1.0]:
		var label := Label3D.new()
		label.text = text
		label.font = RSUi.font()
		label.font_size = 110
		label.pixel_size = 0.01
		label.outline_size = 24
		label.modulate = Color.WHITE
		label.outline_modulate = color.darkened(0.6)
		label.position = Vector3(c, y + 6.4, -s + face * 0.22)
		label.rotation.y = 0.0 if face > 0.0 else PI
		add_child(label)


# -------------------------------------------------------------------- finish area ----

func _build_finish() -> void:
	_arch(length, "FINISH  终点", Color(0.1, 0.12, 0.16))   # no-i18n: bilingual sign in the world
	# Checkered strip across the finish line.
	var hw := half_width(length) + 1.0
	for i in int(hw * 2.0 / 0.5):
		var u := -hw + i * 0.5
		var p := world(u + 0.25, length, 0.02)
		_box("vc", Transform3D(Basis(), p), Vector3(0.5, 0.02, 0.5), Color(0.05, 0.05, 0.06) if i % 2 == 0 else Color(0.95, 0.95, 0.95))
		_box("vc", Transform3D(Basis(), p + Vector3(0, 0, -0.5)), Vector3(0.5, 0.02, 0.5), Color(0.95, 0.95, 0.95) if i % 2 == 0 else Color(0.05, 0.05, 0.06))
	# Fences with sponsor-style boards along the arena, crowd behind them.
	var crowd: Array[Transform3D] = []
	var board_colors := [Color(0.95, 0.42, 0.18), Color(0.1, 0.35, 0.9), Color(0.96, 0.96, 0.96), Color(0.9, 0.12, 0.15)]
	for side: float in [-1.0, 1.0]:
		var s := length - 45.0
		var bi := 0
		while s < length + 60.0:
			var u := side * (half_width(s) + 1.6)
			var p := world(u, s)
			var yaw := heading_at(s)
			_box("vc_shiny", Transform3D(Basis(Vector3.UP, yaw), p + Vector3(0, 0.45, 0)), Vector3(0.06, 0.9, 2.3), board_colors[bi % 4])
			bi += 1
			for row in 3:
				var cu := u + side * (1.0 + row * 0.8 + _rng.randf_range(-0.1, 0.1))
				var cs := s + _rng.randf_range(-0.6, 0.6)
				var face := Basis(Vector3.UP, -side * PI * 0.5 + _rng.randf_range(-0.5, 0.5) + yaw)
				crowd.append(Transform3D(face.scaled(Vector3.ONE * _rng.randf_range(0.9, 1.08)), world(cu, cs, row * 0.25)))
			s += 2.4
	_commit("finish")
	RSCrowd.place(self, crowd, _rng, [Color(0.95, 0.3, 0.3), Color(0.2, 0.5, 0.95), Color(1.0, 0.8, 0.2), Color(0.12, 0.13, 0.16),
		Color(0.95, 0.95, 0.95), Color(0.6, 0.35, 0.8), Color(1.0, 0.55, 0.2), Color(0.2, 0.7, 0.45)])
	# Timing board on the left of the line, facing up the hill.
	var bp := world(-(half_width(length) + 5.0), length + 6.0)
	_box("vc_shiny", Transform3D(Basis(), bp + Vector3(0, 2.6, 0)), Vector3(0.3, 5.2, 0.3), Color(0.12, 0.13, 0.17))
	_box("vc_shiny", Transform3D(Basis(Vector3.UP, 0.35), bp + Vector3(0, 5.6, 0)), Vector3(5.4, 3.0, 0.35), Color(0.03, 0.03, 0.04))
	_commit("timing_board")
	_board = Label3D.new()
	_board.font = RSUi.font()
	_board.font_size = 64
	_board.pixel_size = 0.009
	_board.modulate = Color(1.0, 0.85, 0.3)
	_board.outline_size = 0
	_board.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_board.width = 540
	_board.autowrap_mode = TextServer.AUTOWRAP_OFF
	_board.position = bp + Vector3(0, 5.6, 0) + Basis(Vector3.UP, 0.35) * Vector3(0, 0, 0.19)
	_board.rotation.y = 0.35
	_board.text = map["en"]
	add_child(_board)


func set_board(text: String) -> void:
	if _board:
		_board.text = text


# ------------------------------------------------------------------------ village ----

func _chalet(at: Vector3, size: Vector3, yaw: float, lit: bool = true) -> void:
	## Timber chalet: log walls, windows, a deep snowy gable roof and a stone chimney.
	var b := Basis(Vector3.UP, yaw)
	var base_xf := Transform3D(b, at)
	_box("vc", base_xf * Transform3D(Basis(), Vector3(0, 0.25, 0)), Vector3(size.x + 0.3, 0.9, size.z + 0.3), Color(0.42, 0.42, 0.44))
	_box("wood", base_xf * Transform3D(Basis(), Vector3(0, size.y * 0.5 + 0.6, 0)), Vector3(size.x, size.y, size.z), Color.WHITE, 0.5)
	# Windows on the long sides, a door on one end.
	for side: float in [-1.0, 1.0]:
		var nw := maxi(1, int(size.x / 2.2))
		for i in nw:
			var wx := -size.x * 0.5 + size.x * (i + 0.5) / nw
			var wp := Vector3(wx, size.y * 0.55 + 0.6, side * (size.z * 0.5 + 0.02))
			_box("vc", base_xf * Transform3D(Basis(), wp), Vector3(0.95, 1.05, 0.06), Color(0.25, 0.16, 0.1))
			_box("window" if lit else "vc_shiny", base_xf * Transform3D(Basis(), wp + Vector3(0, 0, side * 0.02)), Vector3(0.75, 0.85, 0.05), Color(0.2, 0.25, 0.3))
	_box("vc", base_xf * Transform3D(Basis(), Vector3(size.x * 0.5 + 0.02, 1.6, 0)), Vector3(0.06, 2.0, 1.0), Color(0.3, 0.18, 0.1))
	# Gable roof: two sloped slabs with snow on them.
	var rise := size.z * 0.42
	var half_z := size.z * 0.5 + 0.9
	var slope_len := sqrt(half_z * half_z + rise * rise)
	var ang := atan2(rise, half_z)
	var top_y := size.y + 0.6 + rise
	for side: float in [-1.0, 1.0]:
		var rb := Basis(Vector3.RIGHT, side * ang)
		var centre_p := Vector3(0, top_y - rise * 0.5, side * half_z * 0.5)
		_box("vc", base_xf * Transform3D(rb, centre_p), Vector3(size.x + 1.4, 0.18, slope_len), Color(0.28, 0.18, 0.12))
		_box("vc", base_xf * Transform3D(rb, centre_p + rb * Vector3(0, 0.2, 0)), Vector3(size.x + 1.3, 0.26, slope_len - 0.1), Color(0.96, 0.97, 1.0))
	# Gable ends.
	for side: float in [-1.0, 1.0]:
		var st := _surf("wood")
		var x := side * size.x * 0.5
		var pts := [base_xf * Vector3(x, size.y + 0.6, -size.z * 0.5), base_xf * Vector3(x, size.y + 0.6, size.z * 0.5), base_xf * Vector3(x, top_y, 0)]
		var n := b * Vector3(side, 0, 0)
		var order := [0, 2, 1] if side < 0.0 else [0, 1, 2]
		for k: int in order:
			st.set_normal(n)
			st.set_color(Color.WHITE)
			var p: Vector3 = pts[k]
			st.set_uv(Vector2(p.z, -p.y) * 0.5)
			st.add_vertex(p)
	_box("vc", base_xf * Transform3D(Basis(), Vector3(size.x * 0.3, top_y, size.z * 0.15)), Vector3(0.6, 1.6, 0.6), Color(0.45, 0.43, 0.42))
	_box("vc", base_xf * Transform3D(Basis(), Vector3(size.x * 0.3, top_y + 0.85, size.z * 0.15)), Vector3(0.7, 0.15, 0.7), Color(0.96, 0.97, 1.0))


func _build_village() -> void:
	var placed := 0
	var tries := 0
	while placed < 14 and tries < 200:
		tries += 1
		var s := _rng.randf_range(length + 70.0, length + POST - 40.0)
		var side := -1.0 if _rng.randf() < 0.5 else 1.0
		var u := side * _rng.randf_range(12.0, 70.0)
		var p := world(u, s)
		if absf(height(p.x - 5, p.z) - height(p.x + 5, p.z)) > 3.0:
			continue
		var size := Vector3(_rng.randf_range(7.0, 11.0), _rng.randf_range(3.0, 5.5), _rng.randf_range(6.0, 8.5))
		_chalet(p - Vector3(0, 0.5, 0), size, _rng.randf_range(-0.3, 0.3) + (PI * 0.5 if _rng.randf() < 0.3 else 0.0))
		placed += 1
	# A few chalets up the slopes beside the run.
	for i in 6:
		var s := _rng.randf_range(80.0, length - 120.0)
		var side := -1.0 if i % 2 == 0 else 1.0
		var p := world(side * (bound(s) + _rng.randf_range(10.0, 18.0)), s)
		_chalet(p - Vector3(0, 0.6, 0), Vector3(8.0, 3.5, 6.5), heading_at(s) + PI * 0.5)
	_commit("village")


# --------------------------------------------------------------------------- lift ----

func _lift_u() -> float:
	return -(float(map["half_width"]) + 30.0)


func _build_lift() -> void:
	## A chairlift up the left side: pylons, two cable lines, chairs going round.
	var u := _lift_u()
	var tops: Array[Vector3] = []
	var s := length + 20.0
	while s > -40.0:
		var x := centre(s) + u
		tops.append(Vector3(x, ground(x, -s) + 11.0, -s))
		s -= 60.0
	var steel := Color(0.55, 0.57, 0.6)
	for t in tops:
		var g := Vector3(t.x, ground(t.x, t.z) - 0.5, t.z)
		_cyl("vc_shiny", g, t, 0.35, steel, 10)
		_box("vc_shiny", Transform3D(Basis(), t + Vector3(0, 0.3, 0)), Vector3(5.2, 0.35, 0.5), Color(0.9, 0.3, 0.12))
		for side: float in [-1.0, 1.0]:
			_box("vc_shiny", Transform3D(Basis(), t + Vector3(side * 2.2, -0.05, 0)), Vector3(0.25, 0.3, 2.0), Color(0.15, 0.15, 0.17))
	# Stations at both ends.
	for i: int in [0, tops.size() - 1]:
		var t: Vector3 = tops[i]
		var g := Vector3(t.x, ground(t.x, t.z), t.z)
		_box("vc_shiny", Transform3D(Basis(), g + Vector3(0, 2.5, 0)), Vector3(7.0, 5.0, 9.0), Color(0.82, 0.83, 0.86))
		_box("vc", Transform3D(Basis(), g + Vector3(0, 5.2, 0)), Vector3(7.6, 0.5, 9.6), Color(0.96, 0.97, 1.0))
		_box("vc_shiny", Transform3D(Basis(), g + Vector3(0, 6.0, 0)), Vector3(6.0, 1.4, 1.4), Color(0.9, 0.3, 0.12))
	# Cable loop: up on the right line, back down on the left, sagging between pylons.
	var up: Array[Vector3] = []
	for i in tops.size() - 1:
		for k in 8:
			var f := float(k) / 8.0
			var p: Vector3 = (tops[i] as Vector3).lerp(tops[i + 1], f)
			p.y -= sin(PI * f) * 1.6
			up.append(p)
	up.append(tops[-1])
	for p in up:
		_lift_pts.append(p + Vector3(2.2, -0.2, 0))
	for i in range(up.size() - 1, -1, -1):
		_lift_pts.append(up[i] + Vector3(-2.2, -0.2, 0))
	_lift_pts.append(_lift_pts[0])
	_lift_cum.append(0.0)
	for i in range(1, _lift_pts.size()):
		_lift_cum.append(_lift_cum[i - 1] + _lift_pts[i - 1].distance_to(_lift_pts[i]))
	for i in _lift_pts.size() - 1:
		_cyl("vc_shiny", _lift_pts[i], _lift_pts[i + 1], 0.025, Color(0.2, 0.2, 0.22), 4)
	_commit("lift", false)
	# Chairs.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seat := BoxMesh.new()
	seat.size = Vector3(1.9, 0.12, 0.55)
	var back := BoxMesh.new()
	back.size = Vector3(1.9, 0.6, 0.1)
	var hanger := BoxMesh.new()
	hanger.size = Vector3(0.06, 2.2, 0.06)
	var bar := BoxMesh.new()
	bar.size = Vector3(1.9, 0.05, 0.05)
	st.append_from(hanger, 0, Transform3D(Basis(), Vector3(0, -1.1, 0)))
	st.append_from(seat, 0, Transform3D(Basis(), Vector3(0, -2.25, 0.05)))
	st.append_from(back, 0, Transform3D(Basis(), Vector3(0, -1.95, 0.3)))
	st.append_from(bar, 0, Transform3D(Basis(), Vector3(0, -1.6, -0.3)))
	var chair := st.commit()
	var cm := StandardMaterial3D.new()
	cm.albedo_color = Color(0.15, 0.17, 0.22)
	cm.metallic = 0.6
	cm.roughness = 0.4
	chair.surface_set_material(0, cm)
	_chairs = MultiMesh.new()
	_chairs.transform_format = MultiMesh.TRANSFORM_3D
	_chairs.mesh = chair
	_chairs.instance_count = int(_lift_cum[_lift_cum.size() - 1] / 22.0)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _chairs
	add_child(mmi)
	_process(0.0)


func _chair_xf(d: float) -> Transform3D:
	var i := _lift_cum.bsearch(d) - 1
	i = clampi(i, 0, _lift_pts.size() - 2)
	var a := _lift_pts[i]
	var b := _lift_pts[i + 1]
	var f := clampf((d - _lift_cum[i]) / maxf(_lift_cum[i + 1] - _lift_cum[i], 1e-3), 0.0, 1.0)
	var dir := Vector3(b.x - a.x, 0, b.z - a.z)
	var yaw := atan2(-dir.x, -dir.z) if dir.length() > 1e-3 else 0.0
	return Transform3D(Basis(Vector3.UP, yaw), a.lerp(b, f))


# -------------------------------------------------------------------- floodlights ----

func _build_floodlights() -> void:
	var s := 10.0
	var side := 1.0
	var steel := Color(0.4, 0.42, 0.45)
	var head := StandardMaterial3D.new()
	head.albedo_color = Color(1, 1, 1)
	head.emission_enabled = true
	head.emission = Color(1.0, 0.95, 0.85)
	head.emission_energy_multiplier = 12.0
	_mats["lamp"] = head
	while s < length + 40.0:
		var u := side * (bound(s) + 5.0)
		var g := world(u, s)
		var top := g + Vector3(0, 15.0, 0)
		_cyl("vc_shiny", g - Vector3(0, 0.5, 0), top, 0.22, steel, 8)
		var toward := Vector3(-side, 0, 0)
		_box("vc_shiny", Transform3D(Basis(), top + Vector3(0, 0.2, 0) + toward * 0.6), Vector3(1.8, 0.2, 0.6), steel)
		for k in 3:
			_box("lamp", Transform3D(Basis(Vector3.BACK, side * 0.6), top + toward * (0.2 + k * 0.6) + Vector3(0, -0.1, 0)), Vector3(0.5, 0.12, 0.45), Color.WHITE)
		var spot := SpotLight3D.new()
		spot.light_color = Color(1.0, 0.94, 0.84)
		spot.light_energy = 9.0
		spot.spot_range = 75.0
		spot.spot_angle = 52.0
		spot.spot_attenuation = 0.6
		spot.shadow_enabled = false
		var aim := world(-side * 3.0, s + 18.0)
		spot.position = top + toward * 0.8
		add_child(spot)
		spot.look_at(aim)
		side = -side
		s += 42.0
	_commit("floodlights", false)


# -------------------------------------------------------------------- environment ----

func setup_environment(parent: Node) -> DirectionalLight3D:
	return RSSkiEnvironment.setup(parent, map)
