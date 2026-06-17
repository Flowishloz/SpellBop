## probe_ui_theme.gd — HEADLESS smoke for the Y2K "Gen X Soft Club" UI theme system.
##
## Verifies: (1) res://ui/main_theme.tres loads as a Theme carrying the Button states + the frosted
## Panel + the HeaderLabel/TitleLabel type variations + a default font; (2) Y2KButton instances and
## runs _ready (its ► cursor + scanline overlay children) without error under that theme; (3) the home
## screen (which mounts the themed menu_flow) and the settings menu both build headless.
## Run: <godot 4.6.3> --headless --path . -s res://tests/probe_ui_theme.gd
extends SceneTree


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame

	# 1) The theme resource.
	var theme: Theme = load("res://ui/main_theme.tres")
	print("THEME is_theme=", theme is Theme,
		" default_font=", theme != null and theme.default_font != null,
		" btn_normal=", theme != null and theme.has_stylebox("normal", "Button"),
		" btn_pressed=", theme != null and theme.has_stylebox("pressed", "Button"),
		" panel=", theme != null and theme.has_stylebox("panel", "PanelContainer"),
		" header=", theme != null and theme.has_font("font", "HeaderLabel"),
		" title=", theme != null and theme.has_font("font", "TitleLabel"))

	# 2) Y2KButton instances + _ready under the theme.
	var holder := Control.new()
	holder.theme = theme
	root.add_child(holder)
	var btn := Y2KButton.new()
	btn.text = "TEST"
	btn.size = Vector2(300, 90)
	holder.add_child(btn)
	for i in 4:
		await process_frame
	print("Y2KBUTTON ok child_count=", btn.get_child_count(), " (cursor + scan overlay)")

	# 3) The home screen (mounts the themed menu_flow) + the settings menu build headless.
	var home: Node = load("res://scenes/home_screen.tscn").instantiate()
	root.add_child(home)
	for i in 6:
		await process_frame
	print("HOME built OK children=", home.get_child_count())

	var settings: Node = load("res://scripts/ui/settings_menu.gd").new()
	root.add_child(settings)
	for i in 4:
		await process_frame
	print("SETTINGS built OK")
	quit(0)
