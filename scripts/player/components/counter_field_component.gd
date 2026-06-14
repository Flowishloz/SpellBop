## counter_field_component.gd — The COUNTER card's reflect window (Category C).
##
## ROLE: armed by CardCasterComponent when a Counter card resolves. For the
## card's opportunity_window (sim ticks), this component scans the projectile
## container each tick for a hostile ball inside the counter radius and
## REDIRECTS the first one it catches: velocity reversed back toward its
## original caster and multiplied by the card's speed_modifier (Manifesto:
## the baseline counter returns the ball at 2x speed). The redirected ball's
## hit source becomes THIS wizard, so it can now strike the original attacker.
##
## DETERMINISM: pure int math — the same direction-sign threat test the AI
## brain uses, plus a fixed-point radius box. Window/multiplier are int sim
## state, saved/loaded for rollback.
##
## GRAVEYARD COMPLIANCE (NO proactive counter spam): this field reflects
## exactly ONE projectile then closes, it only exists for a short armed
## window, and the Counter CARD that arms it is reactive-only (castable only
## during the Stack window — enforced by CardCasterComponent).
class_name CounterFieldComponent
extends Node

## A hostile projectile was caught and redirected. MatchController listens:
## closes the Stack window early (the counter IS the answer) + camera shake.
signal counter_triggered(projectile: Node)

## Path to this wizard's SGCharacterBody2D. Empty = direct parent.
@export var body_path: NodePath

## Container whose children are live projectiles (the arena "Projectiles"
## node — same default shape as AIBrainComponent).
@export var projectile_container_path: NodePath = NodePath("../../Projectiles")

## Catch radius around the wizard, sim units: a hostile ball whose |dx| AND
## |dy| are inside this is caught. Generous by design — countering is a
## reactive skill moment, not a pixel hunt.
@export var counter_radius: float = 260.0

# Authoritative sim state (ints): ticks of armed window remaining, and the
# latched fixed-point speed multiplier for the redirect.
var _window_remaining: int = 0
var _speed_mult_fp: int = 131072  # 2.0 — overwritten by activate()

var _body: SGCharacterBody2D
var _container: Node
var _radius_fp: int = 0


func _ready() -> void:
	_body = _resolve_body()
	assert(_body != null, "CounterFieldComponent requires an SGCharacterBody2D (set body_path or parent it under one).")
	_container = get_node_or_null(projectile_container_path)
	_radius_fp = SGFixed.from_float(maxf(0.0, counter_radius))


## Arms the field. Called by CardCasterComponent when a Counter card resolves.
##  - window_ticks: armed duration, whole sim ticks (ceil of opportunity_window).
##  - speed_mult_fp: fixed-point redirect multiplier (131072 = 2x).
func activate(window_ticks: int, speed_mult_fp: int) -> void:
	_window_remaining = maxi(_window_remaining, window_ticks)
	_speed_mult_fp = speed_mult_fp


# =====================================================================
# ROLLBACK CONTRACT
# =====================================================================

## One armed tick: count down, scan, redirect at most one hostile ball.
func _network_process(_input: Dictionary) -> void:
	if _window_remaining <= 0:
		return
	_window_remaining -= 1

	if _container == null:
		return
	var my_pos: SGFixedVector2 = _body.get_global_fixed_position()
	for child in _container.get_children():
		if not child.has_method(&"redirect") or not child.has_method(&"get_velocity_y"):
			continue
		var ball_pos: SGFixedVector2 = child.get_global_fixed_position()
		var dy: int = my_pos.y - ball_pos.y
		var vy: int = child.get_velocity_y()
		# Hostile = moving TOWARD me (the AI brain's threat-sign test). A ball
		# we just threw (or already reflected) moves away and is skipped.
		if vy == 0 or (vy > 0) != (dy > 0):
			continue
		if absi(my_pos.x - ball_pos.x) < _radius_fp and absi(dy) < _radius_fp:
			child.redirect(_body, _speed_mult_fp)
			_window_remaining = 0
			counter_triggered.emit(child)
			return


func _save_state() -> Dictionary:
	return {
		"cw": _window_remaining,
		"cm": _speed_mult_fp,
	}


func _load_state(state: Dictionary) -> void:
	_window_remaining = int(state.get("cw", 0))
	_speed_mult_fp = int(state.get("cm", 131072))


func _resolve_body() -> SGCharacterBody2D:
	if not body_path.is_empty():
		return get_node_or_null(body_path) as SGCharacterBody2D
	return get_parent() as SGCharacterBody2D
