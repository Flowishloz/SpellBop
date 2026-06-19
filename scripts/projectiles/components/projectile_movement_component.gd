## projectile_movement_component.gd — Deterministic projectile mover (SG Physics 2D fixed-point).
##
## ROLE: The single source of truth for projectile flight simulation. ALL math
## in here is 64.16 fixed-point (SGFixed, ONE = 65536) — never Godot floats —
## so every peer that replays the same launch gets bit-identical results.
##
## Projectiles are dumb ballistic movers: launched once with a fixed-point
## velocity, advanced one move_and_collide() step per tick, and deterministically
## reflected off whatever they hit (BounceWall, arena bounds, players' colliders)
## using SGFixedVector2.bounce(normal) — the fixed-point v' = v - 2(v·n)n —
## scaled by a per-projectile bounciness. Projectiles take NO input; their
## _network_process ignores the input dictionary entirely.
##
## UNITS & TUNING MODEL (what the human tunes in the Inspector):
##  - terminal_velocity: sim units per SECOND (1 sim unit = 1 "pixel" on the sim
##    plane). Hard ceiling on projectile speed, enforced every tick and after
##    every bounce — protects against runaway speed from boosted spells and
##    keeps tunneling impossible at sane collider sizes.
## The float is converted ONCE to a fixed-point per-tick cap in _ready() and
## cached; the per-tick hot path touches integers only.
##
## LAUNCH UNITS — IMPORTANT: launch() velocity arguments are fixed-point sim
## units per TICK (the spawner — SpellCasterComponent — converts the spell's
## units/sec stat to units/tick once at cast time). Bounciness is fixed-point
## where ONE (65536) = no speed loss per bounce, 32768 = half speed, etc.
##
## ROLLBACK CONTRACT: exposes _network_process(input), _save_state(),
## _load_state(state) per the godot-rollback-netcode conventions. State dicts
## contain only ints. A local tick driver (FireballController) calls these for
## now; the rollback SyncManager will drive them in a later sprint.
class_name ProjectileMovementComponent
extends Node

## Fired every simulated tick (and on state load) with the body's fixed-point
## position. The VisualBridgeComponent listens to this — visuals READ from the
## sim via this signal and never write back.
signal state_updated(fixed_x: int, fixed_y: int)

## Fired when the projectile reflects off a collider, with the fixed-point
## collision normal. SFX/VFX/gameplay hooks listen here (signal-driven
## decoupling) — listeners read, they never modify sim state.
signal bounced(normal_x: int, normal_y: int)

## Fired when the projectile leaves the playable court (|x| or |y| beyond
## despawn_distance). The controller listens and frees the projectile —
## rally hygiene so missed shots don't accumulate forever. Deterministic:
## purely a function of the simulated position.
signal expired

## Path to the SGCharacterBody2D this component moves. Leave empty to use the
## component's direct parent (the recommended scene shape:
## FireballController (SGCharacterBody2D) -> ProjectileMovementComponent).
@export var body_path: NodePath

## Hard speed ceiling, in sim units per second. Enforced every tick and after
## every bounce: if |velocity| exceeds the cap the vector is rescaled (same
## direction, capped magnitude) in fixed point. Default is generous — base
## fireballs fly well below it; it exists to bound stacked speed buffs.
@export var terminal_velocity: float = 1600.0

## Simulation ticks per second. MUST match the project physics tick rate now,
## and the rollback network tick rate later. Changing this rescales the cached
## per-tick cap (done once in _ready()).
@export var tick_rate: int = 60

## Court bound, in sim units: when |x| or |y| exceeds this the projectile
## emits `expired` and its controller frees it. Set beyond both baselines
## (court is ±1100 down-court) so balls visibly leave play before vanishing.
@export var despawn_distance: float = 1500.0

## Maximum flight time in SECONDS before the projectile expires, counted in
## deterministic ticks from launch(). 0 = unlimited (despawn_distance only).
## The Base Fireball uses ~the time to cross the court and just pass the
## opponent — a missed default shot never lives long enough to circle back to
## its caster (Creative Director directive).
@export var lifespan_seconds: float = 0.0

