class_name RSGolfCourse
extends Node3D
## A three-hole golf course (par 4, 3, 5 in some order) built from a few hand-placed features
## per hole: a fairway centreline with half-widths, an elliptical green, bunkers, ponds. The
## features are rasterized once into signed-distance fields (1 m texels, RGBA: fairway, green,
## bunker, water), which both the ball physics (surface_at) and the terrain shader read, so the
## lies the ball gets are the ones you see. The heightfield (2.5 m grid) is noise shaped by the
## same fields: flat tees, raised tilted greens, bunker bowls with a lip, ponds, links dunes or
## parkland mounds; it is drawn as chunked meshes, and height_at() interpolates the same grid.
## Trees are baked impostors (shaders/impostor.gdshader), scattered outside the lines of play;
## their canopies slow and knock down balls (tree_hit).
##
## World axes: metres, y up. Feature coordinates are Vector2(x, z).

enum Lie { TEE, FAIRWAY, FIRST_CUT, ROUGH, GREEN, FRINGE, BUNKER, WATER, OB }

const LIE_NAMES := ["发球台", "球道", "浅长草", "长草", "果岭", "果岭边", "沙坑", "水障碍", "界外"]
const CELL := RSGolfSurface.CELL  ## unchanged coarse heightfield grid, m
const SDF := 1.0                 ## surface field texel, m
const SDF_RANGE := 12.0          ## field values are clamped to +-this many metres
const LINE_RANGE := 90.0         ## the line-of-play distance field reaches this far
const TREE_CELL := 20.0
const CHUNK := 48                ## heightfield cells per mesh chunk side
const MARGIN := 170.0            ## terrain beyond the features' bounds
const OB_FROM_FAIRWAY := 62.0    ## further than this from every fairway and green = out of bounds
const CUP_R := 0.054
const TREE_DIR := "res://assets/golf/trees/"

const MAPS := [
	{"name": "海岸林克斯", "en": "Coastal Links", "links": true,
		"desc": "海边的林克斯球场：起伏的沙丘、深草、风大，球落地会滚很远。",
		"hdri": "res://assets/polyhaven/hdris/kloofendal_48d_partly_cloudy_puresky/kloofendal_48d_partly_cloudy_puresky_4k.hdr",
		"sky_energy": 1.0, "sky_rot": 0.6, "exposure": 0.95, "ambient": 0.9,
		"fog": Color(0.72, 0.8, 0.88), "fog_density": 0.0009,
		"sun_az": 215.0, "sun_el": 38.0, "sun_color": Color(1.0, 0.96, 0.9), "sun_energy": 1.5, "shadow_blur": 1.2,
		"rough": "withered_grass", "sand": "coast_sand_01", "trees": ["fir_b", "fir_c", "island02"],
		"tree_density": 0.28, "wind": [3.0, 7.5], "ambience": "links_amb", "tee_color": Color(0.95, 0.95, 0.92),
		"grass": Color(0.27, 0.42, 0.14), "green": Color(0.2, 0.43, 0.13), "rough_tint": Color(0.75, 0.72, 0.5)},
	{"name": "夕阳庄园", "en": "Sunset Parkland", "links": false,
		"desc": "林木环绕的庄园球场：成片的树林、湖泊和小溪，傍晚的阳光。",
		"hdri": "res://assets/polyhaven/hdris/belfast_sunset_puresky/belfast_sunset_puresky_4k.hdr",
		"sky_energy": 1.0, "sky_rot": 2.3, "exposure": 1.0, "ambient": 0.7,
		"fog": Color(0.95, 0.75, 0.55), "fog_density": 0.0012,
		"sun_az": 290.0, "sun_el": 13.0, "sun_color": Color(1.0, 0.72, 0.45), "sun_energy": 1.7, "shadow_blur": 1.6,
		"rough": "leafy_grass", "sand": "playground_sand", "trees": ["jacaranda", "island01", "fir_a", "fir_b"],
		"tree_density": 0.62, "wind": [0.5, 4.0], "ambience": "park_amb", "tee_color": Color(0.2, 0.45, 0.95),
		"grass": Color(0.24, 0.43, 0.12), "green": Color(0.19, 0.45, 0.12), "rough_tint": Color(0.5, 0.62, 0.3)},
]

