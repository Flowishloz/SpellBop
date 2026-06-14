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

# --- Cached fixed-point per-tick values (computed once in _ready()) ---
var _terminal_velocity_fp: int = 0   # speed cap, units/tick (fixed-point)
var _despawn_distance_fp: int = 0    # court bound, fixed-point sim units
var _lifespan_ticks: int = 0         # max flight time, whole ticks (0 = off)

# Ticks since launch() — deterministic sim state (saved/loaded for rollback).
var _age_ticks: int = 0

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

	# Expiry checks (rally hygiene). Deterministic: position + tick age only.
	_age_ticks += 1
	if absi(pos.x) > _despawn_distance_fp or absi(pos.y) > _despawn_distance_fp:
		expired.emit()
	elif _lifespan_ticks > 0 and _age_ticks >= _lifespan_ticks:
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


## COUNTER REDIRECT (Manifesto: counter returns the ball at 2x speed toward
## its original caster): reverses the velocity vector and scales it by the
## fixed-point multiplier, then restarts the lifespan clock so the returned
## ball lives long enough to cross back. The terminal-velocity cap bounds
## stacked multipliers. Pure fixed-point int math — deterministic.
func redirect(speed_multiplier_fp: int) -> void:
	_velocity_x = -SGFixed.mul(_velocity_x, speed_multiplier_fp)
	_velocity_y = -SGFixed.mul(_velocity_y, speed_multiplier_fp)
	_age_ticks = 0
	_apply_speed_cap()


## Current fixed-point velocity components, sim units per TICK. Read-only
## accessors for gameplay readers (e.g. the AI threat scan) — sim state stays
## owned by this component.
func get_velocity_x() -> int:
	return _velocity_x


func get_velocity_y() -> int:
	return _velocity_y


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
	var vel: SGFixedVector2 = SGFixed.vector2(_velocity_x, _velocity_y)
	var speed: int = vel.length()
	if speed <= _terminal_velocity_fp:
		return

	var capped: SGFixedVector2 = vel.normalized()
	capped.imul(_terminal_velocity_fp)
	_velocity_x = capped.x
	_velocity_y = capped.y


func _resolve_body() -> SGCharacterBody2D:
	if not body_path.is_empty():
		return get_node_or_null(body_path) as SGCharacterBody2D
	return get_parent() as SGCharacterBody2D
