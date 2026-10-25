extends Node
## Autoload "ControllerHub": UDP link to regina-hub (docs/protocol.md section 4).
##
## Usage:
##   ControllerHub.button_pressed.connect(func(c, b): ...)
##   var c := ControllerHub.get_player(1)
##   if c: $Racket.quaternion = c.orientation
##   ControllerHub.send_ui(c.id, {"title": "TENNIS", "legends": ["SERVE", "", "", "ZERO"]})

signal roster_changed
signal controller_connected(controller: RSController)
signal controller_disconnected(controller: RSController)
signal controller_event(controller: RSController, event_name: String)
signal button_pressed(controller: RSController, button: int)
signal button_released(controller: RSController, button: int)
## A held button whose release will never arrive because the controller
## disconnected: the hold must be *cancelled*, not completed, so this is a
## separate signal from button_released (#55).
signal button_cancelled(controller: RSController, button: int)
signal dial_changed(controller: RSController, small_delta: int, big_delta: int)
signal samples_received(controller: RSController, count: int)
signal qr_received(url: String, rows: PackedStringArray)

const LISTEN_PORT := 47800
const HUB_PORT := 47801
const HELLO_INTERVAL := 2.0
const HUB_TIMEOUT := 3.0

const MSG_SAMPLES := 0x53
const MSG_INPUT := 0x49
const SAMPLE_SIZE := 60

var controllers: Dictionary = {}   ## id -> RSController
var phone_url: String = ""
var qr_rows := PackedStringArray()

var _udp := PacketPeerUDP.new()
var _bound := false
var _port := 0
var _hub_port := 0
var _hello_timer := 0.0
var _last_rx_msec := -100000


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # menus pause the tree; hub input/OLED must keep flowing (#56)
	RSSettings.load_once()       # sets the interface language before the first scene's UI
	process_priority = -100  # update before game nodes read controller state
	# Bind before any scene parses arguments; see docs/ARCHITECTURE.md (test-mode ports).
	var ports := ports_for(OS.get_cmdline_user_args(), OS.get_environment("RS_TEST_MODE") == "1")  # allow: ARCH-ARGS
	if ports.x < 0:
		push_error("ControllerHub: --hub-port must be 2-65535")
		return
	var err := _udp.bind(ports.x, "127.0.0.1")
	_bound = err == OK
	if not _bound:
		push_error("ControllerHub: cannot bind UDP %d (another game instance running?)" % ports.x)
		return
	_port = _udp.get_local_port()
	_hub_port = ports.y
	if _hub_port > 0:
		_udp.set_dest_address("127.0.0.1", _hub_port)
	_send({"cmd": "hello"})


static func ports_for(args: PackedStringArray, test_mode: bool) -> Vector2i:
	## (listen, hub). Normal play: 47800 / 47801. Test mode: an OS-assigned port and no hub,
	## so parallel instances never collide or reach a real hub. --hub-port=N talks to a hub
	## on N and listens on N - 1 (regina_hub --hub-port N --game-port N-1). x < 0 = invalid.
	for a: String in args:
		if a.begins_with("--hub-port="):
			var value := a.trim_prefix("--hub-port=")
			var hub := int(value)
			return Vector2i(hub - 1, hub) if value.is_valid_int() and hub >= 2 and hub <= 65535 else Vector2i(-1, 0)
	return Vector2i(0, 0) if test_mode else Vector2i(LISTEN_PORT, HUB_PORT)


func _process(delta: float) -> void:
	if not _bound:
		return
	_hello_timer += delta
	if _hello_timer >= HELLO_INTERVAL:
		_hello_timer = 0.0
		_send({"cmd": "hello"})
	var budget := 2000
	while _udp.get_available_packet_count() > 0 and budget > 0:
		budget -= 1
		var pkt := _udp.get_packet()
		if pkt.is_empty():
			continue
		_last_rx_msec = Time.get_ticks_msec()
		var first := pkt.decode_u8(0)
		if first == MSG_SAMPLES:
			_handle_samples(pkt)
		elif first == MSG_INPUT:
			_handle_input(pkt)
		elif first == 0x7B:  # '{'
			_handle_json(pkt)


func _exit_tree() -> void:
	_udp.close()


# ------------------------------------------------------------------------ queries ----

func listen_port() -> int:
	## The bound local UDP port (0 = not bound). Tests send synthetic hub packets here.
	return _port


func is_hub_connected() -> bool:
	return Time.get_ticks_msec() - _last_rx_msec < int(HUB_TIMEOUT * 1000.0)