## Per map, three holes. fairway: [x, z, half width] along the line of play; green: [x, z,
## radius x, radius z, turn]; bunkers / water: [x, z, radius x, radius z, turn].
const HOLES := [
	[
		{"par": 4, "tee": Vector2(0, 0), "fairway": [[4, -72, 14], [13, -150, 18], [30, -238, 16], [50, -306, 12]],
			"green": [66, -350, 15, 12, 0.5], "pin": Vector2(70, -354),
			"bunkers": [[34, -196, 7, 4, 0.3], [-8, -232, 6, 4, -0.2], [48, -352, 5, 3.5, 1.2], [84, -342, 4.5, 4, 0.4], [70, -366, 6, 2.5, 0.0]],
			"water": []},
		{"par": 3, "tee": Vector2(120, -404), "fairway": [[196, -278, 9], [204, -268, 9]],
			"green": [214, -254, 13, 11, -0.5], "pin": Vector2(217, -250),
			"bunkers": [[198, -242, 5, 3, 0.8], [230, -266, 4, 4, 0.0], [222, -238, 5, 2.5, -0.4]],
			"water": [[164, -332, 30, 19, 0.6]]},
		{"par": 5, "tee": Vector2(262, -222), "fairway": [[268, -150, 15], [294, -60, 18], [322, 40, 16], [330, 120, 14], [316, 190, 12]],
			"green": [302, 236, 16, 13, 0.2], "pin": Vector2(296, 240),
			"bunkers": [[312, -78, 8, 4.5, 0.4], [276, -30, 6, 4, -0.3], [350, 110, 7, 4, 0.2], [286, 220, 5, 3.5, 0.6], [320, 250, 5, 4, -0.5]],
			"water": [[318, 152, 46, 6, 0.08]]},
	],
	[
		{"par": 4, "tee": Vector2(0, 0), "fairway": [[0, -62, 15], [-5, -140, 17], [10, -212, 16], [44, -272, 13]],
			"green": [70, -318, 14, 12, 0.6], "pin": Vector2(74, -322),
			"bunkers": [[26, -214, 6, 4, 0.3], [86, -302, 5, 4, 0.5], [52, -332, 4.5, 3.5, 0.0]],
			"water": [[-34, -190, 22, 14, 0.3]]},
		{"par": 5, "tee": Vector2(130, -300), "fairway": [[140, -230, 15], [160, -140, 17], [170, -40, 16], [160, 40, 14], [150, 90, 12]],
			"green": [148, 126, 15, 12, -0.2], "pin": Vector2(144, 130),
			"bunkers": [[182, -150, 7, 4, 0.2], [132, -30, 6, 4, 0.0], [170, 112, 5, 4, 0.3], [128, 136, 4, 3, 0.9]],
			"water": [[163, 0, 48, 5, 0.1]]},
		{"par": 3, "tee": Vector2(262, 122), "fairway": [[296, -2, 8], [300, -12, 8]],
			"green": [302, -28, 13, 11, 0.3], "pin": Vector2(305, -32),
			"bunkers": [[287, -14, 4, 3, 0.5], [318, -40, 4.5, 3.5, -0.4], [296, -44, 5, 2.5, 0.0]],
			"water": [[284, 46, 20, 26, 0.2]]},
	],
]

var map: Dictionary
var map_index := 0
var holes: Array = []            ## per hole: {par, tee, pin (Vector3), green_c, path (PackedVector2Array), length, water_y[]}
var trees: Array = []            ## [Vector3 ground, canopy centre Vector3, canopy radius, trunk radius]
var water_levels: Array = []     ## per pond (all holes): [Vector2 c, Vector2 r, turn, level]
var sea_level := -1000.0

var _x0 := 0.0                   ## world corner of the fields
var _z0 := 0.0
var _sw := 0                     ## surface field size, texels
var _sh := 0
var _fair := PackedFloat32Array()
var _green := PackedFloat32Array()
var _bunk := PackedFloat32Array()
var _water := PackedFloat32Array()
var _line := PackedFloat32Array()  ## distance to the nearest hole's line of play (tee - fairway - green)
var _tree_grid: Dictionary = {}  ## Vector2i cell -> tree indices
var _dir := PackedByteArray()    ## fairway mowing direction, 2 bytes a texel
var surface := RSGolfSurface.new()
var _height_links := false
var _height_greens: Array[Array] = []
var _height_tees: Array[Array] = []
var _noise := FastNoiseLite.new()
var _noise2 := FastNoiseLite.new()
var _rng := RandomNumberGenerator.new()
var _flags: Array[Node3D] = []


func _init(i: int = 0) -> void:
	map_index = posmod(i, MAPS.size())
	map = MAPS[map_index]
	name = "GolfCourse"
	_rng.seed = 9100 + map_index * 77
	_noise.seed = 31 + map_index * 5
	_noise.frequency = 1.0 / 170.0
	_noise.fractal_octaves = 3
	_noise2.seed = 77 + map_index * 3
	_noise2.frequency = 1.0 / 28.0
	_noise2.fractal_octaves = 2


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	_layout_holes()
	_rasterize()
	_build_heights()
	_build_terrain_meshes()
	_build_water()
	_build_trees()
	_build_hole_furniture()
	print("[golf] course %s built in %d ms, %d trees" % [map["en"], Time.get_ticks_msec() - t0, trees.size()])


