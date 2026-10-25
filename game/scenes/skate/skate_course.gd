class_name RSSkateCourse
extends Node3D
## 滑板 course: a straight downhill street run toward the sea at golden hour. Everything the
## physics needs comes from data defined in _init() (road profile, obstacle pieces, rails,
## gaps, posts), and the meshes are built from the same data in _ready(), so what you see is
## what you ride.
##
## Course space: s = metres along the run (world z = -s), x = across the street (road from
## -HALF_W to HALF_W, sidewalks out to BOUND). Heights: a piecewise-linear road profile H(s)
## (stairs are ridden along their nosing line) plus pieces standing on it whose height
## follows the road slope.

const HALF_W := 9.0
const BOUND := 12.4
const BUILD_X := 14.4         ## building fronts; BOUND..BUILD_X is street furniture
const CURB := 0.15
const START_S := 8.0
const FINISH_S := 520.0
const END_S := 584.0
const SEA_Y := -25.0
const STAIR_TREAD := 0.6
const HDRI := "res://assets/polyhaven/hdris/kloppenheim_06_puresky/kloppenheim_06_puresky_4k.hdr"
## Toward the sun: the HDRI's sun bearing (ahead-right), raised so light reaches the street.
const TO_SUN := Vector3(0.61, 0.52, -0.78)
## Static meshes are cut into chunks this long along s so each view (and each shadow cascade)
## only draws the stretch of street it can see (#53).
const CHUNK_S := 50.0
const PIECE_BUCKET := 4.0     ## metres of s per bucket of the piece lookup (surface / top)


class Piece:
	const BOX := 0
	const RAMP_UP := 1
	const RAMP_DOWN := 2

	var kind := BOX
	var x0 := 0.0
	var x1 := 0.0
	var s0 := 0.0
	var s1 := 0.0
	var h := 0.0
	var tag := ""          ## "ledge", "pad", "bench", "kicker", "deck", "top", "walk"
	var paint := 0         ## colour set for ramps

	func contains(x: float, s: float) -> bool:
		return x >= x0 and x <= x1 and s >= s0 and s <= s1

	func rel(s: float) -> float:
		var t := clampf((s - s0) / (s1 - s0), 0.0, 1.0)
		if kind == RAMP_UP:
			return h * t * t
		if kind == RAMP_DOWN:
			return h * (1.0 - t)
		return h

	func slope(s: float) -> float:
		var t := clampf((s - s0) / (s1 - s0), 0.0, 1.0)
		if kind == RAMP_UP:
			return 2.0 * h * t / (s1 - s0)
		if kind == RAMP_DOWN:
			return -h / (s1 - s0)
		return 0.0


class Rail:
	var a := Vector3.ZERO
	var b := Vector3.ZERO
	var ledge := false     ## concrete edge (coping) rather than a steel pipe
	var name := ""
	var length := 0.0
	var dir := Vector3.ZERO
	var color := Color.WHITE

	func setup() -> void:
		length = a.distance_to(b)
		dir = (b - a) / length

	func point(t: float) -> Vector3:
		return a.lerp(b, clampf(t, 0.0, 1.0))

	func flat_t(p: Vector3) -> float:
		## Parameter of the closest point on the rail, measured on the ground plane.
		var ab := Vector2(b.x - a.x, b.z - a.z)
		return clampf(Vector2(p.x - a.x, p.z - a.z).dot(ab) / ab.length_squared(), 0.0, 1.0)

	func flat_dist(p: Vector3) -> float:
		var q := point(flat_t(p))
		return Vector2(p.x - q.x, p.z - q.z).length()


class Gap:
	var name := ""
	var points := 0
	var take0 := 0.0       ## take off with s in [take0, take1]
	var take1 := 0.0
	var land := 0.0        ## and land beyond this s
	var x0 := -99.0
	var x1 := 99.0


var pieces: Array[Piece] = []
var rails: Array[Rail] = []
var gaps: Array[Gap] = []
var letters: Array[Vector3] = []        ## S K A T E, world positions
var posts: Array[Vector3] = []          ## solid poles: (x, s, radius)
var hydrants: Array[Vector2] = []       ## (x, s), also in posts
var _ac: Array = []                     ## facade AC units (transforms), built with the city
var features: Array[Dictionary] = []    ## for bots and hints: kickers, pads

var _ps := PackedFloat32Array()         ## road profile knots (s, y)
var _py := PackedFloat32Array()
var _stairs: Array[Vector3] = []        ## (s0, s1, steps)
var _sections: Array[Array] = []        ## [s0, s1, surface name]
var _rng := RandomNumberGenerator.new()
var _st: Dictionary = {}                ## Vector2i(chunk, material id) -> SurfaceTool while building
var _mat_ids: Dictionary = {}           ## material name -> id in those keys
var _mats: Dictionary = {}
var _buckets: Array[PackedInt32Array] = []   ## piece indices per PIECE_BUCKET of s
var _bucket_s0 := 0.0
var _bucketed := -1                          ## pieces.size() when _buckets was built


func _init() -> void:
	_rng.seed = 20261017
	_build_profile()
	_build_layout()


# ------------------------------------------------------------------------ queries ----

func H(s: float) -> float:
	## Road height along the run (stairs: their nosing line).
	var n := _ps.size()
	if s <= _ps[0]:
		return _py[0]
	var i := _knot(s)
	if i < n:
		return lerpf(_py[i - 1], _py[i], (s - _ps[i - 1]) / (_ps[i] - _ps[i - 1]))
	return _py[n - 1]


func road_slope(s: float) -> float:
	## dH/ds.
	var i := _knot(s)
	if i < _ps.size():
		return (_py[i] - _py[i - 1]) / (_ps[i] - _ps[i - 1])
	return 0.0


func _knot(s: float) -> int:
	## The first profile knot i >= 1 with s <= _ps[i] (_ps.size() past the end). bsearch
	## compares in float32, so step to the exact answer from there.
	var n := _ps.size()
	var i := maxi(_ps.bsearch(s), 1)
	while i > 1 and s <= _ps[i - 1]:
		i -= 1
	while i < n and s > _ps[i]:
		i += 1
	return i


func _near(s: float) -> PackedInt32Array:
	## Indices (ascending) of the pieces whose s range can contain s: one bucket per
	## PIECE_BUCKET metres, built on first use and again if pieces were added.
	if _bucketed != pieces.size():
		_bucket_pieces()
	var b := floori((s - _bucket_s0) / PIECE_BUCKET)
	return _buckets[b] if b >= 0 and b < _buckets.size() else PackedInt32Array()


func _bucket_pieces() -> void:
	_bucketed = pieces.size()
	_buckets.clear()
	if pieces.is_empty():
		return
	_bucket_s0 = pieces[0].s0
	var s1 := pieces[0].s1
	for p in pieces:
		_bucket_s0 = minf(_bucket_s0, p.s0)
		s1 = maxf(s1, p.s1)
	_buckets.resize(floori((s1 - _bucket_s0) / PIECE_BUCKET) + 1)
	for i in pieces.size():
		var p := pieces[i]
		for b in range(floori((p.s0 - _bucket_s0) / PIECE_BUCKET), floori((p.s1 - _bucket_s0) / PIECE_BUCKET) + 1):
			var cell := _buckets[b]
			cell.append(i)
			_buckets[b] = cell


func stairs_at(s: float) -> bool:
	for st in _stairs:
		if s >= st.x and s <= st.y:
			return true
	return false


func tread_y(s: float) -> float:
	## Height of the actual stair tread under s (for props standing on the stairs).
	for st in _stairs:
		if s >= st.x and s < st.y:
			var i := floori((s - st.x) / STAIR_TREAD)
			return H(st.x) - (H(st.x) - H(st.y)) / st.z * (i + 1)
	return H(s)


func world(x: float, s: float, rel: float = 0.0) -> Vector3:
	return Vector3(x, H(s) + rel, -s)


func bound(_s: float) -> float:
	return BOUND


func surface(x: float, s: float, y_max: float) -> Vector3:
	## Highest walkable surface at (x, s) that is not above y_max:
	## (height, slope dh/ds, piece index or -1).
	var base := H(s)
	var rs := road_slope(s)
	var best := Vector3(base, rs, -1.0)
	if absf(x) > HALF_W and not stairs_at(s):
		best.x += CURB
	for i in _near(s):
		var p := pieces[i]
		if p.contains(x, s):
			var y := base + p.rel(s)
			if y <= y_max and y > best.x:
				best = Vector3(y, rs + p.slope(s), float(i))
	return best


func top(x: float, s: float) -> float:
	## Highest surface at (x, s), however high (for wall checks).
	var base := H(s)
	var best := base + (CURB if absf(x) > HALF_W and not stairs_at(s) else 0.0)
	for i in _near(s):
		var p := pieces[i]
		if p.contains(x, s):
			best = maxf(best, base + p.rel(s))
	return best


# ------------------------------------------------------------------------- layout ----

func _build_profile() -> void:
	# [length, drop, stair steps (0 = slope), surface]
	var segs := [
		[40.0, 0.0, 0, "tile_start"],
		[85.0, 4.25, 0, "asphalt"],
		[4.2, 1.4, 7, "stairs"],
		[85.8, 1.3, 0, "tile_plaza"],
		[85.0, 5.1, 0, "asphalt"],
		[6.0, 2.0, 10, "stairs"],
		[114.0, 2.3, 0, "tile_prom"],
		[85.0, 4.25, 0, "asphalt"],
		[79.0, 0.0, 0, "tile_finish"],
	]
	_ps.append(-90.0)
	_py.append(4.5)
	_sections.append([-90.0, 0.0, "asphalt"])
	_ps.append(0.0)
	_py.append(0.0)
	var s := 0.0
	var y := 0.0
	for seg in segs:
		var s1: float = s + seg[0]
		y -= seg[1]
		_ps.append(s1)
		_py.append(y)
		if seg[2] > 0:
			_stairs.append(Vector3(s, s1, seg[2]))
		_sections.append([s, s1, seg[3]])
		s = s1
	# Past the end: a little further for the sea view geometry.
	_ps.append(s + 60.0)
	_py.append(y)


