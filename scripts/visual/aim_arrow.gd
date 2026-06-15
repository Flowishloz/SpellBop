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
## Arrow length in metres (tip distance from the feet). Sized for the shallow
## over-the-shoulder camera, which foreshortens a flat ground arrow heavily.
@export var length: float = 2.6
## Arrowhead half-width in metres.
@export var head_half_width: float = 0.62

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
	global_position = Vector3(feet.x, floor_y, feet.z)
	rotation = Vector3(0.0, atan2(dir.x, dir.z), 0.0)


func hide_arrow() -> void:
	visible = false


## A flat arrow on the XZ plane pointing +Z: a shaft quad (z in [0, neck]) plus a
## wider head triangle (z in [neck, length]).
func _build_arrow_mesh() -> ArrayMesh:
	var shaft_half: float = head_half_width * 0.42
	var neck: float = length * 0.58
	var verts := PackedVector3Array([
		# shaft (two triangles, CCW seen from +Y)
		Vector3(-shaft_half, 0.0, 0.0), Vector3(shaft_half, 0.0, neck), Vector3(shaft_half, 0.0, 0.0),
		Vector3(-shaft_half, 0.0, 0.0), Vector3(-shaft_half, 0.0, neck), Vector3(shaft_half, 0.0, neck),
		# head triangle
		Vector3(-head_half_width, 0.0, neck), Vector3(0.0, 0.0, length), Vector3(head_half_width, 0.0, neck),
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