# ------------------------------------------------------------------------- holes ----

func _layout_holes() -> void:
	holes.clear()
	water_levels.clear()
	for h: Dictionary in HOLES[map_index]:
		var path := PackedVector2Array([h["tee"]])
		for f: Array in h["fairway"]:
			path.append(Vector2(f[0], f[1]))
		var g: Array = h["green"]
		var gc := Vector2(g[0], g[1])
		path.append(gc)
		var length := 0.0
		for i in range(1, path.size()):
			length += path[i - 1].distance_to(path[i])
		holes.append({"par": h["par"], "tee2": h["tee"], "pin2": h["pin"], "green_c": gc, "path": path,
			"length": length, "def": h})


func hole_count() -> int:
	return holes.size()


func tee_pos(i: int) -> Vector3:
	var t: Vector2 = holes[i]["tee2"]
	return Vector3(t.x, height_at(t.x, t.y), t.y)


func pin_pos(i: int) -> Vector3:
	var p: Vector2 = holes[i]["pin2"]
	return Vector3(p.x, height_at(p.x, p.y), p.y)


func tee_dir(i: int) -> Vector3:
	## Initial line of play from the tee (towards the first fairway point).
	var path: PackedVector2Array = holes[i]["path"]
	var d := (path[1] - path[0]).normalized()
	return Vector3(d.x, 0.0, d.y)


func hole_yards(i: int) -> int:
	## Hole length in metres, along the line of play to the pin.
	var path: PackedVector2Array = holes[i]["path"]
	var pin: Vector2 = holes[i]["pin2"]
	var d := 0.0
	for k in range(1, path.size() - 1):
		d += path[k - 1].distance_to(path[k])
	return roundi(d + path[path.size() - 2].distance_to(pin))


func aim_point(i: int, from: Vector3, reach: float) -> Vector3:
	## Where to aim from `from` with a club that carries `reach`: the pin when it is in range,
	## otherwise the point on the line of play `reach` away (well inside the fairway).
	var pin := pin_pos(i)
	var f2 := Vector2(from.x, from.z)
	if f2.distance_to(Vector2(pin.x, pin.z)) <= reach * 1.04:
		return pin
	var path: PackedVector2Array = holes[i]["path"]
	# Furthest point along the path (after the nearest one) within reach.
	var best := Vector2(pin.x, pin.z)
	var near_k := 0
	var near_d := INF
	for k in range(path.size() - 1):
		var c := Geometry2D.get_closest_point_to_segment(f2, path[k], path[k + 1])
		if c.distance_to(f2) < near_d:
			near_d = c.distance_to(f2)
			near_k = k
	for k in range(near_k, path.size() - 1):
		var a := path[k]
		var b := path[k + 1]
		# Solve |a + t (b - a) - f| = reach for the larger t in [0, 1].
		var d := b - a
		var m := a - f2
		var qa := d.dot(d)
		var qb := 2.0 * m.dot(d)
		var qc := m.dot(m) - reach * reach
		var disc := qb * qb - 4.0 * qa * qc
		if disc < 0.0:
			continue
		var t := (-qb + sqrt(disc)) / (2.0 * qa)
		if t >= 0.0 and t <= 1.0:
			best = a + d * t
	return Vector3(best.x, height_at(best.x, best.y), best.y)


# ------------------------------------------------------------------- surface field ----

func _rasterize() -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for h: Dictionary in holes:
		for p: Vector2 in h["path"]:
			lo = lo.min(p)
			hi = hi.max(p)
	_x0 = floorf(lo.x - MARGIN)
	_z0 = floorf(lo.y - MARGIN)
	_sw = int(ceilf((hi.x - lo.x + MARGIN * 2.0) / SDF)) + 1
	_sh = int(ceilf((hi.y - lo.y + MARGIN * 2.0) / SDF)) + 1
	var n := _sw * _sh
	# (Packed arrays are values: resize the members themselves, not loop copies.)
	_fair.resize(n)
	_fair.fill(SDF_RANGE)
	_green.resize(n)
	_green.fill(SDF_RANGE)
	_bunk.resize(n)
	_bunk.fill(SDF_RANGE)
	_water.resize(n)
	_water.fill(SDF_RANGE)
	_line.resize(n)
	_line.fill(LINE_RANGE)
	_dir.resize(n * 2)
	_dir.fill(128)
	for h: Dictionary in holes:
		var d: Dictionary = h["def"]
		var tee: Vector2 = d["tee"]
		var f: Array = d["fairway"]
		var first := Vector2(f[0][0], f[0][1])
		var tdir := (first - tee).normalized()
		# Tee box: a rounded rectangle 7 x 16 m along the first line of play.
		_raster_segment(_fair, tee - tdir * 6.0, tee + tdir * 6.0, 4.0, 4.0, true)
		for k in range(f.size() - 1):
			_raster_segment(_fair, Vector2(f[k][0], f[k][1]), Vector2(f[k + 1][0], f[k + 1][1]), f[k][2], f[k + 1][2], true)
		if f.size() == 1:
			_raster_segment(_fair, Vector2(f[0][0], f[0][1]), Vector2(f[0][0], f[0][1]) + tdir, f[0][2], f[0][2], true)
		var g: Array = d["green"]
		_raster_ellipse(_green, g, 0.0)
		for b: Array in d["bunkers"]:
			_raster_ellipse(_bunk, b, 0.0)
			# A second lobe makes the outline less of a perfect ellipse.
			var lobe := [b[0] + cos(b[4] + 1.0) * b[2] * 0.45, b[1] + sin(b[4] + 1.0) * b[3] * 0.45, b[2] * 0.6, b[3] * 0.75, b[4] + 0.7]
			_raster_ellipse(_bunk, lobe, 0.0)
		for w: Array in d["water"]:
			_raster_ellipse(_water, w, 0.0)
		var path: PackedVector2Array = h["path"]
		for k in range(path.size() - 1):
			_raster_segment(_line, path[k], path[k + 1], 0.0, 0.0, false, LINE_RANGE)


