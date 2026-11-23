class_name RSPodium
extends Node3D
## Shared three-step podium and optional tied fourth step. Dimensions are metres in local
## space; spot() returns world coordinates. Scores arrive in ranked_players() order.

const TRIMS := [Color(1.0, 0.78, 0.25), Color(0.78, 0.8, 0.84), Color(0.8, 0.5, 0.28)]
const BAND_HEIGHT := 0.06
const TRIM_OVERHANG := 0.02
const TIE_GAP := 0.1
const CAMERA_SETTLE := 6.0       ## seconds before the results camera stops dollying
const FRAME_LEFT := -0.94       ## NDC bounds leave the right half for results
const FRAME_RIGHT := -0.06
const FRAME_VERTICAL := 0.9
const ACTOR_HEIGHT := 2.35      ## includes the player tag above the head

var _steps: Array[Vector2] = []
var _footprint := Vector2.ZERO
var _extra := Vector3.ZERO
var _spacing := 1.0
var _buried := 0.0
var _ranks := PackedInt32Array()
var _blocks: Array[MeshInstance3D] = []
var _bands: Array[MeshInstance3D] = []
var _labels: Array[Label3D] = []
var _trims: Array[StandardMaterial3D] = []
var _bounds: Array[Vector3] = []


func configure(steps: Array, footprint: Vector2, extra: Vector3, spacing: float, font: Font, buried := 0.0) -> void:
	assert(_blocks.is_empty() and steps.size() == 3 and footprint.x > 0 and footprint.y > 0)
	for step: Array in steps:
		_steps.append(Vector2(float(step[0]), float(step[1])))
	_footprint = footprint
	_extra = extra
	_spacing = spacing
	_buried = buried
	var body := StandardMaterial3D.new()
	body.albedo_color = Color(0.93, 0.93, 0.92)
	body.roughness = 0.35
	for color: Color in TRIMS:
		var trim := StandardMaterial3D.new()
		trim.albedo_color = color
		trim.metallic = 0.9
		trim.roughness = 0.25
		_trims.append(trim)
	for i in 4:
		var block := MeshInstance3D.new()
		block.mesh = BoxMesh.new()
		block.material_override = body
		add_child(block)
		_blocks.append(block)
		var band := MeshInstance3D.new()
		band.mesh = BoxMesh.new()
		add_child(band)
		_bands.append(band)
		var label := Label3D.new()
		label.font = font
		label.font_size = 120
		label.pixel_size = 0.004
		label.outline_size = 10
		label.outline_modulate = Color(0.25, 0.22, 0.2)
		add_child(label)
		_labels.append(label)
	# Establish the normal three-step geometry without making a new scene visible.
	present(PackedInt64Array([3, 2, 1, 0]))
	reset()


func reset() -> void:
	visible = false
	_ranks.clear()
	_bounds.clear()


func present(scores: PackedInt64Array) -> void:
	assert(scores.size() <= 4)
	_ranks.clear()
	for i in scores.size():
		assert(i == 0 or scores[i - 1] >= scores[i])
		var score := scores[i]
		var place := 1
		for other in scores:
			if other > score:
				place += 1
		_ranks.append(place)
	for i in 4:
		var place := rank(i)
		var enabled := i < 3 or (i < scores.size() and place <= 3)
		_blocks[i].visible = enabled
		_bands[i].visible = enabled
		_labels[i].visible = enabled
		if not enabled:
			continue
		var at := _local_spot(i)
		(_blocks[i].mesh as BoxMesh).size = Vector3(_footprint.x, at.y + _buried, _footprint.y)
		_blocks[i].position = Vector3(at.x, (at.y - _buried) * 0.5, at.z)
		(_bands[i].mesh as BoxMesh).size = Vector3(_footprint.x + TRIM_OVERHANG, BAND_HEIGHT, _footprint.y + TRIM_OVERHANG)
		_bands[i].position = at - Vector3.UP * BAND_HEIGHT * 0.5
		_bands[i].material_override = _trims[place - 1]
		_labels[i].text = str(place)
		_labels[i].modulate = TRIMS[place - 1].darkened(0.25)
		_labels[i].position = Vector3(at.x, at.y * 0.5, at.z + _footprint.y * 0.5 + 0.01)
	_cache_bounds(scores.size())
	visible = not scores.is_empty()


