extends RefCounted


class LeftController extends RSController:
	func left_handed() -> bool:
		return true


static func _swing() -> Dictionary:
	return {
		"axis_world": Vector3.UP,
		"start_orientation": Quaternion(Vector3.UP, deg_to_rad(-30.0)),
		"peak_orientation": Quaternion.IDENTITY,
		"peak_rate": 8.5,
		"peak_msec": 1234,
		"id": 17,
		"epoch": 3,
	}


static func run(check: Callable) -> void:
	_directions(check)
	_height(check)
	_power(check)
	_face(check)
	_reference(check)
	_mirror(check)
	check.call(RSSwingClassifier.classify({}, Quaternion.IDENTITY).is_empty(), "missing swing fields return empty with one warning, without crashing")


static func _directions(check: Callable) -> void:
	var swing := _swing()
	var result := RSSwingClassifier.classify(swing, Quaternion.IDENTITY)
	check.call(result["side"] == RSSwingClassifier.Side.FOREHAND and result["toward"], "positive vertical rotation from the racket side is a forward forehand")
	swing["axis_world"] = Vector3.DOWN
	swing["start_orientation"] = Quaternion(Vector3.UP, deg_to_rad(30.0))
	result = RSSwingClassifier.classify(swing, Quaternion.IDENTITY)
	check.call(result["side"] == RSSwingClassifier.Side.BACKHAND and result["toward"], "negative vertical rotation from the opposite side is a forward backhand")
	swing["start_orientation"] = Quaternion(Vector3.UP, deg_to_rad(-30.0))
	check.call(not RSSwingClassifier.classify(swing, Quaternion.IDENTITY)["toward"], "outward rotation with the same sign as start yaw is a backswing")
	swing["start_orientation"] = Quaternion.IDENTITY
	check.call(not RSSwingClassifier.classify(swing, Quaternion.IDENTITY)["toward"], "rotation starting on the center line is a backswing")
	swing["axis_world"] = Vector3.UP
	for degrees: float in [14.99, 15.0, 15.01]:
		swing["start_orientation"] = Quaternion(Vector3.UP, deg_to_rad(-degrees))
		result = RSSwingClassifier.classify(swing, Quaternion.IDENTITY)
		check.call(result["toward"] == (degrees >= 15.0), "backswing minimum includes the boundary at %.2f degrees" % degrees)
	var p := RSSwingClassifier.Params.new()
	p.backswing_min = deg_to_rad(40.0)
	check.call(not RSSwingClassifier.classify(_swing(), Quaternion.IDENTITY, p)["toward"], "custom backswing minimum is respected")
	swing["axis_world"] = Vector3.ZERO
	check.call(not RSSwingClassifier.classify(swing, Quaternion.IDENTITY)["toward"], "zero vertical rotation cannot count as a forward stroke")


static func _height(check: Callable) -> void:
	var swing := _swing()
	var expected := [RSSwingClassifier.Height.HIGH, RSSwingClassifier.Height.MID, RSSwingClassifier.Height.LOW]
	var pitches := [45.0, 0.0, -30.0]
	for i in range(pitches.size()):
		swing["peak_orientation"] = Quaternion(Vector3.RIGHT, deg_to_rad(pitches[i]))
		check.call(RSSwingClassifier.classify(swing, Quaternion.IDENTITY)["height"] == expected[i], "peak front pitch %.0f degrees determines height" % pitches[i])
	var p := RSSwingClassifier.Params.new()
	p.high_pitch = deg_to_rad(50.0)
	p.low_pitch = deg_to_rad(-40.0)
	check.call(RSSwingClassifier.classify(swing, Quaternion.IDENTITY, p)["height"] == RSSwingClassifier.Height.MID, "custom low pitch changes the height band")
	swing["peak_orientation"] = Quaternion(Vector3.RIGHT, deg_to_rad(45.0))
	check.call(RSSwingClassifier.classify(swing, Quaternion.IDENTITY, p)["height"] == RSSwingClassifier.Height.MID, "custom high pitch changes the height band")
	p.high_pitch = 0.0
	p.low_pitch = 0.0
	swing["peak_orientation"] = Quaternion.IDENTITY
	check.call(RSSwingClassifier.classify(swing, Quaternion.IDENTITY, p)["height"] == RSSwingClassifier.Height.MID, "height thresholds are strict and the exact boundary stays MID")


static func _power(check: Callable) -> void:
	var swing := _swing()
	var rates := [3.0, 5.0, 8.5, 12.0, 14.0]
	var powers := [0.0, 0.0, 0.5, 1.0, 1.0]
	for i in range(rates.size()):
		swing["peak_rate"] = rates[i]
		var result := RSSwingClassifier.classify(swing, Quaternion.IDENTITY)
		check.call(is_equal_approx(result["power"], powers[i]), "peak rate %.1f maps linearly to bounded power" % rates[i])
		check.call(result["peak_rate"] == rates[i] and result["peak_msec"] == 1234 and result["id"] == 17 and result["epoch"] == 3, "classification preserves timing, speed and consumption identity")
	var p := RSSwingClassifier.Params.new()
	p.rate_min = 4.0
	p.rate_full = 8.0
	swing["peak_rate"] = 6.0
	check.call(is_equal_approx(RSSwingClassifier.classify(swing, Quaternion.IDENTITY, p)["power"], 0.5), "power uses the caller's adjustable rate endpoints")