func _raster_segment(arr: PackedFloat32Array, a: Vector2, b: Vector2, wa: float, wb: float, mow: bool, reach: float = SDF_RANGE) -> void:
	var pad := maxf(wa, wb) + reach
	var lo := a.min(b) - Vector2(pad, pad)
	var hi := a.max(b) + Vector2(pad, pad)
	var ab := b - a
	var len2 := maxf(ab.length_squared(), 1e-6)
	var dirv := ab.normalized()
	var dx := int(clampf(dirv.x * 127.0 + 128.0, 0, 255))
	var dz := int(clampf(dirv.y * 127.0 + 128.0, 0, 255))
	var i0 := clampi(int((lo.x - _x0) / SDF), 0, _sw - 1)
	var i1 := clampi(int((hi.x - _x0) / SDF) + 1, 0, _sw - 1)
	var j0 := clampi(int((lo.y - _z0) / SDF), 0, _sh - 1)
	var j1 := clampi(int((hi.y - _z0) / SDF) + 1, 0, _sh - 1)
	for j in range(j0, j1 + 1):
		var z := _z0 + j * SDF
		for i in range(i0, i1 + 1):
			var p := Vector2(_x0 + i * SDF, z)
			var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
			var d := p.distance_to(a + ab * t) - lerpf(wa, wb, t)
			var k := j * _sw + i
			if d < arr[k]:
				arr[k] = maxf(d, -reach)
				if mow:
					_dir[k * 2] = dx
					_dir[k * 2 + 1] = dz


func _raster_ellipse(arr: PackedFloat32Array, e: Array, grow: float) -> void:
	var c := Vector2(e[0], e[1])
	var r := Vector2(e[2], e[3]) + Vector2(grow, grow)
	var rot: float = e[4]
	var pad := maxf(r.x, r.y) + SDF_RANGE
	var i0 := clampi(int((c.x - pad - _x0) / SDF), 0, _sw - 1)
	var i1 := clampi(int((c.x + pad - _x0) / SDF) + 1, 0, _sw - 1)
	var j0 := clampi(int((c.y - pad - _z0) / SDF), 0, _sh - 1)
	var j1 := clampi(int((c.y + pad - _z0) / SDF) + 1, 0, _sh - 1)
	var cs := cos(rot)
	var sn := sin(rot)
	var rmin := minf(r.x, r.y)
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var p := Vector2(_x0 + i * SDF, _z0 + j * SDF) - c
			var q := Vector2(p.x * cs + p.y * sn, -p.x * sn + p.y * cs)
			var l := (q / r).length()
			# Ellipse distance, good near the outline and fair further out.
			var d := (l - 1.0) * rmin if l < 1.0 else (q - q / l).length() if l > 1e-4 else -rmin
			var k := j * _sw + i
			if d < arr[k]:
				arr[k] = maxf(d, -SDF_RANGE)


func _field(arr: PackedFloat32Array, x: float, z: float) -> float:
	var fx := clampf((x - _x0) / SDF, 0.0, _sw - 1.001)
	var fz := clampf((z - _z0) / SDF, 0.0, _sh - 1.001)
	var i := int(fx)
	var j := int(fz)
	var u := fx - i
	var v := fz - j
	var k := j * _sw + i
	return lerpf(lerpf(arr[k], arr[k + 1], u), lerpf(arr[k + _sw], arr[k + _sw + 1], u), v)


func fairway_d(x: float, z: float) -> float:
	return _field(_fair, x, z)


func green_d(x: float, z: float) -> float:
	return _field(_green, x, z)


