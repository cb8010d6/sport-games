class_name RSRaceFollower
extends RefCounted
## Route guidance in metres/seconds; the project owns steering and vehicle physics.
## Profiles use uniform arc-length nodes, spaced at most RSRaceTrack.SPLINE_STEP.
## Closed profiles have n unique nodes (step = length/n); open profiles include both
## endpoints (step = length/(n-1)). No private track sampling tables are required.
## Usage:
## var f := RSRaceFollower.new(track, 22.0)
## f.lane = 2.0
## var aim := f.target(r, speed)
## var steer := RSRaceTrack.steer_angle(forward, pos, aim)
## var want := f.speed(r) * RSRaceFollower.rubber_band(best_human.progress - r.progress, 80.0, 0.15, 0.1)

var track: RSRaceTrack
var lane := 0.0
var lookahead := 6.0
var lookahead_time := 0.6
var gate_margin := 1.0
var profile := PackedFloat32Array()


func _init(race_track: RSRaceTrack, vmax: float, lat_accel := 6.0, brake := 8.0, accel := 0.0) -> void:
	track = race_track
	profile = speed_profile(track, vmax, lat_accel, brake, accel)


func target(r: RSRaceTrack.Racer, current_speed: float) -> Vector3:
	var s := r.s + lookahead + maxf(current_speed, 0.0) * lookahead_time
	return track.point_at(s) + track.right_at(s) * lane_for(r)


func lane_for(r: RSRaceTrack.Racer) -> float:
	if r.next_gate >= track.gate_count():
		return lane
	var window := track.gate_window(r.next_gate)
	var margin := maxf(gate_margin, 0.0)
	if window.y - window.x <= margin * 2.0:
		return (window.x + window.y) * 0.5
	return clampf(lane, window.x + margin, window.y - margin)


func speed(r: RSRaceTrack.Racer) -> float:
	return profile_at(track, profile, r.s)


static func speed_profile(race_track: RSRaceTrack, vmax: float, lat_accel: float, brake: float, accel := 0.0) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	if race_track.length <= 0.0:
		return result
	var segments := maxi(ceili(race_track.length / RSRaceTrack.SPLINE_STEP), 3 if race_track.closed else 1)
	var n := segments if race_track.closed else segments + 1
	var ds := race_track.length / segments
	result.resize(n)
	var slowest := 0
	for i in n:
		var curvature := absf(race_track.curvature_at(i * ds))
		var cap := maxf(vmax, 0.0)
		if curvature > 0.000001:
			cap = minf(cap, sqrt(maxf(lat_accel, 0.0) / curvature))
		result[i] = cap
		if result[i] < result[slowest]:
			slowest = i
	# On a ring, the global minimum is an unchanged anchor. One complete sweep
	# in each direction propagates every limit, including the last->first edge.
	if brake > 0.0:
		for k in range(1, n + 1) if race_track.closed else range(1, n):
			var i := posmod(slowest - k, n) if race_track.closed else n - 1 - k
			var next := (i + 1) % n
			result[i] = minf(result[i], sqrt(result[next] * result[next] + 2.0 * brake * ds))
	if accel > 0.0:
		for k in range(1, n + 1) if race_track.closed else range(1, n):
			var i := (slowest + k) % n if race_track.closed else k
			var previous := posmod(i - 1, n)
			result[i] = minf(result[i], sqrt(result[previous] * result[previous] + 2.0 * accel * ds))
	return result


static func profile_at(race_track: RSRaceTrack, speeds: PackedFloat32Array, s: float) -> float:
	var n := speeds.size()
	if n == 0:
		return 0.0
	if n == 1 or race_track.length <= 0.0:
		return speeds[0]
	var at := race_track.wrap_s(s) / race_track.length * (n if race_track.closed else n - 1)
	var i := mini(floori(at), n - 1)
	var next := (i + 1) % n if race_track.closed else mini(i + 1, n - 1)
	# Interpolate kinetic energy, not velocity, to retain the segment's constant
	# acceleration/deceleration bound between profile nodes as well as at them.
	return sqrt(maxf(lerpf(speeds[i] * speeds[i], speeds[next] * speeds[next], at - i), 0.0))


static func rubber_band(gap: float, full_gap: float, boost: float, brake_factor: float) -> float:
	if full_gap <= 0.0:
		return 1.0
	var amount := clampf(gap / full_gap, -1.0, 1.0)
	return 1.0 + amount * clampf(boost if amount > 0.0 else brake_factor, 0.0, 0.5)