func _box(x0: float, x1: float, s0: float, s1: float, h: float, tag: String) -> Piece:
	var p := Piece.new()
	p.kind = Piece.BOX
	p.x0 = x0
	p.x1 = x1
	p.s0 = s0
	p.s1 = s1
	p.h = h
	p.tag = tag
	pieces.append(p)
	if tag in ["ledge", "bench", "top"]:
		_ledge_rail(x0, s0, s1, h, "Ledge" if tag != "bench" else "Bench")
		_ledge_rail(x1, s0, s1, h, "Ledge" if tag != "bench" else "Bench")
	return p


func _ramp(kind: int, x0: float, x1: float, s0: float, s1: float, h: float, paint: int) -> Piece:
	var p := _box(x0, x1, s0, s1, h, "kicker" if kind == Piece.RAMP_UP else "landing")
	p.kind = kind
	p.paint = paint
	return p


func _kicker(x0: float, x1: float, s0: float, length: float, h: float, deck: float, paint: int) -> void:
	_ramp(Piece.RAMP_UP, x0, x1, s0, s0 + length, h, paint)
	_box(x0, x1, s0 + length, s0 + length + deck, h, "deck")
	features.append({"type": "kicker", "x": (x0 + x1) * 0.5, "w": x1 - x0, "s0": s0, "lip": s0 + length + deck, "h": h})


func _ledge_rail(x: float, s0: float, s1: float, h: float, rail_name: String) -> void:
	var r := Rail.new()
	r.a = world(x, s0 + 0.15, h)
	r.b = world(x, s1 - 0.15, h)
	r.ledge = true
	r.name = rail_name
	r.setup()
	rails.append(r)


func _rail(x: float, s0: float, s1: float, rel: float, rail_name: String, color: Color) -> void:
	var r := Rail.new()
	r.a = world(x, s0, rel)
	r.b = world(x, s1, rel)
	r.name = rail_name
	r.color = color
	r.setup()
	rails.append(r)


func _gap(gap_name: String, points: int, take0: float, take1: float, land: float, x0: float = -99.0, x1: float = 99.0) -> void:
	var g := Gap.new()
	g.name = gap_name
	g.points = points
	g.take0 = take0
	g.take1 = take1
	g.land = land
	g.x0 = x0
	g.x1 = x1
	gaps.append(g)


func _build_layout() -> void:
	var yellow := Color(1.0, 0.78, 0.1)
	var red := Color(0.92, 0.25, 0.22)
	var blue := Color(0.2, 0.5, 0.95)
	var teal := Color(0.1, 0.75, 0.7)

	# Start plaza: two manual pads and a flat bar to warm up on.
	_box(-7.5, -4.5, 16.0, 26.0, 0.2, "pad")
	_box(4.5, 7.5, 16.0, 26.0, 0.2, "pad")
	_rail(0.0, 17.0, 31.0, 0.45, "Flat Bar", yellow)

	# Slope A: kickers either side, a long bar down the middle, ledges, then stair set 1.
	_kicker(-7.5, -4.5, 52.0, 3.0, 0.7, 1.0, 0)
	letters.append(world(-6.0, 61.5, 2.5))
	_kicker(4.5, 7.5, 70.0, 3.0, 0.7, 1.0, 1)
	_rail(0.0, 62.0, 86.0, 0.5, "Long Bar", red)
	_box(7.6, 8.7, 90.0, 112.0, 0.45, "ledge")
	_box(-8.7, -6.7, 95.0, 107.0, 0.5, "ledge")
	_kicker(-1.5, 1.5, 119.0, 2.5, 0.5, 1.0, 2)
	_rail(-4.0, 124.4, 129.8, 0.75, "Handrail", blue)
	_rail(4.0, 124.4, 129.8, 0.75, "Handrail", blue)
	_gap("Stair Set", 250, -999.0, 125.3, 129.0)

	# Plaza B: a funbox with a rail on top, benches, a long planter, a manual pad.
	_ramp(Piece.RAMP_UP, -2.5, 2.5, 150.0, 152.5, 0.8, 1)
	_box(-2.5, 2.5, 152.5, 157.5, 0.8, "top")
	_ramp(Piece.RAMP_DOWN, -2.5, 2.5, 157.5, 160.5, 0.8, 1)
	features.append({"type": "kicker", "x": 0.0, "w": 5.0, "s0": 150.0, "lip": 152.5, "h": 0.8})
	_rail(0.0, 153.0, 157.0, 1.25, "Funbox Rail", yellow)
	letters.append(world(0.0, 155.0, 3.3))
	_gap("Funbox Gap", 200, 150.0, 152.6, 157.5, -2.5, 2.5)
	_box(-8.6, -7.6, 168.0, 175.0, 0.45, "bench")
	_box(-8.6, -7.6, 182.0, 189.0, 0.45, "bench")
	_box(5.5, 8.6, 170.0, 194.0, 0.55, "ledge")
	_box(-2.2, 2.2, 178.0, 192.0, 0.22, "pad")
	_kicker(-6.0, -3.0, 204.0, 2.0, 0.6, 0.8, 0)
	_kicker(3.0, 6.0, 204.0, 2.0, 0.6, 0.8, 2)

	# Slope C: the big gap (kicker, drop, landing), a long rail, a ledge, then stair set 2.
	_kicker(-6.5, -1.5, 228.0, 3.0, 1.0, 1.5, 1)
	_box(-6.5, -1.5, 239.0, 240.5, 1.0, "deck")
	_ramp(Piece.RAMP_DOWN, -6.5, -1.5, 240.5, 245.0, 1.0, 1)
	letters.append(world(-4.0, 235.8, 3.0))
	_gap("Big Gap", 600, 228.0, 232.6, 239.0, -6.5, -1.5)
	_rail(5.5, 236.0, 262.0, 0.55, "Long Rail", teal)
	_box(-8.7, -7.6, 258.0, 284.0, 0.5, "ledge")
	_kicker(-1.5, 1.5, 288.0, 2.5, 0.55, 0.8, 0)
	_rail(-5.0, 299.4, 306.6, 0.75, "Big Rail", red)
	_rail(0.0, 299.4, 306.6, 0.75, "Big Rail", yellow)
	_rail(5.0, 299.4, 306.6, 0.75, "Big Rail", red)
	_gap("Big Stairs", 500, -999.0, 300.3, 305.8)

	# Promenade: the seawall ledge, twin rails, a raised platform, a pyramid.
	_box(7.8, 8.8, 320.0, 400.0, 0.55, "ledge")
	letters.append(world(8.3, 372.0, 1.6))
	_rail(-1.6, 330.0, 350.0, 0.5, "Twin Rail", blue)
	_rail(1.6, 330.0, 350.0, 0.5, "Twin Rail", blue)
	_ramp(Piece.RAMP_UP, -7.5, -3.5, 356.0, 358.5, 0.6, 2)
	_box(-7.5, -3.5, 358.5, 372.0, 0.6, "top")
	features.append({"type": "kicker", "x": -5.5, "w": 4.0, "s0": 356.0, "lip": 358.5, "h": 0.6})
	_ramp(Piece.RAMP_UP, -3.0, 3.0, 385.0, 387.5, 0.9, 0)
	_box(-3.0, 3.0, 387.5, 390.0, 0.9, "deck")
	_ramp(Piece.RAMP_DOWN, -3.0, 3.0, 390.0, 393.0, 0.9, 0)
	features.append({"type": "kicker", "x": 0.0, "w": 6.0, "s0": 385.0, "lip": 387.5, "h": 0.9})
	_gap("Pyramid Gap", 250, 385.0, 387.6, 390.0, -3.0, 3.0)

	# Slope E: the big kicker over the street, side kickers, rails and a centre ledge.
	_kicker(-3.0, 3.0, 440.0, 4.0, 1.4, 1.5, 2)
	letters.append(world(0.0, 452.0, 4.2))
	_gap("Huge Air", 500, 440.0, 445.6, 453.0, -3.0, 3.0)
	_kicker(-8.0, -5.0, 466.0, 2.5, 0.6, 0.8, 1)
	_kicker(5.0, 8.0, 466.0, 2.5, 0.6, 0.8, 0)
	_rail(-6.5, 476.0, 497.0, 0.55, "Rail", teal)
	_rail(6.5, 476.0, 497.0, 0.55, "Rail", teal)
	_box(-0.6, 0.6, 478.0, 496.0, 0.5, "ledge")

	# Curbs are grindable too (not on the stairs, not in front of the finish crowd).
	for sec in _sections:
		var s0: float = maxf(sec[0], 2.0)
		var s1: float = minf(sec[1], FINISH_S - 30.0)
		if sec[2] == "stairs" or s1 - s0 < 5.0:
			continue
		for side in [-1.0, 1.0]:
			var r := Rail.new()
			r.a = world(side * HALF_W, s0 + 0.5, CURB)
			r.b = world(side * HALF_W, s1 - 0.5, CURB)
			r.ledge = true
			r.name = "Curb"
			r.setup()
			rails.append(r)

	for p in pieces:
		if p.tag == "pad":
			features.append({"type": "pad", "x": (p.x0 + p.x1) * 0.5, "w": p.x1 - p.x0, "s0": p.s0, "s1": p.s1})

	# Street lamps by the curb are solid; palms stand in the furniture strip by the buildings.
	var s := -60.0
	while s < END_S - 4.0:
		if not stairs_at(s) and not stairs_at(s + 2.0) and not (s > FINISH_S - 34.0 and s < FINISH_S + 18.0):
			for side in [-1.0, 1.0]:
				if side > 0.0 and s > 300.0:
					continue      # sea side of the promenade stays open
				posts.append(Vector3(side * 13.3, s + _rng.randf_range(-1.5, 1.5), 0.32))
		if int(s) % 24 == 0 and not stairs_at(s):
			posts.append(Vector3(10.1 * (1.0 if int(s / 24.0) % 2 == 0 else -1.0), s + 6.0, 0.14))
		s += 12.0
	for hs: float in [20.0, 98.0, 176.0, 250.0, 352.0, 450.0]:
		var hx := (HALF_W + 0.4) * (-1.0 if int(hs) % 3 == 0 else 1.0)
		if hx > 0.0 and hs > 300.0:
			hx = -hx
		hydrants.append(Vector2(hx, hs))
		posts.append(Vector3(hx, hs, 0.16))
	posts.append(Vector3(-11.0, 562.0, 0.9))      # the whale statue on the finish plaza


