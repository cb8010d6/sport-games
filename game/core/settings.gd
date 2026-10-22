class_name RSSettings
extends RefCounted
## Player-facing display settings (frame rate, graphics quality, window mode), kept in
## user://settings.cfg and applied to the window, every viewport in the tree and every
## WorldEnvironment. The pause menu (RSPauseMenu) changes them; scenes call apply() once
## their viewports exist.
##
## VRR (FreeSync / G-Sync): Godot has no switch for it; a variable-refresh display follows
## the game's frame rate by itself as long as frames come a little slower than its maximum
## refresh. The VRR frame rate mode does the usual thing for that: V-Sync on (no tearing
## above the range) and a cap a few frames under the display's refresh rate, so frames never
## queue up behind V-Sync. Best in exclusive fullscreen.
##
## HDR: on Windows Godot outputs HDR only through Direct3D 12, and the driver is picked at
## startup. Vulkan is the default; enabling HDR writes the driver switch to OVERRIDE_PATH
## (project.godot's project_settings_override) for the next start. Test output and performance
## on the target display and GPU.

const PATH := "user://settings.cfg"
const OVERRIDE_PATH := "user://override.cfg"
const VSYNC := 0
const VRR := -2
const UNCAPPED := -1
const FPS := [VSYNC, VRR, 30, 60, 120, 144, UNCAPPED]   ## anything > 0 is a cap
const OLD_FPS := [VSYNC, 30, 60, 120, UNCAPPED]          ## the "fps" key's indices before VRR
const QUALITY_NAMES := ["低", "中", "高", "极高"]
const WINDOW_NAMES := ["窗口", "全屏", "独占全屏"]
## Upscaling: render 3D smaller and let AMD FSR 2 rebuild the detail (its own temporal
## anti-aliasing replaces MSAA / FXAA). Scales are AMD's presets.
const UPSCALE_NAMES := ["原生", "FSR 质量", "FSR 均衡", "FSR 性能", "FSR 超级性能"]
const UPSCALE_SCALES := [1.0, 0.77, 0.67, 0.59, 0.5]

static var fps := 0                          ## index into FPS
static var quality := 2                      ## index into QUALITY_NAMES
static var window := 0                       ## index into WINDOW_NAMES
static var upscale := 0                      ## index into UPSCALE_NAMES
static var language := 0                     ## index into RSLang.CODES
static var hdr := false
static var color_safe := false
static var camera_shake := true              ## cosmetic impact jitter; existing behavior by default
static var volumes := [10, 7, 10, 8]         ## 0..10 per RSAudio.BUSES (master, music, sfx, ambience)
static var _loaded := false


static func load_once() -> void:
	if _loaded:
		return
	_loaded = true
	var cf := ConfigFile.new()
	cf.load(PATH)
	language = clampi(int(cf.get_value("general", "language", 0)), 0, RSLang.CODES.size() - 1)   # Chinese first
	RSLang.apply(language)
	color_safe = bool(cf.get_value("accessibility", "color_safe", false))
	var shake: Variant = cf.get_value("accessibility", "camera_shake", true)
	camera_shake = shake if shake is bool else true
	for i in volumes.size():
		volumes[i] = clampi(int(cf.get_value("audio", (RSAudio.BUSES[i] as String).to_lower(), volumes[i])), 0, RSAudio.STEPS)
	if not cf.has_section("display"):
		return
	var mode: int = cf.get_value("display", "frame_rate",
		OLD_FPS[clampi(int(cf.get_value("display", "fps", 0)), 0, OLD_FPS.size() - 1)])
	fps = maxi(FPS.find(mode), 0)
	quality = clampi(int(cf.get_value("display", "quality", quality)), 0, QUALITY_NAMES.size() - 1)
	window = clampi(int(cf.get_value("display", "window", 1 if cf.get_value("display", "fullscreen", false) else 0)),
		0, WINDOW_NAMES.size() - 1)
	hdr = bool(cf.get_value("display", "hdr", false))
	upscale = clampi(int(cf.get_value("display", "upscale", 0)), 0, UPSCALE_NAMES.size() - 1)


