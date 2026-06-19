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
## (Sprint 19, Phase 1: the Left-Shift DASH ability was REMOVED wholesale per the
## Creative Director — movement is now pure accelerate/decelerate locomotion. The
## lane-edge restitution below stays as a gentle wall bounce.)
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

## TIMED MOVE BOOST (the Defense BUFF archetype — Hermes' Boon): fired when a speed boost lands / wears
## off. A presentation hook (a speed-trail VFX could latch on); listeners read sim, never write it, and
## must guard with is_in_rollback() since the apply path re-runs on rollback re-sims (like slow_started).
signal boost_started(duration_ticks: int)
signal boost_ended

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

## Restitution at the lane edge: hitting the wall REFLECTS your speed instead
## of killing it. Reflected speed is capped at max_speed so the carry-off stays
## sane. (Originally tuned for dash momentum; with dash removed it is just a
## gentle wall bounce on normal locomotion.)
@export_range(0.0, 1.0) var arena_bounce: float = 0.6

## Simulation ticks per second. MUST match the project physics tick rate now,
## and the rollback network tick rate later. Changing this rescales all the
## cached per-tick values (done once in _ready()).
@export var tick_rate: int = 60

# --- Cached fixed-point per-tick values (computed once in _ready()) ---
var _max_speed_fp: int = 0        # max speed, units/tick (fixed-point)
var _acceleration_fp: int = 0     # speed change per tick, units/tick (fixed-point)
var _friction_fp: int = 0         # speed loss per tick, units/tick (fixed-point)
var _arena_half_width_fp: int = 0 # arena bound, fixed-point sim units
var _arena_bounce_fp: int = 39322 # lane-edge restitution (0.6)

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

# TIMED MOVE BOOST (the Defense BUFF archetype — Hermes' Boon): the speed-UP mirror of the slow. While
# _boost_ticks > 0 the effective speed scale is MULTIPLIED by _boost_scale_fp (>= ONE), so the wizard
# moves FASTER than base (its max-speed clamp rises with it). RESET-not-stack on re-cast, exactly like
# the timed slow. Int sim state ("bt" / "bs"), composed AFTER the slow so the two products net out.
var _boost_ticks: int = 0
var _boost_scale_fp: int = SGFixed.ONE

# SHIELD-CAPTURE MOTION LOCK (Task 3): while a barrier this wizard deployed is HOLDING a captured ball,
# the owner is frozen — no directional input, an instant stop. A capturing BarrierController re-pushes
# this every held tick (apply_movement_freeze) with a small TTL, so the lock lapses ~1 tick after the
# ball releases. Counts DOWN one per tick, exactly like _slow_ticks. Saved as "fz" so a rollback that
# straddles the hold restores the lock (the cross-tick push has the same one-tick latency as the speed
# accumulator). The WizardAnimatorComponent reads is_frozen() at render-rate for the hold pose + shake.
var _freeze_ticks: int = 0

# SHIELD-RALLY CAST LOCK (the rally "commit"): while a shield RALLY hold runs — the 2nd reciprocated block
# on (a single block never triggers it) — BOTH wizards' casting is locked: the deck-card hand pops out AND
# the base-fireball cast button fades, and no cast (card OR fireball) is accepted, so neither player drops a
# fresh projectile into the dramatic beat. DISTINCT from _freeze_ticks above: this gates ONLY casting (both
# casters — CardCasterComponent + SpellCasterComponent — read is_cast_locked()), NEVER movement, so the
# non-blocking wizard can still dodge a stray. A capturing BarrierController re-pushes it every rally hold
# tick (apply_cast_lock, TTL 2 spans the cross-node ordering latency), so it lapses ~1 tick after release.
# Counts DOWN one per tick like the freeze; saved as "cl" so a rollback restores it.
var _cast_lock_ticks: int = 0

# AIM STATE (Creative Director: the held movement input at release tilts a
# projectile's launch angle — hold longer = steeper). Sim state "ad"/"at".
# While idle the banked aim DECAYS one tick per tick (intent fades). On
# mobile the virtual joystick's push distance will feed this instead.
var _aim_dir: int = 0
var _aim_ticks: int = 0
# Touch-joystick aim sector for THIS tick (Mobile-MP B2): the analog firing angle
# from KEY_AIM in the synced input (0 = none, so the keyboard hold-duration aim
# above applies instead). Transient/input-derived — replayed each tick, NOT saved.
var _aim_key: int = 0

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