# ------------------------------------------------------------------------- meshes ----

func _ready() -> void:
	_make_materials()
	_build_ground()
	for p in pieces:
		_build_piece(p)
	for r in rails:
		if not r.ledge:
			_build_rail(r)
	_commit("course")
	_build_city()
	_build_seafront()
	_build_props()
	_build_arches()


func _make_materials() -> void:
	# Scanned PBR surfaces (Poly Haven, CC0); UVs are in metres, size = metres per texture.
	_mats["asphalt"] = RSPbr.surface("clean_asphalt", 2.1, Color(0.95, 0.95, 0.97), {"road_lines": true, "half_width": HALF_W, "macro": 0.18})
	_mats["tile_start"] = RSPbr.surface("herringbone_brick_03", 1.98, Color(1.0, 0.95, 0.9), {"macro": 0.1})
	_mats["tile_plaza"] = RSPbr.surface("large_grey_tiles", 3.0, Color(1.05, 0.98, 0.9))
	_mats["tile_prom"] = RSPbr.surface("patterned_concrete_pavers", 1.8, Color(0.86, 0.82, 0.76))
	_mats["tile_finish"] = RSPbr.surface("large_grey_tiles", 3.0, Color(0.92, 0.95, 1.0))
	_mats["stairs"] = RSPbr.surface("concrete_floor_worn_001", 3.0, Color(1.0, 0.98, 0.95))
	_mats["walk"] = RSPbr.surface("patterned_concrete_pavers", 1.8)
	_mats["concrete"] = RSPbr.surface("concrete_floor_worn_001", 3.0, Color(1.02, 1.0, 0.97))
	_mats["curb"] = RSPbr.surface("concrete_floor_worn_001", 1.5, Color(1.25, 1.22, 1.18))
	_mats["wall"] = RSPbr.surface("concrete_wall_003", 3.0)
	_mats["wood"] = RSPbr.surface("plywood", 0.5, Color(0.72, 0.5, 0.34), {"anti_tile": 0.0})
	_mats["ply"] = RSPbr.surface("plywood", 0.5, Color(1.0, 0.95, 0.88), {"anti_tile": 0.0, "macro": 0.06})
	_mats["roof"] = RSPbr.surface("concrete_wall_003", 3.0, Color.WHITE, {"use_vertex_color": true})
	var iron := StandardMaterial3D.new()
	iron.vertex_color_use_as_albedo = true
	iron.metallic = 0.6
	iron.roughness = 0.45
	_mats["iron"] = iron
	_mats["steel"] = _metal(Color(0.62, 0.63, 0.65), 0.9, 0.3)
	_mats["white"] = _metal(Color(0.9, 0.9, 0.88), 0.2, 0.4)
	_mats["yellow"] = _metal(Color(1.0, 0.78, 0.1), 0.1, 0.45)
	var vc := StandardMaterial3D.new()
	vc.vertex_color_use_as_albedo = true
	vc.roughness = 0.75
	_mats["vc"] = vc
	var awning := StandardMaterial3D.new()
	awning.vertex_color_use_as_albedo = true
	awning.roughness = 0.85
	awning.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mats["awning"] = awning
	var ply := RSPbr.maps("plywood")
	var paint_cols := [Color(0.42, 0.45, 0.47), Color(0.2, 0.25, 0.32), Color(0.58, 0.55, 0.48)]
	for i in 3:
		# Painted plywood with scanned graffiti pieces (tools/blender/extract_graffiti.py).
		var m := ShaderMaterial.new()
		m.shader = preload("res://shaders/ramp_paint.gdshader")
		m.set_shader_parameter("ply_albedo", ply[0])
		m.set_shader_parameter("ply_normal", ply[1])
		for d in 3:
			m.set_shader_parameter("decal%d" % d, load("res://assets/decals/graffiti_%d.png" % d))
		m.set_shader_parameter("paint", paint_cols[i])
		_mats["paint%d" % i] = m


