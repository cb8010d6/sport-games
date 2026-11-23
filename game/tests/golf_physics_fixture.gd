extends RefCounted
## Small analytic worlds for independent G3 expectations; no rendered scene or downloaded assets.

class Sampler extends RefCounted:
	var slope := Vector2.ZERO
	var base := 0.0
	var lie := RSGolfCourse.Lie.GREEN
	var ridge := false

	func height_at(x: float, z: float) -> float:
		return maxf(0.0, 0.5 - absf(x)) if ridge else base + slope.x * x + slope.y * z

	func lie_at(_point: Vector3) -> int:
		return lie


static func make(slope := Vector2.ZERO, base := 0.0, water: Array = [], trees: Array = [], cup := Vector3(8.0, 0.0, 8.0), area := Rect2(-10.0, -10.0, 20.0, 20.0), routes: Array[PackedVector2Array] = [], lie := RSGolfCourse.Lie.GREEN, ridge := false) -> RSGolfWorld:
	var sampler := Sampler.new()
	sampler.slope = slope
	sampler.base = base
	sampler.lie = lie
	sampler.ridge = ridge
	var surface := RSGolfSurface.new()
	var cells := Vector2i(roundi(area.size.x / RSGolfSurface.CELL), roundi(area.size.y / RSGolfSurface.CELL))
	var patches: Array[Rect2i] = []
	if ridge:
		patches.append(Rect2i(Vector2i.ZERO, cells))
	if not surface.build(area.position, cells, sampler.height_at, patches):
		return null
	var paths: Array[PackedVector2Array] = routes
	if paths.is_empty():
		paths = [PackedVector2Array([Vector2(-1000.0, 0.0), Vector2(1000.0, 0.0)])]
	var bounds := RSGolfBounds.new()
	if not bounds.build(surface, paths):
		return null
	var world := RSGolfWorld.new()
	if not world.configure(surface, bounds, water, trees, cup, -INF, sampler.lie_at):
		return null
	# Callable stores an object identity, not a strong owner. Keep the fixture's
	# sampler alive exactly as the scene keeps its production course alive.
	world.set_meta("fixture_sampler_owner", sampler)
	return world


static func flags(world: RSGolfWorld) -> PackedByteArray:
	var values := PackedByteArray()
	values.resize(world.trees.size())
	return values


static func ball(world: RSGolfWorld, point: Vector3) -> RSGolfBall:
	var value := RSGolfBall.new()
	if not value.reset(world, point):
		return null
	return value
