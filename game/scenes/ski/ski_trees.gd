class_name RSSkiTrees
extends RefCounted
## Ski-course fir geometry and manual LOD. Layout draws and instance order match the
## original 150 m batches: snow_fir uses INSTANCE_ID for its fine surface noise.
## Distances are world metres. The renderer evaluates each visibility dependency per
## camera, including split-screen and the lobby; no per-frame script or setting change.

const HEIGHTS := [13.0, 10.0, 16.0, 7.0]
const TIERS := [9, 8, 10, 6]
const LOBES := [9, 8, 10, 7]
const LOW_LOBES := 4
const NEAR_DISTANCE := 250.0       ## keep every tree in this radius fully detailed
const FADE_MARGIN := 40.0          ## renderer's begin margin on either side of threshold


static func fir_mesh(rng: RandomNumberGenerator, tall: float, tiers: int, lobes: int, material: Material) -> ArrayMesh:
	## A snow-laden fir: a bark trunk and stacked drooping tiers with jagged edges. Vertex
	## alpha = snow cover (tops of the tiers under snow, undersides green).
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var green := Color(0.06, 0.13, 0.08).lerp(Color(0.1, 0.17, 0.09), rng.randf())
	var bark := Color(0.2, 0.14, 0.1)
	var r0 := tall * rng.randf_range(0.2, 0.26)
	# Trunk.
	var tr := tall * 0.022 + 0.05
	for i in 6:
		var a0 := TAU * i / 6.0
		var a1 := TAU * (i + 1) / 6.0
		var p := [Vector3(cos(a0) * tr, -0.3, sin(a0) * tr), Vector3(cos(a1) * tr, -0.3, sin(a1) * tr),
			Vector3(cos(a1) * tr * 0.3, tall * 0.9, sin(a1) * tr * 0.3), Vector3(cos(a0) * tr * 0.3, tall * 0.9, sin(a0) * tr * 0.3)]
		for k: int in [0, 1, 2, 0, 2, 3]:
			var v: Vector3 = p[k]
			st.set_color(Color(bark, 0.0))
			st.set_normal(Vector3(v.x, 0, v.z).normalized())
			st.set_uv(Vector2(float(i) / 6.0, v.y))
			st.add_vertex(v)
	for t in tiers:
		var f := float(t) / tiers
		var y_base := tall * lerpf(0.1, 0.84, f)
		var rad := r0 * pow(1.0 - f, 0.95) + 0.22
		var y_top := y_base + tall * 0.15 * (1.0 - 0.4 * f) + 0.15
		var droop := rad * 0.32
		var turn := rng.randf() * TAU
		var ring: Array[Vector3] = []
		var n := lobes * 2
		for j in n:
			var a := turn + TAU * j / n
			var tip := j % 2 == 0
			var rr := rad * (1.0 if tip else 0.72) * rng.randf_range(0.88, 1.1)
			var yy := y_base - (droop if tip else droop * 0.5) + rng.randf_range(-0.06, 0.06)
			ring.append(Vector3(cos(a) * rr, yy, sin(a) * rr))
		var apex := Vector3(0, y_top, 0)
		var under := Vector3(0, y_base + (y_top - y_base) * 0.25, 0)
		for j in n:
			var a: Vector3 = ring[j]
			var b: Vector3 = ring[(j + 1) % n]
			# Snow on top: thick near the trunk, thinner toward the tips.
			var nt := (b - apex).cross(a - apex).normalized()
			if nt.y < 0.0:
				nt = -nt
			var snow_tip := 0.62 if j % 2 == 0 else 0.5
			for v: Vector3 in [apex, a, b]:
				var al := 1.0 if v == apex else snow_tip
				st.set_color(Color(green, al))
				st.set_normal((nt + Vector3(v.x, 0, v.z).normalized() * 0.5).normalized())
				st.set_uv(Vector2(v.x, v.z))
				st.add_vertex(v)
			var nu := (a - under).cross(b - under).normalized()
			if nu.y > 0.0:
				nu = -nu
			for v: Vector3 in [under, b, a]:
				st.set_color(Color(green * 0.8, 0.0))
				st.set_normal((nu + Vector3(v.x, 0, v.z).normalized() * 0.8).normalized())
				st.set_uv(Vector2(v.x, v.z))
				st.add_vertex(v)
	st.generate_tangents()
	var mesh := st.commit()
	mesh.surface_set_material(0, material)
	return mesh


