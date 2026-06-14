## movement_component.gd — Deterministic X-axis mover (SG Physics 2D fixed-point).
##
## ROLE: The single source of truth for player movement simulation. ALL math in
## here is 64.16 fixed-point (SGFixed, ONE = 65536) — never Godot floats — so
## every peer that replays the same inputs gets bit-identical results.
##
## Movement is locked to the X axis (left/right along the dodgeball baseline).
## The sim runs on the SG Physics 2D plane; the VisualBridgeComponent maps
## sim X -> visual X and sim Y -> visual Z for the 3D "tennis court" view.
##
## UNITS & TUNING MODEL (what the human tunes in the Inspector):
##  - max_speed:    sim units per SECOND (1 sim unit = 1 "pixel" on the sim plane).
##  - acceleration: sim units/sec of speed gained per SECOND while input is held
##                  (i.e. units/sec^2). max_speed / acceleration = seconds to
##                  reach top speed from standstill.
##  - friction:     sim units/sec of speed lost per SECOND with no input
##                  (units/sec^2). max_speed / friction = seconds to stop.
## All four floats are converted ONCE to fixed-point per-tick values in _ready()
## and cached; the per-tick hot path touches integers only.
##
## ROLLBACK CONTRACT: exposes _network_process(input), _save_state(),
## _load_state(state) per the godot-rollback-netcode conventions. State dicts
## contain only ints. A local tick driver (PlayerController) calls these for
## now; the rollback SyncManager will drive them in a later sprint.
class_name MovementComponent
extends Node

## Fired every simulated tick (and on state load) with the body's fixed-point
## position. The VisualBridgeComponent listens to this — visuals READ from the
## sim via this signal and never write back.
signal state_updated(fixed_x: int, fixed_y: int)

## TIMED SLOW (the Counter's frost debuff): fired when a slow lands / wears
## off. Presentation hooks (the ice-cube VFX + countdown) — listeners read,
## never write sim.
signal slow_started(duration_ticks: int)
signal slow_ended

## A dash just triggered (presentation hook: SFX/VFX).
signal dashed

## Path to the SGCharacterBody2D this component moves. Leave empty to use the
## component's direct parent (the recommended scene shape:
## PlayerController (SGCharacterBody2D) -> MovementComponent).
@export var body_path: NodePath

## Top horizontal speed, in sim units per second. Tune for overall game pace.
@export var max_speed: float = 400.0

## Speed gained per second while holding a direction (units/sec^2).
## max_speed / acceleration = time-to-max-speed. 2000 with max_speed 400
## means full speed in 0.2 s — snappy but not instant.
@export var acceleration: float = 2000.0

## Speed lost per second when no direction is held (units/sec^2).
## max_speed / friction = stopping time. Higher than acceleration gives a
## tight, responsive stop.
@export var friction: float = 2400.0

## Half the playable lane width in sim units. fixed_position.x is clamped to
## the range [-arena_half_width, +arena_half_width] every tick.
@export var arena_half_width: float = 600.0

## Restitution at the lane edge: hitting the wall REFLECTS your speed
## instead of killing it (Creative Director: dash momentum should bounce
## you away). Reflected speed is capped at max_speed so a dash's huge
## per-tick step bounces you off at a sane pace.
@export_range(0.0, 1.0) var arena_bounce: float = 0.6

## Simulation ticks per second. MUST match the project physics tick rate now,
## and the rollback network tick rate later. Changing this rescales all the
## cached per-tick values (done once in _ready()).
@export var tick_rate: int = 60

@export_group("Dash")
## DASH (Creative Director: Left Shift) — a burst that covers
## dash_distance_fraction of the FULL arena width in dash_time_fraction of
## the time normal movement would need, on a press EDGE while a direction
## is held. Landing roots the wizard: 90% speed loss for 0.8 s.
@export var dash_enabled: bool = true

## Fraction of the full arena width (2 x arena_half_width) the dash covers.
@export var dash_distance_fraction: float = 0.35

## Dash flight time as a fraction of the normal travel time at max_speed.
## 0.04 resolves to a SINGLE TICK — the dash is an instant blink, so the
## Stack's 10% time dilation can't smear it into a slow glide (Creative
## Director: "the dash doesn't interact well with the slow motion"). The
## visual still sweeps via the VisualBridge smoothing, which runs on render
## frames and stays fast inside slow-mo.
@export var dash_time_fraction: float = 0.04

## Seconds between dashes.
@export var dash_cooldown_seconds: float = 5.0