func lie_at(p: Vector3) -> Lie:
	if p.y < sea_level + 0.05:
		return Lie.WATER
	if _field(_water, p.x, p.z) < 0.0:
		return Lie.WATER
	if _field(_bunk, p.x, p.z) < 0.0:
		return Lie.BUNKER
	var g := _field(_green, p.x, p.z)
	if g < 0.0:
		return Lie.GREEN
	if g < 1.4:
		return Lie.FRINGE
	var f := _field(_fair, p.x, p.z)
	if f < 0.0:
		for h: Dictionary in holes:
			if (h["tee2"] as Vector2).distance_to(Vector2(p.x, p.z)) < 8.0:
				return Lie.TEE
		return Lie.FAIRWAY
	if f < 2.5:
		return Lie.FIRST_CUT
	if _min_feature_dist(p) > OB_FROM_FAIRWAY and f > 30.0 and g > 30.0:
		return Lie.OB
	return Lie.ROUGH


func _min_feature_dist(p: Vector3) -> float:
	## Distance to the nearest line of play (capped at LINE_RANGE).
	return _field(_line, p.x, p.z)


func in_bounds(p: Vector3) -> bool:
	return lie_at(p) != Lie.OB


# --------------------------------------------------------------------- heightfield ----

func _build_heights() -> void:
	var cells := Vector2i(int(ceilf(_sw * SDF / CELL)), int(ceilf(_sh * SDF / CELL)))
	_height_links = map["links"]
	# Ponds sit at the low ground of their surroundings.
	for h: Dictionary in holes:
		for w: Array in h["def"]["water"]:
			water_levels.append([Vector2(w[0], w[1]), Vector2(w[2], w[3]), w[4], _base(w[0], w[1]) - 0.7])
	_height_greens.clear()
	for h: Dictionary in holes:
		var gc: Vector2 = h["green_c"]
		var path: PackedVector2Array = h["path"]
		var into := (gc - path[path.size() - 2]).normalized()
		_height_greens.append([gc, into, _base(gc.x, gc.y) + 0.45])
	_height_tees.clear()
	for h: Dictionary in holes:
		var t: Vector2 = h["tee2"]
		_height_tees.append([t, _base(t.x, t.y) + 0.55])
	if _height_links:
		sea_level = 0.0
	surface.build(Vector2(_x0, _z0), cells, raw_height_at)


func raw_height_at(x: float, z: float) -> float:
	## Construction sampler: preserve the original shaping formula and operation order.
	var fd := _field(_fair, x, z)
	var gd := _field(_green, x, z)
	var bd := _field(_bunk, x, z)
	var wd := _field(_water, x, z)
	var y := _base(x, z)
	# Bumps: smooth on the short grass, more in the rough, dunes on the links.
	var play := minf(fd, gd)
	var rough_w := smoothstep(1.0, 14.0, play)
	var n2 := _noise2.get_noise_2d(x, z)
	y += n2 * (0.25 + rough_w * (1.6 if _height_links else 0.7))
	if _height_links:
		var dune := smoothstep(30.0, 70.0, _field(_line, x, z)) * smoothstep(10.0, 12.0, play)
		y += (absf(_noise2.get_noise_2d(x * 0.35 + 40.0, z * 0.35)) * 9.0 + 1.0) * dune
		# The shore: west of the course the land runs down into the sea.
		y = lerpf(y, -3.5, smoothstep(-95.0, -175.0, x + n2 * 18.0))
	# Greens: raised, tilted up away from the approach, gently rolling.
	for g: Array in _height_greens:
		var gc: Vector2 = g[0]
		var dist := Vector2(x, z).distance_to(gc)
		if dist > 45.0:
			continue
		var w := smoothstep(5.0, -1.0, gd) if dist < 30.0 else 0.0
		var rel := Vector2(x, z) - gc
		var gy: float = g[2] + rel.dot(g[1]) * 0.022 + _noise2.get_noise_2d(x * 2.2, z * 2.2) * 0.22
		y = lerpf(y, gy, w)
	for t: Array in _height_tees:
		var dist := Vector2(x, z).distance_to(t[0])
		y = lerpf(y, t[1], smoothstep(14.0, 8.0, dist))
	# Bunkers: a bowl and a little lip.
	if bd < 3.0:
		y -= 0.85 * smoothstep(0.6, -3.0, bd)
		y += 0.3 * exp(-pow((bd - 0.9) / 0.9, 2.0))
	# Ponds: banks down to below the water.
	if wd < 8.0:
		var lvl := _pond_level(x, z)
		y = lerpf(y, minf(y, lvl + 0.25), smoothstep(8.0, 0.5, wd))
		y = lerpf(y, lvl - 1.4, smoothstep(0.5, -4.0, wd))
	return y