static func save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("display", "frame_rate", FPS[fps])
	cf.set_value("display", "quality", quality)
	cf.set_value("display", "window", window)
	cf.set_value("display", "hdr", hdr)
	cf.set_value("display", "upscale", upscale)
	cf.set_value("general", "language", language)
	cf.set_value("accessibility", "color_safe", color_safe)
	cf.set_value("accessibility", "camera_shake", camera_shake)
	for i in volumes.size():
		cf.set_value("audio", (RSAudio.BUSES[i] as String).to_lower(), volumes[i])
	cf.save(PATH)
	_save_override()


static func _save_override() -> void:
	## Settings that only take effect at startup.
	var cf := ConfigFile.new()
	cf.load(OVERRIDE_PATH)
	if hdr and OS.get_name() == "Windows":
		cf.set_value("rendering", "rendering_device/driver.windows", "d3d12")
	elif cf.has_section_key("rendering", "rendering_device/driver.windows"):
		cf.erase_section_key("rendering", "rendering_device/driver.windows")
	cf.save(OVERRIDE_PATH)


static func hdr_ready() -> bool:
	## The running driver can output HDR (on Windows: Direct3D 12).
	return OS.get_name() != "Windows" or RenderingServer.get_current_rendering_driver_name() == "d3d12"


static func hdr_active() -> bool:
	## HDR is on, the driver can do it and the window's screen supports it.
	return hdr and hdr_ready() and DisplayServer.window_is_hdr_output_supported()


static func hdr_name() -> String:
	if not hdr:
		return RSLang.t("关")
	if not hdr_ready():
		return RSLang.t("开（重启游戏后生效）")
	if not DisplayServer.window_is_hdr_output_supported():
		return RSLang.t("开（这块屏幕不支持）")
	return RSLang.t("开")


static func hdr_oled() -> String:
	if not hdr:
		return "OFF"
	if not hdr_ready():
		return "RESTART"
	return "ON" if DisplayServer.window_is_hdr_output_supported() else "N/A"


static func refresh_rate() -> int:
	## The current screen's refresh rate in Hz (60 when the system doesn't say).
	var hz := DisplayServer.screen_get_refresh_rate(DisplayServer.window_get_current_screen())
	return roundi(hz) if hz > 0.0 else 60


static func vrr_cap() -> int:
	return maxi(refresh_rate() - 3, 30)


static func fps_name() -> String:
	match FPS[fps]:
		VSYNC:
			return RSLang.t("垂直同步（%d Hz）") % refresh_rate()
		VRR:
			return RSLang.t("VRR 可变刷新（%d 帧）") % vrr_cap()
		UNCAPPED:
			return RSLang.t("不限")
	return RSLang.t("%d 帧") % FPS[fps]


static func fps_oled() -> String:
	match FPS[fps]:
		VSYNC:
			return "VSYNC"
		VRR:
			return "VRR %d" % vrr_cap()
		UNCAPPED:
			return "MAX"
	return str(FPS[fps])


static func window_name() -> String:
	return RSLang.t(WINDOW_NAMES[window])


static func upscale_name() -> String:
	return RSLang.t(UPSCALE_NAMES[upscale])


static func language_name() -> String:
	return RSLang.NAMES[language]


static func next_language() -> void:
	## Switch the language and save it; the caller reloads its scene so every text is redone.
	language = (language + 1) % RSLang.CODES.size()
	RSLang.apply(language)
	save()


static func quality_name() -> String:
	return RSLang.t(QUALITY_NAMES[quality])


static func apply_volumes() -> void:
	for i in volumes.size():
		RSAudio.set_volume(RSAudio.BUSES[i], volumes[i])


