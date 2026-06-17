## gen_ui_theme.gd — builds res://ui/main_theme.tres, the universal "Gen X Soft Club" / PS2 Y2K theme.
##
## Run headless:  <godot 4.6.3 console> --headless --path . -s res://tests/gen_ui_theme.gd
##
## GENERATOR (not a test suite). It constructs the Theme with the real engine API and
## ResourceSaver.save()s it — which guarantees a valid .tres, unlike hand-authoring the text. The
## DESIGN TOKENS below are the single source of truth for the aesthetic; they are mirrored in
## Wizard_Dodgeball_Brain/ui_design_system.md so every future menu stays on-palette. Re-run this
## after editing any token to regenerate the committed theme.
extends SceneTree

# ---- DESIGN TOKENS — icy blues / muted silvers / sterile whites / translucent greys --------------
const IDLE_TEXT      := Color(0.74, 0.81, 0.90)         # muted grey-blue — unfocused text (light look)
const WHITE          := Color(1.0, 1.0, 1.0)            # stark white — focused / hovered text
const HEADER_TEXT    := Color(0.93, 0.97, 1.0)          # near-white icy — headers
const INK            := Color(0.06, 0.09, 0.16)         # near-black — text on the inverted pressed fill
const DISABLED_TEXT  := Color(0.52, 0.57, 0.66)
const ACCENT         := Color(0.55, 0.82, 1.0)          # icy-blue accent — caret, focus ring

const BORDER         := Color(0.90, 0.95, 1.0, 0.55)    # 1px bright silver — the soft tech grid-line
const BORDER_HOVER   := Color(1.0, 1.0, 1.0, 0.90)
const BORDER_PRESSED := Color(1.0, 1.0, 1.0, 0.95)

const PANEL_FILL     := Color(0.84, 0.90, 0.99, 0.12)   # airy frosted silver-white (cascading panels)
const BTN_FILL       := Color(0.84, 0.90, 0.99, 0.12)
const BTN_HOVER_FILL := Color(0.93, 0.97, 1.0, 0.28)    # brighter — the hover "snap"
const BTN_PRESS_FILL := Color(0.93, 0.97, 1.0, 0.92)    # near-white — the press invert
const FIELD_FILL     := Color(0.82, 0.89, 0.99, 0.14)

const RADIUS     := 30   # soft rounded corner (the ~0.3 curve) — light / futuristic, NOT sharp
const BTN_RADIUS := 30


func _init() -> void:
	_build()
	quit()


