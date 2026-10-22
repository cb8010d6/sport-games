extends Node
## Asset-generation harness: exports the real camera's 3D viewport, without HUD nodes.

const TIMES := {"plane": 4.0, "archery": 4.5, "bowling": 3.0,
	"skate": 4.0, "ski": 4.0, "basketball": 4.0}


func _ready() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1" or DisplayServer.get_name() == "headless":
		push_error("Use tools/capture_previews.py with a graphics driver and isolated data.")
		get_tree().quit(1)
		return
	_run.call_deferred()


func _run() -> void:
	var id := OS.get_environment("RS_PREVIEW_GAME")
	var entry := RSCatalog.find_game(id)
	if entry.is_empty() or not TIMES.has(id):
		get_tree().quit(1)
		return
	get_tree().current_scene = null
	var game := (load(entry["scene"]) as PackedScene).instantiate() as RSPartyGame
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	for _i in 1800:
		await get_tree().process_frame
		if game.phase == RSPartyGame.Phase.PLAY and game.phase_time >= TIMES[id]:
			break
	if game.phase != RSPartyGame.Phase.PLAY or game.players.size() != 1:
		get_tree().quit(1)
		return
	var player: RSPartyGame.Player = game.ordered()[0]
	await RenderingServer.frame_post_draw
	var picture := player.cam.get_viewport().get_texture().get_image()
	if picture.get_size() != Vector2i(1600, 900):
		push_error("Preview camera viewport must be 1600x900")
		get_tree().quit(1)
		return
	picture.convert(Image.FORMAT_RGB8)
	var err := picture.save_jpg(OS.get_environment("RS_PREVIEW_OUTPUT"), 0.92)
	for audio: AudioStreamPlayer in game.find_children("*", "AudioStreamPlayer", true, false):
		audio.stop()
		audio.stream = null
	get_tree().current_scene = null
	game.queue_free()
	var until := Time.get_ticks_msec() + 350
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
	print("RS_PREVIEW_DONE: %s 1600x900" % id)
	get_tree().quit(0 if err == OK else 1)