## Landing penalty: speed scale (0.1 = 90% slower) for this many seconds.
@export var dash_landing_slow_seconds: float = 0.8
@export var dash_landing_slow_scale: float = 0.1

# --- Cached fixed-point per-tick values (computed once in _ready()) ---
var _max_speed_fp: int = 0        # max speed, units/tick (fixed-point)
var _acceleration_fp: int = 0     # speed change per tick, units/tick (fixed-point)
var _friction_fp: int = 0         # speed loss per tick, units/tick (fixed-point)
var _arena_half_width_fp: int = 0 # arena bound, fixed-point sim units
var _arena_bounce_fp: int = 39322 # lane-edge restitution (0.6)
var _dash_duration_ticks: int = 1 # dash flight time, whole ticks
var _dash_step_fp: int = 0        # dash distance per tick (fixed-point)
var _dash_cd_ticks: int = 300     # cooldown, whole ticks
var _dash_slow_cfg_ticks: int = 48
var _dash_slow_scale_fp: int = 6554

# Authoritative simulation state (fixed-point int). Velocity is stored here —
# not read from the body between ticks — so _save_state()/_load_state() fully
# own it.
var _velocity_x: int = 0

# Deterministic speed modifier (fixed-point, ONE = full speed). ACCUMULATOR:
# casters (SpellCasterComponent's charge ramp, CardCasterComponent's casting
# cost) push penalties with apply_speed_penalty() during THEIR slice of the
# tick; this component consumes the min-composed value at the top of its NEXT
# tick and then resets the accumulator to ONE. A caster that is idle simply
# pushes nothing — so two casters never fight over the scale (the old
# single-writer set_speed_scale let an idle caster's ONE erase an active
# caster's penalty). Applied to max speed AND acceleration; friction is
# unscaled so stopping stays snappy. Saved/loaded as sim state ("ss").
var _speed_scale_fp: int = SGFixed.ONE

# TIMED SLOW (Counter frost): independent of the per-tick accumulator above —
# a debuff with a tick lifetime. Min-composed with the accumulator each tick.
# Both values are int sim state ("slt" / "sls").
var _slow_ticks: int = 0
var _slow_scale_fp: int = SGFixed.ONE

# DASH sim state (ints): flight ticks left, direction, cooldown, the landing
# slow (its own field — the frost slow drives the ice-cube VFX, this one
# must not), last tick's dash bit (press-edge derivation), and the last
# nonzero movement direction (dash fallback when Shift is tapped alone).
var _dash_remaining: int = 0
var _dash_dir: int = 0
var _dash_cd: int = 0
var _dash_slow: int = 0
var _prev_dash: int = 0
var _last_input_dir: int = 1
# Wall REBOUND: dashing into the lane edge mirrors into a half-step blink
# away from it (sim state "dbr"); _dash_moved_this_tick is within-tick
# transient (recomputed every tick, never saved).
var _dash_rebound: bool = false
var _dash_moved_this_tick: bool = false

# AIM STATE (Creative Director: the held movement input at release tilts a
# projectile's launch angle — hold longer = steeper). Sim state "ad"/"at".
# While idle the banked aim DECAYS one tick per tick (intent fades). On
# mobile the virtual joystick's push distance will feed this instead.
var _aim_dir: int = 0
var _aim_ticks: int = 0

var _body: SGCharacterBody2D


func _ready() -> void:
	_body = _resolve_body()
	assert(_body != null, "MovementComponent requires an SGCharacterBody2D (set body_path or parent it under one).")
	_cache_fixed_point_values()


## Converts the human-friendly float exports to fixed-point per-tick values.
## Called once in _ready(); call again manually if you live-tweak exports at
## runtime in a debug build.
func _cache_fixed_point_values() -> void:
	var safe_tick_rate: int = maxi(1, tick_rate)
	var tick_fp: int = SGFixed.from_int(safe_tick_rate)
	# units/sec -> units/tick
	_max_speed_fp = SGFixed.div(SGFixed.from_float(max_speed), tick_fp)
	# units/sec^2 -> (units/tick) change per tick: divide by tick_rate twice.
	_acceleration_fp = SGFixed.div(SGFixed.div(SGFixed.from_float(acceleration), tick_fp), tick_fp)
	_friction_fp = SGFixed.div(SGFixed.div(SGFixed.from_float(friction), tick_fp), tick_fp)
	_arena_half_width_fp = SGFixed.from_float(arena_half_width)
	_arena_bounce_fp = SGFixed.from_float(clampf(arena_bounce, 0.0, 1.0))

	# DASH derivation: distance = fraction of full arena width; flight time =
	# dash_time_fraction of the normal time at max_speed (ceil to ticks).
	var dash_distance: float = 2.0 * arena_half_width * clampf(dash_distance_fraction, 0.0, 1.0)
	var normal_seconds: float = dash_distance / maxf(1.0, max_speed)
	_dash_duration_ticks = maxi(1, ceili(normal_seconds * maxf(0.01, dash_time_fraction) * float(safe_tick_rate)))
	_dash_step_fp = SGFixed.div(SGFixed.from_float(dash_distance), SGFixed.from_int(_dash_duration_ticks))
	_dash_cd_ticks = maxi(1, ceili(dash_cooldown_seconds * float(safe_tick_rate)))
	_dash_slow_cfg_ticks = maxi(0, ceili(dash_landing_slow_seconds * float(safe_tick_rate)))
	_dash_slow_scale_fp = SGFixed.from_float(clampf(dash_landing_slow_scale, 0.0, 1.0))


