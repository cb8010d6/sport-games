## CPU regression for optional fork APIs, old settings and explicit raster fallback.
extends Node

var _checks := 0
var _failures := 0


func _ready() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("FAIL: " + message)


func _run() -> void:
	RSSettings.load_once()
	_check(RSSettings.upscale == 0 and RSSettings.nvidia_lighting == 0 and not RSSettings.nvidia_fg and RSSettings.nvidia_sharpness == 0, "legacy saves keep raster defaults and NIS off")
	_check(ProjectSettings.get_setting("physics/3d/physics_engine") == "Jolt Physics", "Jolt unchanged")
	_check(ProjectSettings.get_setting("physics/common/physics_ticks_per_second") == 120, "120 Hz unchanged")
	_check(not RSNvidia.dlss_available(), "headless never claims DLSS availability")
	_check(not RSNvidia.lighting_available(1) and not RSNvidia.lighting_available(2), "headless ray tracing unavailable")
	_check(RSSettings.upscale_count() == 6, "unsupported engine offers original six modes")
	var vp := SubViewport.new()
	for mode in RSSettings.UPSCALE_NAMES.size():
		RSSettings.upscale = mode
		RSSettings.apply_viewport(vp)
		var effective := mode - 5 if mode >= 6 else mode
		_check(RSSettings.effective_upscale() == effective, "requested mode maps to explicit FSR fallback")
		_check(vp.scaling_3d_mode == (Viewport.SCALING_3D_MODE_BILINEAR if effective == 0 else Viewport.SCALING_3D_MODE_FSR2), "apply_viewport owns scaling mode")
		_check(is_equal_approx(vp.scaling_3d_scale, RSSettings.UPSCALE_SCALES[effective]), "fallback uses matching scale")
		if effective > 0:
			_check(vp.msaa_3d == Viewport.MSAA_DISABLED and vp.screen_space_aa == Viewport.SCREEN_SPACE_AA_DISABLED, "temporal mode replaces spatial AA")
	RSSettings.nvidia_fg = true
	RSNvidia.apply_viewport(vp)
	if RSNvidia.has_property(vp, &"frame_generation"):
		_check(not vp.get("frame_generation"), "player SubViewport never requests FG")
	vp.free()
	RSSettings.upscale = 7
	RSSettings.nvidia_preset = 3
	RSSettings.nvidia_sharpness = 7
	RSSettings.nvidia_lighting = 2
	_check(RSSettings.save() == OK, "optional keys save through existing settings file")
	RSSettings.upscale = 0
	RSSettings.nvidia_preset = 0
	RSSettings.nvidia_sharpness = 0
	RSSettings.nvidia_lighting = 0
	RSSettings.nvidia_fg = false
	RSSettings._loaded = false
	RSSettings.load_once()
	_check(RSSettings.upscale == 7 and RSSettings.nvidia_preset == 3 and RSSettings.nvidia_lighting == 2 and RSSettings.nvidia_fg and RSSettings.nvidia_sharpness == 7, "optional settings round trip")
	_check(RSSettings.upscale_name().contains(RSLang.t("%s（回退 FSR）").get_slice("%s", 1)), "unsupported DLSS fallback visible")
	_check(RSSettings.nvidia_lighting_name() == RSLang.t("%s（回退光栅）") % RSLang.t(RSNvidia.LIGHTING_NAMES[2]), "unsupported PT fallback visible")
	var status := RSNvidia.fg_status()
	for key in ["available", "eligible", "sdk_enabled", "reason"]:
		_check(status.has(key), "status schema includes " + key)
	_check(not status.available and not status.sdk_enabled, "headless cannot claim generated frames")
	var cf := RSSave.read(RSSettings.PATH)
	cf.set_value("display", "nvidia_preset", -12)
	cf.set_value("display", "nvidia_lighting", 100)
	cf.set_value("display", "nvidia_sharpness", 100)
	cf.set_value("display", "nvidia_fg", "true")
	_check(RSSave.write(RSSettings.PATH, cf) == OK, "invalid optional fixture saved with checksum")
	RSSettings._loaded = false
	RSSettings.load_once()
	_check(RSSettings.nvidia_preset == 0 and RSSettings.nvidia_lighting == 2 and not RSSettings.nvidia_fg and RSSettings.nvidia_sharpness == 10, "optional settings validate type and range")
	print("RS_NVIDIA: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)
