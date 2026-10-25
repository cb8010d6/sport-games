extends RefCounted


class LeftController extends RSController:
	func left_handed() -> bool:
		return true


static func _record(det: RSSwingDetector) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	det.swing_started.connect(func(_c: RSController) -> void: events.append({"kind": "started"}))
	det.swing_peaked.connect(func(_c: RSController, swing: Dictionary) -> void: events.append({"kind": "peaked", "swing": swing}))
	det.swing_finished.connect(func(_c: RSController, swing: Dictionary) -> void: events.append({"kind": "finished", "swing": swing}))
	return events


static func _push(c: RSController, t: float, g: Vector3, q: Quaternion = Quaternion.IDENTITY) -> void:
	c.push_sample(t, q, g, Vector3.UP * 9.8, Vector3.UP * 2.0)


static func _sample(det: RSSwingDetector, c: RSController, t: float, rate: float, q: Quaternion = Quaternion.IDENTITY) -> void:
	_push(c, t, Vector3.UP * rate, q)
	det.feed(c, 1)


static func run(check: Callable) -> void:
	_normal(check)
	_cursor(check)
	_restart(check)
	_gap(check)
	_reset(check)
	_backlog(check)
	_mirror(check)
	_fallback(check)


static func _normal(check: Callable) -> void:
	var c := RSController.new()
	var det := RSSwingDetector.new()
	var events := _record(det)
	var peak_pose := Quaternion(Vector3.RIGHT, 0.4)
	_sample(det, c, 10.0, 6.0)
	_sample(det, c, 10.02, 10.0, peak_pose)
	_sample(det, c, 10.04, 6.0)
	check.call(events.size() == 2 and events[0]["kind"] == "started" and events[1]["kind"] == "peaked", "swing peak is emitted before the end hold")
	check.call(det.is_swinging(), "peak confirmation keeps the swing active")
	if events.size() < 2:
		return
	var peak: Dictionary = events[1]["swing"]
	check.call(peak["peak_orientation"].is_equal_approx(peak_pose) and peak["peak_gyro"] == Vector3.UP * 10.0, "peak retains the peak sample pose and gyro")
	check.call(is_equal_approx(peak["start_time"], 10.0) and is_equal_approx(peak["peak_time"], 10.02), "swing timing stays in hub seconds")
	check.call(peak["peak_rate"] == 10.0 and peak["peak_lin_accel"] == 2.0, "peak rates retain their units")
	check.call(peak["axis_body"].is_equal_approx(Vector3.UP) and is_equal_approx(peak["axis_world"].length(), 1.0), "summary axes are normalized")
	check.call(peak["peak_msec"] == peak["received_msec"] - 20, "single-sample batch maps the earlier peak onto local monotonic time")
	_sample(det, c, 10.06, 9.0)
	_sample(det, c, 10.08, 1.0)
	_sample(det, c, 10.16, 0.0)
	check.call(events.size() == 3 and events[2]["kind"] == "finished", "a swing emits exactly one candidate and one finish")
	if events.size() < 3:
		return
	var finished: Dictionary = events[2]["swing"]
	check.call(peak["id"] == finished["id"] and peak["epoch"] == finished["epoch"] and peak["epoch"] == det.epoch(), "peak and finish share their id and epoch")
	check.call(is_equal_approx(finished["duration"], 0.16) and finished["end_orientation"] == Quaternion.IDENTITY, "existing finished duration and end pose remain compatible")
	check.call(finished["angle"] > peak["angle"] and not det.is_swinging(), "finish carries the completed angular sweep")
	_sample(det, c, 10.20, 6.0)
	check.call(events.size() == 3, "finished swing keeps the existing hub-time cooldown")
	_sample(det, c, 10.40, 6.0)
	_sample(det, c, 10.42, 9.0)
	_sample(det, c, 10.44, 5.0)
	check.call(events.size() == 5 and events[4]["swing"]["id"] > peak["id"], "new swings receive increasing ids")