# =====================================================================
# ROLLBACK CONTRACT
# =====================================================================

## Advances the simulation by exactly one tick using [param input]
## (an InputCommand dictionary: {"x": -1|0|1} or {}). Deterministic:
## same prior state + same input = bit-identical next state on every machine.
func _network_process(input: Dictionary) -> void:
	var input_x: int = InputCommand.get_x(input)

	# This tick's effective tuning under the deterministic speed modifier
	# (ONE = unscaled). Pure fixed-point multiplies — still integer math.
	# Consume the penalties casters pushed LAST tick, then reset the
	# accumulator: active casters re-push every tick (one-tick latency,
	# identical on every peer); idle casters stay silent. The timed slow
	# (Counter frost) min-composes on top and burns one tick.
	var effective_scale_fp: int = _speed_scale_fp
	_speed_scale_fp = SGFixed.ONE
	if _slow_ticks > 0:
		_slow_ticks -= 1
		effective_scale_fp = mini(effective_scale_fp, _slow_scale_fp)
		if _slow_ticks == 0:
			slow_ended.emit()
	# Dash-landing root (own field — never triggers the frost VFX).
	if _dash_slow > 0:
		_dash_slow -= 1
		effective_scale_fp = mini(effective_scale_fp, _dash_slow_scale_fp)
	var max_speed_fp: int = SGFixed.mul(_max_speed_fp, effective_scale_fp)
	var acceleration_fp: int = SGFixed.mul(_acceleration_fp, effective_scale_fp)

	# --- AIM TRACKING (how long the current direction has been held) -----
	if input_x != 0:
		if input_x == _aim_dir:
			_aim_ticks += 1
		else:
			_aim_dir = input_x
			_aim_ticks = 1
	elif _aim_ticks > 0:
		_aim_ticks -= 1  # idle: the banked aim fades, never hard-resets

	# --- DASH (press edge, off cooldown) ---------------------------------
	# Direction = the held input, falling back to the LAST direction moved
	# (a bare Shift tap must always do something — playtest fix).
	if input_x != 0:
		_last_input_dir = input_x
	if _dash_cd > 0:
		_dash_cd -= 1
	var dash_bit: int = InputCommand.get_dash(input)
	if dash_enabled and dash_bit == 1 and _prev_dash == 0 \
			and _dash_cd == 0 and _dash_remaining == 0:
		_dash_remaining = _dash_duration_ticks
		_dash_dir = input_x if input_x != 0 else _last_input_dir
		_dash_cd = _dash_cd_ticks
		dashed.emit()
	_prev_dash = dash_bit

	_dash_moved_this_tick = false
	if _dash_remaining > 0:
		# Dash flight overrides normal locomotion entirely (no input, no
		# friction, no speed scaling — a committed blink along X). A wall
		# REBOUND blink travels at half the step.
		_dash_remaining -= 1
		_dash_moved_this_tick = true
		var step: int = (_dash_step_fp >> 1) if _dash_rebound else _dash_step_fp
		_velocity_x = _dash_dir * step
		if _dash_remaining == 0:
			_dash_rebound = false
			_dash_slow = _dash_slow_cfg_ticks  # landing root
	elif input_x != 0:
		# Accelerate toward the held direction. input_x is -1 or +1, so plain
		# int multiplication just flips the sign of the fixed-point step.
		_velocity_x += input_x * acceleration_fp
		_velocity_x = clampi(_velocity_x, -max_speed_fp, max_speed_fp)
	else:
		# Decelerate toward zero, never overshooting past it.
		if _velocity_x > 0:
			_velocity_x = maxi(0, _velocity_x - _friction_fp)
		elif _velocity_x < 0:
			_velocity_x = mini(0, _velocity_x + _friction_fp)

	# Push velocity into the deterministic physics body. Y is always zero:
	# baseline movement is X-only this milestone.
	var vel: SGFixedVector2 = _body.velocity
	vel.x = _velocity_x
	vel.y = 0
	_body.velocity = vel
	_body.move_and_slide()

	# Respect deterministic collisions (e.g. future obstacles): the body's
	# post-slide velocity becomes our authoritative velocity.
	_velocity_x = _body.velocity.x

	_clamp_to_arena()

	var pos: SGFixedVector2 = _body.fixed_position
	state_updated.emit(pos.x, pos.y)


