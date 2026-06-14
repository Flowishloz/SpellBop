## fireball_controller.gd — Thin coordinator for the Base Fireball projectile.
##
## LOCAL TICK DRIVER — this _physics_process loop is replaced by the rollback
## SyncManager in a later sprint. Nothing in here should grow gameplay logic;
## it only (1) advances the local tick counter and (2) hands an empty input to
## the deterministic ProjectileMovementComponent (projectiles take no input).
##
## All gameplay math is fixed-point (SG Physics 2D). This node IS the
## deterministic body (SGCharacterBody2D); its components do the work:
##   - ProjectileMovementComponent: deterministic ballistic mover + bounce.
##   - VisualBridgeComponent:       maps sim X/Y -> visual X/Z (reads sim, never writes).
##
## Recommended scene shape (built by the Creative Director in the editor):
##   FireballController (SGCharacterBody2D) [+ SGCollisionShape2D (SGCircleShape2D)]
##     ├─ ProjectileMovementComponent
##     └─ VisualBridgeComponent  (visual_root -> the fireball's Node3D rig)
##
## Spawned and armed by SpellCasterComponent: it positions the body (teleport +
## sync_to_physics_engine), then calls launch() with fixed-point per-TICK
## velocity and bounciness — see ProjectileMovementComponent for the contract.
class_name FireballController
extends SGCharacterBody2D

## Path to the ProjectileMovementComponent child. Leave empty to auto-find by class.
@export var movement_path: NodePath

## When false, the local tick driver idles (useful for menus/cutscenes, and
## flipped off permanently once the rollback SyncManager takes over driving).
@export var local_tick_driver_enabled: bool = true

## Current simulation tick (int). Owned by the local driver for now; the
## rollback framework will own tick counting later.
var current_tick: int = 0

## Damage dealt on a wizard hit. Set by SpellCasterComponent from
## SpellResource.damage at spawn (immutable per projectile thereafter).
var damage: int = 1

## FROST PAYLOAD (the Counter's ice wave): when slow_ticks > 0, a struck
## wizard is slowed to slow_scale_fp for that many ticks instead of / in
## addition to damage. Armed by CardCasterComponent at spawn.
var slow_ticks: int = 0
var slow_scale_fp: int = 65536

## BARRIER BREAKER (the Spark Bolt): a barrier that would capture this ball
## shatters instead, and the ball SPLITS (split_on_barrier). Armed by
## CardCasterComponent from CardResource.barrier_breaker.
var splits_on_barrier: bool = false

var _movement: ProjectileMovementComponent
var _hit_detection: HitDetectionComponent


func _ready() -> void:
	# HARDCODED COLLISION LAYERS (Sprint 2 hotfix) — the editor UI fails to
	# persist SG Physics 2D layer assignments, leaving bodies on the plugin
	# default (layer 1 / mask 1). That default made the fireball spawn
	# overlapping its caster (also layer 1) and bounce backwards on tick 0.
	# DO NOT move this back to the Inspector. See scripts/physics_layers.gd.
	# Fireball lives on the projectile layer and ONLY sees walls — it
	# explicitly ignores players (damage will be an Area-based system in a
	# later sprint) and other projectiles.
	collision_layer = PhysicsLayers.LAYER_PROJECTILES
	collision_mask = PhysicsLayers.LAYER_WALLS

	if not movement_path.is_empty():
		_movement = get_node_or_null(movement_path) as ProjectileMovementComponent
	if _movement == null:
		for child in get_children():
			if child is ProjectileMovementComponent:
				_movement = child
				break
	assert(_movement != null, "FireballController: missing ProjectileMovementComponent child.")

	# Court-bound cleanup: free the projectile when the sim says it left play.
	# NOTE: local lifecycle only — the rollback SyncManager's despawn() owns
	# projectile lifecycle in a later sprint (despawn must be rewindable).
	_movement.expired.connect(_on_expired)
	_movement.bounced.connect(_on_bounced)

	# Optional wizard-hit scan (deterministic overlap query, no physics mask).
	for child in get_children():
		if child is HitDetectionComponent:
			_hit_detection = child
			_hit_detection.hit.connect(_on_hit)
			break


## LOCAL TICK DRIVER — replaced by the rollback SyncManager in a later sprint.
func _physics_process(_delta: float) -> void:
	if not local_tick_driver_enabled:
		return

	current_tick += 1

	# Projectiles take no input: always simulate with the canonical empty input.
	# Order matters (deterministic contract): move first, THEN scan for hits at
	# the post-move position.
	_movement._network_process({})
	if _hit_detection != null:
		_hit_detection._network_process({})


