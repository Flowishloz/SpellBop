## camera_rig.gd — The "Punch-Out" portrait camera.
##
## Sits low to the ground directly behind Player 1's baseline, looking straight
## down-court (-Z) at the opponent — over-the-shoulder arcade-fighter framing
## adapted to the 9:16 portrait FOV. The node's basis stays IDENTITY (no
## rotation): the horizon sits mid-frame, floor below, starfield above.
##
## FOLLOW: "directly behind Player 1" stays true while the player moves — this
## script eases the camera's X toward the player rig's X each rendered frame.
## PURE VISUAL: reads the rig's float transform only, never touches the sim.
## Set follow_strength = 0.0 for a fully fixed camera.
class_name PunchOutCameraRig
extends Camera3D

## The player's visual rig (Node3D) whose X the camera shadows.
@export var target_path: NodePath

## 0.0 = fixed camera. 1.0 = camera X mirrors the player's X exactly.
## Values between give a "soft pan" that under-travels the player.
@export_range(0.0, 1.0) var follow_strength: float = 0.55

## Exponential follow rate per second (higher = tighter). Uses _process delta,
## so the pan slows with the world inside the Stack window — intentional.
@export var follow_speed: float = 5.5

## Hard clamp (meters) on how far from center the camera may pan, so the
## frame never slides off the court edges.
@export var max_offset_x: float = 4.0

## KEEP-IN-VIEW LEASH (Creative Director): max horizontal distance (meters)
## between camera and player before the camera is dragged along. The soft
## pan keeps its momentum inside the leash; at the leash the sprite is about
## half out of frame — it can never fully escape (dash, shoulder swaps).
@export var keep_in_view_max_dx: float = 1.55

## Downward pitch in degrees, applied from script in _ready(). Graveyard rule:
## rotated Transform3D values are never hand-authored in .tscn (row-major
## serialization transposed one once and pointed the camera at the sky) —
## the scene keeps an IDENTITY basis and this script owns ALL rotation.
@export var pitch_degrees: float = -23.3

## Horizontal yaw in degrees (positive = look left). Matched to the Creative
## Director's hand-tuned TestArena camera: offset right of the player's
## shoulder, yawed slightly back toward them — the "dynamic tilt".
@export var yaw_degrees: float = 8.0

## Final yaw clamp (degrees) — a hard guard so the camera can never "flip" past a
## sane angle however the shoulder swap / follow combine (Phase 2 Creative
## Director: avoid jarring flips past 90 degrees).
@export var max_yaw_degrees: float = 60.0

@export_group("Default Perspective")
## PHASE 2 (Creative Director): push the camera BACK from the arena by this factor
## (1.15 = +15% further: scales height + depth, keeps the lateral shoulder) and
## widen the default FOV by base_fov_scale (+15%) so more of the court is framed.
@export var pullback_factor: float = 1.15
@export var base_fov_scale: float = 1.15

@export_group("Dynamic Stack Zoom")
## PHASE 2 (Creative Director): while the stack resolves in slow-mo, tighten the
## FOV to base_fov * stack_zoom_scale (0.85 = zoom in 15%), easing back as normal
## speed resumes. Driven off Engine.time_scale (dilated == stack active).
@export var stack_zoom_scale: float = 0.85
@export var stack_zoom_speed: float = 5.0
## Engine.time_scale below this counts as "in the stack" (dilated) -> zoom in.
@export var stack_zoom_time_threshold: float = 0.92

@export_group("Dynamic Shoulder")
## DYNAMIC SHOULDER SWAP (Creative Director): same angles and perspective,
## but the camera glides to the LEFT shoulder when the wizard plays the left
## side of the court, and back to the right shoulder on the right side.
@export var shoulder_swap_enabled: bool = true

## Player |x| (meters) beyond which the shoulder swaps — hysteresis: between
## the thresholds the camera keeps its current side (no flip-flapping).
@export var shoulder_swap_threshold: float = 1.15

## Glide rate (per second) of the swap. Runs on the WALL clock — the camera
## must stay alive inside the Stack window (Creative Director: it read as
## "locked" during slow-mo when this used scaled delta).
@export var shoulder_glide_speed: float = 1.5

@export_group("Shake")
## Master switch for the trauma shake (charging rumble, cast bursts, hits).
@export var shake_enabled: bool = true

## Max positional shake (meters) on camera X/Y at full trauma.
@export var max_shake_offset: Vector2 = Vector2(0.16, 0.12)

## Max roll (degrees) at full trauma — the "kick" component.
@export var max_shake_roll_degrees: float = 1.5

