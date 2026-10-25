class_name RSGolfWorldHit
extends RefCounted
## Caller-owned earliest geometry event and simultaneous solid normals for a local ball step.
## Hazard priority is cup, water, OB; solids and canopy never directly change the score.

enum Kind { NONE, CUP, WATER, OB, TRUNK, TERRAIN, CANOPY, INVALID }
const CAPACITY := 32

var kind := Kind.NONE
var fraction := INF
var point := Vector3.ZERO
var centre := Vector3.ZERO
var normal := Vector3.ZERO
var depth := 0.0
var feature_id := -1
var count := 0
var normals := PackedVector3Array()
var solid_kinds := PackedByteArray()
var solid_ids := PackedInt32Array()


func _init() -> void:
	normals.resize(CAPACITY)
	solid_kinds.resize(CAPACITY)
	solid_ids.resize(CAPACITY)


func reset() -> void:
	kind = Kind.NONE
	fraction = INF
	point = Vector3.ZERO
	centre = Vector3.ZERO
	normal = Vector3.ZERO
	depth = 0.0
	feature_id = -1
	count = 0


func add_normal(value: Vector3, solid: Kind, id: int) -> bool:
	for i in count:
		if normals[i].dot(value) > 1.0 - 1.0e-6 and solid_kinds[i] == solid and (solid != Kind.TRUNK or solid_ids[i] == id):
			return true
	if count == CAPACITY:
		kind = Kind.INVALID
		push_error("RSGolfWorldHit: simultaneous contact capacity exceeded")
		return false
	normals[count] = value
	solid_kinds[count] = solid
	solid_ids[count] = id
	count += 1
	return true