## STUCK-PROJECTILE CLEANUP (Creative Director): a homing bolt chasing an evading wizard
## bleeds speed — the steer blends two equal-length vectors, so a turning ball's velocity
## gets SHORTER each tick — and can crawl to a near-stop mid-court, then sit out its full
## lifespan ("the spark gets stuck in the middle and takes too long to despawn"). Despawn it
## promptly once it has stayed slower than this floor for stationary_lifespan_seconds. Set
## the floor WELL BELOW cruising speed (a base fireball flies ~17.5 u/tick = ~1050 u/s) so
## only genuinely stalled balls qualify; a normal lossless-bounce ball never dips here. A
## barrier-CAPTURED ball is frozen at 0 on purpose — the barrier calls keep_alive() each
## hold tick so the stall despawn never reclaims it. 0 disables the check.
## Floor is a NEAR-STOP speed (120 u/s = 2 u/tick ≈ 1.2 m/s): genuinely stuck, not merely
## slow — a real projectile cruises ~17.5+ u/tick and can only dip here by homing-stalling
## (its speed is monotonically non-increasing after launch, so a low reading can't recover).
@export var stationary_speed_threshold: float = 120.0
@export var stationary_lifespan_seconds: float = 0.6

## SHIELD-REFLECT RALLY (Creative Director): each barrier reflect of THIS ball raises its effective
## speed cap by rally_speed_growth, so a rallied ball ACCELERATES instead of pinning to the base
## terminal cap (the reflect grows the ball past the old ceiling). Bounded at max_rally_reflects
## compounding steps so a long rally can't reach tunnelling speeds. reflect 0 (the first block) is the
## baseline (mult 1.0); the growth applies from the rally's later exchanges. Pairs with the barrier's
## reflect_hold_growth + MatchController's reflect_shake_growth — see BarrierController._tick_capture.
@export var rally_speed_growth: float = 1.2
@export var max_rally_reflects: int = 6

# --- Cached fixed-point per-tick values (computed once in _ready()) ---
var _terminal_velocity_fp: int = 0   # speed cap, units/tick (fixed-point)
var _despawn_distance_fp: int = 0    # court bound, fixed-point sim units
var _lifespan_ticks: int = 0         # max flight time, whole ticks (0 = off)
var _stationary_speed_fp: int = 0    # stall speed floor, units/tick (fixed-point)
var _stationary_lifespan_ticks: int = 0  # ticks below the floor before despawn (0 = off)
var _rally_growth_fp: int = SGFixed.ONE  # rally_speed_growth as fixed-point (cached in _ready)

# Ticks since launch() — deterministic sim state (saved/loaded for rollback).
var _age_ticks: int = 0
# Consecutive ticks the speed has stayed below the stall floor — deterministic sim state
# (saved/loaded; reset by motion above the floor OR a barrier's keep_alive() during capture).
var _stationary_ticks: int = 0
# SHIELD-REFLECT RALLY: how many times a barrier has reflected this ball — deterministic sim state
# (saved "rc"). Drives the escalating speed cap here AND the barrier's escalating hold. Incremented
# by BarrierController at release; NEVER reset by launch() (it must persist across the rally).
var _reflect_count: int = 0

# SHIELD-RALLY SIM SLOW (the gameplay half of the shield rally slow-mo): while _sim_slow_ticks > 0 this
# projectile's per-tick MOTION is scaled by _sim_slow_factor_fp (< ONE), so a stray ball CRAWLS during a
# shield rally hold and can't cross into a frozen wizard mid-rally. This is the deterministic counterpart to
# the presentation time-dilation: Engine.time_scale slows REAL time but NEVER the per-tick sim distance
# (graveyard rule), so on its own it can't hold a stray back — this does. A capturing BarrierController
# re-pushes it every rally hold tick (apply_sim_slow, TTL 2 spans the cross-node ordering latency), so it
# lapses ~1 tick after release. Only the MOVE is scaled — stored velocity is untouched, so the speed cap,
# stall-despawn and homing all keep reading the TRUE speed. Int sim state, saved/loaded as "ssk"/"ssf".
var _sim_slow_ticks: int = 0
var _sim_slow_factor_fp: int = SGFixed.ONE