# =====================================================================
# ROLLBACK CONTRACT
# =====================================================================

## Advances the simulation by exactly one tick using [param input]
## (an InputCommand dictionary: {"x": -1|0|1} or {}). Deterministic:
## same prior state + same input = bit-identical next state on every machine.
func _network_process(input: Dictionary) -> void:
	var input_x: int = InputCommand.get_x(input)

	# SHIELD-CAPTURE MOTION LOCK (Task 3): while a barrier this wizard deployed holds a captured ball it
	# re-pushes this freeze every held tick. Burn one tick, then drop directional input AND any carried
	# velocity so the wizard is pinned in place (not coasting to a stop) for the whole hold. Aiming/casting
	# are untouched — the lock is "no directional inputs accepted", per the brief. Deterministic (int only).
	if _freeze_ticks > 0:
		_freeze_ticks -= 1
		input_x = 0
		_velocity_x = 0

	# SHIELD-RALLY CAST LOCK (gates casting only — see the field doc): burn one tick. Movement is left
	# untouched here on purpose, so the non-blocking wizard keeps dodging; both casters read is_cast_locked()
	# to refuse new casts (the hand pops out and the fireball button fades).
	if _cast_lock_ticks > 0:
		_cast_lock_ticks -= 1

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
	# TIMED MOVE BOOST (Hermes' Boon): multiply the effective scale by the boost while active, AFTER the
	# slow so a slowed + boosted wizard nets to the product. Burns one tick (identical on every peer).
	if _boost_ticks > 0:
		_boost_ticks -= 1
		effective_scale_fp = SGFixed.mul(effective_scale_fp, _boost_scale_fp)
		if _boost_ticks == 0:
			boost_ended.emit()
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

	# Touch aim (Mobile-MP B2): the joystick's quantized firing angle for this tick.
	# 0 when absent (keyboard) -> the casters fall back to the held-duration aim above.
	_aim_key = InputCommand.get_aim(input)

	# --- LOCOMOTION (accelerate toward the held direction, else decelerate) -
	if input_x != 0:
		# input_x is -1 or +1, so plain int multiplication just flips the sign
		# of the fixed-point step.
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
## RE-APPLICATION RESETS the freeze to a fresh full duration AND scale (Creative
## Director): a reflected ice wall striking an already-frozen wizard restarts the
## timer "as if frozen for the first time" — it never stacks/extends the remaining
## time. Deterministic: a single int assignment, identical on every peer.
func apply_timed_slow(duration_ticks: int, scale_fp: int) -> void:
	if duration_ticks <= 0:
		return
	# RESET (not max/accumulate): the new freeze fully REPLACES the old one — both
	# its duration and its scale start clean, exactly like a first-time freeze.
	_slow_ticks = duration_ticks
	_slow_scale_fp = clampi(scale_fp, 0, SGFixed.ONE)
	slow_started.emit(_slow_ticks)


## Remaining frost ticks (0 = not slowed). Read-only — the ice-cube VFX
## countdown reads this each rendered frame.
func slow_ticks_remaining() -> int:
	return _slow_ticks


## Lands a TIMED move-speed BOOST (the Defense BUFF archetype — Hermes' Boon): for [param duration_ticks]
## the body's speed/acceleration are MULTIPLIED by [param scale_fp] (must be > ONE; a value <= ONE no-ops
## so a buff can never become a hidden slow). RE-APPLICATION RESETS to a fresh full duration + scale (like
## the slow). Deterministic: a couple of int assignments, identical on every peer.
func apply_timed_boost(duration_ticks: int, scale_fp: int) -> void:
	if duration_ticks <= 0 or scale_fp <= SGFixed.ONE:
		return
	_boost_ticks = duration_ticks
	_boost_scale_fp = scale_fp
	boost_started.emit(_boost_ticks)


## Remaining boost ticks (0 = no boost). Read-only presentation/HUD accessor.
func boost_ticks_remaining() -> int:
	return _boost_ticks


