## screenshot_aim_arrow.gd — Mobile-MP B2b visual ground truth: boots the arena, makes
## the local Player CHARGE a fireball while banking a strong rightward aim, and saves
## what the camera renders so the glowing ground aim arrow can be eyeballed.
## NOT headless (needs a real window/GPU).
## Run: <godot> --path . -s res://tests/screenshot_aim_arrow.gd
extends SceneTree

const SCENE := "res://scenes/match_arena.tscn"
const OUT := "res://tests/_screenshot_aim_arrow.png"
const AIM_SECTOR := 14   # right tilt (of 24) so the arrow's angle is obvious


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var packed: PackedScene = load(SCENE)
	if packed == null:
		print("PROBE FAIL: scene did not load")
		quit(1)
		return
	root.add_child(packed.instantiate())
	for i in 120:   # let the round go ACTIVE and the ROUND 1 banner clear
		await process_frame
	# Drive the local Player: hold cast (build + hold charge) + bank a rightward aim.
	InputCommand.touch_aim_sector = AIM_SECTOR
	Input.action_press(&"cast_spell")
	for i in 50:
		await process_frame
	# Diagnostic: confirm the local wizard is actually charging + its aim sector.
	var charging := false
	var sector := 0
	for w in get_nodes_in_group("wizards"):
		for c in w.get_children():
			if c.has_method("is_charging") and c.is_charging():
				charging = true
				sector = c.get_aim_sector()
	print("DIAG: charging=", charging, " aim_sector=", sector)
	var img: Image = root.get_texture().get_image()
	img.save_png(OUT)
	print("PROBE: saved ", OUT, " (", img.get_width(), "x", img.get_height(), ")")
	Input.action_release(&"cast_spell")
	InputCommand.touch_aim_sector = 0
	quit(0)
