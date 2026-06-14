## ice_cube_vfx_component.gd — The Counter's frost prison visual.
##
## PURE VISUAL: when the sibling MovementComponent reports a timed slow
## (slow_started / slow_ended), this wraps the wizard in a translucent ice
## cube and floats a live countdown above their head. The countdown reads
## slow_ticks_remaining() each frame (read-only) and renders in seconds.
## Built entirely in code — no scene wiring beyond the two paths.
class_name IceCubeVFXComponent
extends Node

@export var movement_path: NodePath = NodePath("../Movement")
@export var rig_path: NodePath = NodePath("../WizardRig")

## Sim ticks per second (countdown display conversion only).
@export var tick_rate: int = 60

var _movement: Node
var _cube: MeshInstance3D
var _label: Label3D


func _ready() -> void:
	_movement = get_node_or_null(movement_path)
	var rig: Node3D = get_node_or_null(rig_path) as Node3D
	if _movement == null or rig == null or not _movement.has_signal(&"slow_started"):
		push_warning("IceCubeVFXComponent: movement/rig not found — frost VFX inert.")
		return

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.55, 0.8, 1.0, 0.38)
	var box := BoxMesh.new()
	box.material = mat
	box.size = Vector3(0.95, 2.3, 0.7)
	_cube = MeshInstance3D.new()
	_cube.mesh = box
	_cube.position = Vector3(0, 1.15, 0)
	_cube.visible = false
	rig.add_child(_cube)

	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 96
	_label.pixel_size = 0.004
	_label.modulate = Color(0.7, 0.9, 1.0)
	_label.outline_size = 24
	_label.position = Vector3(0, 2.75, 0)
	_label.visible = false
	rig.add_child(_label)

	_movement.slow_started.connect(_on_slow_started)
	_movement.slow_ended.connect(_on_slow_ended)


func _process(_delta: float) -> void:
	if _label == null or not _label.visible or _movement == null:
		return
	var ticks: int = _movement.slow_ticks_remaining()
	_label.text = "%.1f" % (float(ticks) / float(maxi(1, tick_rate)))


func _on_slow_started(_duration_ticks: int) -> void:
	if _cube != null:
		_cube.visible = true
		_label.visible = true


func _on_slow_ended() -> void:
	if _cube != null:
		_cube.visible = false
		_label.visible = false
