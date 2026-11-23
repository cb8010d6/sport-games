extends RefCounted
## Pure G2 table cases; scene integration and disposable storage checks stay in test_golf.gd.

const EMPTY: Array[RSGolfRules.Event] = []
const PARS := [4, 3, 5]


static func run(check: Callable) -> void:
	var rules := fresh()
	check.call(rules.score() == 0 and rules.summary()["holes"][0]["points"] == 0, "unfinished holes have zero points")
	check.call(not rules.start_hole(0) and not rules.start_hole(2), "cannot restart or skip holes")
	check.call(rules.try_stroke(rules.command_key(0, 0)) == null, "nonpositive command rejected")
	check.call(rules.try_stroke(rules.command_key(1, 1)) == null, "future command tick rejected")
	var command := rules.command_key(5, 0)
	var shot := rules.try_stroke(command)
	check.call(shot != null and rules.stroke_count() == 1 and rules.score() == 0, "accepted shot adds exactly one stroke")
	check.call(rules.try_stroke(command) == null, "duplicate active command rejected")
	var blocked := rules.command_key(6, rules.tick)
	check.call(rules.try_stroke(blocked) == null, "new release blocked during flight")
	contact(rules, shot, RSGolfRules.Outcome.REST)
	check.call(rules.ready() and rules.try_stroke(command) == null, "duplicate settled command rejected")
	check.call(rules.try_stroke(rules.command_key(blocked.seq, rules.tick)) == null, "flight-blocked sequence remains consumed even with current tick")
	check.call(rules.try_stroke(rules.command_key(4, rules.tick)) == null, "out of order command rejected")
	penalties(check)
	isolation(check)
	caps(check)
	deadlines(check)
	summaries(check)


static func fresh(slot := 1) -> RSGolfRules:
	var rules := RSGolfRules.new()
	rules.reset_round(PackedInt32Array(PARS), slot)
	assert(rules.start_hole(0))
	return rules


static func advance(rules: RSGolfRules, until: int) -> void:
	while rules.tick < until and not rules.finished():
		rules.resolve_tick(rules.tick + 1, EMPTY)


static func contact(rules: RSGolfRules, shot: RSGolfRules.StrokeKey, kind: RSGolfRules.Outcome) -> void:
	var events: Array[RSGolfRules.Event] = [RSGolfRules.Event.new(shot, kind, rules.tick + 1)]
	rules.resolve_tick(rules.tick + 1, events)


static func play(rules: RSGolfRules, seq: int, kind: RSGolfRules.Outcome) -> RSGolfRules.StrokeKey:
	var shot := rules.try_stroke(rules.command_key(seq, rules.tick))
	assert(shot != null)
	contact(rules, shot, kind)
	return shot


