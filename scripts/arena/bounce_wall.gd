## bounce_wall.gd — Static defensive/arena wall (SG Physics 2D fixed-point).
##
## ROLE: The immovable collider that projectiles deterministically reflect off
## (ProjectileMovementComponent reads the SGKinematicCollision2D normal and
## bounces in fixed point). Used both for the arena boundary walls and for the
## Defensive Wall spell's conjured barrier.
##
## SGStaticBody2D never moves and has NO per-tick logic and NO mutable
## simulation state — static bodies don't roll back, so this class deliberately
## implements none of the rollback contract (_network_process/_save_state/
## _load_state). If a future spell needs a wall with a lifetime/HP, that state
## belongs in a component child following the rollback contract — not here.
##
## Recommended scene shape (built by the Creative Director in the editor):
##   BounceWall (SGStaticBody2D)
##     └─ SGCollisionShape2D (SGRectangleShape2D — extents are HALF-sizes, fixed-point)
##
## NOTE: if a wall is ever positioned from code (e.g. the Defensive Wall spell
## placing it), writing fixed_position is a teleport — sync_to_physics_engine()
## is MANDATORY afterwards.
class_name BounceWall
extends SGStaticBody2D


func _ready() -> void:
	# HARDCODED COLLISION LAYERS (Sprint 2 hotfix) — the editor UI fails to
	# persist SG Physics 2D layer assignments, leaving bodies on the plugin
	# default (layer 1 / mask 1). DO NOT move this back to the Inspector.
	# See scripts/physics_layers.gd. Walls live on the wall layer so the
	# fireball's wall-only mask can match them; as a static body the wall
	# scans nothing itself (mask 0) — movers detect IT, never the reverse.
	collision_layer = PhysicsLayers.LAYER_WALLS
	collision_mask = PhysicsLayers.MASK_NONE