func _metal(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = roughness
	return m


func _surf(mat_name: String, z: float) -> SurfaceTool:
	## The SurfaceTool for mat_name in the CHUNK_S chunk holding world z.
	var key := Vector2i(floori(-z / CHUNK_S), _mat_ids.get_or_add(mat_name, _mat_ids.size()))
	if not _st.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_st[key] = st
	return _st[key]


func _commit(node_name: String) -> void:
	## One MeshInstance3D per chunk ("<node_name>_<chunk>"), one surface per material.
	var names := _mat_ids.keys()
	var meshes: Dictionary = {}     # chunk -> ArrayMesh
	for key: Vector2i in _st:
		var st: SurfaceTool = _st[key]
		var mat_name: String = names[key.y]
		var mat: Material = _mats[mat_name]
		if mat is ShaderMaterial or (mat is BaseMaterial3D and (mat as BaseMaterial3D).normal_enabled):
			st.generate_tangents()   # normal maps need them (every such surface has UVs)
		var mesh: ArrayMesh = meshes.get_or_add(key.x, ArrayMesh.new())
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	_st.clear()
	var chunks := meshes.keys()
	chunks.sort()
	for c: int in chunks:
		var mi := MeshInstance3D.new()
		mi.name = "%s_%d" % [node_name, c]
		mi.mesh = meshes[c]
		add_child(mi)


func _props(key: String, xforms: Array, layers: int = 1, shadows: bool = true) -> void:
	## RSProps.place, one MultiMesh per CHUNK_S chunk instead of one across the whole map.
	var groups: Dictionary = {}
	for xf: Transform3D in xforms:
		(groups.get_or_add(floori(-xf.origin.z / CHUNK_S), []) as Array).append(xf)
	var chunks := groups.keys()
	chunks.sort()
	for c: int in chunks:
		RSProps.place(self, key, groups[c], layers, shadows)


func _quad(mat_name: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, uv_scale: float = 1.0, color: Color = Color.WHITE, uv2: Array = []) -> void:
	## A flat quad with outward normal n; the winding is fixed up to face n. UVs are a planar
	## projection in metres (times uv_scale), picked by the dominant normal axis; uv2, when
	## given, holds one UV2 per corner a, b, c, d.
	var st := _surf(mat_name, (a.z + c.z) * 0.5)
	var pts := [a, b, c, d]
	var idx := [0, 1, 2, 3]
	if (c - a).cross(b - a).dot(n) < 0.0:
		pts = [a, d, c, b]
		idx = [0, 3, 2, 1]
	for i in [0, 1, 2, 0, 2, 3]:
		var p: Vector3 = pts[i]
		if not uv2.is_empty():
			st.set_uv2(uv2[idx[i]])
		var uv: Vector2
		var an := n.abs()
		if an.y >= an.x and an.y >= an.z:
			uv = Vector2(p.x, p.z)
		elif an.x >= an.z:
			uv = Vector2(p.z, -p.y)
		else:
			uv = Vector2(p.x, -p.y)
		st.set_normal(n)
		st.set_color(color)
		st.set_uv(uv * uv_scale)
		st.add_vertex(p)


func _quad_uv(mat_name: String, pts: Array, uvs: Array, n: Vector3, color: Color) -> void:
	## Quad with explicit UVs (building facades).
	var st := _surf(mat_name, (pts[0].z + pts[2].z) * 0.5)
	var order := [0, 1, 2, 0, 2, 3]
	if (pts[2] - pts[0]).cross(pts[1] - pts[0]).dot(n) < 0.0:
		order = [0, 3, 2, 0, 2, 1]
	for i: int in order:
		st.set_normal(n)
		st.set_color(color)
		st.set_uv(uvs[i])
		st.add_vertex(pts[i])


func _append(mat_name: String, mesh: Mesh, xf: Transform3D) -> void:
	_surf(mat_name, xf.origin.z).append_from(mesh, 0, xf)


func _cyl_xf(a: Vector3, b: Vector3) -> Transform3D:
	## Transform putting a unit-height Y-axis cylinder between a and b.
	var d := b - a
	var y := d.normalized()
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	return Transform3D(Basis(x, y * d.length(), z), (a + b) * 0.5)


func _build_ground() -> void:
	var sec_list := _sections.duplicate()
	for sec in sec_list:
		var s0: float = sec[0]
		var s1: float = sec[1]
		var kind: String = sec[2]
		if kind == "stairs":
			_build_stairs(s0, s1)
			continue
		var y0 := H(s0)
		var y1 := H(s1)
		_quad(kind, Vector3(-HALF_W, y0, -s0), Vector3(HALF_W, y0, -s0), Vector3(HALF_W, y1, -s1), Vector3(-HALF_W, y1, -s1), Vector3.UP)
		for side in [-1.0, 1.0]:
			var xi: float = side * HALF_W
			var xo: float = side * (BUILD_X if side < 0.0 or s1 <= 300.0 else BOUND)
			_quad("walk", Vector3(xi, y0 + CURB, -s0), Vector3(xo, y0 + CURB, -s0), Vector3(xo, y1 + CURB, -s1), Vector3(xi, y1 + CURB, -s1), Vector3.UP)
			_quad("curb", Vector3(xi, y0, -s0), Vector3(xi, y0 + CURB, -s0), Vector3(xi, y1 + CURB, -s1), Vector3(xi, y1, -s1), Vector3(-side, 0, 0))
			# Retaining wall below the outer edge (seen from the beach side).
			_quad("wall", Vector3(xo, y0 + CURB, -s0), Vector3(xo, SEA_Y - 2.0, -s0), Vector3(xo, SEA_Y - 2.0, -s1), Vector3(xo, y1 + CURB, -s1), Vector3(side, 0, 0))
	# Under the far end of the course (beyond the finish) a seawall drops to the beach.
	var ye := H(END_S)
	_quad("wall", Vector3(-BUILD_X, ye + CURB, -END_S), Vector3(BOUND, ye + CURB, -END_S), Vector3(BOUND, SEA_Y - 2.0, -END_S), Vector3(-BUILD_X, SEA_Y - 2.0, -END_S), Vector3.FORWARD)


func _build_stairs(s0: float, s1: float) -> void:
	var steps := int(round((s1 - s0) / STAIR_TREAD))
	var y_top := H(s0)
	var riser := (y_top - H(s1)) / steps
	var xl := -BUILD_X
	var xr := BUILD_X if s1 <= 300.0 else BOUND
	for i in steps:
		var sa := s0 + i * STAIR_TREAD
		var sb := sa + STAIR_TREAD
		var y := y_top - riser * (i + 1)
		_quad("stairs", Vector3(xl, y, -sa), Vector3(xr, y, -sa), Vector3(xr, y, -sb), Vector3(xl, y, -sb), Vector3.UP)
		_quad("curb", Vector3(xl, y + riser, -sa), Vector3(xr, y + riser, -sa), Vector3(xr, y, -sa), Vector3(xl, y, -sa), Vector3.BACK)
		for xo: float in [xl, xr]:
			_quad("wall", Vector3(xo, y, -sa), Vector3(xo, SEA_Y - 2.0, -sa), Vector3(xo, SEA_Y - 2.0, -sb), Vector3(xo, y, -sb), Vector3(signf(xo), 0, 0))
	if xr < BUILD_X:
		# The furniture strip before the big stairs ends over the beach: close it off.
		var yt := H(s0) + CURB
		_quad("wall", Vector3(BOUND, yt, -s0), Vector3(BUILD_X, yt, -s0), Vector3(BUILD_X, SEA_Y - 2.0, -s0), Vector3(BOUND, SEA_Y - 2.0, -s0), Vector3.FORWARD)


func _build_piece(p: Piece) -> void:
	var bottom := minf(H(p.s0), H(p.s1)) - 0.3
	var n := 1 if p.kind == Piece.BOX else 12
	var side_mat := "concrete"
	var top_mat := "concrete"
	match p.tag:
		"bench":
			top_mat = "wood"
		"kicker", "landing":
			top_mat = "ply"
			side_mat = "paint%d" % p.paint
		"deck":
			top_mat = "ply"
			side_mat = "paint%d" % p.paint
	var painted := side_mat.begins_with("paint")
	var y0 := H(p.s0) + p.rel(p.s0)
	var y1 := H(p.s1) + p.rel(p.s1)
	# Painted panels: UV2 = (metres along as seen from outside, metres above the ground) and the
	# vertex colour describes the panel for ramp_paint.gdshader; a hash of the piece picks where
	# its graffiti sits and whether a side has any.
	var ground := bottom + 0.3
	var y_max := maxf(y0, y1)
	for i in n + 1:
		var si := lerpf(p.s0, p.s1, float(i) / n)
		y_max = maxf(y_max, H(si) + p.rel(si))
	var pseed := fposmod(sin(p.s0 * 12.9898 + p.x0 * 78.233) * 43758.5453, 1.0)
	var side_cols := {}
	for x: float in [p.x0, p.x1]:
		var r := fposmod(pseed * 7.13 + (0.37 if x == p.x1 else 0.0), 1.0)
		side_cols[x] = Color((y_max - ground) / 4.0, r, 1.0 if r < 0.8 else 0.0, (p.s1 - p.s0) / 16.0)
	var prev_top := Vector2.ZERO
	for i in n + 1:
		var s := lerpf(p.s0, p.s1, float(i) / n)
		var y := H(s) + p.rel(s)
		if i > 0:
			var sa := s - (p.s1 - p.s0) / n
			var ya := prev_top.y
			var nrm := Vector3(0.0, 1.0, p.slope(s) + road_slope(s)).normalized()
			_quad(top_mat, Vector3(p.x0, ya, -sa), Vector3(p.x1, ya, -sa), Vector3(p.x1, y, -s), Vector3(p.x0, y, -s), nrm)
			for x: float in [p.x0, p.x1]:
				var out := Vector3(-1, 0, 0) if x == p.x0 else Vector3(1, 0, 0)
				if painted:
					# Seen from +x, "along" runs with s; seen from -x, against it.
					var ua := (sa - p.s0) if x == p.x1 else (p.s1 - sa)
					var ub := (s - p.s0) if x == p.x1 else (p.s1 - s)
					_quad(side_mat, Vector3(x, bottom, -sa), Vector3(x, ya, -sa), Vector3(x, y, -s), Vector3(x, bottom, -s), out, 1.0, side_cols[x],
							[Vector2(ua, bottom - ground), Vector2(ua, ya - ground), Vector2(ub, y - ground), Vector2(ub, bottom - ground)])
				else:
					_quad(side_mat, Vector3(x, bottom, -sa), Vector3(x, ya, -sa), Vector3(x, y, -s), Vector3(x, bottom, -s), out)
		prev_top = Vector2(s, y)
	var w := p.x1 - p.x0
	if y0 > H(p.s0) + 0.01:
		var col := Color((y0 - ground) / 4.0, fposmod(pseed * 3.7, 1.0), 1.0, w / 16.0)
		var uv: Array = [Vector2(0, bottom - ground), Vector2(w, bottom - ground), Vector2(w, y0 - ground), Vector2(0, y0 - ground)] if painted else []
		_quad(side_mat, Vector3(p.x0, bottom, -p.s0), Vector3(p.x1, bottom, -p.s0), Vector3(p.x1, y0, -p.s0), Vector3(p.x0, y0, -p.s0), Vector3.BACK, 1.0, col, uv)
	if y1 > H(p.s1) + 0.01:
		var col := Color((y1 - ground) / 4.0, fposmod(pseed * 5.3, 1.0), 1.0, w / 16.0)
		var uv: Array = [Vector2(w, bottom - ground), Vector2(0, bottom - ground), Vector2(0, y1 - ground), Vector2(w, y1 - ground)] if painted else []
		_quad(side_mat, Vector3(p.x0, bottom, -p.s1), Vector3(p.x1, bottom, -p.s1), Vector3(p.x1, y1, -p.s1), Vector3(p.x0, y1, -p.s1), Vector3.FORWARD, 1.0, col, uv)
	# Trim: steel coping on ledges, a lip plate on kickers, yellow edges on manual pads.
	var lift := 0.004
	if p.tag in ["ledge", "top"]:
		for x: float in [p.x0, p.x1]:
			var inward := 0.05 if x == p.x0 else -0.05
			_quad("steel", Vector3(x, y0 + lift, -p.s0), Vector3(x + inward, y0 + lift, -p.s0), Vector3(x + inward, y1 + lift, -p.s1), Vector3(x, y1 + lift, -p.s1), Vector3.UP)
	elif p.tag == "pad":
		for x: float in [p.x0, p.x1]:
			var inward := 0.12 if x == p.x0 else -0.12
			_quad("yellow", Vector3(x, y0 + lift, -p.s0), Vector3(x + inward, y0 + lift, -p.s0), Vector3(x + inward, y1 + lift, -p.s1), Vector3(x, y1 + lift, -p.s1), Vector3.UP)
	elif p.kind == Piece.RAMP_UP:
		var sl := p.s1 - 0.18
		var yl := H(sl) + p.rel(sl)
		_quad("steel", Vector3(p.x0, yl + lift, -sl), Vector3(p.x1, yl + lift, -sl), Vector3(p.x1, y1 + lift, -p.s1), Vector3(p.x0, y1 + lift, -p.s1), Vector3.UP)


func _build_rail(r: Rail) -> void:
	var mat_name := "rail_%s" % r.color.to_html(false)
	if not _mats.has(mat_name):
		_mats[mat_name] = _metal(r.color, 0.55, 0.32)
	var pipe := CylinderMesh.new()
	pipe.top_radius = 0.035
	pipe.bottom_radius = 0.035
	pipe.height = 1.0
	pipe.radial_segments = 10
	pipe.rings = 1
	_append(mat_name, pipe, _cyl_xf(r.a, r.b))
	var post := CylinderMesh.new()
	post.top_radius = 0.025
	post.bottom_radius = 0.025
	post.height = 1.0
	post.radial_segments = 8
	post.rings = 1
	var plate := BoxMesh.new()
	plate.size = Vector3(0.14, 0.02, 0.14)
	var count := maxi(2, ceili(r.length / 2.4) + 1)
	for i in count:
		var t := lerpf(0.04, 0.96, float(i) / (count - 1))
		var p := r.point(t)
		var g := top(p.x, -p.z)
		if stairs_at(-p.z):
			g = tread_y(-p.z)
		_append("steel", post, _cyl_xf(Vector3(p.x, g, p.z), p))
		_append("steel", plate, Transform3D(Basis(), Vector3(p.x, g + 0.01, p.z)))
	# Rounded end caps.
	var cap := SphereMesh.new()
	cap.radius = 0.035
	cap.height = 0.07
	cap.radial_segments = 8
	cap.rings = 4
	_append(mat_name, cap, Transform3D(Basis(), r.a))
	_append(mat_name, cap, Transform3D(Basis(), r.b))


# ---------------------------------------------------------------------- scenery ----

const WALL_COLORS := [
	Color(0.96, 0.88, 0.74), Color(0.98, 0.76, 0.62), Color(0.93, 0.6, 0.52), Color(0.72, 0.86, 0.78),
	Color(0.68, 0.8, 0.92), Color(0.82, 0.74, 0.9), Color(0.9, 0.82, 0.62), Color(0.8, 0.52, 0.42),
	Color(0.97, 0.94, 0.88),
]
const AWNING_COLORS := [Color(0.85, 0.2, 0.2), Color(0.15, 0.45, 0.6), Color(0.2, 0.55, 0.35), Color(0.95, 0.6, 0.1)]


func _build_city() -> void:
	var facade := ShaderMaterial.new()
	facade.shader = preload("res://shaders/facade.gdshader")
	var plaster := RSPbr.maps("beige_wall_001")
	facade.set_shader_parameter("plaster_albedo", plaster[0])
	facade.set_shader_parameter("plaster_normal", plaster[1])
	facade.set_shader_parameter("plaster_orm", plaster[2])
	facade.set_shader_parameter("plaster_size", 3.0)
	facade.set_shader_parameter("sky_pano", load(HDRI))
	facade.set_shader_parameter("street_w", BUILD_X * 2.0)
	facade.set_shader_parameter("sun_dir", TO_SUN)
	_mats["facade"] = facade
	# Left side all the way down; right side until the promenade opens up to the sea.
	_building_row(-1.0, BUILD_X + 0.05, -90.0, END_S + 4.0, 7.0, 22.0, true)
	_building_row(1.0, BUILD_X + 0.05, -90.0, 299.5, 7.0, 18.0, true)
	_building_row(-1.0, BUILD_X + 16.0, -90.0, END_S + 30.0, 16.0, 40.0, false)
	_building_row(1.0, BUILD_X + 16.0, -90.0, 290.0, 14.0, 34.0, false)
	_commit("city")


func _building_row(side: float, x_in: float, s_from: float, s_to: float, h_min: float, h_max: float, detail: bool) -> void:
	var s := s_from
	while s < s_to:
		var w := _rng.randf_range(9.0, 16.0)
		var s0 := s
		var s1 := minf(s + w, s_to)
		s = s1 + (_rng.randf_range(0.0, 1.8) if _rng.randf() < 0.5 else 0.0)
		if s1 - s0 < 4.0:
			continue
		var depth := _rng.randf_range(10.0, 14.0)
		var xi := side * x_in
		var xo := side * (x_in + depth)
		var street := minf(H(s0), H(s1)) + CURB
		var base := street - 12.0
		var h := _rng.randf_range(h_min, h_max)
		var top := street + h
		var wall := (WALL_COLORS[_rng.randi_range(0, WALL_COLORS.size() - 1)] as Color).srgb_to_linear()
		# Facade toward the street, the two ends, and the back (seen from the beach).
		var xs := [xi, xo]
		_quad_uv("facade", [Vector3(xi, base, -s0), Vector3(xi, top, -s0), Vector3(xi, top, -s1), Vector3(xi, base, -s1)],
			[Vector2(0, base - street), Vector2(0, top - street), Vector2(s1 - s0, top - street), Vector2(s1 - s0, base - street)], Vector3(-side, 0, 0), wall)
		for k in 2:
			var sz: float = [s0, s1][k]
			var nz := Vector3.BACK if k == 0 else Vector3.FORWARD
			_quad_uv("facade", [Vector3(xs[0], base, -sz), Vector3(xs[0], top, -sz), Vector3(xs[1], top, -sz), Vector3(xs[1], base, -sz)],
				[Vector2(0, base - street), Vector2(0, top - street), Vector2(depth, top - street), Vector2(depth, base - street)], nz, wall)
		_quad_uv("facade", [Vector3(xo, base, -s0), Vector3(xo, top, -s0), Vector3(xo, top, -s1), Vector3(xo, base, -s1)],
			[Vector2(0, base - street), Vector2(0, top - street), Vector2(s1 - s0, top - street), Vector2(s1 - s0, base - street)], Vector3(side, 0, 0), wall)
		if detail:
			_facade_units(side, xi, s0, s1, street, top)
			_facade_relief(side, xi, s0, s1, street, top, wall)
		var roof := wall.darkened(0.25)
		_quad("roof", Vector3(xi, top, -s0), Vector3(xo, top, -s0), Vector3(xo, top, -s1), Vector3(xi, top, -s1), Vector3.UP, 1.0, roof)
		if not detail:
			continue
		# Parapet lip, rooftop boxes, and a shop awning at street level.
		_box_vc(Vector3(minf(xi, xo), top, -s1), Vector3(maxf(xi, xo), top + 0.5, -s1 + 0.3), wall.darkened(0.1), "roof")
		_box_vc(Vector3(minf(xi, xo), top, -s0 - 0.3), Vector3(maxf(xi, xo), top + 0.5, -s0), wall.darkened(0.1), "roof")
		for k in _rng.randi_range(1, 3):
			var cx := lerpf(xi, xo, _rng.randf_range(0.3, 0.8))
			var cs := _rng.randf_range(s0 + 1.5, s1 - 1.5)
			var bw := _rng.randf_range(1.2, 2.6)
			_box_vc(Vector3(cx - bw * 0.5, top, -cs - bw * 0.5), Vector3(cx + bw * 0.5, top + _rng.randf_range(0.8, 2.2), -cs + bw * 0.5), Color(0.62, 0.63, 0.66).srgb_to_linear(), "roof")
		if _rng.randf() < 0.7:
			var ac := (AWNING_COLORS[_rng.randi_range(0, AWNING_COLORS.size() - 1)] as Color).srgb_to_linear()
			var ya := street + 3.3
			var xa := xi - side * 1.3
			# Striped canvas: alternating 0.5 m strips of colour and off-white.
			var sa := s0 + 0.6
			var k := 0
			while sa < s1 - 0.6 - 0.01:
				var sb := minf(sa + 0.5, s1 - 0.6)
				var col := ac if k % 2 == 0 else Color(0.92, 0.9, 0.85).srgb_to_linear()
				_quad("awning", Vector3(xi, ya + 0.5, -sa), Vector3(xa, ya, -sa), Vector3(xa, ya, -sb), Vector3(xi, ya + 0.5, -sb), Vector3(-side * 0.36, 0.93, 0), 1.0, col)
				_quad("awning", Vector3(xa, ya, -sa), Vector3(xa, ya - 0.35, -sa), Vector3(xa, ya - 0.35, -sb), Vector3(xa, ya, -sb), Vector3(-side, 0, 0), 1.0, col.darkened(0.1))
				sa = sb
				k += 1


func _facade_units(side: float, xi: float, s0: float, s1: float, street: float, top: float) -> void:
	## Air-con units hung under a few windows (cells 3 m wide from s0, floors 3.2 m from 4 m).
	var floors := int((top - street - 4.0) / 3.2)
	for f in floors:
		var j := 0
		while 3.0 * j + 3.0 <= s1 - s0:
			if _rng.randf() < 0.09:
				var y := street + 4.0 + f * 3.2 - 0.28
				var at := Vector3(xi - side * 0.19, y, -(s0 + 3.0 * j + 1.5 + _rng.randf_range(-0.5, 0.5)))
				_ac.append(Transform3D(Basis(Vector3.UP, -side * PI * 0.5).scaled(Vector3.ONE * 0.8), at))
			j += 1


func _facade_relief(side: float, xi: float, s0: float, s1: float, street: float, top: float, wall: Color) -> void:
	## Depth on a street facade: a cornice at the roof, a band over the shops, and on some
	## buildings balconies with railings in front of the upper windows.
	var out := -side           # toward the street
	var trim := wall.lightened(0.25)
	var x0 := xi
	_box_vc(Vector3(minf(x0, x0 + out * 0.4), top - 0.45, -s1), Vector3(maxf(x0, x0 + out * 0.4), top + 0.05, -s0), trim, "roof")
	_box_vc(Vector3(minf(x0, x0 + out * 0.15), street + 3.95, -s1), Vector3(maxf(x0, x0 + out * 0.15), street + 4.2, -s0), trim, "roof")
	if _rng.randf() > 0.45:
		return
	var floors := int((top - street - 4.0) / 3.2)
	var depth := 0.85
	for f in range(0, floors):
		if _rng.randf() < 0.35:
			continue
		var y := street + 4.0 + f * 3.2 + 0.45
		var j := 0
		while 3.0 * j + 3.0 <= s1 - s0:
			if _rng.randf() < 0.7:
				var sa := s0 + 3.0 * j + 0.35
				var sb := s0 + 3.0 * j + 2.65
				var xa := x0
				var xb := x0 + out * depth
				_box_vc(Vector3(minf(xa, xb), y - 0.16, -sb), Vector3(maxf(xa, xb), y, -sa), trim, "roof")
				# Railing: top rail, bottom rail and balusters, painted black iron.
				for k in 2:
					var yy := y + 0.08 + k * 0.9
					_box_vc(Vector3(minf(xb, xb - out * 0.04), yy, -sb), Vector3(maxf(xb, xb - out * 0.04), yy + 0.04, -sa), Color(0.03, 0.03, 0.035), "iron")
					for e: float in [sa, sb]:
						_box_vc(Vector3(minf(xa, xb), yy, -e - 0.02), Vector3(maxf(xa, xb), yy + 0.04, -e + 0.02), Color(0.03, 0.03, 0.035), "iron")
				var b := sa + 0.06
				while b < sb:
					_box_vc(Vector3(minf(xb, xb - out * 0.02), y, -b - 0.012), Vector3(maxf(xb, xb - out * 0.02), y + 1.0, -b + 0.012), Color(0.03, 0.03, 0.035), "iron")
					b += 0.13
			j += 1


func _box_vc(lo: Vector3, hi: Vector3, color: Color, mat_name: String = "vc") -> void:
	var c := [Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)]
	_quad(mat_name, c[4], c[5], c[6], c[7], Vector3.UP, 1.0, color)
	_quad(mat_name, c[0], c[1], c[5], c[4], Vector3.FORWARD, 1.0, color.darkened(0.08))
	_quad(mat_name, c[3], c[2], c[6], c[7], Vector3.BACK, 1.0, color.darkened(0.08))
	_quad(mat_name, c[0], c[3], c[7], c[4], Vector3.LEFT, 1.0, color.darkened(0.15))
	_quad(mat_name, c[1], c[2], c[6], c[5], Vector3.RIGHT, 1.0, color.darkened(0.15))


