class_name RSSwingClassifier
extends RefCounted
## Input poses and axes already include the controller's handedness reflection.
## In the neutral reference frame +Y is up and -Z is the player's forward direction.

enum Side { FOREHAND, BACKHAND }
enum Height { LOW, MID, HIGH }

const REQUIRED_KEYS := ["axis_world", "start_orientation", "peak_orientation", "peak_rate", "peak_msec", "id", "epoch"]


class Params:
	var rate_min := 5.0
	var rate_full := 12.0
	var high_pitch := deg_to_rad(35.0)
	var low_pitch := deg_to_rad(-20.0)
	var backswing_min := deg_to_rad(15.0)
	var face_axis := Vector3.RIGHT


static func classify(swing: Dictionary, neutral: Quaternion, params: Params = null) -> Dictionary:
	for key: String in REQUIRED_KEYS:
		if not swing.has(key):
			push_warning("RSSwingClassifier: missing swing field '%s'" % key)
			return {} # One warning per invalid input, including inputs missing several keys.
	var p := params if params != null else Params.new()
	var axis_world: Vector3 = swing["axis_world"]
	var start_orientation: Quaternion = swing["start_orientation"]
	var peak_orientation: Quaternion = swing["peak_orientation"]
	var peak_rate: float = swing["peak_rate"]
	var reference := neutral.inverse()
	var axis := reference * axis_world
	var start := reference * start_orientation
	var peak := reference * peak_orientation
	var start_front := start * Vector3.FORWARD
	var peak_front := peak * Vector3.FORWARD
	# Positive yaw turns the handle from -Z toward -X. Positive vertical rotation
	# is FOREHAND, so a forward stroke starts at negative yaw and turns toward zero.
	var start_yaw := atan2(-start_front.x, -start_front.z)
	# The inclusive boundary tolerates float rounding in quaternion/vector products.
	var enough_backswing := absf(start_yaw) >= p.backswing_min or is_equal_approx(absf(start_yaw), p.backswing_min)
	var toward := enough_backswing and start_yaw * axis.y < 0.0
	# Height follows the handle's front, independently of its yaw and axial twist.
	var pitch := asin(clampf(peak_front.y, -1.0, 1.0))
	var height := Height.MID
	if pitch > p.high_pitch:
		height = Height.HIGH
	elif pitch < p.low_pitch:
		height = Height.LOW
	# YXZ grip angles retain twist even when the face normal lies on the pitch
	# axis: rotating +20 degrees around RIGHT must still report +20 pitch.
	var grip_angles := peak.get_euler()
	return {
		"side": Side.FOREHAND if axis.y >= 0.0 else Side.BACKHAND,
		"height": height,
		"power": clampf((peak_rate - p.rate_min) / (p.rate_full - p.rate_min), 0.0, 1.0),
		"toward": toward,
		"face_normal": (peak * p.face_axis).normalized(),
		"face_pitch": grip_angles.x,
		"face_roll": grip_angles.z,
		"peak_rate": swing["peak_rate"],
		"peak_msec": swing["peak_msec"],
		"id": swing["id"],
		"epoch": swing["epoch"],
	}
