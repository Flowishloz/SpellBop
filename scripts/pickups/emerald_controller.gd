## emerald_controller.gd — The healing emerald pickup (Phase 1).
##
## A glowing 3D emerald that spawns near the arena centre, FLOATS, SPINS, and
## DRIFTS randomly, and grants a life back to whoever STRIKES it with a
## projectile. The sim half (position + drift + the projectile-strike pickup) is
## fully deterministic 64.16 fixed-point — the drift "randomness" is a SEEDED
## integer LCG, so it replays bit-identically. The float + spin are PURELY
## VISUAL (wall-clock cosmetic on the mesh; they never touch sim state).
##
## INTERACTION SURFACE (deliberately minimal): this body exposes NO
## get_velocity_y / get_hit_source / slow_ticks / redirect / damage, so every
## existing sim scan (AI threat dodge, defense WOA, barrier capture, the
## fireball ice-shatter) skips it for free — only its OWN pickup scan reaches
## into the projectile container. The AI finds it via the "pickups" group.
##
## ROLLBACK CONTRACT: _network_process / _save_state / _load_state, int-only
## state, driven by a local tick driver for now (the SyncManager owns it later).
class_name EmeraldController
extends SGCharacterBody2D

## Emitted every simulated tick (and at spawn / on state load) with the body's
## fixed-point position — the VisualBridgeComponent listens here (movement_path
## points at this body, "..").
signal state_updated(fixed_x: int, fixed_y: int)

## Lives granted to the wizard whose projectile strikes the emerald.
@export var heal_amount: int = 1

## Drift speed, sim units/sec — each retarget picks a new random velocity up to
## this in EACH axis. Slow: the emerald wanders, it never darts.
@export var drift_speed: float = 90.0

## Half-size (sim units) of the box around the arena centre the emerald wanders
## inside; it reflects off this boundary so it stays near the middle.
@export var wander_half_extent: float = 230.0

## Whole ticks between drift re-targets (a new random heading). 48 = 0.8 s.
@export var retarget_interval_ticks: int = 48

## Projectile-strike pickup radius (sim units). The strike test adds the
## projectile's own radius + its per-tick step (anti-tunnel) on top.
@export var pickup_radius: float = 46.0

## Simulation ticks per second (must match the project tick rate).
@export var tick_rate: int = 60

## When false the local tick driver idles (round park / SyncManager later).
@export var local_tick_driver_enabled: bool = true

## Visual rig (mesh + glow). VisualBridge drives its X/Z from the sim; this
## script bobs/spins the MESH child locally.
@export var visual_root_path: NodePath = NodePath("Visual")
@export var mesh_path: NodePath = NodePath("Visual/EmeraldMesh")

## VISUAL float/spin (wall-clock cosmetic; never sim).
@export var hover_height: float = 0.85
@export var bob_amplitude: float = 0.14
@export var bob_speed: float = 2.2
@export var spin_speed: float = 1.7

# --- cached fixed-point (computed in _ready) ---
var _drift_step_fp: int = 0   # max per-tick velocity component (fixed-point)
var _wander_fp: int = 0
var _pickup_fp: int = 0

# --- sim state (ints only — rollback-safe) ---
var _vx: int = 0
var _vy: int = 0
var _rng: int = 0
var _retarget: int = 0
var _claimed: bool = false    # latched on strike (one pickup, then freed)

# --- visual (float; never sim) ---
var _vis_time: float = 0.0
var _mesh: Node3D

# The container scanned for striking projectiles (the arena Projectiles node) —
# set by the spawner so the emerald can live OUTSIDE that container yet still
# detect strikes against it.
var _scan_container: Node = null


func _ready() -> void:
	# Hardcoded layers (graveyard rule): the emerald is a pure positioned marker
	# — it sees nothing and is seen by no physics body (layer/mask 0). All its
	# interactions are deterministic overlap queries, never physics collisions.
	collision_layer = 0
	collision_mask = 0
	fixed_rotation = 0
	add_to_group(&"pickups")
	var safe_tr: int = maxi(1, tick_rate)
	_drift_step_fp = SGFixed.div(SGFixed.from_float(maxf(0.0, drift_speed)), SGFixed.from_int(safe_tr))
	_wander_fp = SGFixed.from_float(maxf(1.0, wander_half_extent))
	_pickup_fp = SGFixed.from_float(maxf(0.0, pickup_radius))
	_mesh = get_node_or_null(mesh_path) as Node3D


## Seeds the deterministic drift LCG (the spawner passes a per-emerald seed so
## each emerald wanders differently but reproducibly).
func seed_drift(seed_value: int) -> void:
	_rng = seed_value & 0xffffffff


## Points the pickup scan at the projectile container (the spawner sets this).
func set_scan_container(container: Node) -> void:
	_scan_container = container


## Snaps the visual to the current sim position (the spawner calls this right
## after teleporting the body, so the rig never renders a frame at the origin).
func emit_position() -> void:
	var pos: SGFixedVector2 = get_global_fixed_position()
	state_updated.emit(pos.x, pos.y)


# =====================================================================
# ROLLBACK CONTRACT
# =====================================================================

