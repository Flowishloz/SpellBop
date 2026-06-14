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
var _hint: Label
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

	_hint = Label.new()
	_hint.text = "ESC to resume"
	_hint.position = Vector2(0, 920)
	_hint.size = Vector2(1080, 50)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override(&"font_size", 28)
	_hint.add_theme_color_override(&"font_color", Color(0.7, 0.7, 0.8))
	add_child(_hint)

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
	_hint.visible = open
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