static func _cursor(check: Callable) -> void:
	var c := RSController.new()
	var det := RSSwingDetector.new()
	var events := _record(det)
	_push(c, 20.0, Vector3.UP * 6.0)
	_push(c, 20.02, Vector3.UP * 10.0)
	det.feed(c, 2)
	det.feed(c, 2)
	check.call(det.feed_new(c) == 0 and events.size() == 1, "feed and feed_new share a cursor for an already consumed batch")
	_push(c, 20.04, Vector3.UP * 6.0)
	check.call(det.feed_new(c) == 1 and events.size() == 2, "feed_new consumes only the newly appended history sample")
	_push(c, 20.04, Vector3.ZERO)
	_push(c, 20.03, Vector3.ZERO)
	check.call(det.feed_new(c) == 0 and det.epoch() == 0 and events.size() == 2, "equal and slightly older hub times are ignored without resetting")
	det.feed(c, c.history_size())
	check.call(det.feed_new(c) == 0 and events.size() == 2, "ignored samples still advance the arrival cursor")
	_push(c, 19.90, Vector3.ZERO)
	_push(c, 20.06, Vector3.ZERO)
	_push(c, 20.14, Vector3.ZERO)
	check.call(det.feed_new(c) == 2 and events.size() == 3, "fresh batch span excludes retained history and ignored backwards samples")
	var batch_c := RSController.new()
	var batch_det := RSSwingDetector.new()
	var batch_events := _record(batch_det)
	_push(batch_c, 30.0, Vector3.UP * 6.0)
	_push(batch_c, 30.02, Vector3.UP * 10.0)
	_push(batch_c, 30.04, Vector3.UP * 6.0)
	_push(batch_c, 30.06, Vector3.UP * 5.0)
	check.call(batch_det.feed_new(batch_c) == 4, "feed_new processes all new increasing samples")
	if batch_events.size() >= 2:
		var peak: Dictionary = batch_events[1]["swing"]
		check.call(peak["peak_msec"] == peak["received_msec"] - 40, "peak_msec uses the last sample of the whole received batch")
	else:
		check.call(false, "fresh multi-sample batch confirms a peak")
	# Overwrite the saved ring position: timestamp filtering must still prevent
	# duplicates, and the next small batch must not inherit the backlog's span.
	for i in range(RSController.HISTORY + 2):
		_push(batch_c, 31.0 + i * 0.005, Vector3.ZERO)
	check.call(batch_det.feed_new(batch_c) == batch_c.history_size(), "an overwritten ring cursor consumes the available backlog once")
	check.call(batch_det.feed_new(batch_c) == 0, "a wrapped ring cannot replay an already consumed backlog")
	_push(batch_c, batch_c.sample_time + 0.02, Vector3.ZERO)
	check.call(batch_det.feed_new(batch_c) == 1, "ring-wrap recovery leaves a usable cursor for the next fresh sample")


static func _restart(check: Callable) -> void:
	var c := RSController.new()
	var det := RSSwingDetector.new()
	det.cooldown = 0.0
	var events := _record(det)
	_sample(det, c, 50.0, 6.0)
	_sample(det, c, 50.02, 10.0)
	_push(c, 1.0, Vector3.ZERO)
	check.call(det.feed_new(c) == 1 and det.epoch() == 1 and not det.is_swinging(), "hub rollback over one second cancels the old epoch")
	check.call(det.feed_new(c) == 0 and det.epoch() == 1, "retained old-era history cannot reset or replay again")
	_sample(det, c, 1.02, 6.0)
	_sample(det, c, 1.04, 10.0)
	_sample(det, c, 1.06, 6.0)
	check.call(events.size() == 3 and events[2]["kind"] == "peaked" and events[2]["swing"]["epoch"] == 1 and events[2]["swing"]["id"] == 2, "new hub-era samples produce only a new swing candidate")
	check.call(det.feed_new(c) == 0, "mixed feed entry points do not replay a restarted hub batch")


static func _gap(check: Callable) -> void:
	var c := RSController.new()
	var det := RSSwingDetector.new()
	det.cooldown = 0.0
	var events := _record(det)
	_sample(det, c, 60.0, 6.0)
	_sample(det, c, 60.02, 10.0)
	_sample(det, c, 60.40, 0.0)
	_sample(det, c, 60.42, 0.0)
	_sample(det, c, 60.50, 0.0)
	check.call(events.size() == 1 and not det.is_swinging() and det.epoch() == 1, "a hub-time gap cancels rather than completing the old swing")
	_sample(det, c, 60.52, 6.0)
	_sample(det, c, 60.54, 10.0)
	_sample(det, c, 60.56, 6.0)
	check.call(events.size() == 3 and events[2]["swing"]["id"] == 2, "fresh motion after a gap belongs to a new swing")


static func _reset(check: Callable) -> void:
	var c := RSController.new()
	var det := RSSwingDetector.new()
	var events := _record(det)
	_sample(det, c, 70.0, 6.0)
	_sample(det, c, 70.02, 10.0)
	det.reset()
	check.call(det.epoch() == 1 and not det.is_swinging() and det.feed_new(c) == 0, "explicit reset cancels the swing, increments epoch, and preserves its cursor")
	_sample(det, c, 700.0, 8.0)
	check.call(events.size() == 1, "a large hub-clock jump cannot bypass reset's local cooldown")
	OS.delay_msec(175)
	_sample(det, c, 700.02, 6.0)
	_sample(det, c, 700.04, 10.0)
	_sample(det, c, 700.06, 6.0)
	check.call(events.size() == 3 and events[2]["swing"]["epoch"] == 1, "reset cooldown expires on the local monotonic clock")
	var cancel_c := RSController.new()
	var cancel_det := RSSwingDetector.new()
	var cancel_ref: WeakRef = weakref(cancel_det)
	var cancelled := _record(cancel_det)
	# The emitter owns this callable; a strong capture of it would form a cycle.
	cancel_det.swing_peaked.connect(func(_c: RSController, _swing: Dictionary) -> void:
		var detector := cancel_ref.get_ref() as RSSwingDetector
		if detector != null:
			detector.reset()
	)
	_sample(cancel_det, cancel_c, 80.0, 6.0)
	_sample(cancel_det, cancel_c, 80.02, 10.0)
	_sample(cancel_det, cancel_c, 80.04, 0.0)
	_sample(cancel_det, cancel_c, 80.12, 0.0)
	check.call(cancelled.size() == 2 and not cancel_det.is_swinging() and cancel_det.epoch() == 1, "reset from a peak consumer prevents the cancelled swing from finishing")
	cancel_det = null
	check.call(cancel_ref.get_ref() == null, "peak cancellation callback does not retain its detector after the owner releases it")