# Authoritative simulation state (fixed-point ints). Velocity is stored here —
# not read from the body between ticks — so _save_state()/_load_state() fully
# own it. Bounciness is mutable sim state too (set per-launch by the spell).
var _velocity_x: int = 0
var _velocity_y: int = 0
var _bounciness: int = SGFixed.ONE

# HOMING (CardResource.homing_strength): per-tick fixed-point steering blend
# toward the target ("hb" in _save_state). The target NODE ref is the same
# rollback-lifecycle debt as projectile spawning itself (SyncManager later).
var _homing_blend_fp: int = 0
var _homing_target: Node = null

var _body: SGCharacterBody2D


func _ready() -> void:
	_body = _resolve_body()
	assert(_body != null, "ProjectileMovementComponent requires an SGCharacterBody2D (set body_path or parent it under one).")
	_cache_fixed_point_values()


## Converts the human-friendly float exports to fixed-point per-tick values.
## Called once in _ready(); call again manually if you live-tweak exports at
## runtime in a debug build.
func _cache_fixed_point_values() -> void:
	var tick_fp: int = SGFixed.from_int(maxi(1, tick_rate))
	# units/sec -> units/tick
	_terminal_velocity_fp = SGFixed.div(SGFixed.from_float(terminal_velocity), tick_fp)
	_despawn_distance_fp = SGFixed.from_float(despawn_distance)
	# seconds -> whole ticks (ceil: never expire EARLIER than the tuned time).
	_lifespan_ticks = 0 if lifespan_seconds <= 0.0 else maxi(1, ceili(lifespan_seconds * float(maxi(1, tick_rate))))
	# stall floor: units/sec -> units/tick (fixed-point); stall window: seconds -> ticks.
	_stationary_speed_fp = SGFixed.div(SGFixed.from_float(maxf(0.0, stationary_speed_threshold)), tick_fp)
	_stationary_lifespan_ticks = 0 if stationary_lifespan_seconds <= 0.0 else maxi(1, ceili(stationary_lifespan_seconds * float(maxi(1, tick_rate))))
	_rally_growth_fp = SGFixed.from_float(maxf(1.0, rally_speed_growth))


## Arms the projectile. EXACT spawner contract (SpellCasterComponent calls this):
##  - [param velocity_x_fp] / [param velocity_y_fp]: fixed-point sim units per
##    TICK (the spawner already divided the spell's units/sec speed by tick_rate).
##  - [param bounciness_fp]: fixed-point speed multiplier applied on each
##    reflection (ONE = 65536 = lossless bounce).
## The terminal-velocity cap is applied at the top of every tick, so an
## over-cap launch is clamped before its first move.
func launch(velocity_x_fp: int, velocity_y_fp: int, bounciness_fp: int = 65536) -> void:
	_velocity_x = velocity_x_fp
	_velocity_y = velocity_y_fp
	_bounciness = bounciness_fp
	_age_ticks = 0
	_stationary_ticks = 0  # a (re)launch is fresh motion — never inherit a prior stall

	# Snap visuals to the spawn point NOW: the spawner has already teleported
	# the body, but the first _network_process (and so the first state_updated)
	# is a whole tick away — without this emit the visual rig renders a frame at
	# the scene-default origin (the "fireball flashes at arena center" bug).
	var pos: SGFixedVector2 = _body.fixed_position
	state_updated.emit(pos.x, pos.y)


# =====================================================================
# ROLLBACK CONTRACT
# =====================================================================

