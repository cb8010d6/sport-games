class_name RSPbr
## Materials from scanned PBR maps: the Poly Haven scans in res://assets/polyhaven (see
## tools/sync_assets.mjs) and processed materials from other CC0 sources under
## res://assets/shared/materials (docs/ASSETS.md "共享素材库").
## An id is a Poly Haven asset id ("clean_asphalt") or "<root>:<name>" for another root in ROOTS
## ("shared:acg_net004a"). Every root uses Poly Haven file names:
## <dir>/<name>_diff_<res>.jpg|png, <name>_nor_gl_<res>.jpg, <name>_arm_<res>.jpg.
## surface(): the anti-tiling shader for course geometry with UVs in metres.
## standard(): a plain ORMMaterial3D from the same maps (props, small parts).
## Picks the highest resolution that was downloaded; caches the textures.

const ROOT := "res://assets/polyhaven/textures/"
const ROOTS := {"shared": "res://assets/shared/materials/"}
const RESOLUTIONS := ["4k", "2k", "1k"]
const SHADER := preload("res://shaders/pbr_surface.gdshader")

static var _tex: Dictionary = {}


static func folder(id: String) -> String:
	## res:// folder holding the maps of a material id ("" for an unknown "<root>:" prefix).
	var at := id.find(":")
	if at < 0:
		return ROOT + id + "/"
	var root: String = ROOTS.get(id.left(at), "")
	return root + id.substr(at + 1) + "/" if root != "" else ""


static func map_path(id: String, map: String, res: String, ext: String = "jpg") -> String:
	## res:// path of one map ("diff", "nor_gl", "arm") at one resolution, Poly Haven naming.
	var dir := folder(id)
	if dir == "":
		return ""
	var name := id.substr(id.find(":") + 1)
	return "%s%s_%s_%s.%s" % [dir, name, map, res, ext]


static func maps(id: String) -> Array:
	## [albedo, normal, orm] textures (null for any that are missing).
	if _tex.has(id):
		return _tex[id]
	var out := [null, null, null]
	for res: String in (RESOLUTIONS if folder(id) != "" else []):
		# A diffuse map with alpha (cut-out nets, foliage) is a PNG; everything else is JPG.
		var diff := map_path(id, "diff", res)
		if not ResourceLoader.exists(diff):
			diff = map_path(id, "diff", res, "png")
		if ResourceLoader.exists(diff):
			out = [load(diff), _load_opt(map_path(id, "nor_gl", res)), _load_opt(map_path(id, "arm", res))]
			break
	if out[0] == null:
		push_warning("RSPbr: no textures for '%s'" % id)
	_tex[id] = out
	return out


static func _load_opt(path: String) -> Texture2D:
	return load(path) if ResourceLoader.exists(path) else null


static func surface(id: String, size_m: float, tint: Color = Color.WHITE, params: Dictionary = {}) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	var t := maps(id)
	m.set_shader_parameter("albedo_tex", t[0])
	m.set_shader_parameter("normal_tex", t[1])
	m.set_shader_parameter("orm_tex", t[2])
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("size_m", size_m)
	for k: String in params:
		m.set_shader_parameter(k, params[k])
	return m


static func standard(id: String, size_m: float = 1.0, tint: Color = Color.WHITE) -> ORMMaterial3D:
	var t := maps(id)
	var m := ORMMaterial3D.new()
	m.albedo_texture = t[0]
	m.albedo_color = tint
	m.normal_enabled = true
	m.normal_texture = t[1]
	m.orm_texture = t[2]
	m.ao_enabled = true
	m.metallic = 1.0
	m.roughness = 1.0
	m.uv1_scale = Vector3.ONE / size_m
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m