func _base(x: float, z: float) -> float:
	return 7.0 + _noise.get_noise_2d(x, z) * 4.0


func _pond_level(x: float, z: float) -> float:
	var best := INF
	var lvl := 0.0
	for w: Array in water_levels:
		var d := (w[0] as Vector2).distance_to(Vector2(x, z))
		if d < best:
			best = d
			lvl = w[3]
	return lvl


func height_at(x: float, z: float) -> float:
	return surface.height_at(x, z)


func normal_at(x: float, z: float) -> Vector3:
	return surface.normal_at(x, z)


func water_level_at(x: float, z: float) -> float:
	## Water surface over a pond (or the sea), -INF where there is none.
	if _field(_water, x, z) < 1.0:
		return _pond_level(x, z)
	return sea_level if sea_level > -100.0 else -INF


# ------------------------------------------------------------------------ meshes ----

func _build_terrain_meshes() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/golf_terrain.gdshader")
	var img := Image.create_empty(_sw, _sh, false, Image.FORMAT_RGBA8)
	var data := PackedByteArray()
	data.resize(_sw * _sh * 4)
	for k in _sw * _sh:
		data[k * 4] = _enc(_fair[k])
		data[k * 4 + 1] = _enc(_green[k])
		data[k * 4 + 2] = _enc(_bunk[k])
		data[k * 4 + 3] = _enc(_water[k])
	img.set_data(_sw, _sh, false, Image.FORMAT_RGBA8, data)
	var dimg := Image.create_from_data(_sw, _sh, false, Image.FORMAT_RG8, _dir)
	mat.set_shader_parameter("fields", ImageTexture.create_from_image(img))
	mat.set_shader_parameter("mow_dir", ImageTexture.create_from_image(dimg))
	mat.set_shader_parameter("field_origin", Vector2(_x0, _z0))
	mat.set_shader_parameter("field_size", Vector2(_sw * SDF, _sh * SDF))
	mat.set_shader_parameter("field_range", SDF_RANGE)
	var tex := "res://assets/polyhaven/textures/%s/%s_%s_2k.jpg"
	var rough: String = map["rough"]
	var sand: String = map["sand"]
	mat.set_shader_parameter("grass_tex", load(tex % ["leafy_grass", "leafy_grass", "diff"]))
	mat.set_shader_parameter("grass_nor", load(tex % ["leafy_grass", "leafy_grass", "nor_gl"]))
	mat.set_shader_parameter("rough_tex", load(tex % [rough, rough, "diff"]))
	mat.set_shader_parameter("rough_nor", load(tex % [rough, rough, "nor_gl"]))
	mat.set_shader_parameter("sand_tex", load(tex % [sand, sand, "diff"]))
	mat.set_shader_parameter("sand_nor", load(tex % [sand, sand, "nor_gl"]))
	mat.set_shader_parameter("grass_color", map["grass"])
	mat.set_shader_parameter("green_color", map["green"])
	mat.set_shader_parameter("rough_tint", map["rough_tint"])
	mat.set_shader_parameter("links", 1.0 if map["links"] else 0.0)
	mat.set_shader_parameter("sea_level", sea_level)
	var nt := NoiseTexture2D.new()
	nt.width = 256
	nt.height = 256
	nt.seamless = true
	nt.generate_mipmaps = true
	var fn := FastNoiseLite.new()
	fn.seed = 5 + map_index
	fn.frequency = 6.0 / 256.0
	fn.fractal_octaves = 4
	nt.noise = fn
	mat.set_shader_parameter("noise_tex", nt)
	var cells := surface.cells
	for cj in range(0, cells.y, CHUNK):
		for ci in range(0, cells.x, CHUNK):
			var mi := MeshInstance3D.new()
			mi.mesh = surface.chunk_mesh(Rect2i(ci, cj, mini(CHUNK, cells.x - ci), mini(CHUNK, cells.y - cj)))
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mi)


static func _enc(d: float) -> int:
	return clampi(int(roundf((d / SDF_RANGE * 0.5 + 0.5) * 255.0)), 0, 255)


func _build_water() -> void:
	var sh := preload("res://shaders/sea.gdshader")
	for w: Array in water_levels:
		var r: Vector2 = w[1]
		var m := ShaderMaterial.new()
		m.shader = sh
		m.set_shader_parameter("wave_scale", 0.35)
		m.set_shader_parameter("clear_depth", 1.6)
		m.set_shader_parameter("deep_color", Color(0.02, 0.06, 0.05))
		m.set_shader_parameter("shallow_color", Color(0.12, 0.24, 0.18))
		var mi := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(r.x, r.y) * 2.0 + Vector2(16, 16)
		mi.mesh = pm
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.transform = Transform3D(Basis(Vector3.UP, -float(w[2])), Vector3((w[0] as Vector2).x, w[3], (w[0] as Vector2).y))
		add_child(mi)
	if map["links"]:
		var m := ShaderMaterial.new()
		m.shader = sh
		var mi := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(6000, 6000)
		pm.subdivide_width = 0
		mi.mesh = pm
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(_x0 - 2700.0, sea_level, _z0 + _sh * 0.5)
		add_child(mi)