func _build_seafront() -> void:
	# The sea, a beach under the promenade and in front of the finish, far headlands.
	var water := ShaderMaterial.new()
	water.shader = preload("res://shaders/sea.gdshader")
	var sea := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(5000, 5000)
	sea.mesh = plane
	sea.material_override = water
	sea.position = Vector3(800, SEA_Y, -1600)
	sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sea)

	_mats["sand"] = RSPbr.surface("coast_sand_01", 6.0, Color(1.05, 1.0, 0.92))
	var y_wall := SEA_Y + 1.2
	_quad("sand", Vector3(BOUND, y_wall, -296.0), Vector3(BOUND + 60.0, SEA_Y - 1.5, -296.0), Vector3(BOUND + 60.0, SEA_Y - 1.5, -END_S - 60.0), Vector3(BOUND, y_wall, -END_S - 10.0), Vector3.UP)
	_quad("sand", Vector3(-BOUND - 40.0, y_wall, -END_S), Vector3(BOUND, y_wall, -END_S), Vector3(BOUND + 60.0, SEA_Y - 1.5, -END_S - 60.0), Vector3(-BOUND - 40.0, SEA_Y - 1.5, -END_S - 50.0), Vector3.UP)
	# Boulders along the waterline.
	var rocks: Array = []
	for i in 30:
		var p := Vector3(_rng.randf_range(BOUND + 22.0, BOUND + 55.0), SEA_Y - 1.2, -_rng.randf_range(320.0, END_S + 40.0))
		var sc := _rng.randf_range(1.6, 4.2)
		var b := Basis(Vector3.UP, _rng.randf() * TAU) * Basis(Vector3.RIGHT, _rng.randf_range(-0.3, 0.3))
		rocks.append(Transform3D(b.scaled(Vector3(sc, sc * _rng.randf_range(0.6, 1.0), sc)), p))
	_props("boulder", rocks, 1, false)
	# Seawall railing along the promenade and across the end.
	var rail_mat := "white"
	var bar := CylinderMesh.new()
	bar.top_radius = 0.03
	bar.bottom_radius = 0.03
	bar.height = 1.0
	bar.radial_segments = 6
	bar.rings = 1
	var s := 306.0
	while s < END_S:
		var s2 := minf(s + 3.0, END_S)
		var a := world(BOUND - 0.15, s, CURB)
		var b := world(BOUND - 0.15, s2, CURB)
		_append(rail_mat, bar, _cyl_xf(a, a + Vector3.UP * 1.0))
		_append(rail_mat, bar, _cyl_xf(a + Vector3.UP * 1.0, b + Vector3.UP * 1.0))
		_append(rail_mat, bar, _cyl_xf(a + Vector3.UP * 0.5, b + Vector3.UP * 0.5))
		s = s2
	var x := -BOUND
	while x < BOUND:
		var a := world(x, END_S - 0.15, CURB)
		var b := world(minf(x + 3.0, BOUND), END_S - 0.15, CURB)
		_append(rail_mat, bar, _cyl_xf(a, a + Vector3.UP * 1.0))
		_append(rail_mat, bar, _cyl_xf(a + Vector3.UP * 1.0, b + Vector3.UP * 1.0))
		_append(rail_mat, bar, _cyl_xf(a + Vector3.UP * 0.5, b + Vector3.UP * 0.5))
		x += 3.0
	_commit("seafront")

	# Headlands on the horizon: noise-shaped ridges, scrub on the slopes, rock on the cliffs.
	var hill_mat := StandardMaterial3D.new()
	hill_mat.vertex_color_use_as_albedo = true
	hill_mat.roughness = 1.0
	var k := 0
	for hp: Array in [[Vector3(700, SEA_Y, -1400), Vector3(420, 90, 260)], [Vector3(1150, SEA_Y, -900), Vector3(300, 60, 200)],
			[Vector3(-500, SEA_Y, -1700), Vector3(600, 120, 300)], [Vector3(250, SEA_Y, -2100), Vector3(500, 70, 220)]]:
		var mi := MeshInstance3D.new()
		mi.mesh = _headland_mesh(hp[1], 11 + k)
		mi.material_override = hill_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = hp[0]
		add_child(mi)
		k += 1


