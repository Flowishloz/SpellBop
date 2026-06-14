## dash_button_hud.gd — The dash thumb button: translucent disc + ">>" chevrons
## + a clock-style cooldown wedge + the seconds-remaining number.
##
## Now a real PRESSABLE button (TouchActionButton): a tap drives the "dash"
## action (Input.action_press/release), exactly like Left Shift on desktop —
## the dash stays edge-triggered in-sim, so holding the disc dashes once and
## re-arms on release. On desktop it doubles as the Shift cooldown readout.
extends TouchActionButton

## The player's MovementComponent (cooldown source).
@export var movement_path: NodePath = NodePath("../../Player/Movement")

var _movement: Node


func _on_ready_extra() -> void:
	_movement = get_node_or_null(movement_path)
	if _movement == null or not _movement.has_method(&"dash_cooldown_fraction"):
		push_warning("DashButtonHUD: MovementComponent not found — readout inert.")
		_movement = null


func _button_action() -> StringName:
	return &"dash"


func _label_text() -> String:
	if _movement == null:
		return ""
	var seconds: float = _movement.dash_cooldown_seconds_remaining()
	return ("%d" % ceili(seconds)) if seconds > 0.05 else ""


func _draw_progress(c: Vector2, r: float) -> void:
	# Clock fill: the remaining-cooldown wedge sweeps from 12 o'clock and
	# SHRINKS as the cooldown completes.
	if _movement == null:
		return
	var fraction: float = _movement.dash_cooldown_fraction()
	if fraction <= 0.001:
		return
	var points := PackedVector2Array([c])
	var steps: int = 40
	for i in steps + 1:
		var angle: float = -PI / 2.0 + TAU * fraction * (float(i) / float(steps))
		points.append(c + Vector2(cos(angle), sin(angle)) * r)
	draw_colored_polygon(points, fill_color)


func _draw_icon(c: Vector2, r: float) -> void:
	# ">>" dash chevrons.
	var s: float = r * 0.34
	for offset_x in [-s * 0.8, s * 0.35]:
		var o: Vector2 = c + Vector2(offset_x, 0)
		draw_polyline(PackedVector2Array([
			o + Vector2(-s * 0.35, -s),
			o + Vector2(s * 0.55, 0),
			o + Vector2(-s * 0.35, s),
		]), icon_color, 7.0, true)
