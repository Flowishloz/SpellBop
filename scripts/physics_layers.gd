## physics_layers.gd — SINGLE SOURCE OF TRUTH for SG Physics 2D collision layers.
##
## WHY THIS EXISTS (Sprint 2 hotfix): the Godot editor fails to persist SG
## Physics 2D collision_layer / collision_mask assignments made through the
## Inspector UI, so every SG body silently falls back to the plugin default
## (layer = 1, mask = 1). That default made a freshly spawned fireball collide
## with its caster's collider on tick 0 and bounce() its velocity backwards.
## ALL collision layers/masks are therefore hardcoded in each controller's
## _ready() using these constants — DO NOT move layer assignment back to the
## editor checkboxes.
##
## Values are int bitmasks (verified via ClassDB: SGCollisionObject2D exposes
## collision_layer / collision_mask as TYPE_INT, bit 0 = editor "Layer 1").
##
## Layer plan (Creative Director mandate):
##   Layer 1 (bit 0, value 1) = Players
##   Layer 2 (bit 1, value 2) = Projectiles
##   Layer 3 (bit 2, value 4) = Walls
class_name PhysicsLayers


## Layer 1 — player bodies live here.
const LAYER_PLAYERS: int = 1

## Layer 2 — projectile bodies (fireballs, etc.) live here.
const LAYER_PROJECTILES: int = 2

## Layer 3 — static arena/spell walls live here.
const LAYER_WALLS: int = 4

## Layers 4/5 — ONE-WAY card barriers (Creative Director: the owner shoots
## THROUGH their own wall). P1's barriers live on layer 4, P2's on layer 5;
## a projectile's mask includes only the ENEMY side's barrier layer, so its
## owner's walls never block it. Side is derived from cast_direction_y
## (-1 = P1 / south baseline, +1 = P2 / north baseline).
const LAYER_BARRIER_P1: int = 8
const LAYER_BARRIER_P2: int = 16

## Mask for bodies that scan nothing (static walls: they are seen, never see).
const MASK_NONE: int = 0


## The barrier layer for the side casting toward [param cast_direction_y]
## (-1 = P1, +1 = P2).
static func barrier_layer_for(cast_direction_y: int) -> int:
	return LAYER_BARRIER_P1 if cast_direction_y < 0 else LAYER_BARRIER_P2


## The projectile mask for a caster: arena walls + the ENEMY's barriers only.
static func projectile_mask_for(cast_direction_y: int) -> int:
	return LAYER_WALLS | (LAYER_BARRIER_P2 if cast_direction_y < 0 else LAYER_BARRIER_P1)
