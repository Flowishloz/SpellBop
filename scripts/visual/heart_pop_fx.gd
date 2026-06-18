## heart_pop_fx.gd — a small emissive heart used as a "you gained a life" cue.
## TWO modes share the same shared-static heart mesh:
##
##   ARC  (HeartPopFX.spawn):       the heart pops vertically out of a point, arcs
##     up, falls under gravity, and DESPAWNS the instant it touches the floor.
##
##   POP  (HeartPopFX.spawn_above):  the heart POPS IN (scales up from nothing with
##     a little overshoot) above a tracked anchor's head, holds, then POPS OUT
##     (scales back to nothing) and frees — the clear "THIS wizard just earned the
##     heart" cue floating over the winner. It follows the anchor's world position
##     each frame (so it stays glued to a moving head) WITHOUT inheriting the rig's
##     scale / spin.
##
## Pure visual, wall-clock driven; self-frees. The mesh + material are SHARED
## statics (built once), so a mid-fight pop never compiles a fresh pipeline
## (graveyard material rule).
class_name HeartPopFX
extends Node3D

const MODE_ARC := 0
const MODE_POP := 1

## ARC mode — upward pop speed (m/s) and the fall gravity (m/s^2).
@export var pop_speed: float = 5.2
@export var gravity: float = 9.0
## ARC mode — floor height the heart despawns at on the way down.
@export var floor_y: float = 0.06

## POP mode — pop-in / hold / pop-out durations (seconds) and the peak scale.
@export var pop_in_time: float = 0.16
@export var pop_hold_time: float = 0.24
@export var pop_out_time: float = 0.18
@export var pop_scale: float = 1.0

var _mode: int = MODE_ARC
var _vel: Vector3 = Vector3.ZERO
var _t: float = 0.0
# POP mode — the head we hover over (tracked each frame) and the height above it.
var _anchor: Node3D = null
var _anchor_height: float = 0.0


## ARC: spawn a heart popping out of [param pos] under [param parent] (a 3D node).
static func spawn(parent: Node, pos: Vector3) -> void:
	if parent == null:
		return
	var fx := HeartPopFX.new()
	parent.add_child(fx)
	fx.global_position = pos
	fx._build()


## POP: pop a heart IN then OUT, [param height] metres above [param anchor]'s
## origin, tracking it each frame. Spawned under [param parent] (a 3D node) so it
## owns its own transform (no rig scale / spin inheritance). The "who earned the
## heart" cue floating over the winner's head.
static func spawn_above(parent: Node, anchor: Node3D, height: float) -> void:
	if parent == null or anchor == null:
		return
	var fx := HeartPopFX.new()
	fx._mode = MODE_POP
	fx._anchor = anchor
	fx._anchor_height = height
	parent.add_child(fx)
	fx.global_position = anchor.global_position + Vector3(0.0, height, 0.0)
	fx.scale = Vector3.ZERO  # start invisible — the pop-in grows it from nothing
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
	if _mode == MODE_POP:
		_process_pop(delta)
		return
	# ARC mode (unchanged): launch up, fall under gravity, despawn on landing.
	_vel.y -= gravity * delta
	global_position += _vel * delta
	# A gentle wobble + a slow spin so the heart reads as a lively pop.
	rotation.y += delta * 2.4
	scale = Vector3.ONE * (1.0 + 0.12 * sin(_t * 9.0))
	# Despawn the instant it lands back on the floor (only while falling).
	if _vel.y < 0.0 and global_position.y <= floor_y:
		queue_free()


## POP mode: follow the head, scale IN (with overshoot) -> hold -> scale OUT -> free.
func _process_pop(delta: float) -> void:
	# Track the head's world position WITHOUT inheriting its rig transform. If the
	# anchor was freed (round reset / match end), hold the last position.
	if is_instance_valid(_anchor):
		global_position = _anchor.global_position + Vector3(0.0, _anchor_height, 0.0)
	rotation.y += delta * 3.0  # a lively spin while it shows
	var total: float = pop_in_time + pop_hold_time + pop_out_time
	if _t >= total:
		queue_free()
		return
	var s: float
	if _t < pop_in_time:
		s = _ease_out_back(_t / maxf(0.0001, pop_in_time))            # 0 -> ~1 with overshoot
	elif _t < pop_in_time + pop_hold_time:
		s = 1.0                                                        # full size, holding
	else:
		var u: float = (_t - pop_in_time - pop_hold_time) / maxf(0.0001, pop_out_time)
		s = 1.0 - _ease_in_back(u)                                     # ~1 -> 0 with anticipation
	scale = Vector3.ONE * (pop_scale * maxf(0.0, s))


## Back-eases (overshoot) for a snappy "pop". Standard easing constants.
func _ease_out_back(x: float) -> float:
	var c1: float = 1.70158
	var c3: float = c1 + 1.0
	var p: float = x - 1.0
	return 1.0 + c3 * p * p * p + c1 * p * p


func _ease_in_back(x: float) -> float:
	var c1: float = 1.70158
	var c3: float = c1 + 1.0
	return c3 * x * x * x - c1 * x * x


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
