## visual_bridge_component.gd — The 2.5D Bridge: deterministic 2D sim -> 3D visuals.
##
## ROLE: The ONLY place where fixed-point simulation coordinates are converted
## to floats. It listens to a sim mover's state_updated signal (the player's
## MovementComponent, or a projectile/wall's ProjectileMovementComponent — any
## emitter of state_updated(fixed_x, fixed_y)) and drives a Node3D:
##
##     sim X (SG2D, fixed-point)  ->  visual_root.position.x  (meters)
##     sim Y (SG2D, fixed-point)  ->  visual_root.position.z  (meters)
##     visual Y (height)          ->  untouched by default; optionally held at
##                                    the constant visual_height (see below)
##
## This matches the "tennis court" design: the deterministic 2D plane lies flat
## on the 3D ground plane. Data flows ONE WAY — sim to visuals. Nothing in this
## component (including smoothing) ever writes back into simulation state, so
## visual polish can never desync the deterministic game.
##
## FACING (Sprint 2 hotfix round 3 — Creative Director mandate): left/right
## facing is implemented HERE, and ONLY here, as a yaw flip of the 3D rig
## (visual_root.rotation.y = 0 or PI). NEVER rotate, mirror, or negative-scale
## the SGCharacterBody2D or ANY SG node to express facing — physics rotation is
## locked at 0 (PlayerController enforces that) and the cast direction lives in
## GLOBAL sim axes on SpellCasterComponent (cast_direction_y), so neither may
## ever depend on which way the wizard looks. Facing is derived by comparing
## the fixed-point sim X ints received from consecutive state_updated emissions
## — a pure read; this component still never writes a single sim value.
class_name VisualBridgeComponent
extends Node

## The 3D node to drive (the wizard's visual rig). Assign in the Inspector.
@export var visual_root: Node3D

## Path to the movement component to listen to — anything that emits
## state_updated(fixed_x: int, fixed_y: int): the player's MovementComponent
## or a projectile's ProjectileMovementComponent. Leave empty to auto-find a
## sibling that emits the signal (recommended scene shape: both components
## share the same body parent).
@export var movement_path: NodePath

## 3D meters per sim unit. With the default 0.01, a 600-unit arena half-width
## is 6 m of court. Tune together with arena_half_width to size the playfield.
@export var sim_to_world_scale: float = 0.01

## When enabled, the visual eases toward the sim position each rendered frame
## instead of snapping. Purely cosmetic — hides the 60 Hz tick stepping and any
## future rollback corrections. Disable to debug raw sim positions.
@export var smoothing_enabled: bool = true

## Exponential smoothing rate (per second). Higher = tighter tracking; ~15 is
## responsive with a hint of glide, ~30 is nearly snapped. Only used while
## smoothing_enabled is on.
@export var smoothing_speed: float = 18.0

## Constant visual height (3D meters, world Y) the visual root hovers at above
## the floor. PURELY cosmetic — the sim has no height axis. A flying fireball
## hovers at e.g. 1.2 m so it reads as airborne; its DropShadowComponent stays
## on the floor for depth judgment. Leave at 0.0 (default) to keep the current
## behavior of never touching the visual's Y at all (jump/FX may own it later).
@export var visual_height: float = 0.0

## Creative Director mandate (Sprint 2 hotfix round 3): face the wizard rig in
## the direction of horizontal travel — PURE VISUAL. When the sim X delta
## between consecutive state_updated emissions is negative the rig yaws to PI
## (faces left); positive yaws to 0 (faces right). The default yaw 0 is the
## spawn state; the −Y down-court cast direction is independent of facing
## either way (it lives in GLOBAL sim axes on SpellCasterComponent).
##
## NEVER rotate/mirror the SGCharacterBody2D (or any SG node) for facing —
## this rig flip is the game's ONLY facing mechanism (see class doc).
##
## NOTE: billboarded Sprite3D children ignore the parent's Y rotation, so with
## today's placeholder billboard art the flip buys nothing visible — and if the
## rig content is NOT centered on the yawed node's origin, a 180° yaw ORBITS it
## across the arena (the Sprint 2 "teleports to the other side on A/D" bug).
## DEFAULT OFF: enable only once directional art lands AND the rig is centered
## on facing_pivot's origin (verify by toggling yaw 180° in the editor — the
## wizard must spin in place, not move).
@export var face_movement_direction: bool = false

