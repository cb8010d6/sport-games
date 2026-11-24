class_name RSSkiEnvironment
extends RefCounted
## The unchanged ski sky, fog and sunlight, selected from RSSkiMaps. Kept outside
## RSSkiCourse so the tree-LOD slice also brings the touched course below SIZE.


static func setup(parent: Node, map: Dictionary) -> DirectionalLight3D:
	## Sky (Poly Haven HDRI), sun matching the map's light, fog for the depth of the valley.
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var pano := PanoramaSkyMaterial.new()
	pano.panorama = load(map["hdri"])
	pano.energy_multiplier = map["sky_energy"]
	var sky := Sky.new()
	sky.sky_material = pano
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	env.sky = sky
	env.sky_rotation = Vector3(0, float(map["sky_rot"]), 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = map["ambient"]
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = map["exposure"]
	env.ssao_enabled = true
	env.ssao_radius = 1.2
	env.ssao_intensity = 1.4
	env.glow_enabled = true
	env.glow_intensity = 0.55 if map["lights"] else 0.4
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.08
	env.adjustment_contrast = 1.06
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = map["fog"]
	env.fog_sun_scatter = 0.25
	env.fog_density = map["fog_density"]
	env.fog_sky_affect = 0.35 if float(map["fog_density"]) > 0.003 else 0.0
	env.fog_aerial_perspective = 0.5
	var we := WorldEnvironment.new()
	we.environment = env
	parent.add_child(we)

	var sun := DirectionalLight3D.new()
	var az := deg_to_rad(float(map["sun_az"]))
	var el := deg_to_rad(float(map["sun_el"]))
	var to_sun := Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))
	sun.basis = Basis.looking_at(-to_sun, Vector3.UP)
	sun.light_color = map["sun_color"]
	sun.light_energy = map["sun_energy"]
	sun.light_angular_distance = 0.5
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = 1.0
	sun.directional_shadow_max_distance = 140.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	parent.add_child(sun)
	return sun
