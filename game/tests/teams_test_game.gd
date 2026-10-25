extends RSPartyGame
## Smallest game with sides, for test_teams.gd: no world, a short countdown, and a round that
## ends as soon as the test has written the scores. `mode` and `size_for` stand in for the
## _team_mode / _team_size answers a real game gives.

var mode := RSTeams.Mode.TEAMS
var size_for := -1               ## _team_size answer; -1 = the mode's default
var scores: Dictionary = {}      ## slot -> score written at the start of play
var added: Array = []            ## slots _player_added saw, with their filler flag
var removed: Array = []


func _game_name() -> String:
	return "Teams test"   # no-i18n


func _oled_name() -> String:
	return "TEAMS"


func _countdown_time() -> float:
	return 0.1


func _team_mode() -> int:
	return mode


func _team_size(count: int) -> int:
	return size_for if size_for > 0 else super(count)


func _player_added(p: Player) -> void:
	added.append([p.c.player, p.filler])


func _player_removed(p: Player) -> void:
	removed.append(p.c.player)


func _play_process(_delta: float) -> void:
	if phase_time < 0.05:
		return
	for p: Player in players.values():
		p.score = int(scores.get(p.c.player, 0))
	finish_round()