## The Node3D that receives the facing yaw. Leave unset to yaw visual_root.
## REQUIREMENT: this node's origin must sit at the character's center/feet —
## any content offset from that origin does not "flip", it ORBITS the origin
## when yawed 180°, visually teleporting the character. Point this at the
## WizardRig itself (centered), never at a wrapper holding positional offsets.
@export var facing_pivot: Node3D

## Facing deadzone, in SIM UNITS of per-update |X delta|. Deltas at or below
## this threshold leave the current facing untouched, so fixed-point
## micro-jitter never flickers the rig. Converted ONCE per write to a
## fixed-point int (the setter, same pattern as SpellCasterComponent's
## spawn_offset_y); the per-update comparison is int vs int.
@export var facing_deadzone: float = 0.25:
	set(value):
		facing_deadzone = value
		_facing_deadzone_fp = SGFixed.from_float(maxf(0.0, value))

## Turn smoothing rate (per second) for the facing flip. 0.0 (default) =
## instant snap to the new yaw. > 0 eases the yaw each rendered frame with the
## same framerate-independent exponential approach used for position smoothing
## (~10 is a readable turn, ~30 is nearly snapped). Purely cosmetic.
@export var facing_turn_speed: float = 0.0

# Latest sim position converted to world-space floats (the smoothing target).
# Float use is allowed here: this is visual-only state, never fed back to sim.
var _target_x: float = 0.0
var _target_z: float = 0.0

# False until the first snap has ACTUALLY been applied to visual_root (set
# inside _apply_snap, not when a target merely arrives). Guarantees the first
# state_updated this bridge ever receives takes the snap path regardless of
# smoothing settings — a freshly spawned projectile must appear AT its sim
# spawn point, never glide in from the scene-default / world-origin transform.
# If visual_root is briefly unresolved, the snap retries on the next update
# instead of being silently lost. (Sprint 2 hotfix.)
var _has_snapped: bool = false

# --- Facing state (visual-only; see face_movement_direction) ---
# Sim X from the PREVIOUS state_updated emission, kept as the raw fixed-point
# int so the facing decision is an int-vs-int compare (no float drift, and
# obviously no sim access — these are copies of received signal arguments).
var _prev_fixed_x: int = 0
var _has_prev_x: bool = false
# facing_deadzone mirrored to fixed point by its setter (kept fresh per write;
# re-derived in _ready() against the initializer-order clobber documented in
# SpellCasterComponent._cache_fixed_point_values).
var _facing_deadzone_fp: int = 0
# Yaw the rig should hold: 0.0 = right / spawn default, PI = left. Applied
# instantly (facing_turn_speed == 0) or eased in _process (> 0).
var _target_yaw: float = 0.0

## NETPLAY visual mirror flag (Sprint 21) — set true by MatchController on the
## CLIENT so this entity's visual Z is mirrored (see _on_state_updated). Default
## false: offline/host present the court normally.
var view_flip_z: bool = false


func _ready() -> void:
	# Belt-and-braces re-derive: the facing_deadzone setter keeps this cache
	# fresh, but member-initializer order can clobber its default-init write
	# (same trap documented in SpellCasterComponent).
	_facing_deadzone_fp = SGFixed.from_float(maxf(0.0, facing_deadzone))

	var movement: Node = _resolve_movement()
	assert(movement != null, "VisualBridgeComponent needs a component emitting state_updated (set movement_path or add one as a sibling).")
	movement.state_updated.connect(_on_state_updated)


## Receives fixed-point sim coordinates each tick. This is the single
## fixed-point -> float conversion point for player position.
func _on_state_updated(fixed_x: int, fixed_y: int) -> void:
	_target_x = SGFixed.to_float(fixed_x) * sim_to_world_scale
	_target_z = SGFixed.to_float(fixed_y) * sim_to_world_scale
	# NETPLAY visual mirror (Sprint 21): the CLIENT sees the court spun front-to-back
	# so ITS wizard sits at the near, well-lit baseline. Pure presentation — only the
	# visual Z is mirrored (X kept, so left/right controls stay correct); the sim is
	# untouched and identical on both peers. Set by MatchController for the client.
	if view_flip_z:
		_target_z = -_target_z

	if face_movement_direction:
		_update_facing(fixed_x)

	if not _has_snapped:
		# First update ever received (spawn, or first after a scene load): snap
		# unconditionally — even with smoothing on — so the visual appears at
		# the true sim spawn point instead of gliding in from the world origin.
		_apply_snap()
	elif not smoothing_enabled:
		_apply_snap()
	# When smoothing is enabled, _process eases toward the new target.