func _headland_mesh(size: Vector3, noise_seed: int) -> ArrayMesh:
	## A ridge of hills size.x by size.z (half-extents) and size.y high: an elliptical dome
	## carved by ridged noise, with cliffs where it drops into the sea.
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	noise.fractal_octaves = 5
	noise.frequency = 1.6
	var detail := FastNoiseLite.new()
	detail.seed = noise_seed + 50
	detail.frequency = 9.0
	var nx := 72
	var nz := 40
	var hts := PackedFloat32Array()
	hts.resize((nx + 1) * (nz + 1))
	for j in nz + 1:
		for i in nx + 1:
			var u := float(i) / nx * 2.0 - 1.0
			var v := float(j) / nz * 2.0 - 1.0
			var r := Vector2(u, v * 1.1).length()
			var dome := pow(clampf(1.0 - r, 0.0, 1.0), 0.7)
			var ridge := noise.get_noise_2d(u, v) * 0.5 + 0.5
			var hh := dome * (0.45 + 0.75 * ridge) + detail.get_noise_2d(u, v) * 0.04 * dome
			hts[j * (nx + 1) + i] = maxf(hh, 0.0) * size.y - (2.0 if r > 0.98 else 0.0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var scrub := [Color(0.17, 0.21, 0.12), Color(0.24, 0.26, 0.15), Color(0.3, 0.27, 0.18)]
	for j in nz + 1:
		for i in nx + 1:
			var hgt := hts[j * (nx + 1) + i]
			var hx := hts[j * (nx + 1) + mini(i + 1, nx)] - hts[j * (nx + 1) + maxi(i - 1, 0)]
			var hz := hts[mini(j + 1, nz) * (nx + 1) + i] - hts[maxi(j - 1, 0) * (nx + 1) + i]
			var slope := Vector2(hx / (4.0 * size.x / nx), hz / (4.0 * size.z / nz)).length()
			var tone := detail.get_noise_2d(i * 0.37, j * 0.41) * 0.5 + 0.5
			var c: Color = (scrub[0] as Color).lerp(scrub[1], tone).lerp(scrub[2], clampf(hgt / size.y - 0.6, 0.0, 1.0))
			c = c.lerp(Color(0.36, 0.33, 0.29), smoothstep(0.55, 1.1, slope))      # cliffs
			c = c.lerp(Color(0.52, 0.47, 0.38), smoothstep(6.0, 1.0, hgt))          # rocky foot
			st.set_color(c.srgb_to_linear())
			st.add_vertex(Vector3((float(i) / nx * 2.0 - 1.0) * size.x, hgt, (float(j) / nz * 2.0 - 1.0) * size.z))
	for j in nz:
		for i in nx:
			var a := j * (nx + 1) + i
			var b := a + 1
			var c := a + nx + 1
			var d := c + 1
			for idx in [a, b, d, a, d, c]:
				st.add_index(idx)
	st.generate_normals()
	return st.commit()


func _build_props() -> void:
	# Palms, scanned lamps, hydrants and facade AC units, the furniture strip, bunting across
	# the street, cones by the kickers.
	var palms := MultiMesh.new()
	palms.transform_format = MultiMesh.TRANSFORM_3D
	palms.mesh = _palm_mesh()
	var palm_xf: Array[Transform3D] = []
	var lamp_xf: Array = []
	for p in posts:
		var y := H(p.y) + CURB
		if absf(p.x) > BOUND:
			var sc := _rng.randf_range(0.85, 1.15)
			palm_xf.append(Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * sc), Vector3(p.x, y, -p.y)))
		elif is_equal_approx(p.z, 0.14):
			lamp_xf.append(Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * 1.2), Vector3(p.x, y, -p.y)))
	palms.instance_count = palm_xf.size()
	for i in palm_xf.size():
		palms.set_instance_transform(i, palm_xf[i])
	var pmi := MultiMeshInstance3D.new()
	pmi.multimesh = palms
	add_child(pmi)
	_props("lamp", lamp_xf)
	var hyd: Array = []
	for h in hydrants:
		hyd.append(Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), world(h.x, h.y, CURB)))
	_props("hydrant", hyd)
	_props("aircon", _ac.slice(0, _ac.size() / 2))
	_props("aircon_rust", _ac.slice(_ac.size() / 2))
	_build_furniture()

	var pennant := ["#ef4444", "#f59e0b", "#22c55e", "#3b82f6", "#a855f7", "#ffffff"]
	for s: float in [30.0, 140.0, 196.0, 330.0, 410.0, 500.0]:
		var y := H(s) + 7.0
		var a := Vector3(-BOUND + 0.5, y, -s)
		var b := Vector3(BOUND - 0.5, y, -s)
		var count := 26
		for i in count:
			var t0 := float(i) / count
			var t1 := float(i + 1) / count
			var p0 := a.lerp(b, t0) + Vector3.DOWN * 1.2 * sin(PI * t0)
			var p1 := a.lerp(b, t1) + Vector3.DOWN * 1.2 * sin(PI * t1)
			var tip := (p0 + p1) * 0.5 + Vector3.DOWN * 0.55
			var c := Color(pennant[i % pennant.size()]).srgb_to_linear()
			var st := _surf("flag", tip.z)
			for tri in [[p0, p1, tip], [p0, tip, p1]]:
				var n: Vector3 = (tri[2] - tri[0]).cross(tri[1] - tri[0]).normalized()
				for v: Vector3 in tri:
					st.set_normal(n)
					st.set_color(c)
					st.add_vertex(v)
	var flag := StandardMaterial3D.new()
	flag.vertex_color_use_as_albedo = true
	flag.roughness = 0.8
	flag.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mats["flag"] = flag

	var cone := CylinderMesh.new()
	cone.top_radius = 0.03
	cone.bottom_radius = 0.17
	cone.height = 0.5
	cone.radial_segments = 10
	cone.rings = 1
	_mats["cone"] = _metal(Color(1.0, 0.36, 0.06), 0.0, 0.45)
	for f in features:
		if f["type"] == "kicker":
			for side in [-1.0, 1.0]:
				var x: float = f["x"] + side * (f["w"] * 0.5 + 0.5)
				var s: float = f["s0"] - 1.0
				_append("cone", cone, Transform3D(Basis(), world(x, s, 0.25)))
	_commit("props")


