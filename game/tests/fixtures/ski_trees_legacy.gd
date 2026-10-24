class_name RSSkiTreesLegacy
extends RefCounted
## Frozen tree builder from dev cd8f70f, used only by test_ski_trees.
## Its mesh/layout RNG consumption and batch order are the compatibility oracle.

var batches: Array[Dictionary] = []
var _mats := {}


func _fir_mesh(rng: RandomNumberGenerator, tall: float, tiers: int, lobes: int) -> ArrayMesh:
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
	mesh.surface_set_material(0, _mats["fir"])
	return mesh


func build(course: RSSkiCourse, material: Material) -> void:
	_mats["fir"] = material
	var map := course.map
	var length := course.length
	var density: float = map["trees"]
	if density <= 0.0:
		return
	var trng := RandomNumberGenerator.new()
	trng.seed = int(map["seed"]) * 31
	var meshes: Array[ArrayMesh] = []
	for v in 4:
		meshes.append(_fir_mesh(trng, [13.0, 10.0, 16.0, 7.0][v], [9, 8, 10, 6][v], [9, 8, 10, 7][v]))
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
			if map["lift"] and absf(u - course._lift_u()) < 6.0:
				continue
			if absf(u) < edge:
				continue
			var x := course.centre(s) + u
			var y := course.ground(x, -s)
			var sc := trng.randf_range(0.75, 1.3)
			var xf := Transform3D(Basis(Vector3.UP, trng.randf() * TAU).scaled(Vector3(sc, sc * trng.randf_range(0.9, 1.15), sc)), Vector3(x, y, -s))
			per[trng.randi_range(0, 3)].append(xf)
		for v in 4:
			_multimesh(meshes[v], per[v], "firs")
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
	_multimesh(meshes[3], far, "far_firs", false)


func _multimesh(mesh: Mesh, xfs: Array, node_name: String, shadows: bool = true) -> void:
	if not xfs.is_empty():
		batches.append({"mesh": mesh, "xfs": xfs, "name": node_name, "shadows": shadows})
