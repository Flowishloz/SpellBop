## y2k_ui_button.gd — the reusable Y2K / PS2-era menu button.
##
## class_name Y2KButton extends Button. Standardises late-90s / early-2000s digital-interface feedback
## so every menu button feels identical:
##   • HOVER / FOCUS — a fast DIGITAL "SNAP": the theme flips the background to brighter silver
##     instantly (no smooth web-style scaling), this script flashes the whole button over-bright for
##     ~0.1 s, and a blocky ► selection cursor pops in at the left edge.
##   • PRESS — PUNCHY + immediate: the theme inverts the colours (near-white fill, dark-ink text) and
##     this script bursts a horizontal SCANLINE that sweeps down the face.
##
## All feedback is Tween-driven and CONTAINER-SAFE: it only animates child overlays and `modulate`,
## never a layout-managed `position`, so it behaves whether the button is absolutely placed (the
## home / cosmetics menus) or sits inside a container.
##
## It carries (almost) no values of its own — the look comes from res://ui/main_theme.tres; ACCENT
## mirrors that theme's icy-blue accent token. See Wizard_Dodgeball_Brain/ui_design_system.md.
class_name Y2KButton extends Button

## Icy-blue accent — mirrors the `ACCENT` token in tests/gen_ui_theme.gd / main_theme.tres.
const ACCENT := Color(0.55, 0.82, 1.0)

## Set false for icon-only buttons (e.g. the carousel arrows / a close ✕) to suppress the ► selection
## cursor while the snap-flash + press-scanline still play.
var show_cursor: bool = true

var _cursor: _CursorTri
var _scan: _ScanFX
var _hovered: bool = false
var _focused: bool = false
var _active: bool = false
var _snap_tw: Tween
var _press_tw: Tween


func _ready() -> void:
	clip_contents = false

	_scan = _ScanFX.new()
	_scan.line_col = ACCENT
	_scan.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scan.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_scan)

	_cursor = _CursorTri.new()
	_cursor.col = ACCENT
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	add_child(_cursor)

	_relayout()
	resized.connect(_relayout)
	mouse_entered.connect(func() -> void: _hovered = true; _refresh_active())
	mouse_exited.connect(func() -> void: _hovered = false; _refresh_active())
	focus_entered.connect(func() -> void: _focused = true; _refresh_active())
	focus_exited.connect(func() -> void: _focused = false; _refresh_active())
	button_down.connect(_on_press)


func _relayout() -> void:
	if _cursor != null:
		var c := minf(size.y * 0.30, 26.0)
		_cursor.size = Vector2(c, c)
		_cursor.position = Vector2(14.0, (size.y - c) * 0.5)
		_cursor.queue_redraw()


func _refresh_active() -> void:
	var want := (_hovered or _focused) and not disabled
	if want == _active:
		return
	_active = want
	if _cursor != null:
		_cursor.visible = want and show_cursor
	if want:
		_snap()


## Instant digital snap — a brief over-bright flash that settles fast (NOT an eased-in scale).
func _snap() -> void:
	if _snap_tw != null and _snap_tw.is_valid():
		_snap_tw.kill()
	modulate = Color(1.28, 1.30, 1.36)
	_snap_tw = create_tween()
	_snap_tw.tween_property(self, "modulate", Color(1, 1, 1, 1), 0.10) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


## Punchy press — a bright scanline sweeps down the face (the theme handles the colour invert).
func _on_press() -> void:
	if disabled or _scan == null:
		return
	if _press_tw != null and _press_tw.is_valid():
		_press_tw.kill()
	_scan.flash = 1.0
	_scan.sweep = 0.0
	_press_tw = create_tween().set_parallel(true)
	_press_tw.tween_property(_scan, "sweep", 1.0, 0.16).set_trans(Tween.TRANS_QUAD)
	_press_tw.tween_property(_scan, "flash", 0.0, 0.20).set_trans(Tween.TRANS_QUAD)


# --- a blocky right-pointing selection cursor (font-independent, like the project's other _draw icons) ---
class _CursorTri extends Control:
	var col: Color = Color(0.55, 0.82, 1.0)

	func _draw() -> void:
		var w := size.x
		var h := size.y
		# a chunky right-pointing wedge with a square nub — reads as a digital menu cursor
		draw_rect(Rect2(0.0, h * 0.30, w * 0.34, h * 0.40), col)
		draw_colored_polygon(PackedVector2Array([
			Vector2(w * 0.30, 0.0), Vector2(w, h * 0.5), Vector2(w * 0.30, h),
		]), col)


# --- a horizontal scanline burst that sweeps down the button face on press ---
class _ScanFX extends Control:
	var line_col: Color = Color(1, 1, 1, 1)
	var flash: float = 0.0:
		set(value):
			flash = value
			queue_redraw()
	var sweep: float = 0.0:
		set(value):
			sweep = value
			queue_redraw()

	func _draw() -> void:
		if flash <= 0.01:
			return
		# faint static grid lines flashing across the whole face
		var yy := 2.0
		while yy < size.y:
			draw_line(Vector2(0.0, yy), Vector2(size.x, yy),
				Color(line_col.r, line_col.g, line_col.b, 0.10 * flash), 1.0)
			yy += 5.0
		# one bright scanline sweeping downward
		var y := sweep * size.y
		draw_rect(Rect2(0.0, y - 1.5, size.x, 3.0),
			Color(line_col.r, line_col.g, line_col.b, 0.75 * flash))