func get_controller(id: int) -> RSController:
	return controllers.get(id) as RSController


func get_player(player: int) -> RSController:
	for c: RSController in controllers.values():
		if c.connected and c.player == player:
			return c
	return null


func connected_controllers() -> Array[RSController]:
	var out: Array[RSController] = []
	for c: RSController in controllers.values():
		if c.connected:
			out.append(c)
	out.sort_custom(func(a: RSController, b: RSController) -> bool:
		var pa := a.player if a.player > 0 else 99
		var pb := b.player if b.player > 0 else 99
		return pa < pb if pa != pb else a.id < b.id)
	return out


# ----------------------------------------------------------------------- commands ----

func set_player(controller_id: int, player: int) -> void:
	_send({"cmd": "set_player", "controller": controller_id, "player": player})


func recenter(controller_id: int = 0) -> void:
	## 0 = all controllers.
	_send({"cmd": "recenter", "controller": controller_id})


func calibrate(controller_id: int = 0) -> void:
	_send({"cmd": "calibrate", "controller": controller_id})


func beep(controller_id: int, freq: int = 2000, ms: int = 80) -> void:
	_send({"cmd": "beep", "controller": controller_id, "freq": freq, "ms": ms})


## Vibrations by meaning, as [on, off, on, ...] ms, so every game feels the same for the
## same kind of moment. Phones scale them by the player's strength setting.
const HAPTICS := {
	"tap": [30],                          # throw, shoot, release
	"hit": [45],                          # a score, a gate, a landed trick
	"bump": [80],                         # a knock: net, rim
	"good": [40, 60, 70],                 # a fine score: spare, money ball, perfect ring
	"great": [60, 50, 60, 50, 150],       # the best: strike, bullseye
	"miss": [120],                        # a missed gate
	"crash": [250, 70, 90],               # crash, bail, splash
	"count": [25],                        # countdown 3-2-1
	"go": [180],                          # countdown GO
	"win": [80, 80, 80, 80, 300],         # first place
}


func vibrate(controller_id: int, ms: int = 60) -> void:
	_send({"cmd": "vibrate", "controller": controller_id, "ms": ms})


func vibrate_pattern(controller_id: int, pattern: Array) -> void:
	## [on, off, on, ...] ms; the hub clamps it to 16 steps and 3 s.
	_send({"cmd": "vibrate", "controller": controller_id, "pattern": pattern})


func haptic(controller_id: int, name: String) -> void:
	## One of HAPTICS.
	vibrate_pattern(controller_id, HAPTICS.get(name, [60]))


func send_ui(controller_id: int, ui: Dictionary) -> void:
	## Keys: clear (bool), title, main, sub (String), bar ({pct, label} or null),
	## legends ([A, B, C, D], null = unchanged), toast ({ms, text}). OLED shows ASCII only.
	_send({"cmd": "ui", "controller": controller_id, "ui": ui})
	var targets: Array = controllers.values() if controller_id == 0 else [controllers.get(controller_id)]
	for c in targets:
		if c != null:
			_merge_ui(c as RSController, ui)


func request_qr() -> void:
	_send({"cmd": "qr"})


# ----------------------------------------------------------------------- internals ----

func _send(msg: Dictionary) -> void:
	if _bound and _hub_port > 0:
		_udp.put_packet(JSON.stringify(msg).to_utf8_buffer())


func _ensure(id: int) -> RSController:
	var c := controllers.get(id) as RSController
	if c == null:
		c = RSController.new()
		c.id = id
		controllers[id] = c
	return c


func _handle_samples(pkt: PackedByteArray) -> void:
	if pkt.size() < 4 or pkt.decode_u8(1) != 1:
		return
	var c := _ensure(pkt.decode_u8(2))
	var n := pkt.decode_u8(3)
	if pkt.size() < 4 + n * SAMPLE_SIZE:
		return
	var off := 4
	for i in n:
		var t := pkt.decode_double(off)
		var q := Quaternion(pkt.decode_float(off + 8), pkt.decode_float(off + 12), pkt.decode_float(off + 16), pkt.decode_float(off + 20))
		var g := Vector3(pkt.decode_float(off + 24), pkt.decode_float(off + 28), pkt.decode_float(off + 32))
		var a := Vector3(pkt.decode_float(off + 36), pkt.decode_float(off + 40), pkt.decode_float(off + 44))
		var l := Vector3(pkt.decode_float(off + 48), pkt.decode_float(off + 52), pkt.decode_float(off + 56))
		c.push_sample(t, q.normalized(), g, a, l)
		off += SAMPLE_SIZE
	samples_received.emit(c, n)


