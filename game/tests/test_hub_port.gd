extends Node
## ControllerHub port selection. tools/test_hub_port.py runs this scene in several
## instances at once; each stays alive long enough for the others to overlap it.

const HOLD_SEC := 2.0
var _failures := 0
var _checks := 0
var _peer := PacketPeerUDP.new()


func _ready() -> void:
	if OS.get_environment("RS_TEST_MODE") != "1":
		get_tree().quit(1)
		return
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("FAIL: " + message)


func _run() -> void:
	var normal := ControllerHub.ports_for(PackedStringArray(), false)
	_check(normal == Vector2i(ControllerHub.LISTEN_PORT, ControllerHub.HUB_PORT), "normal play keeps 47800 / 47801")
	_check(ControllerHub.ports_for(PackedStringArray(), true) == Vector2i(0, 0), "test mode asks for an OS port and no hub")
	_check(ControllerHub.ports_for(PackedStringArray(["--demo=2", "--hub-port=47811"]), true) == Vector2i(47810, 47811), "--hub-port pairs N - 1 / N")
	_check(ControllerHub.ports_for(PackedStringArray(["--hub-port=47811"]), false) == Vector2i(47810, 47811), "--hub-port also applies outside test mode")
	for bad in ["--hub-port=", "--hub-port=1", "--hub-port=65536", "--hub-port=x"]:
		_check(ControllerHub.ports_for(PackedStringArray([bad]), true).x < 0, "rejects " + bad)

	var port := ControllerHub.listen_port()
	var expected := ControllerHub.ports_for(OS.get_cmdline_user_args(), true).x
	_check(port > 0, "test instance is bound")
	_check(port == expected if expected > 0 else port != ControllerHub.LISTEN_PORT, "bound to the selected port")
	print("RS_HUB_PORT: %d" % port)

	# The bound port still receives synthetic hub packets, as the UDP tests rely on.
	_peer.set_dest_address("127.0.0.1", port)
	var roster := {"type": "roster", "controllers": [{"id": 91, "player": 1, "kind": "sim", "name": "Port", "connected": true}]}
	_peer.put_packet(JSON.stringify(roster).to_utf8_buffer())
	for _i in 10:
		await get_tree().process_frame
	_check(ControllerHub.is_hub_connected(), "loopback packet reached ControllerHub")
	_check(ControllerHub.get_controller(91) != null, "roster applied")
	await _test_ble_diagnostics()

	await get_tree().create_timer(HOLD_SEC).timeout
	print("RS_HUB_PORT_TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)


func _send_roster(state: String) -> void:
	var roster := {"type": "roster", "controllers": []}
	if not state.is_empty():
		roster["ble_state"] = state
	_peer.put_packet(JSON.stringify(roster).to_utf8_buffer())
	for _i in 10:
		await get_tree().process_frame


func _has_label(node: Node, text: String) -> bool:
	if node is Label and node.text == text:
		return true
	for child: Node in node.get_children():
		if _has_label(child, text):
			return true
	return false


func _check_ble_views(menu: Variant, pages: RSMenuPages, lobby: RSPartyUi, warning: String, context: String) -> void:
	menu._status_text()
	pages._refresh_devices()
	lobby.update_lobby()
	_check(ControllerHub.ble_warning() == warning, context + " query")
	if not warning.is_empty():
		_check(menu._status.text == warning, context + " main-menu hint")
		_check(_has_label(pages._device_rows, warning), context + " controller-page hint")
		_check(lobby._lobby_players.text.contains(warning), context + " lobby hint")
	else:
		for text: String in [tr("蓝牙未发现广播，请尝试关闭再打开电脑蓝牙。"), tr("蓝牙不可用，请检查适配器；手机手柄仍可使用。")]:
			_check(menu._status.text != text, context + " clears main-menu hint")
			_check(not _has_label(pages._device_rows, text), context + " clears controller-page hint")
			_check(not lobby._lobby_players.text.contains(text), context + " clears lobby hint")


func _test_ble_diagnostics() -> void:
	# Exercise the actual UI methods without starting a sport or the menu's 3D backdrop.
	var menu: Variant = load("res://scenes/menu/main_menu.gd").new()
	menu._status = Label.new()
	menu.add_child(menu._status)
	var pages := RSMenuPages.new()
	add_child(pages)
	pages.open("players")
	var game := RSPartyGame.new()
	var lobby := RSPartyUi.new(game)
	add_child(lobby)
	var original_locale := TranslationServer.get_locale()
	for language in 2:
		RSLang.apply(language)
		for state: String in ["no_adverts", "scanning", "unavailable", "connected", "disabled", "unexpected", ""]:
			await _send_roster(state)
			var warning := ""
			if state == "no_adverts":
				warning = tr("蓝牙未发现广播，请尝试关闭再打开电脑蓝牙。")
			elif state == "unavailable":
				warning = tr("蓝牙不可用，请检查适配器；手机手柄仍可使用。")
			_check_ble_views(menu, pages, lobby, warning, "%s/%s" % [language, state])
			_check(ControllerHub.get_controller(91).connected, "diagnostics preserve the existing controller")
		await _send_roster("unavailable")
		var warning := ControllerHub.ble_warning()
		_check(not warning.is_empty(), "fresh unavailable state is visible")
		# Real elapsed time verifies expiration, rather than changing the autoload's private clock.
		await get_tree().create_timer(ControllerHub.HUB_TIMEOUT + 0.1).timeout
		_check(not ControllerHub.is_hub_connected(), "hub heartbeat expires")
		_check_ble_views(menu, pages, lobby, "", "expired hub")
		# A non-roster packet makes the hub live again but must not revive its expired diagnosis.
		_peer.put_packet(JSON.stringify({"type": "qr", "url": "", "rows": []}).to_utf8_buffer())
		for _i in 10:
			await get_tree().process_frame
		_check(ControllerHub.is_hub_connected(), "non-roster traffic restores hub heartbeat")
		_check_ble_views(menu, pages, lobby, "", "expired roster with live hub")
	TranslationServer.set_locale(original_locale)
	lobby.free()
	game.free()
	pages.free()
	menu.free()