## One tick: re-target drift on the interval, drift + reflect inside the wander
## box, then scan for a striking projectile. Deterministic int math throughout.
func _network_process(_input: Dictionary) -> void:
	if _claimed:
		return

	# New random heading every retarget_interval ticks (seeded LCG).
	if _retarget <= 0:
		_vx = _rand_component()
		_vy = _rand_component()
		_retarget = maxi(1, retarget_interval_ticks)
	_retarget -= 1

	# Drift, reflecting off the wander box so the emerald stays near centre.
	var pos: SGFixedVector2 = get_global_fixed_position()
	pos.x += _vx
	pos.y += _vy
	if pos.x > _wander_fp:
		pos.x = _wander_fp
		_vx = -_vx
	elif pos.x < -_wander_fp:
		pos.x = -_wander_fp
		_vx = -_vx
	if pos.y > _wander_fp:
		pos.y = _wander_fp
		_vy = -_vy
	elif pos.y < -_wander_fp:
		pos.y = -_wander_fp
		_vy = -_vy
	set_global_fixed_position(pos)
	sync_to_physics_engine()
	state_updated.emit(pos.x, pos.y)

	_scan_strike(pos)


## A new random velocity component in [-_drift_step_fp, +_drift_step_fp] from the
## seeded LCG. Pure int math (the modulo of a masked 32-bit value is positive).
func _rand_component() -> int:
	var span: int = 2 * _drift_step_fp + 1
	if span <= 1:
		return 0
	return (_next_rng() % span) - _drift_step_fp


## Advances the LCG (Numerical Recipes constants) and returns the new 32-bit
## state. Masked to 32 bits so the multiply never overflows int64 — bit-identical
## on every peer.
func _next_rng() -> int:
	_rng = (_rng * 1664525 + 1013904223) & 0xffffffff
	return _rng


## Scan the projectile container for a ball overlapping the emerald; the FIRST
## one to strike heals its thrower and claims the emerald. Fixed-point overlap
## widened by the ball's per-tick step so a fast strike can't tunnel through.
func _scan_strike(my_pos: SGFixedVector2) -> void:
	var container: Node = _scan_container if _scan_container != null else get_parent()
	if container == null:
		return
	for child in container.get_children():
		# A strike candidate is a projectile: it can name its thrower and report
		# its collider size + flight speed.
		if not child.has_method(&"get_hit_source") \
				or not child.has_method(&"get_collider_half_extents") \
				or not child.has_method(&"get_velocity_y"):
			continue
		var their_pos: SGFixedVector2 = child.get_global_fixed_position()
		var their_half: SGFixedVector2 = child.get_collider_half_extents()
		var band_x: int = _pickup_fp + their_half.x
		var band_y: int = _pickup_fp + their_half.y + absi(child.get_velocity_y())
		if absi(my_pos.x - their_pos.x) < band_x and absi(my_pos.y - their_pos.y) < band_y:
			_grant_heal(child)
			return


## The struck projectile's thrower gains a life; the ball is consumed and the
## emerald bursts and frees itself. Heal target read via the projectile's public
## get_hit_source() — "whoever hits it" is whoever threw the ball that hit it.
func _grant_heal(projectile: Node) -> void:
	_claimed = true
	var thrower: Node = projectile.get_hit_source()
	if thrower != null and thrower.has_method(&"apply_heal"):
		thrower.apply_heal(heal_amount)
	var visual: Node3D = get_node_or_null(visual_root_path) as Node3D
	if visual != null:
		BurstFX.spawn(get_parent(), visual.global_position + Vector3(0, hover_height * 0.5, 0),
				Vector3.UP, Color(0.35, 1.0, 0.55, 0.95), 36, 3.4, 0.08, 150.0)
	Sfx.play(&"heal")
	if is_instance_valid(projectile):
		projectile.queue_free()
	queue_free()


func _save_state() -> Dictionary:
	var pos: SGFixedVector2 = get_global_fixed_position()
	return {
		"px": pos.x, "py": pos.y,
		"vx": _vx, "vy": _vy,
		"rng": _rng, "rt": _retarget,
		"cl": 1 if _claimed else 0,
	}


func _load_state(state: Dictionary) -> void:
	_vx = int(state.get("vx", 0))
	_vy = int(state.get("vy", 0))
	_rng = int(state.get("rng", 0))
	_retarget = int(state.get("rt", 0))
	_claimed = int(state.get("cl", 0)) == 1
	var pos: SGFixedVector2 = get_global_fixed_position()
	pos.x = int(state.get("px", pos.x))
	pos.y = int(state.get("py", pos.y))
	set_global_fixed_position(pos)
	sync_to_physics_engine()
	state_updated.emit(pos.x, pos.y)


## LOCAL TICK DRIVER — replaced by the rollback SyncManager in a later sprint.
func _physics_process(_delta: float) -> void:
	if local_tick_driver_enabled:
		_network_process({})


## VISUAL ONLY (wall-clock): bob the mesh up/down and spin it. Never sim.
func _process(delta: float) -> void:
	if _mesh == null:
		return
	_vis_time += delta
	_mesh.position.y = hover_height + sin(_vis_time * bob_speed) * bob_amplitude
	_mesh.rotation.y += spin_speed * delta
