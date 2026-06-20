## the_stack.gd — "The Stack" window state machine + the global slow-motion clock (autoload: TheStack).
##
## THE STACK WINDOW (Manifesto §2): playing a card opens a telegraph window — the cast is shown at the
## top of the screen and a REAL-TIME timer counts down; opponents react with an 'instant' or counter
## during it. Sprint 23 batch 3 (Creative Director): the window NO LONGER slows time — it runs at full
## speed. Slow-motion is now RESERVED for impact moments: a shield reflect, a player taking damage, and
## the death beat (see hold_dilation / hitstop's timed-slow transition).
##
## THE SLOW-MO CLOCK: this autoload owns Engine.time_scale. hold_dilation() parks a HELD slow-mo (shield
## reflect, death — released by resume_speed()); hitstop() does a sharp freeze that can EASE INTO a held
## dilation (the KO) or a TIMED real-seconds slow-mo (a player-damage hit) before ramping back to 1.0.
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

## VESTIGIAL (Sprint 23 batch 3): the stack window no longer dilates time, so this is no longer applied
## (kept only so existing scene/test overrides don't error). Slow-mo lives on hold_dilation / hitstop now.
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
# HARD KO HITSTOP (Sprint 23 batch 2): when a freeze is armed with a follow-on hold scale (> 0), it
# EASES INTO that held slow-mo when it expires (the death beat) instead of snapping back to full speed
# — the crunch, THEN the slow-mo. 0 = a plain hit hitstop that snaps to 1.0.
var _after_freeze_scale: float = 0.0
# How many real seconds to HOLD the post-freeze slow-mo before ramping back (a player-damage hit). 0 =
# the freeze eases into a HELD dilation instead (the KO death beat). Set alongside _after_freeze_scale.
var _after_freeze_seconds: float = 0.0
# TIMED SLOW-MO (Sprint 23 batch 3, player-damage beat): wall-clock deadline (msec) + the held scale of
# a real-seconds slow-mo that auto-resumes when it elapses (0 = none). Distinct from hold_dilation's
# indefinitely-HELD slow-mo (shield / death, released explicitly).
var _slowmo_until_msec: int = 0
var _slowmo_scale: float = 1.0


## Opens the stack TELEGRAPH window (or refreshes the deadline if already open). Sprint 23 batch 3: the
## window NO LONGER slows time — it is pure state + a real-time countdown now (slow-mo is reserved for
## impacts). Called by arena orchestration (MatchController) whenever a card is staged.
func open_window(duration_s: float = -1.0) -> void:
	var seconds: float = duration_s if duration_s > 0.0 else default_window_seconds
	_deadline_msec = Time.get_ticks_msec() + int(seconds * 1000.0)
	_window_total_s = seconds
	if state == State.NORMAL:
		state = State.STACK_WINDOW
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
	# Sprint 23 batch 3: the window held no dilation, so there is nothing to resume — closing must NOT
	# touch Engine.time_scale (a shield / player-damage slow-mo can be running through a stack window
	# and must survive the window closing).
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
	# Sprint 23 batch 3 (bugfix): do NOT force the stack window to NORMAL here. The window no longer
	# dilates, so the held slow-mo (shield reflect / death) is INDEPENDENT of it — a shield catch during
	# an open stack must leave the staged spells counting down (closing it silently here, without a
	# stack_closed, orphaned the on-screen pile so it lingered into the next round). The death path
	# already calls close_window() before this, so the window still closes correctly on a KO.
	_resolving = true   # held: _process won't touch Engine.time_scale
	_resuming = false
	_hitstop_until_msec = 0  # a held dilation (death / shield) supersedes a hitstop crunch
	_after_freeze_scale = 0.0
	_after_freeze_seconds = 0.0
	_slowmo_until_msec = 0   # ...and supersedes any in-flight timed (player-damage) slow-mo
	Engine.time_scale = clampf(scale, 0.01, 1.0)


