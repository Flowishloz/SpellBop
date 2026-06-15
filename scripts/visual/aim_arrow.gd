## aim_arrow.gd — Mobile-MP B2b: a glowing-blue ground arrow at the LOCAL wizard's
## feet that shows the EXACT firing angle.
##
## PURE PRESENTATION (no sim / no determinism): MatchController points it each frame
## at the local wizard's current aim (the same sector the caster turns into vx), and
## shows it ONLY while that wizard is charging a fireball or has an owned spell staged
## on the stack. The glow matches the arena-border look (emissive cyan, unshaded).
##
## The arrow mesh points local +Z; MatchController rotates the node about Y so +Z
## aligns with the firing direction in world space (down-court sign from the foe's
## rig Z, which already encodes the client's view_flip_z; lateral from world +X).
extends Node3D

## Height above the floor plane (the arena borders sit at ~0.08).
@export var floor_y: float = 0.06
## Arrow length in metres. Sized for the shallow over-the-shoulder camera, which
## foreshortens a flat ground arrow heavily. (Creative Director: shorter overall — but
## the TIP stays at the same distance from the wizard, so feet_gap absorbs the shrink:
## tip distance = feet_gap + length, kept ≈3.28 m while length dropped from 2.08.)
@export var length: float = 1.3
## Triangle BASE half-width in metres (slender — a thin directional triangle, not
## a generic shaft+head arrow).
@export var head_half_width: float = 0.40
## How far FORWARD (along the aim) to detach the arrow from the feet, so it leads
## the wizard a little instead of sitting under it (still flat on the floor). Raised in
## lockstep with the length cut so the arrow TIP holds its distance from the wizard.
@export var feet_gap: float = 1.98

var _mesh_instance: MeshInstance3D = null


func _ready() -> void:
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = _build_arrow_mesh()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.9, 1.0, 0.85)
	mat.emission_enabled = true
	mat.emission = Color(0.3, 0.95, 1.0)
	mat.emission_energy_multiplier = 2.4
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED   # flat on the floor; seen from above
	_mesh_instance.material_override = mat
	add_child(_mesh_instance)
	visible = false


## Place the arrow at [param feet] (snapped to the floor plane) and aim local +Z along
## [param dir] (an XZ-plane direction). Makes the arrow visible.
func point(feet: Vector3, dir: Vector3) -> void:
	visible = true
	# Detach from the feet: shove the arrow forward along the aim so it LEADS the
	# wizard (still snapped flat to the floor plane).
	var ahead: Vector3 = dir.normalized() * feet_gap
	global_position = Vector3(feet.x + ahead.x, floor_y, feet.z + ahead.z)
	rotation = Vector3(0.0, atan2(dir.x, dir.z), 0.0)


func hide_arrow() -> void:
	visible = false


## A single SLENDER triangle flat on the XZ plane, pointing +Z: base (width
## 2*head_half_width) at z=0, tip at z=length — a thin directional pointer.
func _build_arrow_mesh() -> ArrayMesh:
	var verts := PackedVector3Array([
		Vector3(-head_half_width, 0.0, 0.0), Vector3(0.0, 0.0, length), Vector3(head_half_width, 0.0, 0.0),
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
