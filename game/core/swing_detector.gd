class_name RSSwingDetector
extends RefCounted
## Generic swing detector on angular velocity: a swing starts when |gyro| rises above
## `start_rate`, ends when it stays under `end_rate` for `end_hold` seconds.
## Games build on the returned summary (peak speed, dominant axis, timing).

signal swing_started(controller: RSController)
signal swing_finished(controller: RSController, swing: Dictionary)

var start_rate := 5.0       ## rad/s (~290 deg/s)
var end_rate := 1.5         ## rad/s
var end_hold := 0.06        ## s
var min_duration := 0.05    ## s
var cooldown := 0.15        ## s after a swing before a new one may start

var _active := false
var _t_start := 0.0
var _t_peak := 0.0
var _t_below := -1.0
var _t_last_end := -100.0
var _peak := 0.0
var _axis_sum := Vector3.ZERO      ## body-frame rotation accumulated during the swing
var _axis_world_sum := Vector3.ZERO
var _peak_lin := 0.0
var _q_start := Quaternion.IDENTITY


func is_swinging() -> bool:
	return _active


func feed(c: RSController, count: int) -> void:
	## Call from ControllerHub.samples_received with the number of new samples.
	var n := mini(count, c.history_size())
	for age in range(n - 1, -1, -1):
		var i := c.history_index(age)
		var prev := c.history_index(age + 1)
		var t: float = c.hist_time[i]
		var dt: float = clampf(t - c.hist_time[prev], 0.0, 0.05) if c.history_size() > n else 0.005
		_step(c, t, dt, c.motion_gyro(c.hist_gyro[i]), c.hist_lin[i], c.motion_pose(c.hist_quat[i]))


func _step(c: RSController, t: float, dt: float, g: Vector3, lin: Vector3, q: Quaternion) -> void:
	var rate := g.length()
	if not _active:
		if rate > start_rate and t - _t_last_end > cooldown:
			_active = true
			_t_start = t
			_t_peak = t
			_peak = rate
			_peak_lin = lin.length()
			_axis_sum = Vector3.ZERO
			_axis_world_sum = Vector3.ZERO
			_t_below = -1.0
			_q_start = q
			swing_started.emit(c)
		return

	_axis_sum += g * dt
	_axis_world_sum += (q * g) * dt
	_peak_lin = maxf(_peak_lin, lin.length())
	if rate > _peak:
		_peak = rate
		_t_peak = t
	if rate < end_rate:
		if _t_below < 0.0:
			_t_below = t
		elif t - _t_below >= end_hold:
			_finish(c, t, q)
	else:
		_t_below = -1.0


func _finish(c: RSController, t: float, q_end: Quaternion) -> void:
	_active = false
	_t_last_end = t
	var duration := t - _t_start
	if duration < min_duration:
		return
	var body_axis := _axis_sum.normalized() if _axis_sum.length() > 1e-4 else Vector3.ZERO
	swing_finished.emit(c, {
		"peak_rate": _peak,                         # rad/s
		"peak_time": _t_peak,                       # hub clock
		"duration": duration,
		"angle": _axis_sum.length(),                # rad swept
		"axis_body": body_axis,                     # dominant rotation axis in the controller frame
		"axis_world": _axis_world_sum.normalized() if _axis_world_sum.length() > 1e-4 else Vector3.ZERO,
		"peak_lin_accel": _peak_lin,                # m/s^2
		"start_orientation": _q_start,
		"end_orientation": q_end,
	})