static func _backlog(check: Callable) -> void:
	var c := RSController.new()
	var det := RSSwingDetector.new()
	var events := _record(det)
	_sample(det, c, 90.0, 6.0)
	_sample(det, c, 90.02, 10.0)
	_push(c, 90.04, Vector3.UP * 6.0)
	_push(c, 90.10, Vector3.ZERO)
	_push(c, 90.20, Vector3.ZERO)
	check.call(det.feed_new(c) == 3 and not det.is_swinging(), "backlog advances the cursor while cancelling an active swing")
	check.call(det.feed_new(c) == 0 and events.size() == 1, "backlog emits neither a peak nor a finish and cannot replay")
	_sample(det, c, 90.22, 0.0)
	_sample(det, c, 90.30, 0.0)
	check.call(events.size() == 1, "a later fresh batch cannot revive the cancelled backlog swing")
	_sample(det, c, 90.40, 6.0)
	_sample(det, c, 90.42, 10.0)
	_sample(det, c, 90.44, 6.0)
	check.call(events.size() == 3 and events[2]["swing"]["id"] == 2, "new motion is usable after a stale batch has been discarded")
	var stale_c := RSController.new()
	var stale_det := RSSwingDetector.new()
	var stale_events := _record(stale_det)
	_push(stale_c, 95.0, Vector3.UP * 6.0)
	_push(stale_c, 95.02, Vector3.UP * 10.0)
	_push(stale_c, 95.04, Vector3.UP * 6.0)
	_push(stale_c, 95.12, Vector3.ZERO)
	_push(stale_c, 95.20, Vector3.ZERO)
	check.call(stale_det.feed_new(stale_c) == 5 and stale_events.is_empty(), "a complete swing inside an initial backlog produces no signal")


static func _mirror(check: Callable) -> void:
	var right := RSController.new()
	var left := LeftController.new()
	var right_det := RSSwingDetector.new()
	var left_det := RSSwingDetector.new()
	var right_events := _record(right_det)
	var left_events := _record(left_det)
	var g := Vector3(2.0, 6.0, 3.0)
	var q := Quaternion(Vector3(1.0, 2.0, 3.0).normalized(), 0.5)
	for c: RSController in [right, left]:
		_push(c, 100.0, g)
		_push(c, 100.02, g * 1.5, q)
		_push(c, 100.04, g * 0.5)
	right_det.feed(right, 3)
	left_det.feed(left, 3)
	check.call(right_events.size() == 2 and left_events.size() == 2, "both hand preferences detect the same raw motion")
	if right_events.size() < 2 or left_events.size() < 2:
		return
	var rp: Dictionary = right_events[1]["swing"]
	var lp: Dictionary = left_events[1]["swing"]
	check.call(is_equal_approx(rp["peak_rate"], lp["peak_rate"]) and lp["peak_gyro"] == Vector3(g.x, -g.y, -g.z) * 1.5, "left-hand gyro is the axial mirror -M g, with unchanged speed")
	check.call(lp["peak_orientation"].is_equal_approx(Quaternion(q.x, -q.y, -q.z, q.w)) and lp["left_handed"] and not rp["left_handed"], "peak pose is mirrored exactly once and preference is display metadata")
	check.call(left.hist_gyro[left.history_index(1)] == g * 1.5 and left.hist_quat[left.history_index(1)] == q, "swing detection leaves raw protocol history intact")


static func _fallback(check: Callable) -> void:
	var c := RSController.new()
	var det := RSSwingDetector.new()
	det.peak_confirm = 0.0
	var events := _record(det)
	_sample(det, c, 110.0, 6.0)
	_sample(det, c, 110.02, 10.0)
	_sample(det, c, 110.04, 0.0)
	_sample(det, c, 110.12, 0.0)
	check.call(events.size() == 3 and events[1]["kind"] == "peaked" and events[2]["kind"] == "finished", "finishing without prior confirmation emits peak before finish")
	if events.size() == 3:
		check.call(events[1]["swing"]["id"] == events[2]["swing"]["id"], "fallback candidate and finish share the same id")
