extends Node
## Full three-event integration: actual scenes, bots, scoring and result-button transitions.

var _seen: Array = []
var _expected: Dictionary = {1: 0, 2: 0}
var _failed := false


func _ready() -> void:
	_start.call_deferred()


func _start() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	# Keep this driver alive while the real game scenes replace one another.
	get_tree().current_scene = null
	RSTournament.begin(["plane", "archery", "bowling"], [1, 2])
	get_tree().change_scene_to_file(RSCatalog.find_game("plane")["scene"])


func _process(_delta: float) -> void:
	var current := get_tree().current_scene
	if not current is RSPartyGame:
		return
	var game := current as RSPartyGame
	if game.phase != RSPartyGame.Phase.RESULTS or game.phase_time < maxf(game.results_delay, 1.0) + 0.1:
		return
	if game.game_id() in _seen:
		return
	_seen.append(game.game_id())
	var list := game.ranked_players()
	var rank := 1
	for i in list.size():
		var player: RSPartyGame.Player = list[i]
		if i > 0 and player.score != (list[i - 1] as RSPartyGame.Player).score:
			rank = i + 1
		_expected[player.c.player] += RSTournament.POINTS[rank - 1]
		if RSTournament.entrants[player.c.player]["points"] != _expected[player.c.player]:
			_failed = true
		if RSRecords.best(game.game_id(), game.map_index, player.c.player) != -1:
			_failed = true # a demo bot must not write a personal best
	print("RS_PARTY_EVENT_DONE: " + game.game_id())
	if RSTournament.last_round():
		game._on_button((list[0] as RSPartyGame.Player).c, RSController.BTN_A, true)
		_failed = _failed or not game._tournament_final_shown
		print("RS_PARTY_FLOW: " + ("FAIL" if _failed or _seen.size() != 3 else "PASS"))
		get_tree().quit(1 if _failed else 0)
	else:
		game._on_button((list[0] as RSPartyGame.Player).c, RSController.BTN_A, true)
