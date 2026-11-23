extends Node
## Actual audio players and game/menu lifecycle, using isolated settings in the runner.

var _failures := 0
var _checks := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("Music: " + label)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true).timeout


func _run() -> void:
	var music := RSMusic.attach(self)
	_check(RSMusic.attach(self) == music, "attach reuses player instead of layering music")
	_check(music.bus == RSAudio.MUSIC, "dedicated music bus")
	for id: String in RSMusic.TRACKS:
		var stream := load(RSMusic.TRACKS[id]) as AudioStreamWAV
		_check(stream != null and stream.get_length() > 5.0 and stream.format == AudioStreamWAV.FORMAT_16_BITS
			and stream.mix_rate == 22050 and not stream.stereo, "lossless PCM cue loads: " + id)
	music.play_track("menu")
	await _wait(0.3)
	_check(music.playing and music.track == "menu", "menu music playing")
	_check((music.stream as AudioStreamWAV).loop_mode == AudioStreamWAV.LOOP_FORWARD, "menu cue loops")
	var at := music.get_playback_position()
	music.play_track("menu")
	_check(music.get_playback_position() >= at, "same cue does not restart")
	music.silence()
	music.play_track("lobby")
	await _wait(0.3)
	_check(music.playing and music.track == "lobby" and is_equal_approx(music.volume_db, RSMusic.GAIN_DB), "new cue cancels old stop fade")
	get_tree().paused = true
	await _wait(0.1)
	_check(music.stream_paused, "scene pause pauses music stream")
	get_tree().paused = false
	await _wait(0.1)
	_check(not music.stream_paused and music.playing, "resume continues music")
	var sfx_muted := AudioServer.is_bus_mute(AudioServer.get_bus_index(RSAudio.SFX))
	RSSettings.volumes[1] = 0
	RSSettings.apply_volumes()
	_check(AudioServer.is_bus_mute(AudioServer.get_bus_index(RSAudio.MUSIC)), "music volume zero mutes")
	_check(AudioServer.is_bus_mute(AudioServer.get_bus_index(RSAudio.SFX)) == sfx_muted, "music mute does not mute effects")
	RSSettings.volumes[1] = 7
	RSSettings.apply_volumes()
	music.silence()
	await _wait(0.3)
	_check(not music.playing and music.track.is_empty(), "fade reaches silence")
	await _game_lifecycle()
	await _menu_lifecycle()
	music.queue_free()
	await _wait(0.4)
	# Close the window while music and a looping effect still play: RSExit must drain them,
	# or the runner sees "leaked at exit" / "still in use at exit".
	RSExit.install(get_tree())
	_check(not get_tree().auto_accept_quit, "window close goes through RSExit")
	RSMusic.attach(self).play_track("menu")
	RSSfx.loop(self, "applause").volume_db = 0.0
	await _wait(0.2)
	print("RS_MUSIC_TESTS: %d checks, %d failures" % [_checks, _failures])
	if _failures == 0:
		get_tree().root.close_requested.emit()
	else:
		RSExit.quit(get_tree(), 1)


func _game_lifecycle() -> void:
	var game := RSPartyGame.new()
	add_child(game)
	var music := game._music
	_check(music != null and music.track == "lobby", "game lobby starts cue")
	game._start_countdown()
	await _wait(0.3)
	_check(not music.playing and music.track.is_empty(), "countdown fades music")
	game.phase = RSPartyGame.Phase.PLAY
	await _wait(0.1)
	_check(not music.playing, "play stays music-free")
	game.finish_round()
	await _wait(0.3)
	_check(music.track == "victory" and music.playing, "results start victory cue")
	_check((music.stream as AudioStreamWAV).loop_mode == AudioStreamWAV.LOOP_DISABLED, "victory does not loop")
	var at := music.get_playback_position()
	game.finish_round()
	_check(music.get_playback_position() >= at, "duplicate finish does not restart victory")
	await _wait(6.0)
	_check(not music.playing, "victory ends naturally after one cue")
	game._to_lobby()
	_check(music.track == "lobby", "again restores lobby cue")
	game.queue_free()
	await _wait(0.3)
	_check(not is_instance_valid(music), "scene change frees old music player")


func _menu_lifecycle() -> void:
	var menu := (load(RSPartyGame.MENU_SCENE) as PackedScene).instantiate()
	add_child(menu)
	await _wait(0.2)
	var players := menu.find_children("BackgroundMusic", "AudioStreamPlayer", true, false)
	_check(players.size() == 1 and (players[0] as RSMusic).track == "menu", "real menu owns one music player")
	menu.queue_free()
	await _wait(0.3)
	_check(not is_instance_valid(players[0]), "menu teardown releases music")
