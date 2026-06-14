## heart_pop_fx.gd — a heart that POPS vertically out of the healing emerald when
## it is struck, arcs up, falls under gravity, and DESPAWNS the moment it touches
## the floor (Sprint 20 round-4, Creative Director: a clear "you gained a life"
## cue). Pure visual, wall-clock driven; self-frees on landing.
##
## The heart is two emissive spheres (lobes) over a downward cone (point) — the
## mesh + material are SHARED statics (built once), so a mid-fight pop never
## compiles a fresh pipeline (graveyard material rule).
class_name HeartPopFX
extends Node3D

## Upward pop speed (m/s) and the fall gravity (m/s^2).
@export var pop_speed: float = 5.2
@export var gravity: float = 9.0
## Floor height the heart despawns at on the way down.
@export var floor_y: float = 0.06

var _vel: Vector3 = Vector3.ZERO
var _t: float = 0.0


## Spawns a heart popping out of [param pos] under [param parent] (a 3D node).
static func spawn(parent: Node, pos: Vector3) -> void:
	if parent == null:
		return
	var fx := HeartPopFX.new()
	parent.add_child(fx)
	fx.global_position = pos
	fx._build()


func _build() -> void:
	_vel = Vector3(0.0, pop_speed, 0.0)
	var lobe: SphereMesh = _shared_lobe()
	var point: CylinderMesh = _shared_point()
	var left := MeshInstance3D.new()
	left.mesh = lobe
	left.position = Vector3(-0.11, 0.13, 0.0)
	add_child(left)
	var right := MeshInstance3D.new()
	right.mesh = lobe
	right.position = Vector3(0.11, 0.13, 0.0)
	add_child(right)
	var pt := MeshInstance3D.new()
	pt.mesh = point
	pt.position = Vector3(0.0, -0.09, 0.0)
	pt.rotation = Vector3(PI, 0.0, 0.0)  # flip the cone so its point faces DOWN
	add_child(pt)


func _process(delta: float) -> void:
	_t += delta
	_vel.y -= gravity * delta
	global_position += _vel * delta
	# A gentle wobble + a slow spin so the heart reads as a lively pop.
	rotation.y += delta * 2.4
	scale = Vector3.ONE * (1.0 + 0.12 * sin(_t * 9.0))
	# Despawn the instant it lands back on the floor (only while falling).
	if _vel.y < 0.0 and global_position.y <= floor_y:
		queue_free()


# --- shared heart geometry (built once) ------------------------------

static var _lobe_mesh: SphereMesh = null
static var _point_mesh: CylinderMesh = null
static var _heart_mat: StandardMaterial3D = null


static func _shared_mat() -> StandardMaterial3D:
	if _heart_mat != null:
		return _heart_mat
	_heart_mat = StandardMaterial3D.new()
	_heart_mat.albedo_color = Color(0.95, 0.15, 0.3)
	_heart_mat.emission_enabled = true
	_heart_mat.emission = Color(1.0, 0.25, 0.4)
	_heart_mat.emission_energy_multiplier = 1.8
	return _heart_mat


static func _shared_lobe() -> SphereMesh:
	if _lobe_mesh == null:
		_lobe_mesh = SphereMesh.new()
		_lobe_mesh.radius = 0.12
		_lobe_mesh.height = 0.24
		_lobe_mesh.material = _shared_mat()
	return _lobe_mesh


static func _shared_point() -> CylinderMesh:
	if _point_mesh == null:
		_point_mesh = CylinderMesh.new()
		_point_mesh.top_radius = 0.0
		_point_mesh.bottom_radius = 0.215
		_point_mesh.height = 0.32
		_point_mesh.material = _shared_mat()
	return _point_mesh
