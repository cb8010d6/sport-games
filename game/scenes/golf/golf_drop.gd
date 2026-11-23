class_name RSGolfDrop
extends RefCounted
## Resolve a single already-penalized recovery along the actual shot polyline; world metres.
## Water searches 2..20 m behind the last land boundary in 0.5 m steps, then the previous shot.

const RETREAT := 2.0  ## m behind the last land/water boundary
const SEARCH_STEP := 0.5
const MAX_RETREAT := 20.0
const BISECTIONS := 32  ## represented XZ convergence, not a physical shape expansion

var _placement := RSGolfWorldHit.new()


func find(world: RSGolfWorld, path: PackedVector3Array, count: int, previous: Vector3, radius: float, water: bool) -> Vector3:
	if water and count >= 2:
		var wet := path[count - 1]
		for i in range(count - 2, -1, -1):
			var land := path[i]
			if not world.land_under(land):
				wet = land
				continue
			# The final short trajectory segment straddles the exact terrain/water footprint.
			var dry := land
			for iteration in BISECTIONS:
				var middle := dry.lerp(wet, 0.5)
				if world.land_under(middle):
					dry = middle
				else:
					wet = middle
			var boundary_distance := _distance_squared(dry, world.pin)
			var tolerance := world.storage_clearance(dry) * maxf(1.0, 2.0 * sqrt(boundary_distance))
			var distance := RETREAT
			while distance <= MAX_RETREAT:
				var candidate := _backward(path, i, dry, distance)
				if not candidate.is_finite():
					break
				if _distance_squared(candidate, world.pin) + tolerance >= boundary_distance and world.legal_placement(candidate, radius, _placement):
					return _placement.centre
				distance += SEARCH_STEP
			break
	if world.legal_placement(previous, radius, _placement):
		return _placement.centre
	push_error("RSGolfDrop: previous shot has no legal recovery position")
	return Vector3(NAN, NAN, NAN)


func _backward(path: PackedVector3Array, index: int, boundary: Vector3, distance: float) -> Vector3:
	var from := boundary
	for i in range(index, -1, -1):
		var to := path[i]
		var length := sqrt(_distance_squared(from, to))
		if length > 0.0 and distance <= length:
			return from.lerp(to, distance / length)
		distance -= length
		from = to
	return Vector3(NAN, NAN, NAN)


func _distance_squared(a: Vector3, b: Vector3) -> float:
	var x := float(a.x) - b.x
	var z := float(a.z) - b.z
	return x * x + z * z