static func generate(course: RSSkiCourse, material: Material, lift_u: float) -> Array[Dictionary]:
	## CPU batches are also the regression/export data; the upload below never reorders them.
	var batches: Array[Dictionary] = []
	var map := course.map
	var length := course.length
	var density: float = map["trees"]
	if density <= 0.0:
		return batches
	var trng := RandomNumberGenerator.new()
	trng.seed = int(map["seed"]) * 31
	var meshes: Array[ArrayMesh] = []
	var low_meshes: Array[ArrayMesh] = []
	for v in 4:
		# The low mesh gets a private copy: its random draws must never move a tree.
		var low_rng := RandomNumberGenerator.new()
		low_rng.seed = trng.seed
		low_rng.state = trng.state
		meshes.append(fir_mesh(trng, HEIGHTS[v], TIERS[v], LOBES[v], material))
		low_meshes.append(fir_mesh(low_rng, HEIGHTS[v], TIERS[v], LOW_LOBES, material))
	var tree_line: float = map["tree_line"]
	var chunk := 150.0
	var c0 := -RSSkiCourse.PRE
	while c0 < length + RSSkiCourse.POST:
		var per: Array = [[], [], [], []]
		var count := int(chunk * 2.0 * density)
		for i in count:
			var s := c0 + trng.randf() * chunk
			if s > length + RSSkiCourse.POST or (tree_line > 0.0 and s < tree_line):
				continue
			var side := -1.0 if trng.randf() < 0.5 else 1.0
			var edge := course.bound(s) + 3.5
			if s > length - 70.0 and s < length + 110.0:
				edge += 30.0                     # finish arena and village stay open
			var u := side * (edge + pow(trng.randf(), 1.7) * (RSSkiCourse.SIDE - 8.0 - edge))
			if map["lift"] and absf(u - lift_u) < 6.0:
				continue
			if absf(u) < edge:
				continue
			var x := course.centre(s) + u
			var y := course.ground(x, -s)
			var sc := trng.randf_range(0.75, 1.3)
			var xf := Transform3D(Basis(Vector3.UP, trng.randf() * TAU).scaled(Vector3(sc, sc * trng.randf_range(0.9, 1.15), sc)), Vector3(x, y, -s))
			per[trng.randi_range(0, 3)].append(xf)
		for v in 4:
			if not per[v].is_empty():
				batches.append({"mesh": meshes[v], "low": low_meshes[v], "xfs": per[v], "name": "firs", "shadows": true})
		c0 += chunk
	# The far slopes: sparse, smaller copies up to where the rock starts.
	var far: Array = []
	for i in int(2600 * density):
		var s := trng.randf_range(-RSSkiCourse.PRE - 300.0, length + RSSkiCourse.POST + 300.0)
		if tree_line > 0.0 and s < tree_line:
			continue
		var u := (-1.0 if trng.randf() < 0.5 else 1.0) * trng.randf_range(RSSkiCourse.SIDE, 900.0)
		var x := course.centre(clampf(s, -RSSkiCourse.PRE, length + RSSkiCourse.POST)) + u
		var y := course.ground(x, -s)
		if y - course.base(clampf(s, -RSSkiCourse.PRE, length + RSSkiCourse.POST)) > 260.0:
			continue
		var sc := trng.randf_range(1.0, 1.6)
		far.append(Transform3D(Basis(Vector3.UP, trng.randf() * TAU).scaled(Vector3.ONE * sc), Vector3(x, y - 0.5, -s)))
	if not far.is_empty():
		batches.append({"mesh": meshes[3], "low": null, "xfs": far, "name": "far_firs", "shadows": false})
	return batches


static func build(course: RSSkiCourse, material: Material, lift_u: float) -> void:
	for batch: Dictionary in generate(course, material, lift_u):
		if batch["low"] == null:
			_multimesh(course, batch["mesh"], batch["xfs"], batch["name"], batch["shadows"])
		else:
			_lod_pair(course, batch["mesh"], batch["low"], batch["xfs"])


static func mesh_bounds(mesh: ArrayMesh) -> AABB:
	## Calculate bounds from the source vertices without a RenderingServer readback.
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var bounds := AABB(vertices[0], Vector3.ZERO)
	for vertex: Vector3 in vertices:
		bounds = bounds.expand(vertex)
	return bounds


static func _batch_bounds(high: ArrayMesh, low: ArrayMesh, xfs: Array) -> AABB:
	var high_bounds := mesh_bounds(high)
	var low_bounds := mesh_bounds(low)
	var bounds: AABB = (xfs[0] as Transform3D) * high_bounds
	for xf: Transform3D in xfs:
		bounds = bounds.merge(xf * high_bounds).merge(xf * low_bounds)
	return bounds


static func _lod_pair(parent: Node3D, high: ArrayMesh, low: ArrayMesh, xfs: Array) -> void:
	if xfs.is_empty():
		return
	var detail := _multimesh(parent, high, xfs, "firs")
	var coarse := _multimesh(parent, low, xfs, "fir_lod")
	# The same centre and conservative bounds are essential: a large batch must not
	# switch just because its centre is far away while its nearest tree is beside us.
	var bounds := _batch_bounds(high, low, xfs)
	detail.multimesh.custom_aabb = bounds
	coarse.multimesh.custom_aabb = bounds
	coarse.visibility_range_begin = NEAR_DISTANCE + bounds.size.length() * 0.5 + FADE_MARGIN
	coarse.visibility_range_begin_margin = FADE_MARGIN
	coarse.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES
	# Siblings share the original course-space transforms and INSTANCE_ID sequence.
	# Let the renderer cross-fade dependencies instead of toggling shared visibility.
	detail.visibility_parent = NodePath("../" + str(coarse.name))


static func _multimesh(parent: Node3D, mesh: Mesh, xfs: Array, node_name: String, shadows: bool = true) -> MultiMeshInstance3D:
	if xfs.is_empty():
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mmi)
	return mmi
