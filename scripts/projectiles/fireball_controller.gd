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

## MAX-CHARGE ICE BREAKER (Phase 1): a fully-charged (gauge 3) base fireball
## SHATTERS the Icey Retort frost wave on contact and powers through it. Armed by
## SpellCasterComponent when the fired charge level is 3.
var shatters_ice: bool = false

## WALL-PULSE OPT-OUT (Sprint 20): the wide Icey Retort frost wave is court-wide
## and travels straight — it must never spew side-wall hit pulses if a corner
## clips a barrier/wall (the Creative Director's "pulses next to the wave's
## sides" graphical error). Point projectiles (fireball/spark bolt) keep it true
## so a genuine side-wall ricochet still pulses AT the wall face.
var emits_wall_pulse: bool = true

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

	# ROLLBACK (Sprint 22): when a netplay match is live the rollback SyncManager
	# drives this projectile (via the "network_sync" group) — the local
	# _physics_process tick driver must idle so the entity isn't double-stepped.
	# Single-player keeps self-driving. (SpawnManager re-sorts the group right
	# after add_child, so joining here in _ready is enough.)
	if SyncManager != null and SyncManager.started:
		local_tick_driver_enabled = false
		add_to_group(&"network_sync")


## LOCAL TICK DRIVER — replaced by the rollback SyncManager in a later sprint.
func _physics_process(_delta: float) -> void:
	if not local_tick_driver_enabled:
		return

	current_tick += 1

	# Projectiles take no input: always simulate with the canonical empty input.
	# Order matters (deterministic contract): move first, THEN scan for hits at
	# the post-move position.
	_movement._network_process({})
	if shatters_ice:
		_scan_ice_shatter()
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
	# Idempotent: repeated expired emits before the free lands are harmless.
	# Rewindable under rollback (SyncManager.despawn), queue_free in single-player.
	_despawn()


## Bounce presentation: an X-facing normal means one of the side walls — pulse it
## visible for a beat (Creative Director). Sprint 20: the pulse spawns ON THE WALL
## FACE (the ball's centre offset out by its own half-extent), not at the ball's
## centre, so the flash always reads exactly at the glowing perimeter — and a wide
## frost wave opts out entirely (emits_wall_pulse) so it never pulses mid-court.
func _on_bounced(normal_x: int, _normal_y: int) -> void:
	if normal_x == 0 or not emits_wall_pulse:
		return
	var visual: Node3D = get_node_or_null(^"Visual") as Node3D
	if visual != null:
		# Push the flash from the ball centre out to the struck wall face: the
		# normal points INTO the court, so the wall is in the -normal direction.
		var half_x_m: float = get_collider_half_extents().x / 65536.0 * 0.01
		var face: Vector3 = visual.global_position
		face.x -= float(signi(normal_x)) * half_x_m
		BurstFX.spawn_wall_pulse(get_parent(), face, signi(normal_x))
		Sfx.play(&"wall_bounce")


func _on_hit(body: Node) -> void:
	# Deal the payload to the struck wizard via ITS public APIs (never poke its
	# internals). Damage and frost are both optional — an ice wave is damage 0 + slow,
	# a fireball is damage + no slow. The HitDetectionComponent._has_hit latch (sim
	# state) guarantees this fires at most once per ball, and re-fires identically on a
	# rollback re-sim.
	if damage > 0 and body.has_method(&"apply_damage"):
		body.apply_damage(damage)
	if slow_ticks > 0 and body.has_method(&"apply_slow"):
		body.apply_slow(slow_ticks, slow_scale_fp)
	# Presentation (frost sfx, impact burst) fires only on the LIVE hit, never on a
	# rollback re-sim (which would otherwise stack duplicate bursts + sounds). The hit
	# itself is rollback-safe now that the _has_hit latch is saved/loaded (see
	# _save_state): a rollback restores the latch, the re-sim re-fires the hit, and the
	# damage stays in lockstep across peers.
	if SyncManager == null or not SyncManager.is_in_rollback():
		if slow_ticks > 0:
			Sfx.play(&"frost_hit")
		_spawn_impact_burst()


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


## MAX-CHARGE ICE SHATTER (Phase 1): a fully-charged fireball scans its sibling
## projectiles for the ENEMY's frost wave (Icey Retort) and SHATTERS it on
## overlap — reusing the broken-defense glass burst — then powers through (this
## ball is NOT consumed). Pure fixed-point overlap test, widened by both bodies'
## per-tick Y step so a fast head-on closing speed can't tunnel between scans.
func _scan_ice_shatter() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	var my_pos: SGFixedVector2 = get_global_fixed_position()
	var my_half: SGFixedVector2 = get_collider_half_extents()
	var my_step: int = absi(get_velocity_y())
	var my_source: Node = get_hit_source()
	for child in parent.get_children():
		if child == self or not ("slow_ticks" in child) or child.slow_ticks <= 0:
			continue
		if not child.has_method(&"get_collider_half_extents") or not child.has_method(&"get_velocity_y"):
			continue
		# Never shatter our OWN frost (friendly); only the enemy's counter wave.
		if child.has_method(&"get_hit_source") and child.get_hit_source() == my_source:
			continue
		var their_pos: SGFixedVector2 = child.get_global_fixed_position()
		var their_half: SGFixedVector2 = child.get_collider_half_extents()
		var band_x: int = my_half.x + their_half.x
		var band_y: int = my_half.y + their_half.y + my_step + absi(child.get_velocity_y())
		if absi(my_pos.x - their_pos.x) < band_x and absi(my_pos.y - their_pos.y) < band_y:
			child.shatter_ice()
			return  # one shatter per tick; this ball powers through


