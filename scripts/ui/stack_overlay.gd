## stack_overlay.gd — The Stack telegraph UI (the card block + countdown).
##
## THE UI EXCEPTION (Manifesto §2): while the sim runs at 10% inside the Stack
## window, this overlay must run at 100%. Engine.time_scale scales _process
## delta, so NOTHING here animates off delta — all motion and the countdown
## are driven by Time.get_ticks_msec() (wall clock, immune to time_scale).
##
## Behavior: when TheStack opens, a placeholder card block slides down from
## the top of the portrait screen with a real-seconds countdown; when the
## window closes, it slides back out. The card visual is a PLACEHOLDER — the
## Creative Director replaces the Panel contents with real card art later;
## this script only moves whatever the "Card" Control is.
extends CanvasLayer

## Y position (px, canvas space) of the card's top edge while shown.
@export var shown_top: float = 48.0

## Real seconds for the slide-in/slide-out animation.
@export var slide_seconds: float = 0.25

@onready var _card: Control = $Card
@onready var _countdown: Label = $Card/Countdown

var _stack: Node = null
var _card_height: float = 0.0
var _hidden_top: float = 0.0
var _progress: float = 0.0  # 0 = hidden above the screen, 1 = fully shown.
var _target: float = 0.0
var _last_msec: int = 0


func _ready() -> void:
	_card_height = _card.offset_bottom - _card.offset_top
	_hidden_top = -(_card_height + 64.0)
	_apply(0.0)
	_last_msec = Time.get_ticks_msec()

	# Autoload lookup is defensive so headless test harnesses that strip
	# autoloads degrade to a warning instead of a crash.
	_stack = get_node_or_null(^"/root/TheStack")
	if _stack == null:
		push_warning("StackOverlay: TheStack autoload not found — overlay inert.")
		return
	_stack.stack_opened.connect(_on_stack_opened)
	_stack.stack_tick.connect(_on_stack_tick)
	_stack.stack_closed.connect(_on_stack_closed)


func _process(_delta: float) -> void:
	# Wall-clock delta: identical animation speed at time_scale 1.0 or 0.1.
	var now: int = Time.get_ticks_msec()
	var real_delta: float = float(now - _last_msec) / 1000.0
	_last_msec = now

	if _progress == _target:
		return
	_progress = move_toward(_progress, _target, real_delta / maxf(slide_seconds, 0.001))
	_apply(_progress)


func _on_stack_opened(duration_s: float) -> void:
	_target = 1.0
	_countdown.text = "%.1f" % duration_s


func _on_stack_tick(remaining_s: float) -> void:
	_countdown.text = "%.1f" % remaining_s


func _on_stack_closed() -> void:
	_target = 0.0


## Positions the card between hidden (above the screen) and shown, with a
## smoothstep ease. Pure canvas-space movement; touches only the Card control.
func _apply(p: float) -> void:
	var eased: float = p * p * (3.0 - 2.0 * p)
	var top: float = lerpf(_hidden_top, shown_top, eased)
	_card.offset_top = top
	_card.offset_bottom = top + _card_height
