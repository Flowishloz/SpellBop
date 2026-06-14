## match_hud.gd — Match HUD: health bars with momentum.
##
## UI READS, NEVER WRITES (project rule): initializes once from
## HealthComponent.get_health(), then reacts ONLY to health_changed signals.
##
## TWO BARS (Creative Director, round-system sprint):
##   - PLAYER: vertical 5-cell bar top-left — mounted on a spring so it has
##     momentum/sway (it lags and overshoots the camera's pan instead of
##     being glued to the screen).
##   - OPPONENT: small horizontal bar FLOATING above the opponent's head —
##     each frame the 3D head position is unprojected to the canvas and the
##     bar SPRING-CHASES it (sway + follow-through, like the camera rig, so
##     it never feels stapled to the model).
##
## All motion is wall-clock spring physics (the UI exception: immune to the
## Stack's 10% time dilation).
extends CanvasLayer

## The player's HealthComponent this bar mirrors.
@export var health_path: NodePath

## The opponent's HealthComponent (floating bar). Optional.
@export var opponent_health_path: NodePath = NodePath("../Opponent/Health")

## The opponent's 3D rig — the floating bar hovers above this.
@export var opponent_rig_path: NodePath = NodePath("../Opponent/WizardRig")

## Meters above the rig origin the floating bar anchors to.
@export var float_height: float = 2.5

## Bar placement/sizing (canvas px, 1080x1920 portrait space).
@export var top_left: Vector2 = Vector2(36, 36)
@export var cell_size: Vector2 = Vector2(44, 64)
@export var cell_gap: float = 10.0

@export var filled_color: Color = Color(0.85, 0.15, 0.18)
@export var empty_color: Color = Color(0.18, 0.05, 0.07, 0.65)
@export var foe_filled_color: Color = Color(0.95, 0.35, 0.25)

## Spring feel (stiffness = chase speed, damping < critical = overshoot).
@export var spring_stiffness: float = 120.0
@export var spring_damping: float = 9.0

## How hard the player bar leans against camera pan (px per meter).
@export var sway_per_meter: float = 26.0

## Hard clamp on the bar's sway offset (px) — the bar must NEVER leave the
## screen, however far the camera pans (Creative Director bug report: the
## bar exited the screen edge with the player at the far lane).
@export var max_sway_px: float = 22.0

var _bar_root: Control
var _cells: Array[ColorRect] = []
var _bar_offset: Vector2 = Vector2.ZERO
var _bar_vel: Vector2 = Vector2.ZERO

var _foe_root: Control
var _foe_cells: Array[ColorRect] = []
var _foe_pos: Vector2 = Vector2(540, 300)
var _foe_vel: Vector2 = Vector2.ZERO

var _camera: Camera3D
var _foe_rig: Node3D
var _cam_base_x: float = 0.0
var _last_msec: int = 0


func _ready() -> void:
	_last_msec = Time.get_ticks_msec()

	# --- player bar (swaying mount) ---
	_bar_root = Control.new()
	_bar_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bar_root)
	var health: Node = get_node_or_null(health_path)
	if health == null:
		push_warning("MatchHUD: health_path not set/found — health bar inert.")
	else:
		for i in health.max_health:
			var cell := ColorRect.new()
			cell.position = top_left + Vector2(0, i * (cell_size.y + cell_gap))
			cell.size = cell_size
			cell.color = filled_color
			_bar_root.add_child(cell)
			_cells.append(cell)
		health.health_changed.connect(_on_health_changed)
		_on_health_changed(health.get_health(), health.max_health)

	# LEFT-HANDED MODE: the player bar mirrors to the top-RIGHT.
	var settings: Node = get_node_or_null(^"/root/GameSettings")
	if settings != null:
		settings.handedness_changed.connect(_on_handedness_changed)
		_on_handedness_changed(settings.left_handed)

	# --- opponent floating bar ---
	_foe_root = Control.new()
	_foe_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_foe_root)
	var foe_health: Node = get_node_or_null(opponent_health_path)
	if foe_health != null:
		var w: float = 26.0
		var gap: float = 6.0
		var total: float = foe_health.max_health * w + (foe_health.max_health - 1) * gap
		for i in foe_health.max_health:
			var cell := ColorRect.new()
			cell.position = Vector2(-total * 0.5 + i * (w + gap), 0)
			cell.size = Vector2(w, 16)
			cell.color = foe_filled_color
			_foe_root.add_child(cell)
			_foe_cells.append(cell)
		foe_health.health_changed.connect(_on_foe_health_changed)
		_on_foe_health_changed(foe_health.get_health(), foe_health.max_health)
	_foe_rig = get_node_or_null(opponent_rig_path) as Node3D


