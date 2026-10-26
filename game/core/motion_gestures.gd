class_name RSMotionGestures
extends RefCounted
## Turns one controller's motion into RSMotionControls (skateboard, skiing, ...). Works on every 200 Hz sample (not just
## once per frame) so short flicks are never missed:
##  - tilt left/right (from the pose captured as "level") -> steer
##  - tilt back / forward -> pitch (manuals)
##  - flick the tip up (fast nose-up rotation, or a sharp upward jolt) -> ollie, strength
##    from the peak rate in the first 45 ms
##  - flick sideways (fast roll) -> kickflip / heelflip; the return stroke of a flick is
##    ignored so one flick is one flip
##  - turning about the vertical -> yaw_delta (spins)

const OLLIE_RATE := 4.0        ## rad/s nose-up
const OLLIE_FULL := 11.0       ## rad/s for a full-height pop
const OLLIE_ACCEL := 13.0      ## m/s^2 upward jolt also counts
const FLIP_RATE := 5.5         ## rad/s roll

var stick := RSTiltStick.new()

var _last_time := -1.0
var _ollie_armed := true
var _ollie_until := -1.0
var _ollie_peak := 0.0
var _ollie_last := -10.0
var _flip_armed := true
var _flip_last_t := -10.0
var _flip_last_sign := 0


func capture(q: Quaternion) -> void:
	stick.capture(q)


func read(c: RSController, out: RSMotionControls) -> void:
	out.ollie = 0.0
	out.flip = 0
	out.yaw_delta = 0.0
	var n := c.history_size()
	if n == 0:
		return
	if c.hist_time[c.history_index(0)] < _last_time - 1.0:
		_last_time = -1.0       # hub clock restarted
	var ages: Array[int] = []
	for age in n:
		if c.hist_time[c.history_index(age)] <= _last_time:
			break
		ages.append(age)
	ages.reverse()
	for age in ages:
		var i := c.history_index(age)
		var t: float = c.hist_time[i]
		var dt := clampf(t - _last_time, 0.0, 0.05) if _last_time >= 0.0 else 0.005
		_last_time = t
		var q := c.motion_pose(c.hist_quat[i])
		var gw := q * c.motion_gyro(c.hist_gyro[i])
		var fr := stick.frame(q)
		out.yaw_delta += gw.y * dt
		_detect(t, gw.dot(fr[0]), gw.dot(fr[1]), c.hist_lin[i].y, out)
	var st := stick.stick(c.motion_orientation())
	out.steer = st.x
	out.pitch = clampf(stick.tilt(c.motion_orientation()).y / stick.max_pitch, -1.5, 1.5)


func _detect(t: float, pitch_rate: float, roll_rate: float, lin_up: float, out: RSMotionControls) -> void:
	if _ollie_until >= 0.0:
		_ollie_peak = maxf(_ollie_peak, pitch_rate)
		if t >= _ollie_until:
			out.ollie = clampf(remap(_ollie_peak, OLLIE_RATE, OLLIE_FULL, 0.35, 1.0), 0.35, 1.0)
			_ollie_until = -1.0
	elif _ollie_armed and t - _ollie_last > 0.3 and ((pitch_rate > OLLIE_RATE and pitch_rate > absf(roll_rate)) or lin_up > OLLIE_ACCEL):
		_ollie_armed = false
		_ollie_last = t
		_ollie_peak = maxf(pitch_rate, OLLIE_RATE + (lin_up - OLLIE_ACCEL) * 0.4)
		_ollie_until = t + 0.045
	if not _ollie_armed and _ollie_until < 0.0 and pitch_rate < 1.5 and lin_up < 6.0 and t - _ollie_last > 0.15:
		_ollie_armed = true

	var ar := absf(roll_rate)
	if _flip_armed and ar > FLIP_RATE and ar > absf(pitch_rate) * 1.2:
		_flip_armed = false
		var sgn := 1 if roll_rate > 0.0 else -1
		if not (sgn == -_flip_last_sign and t - _flip_last_t < 0.4):
			out.flip = sgn
			_flip_last_sign = sgn
			_flip_last_t = t
	if not _flip_armed and ar < 2.0:
		_flip_armed = true
