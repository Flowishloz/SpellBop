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

## Window closed — emitted only by close_window() now (Sprint 22 Phase 2: the
## wall-clock auto-expiry was removed). MatchController fires it when the SIM-side
## StackResolver resolves (and on a KO/forced close). Presentation listeners (the
## StackDisplay card pile) clear on this.
signal stack_closed

enum State { NORMAL, STACK_WINDOW }

## Simulation speed inside the window (Manifesto: 10% "bullet time"). The stack
## resolves at this same dilation: when the window expires MatchController fires
## ALL staged spells at once, then resume_speed() ramps back to 1.0.
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

## HITSTOP (Sprint 23, Creative Director): how frozen the world goes during an impact crunch
## (0.04 = near-stopped). The biggest "explosive" lever — a sharp, brief freeze on every hit.
@export_range(0.0, 0.5) var hitstop_scale: float = 0.04
# Wall-clock deadline (msec) of the current hitstop freeze (0 = none).
var _hitstop_until_msec: int = 0


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
	_hitstop_until_msec = 0  # the stack window supersedes any in-flight hitstop crunch
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


## Closes the window: ramps speed back up + emits stack_closed (the HUD card pile
## flies away). Used for BOTH the normal end-of-stack close — MatchController calls
## this when the StackResolver resolves on its deterministic tick — and the KO / forced
## snap-back. Speed RAMPS rather than jumping (Creative Director). (Sprint 22 Phase 2:
## the old wall-clock _expire_window auto-close was removed — the SIM-side resolver owns
## WHEN the window closes; this autoload is now presentation only.)
func close_window() -> void:
	if state != State.STACK_WINDOW:
		return
	state = State.NORMAL
	resume_speed()
	stack_closed.emit()


## Begins the smooth wall-clock ramp back to 1.0. Called by MatchController AFTER
## the staggered resolution finishes (resume after the FINAL spell), and by
## close_window() for the instant KO / forced path.
func resume_speed() -> void:
	_resolving = false
	_resuming = true
	_resume_last_msec = Time.get_ticks_msec()


## DEATH SLOW-MO (Sprint 20): parks the dilation at [param scale] and HOLDS it
## (no resume) so a knockout plays in slow motion. MatchController calls this on a
## KO and resume_speed() after the death beat. Uses the same held-dilation latch
## as the stack resolution, so _process leaves Engine.time_scale untouched until
## the resume.
func hold_dilation(scale: float) -> void:
	state = State.NORMAL
	_resolving = true   # held: _process won't touch Engine.time_scale
	_resuming = false
	_hitstop_until_msec = 0  # a held dilation (death / stack resolve) supersedes a hitstop crunch
	Engine.time_scale = clampf(scale, 0.01, 1.0)


## HITSTOP (Sprint 23): a sharp, brief presentation FREEZE on impact — the "crunch" (the biggest
## "explosive" lever). Wall-clock timed (immune to Engine.time_scale), rollback-safe — it re-paces
## presentation only, never the tick math. SKIPPED while a stack window or a held dilation (death
## beat / stack resolve) already owns the clock; otherwise it overrides any resume ramp and snaps
## back SHARP (in _process) for the punch. MatchController calls it on hits, scaling the duration.
func hitstop(duration_ms: int) -> void:
	if state == State.STACK_WINDOW or _resolving:
		return
	_hitstop_until_msec = Time.get_ticks_msec() + maxi(1, duration_ms)
	_resuming = false
	Engine.time_scale = hitstop_scale


## REAL seconds until the window closes (0.0 when closed).
func remaining_seconds() -> float:
	if state != State.STACK_WINDOW:
		return 0.0
	return maxf(0.0, float(_deadline_msec - Time.get_ticks_msec()) / 1000.0)


func _process(_delta: float) -> void:
	# HITSTOP: hold the freeze until its wall-clock deadline, then SNAP back to 1.0 (sharp =
	# punchy). Takes priority — a crunch overrides the gentle resume ramp.
	if _hitstop_until_msec > 0:
		if Time.get_ticks_msec() < _hitstop_until_msec:
			Engine.time_scale = hitstop_scale
			return
		_hitstop_until_msec = 0
		Engine.time_scale = 1.0
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
	# UI COUNTDOWN ONLY (Sprint 22 Phase 2): the SIM-side StackResolver owns when the
	# window actually closes (a deterministic tick), so the wall clock no longer
	# auto-resolves. remaining_seconds() clamps at 0, so the on-screen timer just sits
	# at 0.0 until the resolver fires (≈ the same instant at the tuned window length).
	stack_tick.emit(remaining_seconds())