func _process(delta: float) -> void:
	if visual_root == null:
		return

	# Eased facing turn (only when a turn-smoothing rate is set; the instant
	# path applies the yaw directly in _update_facing). Rotation-only — never
	# touches the position mapping below.
	if face_movement_direction and facing_turn_speed > 0.0:
		var pivot: Node3D = _resolve_facing_pivot()
		if pivot != null:
			var ft: float = 1.0 - exp(-facing_turn_speed * delta)
			pivot.rotation.y = lerp_angle(pivot.rotation.y, _target_yaw, ft)

	if not smoothing_enabled or not _has_snapped:
		return
	# Framerate-independent exponential approach toward the sim position.
	var rate: float = smoothing_speed
	var t: float = 1.0 - exp(-rate * delta)
	var pos: Vector3 = visual_root.position
	pos.x = lerpf(pos.x, _target_x, t)
	pos.z = lerpf(pos.z, _target_z, t)
	if visual_height != 0.0:
		pos.y = visual_height  # Constant cosmetic hover height.
	visual_root.position = pos  # At height 0.0, Y deliberately untouched.


## Picks the rig facing from the sign of the int delta between consecutive sim
## X positions. PURE VISUAL READ: compares the received fixed-point ints and
## writes ONLY visual_root.rotation.y — never any SG node, never sim state.
## Deltas inside the deadzone hold the current facing (no jitter flicker);
## the first update only seeds the comparison baseline (spawn faces yaw 0).
func _update_facing(fixed_x: int) -> void:
	if not _has_prev_x:
		_prev_fixed_x = fixed_x
		_has_prev_x = true
		return

	var delta_x: int = fixed_x - _prev_fixed_x
	_prev_fixed_x = fixed_x

	if delta_x > _facing_deadzone_fp:
		_target_yaw = 0.0  # Moving +X: face right (the spawn default).
	elif delta_x < -_facing_deadzone_fp:
		_target_yaw = PI   # Moving -X: face left — 180° around VISUAL Y only.
	else:
		return  # Inside the deadzone: hold the current facing.

	if facing_turn_speed <= 0.0:
		var pivot: Node3D = _resolve_facing_pivot()
		if pivot != null:
			pivot.rotation.y = _target_yaw  # Instant flip (default).


## The node the facing yaw is applied to: facing_pivot when assigned, else
## visual_root. Kept separate from the position mapping so a mis-centered rig
## can be fixed by re-pointing the pivot without touching position flow.
func _resolve_facing_pivot() -> Node3D:
	if facing_pivot != null:
		return facing_pivot
	return visual_root


## Instantly snaps the visual to the current sim position (used on first
## update, when smoothing is off, and useful after teleports/respawns).
## Latches _has_snapped only on success, so a snap attempted while visual_root
## is unresolved is retried on the next state_updated rather than dropped.
func _apply_snap() -> void:
	if visual_root == null:
		return
	var pos: Vector3 = visual_root.position
	pos.x = _target_x
	pos.z = _target_z
	if visual_height != 0.0:
		pos.y = visual_height  # Constant cosmetic hover height.
	visual_root.position = pos
	_has_snapped = true


## Duck-typed on the state_updated signal (not the MovementComponent class) so
## one bridge serves players AND projectiles/walls — any sim mover that emits
## state_updated(fixed_x: int, fixed_y: int) qualifies.
func _resolve_movement() -> Node:
	if not movement_path.is_empty():
		var node: Node = get_node_or_null(movement_path)
		if node != null and node.has_signal(&"state_updated"):
			return node
		return null
	var parent: Node = get_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if child != self and child.has_signal(&"state_updated"):
			return child
	return null
