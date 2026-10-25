class_name RSGolfBoundary
extends RefCounted
## G3 visible OB posts on exposed route-capsule arcs/offsets; generated once per course.
## Placement uses the exact bounds query, while the rasterized material fields stay unchanged.

const SPACING := 20.0  ## m along exposed boundary candidates
const ARC_STEPS := 48


static func build(parent: Node3D, surface: RSGolfSurface, bounds: RSGolfBounds, routes: Array[PackedVector2Array]) -> void:
	var positions: Array[Vector3] = []
	var seen: Dictionary = {}
	for path: PackedVector2Array in routes:
		for i in range(1, path.size()):
			var a := path[i - 1]
			var b := path[i]
			var direction := b - a
			var length := direction.length()
			if length == 0.0:
				continue
			var side := Vector2(-direction.y, direction.x) / length * RSGolfBounds.RADIUS
			var steps := maxi(1, ceili(length / SPACING))
			for step in range(steps + 1):
				var centre := a.lerp(b, float(step) / steps)
				_add(centre + side, surface, bounds, positions, seen)
				_add(centre - side, surface, bounds, positions, seen)
		for centre: Vector2 in path:
			for step in ARC_STEPS:
				var angle := TAU * step / ARC_STEPS
				_add(centre + Vector2(cos(angle), sin(angle)) * RSGolfBounds.RADIUS, surface, bounds, positions, seen)
	if positions.is_empty():
		return
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.05
	mesh.bottom_radius = 0.05
	mesh.height = 0.8
	mesh.radial_segments = 6
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.65, 0.12, 0.85)
	material.roughness = 0.8
	mesh.material = material
	var instances := MultiMesh.new()
	instances.transform_format = MultiMesh.TRANSFORM_3D
	instances.mesh = mesh
	instances.instance_count = positions.size()
	for i in positions.size():
		instances.set_instance_transform(i, Transform3D(Basis.IDENTITY, positions[i] + Vector3.UP * 0.4))
	var posts := MultiMeshInstance3D.new()
	posts.name = "GolfOBPosts"
	posts.multimesh = instances
	parent.add_child(posts)


static func _add(point: Vector2, surface: RSGolfSurface, bounds: RSGolfBounds, positions: Array[Vector3], seen: Dictionary) -> void:
	if not surface.contains_xz(point.x, point.y):
		return
	var at := Vector3(point.x, 0.0, point.y)
	if absf(bounds.distance(at) - RSGolfBounds.RADIUS) > 0.01:
		return  # A nearer route hides this internal boundary of the union.
	var key := Vector2i(roundi(point.x * 10.0), roundi(point.y * 10.0))
	if seen.has(key):
		return
	seen[key] = true
	at.y = surface.height_at(point.x, point.y)
	positions.append(at)