static func penalties(check: Callable) -> void:
	for kind: RSGolfRules.Outcome in [RSGolfRules.Outcome.WATER, RSGolfRules.Outcome.OB]:
		var rules := fresh()
		var shot := rules.try_stroke(rules.command_key(1, 0))
		var event := RSGolfRules.Event.new(shot, kind, 1)
		var events: Array[RSGolfRules.Event] = [event, event]
		check.call(rules.resolve_tick(1, events), "hazard event accepted")
		check.call(rules.stroke_count() == 2 and rules.summary()["holes"][0]["penalties"] == 1, "duplicate hazard adds one penalty")
		var expected := RSGolfRules.Recovery.WATER_BACKTRACK if kind == RSGolfRules.Outcome.WATER else RSGolfRules.Recovery.PREVIOUS_SHOT
		check.call(rules.recovery == expected and not rules.ready(), "abstract drop policy blocks another shot")
		check.call(not rules.resolve_tick(1, events) and not rules.resolve_tick(2, events), "duplicate tick and old contact do not penalize twice")
		var foreign := RSGolfRules.StrokeKey.new(2, shot.epoch, shot.hole, shot.seq, shot.tick)
		check.call(not rules.complete_drop(foreign), "foreign player drop rejected")
		check.call(rules.complete_drop(shot) and not rules.complete_drop(shot), "drop acknowledgment is idempotent")
		var next := play(rules, 2, kind)
		check.call(not rules.complete_drop(shot) and not rules.ready(), "old shot cannot acknowledge new recovery")
		var old_command := rules.command_key(3, rules.tick)
		rules.reset_round(PackedInt32Array(PARS), 1)
		rules.start_hole(0)
		var current := play(rules, 1, kind)
		check.call(not rules.complete_drop(next) and rules.try_stroke(old_command) == null, "old round tokens rejected")
		advance(rules, RSGolfRules.HOLE_TICKS)
		check.call(not rules.complete_drop(current) and rules.finished(), "drop cannot reopen timeout")
		rules.start_hole(1)
		play(rules, 1, kind)
		check.call(not rules.complete_drop(current) and not rules.ready(), "old hole drop cannot reopen new hole")
	var rules := fresh()
	var shot := rules.try_stroke(rules.command_key(1, 0))
	var events: Array[RSGolfRules.Event] = [RSGolfRules.Event.new(shot, RSGolfRules.Outcome.WATER, 1), RSGolfRules.Event.new(shot, RSGolfRules.Outcome.HOLED, 1)]
	rules.resolve_tick(1, events)
	check.call(rules.finished() and rules.score() == 5, "equal-order cup precedes hazard")
	rules = fresh()
	shot = rules.try_stroke(rules.command_key(1, 0))
	events = [RSGolfRules.Event.new(shot, RSGolfRules.Outcome.HOLED, 1, 1), RSGolfRules.Event.new(shot, RSGolfRules.Outcome.WATER, 1, 0)]
	rules.resolve_tick(1, events)
	check.call(not rules.finished() and rules.recovery == RSGolfRules.Recovery.WATER_BACKTRACK, "earlier contact precedes kind priority")


static func isolation(check: Callable) -> void:
	var first := fresh()
	var second := fresh()  # Same slot and all numeric fields, still a distinct ledger.
	var a := first.try_stroke(first.command_key(1, 0))
	var b := second.try_stroke(second.command_key(1, 0))
	var before := second.summary()
	var events: Array[RSGolfRules.Event] = [RSGolfRules.Event.new(a, RSGolfRules.Outcome.WATER, 1)]
	second.resolve_tick(1, events)
	check.call(second.summary() == before, "foreign ledger event rejected despite identical numeric keys")
	contact(second, b, RSGolfRules.Outcome.WATER)
	check.call(not second.complete_drop(a), "foreign ledger cannot confirm recovery")
	check.call(second.try_stroke(first.command_key(99, second.tick)) == null, "foreign command does not poison sequence")
	var blocked := second.command_key(2, second.tick)
	check.call(second.try_stroke(blocked) == null, "release blocked during drop")
	check.call(second.complete_drop(b) and second.try_stroke(blocked) == null, "blocked release stays consumed after drop completion")
	check.call(second.try_stroke(second.command_key(3, second.tick)) != null, "fresh release required after recovery")


static func caps(check: Callable) -> void:
	for par: int in [3, 4, 5]:
		for kind: RSGolfRules.Outcome in [RSGolfRules.Outcome.HOLED, RSGolfRules.Outcome.REST, RSGolfRules.Outcome.WATER]:
			var rules := RSGolfRules.new()
			rules.reset_round(PackedInt32Array([par, par, par]), 1)
			rules.start_hole(0)
			for seq in range(1, par + 4):
				play(rules, seq, RSGolfRules.Outcome.REST)
			var key := play(rules, par + 4, kind)
			var row: Dictionary = rules.summary()["holes"][0]
			check.call(row["strokes"] == par + 4 and row["points"] == 0, "last allowed stroke stays bounded")
			check.call(row["status"] == (RSGolfRules.Status.HOLED if kind == RSGolfRules.Outcome.HOLED else RSGolfRules.Status.CAPPED), "last shot can hole before pickup")
			check.call(not rules.complete_drop(key) and rules.try_stroke(rules.command_key(par + 5, rules.tick)) == null, "terminal state cannot reopen")
			var snapshot := rules.summary()
			check.call(not rules.resolve_tick(rules.tick + 1, EMPTY) and rules.summary() == snapshot, "terminal settlement occurs once")
	var rules := fresh()
	for seq in range(1, 7):
		play(rules, seq, RSGolfRules.Outcome.REST)
	play(rules, 7, RSGolfRules.Outcome.OB)
	check.call(rules.stroke_count() == 8 and rules.recovery == RSGolfRules.Recovery.NONE and rules.summary()["holes"][0]["reason"] == "penalty_limit", "seventh stroke OB reaches par4 cap without drop")


