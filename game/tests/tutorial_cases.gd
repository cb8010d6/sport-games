extends RefCounted


class PracticeGame extends RSPartyGame:
	func game_id() -> String:
		return "plane"


static func _controller() -> RSController:
	var c := RSController.new()
	c.connected = true
	c.kind = "phone"
	return c


static func _sample(c: RSController, q: Quaternion = Quaternion.IDENTITY, gyro: Vector3 = Vector3.ZERO, up: float = 0.0) -> void:
	c.push_sample(c.sample_time + 0.02, q, gyro, Vector3.UP * 9.8, Vector3.UP * up)


static func _button(lesson: RSTutorial, c: RSController, button: int, down: bool) -> void:
	c.buttons = (c.buttons | button) if down else (c.buttons & ~button)
	lesson.on_button(c, button, down)


static func _demo(lesson: RSTutorial, c: RSController) -> void:
	lesson.update(c, RSTutorial.DEMO_SECONDS + 0.01)


static func _right(lesson: RSTutorial, c: RSController) -> void:
	_demo(lesson, c)
	_sample(c, Quaternion(Vector3.FORWARD, 0.5))
	lesson.update(c, 0.31)


static func _throw(lesson: RSTutorial, c: RSController) -> void:
	_demo(lesson, c)
	_button(lesson, c, RSController.BTN_B, true)
	_sample(c, Quaternion.IDENTITY, Vector3(6, 0, 0))
	lesson.update(c, 0.2)
	_button(lesson, c, RSController.BTN_B, false)


static func run(check: Callable) -> void:
	for entry: Dictionary in RSCatalog.games():
		var steps := RSTutorial.step_list(RSCatalog.lessons(entry["id"]))
		check.call(not steps.is_empty() and steps.size() == RSCatalog.lessons(entry["id"]).size(), "catalog game has tutorial: " + entry["id"])
	var c := _controller()
	var lesson := RSTutorial.new("plane")
	_button(lesson, c, RSController.BTN_A, true)
	_button(lesson, c, RSController.BTN_A, false)
	_sample(c, Quaternion(Vector3.FORWARD, 0.5))
	lesson.update(c, 0.5)
	check.call(lesson.index == 0 and not lesson.practicing, "practice cannot skip demonstration")
	_demo(lesson, c)
	lesson.update(c, 0.5)
	check.call(lesson.index == 0, "stale pose does not count as fresh practice")
	_sample(c, Quaternion(Vector3.FORWARD, -0.5))
	lesson.update(c, 0.31)
	check.call(lesson.index == 0, "wrong tilt does not complete lesson")
	_sample(c, Quaternion(Vector3.FORWARD, 0.5))
	lesson.update(c, 0.31)
	check.call(lesson.index == 1, "right tilt completes first step")
	_demo(lesson, c)
	_sample(c, Quaternion(Vector3.RIGHT, -0.5))
	lesson.update(c, 0.31)
	check.call(lesson.index == 2, "forward tilt completes second step")
	_demo(lesson, c)
	_button(lesson, c, RSController.BTN_B, true)
	c.connected = false
	lesson.update(c, 2.0)
	check.call(not lesson.finished, "disconnect cannot finish a held-button step")
	c.connected = true
	_button(lesson, c, RSController.BTN_B, true)
	lesson.update(c, 0.51)
	check.call(lesson.finished, "plane tutorial finishes after real input")
	c = _controller()
	lesson = RSTutorial.new("archery")
	lesson.start(c)
	_demo(lesson, c)
	_sample(c, Quaternion(Vector3.UP, 0.3))
	lesson.update(c, 0.31)
	_demo(lesson, c)
	_button(lesson, c, RSController.BTN_A, true)
	lesson.update(c, 0.2)
	_button(lesson, c, RSController.BTN_A, false)
	check.call(not lesson.finished, "short draw is rejected")
	_button(lesson, c, RSController.BTN_A, true)
	c.buttons = 0 # release while paused: the game did not receive the release callback
	lesson.update(c, 1.1)
	_button(lesson, c, RSController.BTN_A, false)
	check.call(not lesson.finished, "lost release cannot count as a draw")
	_button(lesson, c, RSController.BTN_A, true)
	lesson.update(c, 1.05)
	_button(lesson, c, RSController.BTN_A, false)
	check.call(lesson.finished, "archery draw and release")
	c = _controller()
	lesson = RSTutorial.new("bowling")
	lesson.start(c)
	_right(lesson, c)
	_demo(lesson, c)
	_button(lesson, c, RSController.BTN_B, true)
	lesson.update(c, 0.2)
	_button(lesson, c, RSController.BTN_B, false)
	check.call(not lesson.finished, "release without swing is rejected")
	_throw(lesson, c)
	check.call(lesson.finished, "bowling hold, swing and release")
	for game_id: String in ["skate", "ski"]:
		c = _controller()
		lesson = RSTutorial.new(game_id)
		lesson.start(c)
		_right(lesson, c)
		if game_id == "ski":
			_demo(lesson, c)
			_sample(c, Quaternion(Vector3.RIGHT, -0.5))
			lesson.update(c, 0.31)
		_demo(lesson, c)
		var before: int = lesson.index
		_sample(c, Quaternion.IDENTITY, Vector3(0, 6, 0))
		lesson.update(c, 0.02)
		check.call(lesson.index == before, game_id + " sideways motion is not an upward flick")
		_sample(c, Quaternion.IDENTITY, Vector3(6, 0, 0))
		lesson.update(c, 0.02)
		check.call(lesson.index == before + 1, game_id + " upward flick")
		_demo(lesson, c)
		_button(lesson, c, RSController.BTN_B, true)
		lesson.update(c, 0.51)
		check.call(lesson.finished, game_id + " tutorial complete")
	c = _controller()
	lesson = RSTutorial.new("basketball")
	lesson.start(c)
	_demo(lesson, c)
	_sample(c, Quaternion(Vector3.UP, 0.3))
	lesson.update(c, 0.31)
	_throw(lesson, c)
	check.call(lesson.finished, "basketball aim and shot")
	lesson = RSTutorial.new("plane")
	lesson.start(c)
	_demo(lesson, c)
	c.sample_time = -2.0
	lesson.update(c, 0.01)
	check.call(not lesson.practicing and lesson.index == 0, "hub clock restart repeats the current demonstration")
	check.call(RSProfiles.complete_tutorial(3, "plane") == OK, "save tutorial completion")
	RSProfiles._loaded = false
	check.call(RSProfiles.tutorial_done(3, "plane") and not RSProfiles.tutorial_done(3, "archery"), "tutorial completion persists per game")
	check.call(not RSProfiles.tutorial_done(4, "plane"), "tutorial completion isolated per profile")