## Trauma lost per REAL second (wall clock: bursts die at the same real pace
## inside the Stack's slow-mo, where scaled delta crawls).
@export var trauma_decay_per_second: float = 1.6

## Wobble speed of the shake pattern (bigger = more frantic).
@export var shake_frequency: float = 16.0

@export_group("Death Cam")
## DEATH CAM (Sprint 20, Creative Director): on a KO the camera zooms onto the
## eliminated wizard's sprite and TRACKS it as it's flung off the arena, so the
## death animation is the focal point. FOV scales by death_zoom_scale (0.5 = zoom
## in ~50%); the camera eases to a point death_cam_distance/height from the sprite
## and looks straight at it. MatchController drives begin/end_death_cam().
@export var death_zoom_scale: float = 0.5
@export var death_cam_distance: float = 4.6   # metres back from the sprite
@export var death_cam_height: float = 1.7     # metres above the sprite
@export var death_cam_speed: float = 6.0      # ease rate into the death framing

# TRAUMA MODEL (pure visual): bursts (add_trauma) decay over real time;
# rumble (set_rumble) is a sustained floor held by whoever sets it (the
# charge-up). Displayed magnitude is trauma squared — small values whisper,
# big values slam. The wobble is layered sines on the wall clock: smooth,
# deterministic-looking, and free of RNG.
var _trauma: float = 0.0
var _rumble: float = 0.0

var _target: Node3D
var _base_x: float = 0.0
var _base_y: float = 0.0
var _base_z: float = 0.0
var _follow_x: float = 0.0
var _base_fov: float = 75.0
var _fov_zoom: float = 1.0

# DEATH CAM (Sprint 20): the eliminated wizard's sprite to frame, or null.
var _death_target: Node3D = null


# Right-shoulder reference values captured at _ready (the dynamic swap and
# left-handed mode both mirror them).
var _default_base_x: float = 0.0
var _default_yaw: float = 0.0

# Current shoulder: +1 = right, -1 = left. The PREFERRED side (used when the
# player is centered) comes from handedness; play position overrides it.
var _side: float = 1.0


func _ready() -> void:
	# PHASE 2: push the camera back from the arena (scale its height + depth, keep
	# the lateral shoulder offset) and widen the default FOV.
	_base_x = global_position.x
	_base_y = global_position.y * pullback_factor
	_base_z = global_position.z * pullback_factor
	_base_fov = fov * base_fov_scale
	_fov_zoom = 1.0
	fov = _base_fov
	_default_base_x = _base_x
	_default_yaw = yaw_degrees
	_follow_x = _base_x
	rotation_degrees = Vector3(pitch_degrees, yaw_degrees, 0.0)
	_target = get_node_or_null(target_path) as Node3D
	if _target == null:
		push_warning("PunchOutCameraRig: target_path not set/found — camera is fixed.")

	# LEFT-HANDED MODE: mirror to the LEFT shoulder (x and yaw flip). Pure
	# presentation — the sim never sees the camera.
	var settings: Node = get_node_or_null(^"/root/GameSettings")
	if settings != null:
		settings.handedness_changed.connect(_on_handedness_changed)
		_on_handedness_changed(settings.left_handed)


func _on_handedness_changed(left_handed: bool) -> void:
	# Handedness picks the STARTING/preferred shoulder; the dynamic swap
	# glides between sides during play either way.
	_side = -1.0 if left_handed else 1.0


## One-shot shake burst (casts, hits, counters). Stacks and clamps at 1.
func add_trauma(amount: float) -> void:
	if shake_enabled:
		_trauma = clampf(_trauma + amount, 0.0, 1.0)


## Sustained shake floor (0 = off) — the charge-up rumble. The caller owns
## turning it back off (MatchController does, off the charge signals).
func set_rumble(strength: float) -> void:
	_rumble = clampf(strength, 0.0, 1.0) if shake_enabled else 0.0


## DEATH CAM start: frame [param sprite] (the eliminated wizard's Sprite3D) — the
## camera zooms in and tracks it until end_death_cam(). Pure presentation.
func begin_death_cam(sprite: Node3D) -> void:
	_death_target = sprite


## DEATH CAM end: release the framing; the normal follow/zoom eases back in.
func end_death_cam() -> void:
	_death_target = null


