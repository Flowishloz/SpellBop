## screenshot_cosmetics_skin.gd — boots the COSMETICS scene, selects a chosen skin on the carousel,
## and screenshots it. Verifies a previously-LOCKED skin (e.g. space_wizard) now renders on the podium
## AND shows EQUIP (not PURCHASE) while the DEV_UNLOCK_ALL master switch is on. NOT headless — needs a
## real window / GPU.
## Run: <godot> --path . -s res://tests/screenshot_cosmetics_skin.gd ++ space_wizard
extends SceneTree

const OUT := "res://tests/_screenshot.png"


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var skin_id := "space_wizard"
	for arg in OS.get_cmdline_user_args():
		skin_id = arg
	var cos: Node = load("res://scenes/cosmetics.tscn").instantiate()
	root.add_child(cos)
	for i in 20:
		await process_frame
	# Drive the carousel onto the requested skin (live podium preview + EQUIP/PURCHASE refresh).
	if cos.has_method(&"_select_skin"):
		cos.call(&"_select_skin", StringName(skin_id))
	for i in 30:
		await process_frame
	var img: Image = root.get_texture().get_image()
	img.save_png(OUT)
	print("PROBE: cosmetics showing '", skin_id, "' -> ", OUT, " (", img.get_width(), "x", img.get_height(), ")")
	quit(0)
