## the_stack.gd — "The Stack" time-dilation state machine (autoload: TheStack).
##
## THE DEFINING MECHANIC (Manifesto §2): playing a card triggers a time-slow
## window — the entire physical simulation drops to stack_time_scale (10%)
## while the cast is telegraphed at the top of the screen and a REAL-TIME
## timer counts down. When it expires, normal speed resumes. This is the
## window in which opponents react with an 'instant' or counter-spell.
##
## HOW THE SLOW-MO WORKS (and why it is rollback-safe):
## Engine.time_scale changes how often physics ticks fire in REAL time — it
## never changes the fixed-point math inside a tick. Tick N produces the same
## bit-identical state at any time scale, so determinism and the future
## Bimdav rollback integration are untouched: this manager only re-paces the
## local PRESENTATION of the deterministic tick timeline.
## NETPLAY NOTE: window open/close is driven by casts (inputs). For rollback,
## the close must eventually be expressed in TICKS (window_ticks = seconds *
## effective tick rate) so both peers agree on the timeline; the real-seconds
## timer here is the single-player presentation of that. When that conversion
## happens it lives in ONE place: this file.
##
## THE UI EXCEPTION: UI must run at 100% during the window. Everything here is
## timed with Time.get_ticks_msec() (wall clock — immune to Engine.time_scale)
## and the signals carry real-seconds values, so UI listeners animate at full
## speed with no special casing. UI scripts should likewise animate off the
## wall clock (see scripts/ui/stack_overlay.gd).
##
## States: NORMAL <-> STACK_WINDOW. Re-opening while already open refreshes
## the deadline (a second cast re-telegraphs and extends the window).
extends Node

## Window opened or refreshed. duration_s is REAL seconds.
signal stack_opened(duration_s: float)

## Emitted every rendered frame while the window is open. REAL seconds left.
signal stack_tick(remaining_s: float)

## Window closed (expired or forced). On the normal expiry path the dilation is
## HELD for the staggered resolution; the listener (MatchController) drives the
## releases and calls resume_speed() after the last spell.
signal stack_closed

enum State { NORMAL, STACK_WINDOW }

## Simulation speed inside the window (Manifesto: 10% "bullet time").
@export_range(0.01, 1.0) var stack_time_scale: float = 0.1

## REAL-seconds length of the window when open_window() is called without an
## explicit duration. Spell cards may pass bespoke durations later.
## 3.0 s per Creative Director (trimmed 0.5 s in the feel pass): every
## staging slows the 3D world to 10% for this long.
@export var default_window_seconds: float = 3.0

var state: State = State.NORMAL

# Wall-clock deadline (msec). Wall clock is immune to Engine.time_scale, so
# the window length is identical no matter how slow the sim is running.
var _deadline_msec: int = 0

# Total length (real seconds) of the CURRENT window — the WOA denominator.
var _window_total_s: float = 0.0

## Exponential ramp rate (per REAL second) of the speed-up back to 1.0. Phase 5:
## raised 7 -> 11 for a snappier, lag-free slow-mo -> normal transition.
@export var resume_ramp_rate: float = 11.0

# Resume-ramp state (wall-clock driven — _process delta is itself scaled).
var _resuming: bool = false
var _resume_last_msec: int = 0

# True between window expiry and resume_speed(): the dilation is HELD while the
# stack resolves spell-by-spell (MatchController drives the staggered releases).
var _resolving: bool = false


## Opens the time-slow window (or refreshes the deadline if already open).
## Called by arena orchestration (MatchController) whenever any caster fires.
func open_window(duration_s: float = -1.0) -> void:
	var seconds: float = duration_s if duration_s > 0.0 else default_window_seconds
	_deadline_msec = Time.get_ticks_msec() + int(seconds * 1000.0)
	_window_total_s = seconds
	_resuming = false  # a fresh window overrides any in-flight resume ramp
	if state == State.NORMAL:
		state = State.STACK_WINDOW
		Engine.time_scale = stack_time_scale
	stack_opened.emit(seconds)


## How much of the current window remains, 0..1 (0 = closed/expired,
## 1 = freshly opened). The COUNTER Window-of-Affect reads this: casting
## later in the countdown (closer to the spell's release) = lower fraction
## = STRONGER counter. NETPLAY NOTE: wall-clock derived, like the reactive
## lock — converts to tick math with the rollback sprint.
func window_fraction_remaining() -> float:
	if state != State.STACK_WINDOW or _window_total_s <= 0.0:
		return 0.0
	return clampf(remaining_seconds() / _window_total_s, 0.0, 1.0)


## Closes the window IMMEDIATELY and ramps speed back up — the instant snap-back
## path, used on a KO / forced close. The NORMAL end-of-stack path is
## _expire_window(), which holds the dilation while the stack resolves spell by
## spell. Speed RAMPS rather than jumping (Creative Director).
func close_window() -> void:
	if state != State.STACK_WINDOW:
		return
	state = State.NORMAL
	resume_speed()
	stack_closed.emit()


## Window timer expired: close the window but HOLD the time dilation so the stack
## can resolve one spell at a time in slow motion. MatchController releases the
## staged entries with a real-time gap between each, then calls resume_speed()
## after the last. NETPLAY NOTE: the resolve cadence is wall-clock presentation
## today; it becomes tick-counted with the rollback sprint (same seam as the
## window timer).
func _expire_window() -> void:
	if state != State.STACK_WINDOW:
		return
	state = State.NORMAL
	_resolving = true
	stack_closed.emit()


## Begins the smooth wall-clock ramp back to 1.0. Called by MatchController AFTER
## the staggered resolution finishes (resume after the FINAL spell), and by
## close_window() for the instant KO / forced path.
func resume_speed() -> void:
	_resolving = false
	_resuming = true
	_resume_last_msec = Time.get_ticks_msec()


## REAL seconds until the window closes (0.0 when closed).
func remaining_seconds() -> float:
	if state != State.STACK_WINDOW:
		return 0.0
	return maxf(0.0, float(_deadline_msec - Time.get_ticks_msec()) / 1000.0)


func _process(_delta: float) -> void:
	# Fast-but-gradual speed-up after a window closes (wall-clock paced).
	if _resuming and state == State.NORMAL:
		var now: int = Time.get_ticks_msec()
		var dt: float = clampf(float(now - _resume_last_msec) / 1000.0, 0.0, 0.05)
		_resume_last_msec = now
		var t: float = 1.0 - exp(-resume_ramp_rate * dt)
		Engine.time_scale = lerpf(Engine.time_scale, 1.0, t)
		if Engine.time_scale > 0.99:
			Engine.time_scale = 1.0
			_resuming = false

	if state != State.STACK_WINDOW:
		return
	var remaining: float = remaining_seconds()
	stack_tick.emit(remaining)
	if remaining <= 0.0:
		_expire_window()