## Pushes a deterministic speed penalty (fixed-point; SGFixed.ONE = 100%,
## 0 = stationary) for this body's NEXT tick. MIN-COMPOSES with any penalty
## already pushed this tick (fireball charge + card cast can overlap — the
## harshest penalty wins), and the accumulator self-resets each tick, so
## active casters must re-push every tick and idle casters push nothing.
func apply_speed_penalty(scale_fp: int) -> void:
	_speed_scale_fp = mini(_speed_scale_fp, clampi(scale_fp, 0, SGFixed.ONE))


## Lands a TIMED slow (the Counter's frost debuff): for [param duration_ticks]
## the body's speed/acceleration are scaled by at most [param scale_fp].
## Re-application keeps the longer duration and the harsher scale.
func apply_timed_slow(duration_ticks: int, scale_fp: int) -> void:
	if duration_ticks <= 0:
		return
	var was_active: bool = _slow_ticks > 0
	var clamped: int = clampi(scale_fp, 0, SGFixed.ONE)
	_slow_ticks = maxi(_slow_ticks, duration_ticks)
	# Overlapping slows keep the harsher scale; a FRESH slow starts clean
	# (an expired debuff's scale must not contaminate the next one).
	_slow_scale_fp = mini(_slow_scale_fp, clamped) if was_active else clamped
	slow_started.emit(_slow_ticks)


## Remaining frost ticks (0 = not slowed). Read-only — the ice-cube VFX
## countdown reads this each rendered frame.
func slow_ticks_remaining() -> int:
	return _slow_ticks


## Current aim direction (-1/0/+1) and how many ticks it has been held —
## casters tilt launch angles from these (read-only sim accessors).
func get_aim_dir() -> int:
	return _aim_dir


func get_aim_ticks() -> int:
	return _aim_ticks


## The cached arena half-width in fixed-point — the SAME lane edge this body is
## clamped to (see _clamp_to_arena). Spawn sites read this so projectile / wall
## / wave ORIGINS clamp to the same bound the wizard uses; spawns and bodies
## never disagree about where the court ends. Scene-overridden (400 in
## match_arena, 500 in test_area, 600 script default).
func arena_half_width_fp() -> int:
	return _arena_half_width_fp


## Deterministic spawn-X clamp (STATIC so a projectile with no MovementComponent
## of its own — e.g. a barrier-breaker shard — can call it too). Keeps a spawned
## object's FULL extent inside the lane by clamping its CENTRE to
## ±(bound − half_extent). Pure 64.16 fixed-point (one subtraction + clampi),
## no float in the cast path, identical on every peer — the same proven pattern
## as _clamp_to_arena(). AIM IS NEVER INVOLVED: this clamps the spawn ORIGIN
## only; the aim tilt lives on launch VELOCITY and is left untouched, so spells
## stay fully aimable. If an object is wider than the whole lane
## (half_extent ≥ bound) the limit floors at 0 (pin to centre) so clampi can
## never be handed an inverted min > max range.
static func clamp_spawn_x_fp(x_fp: int, half_extent_fp: int, bound_fp: int) -> int:
	var limit_fp: int = bound_fp - half_extent_fp
	if limit_fp < 0:
		limit_fp = 0
	return clampi(x_fp, -limit_fp, limit_fp)


## Dash cooldown remaining, REAL seconds (0 = ready). HUD button readout.
func dash_cooldown_seconds_remaining() -> float:
	return float(_dash_cd) / float(maxi(1, tick_rate))


## Dash cooldown as a 0..1 fraction (0 = ready) — the clock-fill readout.
func dash_cooldown_fraction() -> float:
	return clampf(float(_dash_cd) / float(maxi(1, _dash_cd_ticks)), 0.0, 1.0)


