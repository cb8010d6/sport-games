class_name RSTutorial
extends RefCounted
## One player's lobby lesson: demonstrate, then require fresh motion/button practice.
## No game state changes and no fabricated controller samples. The party frame saves completion.

const DEMO_SECONDS := 2.4
const TILT_RIGHT := {"kind": "right", "text": "向右倾斜手柄，并保持片刻"}
const TILT_FORWARD := {"kind": "forward", "text": "向前压手柄，并保持片刻"}
const AIM := {"kind": "aim", "text": "轻轻转动手柄，练习瞄准"}
const BOOST := {"kind": "hold_b", "text": "按住 B，练习加速"}
const DRAW := {"kind": "draw", "text": "按住 A 拉弓一秒，再松开"}
const THROW := {"kind": "throw", "text": "按住 B 挥动手柄，再松开出手"}
const JUMP := {"kind": "jump", "text": "快速向上抬手柄，练习起跳"}
const GRAB := {"kind": "hold_b", "text": "按住 B，练习空中抓板"}
const LESSONS := {
	"plane": [TILT_RIGHT, TILT_FORWARD, BOOST],
	"archery": [AIM, DRAW],
	"bowling": [TILT_RIGHT, THROW],
	"skate": [TILT_RIGHT, JUMP, GRAB],
	"ski": [TILT_RIGHT, TILT_FORWARD, JUMP, GRAB],
	"basketball": [AIM, THROW],
}

var steps: Array = []
var index := 0
var started := false
var practicing := false
var finished := false
var elapsed := 0.0
var _neutral := Quaternion.IDENTITY
var _stick := RSTiltStick.new()
var _hold := 0.0
var _held := false
var _held_for := 0.0
var _peak := 0.0
var _sample_at_start := 0.0
var _last_sample := -1.0
var _stale := 0.0


func _init(game_id: String) -> void:
	steps = LESSONS.get(game_id, []).duplicate()
	finished = steps.is_empty()


func start(c: RSController) -> void:
	if started or finished:
		return
	started = true
	_neutral = c.orientation
	_stick.capture(_neutral)
	_begin_step(c)


func _begin_step(c: RSController) -> void:
	elapsed = 0.0
	practicing = false
	_hold = 0.0
	_held = false
	_held_for = 0.0
	_peak = 0.0
	_sample_at_start = c.sample_time
	_last_sample = c.sample_time
	_stale = 0.0


func instruction() -> String:
	return RSLang.t(steps[index]["text"]) if not finished else RSLang.t("教学完成，回到舒适握姿后按 A 准备")


func status() -> String:
	if finished:
		return RSLang.t("教学完成，回到舒适握姿后按 A 准备")
	if not started:
		return RSLang.t("按 A 开始教学")
	return (RSLang.t("练习 %d/%d：%s") if practicing else RSLang.t("示范 %d/%d：%s")) % [index + 1, steps.size(), instruction()]


func update(c: RSController, delta: float) -> void:
	if not started or finished:
		return
	if not c.connected:
		_hold = 0.0
		_held = false
		_held_for = 0.0
		return
	if c.sample_time < _last_sample:
		_neutral = c.orientation
		_stick.capture(_neutral)
		_begin_step(c)
		return
	elapsed += delta
	if not practicing:
		if elapsed >= DEMO_SECONDS:
			practicing = true
			_sample_at_start = c.sample_time
			_last_sample = c.sample_time
		return
	if c.sample_time != _last_sample:
		_last_sample = c.sample_time
		_stale = 0.0
	else:
		_stale += delta
	var kind: String = steps[index]["kind"]
	if _held and not c.is_pressed(RSController.BTN_A if kind == "draw" else RSController.BTN_B):
		_held = false
		_held_for = 0.0
	if _held:
		_held_for += delta
	var fresh := c.sample_time > _sample_at_start and _stale < 0.3
	var tilt := _stick.stick(c.orientation)
	var correct := false
	match kind:
		"right":
			correct = fresh and tilt.x > 0.3
		"forward":
			correct = fresh and tilt.y < -0.3
		"aim":
			correct = fresh and _neutral.angle_to(c.orientation) > deg_to_rad(10.0)
		"hold_b":
			correct = _held
		"throw":
			if _held:
				_peak = maxf(_peak, _motion_peak(c, false))
		"jump":
			if fresh and _motion_peak(c, true) >= 4.0:
				_pass(c)
			return
		_:
			return
	_hold = _hold + delta if correct else 0.0
	if _hold >= (0.5 if kind == "hold_b" else 0.3):
		_pass(c)


func on_button(c: RSController, button: int, pressed: bool) -> void:
	if not started:
		if pressed and button == RSController.BTN_A:
			start(c)
		return
	if finished or not practicing or not c.connected:
		return
	var kind: String = steps[index]["kind"]
	var expected := RSController.BTN_A if kind == "draw" else RSController.BTN_B
	if kind not in ["draw", "throw", "hold_b"] or button != expected:
		return
	if pressed:
		_held = true
		_held_for = 0.0
		_peak = 0.0
		_sample_at_start = c.sample_time
	else:
		if _held and kind == "draw" and _held_for >= 1.0:
			_pass(c)
		elif _held and kind == "throw" and _held_for >= 0.15 and maxf(_peak, _motion_peak(c, false)) >= 4.0:
			_pass(c)
		_held = false
		_held_for = 0.0


func _motion_peak(c: RSController, upward: bool) -> float:
	var result := 0.0
	for age in c.history_size():
		var i := c.history_index(age)
		if c.hist_time[i] <= _sample_at_start:
			break
		if upward:
			var q: Quaternion = c.hist_quat[i]
			result = maxf(result, (q * c.hist_gyro[i]).dot(_stick.frame(q)[0]))
			if c.hist_lin[i].y >= 13.0:
				result = maxf(result, 4.0)
		else:
			result = maxf(result, c.hist_gyro[i].length())
	return result


func _pass(c: RSController) -> void:
	index += 1
	finished = index >= steps.size()
	if not finished:
		_begin_step(c)


class Demo extends Control:
	## A small animated controller cue for each player's lesson card.
	var lesson: RefCounted
	var _body := RSUi.panel_style(12, Color("334155"))

	func _ready() -> void:
		custom_minimum_size = Vector2(180, 80)
		mouse_filter = MOUSE_FILTER_IGNORE

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var kind := "" if lesson == null or lesson.finished else str(lesson.steps[lesson.index]["kind"])
		var phase := fmod(float(lesson.elapsed) / DEMO_SECONDS, 1.0) if lesson != null else 0.0
		var wave := sin(phase * TAU)
		var angle := 0.35 * maxf(wave, 0.0) if kind == "right" else (0.35 * wave if kind == "aim" else 0.0)
		var at := size * 0.5 + Vector2(0, -16.0 * maxf(wave, 0.0) if kind in ["jump", "throw"] else 0.0)
		var scale_y := 1.0 - 0.35 * maxf(wave, 0.0) if kind == "forward" else 1.0
		draw_set_transform(at, angle, Vector2(1, scale_y))
		draw_style_box(_body, Rect2(-35, -29, 70, 58))
		draw_rect(Rect2(-24, -19, 48, 18), Color("0f172a"))
		var button := "A" if kind == "draw" else "B"
		draw_circle(Vector2(0, 15), 10, Color("22c55e") if kind in ["draw", "throw", "hold_b"] and phase < 0.6 else Color("64748b"))
		draw_string(RSUi.font(), Vector2(-5, 20), button, HORIZONTAL_ALIGNMENT_LEFT, -1, 15)
