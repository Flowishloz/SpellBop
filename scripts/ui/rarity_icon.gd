## rarity_icon.gd — procedural RARITY indicator (placeholder until a real asset exists).
##
## Draws a shape by CardResource.rarity, tinted: 0 Common = silver CIRCLE, 1 Uncommon = green DIAMOND,
## 2 Rare = gold STAR. Used in all 3 card variants (deck pill / in-round / Big Inspect). Presentation only.
class_name RarityIcon
extends Control

const COL := {0: Color(0.72, 0.77, 0.85), 1: Color(0.48, 0.86, 0.62), 2: Color(1.0, 0.81, 0.36)}

@export var rarity: int = 0:
	set(value):
		rarity = value
		queue_redraw()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var col: Color = COL.get(rarity, COL[0])
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.46
	# subtle dark backing disc so the shape reads on bright art
	draw_circle(c, minf(size.x, size.y) * 0.5, Color(0, 0, 0, 0.34))
	match rarity:
		0:  # Common — circle
			draw_circle(c, r, col)
		1:  # Uncommon — diamond
			draw_colored_polygon(PackedVector2Array([
				c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)]), col)
		_:  # Rare — 5-point star
			draw_colored_polygon(_star(c, r, r * 0.44, 5), col)


static func _star(c: Vector2, outer: float, inner: float, points: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in points * 2:
		var rad := outer if (i % 2 == 0) else inner
		var a := -PI / 2.0 + float(i) * PI / float(points)
		pts.append(c + Vector2(cos(a) * rad, sin(a) * rad))
	return pts
