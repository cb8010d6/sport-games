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

	await get_tree().create_timer(HOLD_SEC).timeout
	print("RS_HUB_PORT_TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)