func _build_furniture() -> void:
	## The strip between the riding area and the buildings: benches with their backs to the
	## wall, café tables, potted plants, bins, utility boxes, planters, barrels by the shops.
	## Also manholes in the road, lifebuoys on the sea railing, a whale statue at the finish.
	var xf: Dictionary = {}
	var add := func(key: String, t: Transform3D) -> void:
		if not xf.has(key):
			xf[key] = []
		xf[key].append(t)
	var palm_s: Array = []
	for p in posts:
		if absf(p.x) > BOUND:
			palm_s.append(Vector2(signf(p.x), p.y))
	for side: float in [-1.0, 1.0]:
		var face := Basis(Vector3.UP, -side * PI * 0.5)    # local +Z toward the street
		var s := -40.0
		var end := END_S - 3.0 if side < 0.0 else 297.0
		while s < end:
			var span := 2.6
			var clear := not (stairs_at(s - 1.0) or stairs_at(s + span + 1.0))
			clear = clear and not (s > FINISH_S - 36.0 and s < FINISH_S + 20.0)
			for ps: Vector2 in palm_s:
				if ps.x == side and ps.y > s - 1.0 and ps.y < s + span + 1.0:
					clear = false
			if not clear:
				s += 1.0
				continue
			var y := H(s + span * 0.5) + CURB
			var wall_x := side * BUILD_X
			var r := _rng.randf()
			var at := func(inset: float, ds: float) -> Vector3:
				return Vector3(wall_x - side * inset, H(s + ds) + CURB, -(s + ds))
			if r < 0.2:
				add.call("bench", Transform3D(face, at.call(0.45, 1.25)))
			elif r < 0.34:
				add.call("cafe", Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), at.call(1.0, 1.2)))
			elif r < 0.48:
				add.call("plant", Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), at.call(0.4, 0.4)))
				if _rng.randf() < 0.6:
					add.call("plant", Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), at.call(0.4, 1.3)))
			elif r < 0.58:
				add.call("bin" if _rng.randf() < 0.7 else "bin_rust", Transform3D(face * Basis(Vector3.UP, _rng.randf_range(-0.3, 0.3)), at.call(0.35, 0.5)))
			elif r < 0.66:
				add.call("utility", Transform3D(face, at.call(0.25, 0.4)))
			elif r < 0.76:
				add.call("planter", Transform3D(face * Basis(Vector3.UP, PI * 0.5), at.call(0.35, 0.8)))
			elif r < 0.82:
				add.call("barrel" if _rng.randf() < 0.5 else "barrel_blue", Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), at.call(0.4, 0.4)))
				add.call("crate", Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), at.call(0.9, 1.1)))
				add.call("box", Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), at.call(0.35, 1.2)))
			else:
				span = 1.0
			s += span + _rng.randf_range(1.0, 4.5)
	# Manholes on the asphalt, sunk to sit flush.
	for sec in _sections:
		if sec[2] != "asphalt":
			continue
		var ms: float = sec[0] + 8.0
		while ms < float(sec[1]) - 4.0:
			var mx := _rng.randf_range(-6.5, 6.5)
			add.call("manhole", Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), world(mx, ms, -0.055)))
			ms += _rng.randf_range(22.0, 40.0)
	# Lifebuoys on the sea railing, facing the street.
	var ls := 318.0
	while ls < END_S - 6.0:
		add.call("lifebuoy", Transform3D(Basis(Vector3.UP, -PI * 0.5), world(BOUND - 0.22, ls, CURB + 0.2)))
		ls += 34.0
	add.call("whale", Transform3D(Basis(Vector3.UP, PI * 0.3).scaled(Vector3.ONE * 1.6), world(-11.0, 562.0, CURB + 0.6)))
	_box_vc(world(-11.8, 561.2, CURB), world(-10.2, 562.8, CURB + 0.6), Color(0.8, 0.78, 0.74).srgb_to_linear(), "roof")
	# Concrete barriers closing the street behind the start.
	var bx := -HALF_W + 0.8
	while bx < HALF_W:
		add.call("barrier", Transform3D(Basis(Vector3.UP, _rng.randf_range(-0.08, 0.08)), world(bx, -6.0, 0.0)))
		bx += 1.62
	for key: String in xf:
		_props(key, xf[key], 1, key != "manhole")


func _palm_mesh() -> ArrayMesh:
	## A date palm: tapered, slightly bent trunk with a scaly bark texture (generated, with a
	## normal map), a crown of arching fronds cut out of a leaflet texture, a few dry fronds
	## hanging below and a cluster of dates.
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 12
	var sides := 10
	var height := 7.8
	var pts: Array[Vector3] = []
	for i in segs + 1:
		var t := float(i) / segs
		pts.append(Vector3(0.9 * t * t, height * t, 0.25 * sin(t * 2.0)))
	for i in segs:
		var r0 := lerpf(0.26, 0.15, pow(float(i) / segs, 0.7))
		var r1 := lerpf(0.26, 0.15, pow(float(i + 1) / segs, 0.7))
		for k in sides:
			var a0 := TAU * k / sides
			var a1 := TAU * (k + 1) / sides
			var n0 := Vector3(cos(a0), 0, sin(a0))
			var n1 := Vector3(cos(a1), 0, sin(a1))
			var quad := [pts[i] + n0 * r0, pts[i] + n1 * r0, pts[i + 1] + n1 * r1, pts[i + 1] + n0 * r1]
			var nn := [n0, n1, n1, n0]
			var v0 := pts[i].y / 0.9
			var v1 := pts[i + 1].y / 0.9
			var uv := [Vector2(float(k) / sides, v0), Vector2(float(k + 1) / sides, v0), Vector2(float(k + 1) / sides, v1), Vector2(float(k) / sides, v1)]
			for j in [0, 2, 1, 0, 3, 2]:
				st.set_normal(nn[j])
				st.set_uv(uv[j])
				st.add_vertex(quad[j])
	st.generate_tangents()
	st.commit(mesh)
	var bark := StandardMaterial3D.new()
	var bt := _palm_bark()
	bark.albedo_texture = bt[0]
	bark.normal_enabled = true
	bark.normal_texture = bt[1]
	bark.normal_scale = 1.4
	bark.roughness = 0.9
	bark.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mesh.surface_set_material(0, bark)

	# Fronds: arching strips with the leaflet texture; dry ones droop below the crown.
	var top := pts[segs]
	var fs := SurfaceTool.new()
	fs.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := 22
	for f in count + 5:
		var dry := f >= count
		var ang := TAU * f / count + 0.37 * sin(f * 2.3)
		var lift: float = [2.4, 1.5, 0.8][f % 3]
		if dry:
			ang = TAU * (f - count) / 5.0 + 0.4
			lift = -1.2
		var dir := Vector3(cos(ang), 0, sin(ang))
		var side := dir.cross(Vector3.UP).normalized()
		var length := (3.0 + 0.8 * sin(f * 1.7) + 0.3 * float(f % 3)) * (0.8 if dry else 1.0)
		var steps := 10
		var shade := Color(0.55, 0.42, 0.25) if dry else Color(1, 1, 1)
		for i in steps:
			var t0 := float(i) / steps
			var t1 := float(i + 1) / steps
			var p0 := top + dir * length * t0 * (0.6 if dry else 1.0) + Vector3.UP * (lift * t0 - 2.3 * t0 * t0)
			var p1 := top + dir * length * t1 * (0.6 if dry else 1.0) + Vector3.UP * (lift * t1 - 2.3 * t1 * t1)
			var w := 0.8
			# The two leaflet rows fold up a little from the midrib (a shallow V).
			var fold := Vector3.UP * 0.14
			var q := [p0 - side * w + fold, p0, p1, p1 - side * w + fold, p0 + side * w + fold, p1 + side * w + fold]
			var u0 := t0
			var u1 := t1
			var uvs := [Vector2(u0, 0.0), Vector2(u0, 0.5), Vector2(u1, 0.5), Vector2(u1, 0.0), Vector2(u0, 1.0), Vector2(u1, 1.0)]
			for tri in [[0, 2, 1], [0, 3, 2], [1, 5, 4], [1, 2, 5]]:
				var n: Vector3 = (q[tri[2]] - q[tri[0]]).cross(q[tri[1]] - q[tri[0]]).normalized()
				if n.y < 0.0:
					n = -n
				for j: int in tri:
					fs.set_color(shade)
					fs.set_normal(n)
					fs.set_uv(uvs[j])
					fs.add_vertex(q[j])
	fs.commit(mesh)
	var leaf := StandardMaterial3D.new()
	leaf.albedo_texture = _palm_frond_texture()
	leaf.vertex_color_use_as_albedo = true
	leaf.alpha_scissor_threshold = 0.5
	leaf.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	leaf.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
	leaf.cull_mode = BaseMaterial3D.CULL_DISABLED
	leaf.roughness = 0.65
	leaf.backlight_enabled = true
	leaf.backlight = Color(0.35, 0.45, 0.12)
	leaf.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mesh.surface_set_material(1, leaf)
	# Dates hanging under the crown.
	var ds := SurfaceTool.new()
	ds.begin(Mesh.PRIMITIVE_TRIANGLES)
	var date := SphereMesh.new()
	date.radius = 0.05
	date.height = 0.1
	date.radial_segments = 6
	date.rings = 3
	for k in 18:
		var a := _rng.randf() * TAU
		var p := top + Vector3(cos(a) * _rng.randf_range(0.15, 0.35), -_rng.randf_range(0.2, 0.75), sin(a) * _rng.randf_range(0.15, 0.35))
		ds.append_from(date, 0, Transform3D(Basis(), p))
	ds.commit(mesh)
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color(0.62, 0.3, 0.08)
	dm.roughness = 0.5
	mesh.surface_set_material(2, dm)
	return mesh


