class_name RSGolfShot
extends RefCounted
## M1 temporary-button adapter: an explicit initial velocity, never a scripted landing.
## Nominal reaches select a club; drag, wind, terrain and collisions determine the actual shot.

const PUTT_REACH := 20.0  ## m, only on green/fringe/fairway
const PUTT_END_SPEED := 0.55  ## m/s in the analytic flat/slope energy estimate
const REACHES := [60.0, 120.0, 220.0]  ## m; retain the M1 temporary button cycle
const ANGLES := [48.0, 32.0, 12.0]  ## degrees above horizontal
const GRAVITY := 9.81  ## m/s²

var velocity := Vector3.ZERO
var spin := Vector3.ZERO
var rolling := false


func aim(world: RSGolfWorld, from: Vector3, target: Vector3, reach_index: int) -> bool:
	velocity = Vector3.ZERO
	spin = Vector3.ZERO
	rolling = false
	if not from.is_finite() or not target.is_finite() or reach_index < 0 or reach_index >= REACHES.size():
		push_error("RSGolfShot: finite target and valid club required")
		return false
	var flat := Vector3(target.x - from.x, 0.0, target.z - from.z)
	var distance := flat.length()
	if distance < 1.0e-6:
		rolling = true
		return true
	var direction := flat / distance
	var lie := world.lie_at(from)
	rolling = distance <= PUTT_REACH and lie in [RSGolfCourse.Lie.GREEN, RSGolfCourse.Lie.FRINGE, RSGolfCourse.Lie.FAIRWAY, RSGolfCourse.Lie.TEE]
	if rolling:
		var normal := world.surface.geometric_normal_at(from.x, from.z)
		var friction: float = RSGolfBall.RESISTANCE[lie]
		var energy := 2.0 * friction * distance + 2.0 * GRAVITY * (target.y - from.y) + PUTT_END_SPEED * PUTT_END_SPEED
		velocity = direction.slide(normal).normalized() * sqrt(maxf(PUTT_END_SPEED * PUTT_END_SPEED, energy))
		return true
	var angle := deg_to_rad(ANGLES[reach_index])
	var height := float(target.y) - from.y
	if distance * tan(angle) <= height:
		angle = atan2(height, distance) + deg_to_rad(12.0)
	var cosine := cos(angle)
	var denominator := 2.0 * cosine * cosine * (distance * tan(angle) - height)
	var speed := sqrt(GRAVITY * distance * distance / denominator)
	velocity = direction * (speed * cosine) + Vector3.UP * (speed * sin(angle))
	if not velocity.is_finite() or speed > RSGolfBall.MAX_SPEED:
		push_error("RSGolfShot: target requires an unsupported launch speed")
		return false
	return true