static func _face(check: Callable) -> void:
	var swing := _swing()
	swing["peak_orientation"] = Quaternion(Vector3.RIGHT, deg_to_rad(20.0))
	var result := RSSwingClassifier.classify(swing, Quaternion.IDENTITY)
	check.call(absf(result["face_pitch"] - deg_to_rad(20.0)) < deg_to_rad(0.5), "positive handle pitch reports positive face_pitch within half a degree")
	check.call(is_zero_approx(result["face_roll"]) and result["face_normal"].is_equal_approx(Vector3.RIGHT), "rotation about the default normal preserves the normal but retains grip pitch")
	swing["peak_orientation"] = Quaternion(Vector3.BACK, deg_to_rad(25.0))
	result = RSSwingClassifier.classify(swing, Quaternion.IDENTITY)
	check.call(absf(result["face_roll"] - deg_to_rad(25.0)) < deg_to_rad(0.5) and is_zero_approx(result["face_pitch"]), "grip twist reports face_roll independently of pitch")
	check.call(result["face_normal"].is_equal_approx(Vector3(cos(deg_to_rad(25.0)), sin(deg_to_rad(25.0)), 0.0)), "face normal follows the peak orientation")
	var p := RSSwingClassifier.Params.new()
	p.face_axis = Vector3.UP
	result = RSSwingClassifier.classify(swing, Quaternion.IDENTITY, p)
	var q: Quaternion = swing["peak_orientation"]
	check.call(result["face_normal"].is_equal_approx(q * Vector3.UP), "caller-defined grip normal is transformed in the neutral reference frame")
	var before := swing.duplicate(true)
	RSSwingClassifier.classify(swing, Quaternion.IDENTITY, p)
	check.call(swing == before, "classifying never mutates the input dictionary")


static func _reference(check: Callable) -> void:
	var swing := _swing()
	swing["peak_orientation"] = Quaternion(Vector3.UP, deg_to_rad(15.0)) * Quaternion(Vector3.RIGHT, deg_to_rad(45.0)) * Quaternion(Vector3.BACK, deg_to_rad(20.0))
	var expected := RSSwingClassifier.classify(swing, Quaternion.IDENTITY)
	var neutral := Quaternion(Vector3.FORWARD, deg_to_rad(110.0)) * Quaternion(Vector3.UP, deg_to_rad(35.0))
	var axis: Vector3 = swing["axis_world"]
	var start: Quaternion = swing["start_orientation"]
	var peak: Quaternion = swing["peak_orientation"]
	swing["axis_world"] = neutral * axis
	swing["start_orientation"] = neutral * start
	swing["peak_orientation"] = neutral * peak
	var result := RSSwingClassifier.classify(swing, neutral)
	check.call(result["side"] == expected["side"] and result["toward"] == expected["toward"] and result["height"] == expected["height"], "side, forward direction and height use neutral coordinates even when world up differs")
	check.call(result["face_normal"].is_equal_approx(expected["face_normal"]), "face normal is expressed relative to neutral rather than world orientation")
	check.call(absf(result["face_pitch"] - expected["face_pitch"]) < deg_to_rad(0.5) and absf(result["face_roll"] - expected["face_roll"]) < deg_to_rad(0.5), "face pitch and roll remove neutral rotation")


static func _mirror_pose(q: Quaternion) -> Quaternion:
	return Quaternion(q.x, -q.y, -q.z, q.w)


static func _mirror(check: Callable) -> void:
	var controller := LeftController.new()
	var neutral := Quaternion(Vector3(1.0, 2.0, 3.0).normalized(), 0.4)
	for direction: float in [1.0, -1.0]:
		var right := _swing()
		right["axis_world"] = neutral * (Vector3.UP * direction)
		right["start_orientation"] = neutral * Quaternion(Vector3.UP, deg_to_rad(-30.0 * direction))
		right["peak_orientation"] = neutral * Quaternion(Vector3.RIGHT, deg_to_rad(20.0))
		var expected := RSSwingClassifier.classify(right, neutral)
		var right_axis: Vector3 = right["axis_world"]
		# First construct the physically mirrored left-hand raw action. Then apply
		# the controller's one input reflection, as the detector does before emitting.
		var raw_axis := Vector3(right_axis.x, -right_axis.y, -right_axis.z)
		var raw_start := _mirror_pose(right["start_orientation"])
		var raw_peak := _mirror_pose(right["peak_orientation"])
		var left := right.duplicate()
		left["axis_world"] = controller.motion_gyro(raw_axis)
		left["start_orientation"] = controller.motion_pose(raw_start)
		left["peak_orientation"] = controller.motion_pose(raw_peak)
		left["left_handed"] = true
		var result := RSSwingClassifier.classify(left, controller.motion_pose(_mirror_pose(neutral)))
		check.call(result["side"] == expected["side"] and result["toward"] == expected["toward"], "equivalent raw left/right actions classify alike after one input reflection")
		check.call(result["face_normal"].is_equal_approx(expected["face_normal"]) and is_equal_approx(result["power"], expected["power"]), "hand preference preserves peak face and power")
		right["left_handed"] = true
		check.call(RSSwingClassifier.classify(right, neutral) == expected, "handedness metadata never triggers a second reflection")
