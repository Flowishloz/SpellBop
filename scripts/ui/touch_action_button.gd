## touch_action_button.gd — Shared base for the on-screen thumb buttons (dash
## + fireball cast). One translucent circle, a custom icon, an optional
## progress viz, and a countdown label — but the important part is INPUT:
##
## A press anywhere inside the circle drives an InputMap ACTION via
## Input.action_press()/action_release(), so touch feeds the EXACT same actions
## the keyboard feeds. The deterministic sim, the render-rate press latch
## (PlayerController), and every consumer of these actions stay untouched —
## touch is just another input source. (Graveyard-safe: no new pathway into the
## sim; the fireball "hold to charge, release to fire" Mario-Kart loop is just a
## held action_press, identical to holding the spacebar.)
##
## MULTITOUCH: each button hit-tests the touch against its OWN circle and tracks
## the owning finger by index, so the movement joystick and a button (and two
## buttons) can be held by different thumbs at once. We also accept mouse clicks
## so the whole rig is testable on desktop with no phone attached.
##
## Subclasses override _button_action(), _draw_icon(), and optionally
## _draw_progress()/_label_text().
class_name TouchActionButton
extends Control

## Button center in canvas px (bottom-RIGHT cluster by default). Left-handed
## mode mirrors it across the 1080-wide portrait canvas automatically.
@export var center: Vector2 = Vector2(930, 1690)

## Button radius (px). The whole disc is the touch target.
@export var radius: float = 84.0

@export var base_color: Color = Color(1, 1, 1, 0.14)
@export var ring_color: Color = Color(1, 1, 1, 0.35)
@export var icon_color: Color = Color(0.85, 0.95, 1.0, 0.95)
@export var fill_color: Color = Color(0.05, 0.05, 0.1, 0.62)

## Press feedback: the disc swells + brightens while held.
@export var pressed_scale: float = 1.12

## MatchController whose round flow gates the button: it stands down between
## rounds and on the victory screen, so e.g. the fireball button can't cast (or
## trigger a rematch) on the match-end overlay — the PLAY AGAIN button owns that.
@export var match_controller_path: NodePath = NodePath("../..")

var _label: Label
var _draw_center: Vector2
var _active: bool = true            # false between rounds / on the match-end screen
var _touch_index: int = -2          # -2 = none, -1 = mouse, >=0 = finger index
var _pressed_t: float = 0.0         # eased 0->1 press animation


func _ready() -> void:
	# Cover the whole canvas so _input positions and our hit-test share the
	# stretched 1080x1920 space; we never use rect-based _gui_input (it would
	# block the rest of the HUD), only manual circular hit-testing.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_draw_center = center

	_label = Label.new()
	_label.size = Vector2(radius * 2.0, 48)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override(&"font_size", 38)
	_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override(&"outline_size", 8)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)

	var settings: Node = get_node_or_null(^"/root/GameSettings")
	if settings != null and settings.has_signal(&"handedness_changed"):
		settings.handedness_changed.connect(_on_handedness_changed)
		_on_handedness_changed(settings.left_handed)
	else:
		_on_handedness_changed(false)

	# Active only while a round is live (no casting/dashing on the victory or
	# round-break screens). Releasing on deactivate clears any stuck action.
	var mc: Node = get_node_or_null(match_controller_path)
	if mc != null and mc.has_signal(&"round_started"):
		mc.round_started.connect(func(_n: int) -> void: _active = true)
		mc.round_ended.connect(func(_w: bool, _p: int, _o: int, _b: float) -> void: _deactivate())
		mc.match_ended.connect(func(_w: bool) -> void: _deactivate())

	_on_ready_extra()


## Stand down and release any held press (so the driven action never sticks).
func _deactivate() -> void:
	_active = false
	if is_held():
		_release()


## Subclass hook (resolve component paths, connect signals, etc.).
func _on_ready_extra() -> void:
	pass


func _on_handedness_changed(left_handed: bool) -> void:
	_draw_center = Vector2(1080.0 - center.x, center.y) if left_handed else center
	_label.position = _draw_center + Vector2(-radius, -24)
	queue_redraw()


## True while a finger/mouse owns this button.
func is_held() -> bool:
	return _touch_index != -2


func _is_inside(pos: Vector2) -> bool:
	return pos.distance_to(_draw_center) <= radius * 1.25  # forgiving thumb target


func _press() -> void:
	var action: StringName = _button_action()
	if action != &"" and InputMap.has_action(action):
		Input.action_press(action)
	queue_redraw()


func _release() -> void:
	var action: StringName = _button_action()
	if action != &"" and InputMap.has_action(action):
		Input.action_release(action)
	_touch_index = -2
	queue_redraw()


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			if _active and _touch_index == -2 and _is_inside(event.position):
				_touch_index = event.index
				_press()
				get_viewport().set_input_as_handled()
		elif event.index == _touch_index:
			_release()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _active and _touch_index == -2 and _is_inside(event.position):
				_touch_index = -1
				_press()
				get_viewport().set_input_as_handled()
		elif _touch_index == -1:
			_release()
			get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	# Lost focus / app paused with a finger down: release so the action doesn't
	# stick (Android home button, incoming call, alt-tab).
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		if is_held():
			_release()


func _process(_delta: float) -> void:
	# Ease the press swell toward its target each frame (wall-clock; this is UI).
	var target: float = 1.0 if is_held() else 0.0
	_pressed_t = move_toward(_pressed_t, target, _delta * 9.0)
	_label.text = _label_text()
	queue_redraw()


func _draw() -> void:
	var r: float = radius * lerpf(1.0, pressed_scale, _pressed_t)
	_draw_glow(_draw_center, r)  # behind the disc
	var bcol: Color = base_color
	bcol.a = lerpf(base_color.a, base_color.a + 0.12, _pressed_t)
	draw_circle(_draw_center, r, bcol)
	draw_arc(_draw_center, r, 0.0, TAU, 48, ring_color, 3.0, true)
	_draw_progress(_draw_center, r)
	_draw_icon(_draw_center, r)


# --- subclass hooks ---------------------------------------------------

## The InputMap action this button drives (e.g. &"dash", &"cast_spell").
func _button_action() -> StringName:
	return &""


## Draw the glyph inside the disc (center + current radius supplied).
func _draw_icon(_c: Vector2, _r: float) -> void:
	pass


## Optional progress viz (cooldown wedge / charge ring). Default: nothing.
func _draw_progress(_c: Vector2, _r: float) -> void:
	pass


## Optional glow/halo drawn BEHIND the disc (e.g. charge-coloured aura).
func _draw_glow(_c: Vector2, _r: float) -> void:
	pass


## Optional countdown/label text.
func _label_text() -> String:
	return ""
