class_name RSProps
## Props placed in bulk with MultiMesh: Poly Haven scans (CC0) and the project's own shared kit
## models. A prefab names a glTF and the mesh parts to take from it (several files hold two
## variants side by side); the parts are re-centred so the prefab stands on the origin with its
## footprint centred, facing +Z. RSProps.place(parent, "urban_bench", transforms) adds one
## MultiMeshInstance3D per part.
##
## Keys are "<kit>_<name>"; the kits are the shared-library groups of docs/ASSETS.md (urban,
## nature, beach, marina, arena, hall). A glTF path is relative to the Poly Haven models folder,
## or starts with "shared:" for res://assets/shared/ (shared kit models, see that folder's CREDITS).

const ROOT := "res://assets/polyhaven/models/"
const SHARED_ROOT := "res://assets/shared/"
const KITS := ["urban", "nature", "beach", "marina", "arena", "hall"]
const PREFABS := {
	# urban: city street furniture (skate, basketball)
	"urban_lamp": ["street_lamp_01/street_lamp_01_2k", []],
	"urban_hydrant": ["fire_hydrant/fire_hydrant_lod", ["fire_hydrant", "fire_hydrant_cap_01", "fire_hydrant_cap_02", "fire_hydrant_cap_03", "fire_hydrant_chain"]],
	"urban_hydrant_aged": ["fire_hydrant/fire_hydrant_lod", ["fire_hydrant_aged", "fire_hydrant_cap_01_aged", "fire_hydrant_cap_02_aged", "fire_hydrant_cap_03_aged", "fire_hydrant_chain_aged"]],
	"urban_bin": ["metal_trash_can/metal_trash_can_2k", ["metal_trash_can", "metal_trash_can_handle_left", "metal_trash_can_handle_right"]],
	"urban_bin_rust": ["metal_trash_can/metal_trash_can_2k", ["metal_trash_can_rust", "metal_trash_can_rust_handle_left", "metal_trash_can_rust_handle_right"]],
	"urban_bench": ["modular_street_seating/modular_street_seating_2k", ["legs_single", "legs_double", "seat", "seat_back", "back_support_r", "back_support_l", "arm_rest_01", "arm_rest_02", "crossbar"]],
	"urban_barrier": ["concrete_road_barrier/concrete_road_barrier_lod", []],
	"urban_utility": ["utility_box_01/utility_box_01_2k", []],
	"urban_aircon": ["exterior_aircon_unit/exterior_aircon_unit_2k", ["exterior_aircon_unit"]],
	"urban_aircon_rust": ["exterior_aircon_unit/exterior_aircon_unit_2k", ["exterior_aircon_unit_rusted"]],
	"urban_plant": ["potted_plant_01/potted_plant_01_lod", []],
	"urban_planter": ["planter_box_02/planter_box_02_2k", []],
	"urban_cafe": ["outdoor_table_chair_set_01/outdoor_table_chair_set_01_2k", []],
	"urban_manhole": ["water_manhole_cover/water_manhole_cover_2k", []],
	"urban_shutter_door": ["rollershutter_door/rollershutter_door_2k", ["rollershutter_door_graffiti"]],
	"urban_shutter_window": ["rollershutter_window_02/rollershutter_window_02_2k", ["rollershutter_window_02_graffiti"]],
	"urban_shutter_window_01": ["rollershutter_window_01/rollershutter_window_01_2k", ["rollershutter_window_01"]],
	"urban_shutter_window_01_graffiti": ["rollershutter_window_01/rollershutter_window_01_2k", ["rollershutter_window_01_graffiti"]],
	"urban_whale": ["bronze_whale_statue/bronze_whale_statue_2k", []],
	"urban_cat_statue": ["concrete_cat_statue/concrete_cat_statue_2k", []],
	"urban_barrel": ["Barrel_01/Barrel_01_2k", []],
	"urban_barrel_blue": ["barrel_03/barrel_03_2k", []],
	"urban_tyre": ["old_tyre/old_tyre_2k", []],
	"urban_box": ["cardboard_box_01/cardboard_box_01_2k", []],
	"urban_crate": ["plastic_crate_01/plastic_crate_01_2k", []],
	"urban_boombox": ["boombox/boombox_2k", []],
	"urban_spray_paint": ["spray_paint_bottles/spray_paint_bottles_2k", ["spray_paint_bottles"]],
	"urban_spray_paint_dirty": ["spray_paint_bottles/spray_paint_bottles_2k", ["spray_paint_bottles_dirty"]],
	# nature: rocks and vegetation (skate beach, ski)
	"nature_boulder": ["boulder_01/boulder_01_lod", []],
	# beach: promenade and shore
	"beach_lifebuoy": ["lifebuoy/lifebuoy_2k", []],
	# hall: indoor venues (bowling #25, table tennis, boxing)
	"hall_wet_floor_sign": ["WetFloorSign_01/WetFloorSign_01_2k", []],
}

static var _cache: Dictionary = {}


static func parts(key: String) -> Array:
	## [[Mesh, Transform3D], ...] for the prefab, re-centred (bottom centre at the origin).
	if _cache.has(key):
		return _cache[key]
	var spec: Array = PREFABS[key]
	var scene: PackedScene = load(path(spec[0]))
	var root := scene.instantiate() as Node3D
	var names: Array = spec[1]
	var out: Array = []
	var box := AABB()
	var first := true
	var stack: Array = [[root, Transform3D()]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var n: Node = item[0]
		var xf: Transform3D = item[1]
		if n is Node3D and n != root:
			xf = xf * (n as Node3D).transform
		if n is MeshInstance3D and (names.is_empty() or names.has(String(n.name))):
			var mesh := (n as MeshInstance3D).mesh
			out.append([mesh, xf])
			var b := xf * mesh.get_aabb()
			box = b if first else box.merge(b)
			first = false
		for c in n.get_children():
			stack.append([c, xf])
	root.free()
	var shift := Vector3(-(box.position.x + box.size.x * 0.5), -box.position.y, -(box.position.z + box.size.z * 0.5))
	for p in out:
		p[1] = Transform3D(Basis(), shift) * p[1]
	_cache[key] = out
	return out


static func path(gltf: String) -> String:
	## res:// path of a prefab glTF ("shared:arena/..." or a Poly Haven models path), with extension.
	if gltf.begins_with("shared:"):
		return SHARED_ROOT + gltf.trim_prefix("shared:") + ".gltf"
	return ROOT + gltf + ".gltf"


static func size(key: String) -> Vector3:
	var box := AABB()
	var first := true
	for p in parts(key):
		var b: AABB = p[1] * (p[0] as Mesh).get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box.size


static func place(parent: Node, key: String, xforms: Array, layers: int = 1, shadows: bool = true) -> void:
	if xforms.is_empty():
		return
	for p in parts(key):
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = p[0]
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, (xforms[i] as Transform3D) * (p[1] as Transform3D))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = key
		mmi.multimesh = mm
		mmi.layers = layers
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mmi)