# ------------------------------------------------------------------------- trees ----

func _build_trees() -> void:
	trees.clear()
	var kinds: Array = map["trees"]
	var per_kind: Array = []
	for k in kinds.size():
		per_kind.append([])
	var density: float = map["tree_density"]
	var clump := FastNoiseLite.new()
	clump.seed = 400 + map_index
	clump.frequency = 1.0 / 60.0
	var step := 9.0
	var z := _z0 + 30.0
	while z < _z0 + _sh * SDF - 30.0:
		var x := _x0 + 30.0
		while x < _x0 + _sw * SDF - 30.0:
			var px := x + _rng.randf_range(-step * 0.45, step * 0.45)
			var pz := z + _rng.randf_range(-step * 0.45, step * 0.45)
			x += step
			var near := _field(_line, px, pz)      # from the line of play (the fields stop at 12 m)
			if minf(_field(_fair, px, pz), _field(_green, px, pz)) < 11.5 or near < 30.0:
				continue
			if _field(_water, px, pz) < 5.0 or _field(_bunk, px, pz) < 6.0:
				continue
			var y := height_at(px, pz)
			if y < sea_level + 1.2:
				continue
			# Clumps of woods, thicker further from play.
			var c := clump.get_noise_2d(px, pz) * 0.5 + 0.5
			var p := density * smoothstep(0.3, 0.7, c) * smoothstep(30.0, 50.0, near)
			if _rng.randf() > p:
				continue
			var kind := _rng.randi_range(0, kinds.size() - 1)
			per_kind[kind].append(Vector3(px, y, pz))
		z += step
	for k in kinds.size():
		_tree_multimesh(kinds[k], per_kind[k])


func _tree_multimesh(kind: String, spots: Array) -> void:
	if spots.is_empty():
		return
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TREE_DIR + kind + ".json"))
	var radius: float = meta["radius"]
	var centre_up: float = meta["centre_up"]
	var width: float = meta["width"]
	var height: float = meta["height"]
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/impostor.gdshader")
	mat.set_shader_parameter("albedo_atlas", load(TREE_DIR + kind + "_albedo.png"))
	mat.set_shader_parameter("normal_atlas", load(TREE_DIR + kind + "_normal.png"))
	mat.set_shader_parameter("frames", float(meta["frames"]))
	mat.set_shader_parameter("radius", radius)
	mat.set_shader_parameter("centre_up", centre_up)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	mm.mesh = q
	mm.instance_count = spots.size()
	# Jacarandas are huge: keep them a little smaller than the model.
	var base_scale := 0.7 if height > 15.0 else 1.0
	for i in spots.size():
		var at: Vector3 = spots[i]
		var s := base_scale * _rng.randf_range(0.8, 1.25)
		var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(Vector3(s, s, s))
		mm.set_instance_transform(i, Transform3D(basis, at - Vector3(0, 0.15, 0)))
		var tint := Color(1, 1, 1).lerp(Color(_rng.randf_range(0.8, 1.05), _rng.randf_range(0.85, 1.1), _rng.randf_range(0.7, 1.0)), 0.8)
		mm.set_instance_custom_data(i, tint)
		var cell := Vector2i(floori(at.x / TREE_CELL), floori(at.z / TREE_CELL))
		if not _tree_grid.has(cell):
			_tree_grid[cell] = PackedInt32Array()
		_tree_grid[cell].append(trees.size())
		trees.append([at, at + Vector3(0, centre_up * s * 1.1, 0), width * 0.42 * s, 0.25 * s, height * s])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mmi)


func tree_hit(p: Vector3) -> int:
	## -1, or the tree whose canopy (or trunk) the point is in.
	var cx := floori(p.x / TREE_CELL)
	var cz := floori(p.z / TREE_CELL)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var hit := _tree_in(p, _tree_grid.get(Vector2i(cx + dx, cz + dz), PackedInt32Array()))
			if hit >= 0:
				return hit
	return -1


func _tree_in(p: Vector3, list: PackedInt32Array) -> int:
	for i in list:
		var t: Array = trees[i]
		var g: Vector3 = t[0]
		var c: Vector3 = t[1]
		var r: float = t[2]
		var rel := p - c
		rel.y *= 0.8
		if rel.length() < r and p.y > g.y + float(t[4]) * 0.3:
			return i
		if Vector2(p.x - g.x, p.z - g.z).length() < float(t[3]) and p.y < c.y:
			return i
	return -1


