class_name RSReplay
extends RefCounted
## In-memory slow-motion sampling shared by sports. Frames have nondecreasing t (seconds)
## and sport-owned payloads. One cursor per player; reset on each round/clip. No physics.

var index := 0
var crossed_from := 1             ## Inclusive newly crossed frame range, through index.
var a: Dictionary = {}
var b: Dictionary = {}
var weight := 0.0
var _clip: Array = []
var _time := 0.0


static func record(frames: Array, frame: Dictionary, window: float) -> void:
	frames.append(frame)
	while not frames.is_empty() and float(frame["t"]) - float(frames[0]["t"]) > maxf(window, 0.0):
		frames.pop_front()


static func since(frames: Array, from_time: float) -> Array:
	return frames.filter(func(frame: Dictionary) -> bool: return float(frame["t"]) >= from_time)


static func duration(frames: Array) -> float:
	return maxf(0.0, float(frames.back()["t"]) - float(frames[0]["t"])) if frames.size() > 1 else 0.0


static func lead_out(longest: float, cap: float, padding := 0.3) -> float:
	return minf(maxf(longest, 0.0), maxf(cap, 0.0)) + (padding if longest > 0.0 else 0.0)


func reset(frames: Array) -> void:
	_clip = frames
	index = 0
	crossed_from = 1
	a = {}
	b = {}
	weight = 0.0
	_time = float(frames[0]["t"]) if not frames.is_empty() else 0.0


func sample(elapsed: float, speed: float) -> bool:
	if _clip.size() < 2:
		return false
	var time := float(_clip[0]["t"]) + clampf(elapsed * maxf(speed, 0.0), 0.0, duration(_clip))
	var backwards := time < _time
	if backwards:
		index = 0
	crossed_from = index + 1
	while index + 1 < _clip.size() and float(_clip[index + 1]["t"]) <= time:
		index += 1
	if backwards:
		crossed_from = index + 1  # A seek changes pose without replaying landing sounds.
	_time = time
	a = _clip[index]
	b = _clip[mini(index + 1, _clip.size() - 1)]
	weight = clampf((time - float(a["t"])) / maxf(float(b["t"]) - float(a["t"]), 1e-4), 0.0, 1.0)
	return true