func _handle_input(pkt: PackedByteArray) -> void:
	if pkt.size() < 16 or pkt.decode_u8(1) != 1:
		return
	var c := _ensure(pkt.decode_u8(2))
	var old := c.buttons
	var new_buttons := pkt.decode_u8(3)
	var small := pkt.decode_s16(4)
	var big := pkt.decode_s16(6)
	var ds := small - c.dial_small
	var db := big - c.dial_big
	c.buttons = new_buttons
	c.dial_small = small
	c.dial_big = big
	c.analog0 = pkt.decode_float(8)
	c.analog1 = pkt.decode_float(12)
	for bit in [RSController.BTN_A, RSController.BTN_B, RSController.BTN_C, RSController.BTN_D]:
		if (new_buttons & bit) and not (old & bit):
			button_pressed.emit(c, bit)
		elif not (new_buttons & bit) and (old & bit):
			button_released.emit(c, bit)
	if ds != 0 or db != 0:
		dial_changed.emit(c, ds, db)


func _handle_json(pkt: PackedByteArray) -> void:
	var msg = JSON.parse_string(pkt.get_string_from_utf8())
	if typeof(msg) != TYPE_DICTIONARY:
		return
	match str(msg.get("type", "")):
		"roster":
			_apply_roster(msg)
		"event":
			var c := _ensure(int(msg.get("controller", 0)))
			var ev := str(msg.get("name", ""))
			if ev == "connected":
				var was_connected := c.connected
				c.connected = true
				if not was_connected:
					controller_connected.emit(c)
			elif ev == "disconnected":
				c.connected = false
				_cancel_held_buttons(c)
				controller_disconnected.emit(c)
			controller_event.emit(c, ev)
		"qr":
			phone_url = str(msg.get("url", ""))
			qr_rows = PackedStringArray(msg.get("rows", []))
			qr_received.emit(phone_url, qr_rows)


func _cancel_held_buttons(c: RSController) -> void:
	## A button still held when the controller goes away never sends its own
	## release (and must not surface as a late release after reconnecting).
	## Report each held button as cancelled exactly once, then clear: the game
	## cancels the held action instead of completing it (#55). Idempotent --
	## clearing first makes repeats (event + roster) no-ops.
	var held := c.buttons
	c.buttons = 0
	for bit in [RSController.BTN_A, RSController.BTN_B, RSController.BTN_C, RSController.BTN_D]:
		if held & bit:
			button_cancelled.emit(c, bit)


func _apply_roster(msg: Dictionary) -> void:
	var url = msg.get("phone_url")
	if url != null and str(url) != phone_url:
		phone_url = str(url)
		if qr_rows.is_empty():
			request_qr()
	var present := {}
	for entry in msg.get("controllers", []):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var c := _ensure(int(entry.get("id", 0)))
		present[c.id] = true
		var was_connected := c.connected  # the event handler may already have emitted for this connection
		c.apply_roster(entry)
		if c.connected and not was_connected:
			controller_connected.emit(c)
		elif was_connected and not c.connected:
			# The roster alone reports it offline (the disconnected event was
			# lost or reordered): same cancellation as the event path, or a
			# held button would surface as a late release on reconnect (#55).
			_cancel_held_buttons(c)
			controller_disconnected.emit(c)
	# A controller that drops out of the roster is only marked disconnected,
	# never deleted: RSPartyGame keys player state to the RSController object,
	# and the same id coming back must get the same object (a mid-game dropout
	# keeps its score and slot). Hub-side id recycling bounds this dictionary
	# to at most 255 entries (#45).
	for id in controllers.keys():
		var c := controllers[id] as RSController
		if not present.has(id) and c.connected:
			c.connected = false
			_cancel_held_buttons(c)
			controller_disconnected.emit(c)
	roster_changed.emit()


func _merge_ui(c: RSController, ui: Dictionary) -> void:
	if ui.get("clear", false):
		c.ui_state = {}
	for key in ui.keys():
		if key == "clear":
			continue
		if key == "legends":
			var cur: Array = c.ui_state.get("legends", [null, null, null, null]).duplicate()
			var incoming: Array = ui[key]
			for i in mini(4, incoming.size()):
				if incoming[i] != null:
					cur[i] = incoming[i]
			c.ui_state["legends"] = cur
		elif key == "toast":
			c.ui_state["toast"] = ui[key]
			c.ui_state["toast_until"] = Time.get_ticks_msec() + int(ui[key].get("ms", 1000))
		else:
			c.ui_state[key] = ui[key]