static func integration(host: Node, check: Callable) -> void:
	var game := PracticeGame.new()
	host.add_child(game)
	game.set_process(false)
	var c := _controller()
	c.id = 911
	c.player = 4
	var player: RSPartyGame.Player = game._add_player(c, false)
	game._set_ready(player, true)
	check.call(not player.ready, "first-time player cannot ready before tutorial")
	game._on_button(c, RSController.BTN_A, true)
	game.ui.update_lobby()
	check.call(game.tutorials_active() and game.ui._tutorial_panel.visible, "A opens real lobby tutorial panel")
	for slot in range(1, 4):
		var other := _controller()
		other.id = 911 + slot
		other.player = slot
		game._add_player(other, false)
	game.review_tutorials()
	game.ui.update_lobby()
	check.call(game.ui._tutorial_grid.get_child_count() == 4 and game.ui._tutorial_grid.columns == 2, "four-player tutorial cards")
	var lesson := game.tutorial_for(player)
	_right(lesson, c)
	_demo(lesson, c)
	_sample(c, Quaternion(Vector3.RIGHT, -0.5))
	lesson.update(c, 0.31)
	_demo(lesson, c)
	_button(lesson, c, RSController.BTN_B, true)
	lesson.update(c, 0.51)
	game._update_tutorials(0.0)
	check.call(game.tutorial_for(player) == null and RSProfiles.tutorial_done(4, "plane"), "party frame persists completed practice")
	game._on_button(c, RSController.BTN_A, true)
	check.call(player.ready, "completed player can ready")
	game.open_pause()
	game.ui.pause._choose((RSPauseMenu.PAGES["main"] as Array).find("tutorial"))
	check.call(not host.get_tree().paused and not player.ready and game.tutorial_for(player) != null, "pause menu replay resets ready state")
	check.call(RSProfiles.tutorial_done(4, "plane"), "replay does not erase saved completion")
	var disconnected: RSPartyGame.Player = game.players[912]
	disconnected.c.connected = false
	game._sync_players()
	check.call(not game._tutorials.has(912) and not game.players.has(912), "disconnect removes stale lobby lesson")
	game.queue_free()
	await host.get_tree().process_frame
