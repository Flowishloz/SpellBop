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

## Emitted (with a WORLD position) the instant a projectile strikes the emerald —
## the arena listens to fire the screen ripple from the point of contact.
signal claimed(world_pos: Vector3)

## Lives granted to the wizard whose projectile strikes the emerald.
@export var heal_amount: int = 1

## Drift speed, sim units/sec — each retarget picks a new random velocity up to
## this in EACH axis. Slow: the emerald wanders the arena, it never darts.
@export var drift_speed: float = 120.0

## Half-size (sim units) of the box the emerald wanders inside, centred on the
## arena origin. Sprint 20 (Creative Director: "move around the arena, bumping
## into walls"): roams most of the central court and visibly BUMPS the side walls
## (X) and mid-court (Y), reflecting off each boundary — kept clear of the
## wizards' baselines (±880) so it never overlaps a player.
@export var wander_half_x: float = 440.0
@export var wander_half_y: float = 560.0

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

## VISUAL float/spin (wall-clock cosmetic; never sim). Sprint 20: a SLOW spin and
## a SUBTLE hover (Creative Director — the chaos-emerald gem turns gently).
@export var hover_height: float = 0.85
@export var bob_amplitude: float = 0.10
@export var bob_speed: float = 2.0
@export var spin_speed: float = 1.0

# --- cached fixed-point (computed in _ready) ---
var _drift_step_fp: int = 0   # max per-tick velocity component (fixed-point)
var _wander_x_fp: int = 0
var _wander_y_fp: int = 0
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
	_wander_x_fp = SGFixed.from_float(maxf(1.0, wander_half_x))
	_wander_y_fp = SGFixed.from_float(maxf(1.0, wander_half_y))
	_pickup_fp = SGFixed.from_float(maxf(0.0, pickup_radius))
	_mesh = get_node_or_null(mesh_path) as Node3D
	# CHAOS-EMERALD GEM (Sprint 20): swap the placeholder sphere for a faceted
	# brilliant-cut gem. The mesh is a SHARED static (built once, never per spawn),
	# so it never compiles a fresh pipeline mid-fight (graveyard material rule).
	if _mesh is MeshInstance3D:
		(_mesh as MeshInstance3D).mesh = _shared_gem_mesh()

	# NETPLAY: when a rollback session is live this emerald was created via
	# SyncManager.spawn — join the synced group + idle the local driver so the
	# SyncManager drives it (the same _ready gate the fireball uses; offline keeps
	# the local driver). SpawnManager re-sorts the group right after add_child.
	if SyncManager != null and SyncManager.started:
		add_to_group(&"network_sync")
		local_tick_driver_enabled = false


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


## ROLLBACK SPAWN (SyncManager.spawn): reconstruct from a pure int/path payload — the
## same setup the spawner used to do inline, now rollback-correct (runs on spawn AND every
## re-sim). px/py = fixed-point position, seed = drift LCG seed, scan = Projectiles path.
func _network_spawn(data: Dictionary) -> void:
	var px: int = int(data.get("px", 0))
	var py: int = int(data.get("py", 0))
	set_global_fixed_position(SGFixed.vector2(px, py))
	sync_to_physics_engine()
	seed_drift(int(data.get("seed", 0)))
	var scan_path: String = String(data.get("scan", ""))
	if scan_path != "":
		var container: Node = get_node_or_null(NodePath(scan_path))
		if container != null:
			set_scan_container(container)
	emit_position()


