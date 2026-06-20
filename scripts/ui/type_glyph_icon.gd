## type_glyph_icon.gd — procedural TYPE glyph (lightning / shield / frost-diamond) by CardResource.card_type.
##
## The ART-WELL fallback when a card has no card_art yet — the same shapes the deck tiles have always
## drawn. Exposes a STATIC draw_glyph() so the deck-pill _draw() and this node share one implementation.
## Presentation only.
class_name TypeGlyphIcon
extends Control

@export var card_type: int = 0:
	set(value):
		card_type = value
		queue_redraw()
@export var tint: Color = Color(0.82, 0.86, 0.95):
	set(value):
		tint = value
		queue_redraw()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	draw_glyph(self, Rect2(Vector2.ZERO, size), card_type, tint)


## Draw the type glyph into ANY CanvasItem, centred in `rect` (shared by the deck tiles + this node).
static func draw_glyph(ci: CanvasItem, rect: Rect2, ftype: int, col: Color) -> void:
	var c := rect.position + rect.size * 0.5
	var r := minf(rect.size.x, rect.size.y) * 0.30
	match ftype:
		0:  # ATTACK — lightning bolt
			ci.draw_colored_polygon(PackedVector2Array([
				c + Vector2(-r * 0.3, -r), c + Vector2(r * 0.45, -r * 0.15),
				c + Vector2(r * 0.05, -r * 0.15), c + Vector2(r * 0.4, r),
				c + Vector2(-r * 0.45, r * 0.1), c + Vector2(-r * 0.02, r * 0.1)]), col)
		1:  # DEFENSE — shield
			ci.draw_colored_polygon(PackedVector2Array([
				c + Vector2(0, -r * 1.1), c + Vector2(r, -r * 0.6), c + Vector2(r * 0.7, r * 0.5),
				c + Vector2(0, r * 1.1), c + Vector2(-r * 0.7, r * 0.5), c + Vector2(-r, -r * 0.6)]), col)
		_:  # COUNTER — frost diamond
			ci.draw_colored_polygon(PackedVector2Array([
				c + Vector2(0, -r), c + Vector2(r * 0.7, 0), c + Vector2(0, r), c + Vector2(-r * 0.7, 0)]), col)
			ci.draw_line(c + Vector2(-r, 0), c + Vector2(r, 0), col, 3.0)
			ci.draw_line(c + Vector2(0, -r), c + Vector2(0, r), col, 3.0)
