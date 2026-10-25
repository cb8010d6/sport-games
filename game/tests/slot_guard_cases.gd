extends RefCounted
## Slot restoration uses the game clock and no live hub or player scene.

class GuardViews extends RSPartyViews:
	var removed := 0

	func add(_p: RSPartyGame.Player) -> void:
		pass

	func remove(_p: RSPartyGame.Player) -> void:
		removed += 1


class GuardGame extends RSPartyGame:
	var pins: Array = []

	func _pin_slot(p: Player) -> void:
		pins.append([p.c.id, p.slot])

	func _oled_lobby(_p: Player) -> void:
		pass


static func run(check: Callable) -> void:
	var saved_controllers := ControllerHub.controllers.duplicate()
	ControllerHub.controllers.clear()
	var game := GuardGame.new()
	var views := GuardViews.new(game)
	game.views = views
	game.add_child(views)
	var c := RSController.new()
	c.id = 5702
	c.player = 2
	c.connected = true
	c.kind = "replay"  # skip lobby tutorials in this scene-free fixture
	ControllerHub.controllers[c.id] = c
	var p := game._add_player(c, false)
	p.score = 57
	check.call(p.slot == 2, "slot guard remembers the joined player number")
	game.phase = RSPartyGame.Phase.PLAY
	c.player = 3
	game._guard_slots()
	check.call(game.pins == [[c.id, 2]], "slot guard requests the original slot immediately")
	check.call(game.players[c.id] == p and p.score == 57 and views.removed == 0,
		"PLAY slot guard preserves the player, score and view")
	game._guard_slots()
	game._clock = RSPartyGame.SLOT_PIN_INTERVAL - 0.01
	game._guard_slots()
	check.call(game.pins.size() == 1, "slot guard limits repeated requests within one second")
	game._clock = RSPartyGame.SLOT_PIN_INTERVAL + 0.01
	game._guard_slots()
	check.call(game.pins.size() == 2, "slot guard retries after the interval")
	c.player = 2
	game._clock += RSPartyGame.SLOT_PIN_INTERVAL + 0.01
	game._guard_slots()
	check.call(game.pins.size() == 2, "slot guard stops once the roster restores the slot")
	var bot := RSController.new()
	bot.id = 5703
	bot.player = 4
	var fake := game._add_player(bot, true)
	bot.player = 1
	game._guard_slots()
	check.call(game.pins.size() == 2, "slot guard skips fake players")
	c.player = 3
	game._guard_slots()
	fake.fake = false
	game._guard_slots()
	check.call(game.pins.size() == 4 and game.pins[-1] == [bot.id, 4],
		"slot guard applies the request interval independently to each player")
	fake.fake = true
	for guarded_phase in [RSPartyGame.Phase.COUNTDOWN, RSPartyGame.Phase.RESULTS]:
		game.phase = guarded_phase
		game._clock += RSPartyGame.SLOT_PIN_INTERVAL + 0.01
		var before := game.pins.size()
		game._guard_slots()
		check.call(game.pins.size() == before + 1 and game.players[c.id] == p,
			"slot guard also preserves the player during countdown and results")
	game.phase = RSPartyGame.Phase.LOBBY
	game._clock += RSPartyGame.SLOT_PIN_INTERVAL + 0.01
	var before_lobby := game.pins.size()
	game._guard_slots()
	check.call(game.pins.size() == before_lobby, "lobby slot changes do not request a pin")
	game._sync_players()
	check.call(not game.players.has(c.id) and views.removed == 1,
		"lobby slot change removes the old player before rejoining")
	game._sync_players()
	var rejoined: RSPartyGame.Player = game.players[c.id]
	check.call(rejoined != p and rejoined.slot == 3 and not rejoined.ready and rejoined.score == 0,
		"next lobby frame joins a fresh player under the new slot")
	game.free()
	ControllerHub.controllers.clear()
	ControllerHub.controllers.merge(saved_controllers)
