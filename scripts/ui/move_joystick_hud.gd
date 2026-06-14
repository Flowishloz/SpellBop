## move_joystick_hud.gd — Floating virtual joystick for the movement thumb.
##
## The left thumb rests anywhere in the lower-LEFT zone (mirrored to the
## lower-RIGHT in left-handed mode). On touch-down the stick SPRINGS UP under
## the finger (floating joystick — no fixed home, so the thumb never has to
## hunt for it); dragging left/right past a deadzone drives the move_left /
## move_right actions. Movement is X-only in the sim, so vertical drag is
## ignored. Release hides the stick and clears both actions.
##
## Graveyard-safe: this feeds the SAME move_left/move_right actions the keyboard
## feeds, so the deterministic mover and the held-direction AIM system (longer
## hold => more aim tilt) behave exactly as on desktop. The sim axis is digital
## (-1/0/+1); pushing the stick past the deadzone == holding the arrow key.
extends CanvasLayer

## Lower-left activation zone (canvas px) in right-handed mode. The thumb may
## press anywhere in here to summon the stick. Mirrored across x=540 when
## left-handed (the dash/cast buttons move left, so movement moves right).
@export var zone_min: Vector2 = Vector2(0, 980)
@export var zone_max: Vector2 = Vector2(540, 1920)

## Max knob travel from the floating base (px) — full deflection at this radius.
@export var stick_radius: float = 150.0

## Horizontal deflection (fraction of stick_radius) past which a direction
## registers. Below this you're idle (a centered thumb shouldn't creep).
@export var deadzone_fraction: float = 0.28

@export var base_color: Color = Color(1, 1, 1, 0.10)
@export var ring_color: Color = Color(1, 1, 1, 0.30)
@export var knob_color: Color = Color(0.8, 0.92, 1.0, 0.5)

## MatchController whose round flow gates the stick: it stands down between
## rounds and on the victory screen (no movement there — and so it never eats a
## touch meant for the PLAY AGAIN button on the match-end overlay).
@export var match_controller_path: NodePath = NodePath("..")

var _draw: Control
var _left_handed: bool = false
var _active: bool = true        # false between rounds / on the match-end screen
var _touch_index: int = -2      # -2 none, -1 mouse, >=0 finger
var _origin: Vector2 = Vector2.ZERO
var _knob: Vector2 = Vector2.ZERO
var _dir: int = 0               # currently-pressed axis (-1/0/+1)


func _ready() -> void:
	layer = 2
	_draw = _JoystickCanvas.new()
	_draw.host = self
	_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_draw.set_anchors_preset(Control.PRESET_FULL_RECT)
	_draw.visible = false
	add_child(_draw)

	var settings: Node = get_node_or_null(^"/root/GameSettings")
	if settings != null and settings.has_signal(&"handedness_changed"):
		settings.handedness_changed.connect(func(left: bool) -> void: _left_handed = left)
		_left_handed = settings.left_handed

	# Active only while a round is live. Between rounds / on the victory screen
	# the stick stands down (releases any drag) so it never steals a tap from
	# the PLAY AGAIN button on the overlay above it.
	var mc: Node = get_node_or_null(match_controller_path)
	if mc != null:
		mc.round_started.connect(func(_n: int) -> void: _active = true)
		mc.round_ended.connect(func(_w: bool, _p: int, _o: int, _b: float) -> void: _set_inactive())
		mc.match_ended.connect(func(_w: bool) -> void: _set_inactive())


## Deactivate and cancel any in-progress drag (clears the held direction too).
func _set_inactive() -> void:
	_active = false
	if _touch_index != -2:
		_end()


func _zone_contains(pos: Vector2) -> bool:
	var mn: Vector2 = zone_min
	var mx: Vector2 = zone_max
	if _left_handed:
		# Mirror the x-band across the 1080-wide canvas.
		mn = Vector2(1080.0 - zone_max.x, zone_min.y)
		mx = Vector2(1080.0 - zone_min.x, zone_max.y)
	return pos.x >= mn.x and pos.x <= mx.x and pos.y >= mn.y and pos.y <= mx.y


func _begin(pos: Vector2, index: int) -> void:
	_touch_index = index
	_origin = pos
	_knob = pos
	_dir = 0
	_draw.visible = true
	_draw.queue_redraw()


func _drag(pos: Vector2) -> void:
	var offset: Vector2 = pos - _origin
	if offset.length() > stick_radius:
		offset = offset.normalized() * stick_radius
	_knob = _origin + offset
	# Digital X axis from horizontal deflection past the deadzone.
	var dx: float = offset.x / stick_radius
	var new_dir: int = 0
	if dx > deadzone_fraction:
		new_dir = 1
	elif dx < -deadzone_fraction:
		new_dir = -1
	if new_dir != _dir:
		_apply_dir(new_dir)
	_draw.queue_redraw()


func _apply_dir(new_dir: int) -> void:
	if _dir < 0:
		Input.action_release(&"move_left")
	elif _dir > 0:
		Input.action_release(&"move_right")
	_dir = new_dir
	if _dir < 0:
		Input.action_press(&"move_left")
	elif _dir > 0:
		Input.action_press(&"move_right")


func _end() -> void:
	_apply_dir(0)
	_touch_index = -2
	_draw.visible = false


func _input(event: InputEvent) -> void:
	# Stand down between rounds / on the victory screen — don't claim touches
	# (a held finger is already released by _set_inactive).
	if not _active and _touch_index == -2:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			if _active and _touch_index == -2 and _zone_contains(event.position):
				_begin(event.position, event.index)
				get_viewport().set_input_as_handled()
		elif event.index == _touch_index:
			_end()
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and event.index == _touch_index:
		_drag(event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _touch_index == -2 and _zone_contains(event.position):
				_begin(event.position, -1)
				get_viewport().set_input_as_handled()
		elif _touch_index == -1:
			_end()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _touch_index == -1:
		_drag(event.position)


func _notification(what: int) -> void:
	# Don't let a direction stick if we lose focus / the tree pauses mid-drag.
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT \
			or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT \
			or what == NOTIFICATION_PAUSED:
		if _touch_index != -2:
			_end()


## Inner canvas that renders the floating stick (the layer can't _draw itself).
class _JoystickCanvas extends Control:
	var host

	func _draw() -> void:
		if host == null:
			return
		var o: Vector2 = host._origin
		var k: Vector2 = host._knob
		draw_circle(o, host.stick_radius, host.base_color)
		draw_arc(o, host.stick_radius, 0.0, TAU, 48, host.ring_color, 3.0, true)
		# Direction hint chevrons left/right of the base.
		var hint := Color(1, 1, 1, 0.18)
		for sgn in [-1.0, 1.0]:
			var hc: Vector2 = o + Vector2(sgn * host.stick_radius * 0.62, 0)
			draw_polyline(PackedVector2Array([
				hc + Vector2(-sgn * 10, -16),
				hc + Vector2(sgn * 10, 0),
				hc + Vector2(-sgn * 10, 16),
			]), hint, 5.0, true)
		draw_circle(k, host.stick_radius * 0.42, host.knob_color)
		draw_arc(k, host.stick_radius * 0.42, 0.0, TAU, 32, host.ring_color, 3.0, true)
