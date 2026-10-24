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


func _invalid_case(kind: String) -> void:
	var out := RSGolfContact.new()
	var start := Vector3(0.2, 1, 0.2)
	var a := Vector3.ZERO
	var b := Vector3.RIGHT
	var radius := 0.02135
	if kind == "nan":
		start.x = NAN
	elif kind == "radius":
		radius = -1.0
	elif kind == "degenerate":
		b = a
	_check(not _sweep.cast_triangle(start, Vector3(0.2, -1, 0.2), radius, a, b, Vector3.BACK, out), "invalid query fails")
	_check(out.status == RSGolfContact.Status.INVALID and out.fraction == INF and out.feature_id == -1 and out.flags == 0, "invalid cannot fabricate a hit or penalty")
