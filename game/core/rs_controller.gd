class_name RSController
extends RefCounted
## State of one controller as reported by regina-hub (see docs/protocol.md section 4).
##
## Orientation is body -> world in Godot axes: +Y up, -Z = where the controller pointed
## when it was last recentered. Assign it straight to a Node3D's `quaternion`.

const BTN_A := 1
const BTN_B := 2
const BTN_C := 4
const BTN_D := 8

const HISTORY := 512

# --- identity / status (from roster) ---------------------------------------------
var id: int = 0
var kind: String = ""          ## "regina", "phone", "sim" or "replay"
var display_name: String = ""
var player: int = 0            ## 0 = unassigned, 1..4
var connected: bool = false
var battery: int = -1          ## -1 = unknown
var charging: bool = false
var calibrated: bool = false
var calibrating: bool = false
var stationary: bool = false
var rate_hz: float = 0.0
var loss: float = 0.0
var info: Dictionary = {}      ## full roster entry, for extra fields (fw, mtu, ...)

# --- latest motion sample -------------------------------------------------------
var sample_time: float = 0.0   ## hub clock, seconds
var orientation: Quaternion = Quaternion.IDENTITY
var gyro: Vector3 = Vector3.ZERO           ## body frame, rad/s
var accel: Vector3 = Vector3.ZERO          ## body frame, m/s^2, incl. gravity
var lin_accel_world: Vector3 = Vector3.ZERO  ## world frame, m/s^2, gravity removed

# --- buttons / dials ------------------------------------------------------------
var buttons: int = 0
var dial_small: int = 0
var dial_big: int = 0
var analog0: float = 0.0
var analog1: float = 0.0

# --- history ring buffers (newest at _head - 1) -------------------------------------
var hist_time := PackedFloat64Array()
var hist_gyro := PackedVector3Array()
var hist_lin := PackedVector3Array()
var hist_quat: Array[Quaternion] = []
var _head: int = 0
var _count: int = 0

## Screen state last sent to this controller (mirrors the OLED; see ControllerHub.send_ui).
var ui_state: Dictionary = {}


func _init() -> void:
	hist_time.resize(HISTORY)
	hist_gyro.resize(HISTORY)
	hist_lin.resize(HISTORY)
	hist_quat.resize(HISTORY)
	hist_quat.fill(Quaternion.IDENTITY)


func is_pressed(button: int) -> bool:
	return (buttons & button) != 0


func forward() -> Vector3:
	## Direction the controller tip points, world frame.
	return orientation * Vector3.FORWARD


func up() -> Vector3:
	return orientation * Vector3.UP


func pitch() -> float:
	## Radians, + when the tip points up.
	return asin(clampf(forward().y, -1.0, 1.0))


func roll() -> float:
	## Radians around the tip axis, + when tilted to the right (right side down).
	var right := orientation * Vector3.RIGHT
	return -asin(clampf(right.y, -1.0, 1.0))


func yaw() -> float:
	## Radians around world up, + when turned to the left.
	var f := forward()
	return atan2(-f.x, -f.z)


func gyro_world() -> Vector3:
	return orientation * gyro


func left_handed() -> bool:
	return RSProfiles.left_handed(player)


func motion_pose(q: Quaternion) -> Quaternion:
	## Reflect both frames through X: M R M. Raw protocol samples stay untouched.
	return Quaternion(q.x, -q.y, -q.z, q.w) if left_handed() else q


func motion_orientation() -> Quaternion:
	return motion_pose(orientation)


func motion_gyro(g: Vector3) -> Vector3:
	## Angular velocity is axial: det(M) M g, rather than a polar position vector.
	return Vector3(g.x, -g.y, -g.z) if left_handed() else g


func motion_roll() -> float:
	return -roll() if left_handed() else roll()


func history_size() -> int:
	return _count


func history_index(age: int) -> int:
	## Ring index for the sample `age` steps back (0 = newest).
	return (_head - 1 - age + HISTORY * 2) % HISTORY


func push_sample(t: float, q: Quaternion, g: Vector3, a: Vector3, lin: Vector3) -> void:
	sample_time = t
	orientation = q
	gyro = g
	accel = a
	lin_accel_world = lin
	hist_time[_head] = t
	hist_gyro[_head] = g
	hist_lin[_head] = lin
	hist_quat[_head] = q
	_head = (_head + 1) % HISTORY
	_count = mini(_count + 1, HISTORY)


func apply_roster(entry: Dictionary) -> void:
	info = entry
	kind = str(entry.get("kind", ""))
	display_name = str(entry.get("name", ""))
	player = int(entry.get("player", 0))
	connected = bool(entry.get("connected", false))
	var b = entry.get("battery")
	battery = -1 if b == null else int(b)
	charging = bool(entry.get("charging", false))
	calibrated = bool(entry.get("calibrated", false))
	calibrating = bool(entry.get("calibrating", false))
	stationary = bool(entry.get("stationary", false))
	rate_hz = float(entry.get("rate_hz", 0.0))
	loss = float(entry.get("loss", 0.0))
