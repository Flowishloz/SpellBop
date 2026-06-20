## placeholder_border.gd — procedural FALLBACK frame, drawn when a universal border PNG
## (border_pill / border_in_round / border_full) isn't on disk yet, so a card never looks unframed
## during the art pass. A cyan or gold double-rectangle (matching the generated placeholder look),
## optionally with a top name plate (the in-round card). Presentation only.
class_name PlaceholderBorder
extends Control

## Frame BASE colour — a near-white grayscale; callers tint it via `modulate` by Card Type
## (red attack / green defense / blue counter), matching how the eventual grayscale PNGs are tinted.
@export var col: Color = Color(0.93, 0.95, 1.0):
	set(value):
		col = value
		queue_redraw()

## Draw a darkened top name-plate band (the in-round 5:7 card needs one for its name).
@export var plate: bool = false:
	set(value):
		plate = value
		queue_redraw()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var w := size.x
	var h := size.y
	var thick := maxf(3.0, minf(w, h) * 0.035)
	var ins := thick * 0.5 + 2.0
	draw_rect(Rect2(ins, ins, w - 2.0 * ins, h - 2.0 * ins), col, false, thick)
	var ins2 := ins + thick + 6.0
	if w - 2.0 * ins2 > 0.0 and h - 2.0 * ins2 > 0.0:
		draw_rect(Rect2(ins2, ins2, w - 2.0 * ins2, h - 2.0 * ins2), col, false, 2.0)
	if plate:
		var py := ins + thick + 8.0
		var ph := maxf(28.0, h * 0.10)
		draw_rect(Rect2(ins2, py, w - 2.0 * ins2, ph), Color(0.03, 0.04, 0.06, 0.66), true)
		draw_rect(Rect2(ins2, py, w - 2.0 * ins2, ph), col, false, 2.0)
