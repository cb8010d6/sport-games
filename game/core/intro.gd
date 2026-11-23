class_name RSIntro
extends RefCounted
## Stateless opening flyovers shared by sports. Times are seconds, points are world-space
## and FOV is degrees. Call with the round's phase_time; no timer can outlive the round.


static func progress(elapsed: float, duration: float) -> float:
	return smoothstep(0.0, duration, elapsed) if duration > 0.0 else 1.0


static func fade(elapsed: float, duration: float, edge: float = 0.6) -> float:
	if duration <= 0.0 or elapsed < 0.0 or elapsed >= duration:
		return 0.0
	if edge <= 0.0:
		return 1.0
	var span := minf(edge, duration * 0.5)
	return clampf(elapsed / span, 0.0, 1.0) * clampf((duration - elapsed) / span, 0.0, 1.0)


static func apply(camera: Camera3D, elapsed: float, duration: float, start: Vector3, via: Vector3,
		end: Vector3, look_start: Vector3, look_end: Vector3, fov_start: float, fov_end: float,
		look_delay: float = 0.25) -> void:
	var u := progress(elapsed, duration)
	camera.global_position = start.lerp(via, u).lerp(via.lerp(end, u), u)
	var delay := clampf(look_delay, 0.0, 1.0)
	var look_u := (1.0 if u >= 1.0 else 0.0) if delay >= 1.0 else smoothstep(delay, 1.0, u)
	var target := look_start.lerp(look_end, look_u)
	var direction := target - camera.global_position
	if direction.length_squared() > 0.000001:
		# look_at cannot construct a basis when its view and up directions are parallel.
		var up := Vector3.FORWARD if absf(direction.normalized().dot(Vector3.UP)) > 0.9999 else Vector3.UP
		camera.look_at(target, up)
	camera.fov = lerpf(fov_start, fov_end, u)