## Hard-stops the body (round reset): zeroes velocity and clears the frost.
## The position itself is set by the caller (PlayerController.reset_for_round)
## — this only clears MOTION state, then re-emits position for the visuals.
func halt() -> void:
	_velocity_x = 0
	_slow_ticks = 0
	_slow_scale_fp = SGFixed.ONE
	_dash_remaining = 0
	_dash_cd = 0
	_dash_slow = 0
	_prev_dash = 0
	_dash_rebound = false
	_aim_dir = 0
	_aim_ticks = 0
	var vel: SGFixedVector2 = _body.velocity
	vel.x = 0
	vel.y = 0
	_body.velocity = vel
	slow_ended.emit()
	var pos: SGFixedVector2 = _body.fixed_position
	state_updated.emit(pos.x, pos.y)


## Snapshot of all mutable simulation state. Ints only (fixed-point), never
## floats/objects — required for rollback hashing and serialization.
func _save_state() -> Dictionary:
	var pos: SGFixedVector2 = _body.fixed_position
	return {
		"px": pos.x,
		"py": pos.y,
		"vx": _velocity_x,
		"ss": _speed_scale_fp,
		"slt": _slow_ticks,
		"sls": _slow_scale_fp,
		"dt": _dash_remaining,
		"dd": _dash_dir,
		"dcd": _dash_cd,
		"dsl": _dash_slow,
		"pd": _prev_dash,
		"lx": _last_input_dir,
		"ad": _aim_dir,
		"at": _aim_ticks,
		"dbr": 1 if _dash_rebound else 0,
	}


## Restores a snapshot produced by _save_state(). Teleports the body, so it
## re-syncs the physics engine, then re-emits state_updated so the visual
## bridge snaps to the restored position.
func _load_state(state: Dictionary) -> void:
	_velocity_x = int(state.get("vx", 0))
	_speed_scale_fp = int(state.get("ss", SGFixed.ONE))
	_slow_ticks = int(state.get("slt", 0))
	_slow_scale_fp = int(state.get("sls", SGFixed.ONE))
	_dash_remaining = int(state.get("dt", 0))
	_dash_dir = int(state.get("dd", 0))
	_dash_cd = int(state.get("dcd", 0))
	_dash_slow = int(state.get("dsl", 0))
	_prev_dash = int(state.get("pd", 0))
	_last_input_dir = int(state.get("lx", 1))
	_aim_dir = int(state.get("ad", 0))
	_aim_ticks = int(state.get("at", 0))
	_dash_rebound = int(state.get("dbr", 0)) == 1

	var pos: SGFixedVector2 = _body.fixed_position
	pos.x = int(state.get("px", 0))
	pos.y = int(state.get("py", 0))
	_body.fixed_position = pos

	var vel: SGFixedVector2 = _body.velocity
	vel.x = _velocity_x
	vel.y = 0
	_body.velocity = vel

	# Mandatory after directly writing fixed_position: keep the SG physics
	# broadphase in agreement with the node.
	_body.sync_to_physics_engine()

	state_updated.emit(pos.x, pos.y)


# =====================================================================
# Internals
# =====================================================================

## Clamps fixed_position.x to ±arena_half_width. The clamp is a teleport, so
## sync_to_physics_engine() is mandatory. Velocity REFLECTS with restitution
## (capped at max_speed — a dash's giant per-tick step bounces you away at
## a sane pace instead of dying against the wall).
func _clamp_to_arena() -> void:
	var pos: SGFixedVector2 = _body.fixed_position
	var clamped_x: int = clampi(pos.x, -_arena_half_width_fp, _arena_half_width_fp)
	if clamped_x == pos.x:
		return

	pos.x = clamped_x
	_body.fixed_position = pos
	if _dash_moved_this_tick:
		# DASH REBOUND (Creative Director: the wall must not eat the
		# momentum): mirror into a half-step blink AWAY from the wall —
		# input can't fight a blink the way it cancels a reflected velocity.
		_dash_dir = -_dash_dir
		_dash_remaining = 1
		_dash_rebound = true
		_velocity_x = 0
	else:
		var reflected: int = -SGFixed.mul(_velocity_x, _arena_bounce_fp)
		_velocity_x = clampi(reflected, -_max_speed_fp, _max_speed_fp)
	var vel: SGFixedVector2 = _body.velocity
	vel.x = _velocity_x
	vel.y = 0
	_body.velocity = vel
	_body.sync_to_physics_engine()


func _resolve_body() -> SGCharacterBody2D:
	if not body_path.is_empty():
		return get_node_or_null(body_path) as SGCharacterBody2D
	return get_parent() as SGCharacterBody2D