func rank(index: int) -> int:
	return _ranks[index] if index < _ranks.size() else index + 1


func cheer(index: int) -> float:
	var place := rank(index)
	return 1.0 if place == 1 else (0.5 if place <= 3 else 0.0)


func _local_spot(index: int) -> Vector3:
	var place := rank(index)
	var height := _steps[place - 1].y if place <= 3 else 0.0
	if index < 3:
		return Vector3(_steps[index].x, height, 0)
	var x := _extra.x + (index - 3) * _spacing
	if place <= 3:
		x = maxf(x, _steps[2].x + _footprint.x + TIE_GAP)
	return Vector3(x, height, _extra.z)


func spot(index: int) -> Vector3:
	return to_global(_local_spot(index))


func apply_camera(camera: Camera3D, elapsed: float, side: float, side_speed: float, distance: float,
		dolly: float, height: float, look_side: float, look_height: float) -> void:
	var t := clampf(elapsed, 0.0, CAMERA_SETTLE)
	var d := distance + t * dolly
	camera.global_position = global_position + global_basis.z * d + global_basis.x * (side + t * side_speed) + Vector3.UP * height
	var ratio := d / distance if absf(distance) > 0.001 else 1.0
	var target := global_position + global_basis.x * (look_side * ratio) + Vector3.UP * look_height
	var direction := target - camera.global_position
	if direction.length_squared() > 0.000001:
		camera.look_at(target, Vector3.FORWARD if absf(direction.normalized().dot(Vector3.UP)) > 0.9999 else Vector3.UP)


func _cache_bounds(count: int) -> void:
	_bounds.clear()
	if count == 0:
		return
	var low := Vector3(INF, 0, INF)
	var high := Vector3(-INF, 0, -INF)
	var margin := Vector3(_footprint.x * 0.5 + 0.15, 0, _footprint.y * 0.5 + 0.15)
	for i in maxi(3, count):
		var at := _local_spot(i)
		low = low.min(Vector3(at.x, 0, at.z) - margin)
		high = high.max(at + margin + Vector3.UP * (ACTOR_HEIGHT if i < count else 0.15))
	for x: float in [low.x, high.x]:
		for y: float in [low.y, high.y]:
			for z: float in [low.z, high.z]:
				_bounds.append(Vector3(x, y, z))


func fit_left(camera: Camera3D) -> void:
	## Translate the original shot, preserving orientation/FOV, until its bounds fit in the
	## left half. All horizontal interval bounds have the same slopes as dolly distance
	## increases, so a single pass solves the frustum constraints without iteration/arrays.
	if _bounds.is_empty():
		return
	var viewport := camera.get_viewport().get_visible_rect().size
	if viewport.x <= 0 or viewport.y <= 0:
		return
	var aspect := viewport.x / viewport.y
	var tangent := tan(deg_to_rad(camera.fov * 0.5))
	var vertical := tangent if camera.keep_aspect == Camera3D.KEEP_HEIGHT else tangent / aspect
	var horizontal := vertical * aspect
	var right := camera.global_basis.x
	var up := camera.global_basis.y
	var back := camera.global_basis.z
	var lower := -INF
	var upper := INF
	var dolly := 0.0
	for local: Vector3 in _bounds:
		var relative := to_global(local) - camera.global_position
		var x := right.dot(relative)
		var y := up.dot(relative)
		var depth := -back.dot(relative)
		lower = maxf(lower, x - FRAME_RIGHT * horizontal * depth)
		upper = minf(upper, x - FRAME_LEFT * horizontal * depth)
		dolly = maxf(dolly, maxf(0.1 - depth, absf(y) / (vertical * FRAME_VERTICAL) - depth))
	dolly = maxf(dolly, (lower - upper) / ((FRAME_RIGHT - FRAME_LEFT) * horizontal))
	var shift := clampf(0, lower - FRAME_RIGHT * horizontal * dolly, upper - FRAME_LEFT * horizontal * dolly)
	camera.global_position += back * dolly + right * shift