## Passthrough to the movement component's launch contract (fixed-point sim
## units per TICK + fixed-point bounciness; ONE = 65536 = lossless bounce).
## This is the entry point SpellCasterComponent calls on the spawned scene root.
func launch(velocity_x_fp: int, velocity_y_fp: int, bounciness_fp: int = 65536) -> void:
	_movement.launch(velocity_x_fp, velocity_y_fp, bounciness_fp)


## Read-only velocity accessors (fixed-point, sim units per TICK) — the duck-
## typed surface gameplay readers use (e.g. AIBrainComponent's threat scan).
func get_velocity_x() -> int:
	return _movement.get_velocity_x()


func get_velocity_y() -> int:
	return _movement.get_velocity_y()


func _on_expired() -> void:
	# queue_free is idempotent; repeated expired emits before the free lands
	# are harmless. SyncManager.despawn() replaces this in the rollback sprint.
	queue_free()


## Bounce presentation: an X-facing normal means one of the invisible side
## walls — pulse it visible for a beat (Creative Director).
func _on_bounced(normal_x: int, _normal_y: int) -> void:
	if normal_x == 0:
		return
	var visual: Node3D = get_node_or_null(^"Visual") as Node3D
	if visual != null:
		BurstFX.spawn_wall_pulse(get_parent(), visual.global_position, signi(normal_x))
		Sfx.play(&"wall_bounce")


func _on_hit(body: Node) -> void:
	# Deal the payload to the struck wizard via ITS public APIs (never poke
	# its internals), then this ball is spent. Damage and frost are both
	# optional — an ice wave is damage 0 + slow, a fireball is damage + no slow.
	if damage > 0 and body.has_method(&"apply_damage"):
		body.apply_damage(damage)
	if slow_ticks > 0 and body.has_method(&"apply_slow"):
		body.apply_slow(slow_ticks, slow_scale_fp)
		Sfx.play(&"frost_hit")
	_spawn_impact_burst()
	queue_free()


## IMPACT FX (pure visual): a burst that CARRIES THE BALL'S MOMENTUM — the
## spray continues along the flight direction (the water-balloon read),
## clearly distinct from the stationary charge sparks. Frost waves spray icy
## blue; fireballs spray fire.
func _spawn_impact_burst() -> void:
	var visual: Node3D = get_node_or_null(^"Visual") as Node3D
	if visual == null:
		return
	# fixed units/tick -> meters/second: /65536 (fixed) * 60 (ticks) * 0.01 (scale)
	var vel_3d := Vector3(
			get_velocity_x() / 65536.0 * 0.6,
			0.15,
			get_velocity_y() / 65536.0 * 0.6)
	var color: Color = Color(0.55, 0.8, 1.0, 0.95) if slow_ticks > 0 else Color(1.0, 0.55, 0.2, 0.95)
	BurstFX.spawn(get_parent(), visual.global_position, vel_3d,
			color, 26, maxf(3.0, vel_3d.length()))


# =====================================================================
# ROLLBACK CONTRACT (called locally for now, by SyncManager later)
# =====================================================================

## Routes the caster's friendly-fire exclusion to the hit scan (duck-typed
## entry point SpellCasterComponent calls before launch()).
func set_hit_source(body: Node) -> void:
	if _hit_detection != null:
		_hit_detection.source = body


## The wizard this projectile cannot hit (its caster, or the wizard who last
## redirected it). Barriers read this to tell friendly balls from hostile.
func get_hit_source() -> Node:
	return _hit_detection.source if _hit_detection != null else null


## HOMING (duck-typed entry point CardCasterComponent calls at spawn, and
## BarrierController calls with (null, 0) to clear on a reflected release).
func set_homing(target: Node, strength_fp: int) -> void:
	_movement.set_homing(target, strength_fp)