## Advances the simulation by exactly one tick. Projectiles take no input, so
## [param _input] is ignored ({} from the tick driver). Deterministic: same
## prior state = bit-identical next state on every machine.
func _network_process(_input: Dictionary) -> void:
	_apply_homing()
	_apply_speed_cap()

	# move_and_collide() takes the motion for THIS call — our per-tick velocity —
	# and stops at the first deterministic contact, returning the collision info.
	var motion: SGFixedVector2 = SGFixed.vector2(_velocity_x, _velocity_y)
	# SHIELD-RALLY SIM SLOW: a stray ball crawls during a shield rally hold so it can't cross into a frozen
	# wizard mid-rally. Scale ONLY this tick's move (stored velocity stays true for the cap/stall/homing
	# above) and burn one tick — resetting the factor when it lapses so the next slow starts clean.
	if _sim_slow_ticks > 0:
		motion.x = SGFixed.mul(motion.x, _sim_slow_factor_fp)
		motion.y = SGFixed.mul(motion.y, _sim_slow_factor_fp)
		_sim_slow_ticks -= 1
		if _sim_slow_ticks == 0:
			_sim_slow_factor_fp = SGFixed.ONE
	var collision: SGKinematicCollision2D = _body.move_and_collide(motion)

	if collision != null:
		# Deterministic reflection off the contact normal, in fixed point:
		# SGFixedVector2.bounce(n) computes v' = v - 2(v·n)n. Then scale by
		# bounciness (fixed-point scalar multiply). The remainder of this
		# tick's motion is intentionally NOT re-applied — the projectile
		# resumes at the contact point next tick (simple and deterministic).
		var normal: SGFixedVector2 = collision.get_normal()
		var reflected: SGFixedVector2 = SGFixed.vector2(_velocity_x, _velocity_y).bounce(normal)
		reflected.imul(_bounciness)
		_velocity_x = reflected.x
		_velocity_y = reflected.y
		_apply_speed_cap()
		bounced.emit(normal.x, normal.y)

	var pos: SGFixedVector2 = _body.fixed_position
	state_updated.emit(pos.x, pos.y)

	# STUCK CLEANUP: count consecutive ticks below the stall floor (the post-bounce/cap
	# velocity for THIS tick). A homing bolt that bled its speed turning crawls to a near-
	# stop and would otherwise sit out its full lifespan; despawn it once stalled long
	# enough. A barrier-captured ball is frozen at 0 but kept alive each hold tick, so it
	# never trips this. Pure fixed-point (length() = fixed sqrt) — deterministic.
	if _stationary_lifespan_ticks > 0 \
			and SGFixed.vector2(_velocity_x, _velocity_y).length() < _stationary_speed_fp:
		_stationary_ticks += 1
	else:
		_stationary_ticks = 0

	# Expiry checks (rally hygiene). Deterministic: position + tick age + stall only.
	_age_ticks += 1
	if absi(pos.x) > _despawn_distance_fp or absi(pos.y) > _despawn_distance_fp:
		expired.emit()
	elif _lifespan_ticks > 0 and _age_ticks >= _lifespan_ticks:
		expired.emit()
	elif _stationary_lifespan_ticks > 0 and _stationary_ticks >= _stationary_lifespan_ticks:
		expired.emit()


## Arms (or clears: target null / strength 0) gentle homing toward a wizard.
## strength_fp is the card's 0..ONE homing attribute; it converts ONCE here
## to a per-tick steering blend (strength x 3.0 / tick_rate — at 20% the
## bolt bends noticeably across a court length without aimbotting).
func set_homing(target: Node, strength_fp: int) -> void:
	if target == null or strength_fp <= 0:
		_homing_target = null
		_homing_blend_fp = 0
		return
	_homing_target = target
	_homing_blend_fp = SGFixed.div(
			SGFixed.mul(strength_fp, SGFixed.from_float(3.0)),
			SGFixed.from_int(maxi(1, tick_rate)))