## HITSTOP (Sprint 23): a sharp, brief presentation FREEZE on impact — the "crunch" (the biggest
## "explosive" lever). Wall-clock timed (immune to Engine.time_scale), rollback-safe — it re-paces
## presentation only, never the tick math. SKIPPED while a stack window or a held dilation (death
## beat / stack resolve) already owns the clock; otherwise it overrides any resume ramp and snaps
## back SHARP (in _process) for the punch. MatchController calls it on hits, scaling the duration.
## HARD KO (Sprint 23 batch 2): pass [param then_hold_scale] > 0 to have the freeze EASE INTO a slow-mo
## when it expires instead of snapping back to 1.0 — the crunch, then the slow-mo. If [param then_seconds]
## > 0 that follow-on slow-mo is a TIMED real-seconds beat that auto-resumes (a player-damage hit); if 0
## it is HELD until resume_speed() (the KO death beat). Skipped only while a HELD dilation already owns
## the clock (the stack window no longer dilates, so a hit DURING a window still crunches).
func hitstop(duration_ms: int, then_hold_scale: float = 0.0, then_seconds: float = 0.0) -> void:
	if _resolving:
		return
	_hitstop_until_msec = Time.get_ticks_msec() + maxi(1, duration_ms)
	_after_freeze_scale = clampf(then_hold_scale, 0.0, 1.0)
	_after_freeze_seconds = maxf(0.0, then_seconds)
	_slowmo_until_msec = 0
	_resuming = false
	Engine.time_scale = hitstop_scale


## REAL seconds until the window closes (0.0 when closed).
func remaining_seconds() -> float:
	if state != State.STACK_WINDOW:
		return 0.0
	return maxf(0.0, float(_deadline_msec - Time.get_ticks_msec()) / 1000.0)


func _process(_delta: float) -> void:
	# UI COUNTDOWN: emit FIRST, every frame the window is open, BEFORE the hitstop / timed-slow-mo
	# early-returns below (they hold Engine.time_scale and used to skip the bottom emit, freezing the
	# on-screen countdown + its tick audio while a hit's slow-mo played even though the SIM resolver
	# kept perfect time -- the 'timer stuck but spells still resolve' bug). The UI exception: the
	# countdown runs at 100% always, immune to the dilation.
	if state == State.STACK_WINDOW:
		stack_tick.emit(remaining_seconds())
	# HITSTOP: hold the freeze until its wall-clock deadline, then either SNAP back to 1.0 (a plain
	# crunch) or EASE INTO the follow-on slow-mo — a HELD death beat or a TIMED player-damage beat.
	if _hitstop_until_msec > 0:
		if Time.get_ticks_msec() < _hitstop_until_msec:
			Engine.time_scale = hitstop_scale
			return
		_hitstop_until_msec = 0
		if _after_freeze_scale > 0.0:
			var s: float = _after_freeze_scale
			var secs: float = _after_freeze_seconds
			_after_freeze_scale = 0.0
			_after_freeze_seconds = 0.0
			if secs > 0.0:
				# TIMED slow-mo (player-damage beat): hold s for secs REAL seconds, then ramp back.
				_slowmo_scale = clampf(s, 0.01, 1.0)
				_slowmo_until_msec = Time.get_ticks_msec() + int(secs * 1000.0)
				Engine.time_scale = _slowmo_scale
			else:
				hold_dilation(s)   # HELD slow-mo (the KO death beat — released by resume_speed)
			return
		Engine.time_scale = 1.0
	# TIMED SLOW-MO (player-damage beat): hold the dilation until its wall-clock deadline (so it lasts
	# the requested REAL seconds regardless of the dilation), then begin the resume ramp.
	if _slowmo_until_msec > 0:
		if Time.get_ticks_msec() < _slowmo_until_msec:
			Engine.time_scale = _slowmo_scale
			return
		_slowmo_until_msec = 0
		_resuming = true
		_resume_last_msec = Time.get_ticks_msec()
	# Fast-but-gradual speed-up back to 1.0 after a slow-mo ends (wall-clock paced). No longer gated on
	# the stack state — the window holds no dilation now, so the ramp runs whenever one is requested.
	if _resuming:
		var now: int = Time.get_ticks_msec()
		var dt: float = clampf(float(now - _resume_last_msec) / 1000.0, 0.0, 0.05)
		_resume_last_msec = now
		var t: float = 1.0 - exp(-resume_ramp_rate * dt)
		Engine.time_scale = lerpf(Engine.time_scale, 1.0, t)
		if Engine.time_scale > 0.99:
			Engine.time_scale = 1.0
			_resuming = false

