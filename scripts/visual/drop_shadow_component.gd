## drop_shadow_component.gd — Hard-edged drop shadow pinned to the floor.
##
## ROLE: Every rendered frame, parks a flat shadow node directly UNDER a
## tracked visual (the wizard rig, a hovering fireball) at floor level. The
## hard, unambiguous floor shadow is the player's primary depth cue on the
## 2.5D court — per the Graphics Pipeline's strict hard-edged readable-shadow
## requirement, depth judgment comes from the shadow, not from perspective.
##
## PURELY VISUAL: floats are fine here. This component READS positions only —
## it never writes to anything except the shadow node, and never touches
## simulation state.
##
## ===== HUMAN SETUP RECIPE — the hard-edged shadow node (build in editor) =====
## Create a Sprite3D for shadow_path and configure it EXACTLY like this:
##   - Texture:        a solid dark circle (pure color, no soft gradient edge).
##   - Billboard:      DISABLED (must lie flat on the floor — it must NOT
##                     turn to face the camera; this component keeps rotation
##                     flat every frame as a safety net).
##   - Rotation:       -90 degrees on X (flat on the ground plane).
##   - Alpha Cut:      Discard — hard pixel edge, no soft alpha blending.
##   - Texture Filter: Nearest — crisp pixels, no bilinear smearing.
##   - Shaded:         OFF (unshaded) — the shadow is flat ink, unaffected by
##                     scene lighting.
## Parent the Sprite3D somewhere that does NOT inherit the target's transform
## (e.g. a sibling of the visual rig), otherwise it would double-move.
## =============================================================================
class_name DropShadowComponent
extends Node

## The flat shadow node (Sprite3D/Node3D built per the recipe above) this
## component positions every frame.
@export var shadow_path: NodePath

## The visual root whose X/Z the shadow tracks (e.g. the node driven by a
## VisualBridgeComponent). Only X and Z are read — the target's height (Y)
## never affects the shadow, which is the whole point: the shadow stays on
## the floor while the visual hovers.
@export var target_path: NodePath

## World Y the shadow sits at: a hair above 0 so it never z-fights with the
## floor plane. Raise slightly if the floor mesh isn't exactly at Y = 0.
@export var floor_y: float = 0.01

var _shadow: Node3D
var _target: Node3D


func _ready() -> void:
	_shadow = get_node_or_null(shadow_path) as Node3D
	_target = get_node_or_null(target_path) as Node3D
	if _shadow == null:
		push_warning("DropShadowComponent: shadow_path is unset or not a Node3D — shadow disabled.")
	if _target == null:
		push_warning("DropShadowComponent: target_path is unset or not a Node3D — shadow disabled.")


func _process(_delta: float) -> void:
	if _shadow == null or _target == null:
		return

	# Pin the shadow to the floor directly beneath the target. Global space so
	# shadow and target can live under different parents.
	var target_pos: Vector3 = _target.global_position
	_shadow.global_position = Vector3(target_pos.x, floor_y, target_pos.z)

	# Keep the shadow flat on the ground no matter what (it must NOT billboard
	# or inherit any tilt): face-down plane, every frame.
	_shadow.global_rotation = Vector3(-PI / 2.0, 0.0, 0.0)