## One steering step: rotate the velocity a blend-fraction toward the target
## while preserving speed magnitude (the cap re-clamps anyway). Pure
## fixed-point int math; a freed/missing target simply flies straight.
func _apply_homing() -> void:
	if _homing_blend_fp <= 0 or _homing_target == null or not is_instance_valid(_homing_target):
		return
	var my_pos: SGFixedVector2 = _body.get_global_fixed_position()
	var target_pos: SGFixedVector2 = _homing_target.get_global_fixed_position()
	var vel: SGFixedVector2 = SGFixed.vector2(_velocity_x, _velocity_y)
	var speed: int = vel.length()
	if speed <= 0:
		return
	var desired: SGFixedVector2 = SGFixed.vector2(
			target_pos.x - my_pos.x, target_pos.y - my_pos.y).normalized()
	desired.imul(speed)
	_velocity_x += SGFixed.mul(desired.x - _velocity_x, _homing_blend_fp)
	_velocity_y += SGFixed.mul(desired.y - _velocity_y, _homing_blend_fp)


## Re-bases the lifespan at runtime (ATTACK cards override the scene default
## from CardResource.lifetime AFTER _ready() has cached — live-recache rule).
func set_lifespan_seconds(seconds: float) -> void:
	lifespan_seconds = seconds
	_lifespan_ticks = 0 if seconds <= 0.0 else maxi(1, ceili(seconds * float(maxi(1, tick_rate))))


## Re-bases the lifespan directly in whole TICKS. The rollback spawn payload carries
## ticks (not seconds), so the window is bit-identical on both peers with no float
## round-trip. 0 = unlimited (despawn_distance only).
func set_lifespan_ticks(ticks: int) -> void:
	_lifespan_ticks = maxi(0, ticks)
	lifespan_seconds = float(_lifespan_ticks) / float(maxi(1, tick_rate))


## COUNTER REDIRECT (Manifesto: counter returns the ball at 2x speed toward
## its original caster): reverses the velocity vector and scales it by the
## fixed-point multiplier, then restarts the lifespan clock so the returned
## ball lives long enough to cross back. The terminal-velocity cap bounds
## stacked multipliers. Pure fixed-point int math — deterministic.
func redirect(speed_multiplier_fp: int) -> void:
	_velocity_x = -SGFixed.mul(_velocity_x, speed_multiplier_fp)
	_velocity_y = -SGFixed.mul(_velocity_y, speed_multiplier_fp)
	_age_ticks = 0
	_stationary_ticks = 0  # the redirected ball flies anew — clear any stall it accrued
	_apply_speed_cap()


## Resets the stuck-cleanup counter. A barrier holding a CAPTURED ball freezes it at
## velocity 0 ON PURPOSE; it calls this each hold tick so the stall despawn never reclaims
## a ball that is being intentionally held. Deterministic (the barrier ticks in lockstep).
func keep_alive() -> void:
	_stationary_ticks = 0


## SHIELD-RALLY SIM SLOW: scale this projectile's per-tick MOVE distance by [param factor_fp] (< ONE) for at
## least [param ttl] ticks, so a stray ball crawls during a shield rally hold and can't reach a frozen
## wizard. A capturing BarrierController re-pushes it every rally hold tick (TTL 2 spans the cross-node
## ordering latency), so the slow lapses ~1 tick after release. MAX-composes the TTL (overlapping pushes
## never shorten it) and takes the DEEPEST factor (mini), so two simultaneous rallies can't net to a
## weaker slow. Stored velocity is untouched — only the move is scaled. Deterministic ints, identical on
## every peer; saved as "ssk"/"ssf".
func apply_sim_slow(factor_fp: int, ttl: int = 2) -> void:
	_sim_slow_ticks = maxi(_sim_slow_ticks, maxi(1, ttl))
	_sim_slow_factor_fp = mini(_sim_slow_factor_fp, clampi(factor_fp, 0, SGFixed.ONE))


## Current fixed-point velocity components, sim units per TICK. Read-only
## accessors for gameplay readers (e.g. the AI threat scan) — sim state stays
## owned by this component.
func get_velocity_x() -> int:
	return _velocity_x


func get_velocity_y() -> int:
	return _velocity_y


