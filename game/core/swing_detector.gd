class_name RSSwingDetector
extends RefCounted
## Generic swing detector on angular velocity: a swing starts when |gyro| rises above
## `start_rate`, ends when it stays under `end_rate` for `end_hold` seconds.
## Games build on the returned summary (peak speed, dominant axis, timing).

signal swing_started(controller: RSController)
signal swing_peaked(controller: RSController, swing: Dictionary)
signal swing_finished(controller: RSController, swing: Dictionary)

var start_rate := 5.0       ## rad/s (~290 deg/s)
var end_rate := 1.5         ## rad/s
var end_hold := 0.06        ## s
var min_duration := 0.05    ## s
var cooldown := 0.15        ## s after a swing before a new one may start
var peak_confirm := 0.7     ## confirm once the rate falls below this fraction of its peak
var max_gap := 0.3          ## s between hub samples before cancelling an active swing
var max_batch_span := 0.1   ## s: longer batches only advance the consumption cursor

var _active := false
var _peaked := false
var _epoch := 0
var _id := 0
var _have_time := false
var _last_time := 0.0
var _cursor_index := -1
var _cursor_time := 0.0
var _reset_msec := -1
var _t_start := 0.0
var _t_peak := 0.0
var _t_below := -1.0
var _t_last_end := -100.0
var _peak := 0.0
var _axis_sum := Vector3.ZERO      ## body-frame rotation accumulated during the swing
var _axis_world_sum := Vector3.ZERO
var _peak_lin := 0.0
var _q_start := Quaternion.IDENTITY
var _q_peak := Quaternion.IDENTITY
var _g_peak := Vector3.ZERO


func is_swinging() -> bool:
	return _active


func reset() -> void:
	## Keep the cursor: cancelled history must never become a new swing.
	_active = false
	_epoch += 1
	_t_last_end = -INF
	_reset_msec = Time.get_ticks_msec()


func epoch() -> int:
	return _epoch


func feed(c: RSController, count: int) -> void:
	## Call from ControllerHub.samples_received with the number of new samples.
	_consume(c, count)


func feed_new(c: RSController) -> int:
	return _consume(c, c.history_size())


func _consume(c: RSController, count: int) -> int:
	var n := clampi(count, 0, c.history_size())
	# A ring position plus its timestamp also distinguishes new, restarted-hub
	# samples from old history that is still retained after resetting the hub clock.
	for age in range(n):
		var i := c.history_index(age)
		if i == _cursor_index and c.hist_time[i] == _cursor_time:
			n = age
			break
	if n == 0:
		return 0
	_cursor_index = c.history_index(0)
	_cursor_time = c.hist_time[_cursor_index]
	var received_msec := Time.get_ticks_msec()
	var batch_last := _cursor_time
	var stale := _stale_batch(c, n)
	if stale:
		# The task's hub-time contract applies here, rather than the background
		# design's local silence timer. Do not let a later fresh batch revive it.
		_active = false
	var processed := 0
	for age in range(n - 1, -1, -1):
		var i := c.history_index(age)
		var t: float = c.hist_time[i]
		var dt := clampf(t - _last_time, 0.0, 0.05) if _have_time else 0.005
		if _have_time and t <= _last_time:
			if _last_time - t <= 1.0:
				continue
			_last_time = t
			reset()
		elif _have_time and _active and t - _last_time > max_gap:
			_last_time = t
			reset()
		_last_time = t
		_have_time = true
		processed += 1
		if stale:
			_t_last_end = t
		if not stale:
			_step(c, t, dt, c.motion_gyro(c.hist_gyro[i]), c.hist_lin[i], c.motion_pose(c.hist_quat[i]), received_msec, batch_last)
	return processed


func _stale_batch(c: RSController, count: int) -> bool:
	var have_time := _have_time
	var cursor := _last_time
	var first := 0.0
	var beginning := true
	for age in range(count - 1, -1, -1):
		var t: float = c.hist_time[c.history_index(age)]
		if have_time and t <= cursor:
			if cursor - t <= 1.0:
				continue # Ignored samples must not make a fresh batch look stale.
			beginning = true # A restarted hub has a separate time origin.
		if beginning:
			first = t
			beginning = false
		if t - first > max_batch_span:
			return true
		cursor = t
		have_time = true
	return false


func _step(c: RSController, t: float, dt: float, g: Vector3, lin: Vector3, q: Quaternion, received_msec: int, batch_last: float) -> void:
	var rate := g.length()
	if not _active:
		# reset() can follow a long pause: its cooldown uses only the local
		# monotonic clock, independently of the existing hub-time finish cooldown.
		var reset_ready := _reset_msec < 0 or received_msec - _reset_msec >= cooldown * 1000.0
		if rate > start_rate and t - _t_last_end > cooldown and reset_ready:
			_active = true
			_peaked = false
			_id += 1
			_t_start = t
			_t_peak = t
			_peak = rate
			_peak_lin = lin.length()
			_axis_sum = Vector3.ZERO
			_axis_world_sum = Vector3.ZERO
			_t_below = -1.0
			_q_start = q
			_q_peak = q
			_g_peak = g
			swing_started.emit(c)
		return

	_axis_sum += g * dt
	_axis_world_sum += (q * g) * dt
	_peak_lin = maxf(_peak_lin, lin.length())
	if rate > _peak:
		_peak = rate
		_t_peak = t
		_q_peak = q
		_g_peak = g
	if not _peaked and rate < _peak * peak_confirm:
		_emit_peak(c, received_msec, batch_last)
		if not _active:
			return # A signal consumer may have cancelled this swing.
	if rate < end_rate:
		if _t_below < 0.0:
			_t_below = t
		elif t - _t_below >= end_hold:
			_finish(c, t, q, received_msec, batch_last)
	else:
		_t_below = -1.0


func _finish(c: RSController, t: float, q_end: Quaternion, received_msec: int, batch_last: float) -> void:
	_t_last_end = t
	var duration := t - _t_start
	if duration < min_duration:
		_active = false
		return
	if not _peaked:
		_emit_peak(c, received_msec, batch_last)
		if not _active:
			return
	_active = false
	var swing := _summary(c, received_msec, batch_last)
	swing["duration"] = duration
	swing["end_orientation"] = q_end
	swing_finished.emit(c, swing)


func _emit_peak(c: RSController, received_msec: int, batch_last: float) -> void:
	_peaked = true
	swing_peaked.emit(c, _summary(c, received_msec, batch_last))


func _summary(c: RSController, received_msec: int, batch_last: float) -> Dictionary:
	var body_axis := _axis_sum.normalized() if _axis_sum.length() > 1e-4 else Vector3.ZERO
	return {
		"id": _id,
		"epoch": _epoch,
		"start_time": _t_start,
		"peak_rate": _peak,                         # rad/s
		"peak_time": _t_peak,                       # hub clock
		"peak_gyro": _g_peak,
		"angle": _axis_sum.length(),                # rad swept
		"axis_body": body_axis,                     # dominant rotation axis in the controller frame
		"axis_world": _axis_world_sum.normalized() if _axis_world_sum.length() > 1e-4 else Vector3.ZERO,
		"peak_lin_accel": _peak_lin,                # m/s^2
		"start_orientation": _q_start,
		"peak_orientation": _q_peak,
		"received_msec": received_msec,
		"peak_msec": received_msec - roundi((batch_last - _t_peak) * 1000.0),
		"left_handed": c.left_handed(),
	}