# ------------------------------------------------------------- flags, cups, tees ----

func _build_hole_furniture() -> void:
	var white := StandardMaterial3D.new()
	white.albedo_color = Color(0.95, 0.95, 0.93)
	white.roughness = 0.4
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.02, 0.02, 0.02)
	dark.roughness = 1.0
	var tee_mat := StandardMaterial3D.new()
	tee_mat.albedo_color = map["tee_color"]
	tee_mat.roughness = 0.35
	var flag_shader := preload("res://shaders/golf_flag.gdshader")
	_flags.clear()
	for i in holes.size():
		var pin := pin_pos(i)
		var n := normal_at(pin.x, pin.z)
		# Cup: a dark disc just over the green and a white liner ring.
		var cup := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = CUP_R
		cm.bottom_radius = CUP_R
		cm.height = 0.02
		cm.radial_segments = 24
		cup.mesh = cm
		cup.material_override = dark
		cup.transform = Transform3D(Basis(Quaternion(Vector3.UP, n)), pin + n * 0.004)
		add_child(cup)
		var liner := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = CUP_R - 0.003
		tm.outer_radius = CUP_R + 0.003
		liner.mesh = tm
		liner.material_override = white
		liner.transform = cup.transform.scaled_local(Vector3(1, 0.3, 1))
		add_child(liner)
		# Flagstick and flag.
		var flag := Node3D.new()
		flag.position = pin
		add_child(flag)
		var pole := MeshInstance3D.new()
		var pmesh := CylinderMesh.new()
		pmesh.top_radius = 0.0065
		pmesh.bottom_radius = 0.0065
		pmesh.height = 2.2
		pmesh.radial_segments = 8
		pole.mesh = pmesh
		var pole_mat := StandardMaterial3D.new()
		pole_mat.albedo_color = Color(0.98, 0.85, 0.2)
		pole_mat.roughness = 0.3
		pole.material_override = pole_mat
		pole.position = Vector3(0, 1.1, 0)
		flag.add_child(pole)
		var cloth := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(0.55, 0.38)
		plane.subdivide_width = 10
		plane.subdivide_depth = 6
		plane.orientation = PlaneMesh.FACE_Z
		cloth.mesh = plane
		var fm := ShaderMaterial.new()
		fm.shader = flag_shader
		fm.set_shader_parameter("color", Color(0.85, 0.1, 0.12) if i % 2 == 0 else Color(0.95, 0.85, 0.15))
		cloth.material_override = fm
		cloth.position = Vector3(0.285, 1.98, 0)
		flag.add_child(cloth)
		var num := Label3D.new()
		num.text = str(i + 1)
		num.font = RSUi.font()
		num.font_size = 64
		num.pixel_size = 0.004
		num.modulate = Color.WHITE
		num.outline_size = 0
		num.double_sided = true
		num.position = Vector3(0.3, 1.98, 0.005)
		flag.add_child(num)
		_flags.append(flag)
		# Tee markers either side of the teeing ground.
		var tee := tee_pos(i)
		var td := tee_dir(i)
		var side := td.cross(Vector3.UP)
		for s in [-1.0, 1.0]:
			var mk := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 0.11
			sm.height = 0.2
			mk.mesh = sm
			mk.material_override = tee_mat
			var at: Vector3 = tee + side * 3.2 * s + td * 1.5
			at.y = height_at(at.x, at.z) + 0.07
			mk.position = at
			add_child(mk)


func set_wind(dir: Vector3, speed: float) -> void:
	## Flags fly downwind.
	for f in _flags:
		var flat := Vector3(dir.x, 0, dir.z)
		if flat.length() > 0.01:
			f.basis = Basis(Vector3.UP, atan2(-flat.z, flat.x))
		var cloth := f.get_child(1) as MeshInstance3D
		(cloth.material_override as ShaderMaterial).set_shader_parameter("wind", speed)


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
	env.ssao_radius = 1.2
	env.ssao_intensity = 1.4
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.08
	env.adjustment_contrast = 1.04
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = map["fog"]
	env.fog_sun_scatter = 0.35
	env.fog_density = map["fog_density"]
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.5
	var we := WorldEnvironment.new()
	we.environment = env
	parent.add_child(we)
	RSSettings.environment(env)

	var sun := DirectionalLight3D.new()
	var az := deg_to_rad(float(map["sun_az"]))
	var el := deg_to_rad(float(map["sun_el"]))
	var to_sun := Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))
	sun.basis = Basis.looking_at(-to_sun, Vector3.UP)
	sun.light_color = map["sun_color"]
	sun.light_energy = map["sun_energy"]
	sun.light_angular_distance = 1.0
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = map["shadow_blur"]
	sun.directional_shadow_max_distance = 140.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	parent.add_child(sun)
	return sun