func _process(_delta: float) -> void:
	# Wall-clock dt: identical spring feel at time_scale 1.0 or 0.1.
	var now: int = Time.get_ticks_msec()
	var dt: float = clampf(float(now - _last_msec) / 1000.0, 0.0, 0.05)
	_last_msec = now
	if dt <= 0.0:
		return

	if _camera == null:
		_camera = get_viewport().get_camera_3d()
		if _camera != null:
			_cam_base_x = _camera.global_position.x

	# Player bar: spring toward a lean opposing the camera's pan. The lean
	# TARGET is clamped, and the integrated offset is clamped again — the
	# bar can sway but never leave the screen.
	# (Springs are inlined: Vector2 is a value type in GDScript — a helper
	# taking pos/vel parameters would silently mutate copies.)
	if _camera != null:
		var lean_x: float = clampf(
				-(_camera.global_position.x - _cam_base_x) * sway_per_meter,
				-max_sway_px, max_sway_px)
		_bar_vel += (Vector2(lean_x, 0) - _bar_offset) * spring_stiffness * dt
		_bar_vel *= maxf(0.0, 1.0 - spring_damping * dt)
		_bar_offset += _bar_vel * dt
		_bar_offset.x = clampf(_bar_offset.x, -max_sway_px * 1.6, max_sway_px * 1.6)
		_bar_offset.y = clampf(_bar_offset.y, -60.0, 60.0)
		_bar_root.position = _bar_offset

	# Opponent bar: spring-chase the unprojected head point (the lag IS the
	# sway/follow-through — it trails the model and settles with overshoot).
	if _camera != null and _foe_rig != null:
		var head: Vector3 = _foe_rig.global_position + Vector3(0, float_height, 0)
		if not _camera.is_position_behind(head):
			var target: Vector2 = _camera.unproject_position(head)
			_foe_vel += (target - _foe_pos) * spring_stiffness * dt
			_foe_vel *= maxf(0.0, 1.0 - spring_damping * dt)
			_foe_pos += _foe_vel * dt
			_foe_root.position = _foe_pos
			_foe_root.visible = true
		else:
			_foe_root.visible = false


func _on_handedness_changed(left_handed: bool) -> void:
	var x: float = (1080.0 - top_left.x - cell_size.x) if left_handed else top_left.x
	for cell in _cells:
		cell.position.x = x
	# The camera's home X moved with the shoulder swap: re-base the sway so
	# the bar doesn't lean permanently against a stale reference.
	_camera = null
	_bar_offset = Vector2.ZERO
	_bar_vel = Vector2.ZERO


func _on_health_changed(current: int, max_health: int) -> void:
	var lost: int = max_health - current
	for i in _cells.size():
		_cells[i].color = empty_color if i < lost else filled_color
	# Impact kick: the bar jumps and the spring settles it (follow-through).
	_bar_vel += Vector2(randf_range(-1.0, 1.0) * 140.0, 180.0)


func _on_foe_health_changed(current: int, max_health: int) -> void:
	var lost: int = max_health - current
	for i in _foe_cells.size():
		_foe_cells[i].color = Color(0.2, 0.08, 0.06, 0.7) if i < lost else foe_filled_color
	_foe_vel += Vector2(0, -160.0)


## NETPLAY (Sprint 21): on the CLIENT the local wizard is the Opponent, so swap
## which HealthComponent each bar reads — the CORNER bar shows the client's OWN
## (Opponent) health, the FLOATING bar shows the FOE (Player) and hovers over the
## far Player rig. Re-binds the signals + refreshes; the cells already match (both
## wizards share the same max_health). Presentation only.
func set_perspective_flipped(own_health: Node, foe_health: Node, foe_rig: Node3D) -> void:
	# Corner (own) bar: re-point from the original Player health to the Opponent.
	var cur: Node = get_node_or_null(health_path)
	if cur != null and cur.health_changed.is_connected(_on_health_changed):
		cur.health_changed.disconnect(_on_health_changed)
	if own_health != null:
		own_health.health_changed.connect(_on_health_changed)
		_on_health_changed(own_health.get_health(), own_health.max_health)
	# Floating (foe) bar: re-point from the original Opponent health to the Player.
	var cur_foe: Node = get_node_or_null(opponent_health_path)
	if cur_foe != null and cur_foe.health_changed.is_connected(_on_foe_health_changed):
		cur_foe.health_changed.disconnect(_on_foe_health_changed)
	if foe_health != null:
		foe_health.health_changed.connect(_on_foe_health_changed)
		_on_foe_health_changed(foe_health.get_health(), foe_health.max_health)
	# Hover the foe bar over the far (Player) rig.
	if foe_rig != null:
		_foe_rig = foe_rig