## SHIELD-CAPTURE MOTION LOCK (Task 3): freeze this wizard for at least [param ttl] ticks. A capturing
## BarrierController re-pushes this EVERY held tick (default TTL 2 spans the one-tick cross-node ordering
## latency and keeps is_frozen() stable for the render-rate animator read); the lock auto-lapses ~1 tick
## after the barrier stops pushing (on release). MAX-composes so overlapping pushes never shorten it.
## Deterministic: a single int max, identical on every peer; saved as "fz".
func apply_movement_freeze(ttl: int = 2) -> void:
	_freeze_ticks = maxi(_freeze_ticks, maxi(1, ttl))


## True while the shield-capture motion lock is active (see apply_movement_freeze). Read-only — the
## WizardAnimatorComponent polls it each rendered frame to drive the hold pose + shake.
func is_frozen() -> bool:
	return _freeze_ticks > 0


## SHIELD-RALLY CAST LOCK: lock this wizard's casting (deck cards + the base fireball) for at least [param
## ttl] ticks — gates CASTING only, never movement. A capturing BarrierController re-pushes it on BOTH
## wizards every rally hold tick; the lock lapses ~1 tick after the barrier stops pushing (release).
## MAX-composes so overlapping pushes never shorten it. Deterministic single int max, identical on every
## peer; saved as "cl".
func apply_cast_lock(ttl: int = 2) -> void:
	_cast_lock_ticks = maxi(_cast_lock_ticks, maxi(1, ttl))


## True while the shield-rally cast lock is active (see apply_cast_lock). BOTH casters gate new casts on it
## (CardCasterComponent + SpellCasterComponent), the card-hand HUD pops the whole hand out, and the cast
## button fades — all for the rally beat. Read-only — does NOT affect movement.
func is_cast_locked() -> bool:
	return _cast_lock_ticks > 0


## Current aim direction (-1/0/+1) and how many ticks it has been held —
## casters tilt launch angles from these (read-only sim accessors).
func get_aim_dir() -> int:
	return _aim_dir


func get_aim_ticks() -> int:
	return _aim_ticks


## This tick's TOUCH aim sector (Mobile-MP B2): the joystick's quantized firing
## angle from the synced input (0 = none, so the casters use the held-direction aim
## above). Casters fold this with get_aim_dir()/get_aim_ticks() into one sector.
func get_aim_key() -> int:
	return _aim_key


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


## Hard-stops the body (round reset): zeroes velocity and clears the frost.
## The position itself is set by the caller (PlayerController.reset_for_round)
## — this only clears MOTION state, then re-emits position for the visuals.
func halt() -> void:
	_velocity_x = 0
	_slow_ticks = 0
	_slow_scale_fp = SGFixed.ONE
	_boost_ticks = 0
	_boost_scale_fp = SGFixed.ONE
	_freeze_ticks = 0
	_cast_lock_ticks = 0
	_aim_dir = 0
	_aim_ticks = 0
	_aim_key = 0
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
		"bt": _boost_ticks,
		"bs": _boost_scale_fp,
		"ad": _aim_dir,
		"at": _aim_ticks,
		"fz": _freeze_ticks,
		"cl": _cast_lock_ticks,
	}


## Restores a snapshot produced by _save_state(). Teleports the body, so it
## re-syncs the physics engine, then re-emits state_updated so the visual
## bridge snaps to the restored position.
func _load_state(state: Dictionary) -> void:
	_velocity_x = int(state.get("vx", 0))
	_speed_scale_fp = int(state.get("ss", SGFixed.ONE))
	_slow_ticks = int(state.get("slt", 0))
	_slow_scale_fp = int(state.get("sls", SGFixed.ONE))
	_boost_ticks = int(state.get("bt", 0))
	_boost_scale_fp = int(state.get("bs", SGFixed.ONE))
	_aim_dir = int(state.get("ad", 0))
	_aim_ticks = int(state.get("at", 0))
	_freeze_ticks = int(state.get("fz", 0))
	_cast_lock_ticks = int(state.get("cl", 0))

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
## (capped at max_speed) so walking into the lane edge gives a gentle bounce
## instead of a dead stop.
func _clamp_to_arena() -> void:
	var pos: SGFixedVector2 = _body.fixed_position
	var clamped_x: int = clampi(pos.x, -_arena_half_width_fp, _arena_half_width_fp)
	if clamped_x == pos.x:
		return

	pos.x = clamped_x
	_body.fixed_position = pos
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
