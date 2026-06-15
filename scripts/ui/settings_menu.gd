## settings_menu.gd — The Escape settings menu.
##
## Toggled by ui_cancel (Escape). Opening PAUSES the tree (the deterministic
## sim parks — its tick drivers live in pausable nodes); this layer runs in
## PROCESS_MODE_ALWAYS so the menu itself stays interactive.
##
## Settings live in the GameSettings autoload; this is just the panel.
## Current options:
##   - LEFT-HANDED MODE: camera over the left shoulder + all HUD elements
##     mirrored (hand/dash to the left thumb, health bar top-right).
extends CanvasLayer

## Show the "Leave match" button (true in match scenes; the home screen
## sets this false on its own SettingsMenu instance).
@export var show_leave_match: bool = true

var _dim: ColorRect
var _title: Label
var _left_toggle: CheckButton
var _leave_button: Button
var _resume_button: Button
var _hint: Label
var _menu_button: Control       # always-visible top-left opener (touch — mobile has no ESC)
var _open: bool = false


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS

	_dim = ColorRect.new()
	_dim.color = Color(0.0, 0.0, 0.04, 0.8)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_dim)

	_title = Label.new()
	_title.text = "SETTINGS"
	_title.position = Vector2(0, 560)
	_title.size = Vector2(1080, 90)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override(&"font_size", 64)
	add_child(_title)

	_left_toggle = CheckButton.new()
	_left_toggle.text = "Left-handed mode"
	_left_toggle.position = Vector2(330, 760)
	_left_toggle.size = Vector2(420, 80)
	_left_toggle.add_theme_font_size_override(&"font_size", 34)
	_left_toggle.toggled.connect(_on_left_handed_toggled)
	add_child(_left_toggle)

	# LEAVE MATCH — only meaningful inside a match scene (the home screen's
	# settings hides it).
	_leave_button = Button.new()
	_leave_button.text = "Leave match"
	_leave_button.position = Vector2(390, 1020)
	_leave_button.size = Vector2(300, 86)
	_leave_button.add_theme_font_size_override(&"font_size", 32)
	_leave_button.pressed.connect(_on_leave_match)
	add_child(_leave_button)

	# RESUME — closes the menu on TOUCH (mobile has no ESC key).
	_resume_button = Button.new()
	_resume_button.text = "Resume"
	_resume_button.position = Vector2(390, 900)
	_resume_button.size = Vector2(300, 86)
	_resume_button.add_theme_font_size_override(&"font_size", 32)
	_resume_button.pressed.connect(_on_resume)
	add_child(_resume_button)

	_hint = Label.new()
	_hint.text = "Tap RESUME (or press ESC)"
	_hint.position = Vector2(0, 1150)
	_hint.size = Vector2(1080, 50)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override(&"font_size", 28)
	_hint.add_theme_color_override(&"font_color", Color(0.7, 0.7, 0.8))
	add_child(_hint)

	# TOP-LEFT MENU OPENER — the only way into the menu on TOUCH. Sits just right of
	# the health bar; visible ONLY while the menu is closed (hidden once it's open).
	_menu_button = _MenuButton.new()
	_menu_button.position = Vector2(112, 40)
	_menu_button.size = Vector2(84, 84)
	_menu_button.mouse_filter = Control.MOUSE_FILTER_STOP
	_menu_button.pressed.connect(_on_menu_button)
	add_child(_menu_button)

	_set_open(false)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Sfx.play(&"ui_click")
		_set_open(not _open)
		get_viewport().set_input_as_handled()


## Public open hook (the home screen's gear button calls this).
func open() -> void:
	_set_open(true)


func _set_open(open: bool) -> void:
	_open = open
	_dim.visible = open
	_title.visible = open
	_left_toggle.visible = open
	_leave_button.visible = open and show_leave_match
	_resume_button.visible = open
	_hint.visible = open
	_menu_button.visible = not open   # the opener tucks away while the menu is up
	get_tree().paused = open
	if open:
		var settings: Node = get_node_or_null(^"/root/GameSettings")
		if settings != null:
			_left_toggle.set_pressed_no_signal(settings.left_handed)


func _on_left_handed_toggled(pressed: bool) -> void:
	var settings: Node = get_node_or_null(^"/root/GameSettings")
	if settings != null:
		settings.set_left_handed(pressed)


func _on_leave_match() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/home_screen.tscn")


func _on_resume() -> void:
	Sfx.play(&"ui_click")
	_set_open(false)


func _on_menu_button() -> void:
	Sfx.play(&"ui_click")
	_set_open(true)


## Top-left menu opener — a DRAWN hamburger (no font-glyph dependency on mobile).
## STOP mouse_filter so it eats only its own small rect; the rest of the screen
## stays playable while the menu is closed.
class _MenuButton extends Control:
	signal pressed

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.10, 0.16, 0.55), true)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.3, 0.95, 1.0, 0.55), false, 2.0)
		var pad: float = size.x * 0.26
		var line_h: float = size.y * 0.11
		for i in 3:
			var yy: float = size.y * (0.30 + float(i) * 0.20)
			draw_rect(Rect2(Vector2(pad, yy - line_h * 0.5), Vector2(size.x - pad * 2.0, line_h)),
					Color(0.85, 0.95, 1.0, 0.95), true)

	func _gui_input(event: InputEvent) -> void:
		var touched: bool = event is InputEventScreenTouch and event.pressed
		var clicked: bool = event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT and event.pressed
		if touched or clicked:
			pressed.emit()
			accept_event()
