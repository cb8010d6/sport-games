extends Node
## Independent analytic fixtures for the unintegrated finite-triangle kernel.

const STEP := 1.0 / 120.0  ## s; the kernel accepts endpoints, never changes timestep
const GOLDEN := "res://tests/data/golf_sweep.json"
var _checks := 0
var _failures := 0
var _sweep := RSGolfSweep.new()


func _ready() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("FAIL: " + message)


func _v(row: Array) -> Vector3:
	return Vector3(row[0], row[1], row[2])


func _cast(row: Dictionary, out: RSGolfContact, offset := Vector3.ZERO) -> bool:
	return _sweep.cast_triangle(_v(row["start"]) + offset, _v(row["end"]) + offset, float(row["radius"]), _v(row["triangle"][0]) + offset, _v(row["triangle"][1]) + offset, _v(row["triangle"][2]) + offset, out, bool(row.get("front_only", false)), 42)


func _snapshot(out: RSGolfContact) -> Array:
	return [out.status, out.feature_id, out.part, out.part_id, out.fraction, out.centre, out.point, out.normal, out.depth, out.flags]


func _run() -> void:
	var invalid := OS.get_environment("RS_GOLF_SWEEP_INVALID")
	if not invalid.is_empty():
		_invalid_case(invalid)
		print("RS_GOLF_SWEEP_REJECTION: %d checks, %d failures" % [_checks, _failures])
		get_tree().quit(1)
		return
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN))
	var out := RSGolfContact.new()
	for row: Dictionary in data["cases"]:
		var hit := _cast(row, out)
		var expected_status: int = RSGolfContact.Status[row["status"]]
		_check(out.status == expected_status and hit == (expected_status != RSGolfContact.Status.MISS), row["id"] + " status")
		if not hit:
			_check(_snapshot(out) == _snapshot(RSGolfContact.new()), row["id"] + " clears every old result field")
			continue
		_check(absf(out.fraction - float(row["fraction"])) <= 0.0000001 and out.feature_id == 42, row["id"] + " analytic fraction")
		_check(out.point.distance_to(_v(row["point"])) <= 0.000001 and out.normal.distance_to(_v(row["normal"])) <= 0.000001, row["id"] + " finite point and geometric normal")
		var expected_flags := 0
		for flag: String in row["flags"]:
			expected_flags |= int(RSGolfContact.Flag[flag])
		_check(out.part == int(RSGolfContact.Part[row["part"]]) and out.part_id == int(row["part_id"]) and out.flags == expected_flags, row["id"] + " topology and t0 classification")
		_check(absf(out.depth - float(row.get("depth", 0.0))) <= 0.000001, row["id"] + " penetration diagnostic")
	_snapshot_cases(data["cases"])
	_translated_cases(data["cases"])
	_skinny_cases()
	_skinny_boundaries()
	_check(is_equal_approx(0.4 / STEP, 48.0), "ridge fixture spans48m/s in one120Hz step")
	print("RS_GOLF_SWEEP_TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)


func _snapshot_cases(rows: Array) -> void:
	var first := RSGolfContact.new()
	_cast(rows[0], first)
	var saved := RSGolfContact.new()
	saved.copy_from(first)
	var expected := _snapshot(saved)
	_cast(rows[5], first)
	_check(_snapshot(saved) == expected and first.status == RSGolfContact.Status.MISS, "caller snapshot survives later miss/reset")
	var second := RSGolfContact.new()
	_cast(rows[1], second)
	var second_value := _snapshot(second)
	_cast(rows[2], first)
	_check(_snapshot(second) == second_value and _snapshot(saved) == expected, "workspace never retains or overwrites another caller result")
	var repeated := _snapshot(first)
	_cast(rows[2], first)
	_check(_snapshot(first) == repeated, "same shared-feature input has stable repeatable selection")


func _translated_cases(rows: Array) -> void:
	var offset := Vector3(300, 10, -500)
	var out := RSGolfContact.new()
	for i in [0, 1, 2, 18, 19]:
		var row: Dictionary = rows[i]
		_check(_cast(row, out, offset), "translated fixture still hits")
		# These bounds concern float32 storage of represented inputs/outputs, NOT shape inflation.
		_check(out.point.distance_to(_v(row["point"]) + offset) <= 0.00025 and absf(out.fraction - float(row["fraction"])) <= 0.0001, "course-scale translation stays below1mm spatial storage budget")
		_check(out.normal.distance_to(_v(row["normal"])) <= 0.002, "translated geometric normal follows the represented finite triangle")


func _skinny_cases() -> void:
	# Independently known planes y=0 and 3y-4x=0; no production barycentrics form the oracle.
	for width: float in [0.001, 0.0001, 0.00001, 0.000001, 0.0000003, 0.0000002]:
		_skinny_case(Vector3.RIGHT, width, 0.0, 1.0)
	for width: float in [0.001, 0.0001, 0.00001, 0.000001]:
		_skinny_case(Vector3(3, 4, 0), width, -0.8, 0.6)


func _skinny_case(b: Vector3, width: float, nx: float, ny: float) -> void:
	var radius := 0.02135
	var c := Vector3(b.x, b.y, width)
	var on_face := Vector3(0.75 * b.x, 0.75 * b.y, 0.25 * width)
	var start := Vector3(on_face.x + nx, on_face.y + ny, on_face.z)
	var end := Vector3(on_face.x - nx, on_face.y - ny, on_face.z)
	# Compute the plane TOI from the represented endpoints and the analytic unit normal.
	var dx := float(end.x) - start.x
	var dy := float(end.y) - start.y
	var expected_time := (radius - nx * start.x - ny * start.y) / (nx * dx + ny * dy)
	var cx := float(start.x) + expected_time * dx
	var cy := float(start.y) + expected_time * dy
	var expected_centre := Vector3(cx, cy, start.z)
	var expected_point := Vector3(cx - radius * nx, cy - radius * ny, start.z)
	var out := RSGolfContact.new()
	var label := "skinny plane b=%s width=%s" % [b, width]
	var hit := _sweep.cast_triangle(start, end, radius, Vector3.ZERO, b, c, out)
	_check(hit and out.status == RSGolfContact.Status.HIT, label + " face hit")
	_check(absf(out.fraction - expected_time) <= 1.0e-9 and out.point.distance_to(expected_point) <= 1.0e-6 and out.centre.distance_to(expected_centre) <= 1.0e-6, label + " independent plane TOI and points")
	_check(out.part == RSGolfContact.Part.FACE and out.part_id == 0 and out.normal.distance_to(Vector3(nx, ny, 0)) <= 1.0e-6 and out.flags == RSGolfContact.Flag.APPROACHING, label + " face topology and separation normal")
	hit = _sweep.cast_triangle(on_face, on_face, radius, Vector3.ZERO, b, c, out)
	_check(hit and out.status == RSGolfContact.Status.OVERLAP and out.fraction == 0.0 and out.point.distance_to(on_face) <= 1.0e-12, label + " initial on-face overlap")
	var expected_flags := RSGolfContact.Flag.START_OVERLAP | RSGolfContact.Flag.STATIONARY | RSGolfContact.Flag.NORMAL_UNDEFINED
	_check(out.normal == Vector3.ZERO and out.flags == expected_flags and absf(out.depth - radius) <= 1.0e-12, label + " true zero distance never invents a normal")
	hit = _sweep.cast_triangle(start, end, radius, Vector3.ZERO, c, b, out)
	_check(hit and absf(out.fraction - expected_time) <= 1.0e-9 and out.part == RSGolfContact.Part.FACE and out.normal.distance_to(Vector3(nx, ny, 0)) <= 1.0e-6 and out.flags == (RSGolfContact.Flag.APPROACHING | RSGolfContact.Flag.BACKFACE), label + " reversed winding keeps two-sided face contact")
	hit = _sweep.cast_triangle(start, end, radius, Vector3.ZERO, c, b, out, true)
	_check(not hit and _snapshot(out) == _snapshot(RSGolfContact.new()), label + " reversed front-only rejects back approach")
	var reverse_time := (-radius - nx * end.x - ny * end.y) / (-nx * dx - ny * dy)
	hit = _sweep.cast_triangle(end, start, radius, Vector3.ZERO, c, b, out, true)
	_check(hit and absf(out.fraction - reverse_time) <= 1.0e-9 and out.normal.distance_to(Vector3(-nx, -ny, 0)) <= 1.0e-6 and out.flags == RSGolfContact.Flag.APPROACHING, label + " reversed front-only accepts its front")
	hit = _sweep.cast_triangle(on_face, on_face, radius, Vector3.ZERO, c, b, out, true)
	_check(hit and out.status == RSGolfContact.Status.OVERLAP and out.normal == Vector3.ZERO and out.flags == expected_flags and absf(out.depth - radius) <= 1.0e-12, label + " reversed on-face overlap has undefined normal")


func _skinny_boundaries() -> void:
	for size: Vector2 in [Vector2(1, 0.001), Vector2(1, 0.000001), Vector2(1, 0.0000002), Vector2(0.001, 0.0000000002)]:
		var b := Vector3(size.x, 0, 0)
		var c := Vector3(size.x, 0, size.y)
		for back_winding: bool in [false, true]:
			_boundary_case(Vector3(0.5 * b.x, 0, 0), RSGolfContact.Part.EDGE, 2 if back_winding else 0, b, c, back_winding)
			_boundary_case(Vector3(b.x, 0, 0.5 * c.z), RSGolfContact.Part.EDGE, 1, b, c, back_winding)
			_boundary_case(Vector3(0.5 * b.x, 0, 0.5 * c.z), RSGolfContact.Part.EDGE, 0 if back_winding else 2, b, c, back_winding)
			_boundary_case(Vector3.ZERO, RSGolfContact.Part.VERTEX, 0, b, c, back_winding)
			_boundary_case(b, RSGolfContact.Part.VERTEX, 2 if back_winding else 1, b, c, back_winding)
			_boundary_case(c, RSGolfContact.Part.VERTEX, 1 if back_winding else 2, b, c, back_winding)


func _boundary_case(point: Vector3, part: RSGolfContact.Part, id: int, b: Vector3, c: Vector3, back_winding: bool) -> void:
	var start := point + Vector3.UP
	var end := point - Vector3.UP
	var first := c if back_winding else b
	var second := b if back_winding else c
	var out := RSGolfContact.new()
	var hit := _sweep.cast_triangle(start, end, 0.02135, Vector3.ZERO, first, second, out)
	var label := "skinny boundary width=%s point=%s reversed=%s" % [c.z, point, back_winding]
	_check(hit and out.status == RSGolfContact.Status.HIT and absf(out.fraction - 0.489325) <= 1.0e-9, label + " closed boundary TOI")
	_check(out.point == point and out.centre == Vector3(point.x, 0.02135, point.z) and out.normal == Vector3.UP, label + " exact represented points and normal")
	var flags := RSGolfContact.Flag.APPROACHING | (RSGolfContact.Flag.BACKFACE if back_winding else 0)
	_check(out.part == part and out.part_id == id and out.flags == flags, label + " boundary topology")
	var expected := _snapshot(out)
	_sweep.cast_triangle(start, end, 0.02135, Vector3.ZERO, first, second, out)
	_check(_snapshot(out) == expected, label + " repeated competing face/edge/vertex candidates are stable")


func _invalid_case(kind: String) -> void:
	var out := RSGolfContact.new()
	var start := Vector3(0.2, 1, 0.2)
	var a := Vector3.ZERO
	var b := Vector3.RIGHT
	var c := Vector3.BACK
	var radius := 0.02135
	if kind == "nan":
		start.x = NAN
	elif kind == "radius":
		radius = -1.0
	elif kind == "degenerate":
		b = a
	elif kind == "conditioning":
		c = Vector3(1, 0, 0.0000001)
	_check(not _sweep.cast_triangle(start, Vector3(0.2, -1, 0.2), radius, a, b, c, out), "invalid query fails")
	_check(out.status == RSGolfContact.Status.INVALID and out.fraction == INF and out.feature_id == -1 and out.flags == 0, "invalid cannot fabricate a hit or penalty")
