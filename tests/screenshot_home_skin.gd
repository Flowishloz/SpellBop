## screenshot_home_skin.gd — boots the HOME screen with a chosen EQUIPPED skin and screenshots it, to
## verify the title-screen wizard reflects the cosmetics choice (cosmetics EQUIP -> GameSettings ->
## the title wizard). NOT headless — needs a real window / GPU.
## Run: <godot> --path . -s res://tests/screenshot_home_skin.gd ++ default_red
extends SceneTree

const OUT := "res://tests/_screenshot.png"


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var skin_id := "default_blue"
	for arg in OS.get_cmdline_user_args():
		skin_id = arg
	# Set the equipped skin IN MEMORY only (don't persist to user:// during a test run).
	var gs: Node = root.get_node_or_null("GameSettings")
	if gs != null:
		gs.set(&"equipped_skin", StringName(skin_id))
	root.add_child(load("res://scenes/home_screen.tscn").instantiate())
	for i in 45:
		await process_frame
	var img: Image = root.get_texture().get_image()
	img.save_png(OUT)
	print("PROBE: home with equipped='", skin_id, "' -> ", OUT, " (", img.get_width(), "x", img.get_height(), ")")
	quit(0)
