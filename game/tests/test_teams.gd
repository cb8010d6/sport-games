extends Node
## RSTeams: sides, fillers, team ranking, party points and podium places, then one 2v2 round
## with three people and a filler through countdown -> finish_round -> results -> tournament.
## Run through tools/test_game.py (isolated user data, RS_TEST_MODE=1).

const TestGame := preload("res://tests/teams_test_game.gd")

var _checks := 0
var _failures := 0


func _ready() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1":
		push_error("Use tools/test_game.py: these tests need an isolated user data directory.")
		get_tree().quit(1)
		return
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("FAIL: " + message)


func _player(game: RSPartyGame, slot: int, score: int, fake := false, kind := "ble") -> RSPartyGame.Player:
	## A bare player (no views) for the ranking checks on a game outside the tree.
	var p := RSPartyGame.Player.new()
	p.c = RSController.new()
	p.c.id = slot
	p.c.player = slot
	p.c.kind = kind
	p.fake = fake
	p.score = score
	game.players[p.c.id] = p
	return p


func _slots(list: Array) -> Array:
	return list.map(func(p: RSPartyGame.Player) -> int: return p.c.player)


func _run() -> void:
	_unit()
	await _round()
	print("RS_TEAMS_CHECKS: %d" % _checks)
	print("RS_TEAMS_TESTS: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)


func _unit() -> void:
	_check(RSTeams.mode_id(RSTeams.Mode.FFA) == "ffa" and RSTeams.mode_id(RSTeams.Mode.VERSUS) == "versus"
		and RSTeams.mode_id(RSTeams.Mode.TEAMS) == "teams", "manifest mode ids")
	_check(RSTeams.mode_from_id("teams") == RSTeams.Mode.TEAMS and RSTeams.mode_from_id("?") == RSTeams.Mode.FFA, "unknown mode id is FFA")
	_check(RSTeams.side(0) == 1.0 and RSTeams.side(1) == -1.0, "sides play from opposite ends")

	# FFA: exactly the old ranking and the old 1, 1, 3 places; no sides, no grouping.
	var ffa := TestGame.new()
	ffa.mode = RSTeams.Mode.FFA
	for item: Array in [[1, 50], [2, 80], [3, 50], [4, 10]]:
		_player(ffa, item[0], item[1])
	var list := ffa.ranked_players()
	_check(_slots(list) == [2, 1, 3, 4], "FFA ranking by score, ties by slot")
	_check(RSTeams.places(ffa, list) == PackedInt32Array([1, 2, 2, 4]), "FFA places share ties")
	_check(not RSTeams.grouped(ffa) and RSTeams.side_size(ffa, 4) == 0 and RSTeams.lobby_line(ffa).is_empty(), "FFA has no sides")
	_check(_slots(ffa._view_order()) == [1, 2, 3, 4], "FFA views keep slot order")
	_check(RSTeams.podium_scores(ffa, list) == PackedInt64Array([80, 50, 50, 10]), "FFA podium scores are the players'")
	_check(RSTeams.ranked_teams(ffa).size() == 4, "FFA: one entry per player")
	ffa.free()

	# Side sizes: VERSUS grows to 2v2 with three or four players; TEAMS is 2v2.
	var game := TestGame.new()
	game.mode = RSTeams.Mode.VERSUS
	_check(RSTeams.side_size(game, 1) == 1 and RSTeams.side_size(game, 2) == 1 and RSTeams.side_size(game, 3) == 2, "versus side size follows the count")
	game.mode = RSTeams.Mode.TEAMS
	_check(RSTeams.side_size(game, 1) == 2 and RSTeams.side_size(game, 4) == 2 and RSTeams.side_size(game, 9) == RSTeams.MAX_SIDE, "teams side size")

	# Assignment: people alternate sides, fillers take what is left; the solo CPU opposes its player.
	var p1 := _player(game, 1, 300)
	var p2 := _player(game, 2, 500)
	var p3 := _player(game, 3, 100)
	var f4 := _player(game, 4, 50, true, "bot")
	f4.filler = true
	game._assign_teams(RSTeams.lineup(game), 2)
	_check([p1.team, p2.team, p3.team, f4.team] == [0, 1, 0, 1], "three people and a filler: 1+3 against 2+filler")
	_check(_slots(RSTeams.members(game, 0)) == [1, 3] and _slots(RSTeams.members(game, 1)) == [2, 4], "members in slot order")
	_check(_slots(game._view_order()) == [1, 2, 3, 4], "2v2 views: red in the left column, blue in the right")
	var rows := RSTeams.ranked_teams(game)
	_check(rows.size() == 2 and rows[0]["team"] == 1 and rows[0]["score"] == 550 and rows[0]["rank"] == 1
		and rows[1]["team"] == 0 and rows[1]["score"] == 400 and rows[1]["rank"] == 2, "sides rank by summed score")
	list = game.ranked_players()
	_check(_slots(list) == [2, 4, 1, 3], "ranked players keep teammates together")
	_check(RSTeams.places(game, list) == PackedInt32Array([1, 1, 2, 2]), "every member takes the side's place")
	_check(RSTeams.podium_scores(game, list) == PackedInt64Array([550, 550, 400, 400]), "podium scores are the side's")
	_check(RSTeams.grouped(game) and RSTeams.lobby_line(game) != "", "2v2 results are grouped by side")
	_check(RSTeams.shared_score([p1, p3]) == 300 and RSTeams.sum_score([p1, p3]) == 400 and RSTeams.shared_score([]) == 0, "score helpers")
	p1.score = 450   # sides tie at 550
	rows = RSTeams.ranked_teams(game)
	list = game.ranked_players()
	_check(rows[0]["rank"] == 1 and rows[1]["rank"] == 1 and _slots(list) == [1, 3, 2, 4], "tied sides share first place, lower slot first")
	_check(RSTeams.places(game, list) == PackedInt32Array([1, 1, 1, 1]), "a tie gives everyone first place")
	_check(game.color_of(f4) == RSTeams.BOT_COLOR and game.color_of(p1) == RSProfiles.player_color(1), "filler shows neutral, people keep their colour")
	_check(not game.can_record(f4), "a filler never records")
	game.free()

	var solo := TestGame.new()
	var human := _player(solo, 1, 0)
	var cpu := _player(solo, 2, 0, true, "bot")
	var fa := _player(solo, 3, 0, true, "bot")
	var fb := _player(solo, 4, 0, true, "bot")
	fa.filler = true
	fb.filler = true
	solo._assign_teams(RSTeams.lineup(solo), 2)
	_check(human.team != cpu.team and fa.team != fb.team, "solo CPU opposes its player, one filler per side")
	solo.free()

	var demo := TestGame.new()
	var bots: Array = []
	for slot in range(1, 4):
		bots.append(_player(demo, slot, 0, true, "replay"))
	var filler := _player(demo, 4, 0, true, "bot")
	filler.filler = true
	demo._assign_teams(RSTeams.lineup(demo), 2)
	_check(bots.map(func(p: RSPartyGame.Player) -> int: return p.team) == [0, 1, 0] and filler.team == 1, "demo bots alternate like people")
	demo.free()

	# 1v1: left and right halves.
	var duel := TestGame.new()
	duel.mode = RSTeams.Mode.VERSUS
	var a := _player(duel, 3, 7)
	var b := _player(duel, 1, 9)
	duel._assign_teams(RSTeams.lineup(duel), 1)
	_check(b.team == 0 and a.team == 1 and _slots(duel._view_order()) == [1, 3], "1v1 sides and views")
	list = duel.ranked_players()
	_check(_slots(list) == [1, 3] and RSTeams.places(duel, list) == PackedInt32Array([1, 2]) and not RSTeams.grouped(duel), "1v1 lists players, not sides")
	duel.free()

	# Podium: explicit places put teammates on one step.
	var podium := RSPodium.new()
	add_child(podium)
	podium.configure([[0, 0.8], [-1.35, 0.55], [1.35, 0.36]], Vector2(1.3, 1.2), Vector3(2.4, 0, 0.6), 0.9, ThemeDB.fallback_font)
	podium.present(PackedInt64Array([550, 550, 400, 400]), PackedInt32Array([1, 1, 2, 2]))
	_check([podium.rank(0), podium.rank(1), podium.rank(2), podium.rank(3)] == [1, 1, 2, 2], "podium uses the side places")
	_check(is_equal_approx(podium.spot(1).y - podium.global_position.y, 0.8) and is_equal_approx(podium.spot(3).y - podium.global_position.y, 0.55)
		and podium._blocks[3].visible, "winners on gold, the other side on silver with the extra step")
	podium.present(PackedInt64Array([550, 550, 400, 400]))
	_check([podium.rank(2), podium.rank(3)] == [3, 3], "without places the podium keeps score ties (1, 1, 3)")
	podium.queue_free()

	# Tournament: same rank -> same points; slots outside the party (fillers) are ignored.
	RSTournament.games = ["plane", "archery", "bowling"]
	RSTournament.entrants = {1: {"name": "A", "points": 0}, 2: {"name": "B", "points": 0}, 3: {"name": "C", "points": 0}}
	RSTournament.index = 0
	RSTournament.round_done = false
	RSTournament.record("plane", [{"slot": 2, "rank": 1}, {"slot": 1, "rank": 2}, {"slot": 3, "rank": 2}, {"slot": 4, "rank": 1}])
	_check(RSTournament.entrants[2]["points"] == 10 and RSTournament.entrants[1]["points"] == 7 and RSTournament.entrants[3]["points"] == 7
		and not RSTournament.entrants.has(4), "team places give every member the same party points")
	RSTournament.clear()


func _round() -> void:
	## Three people in a 2v2: a filler joins at the countdown, sides rank, records and party points follow.
	RSRecords._loaded = true
	RSRecords._boards.clear()
	RSTournament.games = ["tests"]   # the test game's id (its folder); not in the catalog, so set directly
	RSTournament.entrants = {}
	for slot in range(1, 4):
		RSTournament.entrants[slot] = {"name": "P%d" % slot, "points": 0}
	RSTournament.index = 0
	RSTournament.round_done = false
	var game := TestGame.new()
	game.scores = {1: 300, 2: 500, 3: 100, 4: 50}
	add_child(game)
	await get_tree().process_frame
	_check(game.phase == RSPartyGame.Phase.LOBBY and game.game_id() == "tests", "test game in the lobby")
	var people: Array = []
	for slot in range(1, 4):
		var c := RSController.new()
		c.id = 30 + slot
		c.player = slot
		c.kind = "ble"
		c.connected = true
		people.append(game._add_player(c, false))
	game._tutorials.clear()   # no lesson for the test game
	await get_tree().process_frame
	_check(game.players.size() == 3 and game.ordered().all(func(p: RSPartyGame.Player) -> bool: return p.team == -1 and not p.filler), "no filler or sides in the lobby")
	for p: RSPartyGame.Player in people:
		game._set_ready(p, true)
	for _i in 30:
		await get_tree().process_frame
		if game.phase != RSPartyGame.Phase.LOBBY:
			break
	_check(game.players.size() == 4, "a filler completes the 2v2 at the countdown")
	var filler: RSPartyGame.Player = null
	for p: RSPartyGame.Player in game.players.values():
		if p.filler:
			filler = p
	_check(filler != null and filler.fake and filler.c.player == 4 and filler.c.id == RSTeams.FILLER_ID - 4
		and game.name_of(filler) == RSLang.t("电脑") and game.added.has([4, true]), "filler: free slot, computer name, _player_added")
	_check(filler != null and filler.cam != null and filler.cell != null, "filler has a view like any player")
	_check([people[0].team, people[1].team, people[2].team, filler.team] == [0, 1, 0, 1], "sides assigned")
	for _i in 120:
		await get_tree().process_frame
		if game.phase == RSPartyGame.Phase.RESULTS:
			break
	_check(game.phase == RSPartyGame.Phase.RESULTS, "round finished")
	var text: String = game.ui._results_text.text
	var blue := text.find(RSTeams.team_name(1))
	var red := text.find(RSTeams.team_name(0))
	_check(blue >= 0 and red > blue and text.contains("550") and text.contains("400") and text.contains(RSLang.t("电脑")), "results list sides, winners first")
	_check(RSTournament.entrants[2]["points"] == 10 and RSTournament.entrants[1]["points"] == 7 and RSTournament.entrants[3]["points"] == 7, "party points by side")
	_check(RSTournament.round_done and RSTournament.standings().size() == 3, "filler never enters the tournament")
	_check(RSRecords.best("tests", 0, 2) == 500 and RSRecords.best("tests", 0, 1) == 300 and RSRecords.best("tests", 0, 4) == -1, "people record, the filler does not")
	# Back to the lobby: the filler leaves, the sides are forgotten.
	game._to_lobby()
	_check(game.players.size() == 3 and game.removed == [4] and game.ordered().all(func(p: RSPartyGame.Player) -> bool: return p.team == -1), "lobby drops the filler and the sides")
	RSTournament.clear()
	# Release the round's music before shutdown, as test_party_flow does, so leaks still show.
	for audio: AudioStreamPlayer in game.find_children("*", "AudioStreamPlayer", true, false):
		audio.stop()
		audio.stream = null
	game.queue_free()
	var until := Time.get_ticks_msec() + 350
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
