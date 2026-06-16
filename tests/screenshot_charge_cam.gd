## screenshot_charge_cam.gd — captures the IN-ACTION charge framing: holds a near-full fireball
## charge so the camera tightens its FOV + dips down + looks up, then saves tests/_screenshot.png.
## Run (NOT headless — needs a window/GPU): <godot> --path . -s res://tests/screenshot_charge_cam.gd
extends SceneTree


func _init() -> void:
	_run()


func _wait_frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	root.add_child(arena)
	await _wait_frames(20)
	var player: Node = arena.get_node("Player")
	var spell: Node = player.get_node("SpellCasterComponent")
	player.local_tick_driver_enabled = false
	# Build a near-full charge and HOLD it (don't release) so the framing eases all the way in.
	for i in 80:
		spell._network_process({"c": 1})
	await _wait_frames(45)   # let the camera ease into the charged framing
	var img: Image = root.get_texture().get_image()
	img.save_png("res://tests/_screenshot.png")
	print("CHARGE-CAM PROBE: saved (charge_fraction=%.2f)" % spell.charge_fraction())
	quit(0)
