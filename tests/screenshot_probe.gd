## screenshot_probe.gd — boots a scene, waits, saves what the camera actually
## renders to tests/_screenshot.png, and quits. Visual ground truth for scene
## debugging (NOT headless — needs a real window/GPU).
## Run: <godot> --path . -s res://tests/screenshot_probe.gd
extends SceneTree

const SCENE := "res://scenes/match_arena.tscn"
const OUT := "res://tests/_screenshot.png"


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	# Optional override: <godot> --path . -s ...probe.gd ++ res://scenes/x.tscn
	var scene_path: String = SCENE
	for arg in OS.get_cmdline_user_args():
		if arg.ends_with(".tscn"):
			scene_path = arg
	var packed: PackedScene = load(scene_path)
	if packed == null:
		print("PROBE FAIL: scene did not load")
		quit(1)
		return
	root.add_child(packed.instantiate())
	for i in 45:
		await process_frame
	var img: Image = root.get_texture().get_image()
	img.save_png(OUT)
	print("PROBE: saved ", OUT, " (", img.get_width(), "x", img.get_height(), ")")
	quit(0)