static func deadlines(check: Callable) -> void:
	var rules := fresh()
	advance(rules, RSGolfRules.HOLE_TICKS - 1)
	var command := rules.command_key(1, rules.tick)
	check.call(rules.try_stroke(command) != null and rules.stroke_count() == 1, "new shot allowed at last completed tick17999")
	rules.resolve_tick(RSGolfRules.HOLE_TICKS, EMPTY)
	check.call(rules.finished() and rules.try_stroke(rules.command_key(2, 18000)) == null, "new shot denied at tick18000")
	for event_tick: int in [17999, 18000, 18001]:
		rules = fresh()
		var shot := rules.try_stroke(rules.command_key(1, 0))
		advance(rules, event_tick - 1 if event_tick < 18000 else 17999)
		var events: Array[RSGolfRules.Event] = [RSGolfRules.Event.new(shot, RSGolfRules.Outcome.HOLED, event_tick)]
		rules.resolve_tick(event_tick if event_tick < 18000 else 18000, events)
		check.call(rules.summary()["holes"][0]["status"] == (RSGolfRules.Status.HOLED if event_tick <= 18000 else RSGolfRules.Status.CAPPED), "contacts before/at/after deadline")
		check.call(rules.score() == (5 if event_tick <= 18000 else 0), "deadline Stableford points")
	rules = fresh()
	var shot := rules.try_stroke(rules.command_key(1, 0))
	advance(rules, 17999)
	var events: Array[RSGolfRules.Event] = [RSGolfRules.Event.new(shot, RSGolfRules.Outcome.WATER, 18000)]
	rules.resolve_tick(18000, events)
	check.call(rules.summary()["holes"][0]["penalties"] == 1 and rules.recovery == RSGolfRules.Recovery.NONE and rules.finished(), "deadline applies penalty before timeout and cancels recovery")


static func summaries(check: Callable) -> void:
	var results: Array[Dictionary] = []
	for strokes: Array in [[4, 3, 5], [3, 2, 9]]:
		var rules := fresh()
		for index in 3:
			if index > 0:
				rules.start_hole(index)
			for seq in range(1, strokes[index]):
				play(rules, seq, RSGolfRules.Outcome.REST)
			play(rules, strokes[index], RSGolfRules.Outcome.HOLED if strokes[index] < PARS[index] + 4 else RSGolfRules.Outcome.REST)
		results.append(rules.summary())
		var snapshot := rules.summary()
		snapshot["holes"][0]["points"] = 999
		check.call(rules.score() == 6, "snapshot cannot mutate ledger")
	check.call(results[0]["score"] == 6 and results[1]["score"] == 6 and results[0]["strokes"] == 12 and results[1]["strokes"] == 14, "Stableford tie preserves different stroke details")
	check.call(results[0]["relative"] == 0 and results[1]["relative"] == 2 and results[1]["capped"] == 1, "relative par and pickup detail")
	var game := RSPartyGame.new()
	for i in 3:
		var player := RSPartyGame.Player.new()
		player.c = RSController.new()
		player.c.player = i + 1
		player.score = 6 if i < 2 else 3
		game.players[i] = player
	var ranked := game.ranked_players()
	check.call(ranked[0].c.player == 1 and ranked[1].c.player == 2 and ranked[0].score == ranked[1].score and ranked[2].score == 3, "public ranking keeps equal points together")
	game.free()