static func volume_name(i: int) -> String:
	return RSLang.t("静音") if volumes[i] <= 0 else "%d%%" % (volumes[i] * 100 / RSAudio.STEPS)


static func apply(tree: SceneTree) -> void:
	load_once()
	# Window first: the refresh rate VRR caps to is the screen's the window ends up on.
	var want: int = [DisplayServer.WINDOW_MODE_WINDOWED, DisplayServer.WINDOW_MODE_FULLSCREEN,
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN][window]
	var mode := DisplayServer.window_get_mode()
	if mode == DisplayServer.WINDOW_MODE_MAXIMIZED or mode == DisplayServer.WINDOW_MODE_MINIMIZED:
		mode = DisplayServer.WINDOW_MODE_WINDOWED
	if mode != want and not DisplayServer.get_name().contains("headless"):
		DisplayServer.window_set_mode(want)
	apply_volumes()
	# HDR output (the viewports' HDR 2D buffers are set below).
	tree.root.hdr_output_requested = hdr_active()
	# Frame rate.
	var setting: int = FPS[fps]
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED if setting == UNCAPPED else DisplayServer.VSYNC_ENABLED)
	Engine.max_fps = vrr_cap() if setting == VRR else maxi(setting, 0)
	# Shadows (global).
	RenderingServer.directional_shadow_atlas_set_size([2048, 4096, 4096, 8192][quality], true)
	RenderingServer.directional_soft_shadow_filter_set_quality([
		RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW, RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM, RenderingServer.SHADOW_QUALITY_SOFT_HIGH][quality])
	# Every viewport: resolution scale, anti-aliasing, mesh LOD.
	var root := tree.root
	apply_viewport(root)
	for vp: Viewport in root.find_children("*", "SubViewport", true, false):
		apply_viewport(vp)
	for we: WorldEnvironment in root.find_children("*", "WorldEnvironment", true, false):
		environment(we.environment)
	for sun: DirectionalLight3D in root.find_children("*", "DirectionalLight3D", true, false):
		sun_shadows(sun)


static func apply_viewport(vp: Viewport) -> void:
	load_once()
	var fsr := upscale > 0
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2 if fsr else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = UPSCALE_SCALES[upscale]
	if fsr:
		vp.msaa_3d = Viewport.MSAA_DISABLED
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	else:
		vp.msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_2X, Viewport.MSAA_4X][quality]
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if quality < 3 else Viewport.SCREEN_SPACE_AA_SMAA
	vp.mesh_lod_threshold = [4.0, 2.0, 1.0, 0.5][quality]
	# Float buffers so the split-screen views and the window keep highlights above SDR white.
	vp.use_hdr_2d = hdr_active()


static func sun_shadows(sun: DirectionalLight3D) -> void:
	## Shadows that soften with distance from the caster (PCSS, from the sun's angular size)
	## can be expensive; below 极高 the sun keeps an ordinary filtered soft edge instead.
	## The scene's value is kept as metadata.
	if not sun.has_meta("angular_distance"):
		sun.set_meta("angular_distance", sun.light_angular_distance)
	sun.light_angular_distance = sun.get_meta("angular_distance") if quality >= 3 else 0.0


static func environment(env: Environment) -> void:
	## Expensive screen-space effects off at low quality; what the scene asked for is kept as
	## metadata so they come back at higher settings.
	if env == null:
		return
	for key in ["ssao_enabled", "ssr_enabled", "ssil_enabled", "sdfgi_enabled", "glow_enabled", "volumetric_fog_enabled"]:
		if not env.has_meta(key):
			env.set_meta(key, env.get(key))
		var want: bool = env.get_meta(key)
		match key:
			"ssao_enabled", "glow_enabled":
				want = want and quality >= 1
			"ssr_enabled", "volumetric_fog_enabled":
				want = want and quality >= 2
			"ssil_enabled", "sdfgi_enabled":
				want = want and quality >= 3
		env.set(key, want)
