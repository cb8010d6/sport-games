## Optional NVIDIA fork adapter. Official Godot parses this without fork-only types.
## Settings are requests: SDK option acceptance does not prove generated output frames.
class_name RSNvidia
extends RefCounted

const PRESETS := ["Recommended", "K", "L", "M"]
const LIGHTING_NAMES := ["光栅", "DDGI（实验）", "路径追踪 + RR（实验）"]


static func has_property(object: Object, key: StringName) -> bool:
	for item: Dictionary in object.get_property_list():
		if item.name == key:
			return true
	return false


static func capability(name: String) -> bool:
	if not Engine.has_singleton("Streamline") or not ClassDB.class_has_integer_constant("Streamline", name):
		return false
	var api := Engine.get_singleton("Streamline")
	return api.has_method("get_capability") and bool(api.call("get_capability", ClassDB.class_get_integer_constant("Streamline", name)))


static func dlss_available() -> bool:
	return RenderingServer.get_current_rendering_method() == "forward_plus" and capability("STREAMLINE_CAPABILITY_DLSS") \
		and ClassDB.class_has_integer_constant("Viewport", "SCALING_3D_MODE_DLSS")


static func lighting_available(mode: int) -> bool:
	if mode == 0:
		return true
	# This fork's D3D12 driver has no ray-tracing pipeline; HDR remains a separate path.
	if RenderingServer.get_current_rendering_driver_name() != "vulkan" or RenderingServer.get_current_rendering_method() != "forward_plus":
		return false
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not ClassDB.class_has_integer_constant("RenderingDevice", "SUPPORTS_RAYTRACING_PIPELINE"):
		return false
	if not rd.has_feature(ClassDB.class_get_integer_constant("RenderingDevice", "SUPPORTS_RAYTRACING_PIPELINE")):
		return false
	var env := Environment.new()
	if mode == 1:
		return has_property(env, &"ddgi_enabled")
	return has_property(env, &"pathtracing_enabled") and has_property(env, &"pathtracing_denoiser") \
		and ClassDB.class_has_integer_constant("RenderingServer", "PT_DENOISER_DLSS_RAY_RECONSTRUCTION") \
		and dlss_available() and capability("STREAMLINE_CAPABILITY_DLSS_RR")


static func apply_preset() -> void:
	if not dlss_available() or not ClassDB.class_has_integer_constant("Streamline", "STREAMLINE_PARAM_DLSS_PRESET"):
		return
	var api := Engine.get_singleton("Streamline")
	if api.has_method("set_parameter"):
		api.call("set_parameter", ClassDB.class_get_integer_constant("Streamline", "STREAMLINE_PARAM_DLSS_PRESET"), PRESETS[RSSettings.nvidia_preset])


static func warmup_available() -> bool:
	## Official Godot and non-RT paths retain their existing startup behavior.
	return DisplayServer.get_name() != "headless" and RSSettings.nvidia_lighting == 2 and RSSettings.upscale >= 6 \
		and lighting_available(2) and ClassDB.class_has_integer_constant("RenderingServer", "VIEWPORT_RENDER_INFO_RT_FRAME_SERIAL")


static func warmup_snapshot(vp: Viewport, previous: int) -> Dictionary:
	## Compare serials around the read so multiple server calls cannot mix frames.
	if not warmup_available():
		return {"state": "unsupported"}
	if not is_instance_valid(vp) or not vp.is_inside_tree():
		return {"state": "failed", "reason": "viewport_removed"}
	var camera := vp.get_camera_3d()
	if camera == null:
		return {"state": "not_applicable"}
	var env := camera.environment if camera.environment != null else vp.find_world_3d().environment
	if env == null or not has_property(env, &"pathtracing_enabled") or not bool(env.get("pathtracing_enabled")):
		return {"state": "not_applicable"}
	var names := ["RT_FRAME_SERIAL", "RT_DISPATCHES", "RT_TLAS_INSTANCES", "RT_SHADER_PENDING", "RT_SHADER_FAILED"]
	var values: Array[int] = []
	var rid := vp.get_viewport_rid()
	var visible_type := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE
	for name: String in names:
		var key := ClassDB.class_get_integer_constant("RenderingServer", "VIEWPORT_RENDER_INFO_" + name)
		values.append(RenderingServer.viewport_get_render_info(rid, visible_type, key))
	var serial_key := ClassDB.class_get_integer_constant("RenderingServer", "VIEWPORT_RENDER_INFO_RT_FRAME_SERIAL")
	var serial := RenderingServer.viewport_get_render_info(rid, visible_type, serial_key)
	var result := {"state": "not_rendered", "serial": serial, "dispatches": values[1], "tlas": values[2],
		"pending": values[3], "failed": values[4]}
	if serial != values[0]:
		return result
	if values[4] > 0:
		result["state"] = "failed"
	elif values[3] > 0:
		result["state"] = "pending"
	elif serial > 0 and serial != previous and values[1] > 0 and values[2] > 0:
		result["state"] = "ready"
	return result


static func apply_viewport(vp: Viewport) -> void:
	# FG is one generated frame for one main-window 3D view. Never request it for a
	# player SubViewport; the engine also guards the actual rendered-view topology.
	if has_property(vp, &"frame_generation"):
		vp.set("frame_generation", vp is Window and vp.is_inside_tree() and vp == vp.get_tree().root and not vp.use_xr and RSSettings.nvidia_fg \
			and capability("STREAMLINE_CAPABILITY_DLSS_G"))


static func environment(env: Environment) -> void:
	var mode := RSSettings.nvidia_lighting
	var supported := lighting_available(mode)
	var pt := mode == 2 and supported and RSSettings.upscale >= 6 and dlss_available()
	if has_property(env, &"pathtracing_enabled"):
		env.set("pathtracing_enabled", pt)
	if has_property(env, &"ddgi_enabled"):
		env.set("ddgi_enabled", mode == 1 and supported)
	if pt:
		env.set("pathtracing_denoiser", ClassDB.class_get_integer_constant("RenderingServer", "PT_DENOISER_DLSS_RAY_RECONSTRUCTION"))
		env.set("pathtracing_samples_per_pixel", 1)


static func fg_status() -> Dictionary:
	if Engine.has_singleton("Streamline"):
		var api := Engine.get_singleton("Streamline")
		if api.has_method("get_frame_generation_status"):
			var status: Variant = api.call("get_frame_generation_status")
			if status is Dictionary:
				return status
	return {"available": false, "eligible": false, "sdk_enabled": false, "reason": "unavailable"}


static func fg_name() -> String:
	if not RSSettings.nvidia_fg:
		return RSLang.t("关")
	var status := fg_status()
	match str(status.get("reason", "unavailable")):
		"ready":
			return RSLang.t("SDK 已启用（生成帧待实测）") if status.get("sdk_enabled", false) else RSLang.t("等待 SDK")
		"multiple_3d_views":
			return RSLang.t("多 3D 视口中停用")
		"offscreen_viewport", "no_request":
			return RSLang.t("仅主窗口 3D 可用")
		"editor":
			return RSLang.t("编辑器中停用")
		"no_3d_view":
			return RSLang.t("等待 3D 视口")
	return RSLang.t("当前不可用")


static func write_report(path: String, data: Dictionary) -> Error:
	## Legacy isolated experiment output; not a player save or evidence of visual quality.
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data, "\t") + "\n")
	file.flush()
	var error := file.get_error()
	file.close()
	return error
