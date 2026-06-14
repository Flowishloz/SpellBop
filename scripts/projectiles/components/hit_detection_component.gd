## hit_detection_component.gd — Deterministic projectile-vs-wizard hit scan.
##
## ROLE: each tick, tests this projectile's body against every wizard body in
## the "wizards" group using PURE fixed-point int math (axis-aligned
## rect-vs-circle approximation: |dx| < half_width + radius AND |dy| <
## half_height + radius). No physics areas, no broadphase — two bodies, two
## compares — so the result is trivially bit-identical on every peer.
##
## WHY NOT collision masks: fireballs deliberately do NOT collide with player
## bodies (mask = walls only) so they never push or deflect wizards; damage is
## an overlap QUERY, not a physical response. This component IS that query.
##
## The caster's own body is excluded via `source` (set by SpellCasterComponent
## through FireballController.set_hit_source) so a freshly spawned ball never
## hits its own wizard, even if redirected later.
##
## ROLLBACK CONTRACT: _network_process(input) drives the scan (called by
## FireballController AFTER movement, same tick order on every peer);
## _save_state()/_load_state() carry the has-hit latch.
class_name HitDetectionComponent
extends Node

## A wizard body was struck. FireballController applies damage and frees the
## projectile. Listeners read — the struck body is modified ONLY via its own
## apply_damage API.
signal hit(body: Node)

## Path to the projectile's SGCharacterBody2D. Empty = direct parent.
@export var body_path: NodePath

## Projectile collision radius, sim units. Match the scene's SGCircleShape2D
## (and SpellResource.projectile_size).
@export var hit_radius: float = 24.0

## RECTANGULAR projectiles (e.g. the Counter's court-wide ice wave): when
## either extent is > 0 it replaces hit_radius on that axis (half-extents in
## sim units, matching the scene's SGRectangleShape2D). 0 = circular default.
@export var hit_extent_x: float = 0.0
@export var hit_extent_y: float = 0.0

## Target wizard collider half-extents, sim units. Match player.tscn's
## SGRectangleShape2D extents.
@export var target_half_width: float = 52.5
@export var target_half_height: float = 16.0

## Group the wizard bodies register under (PlayerController._ready()).
@export var target_group: StringName = &"wizards"

# Excluded source body (the caster). Set via FireballController.set_hit_source.
var source: Node = null

# Latch: a projectile lands at most one hit, then expires.
var _has_hit: bool = false

var _body: SGCharacterBody2D
var _radius_x_fp: int = 0
var _radius_y_fp: int = 0
var _half_w_fp: int = 0
var _half_h_fp: int = 0


func _ready() -> void:
	_body = _resolve_body()
	assert(_body != null, "HitDetectionComponent requires an SGCharacterBody2D (set body_path or parent it under one).")
	_radius_x_fp = SGFixed.from_float(hit_extent_x if hit_extent_x > 0.0 else hit_radius)
	_radius_y_fp = SGFixed.from_float(hit_extent_y if hit_extent_y > 0.0 else hit_radius)
	_half_w_fp = SGFixed.from_float(target_half_width)
	_half_h_fp = SGFixed.from_float(target_half_height)


# =====================================================================
# ROLLBACK CONTRACT
# =====================================================================

## One overlap scan per tick. Group iteration order is scene-tree order —
## deterministic for identical trees on every peer.
func _network_process(_input: Dictionary) -> void:
	if _has_hit:
		return
	var my_pos: SGFixedVector2 = _body.get_global_fixed_position()
	for target in get_tree().get_nodes_in_group(target_group):
		if target == source or not (target is SGFixedNode2D):
			continue
		var target_pos: SGFixedVector2 = target.get_global_fixed_position()
		if absi(my_pos.x - target_pos.x) < _half_w_fp + _radius_x_fp \
				and absi(my_pos.y - target_pos.y) < _half_h_fp + _radius_y_fp:
			_has_hit = true
			hit.emit(target)
			return


## Re-bases the scan radius at runtime. CardCasterComponent sizes spawned
## projectiles from CardResource.projectile_size AFTER _ready() has cached —
## same live-recache rule as the spawn_offset_y graveyard entry.
func set_radius_units(units: float) -> void:
	hit_radius = units
	_radius_x_fp = SGFixed.from_float(units)
	_radius_y_fp = SGFixed.from_float(units)


func _save_state() -> Dictionary:
	return {
		"hh": 1 if _has_hit else 0,
	}


func _load_state(state: Dictionary) -> void:
	_has_hit = int(state.get("hh", 0)) == 1


func _resolve_body() -> SGCharacterBody2D:
	if not body_path.is_empty():
		return get_node_or_null(body_path) as SGCharacterBody2D
	return get_parent() as SGCharacterBody2D