func _build() -> void:
	var base_font: FontFile = load("res://ui/fonts/Inter.ttf")
	if base_font == null:
		push_error("[gen_ui_theme] Inter.ttf failed to load — run --headless --import first")
		quit(1)
		return

	# Inter is a variable font; weight via the 'wght' axis, tracking via spacing_glyph (the "strict
	# tracking" of the 90s-minimalist revival — heaviest on headers).
	var body := _font(base_font, 440, 1)     # body text — slightly tracked
	var ui := _font(base_font, 520, 2)       # buttons / interactive labels — medium + tracked
	var header := _font(base_font, 660, 8)   # headers — heavy + strict tracking

	var theme := Theme.new()
	theme.default_font = ui
	theme.default_font_size = 30

	# ---------- Label ----------
	theme.set_font("font", "Label", body)
	theme.set_font_size("font_size", "Label", 30)
	theme.set_color("font_color", "Label", IDLE_TEXT)
	theme.set_color("font_outline_color", "Label", Color(0, 0, 0, 0))
	theme.set_constant("outline_size", "Label", 0)
	theme.set_constant("line_spacing", "Label", 4)

	# ---------- Button  (Y2KButton extends Button -> same native class -> inherits all of this) ----------
	theme.set_font("font", "Button", ui)
	theme.set_font_size("font_size", "Button", 32)
	theme.set_color("font_color", "Button", IDLE_TEXT)
	theme.set_color("font_hover_color", "Button", WHITE)
	theme.set_color("font_focus_color", "Button", WHITE)
	theme.set_color("font_pressed_color", "Button", INK)
	theme.set_color("font_hover_pressed_color", "Button", INK)
	theme.set_color("font_disabled_color", "Button", DISABLED_TEXT)
	theme.set_constant("outline_size", "Button", 0)
	theme.set_constant("h_separation", "Button", 8)
	theme.set_stylebox("normal", "Button", _sb(BTN_FILL, BORDER, 1, BTN_RADIUS, 24, 12))
	theme.set_stylebox("hover", "Button", _sb(BTN_HOVER_FILL, BORDER_HOVER, 1, BTN_RADIUS, 24, 12))
	theme.set_stylebox("pressed", "Button", _sb(BTN_PRESS_FILL, BORDER_PRESSED, 1, BTN_RADIUS, 24, 12))
	theme.set_stylebox("disabled", "Button", _sb(Color(0.40, 0.45, 0.55, 0.05), Color(0.60, 0.66, 0.75, 0.22), 1, BTN_RADIUS, 24, 12))
	theme.set_stylebox("focus", "Button", _sb(Color(0, 0, 0, 0), ACCENT, 1, BTN_RADIUS, 24, 12))

	# ---------- Panel + PanelContainer (frosted cascading fill — the acrylic look without the blur) ----------
	theme.set_stylebox("panel", "Panel", _sb(PANEL_FILL, BORDER, 1, RADIUS, 0, 0))
	theme.set_stylebox("panel", "PanelContainer", _sb(PANEL_FILL, BORDER, 1, RADIUS, 22, 18))

	# ---------- LineEdit ----------
	theme.set_font("font", "LineEdit", body)
	theme.set_font_size("font_size", "LineEdit", 30)
	theme.set_color("font_color", "LineEdit", WHITE)
	theme.set_color("font_placeholder_color", "LineEdit", Color(0.55, 0.60, 0.70, 0.70))
	theme.set_color("caret_color", "LineEdit", ACCENT)
	theme.set_color("selection_color", "LineEdit", Color(0.40, 0.70, 1.0, 0.30))
	theme.set_stylebox("normal", "LineEdit", _sb(FIELD_FILL, BORDER, 1, BTN_RADIUS, 18, 12))
	theme.set_stylebox("focus", "LineEdit", _sb(FIELD_FILL, ACCENT, 1, BTN_RADIUS, 18, 12))

	# ---------- type variations (assign via Control.theme_type_variation) ----------
	theme.set_type_variation("HeaderLabel", "Label")
	theme.set_font("font", "HeaderLabel", header)
	theme.set_font_size("font_size", "HeaderLabel", 56)
	theme.set_color("font_color", "HeaderLabel", HEADER_TEXT)

	theme.set_type_variation("TitleLabel", "Label")
	theme.set_font("font", "TitleLabel", header)
	theme.set_font_size("font_size", "TitleLabel", 72)
	theme.set_color("font_color", "TitleLabel", WHITE)

	theme.set_type_variation("MutedLabel", "Label")
	theme.set_font("font", "MutedLabel", body)
	theme.set_font_size("font_size", "MutedLabel", 24)
	theme.set_color("font_color", "MutedLabel", Color(0.52, 0.58, 0.68))

	var err := ResourceSaver.save(theme, "res://ui/main_theme.tres")
	if err != OK:
		push_error("[gen_ui_theme] ResourceSaver.save failed: %d" % err)
		quit(1)
		return
	print("[gen_ui_theme] wrote res://ui/main_theme.tres OK (font=", base_font.resource_path, ")")


## One Inter weight+tracking as a FontVariation (wght axis + per-glyph spacing).
func _font(base: FontFile, weight: int, tracking: int) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = base
	fv.variation_opentype = {"wght": float(weight)}
	fv.spacing_glyph = tracking
	return fv


## A frosted StyleBoxFlat: translucent fill, crisp thin border, tiny chamfer, symmetric padding.
func _sb(bg: Color, border_col: Color, border_w: int, radius: int, pad_h: int, pad_v: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border_col
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	sb.anti_aliasing = true
	return sb
