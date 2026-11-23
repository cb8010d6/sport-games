class_name RSRenderWarmup
extends CanvasLayer
## A scene-owned RT loading gate. Real cameras keep rendering behind the cover;
## gameplay/physics pause until all active views publish fresh ready submissions.
## No settings are saved. Official Godot/non-RT paths do not create this gate.

signal completed(result: Dictionary)
signal cancelled

const TIMEOUT_MSEC := 120000   ## Failure deadline, never a successful wait duration.
const READY_SUBMISSIONS := 2

var busy := false
var result: Dictionary = {"state": "not_rendered"}
var _game: RSPartyGame
var _views: Array[Viewport] = []
var _serials: Dictionary = {}
var _ready: Dictionary = {}
var _update_modes: Dictionary = {}
var _saved_pause := false
var _restored := false
var _views_restored := false
var _closing := false
var _started := 0
var _message: Label


func begin(game: RSPartyGame, viewports: Array[Viewport]) -> void:
	_game = game
	for vp: Viewport in viewports:
		if is_instance_valid(vp) and RSNvidia.warmup_snapshot(vp, -1)["state"] != "not_applicable":
			_views.append(vp)
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 100
	if _views.is_empty() or not RSNvidia.warmup_available():
		_restored = true
		result = {"state": "not_applicable" if RSNvidia.warmup_available() else "unsupported"}
		completed.emit(result.duplicate(true))
		queue_free()
		return
	busy = true
	_started = Time.get_ticks_msec()
	_saved_pause = get_tree().paused
	_build_cover()
	for vp: Viewport in _views:
		var id := vp.get_instance_id()
		_serials[id] = int(RSNvidia.warmup_snapshot(vp, -1).get("serial", 0))
		_ready[id] = 0
		if vp is SubViewport:
			_update_modes[id] = (vp as SubViewport).render_target_update_mode
			(vp as SubViewport).render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_tree().paused = true
	get_tree().root.close_requested.connect(_window_closing)
	RenderingServer.frame_post_draw.connect(_after_draw)
	result = {"state": "pending", "views": _views.size()}


func _build_cover() -> void:
	var cover := ColorRect.new()
	cover.color = RSUi.PANEL_BG
	cover.color.a = 1.0
	cover.mouse_filter = Control.MOUSE_FILTER_STOP
	cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	cover.theme = RSUi.theme(20)
	add_child(cover)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	cover.add_child(center)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 24)
	center.add_child(column)
	_message = Label.new()
	_message.text = tr("正在准备画面…")
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_message)
	var back := Button.new()
	back.text = tr("返回主菜单")
	back.pressed.connect(cancel)
	column.add_child(back)
	back.grab_focus()


func _after_draw() -> void:
	if not busy or _closing:
		return
	if not is_instance_valid(_game) or _game.is_queued_for_deletion():
		busy = false
		result = {"state": "cancelled", "reason": "scene_removed"}
		_restore()
		queue_free()
		return
	var snapshots: Array[Dictionary] = []
	var all_ready := not _views.is_empty()
	for vp: Viewport in _views:
		if not is_instance_valid(vp):
			_fail("viewport_removed")
			return
		var id := vp.get_instance_id()
		var sample := RSNvidia.warmup_snapshot(vp, int(_serials[id]))
		snapshots.append(sample)
		if sample["state"] in ["failed", "unsupported", "not_applicable"]:
			result["views"] = snapshots.duplicate(true)
			_fail(str(sample["state"]))
			return
		var serial := int(sample.get("serial", 0))
		if serial > 0 and serial != int(_serials[id]):
			_serials[id] = serial
			_ready[id] = int(_ready[id]) + 1 if sample["state"] == "ready" else 0
		elif sample["state"] == "pending":
			_ready[id] = 0
		all_ready = all_ready and sample["state"] == "ready" and int(_ready[id]) >= READY_SUBMISSIONS
	result = {"state": "pending", "views": snapshots, "ready_submissions": _ready.duplicate(),
		"elapsed_msec": Time.get_ticks_msec() - _started}
	if all_ready:
		busy = false
		result["state"] = "ready"
		_restore()
		completed.emit(result.duplicate(true))
		queue_free()


func _process(_delta: float) -> void:
	if busy and not _closing and Time.get_ticks_msec() - _started >= TIMEOUT_MSEC:
		_fail("timeout")


func _fail(reason: String) -> void:
	busy = false
	result["state"] = "timeout" if reason == "timeout" else "failed"
	result["reason"] = reason
	result["elapsed_msec"] = Time.get_ticks_msec() - _started
	_restore_views()
	_message.text = tr("画面准备失败。请返回主菜单后重试。")
	# Keep physics and clocks paused; cancellation is an explicit recovery path.
	completed.emit(result.duplicate(true))
	push_warning("RT warmup did not complete: " + reason) # no-i18n


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		cancel()


func cancel() -> void:
	if _restored or _closing:
		return
	busy = false
	result["state"] = "cancelled"
	_restore()
	cancelled.emit()
	queue_free()


func _window_closing() -> void:
	_closing = true   # RSExit owns the pause/audio-drain state during shutdown.
	busy = false
	result = {"state": "cancelled", "reason": "window_closing"}
	_restore_views()


func _restore() -> void:
	if _restored:
		return
	_restored = true
	_restore_views()
	if is_inside_tree() and not _closing:
		get_tree().paused = _saved_pause


func _restore_views() -> void:
	if _views_restored:
		return
	_views_restored = true
	if RenderingServer.frame_post_draw.is_connected(_after_draw):
		RenderingServer.frame_post_draw.disconnect(_after_draw)
	for vp: Viewport in _views:
		if is_instance_valid(vp) and vp is SubViewport and _update_modes.has(vp.get_instance_id()):
			(vp as SubViewport).render_target_update_mode = _update_modes[vp.get_instance_id()]


func _exit_tree() -> void:
	_restore()
