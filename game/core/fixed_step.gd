class_name RSFixedStep
extends RefCounted
## Fixed-step clock for the hand-written ride physics (skate, ski). Frame time goes into an
## accumulator and comes out as whole STEP sub-steps, at most MAX_STEPS per frame, so a slow
## frame can no longer ask for more and more sub-steps (more CPU, slower frames, more steps).
## A frame that would need more than MAX_STEPS takes MAX_STEPS longer steps instead (up to
## MAX_H each) so the ride stays in real time; only a hitch beyond MAX_STEPS * MAX_H is dropped.
## The leftover time is drawn by interpolating between the last two states (draw()).

const STEP := 1.0 / 120.0
const MAX_STEPS := 3
const MAX_H := 1.0 / 40.0        ## longest sub-step: 30 FPS = 3 x 11.1 ms
const SNAP := 2.0                ## farther than this in one step is a teleport: don't blend

var acc := 0.0                   ## simulated time still owed, < STEP after advance()
var h := STEP                    ## length of each sub-step of the last advance()
var steps := 0                   ## sub-steps taken by the last advance()
var _prev := Vector3.ZERO
var _cur := Vector3.ZERO


func advance(dt: float) -> int:
	## How many sub-steps of length `h` to run for a frame of `dt` seconds.
	acc += maxf(dt, 0.0)
	# The epsilon keeps 2 x (1/120) from coming out as 1 step when dt is exactly 1/60.
	var n := floori(acc / STEP + 1e-4)
	if n <= MAX_STEPS:
		h = STEP
		acc = maxf(acc - n * STEP, 0.0)
	else:
		h = minf(acc / MAX_STEPS, MAX_H)
		n = MAX_STEPS
		acc = 0.0
	steps = n
	return n


func reset(p: Vector3) -> void:
	acc = 0.0
	steps = 0
	_prev = p
	_cur = p


func push(before: Vector3, after: Vector3) -> void:
	## Record the position before and after the last sub-step of this frame.
	_prev = after if before.distance_to(after) > SNAP else before
	_cur = after


func draw(p: Vector3) -> Vector3:
	## Where to draw a body whose simulated position is p (= the last pushed state, unless
	## something moved it outside the sub-steps, which then wins).
	if not p.is_equal_approx(_cur):
		reset(p)
		return p
	return _prev.lerp(_cur, clampf(acc / h, 0.0, 1.0))
