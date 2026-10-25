class_name RSSkiSnow
extends RefCounted
## Falling snow in a camera-following box; the caller owns and positions the returned node.

const AMOUNT := 2400
const SPLIT_FACTOR := 0.5


static func make(layers: int, quality: int) -> GPUParticles3D:
	var flake := QuadMesh.new()
	flake.size = Vector2(0.035, 0.035)
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.albedo_color = Color(1, 1, 1, 0.85)
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var dot := GradientTexture2D.new()
	dot.gradient = g
	dot.fill = GradientTexture2D.FILL_RADIAL
	dot.fill_from = Vector2(0.5, 0.5)
	dot.fill_to = Vector2(0.5, 0.0)
	dot.width = 32
	dot.height = 32
	fm.albedo_texture = dot
	flake.material = fm
	var ps := GPUParticles3D.new()
	ps.amount = AMOUNT
	ps.lifetime = 2.6
	ps.preprocess = 2.6
	ps.local_coords = false
	ps.visibility_aabb = AABB(Vector3(-30, -30, -30), Vector3(60, 60, 60))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(16, 8, 16)
	pm.direction = Vector3(0.25, -1, 0.1)
	pm.spread = 12.0
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 4.0
	pm.gravity = Vector3(0.6, -1.2, 0.0)
	pm.turbulence_enabled = quality != 0
	pm.turbulence_noise_strength = 1.5
	pm.turbulence_noise_scale = 4.0
	pm.scale_min = 0.6
	pm.scale_max = 1.6
	ps.process_material = pm
	ps.draw_pass_1 = flake
	ps.layers = layers
	ps.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ps.top_level = true
	ps.emitting = false
	return ps


static func ratio(snowfall: float, views: int) -> float:
	if snowfall <= 0.0:
		return 0.0
	return maxf(snowfall * (SPLIT_FACTOR if views >= RSSettings.SPLIT_TIER_VIEWS else 1.0), 0.01)


static func apply(ps: GPUParticles3D, snowfall: float, views: int) -> void:
	ps.emitting = snowfall > 0.0
	ps.amount_ratio = ratio(snowfall, views)