func _process(delta: float) -> void:
	# Decay on the WALL clock so bursts feel identical inside slow-mo.
	var real_delta: float = delta / maxf(Engine.time_scale, 0.001)
	_trauma = maxf(0.0, _trauma - trauma_decay_per_second * real_delta)

	# DEATH CAM (Sprint 20): when an eliminated wizard is being framed, the death
	# cam OWNS the camera — zoom in, ease toward the sprite, look straight at it.
	if _death_target != null and is_instance_valid(_death_target):
		_update_death_cam(real_delta)
		return

	# DYNAMIC SHOULDER: pick the side from the player's court position
	# (hysteresis holds the current side near center), then glide the base
	# offset AND the yaw toward that shoulder's mirror.
	if _target != null and shoulder_swap_enabled:
		var px: float = _target.global_position.x
		if px > shoulder_swap_threshold:
			_side = 1.0
		elif px < -shoulder_swap_threshold:
			_side = -1.0
		var glide: float = 1.0 - exp(-shoulder_glide_speed * real_delta)
		_base_x = lerpf(_base_x, _default_base_x * _side, glide)
		yaw_degrees = lerpf(yaw_degrees, _default_yaw * _side, glide)

	# Soft pan toward the player — on the WALL clock, so the camera never
	# freezes inside the Stack window (Creative Director slow-mo lock fix).
	if _target != null and follow_strength > 0.0:
		var desired: float = clampf(_target.global_position.x * follow_strength, -max_offset_x, max_offset_x)
		var t: float = 1.0 - exp(-follow_speed * real_delta)
		_follow_x = lerpf(_follow_x, _base_x + desired, t)

	# LEASH: whatever the easing/shoulder state, never let the sprite fully
	# leave frame — hard-clamp the pan around the player (momentum survives
	# inside the band; a dash just drags the camera with it at the edge).
	if _target != null:
		var px2: float = _target.global_position.x
		_follow_x = clampf(_follow_x, px2 - keep_in_view_max_dx, px2 + keep_in_view_max_dx)

	# Layer the shake on top of the follow.
	var shake: float = maxf(_trauma, _rumble)
	var offset_x: float = 0.0
	var offset_y: float = 0.0
	var roll: float = 0.0
	if shake > 0.0:
		var magnitude: float = shake * shake
		var wobble_t: float = Time.get_ticks_msec() / 1000.0 * shake_frequency
		offset_x = max_shake_offset.x * magnitude * sin(wobble_t * 1.7)
		offset_y = max_shake_offset.y * magnitude * sin(wobble_t * 2.3 + 1.3)
		roll = max_shake_roll_degrees * magnitude * sin(wobble_t * 1.3 + 0.7)

	# DYNAMIC STACK ZOOM (Phase 2): tighten the FOV while the world is dilated
	# (the stack resolving in slow-mo), ease back as normal speed resumes.
	var want_zoom: float = stack_zoom_scale if Engine.time_scale < stack_zoom_time_threshold else 1.0
	var zt: float = 1.0 - exp(-stack_zoom_speed * real_delta)
	_fov_zoom = lerpf(_fov_zoom, want_zoom, zt)
	fov = _base_fov * _fov_zoom

	# Hard yaw guard so the camera never flips past a sane angle (Phase 2).
	var clamped_yaw: float = clampf(yaw_degrees, -max_yaw_degrees, max_yaw_degrees)
	global_position = Vector3(_follow_x + offset_x, _base_y + offset_y, _base_z)
	rotation_degrees = Vector3(pitch_degrees, clamped_yaw, roll)


## DEATH CAM framing (Sprint 20): ease the camera toward a close shot of the
## eliminated wizard's sprite, zoom the FOV in, and look straight at it so the
## knockout animation is the focal point. Driven on the WALL clock (real_delta) so
## the framing keeps gliding even though the world is in death slow-mo.
func _update_death_cam(dt: float) -> void:
	var sp: Vector3 = _death_target.global_position
	# Frame from the camera's own baseline side, pulled in close to the sprite.
	var side: float = 1.0 if _base_z >= 0.0 else -1.0
	var desired: Vector3 = sp + Vector3(0.0, death_cam_height, death_cam_distance * side)
	var t: float = 1.0 - exp(-death_cam_speed * dt)
	var pos: Vector3 = global_position.lerp(desired, t)
	# Layer the KO jolt shake on top.
	var shake: float = maxf(_trauma, _rumble)
	if shake > 0.0:
		var mag: float = shake * shake
		var wob: float = Time.get_ticks_msec() / 1000.0 * shake_frequency
		pos += Vector3(max_shake_offset.x * mag * sin(wob * 1.7),
				max_shake_offset.y * mag * sin(wob * 2.3 + 1.3), 0.0)
	global_position = pos
	# Zoom in on the sprite.
	_fov_zoom = lerpf(_fov_zoom, death_zoom_scale, t)
	fov = _base_fov * _fov_zoom
	# Look straight at the sprite (the death cam owns rotation). Guard the
	# degenerate near-zero distance so look_at never errors.
	if pos.distance_to(sp) > 0.05:
		look_at(sp, Vector3.UP)