## SHIELD-BREAK SPLIT (BarrierController calls this instead of capturing a
## barrier_breaker ball): spawn [param count] smaller copies continuing
## down-court toward [param dir_sign] at this ball's speed, each carrying
## [param damage_each], fanned apart laterally — then this ball is spent.
## Duplicated copies run _ready() fresh on add (layers re-hardcode, comps
## re-resolve); only the payload fields are re-armed here.
func split_on_barrier(dir_sign: int, count: int = 2, damage_each: int = 1) -> void:
	var speed_fp: int = absi(get_velocity_y())
	if speed_fp == 0:
		speed_fp = absi(get_velocity_x())
	var parent: Node = get_parent()
	var my_pos: SGFixedVector2 = get_global_fixed_position()
	var lateral_fp: int = SGFixed.div(SGFixed.from_float(190.0), SGFixed.from_int(60))
	for i in count:
		var fan_sign: int = 1 if i % 2 == 0 else -1
		var shard: Node = duplicate()
		parent.add_child(shard)
		# Keep each shard's full radius (BASE_RADIUS_UNITS * 0.75) inside the lane
		# even when the ±28 fan pushes it outward from a parent already at the
		# wall — clamp AFTER adding the fan offset, per shard.
		var shard_x: int = MovementComponent.clamp_spawn_x_fp(
				my_pos.x + SGFixed.from_float(28.0) * fan_sign,
				SGFixed.from_float(BASE_RADIUS_UNITS * 0.75),
				_arena_bound_fp())
		shard.set_global_fixed_position(SGFixed.vector2(shard_x, my_pos.y))
		shard.sync_to_physics_engine()
		shard.collision_mask = collision_mask
		shard.damage = damage_each
		shard.splits_on_barrier = false
		shard.set_hit_source(get_hit_source())
		shard.set_homing(null, 0)
		shard.apply_size(BASE_RADIUS_UNITS * 0.75)
		shard.launch(fan_sign * lateral_fp, dir_sign * speed_fp, SGFixed.ONE)
	queue_free()


## COUNTER REDIRECT (duck-typed entry point CounterFieldComponent calls):
## reverses the ball back toward its original caster at the multiplied speed
## and hands the hit exclusion to the countering wizard — the redirected ball
## can now strike the wizard who originally threw it.
func redirect(new_source: Node, speed_multiplier_fp: int) -> void:
	_movement.redirect(speed_multiplier_fp)
	set_hit_source(new_source)


## The lane half-width (fixed-point) shards clamp to. A projectile owns no
## MovementComponent, so read the bound from a wizard's mover — deterministic:
## the "wizards" group iterates in scene-tree order, identical on every peer
## (the same group-walk _find_enemy_wizard / hit detection already rely on).
## Falls back to the match_arena default only if no wizard mover is found.
func _arena_bound_fp() -> int:
	for wizard in get_tree().get_nodes_in_group(&"wizards"):
		for child in wizard.get_children():
			if child is MovementComponent:
				return child.arena_half_width_fp()
	return SGFixed.from_float(400.0)


## The collider radius this scene was AUTHORED at (SGCircleShape2D 24 units,
## Sprite3D/shadow scaled to a 0.48 m orb). apply_size() scales relative to it.
const BASE_RADIUS_UNITS: float = 24.0


## Sizes this projectile from spell data (CardResource.projectile_size).
## Call AFTER add_child + positioning. The scene's shape sub-resource is
## DUPLICATED before mutating — instanced scenes share sub-resources, so
## writing the shared radius would silently resize every live fireball.
func apply_size(radius_units: float) -> void:
	if radius_units <= 0.0 or is_equal_approx(radius_units, BASE_RADIUS_UNITS):
		return
	for child in get_children():
		if child is SGCollisionShape2D and child.shape != null:
			var shape: SGShape2D = child.shape.duplicate()
			shape.set(&"radius", SGFixed.from_float(radius_units))
			child.shape = shape
			break
	sync_to_physics_engine()
	if _hit_detection != null:
		_hit_detection.set_radius_units(radius_units)
	# Presentation: scale the orb art and its drop shadow to match.
	var factor: float = radius_units / BASE_RADIUS_UNITS
	var visual: Node3D = get_node_or_null(^"Visual") as Node3D
	if visual != null:
		visual.scale = Vector3.ONE * factor
	var shadow: Node3D = get_node_or_null(^"ShadowSprite") as Node3D
	if shadow != null:
		shadow.scale = Vector3.ONE * factor


## Advances all simulated components by one tick. Mirrors the contract the
## rollback framework calls on network-synced nodes.
func _network_process(input: Dictionary) -> void:
	_movement._network_process(input)
	if _hit_detection != null:
		_hit_detection._network_process(input)


## Aggregates component states keyed by component name, plus the tick counter.
## Leaf values are ints only (fixed-point) — rollback-serialization safe.
func _save_state() -> Dictionary:
	return {
		"tick": current_tick,
		"movement": _movement._save_state(),
	}


## Restores an aggregate snapshot produced by _save_state().
func _load_state(state: Dictionary) -> void:
	current_tick = int(state.get("tick", current_tick))
	if state.has("movement"):
		_movement._load_state(state["movement"])
