class_name RSGolfContact
extends RefCounted
## Caller-owned geometry result, in world metres; no score, clock or collision response.
## OVERLAP is an initial-state diagnostic, not an instruction to apply a penalty or impulse.

enum Status { MISS, HIT, OVERLAP, INVALID }
enum Part { NONE, FACE, EDGE, VERTEX }
enum Flag { START_TOUCH = 1, START_OVERLAP = 2, APPROACHING = 4, SEPARATING = 8,
	TANGENT = 16, STATIONARY = 32, NORMAL_UNDEFINED = 64, BACKFACE = 128 }

var status := Status.MISS
var feature_id := -1
var part := Part.NONE
var part_id := -1  ## edges AB/BC/CA; vertices A/B/C; face 0
var fraction := INF
var centre := Vector3.ZERO
var point := Vector3.ZERO  ## actual finite-triangle closest point, not a plane extension
var normal := Vector3.ZERO  ## geometric separation normal towards the ball; may be undefined
var depth := 0.0
var flags := 0


func reset() -> void:
	status = Status.MISS
	feature_id = -1
	part = Part.NONE
	part_id = -1
	fraction = INF
	centre = Vector3.ZERO
	point = Vector3.ZERO
	normal = Vector3.ZERO
	depth = 0.0
	flags = 0


func copy_from(other: RSGolfContact) -> void:
	status = other.status
	feature_id = other.feature_id
	part = other.part
	part_id = other.part_id
	fraction = other.fraction
	centre = other.centre
	point = other.point
	normal = other.normal
	depth = other.depth
	flags = other.flags