## SHIELD-REFLECT RALLY: this ball's current rally speed multiplier (fixed-point) — rally_speed_growth
## raised to the reflect count, bounded by max_rally_reflects. The escalating speed cap (_apply_speed_cap)
## AND the BarrierController's release both multiply by this, so a rallied ball speeds up per reflect.
## Deterministic: a small bounded loop of SGFixed.mul, identical on every peer.
func rally_speed_mult_fp() -> int:
	var n: int = clampi(_reflect_count, 0, maxi(0, max_rally_reflects))
	var result: int = SGFixed.ONE
	for _i in n:
		result = SGFixed.mul(result, _rally_growth_fp)
	return result


## SHIELD-REFLECT RALLY: how many barrier reflects this ball has taken (read by the barrier at capture
## to scale the hold, and by the cap above). Duck-typed surface BarrierController calls.
func get_reflect_count() -> int:
	return _reflect_count


## SHIELD-REFLECT RALLY: record one more reflect of this ball — called by BarrierController at release.
func add_reflect() -> void:
	_reflect_count += 1


## Snapshot of all mutable simulation state. Ints only (fixed-point), never
## floats/objects — required for rollback hashing and serialization.
func _save_state() -> Dictionary:
	var pos: SGFixedVector2 = _body.fixed_position
	return {
		"px": pos.x,
		"py": pos.y,
		"vx": _velocity_x,
		"vy": _velocity_y,
		"b": _bounciness,
		"age": _age_ticks,
		"hb": _homing_blend_fp,
		"sk": _stationary_ticks,
		"rc": _reflect_count,
		"ssk": _sim_slow_ticks,
		"ssf": _sim_slow_factor_fp,
	}


## Restores a snapshot produced by _save_state(). Teleports the body, so it
## re-syncs the physics engine, then re-emits state_updated so the visual
## bridge snaps to the restored position.
func _load_state(state: Dictionary) -> void:
	_velocity_x = int(state.get("vx", 0))
	_velocity_y = int(state.get("vy", 0))
	_bounciness = int(state.get("b", SGFixed.ONE))
	_age_ticks = int(state.get("age", 0))
	_homing_blend_fp = int(state.get("hb", 0))
	_stationary_ticks = int(state.get("sk", 0))
	_reflect_count = int(state.get("rc", 0))
	_sim_slow_ticks = int(state.get("ssk", 0))
	_sim_slow_factor_fp = int(state.get("ssf", SGFixed.ONE))

	var pos: SGFixedVector2 = _body.fixed_position
	pos.x = int(state.get("px", 0))
	pos.y = int(state.get("py", 0))
	_body.fixed_position = pos

	# Mandatory after directly writing fixed_position: keep the SG physics
	# broadphase in agreement with the node.
	_body.sync_to_physics_engine()

	state_updated.emit(pos.x, pos.y)


# =====================================================================
# Internals
# =====================================================================

## Rescales the velocity vector to the terminal-velocity cap when its magnitude
## exceeds it, preserving direction. Pure fixed-point: SGFixedVector2.length()
## (fixed sqrt of the fixed dot product) and normalized() + scalar imul().
func _apply_speed_cap() -> void:
	# SHIELD-REFLECT RALLY: the cap grows with this ball's reflect count so a rallied ball accelerates
	# past the base ceiling (bounded by max_rally_reflects). A never-reflected ball uses the base cap.
	var cap: int = SGFixed.mul(_terminal_velocity_fp, rally_speed_mult_fp())
	var vel: SGFixedVector2 = SGFixed.vector2(_velocity_x, _velocity_y)
	var speed: int = vel.length()
	if speed <= cap:
		return

	var capped: SGFixedVector2 = vel.normalized()
	capped.imul(cap)
	_velocity_x = capped.x
	_velocity_y = capped.y


func _resolve_body() -> SGCharacterBody2D:
	if not body_path.is_empty():
		return get_node_or_null(body_path) as SGCharacterBody2D
	return get_parent() as SGCharacterBody2D
