class_name RSMusic
extends AudioStreamPlayer
## One scene-owned music player on RSAudio.MUSIC. Cues have no third-party samples.
## Menu/lobby loop; victory plays once. Fades are cancelled when a new cue starts.

const TRACKS := {"menu": "res://assets/music/menu.wav", "lobby": "res://assets/music/lobby.wav",
	"victory": "res://assets/music/victory.wav"}
const GAIN_DB := -7.0
const FADE := 0.18
var track := ""
var _fade: Tween


static func attach(parent: Node) -> RSMusic:
	for child: Node in parent.get_children():
		if child is RSMusic:
			return child
	var music := RSMusic.new()
	parent.add_child(music)
	return music


func _init() -> void:
	RSAudio.ensure()
	bus = RSAudio.MUSIC
	name = "BackgroundMusic"
	process_mode = Node.PROCESS_MODE_PAUSABLE


func play_track(id: String) -> void:
	if not TRACKS.has(id):
		push_error("RSMusic: unknown cue %s" % id)
		return
	if track == id and playing:
		return
	_cancel_fade()
	track = id
	var cue := load(TRACKS[id]) as AudioStreamWAV
	if cue == null:
		push_error("RSMusic: missing cue %s" % id)
		return
	cue.loop_mode = AudioStreamWAV.LOOP_DISABLED if id == "victory" else AudioStreamWAV.LOOP_FORWARD
	cue.loop_begin = 0
	cue.loop_end = roundi(cue.get_length() * cue.mix_rate)
	stream = cue
	volume_db = -50.0
	play()
	_fade = create_tween()
	_fade.tween_property(self, "volume_db", GAIN_DB, FADE)


func silence() -> void:
	_cancel_fade()
	track = ""
	if playing:
		_fade = create_tween()
		_fade.tween_property(self, "volume_db", -50.0, FADE)
		_fade.tween_callback(stop)


func _cancel_fade() -> void:
	if _fade != null and _fade.is_valid():
		_fade.kill()


func _exit_tree() -> void:
	_cancel_fade()
	stop()