## Rollback-aware free: SyncManager.despawn under a live match (keeps the spawn record
## consistent across re-sims), else queue_free. Every self-free site routes through here.
func _despawn() -> void:
	if SyncManager != null and SyncManager.started:
		SyncManager.despawn(self)
	else:
		queue_free()


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
	if pos.x > _wander_x_fp:
		pos.x = _wander_x_fp
		_vx = -_vx
	elif pos.x < -_wander_x_fp:
		pos.x = -_wander_x_fp
		_vx = -_vx
	if pos.y > _wander_y_fp:
		pos.y = _wander_y_fp
		_vy = -_vy
	elif pos.y < -_wander_y_fp:
		pos.y = -_wander_y_fp
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
		# Only a DAMAGING projectile (fireball / spark bolt + their shards) breaks the emerald — the
		# Counter's frost wave (0 damage, slow only) now passes harmlessly through it (Creative
		# Director). Deterministic: `damage` is an immutable int set at spawn, identical on both peers.
		if not ("damage" in child) or int(child.damage) <= 0:
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
	# PRESENTATION — suppressed during a rollback re-sim so a re-applied strike never
	# doubles the burst / heart / ripple / SFX. The heal above is deterministic + rolled
	# back; only these cosmetics are gated (the emerald claimed->ripple stays pure-visual).
	if not (SyncManager != null and SyncManager.is_in_rollback()):
		var visual: Node3D = get_node_or_null(visual_root_path) as Node3D
		if visual != null:
			var burst_pos: Vector3 = visual.global_position + Vector3(0, hover_height * 0.5, 0)
			BurstFX.spawn(get_parent(), burst_pos,
					Vector3.UP, Color(0.35, 1.0, 0.55, 0.95), 36, 3.4, 0.08, 150.0)
			# A HEART pops up out of the gem and falls — the "you gained a life" cue.
			HeartPopFX.spawn(get_parent(), visual.global_position + Vector3(0, hover_height, 0))
			# Notify the arena so it can fire the screen ripple from the point of contact.
			claimed.emit(burst_pos)
		Sfx.play(&"heal")
	# The struck ball is consumed; both frees route through the rollback-aware path so a
	# SyncManager-tracked node never dangles its spawn record into the next rollback.
	if is_instance_valid(projectile):
		if projectile.has_method(&"_despawn"):
			projectile._despawn()
		else:
			projectile.queue_free()
	_despawn()


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


# =====================================================================
# Chaos-emerald gem mesh (Sprint 20)
# =====================================================================

## A faceted brilliant-cut gem (flat top "table", crown facets, long pointed
## pavilion) built ONCE and shared by every emerald — the mesh is read-only, so
## sharing is safe and no fresh pipeline compiles mid-fight. The embedded material
## is emissive green so the gem glows like a classic Chaos Emerald.
static var _gem_mesh: ArrayMesh = null


static func _shared_gem_mesh() -> ArrayMesh:
	if _gem_mesh != null:
		return _gem_mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sides: int = 8
	var girdle_r: float = 0.30   # widest ring (the gem's equator)
	var table_r: float = 0.12    # flat top face radius
	var y_table: float = 0.17    # crown height
	var y_tip: float = -0.34     # pavilion point (the long, pointed bottom)
	var table := PackedVector3Array()
	var girdle := PackedVector3Array()
	for i in sides:
		var a: float = TAU * float(i) / float(sides)
		table.append(Vector3(cos(a) * table_r, y_table, sin(a) * table_r))
		girdle.append(Vector3(cos(a) * girdle_r, 0.0, sin(a) * girdle_r))
	var top := Vector3(0.0, y_table, 0.0)
	var tip := Vector3(0.0, y_tip, 0.0)
	var center := Vector3(0.0, -0.05, 0.0)  # rough centroid for the outward test
	for i in sides:
		var j: int = (i + 1) % sides
		_add_face(st, top, table[i], table[j], center)          # flat table cap
		_add_face(st, table[i], girdle[i], girdle[j], center)   # crown facet A
		_add_face(st, table[i], girdle[j], table[j], center)    # crown facet B
		_add_face(st, girdle[i], tip, girdle[j], center)        # pavilion facet
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.78, 0.42)
	mat.metallic = 0.5
	mat.roughness = 0.12
	mat.emission_enabled = true
	mat.emission = Color(0.2, 1.0, 0.55)
	mat.emission_energy_multiplier = 1.8
	st.set_material(mat)
	_gem_mesh = st.commit()
	return _gem_mesh


## Adds one flat-shaded triangle facet, forcing the normal to point OUTWARD from
## [param center] (winding-independent — it flips the order if the face points
## inward, so the gem renders solid regardless of how the rings were ordered).
static func _add_face(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, center: Vector3) -> void:
	var n: Vector3 = (b - a).cross(c - a)
	if n.length() < 0.000001:
		return
	n = n.normalized()
	var centroid: Vector3 = (a + b + c) / 3.0
	if n.dot(centroid - center) < 0.0:
		n = -n
		var tmp: Vector3 = b
		b = c
		c = tmp
	st.set_normal(n)
	st.add_vertex(a)
	st.set_normal(n)
	st.add_vertex(b)
	st.set_normal(n)
	st.add_vertex(c)
