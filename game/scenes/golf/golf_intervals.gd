class_name RSGolfIntervals
extends RefCounted
## Reused double-scalar line intervals for project-local hazard volumes; metres, y up.
## Inputs are represented Vector3 values. lo/hi include closed endpoints in the cast's [0,1].

const ROUND := 64.0 * 2.220446049250313e-16

var lo := INF
var hi := -INF


func sphere(start: Vector3, end: Vector3, centre: Vector3, radius: float) -> bool:
	return _radial(float(start.x) - centre.x, float(start.y) - centre.y, float(start.z) - centre.z, float(end.x) - start.x, float(end.y) - start.y, float(end.z) - start.z, radius)


func ellipse(start: Vector3, end: Vector3, centre: Vector2, axes: Vector2, turn: float) -> bool:
	var cosine := cos(turn)
	var sine := sin(turn)
	var x := float(start.x) - centre.x
	var z := float(start.z) - centre.y
	var dx := float(end.x) - start.x
	var dz := float(end.z) - start.z
	return _radial((x * cosine + z * sine) / axes.x, 0.0, (-x * sine + z * cosine) / axes.y, (dx * cosine + dz * sine) / axes.x, 0.0, (-dx * sine + dz * cosine) / axes.y, 1.0)


func ellipsoid(start: Vector3, end: Vector3, centre: Vector3, axes: Vector3) -> bool:
	return _radial((float(start.x) - centre.x) / axes.x, (float(start.y) - centre.y) / axes.y, (float(start.z) - centre.z) / axes.z, (float(end.x) - start.x) / axes.x, (float(end.y) - start.y) / axes.y, (float(end.z) - start.z) / axes.z, 1.0)


func capsule(start: Vector3, end: Vector3, a: Vector3, b: Vector3, radius: float) -> bool:
	var ux := float(b.x) - a.x
	var uy := float(b.y) - a.y
	var uz := float(b.z) - a.z
	var length := sqrt(ux * ux + uy * uy + uz * uz)
	if length == 0.0:
		return sphere(start, end, a, radius)
	ux /= length
	uy /= length
	uz /= length
	var mx := float(start.x) - a.x
	var my := float(start.y) - a.y
	var mz := float(start.z) - a.z
	var dx := float(end.x) - start.x
	var dy := float(end.y) - start.y
	var dz := float(end.z) - start.z
	var along := mx * ux + my * uy + mz * uz
	var velocity := dx * ux + dy * uy + dz * uz
	var first := INF
	var last := -INF
	if _radial(mx - ux * along, my - uy * along, mz - uz * along, dx - ux * velocity, dy - uy * velocity, dz - uz * velocity, radius):
		if velocity == 0.0:
			if along >= 0.0 and along <= length:
				first = lo
				last = hi
		else:
			var ta := -along / velocity
			var tb := (length - along) / velocity
			var clipped_lo := maxf(lo, minf(ta, tb))
			var clipped_hi := minf(hi, maxf(ta, tb))
			if clipped_lo <= clipped_hi:
				first = clipped_lo
				last = clipped_hi
	if sphere(start, end, a, radius):
		first = minf(first, lo)
		last = maxf(last, hi)
	if sphere(start, end, b, radius):
		first = minf(first, lo)
		last = maxf(last, hi)
	# A capsule is convex, so the union of these axis/cap intervals is connected.
	lo = first
	hi = last
	return lo <= hi


func clip_y(start: Vector3, end: Vector3, level: float, below: bool) -> bool:
	var dy := float(end.y) - start.y
	if dy == 0.0:
		return start.y <= level if below else start.y >= level
	var time := (level - start.y) / dy
	if (dy > 0.0) == below:
		hi = minf(hi, time)
	else:
		lo = maxf(lo, time)
	return lo <= hi


func _radial(mx: float, my: float, mz: float, dx: float, dy: float, dz: float, radius: float) -> bool:
	lo = INF
	hi = -INF
	var speed_squared := dx * dx + dy * dy + dz * dz
	var start_squared := mx * mx + my * my + mz * mz
	if speed_squared == 0.0:
		if start_squared <= radius * radius:
			lo = 0.0
			hi = 1.0
			return true
		return false
	var middle := -(mx * dx + my * dy + mz * dz) / speed_squared
	var x := mx + middle * dx
	var y := my + middle * dy
	var z := mz + middle * dz
	var nearest := x * x + y * y + z * z
	var gap := radius * radius - nearest
	var scale := maxf(1.0, maxf(radius, maxf(sqrt(start_squared), sqrt(speed_squared))))
	var epsilon := ROUND * scale
	var tolerance := epsilon * (2.0 * sqrt(nearest) + epsilon) + ROUND * (radius * radius + nearest)
	if gap < -tolerance:
		return false
	var half := sqrt(maxf(0.0, gap) / speed_squared)
	lo = maxf(0.0, middle - half)
	hi = minf(1.0, middle + half)
	return lo <= hi
