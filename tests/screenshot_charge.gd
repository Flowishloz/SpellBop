## screenshot_charge.gd — visual proof of the fireball charge rework: drives the
## player's fireball to gauge 3 (holding cast) so the segmented cast button (3
## thirds lit yellow/red/blue), the BLUE charge particles, the shaking wizard,
## and the screen rumble all show. Saves tests/_screenshot_charge.png.
## NOT headless. Run: <godot> --path . -s res://tests/screenshot_charge.gd
extends SceneTree


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	root.add_child(arena)
	for i in 30:
		await process_frame

	# Take manual control so the player's own tick driver (cast not held) doesn't
	# drain the charge we're banking by hand.
	arena.get_node("Player").local_tick_driver_enabled = false
	var spell: Node = arena.get_node("Player/SpellCasterComponent")
	# Capture the button at EACH gauge to verify the segmented thirds light in
	# order (yellow @ 1, red @ 2, blue @ 3).
	for target in [1, 2, 3]:
		var guard: int = 0
		while spell.charge_level() < target and guard < 400:
			spell._network_process({"c": 1})
			guard += 1
		for i in 12:
			spell._network_process({"c": 1})  # hold at this gauge while rendering
			await process_frame
		var img: Image = root.get_texture().get_image()
		img.save_png("res://tests/_charge_l%d.png" % target)
		print("PROBE: saved _charge_l%d.png (level %d)" % [target, spell.charge_level()])
	quit(0)