## The body's collider half-extents (fixed-point): a circle returns
## (radius, radius); a rectangle (the ice wave) returns (extents_x, extents_y).
## Read by the ice-shatter overlap test on both bodies.
func get_collider_half_extents() -> SGFixedVector2:
	for child in get_children():
		if child is SGCollisionShape2D and child.shape != null:
			var shape: SGShape2D = child.shape
			var ex: Variant = shape.get(&"extents_x")
			if ex != null:
				return SGFixed.vector2(int(ex), int(shape.get(&"extents_y")))
			var r: Variant = shape.get(&"radius")
			if r != null:
				return SGFixed.vector2(int(r), int(r))
	return SGFixed.vector2(0, 0)


## SHATTER this frost wave: the broken-defense glass burst + shatter SFX, then
## the wave is gone (called by a max-charge fireball that broke through it).
func shatter_ice() -> void:
	var visual: Node3D = get_node_or_null(^"Visual") as Node3D
	if visual != null:
		BurstFX.spawn(get_parent(), visual.global_position + Vector3(0, 0.3, 0),
				Vector3.UP, Color(0.78, 0.95, 1.0, 0.95), 34, 4.4, 0.06, 84.0)
	Sfx.play(&"shield_shatter")
	_despawn()


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
	_despawn()


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
	# DESPAWN-WINDOW GUARD (Sprint 22 netplay crash fix): after SyncManager.despawn() a
	# ball is removed from the tree but kept in the rollback "retire" buffer for ~20 ticks
	# (so a rollback can restore it). During that window it is DETACHED yet can still be
	# group-driven by SyncManager — and the hit scan's get_tree().get_nodes_in_group()
	# then crashes on a null tree. Skip any tick while detached: a despawned ball is out
	# of the live sim, and a rollback that restores it re-adds it to the tree first.
	if not is_inside_tree():
		return
	_movement._network_process(input)
	if shatters_ice:
		_scan_ice_shatter()
	if _hit_detection != null:
		_hit_detection._network_process(input)


## Snapshots the tick counter plus each stateful child under a STABLE key ("movement" /
## "hit") — stable so it never depends on a scene's node names and the headless suites can
## assert on it directly. Leaf values are ints only (fixed-point) — rollback-safe. CRITICAL:
## the HitDetectionComponent's `_has_hit` latch MUST be saved ("hit") — omitting it meant the
## latch never rolled back, so a rollback past a hit left it stuck true, the re-sim never
## re-fired the hit, the cross-node damage was reverted-but-not-reapplied -> health desync ->
## netplay crash. (The fireball's only stateful children are the mover and the hit scan.)
func _save_state() -> Dictionary:
	var state: Dictionary = {"tick": current_tick}
	if _movement != null:
		state["movement"] = _movement._save_state()
	if _hit_detection != null:
		state["hit"] = _hit_detection._save_state()
	return state


## Restores a snapshot produced by _save_state().
func _load_state(state: Dictionary) -> void:
	current_tick = int(state.get("tick", current_tick))
	if _movement != null and state.has("movement"):
		_movement._load_state(state["movement"])
	if _hit_detection != null and state.has("hit"):
		_hit_detection._load_state(state["hit"])


## ROLLBACK SPAWN (Sprint 22): the deterministic, rewindable initializer. Called
## by SyncManager.spawn() on the spawn tick AND re-called identically on every
## rollback re-spawn, so it is PURE SETUP from an int/fixed-point-only payload (no
## node refs except the hit-source, resolved by its stable scene path). It does
## exactly what SpellCasterComponent used to do inline after add_child + launch().
func _network_spawn(data: Dictionary) -> void:
	set_global_fixed_position(SGFixed.vector2(int(data.get("px", 0)), int(data.get("py", 0))))
	sync_to_physics_engine()
	if data.has("mask"):
		collision_mask = int(data["mask"])
	damage = int(data.get("dmg", 1))
	shatters_ice = int(data.get("shat", 0)) == 1
	slow_ticks = int(data.get("slt", 0))
	slow_scale_fp = int(data.get("sls", SGFixed.ONE))
	splits_on_barrier = int(data.get("split", 0)) == 1
	if data.has("pulse"):
		emits_wall_pulse = int(data["pulse"]) == 1
	if data.has("size"):
		apply_size(SGFixed.to_float(int(data["size"])))
	var src_path: String = String(data.get("src", ""))
	if src_path != "":
		var src: Node = get_node_or_null(NodePath(src_path))
		if src != null:
			set_hit_source(src)
	launch(int(data.get("vx", 0)), int(data.get("vy", 0)), int(data.get("b", SGFixed.ONE)))


## Rewindable free: under a live rollback match this routes through
## SyncManager.despawn() (the despawn rolls back); otherwise (single-player, or a
## node not spawned via SyncManager) it falls back to queue_free().
func _despawn() -> void:
	if SyncManager != null and SyncManager.started and has_meta("spawn_name"):
		SyncManager.despawn(self)
	else:
		queue_free()