func _palm_bark() -> Array:
	## Overlapping leaf-base scales in a diamond pattern: height -> albedo and a normal map.
	var w := 128
	var h := 256
	var hgt := PackedFloat32Array()
	hgt.resize(w * h)
	for y in h:
		for x in w:
			# Rows of scales, every other row shifted half a scale.
			var row := floori(y / 16.0)
			var fx := fposmod(x / 16.0 + (0.5 if row % 2 == 1 else 0.0), 1.0)
			var fy := fposmod(y / 16.0, 1.0)
			var scale := clampf(1.0 - pow(absf(fx - 0.5) * 2.0, 2.0) * 0.8 - fy * 0.6, 0.0, 1.0)
			hgt[y * w + x] = scale + _rng.randf() * 0.08
	var alb := Image.create_empty(w, h, false, Image.FORMAT_RGB8)
	var nrm := Image.create_empty(w, h, false, Image.FORMAT_RGB8)
	for y in h:
		for x in w:
			var v := hgt[y * w + x]
			var c := Color(0.2, 0.16, 0.12).lerp(Color(0.48, 0.4, 0.31), v)
			alb.set_pixel(x, y, c)
			var dx := hgt[y * w + (x + 1) % w] - hgt[y * w + (x - 1 + w) % w]
			var dy := hgt[((y + 1) % h) * w + x] - hgt[((y - 1 + h) % h) * w + x]
			var n := Vector3(-dx * 2.0, dy * 2.0, 1.0).normalized()
			nrm.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5))
	alb.generate_mipmaps()
	nrm.generate_mipmaps()
	return [ImageTexture.create_from_image(alb), ImageTexture.create_from_image(nrm)]


func _palm_frond_texture() -> ImageTexture:
	## u along the frond (0 base .. 1 tip), v across (0.5 = midrib): slender leaflets angled
	## toward the tip, with transparent gaps between them.
	var w := 512
	var h := 256
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var dark := Color(0.13, 0.3, 0.1)
	var light := Color(0.42, 0.58, 0.2)
	var n := 44
	for i in n:
		var u := lerpf(0.06, 0.98, float(i) / (n - 1))
		var len := 0.48 * sin(PI * minf(u * 1.1, 1.0)) + 0.05
		for half: float in [-1.0, 1.0]:
			var x0 := u * w
			var y0 := h * 0.5
			var x1 := x0 + len * w * 0.25
			var y1 := y0 + half * len * h
			var steps := 60
			for k in steps:
				var t := float(k) / steps
				var px := lerpf(x0, x1, t)
				var py := lerpf(y0, y1, t)
				var thick := 5.0 * (1.0 - t * 0.8)
				var col := dark.lerp(light, t * 0.7 + _rng.randf() * 0.15)
				for dy in range(-ceili(thick), ceili(thick) + 1):
					var yy := int(py) + dy
					var xx := int(px)
					if yy >= 0 and yy < h and xx >= 0 and xx < w:
						img.set_pixel(xx, yy, Color(col, 1.0))
	# Midrib.
	for x in w:
		for dy in range(-3, 4):
			img.set_pixel(x, h / 2 + dy, Color(0.4, 0.42, 0.2, 1.0))
	return ImageTexture.create_from_image(RSMeshUtil.coverage_mipmaps(img, 0.5))


func _lamp_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pole := CylinderMesh.new()
	pole.top_radius = 0.06
	pole.bottom_radius = 0.09
	pole.height = 6.2
	pole.radial_segments = 8
	pole.rings = 1
	st.append_from(pole, 0, Transform3D(Basis(), Vector3(0, 3.1, 0)))
	var arm := BoxMesh.new()
	arm.size = Vector3(0.08, 0.08, 1.5)
	st.append_from(arm, 0, Transform3D(Basis(), Vector3(0, 6.1, -0.7)))
	var head := BoxMesh.new()
	head.size = Vector3(0.36, 0.14, 0.6)
	st.append_from(head, 0, Transform3D(Basis(), Vector3(0, 6.05, -1.35)))
	var mesh := st.commit()
	mesh.surface_set_material(0, RSMeshUtil.toon_material(Color(0.22, 0.3, 0.3), 0.4, 0.5))
	var bulb := SurfaceTool.new()
	bulb.begin(Mesh.PRIMITIVE_TRIANGLES)
	var glow := BoxMesh.new()
	glow.size = Vector3(0.28, 0.04, 0.5)
	bulb.append_from(glow, 0, Transform3D(Basis(), Vector3(0, 5.97, -1.35)))
	bulb.commit(mesh)
	var em := StandardMaterial3D.new()
	em.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	em.albedo_color = Color(1.0, 0.86, 0.6)
	em.emission_enabled = true
	em.emission = Color(1.0, 0.75, 0.4)
	em.emission_energy_multiplier = 2.0
	mesh.surface_set_material(1, em)
	return mesh


func _build_arches() -> void:
	_arch(START_S - 2.0, "START  起点", false)   # no-i18n: bilingual sign in the world
	_arch(FINISH_S, "FINISH  终点", true)   # no-i18n: bilingual sign in the world
	# Finish crowd: two banks of fans behind barriers, bouncing (crowd shader).
	var person := RSCrowd.person_mesh()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = person
	var xfs: Array[Transform3D] = []
	for side in [-1.0, 1.0]:
		var s := FINISH_S - 32.0
		while s < FINISH_S + 16.0:
			for row in 3:
				var x: float = side * (HALF_W + 1.0 + row * 0.75 + _rng.randf_range(-0.15, 0.15))
				var ss := s + _rng.randf_range(-0.25, 0.25) + row * 0.3
				var face := Basis(Vector3.UP, -side * PI * 0.5 + _rng.randf_range(-0.4, 0.4))
				xfs.append(Transform3D(face.scaled(Vector3.ONE * _rng.randf_range(0.9, 1.08)), world(x, ss, CURB + row * 0.25)))
			s += 0.7
	mm.instance_count = xfs.size()
	var shirt := [Color(0.95, 0.3, 0.3), Color(0.2, 0.5, 0.95), Color(1.0, 0.8, 0.2), Color(0.2, 0.75, 0.4), Color(0.95, 0.95, 0.95),
		Color(0.6, 0.35, 0.8), Color(0.1, 0.12, 0.16), Color(1.0, 0.55, 0.2)]
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
		mm.set_instance_color(i, (shirt[_rng.randi_range(0, shirt.size() - 1)] as Color))
		mm.set_instance_custom_data(i, Color(_rng.randf(), _rng.randf_range(0.7, 1.3), 0, 0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)
	# Crowd barriers along the curb.
	for side in [-1.0, 1.0]:
		var s := FINISH_S - 33.0
		while s < FINISH_S + 16.0:
			var x: float = side * (HALF_W + 0.45)
			_box_vc(world(x - 0.04, s, CURB) + Vector3(0, 0, 0), world(x + 0.04, s + 2.2, CURB + 1.0), Color(0.85, 0.86, 0.88).srgb_to_linear())
			s += 2.4
	_commit("crowd_barriers")


func _arch(s: float, text: String, checkered: bool) -> void:
	var y := H(s) + CURB
	var pillar := RSMeshUtil.rounded_box(Vector3(0.7, 6.4, 0.7), 0.12)
	var mat := _metal(Color(0.12, 0.13, 0.17), 0.6, 0.35)
	for side in [-1.0, 1.0]:
		var mi := MeshInstance3D.new()
		mi.mesh = pillar
		mi.material_override = mat
		mi.position = Vector3(side * (HALF_W + 0.6), y + 3.2, -s)
		add_child(mi)
	var banner := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.0 * HALF_W + 1.9, 1.3, 0.35)
	banner.mesh = bm
	var bmat := StandardMaterial3D.new()
	bmat.albedo_texture = _checker_texture() if checkered else null
	bmat.albedo_color = Color.WHITE if checkered else Color(0.95, 0.42, 0.18)
	bmat.uv1_scale = Vector3(6, 2, 1)
	banner.material_override = bmat
	banner.position = Vector3(0, y + 6.2, -s)
	add_child(banner)
	for face in [1.0, -1.0]:
		var label := Label3D.new()
		label.text = text
		label.font = RSUi.font()
		label.font_size = 96
		label.pixel_size = 0.009
		label.outline_size = 24
		label.modulate = Color.WHITE
		label.outline_modulate = Color(0.08, 0.08, 0.12)
		label.position = Vector3(0, y + 6.2, -s + face * 0.19)
		label.rotation.y = 0.0 if face > 0.0 else PI
		add_child(label)


func _checker_texture() -> ImageTexture:
	var img := Image.create_empty(16, 16, false, Image.FORMAT_RGB8)
	for y in 16:
		for x in 16:
			img.set_pixel(x, y, Color.WHITE if (x / 4 + y / 4) % 2 == 0 else Color(0.08, 0.08, 0.1))
	return ImageTexture.create_from_image(img)


static func setup_environment(parent: Node) -> DirectionalLight3D:
	## Golden hour by the sea: a scanned sky (Poly Haven HDRI) lights and reflects the scene;
	## its sun sits ahead-right, low over the water, and the sun light matches it.
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var pano := PanoramaSkyMaterial.new()
	pano.panorama = load(HDRI)
	pano.energy_multiplier = 0.85
	var sky := Sky.new()
	sky.sky_material = pano
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.7
	env.ambient_light_sky_contribution = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	env.ssao_enabled = true
	env.ssao_radius = 1.0
	env.ssao_intensity = 1.6
	env.ssao_detail = 0.6
	env.ssil_enabled = true
	env.ssil_radius = 4.0
	env.ssil_intensity = 0.8
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.1
	# Screen-space reflections: shop windows and the sea pick up the street, not only the sky.
	env.ssr_enabled = true
	env.ssr_max_steps = 56
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.3
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.1
	env.adjustment_contrast = 1.08
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = Color(0.78, 0.76, 0.76)
	env.fog_sun_scatter = 0.15
	env.fog_density = 0.0005
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.35
	var we := WorldEnvironment.new()
	we.environment = env
	parent.add_child(we)

	var sun := DirectionalLight3D.new()
	# Same bearing as the HDRI's sun (ahead-right) but higher, so light reaches the street
	# between the buildings instead of leaving it all in shade.
	var to_sun := TO_SUN.normalized()
	sun.basis = Basis.looking_at(-to_sun, Vector3.UP)
	sun.light_color = Color(1.0, 0.8, 0.6)
	sun.light_energy = 2.8
	sun.light_angular_distance = 0.6
	sun.shadow_enabled = true
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.0
	sun.shadow_blur = 1.2
	sun.directional_shadow_max_distance = 110.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	parent.add_child(sun)
	return sun
